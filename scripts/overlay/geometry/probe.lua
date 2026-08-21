-- Overlay geometry probe. Runs as `nvim -c luafile` *inside* a real terminal
-- window, driven by run.sh.
--
-- It draws through the production code path -- `kitty_raw.show` for the base
-- frame and `kitty_raw.overlay_apply` for the highlight rectangles -- rather
-- than through hand-written escapes, so what the screenshot shows is what a
-- moving selection frame would actually send. The only hand-drawn things are the fiducials, and
-- those are Neovim's own cell backgrounds rather than graphics, so they are
-- pixel-exact by construction and independent of the protocol under test.
--
-- Registration: the screenshot is of a whole display, and nothing in it says
-- where the terminal's content origin is or what the display's backing scale
-- did to the numbers. Screen row 0 is painted magenta end to end, and one cell
-- near the bottom right is painted too. assert.mjs finds them and derives the
-- origin, the device-pixel cell size, and therefore whether a placement pixel
-- is a device pixel -- instead of trusting arithmetic over title bars, window
-- padding and HiDPI.
--
-- Phase protocol with run.sh, so the capture never races the draw:
--   probe writes <out>/phase-N.ready  ->  run.sh screenshots  ->  writes
--   <out>/phase-N.done  ->  probe advances.

local repo = assert(vim.env.MD_VIEWER_REPO, "MD_VIEWER_REPO is required")
local out = assert(vim.env.MD_VIEWER_OVERLAY_OUT, "MD_VIEWER_OVERLAY_OUT is required")

vim.opt.runtimepath:append(repo)

local raw = require("md-viewer.backends.kitty_raw")
local cellpixels = require("md-viewer.cellpixels")

-- The whole point of the run is to find out whether the wezterm profile should
-- have `selection_overlay = true`, so it cannot be relied on to already be
-- true. `"on"` is the override that exists for exactly this -- qualifying a
-- terminal the profile gate has not yet been opened for. Note what it cannot
-- do: it does not override the cell-size or floored-cell preconditions below,
-- because those are correctness and safety, not a capability judgement.
require("md-viewer.config").setup({
  terminal = { profile = vim.env.MD_VIEWER_OVERLAY_PROFILE or "wezterm" },
  interaction = { selection_overlay = "on" },
})

local FIDUCIAL = "#ff00ff"
local BASE_ROW, BASE_COL = 2, 2
local BASE_COLS, BASE_ROWS = 90, 24
-- The production dark-theme selection tint (renderer/src/interact.js's
-- SELECTION_TINT.dark). Using the real one keeps the composite this measures
-- the same composite a user sees.
local TINT = { r = 220, g = 220, b = 220, a = 0.3 }
-- Opaque mid-grey, so the tint composites against something with headroom in
-- both directions and the base's own edges are findable.
local BASE_RGB = { r = 64, g = 64, b = 64, a = 1 }

local function die(message)
  vim.fn.writefile({ message }, out .. "/error.txt")
  vim.cmd("qa!")
end

local function png(width, height, colour, path, margin_x, margin_y)
  local result = vim
    .system({
      "node",
      repo .. "/scripts/overlay/geometry/make-png.mjs",
      tostring(width),
      tostring(height),
      tostring(colour.r),
      tostring(colour.g),
      tostring(colour.b),
      tostring(colour.a),
      path,
      tostring(margin_x or 0),
      tostring(margin_y or 0),
    }, { text = true })
    :wait()
  if result.code ~= 0 then die("make-png failed: " .. tostring(result.stderr)) end
  -- io.open, not vim.fn.readfile: Vim's binary readfile represents NUL bytes as
  -- newlines and splits on real newlines, so a PNG does not survive the round
  -- trip. WezTerm's decoder said so precisely -- "Chunk length wrong: IHDR".
  local handle = assert(io.open(path, "rb"), "cannot read " .. path)
  local bytes = handle:read("*a")
  handle:close()
  return bytes
end

