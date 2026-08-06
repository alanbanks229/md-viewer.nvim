local config = require("md-viewer.config")
local state = require("md-viewer.state")

local M = {}
local installed = false
local callback
local saved = {}
local modes = { "n", "i", "v" }
local wheels = {
  { lhs = "<ScrollWheelDown>", action = "wheel_down" },
  { lhs = "<ScrollWheelUp>", action = "wheel_up" },
}

local function has_graphical_session()
  for _, session in pairs(state.all()) do
    if not session.closed and session.backend and session.backend.name ~= "cells" then return true end
  end
  return false
end

local function install(mode, wheel)
  saved[mode .. wheel.lhs] = vim.fn.maparg(wheel.lhs, mode, false, true)
  vim.keymap.set(mode, wheel.lhs, function()
    local position = vim.fn.getmousepos()
    local session = position and state.from_preview_win(position.winid)
    if session and config.get().sync.mouse_scroll then
      vim.schedule(function()
        if callback then callback(session, wheel.action) end
      end)
      return "<Ignore>"
    end
    return wheel.lhs
  end, {
    expr = true,
    replace_keycodes = true,
    silent = true,
    desc = "md-viewer preview wheel dispatch",
  })
end

function M.attach(navigate)
  callback = navigate
  if installed or not config.get().sync.mouse_scroll then return end
  installed = true
  for _, mode in ipairs(modes) do
    for _, wheel in ipairs(wheels) do install(mode, wheel) end
  end
end

function M.detach_if_unused()
  if not installed or has_graphical_session() then return end
  for _, mode in ipairs(modes) do
    for _, wheel in ipairs(wheels) do
      pcall(vim.keymap.del, mode, wheel.lhs)
      local previous = saved[mode .. wheel.lhs]
      if previous and not vim.tbl_isempty(previous) then pcall(vim.fn.mapset, mode, false, previous) end
    end
  end
  installed, callback, saved = false, nil, {}
end

function M.is_attached()
  return installed
end

return M
