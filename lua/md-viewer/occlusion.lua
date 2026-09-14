local animation = require("md-viewer.animation")
local config = require("md-viewer.config")
local coordinates = require("md-viewer.coordinates")
local debounce = require("md-viewer.debounce")
local presenter = require("md-viewer.presenter")
local preview = require("md-viewer.preview")
local resident_session = require("md-viewer.resident_session")
local state = require("md-viewer.state")

local M = {}
local host

---Connect the controller-owned orchestration that reconciliation invokes.
---Functions are injected so this module can drive either rendering model
---without requiring controller and recreating the cycle presenter removed.
function M.set_host(value)
  assert(type(value) == "table", "occlusion host must be a table")
  for _, name in ipairs({ "valid", "show_cached", "draw_resident", "schedule" }) do
    assert(type(value[name]) == "function", "occlusion host is missing " .. name)
  end
  host = value
end

local function valid(session) return host ~= nil and host.valid(session) end
local function notify_error(message) vim.notify("md-viewer: " .. tostring(message), vim.log.levels.ERROR) end

---Visit each drawable document once. Pane-scoped state may contain inactive
---documents too, so every caller shares this active-and-valid filter.
function M.each_session(fn)
  for _, session in pairs(state.active_documents()) do
    if valid(session) then fn(session) end
  end
end

---Remove every terminal placement owned by a session while retaining caches
---that can restore it without another renderer round trip.
function M.clear_image(session)
  presenter.clear_selection_overlay(session)
  presenter.clear_caret_overlay(session)
  if session.image_id and session.backend then session.backend.clear(session.image_id) end
  session.image_id = nil
  session.frame_scroll_y, session.frame_revision = nil, nil
  session.last_placement = nil
  -- A resident session has no image_id, so its composed bands have to be
  -- removed explicitly. The uploaded chunks remain available for re-cropping.
  session.resident_screen = false
  resident_session.unplace(session)
  animation.clear(session)
end

---Refresh the session's occlusion diagnostics and report whether its image
---must be hidden. The result deliberately includes all three reasons an image
---cannot be shown: a background tabpage, a blocking window, or transient UI
---suppression. Calling this `must_hide` names the broader meaning that the old
---`update_occlusion` boolean left implicit.
function M.must_hide(session)
  if not valid(session) or session.backend.name == "cells" then return false end
  -- preview.occlusion only examines windows on the preview's own tabpage.
  -- A hidden tab retains plausible geometry, so detect it independently before
  -- any placement can be sent over the currently visible tabpage.
  local hidden = not coordinates.window_is_displayed(session.preview_win)
  session.tabpage_hidden = hidden
  if hidden then
    session.occluded = false
    session.occluding_windows = {}
    return true
  end
  local blocked, windows = preview.occlusion(session.preview_win)
  session.occluded = blocked
  session.occluding_windows = windows
  return blocked or session.ui_suppressed
end

local function local_mode(session) return presenter.local_mode(session) end

---Re-place the viewport model's existing frame after geometry or exclusions
---change. `force` redraws even an identical placement for terminal-owned UI
---transitions such as CmdlineEnter and CmdlineLeave.
function M.reconcile_placement(session, force)
  if session.backend.name ~= "kitty_raw" or not session.image_id or session.ui_suppressed then return end
  -- In local mode, the id is only a reference until the helper confirms the
  -- upload. Addressing it earlier asks the terminal to move pixels not yet up.
  if local_mode(session) and not session.local_frame_confirmed then return end
  -- A hidden tabpage keeps reporting geometry, but using it would place the
  -- image over the tabpage the user is actually viewing.
  if not coordinates.window_is_displayed(session.preview_win) then return end
  local placement = preview.placement(session.preview_win, session.backend.name)
  if force or not coordinates.same(session.last_placement, placement) then
    local ok, moved, err = pcall(session.backend.move, session.image_id, placement)
    if not ok then
      notify_error(moved)
      return
    end
    if not moved then
      notify_error(err or "failed to update image placement")
      return
    end
    -- Selection rectangles were measured against the old placement. A later
    -- selection frame will derive them again against the new one.
    presenter.clear_selection_overlay(session)
  end
  -- Refresh even when no move happened: click resolution reads exclusions
  -- from this value, and the animation and caret surfaces share its geometry.
  session.last_placement = placement
  animation.repaint(session)
  preview.reset_surface(session)
  preview.update_line_numbers(session)
end

---Reconcile the resident model by composing its retained bands again. A
---resident screen owns no single image id that can be moved in place.
function M.reconcile_resident(session)
  if session.ui_suppressed then return end
  if not coordinates.window_is_displayed(session.preview_win) then return end
  if not session.resident_screen then
    host.draw_resident(session)
    return
  end
  local placement = preview.placement(session.preview_win, session.backend.name)
  if not coordinates.same(session.last_placement, placement) then host.draw_resident(session) end
end

local function reconcile_session(session, idle_only)
  if session.backend.name == "cells" then return end
  if M.must_hide(session) then
    M.clear_image(session)
  elseif session.image_id then
    -- A resident bootstrap is still an ordinary image until its first bands
    -- replace it, so it follows the viewport placement path here.
    M.reconcile_placement(session)
  elseif session.render_path == "resident" and session.resident then
    M.reconcile_resident(session)
  elseif idle_only and (session.loading or session.render_failed) then
    return
  elseif not host.show_cached(session) then
    host.schedule(session, 0)
  end
end

function M.reconcile() M.each_session(reconcile_session) end

function M.clear_raw_sessions()
  M.each_session(function(session)
    if session.backend.name == "kitty_raw" then M.clear_image(session) end
  end)
end

function M.refresh_raw_sessions()
  M.each_session(function(session)
    if session.backend.name ~= "kitty_raw" or session.ui_suppressed then return end
    if host.show_cached(session) then return end
    if not M.must_hide(session) then host.schedule(session, 0) end
  end)
end

function M.start_ui_poll(session)
  if session.backend.name ~= "kitty_raw" then return end
  local interval = math.max(0, math.floor(config.get().image.ui_poll_ms or 50))
  if interval == 0 or session.ui_poll_timer then return end
  local timer = vim.uv.new_timer()
  session.ui_poll_timer = timer
  timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      if valid(session) then
        reconcile_session(session, true)
      else
        debounce.close(session, "ui_poll_timer")
      end
    end)
  )
end

return M
