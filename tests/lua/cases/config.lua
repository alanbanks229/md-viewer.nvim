return function(t)
  local config = require("md-viewer.config")
  config.reset()
  local cfg = config.setup({ split = { width = 0.4 }, image = { backend = "cells" } })
  t.eq(0.4, cfg.split.width, "configuration override")
  t.eq(45, cfg.split.min_width, "configuration deep merge")
  t.eq(false, cfg.security.raw_html, "raw html parsing defaults to off")
  t.eq(true, cfg.preview.pinned, "preview remains pinned by default")
  t.eq(true, cfg.preview.loading, "graphical preview loading indicator default")
  t.eq(80, cfg.preview.loading_interval_ms, "loading indicator animation interval")
  t.eq("off", cfg.preview.line_numbers, "rendered visual-line numbers default to off")
  t.eq(true, cfg.sync.mouse_scroll, "preview mouse scrolling default")
  t.eq(true, cfg.render.scroll_past_end, "preview scrolls past its last block")
  t.eq(true, cfg.render.fast_scroll, "fast scroll capture default")
  t.eq(nil, cfg.render.fast_scroll_fps, "scroll captures have no artificial FPS cap")
  -- Paired with the measured cell: a 2x display's cell is about 7 CSS px wide,
  -- and a 14px body font averages about 7px per character, so preview text
  -- lands at roughly one character per terminal cell.
  t.eq(14, cfg.render.font_size_px, "preview base font size default")
  -- Animated playback is opt-in. Turning it off never costs a picture: the
  -- still frame the screenshot captured is what stays on screen.
  t.eq(false, cfg.render.animate, "animated image playback is off by default")
  t.eq(5, cfg.render.animate_fps, "client-driven frame swaps are capped at 5fps")
  -- Unset rather than 1: nil is what lets the SSH default apply without making
  -- "the user asked for full size" and "the user said nothing" the same value.
  t.eq(nil, cfg.render.scroll_scale, "the moving scroll frame follows the session by default")
  t.eq(0.5, cfg.render.ssh_scroll_scale, "an SSH session halves the moving scroll frame")
  t.eq(160, cfg.render.scroll_settle_ms, "the local settle delay is unchanged")
  t.eq(400, cfg.render.ssh_scroll_settle_ms, "an SSH session waits longer before the sharp frame")
  -- "auto" rather than nil, and rather than any number. One ~/.config/nvim is
  -- symlinked to machines whose links measured fourteen times apart, so a
  -- constant is wrong on all but one of them; "auto" reads a measurement each
  -- machine made for itself, and takes none on its own.
  t.eq("auto", cfg.render.ssh_link_bytes_per_sec, "the link rate resolves per machine by default")
  config.reset()
  local bad_font_ok, bad_font_err = pcall(config.setup, { render = { font_size_px = 0 } })
  t.eq(false, bad_font_ok, "non-positive render.font_size_px is rejected")
  t.ok(tostring(bad_font_err):match("font_size_px"), "invalid font_size_px error names the offending option")
  config.reset()
  local sized_cfg = config.setup({ render = { font_size_px = 20 } })
  t.eq(20, sized_cfg.render.font_size_px, "render.font_size_px is overridable")
  config.reset()
  local animate_cfg = config.setup({ render = { animate = true } })
  t.eq(true, animate_cfg.render.animate, "render.animate is overridable")
  config.reset()
  local bad_animate_ok, bad_animate_err = pcall(config.setup, { render = { animate = "yes" } })
  t.eq(false, bad_animate_ok, "a non-boolean render.animate is rejected")
  t.ok(tostring(bad_animate_err):match("animate"), "the animate error names the offending option")
  config.reset()
  -- Both of these are divisors on the viewport path, and the measured
  -- calibration tier makes device_scale_factor one. Its bound is the same 1..3
  -- browser.js applies when it creates the browser context; a wider value here
  -- only produces a viewport that disagrees with the page.
  local bad_scale_ok, bad_scale_err = pcall(config.setup, { render = { device_scale_factor = 0 } })
  t.eq(false, bad_scale_ok, "a device scale below 1 is rejected")
  t.ok(tostring(bad_scale_err):match("device_scale_factor"), "the device scale error names the offending option")
  config.reset()
  local high_scale_ok = pcall(config.setup, { render = { device_scale_factor = 4 } })
  t.eq(false, high_scale_ok, "a device scale the renderer would re-clamp is rejected")
  config.reset()
  local scaled_cfg = config.setup({ render = { device_scale_factor = 1 } })
  t.eq(1, scaled_cfg.render.device_scale_factor, "a non-Retina device scale is accepted")
  config.reset()
  -- Bounded at both ends, and the upper bound matters as much as the lower one:
  -- this knob only ever *reduces* the moving frame, so a value above 1 would
  -- spend bytes to gain nothing over what device_scale_factor already decided.
  local low_scroll_ok, low_scroll_err = pcall(config.setup, { render = { scroll_scale = 0.1 } })
  t.eq(false, low_scroll_ok, "a scroll scale below the legibility floor is rejected")
  t.ok(tostring(low_scroll_err):match("scroll_scale"), "the scroll scale error names the offending option")
  config.reset()
  local high_scroll_ok = pcall(config.setup, { render = { scroll_scale = 2 } })
  t.eq(false, high_scroll_ok, "a scroll scale above natural size is rejected")
  config.reset()
  local scroll_cfg = config.setup({ render = { scroll_scale = 0.5 } })
  t.eq(0.5, scroll_cfg.render.scroll_scale, "render.scroll_scale is overridable")
  config.reset()
  local bad_ssh_scroll_ok, bad_ssh_scroll_err = pcall(config.setup, { render = { ssh_scroll_scale = 0 } })
  t.eq(false, bad_ssh_scroll_ok, "a zero SSH scroll scale is rejected")
  t.ok(tostring(bad_ssh_scroll_err):match("ssh_scroll_scale"), "the SSH scroll scale error names the option")
  config.reset()
  local bad_settle_ok, bad_settle_err = pcall(config.setup, { render = { ssh_scroll_settle_ms = -1 } })
  t.eq(false, bad_settle_ok, "a negative SSH settle delay is rejected")
  t.ok(tostring(bad_settle_err):match("ssh_scroll_settle_ms"), "the SSH settle error names the offending option")
  config.reset()
  -- Unlike the scale, nil here means "use one delay everywhere" rather than
  -- "follow the session", so it has to survive validation as a real choice.
  local no_ssh_settle = config.setup({ render = { ssh_scroll_settle_ms = nil } })
  t.eq(400, no_ssh_settle.render.ssh_scroll_settle_ms, "omitting the SSH settle delay keeps the default")
  config.reset()
  -- A measured number still wins over per-machine detection and is never capped
  -- against anything, which is both the feature and the trap: see
  -- md-viewer.linkrate for why a rate in a shared config defeats detection on
  -- every machine that shares it.
  local pinned_rate = config.setup({ render = { ssh_link_bytes_per_sec = 1030000 } })
  t.eq(1030000, pinned_rate.render.ssh_link_bytes_per_sec, "a measured link rate can still be pinned by hand")
  config.reset()
  local bad_rate_ok, bad_rate_err = pcall(config.setup, { render = { ssh_link_bytes_per_sec = 0 } })
  t.eq(false, bad_rate_ok, "a non-positive link rate is rejected")
  t.ok(tostring(bad_rate_err):match("ssh_link_bytes_per_sec"), "the link rate error names the offending option")
  config.reset()
  local bad_rate_word_ok = pcall(config.setup, { render = { ssh_link_bytes_per_sec = "fast" } })
  t.eq(false, bad_rate_word_ok, 'the only word the link rate accepts is "auto"')
  config.reset()
  -- nil is a value here, not an omission: it is how "follow the session" is
  -- spelled, so it has to survive validation rather than being defaulted away.
  local unset_scroll_cfg = config.setup({ render = { scroll_scale = nil } })
  t.eq(nil, unset_scroll_cfg.render.scroll_scale, "an unset scroll scale stays unset")
  config.reset()
  local bad_aspect_ok, bad_aspect_err = pcall(config.setup, { render = { cell_aspect_ratio = 0 } })
  t.eq(false, bad_aspect_ok, "a zero cell aspect ratio is rejected before it divides by zero")
  t.ok(tostring(bad_aspect_err):match("cell_aspect_ratio"), "the aspect ratio error names the offending option")
  config.reset()
  local relative_numbers = config.setup({ preview = { line_numbers = "relative" } })
  t.eq("relative", relative_numbers.preview.line_numbers, "relative visual-line numbers are configurable")
  config.reset()
  local bad_numbers_ok, bad_numbers_err = pcall(config.setup, { preview = { line_numbers = "yes" } })
  t.eq(false, bad_numbers_ok, "an unknown line-number mode is rejected")
  t.ok(tostring(bad_numbers_err):match("line_numbers"), "the line-number error names the offending option")
  config.reset()
  config.setup({ split = { width = 0.4 }, image = { backend = "cells" } })
  t.eq(nil, cfg.image.raw_zindex, "raw z-index defers to the terminal profile default until overridden")
  t.eq(nil, cfg.image.double_buffer, "double buffering defers to the terminal profile default until overridden")
  t.eq(1, cfg.image.raw_statusline_guard_cells, "raw graphics reserve a statusline boundary cell")
  t.eq(1, cfg.image.raw_overlay_bleed_cells, "passive overlay cutouts bleed one trailing column by default")
  t.eq(0, cfg.image.raw_cell_offset_px.x, "no sub-cell placement offset until the terminal is calibrated")
  t.eq(0, cfg.image.raw_cell_offset_px.y, "no sub-cell placement offset until the terminal is calibrated")
  t.eq(50, cfg.image.ui_poll_ms, "raw previews poll for no-autocmd floating UI")
  config.reset()
  local bleed_ok, bleed_err = pcall(config.setup, { image = { raw_overlay_bleed_cells = -1 } })
  t.eq(false, bleed_ok, "a negative overlay bleed is rejected")
  t.ok(tostring(bleed_err):match("raw_overlay_bleed_cells"), "the bleed error names the offending option")
  config.reset()
  local offset_ok, offset_err = pcall(config.setup, { image = { raw_cell_offset_px = { x = -4, y = 0 } } })
  t.eq(false, offset_ok, "a negative sub-cell offset is rejected")
  t.ok(tostring(offset_err):match("raw_cell_offset_px"), "the offset error names the offending option")
  config.reset()
  local calibrated = config.setup({ image = { raw_cell_offset_px = { x = 10, y = 0 } } })
  t.eq(10, calibrated.image.raw_cell_offset_px.x, "a measured sub-cell offset is accepted")
  t.eq("auto", cfg.terminal.profile, "terminal profile defaults to auto")
  t.eq("auto", cfg.terminal.kitty_graphics, "kitty graphics inference defaults to auto")
  t.eq("off", cfg.terminal.probe, "active graphics probe is off by default")
  config.reset()
  local raw_html_cfg = config.setup({ security = { raw_html = true } })
  t.eq(true, raw_html_cfg.security.raw_html, "security.raw_html is overridable")
  config.reset()
  local bad_raw_html_ok, bad_raw_html_err = pcall(config.setup, { security = { raw_html = "yes" } })
  t.eq(false, bad_raw_html_ok, "a non-boolean security.raw_html is rejected")
  t.ok(tostring(bad_raw_html_err):match("raw_html"), "the raw_html error names the offending option")

  -- Every option is documented, or it exists only for its author. The same
  -- pin commands.lua applies to the command surface: `:help md-viewer-options`
  -- is the canonical reference, and a table nothing checks is stale within a
  -- release. An option added without a row here fails on the next run rather
  -- than shipping undocumented.
  --
  -- Derived from this file rather than the working directory, so the check
  -- holds wherever the suite is invoked from.
  local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here))))
  local help = table.concat(vim.fn.readfile(root .. "/doc/md-viewer.txt"), "\n")
  -- Bounded at the sentence that closes the table, not at the next section
  -- rule: the subsections after it discuss individual options in prose, and
  -- letting those count would pass an option that had been dropped from the
  -- table itself.
  local options_section = help:match("%*md%-viewer%-options%*(.-)\nThe options in the rest of this section")
  t.ok(options_section ~= nil, "the help file has an *md-viewer-options* section")

  -- Every row is four spaces, the option name, then padding, so anchoring on
  -- the indent and requiring a trailing space keeps `scroll_scale` from being
  -- satisfied by `ssh_scroll_scale`.
  local documented, missing = 0, {}
  for group, options in pairs(config.defaults) do
    t.ok(options_section:find("\n" .. group .. " ~", 1, true) ~= nil, ("the %s group has a heading"):format(group))
    for name in pairs(options) do
      documented = documented + 1
      if not options_section:find("\n    " .. name .. " ", 1, true) then table.insert(missing, group .. "." .. name) end
    end
  end
  table.sort(missing)
  t.eq(0, #missing, "every option appears in *md-viewer-options*: " .. table.concat(missing, ", "))
  t.ok(documented > 60, ("the option table covers the whole surface (%d options)"):format(documented))

  -- plugin/md-viewer.lua calls setup() with no arguments after every rtp
  -- load, and plugin files run *after* a manual init file's explicit setup --
  -- so the argless call must defer, not clobber. Measured clobbering
  -- render.location back to "current" through `nvim -u` before this guard.
  require("md-viewer").setup({ render = { location = "local" } })
  require("md-viewer").setup()
  t.eq("local", config.get().render.location, "an argless setup defers to an explicit configuration")
  require("md-viewer").setup({})
  t.eq("current", config.get().render.location, "an explicit empty setup still reconfigures")
end
