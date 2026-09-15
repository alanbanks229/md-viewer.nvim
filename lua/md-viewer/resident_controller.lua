---Whole-document resident mode: the loop that drives it.
---
---Third and outermost of the resident layers. `resident.lua` is the arithmetic,
---`resident_session.lua` is the per-session state machine around it, and this is
---what spends the renderer and the wire on that plan: capture the next chunk,
---draw the reader's position from the chunks already held, and start the whole
---thing from the render that measured the document.
---
---Resident mode is the document held in the terminal, scrolling by placement.
---Every function here is currently unreached on every host this plugin runs on
---(see the KEEP_IN_MIND notes below and in `resident_session.lua`), so the suite
---proves little about it; `scripts/resident/drive.lua` is the oracle.
local linkrate = require("md-viewer.linkrate")
local occlusion = require("md-viewer.occlusion")
local presenter = require("md-viewer.presenter")
local preview = require("md-viewer.preview")
local renderer = require("md-viewer.renderer")
local resident_session = require("md-viewer.resident_session")

local M = {}
local host

local clear_image = occlusion.clear_image
local clear_selection_overlay = presenter.clear_selection_overlay
local must_hide = occlusion.must_hide

---Connect the controller-owned orchestration the resident loop reaches back
---for: session validity, the document's text, and the fall-back to the
---per-scroll model when a demotion ends resident mode. Functions are injected
---so this module can drive the resident model without requiring controller and
---recreating the cycle presenter removed.
function M.set_host(value)
  assert(type(value) == "table", "resident_controller host must be a table")
  for _, name in ipairs({ "valid", "markdown", "refresh" }) do
    assert(type(value[name]) == "function", "resident_controller host is missing " .. name)
  end
  host = value
end

local function valid(session) return host ~= nil and host.valid(session) end
local function markdown(session) return host.markdown(session) end
local function refresh(session) return host.refresh(session) end
local function notify_error(message) vim.notify("md-viewer: " .. tostring(message), vim.log.levels.ERROR) end

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
  -- A render of the reader's content outranks the warm-up: the chunk would
  -- otherwise spend the renderer and the wire ahead of an edit the reader is
  -- waiting to see. `controller.refresh`'s callback restarts the pump on every
  -- exit, so this is a wait rather than a stop.
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
      -- This is now much rarer than it was: a chunk is only staled by another
      -- chunk or by a content render, because md-viewer.lanes gave it a lane of
      -- its own. Before that every `renderer.request` shared one serial, so a
      -- settle capture, a resize, a ColorScheme or an OptionSet was enough --
      -- and `next_chunk` has already removed this index from the queue, so
      -- returning here dropped it for good. Nothing rebuilds the queue:
      -- `resident_session.begin` early-returns on an unchanged key, so the
      -- warm-up simply stopped at n/N and stayed there, and the region was only
      -- ever captured if the reader happened to scroll into it. On a link where
      -- a chunk is a second of wire that was not a rare race.
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
        refresh(session)
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
      refresh(session)
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
---The same proof `presenter.restore_clean_base` demands before it re-shows a
---cached frame, asked of the frame that is up rather than of the cached one: an
---image is placed, it was captured against this content, and it was captured at
---this position. Anything short of all three is a refusal.
---
---This is what stops the resident bootstrap blanking its own first paint.
---`presenter.apply_image` lands the render that measured the document -- the
---reader's own position, captured a call ago -- and `M.begin_resident` runs one
---line later with no chunks captured yet, so `resident_session.draw` can only
---say "waiting". Waiting is not a reason to take correct pixels down; it is a
---reason to leave them up until the chunks can replace them. What the invariant
---forbids is presenting a frame of *somewhere else* as this position, and this
---is how the two are told apart.
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
  -- Ahead of the compose, for the reason `presenter.apply_image` takes it down
  -- ahead of `backend.show`: the indicator is a passive float, so it punches an
  -- exclusion out of the placement, and taking it down afterwards would leave a
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
    -- compose rather than before it, the same create-then-delete rule
    -- `backend.move` and `backend.update` follow: deleting first is a blank pane
    -- for one write.
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
    -- Same rule `presenter.apply_image` follows, for the same reason: the base
    -- under the highlight has moved, so rectangles measured against the old one
    -- are on the wrong text now.
    clear_selection_overlay(session)
    presenter.clear_caret_overlay(session)
    presenter.place_caret(session)
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
  refresh(session)
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
  linkrate.notice_unknown()
  M.draw_resident(session)
  M.pump_resident(session)
end

return M
