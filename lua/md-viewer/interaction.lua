local config = require("md-viewer.config")
local coordinates = require("md-viewer.coordinates")
local debounce = require("md-viewer.debounce")
local process = require("md-viewer.process")
local security = require("md-viewer.security")

local M = {}

-- The session currently "owning" an in-progress left-button press. Mouse
-- capture is button-scoped, not window-scoped: once a press lands on preview
-- content, every subsequent <LeftDrag>/<LeftRelease> belongs to that session
-- even if the pointer later leaves the window (or the window's placement
-- rectangle) before the button comes up. Routing drag/release through the
-- window under the pointer instead would both strand `pressed = true`
-- forever when the drag leaves the window, and swallow unrelated drags (e.g.
-- a source-buffer text selection that crosses into the preview) that this
-- session never captured.
local captured = nil

function M.captured_session() return captured end
function M.is_captured(session) return captured ~= nil and captured == session end

---Drop button-scoped pointer/capture state for `session`. Called on session
---teardown (close, buffer wipeout, exit) and on events that hide the preview
---without destroying it (tab leave, suspend), so a stale press can never
---survive past the gesture that started it.
---
---Deliberately does not touch selection/find state -- see `M.forget_selection`
---below. A press captured against the preview does not survive a tab leave
---(there is no guarantee its matching release ever arrives), but a completed
---selection must: §6.3 requires it survive preview focus changes, and reusing
---this function for both would violate that on every tab switch.
function M.forget(session)
  if captured == session then captured = nil end
  if session then session.pointer = nil end
end

---Drop selection/find display state for `session`: on preview close, on a
---content-revision change (a selection from older content must never be
---applied to newer content -- that would be silent corruption in a copy
---operation), and on a renderer restart (the renderer's own in-memory
---interactionState no longer exists in the new process, so the cached Lua-side
---flags describing it would otherwise go stale silently). Lua-side bookkeeping
---only: it deliberately sends no `selection_clear`/`find_clear` request, since
---in every case that calls it the renderer-side state either no longer matters
---(session closing) or no longer exists (process restarted).
function M.forget_selection(session)
  if not session then return end
  session.selection_active = false
  session.selection_content_revision = nil
  session.find_active = false
  session.find_query = nil
  session.find_match_count = 0
  session.find_active_index = nil
  debounce.close(session, "selection_debounce_timer")
  debounce.close(session, "selection_settle_timer")
  if session.pointer then
    session.pointer.selection_request_in_flight = false
    session.pointer.pending_settle = nil
  end
end

---Convert a getmousepos() point into CSS pixels against the placement and
---viewport that produced the image currently on screen, or nil when the
---point cannot be resolved to addressable content.
function M.locate(session, mouse)
  if not (session and mouse and mouse.winid and mouse.winid ~= 0) then return nil end
  if not config.get().interaction.enabled then return nil end
  if not (session.backend and session.backend.name ~= "cells") then return nil end
  if mouse.winid ~= session.preview_win then return nil end
  if not session.last_placement then return nil end
  if not (session.viewport_width_px and session.viewport_height_render_px) then return nil end
  return coordinates.cell_to_css(mouse, session.last_placement, {
    widthPx = session.viewport_width_px,
    heightPx = session.viewport_height_render_px,
  })
end

local function cell_distance(a, b)
  if not (a and b) then return 0 end
  return math.max(math.abs(a.row - b.row), math.abs(a.col - b.col))
end

local function screen_cell(mouse) return { row = tonumber(mouse.screenrow) or 0, col = tonumber(mouse.screencol) or 0 } end

