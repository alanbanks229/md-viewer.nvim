return function(t)
  -- Entering the command line (":", "/", "?") used to fully delete and
  -- re-upload the raw Kitty image, leaving the preview blank for the
  -- duration. It should instead just re-place the already-uploaded image at
  -- its current geometry -- cheap, and never actually disappears.
  local config = require("md-viewer.config")
  local controller = require("md-viewer.controller")
  local occlusion = require("md-viewer.occlusion")
  local preview = require("md-viewer.preview")

  config.reset()
  require("md-viewer").setup({ image = { backend = "cells" } })
  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source)
  vim.bo[source].filetype = "markdown"
  local session = assert(controller.open("right"))

  local move_calls, clear_calls, show_calls = 0, 0, 0
  session.backend = {
    name = "kitty_raw",
    clear = function()
      clear_calls = clear_calls + 1
      return true
    end,
    show = function()
      show_calls = show_calls + 1
      return 99
    end,
    move = function(image_id)
      move_calls = move_calls + 1
      return image_id
    end,
  }
  session.image_id = 42
  session.last_placement = preview.placement(session.preview_win, "kitty_raw")

  local visited = {}
  occlusion.each_session(function(active) visited[#visited + 1] = active end)
  t.eq(1, #visited, "the extracted iterator visits each active preview once")
  t.eq(session, visited[1], "the extracted iterator yields the active document")

  occlusion.reconcile_placement(session, true)
  t.eq(1, move_calls, "force redraws an existing image even when its placement is unchanged")
  t.eq(0, clear_calls, "a forced same-placement redraw does not delete the image")
  t.eq(42, session.image_id, "a forced same-placement redraw retains the image ID")

  vim.api.nvim_exec_autocmds("CmdlineEnter", {})
  t.eq(2, move_calls, "entering the command line re-places the raw image instead of hiding it")
  t.eq(0, clear_calls, "entering the command line never deletes the image")
  t.eq(0, show_calls, "entering the command line never re-uploads the image")
  t.eq(42, session.image_id, "the image ID is unchanged across command-line entry")

  vim.api.nvim_exec_autocmds("CmdlineLeave", {})
  t.eq(3, move_calls, "leaving the command line re-places the raw image again")
  t.eq(0, clear_calls, "leaving the command line never deletes the image")
  t.eq(0, show_calls, "leaving the command line never re-uploads the image")

  controller.close(source)
  config.reset()
end
