local config = require("md-viewer.config")
local coordinates = require("md-viewer.coordinates")
local process = require("md-viewer.process")
local security = require("md-viewer.security")
local sync = require("md-viewer.sync")

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

---Drop all interaction state for `session`. Called on session teardown
---(close, buffer wipeout, exit) and on events that hide the preview without
---destroying it (tab leave, suspend), so a stale press can never survive
---past the gesture that started it.
function M.forget(session)
  if captured == session then captured = nil end
  if session then session.pointer = nil end
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
  session.pointer = {
    pressed = true,
    press_cell = screen_cell(mouse),
    latest_cell = screen_cell(mouse),
    press_time = vim.uv.now(),
    drag_started = false,
    interaction_serial = ((session.pointer or {}).interaction_serial or 0) + 1,
    selection_request_in_flight = false,
    newest_pending_drag_point = nil,
    content_revision = session.renderer_revision,
    cached_selected_text = nil,
    click_count = click_count or 1,
  }
  captured = session
end

function M.on_drag(session, mouse)
  local pointer = session.pointer
  if not (pointer and pointer.pressed) then return end
  pointer.latest_cell = screen_cell(mouse)
  local distance = cell_distance(pointer.press_cell, pointer.latest_cell)
  if distance >= config.get().interaction.drag_threshold_cells then
    pointer.drag_started = true
    -- Part 6 creates the selection from this point; Part 4 only tracks it so
    -- Part 6's wiring is purely additive.
    pointer.newest_pending_drag_point = M.locate(session, mouse)
  end
end

---Move the source cursor to `position` (a hit-test source position: `line`,
---`byteColumn`, `precision`), clamped to the buffer and to a valid UTF-8
---byte boundary, going through the same sync-guard technique
---`sync.update_source_from_scroll` uses so this cannot feed back into a
---preview scroll.
---
---`byteColumn` is the renderer's own wire field, which is what
---`result.sourcePosition` actually carries. `byte_column` is accepted as an
---alias: Part 4 read only the snake_case name, and because every column the
---renderer produced back then was 0 the mismatch was invisible -- the cursor
---landed at column 0, which was also the correct answer. Part 5 is the first
---part that sends a column worth getting wrong.
function M.move_source_cursor(session, position)
  -- Typed, not merely non-nil. A click on empty space resolves to precision
  -- "none" and the renderer honestly sends `line: null` -- which arrives as a
  -- number only if protocol.lua decoded it as absent. Checking the type here
  -- too means this function cannot be made to crash by a position it should
  -- simply decline to act on, whatever the transport did.
  if type(position) ~= "table" or type(position.line) ~= "number" then return end
  local win = session.source_win
  if type(win) ~= "number" or not vim.api.nvim_win_is_valid(win) then return end
  local buf = session.source_buf
  local line_count = vim.api.nvim_buf_line_count(buf)
  local line = math.max(1, math.min(line_count, math.floor(position.line)))
  local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
  local requested = position.byteColumn
  if type(requested) ~= "number" then requested = position.byte_column end
  if type(requested) ~= "number" then requested = 0 end
  local byte_col = math.max(0, math.min(math.floor(requested), #text))
  while byte_col > 0 and byte_col < #text do
    local byte = text:byte(byte_col + 1)
    if not (byte and (byte & 0xC0) == 0x80) then break end
    byte_col = byte_col - 1
  end

  session.sync_guard = true
  if config.get().interaction.focus_source_on_click then pcall(vim.api.nvim_set_current_win, win) end
  pcall(vim.api.nvim_win_set_cursor, win, { line, byte_col })
  -- Neovim's own normal-mode clamping can land the cursor short of the column
  -- we asked for, so the echo is recorded from where the cursor actually is.
  -- Recording the requested position instead would fail to match and the
  -- preview would scroll itself to re-anchor the line the user just clicked.
  sync.suppress_echo(session, win)
  vim.schedule(function() session.sync_guard = false end)
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
---`activate_at`: it reports a link when the point is over one and falls back
---to source semantics otherwise, so a plain click on a link still navigates
---to source without a second round trip.
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

function M.click(session, point, click_count)
  if not config.get().interaction.click_to_source then return end
  M.request_hit(session, point, {}, click_count, function(result, err)
    if err or not result then return end
    record_result(session, result)
    M.move_source_cursor(session, result.sourcePosition)
  end)
end

function M.activate(session, point, modifiers)
  if not config.get().interaction.links then
    M.click(session, point)
    return
  end
  M.request_hit(session, point, modifiers, 1, function(result, err)
    if err or not result then return end
    record_result(session, result)
    if result.kind == "link" and result.link then
      M.activate_link(session, result)
    else
      M.move_source_cursor(session, result.sourcePosition)
    end
  end)
end

function M.on_release(session, mouse)
  local pointer = session.pointer
  if not (pointer and pointer.pressed) then return end
  pointer.latest_cell = screen_cell(mouse)
  local distance = cell_distance(pointer.press_cell, pointer.latest_cell)
  local is_drag = pointer.drag_started or distance >= config.get().interaction.drag_threshold_cells
  local click_count = pointer.click_count
  pointer.pressed = false
  pointer.drag_started = false
  pointer.newest_pending_drag_point = nil
  if captured == session then captured = nil end
  if is_drag then return end -- Part 6 creates the selection; Part 4 tracks state only.
  local point = M.locate(session, mouse)
  if not point then return end -- released outside resolvable content; nothing to click.
  M.click(session, point, click_count)
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
