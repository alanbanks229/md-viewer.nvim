local backends = require("md-viewer.backends")
local caret = require("md-viewer.caret")
local cellpixels = require("md-viewer.cellpixels")
local config = require("md-viewer.config")
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
local lanes = require("md-viewer.lanes")
local resident_controller = require("md-viewer.resident_controller")
local resident_session = require("md-viewer.resident_session")
local localrender = require("md-viewer.localrender")
local history = require("md-viewer.history")
local occlusion = require("md-viewer.occlusion")
local presenter = require("md-viewer.presenter")

local M = {}

local apply_image = presenter.apply_image
local apply_surface = presenter.apply_surface
local local_mode = presenter.local_mode
local begin_resident = resident_controller.begin_resident
local draw_resident = resident_controller.draw_resident
local pump_resident = resident_controller.pump_resident
local clear_image = occlusion.clear_image
local clear_raw_sessions = occlusion.clear_raw_sessions
local each_session = occlusion.each_session
local must_hide = occlusion.must_hide
local reconcile_occlusion = occlusion.reconcile
local reconcile_placement = occlusion.reconcile_placement
local refresh_raw_sessions = occlusion.refresh_raw_sessions
local start_ui_poll = occlusion.start_ui_poll

M.clear_selection_overlay = presenter.clear_selection_overlay
M.restore_clean_base = presenter.restore_clean_base
M.display_selection_overlay = presenter.display_selection_overlay
M.display_caret_overlay = presenter.display_caret_overlay
M.place_caret = presenter.place_caret
M.clear_caret_overlay = presenter.clear_caret_overlay
M.display_interact_result = presenter.display_interact_result
M.pump_resident = resident_controller.pump_resident
M.draw_resident = resident_controller.draw_resident
M.begin_resident = resident_controller.begin_resident

local function valid(session)
  return session
    and not session.closed
    and state.is_active(session)
    and type(session.source_buf) == "number"
    and type(session.preview_buf) == "number"
    and type(session.preview_win) == "number"
    and vim.api.nvim_buf_is_valid(session.source_buf)
    and vim.api.nvim_buf_is_valid(session.preview_buf)
    and vim.api.nvim_win_is_valid(session.preview_win)
    and vim.api.nvim_win_get_buf(session.preview_win) == session.preview_buf
end

local function markdown(session) return table.concat(vim.api.nvim_buf_get_lines(session.source_buf, 0, -1, false), "\n") end

local function notify_error(message) vim.notify("md-viewer: " .. tostring(message), vim.log.levels.ERROR) end

local function current_session(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local session = state.get(buf)
    or state.from_preview(buf)
    or state.from_source_win(vim.api.nvim_get_current_win())
    or state.visible_in_tab()
  return session and session.pane and session.pane.active or session
end

local history_host = {
  current_session = current_session,
  valid = valid,
  schedule = function(...) return M.schedule(...) end,
  retarget = function(...) return M.retarget(...) end,
}

presenter.set_host({
  valid = valid,
  must_hide = must_hide,
  clear_image = clear_image,
  request_caret = function(session) interaction.caret_motion(session, "none", "forward", 1) end,
})

interaction.set_host({
  retarget = function(...) return M.retarget(...) end,
  schedule_scroll = function(...) return M.schedule_scroll(...) end,
})

resident_controller.set_host({
  valid = valid,
  markdown = markdown,
  refresh = function(session) return M.refresh(session) end,
})

---Put back on screen whatever this session already has, without a renderer
---round trip. For the viewport model that is the cached PNG; for the resident
---model it is a re-crop of chunks the terminal is still holding, which is
---cheaper still.
---
---Both models are handled here rather than at the six call sites, because every
---one of them -- the 50ms poll, WinEnter/FocusGained/VimResume, CompleteDone,
---WinClosed, WinNew, a resize -- means the same thing: the pane can be drawn
---again, so put something on it. A resident session that fell through to the PNG
---branch re-uploaded a full-viewport frame the resident compositor knows nothing
---about, and left it z-fighting the bands by image id.
local function show_cached(session)
  if not valid(session) or not session.backend.is_graphical then return false end
  if must_hide(session) then
    clear_image(session)
    return false
  end
  if session.render_path == "resident" and session.resident then
    draw_resident(session)
    -- Same catch-up the cached branch does below, and for the same reason: a
    -- render dropped while the pane could not be drawn left the document a
    -- frame behind the source, and an idle preview issues no renders.
    if session.refresh_deferred then
      session.refresh_deferred = false
      M.schedule(session, 0)
    end
    -- True whatever `draw_resident` decided. It has already put up a screen, or
    -- kept the bootstrap frame, or gone blank on purpose and said so in the
    -- winbar -- and in none of those cases does the caller's fallback (a full
    -- document re-render) help. That re-render is also a content admission,
    -- which voids an in-flight chunk -- deliberately now (it re-lays out the
    -- page the chunk was cut from), where it used to be a side effect of one
    -- serial shared by everything.
    return true
  end
  if not session.last_image_bytes then return false end
  preview.stop_loading(session)
  preview.reset_surface(session)
  local placement = preview.placement(session.preview_win, session.backend)
  local ok, image_id, image_err = pcall(session.backend.show, session.last_image_bytes, placement)
  if not ok or not image_id then
    session.render_failed = true
    notify_error(ok and (image_err or "failed to display cached image") or image_id)
    return false
  end
  session.image_id = image_id
  session.last_placement = placement
  preview.update_line_numbers(session)
  -- Unknown, and said so. `last_image_bytes` carries no record of the position
  -- it was captured at, and the page may well have scrolled since, so nothing
  -- here can vouch for this frame the way `apply_image` vouches for its own.
  -- `resident_controller`'s `holding_position` refuses on nil, which is the
  -- answer we want.
  session.frame_scroll_y, session.frame_revision = nil, nil
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

