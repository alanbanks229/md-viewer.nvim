local backends = require("md-viewer.backends")
local caret = require("md-viewer.caret")
local cellpixels = require("md-viewer.cellpixels")
local config = require("md-viewer.config")
local coordinates = require("md-viewer.coordinates")
local preview = require("md-viewer.preview")
local renderer = require("md-viewer.renderer")
local state = require("md-viewer.state")
local sync = require("md-viewer.sync")
local terminal = require("md-viewer.terminal")
local process = require("md-viewer.process")
local debounce = require("md-viewer.debounce")
local animation = require("md-viewer.animation")
local navigation = require("md-viewer.navigation")
local mouse = require("md-viewer.mouse")
local interaction = require("md-viewer.interaction")
local source = require("md-viewer.source")
local remote_assets = require("md-viewer.remote_assets")
local resident = require("md-viewer.resident")

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

---Attribute what a backend operation actually wrote to the terminal to this
---session.
---
---`last_png_bytes` is the largest part of a frame but never the whole of it: the
---placements that position it, the deletions that supersede them, and the
---overlay rectangles composited on top are bytes on the same pty. Over SSH that
---pty is the constraint, so counting only the PNG is how "the payload fell to
---zero" can be true while the traffic did not -- the second-largest-item trap
---docs/local-render-design.md records being caught by once already.
---
---A no-op for a backend that reports nothing, which is every backend but
---kitty_raw. `kitty_raw.ui_bytes_total()` is the process-wide total these
---per-session shares are a subset of.
local function record_ui_bytes(session, stats)
  local bytes = type(stats) == "table" and tonumber(stats.bytes) or nil
  if not bytes then return end
  session.ui_bytes_total = (session.ui_bytes_total or 0) + bytes
  session.last_ui_bytes = bytes
end

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

---Give up every resident region's pixels.
---
---The counterpart to `backend.hide`, and the distinction matters: hiding takes
---an image off the screen and keeps it, this frees it. Only the paths that end a
---session's claim on the terminal's memory belong here -- closing, retargeting
---to another document, and falling back -- because everything else will want
---those pixels again within seconds.
---
---Deliberately **not** called on a renderer restart. The regions are pixels the
---terminal already holds, keyed by content revision, and a restarted renderer
---rebuilds the same document from the same buffer -- so they stay correct and
---survive for free. `animation.lua` keeps its terminal-resident uploads across a
---restart on exactly this reasoning ("uploads survive by stable content key").
local function free_resident(session)
  local state_ = session.resident
  if not (state_ and session.backend) then return end
  for _, region in ipairs(resident.drain(state_)) do
    if region.image_id and session.backend.clear then pcall(session.backend.clear, region.image_id) end
  end
end

function M.free_resident(session) free_resident(session) end

---Is this image one the resident cache is still counting on?
local function resident_holds(live, image_id)
  if not (live and image_id) then return false end
  for _, region in ipairs(live.regions) do
    if region.image_id == image_id then return true end
  end
  return false
end

---Nothing this session owns is on the screen any more. Placement state only --
---the pixels are a separate question, and `clear_image` answers it.
local function mark_regions_unplaced(session)
  local live = session.resident
  if not live then return end
  for _, region in ipairs(live.regions) do
    region.placed = false
  end
end

-- The hit path, defined with the rest of the resident policy further down.
-- Declared here because restoring a preview is one of the things it answers,
-- and `show_cached` -- which sits between the two -- is what asks.
local try_pan

