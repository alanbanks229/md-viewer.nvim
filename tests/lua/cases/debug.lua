return function(t)
  -- :MdViewerDebug went uncovered until its per-session snapshot grew fields
  -- (placement rectangle, calibration tier) that could silently stop being
  -- reported. Exercise the real command end to end, the same lesson
  -- :MdViewerHealth taught first (see health.lua's test).
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

  -- The diagnostics privacy rule: selection/find state as lengths only, never
  -- the text itself. That, the request/stale/coalesced counters, and the
  -- content revision
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

  -- Round-trips to the renderer (a cold Chromium launch on a loaded CI runner
  -- is not fast) so the Chromium path and launch result are answered for by
  -- the subprocess rather than guessed at locally.
  -- Reading the diagnostics must not change what they are diagnosing. This used
  -- to open `botright new`, a full-width split that takes rows from every window
  -- above it -- including the preview, whose height is part of the resident key,
  -- because the document reflows at a different viewport. So checking the
  -- numbers threw away every slice the terminal was holding and paid for them
  -- again, twice per look: once opening, once closing. It cost a real session
  -- six slices and ~2.5 MB, on a run whose own protocol says to check this
  -- command while walking, and it reported `evictions: 0` throughout.
  local preview_win = session.preview_win
  local rows_before = vim.api.nvim_win_get_height(preview_win)
  local tab_before = vim.api.nvim_get_current_tabpage()
  vim.cmd("MdViewerDebug")
  vim.wait(30000, function() return vim.bo.filetype == "md-viewer-debug" end, 20)
  t.eq("md-viewer-debug", vim.bo.filetype, "MdViewerDebug renders its snapshot buffer")
  t.ok(vim.api.nvim_get_current_tabpage() ~= tab_before, "in a tab of its own")
  t.eq(rows_before, vim.api.nvim_win_get_height(preview_win), "leaving the preview exactly the size it was")

  local buffer_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local buffer_text = table.concat(buffer_lines, "\n")

  for _, line in ipairs(buffer_lines) do
    t.ok(not line:find("\n", 1, true), "no debug report line contains an embedded newline")
  end

  -- The environment half, absorbed from what used to be
  -- `:MdViewerHealth verbose`. Both halves have to be here: almost every real
  -- report needs the machine's capabilities *and* what the preview did with
  -- them, and while they lived in two commands each report arrived with one.
  t.ok(buffer_text:match("%-%- Environment %-%-"), "the debug report describes the environment")
  t.ok(buffer_text:match("node:%s+%S"), "including the Node version the renderer runs on")
  t.ok(buffer_text:match("chromium:%s+%S"), "and which Chromium was found")
  t.ok(buffer_text:match("document root:%s+%S"), "and the security root local links resolve against")
  t.ok(buffer_text:match("interaction enabled:%s+yes"), "and whether interaction is enabled")

  -- The drag-highlight overlay's own diagnostics. Without these, a terminal
  -- silently drawing the highlight underneath the base image looks identical
  -- to one falling back to full captures -- exactly how the 2026-08-08 Ghostty
  -- defect presented. When the overlay is on, both z-indices appear together
  -- on one line: equal numbers mean the base and highlight are ordered by
  -- image id rather than by layer. When it is off, that line carries why.
  t.ok(buffer_text:match("overlay:%s+%S"), "the debug report states whether the overlay is in use")
  t.ok(buffer_text:match("cell pixels:"), "and what a pixel is worth on screen")
  t.ok(buffer_text:match("base layer:%s+%-?%d+"), "and which layer the preview is drawn on")
  local overlay_z, base_z = buffer_text:match("overlay:%s+on, layer (%-?%d+) over base (%-?%d+)")
  if overlay_z and base_z then
    t.eq(tonumber(base_z) + 1, tonumber(overlay_z), "the overlay sits exactly one layer above the base, never on it")
  else
    t.ok(buffer_text:match("overlay:%s+off %-%-%s+%S"), "an overlay that is off says why, so the refusal is actionable")
  end

  -- Verbose used to report this project's own testing history and a probe
  -- result hardcoded to false. Neither says anything about the machine the
  -- report was taken on, so neither survived the merge.
  t.ok(not buffer_text:match("operator%-validated"), "the report carries no validation history")
  t.ok(not buffer_text:match("probe succeeded"), "nor a probe result that can never be true")

  -- Capability data is rendered once. It used to be dumped a second time as
  -- raw `terminal`/`backends`/`renderer` tables in the same buffer.
  t.ok(not buffer_text:match("profile_id ="), "terminal capability is not also dumped as a raw table")
  t.ok(not buffer_text:match("overlay_reason ="), "nor is backend capability")

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

  vim.cmd("bwipeout!")
  controller.close(source)
  require("md-viewer.process").stop()
  vim.wait(5000, function() return not require("md-viewer.process").status().running end, 20)
end
