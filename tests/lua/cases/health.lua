local function base_report()
  return {
    neovim = "0.12.0",
    vim_ui_img = false,
    tui_attached = true,
    terminal_program = "iTerm.app",
    iterm2_version = "3.5.0",
    platform = "darwin",
    multiplexer = "none",
    terminal_profile = "iterm2 (iTerm2)",
    terminal_profile_evidence = "TERM_PROGRAM=iTerm.app",
    graphics_confidence = "inferred",
    graphics_decision_reason = "inferred from TERM_PROGRAM=iTerm.app",
    graphics_validation = "photographed",
    graphics_caveats = {},
    kitty_graphics_probe_succeeded = false,
    vim_ui_img_render_succeeded = false,
    selected_backend = "kitty_raw",
    backend_decision = "verified: inferred from TERM_PROGRAM=iTerm.app",
    raw_graphics_zindex = -2,
    raw_graphics_zindex_source = "profile default (iterm2)",
    raw_graphics_overlay_supported = true,
    raw_graphics_overlay_reason = "profile iterm2 is validated for translucent overlay placements",
    raw_graphics_overlay_zindex = -1,
    raw_graphics_cell_pixels = "14.00x32.00 px per cell",
    raw_graphics_double_buffer = true,
    raw_graphics_double_buffer_source = "explicit override",
    raw_graphics_cell_offset_px = "x=0, y=0",
    raw_graphics_overlay_bleed_cells = 1,
    raw_graphics_owned_images = 0,
    raw_graphics_owned_placements = 0,
    node_version = "v24.14.0",
    playwright_package = "available",
    chromium_executable = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    chromium_discovery = "confirmed by renderer subprocess",
    chromium_launch = "succeeded",
    temporary_directory_writable = true,
    renderer_process = { running = true, pid = 1234, stderr = "" },
    network_blocked = true,
    raw_html = false,
    local_image_root = "/project",
    document_root_source = "configured (security.document_root)",
    document_root_excludes_current = false,
    document_root_unbounded = false,
    security_overrides = "none",
    viewport_calibration_tier = "estimated",
    interaction_enabled = true,
    chromium_active_document = "doc-1",
    chromium_cached_document_frames = 1,
    chromium_cached_documents = 1,
    chromium_lane_documents = 0,
    chromium_interaction_documents = 0,
  }
end

