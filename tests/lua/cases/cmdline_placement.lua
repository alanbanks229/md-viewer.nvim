return function(t)
  -- Entering the command line (":", "/", "?") used to fully delete and
  -- re-upload the raw Kitty image, leaving the preview blank for the
  -- duration. It should instead just re-place the already-uploaded image at
  -- its current geometry -- cheap, and never actually disappears.
  local config = require("md-viewer.config")
  local controller = require("md-viewer.controller")

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

  vim.api.nvim_exec_autocmds("CmdlineEnter", {})
  t.eq(1, move_calls, "entering the command line re-places the raw image instead of hiding it")
  t.eq(0, clear_calls, "entering the command line never deletes the image")
  t.eq(0, show_calls, "entering the command line never re-uploads the image")
  t.eq(42, session.image_id, "the image ID is unchanged across command-line entry")

  vim.api.nvim_exec_autocmds("CmdlineLeave", {})
  t.eq(2, move_calls, "leaving the command line re-places the raw image again")
  t.eq(0, clear_calls, "leaving the command line never deletes the image")
  t.eq(0, show_calls, "leaving the command line never re-uploads the image")

  controller.close(source)
  config.reset()
end
