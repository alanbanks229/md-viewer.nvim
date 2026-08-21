local coordinates = require("md-viewer.coordinates")
local preview = require("md-viewer.preview")

---The preview's caret.
---
---A caret here is a **position in the rendered document**, and what it reports
---is the box of the glyph it sits on. That is the whole design, and it is what
---the first attempt got wrong: a caret that was a free terminal cell could sit
---in the page margin or in the blank space beside a short heading, addressing
---nothing, and was drawn at a fixed cell size that had no relationship to the
---text under it.
---
---So: the renderer owns where the caret may be (`caret_move`, which only ever
---lands on a real character), and the caret is *drawn* from the glyph box it
---reports, through the same overlay path the selection highlight uses. Neovim's own
---cursor is hidden while that is on screen and follows along underneath as a
---shadow, purely so window-level things -- which window is focused, what a
---mapping applies to -- keep working.
---
---The box is stored with the scroll position it was measured at, so an
---ordinary scroll can re-place it locally, with no round trip: subtract the
---scroll that has happened since. A caret scrolled out of the viewport is
---simply not drawn.
---
---The box is how the caret is *drawn*; it is not what the caret *is*. That is
---the index the renderer reports alongside it, and sending that index back with
---the next motion is what keeps the two in step. Asking the renderer to find the
---caret again from the box -- hit-testing the glyph's own centre -- cannot work:
---a point resolves to the nearest boundary *between* characters, and the middle
---of a glyph is equidistant from the boundaries either side of it. Half the
---glyphs answered one character to the right, which is exactly what made `h`
---step back onto the glyph it started on and stay there.
local M = {}

---Where the caret is, as a point the `interact` transport can resolve: the
---centre of its glyph, in viewport CSS pixels at the *current* scroll.
---Returns nil when there is no caret yet, or when it has scrolled out of view.
function M.point(session)
  local rect = M.rect(session)
  if not rect then return nil end
  return { x = rect.x + rect.width / 2, y = rect.y + rect.height / 2 }
end

---The caret's glyph box in viewport CSS pixels at the current scroll, or nil
---when there is no caret or it is off screen.
function M.rect(session)
  local rect = session and session.caret_rect
  if not rect then return nil end
  local drift = (session.applied_scroll_y or 0) - (session.caret_scroll_y or 0)
  local y = rect.y - drift
  local height = session.viewport_height_render_px or 0
  if height > 0 and (y + rect.height <= 0 or y >= height) then return nil end
  return { x = rect.x, y = y, width = rect.width, height = rect.height }
end

---Record where the renderer says the caret now is. `rect` is viewport-relative
---at `scroll_y`, which is the scroll the renderer resolved it against, and
---`index` is which character that is in the renderer's character space (see
---`M.index`). A caller with no index -- one placing the caret at a coordinate
---rather than reading back a motion -- passes none, and the next motion resolves
---from the point instead.
function M.set_rect(session, rect, scroll_y, index)
  if not (session and type(rect) == "table" and rect.width and rect.height) then return end
  session.caret_rect = { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
  session.caret_scroll_y = scroll_y or session.applied_scroll_y or 0
  session.caret_index = type(index) == "number" and index or nil
  session.caret_index_revision = session.caret_index and session.renderer_revision or nil
  M.shadow_cursor(session)
end

---Which character the caret is on, to send with the next motion so the renderer
---resumes from the caret itself rather than hit-testing its glyph again.
---
---Only for the content it was measured against. The renderer builds that
---character space from the DOM per request, so a re-render renumbers it, and an
---index from the document before it names a different character -- or none.
---Nil here means "resolve from the point", which is what a click does anyway.
function M.index(session)
  if not (session and session.caret_index) then return nil end
  if session.caret_index_revision ~= session.renderer_revision then return nil end
  return session.caret_index
end

function M.forget(session)
  if not session then return end
  session.caret_rect = nil
  session.caret_scroll_y = nil
  session.caret_desired_x = nil
  session.caret_index = nil
  session.caret_index_revision = nil
end

---Park Neovim's own cursor on the cell the caret's glyph falls in.
---
---Not what the reader sees -- that is the overlay rectangle -- but it keeps the
---preview window's cursor somewhere meaningful rather than pinned at the top
---left, which matters for the terminals that cannot draw the overlay and are
---left showing the real cursor, and for anything that reads the window's cursor
---position.
function M.shadow_cursor(session)
  local win = session and session.preview_win
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  if vim.api.nvim_win_get_buf(win) ~= session.preview_buf then return end
  local rect = M.rect(session)
  if not rect then return end
  local placement = session.last_placement
  if not placement then return end
  local rows, columns = preview.surface_size(session)
  if not rows then return end
  -- The glyph's middle, not its top-left corner: a heading's box spans two or
  -- three terminal rows, and the corner would put the shadow a row above the
  -- character the caret is actually on.
  local row, column = coordinates.css_to_cell(
    {
      x = rect.x + rect.width / 2,
      y = rect.y + rect.height / 2,
    },
    placement,
    {
      widthPx = session.viewport_width_px,
      heightPx = session.viewport_height_render_px,
    }
  )
  if not row then return end
  pcall(vim.api.nvim_win_set_cursor, win, {
    math.max(1, math.min(rows, row)),
    math.max(0, math.min(columns - 1, column - 1)),
  })
end

---The point a motion should start from. The caret's own glyph centre when there
---is one; otherwise the top-left cell of the image, which `caret_move`'s
---`"none"` granularity will snap onto the document's first character.
function M.origin(session)
  local point = M.point(session)
  if point then return point end
  local placement = session and session.last_placement
  if not placement then return nil end
  return coordinates.cell_to_css(
    { screenrow = placement.row + 1, screencol = placement.col + 1 },
    placement,
    { widthPx = session.viewport_width_px, heightPx = session.viewport_height_render_px }
  )
end

return M
