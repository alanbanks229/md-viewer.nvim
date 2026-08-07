local config = require("md-viewer.config")
local state = require("md-viewer.state")
local interaction = require("md-viewer.interaction")

local M = {}
local installed_wheel = false
local installed_gestures = false
local installed_gesture_list = {}
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

local function install_wheel(mode, wheel)
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

---Mouse capture is button-scoped (see interaction.lua): a press/activate
---gesture resolves its session from whatever preview is under the pointer,
---but a drag/release belongs to whichever session captured the press, even
---if the pointer has since left that window entirely.
local function gesture_session(mouse, gesture)
  if gesture.kind == "drag" or gesture.kind == "release" then return interaction.captured_session() end
  if not (mouse and mouse.winid and mouse.winid ~= 0) then return nil end
  return state.from_preview_win(mouse.winid)
end

local function install_gesture(mode, gesture)
  saved[mode .. gesture.lhs] = vim.fn.maparg(gesture.lhs, mode, false, true)
  vim.keymap.set(mode, gesture.lhs, function()
    local mouse = vim.fn.getmousepos()
    local session = gesture_session(mouse, gesture)
    if not session then return gesture.lhs end
    local point = interaction.locate(session, mouse)
    -- Press/activate require a resolvable point up front, matching the
    -- excluded/occluded-rectangle rule in policy: nothing is dispatched
    -- there, and the keystroke falls through to normal Neovim behaviour.
    -- Drag/release for an already-captured session always dispatch, even
    -- with no point, so pointer state cannot get stuck "pressed".
    local dispatchable = point ~= nil or gesture.kind == "drag" or gesture.kind == "release"
    if not dispatchable then return gesture.lhs end
    vim.schedule(function() interaction.dispatch(session, gesture, mouse, point) end)
    return "<Ignore>"
  end, {
    expr = true,
    replace_keycodes = true,
    silent = true,
    desc = "md-viewer preview " .. gesture.kind .. " dispatch",
  })
end

local function gestures()
  local cfg = config.get().interaction
  local list = {
    { lhs = "<LeftMouse>", kind = "press", click_count = 1 },
    { lhs = "<LeftDrag>", kind = "drag" },
    { lhs = "<LeftRelease>", kind = "release" },
    { lhs = "<C-LeftMouse>", kind = "activate", modifiers = { ctrl = true } },
    { lhs = "<D-LeftMouse>", kind = "activate", modifiers = { meta = true } },
  }
  if cfg.double_click then
    list[#list + 1] = { lhs = "<2-LeftMouse>", kind = "press", click_count = 2 }
    -- Vim's click-count escalation requires <2-LeftMouse> to already be
    -- mapped for <3-LeftMouse> to ever fire, so triple click rides the same
    -- install gate rather than inventing a second one.
    list[#list + 1] = { lhs = "<3-LeftMouse>", kind = "press", click_count = 3 }
  end
  return list
end

function M.attach(navigate)
  callback = navigate
  local cfg = config.get()
  if not installed_wheel and cfg.sync.mouse_scroll then
    installed_wheel = true
    for _, mode in ipairs(modes) do
      for _, wheel in ipairs(wheels) do
        install_wheel(mode, wheel)
      end
    end
  end
  if not installed_gestures and cfg.interaction.enabled then
    installed_gestures = true
    installed_gesture_list = gestures()
    for _, mode in ipairs(modes) do
      for _, gesture in ipairs(installed_gesture_list) do
        install_gesture(mode, gesture)
      end
    end
  end
end

function M.detach_if_unused()
  if (not installed_wheel and not installed_gestures) or has_graphical_session() then return end
  if installed_wheel then
    for _, mode in ipairs(modes) do
      for _, wheel in ipairs(wheels) do
        pcall(vim.keymap.del, mode, wheel.lhs)
        local previous = saved[mode .. wheel.lhs]
        if previous and not vim.tbl_isempty(previous) then pcall(vim.fn.mapset, mode, false, previous) end
      end
    end
  end
  if installed_gestures then
    for _, mode in ipairs(modes) do
      for _, gesture in ipairs(installed_gesture_list) do
        pcall(vim.keymap.del, mode, gesture.lhs)
        local previous = saved[mode .. gesture.lhs]
        if previous and not vim.tbl_isempty(previous) then pcall(vim.fn.mapset, mode, false, previous) end
      end
    end
  end
  installed_wheel, installed_gestures, installed_gesture_list, callback, saved = false, false, {}, nil, {}
end

function M.is_attached() return installed_wheel or installed_gestures end

return M
