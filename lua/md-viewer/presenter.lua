local animation = require("md-viewer.animation")
local caret = require("md-viewer.caret")
local config = require("md-viewer.config")
local localrender = require("md-viewer.localrender")
local metrics = require("md-viewer.metrics")
local preview = require("md-viewer.preview")
local renderer = require("md-viewer.renderer")
local state = require("md-viewer.state")

local M = {}
local host

---Connect the orchestration decisions that intentionally remain in controller:
---session validity, occlusion, full teardown, and the first caret request.
---Functions are closures so controller can wire them before its definitions
---are reached and presenter never has to require controller or interaction.
function M.set_host(value)
  assert(type(value) == "table", "presenter host must be a table")
  for _, name in ipairs({ "valid", "update_occlusion", "clear_image", "request_caret" }) do
    assert(type(value[name]) == "function", "presenter host is missing " .. name)
  end
  host = value
end

local function valid(session) return host ~= nil and host.valid(session) end
local function update_occlusion(session) return host.update_occlusion(session) end
local function clear_image(session) return host.clear_image(session) end
local function notify_error(message) vim.notify("md-viewer: " .. tostring(message), vim.log.levels.ERROR) end

---Remove the selection overlay rectangles, if any are on screen. Cheap
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

---Deliver an image to the backend and record the placement/diagnostic
---bookkeeping that goes with it. The single choke point both `controller.refresh`'s
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
  metrics.record_frame(
    session,
    (vim.uv.hrtime() - image_started) / 1000000,
    png_bytes,
    capture_ms,
    capture_scale,
    capture_encoder
  )
  session.image_id = image_id
  session.last_placement = placement
  -- What the frame *now on screen* is a picture of. `applied_scroll_y` was set
  -- from this render's own `meta.scrollY` before we were called, so it is this
  -- frame's position and not a newer request's.
  --
  -- Deliberately not the `clean_image_*` block below, which answers the same
  -- question about the newest *selection-free* frame: a settle frame with a
  -- browser-painted highlight in it supersedes what is on screen without
  -- replacing that cache, so reading `clean_image_scroll_y` as "what is up right
  -- now" would vouch for a frame that is not up -- the exact class of error the
  -- resident invariant exists to stop.
  session.frame_scroll_y = session.applied_scroll_y or 0
  session.frame_revision = session.renderer_revision
  -- Whether this frame has a browser-painted selection baked into it. Any
  -- capture taken while a DOM selection exists does, and `selection_active` is
  -- always updated before the frame is applied (interaction.lua sets it in the
  -- request callback, ahead of display).
  --
  -- The selection overlay composites *over* this frame, so it can only ever
  -- add a highlight -- never remove one. Starting a second gesture on top of a
  -- frame that still shows the first gesture's highlight leaves that
  -- highlight on screen for the whole gesture, which is exactly what the
  -- operator reported on 2026-08-08. `M.restore_clean_base` is how a gesture
  -- gets out of it.
  session.base_selection_painted = session.selection_active == true
  -- The newest frame known to carry no browser-painted selection, kept so a
  -- gesture starting on top of an earlier one can get a clean base back
  -- without a renderer round trip (see `M.restore_clean_base`).
  --
  -- Recorded here, at the one place every full frame passes through, rather
  -- than in `M.refresh` alone. A scroll taken while a selection was up used to
  -- drop this cache and nothing put it back: interact frames never reached
  -- `M.refresh`, so clicking to deselect -- which produces a perfectly good
  -- clean frame -- left the selection overlay disabled until some later
  -- render happened to land with nothing selected. `restore_clean_base`
  -- re-applies through here with `selection_active` still true, so it cannot
  -- overwrite the entry it is reading.
  if not session.base_selection_painted then
    session.clean_image_bytes = image_bytes
    session.clean_image_scroll_y = session.applied_scroll_y or 0
    session.clean_image_revision = session.renderer_revision
    session.clean_image_scale = capture_scale
  end
  -- Any full frame supersedes the selection overlay: a settle frame has the
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
  preview.update_progress(session)
  preview.update_line_numbers(session)
  -- After the caret, because both draw over the base that has just landed and
  -- the animation is the lower of the two layers. `adopt` re-places the current
  -- step in this same tick, so a scroll frame does not drop the animation for
  -- 200ms on its way past.
  animation.adopt(session)
  return true
