return function(t)
  local cellpixels = require("md-viewer.cellpixels")

  -- The measurement must never be cached across a change the terminal makes
  -- without changing the grid.
  --
  -- This is the 2026-08-08 WezTerm defect, and it was not WezTerm's fault.
  -- Measured on both 20240203-110809-5046fc22 and 20260805-104032-4b1c3c15:
  -- the pty is sized 800x480 for a 100x30 grid at startup and corrected to
  -- 1600x1050 about two seconds later, with the row and column counts
  -- identical throughout. `measure` used to cache its first answer and
  -- re-validate it against `vim.o.columns`/`vim.o.lines`, which never move --
  -- so a preview opened in that window kept a half-scale cell for the rest of
  -- the session, and every overlay rectangle was drawn at half size. That is
  -- the same defect as the rectangles once sized in captured pixels, arriving
  -- by a different route.
  --
  -- The reader is substituted rather than the whole of `measure`, so the
  -- caching behaviour under test is the real one.
  --
  -- The grid the stub reports has to be Neovim's own, or the check that used
  -- to validate the cache ("do the row and column counts still match?") fails
  -- for the wrong reason and the stale value is never returned -- which is
  -- exactly how a first attempt at this test passed against the broken code.
  local real_reader = cellpixels.read_winsize
  local grid_cols, grid_rows = vim.o.columns, vim.o.lines
  local reading = { cols = grid_cols, rows = grid_rows, xpixel = grid_cols * 8, ypixel = grid_rows * 16 }
  local reads = 0
  cellpixels.read_winsize = function()
    reads = reads + 1
    return reading.cols, reading.rows, reading.xpixel, reading.ypixel
  end

  local first = cellpixels.measure()
  if first then
    t.eq(8, first.width, "the startup reading is reported as-is")
    t.eq(16, first.height, "including its height")

    -- The terminal corrects itself. Grid unchanged: 100x30 before and after.
    reading.xpixel, reading.ypixel = grid_cols * 16, grid_rows * 35
    local second = cellpixels.measure() or {}
    t.eq(16, second.width, "a corrected pty size is picked up even though the grid did not change")
    t.eq(35, second.height, "in both axes")
    t.ok(reads >= 2, "which means the ioctl is actually re-read, not remembered")

    -- Transient failures must not be remembered either: a terminal that stops
    -- reporting pixel geometry and starts again has to be believed both times.
    reading.xpixel, reading.ypixel = 0, 0
    local blind, blind_reason = cellpixels.measure()
    t.eq(nil, blind, "zero pixel geometry is refused")
    t.ok(
      blind_reason ~= nil and blind_reason:match("no pixel geometry") ~= nil,
      "and says why: " .. tostring(blind_reason)
    )
    reading.xpixel, reading.ypixel = grid_cols * 16, grid_rows * 35
    t.eq(16, (cellpixels.measure() or {}).width, "and the refusal is not sticky once the terminal answers again")

    -- The plausibility band still applies, and is still not remembered.
    reading.xpixel, reading.ypixel = grid_cols, grid_rows * 35
    t.eq(nil, cellpixels.measure(), "a 1px cell is outside the plausible band")
    reading.xpixel = grid_cols * 16
    t.eq(16, (cellpixels.measure() or {}).width, "and that refusal is not sticky either")

    -- A fractional cell survives unrounded: rounding here is what the
    -- mis-sized-rectangle defect was made of.
    reading.xpixel, reading.ypixel = grid_cols * 16 - 1, grid_rows * 35
    t.eq(
      16 - 1 / grid_cols,
      (cellpixels.measure() or {}).width,
      "a cell that does not divide evenly is reported fractionally"
    )
  else
    -- LuaJIT ffi or the platform constant is missing; `measure` short-circuits
    -- before the reader and there is nothing here to test.
    t.ok(true, "cellpixels is unavailable on this platform; caching test skipped")
  end

  cellpixels.read_winsize = real_reader
end
