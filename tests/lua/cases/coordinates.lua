return function(t)
  local config = require("md-viewer.config")
  local coords = require("md-viewer.coordinates")
  local preview = require("md-viewer.preview")
  local cfg = config.get()

  -- ---------------------------------------------------------------------
  -- Every tier assertion below depends on whether the terminal running the
  -- suite reports pixel geometry, and `nvim --headless -l` leaves stdout on
  -- the real terminal -- so an unstubbed answer differs between a developer's
  -- machine and a piped CI run, and the estimated-tier assertions would pass
  -- in one and fail in the other. Substituting the single ioctl read makes the
  -- tier a property of the test. `winsize = nil` is an unmeasurable terminal.
  -- ---------------------------------------------------------------------
  local cellpixels = require("md-viewer.cellpixels")
  local real_read_winsize = cellpixels.read_winsize
  local winsize = nil
  cellpixels.read_winsize = function()
    if not winsize then return nil end
    return winsize.cols, winsize.rows, winsize.xpixel, winsize.ypixel
  end
  -- LuaJIT ffi or the platform constant may be missing, in which case `measure`
  -- short-circuits before the reader and the measured tier is unreachable here.
  local measurable = (function()
    winsize = { cols = 100, rows = 40, xpixel = 800, ypixel = 640 }
    local reachable = cellpixels.measure() ~= nil
    winsize = nil
    return reachable
  end)()

  local viewport = coords.viewport({ width = 80, height = 30 }, cfg.render)
  t.ok(viewport.widthPx <= cfg.render.max_width_px, "bounded viewport width")
  t.ok(viewport.heightPx <= cfg.render.max_height_px, "bounded viewport height")
  t.eq("estimated", viewport.tier, "uncalibrated viewport reports the estimated tier")
  t.ok(
    coords.same({ row = 1, col = 2, width = 3, height = 4 }, { row = 1, col = 2, width = 3, height = 4 }),
    "coordinate equality"
  )
  t.eq(
    false,
    coords.same(
      { row = 1, col = 2, width = 3, height = 4, exclusions = { { row = 1, col = 2, width = 1, height = 1 } } },
      { row = 1, col = 2, width = 3, height = 4 }
    ),
    "placement equality includes overlay cutouts"
  )

  -- Calibration tiers.
  local original_cell_w, original_cell_h = vim.env.MD_VIEWER_CELL_WIDTH_PX, vim.env.MD_VIEWER_CELL_HEIGHT_PX
  vim.env.MD_VIEWER_CELL_WIDTH_PX = nil
  vim.env.MD_VIEWER_CELL_HEIGHT_PX = nil
  t.eq("estimated", coords.calibration_tier(), "no env vars means the estimated tier")

  vim.env.MD_VIEWER_CELL_WIDTH_PX = "8"
  vim.env.MD_VIEWER_CELL_HEIGHT_PX = "17"
  t.eq("env", coords.calibration_tier(), "both env vars present means the env tier")
  local env_viewport = coords.viewport({ width = 40, height = 20 }, cfg.render)
  t.eq("env", env_viewport.tier, "viewport reports the env tier when calibrated")
  t.eq(8, env_viewport.cellWidthPx, "viewport surfaces the raw env cell width")
  t.eq(17, env_viewport.cellHeightPx, "viewport surfaces the raw env cell height")
  t.eq(320, env_viewport.widthPx, "env-calibrated width is cells * cell pixel width")
  t.eq(340, env_viewport.heightPx, "env-calibrated height is cells * cell pixel height")

  vim.env.MD_VIEWER_CELL_WIDTH_PX = "0"
  vim.env.MD_VIEWER_CELL_HEIGHT_PX = "17"
  t.eq("estimated", coords.calibration_tier(), "a non-positive env value does not count as calibrated")
  vim.env.MD_VIEWER_CELL_WIDTH_PX, vim.env.MD_VIEWER_CELL_HEIGHT_PX = original_cell_w, original_cell_h

  -- Clamping at viewport bounds. A square cell rect scaled by the estimated
  -- tier's aspect ratio produces a much taller-than-wide pixel rect, so the
  -- height bound is what actually binds here; width still must respect its
  -- own bound without needing to hit it exactly.
  local clamped = coords.viewport({ width = 1000, height = 1000 }, cfg.render)
  t.eq(cfg.render.max_height_px, clamped.heightPx, "oversized viewport clamps its binding dimension exactly")
  t.ok(clamped.widthPx <= cfg.render.max_width_px, "clamped width never exceeds max_width_px")

  -- The configured caps are themselves bounded by what browser.js will honour
  -- (it re-clamps to 1920x1440 on its own), so raising them cannot produce a
  -- viewport that disagrees with the page the numbers describe.
  local generous = vim.tbl_extend("force", cfg.render, { max_width_px = 4000, max_height_px = 4000 })
  local over_capped = coords.viewport({ width = 1000, height = 1000 }, generous)
  t.ok(over_capped.widthPx <= 1920, "a raised max_width_px is still bounded by the renderer's own cap")
  t.eq(1440, over_capped.heightPx, "a raised max_height_px is still bounded by the renderer's own cap")

  -- browser.js also *floors* the page viewport, at 320x240 CSS px. Mirroring
  -- that is what keeps `viewport()`'s numbers equal to the ones the page used:
  -- they become session.viewport_width_px/viewport_height_render_px, the
  -- denominator of every hit test, overlay scale and animation frame. A
  -- 32x10-cell preview used to report 320x200 against a page 240 pixels tall.
  --
  -- The floor is applied as one uniform scale, like the cap above it. Flooring
  -- each axis on its own is what browser.js does, but browser.js is the last
  -- stop -- here it would change the aspect ratio, and the terminal then
  -- squeezes the PNG back into the cell box, so the text comes out compressed
  -- rather than merely small. 320x200 scales to 384x240, not 320x240.
  local shallow = coords.viewport({ width = 32, height = 10 }, cfg.render)
  t.eq(384, shallow.widthPx, "a short viewport scales up uniformly rather than stretching to the floor")
  t.eq(240, shallow.heightPx, "the binding axis lands exactly on the page's own floor")
  t.near(320 / 200, shallow.widthPx / shallow.heightPx, 1e-9, "the floor preserves the aspect ratio the cells describe")
  t.ok(shallow.widthPx >= 320 and shallow.heightPx >= 240, "both axes still clear the page's floors")

  -- ---------------------------------------------------------------------
  -- The measured tier: env > measured > estimated.
  --
  -- `cellpixels.measure()` reports *device* pixels, which is the unit a
  -- placement rectangle is drawn in. A viewport is CSS pixels and browser.js
  -- captures it back at `device_scale_factor`, so the conversion is a
  -- division. Inverting it doubles the CSS viewport and quadruples the PNG,
  -- and the 1920x1440 caps then hide the mistake by silently downscaling.
  -- ---------------------------------------------------------------------
  if measurable then
    vim.env.MD_VIEWER_CELL_WIDTH_PX = nil
    vim.env.MD_VIEWER_CELL_HEIGHT_PX = nil
    -- 100x40 cells over 1400x1280 device pixels: the 14x32 cell actually read
    -- from the 2x display that motivated this tier.
    winsize = { cols = 100, rows = 40, xpixel = 1400, ypixel = 1280 }

    local retina = vim.tbl_extend("force", cfg.render, { device_scale_factor = 2 })
    t.eq("measured", coords.calibration_tier(retina), "a terminal reporting pixel geometry measures its own cell")
    local measured = coords.viewport({ width = 60, height = 30 }, retina)
    t.eq("measured", measured.tier, "viewport reports the measured tier")
    t.eq(7, measured.cellWidthPx, "a 14px device cell is 7 CSS px at a device scale of 2")
    t.eq(16, measured.cellHeightPx, "a 32px device cell is 16 CSS px at a device scale of 2")
    t.eq(60 * 7, measured.widthPx, "measured width is cells times the CSS cell width")
    t.eq(30 * 16, measured.heightPx, "measured height is cells times the CSS cell height")

    -- The divisor is the configured scale, not a hardcoded 2. A non-Retina
    -- terminal measures the same cell it draws.
    local unscaled = vim.tbl_extend("force", cfg.render, { device_scale_factor = 1 })
    local plain = coords.viewport({ width = 60, height = 30 }, unscaled)
    t.eq(14, plain.cellWidthPx, "a device scale of 1 leaves device pixels as CSS pixels")
    t.eq(60 * 14, plain.widthPx, "the conversion divides by the configured scale, not by 2 (scale 1)")

    -- A 3x display reports a 3x cell. The reported geometry and the configured
    -- scale have to be consistent with each other now: pairing a 2x display's
    -- 14px cell with `device_scale_factor = 3` would describe a 4.67 CSS px
    -- cell -- a font no one is running -- and the plausibility check below
    -- would (correctly) read that as a double divide and refuse it.
    winsize = { cols = 100, rows = 40, xpixel = 2100, ypixel = 1920 }
    local dense_cfg = vim.tbl_extend("force", cfg.render, { device_scale_factor = 3 })
    local dense = coords.viewport({ width = 100, height = 40 }, dense_cfg)
    t.eq(7, dense.cellWidthPx, "a device scale of 3 divides by 3")
    t.eq(100 * 7, dense.widthPx, "the conversion divides by the configured scale (scale 3)")
    t.eq("device", dense.cellUnit, "a self-consistent 3x report is taken at face value")
    winsize = { cols = 100, rows = 40, xpixel = 1400, ypixel = 1280 }

    -- ------------------------------------------------------------------
    -- Picking the divisor rather than assuming it.
    --
    -- The divide above rests on two things nothing can check directly: that
    -- the terminal means device pixels by `ws_xpixel`, and that the display
    -- really is `device_scale_factor` times logical. Break either and the CSS
    -- viewport comes out half size, the terminal upscales the PNG into the
    -- cells anyway, and every glyph renders at twice its configured size.
    -- ------------------------------------------------------------------

    -- A terminal reporting *logical* points: the cell is already CSS pixels,
    -- and dividing it again would describe a 3.5px-wide cell.
    winsize = { cols = 100, rows = 40, xpixel = 700, ypixel = 640 }
    local logical = coords.viewport({ width = 60, height = 30 }, retina)
    t.eq("measured", logical.tier, "the unit decision does not invent a new calibration tier")
    t.eq(7, logical.cellWidthPx, "a cell already in CSS pixels is not divided a second time")
    t.eq(16, logical.cellHeightPx, "the height follows the same divisor as the width")
    t.eq("logical", logical.cellUnit, "the reported unit is named")
    t.eq(1, logical.cellDivisor, "the chosen divisor is reported")
    t.eq("heuristic", logical.cellUnitSource, "and so is what chose it")
    t.eq(60 * 7, logical.widthPx, "the viewport is sized from the repaired cell")

    -- The same repair, arriving by the other route: a 1x display left on the
    -- default device_scale_factor of 2. No terminal bug is required.
    winsize = { cols = 100, rows = 40, xpixel = 800, ypixel = 680 }
    local one_x = coords.viewport({ width = 60, height = 30 }, retina)
    t.eq(8, one_x.cellWidthPx, "a 1x display's cell survives a device_scale_factor it does not match")
    t.eq(17, one_x.cellHeightPx, "the 8x17 cell a non-Retina terminal actually reports")
    t.eq("heuristic", one_x.cellUnitSource, "the mismatch is repaired by the same rule")

    -- Where both divisors describe a plausible cell -- the ordinary,
    -- correctly-reporting 2x terminal -- the configured scale wins and nothing
    -- about this changes.
    winsize = { cols = 100, rows = 40, xpixel = 1400, ypixel = 1280 }
    local unambiguous = coords.viewport({ width = 60, height = 30 }, retina)
    t.eq(7, unambiguous.cellWidthPx, "an unambiguous report still divides by the configured scale")
    t.eq("device", unambiguous.cellUnit, "and is still reported as device pixels")
    t.eq("default", unambiguous.cellUnitSource, "with no heuristic involved")
    t.ok(unambiguous.cellPlausible, "the resulting cell is a cell a font could have")

    -- Explicit configuration still outranks the measurement, so a terminal
    -- that reports geometry nobody can correct stays correctable by hand.
    vim.env.MD_VIEWER_CELL_WIDTH_PX = "8"
    vim.env.MD_VIEWER_CELL_HEIGHT_PX = "17"
    local overridden = coords.viewport({ width = 60, height = 30 }, retina)
    t.eq("env", overridden.tier, "an explicit env override outranks a measurable terminal")
    t.eq(8, overridden.cellWidthPx, "the env override supplies the cell, and is not divided by the device scale")
    t.eq(60 * 8, overridden.widthPx, "the env override sizes the viewport")
    vim.env.MD_VIEWER_CELL_WIDTH_PX = nil
    vim.env.MD_VIEWER_CELL_HEIGHT_PX = nil

    -- A terminal is free to report a pixel size its grid does not divide
    -- evenly. Rounding the cell would put back the error this tier removes;
    -- only the finished viewport is rounded.
    winsize = { cols = 3, rows = 2, xpixel = 43, ypixel = 65 }
    local fractional = coords.viewport({ width = 60, height = 30 }, retina)
    t.near(43 / 6, fractional.cellWidthPx, 1e-9, "a fractional cell survives the device-to-CSS conversion")
    t.eq(430, fractional.widthPx, "the fractional cell is rounded once, at the viewport")
    t.eq(488, fractional.heightPx, "the fractional cell height is rounded once, at the viewport")

    -- Degrade, never fail: tmux and screen do not propagate pixel geometry.
    winsize = { cols = 100, rows = 40, xpixel = 0, ypixel = 0 }
    t.eq("estimated", coords.calibration_tier(retina), "a terminal reporting zero pixel geometry falls back")

    winsize = nil
    t.eq("estimated", coords.calibration_tier(retina), "a refused ioctl falls back to the estimated tier")
    local fallback = coords.viewport({ width = 80, height = 30 }, cfg.render)
    t.eq("estimated", fallback.tier, "the estimated tier still renders when nothing can be measured")
    t.eq(nil, fallback.cellWidthPx, "the estimated tier has no exact cell to report")
    t.eq(viewport.widthPx, fallback.widthPx, "adding the measured tier left the estimated width unchanged")
    t.eq(viewport.heightPx, fallback.heightPx, "adding the measured tier left the estimated height unchanged")
  else
    t.ok(true, "cellpixels is unavailable on this platform; the measured tier cannot be exercised")
  end
  cellpixels.read_winsize = real_read_winsize
  vim.env.MD_VIEWER_CELL_WIDTH_PX, vim.env.MD_VIEWER_CELL_HEIGHT_PX = original_cell_w, original_cell_h

  -- Real window geometry.
  local original_win = vim.api.nvim_get_current_win()
  local original_laststatus = vim.o.laststatus
  local original_showtabline = vim.o.showtabline

  local split_commands = {
    right = "rightbelow vsplit",
    left = "leftabove vsplit",
    below = "rightbelow split",
    above = "leftabove split",
  }
  for position, command in pairs(split_commands) do
    vim.api.nvim_set_current_win(original_win)
    vim.cmd(command)
    local win = vim.api.nvim_get_current_win()
    local rect = coords.for_window(win)
    t.eq(vim.api.nvim_win_get_width(win), rect.width, position .. " split reports its real width")
    t.eq(vim.api.nvim_win_get_height(win), rect.height, position .. " split reports its real height")
    vim.api.nvim_win_close(win, true)
  end
  vim.api.nvim_set_current_win(original_win)

  -- Winbar presence shifts the text area's screen row down by one.
  vim.cmd("rightbelow vsplit")
  local winbar_win = vim.api.nvim_get_current_win()
  t.eq(false, coords.for_window(winbar_win).winbar, "no winbar by default")
  local without_winbar_row = coords.for_window(winbar_win).row
  vim.wo[winbar_win].winbar = "test"
  local with_winbar = coords.for_window(winbar_win)
  t.eq(true, with_winbar.winbar, "winbar option is detected")
  t.eq(without_winbar_row + 1, with_winbar.row, "a winbar pushes the text area down one screen row")
  vim.api.nvim_win_close(winbar_win, true)
  vim.api.nvim_set_current_win(original_win)

  -- ---------------------------------------------------------------------
  -- A horizontally scrolled window still reports a real placement.
  --
  -- screenpos() answers with every field 0 once `leftcol > 0`, because column
  -- 1 is no longer on screen. The guard used to be `tonumber(screen.row) or
  -- fallback`, and 0 is truthy in Lua -- so the fallback never ran and the
  -- placement came back row/col = -1, which kitty_raw formats as `ESC[0;0H`
  -- and every terminal clamps to the origin: the preview painted over the top
  -- left of the whole terminal instead of over its own split. A bare `zl`
  -- reaches this, with or without any of the caret work that made it likely.
  -- ---------------------------------------------------------------------
  do
    vim.cmd("rightbelow vsplit")
    local scrolled_win = vim.api.nvim_get_current_win()
    local scrolled_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(scrolled_win, scrolled_buf)
    vim.api.nvim_win_set_width(scrolled_win, 40)
    vim.wo[scrolled_win].wrap = false
    vim.api.nvim_buf_set_lines(scrolled_buf, 0, -1, false, { string.rep("x", 200) })

    local unscrolled = coords.for_window(scrolled_win)
    vim.cmd("normal! zl")
    t.ok(
      vim.api.nvim_win_call(scrolled_win, function() return vim.fn.winsaveview().leftcol end) > 0,
      "zl actually scrolled the window horizontally"
    )
    local scrolled = coords.for_window(scrolled_win)
    t.ok(scrolled.row >= 0, "a horizontally scrolled window reports a non-negative row")
    t.ok(scrolled.col >= 0, "a horizontally scrolled window reports a non-negative column")
    t.eq(unscrolled.row, scrolled.row, "horizontal scroll does not move the text area's screen row")
    t.eq(unscrolled.col, scrolled.col, "horizontal scroll does not move the text area's screen column")

    -- Same again with a winbar: the fallback has to add the winbar row back
    -- itself, since nvim_win_get_position() reports the frame, not the text
    -- area. Without that it lands one row high and the image covers the title.
    vim.wo[scrolled_win].winbar = "test"
    local scrolled_winbar = coords.for_window(scrolled_win)
    t.eq(unscrolled.row + 1, scrolled_winbar.row, "the scrolled fallback still accounts for the winbar row")

    vim.api.nvim_win_close(scrolled_win, true)
    vim.api.nvim_buf_delete(scrolled_buf, { force = true })
    vim.api.nvim_set_current_win(original_win)
  end

  -- laststatus: 0/1/2/3.
  vim.cmd("rightbelow vsplit")
  local status_win = vim.api.nvim_get_current_win()
  vim.o.laststatus = 0
  t.eq(false, coords.for_window(status_win).statusline, "laststatus=0 never shows a statusline")
  vim.o.laststatus = 2
  t.eq(true, coords.for_window(status_win).statusline, "laststatus=2 always shows a statusline")
  t.eq(false, coords.for_window(status_win).global_statusline, "laststatus=2 is not reported as global")
  vim.o.laststatus = 3
  t.eq(true, coords.for_window(status_win).statusline, "laststatus=3 shows a statusline")
  t.eq(true, coords.for_window(status_win).global_statusline, "laststatus=3 is reported as global")
  vim.o.laststatus = 1
  t.eq(true, coords.for_window(status_win).statusline, "laststatus=1 shows a statusline once a second window exists")
  vim.o.laststatus = original_laststatus
  vim.api.nvim_win_close(status_win, true)
  vim.api.nvim_set_current_win(original_win)

  -- laststatus=1 with only a single window (back to just original_win, since
  -- every split opened above has already been closed) shows no statusline.
  vim.o.laststatus = 1
  t.eq(false, coords.for_window(original_win).statusline, "laststatus=1 shows no statusline with a single window")
  vim.o.laststatus = original_laststatus

  -- A forced tabline occupies the top screen row, shifting every window down.
  vim.o.showtabline = 0
  local row_without_tabline = coords.for_window(original_win).row
  vim.o.showtabline = 2
  local row_with_tabline = coords.for_window(original_win).row
  t.eq(row_without_tabline + 1, row_with_tabline, "a forced tabline occupies the top screen row")
  vim.o.showtabline = original_showtabline

  -- Resize: geometry recomputes from live window dimensions.
  vim.cmd("rightbelow vsplit")
  local resize_win = vim.api.nvim_get_current_win()
  local before_resize = coords.for_window(resize_win)
  vim.api.nvim_win_set_width(resize_win, math.max(10, before_resize.width - 5))
  local after_resize = coords.for_window(resize_win)
  t.ok(after_resize.width < before_resize.width, "resizing a window changes its reported cell width")
  vim.api.nvim_win_close(resize_win, true)
  vim.api.nvim_set_current_win(original_win)

  -- Guard-cell reservation: preview.placement() reserves the configured
  -- number of cells above the statusline for the raw Kitty backend only.
  vim.cmd("rightbelow vsplit")
  local guard_win = vim.api.nvim_get_current_win()
  vim.o.laststatus = 2
  local plain_placement = preview.placement(guard_win, "nvim_img")
  local raw_placement = preview.placement(guard_win, "kitty_raw")
  t.eq(coords.for_window(guard_win).height, plain_placement.height, "non-raw backends get no statusline guard")
  t.eq(
    plain_placement.height - cfg.image.raw_statusline_guard_cells,
    raw_placement.height,
    "raw backend reserves the configured guard cells"
  )
  t.eq(
    cfg.image.raw_statusline_guard_cells,
    raw_placement.statusline_guard_cells,
    "raw placement reports its guard reservation"
  )
  vim.o.laststatus = original_laststatus
  vim.api.nvim_win_close(guard_win, true)
  vim.api.nvim_set_current_win(original_win)

  -- Overlay bleed: a passive float's cutout grows on its trailing edge only, to
  -- absorb the sub-cell offset a terminal introduces when it applies its window
  -- margin to text but not to graphics placements (see passive_overlays).
  local bleed_rect = { row = 0, col = 0, width = 60, height = 20 }
  local bleed_buf = vim.api.nvim_create_buf(false, true)
  local bleed_win = vim.api.nvim_open_win(bleed_buf, false, {
    relative = "editor",
    row = 2,
    col = 5,
    width = 10,
    height = 1,
    style = "minimal",
    focusable = false,
  })
  local exact = coords.passive_overlays(bleed_rect, nil, 0)[1]
  local bled = coords.passive_overlays(bleed_rect, nil, 2)[1]
  t.ok(exact ~= nil and bled ~= nil, "a passive float is discovered with and without bleed")
  t.eq(exact.col, bled.col, "the bleed leaves the leading edge exactly where it was")
  t.eq(exact.row, bled.row, "the bleed never touches the vertical origin")
  t.eq(exact.height, bled.height, "the bleed never touches the vertical extent")
  t.eq(exact.width + 2, bled.width, "the bleed widens the trailing edge by the requested columns")

  -- Clipping: the bleed can never push the cutout past the placement's own
  -- right edge, which would crop image the overlay does not actually cover.
  local edge_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    relative = "editor",
    row = 4,
    col = 50,
    width = 10,
    height = 1,
    style = "minimal",
    focusable = false,
  })
  vim.api.nvim_win_close(bleed_win, true)
  local clipped
  for _, rect in ipairs(coords.passive_overlays(bleed_rect, nil, 5)) do
    if rect.row == 4 then clipped = rect end
  end
  t.ok(clipped ~= nil, "the edge-hugging float is discovered")
  t.eq(60, clipped.col + clipped.width, "the bleed is clipped to the placement's right edge")
  vim.api.nvim_win_close(edge_win, true)

  -- cell_to_css: Part 4's mouse-cell -> browser-CSS-pixel conversion.
  local placement = { row = 5, col = 10, width = 40, height = 20, exclusions = {} }
  local view = { widthPx = 800, heightPx = 400 }

  -- Cell centring: the first cell (row=5,col=10 in 0-based screen space,
  -- i.e. screenrow=6/screencol=11 in getmousepos()'s 1-based coordinates)
  -- must land on its own centre, not its top-left corner.
  local origin = coords.cell_to_css({ screenrow = 6, screencol = 11 }, placement, view)
  t.near(10, origin.x, 0.01, "first cell's CSS x sits at half a cell width (+0.5 centring)")
  t.near(10, origin.y, 0.01, "first cell's CSS y sits at half a cell height (+0.5 centring)")

  -- The centre is only a representative point. The cell's real extent goes with
  -- it, because the renderer needs the box -- not the point -- to resolve a
  -- click on a cell that straddles the edge of the text. Without it the cell
  -- holding the first character of a line resolves to the page padding and the
  -- click does nothing.
  t.near(20, origin.cellWidthPx, 0.01, "the cell's CSS width travels with the point")
  t.near(20, origin.cellHeightPx, 0.01, "the cell's CSS height travels with the point")

  -- The last addressable cell (row=24,col=49 0-based) also centres, and never
  -- reaches the far edge of the viewport.
  local last_cell = coords.cell_to_css({ screenrow = 25, screencol = 50 }, placement, view)
  t.ok(last_cell.x < view.widthPx, "last cell's CSS x stays inside the viewport")
  t.ok(last_cell.y < view.heightPx, "last cell's CSS y stays inside the viewport")

  -- 1-based -> 0-based origin conversion: screenrow/screencol of exactly
  -- placement.row+1/placement.col+1 is cell (0,0), not (1,1).
  local one_based =
    coords.cell_to_css({ screenrow = placement.row + 1, screencol = placement.col + 1 }, placement, view)
  t.eq(origin, one_based, "1-based getmousepos() coordinates align to the 0-based placement origin")

  t.eq(
    nil,
    coords.cell_to_css({ screenrow = placement.row, screencol = placement.col + 1 }, placement, view),
    "a point one row above the placement is outside it"
  )
  t.eq(
    nil,
    coords.cell_to_css({ screenrow = placement.row + 1, screencol = placement.col }, placement, view),
    "a point one column left of the placement is outside it"
  )
  t.eq(
    nil,
    coords.cell_to_css(
      { screenrow = placement.row + placement.height + 1, screencol = placement.col + 1 },
      placement,
      view
    ),
    "a point below the placement's last row is outside it"
  )
  t.eq(
    nil,
    coords.cell_to_css(
      { screenrow = placement.row + 1, screencol = placement.col + placement.width + 1 },
      placement,
      view
    ),
    "a point right of the placement's last column is outside it"
  )

  -- Excluded rectangles (passive overlay cutouts) refuse to resolve even
  -- though the point is inside the placement's outer bounds.
  local guarded = {
    row = 5,
    col = 10,
    width = 40,
    height = 20,
    exclusions = { { row = 8, col = 12, width = 4, height = 2 } },
  }
  t.eq(
    nil,
    coords.cell_to_css({ screenrow = 9, screencol = 13 }, guarded, view),
    "a point inside a passive-overlay cutout does not resolve"
  )
  t.ok(
    coords.cell_to_css({ screenrow = 20, screencol = 13 }, guarded, view) ~= nil,
    "a point outside the cutout, but still inside the placement, resolves normally"
  )

  -- Resize: the same screen cell maps to a different CSS point once the
  -- viewport or placement dimensions change.
  local resized_view = { widthPx = 1600, heightPx = 800 }
  local after_resize = coords.cell_to_css({ screenrow = 6, screencol = 11 }, placement, resized_view)
  t.near(20, after_resize.x, 0.01, "widening the viewport scales the resolved CSS x proportionally")
  t.near(20, after_resize.y, 0.01, "heightening the viewport scales the resolved CSS y proportionally")

  t.eq(nil, coords.cell_to_css(nil, placement, view), "a missing mouse point never resolves")
  t.eq(nil, coords.cell_to_css({ screenrow = 6, screencol = 11 }, nil, view), "a missing placement never resolves")
  t.eq(
    nil,
    coords.cell_to_css({ screenrow = 6, screencol = 11 }, placement, { widthPx = 0, heightPx = 0 }),
    "a missing/zero viewport never resolves"
  )
end
