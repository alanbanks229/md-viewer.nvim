return function(t)
  local config = require("md-viewer.config")
  local interaction = require("md-viewer.interaction")
  local process = require("md-viewer.process")
  local controller = require("md-viewer.controller")
  local debounce = require("md-viewer.debounce")

  -- config.setup() merges its argument onto the *defaults*, not onto the
  -- current config (see config.lua's known reassign-before-validate quirk
  -- note), so every partial re-setup below must go through this helper
  -- rather than a bare `config.setup({interaction = {...}})` -- otherwise a
  -- later call meant to flip one flag would silently reset drag_debounce_ms/
  -- settle_ms back to their (much slower) real-world defaults.
  local base_interaction = {
    drag_threshold_cells = 1,
    drag_debounce_ms = 5,
    settle_ms = 5,
    selection = true,
    copy = true,
    copy_on_select = false,
    word_select = true,
    find = true,
  }
  local function setup_interaction(overrides)
    config.setup({ interaction = vim.tbl_extend("force", vim.deepcopy(base_interaction), overrides or {}) })
  end

  config.reset()
  setup_interaction({})

  local PREVIEW_WIN = 5151

  local function fake_session()
    return {
      source_buf = nil,
      source_win = nil,
      preview_win = PREVIEW_WIN,
      document_id = "buffer-selection-test",
      renderer_revision = "1:0",
      scroll_y = 0,
      applied_scroll_y = 0,
      viewport_width_px = 800,
      viewport_height_render_px = 600,
      last_placement = { row = 0, col = 0, width = 80, height = 24, exclusions = {} },
      backend = { name = "kitty_raw" },
      closed = false,
    }
  end

  local function point(row, col, winid) return { screenrow = row, screencol = col, winid = winid or PREVIEW_WIN } end

  -- Stub out the actual backend display: these tests are about the
  -- request/backpressure/state machinery in interaction.lua, not image
  -- rendering, which controller.lua's own tests already cover.
  local original_display = controller.display_interact_result
  local displayed = {}
  controller.display_interact_result = function(session, result)
    displayed[#displayed + 1] = { session = session, result = result }
  end

  -- ---------------------------------------------------------------------
  -- Drag-threshold crossing initiates a debounced selection_preview request;
  -- only one request is ever in flight; the newest pending point is retained
  -- and intermediates are dropped; release issues a settled, device-scale
  -- commit.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local requests = {}
    local callbacks = {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = { method = method, params = params }
      callbacks[#callbacks + 1] = callback
    end

    interaction.on_press(session, point(10, 10), { x = 100, y = 100 }, 1)
    interaction.on_drag(session, point(10, 15)) -- crosses the 1-cell threshold
    vim.wait(200, function() return #requests >= 1 end, 5)
    t.eq(1, #requests, "the first threshold crossing issues exactly one selection_preview request")
    t.eq("interact", requests[1].method)
    t.eq("selection_preview", requests[1].params.action)
    t.eq("device", requests[1].params.captureScale, "a drag-preview frame is sharp by default")
    t.ok(requests[1].params.anchorCoordinates ~= nil, "a selection request always carries an explicit anchor")
    t.eq(true, session.pointer.selection_request_in_flight, "the request is marked in flight")

    -- Two more drag events arrive while the first request is still in
    -- flight: no second request may be issued yet.
    interaction.on_drag(session, point(10, 20))
    local third_point = interaction.locate(session, point(10, 25))
    interaction.on_drag(session, point(10, 25))
    vim.wait(60, function() return #requests >= 2 end, 5)
    t.eq(1, #requests, "no second request is issued while the first is still in flight")

    -- Completing the in-flight request picks up the newest coalesced point
    -- (the third one), not the intermediate (second) one.
    callbacks[1]({ kind = "selection", ok = true, text = "a", collapsed = false }, nil)
    vim.wait(300, function() return #requests >= 2 end, 5)
    t.eq(2, #requests, "the newest pending point is sent once the in-flight request completes")
    t.eq(
      third_point.x,
      requests[2].params.coordinates.x,
      "the coalesced request uses the newest drag point, not an intermediate one"
    )
    t.eq(
      third_point.y,
      requests[2].params.coordinates.y,
      "the coalesced request uses the newest drag point, not an intermediate one"
    )
    t.eq("device", requests[2].params.captureScale, "the coalesced re-fire is a preview frame at the same scale")
    t.eq(true, session.selection_active, "a successful preview marks the selection active")
    t.eq(1, #displayed, "a successful preview displays its captured frame")

    callbacks[2]({ kind = "selection", ok = true, text = "ab", collapsed = false }, nil)
    interaction.on_release(session, point(10, 25))
    vim.wait(300, function() return #requests >= 3 end, 5)
    t.eq(3, #requests, "release issues a final, settled selection request")
    t.eq("selection_commit", requests[3].params.action, "the settled request commits the selection")
    t.eq("device", requests[3].params.captureScale, "the settled request uses device scale")
    callbacks[3]({ kind = "selection", ok = true, text = "abc", collapsed = false }, nil)
    vim.wait(100, function() return #displayed >= 3 end, 5)

    process.request = original_request
  end

  -- ---------------------------------------------------------------------
  -- interaction.fast_drag = true is what softens a moving drag frame -- and
  -- it is the *only* thing that does. render.fast_scroll is left on in both
  -- halves below so the drag frame is shown to ignore it: coupling the two
  -- is what blurred the preview for the whole of every gesture, and a moving
  -- scroll frame and a moving drag frame are only superficially alike (see
  -- config.lua's fast_drag comment).
  -- ---------------------------------------------------------------------
  do
    local function first_drag_scale(interaction_overrides)
      config.setup({
        interaction = vim.tbl_extend("force", vim.deepcopy(base_interaction), interaction_overrides),
        render = { fast_scroll = true },
      })
      local session = fake_session()
      local requests = {}
      local original_request = process.request
      process.request = function(method, params) requests[#requests + 1] = { method = method, params = params } end
      interaction.on_press(session, point(10, 10), { x = 100, y = 100 }, 1)
      interaction.on_drag(session, point(10, 15))
      vim.wait(200, function() return #requests >= 1 end, 5)
      interaction.forget_selection(session)
      process.request = original_request
      return #requests, requests[1] and requests[1].params.captureScale
    end

    local count, scale = first_drag_scale({})
    t.eq(1, count)
    t.eq("device", scale, "fast_drag defaults off, so a moving drag frame stays sharp under render.fast_scroll")

    count, scale = first_drag_scale({ fast_drag = true })
    t.eq(1, count)
    t.eq("css", scale, "fast_drag = true opts the moving drag frame into the cheap capture")

    setup_interaction({})
  end

  -- ---------------------------------------------------------------------
  -- drag_debounce_ms = 0 (the default): a preview request dispatches
  -- synchronously on the threshold-crossing on_drag call, with no timer wait
  -- needed, mirroring controller.schedule_scroll's immediate-fire shape. A
  -- second on_drag while that request is still in flight coalesces
  -- synchronously too, and no second request is sent until the first
  -- completes.
  -- ---------------------------------------------------------------------
  do
    setup_interaction({ drag_debounce_ms = 0 })
    local session = fake_session()
    local requests, callbacks = {}, {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = params
      callbacks[#callbacks + 1] = callback
    end

    interaction.on_press(session, point(10, 10), { x = 100, y = 100 }, 1)
    interaction.on_drag(session, point(10, 15)) -- crosses the 1-cell threshold
    t.eq(1, #requests, "drag_debounce_ms = 0 dispatches the first preview frame with no timer wait at all")
    t.eq(true, session.pointer.selection_request_in_flight)

    interaction.on_drag(session, point(10, 20)) -- arrives while the first request is still in flight
    t.eq(1, #requests, "no second request is issued while the first is still in flight")
    t.eq(1, session.coalesced_drag_events, "the synchronous re-attempt while in flight still counts as coalesced")

    callbacks[1]({ kind = "selection", ok = true, text = "a", collapsed = false }, nil)
    t.eq(2, #requests, "completing the in-flight request immediately sends the newest coalesced point")

    callbacks[2]({ kind = "selection", ok = true, text = "ab", collapsed = false }, nil)
    -- No on_release in this block: it is testing preview pacing, not the
    -- release path. Drop the gesture explicitly so no timer this block armed
    -- can outlive it and fire against a later block's process.request stub.
    interaction.forget_selection(session)
    process.request = original_request
    setup_interaction({})
  end

  -- ---------------------------------------------------------------------
  -- Release while a preview request is still in flight defers the settled
  -- commit via pointer.pending_settle rather than racing a second concurrent
  -- request; the deferred commit fires automatically, still at device scale,
  -- once the in-flight preview's own completion callback runs.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local requests, callbacks = {}, {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = { method = method, params = params }
      callbacks[#callbacks + 1] = callback
    end

    interaction.on_press(session, point(10, 10), { x = 100, y = 100 }, 1)
    interaction.on_drag(session, point(10, 15))
    vim.wait(200, function() return #requests >= 1 end, 5)
    t.eq(1, #requests, "the drag issues its one preview request")
    t.eq(true, session.pointer.selection_request_in_flight, "the preview request is still outstanding")

    interaction.on_release(session, point(10, 15))
    t.eq(1, #requests, "release while a preview is in flight must not send a second, concurrent request")
    t.ok(session.pointer.pending_settle ~= nil, "release while in flight defers via pointer.pending_settle")

    callbacks[1]({ kind = "selection", ok = true, text = "a", collapsed = false }, nil)
    vim.wait(200, function() return #requests >= 2 end, 5)
    t.eq(2, #requests, "the deferred commit fires once the in-flight preview's callback runs")
    t.eq("selection_commit", requests[2].params.action, "the deferred request is the settled commit")
    t.eq("device", requests[2].params.captureScale, "the deferred commit still captures at device scale")
    callbacks[2]({ kind = "selection", ok = true, text = "ab", collapsed = false }, nil)

    process.request = original_request
  end

  -- ---------------------------------------------------------------------
  -- By default, a *moving* drag-preview frame captures at device scale, and
  -- no idle-settle timer is armed at all: interaction.fast_drag is off, so
  -- there is nothing to sharpen later. render.fast_scroll is deliberately
  -- left on here -- the drag frame must not follow it, which is exactly the
  -- coupling that made the preview go blurry for a whole gesture.
  -- ---------------------------------------------------------------------
  do
    config.setup({
      interaction = vim.tbl_extend("force", vim.deepcopy(base_interaction), { drag_debounce_ms = 0 }),
      render = { fast_scroll = true, scroll_settle_ms = 5 },
    })
    local session = fake_session()
    local requests, callbacks = {}, {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = { method = method, params = params }
      callbacks[#callbacks + 1] = callback
    end

    interaction.on_press(session, point(10, 10), { x = 100, y = 100 }, 1)
    interaction.on_drag(session, point(10, 15))
    t.eq(1, #requests, "the first drag point dispatches immediately")
    t.eq("device", requests[1].params.captureScale, "the moving drag frame is sharp by default")
    callbacks[1]({ kind = "selection", ok = true, text = "a", collapsed = false }, nil)

    -- Nothing further may fire on its own: with every frame already sharp an
    -- idle-settle frame would be a pure duplicate capture.
    vim.wait(80, function() return #requests >= 2 end, 5)
    t.eq(1, #requests, "no idle-settle frame is armed when fast_drag is off")
    t.eq(nil, session.drag_idle_settle_timer, "and no idle-settle timer is left behind")

    interaction.forget_selection(session)
    process.request = original_request
    setup_interaction({})
  end

  -- ---------------------------------------------------------------------
  -- Idle-settle, opt-in: with interaction.fast_drag on, a drag that pauses
  -- mid-gesture (mouse still down, no new point for render.scroll_settle_ms)
  -- automatically captures one sharp, device-scale frame, exactly like
  -- controller.schedule_scroll's own scroll_settle_timer does for a paused
  -- scroll. Without it, a reader who opted into the cheap moving frame and
  -- then stopped to look at what is being selected would stare at the soft
  -- frame for as long as they paused.
  -- ---------------------------------------------------------------------
  do
    config.setup({
      interaction = vim.tbl_extend("force", vim.deepcopy(base_interaction), { drag_debounce_ms = 0, fast_drag = true }),
      render = { scroll_settle_ms = 5 },
    })
    local session = fake_session()
    local requests, callbacks = {}, {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = { method = method, params = params }
      callbacks[#callbacks + 1] = callback
    end

    interaction.on_press(session, point(10, 10), { x = 100, y = 100 }, 1)
    interaction.on_drag(session, point(10, 15))
    t.eq(1, #requests, "the first drag point dispatches immediately")
    t.eq("css", requests[1].params.captureScale, "the moving frame is still the cheap scale")
    callbacks[1]({ kind = "selection", ok = true, text = "a", collapsed = false }, nil)

    -- No further movement: after scroll_settle_ms of silence, a sharp frame
    -- fires on its own, with no on_drag/on_release call from the test.
    vim.wait(200, function() return #requests >= 2 end, 5)
    t.eq(2, #requests, "idle-settle fires a frame on its own once the drag has paused")
    t.eq("selection_preview", requests[2].params.action, "the idle-settle frame is still a preview, not a commit")
    t.eq("device", requests[2].params.captureScale, "the idle-settle frame captures at device scale")
    callbacks[2]({ kind = "selection", ok = true, text = "a", collapsed = false }, nil)

    interaction.forget_selection(session)
    process.request = original_request
    setup_interaction({})
  end

  -- ---------------------------------------------------------------------
  -- Idle-settle vs. an in-flight request: if the idle timer fires while a
  -- preview request is still outstanding, it must not drop the sharpen
  -- attempt (which would leave a genuinely paused drag soft until the next
  -- real movement or release) -- it defers via pointer.pending_idle_settle
  -- and the in-flight request's own completion callback picks it up.
  -- ---------------------------------------------------------------------
  do
    config.setup({
      interaction = vim.tbl_extend("force", vim.deepcopy(base_interaction), { drag_debounce_ms = 0, fast_drag = true }),
      render = { scroll_settle_ms = 5 },
    })
    local session = fake_session()
    local requests, callbacks = {}, {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = { method = method, params = params }
      callbacks[#callbacks + 1] = callback
    end

    interaction.on_press(session, point(10, 10), { x = 100, y = 100 }, 1)
    interaction.on_drag(session, point(10, 15))
    t.eq(1, #requests, "the first drag point dispatches immediately")

    -- Leave callbacks[1] unresolved (request still in flight) long enough
    -- for the idle timer to fire against it.
    vim.wait(60, function() return session.pointer.pending_idle_settle == true end, 5)
    t.eq(true, session.pointer.pending_idle_settle, "the idle timer found a request in flight and deferred")
    t.eq(1, #requests, "no second request is sent while the first is still outstanding")
    t.eq(0, session.coalesced_drag_events or 0, "a deferred idle-settle is not a dropped drag point")

    callbacks[1]({ kind = "selection", ok = true, text = "a", collapsed = false }, nil)
    t.eq(2, #requests, "completing the in-flight request immediately fires the deferred idle-settle")
    t.eq("device", requests[2].params.captureScale, "the deferred idle-settle still captures at device scale")
    callbacks[2]({ kind = "selection", ok = true, text = "a", collapsed = false }, nil)

    interaction.forget_selection(session)
    process.request = original_request
    setup_interaction({})
  end

  -- ---------------------------------------------------------------------
  -- locate_for_drag clamps an out-of-window mouse position to the nearest
  -- edge of the placement instead of refusing outright -- M.locate itself
  -- (used by press/click) stays strict for the identical input, since
  -- clamping must never let a gesture *begin* outside the window.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session() -- placement: row=0, col=0, width=80, height=24
    local OTHER_WIN = 9999

    local off_left = { screenrow = 10, screencol = -50, winid = OTHER_WIN }
    t.eq(nil, interaction.locate(session, off_left), "M.locate stays strict for a point outside the preview window")
    local clamped_left = interaction.locate_for_drag(session, off_left)
    t.ok(clamped_left ~= nil, "locate_for_drag resolves a point outside the window instead of refusing")
    local expected_left = interaction.locate_for_drag(session, { screenrow = 10, screencol = 1, winid = PREVIEW_WIN })
    t.eq(expected_left.x, clamped_left.x, "the clamped point matches the placement's leftmost column")
    t.eq(expected_left.y, clamped_left.y, "row 10 is already in range, unaffected by the column clamp")

    local off_top_right = { screenrow = -20, screencol = 500, winid = OTHER_WIN }
    local clamped_tr = interaction.locate_for_drag(session, off_top_right)
    local expected_tr = interaction.locate_for_drag(session, { screenrow = 1, screencol = 80, winid = PREVIEW_WIN })
    t.eq(expected_tr.x, clamped_tr.x, "the clamped point matches the placement's rightmost column")
    t.eq(expected_tr.y, clamped_tr.y, "the clamped point matches the placement's topmost row")

    local inside = { screenrow = 12, screencol = 40, winid = PREVIEW_WIN }
    t.eq(
      interaction.locate(session, inside),
      interaction.locate_for_drag(session, inside),
      "inside the window, locate and locate_for_drag agree exactly"
    )

    -- Same window, but below the placement's own last row (a real case if the
    -- placed image does not fill the whole window) -- also clamped, not
    -- refused, since M.locate would otherwise freeze the same as leaving the
    -- window entirely.
    local below_placement = { screenrow = 40, screencol = 40, winid = PREVIEW_WIN }
    t.eq(nil, interaction.locate(session, below_placement), "M.locate stays strict below the placement too")
    local clamped_below = interaction.locate_for_drag(session, below_placement)
    local expected_below = interaction.locate_for_drag(session, { screenrow = 24, screencol = 40, winid = PREVIEW_WIN })
    t.eq(expected_below.x, clamped_below.x, "same-window-but-below-placement clamps to the bottom row")
    t.eq(expected_below.y, clamped_below.y, "same-window-but-below-placement clamps to the bottom row")
  end

  -- ---------------------------------------------------------------------
  -- A drag that leaves the preview window keeps extending toward the
  -- window's edge instead of freezing there -- mouse capture is button-
  -- scoped (see interaction.lua's module comment), so on_drag/on_release
  -- for the captured session keep dispatching even once the pointer is over
  -- a different window entirely.
  -- ---------------------------------------------------------------------
  do
    setup_interaction({ drag_debounce_ms = 0 })
    local session = fake_session()
    local requests = {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = { method = method, params = params }
      callback({ kind = "selection", ok = true, text = "x", collapsed = false }, nil)
    end

    interaction.on_press(session, point(10, 10), { x = 100, y = 100 }, 1)
    interaction.on_drag(session, point(10, 15)) -- inside the window
    t.eq(1, #requests, "the first in-window drag point issues a request")

    local OTHER_WIN = 9999
    local off_window = { screenrow = 10, screencol = -100, winid = OTHER_WIN }
    interaction.on_drag(session, off_window)
    t.eq(2, #requests, "a drag point outside the preview window still issues a request instead of freezing")
    local clamped = interaction.locate_for_drag(session, off_window)
    t.eq(clamped.x, requests[2].params.coordinates.x, "the off-window request uses the edge-clamped point")
    t.eq(clamped.y, requests[2].params.coordinates.y, "the off-window request uses the edge-clamped point")

    interaction.on_release(session, off_window)
    vim.wait(200, function() return #requests >= 3 end, 5)
    t.eq(3, #requests, "release outside the window still commits, not frozen")
    t.eq("selection_commit", requests[3].params.action)
    t.eq(clamped.x, requests[3].params.coordinates.x, "the off-window commit also uses the edge-clamped point")

    process.request = original_request
    setup_interaction({})
  end

  -- ---------------------------------------------------------------------
  -- VS Code-style click-to-deselect, end to end: drag to commit a real
  -- selection, then a separate, later plain click (no drag) clears it. A
  -- click never navigates to source -- that fallback was removed because it
  -- fought this exact gesture (dismissing a highlight used to also relocate
  -- the cursor).
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local requests = {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = { method = method, params = params }
      callback({ kind = "selection", ok = true, text = "committed", collapsed = false }, nil)
    end

    interaction.on_press(session, point(10, 10), { x = 100, y = 100 }, 1)
    interaction.on_drag(session, point(10, 15))
    vim.wait(200, function() return #requests >= 1 end, 5)
    interaction.on_release(session, point(10, 15))
    vim.wait(200, function() return #requests >= 2 end, 5)
    t.eq(true, session.selection_active, "the drag committed a real selection")
    t.eq("selection_commit", requests[#requests].params.action, "sanity: the drag ended in a commit")

    -- A later, separate press/release with no movement is a plain click. It
    -- must clear the selection via selection_clear, never re-navigate to
    -- source (there is no source-navigating action left to send at all).
    local before = #requests
    interaction.on_press(session, point(20, 20), { x = 300, y = 300 }, 1)
    interaction.on_release(session, point(20, 20))
    t.eq(before + 1, #requests, "the plain click issued exactly one more request")
    t.eq("selection_clear", requests[#requests].params.action, "a plain click clears the selection, not activate_at")
    t.eq(false, session.selection_active, "the selection is inactive once the click clears it")

    process.request = original_request
  end

  -- ---------------------------------------------------------------------
  -- Double-click word selection dispatches on press, and the matching
  -- release performs no other action (there is no click-to-source fallback
  -- for it to fall into).
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local requests = {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = params
      callback({ kind = "selection", ok = true, text = "word", collapsed = false }, nil)
    end

    interaction.on_press(session, point(10, 10), { x = 50, y = 50 }, 2)
    t.eq(1, #requests, "a double-click with word_select enabled issues exactly one request")
    t.eq("word_select", requests[1].action)
    t.eq(true, session.selection_active)

    interaction.on_release(session, point(10, 10))
    t.eq(1, #requests, "release after word_select fired performs no additional request")

    process.request = original_request
  end

  -- ---------------------------------------------------------------------
  -- Triple-click paragraph selection dispatches on press, mirroring
  -- double-click word selection exactly.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local requests = {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = params
      callback({ kind = "selection", ok = true, text = "whole paragraph", collapsed = false }, nil)
    end

    interaction.on_press(session, point(10, 10), { x = 50, y = 50 }, 3)
    t.eq(1, #requests, "a triple-click with paragraph_select enabled issues exactly one request")
    t.eq("paragraph_select", requests[1].action)
    t.eq(session.applied_scroll_y, requests[1].scrollY, "the request carries the session's current scrollY")
    t.eq(true, session.selection_active)

    interaction.on_release(session, point(10, 10))
    t.eq(1, #requests, "release after paragraph_select fired performs no additional request")

    process.request = original_request
  end

  -- ---------------------------------------------------------------------
  -- paragraph_select = false disables triple-click paragraph selection
  -- outright, matching word_select's own disable behaviour.
  -- ---------------------------------------------------------------------
  do
    setup_interaction({ paragraph_select = false })
    local session = fake_session()
    local requests = {}
    local original_request = process.request
    process.request = function(method, params, callback) requests[#requests + 1] = params end

    interaction.on_press(session, point(10, 10), { x = 50, y = 50 }, 3)
    t.eq(0, #requests, "on_press alone issues nothing when paragraph_select is disabled")
    interaction.on_release(session, point(10, 10))
    t.eq(0, #requests, "a disabled paragraph_select issues no request on release either")

    process.request = original_request
    setup_interaction({})
  end

  -- ---------------------------------------------------------------------
  -- word_select = false disables double-click word selection outright --
  -- the "keep it selectable" requirement -- rather than falling through to
  -- click-to-source, which no longer exists as a fallback for any click.
  -- ---------------------------------------------------------------------
  do
    setup_interaction({ word_select = false })
    local session = fake_session()
    local requests = {}
    local original_request = process.request
    process.request = function(method, params, callback) requests[#requests + 1] = params end

    interaction.on_press(session, point(10, 10), { x = 50, y = 50 }, 2)
    t.eq(0, #requests, "on_press alone issues nothing when word_select is disabled")
    interaction.on_release(session, point(10, 10))
    t.eq(
      0,
      #requests,
      "a disabled word_select issues no request on release either -- there is no click fallback anymore"
    )

    process.request = original_request
    setup_interaction({})
  end

  -- ---------------------------------------------------------------------
  -- Copy: writes to '"' and '+' when a clipboard provider is configured,
  -- length-only notification, and always a live re-query.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local original_request = process.request
    local original_has = vim.fn.has
    local original_notify = vim.notify
    local notified = {}
    vim.notify = function(message, level) notified[#notified + 1] = { message = message, level = level } end
    vim.fn.has = function(feature)
      if feature == "clipboard" then return 1 end
      return original_has(feature)
    end
    process.request = function(method, params, callback)
      t.eq("selection_text", params.action, "copy always re-queries the live selection, never a cached string")
      t.eq(
        session.applied_scroll_y,
        params.scrollY,
        "copy carries the session's current scrollY, so it cannot reset the shared page's scroll position"
      )
      callback({ kind = "selection_text", text = "copied text", collapsed = false }, nil)
    end

    vim.fn.setreg('"', "sentinel-unnamed")
    vim.fn.setreg("+", "sentinel-plus")
    interaction.copy_selection(session, false)
    t.eq("copied text", vim.fn.getreg('"'), "copy writes to the unnamed register")
    t.eq("copied text", vim.fn.getreg("+"), "copy writes to + when clipboard support is available")
    t.eq(1, #notified, "a non-silent copy notifies")
    t.eq("md-viewer: copied 11 characters", notified[1].message, "the notification is length-only, no register summary")
    t.eq(nil, notified[1].message:match("copied text"), "the notification never includes the selected text itself")

    vim.fn.has = original_has
    vim.notify = original_notify
    process.request = original_request
  end

  -- ---------------------------------------------------------------------
  -- Copy: '+' is left untouched when no clipboard provider is configured.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local original_request = process.request
    local original_has = vim.fn.has
    vim.fn.has = function(feature)
      if feature == "clipboard" then return 0 end
      return original_has(feature)
    end
    process.request = function(method, params, callback)
      callback({ kind = "selection_text", text = "no clipboard here", collapsed = false }, nil)
    end
    vim.fn.setreg("+", "unchanged")
    interaction.copy_selection(session, true)
    t.eq("no clipboard here", vim.fn.getreg('"'), "the unnamed register is always written")
    t.eq("unchanged", vim.fn.getreg("+"), "+ is never written when has('clipboard') is false")

    vim.fn.has = original_has
    process.request = original_request
  end

  -- ---------------------------------------------------------------------
  -- copy_on_select: disabled by default; respected in both states.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local original_request = process.request
    local copy_calls = 0

    -- copy_on_select = false (the default set at the top of this file):
    -- word_select must not trigger a copy.
    process.request = function(method, params, callback)
      if params.action == "selection_text" then copy_calls = copy_calls + 1 end
      callback({ kind = "selection", ok = true, text = "x", collapsed = false }, nil)
    end
    interaction.word_select(session, { x = 10, y = 10, cellWidthPx = 0, cellHeightPx = 0 })
    t.eq(0, copy_calls, "copy_on_select defaults to false: word_select must not copy")

    -- copy_on_select = true: the same successful commit now also copies.
    setup_interaction({ copy_on_select = true })
    interaction.word_select(session, { x = 10, y = 10, cellWidthPx = 0, cellHeightPx = 0 })
    t.eq(1, copy_calls, "copy_on_select = true copies after a successful selection")

    setup_interaction({})
    process.request = original_request
  end

  -- ---------------------------------------------------------------------
  -- Copy with nothing selected notifies and does not clobber the registers.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local original_request = process.request
    local original_notify = vim.notify
    local notified = {}
    vim.notify = function(message, level) notified[#notified + 1] = { message = message, level = level } end
    process.request = function(method, params, callback)
      callback({ kind = "selection_text", text = "", collapsed = true }, nil)
    end

    vim.fn.setreg('"', "untouched-unnamed")
    vim.fn.setreg("+", "untouched-plus")
    interaction.copy_selection(session, false)
    t.eq("untouched-unnamed", vim.fn.getreg('"'), "an empty selection must not clobber the unnamed register")
    t.eq("untouched-plus", vim.fn.getreg("+"), "an empty selection must not clobber the + register")
    t.eq(1, #notified, "copying nothing still notifies")
    t.eq(vim.log.levels.WARN, notified[1].level, "a nothing-selected copy warns rather than errors")

    -- No renderer content at all (renderer_revision nil): still a clean
    -- no-op notification, never an error.
    local empty_session = { document_id = "buffer-empty" }
    notified = {}
    interaction.copy_selection(empty_session, false)
    t.eq(1, #notified, "copying with no rendered content at all still notifies cleanly")

    vim.notify = original_notify
    process.request = original_request
  end

  -- ---------------------------------------------------------------------
  -- :MdViewerClearSelection.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    session.selection_active = true
    session.selection_content_revision = "1:0"
    local original_request = process.request
    local requests = {}
    process.request = function(method, params, callback)
      requests[#requests + 1] = params
      callback({ kind = "selection", cleared = true }, nil)
    end
    interaction.clear_selection(session)
    t.eq(false, session.selection_active, "clear_selection immediately marks the selection inactive")
    t.eq(1, #requests)
    t.eq("selection_clear", requests[1].action)
    t.eq(
      session.applied_scroll_y,
      requests[1].scrollY,
      "clear_selection carries the session's current scrollY -- omitting it used to reset the page to the top"
    )
    process.request = original_request
  end

  -- ---------------------------------------------------------------------
  -- Find command dispatch: find_set / find_next / find_previous / find_clear
  -- each issue the correctly-shaped request and update session state from
  -- the response. find_next/find_clear with no active search notify cleanly
  -- rather than erroring -- the state most likely to be under-tested.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local original_request = process.request
    local original_notify = vim.notify
    local notified = {}
    vim.notify = function(message, level) notified[#notified + 1] = { message = message, level = level } end

    -- No active search yet: find_next/find_previous must not-op cleanly.
    process.request = function() error("must not send a request when no search is active") end
    local ok_next = pcall(interaction.find_next, session)
    t.eq(true, ok_next, "find_next with no active search does not error")
    t.eq(1, #notified, "find_next with no active search notifies")
    t.eq(vim.log.levels.WARN, notified[1].level)
    notified = {}
    local ok_prev = pcall(interaction.find_previous, session)
    t.eq(true, ok_prev, "find_previous with no active search does not error")
    t.eq(1, #notified, "find_previous with no active search notifies")

    process.request = original_request
    notified = {}

    -- find_set.
    local requests = {}
    process.request = function(method, params, callback)
      requests[#requests + 1] = params
      callback({
        kind = "find",
        query = "hello",
        matchCount = 3,
        activeIndex = 0,
        activeSourcePosition = { line = 2, byteColumn = 0, precision = "line" },
      }, nil)
    end
    interaction.find_set(session, "hello")
    t.eq(1, #requests)
    t.eq("find_set", requests[1].action)
    t.eq("hello", requests[1].query)
    t.eq(session.applied_scroll_y, requests[1].scrollY, "find_set carries the session's current scrollY")
    t.eq(true, session.find_active)
    t.eq("hello", session.find_query)
    t.eq(3, session.find_match_count)
    t.eq(0, session.find_active_index)

    -- find_next now that a search is active.
    process.request = function(method, params, callback)
      requests[#requests + 1] = params
      callback({ kind = "find", activeIndex = 1 }, nil)
    end
    interaction.find_next(session)
    t.eq("find_next", requests[2].action)
    t.eq(session.applied_scroll_y, requests[2].scrollY, "find_next carries the session's current scrollY")
    t.eq(1, session.find_active_index)

    -- find_clear.
    process.request = function(method, params, callback)
      requests[#requests + 1] = params
      callback({ kind = "find", cleared = true }, nil)
    end
    interaction.find_clear(session)
    t.eq("find_clear", requests[3].action)
    t.eq(session.applied_scroll_y, requests[3].scrollY, "find_clear carries the session's current scrollY")
    t.eq(false, session.find_active)
    t.eq(nil, session.find_query)

    -- find_clear with nothing active is still a clean no-op (Lua-side state
    -- is already cleared; no request should error even though one is sent).
    notified = {}
    local ok_clear = pcall(interaction.find_clear, session)
    t.eq(true, ok_clear, "find_clear with no active search does not error")

    process.request = original_request
    vim.notify = original_notify
  end

  -- ---------------------------------------------------------------------
  -- Escape precedence: find, then selection, then normal fallthrough.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local original_request = process.request
    process.request = function(method, params, callback)
      callback({ kind = params.action:match("^find") and "find" or "selection", cleared = true }, nil)
    end

    session.find_active = true
    session.selection_active = true
    t.eq(true, interaction.escape(session), "escape clears an active find first")
    t.eq(false, session.find_active, "find is cleared")
    t.eq(true, session.selection_active, "selection is untouched while a find was still active")

    t.eq(true, interaction.escape(session), "escape clears the selection once find is already clear")
    t.eq(false, session.selection_active)

    t.eq(false, interaction.escape(session), "escape with neither active falls through to normal behaviour")

    process.request = original_request
  end

  -- ---------------------------------------------------------------------
  -- Cleanup on preview close: forget_selection resets all Part 6 state and
  -- closes its debounce timers.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    session.selection_active = true
    session.selection_content_revision = "1:0"
    session.find_active = true
    session.find_query = "x"
    session.find_match_count = 2
    session.find_active_index = 0
    debounce.call(session, "selection_debounce_timer", 10000, function() end)

    interaction.forget_selection(session)
    t.eq(false, session.selection_active)
    t.eq(nil, session.selection_content_revision)
    t.eq(false, session.find_active)
    t.eq(nil, session.find_query)
    t.eq(0, session.find_match_count)
    t.eq(nil, session.find_active_index)
    t.eq(nil, session.selection_debounce_timer, "forget_selection closes the debounce timer it owns")
  end

  -- ---------------------------------------------------------------------
  -- A selection from an older content revision is dropped as soon as new
  -- content lands, before it is ever displayed against the wrong revision.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    session.selection_active = true
    session.selection_content_revision = "1:0"
    session.renderer_revision = "2:0" -- content has already moved on
    interaction.forget_selection(session)
    t.eq(
      false,
      session.selection_active,
      "forget_selection is the mechanism controller.M.refresh calls on a revision change"
    )
  end

  -- ---------------------------------------------------------------------
  -- Cleanup on renderer restart: process.on_exit fires every registered
  -- listener when the real subprocess exits.
  -- ---------------------------------------------------------------------
  do
    local ping_result, ping_error
    process.request("ping", {}, function(result, err)
      ping_result, ping_error = result, err
    end)
    vim.wait(5000, function() return ping_result ~= nil or ping_error ~= nil end, 20)
    t.eq(nil, ping_error, "renderer must be reachable for this test to be meaningful")

    local session = fake_session()
    session.selection_active = true
    local fired = false
    process.on_exit(function()
      fired = true
      interaction.forget_selection(session)
    end)

    process.stop()
    vim.wait(5000, function() return fired end, 20)
    t.eq(true, fired, "process.on_exit fires its listener when the renderer subprocess exits")
    t.eq(false, session.selection_active, "the listener's forget_selection call reached the session")
  end

  -- ---------------------------------------------------------------------
  -- :MdViewerDebug diagnostics: every interact request this session sends is
  -- counted, a STALE_INTERACTION response (identified by process.request's
  -- third `meta` argument, not by parsing the error string) counts separately
  -- as lost-the-race, and a successful selection records its text length
  -- without ever caching the text itself.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    session.interaction_request_count = 0
    session.interaction_stale_count = 0
    local original_request = process.request

    process.request = function(method, params, callback)
      callback({ kind = "selection", ok = true, text = "seven!!", collapsed = false }, nil)
    end
    interaction.word_select(session, { x = 10, y = 10, cellWidthPx = 0, cellHeightPx = 0 })
    t.eq(1, session.interaction_request_count, "word_select counts as one interact request")
    t.eq(0, session.interaction_stale_count, "a successful request never counts as stale")
    t.eq(7, session.selection_text_length, "the selection's text length is recorded")

    process.request = function(method, params, callback)
      callback(nil, "interact request superseded by a newer request", { code = "STALE_INTERACTION" })
    end
    interaction.word_select(session, { x = 10, y = 10, cellWidthPx = 0, cellHeightPx = 0 })
    t.eq(2, session.interaction_request_count, "a failed request still counts as sent")
    t.eq(1, session.interaction_stale_count, "a STALE_INTERACTION response counts as lost-the-race")

    -- A non-stale failure (no meta.code, or a different code) must not be
    -- miscounted as staleness.
    process.request = function(method, params, callback) callback(nil, "renderer error") end
    interaction.word_select(session, { x = 10, y = 10, cellWidthPx = 0, cellHeightPx = 0 })
    t.eq(3, session.interaction_request_count)
    t.eq(1, session.interaction_stale_count, "an ordinary failure with no stale code does not inflate the stale count")

    -- clear_selection and forget_selection both drop the cached length so a
    -- stale value can never outlive the selection it described.
    process.request = function(method, params, callback) callback({ kind = "selection", cleared = true }, nil) end
    interaction.clear_selection(session)
    t.eq(nil, session.selection_text_length, "clear_selection drops the cached selection length")

    session.selection_text_length = 42
    interaction.forget_selection(session)
    t.eq(nil, session.selection_text_length, "forget_selection drops the cached selection length")

    process.request = original_request
  end

  -- ---------------------------------------------------------------------
  -- coalesced_drag_events: an in-flight selection_preview request must not
  -- block a drag from being tracked -- when the debounce timer fires again
  -- while a request is still outstanding, that point is dropped and counted
  -- rather than silently lost.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local requests, callbacks = {}, {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = params
      callbacks[#callbacks + 1] = callback
    end

    interaction.on_press(session, point(10, 10), { x = 100, y = 100 }, 1)
    interaction.on_drag(session, point(10, 15))
    vim.wait(200, function() return #requests >= 1 end, 5)
    t.eq(0, session.coalesced_drag_events or 0, "no drag has been coalesced yet -- only one request has ever been sent")

    -- Force the debounce timer to fire again while the first request is
    -- still in flight, by calling schedule_selection_preview directly
    -- (on_drag alone would just reset the same timer).
    session.pointer.newest_pending_drag_point = interaction.locate(session, point(10, 20))
    session.pointer.drag_started = true
    interaction.schedule_selection_preview(session)
    vim.wait(60, function() return (session.coalesced_drag_events or 0) > 0 end, 5)
    t.eq(1, session.coalesced_drag_events, "a debounce firing while a request is in flight counts as coalesced")
    t.eq(1, #requests, "the coalesced point is not sent as its own request")

    callbacks[1]({ kind = "selection", ok = true, text = "a", collapsed = false }, nil)
    -- Same reasoning as the drag_debounce_ms = 0 block above: no on_release
    -- here, so drop the gesture rather than leave a timer holding this
    -- block's process.request stub after it has been restored.
    interaction.forget_selection(session)
    process.request = original_request
  end

  -- ---------------------------------------------------------------------
  -- Stage-4 overlay path: a moving preview frame on an overlay-capable
  -- backend opts out of capture and is displayed through
  -- display_selection_overlay; every failure mode falls back to the
  -- captured path (sticky for the gesture), except a missing tint sheet,
  -- which retries exactly once with the sheet attached. The commit frame
  -- never opts out.
  -- ---------------------------------------------------------------------
  do
    setup_interaction({ drag_debounce_ms = 0, settle_ms = 0 })
    local needs_sheet = false
    local function overlay_session()
      local session = fake_session()
      session.image_id = 7
      session.backend = {
        name = "kitty_raw",
        overlay_supported = function() return true end,
        overlay_apply = function() end,
        overlay_needs_sheet = function() return needs_sheet end,
      }
      return session
    end

    local requests, callbacks = {}, {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = params
      callbacks[#callbacks + 1] = callback
    end
    local original_overlay_display = controller.display_selection_overlay
    local overlay_displays = {}
    local overlay_result = { applied = true, reason = nil }
    controller.display_selection_overlay = function(session, result)
      overlay_displays[#overlay_displays + 1] = { session = session, result = result }
      return overlay_result.applied, overlay_result.reason
    end

    local function fresh_gesture(session)
      requests, callbacks, displayed, overlay_displays = {}, {}, {}, {}
      interaction.on_press(session, point(10, 10), { x = 100, y = 100 }, 1)
      interaction.on_drag(session, point(10, 15))
      vim.wait(200, function() return #requests >= 1 end, 5)
      t.eq(1, #requests, "the drag issues one preview request")
    end

    -- Happy path: capture:false, sheet requested only when the backend needs
    -- it, and the overlay display path is the one that runs.
    needs_sheet = true
    local session = overlay_session()
    fresh_gesture(session)
    t.eq(false, requests[1].capture, "an overlay preview frame opts out of the capture")
    t.ok(requests[1].overlaySheet ~= nil, "the first frame asks for the tint sheet the backend lacks")
    t.eq(1600, requests[1].overlaySheet.widthPx, "sheet dimensions cover the device-scale capture")
    overlay_result.applied = true
    callbacks[1]({
      kind = "selection",
      ok = true,
      text = "abc",
      collapsed = false,
      rects = { { x = 1, y = 2, width = 3, height = 4 } },
    }, nil)
    t.eq(1, #overlay_displays, "the overlay display path runs for the frame")
    t.eq(0, #displayed, "the captured-frame display path does not")
    interaction.on_release(session, point(10, 15))
    vim.wait(200, function() return #requests >= 2 end, 5)
    t.eq("selection_commit", requests[2].action, "release still issues the settle commit")
    t.eq(nil, requests[2].capture, "the commit frame never opts out of capturing")
    callbacks[2]({ kind = "selection", ok = true, text = "abc", collapsed = false }, nil)

    -- Structural failure: the overlay could not display the frame, so the
    -- gesture falls back -- the same frame is re-requested through the
    -- captured path and stays captured for the rest of the gesture.
    needs_sheet = false
    session = overlay_session()
    fresh_gesture(session)
    overlay_result.applied = false
    overlay_result.reason = nil
    callbacks[1]({ kind = "selection", ok = true, text = "abc", collapsed = false, rects = {} }, nil)
    vim.wait(200, function() return #requests >= 2 end, 5)
    t.eq(2, #requests, "a failed overlay frame is redrawn through the fallback")
    t.eq(nil, requests[2].capture, "the fallback frame captures normally")
    t.eq(true, session.pointer.overlay_fallback, "the fallback is sticky for the gesture")
    callbacks[2]({ kind = "selection", ok = true, text = "abc", collapsed = false }, nil)
    t.eq(1, #displayed, "the fallback frame displays through the captured path")
    interaction.on_release(session, point(10, 15))
    vim.wait(200, function() return #requests >= 3 end, 5)
    callbacks[3]({ kind = "selection", ok = true, text = "abc", collapsed = false }, nil)

    -- Missing sheet: retried once with the sheet attached, not a sticky
    -- fallback; a need_sheet answer even WITH the sheet attached is
    -- structural and does fall back, so the pair can never loop.
    needs_sheet = false
    session = overlay_session()
    fresh_gesture(session)
    t.eq(nil, requests[1].overlaySheet, "the backend reported the sheet cache warm, so none is requested")
    overlay_result.applied = false
    overlay_result.reason = "need_sheet"
    callbacks[1]({ kind = "selection", ok = true, text = "abc", collapsed = false, rects = {} }, nil)
    vim.wait(200, function() return #requests >= 2 end, 5)
    t.eq(2, #requests, "a need_sheet answer retries the frame")
    t.ok(requests[2].overlaySheet ~= nil, "and the retry carries the sheet request")
    t.eq(false, requests[2].capture, "the retry stays on the overlay path")
    t.eq(false, session.pointer.overlay_fallback, "need_sheet alone is not a sticky fallback")
    callbacks[2]({ kind = "selection", ok = true, text = "abc", collapsed = false, rects = {} }, nil)
    vim.wait(200, function() return #requests >= 3 end, 5)
    t.eq(3, #requests, "need_sheet WITH the sheet attached falls back and redraws")
    t.eq(true, session.pointer.overlay_fallback, "that pair can never loop")
    callbacks[3]({ kind = "selection", ok = true, text = "abc", collapsed = false }, nil)
    interaction.forget_selection(session)

    -- A second gesture starting on top of a committed selection. The frame on
    -- screen has the FIRST selection painted into it by the browser, and
    -- overlay rectangles composite over it -- they add a highlight, they
    -- cannot remove one. Without a clean base the first selection stays
    -- visible for the whole second drag, which is what the operator reported
    -- on 2026-08-08 (highlight one code block, release, then drag in another).
    local original_restore = controller.restore_clean_base
    local restores = 0
    needs_sheet = false
    session = overlay_session()
    session.base_selection_painted = true
    controller.restore_clean_base = function(s)
      restores = restores + 1
      s.base_selection_painted = false
      return true
    end
    fresh_gesture(session)
    t.eq(1, restores, "a drag over a painted base restores a selection-free frame first")
    t.eq(false, requests[1].capture, "and then runs on the overlay path as usual")
    overlay_result.applied = true
    overlay_result.reason = nil
    callbacks[1]({ kind = "selection", ok = true, text = "abc", collapsed = false, rects = {} }, nil)
    t.eq(1, #overlay_displays, "the overlay draws over the clean base")
    interaction.forget_selection(session)

    -- No cached clean frame to go back to (the page was scrolled while the
    -- selection was up, say). Refusing is the honest answer: the gesture runs
    -- on captured frames, which repaint the whole preview and cannot inherit a
    -- stale highlight.
    session = overlay_session()
    session.base_selection_painted = true
    controller.restore_clean_base = function() return false end
    fresh_gesture(session)
    t.eq(true, session.pointer.overlay_fallback, "an unrestorable base falls back for the gesture")
    t.eq(nil, requests[1].capture, "and captures the frame instead of overlaying it")
    callbacks[1]({ kind = "selection", ok = true, text = "abc", collapsed = false }, nil)
    interaction.forget_selection(session)
    controller.restore_clean_base = original_restore

    controller.display_selection_overlay = original_overlay_display
    process.request = original_request
  end

  controller.display_interact_result = original_display
  config.reset()
end