end

---Is this session rendering beside the terminal? True only while the helper
---is attached and the backend can speak markers; every local branch in this
---file asks this one question.
local function local_mode(session)
  return localrender.active() and session.backend and session.backend.name == "kitty_raw"
end

---`apply_image` for a frame whose pixels live beside the terminal: emit one
---frame marker referencing the surface `(doc, rev, scrollY, viewport, epoch)`
---and do the placement/overlay bookkeeping that goes with a new base frame.
---No pixels, no request, no waiting -- the helper resolves the reference
---against its replica and injects at the marker's stream position.
---
---The scroll position recorded here is the *requested* one; a clamped
---request is reconciled from the render response's achieved `scrollY`, the
---same way `controller.refresh`'s callback consumes `meta.scrollY` today. Scroll-only
---markers have no response, and need none: the clamp arithmetic
---(`scroll_maximum`) already bounded the request against the last known
---document height.
---
---`opts.scale` overrides the reference's capture scale below the viewport's
---device factor: the moving frame of a scroll burst. In local mode the
---pixels never touch the wire, so what the reduced scale buys is not bytes
---but *capture time* -- the helper screenshots sixteen times fewer pixels at
---0.5 than at a Retina 2, and capture time is the whole of the frame cadence
---while a key is held. The settle re-reference restores the device factor,
---so the frame a reader actually looks at is never the reduced one -- the
---same never-soft-at-rest rule `render.scroll_scale` documents.
local function apply_surface(session, revision, scroll_y, viewport, opts)
  preview.reset_surface(session)
  local placement = preview.placement(session.preview_win, session.backend.name)
  session.preview_width_cells = placement.width
  session.preview_height_cells = placement.height
  local scale = opts and opts.scale or viewport.deviceScaleFactor or 1
  local descriptor = {
    width_px = math.floor(viewport.widthPx * scale + 0.5),
    height_px = math.floor(viewport.heightPx * scale + 0.5),
    ref = {
      doc = session.document_id,
      rev = revision,
      scrollY = scroll_y,
      epoch = session.visual_epoch or 0,
      widthPx = viewport.widthPx,
      heightPx = viewport.heightPx,
      scale = scale,
    },
  }
  local ok, image_id, image_err = pcall(function()
    if session.image_id then return session.backend.update_surface(session.image_id, descriptor, placement) end
    return session.backend.show_surface(descriptor, placement)
  end)
  if not ok or not image_id then
    session.render_failed = true
    notify_error(ok and (image_err or "failed to reference local surface") or image_id)
    return false
  end
  session.image_id = image_id
  -- Not yet true: `image_id` here is a reference the marker just carried
  -- toward the helper, not proof any pixels exist on the terminal for it.
  -- The upload is a network round trip in local mode (never true of the
  -- direct path's apply_image, which ships real bytes synchronously in the
  -- same transaction) -- so anything that addresses this id before its own
  -- `presented` notification lands (below, set true) is placing or cropping
  -- around a reference the terminal has nothing to draw for. Measured live
  -- (2026-08-27): the ui_poll's reconcile_placement and the caret's
  -- overlay_apply both fired within one 50ms tick of a fresh open, against
  -- an id whose upload had not arrived, leaving a patchwork of resolved and
  -- unresolved placements on screen until an unrelated later frame overwrote
  -- it clean -- which is why scrolling "fixed" it.
  session.local_frame_confirmed = false
  session.last_placement = placement
  session.local_viewport = viewport
  session.local_marker_frames = (session.local_marker_frames or 0) + 1
  session.frame_scroll_y = scroll_y
  session.frame_revision = revision
  session.applied_scroll_y = scroll_y
  session.viewport_width_px = viewport.widthPx
  session.viewport_height_render_px = viewport.heightPx
  session.viewport_calibration_tier = viewport.tier
  -- Same supersession rules as apply_image, same order: the base under the
  -- overlays has moved, clear after the new frame is referenced, then put the
  -- caret straight back.
  clear_selection_overlay(session)
  M.clear_caret_overlay(session)
  M.place_caret(session)
  preview.update_progress(session)
  preview.update_line_numbers(session)
  return true