occlusion.set_host({
  valid = valid,
  show_cached = show_cached,
  draw_resident = draw_resident,
  schedule = function(...) return M.schedule(...) end,
})

---A chunk capture never re-enters the resident bootstrap: it *is* the warm-up.
local function render_options_is_chunk(render_options)
  return render_options ~= nil and render_options.resident_chunk ~= nil
end

function M.refresh(session, render_options)
  local explicit = session == nil
  session = session or current_session()
  if not valid(session) then return end
  if explicit then session.render_epoch = (session.render_epoch or 0) + 1 end
  if not session.backend.is_graphical then
    session.backend.render(session.preview_buf, markdown(session))
    session.dirty = false
    if render_options and render_options.on_complete then render_options.on_complete(false, nil) end
    return
  end
  session.render_failed = false
  if must_hide(session) then
    clear_image(session)
    -- Nothing was captured, so the cached PNG stays a frame behind whatever
    -- triggered this refresh. show_cached() replays it once the image can be
    -- displayed again.
    session.refresh_deferred = true
    if render_options and render_options.on_complete then render_options.on_complete(false, nil) end
    return
  end
  -- While a helper attach is still settling, rendering would race it onto
  -- the direct path -- spawning this host's Chromium and shipping the full
  -- PNG local mode exists to avoid (window events around the preview split
  -- opening are exactly when this fires). Both attach outcomes re-render:
  -- success through the "attached" listener, failure through M.open's
  -- continuation.
  if
    localrender.enabled()
    and session.backend.supports_local_markers
    and localrender.status().phase == "connecting"
  then
    session.refresh_deferred = true
    if render_options and render_options.on_complete then render_options.on_complete(false, nil) end
    return
  end
  -- A render of the document's content, as opposed to a chunk capture, has
  -- right of way over the warm-up while it is in flight. The lane rules mean a
  -- chunk can no longer stale a render outright, but the queueing is still
  -- worth keeping: a chunk capture is 116-373ms of renderer time and about a
  -- second of wire, spent ahead of an edit the reader is waiting to see.
  -- `pump_resident` waits; the callback below restarts it either way.
  local content_render = not render_options_is_chunk(render_options)
  if content_render then session.content_render_in_flight = true end
  if local_mode(session) and content_render then
    -- Local rendering owns scrolling outright, so a session that selected the
    -- resident path before the helper attached is demoted the first time it
    -- renders locally -- two scroll owners is the reproducibility problem
    -- select_path exists to prevent.
    if session.render_path == "resident" then resident_session.demote(session, "local render owns scrolling") end
    -- The frame marker leaves in the same tick as the request: the revision
    -- is computed here, so pixels never wait for any response. The helper
    -- holds the marker until its own render resolves the reference.
    local revision = renderer.content_revision(session)
    local viewport = preview.viewport(session.preview_win, session.backend)
    apply_surface(session, revision, session.scroll_y or 0, viewport)
  end
  renderer.request(session, markdown(session), render_options, function(result, err, stale)
    if content_render then session.content_render_in_flight = false end
    local function finish()
      if render_options and render_options.on_complete then render_options.on_complete(stale, err) end
      -- The warm-up deferred to this render and has to be told it may go on,
      -- whatever the outcome. The success path re-pumps through
      -- `begin_resident`; this covers the error and stale exits, which would
      -- otherwise leave the queue parked forever.
      if content_render and session.render_path == "resident" and session.resident then
        vim.schedule(function() pump_resident(session) end)
      end
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
    session.dirty = false
    -- A selection captured against older content must never be displayed or
    -- reused against newer content -- that would be silent corruption in a
    -- copy operation. renderer.lua has already updated session.renderer_revision
    -- by this point, so this is the first tick new content can be observed on.
    if session.selection_content_revision and session.selection_content_revision ~= session.renderer_revision then
      interaction.forget_selection(session)
    end
    local newer_scroll_pending = render_options and render_options.scroll_frame and session.scroll_render_pending
    -- Local scrolls are markers, not requests, so `scroll_render_pending`
    -- never marks them; the position itself is the record. A `scroll_y` that
    -- moved since this render was issued means newer frames are already on
    -- their way to the glass, and this response must not snap back to it.
    if meta.local_render then
      newer_scroll_pending = math.abs((session.scroll_y or 0) - (meta.requestedScrollY or 0)) > 0.5
    end
    session.latest_blocks = meta.blocks
    session.latest_lines = meta.lines
    session.document_height_px = meta.documentHeightPx
    session.viewport_height_px = meta.viewportHeightPx
    -- Preserve a newer requested position while showing this completed frame.
    -- The next capture then uses the desired position instead of snapping back
    -- to the older frame's scrollY.
    if not newer_scroll_pending then session.scroll_y = meta.scrollY end
    if not (meta.local_render and newer_scroll_pending) then session.applied_scroll_y = meta.scrollY end
    session.last_layout_reused = meta.layoutReused == true
    session.last_markdown_reused = meta.markdownReused == true
    session.last_capture_scale = meta.captureScale
    -- A local render carries no image and moves no PNG bytes; the field keeps
    -- its last direct-path value rather than lying with a zero.
    if result.image or meta.pngBytes then session.last_png_bytes = meta.pngBytes or #result.image end
    -- The helper's visual epoch, named by every frame reference. Selection
    -- and find mutations bump it (their responses carry the new value through
    -- interaction.lua), which is how DOM changes invalidate local surfaces
    -- without a content revision.
    if type(meta.visualEpoch) == "number" then session.visual_epoch = meta.visualEpoch end
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
    -- How many of them the renderer has given up on. Recorded but never acted
    -- on: `animationsIncomplete` going false is what stops the retry above, and
    -- a non-zero count beside it is the difference between "these images could
    -- not be measured" and "this document has none" -- which :MdViewerDebug had
    -- no way to tell apart.
    session.animation_geometry_unmeasured = tonumber(meta.animationsUnmeasured) or 0
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
    -- A render changes progress's denominator and the line-number geometry
    -- even when the caret itself has not moved -- an edit can shrink or grow
    -- the document out from under a caret sitting exactly where it was. Both
    -- branches below have by now set every field either update reads, so one
    -- call here covers the local-render early return and direct-render tail.
    preview.update_progress(session)
    preview.update_line_numbers(session)
    if meta.local_render then
      -- The frame itself went up when its marker was emitted, back in the
      -- tick that issued this request; this response only settles what the
      -- marker could not know. The achieved scroll is the one reconciliation
      -- that matters: a clamped request means the frame on glass shows the
      -- clamp, and every later marker must be built from it -- unless newer
      -- scroll markers already superseded this frame, in which case theirs is
      -- the position on glass, not this one's.
      if not newer_scroll_pending and type(meta.scrollY) == "number" then session.frame_scroll_y = meta.scrollY end
      session.frame_revision = session.renderer_revision
      vim.schedule(function()
        if valid(session) then interaction.resolve_pending_obsidian_anchor(session) end
      end)
      finish()
      return
    end
    session.last_image_bytes = result.image
    -- A capture taken while a DOM selection was live has it painted in, so the
    -- cached clean base cannot be this frame. `apply_image` records the
    -- replacement whenever a selection-free frame does reach the screen.
    if session.selection_active then session.clean_image_bytes = nil end
    if must_hide(session) then
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
    -- The render that measured the document is also what the chunk plan is
    -- derived from, and its frame is the reader's own position rather than a
    -- remembered one -- so it doubles as first paint while the chunks warm.
    -- `draw_resident` keeps it up for exactly as long as that is true (see
    -- `holding_position` in resident_controller); it used to blank it one call
    -- later, which is what the reader on a slow link saw as a flash of "waiting
    -- for this page" over an empty pane. After this, a resident session captures
    -- chunks and nothing else.
    if session.render_path == "resident" and not render_options_is_chunk(render_options) then
      begin_resident(session, meta)
    end
    vim.schedule(function()
      if valid(session) then interaction.resolve_pending_obsidian_anchor(session) end
    end)
    finish()
  end)
