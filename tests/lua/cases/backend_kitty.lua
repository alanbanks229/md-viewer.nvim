return function(t)
  local config = require("md-viewer.config")
  local raw_backend = require("md-viewer.backends.kitty_raw")

  local original_ui_send = vim.api.nvim_ui_send
  local sequences
  vim.api.nvim_ui_send = function(value) sequences[#sequences + 1] = value end
  local function output() return table.concat(sequences) end
  local function reset_sequences() sequences = {} end

  local function fake_png(extra_bytes)
    local header = "\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\0\100\0\0\0\100"
    if not extra_bytes then return header end
    return header .. string.rep("\0", extra_bytes)
  end

  local placement = { row = 0, col = 0, width = 10, height = 10 }

  -- Z-index: explicit override, in every sign, always wins over the profile
  -- default and is the literal value encoded into the placement command.
  for _, value in ipairs({ -5, 0, 5 }) do
    config.reset()
    config.setup({ image = { raw_zindex = value }, terminal = { profile = "kitty" } })
    local health = raw_backend.health()
    t.eq(value, health.zindex, ("explicit raw_zindex=%d is the effective value"):format(value))
    t.ok(health.zindex_source:match("explicit override"), "explicit override is named as the source")
    reset_sequences()
    local id = raw_backend.show(fake_png(), placement)
    t.eq(tostring(value), output():match("z=(%-?%d+)"), "encoded placement z= matches the explicit override")
    raw_backend.clear(id)
  end

  -- Z-index: with no explicit override, each profile's own default supplies
  -- the value and names itself as the source.
  config.reset()
  config.setup({ terminal = { profile = "kitty" } })
  local kitty_health = raw_backend.health()
  t.eq(-1, kitty_health.zindex, "profile default zindex for kitty")
  t.ok(kitty_health.zindex_source:match("profile default"), "profile default is named as the source")
  t.ok(kitty_health.zindex_source:match("kitty"), "source names the active profile")

  -- An explicit override still beats a different profile's default.
  config.reset()
  config.setup({ terminal = { profile = "wezterm" }, image = { raw_zindex = 9 } })
  local overridden_health = raw_backend.health()
  t.eq(9, overridden_health.zindex, "explicit override wins over a non-default profile")
  t.ok(overridden_health.zindex_source:match("explicit override"), "override source names itself, not the profile")

  -- Double buffering: profile default is true (place-then-delete). An
  -- explicit false flips the order to delete-then-place.
  config.reset()
  config.setup({ terminal = { profile = "kitty" } })
  local db_health = raw_backend.health()
  t.eq(true, db_health.double_buffer, "profile default double_buffer is true")
  t.ok(db_health.double_buffer_source:match("profile default"), "double_buffer source names the profile default")

  reset_sequences()
  local first_id = raw_backend.show(fake_png(), placement)
  reset_sequences()
  local second_id = raw_backend.update(first_id, fake_png(), placement)
  local double_buffered_output = output()
  local shows_first = double_buffered_output:find("a=t,f=100", 1, true)
  local deletes_first = double_buffered_output:find("d=I", 1, true)
  t.ok(shows_first ~= nil and deletes_first ~= nil, "both the new upload and the old deletion are present")
  t.ok(shows_first < deletes_first, "double_buffer=true shows the new image before deleting the old one")
  raw_backend.clear(second_id)

  config.reset()
  config.setup({ image = { double_buffer = false } })
  local forced_health = raw_backend.health()
  t.eq(false, forced_health.double_buffer, "explicit double_buffer=false overrides the profile default")
  t.ok(forced_health.double_buffer_source:match("explicit override"), "explicit override is named as the source")
  reset_sequences()
  local third_id = raw_backend.show(fake_png(), placement)
  reset_sequences()
  local fourth_id = raw_backend.update(third_id, fake_png(), placement)
  local single_buffered_output = output()
  local deletes_second = single_buffered_output:find("d=I", 1, true)
  local shows_second = single_buffered_output:find("a=t,f=100", 1, true)
  t.ok(deletes_second ~= nil and shows_second ~= nil, "both the old deletion and the new upload are present")
  t.ok(deletes_second < shows_second, "double_buffer=false deletes the old image before showing the new one")
  raw_backend.clear(fourth_id)
  config.reset()

  -- Sub-cell calibration: the Kitty X/Y placement keys cancel the origin
  -- offset a terminal introduces by applying its window margin to text but not
  -- to graphics. Absent by default, so a terminal that does not implement them
  -- receives exactly the bytes it did before this existed.
  config.reset()
  config.setup({ terminal = { profile = "iterm2" } })
  reset_sequences()
  local plain_offset_id = raw_backend.show(fake_png(), placement)
  t.eq(nil, output():match("X=%d+"), "no X/Y is emitted when the offset is zero")
  raw_backend.clear(plain_offset_id)
  config.reset()
  config.setup({ terminal = { profile = "iterm2" }, image = { raw_cell_offset_px = { x = 10, y = 3 } } })
  reset_sequences()
  local offset_id = raw_backend.show(fake_png(), {
    row = 0,
    col = 0,
    width = 10,
    height = 10,
    exclusions = { { row = 2, col = 2, width = 4, height = 4 } },
  })
  local offset_output = output()
  t.eq("10", offset_output:match("X=(%d+)"), "a configured x offset reaches the placement command")
  t.eq("3", offset_output:match("Y=(%d+)"), "a configured y offset reaches the placement command")
  local _, offset_placements = offset_output:gsub("\27_Ga=p", "")
  local _, offset_keys = offset_output:gsub("X=%d+", "")
  t.eq(offset_placements, offset_keys, "every cropped region carries the offset, not only the first")
  raw_backend.clear(offset_id)
  config.reset()

  -- Placement lifecycle: upload-once, cropped placements, targeted
  -- deletion, and crop recomputation when exclusions change.
  reset_sequences()
  local raw_id = raw_backend.show(fake_png(), {
    row = 0,
    col = 0,
    width = 10,
    height = 10,
    exclusions = { { row = 2, col = 2, width = 4, height = 4 } },
  })
  local placed_output = output()
  t.ok(placed_output:find("a=t,f=100", 1, true), "raw image uploads independently of placements")
  local _, cropped_placements = placed_output:gsub("\27_Ga=p", "")
  t.eq(4, cropped_placements, "one passive overlay cuts the preview into four placements")

  reset_sequences()
  raw_backend.move(raw_id, { row = 0, col = 0, width = 10, height = 10, exclusions = {} })
  local moved_output = output()
  t.ok(moved_output:find("a=d,d=i", 1, true), "moving deletes only owned placement IDs")
  t.eq(false, moved_output:find("a=t,f=100", 1, true) ~= nil, "moving never re-uploads the already-owned image")
  local _, restored_placements = moved_output:gsub("\27_Ga=p", "")
  t.eq(1, restored_placements, "removing the overlay restores one full placement")

  -- Regression: a re-crop must never leave the terminal with nothing to
  -- composite, or the image visibly blinks and rolls for as long as the float
  -- that triggered it stays open. The replacement placement has to be written
  -- before the deletion it supersedes, and both in the same write.
  t.eq(1, #sequences, "a move is a single write, so no redraw can land mid-recrop")
  t.ok(
    moved_output:find("\27_Ga=p", 1, true) < moved_output:find("a=d,d=i", 1, true),
    "the new placement is sent before the placement it replaces is deleted"
  )
  raw_backend.clear(raw_id)

  -- Base64 chunking at the 4096-byte boundary: an upload whose encoded form
  -- lands exactly on two full chunks, and one that spills one chunk's worth
  -- of bytes into a third, tiny final chunk.
  reset_sequences()
  local exact_id = raw_backend.show(fake_png(6144 - 24), placement) -- base64(6144 bytes) == 8192 chars
  local exact_output = output()
  local _, exact_more_zero = exact_output:gsub("q=2,m=0", "")
  local _, exact_more_one = exact_output:gsub(",m=1", "")
  t.eq(1, exact_more_zero, "an exactly-two-chunk upload ends with a single terminating m=0 chunk")
  t.eq(1, exact_more_one, "an exactly-two-chunk upload has exactly one continuation chunk before it")
  raw_backend.clear(exact_id)

  reset_sequences()
  local remainder_id = raw_backend.show(fake_png(6147 - 24), placement) -- base64(6147 bytes) == 8196 chars
  local remainder_output = output()
  local _, remainder_more_zero = remainder_output:gsub("q=2,m=0", "")
  local _, remainder_more_one = remainder_output:gsub(",m=1", "")
  t.eq(1, remainder_more_zero, "a spillover upload still ends with a single terminating m=0 chunk")
  t.eq(2, remainder_more_one, "a spillover upload sends two full chunks before its tiny remainder")
  raw_backend.clear(remainder_id)

  -- Invalid PNGs are rejected outright rather than uploaded blind.
  local invalid_ok = pcall(raw_backend.show, "not a png", placement)
  t.eq(false, invalid_ok, "an invalid PNG payload is rejected")

  -- ---------------------------------------------------------------------
  -- Stage-4 selection overlay.
  -- ---------------------------------------------------------------------
  local tint = { r = 220, g = 220, b = 220, a = 0.3 }

  -- Gating: profile flag under "auto", explicit on/off overrides.
  config.reset()
  config.setup({ terminal = { profile = "wezterm" } })
  local wez_supported, wez_reason = raw_backend.overlay_supported()
  t.eq(false, wez_supported, "the wezterm profile refuses overlay placements (it crashed the probe)")
  t.ok(wez_reason:match("not validated"), "the refusal names the profile gate")
  config.reset()
  config.setup({ terminal = { profile = "wezterm" }, interaction = { selection_overlay = "on" } })
  t.eq(true, (raw_backend.overlay_supported()), "selection_overlay=on forces the overlay past the profile")
  config.reset()
  config.setup({ terminal = { profile = "iterm2" }, interaction = { selection_overlay = "off" } })
  t.eq(false, (raw_backend.overlay_supported()), "selection_overlay=off wins over a validated profile")
  config.reset()
  config.setup({ terminal = { profile = "iterm2" } })
  t.eq(true, (raw_backend.overlay_supported()), "the iterm2 profile default enables the overlay")

  -- Sheet lifecycle: an apply without the sheet says need_sheet and sends
  -- nothing; supplying it uploads once and places crops.
  reset_sequences()
  local overlay_base = raw_backend.show(fake_png(), placement) -- 100x100 px over 10x10 cells
  t.eq(true, raw_backend.overlay_needs_sheet(overlay_base), "no tint sheet is uploaded yet")
  reset_sequences()
  local viewport = { widthPx = 100, heightPx = 100 }
  local rect = { x = 5.5, y = 7.25, width = 20, height = 10 }
  local no_sheet_set, no_sheet_reason =
    raw_backend.overlay_apply(nil, overlay_base, { rect }, viewport, tint, nil, placement)
  t.eq(nil, no_sheet_set, "without the sheet the apply refuses")
  t.eq("need_sheet", no_sheet_reason, "and reports the caller-actionable reason")
  t.eq(0, #sequences, "a refused apply must not write anything to the terminal")

  local set_id, stats = raw_backend.overlay_apply(nil, overlay_base, { rect }, viewport, tint, fake_png(), placement)
  t.ok(set_id ~= nil, "supplying the sheet makes the apply succeed: " .. tostring(stats))
  local overlay_output = output()
  t.ok(overlay_output:find("a=t,f=100", 1, true) ~= nil, "the tint sheet uploads as a direct PNG transmission")
  t.ok(overlay_output:find("x=0,y=0,w=20,h=10", 1, true) ~= nil, "the rect places as a crop of the sheet")
  t.eq(nil, overlay_output:match(",c=%d"), "overlay placements never use cell scaling (c/r)")
  t.eq("-1", overlay_output:match("w=20,h=10,z=(%-?%d+)"), "the overlay sits one layer above the -2 base, under text")
  t.ok(overlay_output:find(",X=6,Y=7", 1, true) ~= nil, "sub-cell offsets carry the rect's pixel remainder")
  t.eq(false, raw_backend.overlay_needs_sheet(overlay_base), "the sheet cache is warm after one upload")
  t.eq(1, stats.placed, "one rectangle placed")

  -- Diffing: an identical rect set writes nothing; a changed set emits the
  -- replacement before the deletion it supersedes, in one write.
  reset_sequences()
  local same_set, same_stats = raw_backend.overlay_apply(set_id, overlay_base, { rect }, viewport, tint, nil, placement)
  t.eq(set_id, same_set, "an unchanged rect set keeps its set id")
  t.eq(0, #sequences, "an unchanged rect set writes nothing at all")
  t.eq(1, same_stats.kept, "the placement is kept, not replaced")
  reset_sequences()
  local moved_set = raw_backend.overlay_apply(
    set_id,
    overlay_base,
    { { x = 30, y = 7.25, width = 20, height = 10 } },
    viewport,
    tint,
    nil,
    placement
  )
  t.eq(set_id, moved_set, "a changed rect set still keeps its set id")
  t.eq(1, #sequences, "a changed rect set is a single write")
  local moved_overlay = output()
  t.ok(
    moved_overlay:find("\27_Ga=p", 1, true) < moved_overlay:find("a=d,d=i", 1, true),
    "the new rectangle is emitted before the placement it supersedes is deleted"
  )

  -- Exclusions: a passive float's cut-out splits the rectangle, so the
  -- overlay never paints across a notification.
  local excluded_placement = {
    row = 0,
    col = 0,
    width = 10,
    height = 10,
    exclusions = { { row = 0, col = 3, width = 2, height = 2 } },
  }
  reset_sequences()
  raw_backend.overlay_apply(
    set_id,
    overlay_base,
    { { x = 0, y = 0, width = 100, height = 10 } },
    viewport,
    tint,
    nil,
    excluded_placement
  )
  local cut_output = output()
  local _, cut_placements = cut_output:gsub("\27_Ga=p", "")
  t.eq(2, cut_placements, "a rect crossing a passive-float cut-out splits into two placements")

  -- Calibration carry: the configured raw_cell_offset_px shifts the overlay
  -- exactly as it shifts the base, carrying into the next cell when the sum
  -- exceeds the cell.
  config.reset()
  config.setup({ terminal = { profile = "iterm2" }, image = { raw_cell_offset_px = { x = 8, y = 0 } } })
  reset_sequences()
  raw_backend.overlay_apply(set_id, overlay_base, { rect }, viewport, tint, nil, placement)
  local carry_output = output()
  t.ok(carry_output:find("\27%[1;2H") ~= nil, "an offset past the cell edge advances the cursor cell")
  t.ok(carry_output:find(",X=4,Y=7", 1, true) ~= nil, "and keeps the remainder as the sub-cell offset")
  config.reset()
  config.setup({ terminal = { profile = "iterm2" } })

  -- Deletion: clearing the set removes every placement; clear_all also frees
  -- the sheet.
  local healthy = raw_backend.health()
  t.eq(1, healthy.overlay_sets, "one overlay set is live")
  t.ok(healthy.overlay_placements >= 1, "with at least one placement")
  t.eq(1, healthy.overlay_sheets, "one tint sheet is cached")
  reset_sequences()
  t.eq(true, raw_backend.overlay_clear(set_id), "clearing an owned set succeeds")
  t.ok(output():find("a=d,d=i", 1, true) ~= nil, "clearing deletes the placements")
  t.eq(0, raw_backend.health().overlay_sets, "no sets remain after clear")
  t.eq(1, raw_backend.health().overlay_sheets, "the sheet survives for the next gesture")
  raw_backend.clear(overlay_base)
  reset_sequences()
  raw_backend.clear_all()
  t.ok(output():find("a=d,d=I", 1, true) ~= nil, "clear_all frees the sheet image")
  t.eq(0, raw_backend.health().overlay_sheets, "no sheets survive clear_all")

  vim.api.nvim_ui_send = original_ui_send
  config.reset()
end