local function warning_texts(diagnosis)
  local texts = {}
  for _, warning in ipairs(diagnosis.warnings) do
    texts[#texts + 1] = warning.text
  end
  return table.concat(texts, "\n")
end

local function section_values(diagnosis)
  local values = {}
  for _, section in ipairs(diagnosis.sections) do
    for _, row in ipairs(section.rows) do
      values[#values + 1] = row.value
    end
  end
  return table.concat(values, "\n")
end

return function(t)
  require("md-viewer").setup({})
  local health = require("md-viewer.health")

  -- Status classification is pure and fast via M._diagnose -- no renderer
  -- round-trip or real terminal/env state needed to cover the decision logic.
  do
    local auto_cfg = { image = { backend = "auto" } }
    local cells_cfg = { image = { backend = "cells" } }

    local healthy = health._diagnose(base_report(), auto_cfg)
    t.eq("healthy", healthy.status, "a working image backend reports healthy")
    t.ok(
      not (warning_texts(healthy) .. section_values(healthy)):match("vim[._]ui[._]?img"),
      "a healthy backend never surfaces vim.ui.img absence as a problem, even though the report has vim_ui_img=false"
    )

    local fallback = base_report()
    fallback.selected_backend = "cells"
    fallback.backend_decision = "nvim_img unavailable (no vim.ui.img); kitty raw unavailable (no evidence); using cells"
    local degraded = health._diagnose(fallback, auto_cfg)
    t.eq("degraded", degraded.status, "an automatic fallback to cells is degraded, not healthy")
    t.ok(degraded.status_reason:match("cell"), "the degraded reason names the fallback")
    t.ok(warning_texts(degraded):match("cell"), "the fallback reason is surfaced as a warning")

    local explicit_cells = health._diagnose(fallback, cells_cfg)
    t.eq(
      "healthy",
      explicit_cells.status,
      "a user-configured cells backend is healthy -- it is not a fallback, it is what was asked for"
    )

    local never_started = base_report()
    never_started.renderer_process = { running = false }
    local not_broken = health._diagnose(never_started, auto_cfg)
    t.eq(
      "healthy",
      not_broken.status,
      "a renderer that simply has not been started yet is not broken (checkhealth never round-trips)"
    )

    local missing_playwright = base_report()
    missing_playwright.playwright_package = "missing"
    local broken_playwright = health._diagnose(missing_playwright, auto_cfg)
    t.eq("broken", broken_playwright.status, "a missing playwright package is a real failure")
    t.ok(broken_playwright.status_reason:match("playwright"), "the broken reason names the missing dependency")

    local crashed = base_report()
    crashed.renderer_process = { running = false, last_error = "spawn ENOENT" }
    local broken_crash = health._diagnose(crashed, auto_cfg)
    t.eq("broken", broken_crash.status, "a renderer that reported an error is broken, distinct from not-yet-started")

    local no_chromium = base_report()
    no_chromium.chromium_executable = "not found"
    t.eq("broken", health._diagnose(no_chromium, auto_cfg).status, "no discoverable Chromium is a real failure")

    t.ok(broken_playwright.status ~= degraded.status, "broken and degraded are visibly distinct statuses")
  end

  -- End-to-end: the concise default and the verbose opt-in both render from
  -- the same collected state, without embedded newlines (nvim_buf_set_lines
  -- rejects those) and without losing any detail field in verbose mode.
  local original_tmux = vim.env.TMUX
  vim.env.TMUX = "/tmp/tmux-501/default,1234,0" -- forces a second, multi-entry caveat

  health.show()
  vim.wait(8000, function() return vim.bo.filetype == "md-viewer-health" end, 20)
  t.eq("md-viewer-health", vim.bo.filetype, "MdViewerHealth renders its report buffer")
  local concise_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for _, line in ipairs(concise_lines) do
    t.ok(not line:find("\n", 1, true), "no concise report line contains an embedded newline")
  end
  local concise_text = table.concat(concise_lines, "\n")
  t.ok(concise_text:match("Status:"), "the concise report leads with an overall status")
  t.ok(concise_text:match("Warnings"), "the concise report has a single Warnings section")
  t.ok(not concise_text:match("raw graphics zindex:"), "raw graphics geometry is not in the concise report")
  t.ok(not concise_text:match("chromium active document:"), "Chromium session state is not in the concise report")
  vim.cmd("bwipeout!")

  health.show("verbose")
  vim.wait(8000, function() return vim.bo.filetype == "md-viewer-health" end, 20)
  t.eq("md-viewer-health", vim.bo.filetype, "MdViewerHealth verbose renders its report buffer")
  local verbose_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local has_embedded_newline = false
  for _, line in ipairs(verbose_lines) do
    if line:find("\n", 1, true) then has_embedded_newline = true end
  end
  t.eq(false, has_embedded_newline, "no verbose report line contains an embedded newline")
  t.ok(#verbose_lines > 40, "verbose report retains the full field-by-field detail")

  local found_multiplexer_caveat = false
  for _, line in ipairs(verbose_lines) do
    if line:match("^  %- ") and line:match("tmux") then found_multiplexer_caveat = true end
  end
  t.ok(found_multiplexer_caveat, "multi-entry caveats render as separate indented lines in verbose mode")

  -- Part 7 §7.4: interaction enabled state and which document Chromium
  -- currently holds active must both be visible in the report -- the
  -- renderer subprocess was actually queried above (health.show() always
  -- round-trips through process.request("health", ...)), so this is real
  -- reported state, not a placeholder. Now verbose-only after the concise
  -- redesign.
  local verbose_text = table.concat(verbose_lines, "\n")
  t.ok(verbose_text:match("interaction enabled:%s+true"), "the verbose report states whether interaction is enabled")
  t.ok(verbose_text:match("chromium active document:"), "the verbose report states which document Chromium holds")
  t.ok(verbose_text:match("chromium cached document frames:"), "the verbose report states cached frame counts")

  -- The drag-highlight overlay's own diagnostics. Without these, a terminal
  -- silently drawing the highlight underneath the base image looks identical
  -- to one falling back to full captures -- which is exactly how the
  -- 2026-08-08 Ghostty defect presented, and why it took source-reading to
  -- find. The two z-indices must be reported together: equal numbers mean the
  -- base and the highlight are ordered by image id rather than by layer.
  t.ok(verbose_text:match("raw graphics overlay supported:"), "the verbose report states if the overlay is in use")
  t.ok(verbose_text:match("raw graphics overlay reason:"), "and why, so a refusal is actionable")
  t.ok(verbose_text:match("raw graphics overlay zindex:"), "the overlay's layer is reported beside the base's")
  t.ok(verbose_text:match("raw graphics cell pixels:"), "and what a pixel is worth on screen")
  local base_z = tonumber(verbose_text:match("raw graphics zindex:%s+(%-?%d+)"))
  local overlay_z = tonumber(verbose_text:match("raw graphics overlay zindex:%s+(%-?%d+)"))
  if base_z and overlay_z then
    t.eq(base_z + 1, overlay_z, "the overlay sits exactly one layer above the base, never on it")
  end

  vim.cmd("bwipeout!")
  vim.env.TMUX = original_tmux
  require("md-viewer.process").stop()
  vim.wait(5000, function() return not require("md-viewer.process").status().running end, 20)
end