end

function M.schedule(session, delay, timer_name, render_options)
  if not valid(session) then return end
  debounce.call(session, timer_name or "render_timer", delay or session.config.render.debounce_ms, function()
    if valid(session) then M.refresh(session, render_options) end
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

---`scroll_capture_scale` for local-render mode, kept separate rather than
---sharing the `terminal.detect().ssh` branch above: `ssh_scroll_scale`
---trades sharpness for *wire bytes*, and local mode never puts a captured
---frame on the wire regardless of resolution -- only a ~0.3-1 KB marker
---crosses SSH either way. Reusing it here bought nothing and cost
---sharpness for free. Measured on the SSM reference host (2026-08-27): a full-resolution
---local capture (device scale 2) costs 31-52ms against 15-34ms at half scale
---(`--status` -> `replica.timing.captureDuration`) -- a ~15-20ms difference,
---not the ~85-120ms AWS SSM round trip `schedule_scroll` no longer waits on.
---Full size by default; an explicit `render.scroll_scale` still applies, for
---a laptop where local capture time itself is the constraint.
local function local_scroll_capture_scale(render)
  if not render.fast_scroll then return nil, "render.fast_scroll=false (no moving frame)" end
  if render.scroll_scale ~= nil then return render.scroll_scale, "explicit override (render.scroll_scale)" end
  return nil, "local mode (full size -- no wire bytes to trade sharpness for)"
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

function M.schedule_scroll(session)
  -- Local rendering: a scroll is one marker naming the new position -- no
  -- renderer request, no capture, no settle timer, and nothing for the
  -- response cycle the rejected 2026 experiment serialized into every frame.
  -- The helper resolves the reference from its surface cache or captures
  -- beside the terminal; superseded markers die in the injector, so there is
  -- no backpressure to manage here either. Above the resident branch on
  -- purpose: local render owns scrolling wherever both could apply.
  if local_mode(session) then
    if must_hide(session) then
      clear_image(session)
      session.refresh_deferred = true
      return
    end
    if not (session.image_id and session.frame_revision and session.local_viewport) then
      -- Nothing referenceable is up yet (first render still in flight, or the
      -- frame was cleared): a full refresh emits its own marker.
      M.schedule(session, 0)
      return
    end
    -- The moving/settle split, carried into local mode but scaled by
    -- `local_scroll_capture_scale`, not the direct path's SSH-gated one: see
    -- that function's comment for why local mode does not trade sharpness
    -- for bytes it never spends. `scroll_settle_delay` (still shared) decides
    -- when the settle frame replaces the moving one.
    local render = session.config.render
    local moving, scale_source = local_scroll_capture_scale(render)
    local viewport = session.local_viewport
    if moving and moving >= (viewport.deviceScaleFactor or 1) then
      moving, scale_source = nil, "factor is not below the device scale (full size)"
    end
    session.scroll_scale = moving
    session.scroll_scale_source = scale_source
    -- Every scroll emits a marker immediately -- no gate on the `presented`
    -- ack. That ack crosses the same link a marker does: on AWS SSM
    -- (~1 MB/s, ~100ms RTT measured on the SSM reference host 2026-08-27), waiting for it
    -- capped throughput at one round trip per frame (p50 116ms, ~8-9
    -- frames/sec) regardless of capture cost (15-50ms measured on the same
    -- session's `--status`). The backpressure this used to buy is already
    -- provided on the other end: replica.js's `scheduleSurface`/`pumpCapture`
    -- hold one capture want per document and drop a superseded one before it
    -- starts (`capturesSupersededBeforeStart`), which is exactly rc9's
    -- problem (517 captures for 206 surfaces -- every miss dispatched into
    -- the queue) without rc9's fix undone. Markers now cost only the
    -- helper's own capture rate, not a round trip on top of it.
    apply_surface(
      session,
      session.frame_revision,
      session.scroll_y or 0,
      viewport,
      moving and { scale = moving } or nil
    )
    if moving then
      local settle_ms, settle_source = scroll_settle_delay(render)
      session.scroll_settle_ms = settle_ms
      session.scroll_settle_source = settle_source
      debounce.call(session, "scroll_settle_timer", settle_ms, function()
        if not valid(session) or not local_mode(session) then return end
        if not (session.image_id and session.frame_revision and session.local_viewport) then return end
        apply_surface(session, session.frame_revision, session.scroll_y or 0, session.local_viewport)
      end)
    end
    return
  end
  -- The whole point of the feature: no renderer request, no capture, no pixels
  -- on the wire. The document is already in the terminal and a scroll is a
  -- placement.
  if session.render_path == "resident" and session.resident then
    draw_resident(session)
    return
  end
  local render = session.config.render
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
    M.schedule(session, settle_ms, "scroll_settle_timer", {
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

-- `stop_opts` is forwarded to `process.stop` for the one call that actually
-- stops the renderer -- closing the last session -- so that `close_all` at
-- VimLeavePre can ask for the blocking teardown. Nil for every ordinary close.
local function delete_preview_buffer(session)
  if session.preview_buf and vim.api.nvim_buf_is_valid(session.preview_buf) then
    pcall(vim.api.nvim_buf_delete, session.preview_buf, { force = true })
  end
end

local SESSION_TIMER_NAMES = {
  "render_timer",
  "resize_timer",
  "scroll_settle_timer",
  "cursor_scroll_timer",
  "animation_geometry_timer",
  "remote_image_timer",
  "ui_poll_timer",
  "selection_debounce_timer",
  "selection_settle_timer",
  "selection_idle_settle_timer",
}

local function close_session_timers(session)
  for _, name in ipairs(SESSION_TIMER_NAMES) do
    debounce.close(session, name)
  end
end

local function release_document(session, forget_renderer, keep_buffer)
  if not session or session.closed then return end
  session.closed = true
  lanes.invalidate(session)
  close_session_timers(session)
  preview.stop_loading(session)
  preview.restore_cursor()
  caret.forget(session)
  -- Before clear_image: these are megabytes of terminal memory that iTerm2 does
  -- not evict on its own, and the session is the only thing that knows the ids.
  resident_session.release(session)
  clear_image(session)
  session.last_image_bytes = nil
  session.clean_image_bytes = nil
  interaction.forget(session)
  interaction.forget_selection(session)
  animation.forget(session)
  if forget_renderer then renderer.forget(session) end
  state.remove_document(session)
  if not keep_buffer then delete_preview_buffer(session) end
end

local function close_session(session, stop_opts)
  if not session then return end
  local pane = session.pane
  if not pane or pane.closed then return end
  local documents = vim.list_slice(pane.documents)
  -- The active document owns every heavy placement, so release it first while
  -- its window/buffer association is still intact.
  table.sort(documents, function(a) return a == pane.active end)
  for _, document in ipairs(documents) do
    -- Deleting the buffer currently displayed in an adopted window can make
    -- Neovim close that window before its original buffer is restored.
    release_document(document, true, true)
  end
  preview.restore_cursor()
  if pane.owned then
    if pane.preview_win and vim.api.nvim_win_is_valid(pane.preview_win) then
      pcall(vim.api.nvim_win_close, pane.preview_win, true)
    end
  else
    preview.restore_adopted(pane)
  end
  for _, document in ipairs(documents) do
    delete_preview_buffer(document)
  end
  preview.clear_clicks(pane)
  state.remove_pane(pane)
  if not next(state.panes()) then process.stop(stop_opts) end
  mouse.detach_if_unused()
end

function M.close(buf)
  local session = current_session(buf)
  close_session(session)
end

function M.close_all(opts)
  local copy = {}
  for _, pane in pairs(state.panes()) do
    copy[#copy + 1] = pane.active
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
  history.init(session)
  session.backend, session.backend_reason = backend, reason
  -- Decided once, here, and never again for the life of this session. A
  -- preview that switches rendering model mid-scroll is one whose behaviour
  -- nobody can reproduce; the only later move is a one-way demotion.
  session.render_path, session.render_path_reason = resident_session.select_path(session)
  session.preview_buf = preview.create_buffer(session)
  local adopt_win
  local siblings = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= source_win and vim.api.nvim_win_get_buf(win) == source_buf then siblings[#siblings + 1] = win end
  end
  if #siblings == 1 and not vim.wo[source_win].winfixbuf then
    adopt_win = source_win
    source_win = siblings[1]
    session.source_win = source_win
    session.pane.source_win = source_win
  end
  session.preview_buf, session.preview_win = preview.open(position, session, adopt_win)
  -- Size the caret surface now that the split has been created and resized;
  -- `preview.open` cannot do it itself, since the placement it measures needs
  -- the window handle this line is what assigns.
  preview.reset_surface(session)
  if backend.is_graphical then
    preview.start_loading(session)
    navigation.attach(session, M.navigate)
    mouse.attach(M.navigate)
  end
  if not adopt_win then vim.api.nvim_set_current_win(source_win) end
  if localrender.enabled() and backend.supports_local_markers and not localrender.active() then
    -- The first render waits for the attach to settle rather than racing it:
    -- losing the race would spawn this host's Chromium and ship one full PNG
    -- over the very link local mode exists to spare. On success the
    -- "attached" listener refreshes every open session, this one included;
    -- failure renders on this host and says so once.
    localrender.attach(function(ok, reason)
      if ok then return end
      vim.notify(
        ("md-viewer: local rendering unavailable (%s); rendering on this host"):format(reason),
        vim.log.levels.WARN
      )
      -- Every raw session, not just this one: refreshes deferred while the
      -- attach was settling have no other continuation on the failure path.
      each_session(function(deferred)
        if deferred.backend.supports_local_markers then M.refresh(deferred) end
      end)
    end)
  else
    M.refresh(session)
  end
  if start_ui_poll then start_ui_poll(session) end
  return session
end

---Create or reuse a stable preview document for `new_buf`, then activate it in
---this pane without displaying it in the editable source window.
---
---`record` (default true) appends the destination to this preview's history.
---The back/forward commands pass false: they are *moving through* the history,
---not extending it, and appending there would make "back" unable to ever leave
---the last two documents.
function M.retarget(session, new_buf, record, restore_scroll, pending_obsidian_anchor)
  if not valid(session) or not session.backend then return false end
  local pane = session.pane
  local target = state.document(pane, new_buf)
  if not target then
    target = state.create_document(pane, new_buf)
    target.backend, target.backend_reason = session.backend, session.backend_reason
    target.render_path, target.render_path_reason = session.render_path, session.render_path_reason
    target.preview_buf = preview.create_buffer(target)
    if target.backend.is_graphical then navigation.attach(target, M.navigate) end
  end
  if type(restore_scroll) == "number" then
    target.scroll_y = restore_scroll
    target.applied_scroll_y = restore_scroll
  end
  target.pending_obsidian_anchor = pending_obsidian_anchor
  if record ~= false then history.push(session, new_buf) end
  return M.activate_document(target, { align_history = record == false })
end

local function deactivate_document(session)
  if not session or session.closed then return end
  -- Every callback already carries a lane ticket; voiding them all is the pane
  -- activation epoch at the document boundary and makes late frames stale.
  lanes.invalidate(session)
  close_session_timers(session)
  preview.stop_loading(session)
  interaction.forget(session)
  resident_session.release(session)
  clear_image(session)
  animation.forget(session)
  session.last_image_bytes = nil
  session.clean_image_bytes = nil
  session.last_png_bytes = nil
  session.content_render_in_flight = false
  session.scroll_render_in_flight = false
  session.scroll_render_pending = false
  session.active = false
end

---Activate one stable preview document without touching the source window.
function M.activate_document(session, opts)
  opts = opts or {}
  if not session or session.closed or not session.pane or session.pane.closed then return false end
  local pane = session.pane
  if pane.active == session and valid(session) then
    preview.update_title(session)
    return true
  end
  local old = pane.active
  if old and old ~= session then deactivate_document(old) end
  state.activate(session)
  session.backend = session.backend or (old and old.backend)
  session.backend_reason = session.backend_reason or (old and old.backend_reason)
  session.render_path = session.render_path or (old and old.render_path)
  session.render_path_reason = session.render_path_reason or (old and old.render_path_reason)
  session.preview_win = pane.preview_win
  session.source_win = pane.source_win
  if not preview.show_document(session) then return false end
  if opts.align_history ~= false then history.align(session) end
  preview.reset_surface(session)
  preview.update_title(session)
  if session.backend and session.backend.is_graphical then preview.start_loading(session) end
  M.refresh(session)
  if start_ui_poll then start_ui_poll(session) end
  return true
end

local function pane_session(session)
  session = session or current_session()
  return session and session.pane and session.pane.active or nil
end

function M.tab_next(session)
  session = pane_session(session)
  if not session then return false end
  local docs, current = session.pane.documents, 1
  for index, document in ipairs(docs) do
    if document == session then current = index end
  end
  return M.activate_document(docs[(current % #docs) + 1])
end

function M.tab_previous(session)
  session = pane_session(session)
  if not session then return false end
  local docs, current = session.pane.documents, 1
  for index, document in ipairs(docs) do
    if document == session then current = index end
  end
  return M.activate_document(docs[((current - 2) % #docs) + 1])
end

function M.tab_close(session)
  session = session or current_session()
  if not session or session.closed or not session.pane then return false end
  local pane = session.pane
  if #pane.documents == 1 then
    close_session(session)
    return true
  end
  local index = 1
  for candidate, document in ipairs(pane.documents) do
    if document == session then index = candidate end
  end
  local was_active = pane.active == session
  if was_active then deactivate_document(session) end
  release_document(session, true, was_active)
  if was_active then
    local target = pane.documents[math.min(index, #pane.documents)]
    local activated = M.activate_document(target)
    delete_preview_buffer(session)
    return activated
  end
  preview.update_title(pane.active)
  return true
end

function M.reveal_source(session)
  session = pane_session(session)
  if not session then
    vim.notify("md-viewer: no preview open", vim.log.levels.WARN)
    return false
  end
  local pane, win = session.pane, session.pane.source_win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    local preview_win = pane.preview_win
    if not (preview_win and vim.api.nvim_win_is_valid(preview_win)) then return false end
    win = vim.api.nvim_open_win(session.source_buf, true, { split = "left", win = preview_win })
    vim.wo[win].winfixbuf = false
    pane.source_win = win
  end
  if vim.wo[win].winfixbuf then
    vim.notify("md-viewer: source window has 'winfixbuf' set", vim.log.levels.WARN)
    return false
  end
  vim.api.nvim_win_set_buf(win, session.source_buf)
  pane.source_win = win
  for _, document in ipairs(pane.documents) do
    document.source_win = win
  end
  vim.api.nvim_set_current_win(win)
  return true
end

M.history_init = history.init
M.history_push = history.push

function M.history_back(session) history.back(session, history_host) end

function M.history_forward(session) history.forward(session, history_host) end

function M.toggle(position)
  local session = current_session()
  if session then
    close_session(session)
  else
    M.open(position)
  end
end

---Switch every preview into the requested line-number mode. Repeating the
---already-active mode turns numbering off; invoking the other named command
---switches modes without passing through off.
function M.toggle_line_numbers(mode)
  assert(mode == "absolute" or mode == "relative", "line-number mode must be absolute or relative")
  -- Through config.set_runtime, not by writing into `config.get()`. That table
  -- is the user's: a keystroke editing it left nothing able to tell an option
  -- they set from one a command changed, and skipped `validate` on the way
  -- past. The runtime layer is validated, is re-applied to every session's
  -- snapshot here, and reaches previews opened later -- which is what "switch
  -- every preview" has always meant.
  local current = config.effective("preview.line_numbers")
  config.set_runtime("preview.line_numbers", current == mode and "off" or mode)
  each_session(function(session) preview.update_line_numbers(session) end)
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
  if not valid(session) or not session.backend.is_graphical then return false end
  local cfg = session.config
  next_scroll = math.max(0, math.min(scroll_maximum(session), next_scroll))
  if math.abs(next_scroll - (session.scroll_y or 0)) < 1 then return false end
  session.scroll_y = next_scroll
  session.progress_basis = "viewport"
  session.manual_scroll_until = vim.uv.now() + cfg.sync.manual_scroll_hold_ms
  if cfg.sync.preview_to_source then sync.update_source_from_scroll(session, next_scroll) end
  M.schedule_scroll(session)
  return true
end

function M.scroll_by(session, delta_px)
  if not valid(session) or not session.backend.is_graphical then return false end
  return M.scroll_to(session, (session.scroll_y or 0) + delta_px)
end

function M.navigate(session, action, count)
  if not valid(session) or not session.backend.is_graphical then return end
  local cfg = session.config
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

---The session a helper notification names. Notifications carry the document
---id because the helper knows nothing smaller; nil for a document whose
---session has since closed, which is a stale notification and not an error.
local function session_by_document(doc)
  for _, session in pairs(state.all()) do
    if session.document_id == doc then return session end
  end
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

---Install the session-lifetime listeners that are not autocmds: the renderer
---process's exit, and local rendering's four helper events. `autocmds.lua`
---owns everything registered against Neovim's own events; these two sources
---are md-viewer's own, and what they do is session bookkeeping rather than
---wiring, so they stay here.
function M.setup_listeners()
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
  -- Local rendering's remote half. The socket directories exist in every
  -- mode because the helper's `ssh -R` bind happens before this plugin runs
  -- in the session -- the directory has to be there from a previous life.
  -- The listeners are session-lifetime, like process.on_exit above.
  localrender.ensure_socket_dirs()
  -- A frame reached the glass beside the terminal. This is the only moment
  -- Lua can know pixels are actually up, so it is what retires the loading
  -- indicator that a direct render would have retired at apply_image.
  localrender.on("presented", function(event)
    local session = session_by_document(event.doc)
    if not session or not valid(session) then return end
    session.local_presented_count = (session.local_presented_count or 0) + 1
    session.local_last_presented_scroll_y = event.scrollY
    -- Any presented event proves the upload pipeline has resolved at least
    -- one transaction for this document since the current image_id was
    -- assigned (apply_surface sets this false the instant it sends a new
    -- reference, before its upload can possibly have landed) -- so it is
    -- safe for reconcile_placement/the caret overlay to address that id now.
    session.local_frame_confirmed = true
    if session.loading then preview.stop_loading(session) end
    -- The caret's own placement may have bailed out above (image_id was
    -- still unconfirmed when something last asked for it); retry now that
    -- it is. Idempotent either way: place_caret no-ops without a focused
    -- preview window, and redraws in place if the caret is already up.
    M.place_caret(session)
  end)
  -- The helper was asked for a revision it has no content for: a marker beat
  -- its own render request across the two channels (they share no ordering),
  -- or a push was lost. If the render is still in flight it will satisfy the
  -- marker by itself; otherwise re-issue it.
  localrender.on("missing", function(event)
    local session = session_by_document(event.doc)
    if not session or not valid(session) then return end
    if session.content_render_in_flight then return end
    M.schedule(session, 0)
  end)
  -- The helper attached (possibly mid-session, after a restart): re-render
  -- every raw session locally. The first marker's deletions retire whatever
  -- direct frame each session had up.
  localrender.on("attached", function()
    each_session(function(session)
      if session.backend.supports_local_markers then M.schedule(session, 0) end
    end)
  end)
  -- The helper died. Injected surfaces died with it (its teardown deletes
  -- every image it placed), so drop the session bookkeeping that referenced
  -- them and re-render through the stdio path, which localrender has already
  -- put back in charge -- presenter included.
  localrender.on("demoted", function()
    each_session(function(session)
      if session.backend.supports_local_markers then
        clear_image(session)
        M.schedule(session, 0)
      end
    end)
  end)
end

-- The event layer's seam. `autocmds.lua` sits above controller -- the arrow in
-- the target architecture points down, wiring to orchestration -- so it reaches
-- these by plain require, the way `commands.lua` already reaches the rest of
-- this module. They are the whole of what its handlers need that was not
-- already public, and nothing else uses them.
M.valid = valid
M.show_cached = show_cached
M.close_session = close_session
M.schedule_source_scroll = schedule_source_scroll

---Follow the source window back to a buffer this preview has already shown.
---Wrapped rather than exposing `history_host`: the host table is controller's
---own wiring and no caller should have to assemble it.
function M.history_follow_buffer(session, buf) history.follow_buffer(session, buf, history_host) end

-- Exported for `tests/lua/cases/scroll_scale.lua` only.
--
-- The rule this resolves depends on a live SSH capability snapshot, so a test
-- driven through `M.schedule_scroll` would need a preview window, a backend and
-- a renderer to reach three lines of arithmetic. Asserting it directly is what
-- makes "a local session sends exactly what it sent before" a fact rather than
-- an intention.
M._scroll_capture_scale = scroll_capture_scale
M._scroll_settle_delay = scroll_settle_delay

return M
