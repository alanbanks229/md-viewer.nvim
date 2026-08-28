local coordinates = require("md-viewer.coordinates")
local state = require("md-viewer.state")

local M = {}

function M.block_for_line(blocks, line)
  local zero = line - 1
  local best, best_index, best_span, best_pixels
  for index, block in ipairs(blocks or {}) do
    if zero >= block.sourceStart and zero < block.sourceEnd then
      local span = math.max(1, block.sourceEnd - block.sourceStart)
      local pixels = math.max(1, block.bottomPx - block.topPx)
      if not best or span < best_span or (span == best_span and pixels < best_pixels) then
        best, best_index, best_span, best_pixels = block, index, span, pixels
      end
    end
  end
  return best, best_index
end

function M.block_target(block, line)
  if not block then return 0 end
  local span = math.max(1, block.sourceEnd - block.sourceStart)
  local fraction = math.max(0, math.min(1, ((line - 1) - block.sourceStart) / span))
  return block.topPx + (block.bottomPx - block.topPx) * fraction
end

function M.scroll_for_block(block, viewport_height, document_height, anchor_ratio, line)
  if not block then return 0 end
  anchor_ratio = math.max(0.1, math.min(0.9, anchor_ratio or 0.2))
  local target = M.block_target(block, line or (block.sourceStart + 1))
  return math.max(0, math.min(math.max(0, document_height - viewport_height), target - viewport_height * anchor_ratio))
end

function M.source_anchor_ratio(win, line)
  local ok, rect = pcall(coordinates.for_window, win)
  if not ok or rect.height <= 1 then return 0.35 end
  local screen = vim.fn.screenpos(win, line, 1)
  if not screen or not screen.row or screen.row <= 0 then return 0.35 end
  local relative = (screen.row - 1 - rect.row) / math.max(1, rect.height - 1)
  return math.max(0.15, math.min(0.80, relative))
end

---Record that we have just moved `session`'s source cursor ourselves, so the
---`CursorMoved` this provokes can be recognised as our own echo and dropped.
---
---`sync_guard` cannot do this on its own, and the reason is a genuine race
---rather than an oversight. Neovim dispatches `CursorMoved` when it next
---returns to its main loop; `vim.schedule` callbacks run on that same loop, so
---a guard released by `vim.schedule` is usually released *first* and the echo
---arrives with the guard already down. The visible symptom is a click on the
---preview scrolling the preview -- the sync sees a cursor on a new block and
---re-anchors it, which reads as the preview jumping to centre whatever was
---clicked. A recorded position is not a race: the cursor either is where we put
---it or it is not.
---
---The position is read back from the window rather than taken from the caller,
---because Neovim's normal-mode clamping can land the cursor short of the column
---that was asked for.
function M.suppress_echo(session, win)
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  session.sync_echo = ok and { line = cursor[1], col = cursor[2] } or nil
end

---True while the cursor is still exactly where we last put it, i.e. while the
---events arriving are echoes of our own move.
---
---The record deliberately survives being checked, because **one cursor move
---produces more than one event**. Moving the cursor to a line that is off
---screen in the source window scrolls that window, so `CursorMoved` is followed
---by `WinScrolled`, and the controller routes both here. Consuming the record
---on the first check left the second event unguarded, which is why clicking a
---preview line that was not already visible in the editor still scrolled the
---preview.
---
---It is dropped as soon as the cursor is anywhere else, so it cannot swallow a
---move the user made -- that is the opposite failure and just as confusing.
local function is_echo(session, win)
  local echo = session.sync_echo
  if not echo then return false end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  if ok and cursor[1] == echo.line and cursor[2] == echo.col then return true end
  session.sync_echo = nil
  return false
end

function M.source_cursor(session, refresh, tolerance)
  -- Resolved rather than trusted. `session.source_win` keeps its id when a
  -- different file is opened in it, and every number below -- cursor line,
  -- screen row, window height -- would then describe that file while being
  -- looked up in this session's source map and written to this session's
  -- preview. That is the whole of the bug where scrolling SECURITY.md scrolled
  -- README.md's preview.
  local win = state.source_window(session)
  if session.sync_guard or not win then return end
  if is_echo(session, win) then
    -- Adopt the block the cursor now sits in without scrolling to it. Leaving
    -- `last_source_block` pointing at wherever the cursor used to be would make
    -- the *next* keyboard move -- even one within the block just clicked --
    -- look like a block change and scroll the preview after all.
    local _, index = M.block_for_line(session.latest_blocks, vim.api.nvim_win_get_cursor(win)[1])
    if index then session.last_source_block = index end
    return
  end
  if (session.manual_scroll_until or 0) > vim.uv.now() then return end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local block, index = M.block_for_line(session.latest_blocks, line)
  if not block or index == session.last_source_block then return end
  session.last_source_block = index
  local anchor = M.source_anchor_ratio(win, line)
  local target = M.block_target(block, line)
  local current_ratio = (target - (session.scroll_y or 0)) / math.max(1, session.viewport_height_px)
  if math.abs(current_ratio - anchor) <= (tolerance or 0.10) then return end
  session.scroll_y = M.scroll_for_block(block, session.viewport_height_px, session.document_height_px, anchor, line)
  session.progress_basis = "viewport"
  refresh(session)
end

function M.update_source_from_scroll(session, scroll)
  local nearest
  for _, block in ipairs(session.latest_blocks) do
    if block.topPx <= scroll + session.viewport_height_px * 0.25 then
      nearest = block
    else
      break
    end
  end
  -- Same resolution as source_cursor, for the mirror failure: the window may
  -- since have been given a different buffer, and this puts *this* document's
  -- line number -- clamped against *this* document's length -- into it, moving
  -- the reader's cursor in a file the preview has nothing to do with.
  local win = state.source_window(session)
  if nearest and win then
    session.sync_guard = true
    local line_count = vim.api.nvim_buf_line_count(session.source_buf)
    pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, math.min(line_count, nearest.sourceStart + 1)), 0 })
    -- Same feedback loop as the click path, and the same fix: the CursorMoved
    -- this provokes arrives after `sync_guard` has already been released.
    M.suppress_echo(session, win)
    vim.schedule(function() session.sync_guard = false end)
  end
end

return M
