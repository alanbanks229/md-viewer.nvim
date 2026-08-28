---The preview window's statusline shows how far down the *document* the
---caret sits, mirroring the source buffer's own ruler (cursor line / file
---length) rather than Neovim's own %P here -- which is computed from
---cursor_line/buffer_line_count, both scoped to one screenful of the preview
---window (see preview.lua's surface_size and caret.shadow_cursor) rather
---than the whole rendered document or the caret's real position in it.
---
---Reported live: `5j` from the top of a document landed the caret on the
---5th rendered *line*, but the block-number overlay (one mark per
---paragraph/heading) only reached "2" by that point, and scrolling the
---viewport did not move the ruler at all -- because it read scroll position,
---and local-mode scrolling bypasses the render-completion path that used to
---be the ruler's only trigger. Both are fixed by keying the ruler and the
---marker overlay off the caret's own document position (session.caret_rect
---+ session.caret_scroll_y) and a dense per-rendered-line geometry
---(session.latest_lines) instead of scroll position and per-block geometry.
return function(t)
  local config = require("md-viewer.config")
  local preview = require("md-viewer.preview")

  config.reset()
  require("md-viewer").setup({ image = { backend = "cells" } })
  local controller = require("md-viewer.controller")

  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# One", "", "body" })
  local session = assert(controller.open("right"))
  session.backend = { name = "kitty_raw" }
  preview.reset_surface(session)

  local function statusline() return vim.wo[session.preview_win].statusline end
  local marker_ns = vim.api.nvim_create_namespace("md-viewer_line_markers")
  local function markers() return vim.api.nvim_buf_get_extmarks(session.preview_buf, marker_ns, 0, -1, {}) end

  -- A document that does not fill the viewport has nothing to scroll, and no
  -- caret position could be anything but the whole of it.
  session.document_height_px = 400
  session.viewport_height_px = 600
  preview.update_statusline(session)
  t.ok(statusline():find("All", 1, true), "a document shorter than the viewport reads All, not a percentage")

  session.document_height_px = 10000
  session.viewport_height_px = 600

  -- No caret placed yet: falls back to the scroll position, the only
  -- position known.
  session.applied_scroll_y = 0
  preview.update_statusline(session)
  t.ok(statusline():find("Top", 1, true), "before any caret is placed, the fallback to scroll position reads Top")

  -- The caret's absolute document position is caret_scroll_y + caret_rect.y,
  -- not the viewport's scroll position: 700px into a 10000px-tall document
  -- is 7% through the whole thing, regardless of where that puts the caret
  -- within whatever screenful is currently on glass.
  session.caret_scroll_y = 0
  session.caret_rect = { x = 10, y = 700, width = 8, height = 20 }
  preview.update_statusline(session)
  t.ok(statusline():find("7%", 1, true), "the ruler reads the caret's own document position")
  t.ok(not statusline():find("70%", 1, true), "700px of a 10000px document is 7%, not 70%")

  session.caret_rect = { x = 10, y = 0, width = 8, height = 20 }
  preview.update_statusline(session)
  t.ok(statusline():find("Top", 1, true), "a caret at the very start of the document reads Top")

  session.caret_scroll_y = 9400
  session.caret_rect = { x = 10, y = 599, width = 8, height = 20 }
  preview.update_statusline(session)
  t.ok(statusline():find("Bot", 1, true), "a caret at the very end of the document reads Bot")

  -- Scrolling the viewport alone, with the caret left where it was, must not
  -- move the ruler: a scroll-based ruler is exactly what read wrong (and,
  -- in local mode, never updated at all -- see the module doc above), and
  -- the caret's own position is the one thing this reports now.
  session.caret_scroll_y = 0
  session.caret_rect = { x = 10, y = 100, width = 8, height = 20 }
  session.applied_scroll_y = 5000
  preview.update_statusline(session)
  t.ok(statusline():find("1%", 1, true), "scrolling alone does not change the ruler; the caret's position still does")

  -- Line markers: dense, one per rendered *line* -- not one per content
  -- block -- so a count motion and the marker numbering agree.
  session.viewport_height_render_px = 600
  session.latest_lines = {
    { topPx = 0, bottomPx = 20 },
    { topPx = 25, bottomPx = 45 },
    { topPx = 50, bottomPx = 70 },
    { topPx = 5000, bottomPx = 5020 }, -- off screen at this scroll
  }
  session.applied_scroll_y = 0

  preview.update_line_markers(session)
  t.eq(0, #markers(), "line markers stay off until preview.line_markers is enabled")

  config.get().preview.line_markers = true
  preview.update_line_markers(session)
  t.eq(3, #markers(), "only the lines visible in the current viewport get a marker")

  config.get().preview.line_markers = false
  preview.update_line_markers(session)
  t.eq(0, #markers(), "disabling the flag clears any markers already drawn")

  -- MdViewerToggleLineMarkers flips the flag and redraws every open session.
  t.eq(false, config.get().preview.line_markers, "line markers start disabled")
  vim.cmd("MdViewerToggleLineMarkers")
  t.eq(true, config.get().preview.line_markers, "the toggle command flips the config flag")
  t.eq(3, #markers(), "toggling on redraws markers for the open session immediately")
  vim.cmd("MdViewerToggleLineMarkers")
  t.eq(false, config.get().preview.line_markers, "a second toggle flips it back off")

  -- The `cells` backend holds the real document as real text, so Neovim's
  -- own ruler is already correct there and must not be overridden.
  session.backend = { name = "cells" }
  vim.wo[session.preview_win].statusline = "sentinel"
  preview.update_statusline(session)
  t.eq("sentinel", statusline(), "the cells backend keeps Neovim's own statusline untouched")

  controller.close(source)
  config.reset()
end
