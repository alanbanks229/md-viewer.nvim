-- The seam between buffer acceptance and the render request: a remote-named
-- buffer must open as a remote session (mirror paths in the request, renders
-- deferred until the root is known) or be refused -- never fall through to
-- local path handling, which would mangle the URL and root the document in
-- whatever project encloses the cwd.
return function(t)
  local config = require("md-viewer.config")
  local controller = require("md-viewer.controller")
  local process = require("md-viewer.process")
  local remote_assets = require("md-viewer.remote_assets")
  local state = require("md-viewer.state")

  require("md-viewer").setup({ render = { debounce_ms = 0 } })

  -- Held transport: remote_attach's root walk parks here until the test
  -- releases it, which is what makes the deferral observable.
  local saved_run = remote_assets._run
  local held = {}
  remote_assets._run = function(argv, _opts, on_exit) held[#held + 1] = { argv = argv, on_exit = on_exit } end
  local function release(reply)
    local job = table.remove(held, 1)
    job.on_exit(reply)
  end

  local saved_request = process.request
  local requests = {}
  process.request = function(method, params)
    requests[#requests + 1] = { method = method, params = params }
    return #requests
  end

  local saved_notify = vim.notify
  local notified = {}
  vim.notify = function(message) notified[#notified + 1] = tostring(message) end

  local fake_backend = {
    name = "kitty_raw",
    clear = function() return true end,
    show = function() return 1 end,
    update = function() return 1 end,
    move = function() return true end,
  }

  local function fabricate(name, buftype, lines)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, name)
    if buftype and buftype ~= "" then vim.bo[buf].buftype = buftype end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "# Remote", "", "![a](images/arch.png)" })
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  -- Refusals: everything that was refused before stays refused, and a remote
  -- name with the feature off is refused rather than treated as local.
  fabricate("oil:///Users/alan/project", "acwrite")
  t.eq(nil, controller.open("right"), "an acwrite buffer with a non-remote name is refused")
  t.ok(notified[#notified]:find("normal Markdown buffer", 1, true) ~= nil, "with the existing message")

  fabricate("rsync://dev-vm//home/alan/project/docs/guide.md", "acwrite")
  config.setup({ remote = { enabled = false } })
  t.eq(nil, controller.open("right"), "a remote name with remote.enabled=false is refused")
  t.ok(notified[#notified]:find("remote.enabled", 1, true) ~= nil, "and the refusal names the setting")
  config.setup({ render = { debounce_ms = 0 } })

  -- Acceptance: acwrite plus a parseable name opens a remote session, and the
  -- first render defers until the root walk answers.
  local remote_buf = fabricate("rsync://alan@dev-vm//home/alan/project/docs/guide.md", "acwrite")
  local session = assert(controller.open("right"), "a remote-ssh.nvim-shaped buffer opens a preview")
  t.ok(session.remote ~= nil, "the session knows it is remote")
  t.eq(false, session.remote.ready, "the root walk has not answered yet")
  t.eq(1, #held, "exactly one transport call is in flight (the root walk)")

  session.backend = fake_backend
  controller.refresh(session)
  t.eq(0, #requests, "a render before the root is known sends nothing")
  t.eq(true, session.remote.pending_refresh, "and is remembered instead of dropped")

  release({
    code = 0,
    stdout = "outcome=ok\ndoc=/home/alan/project/docs/guide.md\nbase=/home/alan/project/docs\nroot=/home/alan/project\n",
  })
  vim.wait(2000, function() return #requests > 0 end)
  t.eq(true, session.remote.ready, "the root walk completes the session")
  t.eq("/home/alan/project", session.remote.root, "the project root came from the walk")
  local request = requests[#requests]
  t.eq("render", request.method, "the deferred render fires once the root is known")
  t.eq(session.remote.mirror_root, request.params.documentRoot, "the security boundary is the mirror root")
  t.eq(session.remote.mirror_base_dir, request.params.baseDir, "relative paths resolve inside the mirror")
  t.eq(
    vim.fs.joinpath(session.remote.mirror_root, "docs"),
    session.remote.mirror_base_dir,
    "the mirror preserves the document's place in the project"
  )
  t.ok(vim.uv.fs_stat(session.remote.mirror_root) ~= nil, "the mirror root exists before the renderer sees it")
  t.ok(request.params.markdown:find("![a](images/arch.png)", 1, true) ~= nil, "the buffer text travels in the request")
  local mirror_to_clean = session.remote.mirror_root

  -- Retargeting to a local document drops the remote state and the request
  -- goes back to real local paths.
  local project = vim.uv.fs_realpath((function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/.git", "p")
    return dir
  end)())
  vim.fn.writefile({ "# Local" }, project .. "/local.md")
  local local_buf = vim.fn.bufadd(project .. "/local.md")
  vim.fn.bufload(local_buf)
  t.eq(true, controller.retarget(session, local_buf), "retargeting to a local file succeeds")
  t.eq(nil, session.remote, "and clears the remote state")
  vim.wait(2000, function() return requests[#requests].params.documentRoot == project end)
  local local_request = requests[#requests]
  t.eq(project, local_request.params.documentRoot, "a local document's boundary is its project again")
  t.eq(project, local_request.params.baseDir, "and its base is its own directory")

  -- Retargeting back to a remote document re-attaches and defers again.
  local remote_two = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(remote_two, "rsync://alan@dev-vm//home/alan/project/README.md")
  vim.api.nvim_buf_set_lines(remote_two, 0, -1, false, { "# Two" })
  local before = #requests
  t.eq(true, controller.retarget(session, remote_two), "retargeting to a remote name succeeds")
  t.ok(session.remote ~= nil and session.remote.ready == false, "the new document starts its own root walk")
  t.eq(before, #requests, "nothing renders until it answers")
  release({
    code = 0,
    stdout = "outcome=ok\ndoc=/home/alan/project/README.md\nbase=/home/alan/project\nroot=/home/alan/project\n",
  })
  vim.wait(2000, function() return #requests > before end)
  t.eq(
    session.remote.mirror_root,
    requests[#requests].params.documentRoot,
    "the re-attached session renders against its mirror"
  )

  -- Retargeting to a remote name while the feature is disabled is refused
  -- outright -- the alternative is rendering it with local path handling.
  config.setup({ remote = { enabled = false }, render = { debounce_ms = 0 } })
  local remote_three = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(remote_three, "scp://dev-vm//srv/notes.md")
  t.eq(false, controller.retarget(session, remote_three), "retarget refuses a remote name when disabled")
  config.setup({ render = { debounce_ms = 0 } })

  -- A provider filling the buffer later (BufReadCmd + async read, or :e!)
  -- must re-render: none of that fires TextChanged.
  local refreshes = 0
  local saved_refresh = controller.refresh
  controller.refresh = function() refreshes = refreshes + 1 end
  vim.api.nvim_exec_autocmds("BufReadPost", { buffer = session.source_buf })
  vim.wait(1000, function() return refreshes > 0 end)
  t.ok(refreshes > 0, "BufReadPost on the source schedules a render")
  controller.refresh = saved_refresh

  -- A remote name with no special buftype still opens as remote: the *name*
  -- is what local path handling cannot be trusted with.
  controller.close(session.source_buf)
  local plain_named = fabricate("scp://dev-vm//srv/wiki/page.md", "")
  local plain_session = assert(controller.open("right"), "a remote name with empty buftype opens")
  t.ok(plain_session.remote ~= nil, "as a remote session, decided by the name alone")
  controller.close(plain_named)
  -- Its root walk is still parked; answering after the close must be inert.
  release({ code = 124, stdout = "", stderr = "" })
  t.eq(nil, held[1], "no transport call is still pending")

  -- History entries for remote documents keep the URL verbatim.
  local entry_name = "rsync://alan@dev-vm//home/alan/project/HISTORY.md"
  fabricate(entry_name, "acwrite", { "# H" })
  local history_session = assert(controller.open("right"))
  t.eq(entry_name, history_session.history[1].path, "the history stores the remote name unmangled")
  controller.close(history_session.source_buf)
  release({ code = 124, stdout = "", stderr = "" })

  remote_assets._run = saved_run
  process.request = saved_request
  vim.notify = saved_notify
  for _, buf in ipairs({ remote_buf, local_buf, remote_two, remote_three }) do
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
  end
  if mirror_to_clean then vim.fn.delete(mirror_to_clean, "rf") end
  vim.fn.delete(project, "rf")
end
