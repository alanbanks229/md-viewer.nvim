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

---Whether Neovim recognises this key name. `nvim_replace_termcodes` leaves an
---unrecognised `<...>` name literal instead of erroring, so a surviving `<` is
---the test. Gestures that fail it are skipped entirely rather than mapped,
---which keeps `installed_gesture_list` equal to what was actually installed --
---the list `M.detach_if_unused` iterates to restore prior mappings.
local function parseable(lhs)
  local ok, resolved = pcall(vim.api.nvim_replace_termcodes, lhs, true, true, true)
  return ok and not resolved:find("<", 1, true)
end

local function install_gesture(mode, gesture)
  saved[mode .. gesture.lhs] = vim.fn.maparg(gesture.lhs, mode, false, true)
  vim.keymap.set(mode, gesture.lhs, function()
    local mouse = vim.fn.getmousepos()
    -- Buttons md-viewer does not act on still have to be swallowed over the
    -- preview: right-drag is Vim's other route into Visual mode and middle
    -- click pastes, and either one repaints the surface cells the image is
    -- composited through.
    if gesture.kind == "suppress" then
      local target = mouse and mouse.winid and mouse.winid ~= 0 and state.from_preview_win(mouse.winid)
      return target and "<Ignore>" or gesture.lhs
    end
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

---Every modifier prefix a terminal can put on a mouse report, as subsets of
---{Shift, Ctrl, Meta}. SGR mouse encoding carries exactly three modifier bits
---(shift 4, alt/meta 8, ctrl 16), so this is the complete set; `D-` is here
---because it was already mapped and the extended keyboard protocols emit it.
---
---`A-` is deliberately absent: Neovim treats `<A-...>` and `<M-...>` as the
---same key, so mapping both would silently overwrite the first and leave
---`saved` holding a restore entry for a mapping that no longer exists.
local MODIFIERS = { "", "S-", "C-", "M-", "C-S-", "M-S-", "C-M-", "C-M-S-", "D-" }

---Left-button gestures, for every modifier combination.
---
---Unmapped modifier combinations do not fall through harmlessly: Vim's default
---for `<M-LeftDrag>` is a *blockwise Visual selection*, and a terminal whose
---modifier encoding differs from the ones this plugin was developed against
---will emit one for an ordinary drag. That was reported from Warp as the
---preview blinking to a blank pane with a blue rectangle over it -- the
---rectangle being Neovim's own V-BLOCK highlight, painted over the surface
---cells the image is composited through.
---
---Drag and release route to the ordinary drag/release dispatch rather than to
---`<Ignore>`, because the modifier state can change *during* a gesture: press
---the Alt key mid-drag and the terminal starts reporting `<M-LeftDrag>` for the
---same unbroken physical drag. Ignoring those would freeze the selection where
---it stood. `gesture_session` already resolves drag and release from the
---captured session, so they need no point and no window under the pointer.
local function left_gestures(list)
  for _, mod in ipairs(MODIFIERS) do
    -- Ctrl and Cmd click keep their established meaning: follow the link under
    -- the pointer. Every other combination is an ordinary press.
    if mod == "C-" then
      list[#list + 1] = { lhs = "<C-LeftMouse>", kind = "activate", modifiers = { ctrl = true } }
    elseif mod == "D-" then
      list[#list + 1] = { lhs = "<D-LeftMouse>", kind = "activate", modifiers = { meta = true } }
    else
      list[#list + 1] = { lhs = ("<%sLeftMouse>"):format(mod), kind = "press", click_count = 1 }
    end
    list[#list + 1] = { lhs = ("<%sLeftDrag>"):format(mod), kind = "drag" }
    list[#list + 1] = { lhs = ("<%sLeftRelease>"):format(mod), kind = "release" }
  end
end

local function gestures()
  local cfg = config.get().interaction
  local list = {}
  left_gestures(list)
  -- Buttons with no preview meaning, swallowed over the preview only.
  for _, button in ipairs({ "Right", "Middle" }) do
    for _, suffix in ipairs({ "Mouse", "Drag", "Release" }) do
      list[#list + 1] = { lhs = ("<%s%s>"):format(button, suffix), kind = "suppress" }
    end
  end
  if cfg.double_click then
    list[#list + 1] = { lhs = "<2-LeftMouse>", kind = "press", click_count = 2 }
    -- Vim's click-count escalation requires <2-LeftMouse> to already be
    -- mapped for <3-LeftMouse> to ever fire, so triple click rides the same
    -- install gate rather than inventing a second one.
    list[#list + 1] = { lhs = "<3-LeftMouse>", kind = "press", click_count = 3 }
    -- A fourth click restarts the cycle, matching what a browser does with the
    -- same gesture, and a drag begun from any multi-click reports its own
    -- click count -- `<2-LeftDrag>` and friends were falling through to Vim.
    list[#list + 1] = { lhs = "<4-LeftMouse>", kind = "press", click_count = 1 }
    for count = 2, 4 do
      list[#list + 1] = { lhs = ("<%d-LeftDrag>"):format(count), kind = "drag" }
      list[#list + 1] = { lhs = ("<%d-LeftRelease>"):format(count), kind = "release" }
    end
  end
  return vim.tbl_filter(function(gesture) return parseable(gesture.lhs) end, list)
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
  installed_wheel, installed_gestures = false, false
  installed_gesture_list, callback, saved = {}, nil, {}
end

function M.is_attached() return installed_wheel or installed_gestures end

return M
