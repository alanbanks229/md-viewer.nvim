return function(t)
  -- :MdViewerDebug had zero automated coverage before Part 2 added new
  -- per-session fields (placement rectangle, calibration tier) to its
  -- snapshot. Exercise the real command end to end, the same lesson Part 1
  -- learned the hard way with :MdViewerHealth (see health.lua's test).
  require("md-viewer").setup({ image = { backend = "cells" } })

  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# Title", "", "body" })
  local controller = require("md-viewer.controller")
  local session = assert(controller.open("right"))

  -- A real terminal session running the raw Kitty backend would populate
  -- these; simulate that here since headless tests have no attached TUI.
  session.last_placement =
    { row = 1, col = 2, width = 40, height = 20, exclusions = { { row = 3, col = 4, width = 5, height = 1 } } }
  session.viewport_calibration_tier = "env"

  vim.cmd("MdViewerDebug")
  vim.wait(2000, function() return vim.bo.filetype == "lua" end, 20)
  t.eq("lua", vim.bo.filetype, "MdViewerDebug renders its snapshot buffer")

  local buffer_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  t.ok(buffer_text:match("viewport_calibration_tier"), "snapshot reports the calibration tier field")
  t.ok(buffer_text:match('"env"'), "snapshot carries the simulated session's calibration tier value")
  t.ok(buffer_text:match("placement"), "snapshot reports the session placement field")
  t.ok(buffer_text:match("exclusions"), "snapshot placement includes its exclusion rectangles")

  vim.cmd("bwipeout!")
  controller.close(source)
  require("md-viewer.process").stop()
  vim.wait(5000, function() return not require("md-viewer.process").status().running end, 20)
end
