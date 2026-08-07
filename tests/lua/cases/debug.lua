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

  -- Part 7 §7.4: selection/find state (length only, never the text itself),
  -- interaction request/stale/coalesced counters, and the content revision
  -- the cached frame is pinned to must all be visible, and a selected
  -- string must never appear verbatim in the diagnostics buffer.
  session.renderer_revision = "9:1"
  session.selection_active = true
  session.selection_text_length = 123
  session.find_active = true
  session.find_query = "needle"
  session.find_match_count = 4
  session.find_active_index = 1
  session.interaction_request_count = 6
  session.interaction_stale_count = 2
  session.coalesced_drag_events = 3

  vim.cmd("MdViewerDebug")
  vim.wait(2000, function() return vim.bo.filetype == "lua" end, 20)
  t.eq("lua", vim.bo.filetype, "MdViewerDebug renders its snapshot buffer")

  local buffer_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  t.ok(buffer_text:match("viewport_calibration_tier"), "snapshot reports the calibration tier field")
  t.ok(buffer_text:match('"env"'), "snapshot carries the simulated session's calibration tier value")
  t.ok(buffer_text:match("placement"), "snapshot reports the session placement field")
  t.ok(buffer_text:match("exclusions"), "snapshot placement includes its exclusion rectangles")
  t.ok(buffer_text:match('content_revision = "9:1"'), "snapshot reports the session's current content revision")
  t.ok(buffer_text:match("selection_text_length = 123"), "snapshot reports the cached selection's length")
  t.ok(buffer_text:match('find_query = "needle"'), "snapshot reports the active search query")
  t.ok(buffer_text:match("find_match_count = 4"), "snapshot reports the active search's match count")
  t.ok(buffer_text:match("interaction_request_count = 6"), "snapshot reports the interaction request count")
  t.ok(buffer_text:match("interaction_stale_count = 2"), "snapshot reports the stale-interaction count")
  t.ok(buffer_text:match("coalesced_drag_events = 3"), "snapshot reports the coalesced-drag-event count")
  t.ok(buffer_text:match("interaction_enabled = true"), "snapshot reports the global interaction-enabled state")

  vim.cmd("bwipeout!")
  controller.close(source)
  require("md-viewer.process").stop()
  vim.wait(5000, function() return not require("md-viewer.process").status().running end, 20)
end