---Block until run.sh has taken the screenshot for this phase.
local function handshake(phase)
  vim.fn.writefile({ tostring(phase) }, ("%s/phase-%d.ready"):format(out, phase))
  local deadline = vim.uv.now() + 60000
  while vim.uv.now() < deadline do
    if vim.uv.fs_stat(("%s/phase-%d.done"):format(out, phase)) then return end
    -- vim.wait rather than uv.sleep: it pumps the loop, which is what lets the
    -- TUI flush the bytes nvim_ui_send queued. Nothing here dirties the screen,
    -- so no redraw lands on top of the placements.
    vim.wait(100, function() return false end, 50)
  end
  die("timed out waiting for the phase " .. phase .. " screenshot")
end

-- ---------------------------------------------------------------------------
-- A screen that will not repaint underneath the measurement.
-- ---------------------------------------------------------------------------
vim.o.termguicolors = true
vim.o.laststatus = 0
vim.o.ruler = false
vim.o.showcmd = false
vim.o.showmode = false
vim.o.number = false
vim.o.relativenumber = false
vim.o.signcolumn = "no"
vim.o.wrap = false
vim.o.cursorline = false
vim.o.list = false
vim.opt.fillchars = { eob = " " }
vim.o.report = 9999
vim.o.more = false

local cols, rows = vim.o.columns, vim.o.lines
local buf = vim.api.nvim_get_current_buf()
vim.bo[buf].modifiable = true
-- Every line is spaces, so no glyph anywhere can be mistaken for painted
-- content and `~` end-of-buffer markers never appear.
local blank = {}
for _ = 1, rows do
  blank[#blank + 1] = string.rep(" ", cols)
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, blank)

-- The fiducials are Neovim's own highlights rather than raw escapes, so a
-- redraw reproduces them instead of erasing them.
vim.api.nvim_set_hl(0, "OverlayProbeFiducial", { bg = FIDUCIAL })
local ns = vim.api.nvim_create_namespace("md-viewer-overlay-probe")
vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = cols, hl_group = "OverlayProbeFiducial" })
-- Buffer line N shows at screen row N-1; the last screen row is the cmdline,
-- so the far corner mark goes one row above it.
local corner_row = rows - 2
vim.api.nvim_buf_set_extmark(buf, ns, corner_row, cols - 1, { end_col = cols, hl_group = "OverlayProbeFiducial" })
vim.api.nvim_win_set_cursor(0, { corner_row + 1, 0 })
vim.cmd("redraw")

-- ---------------------------------------------------------------------------
-- Measure, then draw.
-- ---------------------------------------------------------------------------
-- Wait for the reading to settle before computing anything from it. WezTerm
-- sizes its pty at half scale and corrects it about two seconds in, with the
-- grid identical either side, so a probe that reads once at startup measures
-- the wrong terminal. Production re-reads every selection frame and a
-- selection extension happens long after this; the rig has to reproduce
-- that, not race it.
local cell, cell_reason
local settle_deadline = vim.uv.now() + 15000
local previous = nil
while vim.uv.now() < settle_deadline do
  cell, cell_reason = cellpixels.measure()
  if cell and previous and previous.width == cell.width and previous.height == cell.height then break end
  previous = cell and { width = cell.width, height = cell.height } or nil
  vim.wait(1000, function() return false end, 100)
end
if not cell then die("cellpixels.measure() failed: " .. tostring(cell_reason)) end

local supported, support_reason = raw.overlay_supported()
local cw, ch = math.floor(cell.width), math.floor(cell.height)
local base_w, base_h = BASE_COLS * cw, BASE_ROWS * ch
local placement = { row = BASE_ROW, col = BASE_COL, width = BASE_COLS, height = BASE_ROWS }

-- Whatever encoding the active profile selects, `overlay_margin` says how much
-- extra sheet it needs: one cell on each axis for the sheet-margin encoding,
-- nothing otherwise -- and a zero margin builds the byte-identical PNG.
local margin = raw.overlay_margin()
local margin_x, margin_y = margin and margin.x or 0, margin and margin.y or 0
local base_png = png(base_w, base_h, BASE_RGB, out .. "/base.png")
local sheet_png = png(base_w + margin_x, base_h + margin_y, TINT, out .. "/sheet.png", margin_x, margin_y)

