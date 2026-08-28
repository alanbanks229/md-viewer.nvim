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
  -- later call meant to flip one flag would silently reset
  -- preview_debounce_ms/settle_ms back to their (much slower) real-world
  -- defaults.
  local base_interaction = {
    preview_debounce_ms = 5,
    settle_ms = 5,
    selection = true,
    copy = true,
    copy_on_select = false,
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

  -- Places the caret's glyph box directly, bypassing a real caret_move round
  -- trip, so the tests below can drive `interaction.visual_start` /
  -- `interaction.visual_update` the same way a real `v`/motion sequence does
  -- -- see `caret.lua`'s `M.rect` for the scroll-drift arithmetic this feeds.
  -- Highlighting is vim-motion-driven only now (mouse drag/double/triple-click
  -- were removed), so this -- not a synthesized mouse drag -- is how every
  -- selection-machinery test below starts and extends a selection.
  local function place_caret(session, rect)
    session.caret_rect = { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
    session.caret_scroll_y = session.applied_scroll_y or 0
  end

  -- The '+' register is provider-backed with no storage of its own: without
  -- a real clipboard utility (xclip/xsel/wl-copy on Linux CI), every
  -- setreg/getreg("+") silently no-ops regardless of has('clipboard'). Stub
  -- it with an in-memory register so these tests exercise interaction.lua's
  -- logic rather than the host's clipboard availability.
  local function fake_plus_register()
    local value = ""
    local original_setreg, original_getreg = vim.fn.setreg, vim.fn.getreg
    vim.fn.setreg = function(name, ...)
      if name == "+" then
        value = select(1, ...)
        return 0
      end
      return original_setreg(name, ...)
    end
    vim.fn.getreg = function(name, ...)
      if name == "+" then return value end
      return original_getreg(name, ...)
    end
    return function()
      vim.fn.setreg = original_setreg
      vim.fn.getreg = original_getreg
    end
  end

  -- Stub out the actual backend display: these tests are about the
  -- request/backpressure/state machinery in interaction.lua, not image
  -- rendering, which controller.lua's own tests already cover.
  local original_display = controller.display_interact_result
  local displayed = {}
  controller.display_interact_result = function(session, result)
    displayed[#displayed + 1] = { session = session, result = result }
  end

  -- ---------------------------------------------------------------------
  -- Starting a keyboard selection (`v`, via visual_start) initiates a
  -- debounced selection_preview request; only one request is ever in flight;
  -- the newest pending focus point is retained and intermediates are
  -- dropped; leaving visual mode with settle=true issues a settled,
  -- device-scale commit.
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

    place_caret(session, { x = 100, y = 100, width = 10, height = 20 })
    interaction.visual_start(session, false) -- anchors, and fires the first preview frame
    vim.wait(200, function() return #requests >= 1 end, 5)
    t.eq(1, #requests, "starting a keyboard selection issues exactly one selection_preview request")
    t.eq("interact", requests[1].method)
    t.eq("selection_preview", requests[1].params.action)
    t.eq("device", requests[1].params.captureScale, "a moving preview frame is sharp by default")
    t.ok(requests[1].params.anchorCoordinates ~= nil, "a selection request always carries an explicit anchor")
    t.eq(true, session.pointer.selection_request_in_flight, "the request is marked in flight")

    -- Two more caret motions arrive while the first request is still in
    -- flight: no second request may be issued yet.
    place_caret(session, { x = 120, y = 100, width = 10, height = 20 })
    interaction.visual_update(session)
    place_caret(session, { x = 150, y = 100, width = 10, height = 20 })
    local third_point = { x = 155, y = 110 } -- centre of the rect just placed
    interaction.visual_update(session)
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
      "the coalesced request uses the newest caret position, not an intermediate one"
    )
    t.eq(
      third_point.y,
      requests[2].params.coordinates.y,
      "the coalesced request uses the newest caret position, not an intermediate one"
    )
    t.eq("device", requests[2].params.captureScale, "the coalesced re-fire is a preview frame at the same scale")
    t.eq(true, session.selection_active, "a successful preview marks the selection active")
    t.eq(1, #displayed, "a successful preview displays its captured frame")

    callbacks[2]({ kind = "selection", ok = true, text = "ab", collapsed = false }, nil)
    interaction.visual_stop(session, true)
    vim.wait(300, function() return #requests >= 3 end, 5)
    t.eq(3, #requests, "leaving visual mode with settle=true issues a final, settled selection request")
    t.eq("selection_commit", requests[3].params.action, "the settled request commits the selection")
    t.eq("device", requests[3].params.captureScale, "the settled request uses device scale")
    callbacks[3]({ kind = "selection", ok = true, text = "abc", collapsed = false }, nil)
    vim.wait(100, function() return #displayed >= 3 end, 5)

    process.request = original_request
  end

  -- ---------------------------------------------------------------------
  -- interaction.fast_preview = true is what softens a moving preview frame --
  -- and it is the *only* thing that does. render.fast_scroll is left on in
  -- both halves below so the preview frame is shown to ignore it: coupling
  -- the two is what blurred the preview for the whole of every gesture, and a
  -- moving scroll frame and a moving selection-preview frame are only
  -- superficially alike (see config.lua's fast_preview comment).
  -- ---------------------------------------------------------------------
  do
    local function first_preview_scale(interaction_overrides)
      config.setup({
        interaction = vim.tbl_extend("force", vim.deepcopy(base_interaction), interaction_overrides),
        render = { fast_scroll = true },
      })
      local session = fake_session()
      local requests = {}
      local original_request = process.request
      process.request = function(method, params) requests[#requests + 1] = { method = method, params = params } end
      place_caret(session, { x = 100, y = 100, width = 10, height = 20 })
      interaction.visual_start(session, false)
      vim.wait(200, function() return #requests >= 1 end, 5)
      interaction.forget_selection(session)
      process.request = original_request
      return #requests, requests[1] and requests[1].params.captureScale
    end

    local count, scale = first_preview_scale({})
    t.eq(1, count)
    t.eq("device", scale, "fast_preview defaults off, so a moving preview frame stays sharp under render.fast_scroll")

    count, scale = first_preview_scale({ fast_preview = true })
    t.eq(1, count)
    t.eq("css", scale, "fast_preview = true opts the moving preview frame into the cheap capture")

    setup_interaction({})
  end

  -- ---------------------------------------------------------------------
  -- preview_debounce_ms = 0 (the default): a preview request dispatches
  -- synchronously on the caret-motion call that starts extending, with no
  -- timer wait needed, mirroring controller.schedule_scroll's immediate-fire
  -- shape. A second motion while that request is still in flight coalesces
  -- synchronously too, and no second request is sent until the first
  -- completes.
  -- ---------------------------------------------------------------------
  do
    setup_interaction({ preview_debounce_ms = 0 })
    local session = fake_session()
    local requests, callbacks = {}, {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = params
      callbacks[#callbacks + 1] = callback
    end

    place_caret(session, { x = 100, y = 100, width = 10, height = 20 })
    interaction.visual_start(session, false)
    t.eq(1, #requests, "preview_debounce_ms = 0 dispatches the first preview frame with no timer wait at all")
    t.eq(true, session.pointer.selection_request_in_flight)

    place_caret(session, { x = 150, y = 100, width = 10, height = 20 })
    interaction.visual_update(session) -- arrives while the first request is still in flight
    t.eq(1, #requests, "no second request is issued while the first is still in flight")
    t.eq(1, session.coalesced_preview_events, "the synchronous re-attempt while in flight still counts as coalesced")

    callbacks[1]({ kind = "selection", ok = true, text = "a", collapsed = false }, nil)
    t.eq(2, #requests, "completing the in-flight request immediately sends the newest coalesced point")

    callbacks[2]({ kind = "selection", ok = true, text = "ab", collapsed = false }, nil)
    -- No visual_stop in this block: it is testing preview pacing, not the
    -- settle path. Drop the gesture explicitly so no timer this block armed
    -- can outlive it and fire against a later block's process.request stub.
    interaction.forget_selection(session)
    process.request = original_request
    setup_interaction({})
  end

  -- ---------------------------------------------------------------------
  -- Leaving visual mode while a preview request is still in flight defers
  -- the settled commit via pointer.pending_settle rather than racing a second
  -- concurrent request; the deferred commit fires automatically, still at
  -- device scale, once the in-flight preview's own completion callback runs.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local requests, callbacks = {}, {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = { method = method, params = params }
      callbacks[#callbacks + 1] = callback
    end

    place_caret(session, { x = 100, y = 100, width = 10, height = 20 })
    interaction.visual_start(session, false)
    vim.wait(200, function() return #requests >= 1 end, 5)
    t.eq(1, #requests, "starting the selection issues its one preview request")
    t.eq(true, session.pointer.selection_request_in_flight, "the preview request is still outstanding")

    interaction.visual_stop(session, true)
    t.eq(1, #requests, "leaving visual mode while a preview is in flight must not send a second, concurrent request")
    t.ok(session.pointer.pending_settle ~= nil, "leaving visual mode while in flight defers via pointer.pending_settle")

    callbacks[1]({ kind = "selection", ok = true, text = "a", collapsed = false }, nil)
    vim.wait(200, function() return #requests >= 2 end, 5)
    t.eq(2, #requests, "the deferred commit fires once the in-flight preview's callback runs")
    t.eq("selection_commit", requests[2].params.action, "the deferred request is the settled commit")
    t.eq("device", requests[2].params.captureScale, "the deferred commit still captures at device scale")
    callbacks[2]({ kind = "selection", ok = true, text = "ab", collapsed = false }, nil)

    process.request = original_request
  end

  -- ---------------------------------------------------------------------
  -- By default, a *moving* preview frame captures at device scale, and no
  -- idle-settle timer is armed at all: interaction.fast_preview is off, so
  -- there is nothing to sharpen later. render.fast_scroll is deliberately
  -- left on here -- the preview frame must not follow it, which is exactly
  -- the coupling that made the preview go blurry for a whole gesture.
  -- ---------------------------------------------------------------------
  do
    config.setup({
      interaction = vim.tbl_extend("force", vim.deepcopy(base_interaction), { preview_debounce_ms = 0 }),
      render = { fast_scroll = true, scroll_settle_ms = 5 },
    })
    local session = fake_session()
    local requests, callbacks = {}, {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = { method = method, params = params }
      callbacks[#callbacks + 1] = callback
    end

    place_caret(session, { x = 100, y = 100, width = 10, height = 20 })
    interaction.visual_start(session, false)
    t.eq(1, #requests, "the first caret position dispatches immediately")
    t.eq("device", requests[1].params.captureScale, "the moving preview frame is sharp by default")
    callbacks[1]({ kind = "selection", ok = true, text = "a", collapsed = false }, nil)

    -- Nothing further may fire on its own: with every frame already sharp an
    -- idle-settle frame would be a pure duplicate capture.
    vim.wait(80, function() return #requests >= 2 end, 5)
    t.eq(1, #requests, "no idle-settle frame is armed when fast_preview is off")
    t.eq(nil, session.selection_idle_settle_timer, "and no idle-settle timer is left behind")

    interaction.forget_selection(session)
    process.request = original_request
    setup_interaction({})
  end

  -- ---------------------------------------------------------------------
  -- Idle-settle, opt-in: with interaction.fast_preview on, an extension that
  -- pauses mid-gesture (visual mode still active, no new caret motion for
  -- render.scroll_settle_ms) automatically captures one sharp, device-scale
  -- frame, exactly like controller.schedule_scroll's own scroll_settle_timer
  -- does for a paused scroll. Without it, a reader who opted into the cheap
  -- moving frame and then stopped to look at what is being selected would
  -- stare at the soft frame for as long as they paused.
  -- ---------------------------------------------------------------------
  do
    config.setup({
      interaction = vim.tbl_extend(
        "force",
        vim.deepcopy(base_interaction),
        { preview_debounce_ms = 0, fast_preview = true }
      ),
      render = { scroll_settle_ms = 5 },
    })
    local session = fake_session()
    local requests, callbacks = {}, {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = { method = method, params = params }
      callbacks[#callbacks + 1] = callback
    end

    place_caret(session, { x = 100, y = 100, width = 10, height = 20 })
    interaction.visual_start(session, false)
    t.eq(1, #requests, "the first caret position dispatches immediately")
    t.eq("css", requests[1].params.captureScale, "the moving frame is still the cheap scale")
    callbacks[1]({ kind = "selection", ok = true, text = "a", collapsed = false }, nil)

    -- No further movement: after scroll_settle_ms of silence, a sharp frame
    -- fires on its own, with no visual_update call from the test.
    vim.wait(200, function() return #requests >= 2 end, 5)
    t.eq(2, #requests, "idle-settle fires a frame on its own once the extension has paused")
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
  -- attempt (which would leave a genuinely paused extension soft until the
  -- next real motion or visual_stop) -- it defers via
  -- pointer.pending_idle_settle and the in-flight request's own completion
  -- callback picks it up.
  -- ---------------------------------------------------------------------
  do
    config.setup({
      interaction = vim.tbl_extend(
        "force",
        vim.deepcopy(base_interaction),
        { preview_debounce_ms = 0, fast_preview = true }
      ),
      render = { scroll_settle_ms = 5 },
    })
    local session = fake_session()
    local requests, callbacks = {}, {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = { method = method, params = params }
      callbacks[#callbacks + 1] = callback
    end

    place_caret(session, { x = 100, y = 100, width = 10, height = 20 })
    interaction.visual_start(session, false)
    t.eq(1, #requests, "the first caret position dispatches immediately")

    -- Leave callbacks[1] unresolved (request still in flight) long enough
    -- for the idle timer to fire against it.
    vim.wait(60, function() return session.pointer.pending_idle_settle == true end, 5)
    t.eq(true, session.pointer.pending_idle_settle, "the idle timer found a request in flight and deferred")
    t.eq(1, #requests, "no second request is sent while the first is still outstanding")
    t.eq(0, session.coalesced_preview_events or 0, "a deferred idle-settle is not a dropped caret position")

    callbacks[1]({ kind = "selection", ok = true, text = "a", collapsed = false }, nil)
    t.eq(2, #requests, "completing the in-flight request immediately fires the deferred idle-settle")
    t.eq("device", requests[2].params.captureScale, "the deferred idle-settle still captures at device scale")
    callbacks[2]({ kind = "selection", ok = true, text = "a", collapsed = false }, nil)

    interaction.forget_selection(session)
    process.request = original_request
    setup_interaction({})
  end

  -- ---------------------------------------------------------------------
  -- Leaving Visual mode clears the highlight immediately -- real Vim's own
  -- `<Esc>`-from-Visual behaviour, not a second press. The settle still
  -- lands first (so copy_on_select, if configured, copies exactly what was
  -- last shown) and the clear rides its completion, never a race against a
  -- settle a coalesced pending_settle was about to re-target.
  --
  -- A click never navigates to source -- that fallback was removed because
  -- it fought this exact gesture (dismissing a highlight used to also
  -- relocate the cursor) -- and since every selection in this plugin is
  -- reached through Visual mode (no mouse-drag path exists), a click has
  -- nothing left to clear once Visual mode's own <Esc> already did.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local requests = {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = { method = method, params = params }
      callback({ kind = "selection", ok = true, text = "committed", collapsed = false }, nil)
    end

    place_caret(session, { x = 100, y = 100, width = 10, height = 20 })
    interaction.visual_start(session, false)
    vim.wait(200, function() return #requests >= 1 end, 5)
    place_caret(session, { x = 150, y = 100, width = 10, height = 20 })
    interaction.visual_update(session)
    vim.wait(200, function() return #requests >= 2 end, 5)
    interaction.visual_stop(session, true)
    vim.wait(200, function() return #requests >= 4 end, 5)
    t.eq("selection_commit", requests[3].params.action, "leaving visual mode settles the final commit first")
    t.eq("selection_clear", requests[4].params.action, "and clears the highlight right after, in the same gesture")
    t.eq(false, session.selection_active, "the selection is inactive the instant Visual mode is left")

    -- A later, separate click has nothing left to clear: on_release only
    -- calls clear_selection while selection_active, so this sends nothing.
    local before = #requests
    interaction.on_press(session, point(20, 20), { x = 300, y = 300 })
    interaction.on_release(session, point(20, 20))
    t.eq(before, #requests, "a click on an already-cleared selection sends nothing further")

    process.request = original_request
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
    local restore_plus_register = fake_plus_register()
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

    restore_plus_register()
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
    local restore_plus_register = fake_plus_register()
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

    restore_plus_register()
    vim.fn.has = original_has
    process.request = original_request
  end

  -- ---------------------------------------------------------------------
  -- copy_on_select: disabled by default; respected in both states. Driven
  -- through the keyboard path all the way to a settled commit, since
  -- copy_on_select is only ever consulted from M.settle_selection's
  -- completion callback -- a moving preview frame never copies.
  -- ---------------------------------------------------------------------
  do
    setup_interaction({ preview_debounce_ms = 0, settle_ms = 0 })
    local session = fake_session()
    local original_request = process.request
    local copy_calls = 0
    local seen_actions = {}
    process.request = function(method, params, callback)
      seen_actions[#seen_actions + 1] = params.action
      if params.action == "selection_text" then copy_calls = copy_calls + 1 end
      callback({ kind = "selection", ok = true, text = "x", collapsed = false }, nil)
    end

    -- copy_on_select = false (the default set at the top of this file):
    -- committing a keyboard selection must not copy.
    place_caret(session, { x = 10, y = 10, width = 10, height = 10 })
    interaction.visual_start(session, false)
    interaction.visual_stop(session, true)
    vim.wait(200, function() return vim.tbl_contains(seen_actions, "selection_commit") end, 5)
    t.eq(0, copy_calls, "copy_on_select defaults to false: committing a selection must not copy")

    -- copy_on_select = true: the same successful commit now also copies.
    setup_interaction({ preview_debounce_ms = 0, settle_ms = 0, copy_on_select = true })
    seen_actions = {}
    place_caret(session, { x = 10, y = 10, width = 10, height = 10 })
    interaction.visual_start(session, false)
    interaction.visual_stop(session, true)
    vim.wait(200, function() return copy_calls > 0 end, 5)
    t.eq(1, copy_calls, "copy_on_select = true copies after a successful selection commit")

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
    local restore_plus_register = fake_plus_register()
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

    restore_plus_register()
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
  -- Cleanup on preview close: forget_selection resets all selection state and
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
  -- without ever caching the text itself. Driven through the keyboard path,
  -- with preview_debounce_ms = 0 so each request dispatches synchronously and
  -- the stubbed process.request can answer inline.
  -- ---------------------------------------------------------------------
  do
    setup_interaction({ preview_debounce_ms = 0 })
    local session = fake_session()
    session.interaction_request_count = 0
    session.interaction_stale_count = 0
    local original_request = process.request

    local function fire_preview()
      place_caret(session, { x = 10, y = 10, width = 10, height = 10 })
      interaction.visual_start(session, false)
    end

    process.request = function(method, params, callback)
      callback({ kind = "selection", ok = true, text = "seven!!", collapsed = false }, nil)
    end
    fire_preview()
    t.eq(1, session.interaction_request_count, "starting a keyboard selection counts as one interact request")
    t.eq(0, session.interaction_stale_count, "a successful request never counts as stale")
    t.eq(7, session.selection_text_length, "the selection's text length is recorded")

    process.request = function(method, params, callback)
      callback(nil, "interact request superseded by a newer request", { code = "STALE_INTERACTION" })
    end
    fire_preview()
    t.eq(2, session.interaction_request_count, "a failed request still counts as sent")
    t.eq(1, session.interaction_stale_count, "a STALE_INTERACTION response counts as lost-the-race")

    -- A non-stale failure (no meta.code, or a different code) must not be
    -- miscounted as staleness.
    process.request = function(method, params, callback) callback(nil, "renderer error") end
    fire_preview()
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
    setup_interaction({})
  end

  -- ---------------------------------------------------------------------
  -- coalesced_preview_events: an in-flight selection_preview request must
  -- not block a caret motion from being tracked -- when the debounce path
  -- fires again while a request is still outstanding, that point is dropped
  -- and counted rather than silently lost.
  -- ---------------------------------------------------------------------
  do
    setup_interaction({ preview_debounce_ms = 0 })
    local session = fake_session()
    local requests, callbacks = {}, {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = params
      callbacks[#callbacks + 1] = callback
    end

    place_caret(session, { x = 100, y = 100, width = 10, height = 20 })
    interaction.visual_start(session, false)
    t.eq(
      0,
      session.coalesced_preview_events or 0,
      "no frame has been coalesced yet -- only one request has ever been sent"
    )

    -- Force schedule_selection_preview to run again while the first request
    -- is still in flight, by calling it directly (a caret motion alone would
    -- just reset the same timer, and with preview_debounce_ms = 0 there is no
    -- timer here to force).
    place_caret(session, { x = 150, y = 100, width = 10, height = 20 })
    session.pointer.newest_pending_focus_point = { x = 155, y = 110 }
    interaction.schedule_selection_preview(session)
    t.eq(1, session.coalesced_preview_events, "a re-attempt while a request is in flight counts as coalesced")
    t.eq(1, #requests, "the coalesced point is not sent as its own request")

    callbacks[1]({ kind = "selection", ok = true, text = "a", collapsed = false }, nil)
    -- Same reasoning as the preview_debounce_ms = 0 block above: no
    -- visual_stop here, so drop the gesture rather than leave a timer holding
    -- this block's process.request stub after it has been restored.
    interaction.forget_selection(session)
    process.request = original_request
    setup_interaction({})
  end

  -- ---------------------------------------------------------------------
  -- Overlay path: a moving preview frame on an overlay-capable
  -- backend opts out of capture and is displayed through
  -- display_selection_overlay; every failure mode falls back to the
  -- captured path (sticky for the gesture), except a missing tint sheet,
  -- which retries exactly once with the sheet attached. The commit frame
  -- never opts out.
  -- ---------------------------------------------------------------------
  do
    setup_interaction({ preview_debounce_ms = 0, settle_ms = 0 })
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
      place_caret(session, { x = 100, y = 100, width = 10, height = 20 })
      interaction.visual_start(session, false)
      vim.wait(200, function() return #requests >= 1 end, 5)
      t.eq(1, #requests, "starting the selection issues one preview request")
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
    interaction.visual_stop(session, true)
    vim.wait(200, function() return #requests >= 2 end, 5)
    t.eq("selection_commit", requests[2].action, "leaving visual mode still issues the settle commit")
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
    interaction.visual_stop(session, true)
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
    -- visible for the whole second gesture, which is what the operator
    -- reported on 2026-08-08 (highlight one code block, release, then select
    -- another).
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
    t.eq(1, restores, "a gesture over a painted base restores a selection-free frame first")
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
