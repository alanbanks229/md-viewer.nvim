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
  -- The stub answers with a stats table, exactly as the raw Kitty backend does,
  -- so the controller's byte attribution is exercised by the same float events
  -- that exercise the re-crop itself rather than needing a case of its own.
  local MOVE_BYTES = 137
  local ui_bytes_before = session.ui_bytes_total or 0
  session.backend.move = function(image_id, moved_placement)
    move_calls = move_calls + 1
    moved_exclusions = #(moved_placement.exclusions or {})
    return image_id, { bytes = MOVE_BYTES }
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

  -- Every byte a re-crop wrote is attributed to the session, which is what makes
  -- "re-placing a resident image costs placements rather than pixels" a measured
  -- claim instead of an intention. Opening and closing the float is at least two
  -- moves; the ui_poll may add more, so this is a floor rather than an equality.
  t.ok(
    (session.ui_bytes_total or 0) >= ui_bytes_before + MOVE_BYTES * 2,
    "the controller attributes each re-crop's byte count to the session"
  )
  t.eq(MOVE_BYTES, session.last_ui_bytes, "and records what the most recent write cost")

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
  -- The settle timer is armed with a *function*, resolved when it fires. Every
  -- event in a burst re-arms it, so options built at arm time would describe
  -- where the reader was when the burst began -- which for a region fill is the
  -- difference between caching what they are reading and what they scrolled past.
  t.eq("function", type(scheduled.scroll_settle_timer.options), "the settle request is decided when the timer fires")
  local settled = scheduled.scroll_settle_timer.options(session)
  t.eq("device", settled.capture_scale, "settled preview restores Retina frame")
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
  -- The surface is exactly the placement: one blank line per row the image
  -- covers, each as wide as the image. That is what makes the caret's cell an
  -- address into the rendered document -- `coordinates.cell_to_css` refuses any
  -- row at or past `placement.height`, so a surface even one row taller would
  -- give the caret a position that silently resolves to nothing.
  do
    local placement = preview.placement(session.preview_win, session.backend.name)
    local lines = vim.api.nvim_buf_get_lines(session.preview_buf, 0, -1, false)
    t.eq(placement.height, #lines, "the caret surface is exactly as tall as the placement")
    t.eq(placement.width, #lines[1], "and exactly as wide")
    t.eq(string.rep(" ", placement.width), lines[1], "made of spaces, not virtual space")
  end
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

  -- ---------------------------------------------------------------------
  -- Regression: splitting off an *unrelated* file must not steal
  -- `session.source_win`. `:split other.md` fires `WinEnter` for the new
  -- window while it still shows the window-it-split-from's buffer (the
  -- source buffer) -- that is how `:split` works, before the trailing
  -- `:edit other.md` swaps it out a moment later in the same command. The
  -- old, synchronous version of this autocmd read `nvim_get_current_buf()`
  -- at that transient instant and reassigned `source_win` to the new
  -- window; nothing ever corrected it back, since the original window
  -- (still legitimately showing the source buffer) was never touched
  -- again. That silently broke `WinScrolled`-driven cursor-follow in the
  -- window the user was actually still working in.
  -- ---------------------------------------------------------------------
  do
    local original_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_buf(source)
    local real_session = assert(controller.open("right"))
    local true_source_win = real_session.source_win
    t.eq(true_source_win, vim.api.nvim_get_current_win(), "sanity: source_win starts out correct")

    local other_path = vim.fn.tempname() .. "-unrelated.md"
    vim.fn.writefile({ "unrelated content" }, other_path)
    -- The real command a user runs: split, then load a different file into
    -- the new window, all as one compound `:split` invocation -- exactly
    -- what triggers the transient WinEnter this regression is about.
    vim.cmd("leftabove vsplit " .. vim.fn.fnameescape(other_path))
    vim.wait(50)

    t.eq(
      true_source_win,
      real_session.source_win,
      "splitting off an unrelated file leaves source_win pointed at the real source window"
    )

    local other_buf = vim.api.nvim_get_current_buf()
    pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), true)
    vim.api.nvim_set_current_win(true_source_win)
    controller.close(source)
    pcall(vim.api.nvim_buf_delete, other_buf, { force = true })
    pcall(vim.api.nvim_set_current_win, original_win)
    vim.fn.delete(other_path)
  end

  -- ---------------------------------------------------------------------
  -- Regression: a window keeps its id when its buffer changes. Opening a
  -- second file in the window a preview was started from left WinScrolled's
  -- `scrolled_win == session.source_win` test passing, so scrolling the new
  -- file looked its line numbers up in the old file's source map and
  -- scrolled the old file's preview -- the operator saw scrolling SECURITY.md
  -- move a README.md preview.
  -- ---------------------------------------------------------------------
  do
    local entry_win = vim.api.nvim_get_current_win()
    local original_lines = vim.api.nvim_buf_get_lines(source, 0, -1, false)
    local long = {}
    for i = 1, 40 do
      long[i] = "line " .. i
    end
    vim.api.nvim_buf_set_lines(source, 0, -1, false, long)
    vim.api.nvim_set_current_buf(source)
    local scrolled = assert(controller.open("right"))
    local win = scrolled.source_win
    -- A source map coarse enough that a line deep in either buffer lands well
    -- outside the anchor tolerance, so the unfixed code moves `scroll_y` a long
    -- way rather than declining to for some unrelated reason.
    local function arm()
      scrolled.latest_blocks = {
        { sourceStart = 0, sourceEnd = 3, topPx = 0, bottomPx = 100 },
        { sourceStart = 3, sourceEnd = 60, topPx = 100, bottomPx = 2000 },
      }
      scrolled.viewport_height_px, scrolled.document_height_px = 200, 2000
      scrolled.scroll_y, scrolled.last_source_block = 0, nil
    end
    local function scroll(target)
      vim.api.nvim_exec_autocmds("WinScrolled", { group = "md-viewer", pattern = tostring(target) })
    end
    -- The debounced follow-up would schedule real renders; every assertion here
    -- is on `scroll_y`, which sync sets synchronously before calling back.
    local original_schedule_scroll = controller.schedule_scroll
    controller.schedule_scroll = function() end

    local stranger = vim.api.nvim_create_buf(true, false)
    vim.bo[stranger].filetype = "markdown"
    vim.api.nvim_buf_set_lines(stranger, 0, -1, false, long)
    vim.api.nvim_win_set_buf(win, stranger)
    vim.api.nvim_win_set_cursor(win, { 30, 0 })
    vim.wait(50)
    arm()
    scroll(win)
    t.eq(0, scrolled.scroll_y, "scrolling another file in the preview's old source window leaves the preview alone")
    t.eq(source, scrolled.source_buf, "...and the pinned preview goes on rendering its own document")

    -- The source document reopened in a different window drives the preview
    -- again. `source_win` is put back deliberately after the split settles: a
    -- wheel over an unfocused window scrolls it without any WinEnter, so this
    -- is the state the resolver has to recover from on its own.
    vim.api.nvim_set_current_win(win)
    vim.cmd("leftabove split")
    local pane3 = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(pane3, source)
    vim.api.nvim_win_set_cursor(pane3, { 30, 0 })
    vim.api.nvim_set_current_win(win)
    vim.wait(50)
    scrolled.source_win = win
    arm()
    scroll(pane3)
    t.ok(scrolled.scroll_y > 0, "the source document reopened in another window drives the preview again")
    t.eq(pane3, scrolled.source_win, "...and that window is adopted as the source window")

    -- Two windows showing one document is the transient state a compound
    -- `:vsplit other.md` passes through, and the one the regression above is
    -- about. There is no principled tiebreak, so nothing is adopted and the
    -- WinEnter handler is left to settle it when the reader picks a window.
    vim.api.nvim_win_set_buf(win, source)
    scrolled.source_win = scrolled.preview_win
    t.eq(nil, state.source_window(scrolled), "one document in two windows adopts neither")

    -- The guard must not have simply switched cursor-follow off.
    scrolled.source_win = win
    vim.api.nvim_win_set_cursor(win, { 30, 0 })
    arm()
    scroll(win)
    t.ok(scrolled.scroll_y > 0, "the window actually showing the source document still drives the preview")

    controller.schedule_scroll = original_schedule_scroll
    pcall(vim.api.nvim_win_close, pane3, true)
    controller.close(source)
    pcall(vim.api.nvim_buf_delete, stranger, { force = true })
    vim.api.nvim_buf_set_lines(source, 0, -1, false, original_lines)
    pcall(vim.api.nvim_set_current_win, entry_win)
  end

  -- ---------------------------------------------------------------------
  -- Overlay display: display_selection_overlay refuses any result
  -- whose geometry cannot be proven to match the frame on screen, applies
  -- matching ones through the backend, and clear_selection_overlay releases
  -- the placements exactly once.
  -- ---------------------------------------------------------------------
  do
    local entry_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_buf(source)
    local session = assert(controller.open("right"))
    local applied, cleared = {}, {}
    session.backend = {
      name = "kitty_raw",
      overlay_supported = function() return true end,
      overlay_needs_sheet = function() return false end,
      overlay_apply = function(set_id, image_id, rects, viewport, tint, sheet, placement)
        applied[#applied + 1] = {
          set_id = set_id,
          image_id = image_id,
          rects = rects,
          viewport = viewport,
          tint = tint,
          sheet = sheet,
          placement = placement,
        }
        return 91, { rects = #rects, bytes = 420, placed = #rects, kept = 0, deleted = 0 }
      end,
      overlay_clear = function(set_id) cleared[#cleared + 1] = set_id end,
      clear = function() return true end,
    }
    session.image_id = 7
    session.last_placement = { row = 0, col = 0, width = 80, height = 24, exclusions = {} }
    session.renderer_revision = "1:0"
    session.applied_scroll_y = 40
    session.viewport_width_px = 800
    session.viewport_height_render_px = 600

    local good = {
      contentRevision = "1:0",
      scrollY = 40,
      rects = { { x = 1, y = 2, width = 3, height = 4 } },
      rectsTruncated = false,
      selectionTint = { r = 220, g = 220, b = 220, a = 0.3 },
    }

    t.eq(
      false,
      (
        controller.display_selection_overlay(
          session,
          vim.tbl_extend("force", vim.deepcopy(good), { contentRevision = "0:9" })
        )
      ),
      "a result from another content revision is refused"
    )
    t.eq(
      false,
      (controller.display_selection_overlay(session, vim.tbl_extend("force", vim.deepcopy(good), { scrollY = 0 }))),
      "a result measured at a different scroll than the frame on screen is refused"
    )
    t.eq(
      false,
      (
        controller.display_selection_overlay(
          session,
          vim.tbl_extend("force", vim.deepcopy(good), { rectsTruncated = true })
        )
      ),
      "a truncated rect set is refused rather than drawn with missing pieces"
    )
    t.eq(0, #applied, "refused results never reach the backend")

    t.eq(true, (controller.display_selection_overlay(session, good)), "a matching result applies")
    t.eq(1, #applied, "the backend received the apply")
    t.eq(7, applied[1].image_id, "the overlay composites over the base image on screen")
    t.eq(91, session.overlay_set, "the set id is recorded for the next diff")
    t.eq(1, session.overlay_rect_count)
    t.eq(420, session.overlay_last_bytes)

    -- The next frame passes the recorded set id back in, so the backend can
    -- diff instead of replacing everything.
    t.eq(true, (controller.display_selection_overlay(session, good)))
    t.eq(91, applied[2].set_id)

    controller.clear_selection_overlay(session)
    t.eq(1, #cleared, "clearing releases the backend set")
    t.eq(91, cleared[1])
    t.eq(nil, session.overlay_set)
    controller.clear_selection_overlay(session)
    t.eq(1, #cleared, "a second clear is a no-op, not a double delete")

    -- restore_clean_base's preconditions. It runs on the first frame of a drag
    -- and puts a cached selection-free frame back so overlay rectangles have
    -- something clean to composite over; every way of not knowing that the
    -- cached frame still matches what is on screen has to refuse rather than
    -- place a frame from the wrong scroll position or the wrong document.
    session.base_selection_painted = false
    t.eq(true, controller.restore_clean_base(session), "an already-clean base needs no work")
    session.base_selection_painted = true
    session.clean_image_bytes = nil
    t.eq(false, controller.restore_clean_base(session), "no cached selection-free frame means no restore")
    session.clean_image_bytes = "png"
    session.clean_image_revision = session.renderer_revision
    session.applied_scroll_y = 0
    session.clean_image_scroll_y = 240
    t.eq(false, controller.restore_clean_base(session), "a frame cached at another scroll position is refused")
    session.clean_image_scroll_y = 0
    session.clean_image_revision = "not-the-current-revision"
    t.eq(false, controller.restore_clean_base(session), "a frame cached against other content is refused")
    t.eq(true, session.base_selection_painted, "a refusal leaves the base marked painted")

    -- Which frames become the cached clean base. Recorded wherever a frame
    -- reaches the screen rather than in M.refresh alone: a scroll taken while
    -- a selection was up drops the cache, and interact frames never reach
    -- M.refresh, so clicking to deselect -- which produces a perfectly good
    -- selection-free frame -- used to leave the drag overlay disabled until
    -- some later render happened to land with nothing selected.
    local function interact_frame(bytes)
      local path = vim.fn.tempname()
      local fd = assert(vim.uv.fs_open(path, "w", 384))
      vim.uv.fs_write(fd, bytes, 0)
      vim.uv.fs_close(fd)
      controller.display_interact_result(session, { pngPath = path, scrollY = 40, captureScale = "device" })
    end
    session.backend.show = function() return 12 end
    session.backend.update = function() return 12 end
    session.clean_image_bytes = nil
    session.clean_image_revision = nil

    session.selection_active = true
    interact_frame("selected-frame")
    t.eq(nil, session.clean_image_bytes, "a frame captured with a selection painted in is not cached as clean")
    t.eq(true, session.base_selection_painted, "and is marked as carrying a selection")

    session.selection_active = false
    interact_frame("clean-frame")
    t.eq("clean-frame", session.clean_image_bytes, "a selection-free interact frame becomes the clean base")
    t.eq(40, session.clean_image_scroll_y, "cached against the scroll position it was taken at")
    t.eq("1:0", session.clean_image_revision, "and against the content revision it belongs to")
    t.eq("device", session.clean_image_scale, "the capture scale rides along so the restore matches")
    t.eq(false, session.base_selection_painted, "the frame on screen is now known to be clean")
    t.eq(true, controller.restore_clean_base(session), "so the next drag has a base to composite over")

    -- ------------------------------------------------------------------
    -- Resident regions: a hit costs a placement, not a frame.
    --
    -- This is the acceptance test for the whole feature. Everything else
    -- measures how much smaller a frame got; this measures that no frame was
    -- produced at all -- no renderer request, no capture, no image bytes.
    -- ------------------------------------------------------------------
    local resident = require("md-viewer.resident")
    local process = require("md-viewer.process")

    -- Counted, and deliberately never forwarded: this measures whether a scroll
    -- *asks* for a frame, and a real renderer round trip would add a Chromium
    -- launch to a question that is answered before the request leaves Lua.
    local requests, request_positions = 0, {}
    local real_request = process.request
    process.request = function(_, params)
      requests = requests + 1
      request_positions[#request_positions + 1] = params and params.scrollY
      return 1
    end

    local moves, move_sources, uploads = 0, {}, 0

    -- A miss leaves a capture in flight, and the next scroll is meant to
    -- coalesce behind it rather than issue a second. That is the existing
    -- backpressure, tested above; here it would mask what is being measured, so
    -- each case starts from an idle pipeline.
    local function scroll_to(position)
      session.scroll_render_in_flight = false
      session.scroll_render_pending = false
      requests, moves, uploads, request_positions = 0, 0, 0, {}
      session.scroll_y = position
      controller.schedule_scroll(session)
    end

    session.backend.move = function(image_id, _, source)
      moves = moves + 1
      move_sources[#move_sources + 1] = source
      return image_id, { bytes = 210 }
    end
    -- A pan places through `compose` rather than `move`: whatever it replaces has
    -- to come down in the same write, and a `move` can only name one predecessor.
    -- Counted as the same thing, because it is -- one placement command for one
    -- band.
    local compose_parts_seen = {}
    session.backend.compose = function(parts, _)
      moves = moves + 1
      move_sources[#move_sources + 1] = parts[1] and parts[1].source
      compose_parts_seen = vim.deepcopy(parts)
      return true, { bytes = 210 }
    end
    session.backend.show = function()
      uploads = uploads + 1
      return 4242, { bytes = 810000, width_px = 1980, height_px = 4040 }
    end
    session.backend.clear = function() return true end

    session.viewport_width_px, session.viewport_height_px = 990, 1020
    session.viewport_height_render_px = 1020
    session.document_height_px = 10891
    session.renderer_revision = "1:0"
    session.selection_active, session.find_active, session.pointer = false, false, nil
    session.base_selection_painted = false

    local live = session.resident
    live.enabled = true
    live.fallback_reason = nil
    live.memory_px = 8000000 * 4
    live.key = controller._resident_key(session)

    -- The grid, and positions derived from it rather than written down. A slice
    -- boundary is a function of the pane's row count, which is whatever window
    -- this test happens to get -- so hard-coded scroll positions would be
    -- asserting about the terminal size rather than about the mechanism.
    local grid = assert(controller._resident_grid(session))
    local function slice_at(index) return (assert(resident.slice(grid, index))) end
    -- A position comfortably inside slice `index`: halfway through the travel it
    -- affords, so a small step in either direction stays inside it.
    local function inside(index)
      local slice = slice_at(index)
      return slice.doc_y + math.floor((slice.doc_h - 1020) / 2)
    end
    -- What a crop of that position looks like in the slice's own image pixels.
    local function crop_y(index, scroll_y) return (scroll_y - slice_at(index).doc_y) * 2 end

    local function make_slice(index, image_id)
      local slice = slice_at(index)
      return assert(resident.region({
        doc_y = slice.doc_y,
        doc_h = slice.doc_h,
        css_w = 990,
        image_w = grid.image_w,
        image_h = slice.doc_h * 2,
        key = live.key,
        image_id = image_id,
      }))
    end

    local region = make_slice(0, 4242)
    assert(resident.register(live, 0, region))
    session.image_id = 4242

    -- A scroll to a position the slice covers.
    local at = inside(0)
    scroll_to(at)
    t.eq(0, requests, "a resident hit sends the renderer nothing at all")
    t.eq(0, uploads, "and uploads no image")
    t.eq(1, moves, "it is one placement command")
    t.eq(crop_y(0, at), move_sources[1].y, "cropping into the slice at the capture scale")
    t.eq(at, session.applied_scroll_y, "and the position recorded is the one the pixels show")
    t.eq(1, live.hits, "counted as a hit")
    t.eq(210, live.placement_bytes, "with the bytes it actually cost")

    -- Scrolling back is free too -- the case a smaller frame can never help
    -- with, because the pixels have already been paid for.
    local back = math.floor(at / 2)
    scroll_to(back)
    t.eq(0, requests, "scrolling back through resident content is also free")
    t.eq(crop_y(0, back), move_sources[#move_sources].y, "and crops backwards within the same image")

    -- Leaving the slice is an ordinary miss, on exactly the path that existed
    -- before any of this. Two slices further on, so this is a cell nothing has
    -- filled rather than a boundary.
    scroll_to(inside(2))
    t.ok(requests > 0, "leaving the resident range falls through to a capture")
    t.eq(0, moves, "and does not pretend to pan")
    t.ok(live.misses > 0, "counted as a miss")

    -- ------------------------------------------------------------------
    -- The boundary. A grid's edges never move, so a reader can park on one --
    -- which is exactly what the bounded region could not survive, because its
    -- edges moved with them. The viewport is drawn as two bands, split at a
    -- whole cell row, in one write.
    -- ------------------------------------------------------------------
    -- One pixel past the last position slice 0 can cover on its own, which is
    -- the first that needs both.
    local boundary = math.floor(slice_at(0).doc_y + slice_at(0).doc_h - 1020) + 1
    local straddle_first, straddle_last = resident.slices_for(grid, boundary, 1020)
    t.eq(0, straddle_first, "sanity: that position starts in slice 0")
    t.eq(1, straddle_last, "and genuinely needs slice 1 as well")

    -- With only the upper slice held there is nothing to composite with, so the
    -- honest answer is today's captured frame -- never one band stretched over
    -- the pane, which is a picture of the wrong part of the document that would
    -- arrive looking perfectly fine.
    local misses_before = live.straddle_misses
    scroll_to(boundary)
    t.eq(0, moves, "a straddle with only one of its two slices held places nothing")
    t.eq(misses_before + 1, live.straddle_misses, "and is counted apart from an ordinary miss")
    t.ok(requests > 0, "falling through to the capture path")

    -- And with both.
    assert(resident.register(live, 1, make_slice(1, 4343)))
    local straddles_before = live.straddles
    scroll_to(boundary - 1)
    scroll_to(boundary)
    t.eq(0, requests, "with both slices held the boundary asks the renderer for nothing")
    t.eq(straddles_before + 1, live.straddles, "and is drawn as the straddle it is")
    t.eq(2, #compose_parts_seen, "as two bands")
    local upper_part, lower_part = compose_parts_seen[1], compose_parts_seen[2]
    t.eq(4242, upper_part.image_id, "the upper band from the slice above the boundary")
    t.eq(4343, lower_part.image_id, "the lower band from the slice below it")

    -- Disjoint in whole cells, and together exactly the pane. Two base-layer
    -- placements over the *same* cells is the 2026-08-08 Ghostty defect; over
    -- disjoint ones the protocol's id tie-break is never consulted at all.
    local pane = preview.placement(session.preview_win, "kitty_raw")
    t.eq(pane.row, upper_part.placement.row, "the upper band starts at the top of the pane")
    t.eq(
      upper_part.placement.row + upper_part.placement.height,
      lower_part.placement.row,
      "the lower band starts exactly where the upper one ends -- no gap, no overlap"
    )
    t.eq(
      pane.height,
      upper_part.placement.height + lower_part.placement.height,
      "and between them they are the whole pane"
    )
    t.ok(upper_part.placement.height >= 1, "with at least one row each")
    t.ok(lower_part.placement.height >= 1, "so neither band is a placement of nothing")

    -- Complementary in the document, which is the part a screenshot could not
    -- show: the upper band ends at the document position the lower one starts
    -- at, so no scanline is drawn twice or skipped across the seam.
    local upper_region, lower_region = resident.hold(live, 0), resident.hold(live, 1)
    local seam_from_upper = upper_region.doc_y + (upper_part.source.y + upper_part.source.height) / upper_region.scale_y
    local seam_from_lower = lower_region.doc_y + lower_part.source.y / lower_region.scale_y
    -- Exactly. Both slices start on a whole image pixel and share a scale, so
    -- the seam rounds the same way in both -- there is no slack to hide a band
    -- that was snapped on its own, which is a scanline drawn twice or skipped.
    t.near(seam_from_upper, seam_from_lower, 1e-6, "the two bands meet at exactly one document position")
    t.near(
      session.applied_scroll_y,
      upper_region.doc_y + upper_part.source.y / upper_region.scale_y,
      0.75,
      "and the pane's top row shows the position recorded as displayed"
    )
    t.near(
      session.applied_scroll_y + 1020,
      lower_region.doc_y + (lower_part.source.y + lower_part.source.height) / lower_region.scale_y,
      1.5,
      "with the bottom row exactly one viewport below it"
    )

    -- The whole pane, not either band. `interaction`, `caret`, `animation` and
    -- the backend's overlay geometry all derive from this and all mean the box
    -- the document is drawn into; a band would put every one of them inside the
    -- top half of the preview.
    t.eq(pane.height, session.last_placement.height, "the recorded placement stays the whole pane")

    -- A float opening over the preview re-places what is on screen. Against a
    -- composite that cannot be `move(session.image_id, ...)`: it would draw the
    -- upper slice across the whole pane and report success. It runs on every
    -- float, every cmdline entry and every 50 ms poll tick, so a composite would
    -- survive about one keystroke.
    compose_parts_seen = {}
    local moved_ids = {}
    local real_move = session.backend.move
    session.backend.move = function(image_id, ...)
      moved_ids[#moved_ids + 1] = image_id
      return real_move(image_id, ...)
    end
    controller._reconcile_placement(session, true)
    session.backend.move = real_move
    t.eq({}, moved_ids, "a composite is never re-placed by moving its head")
    t.eq(2, #compose_parts_seen, "it is recomposed, both bands together")
    t.eq(4242, compose_parts_seen[1].image_id, "still the upper slice above")
    t.eq(4343, compose_parts_seen[2].image_id, "and the lower one below")

    -- Back inside a single slice for the assertions that follow.
    scroll_to(inside(0))

    -- Browser-painted state that a clean region does not carry. Refusing to
    -- *fill* while a search is up is not enough on its own: a region captured
    -- before the search is still valid by key, so it would be eligible to pan
    -- straight over the marks and erase them.
    session.find_active = true
    scroll_to(inside(0))
    t.eq(0, moves, "an active search refuses to pan even over a slice that covers the viewport")
    t.ok(live.blocked_by_find > 0, "and says why")
    t.ok(requests > 0, "falling through to the capture path that shows the marks")

    session.find_active = false
    session.selection_active = true
    scroll_to(inside(0) - 50)
    t.eq(0, moves, "a live selection refuses for the same reason")
    t.ok(live.blocked_by_selection > 0, "and is counted separately")

    -- Clearing it restores panning at no cost: the region was never discarded,
    -- so the next scroll is a placement rather than a capture.
    session.selection_active = false
    scroll_to(inside(0) - 100)
    t.eq(0, requests, "clearing the search or selection makes scrolling free again")
    t.eq(1, moves, "at the cost of one placement")
    t.eq(0, uploads, "and no re-upload -- the slice was kept throughout")

    -- New content supersedes every slice, and the pixels go back.
    local freed = {}
    session.backend.clear = function(image_id)
      freed[#freed + 1] = image_id
      return true
    end
    session.renderer_revision = "2:0"
    local generation_before = live.generation
    scroll_to(inside(0) - 150)
    t.eq(0, moves, "a new content revision invalidates every slice")
    t.eq(0, #resident.slice_records(live), "dropping them")
    t.ok(vim.tbl_contains(freed, 4242), "and freeing their pixels rather than leaking them")
    t.eq(0, live.resident_px, "so the ceiling is given back")
    t.eq(nil, live.grid, "the grid goes with them, since its boundaries described the old document")
    t.ok(live.generation > generation_before, "and the generation moves, so a fill in flight knows it is orphaned")

    -- ------------------------------------------------------------------
    -- The wire: at most one image payload outstanding per session.
    --
    -- The renderer's `settle` lane stops a region fill and a moving capture
    -- cancelling each other inside Node. It does not give them separate wires.
    -- A region and the frames it replaces go through the same `nvim_ui_send`
    -- queue into the same pty, and bytes handed to that queue cannot be
    -- recalled -- so unless something declines to produce them, a region
    -- draining for a second collects behind it every frame produced during that
    -- second, each showing a position the reader has already left. That is the
    -- backlog this whole feature exists to remove, rebuilt by the feature.
    -- ------------------------------------------------------------------

    -- The renderer owns this field and rewrites it on every completed request,
    -- so a fill can only be tested against the revision it will actually be
    -- given. Setting it to anything else makes every fill below correctly
    -- discarded as stale, which is a real behaviour but not the one under test.
    session.renderer_revision = ("%d:%d"):format(
      vim.api.nvim_buf_get_changedtick(session.source_buf),
      session.render_epoch or 0
    )
    live.key = controller._resident_key(session)
    grid = assert(controller._resident_grid(session))
    assert(resident.register(live, 0, make_slice(0, 4242)))
    session.image_id = 4242

    -- A pan during a drain is not merely allowed but preferred: two hundred
    -- bytes queue trivially behind the slice they crop into, and they show the
    -- reader where they actually are.
    live.upload_hold_until = vim.uv.now() + 120
    scroll_to(inside(0))
    t.eq(1, moves, "a pan during a slice's drain is emitted rather than held")
    t.eq(0, requests, "and still asks the renderer for nothing")
    t.eq(0, live.frames_suppressed_by_hold, "so there was nothing to suppress")

    -- A miss during a drain is the opposite. Twenty of them, which is what one
    -- flick of a wheel produces.
    requests, moves, uploads, request_positions = 0, 0, 0, {}
    session.scroll_render_in_flight = false
    session.scroll_render_pending = false
    local coalesced_before = session.coalesced_scroll_events or 0
    for i = 1, 20 do
      session.scroll_y = 5000 + i
      controller.schedule_scroll(session)
    end
    t.eq(0, requests, "twenty scroll events during one drain ask the renderer for nothing at all")
    t.eq(0, uploads, "and put no second image on a wire that is already carrying one")
    t.eq(0, moves, "and place nothing -- these are misses, outside the region")
    t.eq(20, live.frames_suppressed_by_hold, "each counted as a frame that was not queued")
    t.eq(20, (session.coalesced_scroll_events or 0) - coalesced_before, "and as a scroll that produced no frame")
    t.eq(5020, live.desired_scroll_y, "with the newest position kept rather than the burst replayed")

    -- And the anti-backlog assertion: the twenty become one.
    t.ok(vim.wait(2000, function() return requests > 0 end, 5), "the hold expires and scrolling resumes on its own")
    t.eq(1, requests, "as exactly one capture, not the twenty that were suppressed")
    t.eq(5020, request_positions[1], "at the newest position rather than the oldest")
    require("md-viewer.debounce").close(session, "scroll_settle_timer")

    -- ------------------------------------------------------------------
    -- The fill: one slot, claimed where the request is issued.
    -- ------------------------------------------------------------------

    live.upload_hold_until = 0
    session.scroll_y = inside(1)
    local first_plan = controller._settle_options(session)
    t.ok(first_plan.capture_region ~= nil, "a settled scroll asks for a slice rather than a viewport")
    t.eq(slice_at(1).doc_y, first_plan.capture_region.yPx, "the slice under the reader, at its own fixed position")
    t.eq(1, first_plan.resident_slice, "named by the cell it will occupy rather than by where the reader is")
    -- Planning must not claim the slot. The settle timer re-plans on every event
    -- of a burst and fires once, so a slot taken at planning time is taken by an
    -- event that issued nothing -- and denied to the one that did.
    t.eq(false, live.fill.in_flight, "planning a fill does not claim the fill slot")
    session.scroll_y = inside(3)
    local later_plan = controller._settle_options(session)
    t.ok(
      later_plan.capture_region.yPx > first_plan.capture_region.yPx,
      "so a later event in the same burst still plans, around wherever the reader has got to"
    )
    -- And the property that makes "uploaded once" true: the same position asks
    -- for the same rectangle however the reader arrived at it. A region anchored
    -- on the reader would have moved with them.
    session.scroll_y = inside(1)
    t.eq(
      first_plan.capture_region.yPx,
      controller._settle_options(session).capture_region.yPx,
      "and coming back to a position asks for exactly the capture it asked for before"
    )
    live.fill.in_flight = true
    t.eq(nil, controller._settle_options(session).capture_region, "but a fill already in flight refuses a second")
    live.fill.in_flight = false

    -- The *press*, not the pointer table. A released drag leaves the table
    -- behind -- only interaction.forget nils it -- and a visual-mode synthetic
    -- pointer exists with pressed=false. Refusing on the table's existence means
    -- one click anywhere in the preview stops every later settle from asking for
    -- a region, and stops every pan, for the rest of the session: silently, with
    -- nothing refused and nothing failed. animation.lua was caught by this same
    -- table once already.
    session.pointer = { pressed = true }
    session.scroll_y = inside(1)
    t.eq(nil, controller._settle_options(session).capture_region, "a drag in progress plans no fill")
    session.scroll_y = inside(0)
    t.eq(false, controller._try_pan(session), "and pans nothing")
    session.pointer = { pressed = false }
    session.scroll_y = inside(1)
    t.ok(
      controller._settle_options(session).capture_region ~= nil,
      "a released drag leaves the table but not the gesture"
    )
    session.scroll_y = inside(0)
    t.eq(true, controller._try_pan(session), "so scrolling after a click still pans")
    session.pointer = nil

    -- The capture scale is read off the last *device-tier* image, not off
    -- whatever is on screen. Over SSH those differ every time it matters: the
    -- settle fires once scrolling stopped, so the frame on screen is a moving
    -- one captured at ssh_scroll_scale, whose PNG at 0.5 and device scale 2 is
    -- exactly viewport-width. Reading 1.0 for a capture that will arrive at 2.0
    -- builds a grid whose slices claim a quarter of the pixels they will really
    -- cost, so the ceiling is silently overrun fourfold.
    session.image_width_px = 990 -- the moving frame: 990 CSS * 2 * 0.5
    session.device_image_width_px = 1980 -- what a settle actually comes back at
    -- The grid is derived once and held, so it has to be dropped to be re-derived
    -- from those two. That is exactly the property being relied on everywhere
    -- else, and the reason this poke is needed here and nowhere else.
    live.grid = nil
    local rebuilt = assert(controller._resident_grid(session))
    t.eq(1980, rebuilt.image_w, "a slice is as wide as a device-tier capture, not as the moving frame on screen")
    t.eq(1980 * 4080, resident.slice_cost_px(rebuilt), "so what it will cost the terminal is what it is judged by")
    t.ok(resident.slice_cost_px(rebuilt) <= live.memory_px, "and fits the ceiling rather than overrunning it fourfold")
    session.image_width_px = 1980
    grid = rebuilt

    -- A fill, end to end. The viewport is pinned for the duration because this
    -- callback adopts whatever the renderer reports, and a viewport that moved
    -- would change the region key -- which is a real hazard, tested below on
    -- purpose rather than by accident here.
    local real_viewport = preview.viewport
    local viewport_answer = { widthPx = 990, heightPx = 1020, tier = "measured" }
    preview.viewport = function() return viewport_answer end

    local pending
    process.request = function(_, params, callback)
      requests = requests + 1
      request_positions[#request_positions + 1] = params and params.scrollY
      pending = { params = params, callback = callback }
      return 1
    end

    local update_opts = {}
    -- The rectangle the renderer says it actually captured, remembered so the
    -- PNG's "real" dimensions below can agree with it. `resident.region` derives
    -- the scale from those two and refuses a disagreement over a hundredth --
    -- correctly, since a region built on numbers that do not add up would crop
    -- wrongly everywhere -- so a stub that answers a fixed size would refuse
    -- every fill and fall the session back before any of this could be measured.
    local captured_region
    session.backend.png_dimensions = function()
      local height = captured_region and captured_region.heightPx or 1020
      return grid.image_w, math.floor(height * 2 + 0.5)
    end
    session.backend.update = function(image_id, _, _, opts)
      uploads = uploads + 1
      update_opts[#update_opts + 1] = opts
      return image_id == 4242 and 4343 or image_id, { bytes = 810000, width_px = 1980, height_px = 4040 }
    end

    local function complete_fill(overrides)
      local path = vim.fn.tempname() .. ".png"
      local fd = assert(vim.uv.fs_open(path, "w", 420))
      vim.uv.fs_write(fd, "png", 0)
      vim.uv.fs_close(fd)
      local answer = vim.tbl_extend("force", {
        pngPath = path,
        blocks = {},
        documentHeightPx = 10891,
        viewportHeightPx = 1020,
        scrollY = pending.params.scrollY,
        captureScale = "device",
        captureEncoder = "cdp",
        pngBytes = 810000,
        captureMs = 146,
        -- Absent on an ordinary settle, which is a picture of one viewport
        -- rather than of a range. The helper answers both so the same completion
        -- path can be used to land either kind.
        regionYPx = pending.params.captureRegion and pending.params.captureRegion.yPx,
        regionHeightPx = pending.params.captureRegion and pending.params.captureRegion.heightPx,
      }, overrides or {})
      captured_region = pending.params.captureRegion
      local callback = pending.callback
      pending = nil
      callback(answer, nil)
    end

    -- One sharp viewport frame, so a fill can be told apart from one.
    session.retina_png_bytes = 305000
    freed = {}
    uploads, requests = 0, 0
    session.scroll_y = inside(1)
    controller.refresh(session, controller._settle_options(session))
    t.eq(true, live.fill.in_flight, "issuing a fill claims the one fill slot")
    t.eq(slice_at(1).doc_y, pending.params.captureRegion.yPx, "and asks for the slice's own fixed rectangle")

    -- The reader keeps reading while it captures. Nothing supersedes the fill: a
    -- resident hit issues no request, so scrolling inside a slice does not
    -- invalidate the fill that is capturing the next one.
    local landed_at = inside(1) + 100
    session.scroll_y = landed_at
    complete_fill()
    t.eq(false, live.fill.in_flight, "which is released when it lands")
    t.eq(landed_at, session.scroll_y, "a fill never drags the reader back to where it was planned")
    t.eq(landed_at, session.applied_scroll_y, "and the position recorded is the one the crop actually shows")
    t.eq(crop_y(1, landed_at), update_opts[#update_opts].source.y, "cropped into the slice at the capture scale")
    t.eq(true, update_opts[#update_opts].retain_superseded, "the image it replaced keeps its pixels through the swap")
    t.eq(2, #resident.slice_records(live), "leaving two slices held, each in its own cell")
    t.eq(4343, live.slices[1].image_id, "the new one registered against the id the backend handed back")
    t.eq(4242, live.slices[0].image_id, "beside the one that was already there, which nothing displaced")
    t.eq(0, live.evictions, "and nothing evicted, which is the property the whole rebuild is for")
    t.eq(305000, session.retina_png_bytes, "a fill is never counted as the cost of a sharp viewport frame")

    -- The hold, from the one number this link has already been tuned around.
    t.eq(160, live.upload_hold_ms, "with no link rate known the hold is the session's settle delay")
    t.ok(live.upload_hold_until > vim.uv.now(), "and the wire is held while the region drains")
    -- And the fill's own transfer is *not* an observation of a link. 810 KB
    -- handed to a stub that returns immediately implies a rate no link can
    -- have, which is exactly what the real session recorded -- SSH took the
    -- payload into its buffer and the write returned before a byte crossed.
    -- Believing it computes a hold of zero and the anti-backlog rule never runs.
    t.eq(nil, live.wire_bytes_per_ms, "a write that did not block is not a throughput sample")
    t.eq(1, live.wire_samples_discarded, "it is thrown out, and visibly")
    live.upload_hold_until = 0

    -- The one failure this cache must not be able to produce: pixels of one
    -- document stamped with another document's identity. The request serial does
    -- not catch this, because the disagreement is created by this very callback
    -- adopting the renderer's viewport before the region is built.
    -- Anchored to the position the *displayed* fill established, not to
    -- whatever the previous statement left behind: a fill that wrongly writes
    -- this on its way to being discarded moves both, and an assertion comparing
    -- them to each other would agree with itself and prove nothing.
    local stale_before, uploads_before = live.stale_fills, uploads
    local displayed_scroll_y = session.applied_scroll_y
    t.eq(landed_at, displayed_scroll_y, "sanity: the last fill that reached the screen set the position")
    session.scroll_y = inside(2)
    -- The preview was resized after the last response landed, so the session's
    -- idea of its own viewport is one response out of date. That is precisely
    -- when this happens: the key is computed from the stale width when the fill
    -- is issued, and from the width the renderer measured when it comes back.
    viewport_answer = { widthPx = 880, heightPx = 1020, tier = "measured" }
    controller.refresh(session, controller._settle_options(session))
    complete_fill()
    t.eq(stale_before + 1, live.stale_fills, "a fill whose document changed under it is discarded, never displayed")
    t.eq(uploads_before, uploads, "without reaching the terminal")
    t.eq(false, live.fill.in_flight, "and the slot is released -- a discarded fill must not disable every later one")
    -- The screen still shows what it showed. `applied_scroll_y` is what the
    -- caret's drift, the animation layer's placement and every interact request
    -- are derived from, so a fill that wrote it while being thrown away would
    -- put all three at a position no pixels were ever drawn for.
    t.eq(displayed_scroll_y, session.applied_scroll_y, "a discarded fill leaves the recorded position where it was")
    viewport_answer = { widthPx = 990, heightPx = 1020, tier = "measured" }
    session.viewport_width_px = 990
    live.key = controller._resident_key(session)

    -- Overtaken rather than wrong, and counted apart for exactly that reason: a
    -- region the reader has left is several hundred kilobytes of wire that would
    -- buy nothing, so it is dropped before it costs any.
    local abandoned_before = live.abandoned_fills
    uploads_before = uploads
    local applied_before = session.applied_scroll_y
    session.scroll_y = inside(2)
    controller.refresh(session, controller._settle_options(session))
    session.scroll_y = 9000
    complete_fill()
    t.eq(abandoned_before + 1, live.abandoned_fills, "a region the reader has left is discarded")
    t.eq(uploads_before, uploads, "without spending a byte on pixels nobody is looking at")
    t.eq(false, live.fill.in_flight, "and releases the slot")
    -- And without claiming the screen moved. A discarded fill puts no pixels
    -- anywhere, so `applied_scroll_y` must still describe what is on screen --
    -- it is what the caret's drift, the animation layer's placement and every
    -- interact request are all derived from, so a fill that wrote it on the way
    -- to being thrown away would put all three somewhere the reader is not.
    t.eq(applied_before, session.applied_scroll_y, "a discarded fill does not claim the view moved")

    -- A capture in flight for the position the reader has just panned away from
    -- must not land on top of them. `request_serial` cannot catch this: a pan
    -- issues no request, so nothing moves it, and before resident panning every
    -- scroll issued a capture so it always moved. Observed in a real session as
    -- scrolling to the top, seeing the top, and then being thrown back down to
    -- where the settle had been requested -- a sharp, internally consistent
    -- frame of the wrong part of the document, arriving late enough to win.
    do
      local superseded_before = live.superseded_by_pan or 0
      local uploads_at_start = uploads
      local requested, panned_to = inside(0), inside(0) - 100
      session.scroll_y = requested
      controller.refresh(session, { capture_scale = "device", capture_only = true })
      t.ok(pending ~= nil, "sanity: an ordinary settle capture is in flight")
      -- The reader pans away. No request is issued, by design -- that is the
      -- whole feature -- so the capture above is not stale by any existing test.
      session.scroll_y = panned_to
      t.eq(true, controller._try_pan(session), "sanity: the scroll away was a pan")
      complete_fill({ scrollY = requested })
      t.eq(uploads_at_start, uploads, "the frame for the position they left never reaches the terminal")
      t.eq(panned_to, session.scroll_y, "and cannot rewind the reader to where it was requested")
      t.eq(panned_to, session.applied_scroll_y, "nor claim the screen is showing that position")
      t.eq(superseded_before + 1, live.superseded_by_pan, "counted, since nothing else can see a pan happen")
    end

    -- A failed capture must release the slot too. This is the shape of the bug
    -- that would silently disable region fills for the rest of a session.
    session.scroll_y = inside(2)
    controller.refresh(session, controller._settle_options(session))
    t.eq(true, live.fill.in_flight, "a fill is in flight")
    local notified = pending.callback
    pending = nil
    -- This one is *meant* to fail, and the notification it produces is
    -- indistinguishable at a glance from a test that broke. Swallowed so the
    -- suite's output still means what it says.
    local real_notify = vim.notify
    vim.notify = function() end
    notified(nil, "renderer exploded")
    vim.notify = real_notify
    t.eq(false, live.fill.in_flight, "and a failed capture gives the slot back rather than keeping it forever")
    session.render_failed = false

    -- Every other way a fill can fail to become a slice, counted -- because six
    -- of them on a real session were not, and the only sign was `fills` sitting
    -- above what was held with `stale`, `abandoned` and `evictions` all at zero.
    do
      -- A newer request superseded this one before it came back. Counted apart
      -- from `stale_fills`, which this used to increment: the two checks that
      -- raise `stale_fills` run *after* `live.fills`, so everything they count
      -- is a fill the total contains. This one never reaches that statement, and
      -- folding it in made `stale_fills` a population `fills` does not include.
      live.upload_hold_until, live.fill.in_flight = 0, false
      session.scroll_y = inside(2)
      controller.refresh(session, controller._settle_options(session))
      t.eq(true, live.fill.in_flight, "sanity: a fill is in flight to supersede")
      local fills_before, stale_before2, superseded_before = live.fills, live.stale_fills, live.superseded_fills
      local superseded_callback = pending.callback
      pending = nil
      -- What a newer request of any kind does to an older one, through the same
      -- serial `renderer.is_stale` compares -- rather than hand-calling the
      -- controller's callback with a staleness flag it would never see, which
      -- would be asserting about a signature instead of about the behaviour.
      session.request_serial = session.request_serial + 1
      superseded_callback(nil, nil)
      t.eq(superseded_before + 1, live.superseded_fills, "a capture superseded before it landed is counted as that")
      t.eq(stale_before2, live.stale_fills, "not as a stale fill, which would be a term outside its own total")
      t.eq(fills_before, live.fills, "and never as a fill, since it never got as far as being one")
      t.eq(false, live.fill.in_flight, "with the slot released")

      -- And the expensive one: the pixels crossed the wire and the backend
      -- would not put them on screen. It was the single path out of the fill
      -- branch with no counter on it at all.
      live.upload_hold_until, live.fill.in_flight = 0, false
      session.scroll_y = inside(2)
      controller.refresh(session, controller._settle_options(session))
      local real_update = session.backend.update
      session.backend.update = function() return nil, "the terminal refused it" end
      local undisplayed_before, held_before = live.undisplayed_fills, #resident.slice_records(live)
      local real_notify = vim.notify
      vim.notify = function() end
      complete_fill()
      vim.notify = real_notify
      session.backend.update = real_update
      session.render_failed = false
      t.eq(undisplayed_before + 1, live.undisplayed_fills, "a fill the backend would not display is counted")
      t.eq(held_before, #resident.slice_records(live), "and does not become a slice")
      t.eq(false, live.fill.in_flight, "with the slot released, as every route out of the callback must")
    end

    -- The boundaries are the document's, not the reader's, and a fill does not
    -- move them. This is what the bounded region could not do and what the whole
    -- rebuild is for: there used to be an adaptive byte cap here that ratcheted
    -- every later region's height down, which -- being a second limit on the
    -- same quantity as the budget, in different units -- always bound first and
    -- silently overrode it. Regions ended up at 43% of their allowed height,
    -- leaving about a third of a screen of travel, so nearly every scroll
    -- missed and refilled: 25% *more* traffic than sending a frame every time.
    -- A grid has no such knob, and a huge PNG must not create one.
    live.upload_hold_until = 0
    session.scroll_y = inside(2)
    local boundaries_before = {}
    for index = 0, grid.count - 1 do
      boundaries_before[index] = slice_at(index).doc_y
    end
    controller.refresh(session, controller._settle_options(session))
    local asked_at = pending.params.captureRegion
    session.scroll_y = inside(2)
    complete_fill({ pngBytes = 6000000 })
    t.eq(grid, live.grid, "a fill does not re-derive the grid, however large its PNG turned out to be")
    for index = 0, grid.count - 1 do
      t.eq(boundaries_before[index], slice_at(index).doc_y, ("slice %d starts where it always did"):format(index))
    end
    live.upload_hold_until = 0
    session.scroll_y = inside(2)
    t.eq(
      nil,
      controller._settle_options(session).capture_region,
      "and a slice already held is never asked for again, whatever it cost"
    )
    session.scroll_y = inside(4)
    t.eq(
      asked_at.heightPx,
      controller._settle_options(session).capture_region.heightPx,
      "while the next slice along is the same height as every other one"
    )

    -- ------------------------------------------------------------------
    -- The idle-time prefetch: everything it is not allowed to do.
    --
    -- It shares the one fill slot with the settle, and it spends wire on a
    -- guess. Both of those make the list of reasons to decline the interesting
    -- part -- each entry below is a way this could quietly become the thing the
    -- grid was built to remove.
    -- ------------------------------------------------------------------
    do
      require("md-viewer.debounce").close(session, "scroll_settle_timer")
      require("md-viewer.debounce").close(session, "resident_prefetch_timer")
      live.upload_hold_until, live.fill.in_flight = 0, false
      session.scroll_render_in_flight, session.scroll_render_pending = false, false
      session.selection_active, session.find_active, session.pointer = false, false, nil
      -- The reader is on slice 0, which is held; slice 1 is held from the
      -- composite above. So the nearest thing to guess at is slice 2.
      session.scroll_y = inside(0)
      live.memory_px = 8000000 * 8
      local abandoned_at_prefetch = live.abandoned_fills

      -- With the link rate stated, because it is the only way this number is
      -- ever right: timing the write measures the pty buffer rather than the
      -- tunnel -- the sample above was discarded for exactly that -- so without
      -- a stated rate the hold falls back to the settle delay and the
      -- anti-backlog rule is never really exercised at all.
      local restore_link = vim.deepcopy(config.get())
      config.setup(vim.tbl_deep_extend("force", vim.deepcopy(restore_link), {
        render = { ssh_link_bytes_per_sec = 800000 },
      }))

      local target = resident.next_prefetch(live, grid, 0)
      t.ok(target ~= nil, "sanity: some slice of this grid is still unfilled")
      t.eq(nil, resident.hold(live, target), "and it is one nothing has reached")

      local before = requests
      controller._prefetch_slice(session)
      t.eq(before + 1, requests, "with the wire idle and the reader settled, a prefetch is issued")
      t.eq(target, live.fill.slice_index, "for the nearest slice nobody has reached")
      t.eq(slice_at(target).doc_y, pending.params.captureRegion.yPx, "at that slice's own fixed rectangle")
      t.eq(true, live.fill.prefetch, "recorded as a guess rather than as something someone waited on")

      -- The reader has not moved, so this capture is of somewhere they are not
      -- looking. That is the whole point, and it is why a prefetch is
      -- transmitted rather than displayed: the coverage test an ordinary fill
      -- runs would discard every prefetch ever taken as overtaken.
      local prefetched_before, uploaded_ids = live.prefetches, {}
      session.backend.upload = function(_)
        uploaded_ids[#uploaded_ids + 1] = 5252
        return 5252, { bytes = 810000, width_px = 1980, height_px = 4080 }
      end
      local screen_before, applied_before = session.image_id, session.applied_scroll_y
      session.scroll_y = inside(0)
      complete_fill()
      t.eq(prefetched_before + 1, live.prefetches, "and counted as one once it lands")
      t.eq(1, #uploaded_ids, "transmitted through the upload path rather than shown")
      t.ok(resident.hold(live, target) ~= nil, "leaving the slice held like any other")
      t.eq(false, resident.hold(live, target).placed, "but not on screen")
      t.eq(screen_before, session.image_id, "so the frame the reader is looking at is untouched")
      t.eq(applied_before, session.applied_scroll_y, "and the position it shows is not claimed to have moved")
      t.eq(0, live.abandoned_fills - abandoned_at_prefetch, "and it is not discarded as overtaken")

      -- 810,000 bytes at the stated 800 B/ms is 1,012 ms of wire, and it is held
      -- for all of it. The cap of twice the settle delay bounds a rate this
      -- module inferred; a stated one is a fact about the link, so the transfer
      -- time computed from it is how long the wire is actually busy and cutting
      -- it short does not make the bytes arrive sooner -- it resumes sending on
      -- top of them. The point is that it is not the 160 ms default and not the
      -- zero a fabricated rate produces: the payload is genuinely still
      -- crossing, and this is the window in which nothing else may be sent.
      t.eq(1012, live.upload_hold_ms, "the hold is the whole transfer at the rate the operator stated")
      t.ok(live.upload_hold_until > vim.uv.now(), "and engages, where a rate inferred from a buffered write did not")
      t.eq("configured", live.link_rate_source, "and records which of the three kinds of number it used")
      config.setup(restore_link)

      -- With no rate stated there is nothing to size a hold from, and the reader
      -- has to be told once. Nothing is failing -- that is the whole difficulty:
      -- the preview just falls further behind, so nobody thinks to open a health
      -- report. md-viewer cannot fill the gap itself either; `nvim_ui_send`
      -- queues into Neovim and returns, so from here a slow link and a fast one
      -- are indistinguishable (see `resident.link_rate`).
      do
        local real_notify = vim.notify
        local notices = {}
        vim.notify = function(message, level) notices[#notices + 1] = { message = message, level = level } end
        controller._forget_link_rate_warning()
        controller._hold_wire(session, 810000, 0)
        t.eq("unobservable", live.link_rate_source, "an unconfigured link is reported as one nobody can see")
        t.eq(160, live.upload_hold_ms, "so the hold falls back to the settle delay rather than the 2 ms it computed")
        t.eq(1, #notices, "and the reader is told, once")
        -- Read through a default rather than indexed directly: `t.eq` records a
        -- failure and carries on, so indexing an empty list here would crash the
        -- whole run and hide the assertion above that actually diagnosed it.
        local notice = notices[1] or { message = "", level = nil }
        t.eq(vim.log.levels.WARN, notice.level, "as a warning, because it costs them something")
        t.ok(notice.message:match("scripts/ssh%-link%-speed%.sh"), "naming the script that measures the link")
        t.ok(notice.message:match("render%.ssh_link_bytes_per_sec"), "and the key the answer goes in")

        -- Once per session, not once per payload: this fires from the upload
        -- path, and a document being warmed sends one of these per slice.
        controller._hold_wire(session, 810000, 0)
        t.eq(1, #notices, "and not again on the next upload over the same link")
        vim.notify = real_notify
        live.upload_hold_until = 0
      end

      -- Now the refusals, each checked against a request count that must not move.
      live.upload_hold_until = 0
      local function refuses(label)
        local requests_at = requests
        controller._prefetch_slice(session)
        t.eq(requests_at, requests, label)
      end

      -- The wire. A guess queued behind a draining slice rebuilds the very
      -- backlog the one-payload invariant exists to prevent.
      live.upload_hold_until = vim.uv.now() + 5000
      refuses("a prefetch waits for the wire rather than queueing behind a draining slice")
      live.upload_hold_until = 0

      -- The slot. It is shared with the settle, and the settle is filling
      -- something somebody is looking at.
      live.fill.in_flight = true
      refuses("and waits for the fill slot rather than competing for it")
      live.fill.in_flight = false

      -- The reader. A slice missing under them is the settle's to fill, and
      -- taking the slot from it would be exactly backwards.
      local reader_slice = resident.hold(live, 0)
      live.slices[0], live.resident_px = nil, live.resident_px - reader_slice.image_w * reader_slice.image_h
      refuses("and never runs while the slice under the reader is missing")
      assert(resident.register(live, 0, reader_slice))

      -- The ceiling. This is the one that matters most: a prefetch that evicts
      -- uploads a slice, drops one the reader may return to, and pays for both
      -- again -- which is the churn the grid removed, brought back on a guess.
      local evictions_at = live.evictions
      live.memory_px = live.resident_px
      refuses("and never prefetches into a full ceiling")
      t.eq(evictions_at, live.evictions, "so it evicts nothing to make room for a slice nobody asked for")
      live.memory_px = 8000000 * 8

      -- Browser-painted state, for the reason a settle refuses a fill: a slice
      -- captured with a highlight in it keeps that highlight for as long as the
      -- terminal holds it.
      session.find_active = true
      refuses("nor while a search is painted into the document")
      session.find_active = false
      session.selection_active = true
      refuses("nor while a selection is")
      session.selection_active = false
      session.pointer = { pressed = true }
      refuses("nor mid-drag")
      session.pointer = nil

      live.fallback_reason = "test"
      refuses("and not at all once the session has fallen back")
      live.fallback_reason = nil
      require("md-viewer.debounce").close(session, "scroll_settle_timer")

      -- Warm-up: the same prefetch, driven as a phase rather than as something
      -- that happens when the reader remembers to pause. Left to itself a slice
      -- is only captured when somebody scrolls onto it, so the document fills in
      -- behind the reader and every screen they have not visited costs a frame.
      -- One measured session spent 16.2 MB on moving frames it threw away
      -- against 11.9 MB of slices it kept.
      do
        local grid = assert(controller._resident_grid(session))
        local fits = select(1, resident.slices_that_fit(grid, live.memory_px))
        t.ok(fits >= 2, "sanity: this ceiling holds more than one slice, so there is a warm-up to have")
        t.ok(controller._warming(session), "a document with slices still to fill is warming")

        -- What the reader sees while it happens, and it is a count rather than a
        -- spinner: the question they have is "how much longer", and a count
        -- answers it where a spinner does not.
        controller._refresh_warm_progress(session)
        t.eq(
          ("%d/%d"):format(#resident.slice_records(live), fits),
          session.warm_progress,
          "and says how far along it is"
        )

        -- Completion is what the ceiling can hold, not what the grid contains. A
        -- document larger than image.resident_memory_mb never reaches every
        -- slice, and a warm-up that could not finish would be an indicator that
        -- never goes away and a suppression rule that never lifts.
        local held, ceiling_at = #resident.slice_records(live), live.memory_px
        live.memory_px = held * resident.slice_cost_px(grid)
        t.eq(false, controller._warming(session), "a document that has filled the ceiling has finished warming")
        controller._refresh_warm_progress(session)
        t.eq(nil, session.warm_progress, "so the indicator goes away rather than counting to a total it cannot reach")
        live.memory_px = ceiling_at

        -- And the off switch, because this is a visible behaviour change.
        local restore_warm = vim.deepcopy(config.get())
        local warm_off = vim.deepcopy(config.get())
        warm_off.image.warm_document = "off"
        config.setup(warm_off)
        t.eq(false, controller._warming(session), "image.warm_document = off means no warm-up at all")
        config.setup(restore_warm)
        t.ok(controller._warming(session), "and turning it back on resumes one")
        controller._refresh_warm_progress(session)
      end
    end

    -- A drag's clean base and an interact frame both replace whatever is on
    -- screen, and what is on screen may be a resident region. Freeing it there
    -- would leave the cache holding an id the terminal has been told to forget,
    -- and the next pan would fail on an image nobody owns. The retention is
    -- derived inside `apply_image` rather than asked of each caller, because the
    -- image being replaced is either one the cache holds or nothing to anyone --
    -- there is no third case, and two of the five callers had already forgotten.
    session.base_selection_painted = true
    session.clean_image_bytes = "clean"
    session.clean_image_scale = "device"
    session.clean_image_scroll_y = session.applied_scroll_y
    session.clean_image_revision = session.renderer_revision
    local updates_before = #update_opts
    t.eq(true, controller.restore_clean_base(session), "a drag's clean base can be laid over a resident region")
    t.ok(#update_opts > updates_before, "sanity: the restore reached the backend")
    t.eq(true, update_opts[#update_opts].retain_superseded, "without freeing the region's pixels to do it")

    -- A pan is not just a placement: the overlays around it were measured
    -- against geometry that has just moved. The caret is re-derived from
    -- `applied_scroll_y` and the animation layer is placed from it, so both have
    -- to be told -- in the order a new frame already establishes.
    local animation = require("md-viewer.animation")
    local real_repaint = animation.repaint
    local repaints = 0
    animation.repaint = function() repaints = repaints + 1 end
    session.base_selection_painted = false
    live.upload_hold_until = 0
    scroll_to(inside(0) - 200)
    t.eq(1, moves, "sanity: that scroll was a pan")
    t.eq(1, repaints, "a pan repaints the animation layer, which is placed from the position it just changed")
    animation.repaint = real_repaint

    preview.viewport = real_viewport
    require("md-viewer.debounce").close(session, "scroll_settle_timer")
    require("md-viewer.debounce").close(session, "resident_hold_timer")

    -- ------------------------------------------------------------------
    -- Off the screen is not out of the terminal.
    --
    -- Every reason a preview stops being drawn is temporary: a focusable float,
    -- a tab switch, a completion popup, a suspend. Before this the image was
    -- freed and re-uploaded on the way back, which for an ordinary frame is one
    -- viewport and for a resident region is several -- paid over the one link
    -- the region exists to spare.
    -- ------------------------------------------------------------------
    process.request = function()
      requests = requests + 1
      return 1
    end
    local hidden, freed_now = {}, {}
    session.backend.hide = function(image_id)
      hidden[#hidden + 1] = image_id
      return true, { bytes = 24 }
    end
    session.backend.clear = function(image_id)
      freed_now[#freed_now + 1] = image_id
      return true
    end

    live.upload_hold_until = 0
    resident.drain(live)
    live.key = controller._resident_key(session)
    grid = assert(controller._resident_grid(session))
    local held = make_slice(0, 5151)
    assert(resident.register(live, 0, held))
    held.placed = true
    session.image_id = 5151
    session.scroll_y = inside(0)
    uploads, moves, requests = 0, 0, 0

    local rect = preview.placement(session.preview_win, "kitty_raw")
    local cover_buf = vim.api.nvim_create_buf(false, true)
    local cover_win = vim.api.nvim_open_win(cover_buf, false, {
      relative = "editor",
      row = rect.row,
      col = rect.col,
      width = math.min(10, rect.width),
      height = math.min(3, rect.height),
      style = "minimal",
    })
    t.eq(true, (preview.occlusion(session.preview_win)), "sanity: the float genuinely occludes the preview")
    controller.refresh(session)
    t.eq({ 5151 }, hidden, "a float over the preview hides the region's placements")
    t.eq({}, freed_now, "and leaves its pixels in the terminal")
    t.eq(1, #resident.slice_records(live), "the grid still holds it")
    t.eq(false, held.placed, "recorded as resident but not on screen")

    -- And back. This is the fourth cache state the design calls
    -- resident-but-unplaced: not a hit to pan within, not a miss to capture, but
    -- a region that simply needs putting back.
    local unplaced_before = live.unplaced_places
    vim.api.nvim_win_close(cover_win, true)
    t.ok(vim.wait(500, function() return session.image_id ~= nil end, 10), "closing it puts the preview back")
    t.eq(5151, session.image_id, "as the same image the terminal never stopped holding")
    t.eq(0, uploads, "costing no upload at all")
    t.eq(0, requests, "and no capture")
    t.eq(1, moves, "one placement command, which is the whole bill")
    t.eq(unplaced_before + 1, live.unplaced_places, "counted as a re-place rather than a pan")
    t.eq(true, held.placed, "and on screen again")

    -- The distinction the whole thing turns on: hiding is not freeing, and the
    -- paths that end a session's claim on the pixels must still free them.
    hidden, freed_now = {}, {}
    controller.free_resident(session)
    t.eq({ 5151 }, freed_now, "giving up a session's slices frees them for real")
    t.eq({}, hidden, "hiding is never a substitute for that")
    t.eq(0, #resident.slice_records(live), "and nothing is held")

    -- ------------------------------------------------------------------
    -- Refusals, and where they land.
    --
    -- The whole feature is an optimization over a path that already works, so
    -- every way it can decline has exactly one correct destination: the
    -- behaviour that existed before it. The only question each refusal answers
    -- is whether to try again.
    -- ------------------------------------------------------------------
    process.request = function(_, params, callback)
      requests = requests + 1
      pending = { params = params, callback = callback }
      return 1
    end
    local function refuse_region(reason)
      local callback = pending.callback
      pending = nil
      callback(nil, reason, { code = "REGION_TOO_LARGE" })
    end

    -- A slice Chromium will not capture means the *slice height* is beyond it,
    -- so the answer is a whole new grid at a shorter height rather than one
    -- shorter slice. Slice height and boundary position are the same fact: a
    -- grid whose slices are not all the same height has no single overlap, and a
    -- viewport straddling one of its boundaries would have no row to split on.
    live.slice_scale, live.slice_shrinks = 1, 0
    live.memory_px, live.upload_hold_until = 8000000 * 4, 0
    live.enabled, live.fallback_reason = true, nil
    live.grid = nil
    resident.drain(live)
    live.key = controller._resident_key(session)
    grid = assert(controller._resident_grid(session))
    assert(resident.register(live, 0, make_slice(0, 6161)))
    session.render_failed = false
    session.scroll_y = inside(1)
    controller.refresh(session, controller._settle_options(session))
    local asked_for = pending.params.captureRegion.heightPx
    local requests_before, generation_at_refusal = requests, live.generation
    refuse_region("capture region of 1980x40000 device px exceeds the safe ceiling")
    t.eq(resident.SLICE_SHRINK, live.slice_scale, "a slice Chromium will not capture is retried a quarter shorter")
    t.eq(1, live.slice_shrinks, "once, and recorded as once")
    t.ok(live.generation > generation_at_refusal, "the grid is regenerated rather than patched")
    t.eq(0, #resident.slice_records(live), "so everything of the old generation goes back to the terminal")
    t.ok(vim.tbl_contains(freed_now, 6161), "by being freed, not merely forgotten")
    t.eq(false, session.render_failed, "and not reported as a render failure -- the frame on screen is untouched")
    t.eq(nil, live.fallback_reason, "with the feature still on")
    t.ok(
      vim.wait(500, function() return requests > requests_before end, 5),
      "retried straight away rather than waiting for the reader to scroll again"
    )
    local retried = pending.params.captureRegion.heightPx
    t.ok(retried < asked_for, "asking for less of the document than last time")
    t.ok(retried > 1020, "but still more than a viewport, or no slice could ever be a hit")
    -- Every slice of the new grid, not just the one being asked for. A halving
    -- applied per fill would leave a grid of mixed heights, which is the shape
    -- with no overlap invariant left.
    local shrunk = assert(controller._resident_grid(session))
    for index = 0, shrunk.count - 2 do
      t.eq(retried, resident.slice(shrunk, index).doc_h, ("slice %d is the new height too"):format(index))
    end

    -- A second refusal is not a size problem. No third size is tried: the
    -- geometry is outside what this Chromium will capture at all, and a smaller
    -- number would only rediscover that on every settle for the rest of the day.
    refuse_region("still too large")
    t.ok(live.fallback_reason ~= nil, "a second refusal gives up for the rest of the session")
    t.ok(live.fallback_reason:find("twice", 1, true) ~= nil, "saying it had already tried")
    t.eq(false, live.enabled, "so nothing tries again")
    t.eq(0, #resident.slice_records(live), "and the terminal gets its pixels back")

    -- And when the shorter grid does not fit either, the refusal has to say so
    -- rather than quietly planning nothing on every settle from then on. A
    -- ceiling below one slice is the way there: no grid whose slices cannot be
    -- held is worth capturing.
    live.enabled, live.fallback_reason = true, nil
    live.slice_scale, live.slice_shrinks = 1, 0
    live.grid, live.upload_hold_until = nil, 0
    session.scroll_y = inside(1)
    controller.refresh(session, controller._settle_options(session))
    live.memory_px = 1000
    refuse_region("capture region of 1980x40000 device px exceeds the safe ceiling")
    t.eq(false, live.enabled, "one refusal is final when no smaller grid can be held either")
    t.ok(
      live.fallback_reason:find("no smaller grid fits", 1, true) ~= nil,
      "and the reason names that, not just the refusal that started it"
    )
    t.ok(
      live.fallback_reason:find("ceiling", 1, true) ~= nil,
      "carrying the grid's own words for why nothing smaller fits"
    )

    -- The destination.
    require("md-viewer.debounce").close(session, "scroll_settle_timer")
    scroll_to(500)
    t.eq(0, moves, "scrolling after a fallback never pans")
    t.ok(requests > 0, "it captures, exactly as it did before any of this existed")
    require("md-viewer.debounce").close(session, "scroll_settle_timer")

    process.request = real_request

    controller.close(source)
    pcall(vim.api.nvim_set_current_win, entry_win)
  end
end
