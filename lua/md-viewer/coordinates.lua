local M = {}

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
  local screen = vim.fn.screenpos(win, topline, 1)
  local row = (tonumber(screen.row) or (pos[1] + 1)) - 1
  local col = (tonumber(screen.col) or (pos[2] + 1)) - 1
  local winbar = option_value("winbar", { win = win }) or ""
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
function M.passive_overlays(rect, ignored_win)
  local result = {}
  for _, item in ipairs(floating_windows(rect, ignored_win, false)) do
    result[#result + 1] = item.rect
  end
  table.sort(result, function(a, b)
    if a.row ~= b.row then return a.row < b.row end
    if a.col ~= b.col then return a.col < b.col end
    if a.height ~= b.height then return a.height < b.height end
    return a.width < b.width
  end)
  return result
end

---Which calibration tier cell-metric conversion currently uses:
---"env" when MD_VIEWER_CELL_WIDTH_PX/MD_VIEWER_CELL_HEIGHT_PX are both set to
---positive numbers, otherwise "estimated" (the configured aspect ratio and
---width guess).
---
---A "measured" tier (deriving real cell-pixel dimensions from the terminal
---itself, with no configuration at all) was investigated for this and is not
---currently possible: Neovim's `TermResponse` autocmd only fires for DA1,
---OSC, DCS, and APC terminal responses, and `nvim_list_uis()` reports grid
---size in cells, not pixels. The XTWINOPS pixel-geometry reports
---(`CSI 14 t` / `CSI 18 t`) most terminals answer are plain CSI responses,
---which Neovim does not expose a way to read. If a future Neovim version
---exposes real pixel geometry, add "measured" ahead of "env" here.
function M.calibration_tier()
  local cell_w = tonumber(vim.env.MD_VIEWER_CELL_WIDTH_PX)
  local cell_h = tonumber(vim.env.MD_VIEWER_CELL_HEIGHT_PX)
  if cell_w and cell_h and cell_w > 0 and cell_h > 0 then return "env" end
  return "estimated"
end

---Map cells to a bounded browser viewport. Exact cell pixels can be supplied
---through MD_VIEWER_CELL_WIDTH_PX/MD_VIEWER_CELL_HEIGHT_PX. Otherwise this preserves
---the configured cell aspect ratio and lets the terminal scale the PNG.
function M.viewport(rect, render)
  local tier = M.calibration_tier()
  local cell_w = tonumber(vim.env.MD_VIEWER_CELL_WIDTH_PX)
  local cell_h = tonumber(vim.env.MD_VIEWER_CELL_HEIGHT_PX)
  local width, height
  if tier == "env" then
    width, height = rect.width * cell_w, rect.height * cell_h
  else
    width = math.max(320, rect.width * (render.estimated_cell_width_px or 10))
    height = width * (rect.height / math.max(rect.width, 1)) / render.cell_aspect_ratio
  end
  local scale = math.min(1, render.max_width_px / width, render.max_height_px / height)
  return {
    widthPx = math.max(1, math.floor(width * scale + 0.5)),
    heightPx = math.max(1, math.floor(height * scale + 0.5)),
    deviceScaleFactor = render.device_scale_factor,
    tier = tier,
    cellWidthPx = cell_w,
    cellHeightPx = cell_h,
  }
end

return M