-- Rectangles in base-relative device pixels. The viewport passed to
-- overlay_apply is the base image's own size, so the scale is exactly 1 and a
-- rect coordinate is a device pixel -- which is what makes the expectations
-- below arithmetic rather than estimation.
local function rect(x, y, w, h, name, note) return { x = x, y = y, width = w, height = h, name = name, note = note } end
local cases = {
  rect(0, 0, 8 * cw, 2 * ch, "A-aligned", "cell-aligned in both axes; X and Y are both zero"),
  rect(
    10 * cw + (cw - 1),
    4 * ch + (ch - 1),
    8 * cw + 3,
    2 * ch + 5,
    "B-maxoffset",
    "the decisive case: the largest sub-cell X and Y a cell can carry, spanning many cells, with an unaligned tail"
  ),
  rect(30 * cw + 3, 8 * ch + 5, math.max(1, cw - 4), math.max(1, ch - 8), "C-subcell", "wholly inside one cell"),
  rect(3, 12 * ch, 60 * cw, ch, "D-longline", "check 3's long line: ~60 cells wide with a non-zero X"),
  rect(2 * cw, 16 * ch, 20 * cw, ch, "E-upper", "adjacent bars must not merge: 4px of gap below this one"),
  rect(2 * cw, 17 * ch + 4, 20 * cw, ch, "E-lower", "the second of the adjacent pair"),
}

local expectations = {
  wezterm = vim.env.MD_VIEWER_OVERLAY_BUILD,
  columns = cols,
  rows = rows,
  fiducial = FIDUCIAL,
  fiducial_corner = { row = corner_row, col = cols - 1 },
  cell_from_ioctl = { width = cell.width, height = cell.height, cols = cell.cols, rows = cell.rows },
  cell_floor = { width = cw, height = ch },
  overlay_supported = supported,
  overlay_reason = support_reason,
  overlay_margin = { x = margin_x, y = margin_y },
  base = { row = BASE_ROW, col = BASE_COL, cols = BASE_COLS, rows = BASE_ROWS, width_px = base_w, height_px = base_h },
  base_rgb = BASE_RGB,
  tint = TINT,
  rects = {},
}
for _, case in ipairs(cases) do
  expectations.rects[#expectations.rects + 1] = {
    name = case.name,
    note = case.note,
    x = case.x,
    y = case.y,
    width = case.width,
    height = case.height,
    -- Where WezTerm should paint it, in cells-plus-sub-cell-offset terms:
    -- content origin + (base cell + floor(px/cell)) * cell + remainder, which
    -- reduces to content origin + base cell * cell + px.
    expect_x = (BASE_COL * cw) + case.x,
    expect_y = (BASE_ROW * ch) + case.y,
    expect_sub_cell_x = case.x % cw,
    expect_sub_cell_y = case.y % ch,
  }
end
vim.fn.writefile({ vim.json.encode(expectations) }, out .. "/expectations.json")

if not supported then die("overlay_supported() is false: " .. tostring(support_reason)) end

-- Phase 1: the base frame alone. Establishes the fiducials, the content
-- origin, the device cell size and the untinted base colour.
local base_id = raw.show(base_png, placement)
handshake(1)

-- Phase 2: the highlight rectangles over it.
local set_id, stats =
  raw.overlay_apply(nil, base_id, cases, { widthPx = base_w, heightPx = base_h }, TINT, sheet_png, placement)
if not set_id then die("overlay_apply refused: " .. tostring(stats)) end
vim.fn.writefile({ vim.json.encode(stats) }, out .. "/apply-stats.json")
handshake(2)

-- Phase 3: deleted again. Must be indistinguishable from phase 1 -- prompt
-- check 5, and the one failure mode that has recurred in this area.
raw.overlay_clear(set_id)
handshake(3)

raw.clear_all()
vim.cmd("qa!")
