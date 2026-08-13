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

    interaction.on_press(session, { screenrow = 1, screencol = 1, winid = session.preview_win }, { x = 5, y = 5 }, 1)
    interaction.on_drag(session, { screenrow = 1, screencol = 5, winid = session.preview_win })
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

  config.reset()
end
