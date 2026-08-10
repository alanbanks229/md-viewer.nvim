return function(t)
  local config = require("md-viewer.config")
  local coords = require("md-viewer.coordinates")
  local preview = require("md-viewer.preview")
  local cfg = config.get()

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
