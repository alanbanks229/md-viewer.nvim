-- Pane-scoped preview history is independent of both the editable source
-- window and the set of currently open preview tabs.
return function(t)
  local config = require("md-viewer.config")
  local controller = require("md-viewer.controller")
  local interaction = require("md-viewer.interaction")
  local state = require("md-viewer.state")

  local project = vim.uv.fs_realpath((function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/.git", "p")
    return dir
  end)())
  vim.fn.writefile({ "# A", "", "[to b](b.md)" }, project .. "/a.md")
  vim.fn.writefile({ "# B", "", "[to c](c.md)" }, project .. "/b.md")
  vim.fn.writefile({ "# C" }, project .. "/c.md")

  require("md-viewer").setup({})
  vim.cmd.edit(vim.fn.fnameescape(project .. "/a.md"))
  local document_a = assert(controller.open("right"))
  local pane, source_win = document_a.pane, document_a.source_win
  local source_buf = vim.api.nvim_win_get_buf(source_win)
  local backend = {
    name = "kitty_raw",
    clear = function() return true end,
    show = function() return 1 end,
    update = function() return 1 end,
    move = function() return true end,
  }
  document_a.backend = backend
  local original_refresh = controller.refresh
  controller.refresh = function() end

  interaction.activate_link(document_a, { link = { type = "local_file", href = "b.md" } })
  local document_b = pane.active
  interaction.activate_link(document_b, { link = { type = "local_file", href = "c.md" } })
  local document_c = pane.active

  t.eq(3, #pane.documents, "linked Markdown files get distinct pane documents")
  t.ok(document_a.preview_buf ~= document_b.preview_buf, "each document has a stable preview buffer")
  t.ok(document_b.preview_buf ~= document_c.preview_buf, "a third document has a third buffer")
  t.eq(source_buf, vim.api.nvim_win_get_buf(source_win), "link navigation never replaces the editable source")
  t.eq(3, #pane.history, "link navigation appends pane history")
  t.eq(3, pane.history_index, "history points at the linked destination")

  controller.history_back()
  t.eq(document_b, pane.active, "history back activates the prior preview document")
  t.eq(source_buf, vim.api.nvim_win_get_buf(source_win), "history back leaves the source pane untouched")
  controller.history_forward(document_b)
  t.eq(document_c, pane.active, "history forward restores the next preview document")

  controller.activate_document(document_a)
  t.eq(1, pane.history_index, "tab selection aligns to that document's most recent history entry")

  -- document_a sits at the oldest entry: repeated history_back calls here
  -- must not spam vim.notify, only report the dead end once.
  do
    local notified = 0
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if tostring(msg):find("no previous document", 1, true) then notified = notified + 1 end
    end
    controller.history_back(pane.active)
    controller.history_back(pane.active)
    controller.history_back(pane.active)
    t.eq(1, notified, "repeated history_back at the boundary notifies only once")
    -- Forward then back twice: the first back only returns to document_a's
    -- entry (a real move, not the boundary); the second is what walks past
    -- it again and should re-fire the notification.
    controller.history_forward(pane.active)
    controller.history_back(pane.active)
    controller.history_back(pane.active)
    t.eq(2, notified, "moving away from the boundary and back re-arms the notification")
    t.eq(document_a, pane.active, "the round trip lands back on the oldest document")
    t.eq(1, pane.history_index, "the round trip leaves the index back at the oldest entry")
    vim.notify = original_notify
  end

  controller.activate_document(document_c)
  t.eq(3, pane.history_index, "tab selection does not append history")
  t.eq(3, #pane.history, "tab selection leaves history length unchanged")

  local closed_b_buf, closed_b_source = document_b.preview_buf, document_b.source_buf
  controller.tab_close(document_b)
  t.eq(nil, state.from_preview(closed_b_buf), "closing an inactive tab removes its preview document")
  t.eq(3, #pane.history, "closing a tab preserves its history entry")
  controller.history_back(document_c)
  local recreated_b = pane.active
  t.eq(closed_b_source, recreated_b.source_buf, "history recreates a closed preview document")
  t.ok(recreated_b.preview_buf ~= closed_b_buf, "the recreated document receives a fresh real buffer")
  t.eq(source_buf, vim.api.nvim_win_get_buf(source_win), "history recreation still isolates the source pane")

  local before_count, before_buf = #pane.documents, recreated_b.preview_buf
  interaction.activate_link(recreated_b, { link = { type = "local_file", href = "c.md" } })
  t.eq(before_count, #pane.documents, "a repeated link reuses an existing preview document")
  controller.history_back(pane.active)
  t.eq(before_buf, pane.active.preview_buf, "the reused document keeps its stable preview buffer")

  config.reset()
  config.setup({ interaction = { history_limit = 2 } })
  local bounded = { source_buf = 1, history = nil, history_index = 0 }
  controller.history_init(bounded)
  for buf = 2, 6 do
    controller.history_push(bounded, buf)
  end
  t.eq(2, #bounded.history, "history is capped at interaction.history_limit")
  t.eq(6, bounded.history[2].buf, "the bounded history retains the newest entry")
  config.reset()
  config.setup({})

  vim.fn.mkdir(project .. "/one", "p")
  vim.fn.mkdir(project .. "/two", "p")
  vim.fn.writefile({ "# One" }, project .. "/one/readme.md")
  vim.fn.writefile({ "# Two" }, project .. "/two/readme.md")
  local one = vim.fn.bufadd(project .. "/one/readme.md")
  local two = vim.fn.bufadd(project .. "/two/readme.md")
  vim.fn.bufload(one)
  vim.fn.bufload(two)
  controller.retarget(pane.active, one)
  controller.retarget(pane.active, two)
  local winbar = vim.wo[pane.preview_win].winbar
  t.ok(winbar:find("one/readme.md", 1, true) ~= nil, "duplicate filenames gain a shortest unique path label")
  t.ok(winbar:find("two/readme.md", 1, true) ~= nil, "both duplicate labels are unambiguous")

  local first_click = tonumber(winbar:match("%%(%d+)@v:lua%.MdViewerWinbarClick@"))
  local first_document = pane.documents[1]
  _G.MdViewerWinbarClick(first_click, 1, "l", "")
  t.eq(first_document, pane.active, "left-clicking a winbar tab activates its stable preview buffer")
  t.eq(source_buf, vim.api.nvim_win_get_buf(source_win), "winbar tab clicks leave the editable source untouched")
  first_click = tonumber(vim.wo[pane.preview_win].winbar:match("%%(%d+)@v:lua%.MdViewerWinbarClick@"))
  _G.MdViewerWinbarClick(first_click, 1, "m", "")
  t.eq(true, first_document.closed, "middle-clicking a winbar tab closes that preview document")

  local revealed = pane.active.source_buf
  controller.reveal_source(pane.active)
  t.eq(revealed, vim.api.nvim_win_get_buf(source_win), "source reveal is the explicit path that replaces source")
  t.eq(source_win, vim.api.nvim_get_current_win(), "source reveal deliberately focuses the editable pane")

  controller.refresh = original_refresh
  controller.close(pane.active.source_buf)
  vim.cmd("enew!")
end
