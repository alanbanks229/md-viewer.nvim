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

  -- The caret is part of what a re-place invalidates, and it was the part nobody
  -- cleaned up. Its rectangle is measured against the placement being superseded,
  -- exactly like the selection overlay's -- which this path has always dropped
  -- for that reason. The caret's was left drawn, so a notification opening over
  -- the preview parked a block at its pre-re-crop cell until some later motion or
  -- frame happened to redraw it. Clearing alone would be wrong: the caret has not
  -- moved and is still on its glyph, so it comes down and goes straight back.
  local overlay_applies, overlay_clears = 0, 0
  session.backend.overlay_supported = function() return true end
  session.backend.overlay_apply = function()
    overlay_applies = overlay_applies + 1
    return 7, { rects = 1 }
  end
  session.backend.overlay_clear = function() overlay_clears = overlay_clears + 1 end
  vim.api.nvim_set_current_win(session.preview_win)
  session.caret_tint = "#ffffff"
  session.caret_rect = { x = 10, y = 20, width = 9, height = 18 }
  session.caret_scroll_y, session.applied_scroll_y = 0, 0
  session.caret_overlay_set = 7

  vim.api.nvim_exec_autocmds("CmdlineEnter", {})
  t.eq(1, overlay_clears, "a re-place takes the caret's rectangle down with the base it was measured against")
  t.eq(1, overlay_applies, "and puts it straight back, against the placement now on screen")

  -- But only when the base actually moved. This reconciliation also runs on a
  -- 50 ms poll tick, where the placement is unchanged and nothing is emitted --
  -- a caret placement on every one of those would be a steady drip of writes down
  -- the link that reusing sent pixels exists to keep quiet.
  overlay_applies, overlay_clears = 0, 0
  controller._reconcile_placement(session)
  t.eq(0, overlay_clears, "an unchanged placement re-places nothing")
  t.eq(0, overlay_applies, "so it redraws no caret either")

  controller.close(source)
  config.reset()
end
