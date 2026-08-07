return function(t)
  local config = require("md-viewer.config")
  local interaction = require("md-viewer.interaction")
  local security = require("md-viewer.security")
  local process = require("md-viewer.process")
  local state = require("md-viewer.state")
  local debug = require("md-viewer.debug")

  config.reset()
  config.setup({ interaction = { drag_threshold_cells = 2 } })

  local PREVIEW_WIN = 4242

  local function fake_session()
    return {
      source_buf = nil,
      source_win = nil,
      preview_win = PREVIEW_WIN,
      document_id = "buffer-test",
      renderer_revision = "1:0",
      scroll_y = 0,
      viewport_width_px = 800,
      viewport_height_render_px = 600,
      last_placement = { row = 0, col = 0, width = 80, height = 24, exclusions = {} },
      backend = { name = "kitty_raw" },
    }
  end

  -- getmousepos() always reports a winid; a real gesture only ever reaches
  -- interaction.lua with one attached, so every synthetic point below carries
  -- the preview window's id unless a case is specifically about occlusion.
  local function point(row, col, winid) return { screenrow = row, screencol = col, winid = winid or PREVIEW_WIN } end

  -- ---------------------------------------------------------------------
  -- Press / drag / release classification.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    interaction.on_press(session, point(10, 10), { x = 1, y = 1 }, 1)
    t.eq(true, session.pointer.pressed, "press starts pointer tracking")
    t.eq(session, interaction.captured_session(), "a press captures its session")

    interaction.on_drag(session, point(10, 11))
    t.eq(false, session.pointer.drag_started, "movement below the threshold is not yet a drag")

    interaction.on_drag(session, point(10, 13))
    t.eq(true, session.pointer.drag_started, "movement at/above the threshold becomes a drag")

    interaction.on_release(session, point(10, 13))
    t.eq(false, session.pointer.pressed, "release always clears the pressed flag")
    t.eq(nil, interaction.captured_session(), "release frees the captured session")

    -- Reverse-direction drag: the threshold check must use unsigned
    -- distance, not a directional delta.
    interaction.on_press(session, point(10, 10), { x = 1, y = 1 }, 1)
    interaction.on_drag(session, point(10, 5))
    t.eq(true, session.pointer.drag_started, "a leftward/upward drag is classified the same as a rightward one")
    interaction.on_release(session, point(10, 5))
  end

  -- ---------------------------------------------------------------------
  -- A plain click no longer navigates to source (removed per operator
  -- decision: it fought the drag-to-select gesture, since clicking to
  -- dismiss a highlight also relocated the cursor). With nothing selected it
  -- does nothing at all -- no interact request, no cursor movement. With an
  -- active selection, it clears it, matching VS Code's own Markdown
  -- preview: drag to select, click anywhere to deselect.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local requests = {}
    local original_request = process.request
    process.request = function(method, params, callback) requests[#requests + 1] = { method = method, params = params } end

    interaction.on_press(session, point(10, 10), { x = 1, y = 1 }, 1)
    interaction.on_drag(session, point(10, 10))
    interaction.on_release(session, point(10, 10))
    process.request = original_request
    t.eq(0, #requests, "a plain click with nothing selected issues no interact request at all")

    -- With an active selection, the same below-threshold press/release
    -- clears it via a real selection_clear interact request.
    session.selection_active = true
    local clear_requests = {}
    process.request = function(method, params, callback)
      clear_requests[#clear_requests + 1] = { method = method, params = params }
      callback({ kind = "selection", cleared = true }, nil)
    end
    interaction.on_press(session, point(10, 10), { x = 1, y = 1 }, 1)
    interaction.on_drag(session, point(10, 10))
    interaction.on_release(session, point(10, 10))
    process.request = original_request

    t.eq(1, #clear_requests, "a plain click with an active selection clears it")
    t.eq("interact", clear_requests[1].method)
    t.eq("selection_clear", clear_requests[1].params.action)
    t.eq(false, session.selection_active, "the selection is marked inactive once cleared")

    -- A press captured while the pointer is over the content, then dragged
    -- until a different, occluding window claims the same screen area (a
    -- winid change with no matching release under our window), must not
    -- leave the button stuck "pressed" -- release still reaches it because
    -- capture is button-scoped, not window-scoped (see mouse.lua).
    interaction.on_press(session, point(10, 10), { x = 1, y = 1 }, 1)
    interaction.on_drag(session, point(10, 10, 9999))
    t.eq(true, session.pointer.pressed, "a drag reported under a different window still updates the captured session")
    interaction.on_release(session, point(10, 10, 9999))
    t.eq(false, session.pointer.pressed, "release under a different window still reaches the captured session")
    t.eq(nil, interaction.captured_session(), "capture is released even when the pointer ended up elsewhere")
  end

  -- ---------------------------------------------------------------------
  -- Ctrl/Cmd-click (M.activate) is the only remaining caller of
  -- request_hit/modifiers now that a plain click no longer is. The
  -- wire-encoding discipline it guards against is still real: an empty
  -- modifiers table must still never encode as `[]` (`vim.json.encode({})`
  -- emits `[]`, and validateEnvelope refuses an array for `modifiers`). A
  -- non-link hit does nothing -- no fallback to source navigation remains --
  -- and a link hit still activates normally.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local requests = {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = { method = method, params = params }
      callback({ kind = "source", sourcePosition = { line = 1, byteColumn = 0, precision = "line" } }, nil)
    end

    interaction.activate(session, { x = 1, y = 1 }, {})
    process.request = original_request

    t.eq(1, #requests, "ctrl/cmd-click issues exactly one interact request")
    t.eq("activate_at", requests[1].params.action)

    local encoded = require("md-viewer.protocol").encode(requests[1].params)
    t.eq(
      true,
      encoded:find('"modifiers":{', 1, true) ~= nil,
      "modifiers must encode as a JSON object, never as an empty array"
    )
    t.eq(false, encoded:find('"modifiers":[]', 1, true) ~= nil, "the empty-array encoding is what the renderer rejects")
    local decoded = vim.json.decode(encoded).modifiers
    t.eq(
      { ctrl = false, shift = false, alt = false, meta = false },
      decoded,
      "all four modifiers are stated explicitly"
    )
    t.eq(nil, session.last_interaction_kind, "a non-link ctrl/cmd-click hit records nothing and moves no cursor")

    -- A link hit under ctrl/cmd-click still activates normally.
    local original_open = vim.ui.open
    local opened = {}
    vim.ui.open = function(target)
      opened[#opened + 1] = target
      return { wait = function() end }
    end
    process.request = function(method, params, callback)
      callback({ kind = "link", link = { type = "https", href = "https://example.invalid" } }, nil)
    end
    interaction.activate(session, { x = 1, y = 1 }, { ctrl = true })
    process.request = original_request
    vim.ui.open = original_open

    t.eq({ "https://example.invalid" }, opened, "ctrl/cmd-click on a link still activates it")
    t.eq("link", session.last_interaction_kind, "a link hit still records its kind")
  end

  -- ---------------------------------------------------------------------
  -- Link dispatch (§4.4): every classified type, unsafe rejection, and the
  -- document-root escape guard.
  -- ---------------------------------------------------------------------
  do
    config.reset()
    config.setup({})
    local opened, notified = {}, {}
    local original_open = vim.ui.open
    local original_notify = vim.notify
    vim.ui.open = function(target)
      opened[#opened + 1] = target
      return { wait = function() end }
    end
    vim.notify = function(message, level) notified[#notified + 1] = { message = message, level = level } end

    for _, case in ipairs({
      { type = "http", href = "http://example.invalid/a" },
      { type = "https", href = "https://example.invalid/b" },
      { type = "mailto", href = "mailto:person@example.invalid" },
    }) do
      opened = {}
      interaction.activate_link({}, { link = case })
      t.eq({ case.href }, opened, ("%s links open via vim.ui.open"):format(case.type))
    end

    opened, notified = {}, {}
    interaction.activate_link({}, { link = { type = "unsafe", href = "javascript:alert(1)" } })
    t.eq({}, opened, "an unsafe scheme is never opened")
    t.eq(1, #notified, "an unsafe scheme activation is reported to the user")

    vim.ui.open = original_open
    vim.notify = original_notify
  end

  -- Local-file links: containment inside the configured document root.
  do
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.mkdir(root .. "/sub", "p")
    -- Canonicalize up front: on macOS /tmp (and Neovim's own buffer-name
    -- handling) resolve through a symlink, so comparing an un-resolved
    -- tempname() against what open_local_file actually produces (which reads
    -- the path back from a Neovim buffer name, already canonical) would fail
    -- on a symlink difference that has nothing to do with the code under test.
    root = vim.uv.fs_realpath(root)
    local inside_file = root .. "/sub/note.md"
    vim.fn.writefile({ "hello" }, inside_file)
    local outside_dir = vim.uv.fs_realpath((function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      return dir
    end)())
    local outside_file = outside_dir .. "/secret.md"
    vim.fn.writefile({ "hello" }, outside_file)

    t.eq(
      inside_file,
      security.resolve_local_link("note.md", root .. "/sub", root),
      "a relative path inside the root resolves"
    )
    t.eq(
      nil,
      security.resolve_local_link("../../" .. vim.fs.basename(outside_dir) .. "/secret.md", root .. "/sub", root),
      "a relative escape above the document root is rejected"
    )
    t.eq(nil, security.resolve_local_link(outside_file, root, root), "an absolute path outside the root is rejected")
    t.eq(
      inside_file,
      security.resolve_local_link("file://" .. inside_file, root, root),
      "a file:// URI inside the root resolves to the same path"
    )
    t.eq(nil, security.resolve_local_link("", root, root), "an empty href never resolves")

    local opened = {}
    local original_open = vim.ui.open
    vim.ui.open = function(target)
      opened[#opened + 1] = target
      return { wait = function() end }
    end
    local original_notify = vim.notify
    local notified = {}
    vim.notify = function(message) notified[#notified + 1] = message end

    local source_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(source_buf, root .. "/sub/doc.md")
    interaction.activate_link({ source_buf = source_buf }, { link = { type = "local_file", href = "note.md" } })
    t.eq({ inside_file }, opened, "an in-root local_file link opens the resolved path")

    opened, notified = {}, {}
    interaction.activate_link({ source_buf = source_buf }, { link = { type = "local_file", href = outside_file } })
    t.eq({}, opened, "an out-of-root local_file link is never opened")
    t.ok(#notified > 0, "an out-of-root local_file link is reported to the user")

    vim.ui.open = original_open
    vim.notify = original_notify
  end

  -- Local-file links: a symlink inside the document root pointing at a real
  -- file outside it must not read as "inside" -- mirrors
  -- tests/node/security.test.js's identical check for image loading, on the
  -- Lua side that resolves local_file link clicks.
  do
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    root = vim.uv.fs_realpath(root)
    local outside_dir = vim.uv.fs_realpath((function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      return dir
    end)())
    local secret = outside_dir .. "/secret.md"
    vim.fn.writefile({ "top secret" }, secret)
    local link = root .. "/escape.md"
    vim.uv.fs_symlink(secret, link)

    t.eq(
      nil,
      security.resolve_local_link("escape.md", root, root),
      "a symlink inside the document root that points outside it is rejected"
    )

    local opened = {}
    local original_open = vim.ui.open
    vim.ui.open = function(target)
      opened[#opened + 1] = target
      return { wait = function() end }
    end
    local notified = {}
    local original_notify = vim.notify
    vim.notify = function(message) notified[#notified + 1] = message end

    local source_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(source_buf, root .. "/doc.md")
    interaction.activate_link({ source_buf = source_buf }, { link = { type = "local_file", href = "escape.md" } })
    t.eq({}, opened, "a symlink escape is never opened")
    t.ok(#notified > 0, "a symlink escape is reported to the user")

    vim.ui.open = original_open
    vim.notify = original_notify
  end

  -- Fragment activation: reads the already-resolved scroll position from the
  -- same interact response, with no second round trip.
  do
    local controller = require("md-viewer.controller")
    local original_schedule_scroll = controller.schedule_scroll
    local scrolled = {}
    controller.schedule_scroll = function(session) scrolled[#scrolled + 1] = session end

    local session = { scroll_y = 0 }
    interaction.activate_link(session, {
      link = { type = "fragment", href = "#target" },
      fragmentResolved = true,
      scrollY = 480,
    })
    t.eq(480, session.scroll_y, "a resolved fragment updates the session's scroll position")
    t.eq(1, #scrolled, "a resolved fragment schedules a real scroll frame")

    local unresolved = { scroll_y = 0 }
    interaction.activate_link(unresolved, { link = { type = "fragment", href = "#missing" }, fragmentResolved = false })
    t.eq(0, unresolved.scroll_y, "an unresolved fragment leaves the scroll position untouched")

    controller.schedule_scroll = original_schedule_scroll
  end

  -- ---------------------------------------------------------------------
  -- Configuration validation.
  -- ---------------------------------------------------------------------
  do
    config.reset()
    for _, case in ipairs({
      { interaction = { enabled = "yes" } },
      { interaction = { links = 0 } },
      { interaction = { double_click = "true" } },
      { interaction = { drag_threshold_cells = -1 } },
      { interaction = { drag_threshold_cells = "1" } },
      { interaction = { selection = "yes" } },
      { interaction = { drag_debounce_ms = -1 } },
      { interaction = { drag_debounce_ms = "40" } },
      { interaction = { settle_ms = -1 } },
      { interaction = { settle_ms = "120" } },
      { interaction = { copy = 1 } },
      { interaction = { copy_on_select = "no" } },
      { interaction = { word_select = 0 } },
      { interaction = { paragraph_select = "no" } },
      { interaction = { find = "true" } },
    }) do
      local ok, err = pcall(config.setup, case)
      t.eq(false, ok, ("invalid interaction config is rejected: %s"):format(vim.inspect(case)))
      t.ok(tostring(err):match("interaction"), "the validation error names the interaction option")
    end
    config.reset()
  end

  -- ---------------------------------------------------------------------
  -- Part 6's new optional envelope fields (anchorCoordinates, query) follow
  -- the same wire-encoding discipline the modifiers table above does: assert
  -- the *encoded* JSON shape, not the Lua table, since a Lua table can look
  -- correct and still encode wrong.
  -- ---------------------------------------------------------------------
  do
    config.reset()
    config.setup({})
    local session = fake_session()
    local requests = {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = params
      callback({ kind = "selection", ok = true, text = "x", collapsed = false }, nil)
    end

    interaction.request_selection(
      session,
      { x = 1, y = 2, cellWidthPx = 10, cellHeightPx = 20 },
      { x = 3, y = 4, cellWidthPx = 10, cellHeightPx = 20 },
      "css",
      false,
      function() end
    )
    local encoded = require("md-viewer.protocol").encode(requests[1])
    t.eq(true, encoded:find('"anchorCoordinates":{', 1, true) ~= nil, "anchorCoordinates must encode as a JSON object")
    local decoded = vim.json.decode(encoded)
    t.eq({ x = 1, y = 2 }, decoded.anchorCoordinates)
    t.eq({ x = 3, y = 4 }, decoded.coordinates)

    requests = {}
    interaction.find_set(session, [[a query with "quotes" and \backslashes\]])
    local encoded_query = require("md-viewer.protocol").encode(requests[1])
    local decoded_query = vim.json.decode(encoded_query)
    t.eq([[a query with "quotes" and \backslashes\]], decoded_query.query, "a query round-trips through JSON unchanged")

    process.request = original_request
    config.reset()
  end

  -- ---------------------------------------------------------------------
  -- Session cleanup: forget() drops both the pointer state and the capture.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    interaction.on_press(session, { screenrow = 1, screencol = 1 }, { x = 1, y = 1 }, 1)
    t.eq(session, interaction.captured_session(), "sanity: the session is captured before forget()")
    interaction.forget(session)
    t.eq(nil, interaction.captured_session(), "forget() releases a captured session")
    t.eq(nil, session.pointer, "forget() clears the session's pointer state")
  end

  -- ---------------------------------------------------------------------
  -- Debug snapshot surfaces the last interaction's kind and precision.
  -- ---------------------------------------------------------------------
  do
    local session = state.create(90210, 1)
    session.last_interaction_kind = "link"
    session.last_interaction_precision = "block"
    local snapshot = debug.snapshot()
    local entry = snapshot.sessions[tostring(90210)]
    t.eq("link", entry.interaction_last_kind, "debug snapshot reports the last interaction kind")
    t.eq("block", entry.interaction_last_precision, "debug snapshot reports the last interaction precision")
    state.remove(90210)
  end
end
