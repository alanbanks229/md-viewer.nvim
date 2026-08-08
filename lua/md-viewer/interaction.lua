local cellpixels = require("md-viewer.cellpixels")
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

---Every `interact` request funnels through here so `:MdViewerDebug` can report
---how many were sent and how many lost a race (STALE_INTERACTION -- a newer
---request for the same document/lane superseded this one before the renderer
---answered it; see renderer/src/lanes.js). `callback` keeps its ordinary
---two-arg `(result, err)` shape; only this wrapper looks at process.request's
---third `meta` argument.
local function interact_request(session, params, callback)
  session.interaction_request_count = (session.interaction_request_count or 0) + 1
  process.request("interact", params, function(result, err, meta)
    if err and meta and meta.code == "STALE_INTERACTION" then
      session.interaction_stale_count = (session.interaction_stale_count or 0) + 1
    end
    -- `meta` is passed on as a third argument so a caller can tell a lost race
    -- (routine, and not worth telling the user about) from a real failure.
    -- Callers that only take two arguments are unaffected.
    callback(result, err, meta)
  end)
end

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
  -- A renderer restart or content change orphans any overlay rectangles on
  -- screen: nothing will ever supersede them, so they must go now.
  require("md-viewer.controller").clear_selection_overlay(session)
  session.selection_active = false
  session.selection_content_revision = nil
  session.selection_text_length = nil
  session.find_active = false
  session.find_query = nil
  session.find_match_count = 0
  session.find_active_index = nil
  debounce.close(session, "selection_debounce_timer")
  debounce.close(session, "selection_settle_timer")
  debounce.close(session, "drag_idle_settle_timer")
  if session.pointer then
    session.pointer.selection_request_in_flight = false
    session.pointer.pending_settle = nil
    session.pointer.pending_idle_settle = nil
  end
end

---Shared by `M.locate` and `M.locate_for_drag`: everything both need besides
---the window/point check itself, which differs between them.
local function interaction_ready(session)
  if not config.get().interaction.enabled then return false end
  if not (session.backend and session.backend.name ~= "cells") then return false end
  if not session.last_placement then return false end
  if not (session.viewport_width_px and session.viewport_height_render_px) then return false end
  return true
end

---Convert a getmousepos() point into CSS pixels against the placement and
---viewport that produced the image currently on screen, or nil when the
---point cannot be resolved to addressable content. Strict: a point outside
---`session.preview_win` is refused, not clamped -- this is also what decides
---whether a press/click may begin a gesture at all, which must never treat
---"outside the window" as "the nearest edge of the window".
function M.locate(session, mouse)
  if not (session and mouse and mouse.winid and mouse.winid ~= 0) then return nil end
  if mouse.winid ~= session.preview_win then return nil end
  if not interaction_ready(session) then return nil end
  return coordinates.cell_to_css(mouse, session.last_placement, {
    widthPx = session.viewport_width_px,
    heightPx = session.viewport_height_render_px,
  })
end

