local M = {}

local cellpixels = require("md-viewer.cellpixels")

-- browser.js bounds the page viewport itself before it renders (`render()`:
-- 320..1920 wide, 240..1440 tall, in CSS pixels). Those bounds are mirrored here
-- so `viewport()` describes the viewport the page actually got: its numbers
-- become `session.viewport_width_px`/`viewport_height_render_px`, which are the
-- denominator of every hit test, overlay scale, and animation frame. A viewport
-- reported outside them is a silent scale error in all three.
local MIN_VIEWPORT_WIDTH_PX, MIN_VIEWPORT_HEIGHT_PX = 320, 240
local MAX_VIEWPORT_WIDTH_PX, MAX_VIEWPORT_HEIGHT_PX = 1920, 1440

-- What a terminal cell can plausibly measure in *CSS* pixels -- the unit the
-- browser lays text out in. A cell is one character of a monospace font, so the
-- band is really a statement about font sizes: 5 CSS px wide is a ~7pt font and
-- 30 is a ~40pt one. Generous at both ends on purpose, because the only job
-- here is to separate a real cell from one that has been divided by the display
-- scale twice, which lands at half the true figure and therefore well outside.
local MIN_CELL_CSS_PX, MAX_CELL_CSS_PX = 5, 30
local MIN_CELL_CSS_HEIGHT_PX, MAX_CELL_CSS_HEIGHT_PX = 10, 60

local function plausible_cell(width, height)
  return width >= MIN_CELL_CSS_PX
    and width <= MAX_CELL_CSS_PX
    and height >= MIN_CELL_CSS_HEIGHT_PX
    and height <= MAX_CELL_CSS_HEIGHT_PX
end

local function option_value(name, scope)
  local ok, value = pcall(vim.api.nvim_get_option_value, name, scope or {})
  return ok and value or nil
end

