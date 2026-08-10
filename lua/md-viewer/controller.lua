local backends = require("md-viewer.backends")
local caret = require("md-viewer.caret")
local cellpixels = require("md-viewer.cellpixels")
local config = require("md-viewer.config")
local coordinates = require("md-viewer.coordinates")
local preview = require("md-viewer.preview")
local renderer = require("md-viewer.renderer")
local state = require("md-viewer.state")
local sync = require("md-viewer.sync")
local process = require("md-viewer.process")
local debounce = require("md-viewer.debounce")
local navigation = require("md-viewer.navigation")
local mouse = require("md-viewer.mouse")
local interaction = require("md-viewer.interaction")

local M = {}
local group
local start_ui_poll

local function valid(session)
  return session
    and not session.closed
    and type(session.source_buf) == "number"
    and type(session.preview_buf) == "number"
    and type(session.preview_win) == "number"
    and vim.api.nvim_buf_is_valid(session.source_buf)
    and vim.api.nvim_buf_is_valid(session.preview_buf)
    and vim.api.nvim_win_is_valid(session.preview_win)
end

local function markdown(session) return table.concat(vim.api.nvim_buf_get_lines(session.source_buf, 0, -1, false), "\n") end

local function notify_error(message) vim.notify("md-viewer: " .. tostring(message), vim.log.levels.ERROR) end

