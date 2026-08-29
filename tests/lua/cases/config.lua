return function(t)
  local config = require("md-viewer.config")
  config.reset()
  local cfg = config.setup({ split = { width = 0.4 }, image = { backend = "cells" } })
  t.eq(0.4, cfg.split.width, "configuration override")
  t.eq(45, cfg.split.min_width, "configuration deep merge")
  t.eq(false, cfg.security.raw_html, "raw html parsing defaults to off")
  t.eq(false, cfg.obsidian.enabled, "Obsidian wikilinks default to off")
  t.eq(nil, cfg.obsidian.vault_root, "the Obsidian vault defaults to the document root")
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
  t.eq("#61afef", config.setup({}).preview.tab_accent, "the active-tab underline defaults to a fixed accent color")
  config.reset()
  local accented_cfg = config.setup({ preview = { tab_accent = "#ff0000" } })
  t.eq("#ff0000", accented_cfg.preview.tab_accent, "preview.tab_accent is overridable")
  config.reset()
  local no_accent_cfg = config.setup({ preview = { tab_accent = false } })
  t.eq(false, no_accent_cfg.preview.tab_accent, "preview.tab_accent accepts false")
  config.reset()
  local bad_accent_ok, bad_accent_err = pcall(config.setup, { preview = { tab_accent = "red" } })
  t.eq(false, bad_accent_ok, "a color name instead of #rrggbb is rejected")
  t.ok(tostring(bad_accent_err):match("tab_accent"), "the tab_accent error names the offending option")
  config.reset()
  local short_hex_ok = pcall(config.setup, { preview = { tab_accent = "#fff" } })
  t.eq(false, short_hex_ok, "a 3-digit hex shorthand is rejected -- nvim_set_hl wants the full 6 digits")
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
  config.reset()
  local obsidian_cfg = config.setup({ obsidian = { enabled = true, vault_root = "/tmp/vault" } })
  t.eq(true, obsidian_cfg.obsidian.enabled, "Obsidian wikilinks are configurable")
  t.eq("/tmp/vault", obsidian_cfg.obsidian.vault_root, "an explicit vault root is retained")
  config.reset()
  local bad_obsidian_ok, bad_obsidian_err = pcall(config.setup, { obsidian = { enabled = "yes" } })
  t.eq(false, bad_obsidian_ok, "a non-boolean obsidian.enabled is rejected")
  t.ok(tostring(bad_obsidian_err):match("obsidian.enabled"), "the Obsidian error names the option")

  -- The seven interaction settings that went with mouse selection in 0.3.0.
  -- `vim.tbl_deep_extend` keeps keys nothing declares, so before this guard a
  -- configuration written against 0.2 was accepted whole and every one of
  -- these silently did nothing -- while CHANGELOG.md promised a configuration
  -- error. Each is checked with `false`, the value most likely to be read as
  -- "not set": a 0.2 config that switched one of these off is still a 0.2
  -- config, and saying nothing about it is the failure, not the value.
  for _, name in ipairs({
    "drag_threshold_cells",
    "double_click",
    "autoscroll",
    "autoscroll_interval_ms",
    "autoscroll_max_lines",
    "word_select",
    "paragraph_select",
  }) do
    config.reset()
    local removed_ok, removed_err = pcall(config.setup, { interaction = { [name] = false } })
    t.eq(false, removed_ok, ("interaction.%s is refused rather than silently ignored"):format(name))
    t.ok(
      tostring(removed_err):match("interaction%." .. name),
      ("the error for interaction.%s names the option in full"):format(name)
    )
    t.ok(
      tostring(removed_err):match("md%-viewer%-visual"),
      ("the error for interaction.%s points at the replacement"):format(name)
    )
  end

  -- The guard reads what the caller wrote, so an unrelated interaction table
  -- and a bare setup() must both still pass straight through it.
  config.reset()
  t.eq(
    true,
    config.setup({ interaction = { copy_on_select = true } }).interaction.copy_on_select,
    "an interaction table with no removed key still configures"
  )
  config.reset()
  t.eq(true, (pcall(config.setup, {})), "zero configuration is unaffected by the removed-key guard")

  -- interaction.keymaps: which key cycles preview tabs. Each entry is a
  -- non-empty string, or `false` to leave that action unmapped.
  config.reset()
  local keymaps_cfg = config.setup({ interaction = { keymaps = { tab_previous = "gh" } } })
  t.eq("gh", keymaps_cfg.interaction.keymaps.tab_previous, "interaction.keymaps.tab_previous is overridable")
  t.eq("L", keymaps_cfg.interaction.keymaps.tab_next, "overriding one keymap leaves the other at its default")
  config.reset()
  local unmapped_cfg = config.setup({ interaction = { keymaps = { tab_previous = false } } })
  t.eq(false, unmapped_cfg.interaction.keymaps.tab_previous, "interaction.keymaps.tab_previous accepts false")
  config.reset()
  local bad_keymap_type_ok, bad_keymap_type_err =
    pcall(config.setup, { interaction = { keymaps = { tab_previous = true } } })
  t.eq(false, bad_keymap_type_ok, "a non-string, non-false interaction.keymaps.tab_previous is rejected")
  t.ok(
    tostring(bad_keymap_type_err):match("interaction%.keymaps%.tab_previous"),
    "the keymaps.tab_previous error names the offending option"
  )
  config.reset()
  local bad_keymaps_shape_ok, bad_keymaps_shape_err = pcall(config.setup, { interaction = { keymaps = "H" } })
  t.eq(false, bad_keymaps_shape_ok, "a non-table interaction.keymaps is rejected")
  t.ok(
    tostring(bad_keymaps_shape_err):match("interaction%.keymaps"),
    "the keymaps shape error names the offending option"
  )
  config.reset()

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

  -- Six options declare `nil` as their default, and a nil value simply does
  -- not exist in a Lua table -- so `pairs(config.defaults)` sees 70 of the 76
  -- rows the help carries, and any of those six could be dropped from either
  -- side without this guard noticing. Listed here because the runtime records
  -- their existence nowhere else.
  local nil_defaults = {
    "browser.executable_path",
    "image.double_buffer",
    "image.raw_zindex",
    "obsidian.vault_root",
    "render.scroll_scale",
    "security.document_root",
  }

  -- Rows are four spaces, the option name, then padding; continuation lines are
  -- indented far past that and group headings sit at column 1, so the group a
  -- row belongs to is whichever heading last preceded it. Anchoring on the
  -- exact indent keeps `scroll_scale` from being satisfied by `ssh_scroll_scale`.
  local help_rows, group_now = {}, nil
  for line in (options_section .. "\n"):gmatch("([^\n]*)\n") do
    local heading = line:match("^([a-z][a-z0-9_]*) ~$")
    if heading then
      group_now = heading
    else
      local name = line:match("^    ([a-z][a-z0-9_]*)%s")
      if name and group_now then help_rows[group_now .. "." .. name] = true end
    end
  end

  local runtime = {}
  for group, options in pairs(config.defaults) do
    t.ok(options_section:find("\n" .. group .. " ~", 1, true) ~= nil, ("the %s group has a heading"):format(group))
    for name in pairs(options) do
      runtime[group .. "." .. name] = true
    end
  end
  for _, path in ipairs(nil_defaults) do
    local group, name = path:match("^(.-)%.(.*)$")
    t.ok(config.defaults[group] ~= nil, ("the %s group exists for nil-default %s"):format(group, path))
    -- If one of these ever gains a real default, `pairs` starts seeing it and
    -- this list is the thing that has gone stale.
    t.eq(nil, config.defaults[group][name], ("%s is still a nil default"):format(path))
    runtime[path] = true
  end

  -- Set equality in both directions. The old check ran one way only, so a help
  -- row for an option that no longer exists read as complete coverage.
  local undocumented, unimplemented = {}, {}
  for path in pairs(runtime) do
    if not help_rows[path] then table.insert(undocumented, path) end
  end
  for path in pairs(help_rows) do
    if not runtime[path] then table.insert(unimplemented, path) end
  end
  table.sort(undocumented)
  table.sort(unimplemented)
  t.eq(0, #undocumented, "every option appears in *md-viewer-options*: " .. table.concat(undocumented, ", "))
  t.eq(0, #unimplemented, "every *md-viewer-options* row is a real option: " .. table.concat(unimplemented, ", "))
  local surface = 0
  for _ in pairs(runtime) do
    surface = surface + 1
  end
  t.ok(surface > 60, ("the option table covers the whole surface (%d options)"):format(surface))

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
