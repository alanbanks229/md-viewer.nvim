local config = require("md-viewer.config")
local coordinates = require("md-viewer.coordinates")
local debounce = require("md-viewer.debounce")

local M = {}

local split_commands = {
  right = "rightbelow vsplit",
  left = "leftabove vsplit",
  below = "rightbelow split",
  above = "leftabove split",
}

local loading_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function loading_label(session)
  local index = (session.loading_frame % #loading_frames) + 1
  return loading_frames[index] .. "  Rendering Markdown…"
end

local function update_loading(session)
  if not session.loading or not session.preview_win or not vim.api.nvim_win_is_valid(session.preview_win) then
    return false
  end
  local label = loading_label(session)
  local available = math.max(1, vim.api.nvim_win_get_width(session.preview_win) - 2)
  local width = math.min(available, vim.fn.strdisplaywidth(label))
  if width < vim.fn.strdisplaywidth(label) then label = vim.fn.strcharpart(label, 0, width) end
  if session.loading_buf and vim.api.nvim_buf_is_valid(session.loading_buf) then
    vim.bo[session.loading_buf].modifiable = true
    vim.api.nvim_buf_set_lines(session.loading_buf, 0, -1, false, { label })
    vim.bo[session.loading_buf].modifiable = false
  end
  if session.loading_win and vim.api.nvim_win_is_valid(session.loading_win) then
    local height = vim.api.nvim_win_get_height(session.preview_win)
    pcall(vim.api.nvim_win_set_config, session.loading_win, {
      relative = "win",
      win = session.preview_win,
      row = math.max(0, math.floor((height - 1) / 2)),
      col = math.max(0, math.floor((vim.api.nvim_win_get_width(session.preview_win) - width) / 2)),
      width = width,
      height = 1,
    })
  end
  return true
end

function M.start_loading(session)
  local cfg = config.get().preview
  if
    not cfg.loading
    or session.loading
    or not session.preview_win
    or not vim.api.nvim_win_is_valid(session.preview_win)
  then
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  session.loading = true
  session.loading_buf = buf
  session.loading_frame = 0
  local label = loading_label(session)
  local width =
    math.min(math.max(1, vim.api.nvim_win_get_width(session.preview_win) - 2), vim.fn.strdisplaywidth(label))
  local height = vim.api.nvim_win_get_height(session.preview_win)
  session.loading_win = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = session.preview_win,
    row = math.max(0, math.floor((height - 1) / 2)),
    col = math.max(0, math.floor((vim.api.nvim_win_get_width(session.preview_win) - width) / 2)),
    width = width,
    height = 1,
    style = "minimal",
    focusable = false,
    noautocmd = true,
    zindex = 210,
  })
  vim.api.nvim_set_hl(0, "MdViewerLoading", { link = "Comment", default = true })
  vim.wo[session.loading_win].winhighlight = "Normal:MdViewerLoading"
  vim.wo[session.loading_win].winblend = 0
  update_loading(session)
  local timer = vim.uv.new_timer()
  session.loading_timer = timer
  timer:start(
    cfg.loading_interval_ms,
    cfg.loading_interval_ms,
    vim.schedule_wrap(function()
      if not session.loading then
        debounce.close(session, "loading_timer")
        return
      end
      session.loading_frame = session.loading_frame + 1
      if not update_loading(session) then M.stop_loading(session) end
    end)
  )
end

function M.stop_loading(session)
  if not session then return end
  session.loading = false
  debounce.close(session, "loading_timer")
  if session.loading_win and vim.api.nvim_win_is_valid(session.loading_win) then
    pcall(vim.api.nvim_win_close, session.loading_win, true)
  end
  session.loading_win = nil
  session.loading_buf = nil
end

local function source_title(source_buf)
  local name = vim.api.nvim_buf_get_name(source_buf)
  local filename = name == "" and "[No Name]" or vim.fn.fnamemodify(name, ":t")
  return filename:gsub("%%", "%%%%")
end

function M.update_title(session)
  if
    not config.get().preview.winbar
    or not session.preview_win
    or not vim.api.nvim_win_is_valid(session.preview_win)
  then
    return
  end
  vim.wo[session.preview_win].winbar = "  %#Title#  " .. source_title(session.source_buf) .. "%*"
end

function M.open(position, source_buf)
  local cfg = config.get()
  position = position or cfg.split.position
  vim.cmd(split_commands[position])
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "md-viewer"
  vim.api.nvim_buf_set_name(buf, "md-viewer://preview/" .. buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].spell = false

  if cfg.preview.winbar then vim.wo[win].winbar = "  %#Title#  " .. source_title(source_buf) .. "%*" end

  if position == "right" or position == "left" then
    vim.api.nvim_win_set_width(win, math.max(cfg.split.min_width, math.floor(vim.o.columns * cfg.split.width)))
  else
    vim.api.nvim_win_set_height(win, math.max(8, math.floor(vim.o.lines * cfg.split.width)))
  end
  return buf, win
end

function M.placement(win, backend_name)
  local value = coordinates.for_window(win)
  value.zindex = config.get().image.zindex
  if backend_name == "kitty_raw" and value.statusline then
    local guard = math.max(0, math.floor(config.get().image.raw_statusline_guard_cells or 1))
    guard = math.min(guard, math.max(0, value.height - 1))
    value.height = value.height - guard
    value.statusline_guard_cells = guard
  end
  if backend_name == "kitty_raw" then value.exclusions = coordinates.passive_overlays(value, win) end
  return value
end

function M.viewport(win, backend_name) return coordinates.viewport(M.placement(win, backend_name), config.get().render) end

function M.occlusion(win)
  local overlaps = coordinates.overlapping_floats(M.placement(win), win)
  return #overlaps > 0, overlaps
end

function M.reset_surface(session)
  if not (session.preview_buf and vim.api.nvim_buf_is_valid(session.preview_buf)) then return end
  if session.backend and session.backend.name == "cells" then return end
  local lines = vim.api.nvim_buf_get_lines(session.preview_buf, 0, -1, false)
  if #lines ~= 1 or lines[1] ~= "" then
    vim.bo[session.preview_buf].modifiable = true
    vim.bo[session.preview_buf].readonly = false
    vim.api.nvim_buf_set_lines(session.preview_buf, 0, -1, false, { "" })
    vim.bo[session.preview_buf].modifiable = false
    vim.bo[session.preview_buf].readonly = true
  end
end

return M
