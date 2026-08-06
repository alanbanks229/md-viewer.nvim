local M = { name = "nvim_img" }
local owned = {}
local last_render_succeeded = false
local config = require("md-viewer.config")

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
  if image_id and not config.get().image.double_buffer then
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
  for id in pairs(owned) do M.clear(id) end
end

function M.health()
  local ok, reason = M.detect()
  return { available = ok, reason = reason, owned_images = vim.tbl_count(owned),
    render_succeeded = last_render_succeeded,
    strategy = config.get().image.double_buffer and "create-then-delete" or "delete-then-create" }
end

return M
