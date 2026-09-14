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
local resident_session = require("md-viewer.resident_session")
local linkrate = require("md-viewer.linkrate")
local localrender = require("md-viewer.localrender")
local history = require("md-viewer.history")
local occlusion = require("md-viewer.occlusion")
local presenter = require("md-viewer.presenter")

local M = {}
local group

local clear_selection_overlay = presenter.clear_selection_overlay
local apply_image = presenter.apply_image
local apply_surface = presenter.apply_surface
local local_mode = presenter.local_mode
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
    M.draw_resident(session)
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
    -- document re-render) help. That re-render is also a `request_serial` bump,
    -- which is what used to lose an in-flight chunk.
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
  -- `holding_position` refuses on nil, which is the answer we want.
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
  draw_resident = function(session) return M.draw_resident(session) end,
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
  -- right of way over the warm-up while it is in flight. `pump_resident` issues
  -- `renderer.request` too and every request bumps `request_serial`, so an edit
  -- made during warm-up could be staled by the very next chunk -- and a staled
  -- render is dropped silently below, with nothing to re-issue it until the
  -- reader typed again. On a host where the warm-up is minutes rather than
  -- seconds that is easy to hit. `pump_resident` waits; the callback below
  -- restarts it either way.
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
      -- `M.begin_resident` below; this covers the error and stale exits, which
      -- would otherwise leave the queue parked forever.
      if content_render and session.render_path == "resident" and session.resident then
        vim.schedule(function() M.pump_resident(session) end)
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
    -- `holding_position`); it used to blank it one call later, which is what the
    -- reader on a slow link saw as a flash of "waiting for this page" over an
    -- empty pane. After this, a resident session captures chunks and nothing
    -- else.
    if session.render_path == "resident" and not render_options_is_chunk(render_options) then
      M.begin_resident(session, meta)
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

-- ---------------------------------------------------------------------------
-- Resident mode: the document held in the terminal, scrolling by placement.
-- ---------------------------------------------------------------------------

