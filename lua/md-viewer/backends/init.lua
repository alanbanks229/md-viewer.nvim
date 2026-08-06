local config = require("md-viewer.config")
local modules = {
  nvim_img = require("md-viewer.backends.nvim_img"),
  kitty_raw = require("md-viewer.backends.kitty_raw"),
  cells = require("md-viewer.backends.cells"),
}

local M = {}

function M.select(requested)
  requested = requested or config.get().image.backend
  if requested ~= "auto" then
    local backend = modules[requested]
    local ok, reason = backend.detect()
    if not ok then return nil, ("requested backend %s unavailable: %s"):format(requested, reason) end
    return backend, reason
  end
  local ok, reason = modules.nvim_img.detect()
  if ok then return modules.nvim_img, "verified: " .. reason end
  local raw_ok, raw_reason = modules.kitty_raw.detect()
  if raw_ok then return modules.kitty_raw, raw_reason end
  return modules.cells, ("nvim_img unavailable (%s); %s; using cells"):format(reason, raw_reason)
end

function M.health()
  local selected, reason = M.select()
  return {
    selected = selected and selected.name or nil,
    decision = reason,
    nvim_img = modules.nvim_img.health(),
    kitty_raw = modules.kitty_raw.health(),
    cells = modules.cells.health(),
  }
end

function M.get(name) return modules[name] end

return M
