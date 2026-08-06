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

  vim.api.nvim_ui_send = original_ui_send
  config.reset()
end
