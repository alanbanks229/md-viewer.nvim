local coordinates = require("md-viewer.coordinates")

local M = {}
local owned = {}
local preview_win
local preview_buf
local timer
local frame = 0

-- Two tiny valid PNGs. The terminal scales them into the requested cell box.
local images = {
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl+Zz8AAAAASUVORK5CYII=",
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
}

local function bytes(index)
  return vim.base64.decode(images[index])
end

local function clear_id(id)
  if id and vim.ui and vim.ui.img and vim.ui.img.del then
    pcall(vim.ui.img.del, id)
  end
  owned[id] = nil
end

local function draw()
  if not (preview_win and vim.api.nvim_win_is_valid(preview_win)) then
    return
  end
  local img = vim.ui and vim.ui.img
  if type(img) ~= "table" or type(img.set) ~= "function" then
    vim.notify("md-viewer spike: vim.ui.img is unavailable in this Neovim build", vim.log.levels.ERROR)
    return
  end
  frame = (frame % #images) + 1
  local place = coordinates.for_window(preview_win)
  place.zindex = 20
  local ok, new_id = pcall(img.set, bytes(frame), place)
  if not ok then
    vim.notify("md-viewer spike: vim.ui.img.set failed: " .. tostring(new_id), vim.log.levels.ERROR)
    return
  end
  owned[new_id] = true
  -- Create first, then delete old: the spike deliberately exercises the
  -- least-gap replacement strategy. Only IDs created here are deleted.
  for id in pairs(owned) do
    if id ~= new_id then
      clear_id(id)
    end
  end
end

function M.clear()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  for id in pairs(owned) do
    clear_id(id)
  end
end

function M.start()
  local img = vim.ui and vim.ui.img
  if type(img) ~= "table" or type(img.set) ~= "function" or type(img.del) ~= "function" then
    vim.notify("md-viewer spike cannot start: this build does not expose vim.ui.img.set/del", vim.log.levels.ERROR)
    return false
  end

  vim.cmd("rightbelow vsplit")
  preview_win = vim.api.nvim_get_current_win()
  preview_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(preview_win, preview_buf)
  vim.bo[preview_buf].buftype = "nofile"
  vim.bo[preview_buf].bufhidden = "wipe"
  vim.bo[preview_buf].swapfile = false
  vim.bo[preview_buf].filetype = "md-viewer-spike"
  vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, {
    "md-viewer.nvim vim.ui.img feasibility spike",
    "",
    "The image should cover only this text-grid area.",
    "Run :MdViewerSpikeReplace to replace it.",
    "Run :MdViewerSpikeStop to remove it and close this split.",
  })
  vim.bo[preview_buf].modifiable = false
  vim.bo[preview_buf].readonly = true
  for name, value in pairs({
    number = false, relativenumber = false, signcolumn = "no",
    foldcolumn = "0", wrap = false, cursorline = false, spell = false,
  }) do
    vim.wo[preview_win][name] = value
  end

  vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "WinScrolled", "WinEnter", "TabEnter" }, {
    group = vim.api.nvim_create_augroup("md-viewer_feasibility", { clear = true }),
    callback = vim.schedule_wrap(draw),
  })
  timer = vim.uv.new_timer()
  timer:start(0, 1000, vim.schedule_wrap(draw))
  draw()
  return true
end

function M.stop()
  M.clear()
  if preview_win and vim.api.nvim_win_is_valid(preview_win) then
    vim.api.nvim_win_close(preview_win, true)
  end
end

vim.api.nvim_create_user_command("MdViewerSpikeStart", M.start, {})
vim.api.nvim_create_user_command("MdViewerSpikeReplace", draw, {})
vim.api.nvim_create_user_command("MdViewerSpikeStop", M.stop, {})
vim.api.nvim_create_autocmd("VimLeavePre", { callback = M.clear })

return M
