local coordinates = require("md-viewer.coordinates")

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
  return math.max(0, math.min(math.max(0, document_height - viewport_height),
    target - viewport_height * anchor_ratio))
end

function M.source_anchor_ratio(session, line)
  local ok, rect = pcall(coordinates.for_window, session.source_win)
  if not ok or rect.height <= 1 then return 0.35 end
  local screen = vim.fn.screenpos(session.source_win, line, 1)
  if not screen or not screen.row or screen.row <= 0 then return 0.35 end
  local relative = (screen.row - 1 - rect.row) / math.max(1, rect.height - 1)
  return math.max(0.15, math.min(0.80, relative))
end

function M.source_cursor(session, refresh, tolerance)
  if session.sync_guard or not vim.api.nvim_win_is_valid(session.source_win) then return end
  if (session.manual_scroll_until or 0) > vim.uv.now() then return end
  local line = vim.api.nvim_win_get_cursor(session.source_win)[1]
  local block, index = M.block_for_line(session.latest_blocks, line)
  if not block or index == session.last_source_block then return end
  session.last_source_block = index
  local anchor = M.source_anchor_ratio(session, line)
  local target = M.block_target(block, line)
  local current_ratio = (target - (session.scroll_y or 0)) / math.max(1, session.viewport_height_px)
  if math.abs(current_ratio - anchor) <= (tolerance or 0.10) then return end
  session.scroll_y = M.scroll_for_block(block, session.viewport_height_px,
    session.document_height_px, anchor, line)
  refresh(session)
end

function M.update_source_from_scroll(session, scroll)
  local nearest
  for _, block in ipairs(session.latest_blocks) do
    if block.topPx <= scroll + session.viewport_height_px * 0.25 then nearest = block else break end
  end
  if nearest and vim.api.nvim_win_is_valid(session.source_win) then
    session.sync_guard = true
    local line_count = vim.api.nvim_buf_line_count(session.source_buf)
    pcall(vim.api.nvim_win_set_cursor, session.source_win,
      { math.max(1, math.min(line_count, nearest.sourceStart + 1)), 0 })
    vim.schedule(function() session.sync_guard = false end)
  end
end

return M
