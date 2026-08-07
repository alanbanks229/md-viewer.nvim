return function(t)
  local config = require("md-viewer.config")
  local coords = require("md-viewer.coordinates")
  local preview = require("md-viewer.preview")
  local state = require("md-viewer.state")
  local mouse = require("md-viewer.mouse")

  require("md-viewer").setup({ image = { backend = "cells" } })
  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# One", "", "body" })
  local controller = require("md-viewer.controller")
  local session = assert(controller.open("right"))
  t.ok(vim.api.nvim_win_is_valid(session.preview_win), "preview opens in a real split")
  t.eq("nofile", vim.bo[session.preview_buf].buftype, "preview scratch buffer")
  t.eq(false, vim.bo[session.preview_buf].modifiable, "preview is read-only")
  local winbar = vim.api.nvim_get_option_value("winbar", { win = session.preview_win })
  t.ok(winbar:match("No Name"), "preview winbar names its source document")
  local placement = coords.for_window(session.preview_win)
  t.eq(vim.api.nvim_win_get_width(session.preview_win), placement.width, "real split coordinate width")
  t.eq(vim.api.nvim_win_get_height(session.preview_win), placement.height, "real split coordinate height")
  t.eq(true, placement.winbar, "image placement accounts for preview winbar")
  t.ok(placement.row > placement.window_row, "image starts below preview winbar")

  local raw_placement = preview.placement(session.preview_win, "kitty_raw")
  t.eq(placement.height - 1, raw_placement.height, "raw placement keeps one row above the statusline")
  t.eq(1, raw_placement.statusline_guard_cells, "raw placement reports its dynamic statusline guard")
  preview.start_loading(session)
  t.eq(true, session.loading, "startup indicator is active before the first graphical frame")
  t.ok(vim.api.nvim_win_is_valid(session.loading_win), "startup indicator uses a real floating window")
  local loading_config = vim.api.nvim_win_get_config(session.loading_win)
  t.eq("win", loading_config.relative, "startup indicator is local to the preview split")
  t.eq(false, loading_config.focusable, "startup indicator cannot steal focus")
  local first_loading_line = vim.api.nvim_buf_get_lines(session.loading_buf, 0, 1, false)[1]
  t.ok(first_loading_line:match("Rendering Markdown"), "startup indicator explains renderer activity")
  vim.wait(300, function()
    local line = vim.api.nvim_buf_get_lines(session.loading_buf, 0, 1, false)[1]
    return line ~= first_loading_line
  end)
  local next_loading_line = vim.api.nvim_buf_get_lines(session.loading_buf, 0, 1, false)[1]
  t.ok(next_loading_line ~= first_loading_line, "startup indicator animates")
  preview.stop_loading(session)
  t.eq(false, session.loading, "startup indicator stops before image display")
  t.eq(nil, session.loading_win, "startup indicator window is cleaned up")
  local original_backend = session.backend
  local cleared_images, restored_images = 0, 0
  session.backend = {
    name = "kitty_raw",
    clear = function()
      cleared_images = cleared_images + 1
      return true
    end,
    show = function(bytes)
      t.eq("cached-png", bytes, "float restoration reuses the cached PNG")
      restored_images = restored_images + 1
      return 88
    end,
    move = function(image_id) return image_id end,
  }
  session.image_id = 77
  session.last_image_bytes = "cached-png"
  local float_buf = vim.api.nvim_create_buf(false, true)
  local float_win = vim.api.nvim_open_win(float_buf, false, {
    relative = "editor",
    row = placement.row,
    col = placement.col,
    width = math.min(10, placement.width),
    height = math.min(3, placement.height),
    style = "minimal",
  })
  local occluded, occluding_windows = preview.occlusion(session.preview_win)
  t.eq(true, occluded, "overlapping floating UI occludes the graphical preview")
  t.eq(float_win, occluding_windows[1], "occlusion reports the actual floating window")
  vim.wait(100, function() return session.image_id == nil end)
  t.eq(1, cleared_images, "opening an overlapping float clears the raw placement")
  vim.api.nvim_win_close(float_win, true)
  t.eq(false, select(1, preview.occlusion(session.preview_win)), "closing a float removes occlusion")
  vim.wait(100, function() return session.image_id == 88 end)
  t.eq(1, restored_images, "closing the float restores the cached raw placement")

  local passive_buf = vim.api.nvim_create_buf(false, true)
  local passive_win = vim.api.nvim_open_win(passive_buf, false, {
    relative = "editor",
    row = placement.row,
    col = placement.col,
    width = math.min(10, placement.width),
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
  })
  t.eq(false, select(1, preview.occlusion(session.preview_win)), "non-focusable notifications do not blank the preview")
  local passive_placement = preview.placement(session.preview_win, "kitty_raw")
  t.ok(#passive_placement.exclusions > 0, "non-focusable notification creates a raw-image cutout")
  local passive_rect = passive_placement.exclusions[1]
  t.eq(
    math.min(10, placement.width) + 2 + config.get().image.raw_overlay_bleed_cells,
    passive_rect.width,
    "notification cutout includes both border columns plus the trailing bleed"
  )
  t.eq(placement.col, passive_rect.col, "the bleed never moves the cutout's leading edge")
  vim.api.nvim_win_close(passive_win, true)

  -- Regression: a passive (non-focusable) float appearing or disappearing must
  -- re-place the image, even though its row/col/width/height never change.
  -- raw_zindex is -1 for every terminal profile (terminal.lua), and a negative
  -- z above INT32_MIN/2 draws the image below text glyphs but *above* cell
  -- background colors -- so a notification does not occlude the image on its
  -- own, and without the cutout actually reaching the terminal the Markdown
  -- composites straight through the notification's background. The exclusion
  -- must also stay tracked on last_placement, since interaction.locate's
  -- click-resolution depends on it.
  local move_calls, moved_exclusions = 0, nil
  session.backend.move = function(image_id, moved_placement)
    move_calls = move_calls + 1
    moved_exclusions = #(moved_placement.exclusions or {})
    return image_id
  end
  t.eq(0, #(session.last_placement.exclusions or {}), "sanity: no exclusion before the notification opens")
  local notify_buf = vim.api.nvim_create_buf(false, true)
  local notify_win = vim.api.nvim_open_win(notify_buf, false, {
    relative = "editor",
    row = placement.row,
    col = placement.col,
    width = math.min(10, placement.width),
    height = 1,
    style = "minimal",
    focusable = false,
  })
  vim.wait(300, function() return #(session.last_placement.exclusions or {}) > 0 end, 10)
  t.ok(#(session.last_placement.exclusions or {}) > 0, "the exclusion is tracked for click-resolution")
  t.ok(move_calls > 0, "a passive float's exclusion change re-crops the image")
  t.eq(1, moved_exclusions, "the re-crop carries the notification's cutout to the backend")
  move_calls, moved_exclusions = 0, nil
  vim.api.nvim_win_close(notify_win, true)
  vim.wait(300, function() return #(session.last_placement.exclusions or {}) == 0 end, 10)
  t.eq(0, #(session.last_placement.exclusions or {}), "the exclusion is removed once the float closes")
  t.ok(move_calls > 0, "closing the passive float restores the uncropped image")
  t.eq(0, moved_exclusions, "the restoring re-crop carries no cutout")

  -- A steady state with no float open must not churn: the 50ms ui_poll and
  -- every window event recompute the placement constantly, and an unchanged
  -- one has to compare equal or the image would be re-placed forever.
  move_calls = 0
  vim.wait(200)
  t.eq(0, move_calls, "an unchanged placement never re-places the image")

  -- Regression: a plain (non-floating) split opened elsewhere -- e.g. a
  -- third-party diff/explorer plugin's own panes, opened "relative to
  -- editor" -- can shrink or reposition the preview split as an immediate
  -- side effect. WinNew must reconcile for *any* new window, not only
  -- floating ones, so the raw image follows without waiting on a separate
  -- WinResized round trip or the 50ms poll to eventually catch up.
  move_calls = 0
  local before_width = vim.api.nvim_win_get_width(session.preview_win)
  local squeeze_buf = vim.api.nvim_create_buf(false, true)
  local squeeze_win = vim.api.nvim_open_win(squeeze_buf, false, {
    split = "left",
    win = -1,
    width = math.max(20, math.floor(vim.o.columns / 2)),
  })
  vim.wait(300, function() return vim.api.nvim_win_get_width(session.preview_win) ~= before_width end, 10)
  t.ok(
    vim.api.nvim_win_get_width(session.preview_win) ~= before_width,
    "sanity: the new split actually resized the preview window"
  )
  vim.wait(300, function() return move_calls > 0 end, 10)
  t.ok(move_calls > 0, "a plain split's WinNew event alone reconciles the preview's now-changed geometry")
  vim.api.nvim_win_close(squeeze_win, true)

  vim.keymap.set("n", "<ScrollWheelDown>", "<Nop>", { desc = "test prior wheel mapping" })
  mouse.attach(controller.navigate)
  t.eq(true, mouse.is_attached(), "mouse wheel dispatch attaches for graphical preview")
  session.document_height_px = 1000
  session.viewport_height_px = 200
  session.scroll_y = 0
  preview.reset_surface(session)
  local source_cursor = vim.api.nvim_win_get_cursor(session.source_win)
  local original_schedule = controller.schedule
  local original_refresh = controller.refresh
  local scheduled = {}
  controller.refresh = function(_, options) scheduled.scroll_timer = { delay = 0, options = options } end
  controller.schedule = function(_, delay, timer_name, options)
    scheduled[timer_name] = { delay = delay, options = options }
  end
  session.scroll_render_in_flight = false
  controller.schedule_scroll(session)
  session.scroll_render_in_flight = false
  controller.refresh = original_refresh
  controller.schedule = original_schedule
  t.eq("css", scheduled.scroll_timer.options.capture_scale, "moving preview uses CSS-resolution frame")
  t.eq(true, scheduled.scroll_timer.options.capture_only, "scroll capture omits unchanged Markdown payload")
  t.eq(true, scheduled.scroll_timer.options.scroll_frame, "moving capture is identified for scroll ordering")
  t.eq("device", scheduled.scroll_settle_timer.options.capture_scale, "settled preview restores Retina frame")
  t.ok(scheduled.scroll_timer.delay < scheduled.scroll_settle_timer.delay, "fast frame precedes settled frame")

  local fast_requests, latest_fast_options = 0, nil
  controller.refresh = function(_, options)
    fast_requests = fast_requests + 1
    latest_fast_options = options
  end
  controller.schedule = function() end
  session.scroll_render_in_flight = false
  session.scroll_render_pending = false
  controller.schedule_scroll(session)
  controller.schedule_scroll(session)
  t.eq(1, fast_requests, "only one scroll capture is in flight")
  t.eq(true, session.scroll_render_pending, "newest scroll position is retained as one pending frame")
  latest_fast_options.on_complete()
  vim.wait(100, function() return fast_requests == 2 end)
  t.eq(2, fast_requests, "pending scroll position renders after current capture")
  session.scroll_render_in_flight = false
  session.scroll_render_pending = false
  controller.refresh = original_refresh
  controller.schedule = original_schedule

  local original_schedule_scroll = controller.schedule_scroll
  local scroll_requests = 0
  controller.schedule_scroll = function() scroll_requests = scroll_requests + 1 end
  controller.navigate(session, "line_down")
  controller.schedule_scroll = original_schedule_scroll
  t.eq(22, session.scroll_y, "j advances one rendered line")
  t.ok(session.manual_scroll_until > vim.uv.now(), "manual navigation pauses cursor-follow briefly")
  t.eq(1, scroll_requests, "preview navigation requests a backpressured scroll frame")
  t.eq(source_cursor, vim.api.nvim_win_get_cursor(session.source_win), "preview motion preserves source cursor")
  t.eq(
    88,
    (function()
      controller.schedule_scroll = function() end
      controller.navigate(session, "wheel_down")
      controller.schedule_scroll = original_schedule_scroll
      return session.scroll_y
    end)(),
    "mouse wheel advances configured rendered lines"
  )
  t.eq(1, vim.api.nvim_buf_line_count(session.preview_buf), "preview has no synthetic extra lines")
  controller.schedule_scroll = function() end
  controller.navigate(session, "bottom")
  controller.schedule_scroll = original_schedule_scroll
  t.eq(800, session.scroll_y, "G moves browser viewport to document bottom")

  session.backend = original_backend
  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(session.source_win, other)
  t.eq(session, state.get(source), "preview survives source buffer becoming hidden")
  t.ok(vim.api.nvim_win_is_valid(session.preview_win), "pinned preview remains visible while browsing files")
  controller.close()
  t.eq(nil, state.get(source), "preview close removes session")
  t.eq(false, mouse.is_attached(), "mouse dispatch is removed with the last graphical preview")
  local restored_wheel = vim.fn.maparg("<ScrollWheelDown>", "n", false, true)
  t.eq("<Nop>", restored_wheel.rhs, "previous mouse mapping is restored")
  vim.keymap.del("n", "<ScrollWheelDown>")
  vim.api.nvim_set_current_buf(source)
  local reopened = assert(controller.open("right"))
  t.ok(reopened.preview_buf ~= session.preview_buf, "preview close and reopen")
  controller.close(source)
end