---Capture the next chunk the warm-up queue wants, one at a time.
---
---One in flight is the whole of the backpressure. A chunk capture is 116-373ms
---and about a second of wire on a slow link, so queueing several would only move
---the wait from the renderer to the socket.
function M.pump_resident(session)
  -- KEEP_IN_MIND: this whole function is currently unreached on every host
  -- this plugin runs on -- the render_path ~= "resident" guard right below
  -- returns before any of the settle-before-placing logic further down
  -- runs. Reachable in principle, not orphaned; do not delete for lack of a
  -- live caller. See the fuller note on resident_session.is_needed in
  -- resident_session.lua for exactly what would have to be true for this to
  -- run again, and a real, runnable snippet (lifted from
  -- scripts/resident/drive.lua) that forces this path for local testing
  -- without a slow real host. Raise removing the path itself with the
  -- operator/orchestrator rather than deciding it here.
  if not valid(session) or session.render_path ~= "resident" then return end
  -- A render of the reader's content outranks the warm-up: issuing a chunk
  -- capture now would bump `request_serial` and stale it, and a staled content
  -- render is dropped with nothing to re-issue it. `M.refresh`'s callback
  -- restarts the pump on every exit, so this is a wait rather than a stop.
  if session.content_render_in_flight then return end
  local state = session.resident
  if not state or state.in_flight then return end
  local index = resident_session.next_chunk(session)
  if not index then
    preview.update_title(session)
    return
  end
  local options = resident_session.capture_options(session, index)
  if not options then return end
  state.in_flight = index
  renderer.request(session, markdown(session), options, function(result, err, stale)
    if not valid(session) or session.render_path ~= "resident" then return end
    local live = session.resident
    if not live or live ~= state then return end
    state.in_flight = nil
    if stale then
      -- Superseded, but not necessarily by anything that invalidates this plan.
      -- *Every* renderer.request bumps `request_serial`, so a settle capture, a
      -- resize, a ColorScheme or an OptionSet is enough to stale a chunk that is
      -- in flight -- and `next_chunk` has already removed this index from the
      -- queue, so returning here dropped it for good. Nothing rebuilds the
      -- queue: `resident_session.begin` early-returns on an unchanged key, so
      -- the warm-up simply stopped at n/N and stayed there, and the region was
      -- only ever captured if the reader happened to scroll into it. On a link
      -- where a chunk is a second of wire that is not a rare race.
      --
      -- A reply that really does belong to a dead plan is caught above, by
      -- `live ~= state`: a content change builds a new state table and a
      -- demotion nils it. Reaching here means the plan is still the live one, so
      -- put the chunk back and carry on -- the same treatment the error branch
      -- below has always given.
      state.queue[#state.queue + 1] = index
      vim.schedule(function() M.pump_resident(session) end)
      return
    end
    if err then
      local code = tostring(err)
      if
        code:match("REGION_CAPTURE_UNSUPPORTED")
        or code:match("REGION_ORIGIN_MOVED")
        or code:match("REGION_TOO_LARGE")
      then
        resident_session.demote(session, code)
        notify_error("resident preview unavailable, falling back to per-scroll capture: " .. code)
        M.refresh(session)
        return
      end
      -- Anything else is this one chunk's problem. Put it back and carry on;
      -- the reader is told by the winbar that it is still warming.
      state.queue[#state.queue + 1] = index
      vim.schedule(function() M.pump_resident(session) end)
      return
    end
    local ok, adopt_err = resident_session.adopt(session, index, result.image, result.metadata)
    if not ok then
      resident_session.demote(session, adopt_err)
      notify_error("resident preview refused a chunk: " .. tostring(adopt_err))
      M.refresh(session)
      return
    end
    resident_session.retain(session, live.drawn or index)
    -- KEEP_IN_MIND: this branch (and is_needed itself) is currently
    -- unreached on every host this plugin runs on -- pump_resident only
    -- runs at all when session.render_path == "resident" (guarded at the
    -- top of this function), which under `image.resident = "auto"` needs a
    -- measured link under image.resident_below_bytes_per_sec on a terminal
    -- profile that allows resident_pan. See the fuller note on
    -- resident_session.is_needed in resident_session.lua for why, and how to
    -- exercise this deliberately with `image.resident = "on"`.
    -- Unexercised, not orphaned -- do not delete for lack of a live caller;
    -- raise removing the path itself with the operator/orchestrator first.
    if resident_session.is_needed(session, session.scroll_y or 0, index) then
      -- The reader is waiting on exactly the chunk that just landed.
      -- `nvim_ui_send` only queues bytes for Neovim's own UI channel to
      -- drain -- it does not wait for them to cross the wire -- and a Kitty
      -- terminal decodes a large image asynchronously with respect to how
      -- fast it can parse the placement that follows it. Composing right
      -- away can crop a buffer the terminal has not finished decoding, which
      -- is indistinguishable from this side: the reply already proved the
      -- pixels are the right ones. Waiting roughly as long as this chunk's
      -- own bytes take to cross the measured link gives the terminal a
      -- realistic chance to finish before being asked to crop it. Only the
      -- placement waits; the next capture request does not.
      local bytes = (result.metadata and result.metadata.pngBytes) or #result.image
      local rate = linkrate.resolve()
      local settle_ms = rate and math.min(2000, math.max(50, math.ceil(bytes / rate * 1000))) or 200
      vim.defer_fn(function()
        if not valid(session) or session.render_path ~= "resident" then return end
        M.draw_resident(session)
        preview.update_title(session)
      end, settle_ms)
    else
      M.draw_resident(session)
      preview.update_title(session)
    end
    vim.schedule(function() M.pump_resident(session) end)
  end)
end

---Is the frame already on screen provably a picture of `scroll_y`?
---
---The same proof `M.restore_clean_base` demands before it re-shows a cached
---frame, asked of the frame that is up rather than of the cached one: an image
---is placed, it was captured against this content, and it was captured at this
---position. Anything short of all three is a refusal.
---
---This is what stops the resident bootstrap blanking its own first paint.
---`apply_image` lands the render that measured the document -- the reader's own
---position, captured a call ago -- and `begin_resident` runs one line later with
---no chunks captured yet, so `draw` can only say "waiting". Waiting is not a
---reason to take correct pixels down; it is a reason to leave them up until the
---chunks can replace them. What the invariant forbids is presenting a frame of
---*somewhere else* as this position, and this is how the two are told apart.
local function holding_position(session, scroll_y)
  if not session.image_id then return false end
  if session.frame_revision ~= session.renderer_revision then return false end
  return math.abs((session.frame_scroll_y or 0) - scroll_y) <= 0.5
end

---Draw the reader's position from resident chunks, or clear the preview.
---
---A position not yet covered shows nothing rather than the previous screen:
---leaving the old picture up presents pixels of somewhere else as though they
---belonged to this position, and the reader has no way to tell. The one
---exception is `holding_position` above, which is not an exception to that rule
---but an application of it -- the frame it keeps *is* this position.
function M.draw_resident(session)
  if not valid(session) or session.render_path ~= "resident" then return end
  if must_hide(session) then
    clear_image(session)
    return
  end
  local scroll_y = session.scroll_y or 0
  -- Ahead of the compose, for the reason `apply_image` takes it down ahead of
  -- `backend.show`: the indicator is a passive float, so it punches an exclusion
  -- out of the placement, and taking it down afterwards would leave a
  -- spinner-shaped hole in the screen that replaced it until the next poll.
  if not resident_session.missing(session, scroll_y) then preview.stop_loading(session) end
  local outcome, detail = resident_session.draw(session, scroll_y)
  if outcome == "drawn" then
    session.resident_waiting = nil
    -- The bootstrap frame this screen has just replaced. `compose` retires only
    -- the bands it tracks itself, so an ordinary frame left placed underneath
    -- goes on compositing -- and every band shares a z layer with it, which
    -- Kitty ties by image id, so whether the dead frame draws over the live one
    -- comes down to which integer happened to be larger. Deleted after the
    -- compose rather than before it, the same create-then-delete rule `M.move`
    -- and `M.update` follow: deleting first is a blank pane for one write.
    if session.image_id then
      pcall(session.backend.clear, session.image_id)
      session.image_id = nil
      -- Not `frame_scroll_y`: the compose above has already recorded what the
      -- bands now on screen are a picture of, and this is only the frame they
      -- replaced. Clearing it here left `caret.rect` measuring its drift
      -- against 0, so a resident preview had no caret anywhere but the top of
      -- the document.
      session.frame_revision = nil
    end
    -- Same rule `apply_image` follows, for the same reason: the base under the
    -- highlight has moved, so rectangles measured against the old one are on the
    -- wrong text now.
    clear_selection_overlay(session)
    M.clear_caret_overlay(session)
    M.place_caret(session)
    preview.update_progress(session)
    preview.update_line_numbers(session)
    preview.update_title(session)
    return
  end
  if outcome == "waiting" then
    if holding_position(session, scroll_y) then
      -- Nothing to do and nothing to say: the pane is showing this position,
      -- captured by the render that measured the document. `resident_waiting`
      -- stays nil so the winbar reads the grey "warming n/N" rather than the
      -- yellow "waiting for this page" -- the yellow notice means the reader is
      -- looking at a blank pane, and they are not.
      preview.update_title(session)
      M.pump_resident(session)
      return
    end
    session.resident_waiting = detail
    clear_image(session)
    -- The pane is genuinely empty now. During bootstrap that is the state the
    -- spinner exists for, and stopping it at first paint was right only because
    -- there *was* a first paint; here there is not. Once the resident path has
    -- drawn a screen the winbar carries this instead -- a spinner blinking into
    -- the middle of the pane on every scroll that outruns the warm-up would be
    -- noise.
    if not (session.resident and session.resident.drawn) then preview.start_loading(session) end
    preview.update_title(session)
    M.pump_resident(session)
    return
  end
  resident_session.demote(session, detail)
  notify_error("resident preview could not draw this position: " .. tostring(detail))
  M.refresh(session)
end

---Start resident mode from the render that measured the document.
function M.begin_resident(session, meta)
  if not valid(session) or session.render_path ~= "resident" then return end
  local ok, reason = resident_session.begin(session, meta)
  if not ok then
    resident_session.demote(session, reason)
    return
  end
  -- The one place the link rate is worth mentioning unprompted: a warm-up is
  -- about to run and the winbar has no idea how long it will take. Said once per
  -- Neovim and never once per preview -- linkrate owns that guard -- and phrased
  -- as a suggestion, because an unmeasured link is not a fault and nothing else
  -- in md-viewer treats it as one.
  require("md-viewer.linkrate").notice_unknown()
  M.draw_resident(session)
  M.pump_resident(session)
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
    M.draw_resident(session)
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
  session.request_serial = session.request_serial + 1
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
  -- Every callback already carries request_serial; advancing it is the pane
  -- activation epoch at the document boundary and makes late frames stale.
  session.request_serial = session.request_serial + 1
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
  group = vim.api.nvim_create_augroup("md-viewer", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    callback = function(args)
      for _, session in ipairs(state.documents_for_source(args.buf)) do
        if state.is_active(session) then
          M.schedule(session)
        else
          session.dirty = true
        end
      end
    end,
  })
  -- Neovim's own Visual mode is not usable inside a graphical preview, and
  -- `navigation.lua` says so where it maps `v`/`V` to a *preview* selection
  -- instead. Saying it was not the same as enforcing it: the plugin maps only
  -- a plain click and its release over the preview, not a drag, so an
  -- ordinary mouse drag -- or `<C-v>` -- still puts Neovim in Visual mode over
  -- the surface, where it selects blank cells and paints a highlight across
  -- the image. Reported from Warp as the preview blinking to a blank pane
  -- with a blue rectangle on it -- that rectangle was V-BLOCK.
  --
  -- Excluded for the `cells` backend, whose buffer holds real styled text where
  -- Visual mode and `y` do exactly what a reader would expect.
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = "*:[vV\22sS\19]*",
    callback = function(args)
      local session = state.from_preview(args.buf)
      if not session or session.closed then return end
      if not (session.backend and session.backend.is_graphical) then return end
      -- One escape per tick. Without this a stream of drag events -- each
      -- re-entering Visual as fast as the escape leaves it -- would spin.
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
      if session and session.config.sync.source_to_preview and session.config.sync.cursor_follow then
        local cfg = session.config.sync
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
        if source_win and scrolled_win == source_win and session.config.sync.source_to_preview then
          local cfg = session.config.sync
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
        if not must_hide(session) then M.schedule(session, 80, "resize_timer") end
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
          state.set_source_window(source_session, vim.api.nvim_get_current_win())
        end
        -- The source window arriving back at a document this preview has
        -- already shown (`<C-o>` after following a link) takes the preview
        -- with it. Deliberately narrow: only buffers in this session's own
        -- history qualify, so `preview.pinned` still holds for every other
        -- buffer switch.
        if source_session then return end
        local win_session = state.from_source_win(vim.api.nvim_get_current_win())
        if win_session and valid(win_session) and vim.api.nvim_get_current_buf() == buf then
          history.follow_buffer(win_session, buf, history_host)
        end
      end)
      each_session(function(session)
        if
          not session.image_id
          and not session.ui_suppressed
          and not must_hide(session)
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
    callback = function()
      preview.restore_cursor()
      -- And take the block down with it. The caret marks where the *focused*
      -- reader is, so one left drawn in a preview nobody is in claims a focus
      -- that has moved on -- and on `FocusLost`, which gives the real cursor
      -- back without any window changing, it would sit there beside it: two
      -- carets at once, the thing this pair exists to prevent. The current
      -- window is still the one being left when these fire.
      --
      -- Only the overlay. `caret_rect` is kept, so coming back redraws the
      -- caret exactly where it was, locally, through the `place_caret` on the
      -- matching enter autocmd -- no round trip and no lost position.
      local session = state.from_preview_win(vim.api.nvim_get_current_win())
      if session and valid(session) then M.clear_caret_overlay(session) end
    end,
  })
  vim.api.nvim_create_autocmd("BufFilePost", {
    group = group,
    callback = function(args)
      for _, session in ipairs(state.documents_for_source(args.buf)) do
        preview.update_title(session)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "CompleteChanged" }, {
    group = group,
    callback = function()
      each_session(function(session)
        if session.backend.needs_ui_poll then session.ui_suppressed = true end
      end)
      clear_raw_sessions()
    end,
  })
  vim.api.nvim_create_autocmd({ "CompleteDone", "WinClosed" }, {
    group = group,
    callback = function(args)
      if args.event ~= "WinClosed" then
        each_session(function(session)
          if session.backend.needs_ui_poll then session.ui_suppressed = false end
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
      -- Preview buffers use bufhidden=hide specifically so switching pane tabs
      -- is not lifecycle. Only the optional unpinned source behavior remains.
      local session
      if not state.from_preview(args.buf) then
        local hidden = state.get(args.buf)
        if hidden and not hidden.config.preview.pinned then session = hidden end
      end
      if session then close_session(session) end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      local preview_document = state.from_preview(args.buf)
      if preview_document then
        M.tab_close(preview_document)
        return
      end
      for _, session in ipairs(state.documents_for_source(args.buf)) do
        M.tab_close(session)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local closed = tonumber(args.match)
      for _, pane in pairs(state.panes()) do
        if pane.preview_win == closed and not pane.closed then
          -- The window is already invalid; teardown skips closing/restoring it
          -- and still releases every document and renderer cache.
          close_session(pane.active)
          break
        end
      end
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
    callback = function()
      -- Detach before tearing down sessions: this closes the control-socket
      -- pipe, which the helper's socket server sees as a real `close` event
      -- on its next tick -- concrete and immediate, unlike the marker-based
      -- image deletions below it, which only reach the helper if a captured
      -- frame happens to carry them before the process exits. Without this,
      -- the operator's own workflow (one helper process wrapping many
      -- Neovim restarts in the same ssh session) leaves every per-document
      -- epoch/seq counter on the helper (replica.js's `docs`, injector.js's
      -- `lastSurfaceSeq`) sitting at whatever the outgoing session left it
      -- at, so the next Neovim session's first frame reference can be
      -- silently refused as stale -- a preview that renders solid black on
      -- reopen, measured live (2026-08-27).
      if localrender.active() then localrender.detach() end
      M.close_all({ blocking = true })
    end,
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

return M
