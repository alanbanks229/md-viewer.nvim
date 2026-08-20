local function base_report()
  return {
    neovim = "0.12.0",
    vim_ui_img = false,
    tui_attached = true,
    terminal_program = "iTerm.app",
    iterm2_version = "3.5.0",
    platform = "darwin",
    multiplexer = "none",
    ssh = "no",
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
    raw_html = false,
    local_image_root = "/project",
    document_root_source = "configured (security.document_root)",
    document_root_excludes_current = false,
    document_root_unbounded = false,
    security_overrides = "none",
    viewport_calibration_tier = "estimated",
    viewport_cell_pixels = "unmeasured (the terminal reports no pixel geometry)",
    viewport_cell_css_px = "n/a (estimated tier)",
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

  -- What may go into "Warnings". The rule is one sentence -- a warning means
  -- something here may not work and you can do something about it -- and these
  -- assert the two ways it used to be broken: provenance filed as a warning,
  -- and a stated configuration argued with as if it were a fault.
  do
    local auto_cfg = { image = { backend = "auto" } }

    local noisy = base_report()
    noisy.graphics_caveats = {
      { kind = "note", text = "Selection-overlay placements were validated by the operator on 2026-08-07." },
      { kind = "note", text = "Kitty graphics support is inferred, not probed." },
      { kind = "warn", text = "Running inside tmux; image position may be wrong." },
    }
    local filtered = health._diagnose(noisy, auto_cfg)
    t.eq(1, #filtered.warnings, "only actionable caveats become warnings")
    t.ok(warning_texts(filtered):match("tmux"), "the actionable caveat is the one kept")
    t.ok(not warning_texts(filtered):match("validated"), "a validation record is evidence, never a warning")
    t.ok(not warning_texts(filtered):match("inferred"), "how the terminal was identified is not a warning")

    -- An unbounded document root is a stated choice reported as a note. The
    -- old escalation to a warning under network access went with
    -- security.network itself: browser networking is always blocked now, and
    -- remote image URLs are static text in a JavaScript-free page, so the
    -- read-a-file-then-send-it pairing cannot recur.
    local wide = base_report()
    wide.document_root_unbounded = true
    wide.local_image_root = "/"
    local wide_diagnosis = health._diagnose(wide, auto_cfg)
    t.eq(0, #wide_diagnosis.warnings, 'document_root="/" is not a warning')
    t.eq(1, #wide_diagnosis.notes, 'document_root="/" is reported as a note')
    t.ok(wide_diagnosis.notes[1].text:match("document_root"), "the note names the setting it is about")
    t.ok(
      not (wide_diagnosis.notes[1].text .. table.concat(wide_diagnosis.notes[1].detail or {}, " ")):match(
          "[Dd]eliberate"
        ),
      "a note states what is true; it does not defend the user's configuration to them"
    )

    -- The genuinely broken case is unchanged: a document outside a configured
    -- root has every local link and image refused, and that is an error.
    local excluded = base_report()
    excluded.document_root_excludes_current = true
    local excluded_diagnosis = health._diagnose(excluded, auto_cfg)
    t.eq("error", excluded_diagnosis.warnings[1].severity, "a document outside its configured root is an error")

    local clean = health._diagnose(base_report(), auto_cfg)
    t.eq(0, #clean.warnings, "a healthy, conventionally configured session warns about nothing")
    t.eq(0, #clean.notes, "and has nothing to note either")
  end

  -- End-to-end: the concise default and the verbose opt-in both render from
  -- the same collected state, without embedded newlines (nvim_buf_set_lines
  -- rejects those) and without losing any detail field in verbose mode.
  -- The calibration tier is only checkable if the numbers behind it are
  -- printed beside it: "measured" alone cannot show that the device-pixel
  -- reading was converted to CSS pixels the right way round, which is the one
  -- way that tier goes wrong.
  do
    local measured = base_report()
    measured.viewport_calibration_tier = "measured"
    measured.viewport_cell_pixels = "14.00x32.00 px per cell (208x55 cells reported by TIOCGWINSZ)"
    measured.viewport_cell_css_px = "7.00x16.00 (device px / 2)"
    measured.viewport_cell_unit = "device (divisor 2, default)"
    local lines = table.concat(health.environment_lines(measured), "\n")
    t.ok(lines:match("viewport calibration:%s+measured"), "the environment dump names the calibration tier")
    t.ok(lines:match("measured cell:%s+14%.00x32%.00 px per cell"), "the environment dump shows the measured cell")
    t.ok(lines:match("viewport cell %(CSS px%):%s+7%.00x16%.00"), "the environment dump shows the converted CSS cell")
    -- Which divisor produced that CSS cell, and what chose it. The conversion
    -- assumes the terminal means device pixels by ws_xpixel and that the
    -- display really is device_scale_factor times logical; where neither holds
    -- the divisor is picked by plausibility instead, and a judgement call
    -- should say that it was one.
    t.ok(lines:match("cell unit:%s+device %(divisor 2, default%)"), "the environment dump names the cell's unit")

    local estimated = base_report()
    local estimated_lines = table.concat(health.environment_lines(estimated), "\n")
    t.ok(estimated_lines:match("unmeasured"), "an unmeasurable terminal says so rather than showing a cell")
    t.ok(estimated_lines:match("n/a %(estimated tier%)"), "the estimated tier reports no exact CSS cell")

    -- A cell neither divisor can make plausible is a warning, not a silent
    -- fallback: the visible symptom is preview text at the wrong size, which
    -- reads as a font setting rather than a measurement fault, so the reader
    -- has to be told where to look and what settles it.
    local implausible = base_report()
    implausible.viewport_calibration_tier = "measured"
    implausible.viewport_cell_css_px = "3.50x8.00 (device px / 2) -- implausible"
    implausible.viewport_cell_implausible = true
    local diagnosis = health._diagnose(implausible, auto_cfg)
    t.ok(warning_texts(diagnosis):match("plausible"), "an implausible cell raises a warning naming the problem")
    t.ok(warning_texts(diagnosis):match("3%.50x8%.00"), "the warning quotes the cell it is complaining about")
    local detail = ""
    for _, warning in ipairs(diagnosis.warnings) do
      if warning.detail then detail = detail .. table.concat(warning.detail, "\n") end
    end
    t.ok(detail:match("MD_VIEWER_CELL_WIDTH_PX"), "and names the override that settles it")

    t.eq(
      0,
      #health._diagnose(measured, auto_cfg).warnings,
      "a plausible cell raises nothing -- the heuristic is not itself a warning"
    )
  end

  -- A session that cannot measure its link has no working anti-backlog pause,
  -- and that is the one fault here a reader can neither see nor guess the fix
  -- for. Nothing errors; the preview just falls further behind the longer it is
  -- open, showing a frame of somewhere they already left. The session this came
  -- from ran for minutes at 101,169 B/ms on an SSM tunnel with a 2 ms hold.
  do
    local unobservable = base_report()
    unobservable.resident_link_unobservable = { samples = 25, discarded = 147 }
    local diagnosis = health._diagnose(unobservable, auto_cfg)
    local texts = warning_texts(diagnosis)
    t.ok(texts:match("cannot measure its link"), "an unmeasurable link raises a warning naming the problem")
    t.ok(texts:match("147 of 172"), "quoting the counts, so the claim can be checked rather than taken on trust")
    local detail = ""
    for _, warning in ipairs(diagnosis.warnings) do
      if warning.detail then detail = detail .. table.concat(warning.detail, "\n") end
    end
    -- Both halves, because either alone is unusable: the key without the script
    -- invites a guess, and guessing high is precisely the failure being reported.
    t.ok(detail:match("scripts/ssh%-link%-speed%.lua"), "and names the script that measures it")
    t.ok(detail:match("render%.ssh_link_bytes_per_sec"), "and the key to put the answer in")

    t.eq(
      0,
      #health._diagnose(base_report(), auto_cfg).warnings,
      "a session with a rate it can trust says nothing -- this is not a standing notice"
    )
  end

  -- Forcing the drag overlay onto a profile that is not validated for it is
  -- supported -- it is how a terminal gets qualified -- but it is not silent.
  -- Warp was qualified this way on 2026-08-11 and failed: overlay rectangles
  -- drew far larger than the crop asked for, so a one-glyph caret block covered
  -- most of the split. That reads as a rendering bug rather than as an override
  -- the reader turned on, which is exactly why it has to be said out loud.
  do
    local forced = base_report()
    forced.raw_graphics_overlay_supported = true
    forced.raw_graphics_overlay_forced = true
    forced.terminal_profile = "warp (Warp)"
    local diagnosis = health._diagnose(forced, auto_cfg)
    t.ok(warning_texts(diagnosis):match("selection_overlay=on"), "forcing the overlay names the option that did it")
    t.ok(warning_texts(diagnosis):match("warp"), "and the terminal it was forced onto")
    t.ok(
      table.concat(health.environment_lines(forced), "\n"):match("forced"),
      "the overlay line says it is on against the profile's advice, not merely on"
    )

    local allowed = base_report()
    allowed.raw_graphics_overlay_supported = true
    allowed.raw_graphics_overlay_forced = false
    t.eq(0, #health._diagnose(allowed, auto_cfg).warnings, "an overlay a validated profile allows is not a warning")
  end

  local original_tmux = vim.env.TMUX
  vim.env.TMUX = "/tmp/tmux-501/default,1234,0" -- forces a second, multi-entry caveat

  -- The renderer subprocess has to spin up and launch a real Chromium for
  -- this round-trip; a cold launch on a loaded CI runner can take well
  -- longer than it does on a warm local machine.
  -- In a tab, not a `botright new` split, for the reason :MdViewerDebug's case
  -- states at length: a full-width split takes rows from the preview, the
  -- preview's height is part of the resident key, and every slice the terminal
  -- is holding is thrown away and re-uploaded because someone opened a report.
  local tab_before = vim.api.nvim_get_current_tabpage()
  local windows_before = #vim.api.nvim_tabpage_list_wins(tab_before)
  health.show()
  vim.wait(30000, function() return vim.bo.filetype == "md-viewer-health" end, 20)
  t.eq("md-viewer-health", vim.bo.filetype, "MdViewerHealth renders its report buffer")
  t.ok(vim.api.nvim_get_current_tabpage() ~= tab_before, "in a tab of its own")
  t.eq(
    windows_before,
    #vim.api.nvim_tabpage_list_wins(tab_before),
    "without adding a window to the tab the preview is in, which would resize it"
  )
  local concise_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for _, line in ipairs(concise_lines) do
    t.ok(not line:find("\n", 1, true), "no concise report line contains an embedded newline")
  end
  local concise_text = table.concat(concise_lines, "\n")
  t.ok(concise_text:match("Status:"), "the concise report leads with an overall status")
  t.ok(concise_text:match("Warnings"), "the concise report has a single Warnings section")
  t.ok(not concise_text:match("raw graphics zindex:"), "raw graphics geometry is not in the concise report")
  t.ok(not concise_text:match("chromium active document:"), "Chromium session state is not in the concise report")
  -- The full environment dump is :MdViewerDebug's job now, and this command
  -- takes no arguments at all: a `verbose` view sitting between the two split
  -- one diagnosis across two commands, so every bug report arrived with half.
  t.ok(not concise_text:match("cell offset"), "field-by-field detail belongs to :MdViewerDebug")
  vim.cmd("bwipeout!")

  vim.env.TMUX = original_tmux
  require("md-viewer.process").stop()
  vim.wait(5000, function() return not require("md-viewer.process").status().running end, 20)
end