local function current_session(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return state.get(buf)
    or state.from_preview(buf)
    or state.from_source_win(vim.api.nvim_get_current_win())
    or state.visible_in_tab()
end

---Remove the drag-selection overlay rectangles, if any are on screen. Cheap
---no-op otherwise. Every path that invalidates the overlay's geometry funnels
---through here: a new base frame (apply_image -- scroll, render, settle), the
---image leaving the screen (clear_image), a placement move under a passive
---float (reconcile_placement), and interaction.forget_selection.
local function clear_selection_overlay(session)
  local set = session.overlay_set
  if not set then return end
  session.overlay_set = nil
  session.overlay_rect_count = 0
  if session.backend and session.backend.overlay_clear then pcall(session.backend.overlay_clear, set) end
end

function M.clear_selection_overlay(session) clear_selection_overlay(session) end

local function clear_image(session)
  clear_selection_overlay(session)
  M.clear_caret_overlay(session)
  if session.image_id and session.backend then session.backend.clear(session.image_id) end
  session.image_id = nil
  session.last_placement = nil
end

---Must the image be off screen right now? Every path that shows, restores or
---re-places a backend image asks this first, so it is the one place that has
---to know every reason the image may not be displayed.
local function update_occlusion(session)
  if not valid(session) or session.backend.name == "cells" then return false end
  -- The preview window living on a *background* tabpage is one of those
  -- reasons, and nothing else here can detect it: `preview.occlusion` only
  -- ever looks at the preview's own tabpage, and `reconcile_placement` sees an
  -- unchanged placement because the geometry genuinely has not changed -- a
  -- hidden window keeps reporting its full on-screen rectangle (coordinates
  -- .window_is_displayed). Left unchecked, the raw image is re-shown at the
  -- hidden tabpage's coordinates on top of whatever the visible tabpage is
  -- drawing, which is what any plugin that opens its UI in its own tab
  -- (codediff.nvim's `:CodeDiff`, for one) triggers.
  local hidden = not coordinates.window_is_displayed(session.preview_win)
  session.tabpage_hidden = hidden
  if hidden then
    session.occluded = false
    session.occluding_windows = {}
    return true
  end
  local blocked, windows = preview.occlusion(session.preview_win)
  session.occluded = blocked
  session.occluding_windows = windows
  return blocked or session.ui_suppressed
end

---Deliver an image to the backend and record the placement/diagnostic
---bookkeeping that goes with it. The single choke point both `M.refresh`'s
---render/capture path and `display_interact_result`'s interact path funnel
---through, so there is exactly one place that knows how to show/update a
---backend image.
local function apply_image(session, image_bytes, capture_scale, png_bytes, capture_ms, capture_encoder)
  preview.stop_loading(session)
  preview.reset_surface(session)
  local placement = preview.placement(session.preview_win, session.backend.name)
  session.preview_width_cells = placement.width
  session.preview_height_cells = placement.height
  local image_started = vim.uv.hrtime()
  local ok, image_id, image_err = pcall(function()
    if session.image_id then return session.backend.update(session.image_id, image_bytes, placement) end
    return session.backend.show(image_bytes, placement)
  end)
  if not ok or not image_id then
    session.render_failed = true
    notify_error(ok and (image_err or "failed to display rendered image") or image_id)
    return false
  end
  session.last_image_update_ms = (vim.uv.hrtime() - image_started) / 1000000
  if png_bytes then session.last_png_bytes = png_bytes end
  if capture_ms then session.last_capture_ms = capture_ms end
  if capture_scale then session.last_capture_scale = capture_scale end
  -- Which of the renderer's two screenshot paths produced this frame. The fast
  -- one falls back silently and permanently on its first failure, so without
  -- this a browser that refused it would just look inexplicably slow.
  if capture_encoder then session.last_capture_encoder = capture_encoder end
  if capture_scale == "css" then
    session.fast_png_bytes = session.last_png_bytes
    session.fast_capture_ms = session.last_capture_ms
    session.fast_image_update_ms = session.last_image_update_ms
  elseif capture_scale == "device" then
    session.retina_png_bytes = session.last_png_bytes
    session.retina_capture_ms = session.last_capture_ms
    session.retina_image_update_ms = session.last_image_update_ms
  end
  session.image_id = image_id
  session.last_placement = placement
  -- Whether this frame has a browser-painted selection baked into it. Any
  -- capture taken while a DOM selection exists does, and `selection_active` is
  -- always updated before the frame is applied (interaction.lua sets it in the
  -- request callback, ahead of display).
  --
  -- The drag overlay composites *over* this frame, so it can only ever add a
  -- highlight -- never remove one. Starting a second gesture on top of a frame
  -- that still shows the first gesture's highlight leaves that highlight on
  -- screen for the whole drag, which is exactly what the operator reported on
  -- 2026-08-08. `M.restore_clean_base` is how a gesture gets out of it.
  session.base_selection_painted = session.selection_active == true
  -- The newest frame known to carry no browser-painted selection, kept so a
  -- drag starting on top of an earlier one can get a clean base back without a
  -- renderer round trip (see `M.restore_clean_base`).
  --
  -- Recorded here, at the one place every full frame passes through, rather
  -- than in `M.refresh` alone. A scroll taken while a selection was up used to
  -- drop this cache and nothing put it back: interact frames never reached
  -- `M.refresh`, so clicking to deselect -- which produces a perfectly good
  -- clean frame -- left the drag overlay disabled until some later render
  -- happened to land with nothing selected. `restore_clean_base` re-applies
  -- through here with `selection_active` still true, so it cannot overwrite
  -- the entry it is reading.
  if not session.base_selection_painted then
    session.clean_image_bytes = image_bytes
    session.clean_image_scroll_y = session.applied_scroll_y or 0
    session.clean_image_revision = session.renderer_revision
    session.clean_image_scale = capture_scale
  end
  -- Any full frame supersedes the drag overlay: a settle frame has the
  -- highlight baked in by the browser, and a scroll/render frame moves the
  -- geometry the overlay rectangles were computed against. Cleared *after*
  -- the new frame was placed, never before -- deleting first would blank the
  -- highlight for the gap between the two writes (the M.move hazard).
  clear_selection_overlay(session)
  -- Same rule for the caret, and then straight back: its rectangle was measured
  -- against the frame that has just been superseded, but the caret itself has
  -- not moved. Redrawing here is local (no round trip), so the caret survives
  -- every scroll and re-render without a flicker or a request.
  --
  -- `place_caret` rather than a bare redraw because this is also the moment a
  -- preview that was focused before it had ever rendered gets its first caret:
  -- there was nothing to place one on until now.
  M.clear_caret_overlay(session)
  M.place_caret(session)
  return true
end

---Put a selection-free frame back on screen so drag-overlay rectangles have a
---clean base to composite over, using the cached PNG rather than a renderer
---round trip -- this runs on the first frame of a drag and must not cost one.
---
---Returns false when there is no cached frame that is known to be both
---selection-free and taken at the scroll position now displayed, which is the
---honest answer whenever the page was scrolled while a selection was up. The
---caller falls back to captured frames for that gesture.
function M.restore_clean_base(session)
  if not session.base_selection_painted then return true end
  if not valid(session) or session.backend.name == "cells" then return false end
  if not session.clean_image_bytes then return false end
  if math.abs((session.clean_image_scroll_y or 0) - (session.applied_scroll_y or 0)) > 0.5 then return false end
  if session.clean_image_revision ~= session.renderer_revision then return false end
  -- `selection_active` is still true (the DOM selection this frame predates is
  -- what the new gesture is replacing), so apply_image would re-mark the base
  -- as painted. It is not: this frame is the cached selection-free one.
  if not apply_image(session, session.clean_image_bytes, session.clean_image_scale) then return false end
  session.base_selection_painted = false
  return true
end

---Display the drag-selection overlay a no-capture `selection_preview` result
---describes: translucent rectangles composited over the base image already on
---screen, in place of the full re-captured frame that used to carry every
---moving selection. The base image stays exactly what it was -- it remains
---authoritative for hit-testing and diagnostics; only backend overlay
---placements change.
---
---Refuses (returns false) whenever the result's geometry cannot be proven to
---match the frame on screen: wrong content revision, wrong scroll position,
---no base image, or a backend without overlay support. The caller falls back
---to the captured-frame path -- correct and slow beats fast and wrong.
function M.display_selection_overlay(session, result)
  if not valid(session) or session.backend.name == "cells" then return false end
  local backend = session.backend
  if not (backend.overlay_apply and backend.overlay_supported and backend.overlay_supported()) then return false end
  if not (session.image_id and session.last_placement) then return false end
  if type(result) ~= "table" or type(result.rects) ~= "table" then return false end
  if result.rectsTruncated then return false end
  if result.contentRevision ~= session.renderer_revision then return false end
  -- The rects were measured at the page scroll the renderer reports; the base
  -- image on screen shows `applied_scroll_y`. Any disagreement means the
  -- highlight would land on the wrong text.
  if type(result.scrollY) == "number" and math.abs(result.scrollY - (session.applied_scroll_y or 0)) > 0.5 then
    return false
  end
  if update_occlusion(session) then
    clear_image(session)
    session.refresh_deferred = true
    return false
  end
  local started = vim.uv.hrtime()
  local sheet_png = nil
  if type(result.overlaySheetPng) == "string" and result.overlaySheetPng ~= "" then
    local ok, decoded = pcall(vim.base64.decode, result.overlaySheetPng)
    if ok then sheet_png = decoded end
  end
  local ok, set_id, stats = pcall(
    backend.overlay_apply,
    session.overlay_set,
    session.image_id,
    result.rects,
    { widthPx = session.viewport_width_px, heightPx = session.viewport_height_render_px },
    result.selectionTint,
    sheet_png,
    session.last_placement
  )
  if not ok or not set_id then
    -- "need_sheet" is expected once per color (the next request asks for the
    -- sheet); anything else disables the overlay for this gesture upstream.
    session.overlay_last_error = ok and stats or tostring(set_id)
    return false, session.overlay_last_error
  end
  session.overlay_set = set_id
  session.overlay_rect_count = type(stats) == "table" and stats.rects or #result.rects
  session.overlay_frames = (session.overlay_frames or 0) + 1
  session.overlay_last_bytes = type(stats) == "table" and stats.bytes or nil
  session.overlay_last_ms = (vim.uv.hrtime() - started) / 1000000
  session.overlay_last_error = nil
  return true
end

---Draw the caret: one overlay rectangle, shaped like the glyph it sits on.
---
---The same `overlay_apply` the drag highlight uses, in its own rect set, so the
---two coexist without either having to know about the other -- a caret inside a
---selection is simply two sets of rectangles over one base image. It carries
---its own, heavier tint (`CARET_TINT` in the renderer): a selection is a wash
---over a span the reader is already looking at, a caret is one glyph they have
---to find.
---
---Local: no renderer round trip, so an ordinary scroll can re-place the caret
---without asking anyone where it went.
---
---Returns false when the caret cannot be drawn -- no overlay support (the
---backend, or the terminal profile), no base image, or the caret has scrolled
---out of view. The terminal's own cursor is left visible in exactly those
---cases; see `preview.hide_cursor`.
function M.display_caret_overlay(session, tint, sheet_png)
  if not valid(session) or session.backend.name == "cells" then return false end
  local backend = session.backend
  if not (backend.overlay_apply and backend.overlay_supported and backend.overlay_supported()) then return false end
  if not (session.image_id and session.last_placement) then return false end
  local rect = caret.rect(session)
  if not rect then
    M.clear_caret_overlay(session)
    -- No block on screen means Neovim's cursor is the only caret there is, so
    -- it has to come back. Restoring here rather than only on WinLeave is what
    -- covers a caret that scrolled out of view.
    preview.restore_cursor()
    return false
  end
  session.caret_tint = tint or session.caret_tint
  if not session.caret_tint then return false end
  local ok, set_id = pcall(
    backend.overlay_apply,
    session.caret_overlay_set,
    session.image_id,
    { rect },
    { widthPx = session.viewport_width_px, heightPx = session.viewport_height_render_px },
    session.caret_tint,
    sheet_png,
    session.last_placement
  )
  if not ok or not set_id then
    -- "need_sheet" is expected once per colour. The sheet is the renderer's to
    -- build, so the next motion asks for one by carrying the tint again; until
    -- then the caret is simply not drawn, which is honest rather than wrong.
    session.caret_overlay_error = ok and set_id or tostring(set_id)
    return false
  end
  session.caret_overlay_set = set_id
  session.caret_overlay_error = nil
  -- The block is on screen now, so Neovim's own cursor would be a second,
  -- differently-sized caret sitting somewhere else. Hidden here, at the one
  -- place that knows the block was actually drawn, rather than on a window
  -- event that has to guess -- guessing is what left both visible at once.
  if vim.api.nvim_get_current_win() == session.preview_win then preview.hide_cursor(session) end
  return true
end

---Make sure this preview has a caret, and that it is drawn.
---
---Cheap and idempotent: an existing caret is simply redrawn locally, and only
---the first call for a session costs the round trip that finds a character to
---put it on. Called from every path that can make a caret visible -- focusing
---the preview, and the first frame landing in an already-focused one.
function M.place_caret(session)
  if not valid(session) or session.backend.name == "cells" then return end
  if not config.get().interaction.enabled then return end
  -- Only for the preview the reader is actually in. A caret in an unfocused
  -- preview is one nobody can see, and placing it costs a round trip -- which
  -- an unrendered document answers with an error, and a failed interact
  -- restarts the renderer, whose exit hook drops selection and find state on
  -- every open session.
  if vim.api.nvim_get_current_win() ~= session.preview_win then return end
  if session.caret_rect then
    M.display_caret_overlay(session)
    return
  end
  if not (session.renderer_revision and session.last_placement) then return end
  interaction.caret_motion(session, "none", "forward", 1)
end

function M.clear_caret_overlay(session)
  local set = session and session.caret_overlay_set
  if not set then return end
  session.caret_overlay_set = nil
  if session.backend and session.backend.overlay_clear then pcall(session.backend.overlay_clear, set) end
end

---Display the PNG an interact response captured (every mutating selection/find
---action always captures one, in the same queued operation the mutation
---itself ran in -- see renderer/src/interact.js's `mutatesVisibleState`).
---Interact requests bypass `renderer.lua`'s request/response envelope
---entirely (`interaction.lua` calls `process.request("interact", ...)`
---directly, exactly as `request_hit` already did before this part), so this
---is the fetch half `M.refresh`'s render/capture path gets from
---`renderer.lua`; the display half is `apply_image`, shared verbatim.
function M.display_interact_result(session, result)
  if not valid(session) or session.backend.name == "cells" then return end
  if type(result) ~= "table" or type(result.pngPath) ~= "string" then return end
  local cfg = config.get().render
  local image, read_err = renderer.read_png(result.pngPath, cfg.max_png_bytes)
  vim.uv.fs_unlink(result.pngPath)
  if not image then
    notify_error(read_err)
    return
  end
  -- A find step and a fragment link both scroll the shared page inside the
  -- interact call and report where they landed. Not recording it left
  -- `applied_scroll_y` describing the position *before* the jump, so the next
  -- interact sent that stale value and `ensureDocumentActive` scrolled the page
  -- back before hit-testing -- a click after a search resolved against a
  -- different position than the image on screen showed.
  if type(result.scrollY) == "number" then
    session.applied_scroll_y = result.scrollY
    session.scroll_y = result.scrollY
  end
  if update_occlusion(session) then
    clear_image(session)
    -- The interact PNG is discarded rather than displayed off screen, and
    -- unlike a render frame it never reaches session.last_image_bytes, so the
    -- cache cannot show this selection/find state. Re-render on restore.
    session.refresh_deferred = true
    return
  end
  apply_image(session, image, result.captureScale, result.pngBytes, result.captureMs, result.captureEncoder)
end

local function show_cached(session)
  if not valid(session) or session.backend.name == "cells" or not session.last_image_bytes then return false end
  if update_occlusion(session) then
    clear_image(session)
    return false
  end
  preview.stop_loading(session)
  preview.reset_surface(session)
  local placement = preview.placement(session.preview_win, session.backend.name)
  local ok, image_id, image_err = pcall(session.backend.show, session.last_image_bytes, placement)
  if not ok or not image_id then
    session.render_failed = true
    notify_error(ok and (image_err or "failed to display cached image") or image_id)
    return false
  end
  session.image_id = image_id
  session.last_placement = placement
  -- A render that was dropped while the image could not be displayed left the
  -- cached PNG a frame behind the source. Now that it can be displayed again,
  -- catch up rather than leaving the restored frame stale indefinitely --
  -- otherwise a debounced render landing just after `:CodeDiff` (or just after
  -- a focusable float opened over the preview) is silently lost.
  if session.refresh_deferred then
    session.refresh_deferred = false
    M.schedule(session, 0)
  end
  return true
end

function M.refresh(session, render_options)
  local explicit = session == nil
  session = session or current_session()
  if not valid(session) then return end
  if explicit then session.render_epoch = (session.render_epoch or 0) + 1 end
  if session.backend.name == "cells" then
    session.backend.render(session.preview_buf, markdown(session))
    if render_options and render_options.on_complete then render_options.on_complete(false, nil) end
    return
  end
  session.render_failed = false
  if update_occlusion(session) then
    clear_image(session)
    -- Nothing was captured, so the cached PNG stays a frame behind whatever
    -- triggered this refresh. show_cached() replays it once the image can be
    -- displayed again.
    session.refresh_deferred = true
    if render_options and render_options.on_complete then render_options.on_complete(false, nil) end
    return
  end
  renderer.request(session, markdown(session), render_options, function(result, err, stale)
    local function finish()
      if render_options and render_options.on_complete then render_options.on_complete(stale, err) end
    end
    if not valid(session) then
      finish()
      return
    end
    if stale then
      finish()
      return
    end
    if err then
      session.render_failed = true
      preview.stop_loading(session)
      notify_error(err)
      finish()
      return
    end
    local meta = result.metadata
    -- A selection captured against older content must never be displayed or
    -- reused against newer content -- that would be silent corruption in a
    -- copy operation. renderer.lua has already updated session.renderer_revision
    -- by this point, so this is the first tick new content can be observed on.
    if session.selection_content_revision and session.selection_content_revision ~= session.renderer_revision then
      interaction.forget_selection(session)
    end
    local newer_scroll_pending = render_options and render_options.scroll_frame and session.scroll_render_pending
    session.latest_blocks = meta.blocks
    session.document_height_px = meta.documentHeightPx
    session.viewport_height_px = meta.viewportHeightPx
    -- Preserve a newer requested position while showing this completed frame.
    -- The next capture then uses the desired position instead of snapping back
    -- to the older frame's scrollY.
    if not newer_scroll_pending then session.scroll_y = meta.scrollY end
    session.applied_scroll_y = meta.scrollY
    session.last_layout_reused = meta.layoutReused == true
    session.last_markdown_reused = meta.markdownReused == true
    session.last_capture_scale = meta.captureScale
    session.last_png_bytes = meta.pngBytes or #result.image
    session.last_layout_ms = meta.layoutMs
    session.last_capture_ms = meta.captureMs
    session.viewport_width_px = result.viewport.widthPx
    session.viewport_height_render_px = result.viewport.heightPx
    session.viewport_calibration_tier = result.viewport.tier
    session.last_image_bytes = result.image
    -- A capture taken while a DOM selection was live has it painted in, so the
    -- cached clean base cannot be this frame. `apply_image` records the
    -- replacement whenever a selection-free frame does reach the screen.
    if session.selection_active then session.clean_image_bytes = nil end
    if update_occlusion(session) then
      clear_image(session)
      finish()
      return
    end
    if
      not apply_image(
        session,
        result.image,
        meta.captureScale,
        session.last_png_bytes,
        session.last_capture_ms,
        meta.captureEncoder
      )
    then
      finish()
      return
    end
    finish()
  end)
end

function M.schedule(session, delay, timer_name, render_options)
  if not valid(session) then return end
  debounce.call(session, timer_name or "render_timer", delay or config.get().render.debounce_ms, function()
    if valid(session) then M.refresh(session, render_options) end
  end)
end

function M.schedule_scroll(session)
  local render = config.get().render
  local fast_scale = render.fast_scroll and "css" or "device"
  if session.scroll_render_in_flight then
    session.scroll_render_pending = true
    session.coalesced_scroll_events = (session.coalesced_scroll_events or 0) + 1
  else
    session.scroll_render_in_flight = true
    M.refresh(session, {
      capture_scale = fast_scale,
      capture_only = true,
      scroll_frame = true,
      on_complete = function()
        session.scroll_render_in_flight = false
        if not valid(session) then return end
        if session.scroll_render_pending then
          session.scroll_render_pending = false
          -- One capture at a time is sufficient backpressure. Continue with
          -- the newest position on the next event-loop turn; capture and
          -- terminal transmission provide the natural pacing.
          vim.schedule(function()
            if valid(session) then M.schedule_scroll(session) end
          end)
        end
      end,
    })
  end
  if render.fast_scroll then
    M.schedule(session, render.scroll_settle_ms, "scroll_settle_timer", {
      capture_scale = "device",
      capture_only = true,
    })
  end
end

local function schedule_source_scroll(session, delay)
  debounce.call(session, "cursor_scroll_timer", delay, function()
    if valid(session) then M.schedule_scroll(session) end
  end)
end

local function close_session(session)
  if not session or session.closed then return end
  session.closed = true
  session.request_serial = session.request_serial + 1
  for _, name in ipairs({
    "render_timer",
    "resize_timer",
    "scroll_settle_timer",
    "cursor_scroll_timer",
    "ui_poll_timer",
    "selection_debounce_timer",
    "selection_settle_timer",
    "drag_idle_settle_timer",
    "drag_autoscroll_timer",
  }) do
    debounce.close(session, name)
  end
  preview.stop_loading(session)
  preview.restore_cursor()
  caret.forget(session)
  clear_image(session)
  session.last_image_bytes = nil
  session.clean_image_bytes = nil
  state.remove(session.source_buf)
  if session.preview_win and vim.api.nvim_win_is_valid(session.preview_win) then
    pcall(vim.api.nvim_win_close, session.preview_win, true)
  end
  if not next(state.all()) then process.stop() end
  interaction.forget(session)
  interaction.forget_selection(session)
  mouse.detach_if_unused()
end

function M.close(buf)
  local session = current_session(buf)
  close_session(session)
end

function M.close_all()
  local copy = {}
  for _, session in pairs(state.all()) do
    copy[#copy + 1] = session
  end
  for _, session in ipairs(copy) do
    close_session(session)
  end
  for _, name in ipairs({ "nvim_img", "kitty_raw" }) do
    backends.get(name).clear_all()
  end
  process.stop()
end

function M.open(position)
  local source_buf, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local existing = state.get(source_buf)
  if existing and valid(existing) then return existing end
  local pinned = state.from_source_win(source_win)
  if pinned and valid(pinned) then return pinned end
  if vim.bo[source_buf].buftype ~= "" then
    notify_error("open a normal Markdown buffer first")
    return
  end
  local backend, reason = backends.select()
  if not backend then
    notify_error(reason)
    return
  end
  local session = state.create(source_buf, source_win)
  M.history_init(session)
  session.backend, session.backend_reason = backend, reason
  session.preview_buf, session.preview_win = preview.open(position, session)
  -- Size the caret surface now that the split has been created and resized;
  -- `preview.open` cannot do it itself, since the placement it measures needs
  -- the window handle this line is what assigns.
  preview.reset_surface(session)
  if backend.name ~= "cells" then
    preview.start_loading(session)
    navigation.attach(session, M.navigate)
    mouse.attach(M.navigate)
  end
  vim.api.nvim_set_current_win(source_win)
  M.refresh(session)
  if start_ui_poll then start_ui_poll(session) end
  return session
end

---Point an existing preview at a different source buffer, reusing its window.
---Used when a local link is activated: the source window edits the new file and
---the preview follows it, which `close_session` + `M.open` would also achieve
---but with a visible split teardown and rebuild in between.
---
---Everything below is per-document and must not survive the move. The serial
---bump is what makes that safe: any render or interact response still in flight
---for the old document fails `renderer.is_stale` and is discarded rather than
---being applied to the new one.
---
---`record` (default true) appends the destination to this preview's history.
---The back/forward commands pass false: they are *moving through* the history,
---not extending it, and appending there would make "back" unable to ever leave
---the last two documents.
function M.retarget(session, new_buf, record)
  if not valid(session) or not session.backend or session.backend.name == "cells" then return false end
  if not state.retarget(session, new_buf) then return false end
  session.request_serial = session.request_serial + 1
  session.render_epoch = (session.render_epoch or 0) + 1
  interaction.forget(session)
  interaction.forget_selection(session)
  session.renderer_revision = nil
  session.latest_blocks = {}
  session.document_height_px = 0
  session.scroll_y, session.applied_scroll_y = 0, 0
  session.last_source_block = nil
  session.last_image_bytes = nil
  session.clean_image_bytes = nil
  session.manual_scroll_until = 0
  session.refresh_deferred = false
  if record ~= false then M.history_push(session, new_buf) end
  preview.update_title(session)
  M.refresh(session)
  return true
end

-- ---------------------------------------------------------------------------
-- Preview history.
--
-- Following a link retargets the preview, and without this the document it came
-- from is simply gone: the source window's jump list can bring the *text* back
-- (`edit_in_source_window` pushes it), but `preview.pinned` deliberately stops
-- the preview from following an ordinary buffer switch, so the rendered view
-- stays on the document the reader has already left.
--
-- The list is per session and holds a buffer *and* the file path. The buffer is
-- what makes returning cheap and exact; the path is the fallback for an entry
-- whose buffer has since been wiped, which is the ordinary outcome of
-- `:bwipeout` or a session that has been open a long time.
-- ---------------------------------------------------------------------------

local function history_entry(buf)
  local name = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ""
  return { buf = buf, path = name ~= "" and vim.fs.normalize(name) or nil }
end

function M.history_init(session)
  session.history = { history_entry(session.source_buf) }
  session.history_index = 1
end

---Append `buf` as the newest entry, discarding anything ahead of the current
---position -- the same rule a browser follows: navigating from a point in the
---middle of the history abandons the forward branch rather than interleaving
---with it.
function M.history_push(session, buf)
  if not session.history then M.history_init(session) end
  local history = session.history
  for index = #history, session.history_index + 1, -1 do
    history[index] = nil
  end
  -- Re-entering the document that is already current is not a new entry:
  -- otherwise a fragment link, or a link back to where the reader just came
  -- from, would grow the list without adding anywhere to go.
  if history[session.history_index] and history[session.history_index].buf == buf then return end
  history[#history + 1] = history_entry(buf)
  local limit = config.get().interaction.history_limit
  while #history > limit do
    table.remove(history, 1)
  end
  session.history_index = #history
end

---Resolve a history entry to a buffer that can actually be displayed, reopening
---the file when the buffer it recorded is gone. Returns nil when neither is
---available any more, which is a dead entry rather than an error.
local function history_buf(entry)
  if entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then return entry.buf end
  if not entry.path or not vim.uv.fs_stat(entry.path) then return nil end
  local buf = vim.fn.bufadd(entry.path)
  if buf == 0 then return nil end
  vim.fn.bufload(buf)
  entry.buf = buf
  return buf
end

---Move the preview (and the source window with it) `step` entries through the
---history. Dead entries are stepped over rather than reported: a wiped buffer
---whose file is also gone is not something the reader can act on.
local function history_go(session, step, direction)
  if not valid(session) or session.backend.name == "cells" then return false end
  if not session.history then M.history_init(session) end
  local index = session.history_index
  while true do
    index = index + step
    local entry = session.history[index]
    if not entry then
      vim.notify(("md-viewer: no %s document in the preview history"):format(direction), vim.log.levels.INFO)
      return false
    end
    local buf = history_buf(entry)
    if buf then
      if buf == session.source_buf then
        session.history_index = index
        return true
      end
      -- The source window follows, for the same reason activating a link moves
      -- it: the preview and the text below the cursor describing the same
      -- document is the whole point of the split.
      local win = session.source_win
      if win and vim.api.nvim_win_is_valid(win) then
        local ok, err = pcall(vim.api.nvim_win_call, win, function()
          vim.cmd("normal! m'")
          vim.api.nvim_win_set_buf(win, buf)
        end)
        if not ok then
          notify_error(err)
          return false
        end
      end
      if not M.retarget(session, buf, false) then
        -- The only way this refuses is another preview already owning that
        -- document. The source window has moved by now, so saying nothing
        -- would leave the two panes describing different files with no
        -- explanation.
        vim.notify("md-viewer: another preview already owns that document", vim.log.levels.WARN)
        return false
      end
      session.history_index = index
      return true
    end
  end
end

---`session` is passed explicitly by the preview-local `H`/`L` mappings, which
---already know which preview they belong to, and omitted by the commands,
---which resolve it the same way every other :MdViewer* command does.
function M.history_back(session)
  session = session or current_session()
  if not valid(session) then
    vim.notify("md-viewer: no preview open", vim.log.levels.WARN)
    return
  end
  history_go(session, -1, "previous")
end

function M.history_forward(session)
  session = session or current_session()
  if not valid(session) then
    vim.notify("md-viewer: no preview open", vim.log.levels.WARN)
    return
  end
  history_go(session, 1, "next")
end

---Re-point the preview when the source window returns, by any means, to a
---document already in this preview's history -- `<C-o>` after a link click
---being the case that matters. `preview.pinned` stops the preview following
---arbitrary buffer switches, and that stays true: only a document the preview
---itself navigated through is followed, and the move never appends, so the
---forward branch survives to be walked back up.
local function follow_history_buffer(session, buf)
  if not session.history or buf == session.source_buf then return end
  -- One document can legitimately appear at more than one position (a link
  -- back to where the reader came from puts it there twice), so search outward
  -- from where the preview currently is rather than from the start -- landing
  -- at the far end of the list would make the next `<C-o>` jump somewhere the
  -- reader has never been. Backwards wins a tie, because the gesture this
  -- exists for is the backwards one.
  local history = session.history
  for distance = 0, #history do
    for _, index in ipairs({ session.history_index - distance, session.history_index + distance }) do
      if history[index] and history[index].buf == buf then
        if M.retarget(session, buf, false) then session.history_index = index end
        return
      end
    end
  end
end

function M.toggle(position)
  local session = current_session()
  if session then
    close_session(session)
  else
    M.open(position)
  end
end

---The furthest the document can be scrolled: everything below scrolls within
---this, and nothing scrolls past it.
local function scroll_maximum(session)
  return math.max(0, (session.document_height_px or 0) - (session.viewport_height_px or 0))
end

---Move the preview to an absolute document position and schedule the frame that
---shows it. The shared tail of every deliberate scroll -- keyboard motions, a
---caret motion that ran off the edge of the surface, the wheel -- so the clamp,
---the manual-scroll hold and the source-sync opt-in are stated once.
---Returns whether the position actually changed.
function M.scroll_to(session, next_scroll)
  if not valid(session) or session.backend.name == "cells" then return false end
  local cfg = config.get()
  next_scroll = math.max(0, math.min(scroll_maximum(session), next_scroll))
  if math.abs(next_scroll - (session.scroll_y or 0)) < 1 then return false end
  session.scroll_y = next_scroll
  session.manual_scroll_until = vim.uv.now() + cfg.sync.manual_scroll_hold_ms
  if cfg.sync.preview_to_source then sync.update_source_from_scroll(session, next_scroll) end
  M.schedule_scroll(session)
  return true
end

function M.scroll_by(session, delta_px)
  if not valid(session) or session.backend.name == "cells" then return false end
  return M.scroll_to(session, (session.scroll_y or 0) + delta_px)
end

function M.navigate(session, action, count)
  if not valid(session) or session.backend.name == "cells" then return end
  local cfg = config.get()
  count = math.max(1, math.floor(count or 1))
  local maximum = scroll_maximum(session)
  local deltas = {
    line_down = cfg.sync.navigation_line_px,
    line_up = -cfg.sync.navigation_line_px,
    half_down = session.viewport_height_px * 0.5,
    half_up = -session.viewport_height_px * 0.5,
    page_down = session.viewport_height_px * 0.9,
    page_up = -session.viewport_height_px * 0.9,
    wheel_down = cfg.sync.navigation_line_px * cfg.sync.mouse_scroll_lines,
    wheel_up = -cfg.sync.navigation_line_px * cfg.sync.mouse_scroll_lines,
  }
  if action == "top" then return M.scroll_to(session, 0) end
  if action == "bottom" then return M.scroll_to(session, maximum) end
  return M.scroll_by(session, (deltas[action] or 0) * count)
end

local function each_session(fn)
  for _, session in pairs(state.all()) do
    if valid(session) then fn(session) end
  end
end

local function clear_raw_sessions()
  each_session(function(session)
    if session.backend.name == "kitty_raw" then clear_image(session) end
  end)
end

local function refresh_raw_sessions()
  each_session(function(session)
    if session.backend.name == "kitty_raw" and not session.ui_suppressed then
      if not show_cached(session) and not update_occlusion(session) then M.schedule(session, 0) end
    end
  end)
end

---A placement change the terminal has to be told about -- `coordinates.same`,
---so `exclusions` count, not just row/col/width/height.
---
---Exclusions have to count because of what `raw_zindex = -1` actually means:
---in the Kitty graphics protocol a negative z above INT32_MIN/2 draws the image
---below text glyphs but *above* cell background colors (see
---docs/architecture.md). A passive float therefore does not occlude the image
---on its own -- only its glyphs and border characters survive, and the image
---keeps compositing across everything else, so a notification renders with the
---Markdown showing through its background instead of its own. Cutting the
---float's rectangle out of the placement is the only thing that gives it back
---an opaque interior, and the cut has to actually reach the terminal.
---
---This comparison used to ignore `exclusions` on purpose, because re-cropping
---on every appearing and disappearing notification was visible as the image
---blinking and rolling by about a row. That was `kitty_raw.move` deleting the
---old placements before sending the new ones; it now emits both in one write,
---new first, so the re-crop is no longer visible as anything.
local function reconcile_placement(session, force)
  if session.backend.name ~= "kitty_raw" or not session.image_id or session.ui_suppressed then return end
  -- Never address the terminal on behalf of a window that is not on screen:
  -- its reported geometry is a hidden tabpage's, so any placement built from
  -- it lands on top of the tabpage the user is actually looking at. The
  -- unconditional `force` callers (CmdlineEnter/CmdlineLeave) reach here
  -- without an occlusion check of their own.
  if not coordinates.window_is_displayed(session.preview_win) then return end
  local placement = preview.placement(session.preview_win, session.backend.name)
  if force or not coordinates.same(session.last_placement, placement) then
    local ok, moved, err = pcall(session.backend.move, session.image_id, placement)
    if not ok then
      notify_error(moved)
      return
    end
    if not moved then
      notify_error(err or "failed to update image placement")
      return
    end
    -- The base just moved or re-cropped (a float opened or closed over it);
    -- overlay rectangles computed against the old placement are wrong now.
    -- Cleared after the move rather than re-derived: the next drag frame
    -- repaints them against the new placement within one round trip.
    clear_selection_overlay(session)
  end
  -- Always refresh, even when no move() happened: exclusions (or any other
  -- field) may have changed and click-resolution reads this on every click.
  session.last_placement = placement
  -- The caret surface is sized from the placement, so it has to follow it here
  -- too. A re-render would resize it via `apply_image`, but the callers that
  -- reach this without one -- a float opening, `cmdheight = 0` shrinking the
  -- window around the command line -- would otherwise leave the caret able to
  -- sit on a row the image no longer covers, which resolves to nothing.
  preview.reset_surface(session)
end

local function reconcile_occlusion()
  each_session(function(session)
    if session.backend.name ~= "cells" then
      if update_occlusion(session) then
        clear_image(session)
      elseif not session.image_id then
        if not show_cached(session) then M.schedule(session, 0) end
      else
        reconcile_placement(session)
      end
    end
  end)
end

start_ui_poll = function(session)
  if session.backend.name ~= "kitty_raw" then return end
  local interval = math.max(0, math.floor(config.get().image.ui_poll_ms or 50))
  if interval == 0 or session.ui_poll_timer then return end
  local timer = vim.uv.new_timer()
  session.ui_poll_timer = timer
  timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      if valid(session) then
        if update_occlusion(session) then
          clear_image(session)
        elseif
          not session.image_id
          and not session.ui_suppressed
          and not session.loading
          and not session.render_failed
        then
          if not show_cached(session) then M.schedule(session, 0) end
        else
          reconcile_placement(session)
        end
      else
        debounce.close(session, "ui_poll_timer")
      end
    end)
  )
end

---Copy the current preview selection to the unnamed register (and `+` when
---available). No-ops with a clean notification, never an error, when no
---preview is open or nothing is selected -- see interaction.copy_selection for
---the latter case.
function M.copy()
  local session = current_session()
  if not valid(session) then
    vim.notify("md-viewer: no preview open", vim.log.levels.WARN)
    return
  end
  interaction.copy_selection(session, false)
end

function M.clear_selection()
  local session = current_session()
  if not valid(session) then
    vim.notify("md-viewer: no preview open", vim.log.levels.WARN)
    return
  end
  interaction.clear_selection(session)
end

function M.find(query)
  local session = current_session()
  if not valid(session) then
    vim.notify("md-viewer: no preview open", vim.log.levels.WARN)
    return
  end
  interaction.find_set(session, query)
end

function M.find_next()
  local session = current_session()
  if not valid(session) then
    vim.notify("md-viewer: no preview open", vim.log.levels.WARN)
    return
  end
  interaction.find_next(session)
end

function M.find_previous()
  local session = current_session()
  if not valid(session) then
    vim.notify("md-viewer: no preview open", vim.log.levels.WARN)
    return
  end
  interaction.find_previous(session)
end

function M.find_clear()
  local session = current_session()
  if not valid(session) then
    vim.notify("md-viewer: no preview open", vim.log.levels.WARN)
    return
  end
  interaction.find_clear(session)
end

---Open the find prompt for `session`, or for the current preview.
---
---The prompt always opens empty; the previous query is never prefilled, so
---every search starts from nothing rather than from whatever was typed last.
---Dismissing it without a query -- Escape, or an empty line -- clears both the
---active search and any selection.
---
---That dismissal is deliberately the clearing gesture. `:MdViewerFindClear` and
---`:MdViewerClearSelection` existed to do exactly these two things and nothing
---else, which is two commands to remember for something the search prompt can
---express by being closed. `<Esc>` in the preview window still clears the same
---two, one press at a time, via interaction.escape().
---
---Both clears are guarded on the session actually having that state, so
---dismissing an empty prompt with nothing active costs no round trip.
function M.find_prompt(session)
  session = session or current_session()
  if not valid(session) then
    vim.notify("md-viewer: no preview open", vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = "md-viewer find: " }, function(input)
    if not valid(session) then return end
    if input and input ~= "" then
      interaction.find_set(session, input)
      return
    end
    if session.find_active then interaction.find_clear(session) end
    if session.selection_active then interaction.clear_selection(session) end
  end)
end

function M.setup_autocmds()
  -- Session-level selection/find display state is not tied to any specific
  -- in-flight request (unlike process.lua's own deliver_error, which already
  -- handles those correctly), so it needs its own hook: the renderer's
  -- in-memory interactionState does not survive a restart, and without this
  -- the cached Lua-side flags describing it would go stale silently.
  process.on_exit(function()
    each_session(function(session) interaction.forget_selection(session) end)
  end)
  group = vim.api.nvim_create_augroup("md-viewer", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    callback = function(args)
      local session = state.get(args.buf)
      if session then M.schedule(session) end
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(args)
      -- Nothing to do for the preview's own buffer: the caret is a position in
      -- the rendered document, not Neovim's cursor, so it moves through
      -- `interaction.caret_motion` and never through a cursor event. Neovim's
      -- cursor only shadows it.
      if state.from_preview(args.buf) then return end
      local session = state.get(args.buf)
      if session and config.get().sync.source_to_preview and config.get().sync.cursor_follow then
        local cfg = config.get().sync
        sync.source_cursor(
          session,
          function(value) schedule_source_scroll(value, cfg.cursor_debounce_ms) end,
          cfg.alignment_tolerance
        )
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function(args)
      local scrolled_win = tonumber(args.match)
      each_session(function(session)
        -- Compared against the window the source *buffer* is in, not against
        -- `session.source_win` directly: a window keeps its id when its buffer
        -- changes, so scrolling SECURITY.md after opening it in the window a
        -- README.md preview was started from satisfied this test and scrolled
        -- README's preview. The nil check is not decoration -- an unresolvable
        -- source window and a non-numeric `args.match` would otherwise compare
        -- equal and match every scroll in the editor.
        local source_win = state.source_window(session)
        if source_win and scrolled_win == source_win and config.get().sync.source_to_preview then
          local cfg = config.get().sync
          sync.source_cursor(
            session,
            function(value) schedule_source_scroll(value, cfg.cursor_debounce_ms) end,
            cfg.alignment_tolerance
          )
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      -- A terminal font-size change moves the pixel cell without changing
      -- anything Neovim reports except the grid. `cellpixels` no longer caches
      -- at all for exactly that reason, so this is now a formality; it stays
      -- because a resize is genuinely the moment the cell can move.
      cellpixels.invalidate()
      each_session(function(session)
        if not update_occlusion(session) then M.schedule(session, 80, "resize_timer") end
      end)
      vim.schedule(reconcile_occlusion)
    end,
  })
  -- FocusGained covers the terminal-side transitions Neovim has no direct
  -- event for (alternate-screen returns, multiplexer pane/window switches):
  -- any of them can silently drop a raw Kitty placement, so treat regained
  -- focus the same as VimResume and recreate it from the cached PNG.
  vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter", "TabEnter", "VimResume", "FocusGained" }, {
    group = group,
    callback = function(args)
      -- Deferred rather than read synchronously off `args`: a compound
      -- command like `:split other.md` fires `WinEnter` for the *new*
      -- window while it still, transiently, shows the window it split
      -- from's buffer -- the buffer swap to `other.md` (and that file's own
      -- `BufEnter`) happens a moment later, in the same command. Reading
      -- `nvim_get_current_buf()` synchronously here reassigns
      -- `session.source_win` to that new window on the strength of a buffer
      -- pairing that is already gone by the time the command finishes,
      -- stranding cursor-follow (WinScrolled below compares against
      -- `source_win` by identity) on a window that no longer shows the
      -- source buffer, with nothing left to correct it since the *real*
      -- source window was never touched. Deferring to the next tick lets
      -- the whole command settle first, so this only ever fires once the
      -- window/buffer pairing is the one the user actually ended up with.
      local buf = args.buf
      vim.schedule(function()
        local source_session = state.get(buf)
        if source_session and vim.api.nvim_get_current_buf() == buf then
          source_session.source_win = vim.api.nvim_get_current_win()
        end
        -- The source window arriving back at a document this preview has
        -- already shown (`<C-o>` after following a link) takes the preview
        -- with it. Deliberately narrow: only buffers in this session's own
        -- history qualify, so `preview.pinned` still holds for every other
        -- buffer switch.
        if source_session then return end
        local win_session = state.from_source_win(vim.api.nvim_get_current_win())
        if win_session and valid(win_session) and vim.api.nvim_get_current_buf() == buf then
          follow_history_buffer(win_session, buf)
        end
      end)
      each_session(function(session)
        if
          not session.image_id
          and not session.ui_suppressed
          and not update_occlusion(session)
          and vim.api.nvim_win_get_tabpage(session.preview_win) == vim.api.nvim_get_current_tabpage()
        then
          if not show_cached(session) then M.schedule(session, 0) end
        end
      end)
    end,
  })
  -- Neovim's cursor is hidden only while a preview with a drawable overlay
  -- caret is focused, so these two autocmds own the whole of that state. Restore
  -- is unconditional and idempotent: leaving a reader with an invisible cursor
  -- is far worse than restoring one that was never hidden.
  --
  -- `FocusGained` is here because `FocusLost` restores the cursor without any
  -- window changing, so nothing fires `WinEnter` on the way back: leaving the
  -- terminal and returning to it left Neovim's own cursor sitting beside the
  -- overlay caret until some later motion happened to redraw it.
  --
  -- `VimSuspend`, the other event that restores without a window change, needs
  -- no counterpart here: it drops the image outright (below), and the resume
  -- that puts one back goes through display_image, which calls place_caret
  -- itself once there is something to draw the caret over.
  vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter", "FocusGained" }, {
    group = group,
    callback = function()
      local session = state.from_preview_win(vim.api.nvim_get_current_win())
      if not (session and valid(session)) then
        preview.restore_cursor()
        return
      end
      -- Focusing a preview is when a caret first becomes something the reader
      -- can see, so this is where one gets placed. Snapping with no motion puts
      -- it on the first character of whatever is on screen; drawing it is what
      -- then hides Neovim's own cursor, so the two can never both be up.
      M.place_caret(session)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave", "TabLeave", "VimSuspend", "VimLeavePre", "FocusLost" }, {
    group = group,
    callback = function() preview.restore_cursor() end,
  })
  vim.api.nvim_create_autocmd("BufFilePost", {
    group = group,
    callback = function(args)
      local session = state.get(args.buf)
      if session then preview.update_title(session) end
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      -- Placement is screen-relative and must not depend on the active cursor.
      -- Intentionally retain normal split images across focus changes.
    end,
  })
  vim.api.nvim_create_autocmd({ "CompleteChanged" }, {
    group = group,
    callback = function()
      each_session(function(session)
        if session.backend.name == "kitty_raw" then session.ui_suppressed = true end
      end)
      clear_raw_sessions()
    end,
  })
  vim.api.nvim_create_autocmd({ "CompleteDone", "WinClosed" }, {
    group = group,
    callback = function(args)
      if args.event ~= "WinClosed" then
        each_session(function(session)
          if session.backend.name == "kitty_raw" then session.ui_suppressed = false end
        end)
      end
      vim.schedule(function()
        if args.event == "WinClosed" then
          reconcile_occlusion()
        else
          refresh_raw_sessions()
        end
      end)
    end,
  })
  -- The command-line reserves its own screen row(s) below every window, so
  -- unlike a real floating window it can never geometrically overlap the
  -- preview under normal Neovim layout. The one exception is `cmdheight = 0`,
  -- which temporarily shrinks the window above the command line for as long
  -- as it's open. Rather than hide the image for the whole time (blanking it
  -- on every `:`, `/`, or `?`), just re-place it at the placement's current
  -- geometry -- a no-op send when nothing changed, and a same-tick resize
  -- when it did, so the image stays visible and confined instead of
  -- disappearing. `force = true` bypasses the usual same-placement skip so a
  -- terminal that erases graphics on its own cmdline redraw gets them
  -- redrawn immediately rather than waiting for the next unrelated event.
  vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineLeave" }, {
    group = group,
    callback = function()
      each_session(function(session) reconcile_placement(session, true) end)
    end,
  })
  -- Any new window can legitimately resize/reposition an existing preview
  -- split -- not only a floating one. WinResized/VimResized (below) is the
  -- other, more usual way that gets caught, but a plugin that opens several
  -- plain splits "relative to editor" (codediff.nvim's diff/explorer panes,
  -- for one -- see the operator report this fixed) can shrink/move the
  -- preview window as an immediate side effect of WinNew itself, before a
  -- separate WinResized round-trip; reconciling here too closes that gap
  -- rather than depending on the 50ms ui_poll_timer to eventually catch up.
  vim.api.nvim_create_autocmd("WinNew", {
    group = group,
    callback = function() vim.schedule(reconcile_occlusion) end,
  })
  vim.api.nvim_create_autocmd({ "ColorScheme" }, {
    group = group,
    callback = function()
      each_session(function(session) M.schedule(session, 0) end)
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "background",
    callback = function()
      each_session(function(session) M.schedule(session, 0) end)
    end,
  })
  -- 'laststatus' decides whether the raw Kitty backend gives a statusline guard
  -- row back (coordinates.for_window, preview.placement), so it changes the
  -- caret surface's height with no resize event of any kind to announce it --
  -- and under `laststatus = 1` it does so whenever the tabpage's window count
  -- crosses one, which is not a change to the preview window at all.
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "laststatus",
    callback = function()
      each_session(function(session) preview.reset_surface(session) end)
    end,
  })
  vim.api.nvim_create_autocmd("BufHidden", {
    group = group,
    callback = function(args)
      local session = state.from_preview(args.buf)
      if not session and not config.get().preview.pinned then session = state.get(args.buf) end
      if session then close_session(session) end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      local session = state.get(args.buf) or state.from_preview(args.buf)
      if session then close_session(session) end
    end,
  })
  vim.api.nvim_create_autocmd({ "TabLeave", "VimSuspend" }, {
    group = group,
    callback = function()
      each_session(function(session)
        -- clear_image() rather than a hand-rolled clear: the placement this
        -- drops must go with the image, since interaction.locate resolves
        -- clicks against session.last_placement and there is no longer an
        -- image on screen for one to land on.
        clear_image(session)
        -- The preview survives a tab leave or suspend, but a mouse press
        -- captured against it does not: there is no guarantee the matching
        -- release ever reaches Neovim across that boundary.
        interaction.forget(session)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.close_all })
end

return M
