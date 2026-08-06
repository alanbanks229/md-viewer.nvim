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
  -- A drag that never crosses the threshold, followed by release, performs
  -- a click (a real interact request is issued).
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local requests = {}
    local original_request = process.request
    process.request = function(method, params, callback)
      requests[#requests + 1] = { method = method, params = params }
      callback({ kind = "source", sourcePosition = { line = 1, byteColumn = 0, precision = "line" } }, nil)
    end

    interaction.on_press(session, point(10, 10), { x = 1, y = 1 }, 1)
    interaction.on_drag(session, point(10, 10))
    interaction.on_release(session, point(10, 10))
    process.request = original_request

    t.eq(1, #requests, "a below-threshold press/release performs exactly one interact request")
    t.eq("interact", requests[1].method, "the click request uses the interact method")
    t.eq("activate_at", requests[1].params.action, "clicks resolve through activate_at for both source and link hits")
    t.eq("line", session.last_interaction_precision, "the resolved precision is recorded on the session")
    t.eq("source", session.last_interaction_kind, "the resolved kind is recorded on the session")

    -- An unmodified click carries no modifiers, and `vim.json.encode({})` emits
    -- `[]` -- which validateEnvelope refuses ("modifiers must be an object of
    -- booleans"). The refusal was swallowed by the error branch in M.click, so
    -- every plain click silently did nothing. Assert the encoded wire form, not
    -- the Lua table, because the Lua table looked correct the whole time.
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

    -- A drag never issues a request at all.
    local drag_requests = {}
    process.request = function(...) drag_requests[#drag_requests + 1] = true end
    interaction.on_press(session, point(10, 10), { x = 1, y = 1 }, 1)
    interaction.on_drag(session, point(10, 20))
    interaction.on_release(session, point(10, 20))
    process.request = original_request
    t.eq(0, #drag_requests, "a drag creates no selection and issues no interact request in this part")

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
  -- Cursor movement: clamping, UTF-8 byte-boundary safety, the sync guard,
  -- and focus_source_on_click.
  -- ---------------------------------------------------------------------
  do
    local source_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "h\xc3\xa9llo w\xc3\xb6rld", "second" })
    vim.cmd("botright new")
    local source_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(source_win, source_buf)
    local other_win = vim.api.nvim_get_current_win()

    local session = { source_buf = source_buf, source_win = source_win, sync_guard = false }

    config.setup({ interaction = { focus_source_on_click = true } })
    -- byte_column 2 lands on the continuation byte of the 2-byte 'é'
    -- (starting at byte offset 1); it must clamp back to offset 1.
    interaction.move_source_cursor(session, { line = 1, byte_column = 2, precision = "block" })
    t.eq({ 1, 1 }, vim.api.nvim_win_get_cursor(source_win), "a mid-sequence byte column clamps to the UTF-8 boundary")
    t.eq(true, session.sync_guard, "the sync guard is held synchronously while the cursor moves")
    vim.wait(200, function() return session.sync_guard == false end)
    t.eq(false, session.sync_guard, "the sync guard releases on the next event-loop turn")
    t.eq(source_win, vim.api.nvim_get_current_win(), "focus_source_on_click=true focuses the source window")

    -- Line and byte-column clamping against buffer bounds.
    interaction.move_source_cursor(session, { line = 9999, byte_column = 0, precision = "block" })
    t.eq(2, vim.api.nvim_win_get_cursor(source_win)[1], "an out-of-range line clamps to the last buffer line")
    interaction.move_source_cursor(session, { line = 1, byte_column = 9999, precision = "block" })
    local clamped_col = vim.api.nvim_win_get_cursor(source_win)[2]
    local line_bytes = #vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1]
    -- We clamp to the line's byte length (per spec); Neovim's own normal-mode
    -- cursor semantics then clamp that further to the last real column, since
    -- "one past the last byte" only exists as a cursor position in insert
    -- mode. Both clamps are honest -- neither guesses -- so the observable
    -- floor is length-1, not length.
    t.eq(line_bytes - 1, clamped_col, "an out-of-range byte column clamps to the line's last valid column")

    -- focus_source_on_click = false updates the cursor without stealing focus.
    vim.api.nvim_set_current_win(other_win)
    config.setup({ interaction = { focus_source_on_click = false } })
    interaction.move_source_cursor(session, { line = 2, byte_column = 0, precision = "line" })
    t.eq(other_win, vim.api.nvim_get_current_win(), "focus_source_on_click=false does not change the active window")
    t.eq(2, vim.api.nvim_win_get_cursor(source_win)[1], "the source cursor still moves when focus is not stolen")

    -- A nil source position (precision "none") is a deliberate no-op.
    local cursor_before = vim.api.nvim_win_get_cursor(source_win)
    interaction.move_source_cursor(session, { line = nil, byte_column = nil, precision = "none" })
    t.eq(cursor_before, vim.api.nvim_win_get_cursor(source_win), "an unresolved source position never moves the cursor")

    vim.api.nvim_win_close(source_win, true)
  end

  -- ---------------------------------------------------------------------
  -- Part 5: a real, non-zero byte column arriving with precision "exact".
  --
  -- Part 4 built the clamping and the UTF-8 boundary walk this relies on, but
  -- every column it ever saw was 0. The renderer's UTF-16 -> UTF-8 conversion
  -- is tested on its own in tests/node/utf.test.js; what is checked here is
  -- the other half of the claim -- that a column derived from multibyte text
  -- survives this function unchanged instead of being clamped or shifted.
  -- ---------------------------------------------------------------------
  do
    local source_buf = vim.api.nvim_create_buf(false, true)
    local prefix = "Unicode line: caf\xc3\xa9 "
    local cjk = "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e"
    local emoji = "\xf0\x9f\x8e\x89"
    vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { prefix .. cjk .. " " .. emoji .. " done." })
    vim.cmd("botright new")
    local source_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(source_win, source_buf)
    local session = { source_buf = source_buf, source_win = source_win, sync_guard = false }
    config.setup({ interaction = { focus_source_on_click = false } })

    -- The columns the renderer reports for a click on each run: 20 bytes of
    -- "Unicode line: café " (19 characters -- the é is two bytes), then 10 more
    -- for the three 3-byte CJK characters plus a space.
    local cjk_column = #prefix
    local emoji_column = cjk_column + #cjk + 1
    t.eq(20, cjk_column, "the CJK run starts 20 bytes in, where a column count would say 19")
    t.eq(30, emoji_column, "the emoji starts 30 bytes in, where a column count would say 23")

    -- `byteColumn`, not `byte_column`: this is the renderer's own wire field,
    -- which is what result.sourcePosition actually carries. Part 4's tests used
    -- the snake_case name only, which is why the field-name mismatch in
    -- move_source_cursor survived until a non-zero column existed to expose it.
    interaction.move_source_cursor(session, { line = 1, byteColumn = cjk_column, precision = "exact" })
    t.eq({ 1, cjk_column }, vim.api.nvim_win_get_cursor(source_win), "an exact column onto CJK is used verbatim")

    interaction.move_source_cursor(session, { line = 1, byteColumn = emoji_column, precision = "exact" })
    t.eq({ 1, emoji_column }, vim.api.nvim_win_get_cursor(source_win), "an exact column onto an emoji is used verbatim")

    -- The boundary walk still protects against a column inside a character,
    -- which is what a broken conversion upstream would produce.
    interaction.move_source_cursor(session, { line = 1, byteColumn = emoji_column + 2, precision = "exact" })
    t.eq(
      { 1, emoji_column },
      vim.api.nvim_win_get_cursor(source_win),
      "a column inside the emoji clamps back to its start"
    )

    -- The snake_case alias still works, so nothing Part 4 wrote regressed.
    interaction.move_source_cursor(session, { line = 1, byte_column = cjk_column, precision = "exact" })
    t.eq({ 1, cjk_column }, vim.api.nvim_win_get_cursor(source_win), "the snake_case alias is still honoured")

    vim.api.nvim_win_close(source_win, true)
  end

  -- ---------------------------------------------------------------------
  -- Part 5: an exact hit round-trips through the click path and is recorded
  -- for :MdViewerDebug, which is the only place a user ever sees the label.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local source_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "Some **bold text** here." })
    vim.cmd("botright new")
    local source_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(source_win, source_buf)
    session.source_buf, session.source_win = source_buf, source_win

    local original_request = process.request
    process.request = function(method, params, callback)
      callback({ kind = "source", sourcePosition = { line = 1, byteColumn = 12, precision = "exact" } }, nil)
    end
    config.setup({ interaction = { focus_source_on_click = false } })
    interaction.click(session, { x = 1, y = 1 }, 1)
    process.request = original_request

    t.eq("exact", session.last_interaction_precision, "an exact precision is recorded on the session")
    t.eq({ 1, 12 }, vim.api.nvim_win_get_cursor(source_win), "the click lands on 'text', past the '**'")
    local entry = debug.snapshot().sessions[tostring(session.source_buf)]
      or { interaction_last_precision = session.last_interaction_precision }
    t.eq("exact", entry.interaction_last_precision, "the debug snapshot reports the exact label")

    vim.api.nvim_win_close(source_win, true)
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
      { interaction = { click_to_source = 1 } },
      { interaction = { focus_source_on_click = "no" } },
      { interaction = { links = 0 } },
      { interaction = { double_click = "true" } },
      { interaction = { drag_threshold_cells = -1 } },
      { interaction = { drag_threshold_cells = "1" } },
    }) do
      local ok, err = pcall(config.setup, case)
      t.eq(false, ok, ("invalid interaction config is rejected: %s"):format(vim.inspect(case)))
      t.ok(tostring(err):match("interaction"), "the validation error names the interaction option")
    end
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
