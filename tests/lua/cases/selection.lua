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
    t.eq("css", requests[1].params.captureScale, "a drag-preview frame uses the cheap CSS scale")
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
      callback({ kind = "selection_text", text = "copied text", collapsed = false }, nil)
    end

    vim.fn.setreg('"', "sentinel-unnamed")
    vim.fn.setreg("+", "sentinel-plus")
    interaction.copy_selection(session, false)
    t.eq("copied text", vim.fn.getreg('"'), "copy writes to the unnamed register")
    t.eq("copied text", vim.fn.getreg("+"), "copy writes to + when clipboard support is available")
    t.eq(1, #notified, "a non-silent copy notifies")
    t.ok(notified[1].message:match("%d+ character"), "the notification reports a length")
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
    t.eq(1, session.find_active_index)

    -- find_clear.
    process.request = function(method, params, callback)
      requests[#requests + 1] = params
      callback({ kind = "find", cleared = true }, nil)
    end
    interaction.find_clear(session)
    t.eq("find_clear", requests[3].action)
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

  controller.display_interact_result = original_display
  config.reset()
end
