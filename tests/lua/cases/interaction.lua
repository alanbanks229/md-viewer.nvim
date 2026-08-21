return function(t)
  local config = require("md-viewer.config")
  local interaction = require("md-viewer.interaction")
  local security = require("md-viewer.security")
  local process = require("md-viewer.process")
  local state = require("md-viewer.state")
  local debug = require("md-viewer.debug")

  config.reset()
  config.setup({})

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
  -- Press / release classification. There is no drag path anymore: a press
  -- only ever leads to a plain click's release.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    interaction.on_press(session, point(10, 10), { x = 1, y = 1 })
    t.eq(true, session.pointer.pressed, "press starts pointer tracking")
    t.eq(session, interaction.captured_session(), "a press captures its session")

    interaction.on_release(session, point(10, 13))
    t.eq(false, session.pointer.pressed, "release always clears the pressed flag")
    t.eq(nil, interaction.captured_session(), "release frees the captured session")
  end

  -- ---------------------------------------------------------------------
  -- A plain click no longer navigates to source (removed per operator
  -- decision: it fought the vim-motion-driven selection gesture, since
  -- clicking to dismiss a highlight also relocated the cursor). With nothing
  -- selected it does nothing at all -- no interact request, no cursor
  -- movement. With an active selection, it clears it, matching VS Code's own
  -- Markdown preview: extend a selection with the keyboard, click anywhere
  -- to deselect.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local requests = {}
    local original_request = process.request
    process.request = function(method, params, callback) requests[#requests + 1] = { method = method, params = params } end

    interaction.on_press(session, point(10, 10), { x = 1, y = 1 })
    interaction.on_release(session, point(10, 10))
    process.request = original_request
    t.eq(0, #requests, "a plain click with nothing selected issues no interact request at all")

    -- With an active selection, a plain press/release clears it via a real
    -- selection_clear interact request.
    session.selection_active = true
    local clear_requests = {}
    process.request = function(method, params, callback)
      clear_requests[#clear_requests + 1] = { method = method, params = params }
      callback({ kind = "selection", cleared = true }, nil)
    end
    interaction.on_press(session, point(10, 10), { x = 1, y = 1 })
    interaction.on_release(session, point(10, 10))
    process.request = original_request

    t.eq(1, #clear_requests, "a plain click with an active selection clears it")
    t.eq("interact", clear_requests[1].method)
    t.eq("selection_clear", clear_requests[1].params.action)
    t.eq(false, session.selection_active, "the selection is marked inactive once cleared")

    -- A press captured while the pointer is over the content, released under
    -- a different, occluding window (no matching release under our window),
    -- must not leave the button stuck "pressed" -- release still reaches it
    -- because capture is button-scoped, not window-scoped (see mouse.lua).
    interaction.on_press(session, point(10, 10), { x = 1, y = 1 })
    t.eq(true, session.pointer.pressed, "press starts pointer tracking")
    t.eq(session, interaction.captured_session(), "a press captures its session")
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
  -- Link dispatch: every classified type, unsafe rejection, and the
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

    -- Every way the hand-off to the OS can fail used to be silent, which made
    -- "the system refused this link" and "md-viewer never saw the click" look
    -- identical to the reader. vim.ui.open reports a missing handler by
    -- *returning* nil rather than raising, so pcall alone never caught it.
    notified = {}
    vim.ui.open = function() return nil, "no handler for scheme" end
    interaction.activate_link({}, { link = { type = "https", href = "https://example.invalid/c" } })
    t.eq(1, #notified, "a handler-less system open is reported instead of being swallowed")
    t.ok(notified[1].message:find("no system handler", 1, true) ~= nil, "and the message says the handler is missing")
    t.eq(
      "no handler: no handler for scheme",
      interaction.last_external.result,
      ":MdViewerDebug records what the system handler answered"
    )
    t.eq("https://example.invalid/c", interaction.last_external.href, "and which link it was for")

    notified = {}
    vim.ui.open = function() error("spawn failed") end
    interaction.activate_link({}, { link = { type = "https", href = "https://example.invalid/d" } })
    t.eq(1, #notified, "a raising system open is still reported")
    t.ok(notified[1].message:find("failed to open link", 1, true) ~= nil, "and named as a failure to open")

    -- A handler that starts and *then* fails is the case pcall cannot see at
    -- all: vim.ui.open returns as soon as the child is spawned. A real process
    -- is used here rather than a fake, because the whole point is that the
    -- exit status is observed without blocking the editor.
    notified = {}
    vim.ui.open = function() return vim.system({ "sh", "-c", "echo nope 1>&2; exit 3" }, { text = true }) end
    interaction.activate_link({}, { link = { type = "https", href = "https://example.invalid/e" } })
    vim.wait(4000, function() return #notified > 0 end)
    t.eq(1, #notified, "a system handler that exits non-zero is reported")
    t.ok(notified[1].message:find("nope", 1, true) ~= nil, "and the handler's own message is carried through")
    t.eq("nope", interaction.last_external.result, "and recorded for :MdViewerDebug")

    -- The successful case says nothing and records the clean exit.
    notified = {}
    vim.ui.open = function() return vim.system({ "true" }, { text = true }) end
    interaction.activate_link({}, { link = { type = "https", href = "https://example.invalid/f" } })
    vim.wait(4000, function() return interaction.last_external.result ~= "spawned" end)
    t.eq("exited 0", interaction.last_external.result, "a handler that exits cleanly is recorded as such")
    t.eq({}, notified, "and says nothing to the user")

    vim.ui.open = original_open
    vim.notify = original_notify
  end

  -- ---------------------------------------------------------------------
  -- A ctrl/cmd-click whose hit test fails outright is reported. Losing a race
  -- to a newer request for the same document is not: that is routine, and
  -- narrating it would fire on ordinary fast clicking.
  -- ---------------------------------------------------------------------
  do
    local session = fake_session()
    local original_request = process.request
    local original_notify, notified = vim.notify, {}
    vim.notify = function(message) notified[#notified + 1] = message end

    process.request = function(_, _, callback) callback(nil, "renderer said no", { code = "INVALID_INTERACTION" }) end
    interaction.activate(session, { x = 1, y = 1 }, { ctrl = true })
    t.eq(1, #notified, "a failed hit test is reported rather than dropped")
    t.ok(notified[1]:find("renderer said no", 1, true) ~= nil, "and it carries the renderer's own reason")

    notified = {}
    process.request = function(_, _, callback) callback(nil, "superseded", { code = "STALE_INTERACTION" }) end
    interaction.activate(session, { x = 1, y = 1 }, { ctrl = true })
    t.eq({}, notified, "losing a race to a newer request says nothing")

    process.request = original_request
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
      { interaction = { selection = "yes" } },
      { interaction = { preview_debounce_ms = -1 } },
      { interaction = { preview_debounce_ms = "40" } },
      { interaction = { fast_preview = "yes" } },
      { interaction = { visual = 0 } },
      { interaction = { settle_ms = -1 } },
      { interaction = { settle_ms = "120" } },
      { interaction = { copy = 1 } },
      { interaction = { copy_on_select = "no" } },
      { interaction = { find = "true" } },
    }) do
      local ok, err = pcall(config.setup, case)
      t.eq(false, ok, ("invalid interaction config is rejected: %s"):format(vim.inspect(case)))
      t.ok(tostring(err):match("interaction"), "the validation error names the interaction option")
    end
    config.reset()
  end

  -- ---------------------------------------------------------------------
  -- The optional envelope fields (anchorCoordinates, query) follow
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
    interaction.on_press(session, { screenrow = 1, screencol = 1 }, { x = 1, y = 1 })
    t.eq(session, interaction.captured_session(), "sanity: the session is captured before forget()")
    interaction.forget(session)
    t.eq(nil, interaction.captured_session(), "forget() releases a captured session")
    t.eq(nil, session.pointer, "forget() clears the session's pointer state")
  end

  -- ---------------------------------------------------------------------
  -- Document root: the boundary is the enclosing project, not the folder the
  -- document happens to sit in. Rooting it at the folder made every
  -- repo-relative link from a subdirectory ("../README.md", "docs/x.md")
  -- report as a security refusal.
  -- ---------------------------------------------------------------------
  do
    local project = vim.uv.fs_realpath((function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. "/docs", "p")
      vim.fn.mkdir(dir .. "/.git", "p")
      return dir
    end)())
    vim.fn.writefile({ "# readme" }, project .. "/README.md")
    vim.fn.writefile({ "# a" }, project .. "/docs/a.md")
    vim.fn.writefile({ "# b" }, project .. "/docs/b.md")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, project .. "/docs/a.md")
    local root = security.document_root(buf, nil, { ".git", ".hg", ".svn" })
    t.eq(project, root, "an unconfigured root is the nearest ancestor holding a marker")

    local base = project .. "/docs"
    t.eq(
      project .. "/README.md",
      security.resolve_local_link("../README.md", base, root),
      "a link out of the document's folder but inside the project resolves"
    )
    t.eq(project .. "/docs/b.md", security.resolve_local_link("b.md", base, root), "a sibling link still resolves")
    t.eq(
      project .. "/docs/a.md",
      security.resolve_local_link("docs/a.md", project, root),
      "a project-root-relative link resolves"
    )

    -- Widening the root must not widen containment itself.
    local _, escape_reason = security.resolve_local_link("../../etc/passwd", base, root)
    t.eq("outside_root", escape_reason, "an escape above the project root is still refused")

    -- No marker anywhere: the previous behaviour, unchanged.
    local bare = vim.uv.fs_realpath((function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. "/nested", "p")
      return dir
    end)())
    local bare_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bare_buf, bare .. "/nested/doc.md")
    t.eq(
      bare .. "/nested",
      security.document_root(bare_buf, nil, { ".git", ".hg", ".svn" }),
      "with no marker found the root falls back to the document's own folder"
    )
    t.eq(
      "/explicit/root",
      security.document_root(buf, "/explicit/root", { ".git" }),
      "an explicitly configured root always wins"
    )
  end

  -- ---------------------------------------------------------------------
  -- A refusal must say which refusal it was. All three used to arrive as
  -- "outside the document root", which for a link to a file that is simply
  -- not there is untrue.
  -- ---------------------------------------------------------------------
  do
    local root = vim.uv.fs_realpath((function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      return dir
    end)())
    vim.fn.writefile({ "x" }, root .. "/real.md")

    local resolved, reason = security.resolve_local_link("real.md", root, root)
    t.eq(root .. "/real.md", resolved, "an existing in-root target resolves")
    t.eq(nil, reason, "a successful resolution reports no reason")

    local missing, missing_reason = security.resolve_local_link("nope.md", root, root)
    t.eq(nil, missing, "a nonexistent in-root target does not resolve")
    t.eq("missing", missing_reason, "a nonexistent in-root target is reported as missing, not as an escape")

    local _, outside_reason = security.resolve_local_link("../elsewhere.md", root, root)
    t.eq("outside_root", outside_reason, "a path above the root is reported as an escape")

    local _, empty_reason = security.resolve_local_link("", root, root)
    t.eq("malformed", empty_reason, "an empty href is reported as malformed")

    -- A path outside the root must be refused without the filesystem being
    -- consulted, so the two messages cannot be used to probe for the
    -- existence of files the reader is not allowed to reach.
    local _, absent_outside = security.resolve_local_link("../definitely-not-here.md", root, root)
    t.eq("outside_root", absent_outside, "an out-of-root path is refused as an escape whether or not it exists")
  end

  -- ---------------------------------------------------------------------
  -- Activating a local link opens the document in Neovim, in the source
  -- window, rather than handing it to the OS.
  -- ---------------------------------------------------------------------
  do
    local project = vim.uv.fs_realpath((function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. "/.git", "p")
      return dir
    end)())
    vim.fn.writefile({ "# target" }, project .. "/target.md")
    vim.fn.writefile({ "png" }, project .. "/picture.png")
    vim.fn.writefile({ "# doc" }, project .. "/doc.md")

    local opened = {}
    local original_open = vim.ui.open
    vim.ui.open = function(target)
      opened[#opened + 1] = target
      return { wait = function() end }
    end
    local original_notify, notified = vim.notify, {}
    vim.notify = function(message) notified[#notified + 1] = message end

    -- A real window and a real file-backed buffer: `:edit` is exercised, not
    -- stubbed, so the jump-list push and the buffer swap are the real ones.
    vim.cmd.edit(vim.fn.fnameescape(project .. "/doc.md"))
    local source_win = vim.api.nvim_get_current_win()
    local source_buf = vim.api.nvim_get_current_buf()
    local session = { source_buf = source_buf, source_win = source_win }

    interaction.activate_link(session, { link = { type = "local_file", href = "target.md" } })
    t.eq({}, opened, "a markdown link is not handed to the OS handler")
    t.eq(
      project .. "/target.md",
      vim.fs.normalize(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(source_win))),
      "a markdown link is edited in the source window"
    )

    opened, notified = {}, {}
    interaction.activate_link(session, { link = { type = "local_file", href = "picture.png" } })
    t.eq({ project .. "/picture.png" }, opened, "a file Neovim has no filetype for still goes to the OS handler")

    -- A link must never be able to ask the OS to run something. The document
    -- root is not a defence here: this file sits inside it, exactly as a
    -- cloned repository could ship one beside its README.
    vim.fn.writefile({ "#!/bin/sh", "echo pwned" }, project .. "/setup.command")
    vim.fn.writefile({ "#!/bin/sh", "echo pwned" }, project .. "/plain-script")
    vim.fn.mkdir(project .. "/Evil.app", "p")
    vim.uv.fs_chmod(project .. "/plain-script", tonumber("755", 8))
    vim.fn.writefile({ "notes" }, project .. "/notes.rst-unknown")

    for _, href in ipairs({ "setup.command", "plain-script", "Evil.app" }) do
      opened, notified = {}, {}
      interaction.activate_link(session, { link = { type = "local_file", href = href } })
      t.eq({}, opened, ("an executable link (%s) is never handed to the system handler"):format(href))
      t.ok(
        #notified > 0 and notified[1]:find("executable", 1, true) ~= nil,
        ("refusing %s says it was refused for being executable"):format(href)
      )
    end

    -- The guard must not swallow ordinary files that simply have no filetype.
    opened, notified = {}, {}
    interaction.activate_link(session, { link = { type = "local_file", href = "notes.rst-unknown" } })
    t.eq(
      { project .. "/notes.rst-unknown" },
      opened,
      "a non-executable file Neovim cannot type still reaches the system handler"
    )

    t.eq(true, security.is_system_executable(project .. "/setup.command"), "a .command is an executable target")
    t.eq(true, security.is_system_executable(project .. "/Evil.app"), "an .app bundle is an executable target")
    t.eq(true, security.is_system_executable(project .. "/plain-script"), "the execute bit alone is enough")
    t.eq(
      false,
      security.is_system_executable(project .. "/notes.rst-unknown"),
      "an ordinary unreadable-by-filetype file is not"
    )
    t.eq(false, security.is_system_executable(project .. "/picture.png"), "a plain image is not")
    t.eq(false, security.is_system_executable(project), "a plain directory is not, despite its mode bits")
    -- Name alone is enough to refuse: the extension check never touches the
    -- filesystem, so it does not depend on the target existing. (In practice
    -- `resolve_local_link` rejects a missing target before this is reached.)
    t.eq(true, security.is_system_executable(project .. "/missing.command"), "a missing .command is refused by name")
    t.eq(false, security.is_system_executable(project .. "/missing.txt-unknown"), "a missing plain name is not refused")

    opened, notified = {}, {}
    interaction.activate_link(session, { link = { type = "local_file", href = "gone.md" } })
    t.eq({}, opened, "a missing target is never opened")
    t.ok(
      #notified > 0 and notified[1]:find("does not exist", 1, true) ~= nil,
      "a missing target is reported as missing rather than as a security refusal"
    )

    vim.ui.open = original_open
    vim.notify = original_notify
    vim.cmd("enew!")
  end

  -- ---------------------------------------------------------------------
  -- A configured root that excludes the document being previewed refuses
  -- every local link and image in it. That is correct for the setting, but on
  -- its own it surfaces one refusal at a time and reads as a broken plugin --
  -- a real configuration shipped exactly this way, pinning every preview to
  -- an Obsidian vault. :MdViewerHealth names the condition once.
  -- ---------------------------------------------------------------------
  do
    local elsewhere = vim.uv.fs_realpath((function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      return dir
    end)())
    local project = vim.uv.fs_realpath((function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. "/.git", "p")
      return dir
    end)())
    vim.fn.writefile({ "# doc" }, project .. "/doc.md")

    -- A buffer that merely carries the name is enough: summary() only reads the
    -- name and the config. Nothing here becomes the current buffer, so no other
    -- case can observe this one having run.
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, project .. "/doc.md")

    local function summary(opts)
      config.reset()
      config.setup(opts)
      return security.summary(config.get(), buf)
    end

    local pinned = summary({ security = { document_root = elsewhere } })
    t.eq(true, pinned.document_root_excludes_current, "a configured root excluding the document is reported")
    t.eq(elsewhere, pinned.document_root, "the reported root is the configured one")
    t.eq("configured (security.document_root)", pinned.document_root_source, "and it is named as configured")

    local detected = summary({})
    t.eq(false, detected.document_root_excludes_current, "a detected project root never excludes its own document")
    t.eq(project, detected.document_root, "the detected root is the enclosing project")
    t.eq(
      "detected from the project enclosing the document",
      detected.document_root_source,
      "and it is named as detected"
    )

    local contained = summary({ security = { document_root = project } })
    t.eq(false, contained.document_root_excludes_current, "a configured root containing the document is not flagged")

    vim.api.nvim_buf_delete(buf, { force = true })
    config.reset()
    config.setup({})
  end

  -- ---------------------------------------------------------------------
  -- Retargeting: one preview window follows a link to another document.
  -- ---------------------------------------------------------------------
  do
    local session = state.create(7001, 1)
    session.renderer_revision = "3:0"
    session.latest_blocks = { { sourceStart = 0 } }
    session.scroll_y, session.applied_scroll_y = 400, 400
    local serial_before = session.request_serial

    t.eq(session, state.retarget(session, 7002), "retarget moves the session onto the new buffer")
    t.eq(7002, session.source_buf, "retarget updates the session's source buffer")
    t.eq("buffer-7002", session.document_id, "retarget re-derives the document id")
    t.eq(nil, state.get(7001), "retarget releases the old buffer's key")
    t.eq(session, state.get(7002), "retarget registers the new buffer's key")

    -- A second session already owning the target must not be stolen.
    local other = state.create(7003, 1)
    t.eq(nil, state.retarget(session, 7003), "retarget refuses a buffer another session already owns")
    t.eq(7002, session.source_buf, "a refused retarget leaves the session where it was")
    t.eq(other, state.get(7003), "a refused retarget leaves the other session intact")
    t.eq(serial_before, session.request_serial, "state.retarget alone does not bump the serial")

    state.remove(7002)
    state.remove(7003)
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