local function clear_image(session)
  clear_selection_overlay(session)
  M.clear_caret_overlay(session)
  if session.image_id and session.backend then
    -- A resident region comes off the *screen*, not out of the terminal. Every
    -- reason a preview stops being drawn is temporary -- a focusable float, a
    -- tab switch, a completion popup, a suspend -- and freeing several viewports
    -- of pixels the terminal has not forgotten means paying to send them all
    -- again seconds later, over the one link this whole feature exists to spare.
    -- `free_resident` stays the only thing that gives a region's pixels back.
    local hide = resident_holds(session.resident, session.image_id) and session.backend.hide
    local hidden, stats
    if hide then
      hidden, stats = select(2, pcall(hide, session.image_id))
    end
    if hidden then
      record_ui_bytes(session, stats)
      mark_regions_unplaced(session)
    else
      session.backend.clear(session.image_id)
    end
  end
  session.image_id = nil
  session.last_placement = nil
  animation.clear(session)
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
local function apply_image(session, image_bytes, capture_scale, png_bytes, capture_ms, capture_encoder, opts)
  opts = opts or {}
  preview.stop_loading(session)
  preview.reset_surface(session)
  local placement = preview.placement(session.preview_win, session.backend.name)
  session.preview_width_cells = placement.width
  session.preview_height_cells = placement.height
  local image_started = vim.uv.hrtime()
  local ok, image_id, image_stats = pcall(function()
    -- `opts.source` shows only part of the image, for one taller than the
    -- viewport.
    --
    -- Whether to keep the image being replaced is deliberately *not* a caller's
    -- choice. It is either one the resident cache still holds -- in which case
    -- freeing it leaves the cache pointing at pixels the terminal has been told
    -- to forget, and the next pan fails on an image nobody owns -- or it is
    -- nothing to anybody, in which case the ordinary free is right. There is no
    -- third case, so deriving it here is what makes "a resident region is never
    -- freed as a side effect" structural rather than remembered at five call
    -- sites, two of which had already forgotten.
    if session.image_id then
      return session.backend.update(session.image_id, image_bytes, placement, {
        source = opts.source,
        retain_superseded = resident_holds(session.resident, session.image_id),
      })
    end
    return session.backend.show(image_bytes, placement, opts.source)
  end)
  if not ok or not image_id then
    session.render_failed = true
    -- On the failure branch the second value is a reason string, not stats.
    notify_error(ok and (image_stats or "failed to display rendered image") or image_id)
    return false
  end
  session.last_image_update_ms = (vim.uv.hrtime() - image_started) / 1000000
  record_ui_bytes(session, image_stats)
  -- Every frame is a measurement of the same wire, and the ordinary ones are the
  -- better sample: there are many of them and they all precede the first region
  -- fill, which is the payload the estimate has to be ready for. A fill folds in
  -- its own sample afterwards, once it has been charged the hold this one
  -- produced -- charging it against its own measurement would be circular.
  if session.resident and not opts.resident_fill then
    resident.note_wire_sample(session.resident, session.last_ui_bytes, session.last_image_update_ms)
  end
  -- What the terminal actually holds, from the PNG header the backend already
  -- parsed rather than from the scale this frame asked for. The two disagree on
  -- the Playwright fallback path, which cannot express a sub-1x factor, so the
  -- measured value is the only one geometry may be derived from.
  if type(image_stats) == "table" then
    session.image_width_px = image_stats.width_px
    session.image_height_px = image_stats.height_px
    -- And, separately, the width a *device-tier* capture comes back at. Not the
    -- same question as "how big is the image on screen", and conflating them is
    -- a bug that only appears over SSH: the settle timer fires once scrolling
    -- has stopped, so the frame on screen at that moment is always a moving one
    -- captured at `ssh_scroll_scale`. A region planned from that width assumes
    -- half the scale it will actually be captured at -- and since a region's
    -- height is derived as budget / (width x scale^2), halving the scale asks
    -- for four times the region the budget can hold. It is then refused, either
    -- by the renderer or by the cache, and nothing is ever resident.
    if capture_scale == "device" then session.device_image_width_px = image_stats.width_px end
  end
  if png_bytes then session.last_png_bytes = png_bytes end
  if capture_ms then session.last_capture_ms = capture_ms end
  if capture_scale then session.last_capture_scale = capture_scale end
  -- Which of the renderer's two screenshot paths produced this frame. The fast
  -- one falls back silently and permanently on its first failure, so without
  -- this a browser that refused it would just look inexplicably slow.
  if capture_encoder then session.last_capture_encoder = capture_encoder end
  -- The `*_png_bytes` fields above are the *last* frame of each kind; the
  -- counters below are every one of them. Both are needed and neither implies
  -- the other: the size says what a frame costs, the count says how many were
  -- actually paid for. Without the count the only available stand-in was
  -- `coalesced_scroll_events`, which counts the opposite thing -- events
  -- superseded *before* capture, so frames that were never produced and never
  -- transmitted -- and reading it as frames sent overstates the traffic badly.
  if capture_scale == "css" then
    session.fast_png_bytes = session.last_png_bytes
    session.fast_capture_ms = session.last_capture_ms
    session.fast_image_update_ms = session.last_image_update_ms
    session.fast_frame_count = (session.fast_frame_count or 0) + 1
    session.fast_bytes_total = (session.fast_bytes_total or 0) + (session.last_png_bytes or 0)
    -- Interval between consecutive moving frames, which is the only honest
    -- measure of how fast this pipeline can actually turn. Frames divided by
    -- wall-clock is not: a scroll driven by hand has pauses in it, and they
    -- land in the denominator as though the pipeline had been busy. The
    -- *minimum* is the floor -- the fastest this loop went when it was
    -- genuinely saturated -- and it is what a per-frame cost has to be compared
    -- against to say whether transit is the constraint or something else is.
    local now = vim.uv.hrtime()
    if session.fast_last_ns then
      local interval = (now - session.fast_last_ns) / 1e6
      session.fast_interval_min_ms = math.min(session.fast_interval_min_ms or interval, interval)
      session.fast_interval_sum_ms = (session.fast_interval_sum_ms or 0) + interval
      session.fast_interval_count = (session.fast_interval_count or 0) + 1
    end
    session.fast_last_ns = now
  elseif capture_scale == "device" and not opts.resident_fill then
    -- A region fill is captured at the device tier too, and is emphatically not
    -- a settle frame: it is several viewports tall, so averaging it in here
    -- would report the sharp-frame cost as several times what a reader actually
    -- waits for. It would also make the adaptive cap self-referential, since the
    -- cap is a multiple of this number -- a region measured against three of
    -- itself is never too large. The fill's own size is `resident.fill_png_bytes`.
    session.retina_png_bytes = session.last_png_bytes
    session.retina_capture_ms = session.last_capture_ms
    session.retina_image_update_ms = session.last_image_update_ms
    session.retina_frame_count = (session.retina_frame_count or 0) + 1
    session.retina_bytes_total = (session.retina_bytes_total or 0) + (session.last_png_bytes or 0)
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
  -- After the caret, because both draw over the base that has just landed and
  -- the animation is the lower of the two layers. `adopt` re-places the current
  -- step in this same tick, so a scroll frame does not drop the animation for
  -- 200ms on its way past.
  animation.adopt(session)
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
  -- The overlay exists to replace a captured frame with a few hundred bytes of
  -- placements, so it has to be inside the same total the frame it replaced was
  -- counted in -- otherwise the saving it makes is invisible to the one number
  -- that could confirm it.
  record_ui_bytes(session, stats)
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
  local ok, set_id, stats = pcall(
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
    --
    -- The reason is `overlay_apply`'s *second* return, not its first. Reading it
    -- from `set_id` recorded the literal string "nil" for every refusal the
    -- backend declined politely -- so the one case this field exists to explain
    -- was the one case it could not.
    session.caret_overlay_error = ok and (stats or "overlay refused") or tostring(set_id)
    return false
  end
  session.caret_overlay_set = set_id
  record_ui_bytes(session, stats)
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
  if not valid(session) or session.backend.name == "cells" then return false end
  -- A resident region goes back with a placement command and no pixels at all:
  -- it never left the terminal, only the screen. Tried before the cached PNG and
  -- not after, because the cached PNG is an *older* frame -- a region that has
  -- been panned within has moved on from whenever that capture was taken, so
  -- restoring the cache would silently put the reader back there.
  if try_pan(session) then return true end
  if not session.last_image_bytes then return false end
  if update_occlusion(session) then
    clear_image(session)
    return false
  end
  preview.stop_loading(session)
  preview.reset_surface(session)
  local placement = preview.placement(session.preview_win, session.backend.name)
  local ok, image_id, image_stats = pcall(session.backend.show, session.last_image_bytes, placement)
  if not ok or not image_id then
    session.render_failed = true
    notify_error(ok and (image_stats or "failed to display cached image") or image_id)
    return false
  end
  record_ui_bytes(session, image_stats)
  session.image_id = image_id
  session.last_placement = placement
  -- This path does not go through `apply_image`, so nothing else would put the
  -- frames back: a preview restored from cache after an occlusion would show a
  -- still image and never start again.
  animation.repaint(session)
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

-- ---------------------------------------------------------------------------
-- Resident regions: policy.
--
-- The split this file keeps to: `md-viewer.resident` answers "does this region
-- cover that scroll, and which pixels of it are the viewport" with no Neovim in
-- it; `backends/kitty_raw` answers "upload, place with this crop, delete" with
-- no idea what a scroll is; and everything between -- is this a hit, may we fill,
-- what has to be freed, when do we give up -- is here.
-- ---------------------------------------------------------------------------

-- Defined further down, beside `scroll_settle_delay`, which they need and which
-- belongs with the capture-scale rule it is the twin of. Declared here because
-- `M.refresh` -- which sits between the two -- is what calls them.
local hold_wire, cap_region_png, settle_options

---Whether this session may keep resident regions at all, and why not when it
---may not. Evaluated once, when the preview opens.
local function resident_gate(session)
  local cfg = config.get()
  if not session.backend or session.backend.name ~= "kitty_raw" then
    return false, ("backend %s cannot crop placements"):format(session.backend and session.backend.name or "none")
  end
  local supported, reason = session.backend.resident_pan_supported()
  if not supported then return false, reason end
  -- The same rule, and the same reason, as the moving frame's scale
  -- (`scroll_capture_scale`): what this trades terminal memory for is wire time,
  -- and wire time only exists over SSH. A local terminal receives a frame for
  -- free, so holding megabytes to avoid sending one would be a pure loss.
  --
  -- `terminal.detect().ssh` answers for the transport Neovim itself runs over
  -- and never for a buffer's origin, so a remote document opened in a local
  -- Neovim keeps the full-quality path -- the boundary
  -- tests/lua/cases/scroll_scale.lua pins between the two remote features.
  local capability = terminal.detect()
  if not capability.ssh then return false, "local session (no wire time to save)" end
  if capability.multiplexer ~= "none" then
    return false, ("multiplexer %s is not validated for resident panning"):format(capability.multiplexer)
  end
  if (cfg.image.resident_budget_px or 0) <= 0 then return false, "image.resident_budget_px is zero" end
  return true, reason
end

---Apply the gate's answer to a session, giving back any pixels it was holding.
---
---`M.open` needs this once. The A/B harness needs it again, because it toggles
---`image.resident_pan` between arms and a gate evaluated only at open would
---leave both arms running whatever the session started as -- the shape of A/B
---that reports a difference of zero and looks like a null result.
---
---Exported rather than left for the harness to reproduce, which is how this went
---wrong the first time: `fallback_reason = ok and nil or reason` reads as "the
---reason, but only on failure" and is not that. `nil` is falsy, so the `or`
---takes its right branch whatever `ok` was, and the gate's *success* message
---became a fallback reason that refused every fill and every pan for the rest of
---the session. Written out longhand below for that reason. The one thing a
---harness must not do is reimplement the decision it exists to measure.
function M.reevaluate_resident(session)
  local live = session.resident
  if not live then return false, "session has no resident state" end
  free_resident(session)
  local ok, reason = resident_gate(session)
  live.enabled = ok
  live.gate_reason = reason
  live.fallback_reason = nil
  if not ok then live.fallback_reason = reason end
  live.budget_px = config.get().image.resident_budget_px
  live.height_scale, live.region_shrinks = 1, 0
  return ok, reason
end

---Everything that must match for a region to still describe this document.
local function resident_key(session)
  local render = config.get().render
  return resident.key({
    document_id = session.document_id,
    renderer_revision = session.renderer_revision,
    viewport_width_px = session.viewport_width_px,
    viewport_height_px = session.viewport_height_px,
    theme = render.theme,
    background = vim.o.background,
    font_size_px = render.font_size_px,
    scroll_past_end = render.scroll_past_end,
    scroll_past_end_offset_px = render.scroll_past_end_offset_px,
    device_scale_factor = render.device_scale_factor,
  })
end

---Stop trying, for the life of this session, and give the pixels back.
---
---One-way on purpose. Every reason to fall back is a reason to distrust the
---machinery rather than the moment -- a refused crop, a capture Chromium will
---not take, metadata that does not add up -- and a gate that re-armed itself
---would rediscover the same defect on every scroll. The reason is reported in
---`:MdViewerDebug`, which is the only way anyone finds out.
local function resident_fallback(session, reason)
  local live = session.resident
  if not live or live.fallback_reason then return end
  live.fallback_reason = reason or "unspecified"
  live.enabled = false
  free_resident(session)
end

---Drop every region and remember the key they were replaced by.
local function resident_invalidate(session, key)
  local live = session.resident
  free_resident(session)
  live.key = key
end

---Show an already-resident region at the newest scroll position, if one covers
---it. This is the whole optimization: no renderer request, no capture, no image
---bytes -- a few hundred bytes of placement commands and the terminal pans
---pixels it is already holding.
---
---Returns false for every reason not to, and every one of them lands on exactly
---the behaviour that existed before this feature.
function try_pan(session)
  local live = session.resident
  if not (live and live.enabled) or live.fallback_reason then return false end
  if not valid(session) or session.backend.name ~= "kitty_raw" then return false end
  if not (session.viewport_width_px and session.viewport_height_px and session.renderer_revision) then return false end

  -- Browser-painted state a clean region does not carry. Find marks and a
  -- committed selection live in the DOM and are baked into the frame that shows
  -- them; a resident region was captured without either. Panning to it would
  -- silently erase a highlight the reader can see, so scrolling keeps its old
  -- behaviour until they clear it. Refusing to *fill* while these are up is not
  -- sufficient on its own -- a region captured before the search is still valid
  -- by key, and would be eligible to pan straight over the marks.
  if session.find_active then
    live.blocked_by_find = live.blocked_by_find + 1
    return false
  end
  if session.selection_active then
    live.blocked_by_selection = live.blocked_by_selection + 1
    return false
  end
  -- A drag resolves its rectangles against the scroll the frame on screen shows
  -- and refuses a disagreement over half a pixel, so moving the page underneath
  -- one would fail every overlay frame of the gesture.
  -- The *press*, not the pointer table. Releasing a drag leaves the table alive
  -- -- only `interaction.forget` nils it -- and a visual-mode synthetic pointer
  -- exists with `pressed = false`, so gating on the table's existence disables
  -- panning for the rest of the session after one click anywhere in the preview.
  -- animation.lua carries this same comment because it was caught there first;
  -- this is the second time the same table has been mistaken for a gesture.
  if session.pointer and session.pointer.pressed then return false end
  if update_occlusion(session) then return false end

  local key = resident_key(session)
  if live.key ~= key then
    resident_invalidate(session, key)
    return false
  end

  local viewport = { widthPx = session.viewport_width_px, heightPx = session.viewport_height_px }
  local desired = session.scroll_y or 0
  local region = resident.find(live, desired, viewport.heightPx, key)
  if not region then
    live.misses = live.misses + 1
    return false
  end
  local source, applied = resident.source_window(region, desired, viewport)
  if not source then
    live.misses = live.misses + 1
    return false
  end

  local placement = preview.placement(session.preview_win, session.backend.name)
  local previous = session.image_id
  local restoring = previous ~= region.image_id
  local ok, moved, stats = pcall(session.backend.move, region.image_id, placement, source)
  if not ok or not moved then
    resident_fallback(session, ok and (stats or "placement refused") or tostring(moved))
    return false
  end

  -- Whatever was on screen before, if it was not itself a region, is now
  -- unreferenced. Freed *after* the replacement is up, never before: deleting
  -- first leaves the terminal a moment with nothing to composite, which is the
  -- blink `M.move` documents at length.
  if previous and restoring and not resident_holds(live, previous) then pcall(session.backend.clear, previous) end
  for _, other in ipairs(live.regions) do
    other.placed = other == region
  end

  record_ui_bytes(session, stats)
  live.placement_bytes = live.placement_bytes + (type(stats) == "table" and stats.bytes or 0)
  live.hits = live.hits + 1
  -- A pan is a scroll that issued no request, and `request_serial` -- the thing
  -- that makes a newer request invalidate an older one -- only moves when a
  -- request is made. So a capture already in flight for the position the reader
  -- has just panned away from is not stale by that measure, and lands, and
  -- repaints the view they left. Before resident panning every scroll issued a
  -- capture, so the serial always moved; this counter is what replaces that.
  --
  -- Deliberately not `request_serial` itself. That would also cancel renders a
  -- pan has no quarrel with -- an edit's re-render, a float closing -- and
  -- `try_pan` runs on those restore paths too.
  session.pan_serial = (session.pan_serial or 0) + 1
  if restoring then
    live.unplaced_places = live.unplaced_places + 1
  else
    live.pans = live.pans + 1
  end

  session.image_id = region.image_id
  session.last_placement = placement
  session.image_width_px, session.image_height_px = region.image_w, region.image_h
  -- The scroll the pixels genuinely show, snapped to a whole image pixel. Three
  -- things read this as exactly that -- the caret's drift, the animation layer's
  -- placement, and the scroll every interact request carries -- so recording the
  -- requested position instead would put all three fractionally out.
  session.applied_scroll_y = applied
  preview.stop_loading(session)
  -- Same order `apply_image` establishes after a new frame lands: the overlays
  -- were measured against geometry that has just moved, and the caret is redrawn
  -- immediately so it survives the pan without a round trip or a flicker.
  clear_selection_overlay(session)
  M.clear_caret_overlay(session)
  M.place_caret(session)
  -- And the terminal cursor that shadows the caret, which is a separate thing
  -- drawn by Neovim rather than by the backend. It is derived from
  -- `applied_scroll_y` -- the same drift subtraction the overlay uses -- but it
  -- is normally only recomputed when the renderer answers with a new caret
  -- position. A pan moves the frame of reference with no round trip, so nothing
  -- would recompute it, and the block would sit at the row the caret occupied
  -- before the scroll while the overlay drew it at the row it occupies now.
  -- Anything derived from `applied_scroll_y` has to follow when it changes.
  caret.shadow_cursor(session)
  animation.repaint(session)
  return true
end

---Turn a completed region capture into a region record, or say why not.
---
---The dimensions come from the PNG's own header rather than from the scale that
---was requested, and the document rectangle from what the renderer says it
---actually captured rather than from what was asked for -- the renderer clamps a
---region to the document's end, and a region that believed the request would
---misplace every crop in a document's last screen.
local function region_from_fill(session, image_bytes, meta)
  if type(meta.regionYPx) ~= "number" or type(meta.regionHeightPx) ~= "number" then
    return nil, "renderer reported no captured region"
  end
  local width_px, height_px = session.backend.png_dimensions(image_bytes)
  if not width_px then return nil, "region PNG has no readable dimensions" end
  return resident.region({
    doc_y = meta.regionYPx,
    doc_h = meta.regionHeightPx,
    css_w = session.viewport_width_px,
    image_w = width_px,
    image_h = height_px,
    key = resident_key(session),
  })
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
  if session.remote and not session.remote.ready then
    -- The mirror paths are not known yet: rendering now would send local-path
    -- garbage as baseDir/documentRoot. Remember that a render was wanted and
    -- let remote_attach's completion fire it -- the loading spinner is
    -- already covering the wait, and this one guard covers every producer
    -- (edits, scrolls, resizes, colorscheme changes) because they all funnel
    -- through here.
    session.remote.pending_refresh = true
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
  -- A fill occupies the one fill slot from here -- the point the request is
  -- genuinely issued, past every early return above -- rather than from where
  -- its options were built. Claiming the slot at planning time was enough to
  -- deny it to the fill that actually went out: the settle timer re-plans on
  -- every scroll event, so the first event of a burst took the slot and the last
  -- one, the only one that fires, found it taken.
  -- Where the reader was, in pans, when this request went out. A pan moves the
  -- view without issuing anything, so it cannot be caught by the request serial.
  local pan_at = session.pan_serial or 0
  local filling = render_options and render_options.resident_fill and session.resident or nil
  local fill_token
  if filling then
    filling.fill.token = (filling.fill.token or 0) + 1
    fill_token = filling.fill.token
    filling.fill.in_flight = true
    -- The document this region will be pixels *of*, recorded now. Compared again
    -- when the capture lands, because between the two the viewport can change
    -- underneath it -- this same callback adopts the renderer's viewport before
    -- the region is built, so a key computed only at the end would stamp a
    -- resized document's identity onto pixels of the old one.
    filling.fill.key = resident_key(session)
    filling.fill.doc_y = render_options.capture_region and render_options.capture_region.yPx
    filling.fill.doc_h = render_options.capture_region and render_options.capture_region.heightPx
    filling.desired_scroll_y = session.scroll_y or 0
  end
  renderer.request(session, markdown(session), render_options, function(result, err, stale, info)
    local function finish()
      -- Released by every route out of this callback -- superseded, failed,
      -- discarded, displayed -- and only by the fill that is actually holding
      -- it. Releasing only on success is how one failed capture would disable
      -- region fills for the rest of a session with nothing on screen to say so.
      if filling and filling.fill.token == fill_token then filling.fill.in_flight = false end
      if render_options and render_options.on_complete then render_options.on_complete(stale, err) end
    end
    if not valid(session) then
      finish()
      return
    end
    if stale then
      -- A newer request of any kind supersedes this one, and for a fill that is
      -- a whole region's capture thrown away. It costs no wire -- nothing was
      -- uploaded -- but it is worth seeing, because a session where every fill
      -- is superseded is a session that never gets a region at all.
      if filling then filling.stale_fills = filling.stale_fills + 1 end
      finish()
      return
    end
    -- A region the renderer will not capture at the size that was asked for.
    -- Handled ahead of the generic error branch because it is not a render
    -- failure: the preview on screen is untouched and the reader has nothing to
    -- be told. Ask once for half as much, and only give up if that is refused
    -- too -- at which point the geometry is beyond what this Chromium will take
    -- at all, and no smaller region is going to change that.
    if filling and info and info.code == "REGION_TOO_LARGE" then
      -- First, because planning the replacement asks whether a fill is already
      -- in flight -- and this one is, until it is finished with.
      finish()
      if filling.region_shrinks >= 1 then
        resident_fallback(session, "renderer refused the region twice: " .. tostring(err))
        return
      end
      filling.region_shrinks = filling.region_shrinks + 1
      filling.height_scale = math.max(resident.MIN_HEIGHT_SCALE, filling.height_scale * 0.5)
      filling.height_reduced = filling.height_reduced + 1
      local retry = settle_options(session)
      if not retry.capture_region then
        -- Halving left nothing worth having, which at a small budget is the
        -- ordinary outcome: half a region is under a viewport, and a region that
        -- cannot hold the viewport can never be a hit. Said out loud rather than
        -- left to plan nothing on every settle for the rest of the session.
        resident_fallback(
          session,
          ("renderer refused the region and no smaller one fits (%s)"):format(filling.plan_refusal or tostring(err))
        )
        return
      end
      -- Immediately, rather than waiting for the reader to scroll again: they
      -- have already stopped, which is the whole condition a settle waits for.
      M.schedule(session, 0, "scroll_settle_timer", retry)
      return
    end
    if err then
      session.render_failed = true
      preview.stop_loading(session)
      notify_error(err)
      finish()
      return
    end
    -- The reader panned while this was in flight, so it is a picture of
    -- somewhere they are no longer looking. Discarded rather than displayed --
    -- displaying it is the defect: the frame is internally consistent and
    -- perfectly sharp, it is simply of the wrong part of the document, and it
    -- arrives *after* the correct view so it wins.
    --
    -- A fill is exempt and must be: it is not a picture of one position but of a
    -- range, and it is cropped to wherever the reader is now. Panning while one
    -- is in flight is the case it was designed for, not a reason to throw it
    -- away.
    if not filling and (session.pan_serial or 0) ~= pan_at then
      if session.resident then session.resident.superseded_by_pan = (session.resident.superseded_by_pan or 0) + 1 end
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
    --
    -- A fill writes neither. It is a cache load, not a navigation: it was
    -- requested from wherever the reader happened to be, and they are free to
    -- have moved on while it captured -- a resident hit issues no request, so a
    -- fill is not superseded by scrolling that lands inside a region. Writing
    -- `scroll_y` here would drag them back to where the fill started. Writing
    -- `applied_scroll_y` would be worse: its pixels are not on screen yet and
    -- may never be, and the caret and the animation layer are both placed from
    -- it. It is set once, below, if the region is actually displayed.
    if not (newer_scroll_pending or filling) then session.scroll_y = meta.scrollY end
    if not filling then session.applied_scroll_y = meta.scrollY end
    session.last_layout_reused = meta.layoutReused == true
    session.last_markdown_reused = meta.markdownReused == true
    session.last_capture_scale = meta.captureScale
    session.last_png_bytes = meta.pngBytes or #result.image
    session.last_layout_ms = meta.layoutMs
    session.last_capture_ms = meta.captureMs
    session.viewport_width_px = result.viewport.widthPx
    session.viewport_height_render_px = result.viewport.heightPx
    session.viewport_calibration_tier = result.viewport.tier
    -- The cell the viewport was actually built from, in CSS pixels, and nil on
    -- the estimated tier. Recorded rather than re-derived for :MdViewerDebug:
    -- the measurement is uncached and follows a font-size change, so asking
    -- again later answers about the terminal now, not about this render.
    session.viewport_cell_css_width_px = result.viewport.cellWidthPx
    session.viewport_cell_css_height_px = result.viewport.cellHeightPx
    -- And how the unit that cell was measured in got decided, for the same
    -- reason: the heuristic reads the terminal live, so asking it again later
    -- answers about the terminal now rather than about this render.
    session.viewport_cell_detail = result.viewport.cellUnit
      and {
        unit = result.viewport.cellUnit,
        divisor = result.viewport.cellDivisor,
        source = result.viewport.cellUnitSource,
        plausible = result.viewport.cellPlausible,
        rejected_divisor = result.viewport.cellRejectedDivisor,
      }
    -- Animation geometry travels with the render it was measured against, so
    -- it inherits this callback's staleness handling wholesale: rects and the
    -- base they overlay can never disagree. animation.adopt() reads it after
    -- apply_image lands this same frame.
    session.animation_geometry = meta.animations
    -- Some animated image had no measurable box yet when this render laid the
    -- document out. The renderer will re-measure, but only on a render, and an
    -- idle preview issues none -- so without this the first attempt would be
    -- the only one and the document would keep its still frames until a resize
    -- or an edit happened along. Debounced under its own timer name, and the
    -- renderer stops asking after a bounded number of attempts, so a genuinely
    -- unmeasurable image costs a handful of renders rather than a loop.
    session.animation_geometry_incomplete = meta.animationsIncomplete == true
    if session.animation_geometry_incomplete then M.schedule(session, 120, "animation_geometry_timer") end
    -- An image the renderer is still fetching. The document has already been
    -- shown with a placeholder in its place rather than waiting for it -- one
    -- unreachable image used to cost the whole preview a 20 second stall before
    -- anything appeared -- so this is the nudge that puts the picture in once it
    -- lands. Nothing else would: an idle preview issues no renders at all.
    --
    -- 400ms rather than the animation retry's 120: a fetch crossing a network is
    -- not going to finish in a tenth of a second, and each attempt costs a full
    -- re-render of the document. The renderer's own timeout bounds how long this
    -- can go on, and a failure caches as a failure, so this stops on its own.
    session.remote_images_pending = meta.remoteImagesPending == true
    if session.remote_images_pending then M.schedule(session, 400, "remote_image_timer") end
    -- The same loop for a remote document's files: the render already showed
    -- placeholders for whatever the mirror lacks, the pipeline fetches those
    -- files, and this callback -- fired at most once per batch, only when the
    -- mirror actually changed -- is the one more render that puts the
    -- pictures in. The epoch bump is what invalidates the renderer's cached
    -- parse; contentRevision carries it, so no new protocol field exists.
    if session.remote and meta.localImageAssets then
      remote_assets.on_assets(session, meta.localImageAssets, function()
        session.render_epoch = (session.render_epoch or 0) + 1
        M.schedule(session, 0)
      end)
    end
    -- A region fill is not a frame; it is an image several viewports tall that
    -- the terminal will hold and be re-cropped within. Caching it as
    -- `last_image_bytes` would have `show_cached` later restore it as though it
    -- were one viewport -- the whole range squashed into the split.
    if not filling then session.last_image_bytes = result.image end
    -- A capture taken while a DOM selection was live has it painted in, so the
    -- cached clean base cannot be this frame. `apply_image` records the
    -- replacement whenever a selection-free frame does reach the screen.
    if session.selection_active then session.clean_image_bytes = nil end
    if update_occlusion(session) then
      clear_image(session)
      finish()
      return
    end

    if filling then
      local live = session.resident
      live.fills = live.fills + 1
      live.fill_png_bytes = session.last_png_bytes
      live.fill_capture_ms = session.last_capture_ms
      -- The document these pixels are of, against the document there is now.
      -- The request serial catches most disagreements, but not the one this
      -- callback creates itself: it adopts the renderer's viewport a few dozen
      -- lines above, so a preview resized while the region captured changes the
      -- key here, between the capture and the region built from it. A region
      -- stamped with the new key and filled with the old document's pixels is
      -- the one failure this whole cache must not be able to produce.
      if live.fill.key and live.fill.key ~= resident_key(session) then
        live.stale_fills = live.stale_fills + 1
        finish()
        return
      end
      local region, region_reason = region_from_fill(session, result.image, meta)
      if not region then
        -- Not a transient failure: the renderer or the image is not answering in
        -- a shape the coordinate model can use, and retrying would rediscover
        -- that on every settle.
        resident_fallback(session, region_reason)
        finish()
        return
      end
      local viewport = { widthPx = session.viewport_width_px, heightPx = session.viewport_height_px }
      local source, applied = resident.source_window(region, session.scroll_y or 0, viewport)
      if not source then
        -- The reader left the range while this captured. Discarded rather than
        -- uploaded-and-kept: a region the viewport is not inside is several
        -- hundred kilobytes of wire spent on pixels nobody is looking at, and on
        -- the link this exists for that is the most expensive thing it could
        -- possibly do. Dropping it here costs nothing at all -- the capture
        -- never left the VM. Counted apart from `stale_fills` because it means
        -- something different: this fill was never wrong, only overtaken.
        live.abandoned_fills = live.abandoned_fills + 1
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
          meta.captureEncoder,
          { source = source, resident_fill = true }
        )
      then
        finish()
        return
      end
      region.image_id = session.image_id
      region.placed = true
      session.applied_scroll_y = applied
      local emitted = session.last_ui_bytes or 0
      live.upload_bytes = live.upload_bytes + emitted
      hold_wire(session, emitted, session.last_image_update_ms)
      -- Fold this payload in only now, after it has been charged the hold the
      -- *previous* frames predicted. Estimating from a payload and then holding
      -- that same payload against its own estimate is circular, and the answer
      -- it converges on is "however long the write happened to block".
      resident.note_wire_sample(live, emitted, session.last_image_update_ms)
      cap_region_png(session)
      local stored, evicted, insert_reason = resident.insert(live, region)
      for _, gone in ipairs(evicted) do
        if gone.image_id and gone.image_id ~= region.image_id then pcall(session.backend.clear, gone.image_id) end
      end
      -- A region that cannot be kept is still on screen and still correct; it
      -- simply will not be there for the next scroll, which is the ordinary
      -- capture path rather than a defect. The next `apply_image` frees its
      -- image, since nothing in the cache holds it.
      live.last_insert_refusal = nil
      if not stored then live.last_insert_refusal = insert_reason end
      live.key = region.key
      for _, other in ipairs(live.regions) do
        other.placed = other == region
      end
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

---`render_options` may be a function, and is then resolved when the timer fires
---rather than when it is armed. The settle timer needs that and nothing else
---does: it is re-armed by every scroll event in a burst, so options built at arm
---time describe where the reader was when the burst *started*. For the sharp
---viewport frame that made no difference -- the request carries no position of
---its own, and `session.scroll_y` is read at send time. For a region fill it is
---the whole thing: the region is anchored around the scroll it was planned at,
---so planning at arm time would centre it a full burst behind the reader.
function M.schedule(session, delay, timer_name, render_options)
  if not valid(session) then return end
  debounce.call(session, timer_name or "render_timer", delay or config.get().render.debounce_ms, function()
    if not valid(session) then return end
    M.refresh(session, type(render_options) == "function" and render_options(session) or render_options)
  end)
end

---The pixel scale for the *moving* frame of a scroll, as a fraction of its
---natural size, and where the number came from.
---
---An explicit `render.scroll_scale` pins it everywhere. Left unset it is full
---size locally and `render.ssh_scroll_scale` over SSH, because what it trades
---sharpness for is wire time, and wire time only exists over SSH: a local
---terminal pays nothing to receive a larger frame, so shrinking one there would
---give up sharpness and buy nothing.
---
---Returns nil when there is no separate moving frame to scale at all
---(`fast_scroll = false` makes every frame the settle frame), which keeps the
---"never scale the frame a reader is looking at" rule in one place rather than
---restated at each caller. nil also means the request carries no factor field,
---so a local session's bytes are exactly what they were before this existed.
local function scroll_capture_scale(render)
  if not render.fast_scroll then return nil, "render.fast_scroll=false (no moving frame)" end
  if render.scroll_scale ~= nil then return render.scroll_scale, "explicit override (render.scroll_scale)" end
  if terminal.detect().ssh then return render.ssh_scroll_scale, "SSH session (render.ssh_scroll_scale)" end
  return nil, "local session (full size)"
end

---How long scrolling must be idle before the sharp settle capture is taken, and
---where the number came from.
---
---`render.ssh_scroll_settle_ms` replaces `render.scroll_settle_ms` outright on
---an SSH session rather than being combined with it, so the two values are
---simply the two answers and neither has to be read in terms of the other. One
---delay everywhere means setting both to the same number: a nil here is still
---honoured, but `setup()` cannot express one -- `vim.tbl_deep_extend` reads an
---absent key as "keep the default" -- so it is not the documented route.
---
---Separate from `scroll_capture_scale` above even though both are SSH-gated,
---because they are gated on different things: the scale trades sharpness for
---bytes, this trades latency for *not spending the bytes at all* on a reader
---who has not finished scrolling.
local function scroll_settle_delay(render)
  if render.ssh_scroll_settle_ms ~= nil and terminal.detect().ssh then
    return render.ssh_scroll_settle_ms, "SSH session (render.ssh_scroll_settle_ms)"
  end
  return render.scroll_settle_ms, "render.scroll_settle_ms"
end

---How many settle frames a region may cost before it is judged too large.
---
---A multiple rather than a byte count, because what a viewport costs to encode
---is a property of the document: a page of prose and a page of syntax-
---highlighted code are not within a factor of each other, and a constant here
---would be wrong for every document but the one it was measured on.
---
---**It must stay above `resident.K_MAX`, and the reason is not obvious.** A
---region's PNG scales close to linearly with its pixel count
---(scripts/resident/probe.mjs), so a region of *k* viewports costs about *k*
---settle frames. That makes this cap and `K_MAX` two limits on the same
---quantity, expressed in different units -- and set below `K_MAX` this one
---always binds first, silently overriding the height the budget derived.
---
---It shipped at 3 against a `K_MAX` of 4 and did exactly that on the first real
---run: regions were ratcheted to 43% of the budget's height, which at that
---viewport left about a third of a screen of travel, so nearly every scroll
---missed and refilled. 6 fills and 5 evictions in 149 seconds, and 25% *more*
---traffic than the baseline. The budget is what bounds size; this exists only to
---catch a region so far outside the linear relationship that the budget's
---estimate of its cost was wrong. Hence the headroom.
local REGION_PNG_CAP_FRAMES = 6

---Keep the wire to this session's region upload for as long as it is likely to
---still be crossing it.
---
---The invariant this exists to hold: **at most one image payload outstanding per
---session**. Nothing else enforces it. `scroll_render_in_flight` clears when the
---*capture* completes, which on this link is an order of magnitude sooner than
---the bytes arrive, and `nvim_ui_send` cannot be taken back once it has them --
---so without a hold, a region draining for a second collects every moving frame
---produced during that second, behind it, at positions the reader has left. That
---is precisely the backlog this whole feature exists to remove, rebuilt by the
---feature itself.
function hold_wire(session, bytes, elapsed_ms)
  local live = session.resident
  if not live then return end
  local settle = scroll_settle_delay(config.get().render)
  live.upload_hold_ms = resident.wire_hold_ms(bytes, live.wire_bytes_per_ms, elapsed_ms, settle, settle * 2)
  live.upload_hold_until = vim.uv.now() + live.upload_hold_ms
end

---Shrink future regions if this one encoded larger than the cap.
---
---A hold is damage control -- it stops a big payload collecting a queue. This is
---prevention: it stops the payload being big. Both are needed, because a hold
---long enough to cover a genuinely oversized region is a hold long enough for
---the reader to notice.
function cap_region_png(session)
  local live = session.resident
  local baseline = session.retina_png_bytes
  -- No sharp frame measured yet means no basis to judge against. A region is not
  -- compared to itself: `apply_image` keeps fills out of `retina_png_bytes`
  -- exactly so this number stays the cost of one *viewport*.
  if not (live and baseline and baseline > 0) then return end
  local reduced = resident.png_cap_scale(live.height_scale, live.fill_png_bytes, baseline * REGION_PNG_CAP_FRAMES)
  if reduced < live.height_scale then
    live.height_scale = reduced
    live.height_reduced = live.height_reduced + 1
  end
end

---What the settle timer should ask for once scrolling stops.
---
---Ordinarily the sharp viewport frame it has always taken. On a session keeping
---resident regions the *same* request becomes a region fill instead: one
---capture, a couple of viewports tall, after which scrolling inside it needs no
---capture at all. One request either way -- the settle is repurposed, not
---doubled up, so a miss costs what it always cost plus the region's extra
---height and nothing more.
---
---Falls back to the plain settle whenever a region would be wrong to take: while
---a selection or a search is painted into the document (a region outlives the
---frame it was captured with by minutes, so either would become a highlight that
---never clears), while a fill is already in flight, and when no region worth
---having fits the budget.
---
---Called when the settle timer *fires*, not when it is armed (see `M.schedule`),
---so the region is planned around where the reader actually stopped.
function settle_options(session)
  local live = session.resident
  local plain = { capture_scale = "device", capture_only = true }
  if not (live and live.enabled) or live.fallback_reason then return plain end
  -- `pointer.pressed`, not `pointer`: a released drag leaves the table behind,
  -- and refusing on its existence means one click stops every later settle from
  -- ever asking for a region -- silently, since nothing was refused and nothing
  -- failed. See `try_pan`.
  if session.selection_active or session.find_active or (session.pointer and session.pointer.pressed) then
    return plain
  end
  if live.fill.in_flight then return plain end
  if not (session.viewport_width_px and session.viewport_height_px and session.document_height_px) then return plain end

  local render = config.get().render
  local plan, refusal = resident.plan_region({
    scroll_y = session.scroll_y or 0,
    viewport_h = session.viewport_height_px,
    viewport_w = session.viewport_width_px,
    document_height_px = session.document_height_px,
    -- The scale the capture will come back at, measured from the last
    -- *device-tier* image rather than from whatever is on screen. Those are the
    -- same thing locally and never the same thing over SSH: a settle fires once
    -- scrolling has stopped, so the frame on screen at that moment is a moving
    -- one captured at `ssh_scroll_scale`, whose PNG at the default 0.5 and
    -- device scale 2 is exactly viewport-width. Reading the scale off that gives
    -- 1.0 for a capture that will arrive at 2.0 -- and since the height below is
    -- derived as budget / (width * scale^2), halving the scale asks for four
    -- times the region the budget can hold. Measured rather than configured
    -- because the Playwright fallback cannot express a sub-1x factor and returns
    -- a full-size frame, so the requested number is wrong on one encoder path.
    scale = (session.device_image_width_px and session.viewport_width_px)
        and (session.device_image_width_px / session.viewport_width_px)
      or render.device_scale_factor,
    -- Not the whole budget when this session has already been shown that its
    -- regions encode larger than the budget assumed. The height is derived from
    -- the budget, so shrinking what the planner may spend is what shrinks the
    -- region -- and every other clamp, including the memory bound itself, still
    -- applies to the result unchanged.
    budget_px = live.budget_px * (live.height_scale or 1),
    max_regions = live.max_regions,
  })
  if not plan then
    live.plan_refusal = refusal
    return plain
  end
  live.plan_refusal = nil

  return {
    capture_scale = "device",
    capture_only = true,
    capture_region = { yPx = plan.doc_y, heightPx = plan.doc_h },
    -- The renderer has had a `settle` lane since the interaction work and has
    -- never been sent one: `capture` has been carrying both the moving frames
    -- and the settle frame, which invalidate each other. A fill is expensive
    -- enough that losing it to the next wheel notch would be the whole cost of
    -- the feature paid for nothing.
    lane = "settle",
    resident_fill = true,
  }
end

---Is the wire still carrying this session's last region upload?
---
---Asked only after `try_pan` has declined, because a pan during a drain is not
---merely allowed but preferred: it is a couple of hundred bytes that queue
---trivially behind the region they crop into, and it shows the reader the
---position they are actually at.
---
---A *miss* during a drain is the opposite. Adding an 80 KB frame behind a
---draining 810 KB one does not make anything appear sooner; it makes it appear
---later, and at a position the reader has already left by the time it lands. So
---nothing is emitted -- not a request, not a byte -- and one resume is armed for
---when the wire is free. Debounced by name, so a burst of twenty events during
---one drain arms one resume rather than twenty, and it resumes at whatever the
---newest position turns out to be rather than replaying the burst.
local function hold_scroll(session)
  local live = session.resident
  if not (live and live.enabled) or live.fallback_reason then return false end
  local remaining = (live.upload_hold_until or 0) - vim.uv.now()
  if remaining <= 0 then return false end
  live.desired_scroll_y = session.scroll_y or 0
  live.frames_suppressed_by_hold = live.frames_suppressed_by_hold + 1
  -- The same counter the ordinary in-flight coalescing uses: from the reader's
  -- side both are "a scroll event that produced no frame of its own", and
  -- splitting them in the headline number would understate how much of the
  -- traffic this removes.
  session.coalesced_scroll_events = (session.coalesced_scroll_events or 0) + 1
  debounce.call(session, "resident_hold_timer", remaining, function()
    if valid(session) then M.schedule_scroll(session) end
  end)
  return true
end

function M.schedule_scroll(session)
  -- The hit path, and the point of all of this: the pixels for this position are
  -- already in the terminal, so the newest scroll costs a placement command
  -- rather than a capture, a transfer and a frame.
  if try_pan(session) then return end
  if hold_scroll(session) then return end

  local render = config.get().render
  local fast_scale = render.fast_scroll and "css" or "device"
  local scale_factor, scale_source = scroll_capture_scale(render)
  -- Recorded rather than re-derived in :MdViewerDebug: the answer depends on
  -- the SSH capability snapshot, and a reader asking later wants to know what
  -- this session's frames were actually captured at.
  session.scroll_scale = scale_factor
  session.scroll_scale_source = scale_source
  if session.scroll_render_in_flight then
    session.scroll_render_pending = true
    session.coalesced_scroll_events = (session.coalesced_scroll_events or 0) + 1
  else
    session.scroll_render_in_flight = true
    M.refresh(session, {
      capture_scale = fast_scale,
      capture_scale_factor = scale_factor,
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
    local settle_ms, settle_source = scroll_settle_delay(render)
    session.scroll_settle_ms = settle_ms
    session.scroll_settle_source = settle_source
    -- Passed as a function, not a value: this is re-armed by every event in a
    -- scroll burst, and a region planned at arm time would be anchored where the
    -- burst started rather than where the reader stopped.
    M.schedule(session, settle_ms, "scroll_settle_timer", settle_options)
  end
end

local function schedule_source_scroll(session, delay)
  debounce.call(session, "cursor_scroll_timer", delay, function()
    if valid(session) then M.schedule_scroll(session) end
  end)
end

-- `stop_opts` is forwarded to `process.stop` for the one call that actually
-- stops the renderer -- closing the last session -- so that `close_all` at
-- VimLeavePre can ask for the blocking teardown. Nil for every ordinary close.
local function close_session(session, stop_opts)
  if not session or session.closed then return end
  session.closed = true
  session.request_serial = session.request_serial + 1
  for _, name in ipairs({
    "render_timer",
    "resize_timer",
    "scroll_settle_timer",
    "resident_hold_timer",
    "cursor_scroll_timer",
    "animation_geometry_timer",
    "remote_image_timer",
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
  -- After clear_image, not before: the image on screen may itself be a resident
  -- region, and freeing the pixels out from under a live placement is the one
  -- ordering that can leave the terminal drawing from an image it was told to
  -- forget.
  free_resident(session)
  session.last_image_bytes = nil
  session.clean_image_bytes = nil
  state.remove(session.source_buf)
  if session.preview_win and vim.api.nvim_win_is_valid(session.preview_win) then
    pcall(vim.api.nvim_win_close, session.preview_win, true)
  end
  if not next(state.all()) then process.stop(stop_opts) end
  interaction.forget(session)
  interaction.forget_selection(session)
  animation.forget(session)
  mouse.detach_if_unused()
end

function M.close(buf)
  local session = current_session(buf)
  close_session(session)
end

function M.close_all(opts)
  local copy = {}
  for _, session in pairs(state.all()) do
    copy[#copy + 1] = session
  end
  for _, session in ipairs(copy) do
    close_session(session, opts)
  end
  for _, name in ipairs({ "nvim_img", "kitty_raw" }) do
    backends.get(name).clear_all()
  end
  -- Usually a no-op: the last close_session already stopped the renderer, with
  -- `opts`. This covers close_all with no sessions open at all.
  process.stop(opts)
end

---Attach remote-document state to a session and start the one round trip that
---resolves the document's physical path, base directory and project root.
---Every render defers (M.refresh's guard) until this lands: the mirror paths
---derived here are what the render request carries as baseDir/documentRoot,
---and they are final for the session -- the renderer's markdown cache keys on
---them, so a mid-session swap would strand every cached parse.
---
---When the walk fails the session still opens: the text is already in the
---buffer and renders without touching the network. It is rooted at the
---document's own directory so the failure stays contained -- images show
---placeholders naming what happened, reported once here rather than once per
---image.
local function remote_attach(session, parsed)
  local remote = { parsed = parsed, ready = false, pending_refresh = false, failed = nil }
  session.remote = remote
  remote_assets.resolve_root(parsed, function(info, err)
    if not valid(session) or session.remote ~= remote then return end
    if info then
      remote.path, remote.base_dir, remote.root = info.path, info.base_dir, info.root
    else
      remote.failed = err
      remote.path = source.normalize_remote(parsed.path)
      remote.base_dir = source.parent_remote(remote.path)
      remote.root = remote.base_dir
      notify_error(err)
    end
    remote.mirror_root = remote_assets.mirror_root(parsed, remote.root)
    remote.mirror_base_dir = remote_assets.mirror_path(remote.mirror_root, remote.root, remote.base_dir)
    remote.ready = true
    if remote.pending_refresh then
      remote.pending_refresh = false
      M.schedule(session, 0)
    end
  end)
end

function M.open(position)
  local source_buf, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local existing = state.get(source_buf)
  if existing and valid(existing) then return existing end
  local pinned = state.from_source_win(source_win)
  if pinned and valid(pinned) then return pinned end
  local remote_parsed = source.parse(vim.api.nvim_buf_get_name(source_buf))
  local buftype = vim.bo[source_buf].buftype
  if remote_parsed then
    -- A parseable remote name must never fall through to local path handling,
    -- whatever its buftype: vim.fs would mangle the URL and root the document
    -- in whichever project encloses Neovim's cwd -- a local security boundary
    -- for remote content. Either it opens as a remote session or it is
    -- refused outright.
    if not config.get().remote.enabled then
      notify_error("remote documents are disabled (remote.enabled = false)")
      return
    end
    if buftype ~= "" and buftype ~= "acwrite" then
      notify_error("open a normal Markdown buffer first")
      return
    end
  elseif buftype ~= "" then
    notify_error("open a normal Markdown buffer first")
    return
  end
  local backend, reason = backends.select()
  if not backend then
    notify_error(reason)
    return
  end
  local session = state.create(source_buf, source_win)
  if remote_parsed then remote_attach(session, remote_parsed) end
  M.history_init(session)
  session.backend, session.backend_reason = backend, reason
  -- Decided once, here, rather than re-derived on the scroll path: the answer
  -- depends on a capability snapshot and a terminal profile, neither of which
  -- changes under a session, and a reader asking `:MdViewerDebug` later wants to
  -- know what this session actually did.
  M.reevaluate_resident(session)
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
  local remote_parsed = source.parse(vim.api.nvim_buf_get_name(new_buf))
  -- Same rule as M.open, for the same reason: a remote name either becomes a
  -- remote session or is refused -- it must never be rendered with local
  -- path handling.
  if remote_parsed and not config.get().remote.enabled then return false end
  if not state.retarget(session, new_buf) then return false end
  session.remote = nil
  if remote_parsed then remote_attach(session, remote_parsed) end
  -- Every resident region belongs to the document being left. The key would
  -- refuse them anyway -- `document_id` moves with the retarget -- but refusing
  -- them is not the same as giving their pixels back, and nothing else would.
  free_resident(session)
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
  if name == "" then return { buf = buf, path = nil } end
  -- A remote name is stored verbatim: vim.fs.normalize would corrupt the URL
  -- (scp://h//a becomes scp:/h/a), and reopening one goes through
  -- bufadd(url) + the provider's BufReadCmd rather than the filesystem.
  return { buf = buf, path = source.parse(name) and name or vim.fs.normalize(name) }
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
  if not entry.path then return nil end
  -- A remote entry cannot be stat'ed here; reopening it hands the URL to
  -- bufadd and the provider's BufReadCmd, which is exactly how it was opened
  -- the first time. Local entries keep the existence check: a dead entry is
  -- stepped over, not reported.
  if not source.parse(entry.path) and not vim.uv.fs_stat(entry.path) then return nil end
  local buf = vim.fn.bufadd(entry.path)
  if buf == 0 then return nil end
  pcall(vim.fn.bufload, buf)
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
    -- Third value is a stats table when `moved` is truthy and a reason string
    -- when it is not; each branch below reads only the one it asked for.
    local ok, moved, stats_or_err = pcall(session.backend.move, session.image_id, placement)
    if not ok then
      notify_error(moved)
      return
    end
    if not moved then
      notify_error(stats_or_err or "failed to update image placement")
      return
    end
    record_ui_bytes(session, stats_or_err)
    -- The base just moved or re-cropped (a float opened or closed over it);
    -- overlay rectangles computed against the old placement are wrong now.
    -- Cleared after the move rather than re-derived: the next drag frame
    -- repaints them against the new placement within one round trip.
    clear_selection_overlay(session)
  end
  -- Always refresh, even when no move() happened: exclusions (or any other
  -- field) may have changed and click-resolution reads this on every click.
  session.last_placement = placement
  -- Animation frames are positioned against the placement, so a float opening
  -- over the preview would otherwise leave them painted across it and offset.
  animation.repaint(session)
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
    -- Frame paths died with the renderer's temp directory; the animation
    -- module drops them and re-materializes, while terminal-resident uploads
    -- survive by stable content key.
    animation.renderer_exited()
  end)
  group = vim.api.nvim_create_augroup("md-viewer", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    callback = function(args)
      local session = state.get(args.buf)
      if session then M.schedule(session) end
    end,
  })
  -- A remote provider fills its buffer through BufReadCmd plus an
  -- asynchronous network read, and `:e!` replays that; neither fires
  -- TextChanged. Without this, a preview opened before the content landed
  -- would sit blank until the first edit.
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(args)
      local session = state.get(args.buf)
      if session then M.schedule(session) end
    end,
  })
  -- Neovim's own Visual mode is not usable inside a graphical preview, and
  -- `navigation.lua` says so where it maps `v`/`V` to a *preview* selection
  -- instead. Saying it was not the same as enforcing it: a mouse chord this
  -- plugin had not mapped, or `<C-v>`, still put Neovim in Visual mode over the
  -- surface, where it selects blank cells and paints a highlight across the
  -- image. Reported from Warp as the preview blinking to a blank pane with a
  -- blue rectangle on it -- that rectangle was V-BLOCK.
  --
  -- Excluded for the `cells` backend, whose buffer holds real styled text where
  -- Visual mode and `y` do exactly what a reader would expect.
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = "*:[vV\22sS\19]*",
    callback = function(args)
      local session = state.from_preview(args.buf)
      if not session or session.closed then return end
      if not (session.backend and session.backend.name ~= "cells") then return end
      -- One escape per tick. Without this a stream of modifier-drag events --
      -- each re-entering Visual as fast as the escape leaves it -- would spin.
      if session.leaving_visual then return end
      session.leaving_visual = true
      vim.schedule(function()
        session.leaving_visual = nil
        if session.closed or not vim.api.nvim_buf_is_valid(args.buf) then return end
        if vim.api.nvim_get_current_buf() ~= args.buf then return end
        if not vim.fn.mode():match("^[vV\22sS\19]") then return end
        -- "n", not "m": the buffer-local <Esc> mapping clears the reader's find
        -- and preview selection, and this is not them asking for that. "x" as
        -- well, so the mode is actually back to normal when this returns
        -- rather than whenever the typeahead next drains -- a drag delivers the
        -- next event immediately, and a queued escape would arrive after it.
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      end)
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
  -- Wrapped rather than passed directly: an autocmd callback receives the event
  -- table as its first argument, which `close_all` now reads as `opts`.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function() M.close_all({ blocking = true }) end,
  })
end

-- Exported for `tests/lua/cases/scroll_scale.lua` only.
--
-- The rule this resolves depends on a live SSH capability snapshot, so a test
-- driven through `M.schedule_scroll` would need a preview window, a backend and
-- a renderer to reach three lines of arithmetic. Asserting it directly is what
-- makes "a local session sends exactly what it sent before" a fact rather than
-- an intention.
M._scroll_capture_scale = scroll_capture_scale
M._scroll_settle_delay = scroll_settle_delay

-- Exported for the same reason, and it is the same kind of rule: whether a
-- session may keep resident regions depends on a live capability snapshot, a
-- terminal profile and the transport Neovim is running over. Driving it through
-- `M.open` would need a preview window, a backend and a renderer to reach a
-- handful of conditions, and the one that matters most -- that a *remote
-- document* in a *local* Neovim is not an SSH session -- is asserted directly in
-- `tests/lua/cases/scroll_scale.lua` beside the identical rule for scroll scale.
M._resident_gate = resident_gate
M._settle_options = settle_options
M._resident_key = resident_key
-- Exported so the interaction gates can be asserted directly rather than
-- inferred from whether a scroll happened to produce a placement. The pointer
-- gate in particular refuses *silently* and correctly-looking -- nothing fails,
-- nothing is counted -- which is exactly the shape that reached a real session.
M._try_pan = try_pan

return M
