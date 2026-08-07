return function(t)
  -- :MdViewerHealth builds its buffer with nvim_buf_set_lines, which throws
  -- if any item contains an embedded newline. vim.inspect() on a table (e.g.
  -- multi-entry caveats, the renderer_process status table) produces
  -- multi-line output by default, so every report field must be sanitized
  -- before formatting. This regression previously reached a real Neovim
  -- session with vim.health output never exercising the M.show() buffer path.
  require("md-viewer").setup({})

  local original_tmux = vim.env.TMUX
  vim.env.TMUX = "/tmp/tmux-501/default,1234,0" -- forces a second, multi-entry caveat

  local health = require("md-viewer.health")
  health.show()
  vim.wait(8000, function() return vim.bo.filetype == "md-viewer-health" end, 20)
  t.eq("md-viewer-health", vim.bo.filetype, "MdViewerHealth renders its report buffer")

  local buffer_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local has_embedded_newline = false
  for _, line in ipairs(buffer_lines) do
    if line:find("\n", 1, true) then has_embedded_newline = true end
  end
  t.eq(false, has_embedded_newline, "no health report line contains an embedded newline")
  t.ok(#buffer_lines > 10, "health report has substantive content")

  local found_multiplexer_caveat = false
  for _, line in ipairs(buffer_lines) do
    if line:match("^  %- ") and line:match("tmux") then found_multiplexer_caveat = true end
  end
  t.ok(found_multiplexer_caveat, "multi-entry caveats render as separate indented lines")

  -- Part 7 §7.4: interaction enabled state and which document Chromium
  -- currently holds active must both be visible in the report -- the
  -- renderer subprocess was actually queried above (health.show() always
  -- round-trips through process.request("health", ...)), so this is real
  -- reported state, not a placeholder.
  local report_text = table.concat(buffer_lines, "\n")
  t.ok(report_text:match("interaction enabled:%s+true"), "the report states whether interaction is enabled")
  t.ok(report_text:match("chromium active document:"), "the report states which document Chromium currently holds")
  t.ok(report_text:match("chromium cached document frames:"), "the report states how many document frames are cached")

  vim.cmd("bwipeout!")
  vim.env.TMUX = original_tmux
  require("md-viewer.process").stop()
  vim.wait(5000, function() return not require("md-viewer.process").status().running end, 20)
end
