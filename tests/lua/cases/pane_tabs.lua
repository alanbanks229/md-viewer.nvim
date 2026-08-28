return function(t)
  local config = require("md-viewer.config")
  local controller = require("md-viewer.controller")
  local state = require("md-viewer.state")

  config.reset()
  require("md-viewer").setup({ image = { backend = "cells" } })

  -- A normal open creates a dedicated, fixed preview window containing a real
  -- unlisted buffer, and leaves focus in the source pane.
  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# source" })
  local source_win = vim.api.nvim_get_current_win()
  local document = assert(controller.open("right"))
  t.eq(source_win, vim.api.nvim_get_current_win(), "automatic split retains source focus")
  t.ok(document.preview_buf ~= source, "automatic split displays a distinct preview buffer")
  t.eq(false, vim.bo[document.preview_buf].buflisted, "preview buffers stay out of global buffer lists")
  t.eq("hide", vim.bo[document.preview_buf].bufhidden, "inactive preview buffers remain stable")
  t.eq(true, vim.wo[document.preview_win].winfixbuf, "the preview pane rejects global buffer cycling")
  controller.close(source)

  -- When exactly one sibling shows the same Markdown buffer, the current half
  -- is adopted in place and restored exactly on toggle.
  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_buf(source_win, source)
  vim.wo[source_win].number = true
  vim.cmd("vsplit")
  local adopted_win = vim.api.nvim_get_current_win()
  vim.wo[adopted_win].number = true
  vim.wo[adopted_win].wrap = true
  vim.api.nvim_win_set_cursor(adopted_win, { 1, 0 })
  local before_width = vim.api.nvim_win_get_width(adopted_win)
  local before_count = #vim.api.nvim_tabpage_list_wins(0)
  local adopted = assert(controller.open("right"))
  t.eq(before_count, #vim.api.nvim_tabpage_list_wins(0), "manual duplicate adoption creates no third pane")
  t.eq(adopted_win, adopted.preview_win, "the current duplicate is the adopted preview pane")
  t.eq(adopted_win, vim.api.nvim_get_current_win(), "an adopted pane retains preview focus")
  t.eq(before_width, vim.api.nvim_win_get_width(adopted_win), "adoption preserves the user's split width")
  t.eq(false, adopted.pane.owned, "adopted panes record user ownership")
  controller.toggle()
  t.ok(vim.api.nvim_win_is_valid(adopted_win), "toggling an adopted pane restores rather than closes it")
  t.eq(source, vim.api.nvim_win_get_buf(adopted_win), "the adopted pane restores its original Markdown buffer")
  t.eq(true, vim.wo[adopted_win].number, "the adopted pane restores window-local options")
  t.eq(true, vim.wo[adopted_win].wrap, "all changed preview window options are restored")
  t.eq(false, vim.wo[adopted_win].winfixbuf, "temporary pane dedication is removed on restore")

  pcall(vim.api.nvim_win_close, adopted_win, true)
  vim.api.nvim_set_current_win(source_win)

  -- A fixed duplicate cannot be adopted, so opening falls back to a normal
  -- plugin-owned split and leaves the fixed source window alone.
  vim.cmd("vsplit")
  local fixed_win = vim.api.nvim_get_current_win()
  vim.wo[fixed_win].winfixbuf = true
  local fixed_count = #vim.api.nvim_tabpage_list_wins(0)
  local fallback = assert(controller.open("right"))
  t.eq(fixed_count + 1, #vim.api.nvim_tabpage_list_wins(0), "a fixed adoption target gets a normal preview split")
  t.eq(true, fallback.pane.owned, "the fallback pane is plugin-owned")
  t.eq(fixed_win, vim.api.nvim_get_current_win(), "fallback opening retains source focus")
  controller.close()
  vim.wo[fixed_win].winfixbuf = false
  pcall(vim.api.nvim_win_close, fixed_win, true)
  vim.api.nvim_set_current_win(source_win)

  pcall(vim.api.nvim_buf_delete, source, { force = true })
  t.eq(0, vim.tbl_count(state.panes()), "pane state is empty after teardown")
  config.reset()
end
