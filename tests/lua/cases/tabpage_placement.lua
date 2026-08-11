return function(t)
  -- Regression: a raw Kitty placement is absolute screen coordinates that the
  -- terminal keeps compositing until told otherwise, and the terminal only
  -- ever displays one tabpage. A plugin that opens its UI in its own tab
  -- (codediff.nvim's `:CodeDiff` runs `vim.cmd("tabnew")` and then splits
  -- inside it -- lua/codediff/ui/view/side_by_side.lua) therefore leaves the
  -- preview window parked on a tabpage nobody can see. Every window API keeps
  -- reporting that window's full, unchanged, on-screen geometry, so the
  -- image was re-shown at the hidden tab's coordinates on top of the diff
  -- panes and stayed there for as long as the diff view was open.
  local config = require("md-viewer.config")
  local controller = require("md-viewer.controller")
  local coordinates = require("md-viewer.coordinates")
  local preview = require("md-viewer.preview")

  config.reset()
  require("md-viewer").setup({ image = { backend = "cells" } })
  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# Heading", "", "- bullet" })
  local session = assert(controller.open("right"))
  local preview_tab = vim.api.nvim_win_get_tabpage(session.preview_win)

  local shows, moves, clears = {}, 0, 0
  session.backend = {
    name = "kitty_raw",
    clear = function()
      clears = clears + 1
      return true
    end,
    show = function(_, placement)
      shows[#shows + 1] = { tab = vim.api.nvim_get_current_tabpage(), row = placement.row, col = placement.col }
      return 901
    end,
    move = function(image_id)
      moves = moves + 1
      return image_id
    end,
  }
  session.image_id = 77
  session.last_image_bytes = "cached-png"
  session.last_placement = preview.placement(session.preview_win, "kitty_raw")
  local before = vim.deepcopy(session.last_placement)

  t.eq(true, coordinates.window_is_displayed(session.preview_win), "the preview window starts on the displayed tabpage")

  -- Exactly what `:CodeDiff` does: its own tabpage, then its explorer sidebar
  -- and side-by-side diff panes split "relative to the editor" inside it.
  vim.cmd("tabnew")
  local diff_tab = vim.api.nvim_get_current_tabpage()
  local sidebar = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    split = "left",
    win = -1,
    width = math.max(20, math.floor(vim.o.columns / 4)),
  })
  vim.cmd("rightbelow vsplit")
  t.ok(diff_tab ~= preview_tab, "sanity: the diff view opened in its own tabpage")

  -- The heart of the bug: none of this is visible through window geometry.
  local hidden_placement = preview.placement(session.preview_win, "kitty_raw")
  t.eq(true, vim.api.nvim_win_is_valid(session.preview_win), "a hidden tabpage's window still reports as valid")
  t.eq(before.row, hidden_placement.row, "a hidden tabpage's window still reports its old screen row")
  t.eq(before.col, hidden_placement.col, "a hidden tabpage's window still reports its old screen column")
  t.eq(before.width, hidden_placement.width, "a hidden tabpage's window still reports its old width")
  t.eq(before.height, hidden_placement.height, "a hidden tabpage's window still reports its old height")
  t.eq(
    false,
    coordinates.window_is_displayed(session.preview_win),
    "only the tabpage check can tell that the preview is no longer on screen"
  )

  -- Give WinNew/WinResized/WinEnter and every other scheduled reconcile a
  -- chance to do the wrong thing, the way they all did before this fix.
  vim.wait(300, function() return session.image_id ~= nil end, 10)
  t.eq(nil, session.image_id, "the raw image is not on screen while its tabpage is hidden")
  t.eq(0, #shows, "no path may re-show the image at a hidden tabpage's coordinates")
  t.eq(0, moves, "no path may re-place the image at a hidden tabpage's coordinates")
  t.ok(clears > 0, "leaving the tabpage deletes the placement instead of orphaning it")
  t.eq(nil, session.last_placement, "the dropped placement goes with the image, so no click resolves against it")
  t.eq(true, session.tabpage_hidden, "the reason the preview is blank is reported for :MdViewerDebug")

  -- Entering the command line re-places unconditionally (cmdline_placement.lua)
  -- and must not become a way back on screen either.
  session.image_id = 77
  vim.api.nvim_exec_autocmds("CmdlineEnter", {})
  t.eq(0, moves, "a forced re-place is still refused while the tabpage is hidden")
  session.image_id = nil

  -- A render landing while the preview is hidden is dropped, not displayed
  -- off screen -- so the cached PNG it would have produced has to be replayed
  -- on the way back rather than leaving a permanently stale frame.
  controller.refresh(session)
  t.eq(true, session.refresh_deferred, "a render dropped on a hidden tabpage is recorded for replay")

  vim.api.nvim_win_close(sidebar, true)
  vim.cmd("tabclose")
  t.eq(preview_tab, vim.api.nvim_get_current_tabpage(), "sanity: closing the diff view returns to the preview tabpage")
  vim.wait(400, function() return session.image_id ~= nil end, 10)
  t.eq(901, session.image_id, "returning to the preview's tabpage restores the image")
  t.eq(1, #shows, "the image is restored exactly once")
  t.eq(preview_tab, shows[1].tab, "the image is restored on the tabpage that actually owns the preview")
  t.eq(before.row, shows[1].row, "the restored image lands back on the preview's own row")
  t.eq(before.col, shows[1].col, "the restored image lands back on the preview's own column")
  t.eq(false, session.tabpage_hidden, "the hidden-tabpage reason is cleared once the preview is displayed again")
  vim.wait(200, function() return session.refresh_deferred == false end, 10)
  t.eq(false, session.refresh_deferred, "the dropped render is replayed once the preview is displayed again")

  controller.close(source)
  config.reset()
end
