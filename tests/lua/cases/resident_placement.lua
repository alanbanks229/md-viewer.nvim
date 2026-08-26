-- What the terminal is actually told when a resident screen is drawn.
--
-- Asserted on the emitted byte stream rather than on the backend's own
-- bookkeeping, because the bookkeeping staying self-consistent while the wrong
-- pixels reach the screen is the exact shape this feature fails in.
return function(t)
  local config = require("md-viewer.config")
  local raw = require("md-viewer.backends.kitty_raw")
  local cellpixels = require("md-viewer.cellpixels")

  local real_measure = cellpixels.measure
  cellpixels.measure = function() return { width = 10, height = 10, cols = 10, rows = 10 } end

  local original_ui_send = vim.api.nvim_ui_send
  local sequences = {}
  vim.api.nvim_ui_send = function(value) sequences[#sequences + 1] = value end
  local function reset() sequences = {} end
  local function output() return table.concat(sequences) end
  local function writes() return #sequences end

  -- 100x100 declared in the IHDR, which is what png_dimensions reads.
  local function fake_png() return "\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\0\100\0\0\0\100" end

  config.reset()
  config.setup({ terminal = { profile = "kitty" } })

  local placement = { row = 0, col = 0, width = 10, height = 10 }

  -- -------------------------------------------------------------------
  -- upload puts pixels in the terminal and draws nothing
  -- -------------------------------------------------------------------

  reset()
  local upper = raw.upload(fake_png())
  t.ok(type(upper) == "number", "upload returns an image id")
  t.ok(output():match("a=t,f=100,t=d,q=2,i=" .. upper), "upload transmits the image")
  t.eq(nil, output():match("a=p"), "upload places nothing")

  reset()
  local lower = raw.upload(fake_png())
  t.ok(lower ~= upper, "a second chunk gets its own image id")

  -- -------------------------------------------------------------------
  -- one write, two bands, no re-upload
  -- -------------------------------------------------------------------

  reset()
  local ok = raw.compose({
    { image_id = upper, row = 0, rows = 4, src_y = 60, src_h = 40 },
    { image_id = lower, row = 4, rows = 6, src_y = 0, src_h = 60 },
  }, placement)
  t.ok(ok, "a two-band screen composes")
  t.eq(1, writes(), "a composite is a single nvim_ui_send write, not one per band")
  t.eq(nil, output():match("a=t"), "panning re-crops and never re-uploads")

  local stream = output()
  -- Cursor is placed at row 1 (1-based) for the upper band and row 5 for the
  -- lower, and each band crops its own chunk at the offset it was given.
  t.ok(stream:match("\27%[1;1H.-i=" .. upper .. ",p=%d+,x=0,y=60,w=100,h=40,c=10,r=4"), "upper band crop and position")
  t.ok(stream:match("\27%[5;1H.-i=" .. lower .. ",p=%d+,x=0,y=0,w=100,h=60,c=10,r=6"), "lower band crop and position")

  local rows_drawn = 0
  for r in stream:gmatch(",r=(%d+),z=") do
    rows_drawn = rows_drawn + tonumber(r)
  end
  t.eq(placement.height, rows_drawn, "the two bands cover the pane exactly once")

  -- -------------------------------------------------------------------
  -- The z-order hazard: every band shares a layer, and Kitty breaks a z tie by
  -- image id. A band left placed from the previous screen draws *over* the live
  -- one whenever its id is higher, so a composite must retire what it replaces.
  -- -------------------------------------------------------------------

  reset()
  raw.compose({ { image_id = lower, row = 0, rows = 10, src_y = 0, src_h = 100 } }, placement)
  local second = output()
  t.eq(1, writes(), "the replacing screen is also one write")
  t.ok(
    second:find("a=p", 1, true) < second:find("a=d,d=i", 1, true),
    "the new placement is emitted before the deletion it supersedes, so nothing blanks between them"
  )
  t.ok(second:match("a=d,d=i,q=2,i=" .. upper), "the band that left the screen is retired")
  t.ok(
    second:match("a=d,d=i,q=2,i=" .. lower .. ",p=%d+"),
    "and so is the superseded placement of the band that stayed"
  )

  -- -------------------------------------------------------------------
  -- hide keeps pixels, retire frees them
  -- -------------------------------------------------------------------

  reset()
  t.ok(raw.hide(lower), "hide drops the placements of a resident chunk")
  t.ok(output():match("a=d,d=i"), "hide deletes placements")
  t.eq(nil, output():match("a=d,d=I"), "hide does not free the image data")

  reset()
  raw.compose({ { image_id = lower, row = 0, rows = 10, src_y = 0, src_h = 100 } }, placement)
  t.eq(nil, output():match("a=t"), "a hidden chunk is still resident and re-places without re-uploading")

  reset()
  t.eq(2, raw.retire({ upper, lower }), "retire frees both chunks")
  t.eq(1, writes(), "retirement of several chunks is one write")
  t.ok(output():match("a=d,d=I,q=2,i=" .. upper), "the first chunk's data is freed")
  t.ok(output():match("a=d,d=I,q=2,i=" .. lower), "the second chunk's data is freed")

  reset()
  t.eq(0, raw.retire({ upper }), "retiring an already-freed chunk is a no-op")
  t.eq(0, writes(), "and writes nothing")

  -- -------------------------------------------------------------------
  -- Refusals: a screen that cannot be drawn correctly is not drawn at all
  -- -------------------------------------------------------------------

  local held = raw.upload(fake_png())
  reset()
  local refused, reason =
    raw.compose({ { image_id = held + 999, row = 0, rows = 10, src_y = 0, src_h = 100 } }, placement)
  t.eq(nil, refused, "composing from a chunk that is not resident is refused")
  t.ok(type(reason) == "string", "and says why")
  t.eq(0, writes(), "a refused composite writes nothing")

  reset()
  -- src_y + src_h runs past the 100px image, which on WezTerm is the divide by
  -- zero in wezterm#6344 rather than a rounding error.
  local out_of_bounds = raw.compose({ { image_id = held, row = 0, rows = 10, src_y = 60, src_h = 100 } }, placement)
  t.eq(nil, out_of_bounds, "a crop running past the image is refused, not clamped")
  t.eq(0, writes(), "and writes nothing")
  raw.retire({ held })

  -- -------------------------------------------------------------------
  -- A float punches out of a band exactly as it punches out of a full frame
  -- -------------------------------------------------------------------

  local chunk = raw.upload(fake_png())
  reset()
  raw.compose({
    { image_id = chunk, row = 0, rows = 5, src_y = 0, src_h = 50 },
    { image_id = chunk, row = 5, rows = 5, src_y = 50, src_h = 50 },
  }, {
    row = 0,
    col = 0,
    width = 10,
    height = 10,
    exclusions = { { row = 2, col = 3, width = 4, height = 2 } },
  })
  local punched = output()
  local placements = 0
  for _ in punched:gmatch("a=p") do
    placements = placements + 1
  end
  t.ok(placements > 2, "an excluded float splits the bands into more than two placements")
  t.eq(1, writes(), "however many pieces, it is still one write")
  local covered = 0
  for c, r in punched:gmatch(",c=(%d+),r=(%d+),z=") do
    covered = covered + tonumber(c) * tonumber(r)
  end
  t.eq(10 * 10 - 4 * 2, covered, "the drawn cells are the pane minus the float, with no overlap")
  raw.retire({ chunk })

  -- -------------------------------------------------------------------
  -- uncompose: the screen comes down, the document stays in the terminal
  --
  -- This is what an occluding float costs a resident preview. Freeing the
  -- chunks would make coming back cost the whole document again, so the
  -- distinction between a=d,d=i and a=d,d=I is the entire point of the call.
  -- -------------------------------------------------------------------

  local a = raw.upload(fake_png())
  local b = raw.upload(fake_png())
  raw.compose({
    { image_id = a, row = 0, rows = 5, src_y = 0, src_h = 50 },
    { image_id = b, row = 5, rows = 5, src_y = 0, src_h = 50 },
  }, placement)

  reset()
  local dropped = raw.uncompose()
  t.ok(dropped >= 2, "uncompose drops the placements of every band on the screen")
  t.eq(1, writes(), "however many bands, taking the screen down is one write")
  t.ok(output():match("a=d,d=i,q=2,i=" .. a), "the upper band's placement goes")
  t.ok(output():match("a=d,d=i,q=2,i=" .. b), "and so does the lower band's")
  t.eq(nil, output():match("a=d,d=I"), "but nothing frees the pixels: an occlusion is not a retirement")

  reset()
  t.eq(0, raw.uncompose(), "a second uncompose has nothing left to take down")
  t.eq(0, writes(), "and writes nothing")

  reset()
  t.ok(
    raw.compose({ { image_id = a, row = 0, rows = 10, src_y = 0, src_h = 100 } }, placement),
    "an uncomposed screen composes again"
  )
  t.eq(nil, output():match("a=t"), "restoring after an occlusion is a re-crop, not a re-upload")
  raw.uncompose()
  raw.retire({ a, b })

  -- -------------------------------------------------------------------
  -- The overlay sizes itself from the placement when there is no base frame,
  -- which is the only thing a resident screen can offer it. Without this a
  -- resident preview had no caret and no selection highlight at all.
  -- -------------------------------------------------------------------

  reset()
  local resident_sheet = raw.overlay_needs_sheet(nil, nil, placement)
  t.ok(resident_sheet, "with no sheet cached, a resident screen is told to send one")
  local set_id, stats = raw.overlay_apply(
    nil,
    nil,
    { { x = 0, y = 0, width = 20, height = 10 } },
    { widthPx = 100, heightPx = 100 },
    { r = 0, g = 0, b = 255, a = 0.3 },
    fake_png(),
    placement
  )
  t.ok(type(set_id) == "number", "and the overlay applies against no base image at all")
  t.ok(type(stats) == "table" and (stats.rects or 0) >= 1, "with the rectangle it was given")
  if type(set_id) == "number" then raw.overlay_clear(set_id) end

  reset()
  local refused_id, refused_why = raw.overlay_apply(
    99999,
    99999,
    { { x = 0, y = 0, width = 20, height = 10 } },
    { widthPx = 100, heightPx = 100 },
    { r = 0, g = 0, b = 255, a = 0.3 },
    fake_png(),
    placement
  )
  t.eq(nil, refused_id, "an id that names nothing is still a refusal -- only nil means 'no base by design'")
  t.ok(type(refused_why) == "string", "and says so")

  -- -------------------------------------------------------------------
  -- Terminal capability
  -- -------------------------------------------------------------------

  -- A headless Neovim has no attached TUI, so `M.detect` refuses before the
  -- profile is ever consulted. Stub it out: what is under test here is the
  -- per-profile decision, not the graphics probe that gates it.
  local real_detect = raw.detect
  raw.detect = function() return true, "stubbed" end

  config.reset()
  config.setup({ terminal = { profile = "wezterm" } })
  local wez_ok, wez_reason = raw.resident_pan_supported()
  t.eq(false, wez_ok, "WezTerm does not hold repeated placements affordably (wezterm#7953)")
  t.ok(type(wez_reason) == "string" and wez_reason:match("WezTerm"), "and the refusal names the terminal")

  for _, profile in ipairs({ "kitty", "ghostty", "iterm2" }) do
    config.reset()
    config.setup({ terminal = { profile = profile } })
    t.ok((raw.resident_pan_supported()), profile .. " can pan resident chunks")
  end

  raw.detect = real_detect
  config.reset()
  t.eq(false, (raw.resident_pan_supported()), "with no attached TUI there is no resident path at all")

  config.reset()
  cellpixels.measure = real_measure
  vim.api.nvim_ui_send = original_ui_send
end