end

---Put a selection-free frame back on screen so overlay rectangles have a
---clean base to composite over, using the cached PNG rather than a renderer
---round trip -- this runs on the first frame of a gesture and must not cost
---one.
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

---Display the selection overlay a no-capture `selection_preview` result
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
  -- "Is there a screen to composite over", not "is there a frame this session
  -- owns": a resident screen is bands cropped out of chunks and deliberately
  -- carries no `image_id`. The `overlay_apply` call below still passes
  -- `session.image_id`, which is nil there and which the backend now reads as
  -- "size the sheet from the placement".
  if not (state.screen_up(session) and session.last_placement) then return false end
  -- Local mode must not upload or place a tint sheet over a frame reference
  -- whose pixels have not resolved yet. Besides drawing against an unknown
  -- image id, sheet uploads used to enter the helper's frame-supersession slot
  -- and evict the pending base frame outright. The injector now distinguishes
  -- the two upload kinds, but this guard still prevents the invalid overlay.
  if local_mode(session) and not session.local_frame_confirmed then return false end
  if type(result) ~= "table" or type(result.rects) ~= "table" then return false end
  if result.rectsTruncated then return false end
  if result.contentRevision ~= session.renderer_revision then return false end
  -- The rects were measured at the page scroll the renderer reports; the base
  -- image on screen shows `frame_scroll_y`, not `applied_scroll_y` -- a caret
  -- motion that scrolls bumps `applied_scroll_y` the instant its response
  -- lands, before the scroll capture it triggered has actually replaced the
  -- frame on screen, so checking against it here would pass during that gap
  -- and composite the highlight over the wrong, stale pixels. Any
  -- disagreement with what is actually painted means the highlight would
  -- land on the wrong text.
  if type(result.scrollY) == "number" and math.abs(result.scrollY - (session.frame_scroll_y or 0)) > 0.5 then
    return false
  end
  if update_occlusion(session) then
    clear_image(session)
    session.refresh_deferred = true
    return false
  end
  local started = vim.uv.hrtime()
  local sheet_png = nil
  if local_mode(session) then
    -- Never bytes here: the helper synthesizes the sheet from the reference
    -- the backend completes (tint, size, margin), so "need_sheet" cannot
    -- occur in local mode and no PNG rides any response.
    sheet_png = { ref = true }
  elseif type(result.overlaySheetPng) == "string" and result.overlaySheetPng ~= "" then
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
---The same `overlay_apply` the selection highlight uses, in its own rect set, so the
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
---backend, or the terminal profile), nothing on the pane at all, or the caret
---has scrolled out of view. The terminal's own cursor is left visible where
---there is no caret to draw at all; a caret that is merely off screen keeps it
---hidden. See `preview.hide_cursor`, and the nil branch below.
function M.display_caret_overlay(session, tint, sheet_png)
  if not valid(session) or session.backend.name == "cells" then return false end
  local backend = session.backend
  if not (backend.overlay_apply and backend.overlay_supported and backend.overlay_supported()) then return false end
  -- Either model's screen will do; see `display_selection_overlay`. Without
  -- this a resident preview had no caret at all except when `show_cached`
  -- happened to have restored a frame for it to sit on.
  if not (state.screen_up(session) and session.last_placement) then return false end
  -- Local mode: session.image_id may still be an unresolved reference (see
  -- apply_surface). Cropping the caret's tint out of it before its own
  -- upload lands addresses an id the terminal has nothing to draw for.
  -- Neovim's own cursor stays visible in the meantime, same as any other
  -- "cannot draw the caret yet" case this function already returns false for.
  if local_mode(session) and not session.local_frame_confirmed then return false end
  local rect = caret.rect(session)
  if not rect then
    M.clear_caret_overlay(session)
    -- A caret that is merely scrolled out of view is still the reader's
    -- position, and Neovim's own cursor is not a stand-in for it: it sits on
    -- the cell `caret.shadow_cursor` last parked it on, the scroll has moved
    -- the text out from under it, and nothing moves it again until the next
    -- motion -- the preview window itself never scrolls. Restoring here put a
    -- one-cell bar in the middle of unrelated prose for the whole of every
    -- scroll past the caret, which is what was reported on 2026-08-29. Only a
    -- session with no caret at all has nothing better to offer.
    if not (session and session.caret_rect) then preview.restore_cursor() end
    return false
  end
  session.caret_tint = tint or session.caret_tint
  if not session.caret_tint then return false end
  -- Same rule as the selection overlay: local mode passes a reference and the
  -- helper synthesizes the caret sheet beside the terminal.
  if local_mode(session) then sheet_png = { ref = true } end
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
  -- The block just moved, so the shadow underneath it has to move too.
  -- `caret.set_rect` shadows on a motion, but a motion that also scrolled
  -- shadows against the frame still on screen -- `caret.rect` is deliberately
  -- frame-relative -- and an ordinary scroll is not a motion at all. This is
  -- the one place that knows which cell the block landed on, which is the only
  -- cell the shadow has any business being on.
  caret.shadow_cursor(session, rect)
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
    -- The shadow follows the block wherever there is one -- `display_caret_overlay`
    -- parks it on the cell it drew into. Where the overlay cannot be drawn the
    -- terminal's own cursor *is* the caret, so it still has to follow the
    -- scroll, and nothing else would move it.
    if not M.display_caret_overlay(session) then caret.shadow_cursor(session) end
    return
  end
  if not (session.renderer_revision and session.last_placement) then return end
  host.request_caret(session)
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
---is the fetch half `controller.refresh`'s render/capture path gets from
---`renderer.lua`; the display half is `apply_image`, shared verbatim.
function M.display_interact_result(session, result)
  if not valid(session) or session.backend.name == "cells" then return end
  if type(result) ~= "table" then return end
  if local_mode(session) then
    -- No PNG crossed the socket and none was captured. The mutation lives in
    -- the helper's DOM behind the visual epoch its response carried (recorded
    -- by interaction.lua's funnel before this ran), so displaying it is one
    -- frame marker: the new epoch makes the old surface unresolvable and
    -- forces the capture beside the terminal.
    if result.contentRevision and result.contentRevision ~= session.renderer_revision then return end
    if type(result.scrollY) == "number" then
      if math.abs(result.scrollY - (session.applied_scroll_y or 0)) > 0.5 then session.progress_basis = "viewport" end
      session.applied_scroll_y = result.scrollY
      session.scroll_y = result.scrollY
    end
    if update_occlusion(session) then
      clear_image(session)
      session.refresh_deferred = true
      return
    end
    if session.renderer_revision and session.local_viewport then
      apply_surface(session, session.renderer_revision, session.scroll_y or 0, session.local_viewport)
    end
    return
  end
  if type(result.pngPath) ~= "string" then return end
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
    if math.abs(result.scrollY - (session.applied_scroll_y or 0)) > 0.5 then session.progress_basis = "viewport" end
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

M.apply_image = apply_image
M.apply_surface = apply_surface
M.local_mode = local_mode

return M