---Like `M.locate`, but for a drag already in progress: mouse capture is
---button-scoped (see the module-local `captured` comment above), so the
---pointer leaving the preview window -- or straying inside it but outside
---the placed image itself (blank margin, a winbar) -- must not freeze the
---selection. It should keep extending toward the nearest edge, the same way
---a browser or a native text editor behaves when a drag runs past the edge
---of a scrollable view. `session.last_placement` is already in the same
---absolute screen-cell space `getmousepos()` reports
---(`coordinates.for_window`'s doc comment), so clamping is a plain min/max,
---no unit conversion. The exact point is tried first when the window
---matches, so this never resolves *differently* than `M.locate` would for a
---point already inside the placement -- it only adds a fallback for the
---points `M.locate` would otherwise refuse.
---
---This is only half the fix, and on its own it is a no-op: the edge column it
---clamps to is the page's own side padding, which held no addressable block,
---so every request it produced came back `focus_miss` and was dropped by the
---`result.ok ~= false` checks below. `resolveSelectionInPage` in
---`renderer/src/interact.js` supplies the other half -- see the
---`nearestBlockPoint` comment there. Change either one without the other and
---a drag that leaves the window freezes again.
function M.locate_for_drag(session, mouse)
  if not (session and mouse) then return nil end
  if not interaction_ready(session) then return nil end
  local placement = session.last_placement
  local viewport = { widthPx = session.viewport_width_px, heightPx = session.viewport_height_render_px }
  if mouse.winid and mouse.winid == session.preview_win then
    local direct = coordinates.cell_to_css(mouse, placement, viewport)
    if direct then return direct end
  end
  local clamped = {
    screenrow = math.max(
      placement.row + 1,
      math.min(placement.row + placement.height, tonumber(mouse.screenrow) or placement.row + 1)
    ),
    screencol = math.max(
      placement.col + 1,
      math.min(placement.col + placement.width, tonumber(mouse.screencol) or placement.col + 1)
    ),
  }
  return coordinates.cell_to_css(clamped, placement, viewport)
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
    selection_request_in_flight = false,
    newest_pending_drag_point = nil,
    -- Sticky per-gesture opt-out of the overlay display path: set when a
    -- frame could not be drawn as overlay rectangles (too many rects, stale
    -- geometry, backend refusal), after which every remaining frame of this
    -- gesture uses the captured-frame path. Correct and slow beats fast and
    -- wrong, and a fresh press gets a fresh chance.
    overlay_fallback = false,
    -- Ask the next preview request to carry the tint-sheet PNG (once per
    -- color: the backend's upload cache stays warm across gestures).
    overlay_want_sheet = false,
    -- Set by on_release when a settle request arrives while a preview is
    -- still in flight; picked up by that preview's own completion callback.
    pending_settle = nil,
    -- Same idea, for the idle-settle timer (schedule_selection_preview)
    -- finding a preview request already in flight.
    pending_idle_settle = nil,
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
    pointer.newest_pending_drag_point = M.locate_for_drag(session, mouse)
    if not pointer.anchor_point and pointer.newest_pending_drag_point then
      pointer.anchor_point = pointer.newest_pending_drag_point
    end
    if config.get().interaction.selection and pointer.anchor_point and pointer.newest_pending_drag_point then
      M.schedule_selection_preview(session)
    end
  end
end

---Whether this gesture's moving frames may be displayed as backend overlay
---rectangles (stage 4) instead of full captured frames. Requires a backend
---that implements and currently allows the overlay (kitty_raw consults the
---terminal profile and `interaction.selection_overlay`), a base image on
---screen for the rectangles to composite over, and no earlier failure this
---gesture (`pointer.overlay_fallback`).
local function overlay_ready(session, pointer)
  if pointer.overlay_fallback then return false end
  local backend = session.backend
  if not (backend and backend.overlay_apply and backend.overlay_supported) then return false end
  if not backend.overlay_supported() then return false end
  if not (session.image_id and session.last_placement) then return false end
  return true
end

---Dimensions for the tint-sheet PNG request: large enough to crop any
---rectangle out of, whichever frame this session produces.
---
---That is the larger of two boxes. A device-scale capture of the render
---viewport is one; the box the base image is *drawn* into -- the placement's
---cells times the terminal's real cell -- is the other, and it is the one
---overlay crops are actually measured in (see `kitty_raw`'s `overlay_apply`).
---Either can be the bigger, depending on which way `coordinates.viewport`
---mis-estimated the cell, so one sheet has to cover both.
local function sheet_dims(session)
  local scale = config.get().render.device_scale_factor or 1
  local width = (session.viewport_width_px or 0) * scale
  local height = (session.viewport_height_render_px or 0) * scale
  local cell = cellpixels.measure()
  local placement = session.last_placement
  if cell and placement and placement.width and placement.height then
    width = math.max(width, placement.width * cell.width)
    height = math.max(height, placement.height * cell.height)
  end
  return {
    widthPx = math.max(1, math.floor(width + 0.5)),
    heightPx = math.max(1, math.floor(height + 0.5)),
  }
end

---The actual dispatch behind `M.schedule_selection_preview`: at most one
---`selection_preview` request in flight, only the newest pending drag point
---is ever sent (mirroring `controller.schedule_scroll`'s
---one-in-flight/one-coalesced-pending shape), and a request already in
---flight when this runs drops the point and counts it as coalesced -- the
---in-flight request's own completion callback below re-fires for whatever
---point is newest by then. `force_device` is set only by the idle-settle
---timer scheduled in `M.schedule_selection_preview`; every ordinary drag
---frame captures at device scale unless `interaction.fast_drag` is on (see
---`config.lua` for why that is its own knob rather than `render.fast_scroll`,
---and why it defaults off).
---
---On the overlay path (stage 4) the request opts out of capturing entirely:
---the renderer answers with selection rectangles from the same evaluate that
---applied the selection, and `controller.display_selection_overlay` draws
---them over the base image already on screen. A frame the overlay cannot
---display correctly falls back to the captured path -- for the rest of the
---gesture when the reason is structural (`overlay_fallback`), or for exactly
---one round trip when the backend merely needs the tint sheet uploaded.
local function attempt_selection_preview(session, pointer, force_device)
  if session.pointer ~= pointer or not pointer.drag_started then return end
  local point = pointer.newest_pending_drag_point
  if not point then return end
  if pointer.selection_request_in_flight then
    if force_device then
      -- The idle-settle timer found a request already in flight. Rather than
      -- drop the sharpen attempt outright (which would leave a genuinely
      -- paused drag showing a soft frame until the next real movement or
      -- release), the in-flight request's own completion callback below
      -- picks this up once it finishes.
      pointer.pending_idle_settle = true
    else
      session.coalesced_drag_events = (session.coalesced_drag_events or 0) + 1
    end
    return
  end
  pointer.selection_request_in_flight = true
  local requested_point = point
  local capture_scale = (force_device or not config.get().interaction.fast_drag) and "device" or "css"
  local overlay = overlay_ready(session, pointer)
  local overlay_opts = nil
  if overlay then
    local want_sheet = pointer.overlay_want_sheet
      or (
        session.backend.overlay_needs_sheet
        and session.backend.overlay_needs_sheet(session.image_id, nil, session.last_placement)
      )
    overlay_opts = { overlay = true, sheet = want_sheet and sheet_dims(session) or nil }
  end
  M.request_selection(session, pointer.anchor_point, point, capture_scale, false, function(result, err)
    if session.pointer ~= pointer then return end
    pointer.selection_request_in_flight = false
    if not err and result and result.ok ~= false then
      session.selection_active = true
      session.selection_content_revision = session.renderer_revision
      session.selection_text_length = type(result.text) == "string" and #result.text or nil
      if overlay then
        pointer.overlay_want_sheet = false
        local applied, reason = require("md-viewer.controller").display_selection_overlay(session, result)
        if not applied then
          if reason == "need_sheet" and not (overlay_opts and overlay_opts.sheet) then
            -- Expected once per color: re-request with the sheet attached.
            pointer.overlay_want_sheet = true
          else
            pointer.overlay_fallback = true
          end
          -- This frame displayed nothing; redraw it through whichever path
          -- the flags above now select.
          pointer.newest_pending_drag_point = pointer.newest_pending_drag_point or requested_point
          M.schedule_selection_preview(session)
        end
      else
        require("md-viewer.controller").display_interact_result(session, result)
      end
    end
    if pointer.pending_settle then
      -- Release wins over a still-pending idle sharpen -- the gesture is
      -- ending, so there is no point capturing a mid-drag frame first.
      local pending = pointer.pending_settle
      pointer.pending_settle = nil
      pointer.pending_idle_settle = nil
      M.settle_selection(session, pointer, pending.anchor, pending.point)
    elseif pointer.pending_idle_settle then
      pointer.pending_idle_settle = nil
      attempt_selection_preview(session, pointer, true)
    elseif
      pointer.drag_started
      and pointer.newest_pending_drag_point
      and pointer.newest_pending_drag_point ~= requested_point
    then
      M.schedule_selection_preview(session)
    end
  end, overlay_opts)
end

---Debounced (`interaction.drag_debounce_ms`, default `0` -- see below),
---coalescing drag-preview request. With the default, dispatch is immediate
---(no fixed frame rate: screenshot and terminal-transfer completion supply
---the pacing, same as scrolling); `drag_debounce_ms` above `0` still
---debounces ahead of that, for anyone who deliberately wants added latency.
---
---When -- and only when -- `interaction.fast_drag` softens the moving frame,
---this also (re)schedules an idle-settle timer, mirroring
---`controller.schedule_scroll`'s own `scroll_settle_timer`:
---`render.scroll_settle_ms` after the *last* drag point with no further
---movement, one frame captures at device scale even though the mouse button
---is still down, so a drag that pauses mid-gesture (the reader dwelling on
---exactly the text being selected, not still moving) is not left soft for as
---long as the pause lasts. With the default `fast_drag = false` every frame
---is already sharp and the timer would be pure overhead, so it is not armed
---at all. `M.settle_selection` on release guarantees the final frame is
---sharp either way.
function M.schedule_selection_preview(session)
  local pointer = session.pointer
  if not pointer then return end
  local cfg = config.get().interaction
  if cfg.fast_drag then
    debounce.call(
      session,
      "drag_idle_settle_timer",
      config.get().render.scroll_settle_ms,
      function() attempt_selection_preview(session, pointer, true) end
    )
  end
  if cfg.drag_debounce_ms > 0 then
    debounce.call(
      session,
      "selection_debounce_timer",
      cfg.drag_debounce_ms,
      function() attempt_selection_preview(session, pointer, false) end
    )
  else
    attempt_selection_preview(session, pointer, false)
  end
end

---Send a `selection_preview`/`selection_commit` interact request. Every
---optional field is always populated -- the same wire-encoding discipline
---`request_hit`'s `modifiers` table follows -- so nothing here can degrade
---into an unexpected JSON shape.
---
---`opts.overlay` marks a stage-4 overlay frame: the renderer skips the
---screenshot (`capture = false`) and answers with selection rectangles
---instead; `opts.sheet` additionally asks for the tint-sheet PNG at the given
---device-pixel dimensions (sent only until the backend's upload cache is
---warm). The commit path never passes opts, so a release always produces the
---true browser-rendered frame.
function M.request_selection(session, anchor, focus, capture_scale, is_commit, callback, opts)
  opts = opts or {}
  local params = {
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
  }
  if opts.overlay then
    params.capture = false
    if opts.sheet then params.overlaySheet = { widthPx = opts.sheet.widthPx, heightPx = opts.sheet.heightPx } end
  end
  interact_request(session, params, callback)
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
        session.selection_text_length = type(result.text) == "string" and #result.text or nil
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
  interact_request(session, {
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
    session.selection_text_length = type(result.text) == "string" and #result.text or nil
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
  interact_request(session, {
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
    session.selection_text_length = type(result.text) == "string" and #result.text or nil
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
  interact_request(session, {
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
  session.selection_text_length = nil
  if not session.renderer_revision then return end
  interact_request(session, {
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
  interact_request(session, {
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
  interact_request(session, {
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
  interact_request(session, {
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

-- The most recent hand-off to the system handler, for :MdViewerDebug. A user
-- reporting "clicking an external link does nothing" needs to be able to see
-- whether md-viewer ever reached this code, what it ran, and what came back;
-- with none of that recorded, an OS-side failure and a missed click looked
-- exactly alike from the outside. Never more than one entry, and it holds only
-- what the document already displayed.
M.last_external = nil

---Watch a system-handler process to completion without blocking Neovim.
---
---`vim.ui.open` returns as soon as the child is spawned, so a handler that
---starts and *then* fails -- `open: unable to find application`, an `xdg-open`
---with no desktop session -- reports through its exit status, which nothing
---looked at. Polling with `kill(pid, 0)` asks the kernel "does this process
---still exist" and sends no signal; only once it is gone is `wait` called, at
---which point it returns without waiting for anything.
---
---A handler still running after `timeout_ms` is the *successful* case (a
---browser that stayed in the foreground), so the watch simply stops.
local function watch_external(handle, href, timeout_ms)
  if not (handle and handle.pid) then return end
  local timer = vim.uv.new_timer()
  if not timer then return end
  local elapsed, interval = 0, 100
  timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      elapsed = elapsed + interval
      local alive = vim.uv.kill(handle.pid, 0) == 0
      if alive and elapsed < (timeout_ms or 5000) then return end
      timer:stop()
      timer:close()
      if alive then return end
      local ok, completed = pcall(handle.wait, handle, 1000)
      if not ok or type(completed) ~= "table" or completed.code == 0 then
        if M.last_external and M.last_external.href == href then M.last_external.result = "exited 0" end
        return
      end
      local detail = vim.trim(tostring(completed.stderr or ""))
      if detail == "" then detail = "exit code " .. tostring(completed.code) end
      if M.last_external and M.last_external.href == href then M.last_external.result = detail end
      vim.notify(("md-viewer: the system handler refused %s: %s"):format(href, detail), vim.log.levels.ERROR)
    end)
  )
end

---Hand `href` to the operating system's default handler for it.
---
---Every failure mode here used to be silent. `vim.ui.open` does not raise when
---there is no handler to run -- it returns `nil, <reason>` -- and it never
---waits, so a handler that fails after starting reports through its exit
---status. Both were discarded, which made an OS-level refusal indis-
---tinguishable from md-viewer never having seen the click at all.
function M.open_external(href)
  M.last_external = { href = href, at = os.date("!%Y-%m-%dT%H:%M:%SZ"), result = "spawned" }
  local ok, handle, reason = pcall(vim.ui.open, href)
  if not ok then
    M.last_external.result = "error: " .. tostring(handle)
    vim.notify("md-viewer: failed to open link: " .. tostring(handle), vim.log.levels.ERROR)
    return
  end
  if not handle then
    M.last_external.result = "no handler: " .. tostring(reason)
    vim.notify(
      ("md-viewer: no system handler available for %s (%s)"):format(href, tostring(reason)),
      vim.log.levels.ERROR
    )
    return
  end
  watch_external(handle, href, config.get().interaction.external_open_timeout_ms)
end

---Filetypes Neovim can technically load as text but that a reader clicking a
---link plainly means to *view*, not edit. Everything `vim.filetype.match`
---cannot name at all (a PNG, a zip) is already handled by the nil branch.
local os_owned_filetypes = { pdf = true }

local function should_edit_in_neovim(path)
  local filetype = vim.filetype.match({ filename = path })
  if not filetype then return false end
  return not os_owned_filetypes[filetype], filetype
end

function M.open_local_file(session, href)
  local cfg = config.get()
  local name = vim.api.nvim_buf_get_name(session.source_buf)
  local base_dir = name ~= "" and vim.fs.dirname(vim.fs.normalize(name)) or vim.uv.cwd()
  local root =
    security.document_root(session.source_buf, cfg.security.document_root, cfg.security.document_root_markers)
  local resolved, reason = security.resolve_local_link(href, base_dir, root)
  if not resolved then
    if reason == "missing" then
      vim.notify("md-viewer: link target does not exist: " .. href, vim.log.levels.WARN)
    elseif reason == "malformed" then
      vim.notify("md-viewer: could not resolve link: " .. href, vim.log.levels.WARN)
    else
      vim.notify(
        ("md-viewer: refused to open link outside the document root (%s): %s"):format(root, href),
        vim.log.levels.WARN
      )
    end
    return
  end
  local edit, filetype = should_edit_in_neovim(resolved)
  if not edit then
    -- Everything reaching here has no Neovim filetype and would be handed to
    -- the OS. For most of those that means "view it" -- a PNG in Preview, a PDF
    -- in a reader. For some it means "run it", and a link in an untrusted
    -- document must never be able to ask for that.
    if security.is_system_executable(resolved) then
      vim.notify(
        "md-viewer: refused to open an executable link via the system handler: " .. resolved,
        vim.log.levels.WARN
      )
      return
    end
    M.open_external(resolved)
    return
  end
  M.edit_in_source_window(session, resolved, filetype)
end

---Open `path` in the session's *source* window, never the preview one, and
---never by making the preview current -- focus discipline is the same as every
---other gesture's. The jump list is pushed first so `<C-o>` returns to the
---document the link was clicked in.
function M.edit_in_source_window(session, path, filetype)
  local win = session.source_win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    M.open_external(path)
    return
  end
  local ok, err = pcall(vim.api.nvim_win_call, win, function()
    vim.cmd("normal! m'")
    vim.cmd.edit(vim.fn.fnameescape(path))
  end)
  if not ok then
    vim.notify("md-viewer: failed to open link: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  -- Only Markdown is worth following with the preview; re-pointing it at a
  -- `.lua` file would render its source as prose.
  if filetype ~= "markdown" then return end
  local new_buf = vim.api.nvim_win_get_buf(win)
  if new_buf == session.source_buf then return end
  require("md-viewer.controller").retarget(session, new_buf)
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
  interact_request(session, {
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
  M.request_hit(session, point, modifiers, 1, function(result, err, meta)
    if err or not result then
      -- Reported rather than dropped. A ctrl-click whose hit test failed and a
      -- ctrl-click that landed on ordinary prose both did nothing and said
      -- nothing, so a genuinely broken activation was indistinguishable from
      -- "there was no link there". A lost race is exempt: a newer request for
      -- the same document superseded this one, which is routine.
      if err and not (meta and meta.code == "STALE_INTERACTION") then
        vim.notify("md-viewer: could not resolve that click: " .. tostring(err), vim.log.levels.WARN)
      end
      return
    end
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
    -- Prefer the point under the pointer right now, clamped to the preview
    -- window's edge if the release lands outside it (same reasoning as
    -- on_drag); fall back to the last point a drag event actually resolved
    -- only if that structurally can't be done (no placement yet).
    local release_point = M.locate_for_drag(session, mouse) or last_drag_point
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