function M.on_press(session, mouse, point, click_count)
  click_count = click_count or 1
  session.pointer = {
    pressed = true,
    press_cell = screen_cell(mouse),
    latest_cell = screen_cell(mouse),
    press_time = vim.uv.now(),
    drag_started = false,
    -- The drag's fixed start point, set once on the first threshold crossing
    -- in on_drag and never moved again for the rest of this gesture.
    anchor_point = nil,
    interaction_serial = ((session.pointer or {}).interaction_serial or 0) + 1,
    selection_request_in_flight = false,
    newest_pending_drag_point = nil,
    -- Set by on_release when a settle request arrives while a preview is
    -- still in flight; picked up by that preview's own completion callback.
    pending_settle = nil,
    content_revision = session.renderer_revision,
    cached_selected_text = nil,
    click_count = click_count,
    multi_click_fired = false,
  }
  captured = session
  -- <2-LeftMouse>/<3-LeftMouse> are already routed through on_press with
  -- click_count = 2/3 (mouse.lua's gestures()); dispatching word/paragraph
  -- select here, on press, matches how a real double/triple-click resolves
  -- synchronously on mousedown rather than waiting for the release that
  -- single-click-to-source used to use. multi_click_fired tells on_release
  -- not to also treat this as a plain-click release.
  if click_count == 2 and point and config.get().interaction.word_select then
    session.pointer.multi_click_fired = true
    M.word_select(session, point)
  elseif click_count == 3 and point and config.get().interaction.paragraph_select then
    session.pointer.multi_click_fired = true
    M.paragraph_select(session, point)
  end
end

function M.on_drag(session, mouse)
  local pointer = session.pointer
  if not (pointer and pointer.pressed) then return end
  pointer.latest_cell = screen_cell(mouse)
  local distance = cell_distance(pointer.press_cell, pointer.latest_cell)
  if distance >= config.get().interaction.drag_threshold_cells then
    pointer.drag_started = true
    pointer.newest_pending_drag_point = M.locate(session, mouse)
    if not pointer.anchor_point and pointer.newest_pending_drag_point then
      pointer.anchor_point = pointer.newest_pending_drag_point
    end
    if config.get().interaction.selection and pointer.anchor_point and pointer.newest_pending_drag_point then
      M.schedule_selection_preview(session)
    end
  end
end

---Debounced (interaction.drag_debounce_ms), coalescing drag-preview request:
---at most one `selection_preview` request in flight, and only the newest
---pending drag point is ever sent -- mirroring
---`controller.schedule_scroll`'s one-in-flight/one-coalesced-pending shape.
---No fixed frame rate: screenshot and terminal-transfer completion supply the
---pacing, same as scrolling.
function M.schedule_selection_preview(session)
  local pointer = session.pointer
  if not pointer then return end
  local cfg = config.get().interaction
  debounce.call(session, "selection_debounce_timer", cfg.drag_debounce_ms, function()
    if session.pointer ~= pointer or not pointer.drag_started then return end
    local point = pointer.newest_pending_drag_point
    if not point or pointer.selection_request_in_flight then return end
    pointer.selection_request_in_flight = true
    local requested_point = point
    M.request_selection(session, pointer.anchor_point, point, "device", false, function(result, err)
      if session.pointer ~= pointer then return end
      pointer.selection_request_in_flight = false
      if not err and result and result.ok ~= false then
        session.selection_active = true
        session.selection_content_revision = session.renderer_revision
        require("md-viewer.controller").display_interact_result(session, result)
      end
      if pointer.pending_settle then
        local pending = pointer.pending_settle
        pointer.pending_settle = nil
        M.settle_selection(session, pointer, pending.anchor, pending.point)
      elseif
        pointer.drag_started
        and pointer.newest_pending_drag_point
        and pointer.newest_pending_drag_point ~= requested_point
      then
        M.schedule_selection_preview(session)
      end
    end)
  end)
end

---Send a `selection_preview`/`selection_commit` interact request. Every
---optional field is always populated -- the same wire-encoding discipline
---`request_hit`'s `modifiers` table follows -- so nothing here can degrade
---into an unexpected JSON shape.
function M.request_selection(session, anchor, focus, capture_scale, is_commit, callback)
  process.request("interact", {
    documentId = session.document_id,
    contentRevision = session.renderer_revision,
    action = is_commit and "selection_commit" or "selection_preview",
    coordinates = { x = focus.x, y = focus.y },
    anchorCoordinates = { x = anchor.x, y = anchor.y },
    cellWidthPx = focus.cellWidthPx,
    cellHeightPx = focus.cellHeightPx,
    viewportWidthPx = session.viewport_width_px,
    viewportHeightPx = session.viewport_height_render_px,
    scrollY = session.applied_scroll_y or 0,
    captureScale = capture_scale,
  }, callback)
end

---Fire the final, settled (device-scale) selection frame after release. If a
---preview request for this gesture is still in flight, defer via
---`pointer.pending_settle` rather than racing a second request against it --
---"one request in flight" governs the commit too, not just preview frames --
---and let that preview's own completion callback pick it up. `settle_ms`
---debounces the request itself, mirroring `scroll_settle_ms`'s role in
---`controller.schedule_scroll`.
function M.settle_selection(session, pointer, anchor, point)
  if pointer.selection_request_in_flight then
    pointer.pending_settle = { anchor = anchor, point = point }
    return
  end
  pointer.selection_request_in_flight = true
  debounce.call(session, "selection_settle_timer", config.get().interaction.settle_ms, function()
    if session.pointer ~= pointer then return end
    M.request_selection(session, anchor, point, "device", true, function(result, err)
      if session.pointer ~= pointer then return end
      pointer.selection_request_in_flight = false
      if not err and result and result.ok ~= false then
        session.selection_active = true
        session.selection_content_revision = session.renderer_revision
        require("md-viewer.controller").display_interact_result(session, result)
        if config.get().interaction.copy_on_select then M.copy_selection(session, true) end
      end
      if pointer.pending_settle then
        local pending = pointer.pending_settle
        pointer.pending_settle = nil
        M.settle_selection(session, pointer, pending.anchor, pending.point)
      end
    end)
  end)
end

---`word_select`, dispatched from `on_press` on a double-click (see there).
function M.word_select(session, point)
  if not point then return end
  if not session.renderer_revision then return end
  if not (session.viewport_width_px and session.viewport_height_render_px) then return end
  process.request("interact", {
    documentId = session.document_id,
    contentRevision = session.renderer_revision,
    action = "word_select",
    coordinates = { x = point.x, y = point.y },
    cellWidthPx = point.cellWidthPx,
    cellHeightPx = point.cellHeightPx,
    viewportWidthPx = session.viewport_width_px,
    viewportHeightPx = session.viewport_height_render_px,
    scrollY = session.applied_scroll_y or 0,
    captureScale = "device",
  }, function(result, err)
    if err or not result or result.ok == false then return end
    session.selection_active = true
    session.selection_content_revision = session.renderer_revision
    require("md-viewer.controller").display_interact_result(session, result)
    if config.get().interaction.copy_on_select then M.copy_selection(session, true) end
  end)
end

---`paragraph_select`, dispatched from `on_press` on a triple-click (see
---there). Mirrors `M.word_select` exactly, except the renderer selects the
---enclosing block's whole text instead of expanding to word boundaries.
function M.paragraph_select(session, point)
  if not point then return end
  if not session.renderer_revision then return end
  if not (session.viewport_width_px and session.viewport_height_render_px) then return end
  process.request("interact", {
    documentId = session.document_id,
    contentRevision = session.renderer_revision,
    action = "paragraph_select",
    coordinates = { x = point.x, y = point.y },
    cellWidthPx = point.cellWidthPx,
    cellHeightPx = point.cellHeightPx,
    viewportWidthPx = session.viewport_width_px,
    viewportHeightPx = session.viewport_height_render_px,
    scrollY = session.applied_scroll_y or 0,
    captureScale = "device",
  }, function(result, err)
    if err or not result or result.ok == false then return end
    session.selection_active = true
    session.selection_content_revision = session.renderer_revision
    require("md-viewer.controller").display_interact_result(session, result)
    if config.get().interaction.copy_on_select then M.copy_selection(session, true) end
  end)
end

---Copy the current selection to the unnamed register, and to `+` when a
---system clipboard provider is configured. Always re-queries the live DOM
---selection (`selection_text`) rather than trusting cached state, so copy
---correctness never depends on any other code path's bookkeeping.
---`silent` suppresses the notification (used by `copy_on_select`, which must
---not narrate every drag).
function M.copy_selection(session, silent)
  if not session.renderer_revision then
    if not silent then vim.notify("md-viewer: nothing selected", vim.log.levels.WARN) end
    return
  end
  process.request("interact", {
    documentId = session.document_id,
    contentRevision = session.renderer_revision,
    action = "selection_text",
    viewportWidthPx = session.viewport_width_px or 0,
    viewportHeightPx = session.viewport_height_render_px or 0,
    scrollY = session.applied_scroll_y or 0,
  }, function(result, err)
    if err or not result or type(result.text) ~= "string" or result.text == "" then
      if not silent then vim.notify("md-viewer: nothing selected", vim.log.levels.WARN) end
      return
    end
    -- Neovim's own clipboard provider decides what happens here (or nothing,
    -- if none is configured) -- md-viewer never shells out to pbcopy/xclip/
    -- wl-copy/clip.exe itself.
    vim.fn.setreg('"', result.text)
    local clipboard_available = vim.fn.has("clipboard") == 1
    if clipboard_available then vim.fn.setreg("+", result.text) end
    if not silent then
      -- Length only. Never put a large selected string into a notification.
      vim.notify(
        ("md-viewer: copied %d character%s"):format(#result.text, #result.text == 1 and "" or "s"),
        vim.log.levels.INFO
      )
    end
  end)
end

function M.clear_selection(session)
  session.selection_active = false
  session.selection_content_revision = nil
  if not session.renderer_revision then return end
  process.request("interact", {
    documentId = session.document_id,
    contentRevision = session.renderer_revision,
    action = "selection_clear",
    viewportWidthPx = session.viewport_width_px or 0,
    viewportHeightPx = session.viewport_height_render_px or 0,
    scrollY = session.applied_scroll_y or 0,
  }, function(result, err)
    if not err and result then require("md-viewer.controller").display_interact_result(session, result) end
  end)
end

function M.find_set(session, query)
  if type(query) ~= "string" or query == "" then return end
  if not session.renderer_revision then
    vim.notify("md-viewer: no rendered content to search yet", vim.log.levels.WARN)
    return
  end
  process.request("interact", {
    documentId = session.document_id,
    contentRevision = session.renderer_revision,
    action = "find_set",
    query = query,
    viewportWidthPx = session.viewport_width_px or 0,
    viewportHeightPx = session.viewport_height_render_px or 0,
    scrollY = session.applied_scroll_y or 0,
  }, function(result, err)
    if err or not result then
      vim.notify("md-viewer: search failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    session.find_active = true
    session.find_query = result.query
    session.find_match_count = result.matchCount or 0
    session.find_active_index = result.activeIndex
    require("md-viewer.controller").display_interact_result(session, result)
    if session.find_match_count == 0 then
      vim.notify(("md-viewer: no matches for %q"):format(query), vim.log.levels.INFO)
    end
  end)
end

local function find_step(session, action)
  if not session.find_active then
    vim.notify("md-viewer: no active search", vim.log.levels.WARN)
    return
  end
  process.request("interact", {
    documentId = session.document_id,
    contentRevision = session.renderer_revision,
    action = action,
    viewportWidthPx = session.viewport_width_px or 0,
    viewportHeightPx = session.viewport_height_render_px or 0,
    scrollY = session.applied_scroll_y or 0,
  }, function(result, err)
    if err or not result then return end
    session.find_active_index = result.activeIndex
    session.find_match_count = result.matchCount or session.find_match_count
    require("md-viewer.controller").display_interact_result(session, result)
  end)
end

function M.find_next(session) find_step(session, "find_next") end
function M.find_previous(session) find_step(session, "find_previous") end

function M.find_clear(session)
  session.find_active = false
  session.find_query = nil
  session.find_match_count = 0
  session.find_active_index = nil
  if not session.renderer_revision then return end
  process.request("interact", {
    documentId = session.document_id,
    contentRevision = session.renderer_revision,
    action = "find_clear",
    viewportWidthPx = session.viewport_width_px or 0,
    viewportHeightPx = session.viewport_height_render_px or 0,
    scrollY = session.applied_scroll_y or 0,
  }, function(result, err)
    if not err and result then require("md-viewer.controller").display_interact_result(session, result) end
  end)
end

---§6.6 Escape precedence: clear an active find; otherwise clear the
---selection; otherwise report false so the caller can fall through to normal
---<Esc> behaviour.
function M.escape(session)
  if session.find_active then
    M.find_clear(session)
    return true
  end
  if session.selection_active then
    M.clear_selection(session)
    return true
  end
  return false
end

local function record_result(session, result)
  session.last_interaction_kind = result.kind
  session.last_interaction_precision = (result.sourcePosition and result.sourcePosition.precision) or "none"
end

function M.open_external(href)
  local ok, err = pcall(vim.ui.open, href)
  if not ok then vim.notify("md-viewer: failed to open link: " .. tostring(err), vim.log.levels.ERROR) end
end

function M.open_local_file(session, href)
  local cfg = config.get()
  local name = vim.api.nvim_buf_get_name(session.source_buf)
  local base_dir = name ~= "" and vim.fs.dirname(vim.fs.normalize(name)) or vim.uv.cwd()
  local root = security.document_root(session.source_buf, cfg.security.document_root)
  local resolved = security.resolve_local_link(href, base_dir, root)
  if not resolved then
    vim.notify("md-viewer: refused to open link outside the document root: " .. href, vim.log.levels.WARN)
    return
  end
  M.open_external(resolved)
end

---§4.4 dispatch table. `result` is a full `activate_at` interact response, so
---a fragment click can read the already-resolved scroll position without a
---second round trip.
function M.activate_link(session, result)
  local link = result.link
  if not link then return end
  if link.type == "fragment" then
    if result.fragmentResolved and type(result.scrollY) == "number" then
      session.scroll_y = result.scrollY
      session.manual_scroll_until = vim.uv.now() + config.get().sync.manual_scroll_hold_ms
      require("md-viewer.controller").schedule_scroll(session)
    end
  elseif link.type == "http" or link.type == "https" or link.type == "mailto" then
    M.open_external(link.href)
  elseif link.type == "local_file" then
    M.open_local_file(session, link.href)
  else
    vim.notify("md-viewer: refused to activate unsafe link: " .. tostring(link.href), vim.log.levels.WARN)
  end
end

---Resolve `point` against the Part 3 `interact` transport. Always uses
---`activate_at`, which reports a link when the point is over one and source
---semantics otherwise. The only remaining caller is the ctrl/cmd-click
---gesture (`M.activate`) -- a plain click no longer navigates to source at
---all (removed per operator decision; see `M.on_release`), so this only ever
---needs the link half of `activate_at`'s answer now.
function M.request_hit(session, point, modifiers, click_count, callback)
  if not session.renderer_revision then
    callback(nil, "md-viewer: no rendered content to interact with yet")
    return
  end
  if not (session.viewport_width_px and session.viewport_height_render_px) then
    callback(nil, "md-viewer: no rendered viewport to interact with yet")
    return
  end
  -- Part 3's contract (see docs/cross-platform-implementation-status.md):
  -- send the scrollY currently on screen, not the position a debounced
  -- scroll has already moved on to wanting. `session.scroll_y` can be ahead
  -- of what the visible image actually shows; `applied_scroll_y` is what the
  -- last completed render/capture put there, i.e. what the user is looking
  -- at and clicking on.
  --
  -- Every modifier is stated explicitly, and that is load-bearing rather than
  -- tidy: `vim.json.encode({})` emits `[]`, not `{}`, and validateEnvelope
  -- rejects an array for `modifiers`. An unmodified click -- which passes no
  -- modifiers at all -- therefore used to be refused with INVALID_INTERACTION
  -- and swallowed by the error branch below, so click-to-source did nothing.
  -- A table that always has four keys can only ever encode as an object.
  modifiers = modifiers or {}
  process.request("interact", {
    documentId = session.document_id,
    contentRevision = session.renderer_revision,
    action = "activate_at",
    coordinates = { x = point.x, y = point.y },
    -- The terminal reports a cell, not a position inside it, so the click
    -- genuinely covers this much of the image. Without it the renderer can only
    -- resolve the cell's centre, and the cell holding the first character of a
    -- line also holds the page's left padding -- so its centre lands on nothing
    -- and clicking the first character of a line does nothing at all.
    cellWidthPx = point.cellWidthPx,
    cellHeightPx = point.cellHeightPx,
    viewportWidthPx = session.viewport_width_px,
    viewportHeightPx = session.viewport_height_render_px,
    scrollY = session.applied_scroll_y or 0,
    modifiers = {
      ctrl = modifiers.ctrl == true,
      shift = modifiers.shift == true,
      alt = modifiers.alt == true,
      meta = modifiers.meta == true,
    },
    clickCount = click_count or 1,
  }, callback)
end

---Ctrl/Cmd-click: activate a link, if the point is over one. A non-link hit
---does nothing -- there is no more "jump to source" fallback here (removed
---per operator decision, matching the plain click's own removal below).
function M.activate(session, point, modifiers)
  if not config.get().interaction.links then return end
  M.request_hit(session, point, modifiers, 1, function(result, err)
    if err or not result then return end
    if result.kind == "link" and result.link then
      record_result(session, result)
      M.activate_link(session, result)
    end
  end)
end

function M.on_release(session, mouse)
  local pointer = session.pointer
  if not (pointer and pointer.pressed) then return end
  pointer.latest_cell = screen_cell(mouse)
  local distance = cell_distance(pointer.press_cell, pointer.latest_cell)
  local is_drag = pointer.drag_started or distance >= config.get().interaction.drag_threshold_cells
  local multi_click_fired = pointer.multi_click_fired
  local last_drag_point = pointer.newest_pending_drag_point
  pointer.pressed = false
  pointer.drag_started = false
  pointer.newest_pending_drag_point = nil
  if captured == session then captured = nil end
  if is_drag then
    -- Prefer the point under the pointer right now; fall back to the last
    -- point a drag event actually resolved, since the release can land a
    -- little outside addressable content (the same cell-edge case Part 5
    -- fixed for clicks).
    local release_point = M.locate(session, mouse) or last_drag_point
    if config.get().interaction.selection and pointer.anchor_point and release_point then
      M.settle_selection(session, pointer, pointer.anchor_point, release_point)
    end
    return
  end
  if multi_click_fired then return end -- already handled on press; not also a click.
  -- VS Code-style click-to-deselect: a plain click no longer navigates to
  -- source at all (removed per operator decision -- it fought the drag-to-
  -- select gesture, since clicking to dismiss a highlight also relocated the
  -- cursor). It only clears an existing selection, matching how a browser or
  -- VS Code's own Markdown preview clears a selection on the next click
  -- regardless of where that click lands.
  if session.selection_active then M.clear_selection(session) end
end

---Entry point called by mouse.lua once a gesture and its owning session are
---resolved. `point` is the CSS point for press/activate (mouse.lua only
---dispatches those once a point resolves); drag/release recompute it
---themselves since the pointer may have left addressable content mid-drag.
function M.dispatch(session, gesture, mouse, point)
  if gesture.kind == "press" then
    M.on_press(session, mouse, point, gesture.click_count)
  elseif gesture.kind == "drag" then
    M.on_drag(session, mouse)
  elseif gesture.kind == "release" then
    M.on_release(session, mouse)
  elseif gesture.kind == "activate" then
    M.activate(session, point, gesture.modifiers)
  end
end

return M
