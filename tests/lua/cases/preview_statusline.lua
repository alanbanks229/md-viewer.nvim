---The graphical preview owns neither a real text buffer nor the user's
---statusline. Its full-document visual-line geometry supplies both the
---line-number overlay and the progress component a statusline integration may
---choose to render.
return function(t)
  local config = require("md-viewer.config")
  local coordinates = require("md-viewer.coordinates")
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
  vim.api.nvim_set_current_win(session.preview_win)

  local number_ns = vim.api.nvim_create_namespace("md-viewer_line_numbers")
  local function numbers()
    return vim.api.nvim_buf_get_extmarks(session.preview_buf, number_ns, 0, -1, { details = true })
  end
  local function labels()
    local result = {}
    for _, mark in ipairs(numbers()) do
      result[mark[2]] = mark[4].virt_text[1][1]
    end
    return result
  end

  session.document_height_px = 1200
  session.viewport_height_px = 600
  session.viewport_height_render_px = 600
  session.viewport_width_px = 800
  session.applied_scroll_y = 0
  session.latest_lines = {
    { topPx = 20, bottomPx = 60 },
    { topPx = 120, bottomPx = 160 },
    { topPx = 220, bottomPx = 260 },
    { topPx = 320, bottomPx = 360 },
    { topPx = 420, bottomPx = 460 },
    { topPx = 520, bottomPx = 560 },
    { topPx = 620, bottomPx = 660 },
    { topPx = 720, bottomPx = 760 },
    { topPx = 820, bottomPx = 860 },
    { topPx = 1020, bottomPx = 1060 },
  }

  preview.update_line_numbers(session)
  t.eq(0, #numbers(), "line numbers default to off")

  vim.cmd("MdViewerToggleAbsoluteLineNumbers")
  t.eq("absolute", config.get().preview.line_numbers, "the absolute command enables absolute numbering")
  t.ok(#numbers() > 0, "enabling a mode redraws the open preview immediately")
  vim.cmd("MdViewerToggleRelativeLineNumbers")
  t.eq("relative", config.get().preview.line_numbers, "the relative command switches directly from absolute")
  vim.cmd("MdViewerToggleAbsoluteLineNumbers")
  t.eq("absolute", config.get().preview.line_numbers, "the absolute command switches directly from relative")
  vim.cmd("MdViewerToggleAbsoluteLineNumbers")
  t.eq("off", config.get().preview.line_numbers, "repeating the visible absolute mode turns numbering off")
  vim.cmd("MdViewerToggleRelativeLineNumbers")
  t.eq("relative", config.get().preview.line_numbers, "relative numbering can be enabled directly from off")
  vim.cmd("MdViewerToggleRelativeLineNumbers")
  t.eq("off", config.get().preview.line_numbers, "repeating the visible relative mode turns numbering off")

  local placement = preview.placement(session.preview_win, session.backend.name)
  session.last_placement = placement
  local cell_height = session.viewport_height_render_px / placement.height
  session.latest_lines = { { topPx = 1, bottomPx = cell_height * 2 + 1 } }
  config.get().preview.line_numbers = "absolute"
  preview.update_line_numbers(session)
  local expected_row = coordinates.css_to_cell(
    { x = 0, y = (session.latest_lines[1].topPx + session.latest_lines[1].bottomPx) / 2 },
    placement,
    { widthPx = 800, heightPx = 600 }
  )
  t.eq(expected_row - 1, numbers()[1][2], "a number aligns to the rendered line box's centre")

  session.latest_lines = {
    { topPx = 1, bottomPx = 3 },
    { topPx = cell_height * 0.45, bottomPx = cell_height * 0.55 },
  }
  preview.update_line_numbers(session)
  t.eq(1, #numbers(), "two browser lines mapped to one terminal row produce one readable number")
  t.eq("2", numbers()[1][4].virt_text[1][1], "a row collision keeps the line nearest the cell centre")

  session.latest_lines = {
    { topPx = 20, bottomPx = 40 },
    { topPx = 100, bottomPx = 120 },
    { topPx = 180, bottomPx = 200 },
  }
  session.caret_scroll_y = 0
  session.caret_rect = { x = 20, y = 100, width = 8, height = 20 }
  config.get().preview.line_numbers = "relative"
  preview.update_line_numbers(session)
  local relative_labels = labels()
  local ordered = {}
  for row, value in pairs(relative_labels) do
    ordered[#ordered + 1] = { row, value }
  end
  table.sort(ordered, function(a, b) return a[1] < b[1] end)
  t.eq("1", ordered[1][2], "the line above the caret shows distance one")
  t.eq("2", ordered[2][2], "the caret line keeps its absolute line number")
  t.eq("1", ordered[3][2], "the line below the caret shows distance one")

  session.caret_rect = nil
  preview.update_line_numbers(session)
  ordered = {}
  for row, value in pairs(labels()) do
    ordered[#ordered + 1] = { row, value }
  end
  table.sort(ordered, function(a, b) return a[1] < b[1] end)
  t.eq("1", ordered[1][2], "relative mode falls back to absolute labels before a caret exists")
  t.eq("2", ordered[2][2], "the no-caret fallback remains sequential")

  session.backend = { name = "cells" }
  config.get().preview.line_numbers = "relative"
  preview.update_line_numbers(session)
  t.eq(true, vim.wo[session.preview_win].number, "cells relative mode enables the number column")
  t.eq(true, vim.wo[session.preview_win].relativenumber, "cells relative mode uses native relative numbers")
  config.get().preview.line_numbers = "off"
  preview.update_line_numbers(session)
  t.eq(false, vim.wo[session.preview_win].number, "cells off mode clears the number column")
  t.eq(false, vim.wo[session.preview_win].relativenumber, "cells off mode clears relative numbers")

  session.backend = { name = "kitty_raw" }
  session.last_placement = placement
  session.latest_lines = {}
  for index = 1, 10 do
    session.latest_lines[index] = { topPx = (index - 1) * 110, bottomPx = (index - 1) * 110 + 20 }
  end
  session.progress_basis = "viewport"
  session.applied_scroll_y = 0
  t.eq("Top", preview.statusline_progress(session.preview_buf), "a viewport at the document start reads Top")
  session.applied_scroll_y = 300
  t.eq("60%", preview.statusline_progress(session.preview_buf), "scroll-only progress follows the viewport midpoint")
  t.eq("60%", require("md-viewer").statusline_progress(), "the public API reads the current preview buffer")
  session.applied_scroll_y = 600
  t.eq("Bot", preview.statusline_progress(session.preview_buf), "a viewport at maximum scroll reads Bot")

  session.progress_basis = "caret"
  session.caret_scroll_y = 0
  session.caret_rect = { x = 10, y = 440, width = 8, height = 20 }
  t.eq("50%", preview.statusline_progress(session.preview_buf), "caret progress uses the caret's document visual line")
  session.caret_rect = { x = 10, y = 0, width = 8, height = 20 }
  t.eq("Top", preview.statusline_progress(session.preview_buf), "the first caret line reads Top")
  session.caret_rect = { x = 10, y = 990, width = 8, height = 20 }
  t.eq("Bot", preview.statusline_progress(session.preview_buf), "the last caret line reads Bot")

  local original_statusline = vim.wo[session.preview_win].statusline
  local events = 0
  local event_group = vim.api.nvim_create_augroup("md-viewer-test-progress", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = event_group,
    pattern = "MdViewerProgressChanged",
    callback = function(event)
      events = events + 1
      t.eq(session.preview_buf, event.data.buf, "the progress event identifies its preview buffer")
      t.eq(session.preview_win, event.data.win, "the progress event identifies its preview window")
      t.eq("Bot", event.data.progress, "the progress event carries the raw statusline label")
    end,
  })
  session.last_progress_text = nil
  preview.update_progress(session)
  preview.update_progress(session)
  t.eq(1, events, "an unchanged label emits no duplicate progress event")
  t.eq(original_statusline, vim.wo[session.preview_win].statusline, "progress updates never replace the statusline")
  vim.api.nvim_del_augroup_by_id(event_group)

  session.backend = { name = "cells" }
  t.eq(
    nil,
    preview.statusline_progress(session.preview_buf),
    "cells previews defer to the statusline's native progress"
  )
  local other = vim.api.nvim_create_buf(false, true)
  t.eq(nil, preview.statusline_progress(other), "non-preview buffers receive no md-viewer progress override")
  vim.api.nvim_buf_delete(other, { force = true })

  controller.close(source)
  config.reset()
end
