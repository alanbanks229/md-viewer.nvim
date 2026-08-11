local M = { name = "nvim_img" }
local owned = {}
local last_render_succeeded = false
local terminal = require("md-viewer.terminal")

function M.detect()
  if vim.fn.has("nvim-0.12") ~= 1 then return false, "requires Neovim 0.12+" end
  if #vim.api.nvim_list_uis() == 0 then return false, "no attached UI" end
  local img = vim.ui and vim.ui.img
  if type(img) ~= "table" then return false, "vim.ui.img is absent" end
  if type(img.set) ~= "function" or type(img.del) ~= "function" then
    return false, "vim.ui.img.set/del are incomplete"
  end
  return true, "vim.ui.img.set/del available"
end

function M.show(image_bytes, placement)
  local id = vim.ui.img.set(image_bytes, placement)
  owned[id] = true
  last_render_succeeded = true
  return id
end

function M.update(image_id, image_bytes, placement)
  -- Create-new/delete-old minimizes the blank interval. This is double
  -- buffering with at most two plugin-owned IDs alive during replacement.
  --
  -- Resolved through `terminal.double_buffer`, not by reading
  -- `image.double_buffer` here. That option's default is `nil`, meaning "ask
  -- the terminal profile", and `not nil` is `true` -- so reading it directly
  -- took the delete-then-create branch for every unconfigured user, which is a
  -- blank frame on every render. It showed up as the preview blinking during a
  -- drag, where a frame arrives every few milliseconds.
  if image_id and not terminal.double_buffer() then
    M.clear(image_id)
    return M.show(image_bytes, placement)
  end
  local new_id = M.show(image_bytes, placement)
  if image_id then M.clear(image_id) end
  return new_id
end

function M.move(image_id, placement)
  -- The experimental API has no stable move contract. Reuse get/set only when
  -- supported by the installed build; otherwise the controller rerenders.
  local img = vim.ui.img
  if type(img.get) == "function" then
    local ok, value = pcall(img.get, image_id)
    if ok and value and value.data then return M.update(image_id, value.data, placement) end
  end
  return nil, "vim.ui.img cannot move an existing image on this build"
end

function M.clear(image_id)
  if not owned[image_id] then return false end
  local ok = pcall(vim.ui.img.del, image_id)
  owned[image_id] = nil
  return ok
end

function M.clear_all()
  for id in pairs(owned) do
    M.clear(id)
  end
end

function M.health()
  local ok, reason = M.detect()
  local double_buffer, source = terminal.double_buffer()
  return {
    available = ok,
    reason = reason,
    owned_images = vim.tbl_count(owned),
    render_succeeded = last_render_succeeded,
    strategy = double_buffer and "create-then-delete" or "delete-then-create",
    strategy_source = source,
  }
end

return M
