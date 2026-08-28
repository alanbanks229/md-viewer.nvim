return function(t)
  -- Every exit path must release what it owns. `controller.lua`'s
  -- other test files already exercise TabLeave/VimSuspend end to end (real
  -- `vim.cmd("tabnew")`/`tabclose"`, see tabpage_placement.lua) and ordinary
  -- `controller.close()` (mouse.lua, controller.lua). This file covers the
  -- paths nothing else does: BufWipeout firing for real, VimLeavePre's
  -- `close_all`, and a selection request still in flight when its session
  -- closes underneath it.
  local config = require("md-viewer.config")
  local controller = require("md-viewer.controller")
  local state = require("md-viewer.state")
  local mouse = require("md-viewer.mouse")
  local backends = require("md-viewer.backends")
  local interaction = require("md-viewer.interaction")
  local process = require("md-viewer.process")

  config.reset()
  require("md-viewer").setup({})

  local function stub_backend()
    local cleared = {}
    return {
      name = "kitty_raw",
      clear = function(image_id)
        cleared[#cleared + 1] = image_id
        return true
      end,
      show = function() return 1 end,
      update = function() return 1 end,
      move = function() return true end,
      clear_all = function() end,
    },
      cleared
  end

  -- Each call opens its source buffer in a fresh window: `preview.pinned`
  -- defaults to true, and M.open() reuses whatever session is already pinned
  -- to the *current window* regardless of which buffer is in it, so two
  -- sessions opened from the same window would silently collapse into one.
  -- `nvim_open_win(buf, ...)` opens the new window showing `buf` from the
  -- very first frame -- unlike `:new` followed by `nvim_win_set_buf`, which
  -- briefly shows the *previous* window's buffer in the new window first
  -- (its own fresh empty buffer swaps in a tick later) and fires WinEnter
  -- for that transient state. `controller.lua`'s own WinEnter/BufEnter
  -- autocmd would read that transient buffer as "the source buffer just
  -- entered its own window" and reassign the *other* session's `source_win`
  -- to this new window, which is exactly the kind of mispointed session this
  -- test exists to catch elsewhere -- but is a false positive here, an
  -- artifact of how the test builds its fixture, not of md-viewer.
  local function open_graphical_session()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_open_win(buf, true, { split = "above", win = -1 })
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# T", "", "body" })
    local source_win = vim.api.nvim_get_current_win()
    local session = assert(controller.open("right"))
    local backend, cleared = stub_backend()
    session.backend = backend
    session.image_id = 501
    session.last_placement = { row = 0, col = 0, width = 80, height = 24, exclusions = {} }
    session.viewport_width_px = 800
    session.viewport_height_render_px = 600
    mouse.attach(controller.navigate)
    return buf, session, cleared, source_win
  end

  -- ---------------------------------------------------------------------
  -- BufWipeout on the source buffer: session removed, image cleared,
  -- mappings restored (this was the only graphical session).
  -- ---------------------------------------------------------------------
  do
    local buf, session, cleared, source_win = open_graphical_session()
    t.eq(true, mouse.is_attached(), "sanity: opening a graphical session installs mouse dispatch")

    vim.api.nvim_buf_call(buf, function() vim.api.nvim_exec_autocmds("BufWipeout", { buffer = buf }) end)
    -- BufWipeout's own callback runs synchronously off nvim_exec_autocmds;
    -- give any vim.schedule-deferred bookkeeping (mouse.detach_if_unused
    -- runs inline, but be defensive the same way the rest of the suite is).
    vim.wait(200, function() return state.get(buf) == nil end, 10)

    t.eq(nil, state.get(buf), "BufWipeout removes the session from state")
    t.eq({ 501 }, cleared, "BufWipeout clears the backend image")
    t.eq(nil, session.image_id, "BufWipeout drops the session's image id")
    t.eq(nil, session.last_placement, "BufWipeout drops the stale placement")
    t.eq(false, mouse.is_attached(), "BufWipeout of the last graphical session restores mouse mappings")

    pcall(vim.api.nvim_win_close, source_win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  -- ---------------------------------------------------------------------
  -- BufWipeout on the *preview* buffer (e.g. `:bwipeout` run from inside the
  -- preview split itself) reaches the same session via state.from_preview.
  -- ---------------------------------------------------------------------
  do
    local buf, session, cleared, source_win = open_graphical_session()
    local preview_buf = session.preview_buf

    vim.api.nvim_buf_call(
      preview_buf,
      function() vim.api.nvim_exec_autocmds("BufWipeout", { buffer = preview_buf }) end
    )
    vim.wait(200, function() return state.get(buf) == nil end, 10)

    t.eq(nil, state.get(buf), "wiping the preview buffer also closes the session")
    t.eq({ 501 }, cleared, "wiping the preview buffer still clears the backend image")

    pcall(vim.api.nvim_win_close, source_win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  -- ---------------------------------------------------------------------
  -- VimLeavePre -> close_all: every open session's image is cleared, every
  -- backend's clear_all() runs, and mouse mappings are restored -- not just
  -- for the last session closed, but as a single sweep across all of them.
  -- ---------------------------------------------------------------------
  do
    local buf1, session1, cleared1, source_win1 = open_graphical_session()
    local buf2, session2, cleared2, source_win2 = open_graphical_session()
    t.eq(true, mouse.is_attached(), "sanity: two graphical sessions are open")

    local original_kitty_clear_all = backends.get("kitty_raw").clear_all
    local original_nvim_img_clear_all = backends.get("nvim_img").clear_all
    local clear_all_calls = { kitty_raw = 0, nvim_img = 0 }
    backends.get("kitty_raw").clear_all = function() clear_all_calls.kitty_raw = clear_all_calls.kitty_raw + 1 end
    backends.get("nvim_img").clear_all = function() clear_all_calls.nvim_img = clear_all_calls.nvim_img + 1 end

    vim.api.nvim_exec_autocmds("VimLeavePre", {})

    t.eq(nil, state.get(buf1), "VimLeavePre closes every open session, not just the current one")
    t.eq(nil, state.get(buf2), "VimLeavePre closes every open session, not just the current one")
    t.eq({ 501 }, cleared1, "VimLeavePre clears the first session's image")
    t.eq({ 501 }, cleared2, "VimLeavePre clears the second session's image")
    t.eq(1, clear_all_calls.kitty_raw, "VimLeavePre sweeps kitty_raw's own clear_all as a backstop")
    t.eq(1, clear_all_calls.nvim_img, "VimLeavePre sweeps nvim_img's own clear_all as a backstop")
    t.eq(false, mouse.is_attached(), "VimLeavePre restores mouse mappings")
    t.eq(false, process.status().running, "VimLeavePre stops the renderer subprocess")

    backends.get("kitty_raw").clear_all = original_kitty_clear_all
    backends.get("nvim_img").clear_all = original_nvim_img_clear_all
    pcall(vim.api.nvim_win_close, source_win1, true)
    pcall(vim.api.nvim_win_close, source_win2, true)
    pcall(vim.api.nvim_buf_delete, buf1, { force = true })
    pcall(vim.api.nvim_buf_delete, buf2, { force = true })
  end

  -- ---------------------------------------------------------------------
  -- A selection request still in flight when its session closes must not
  -- crash when its callback eventually fires, and must not resurrect any
  -- image/mapping state the close already tore down.
  -- ---------------------------------------------------------------------
  do
    local buf, session, _, source_win = open_graphical_session()
    local original_request = process.request
    local pending_callback
    process.request = function(_, _, callback) pending_callback = callback end

    local original_display = require("md-viewer.controller").display_interact_result
    local displayed = 0
    require("md-viewer.controller").display_interact_result = function() displayed = displayed + 1 end

    session.caret_rect = { x = 5, y = 5, width = 10, height = 20 }
    session.caret_scroll_y = session.applied_scroll_y or 0
    interaction.visual_start(session, false)
    vim.wait(500, function() return pending_callback ~= nil end, 10)
    t.ok(pending_callback ~= nil, "sanity: a selection_preview request is in flight")

    controller.close(buf)
    t.eq(nil, state.get(buf), "sanity: the session is fully closed before the request answers")

    local ok = pcall(pending_callback, { kind = "selection", ok = true, text = "late", collapsed = false }, nil)
    t.eq(true, ok, "a selection response arriving after close does not error")
    t.eq(
      0,
      displayed,
      "a selection response arriving after close never displays -- there is nothing left to show it on"
    )

    process.request = original_request
    require("md-viewer.controller").display_interact_result = original_display
    pcall(vim.api.nvim_win_close, source_win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  -- ---------------------------------------------------------------------
  -- VimLeavePre detaches an attached local-render helper, not just the
  -- ordinary sessions close_all already tears down.
  --
  -- Without this, the operator's own workflow -- one helper process
  -- wrapping one long-lived ssh session, with Neovim itself quit and
  -- reopened many times inside it -- left the control-socket connection to
  -- die from the OS (an unhandled EOF) rather than a real close the
  -- helper's socket server could react to. Nothing on the helper side ever
  -- learned the outgoing session was gone, so its per-document state
  -- (epoch, seq floor) persisted across every restart -- and a fresh
  -- Neovim process regenerates the identical documentId ("buffer-1") for
  -- the same file, so its first frame could be silently refused as stale
  -- against a counter the session that just quit left elevated. Measured
  -- live as a preview rendering solid black on reopen (2026-08-27).
  -- ---------------------------------------------------------------------
  do
    local localrender = require("md-viewer.localrender")
    local TOKEN = ("ab"):rep(16)
    local tmp = vim.fn.tempname()
    local dir = tmp .. "/md-viewer"
    vim.fn.mkdir(dir, "p")
    vim.uv.fs_chmod(dir, 448) -- 0700
    local real_runtime = vim.env.XDG_RUNTIME_DIR
    vim.env.XDG_RUNTIME_DIR = tmp

    local sock_path = dir .. "/r-leave01.sock"
    local server_client -- the socket server's end of the accepted connection
    local server_saw_close = false
    local server = vim.uv.new_pipe(false)
    assert(server:bind(sock_path))
    vim.uv.fs_chmod(sock_path, 384) -- 0600
    server:listen(16, function(err)
      assert(not err, err)
      local client = vim.uv.new_pipe(false)
      server:accept(client)
      server_client = client
      local buffer = ""
      client:read_start(function(rerr, data)
        if rerr or not data then
          server_saw_close = true
          return
        end
        buffer = buffer .. data
        while true do
          local nl = buffer:find("\n", 1, true)
          if not nl then break end
          local line = buffer:sub(1, nl - 1)
          buffer = buffer:sub(nl + 1)
          local message = vim.json.decode(line, { luanil = { object = true } })
          if message.method == "hello" then
            client:write(vim.json.encode({
              id = message.id,
              ok = true,
              result = {
                protocol = localrender.PROTOCOL,
                helperVersion = "md-viewer-local vtest",
                token = TOKEN,
                terminal = { kittyGraphics = "verified" },
              },
            }) .. "\n")
          end
        end
      end)
    end)

    local real_ui_send = vim.api.nvim_ui_send
    local sent_ui = {}
    vim.api.nvim_ui_send = function(bytes) sent_ui[#sent_ui + 1] = bytes end
    vim.env.MD_VIEWER_LOCAL_SOCKET = sock_path

    local attach_ok
    localrender.attach(function(ok) attach_ok = ok end)
    vim.wait(3000, function() return #sent_ui > 0 end, 10)
    t.ok(
      sent_ui[1] and sent_ui[1]:find(";t=" .. TOKEN .. ";s=0;", 1, true),
      "sanity: the pairing probe carrying the hello's token reached the terminal stream"
    )
    -- Confirm the probe over the socket, the same way the real helper would
    -- once its own filter sees the marker on this terminal.
    server_client:write(vim.json.encode({ event = "presented", seq = 0 }) .. "\n")
    vim.wait(3000, function() return attach_ok ~= nil end, 10)
    t.eq(true, attach_ok, "sanity: local render is attached before VimLeavePre fires")
    t.eq(true, localrender.active(), "sanity: phase is attached")

    vim.api.nvim_exec_autocmds("VimLeavePre", {})
    vim.wait(1000, function() return server_saw_close end, 10)

    t.eq(true, server_saw_close, "VimLeavePre closed the control-socket connection the helper's server can see")
    t.eq(false, localrender.active(), "VimLeavePre detached local render, not only close_all's ordinary sessions")

    vim.api.nvim_ui_send = real_ui_send
    server:close()
    if vim.uv.fs_stat(sock_path) then vim.uv.fs_unlink(sock_path) end
    localrender._reset()
    vim.env.MD_VIEWER_LOCAL_SOCKET = nil
    vim.env.XDG_RUNTIME_DIR = real_runtime
  end

  config.reset()
end