---Return the actual screen-cell rectangle occupied by a window's text area.
---Rows and columns are zero-based for vim.ui.img / terminal protocols.
function M.for_window(win)
  assert(vim.api.nvim_win_is_valid(win), "invalid window")

  local width = vim.api.nvim_win_get_width(win)
  local height = vim.api.nvim_win_get_height(win)
  local pos = vim.api.nvim_win_get_position(win)
  local topline = vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
  local winbar = option_value("winbar", { win = win }) or ""

  -- screenpos() reports every field as 0 when the requested position is not
  -- currently visible, and a window reaches that state on its own the moment it
  -- scrolls horizontally: `leftcol > 0` means column 1 is off screen. Measured
  -- on Neovim 0.12.4 -- a bare `zl` in a 40-column split is enough.
  --
  -- The old guard was `tonumber(screen.row) or fallback`, which never fired:
  -- 0 is truthy in Lua, so the fallback was dead code and the placement became
  -- row/col = -1. kitty_raw then formats `ESC[0;0H` (kitty_raw.lua's `at`),
  -- terminals clamp that to the origin, and the preview PNG is painted over the
  -- top-left of the whole terminal instead of over its own split. Test the
  -- value, not its type.
  --
  -- nvim_win_get_position() reports the window frame, which starts one row
  -- above the text area whenever a winbar is present (measured: position row 0
  -- with screenpos row 2). The fallback has to add that row back itself; it is
  -- the text area, not the frame, that every caller here means by "row".
  local screen = vim.fn.screenpos(win, topline, 1)
  local screen_row = tonumber(screen.row) or 0
  local screen_col = tonumber(screen.col) or 0
  local row = screen_row > 0 and (screen_row - 1) or (pos[1] + (winbar ~= "" and 1 or 0))
  local col = screen_col > 0 and (screen_col - 1) or pos[2]

  local laststatus = tonumber(option_value("laststatus", {})) or 2
  local window_count = #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win))
  local statusline_present = laststatus == 2 or laststatus == 3 or (laststatus == 1 and window_count > 1)

  -- nvim_win_get_height() is the text-grid height. screenpos() locates its
  -- first buffer cell, so neither a winbar nor a statusline is included.
  return {
    row = row,
    col = col,
    width = width,
    height = height,
    winbar = winbar ~= "",
    statusline = statusline_present,
    global_statusline = laststatus == 3,
    laststatus = laststatus,
    topline = topline,
    window_row = pos[1],
    window_col = pos[2],
  }
end

---Whether `win` is on the tabpage the terminal is actually displaying.
---
---`M.for_window` above cannot answer this on its own, and neither can any
---other window API: for a window sitting on a *background* tabpage,
---nvim_win_is_valid, nvim_win_get_position, nvim_win_get_width/height and
---vim.fn.screenpos all keep reporting full, valid, completely unchanged
---on-screen geometry, exactly as if it were visible. That is harmless for
---anything Neovim draws itself -- a hidden tabpage is simply not composited
---to the grid -- but a raw Kitty placement is absolute screen coordinates the
---*terminal* keeps compositing until it is explicitly told to stop, so a
---caller that only asks "where is this window?" will happily paint over
---whichever tabpage is really on screen.
function M.window_is_displayed(win)
  if type(win) ~= "number" or not vim.api.nvim_win_is_valid(win) then return false end
  return vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
end

function M.same(a, b)
  if not (a and b and a.row == b.row and a.col == b.col and a.width == b.width and a.height == b.height) then
    return false
  end
  local left, right = a.exclusions or {}, b.exclusions or {}
  if #left ~= #right then return false end
  for index, rect in ipairs(left) do
    if not M.same(rect, right[index]) then return false end
  end
  return true
end

function M.intersects(a, b)
  if not a or not b then return false end
  return a.row < b.row + b.height and b.row < a.row + a.height and a.col < b.col + b.width and b.col < a.col + a.width
end

local function border_cell(border, index)
  return type(border) == "table" and type(border[index]) == "string" and border[index] ~= ""
end

---Return the complete screen rectangle for a float, including its border.
function M.float_rect(win)
  local content = M.for_window(win)
  local cfg = vim.api.nvim_win_get_config(win)
  local pos = vim.api.nvim_win_get_position(win)
  local top = math.max(0, content.row - pos[1])
  local left = math.max(0, content.col - pos[2])
  local right = border_cell(cfg.border, 4) and 1 or 0
  local bottom = border_cell(cfg.border, 6) and 1 or 0
  return {
    row = pos[1],
    col = pos[2],
    width = left + content.width + right,
    height = top + content.height + bottom,
  }
end

local function floating_windows(rect, ignored_win, focusable)
  local result = {}
  local tab = ignored_win and vim.api.nvim_win_get_tabpage(ignored_win) or vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if win ~= ignored_win and vim.api.nvim_win_is_valid(win) then
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative ~= "" and (cfg.focusable ~= false) == focusable and not cfg.hide and not cfg.external then
        local ok, float_rect = pcall(M.float_rect, win)
        if ok and M.intersects(rect, float_rect) then result[#result + 1] = { win = win, rect = float_rect } end
      end
    end
  end
  return result
end

---Return focusable floating windows that require full image suppression.
function M.overlapping_floats(rect, ignored_win)
  local result = {}
  for _, item in ipairs(floating_windows(rect, ignored_win, true)) do
    result[#result + 1] = item.win
  end
  return result
end

---Return passive overlay rectangles to cut out of a raw Kitty placement.
---
---Each rectangle is widened by `image.raw_overlay_bleed_cells` columns on its
---trailing edge, clipped to `rect`. A terminal that applies its horizontal
---window margin to text but not to graphics placements composites the image a
---fraction of a cell toward the origin -- measured at ~10px of a 20px cell on
---iTerm2 -- so the cut-out, which is exact in cells, inherits that shift and the
---image overhangs the overlay's last column. The bleed absorbs it. Trailing edge
---only, because a window margin is never negative: the image can be offset left,
---never right, so it can only ever intrude from that side. Widening the leading
---edge instead would double the gap on the other side and fix nothing.
---
---Horizontal only for the same reason -- the vertical origin measured exact, and
---a blank row under every notification would be more conspicuous than the
---overhang it replaced.
function M.passive_overlays(rect, ignored_win, bleed_cells)
  local bleed = math.max(0, math.floor(bleed_cells or 0))
  local result = {}
  for _, item in ipairs(floating_windows(rect, ignored_win, false)) do
    local overlay = item.rect
    if bleed > 0 then
      local right = math.min(overlay.col + overlay.width + bleed, rect.col + rect.width)
      overlay = {
        row = overlay.row,
        col = overlay.col,
        width = math.max(overlay.width, right - overlay.col),
        height = overlay.height,
      }
    end
    result[#result + 1] = overlay
  end
  table.sort(result, function(a, b)
    if a.row ~= b.row then return a.row < b.row end
    if a.col ~= b.col then return a.col < b.col end
    if a.height ~= b.height then return a.height < b.height end
    return a.width < b.width
  end)
  return result
end

---The terminal's cell in **CSS** pixels, and which tier it came from.
---
---Precedence is env > measured > estimated:
---
---* "env" -- MD_VIEWER_CELL_WIDTH_PX/MD_VIEWER_CELL_HEIGHT_PX are both set to
---  positive numbers. Deliberately ahead of the measurement so a terminal that
---  reports geometry nobody can correct stays correctable by hand.
---* "measured" -- `cellpixels.measure()` answered. `TIOCGWINSZ` carries
---  `ws_xpixel`/`ws_ypixel` beside the grid size, so this needs no terminal
---  reply and no Neovim API. (An earlier note here said a measured tier was
---  impossible; it reasoned only about the XTWINOPS reports `CSI 14 t` /
---  `CSI 18 t`, which are plain CSI responses Neovim owns and will not surface.
---  The ioctl sidesteps that entirely -- see `cellpixels.lua`.)
---* "estimated" -- nothing measurable, chiefly tmux and screen, which do not
---  propagate pixel geometry. Both dimensions come back nil and the caller
---  falls back to `estimated_cell_width_px` and `cell_aspect_ratio`.
---
---Returns `tier, css_width, css_height`.
function M.cell_metrics(render)
  local env_w = tonumber(vim.env.MD_VIEWER_CELL_WIDTH_PX)
  local env_h = tonumber(vim.env.MD_VIEWER_CELL_HEIGHT_PX)
  if env_w and env_h and env_w > 0 and env_h > 0 then
    return "env", env_w, env_h, { unit = "css", divisor = 1, source = "env", plausible = true }
  end

  local cell = cellpixels.measure()
  if cell then
    local scale = tonumber(render and render.device_scale_factor) or 1
    if not (scale > 0) then scale = 1 end
    local unit, divisor, source = "device", scale, "default"
    -- `measure()` reports whatever the terminal put in `ws_xpixel`, which is
    -- *supposed* to be device pixels -- the unit a placement rectangle is drawn
    -- in. A viewport is CSS pixels, and browser.js captures it back at
    -- `deviceScaleFactor`, so dividing by the scale is what makes the PNG land
    -- exactly `cols * cell.width` device pixels wide: the same number of pixels
    -- the terminal draws it into.
    --
    -- That divide used to be unconditional, and it rested on two things nothing
    -- here checks -- that the terminal means device pixels, and that the display
    -- really is `device_scale_factor` times logical. Break either and the CSS
    -- viewport comes out half size, the terminal upscales the PNG to fill the
    -- cells anyway, and every glyph renders at twice its configured size. Two
    -- separate reports land here: a terminal filling `ws_xpixel` with logical
    -- points (Warp), and a 1x display left on the default `device_scale_factor
    -- = 2`, which needs no terminal bug at all.
    --
    -- So try both divisors and keep the one that yields a cell a font could
    -- actually have. Where both do -- the ordinary, correctly-reporting 2x
    -- terminal -- the scale wins and nothing changes. Not rounded: `measure()`
    -- reports fractional cells on purpose.
    local rejected
    if scale ~= 1 and not plausible_cell(cell.width / scale, cell.height / scale) then
      if plausible_cell(cell.width, cell.height) then
        unit, divisor, source, rejected = "logical", 1, "heuristic", scale
      end
    end
    local width, height = cell.width / divisor, cell.height / divisor
    return "measured",
      width,
      height,
      {
        unit = unit,
        divisor = divisor,
        source = source,
        rejected_divisor = rejected,
        plausible = plausible_cell(width, height),
        reported_width = cell.width,
        reported_height = cell.height,
      }
  end

  return "estimated", nil, nil, { unit = "none", divisor = 1, source = "estimate", plausible = true }
end

---One line describing the cell a viewport is built from, and how the unit its
---measurement arrived in was decided. Shared by `:MdViewerHealth` and
---`:MdViewerDebug` so the two cannot describe the same decision differently.
---
---The obvious diagnostic -- the PNG's pixel size against the box it is drawn
---into -- cannot detect this class of error, because both sides are computed
---from the same reported cell and their ratio stays 1.0 however wrong that cell
---is. The only usable signal is whether the CSS cell is a size a font could
---have, so this reports that verdict rather than a measurement.
function M.describe_cell(width, height, detail)
  if not width then return "n/a (estimated tier)" end
  local text = ("%.2fx%.2f"):format(width, height)
  local source = detail and detail.source
  if source == "env" then return text .. " (env override, already CSS px)" end
  if source == "heuristic" then
    return ("%s (reported px taken as CSS and not divided: dividing by %g gave an implausible %.2fx%.2f cell)"):format(
      text,
      detail.rejected_divisor or 1,
      width / (detail.rejected_divisor or 1),
      height / (detail.rejected_divisor or 1)
    )
  end
  if source == "estimate" then return text end
  local qualifier = ("device px / %g"):format((detail and detail.divisor) or 1)
  if detail and detail.plausible == false then
    return ("%s (%s) -- implausible, a terminal cell is normally %g-%g x %g-%g CSS px"):format(
      text,
      qualifier,
      MIN_CELL_CSS_PX,
      MAX_CELL_CSS_PX,
      MIN_CELL_CSS_HEIGHT_PX,
      MAX_CELL_CSS_HEIGHT_PX
    )
  end
  return ("%s (%s)"):format(text, qualifier)
end

---Which calibration tier cell-metric conversion currently uses. `render`
---defaults to the active configuration, so the health collector can ask
---without one; the measured tier needs it only for `device_scale_factor`.
function M.calibration_tier(render)
  local tier = M.cell_metrics(render or require("md-viewer.config").get().render)
  return tier
end

---Map cells to a bounded browser viewport. Under the env and measured tiers the
---cell size is exact and the viewport is the cell rect scaled by it; otherwise
---this preserves the configured cell aspect ratio and lets the terminal scale
---the PNG.
function M.viewport(rect, render)
  local tier, cell_w, cell_h, detail = M.cell_metrics(render)
  local width, height
  if cell_w and cell_h then
    width, height = rect.width * cell_w, rect.height * cell_h
  else
    -- The width floor stays ahead of the aspect derivation: height is derived
    -- from the floored width, and flooring afterwards instead would squash a
    -- narrow preview to the wrong aspect rather than merely stretch it.
    width = math.max(MIN_VIEWPORT_WIDTH_PX, rect.width * (render.estimated_cell_width_px or 10))
    height = width * (rect.height / math.max(rect.width, 1)) / render.cell_aspect_ratio
  end
  -- One uniform scale, so the cap never changes the aspect. The configured caps
  -- are themselves bounded by what browser.js will honour: raising
  -- `max_width_px` past 1920 otherwise buys nothing but a viewport that
  -- disagrees with the page.
  local max_width = math.min(render.max_width_px, MAX_VIEWPORT_WIDTH_PX)
  local max_height = math.min(render.max_height_px, MAX_VIEWPORT_HEIGHT_PX)
  local scale = math.min(1, max_width / width, max_height / height)
  -- The floor is uniform for the same reason the cap is: browser.js clamps each
  -- axis independently, so a viewport under the floor on one axis only came
  -- back with its aspect ratio changed, and the terminal then squeezed the PNG
  -- into the cell box -- horizontally compressed text rather than merely small
  -- text. Scaling up to the floor keeps the shape and lets the caps below
  -- reclaim anything that overshoots.
  scale = math.max(scale, MIN_VIEWPORT_WIDTH_PX / width, MIN_VIEWPORT_HEIGHT_PX / height)
  width, height = width * scale, height * scale
  if width > max_width or height > max_height then
    local back = math.min(max_width / width, max_height / height)
    width, height = width * back, height * back
  end
  return {
    widthPx = math.max(MIN_VIEWPORT_WIDTH_PX, math.floor(width + 0.5)),
    heightPx = math.max(MIN_VIEWPORT_HEIGHT_PX, math.floor(height + 0.5)),
    deviceScaleFactor = render.device_scale_factor,
    tier = tier,
    cellWidthPx = cell_w,
    cellHeightPx = cell_h,
    cellUnit = detail and detail.unit,
    cellDivisor = detail and detail.divisor,
    cellUnitSource = detail and detail.source,
    cellPlausible = detail and detail.plausible,
    cellRejectedDivisor = detail and detail.rejected_divisor,
  }
end

---The inverse of `M.cell_to_css`: the surface cell a viewport CSS point falls
---in, as 1-based `row, column` within `placement`.
---
---Clamped rather than refused, unlike `cell_to_css` in the other direction. The
---caller is placing a caret, and a caret has to go somewhere -- a point a
---fraction of a pixel outside the image should put it on the nearest edge cell,
---not nowhere.
function M.css_to_cell(point, placement, viewport)
  if not (point and placement and viewport and viewport.widthPx and viewport.heightPx) then return nil end
  if placement.width <= 0 or placement.height <= 0 then return nil end
  if viewport.widthPx <= 0 or viewport.heightPx <= 0 then return nil end
  local row = math.floor(((tonumber(point.y) or 0) / viewport.heightPx) * placement.height) + 1
  local column = math.floor(((tonumber(point.x) or 0) / viewport.widthPx) * placement.width) + 1
  return math.max(1, math.min(placement.height, row)), math.max(1, math.min(placement.width, column))
end

-- If anything ever needs the absolute screen cell Neovim's *own* cursor sits
-- on: use `winline()`/`wincol()` inside `nvim_win_call`, added to
-- `M.for_window`'s origin. Not `screenrow()`/`screencol()` -- those read the UI
-- grid's cursor rather than the window's and answer 1,1 for a window that is
-- not current, measured on 0.12.4 inside `nvim_win_call`, after a redraw, and
-- with the window made current. The caret does not need it: its identity is
-- renderer-owned (see caret.lua), so the conversion only ever runs the other
-- way, through `M.css_to_cell`.

---Convert a `vim.fn.getmousepos()`-style screen point into CSS pixel
---coordinates inside the browser viewport that produced the currently
---displayed image, or `nil` when the point cannot be resolved to addressable
---content: outside the placement's cell rectangle, or inside one of its
---excluded rectangles (a passive overlay cutout).
---
---`mouse` needs 1-based `screenrow`/`screencol` (exactly what getmousepos()
---returns). `placement` is the screen-space rect the image was actually drawn
---into (0-based `row`/`col`, cell `width`/`height`, optional `exclusions`).
---`viewport` is the browser viewport, in CSS pixels, that produced that image
---(`widthPx`/`heightPx`). The cell is addressed at its centre (+0.5) because
---the terminal cannot report a sub-cell pointer position.
function M.cell_to_css(mouse, placement, viewport)
  if not (mouse and placement and viewport and viewport.widthPx and viewport.heightPx) then return nil end
  if placement.width <= 0 or placement.height <= 0 then return nil end
  if viewport.widthPx <= 0 or viewport.heightPx <= 0 then return nil end
  local screen_row = (tonumber(mouse.screenrow) or 0) - 1
  local screen_col = (tonumber(mouse.screencol) or 0) - 1
  local local_row = screen_row - placement.row
  local local_col = screen_col - placement.col
  if local_row < 0 or local_col < 0 or local_row >= placement.height or local_col >= placement.width then return nil end
  for _, rect in ipairs(placement.exclusions or {}) do
    if
      screen_row >= rect.row
      and screen_row < rect.row + rect.height
      and screen_col >= rect.col
      and screen_col < rect.col + rect.width
    then
      return nil
    end
  end
  local cell_width = viewport.widthPx / placement.width
  local cell_height = viewport.heightPx / placement.height
  local x = ((local_col + 0.5) / placement.width) * viewport.widthPx
  local y = ((local_row + 0.5) / placement.height) * viewport.heightPx
  return {
    x = math.max(0, math.min(viewport.widthPx - 1e-6, x)),
    y = math.max(0, math.min(viewport.heightPx - 1e-6, y)),
    -- How much of the image one cell actually covers. The centre above is only
    -- a representative point inside this box; the renderer needs the box itself
    -- to resolve a click that lands on a cell straddling the edge of the text.
    cellWidthPx = cell_width,
    cellHeightPx = cell_height,
  }
end

return M
