---The preview window's statusline shows how far down the *document* the
---reader has scrolled, not Neovim's own %P -- which is computed from
---cursor_line/buffer_line_count, both scoped to one screenful of the preview
---window (see preview.lua's surface_size and caret.shadow_cursor) rather than
---the whole rendered document. Left alone, that produced exactly the
---disorientation reported: 7% in the source buffer read as 96% in the
---preview, then BOT, then 74%, purely from scrolling within one screenful.
---
---This also covers the block-number overlay (`preview.line_markers`), which
---shares the same applied_scroll_y/viewport_height_render_px inputs and the
---same call sites.
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

  -- A document that does not fill the viewport has nothing to scroll.
  session.document_height_px = 400
  session.viewport_height_px = 600
  session.applied_scroll_y = 0
  preview.update_statusline(session)
  t.ok(statusline():find("All", 1, true), "a document shorter than the viewport reads All, not a percentage")

  session.document_height_px = 10000
  session.viewport_height_px = 600

  session.applied_scroll_y = 0
  preview.update_statusline(session)
  t.ok(statusline():find("Top", 1, true), "scrolled to the very start reads Top")

  session.applied_scroll_y = 9400
  preview.update_statusline(session)
  t.ok(statusline():find("Bot", 1, true), "scrolled to the very end reads Bot")

  -- The bug: a caret sitting near the bottom of the *current screenful*, deep
  -- inside a long document, is nowhere near the bottom of the *document*.
  -- 700px into a 10000px-tall document with a 600px viewport is ~7% through
  -- the whole document, even though that position is most of the way down
  -- the first screenful.
  session.applied_scroll_y = 700
  preview.update_statusline(session)
  t.ok(statusline():find("7%", 1, true), "a small scroll offset into a long document reads a small percentage")
  t.ok(not statusline():find("96%", 1, true), "the document-wide percentage is not confused with the on-screen one")

  -- Line markers: off by default, on only once the config flag is enabled.
  session.viewport_height_render_px = 600
  session.latest_blocks = {
    { sourceStart = 0, sourceEnd = 1, topPx = 0, bottomPx = 40 },
    { sourceStart = 1, sourceEnd = 2, topPx = 300, bottomPx = 340 },
    { sourceStart = 2, sourceEnd = 3, topPx = 5000, bottomPx = 5040 }, -- off screen at this scroll
  }
  session.applied_scroll_y = 0

  preview.update_line_markers(session)
  t.eq(0, #markers(), "line markers stay off until preview.line_markers is enabled")

  config.get().preview.line_markers = true
  preview.update_line_markers(session)
  t.eq(2, #markers(), "only the blocks visible in the current viewport get a marker")

  config.get().preview.line_markers = false
  preview.update_line_markers(session)
  t.eq(0, #markers(), "disabling the flag clears any markers already drawn")

  -- MdViewerToggleLineMarkers flips the flag and redraws every open session.
  t.eq(false, config.get().preview.line_markers, "line markers start disabled")
  vim.cmd("MdViewerToggleLineMarkers")
  t.eq(true, config.get().preview.line_markers, "the toggle command flips the config flag")
  t.eq(2, #markers(), "toggling on redraws markers for the open session immediately")
  vim.cmd("MdViewerToggleLineMarkers")
  t.eq(false, config.get().preview.line_markers, "a second toggle flips it back off")

  controller.close(source)
  config.reset()
end
