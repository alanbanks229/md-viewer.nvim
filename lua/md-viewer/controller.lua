local backends = require("md-viewer.backends")
local config = require("md-viewer.config")
local preview = require("md-viewer.preview")
local coordinates = require("md-viewer.coordinates")
local renderer = require("md-viewer.renderer")
local state = require("md-viewer.state")
local sync = require("md-viewer.sync")
local process = require("md-viewer.process")
local debounce = require("md-viewer.debounce")
local navigation = require("md-viewer.navigation")
local mouse = require("md-viewer.mouse")

local M = {}
local group
local start_ui_poll

local function valid(session)
  return session
    and not session.closed
    and type(session.source_buf) == "number"
    and type(session.preview_buf) == "number"
    and type(session.preview_win) == "number"
    and vim.api.nvim_buf_is_valid(session.source_buf)
    and vim.api.nvim_buf_is_valid(session.preview_buf)
    and vim.api.nvim_win_is_valid(session.preview_win)
end

local function markdown(session) return table.concat(vim.api.nvim_buf_get_lines(session.source_buf, 0, -1, false), "\n") end

local function notify_error(message) vim.notify("md-viewer: " .. tostring(message), vim.log.levels.ERROR) end

local function current_session(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  return state.get(buf)
    or state.from_preview(buf)
    or state.from_source_win(vim.api.nvim_get_current_win())
    or state.visible_in_tab()
end

local function clear_image(session)
  if session.image_id and session.backend then session.backend.clear(session.image_id) end
  session.image_id = nil
  session.last_placement = nil
end

local function update_occlusion(session)
  if not valid(session) or session.backend.name == "cells" then return false end
  local blocked, windows = preview.occlusion(session.preview_win)
  session.occluded = blocked
  session.occluding_windows = windows
  return blocked or session.ui_suppressed
end

local function show_cached(session)
  if not valid(session) or session.backend.name == "cells" or not session.last_image_bytes then return false end
  if update_occlusion(session) then
    clear_image(session)
    return false
  end
  preview.stop_loading(session)
  preview.reset_surface(session)
  local placement = preview.placement(session.preview_win, session.backend.name)
  local ok, image_id, image_err = pcall(session.backend.show, session.last_image_bytes, placement)
  if not ok or not image_id then
    session.render_failed = true
    notify_error(ok and (image_err or "failed to display cached image") or image_id)
    return false
  end
  session.image_id = image_id
  session.last_placement = placement
  return true
end

function M.refresh(session, render_options)
  local explicit = session == nil
  session = session or current_session()
  if not valid(session) then return end
  if explicit then session.render_epoch = (session.render_epoch or 0) + 1 end
  if session.backend.name == "cells" then
    session.backend.render(session.preview_buf, markdown(session))
    if render_options and render_options.on_complete then render_options.on_complete(false, nil) end
    return
  end
  session.render_failed = false
  if update_occlusion(session) then
    clear_image(session)
    if render_options and render_options.on_complete then render_options.on_complete(false, nil) end
    return
  end
  renderer.request(session, markdown(session), render_options, function(result, err, stale)
    local function finish()
      if render_options and render_options.on_complete then render_options.on_complete(stale, err) end
    end
    if not valid(session) then
      finish()
      return
    end
    if stale then
      finish()
      return
    end
    if err then
      session.render_failed = true
      preview.stop_loading(session)
      notify_error(err)
      finish()
      return
    end
    local meta = result.metadata
    local newer_scroll_pending = render_options and render_options.scroll_frame and session.scroll_render_pending
    session.latest_blocks = meta.blocks
    session.document_height_px = meta.documentHeightPx
    session.viewport_height_px = meta.viewportHeightPx
    -- Preserve a newer requested position while showing this completed frame.
    -- The next capture then uses the desired position instead of snapping back
    -- to the older frame's scrollY.
    if not newer_scroll_pending then session.scroll_y = meta.scrollY end
    session.applied_scroll_y = meta.scrollY
    session.last_layout_reused = meta.layoutReused == true
    session.last_markdown_reused = meta.markdownReused == true
    session.last_capture_scale = meta.captureScale
    session.last_png_bytes = meta.pngBytes or #result.image
    session.last_layout_ms = meta.layoutMs
    session.last_capture_ms = meta.captureMs
    session.viewport_width_px = result.viewport.widthPx
    session.viewport_height_render_px = result.viewport.heightPx
    session.viewport_calibration_tier = result.viewport.tier
    session.last_image_bytes = result.image
    if update_occlusion(session) then
      clear_image(session)
      finish()
      return
    end
    preview.stop_loading(session)
    preview.reset_surface(session)
    local placement = preview.placement(session.preview_win, session.backend.name)
    session.preview_width_cells = placement.width
    session.preview_height_cells = placement.height
    local image_started = vim.uv.hrtime()
    local ok, image_id, image_err = pcall(function()
      if session.image_id then return session.backend.update(session.image_id, result.image, placement) end
      return session.backend.show(result.image, placement)
    end)
    if not ok or not image_id then
      session.render_failed = true
      notify_error(ok and (image_err or "failed to display rendered image") or image_id)
      finish()
      return
    end
    session.last_image_update_ms = (vim.uv.hrtime() - image_started) / 1000000
    if meta.captureScale == "css" then
      session.fast_png_bytes = session.last_png_bytes
      session.fast_capture_ms = session.last_capture_ms
      session.fast_image_update_ms = session.last_image_update_ms
    else
      session.retina_png_bytes = session.last_png_bytes
      session.retina_capture_ms = session.last_capture_ms
      session.retina_image_update_ms = session.last_image_update_ms
    end
    session.image_id = image_id
    session.last_placement = placement
    finish()
  end)
end

function M.schedule(session, delay, timer_name, render_options)
  if not valid(session) then return end
  debounce.call(session, timer_name or "render_timer", delay or config.get().render.debounce_ms, function()
    if valid(session) then M.refresh(session, render_options) end
  end)
end

function M.schedule_scroll(session)
  local render = config.get().render
  local fast_scale = render.fast_scroll and "css" or "device"
  if session.scroll_render_in_flight then
    session.scroll_render_pending = true
    session.coalesced_scroll_events = (session.coalesced_scroll_events or 0) + 1
  else
    session.scroll_render_in_flight = true
    M.refresh(session, {
      capture_scale = fast_scale,
      capture_only = true,
      scroll_frame = true,
      on_complete = function()
        session.scroll_render_in_flight = false
        if not valid(session) then return end
        if session.scroll_render_pending then
          session.scroll_render_pending = false
          -- One capture at a time is sufficient backpressure. Continue with
          -- the newest position on the next event-loop turn; capture and
          -- terminal transmission provide the natural pacing.
          vim.schedule(function()
            if valid(session) then M.schedule_scroll(session) end
          end)
        end
      end,
    })
  end
  if render.fast_scroll then
    M.schedule(session, render.scroll_settle_ms, "scroll_settle_timer", {
      capture_scale = "device",
      capture_only = true,
    })
  end
end

local function schedule_source_scroll(session, delay)
  debounce.call(session, "cursor_scroll_timer", delay, function()
    if valid(session) then M.schedule_scroll(session) end
  end)
end

local function close_session(session)
  if not session or session.closed then return end
  session.closed = true
  session.request_serial = session.request_serial + 1
  for _, name in ipairs({
    "render_timer",
    "resize_timer",
    "scroll_settle_timer",
    "cursor_scroll_timer",
    "ui_poll_timer",
  }) do
    debounce.close(session, name)
  end
  preview.stop_loading(session)
  clear_image(session)
  session.last_image_bytes = nil
  state.remove(session.source_buf)
  if session.preview_win and vim.api.nvim_win_is_valid(session.preview_win) then
    pcall(vim.api.nvim_win_close, session.preview_win, true)
  end
  if not next(state.all()) then process.stop() end
  mouse.detach_if_unused()
end

function M.close(buf)
  local session = current_session(buf)
  close_session(session)
end

function M.close_all()
  local copy = {}
  for _, session in pairs(state.all()) do
    copy[#copy + 1] = session
  end
  for _, session in ipairs(copy) do
    close_session(session)
  end
  for _, name in ipairs({ "nvim_img", "kitty_raw" }) do
    backends.get(name).clear_all()
  end
  process.stop()
end

function M.open(position)
  local source_buf, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local existing = state.get(source_buf)
  if existing and valid(existing) then return existing end
  local pinned = state.from_source_win(source_win)
  if pinned and valid(pinned) then return pinned end
  if vim.bo[source_buf].buftype ~= "" then
    notify_error("open a normal Markdown buffer first")
    return
  end
  local backend, reason = backends.select()
  if not backend then
    notify_error(reason)
    return
  end
  local session = state.create(source_buf, source_win)
  session.backend, session.backend_reason = backend, reason
  session.preview_buf, session.preview_win = preview.open(position, session)
  if backend.name ~= "cells" then
    preview.start_loading(session)
    navigation.attach(session, M.navigate)
    mouse.attach(M.navigate)
  end
  vim.api.nvim_set_current_win(source_win)
  M.refresh(session)
  if start_ui_poll then start_ui_poll(session) end
  return session
end

function M.toggle(position)
  local session = current_session()
  if session then
    close_session(session)
  else
    M.open(position)
  end
end

function M.navigate(session, action)
  if not valid(session) or session.backend.name == "cells" then return end
  local cfg = config.get()
  local maximum = math.max(0, session.document_height_px - session.viewport_height_px)
  local deltas = {
    line_down = cfg.sync.navigation_line_px,
    line_up = -cfg.sync.navigation_line_px,
    half_down = session.viewport_height_px * 0.5,
    half_up = -session.viewport_height_px * 0.5,
    page_down = session.viewport_height_px * 0.9,
    page_up = -session.viewport_height_px * 0.9,
    wheel_down = cfg.sync.navigation_line_px * cfg.sync.mouse_scroll_lines,
    wheel_up = -cfg.sync.navigation_line_px * cfg.sync.mouse_scroll_lines,
  }
  local next_scroll
  if action == "top" then
    next_scroll = 0
  elseif action == "bottom" then
    next_scroll = maximum
  else
    next_scroll = (session.scroll_y or 0) + (deltas[action] or 0)
  end
  next_scroll = math.max(0, math.min(maximum, next_scroll))
  if math.abs(next_scroll - (session.scroll_y or 0)) < 1 then return end
  session.scroll_y = next_scroll
  session.manual_scroll_until = vim.uv.now() + cfg.sync.manual_scroll_hold_ms
  if cfg.sync.preview_to_source then sync.update_source_from_scroll(session, next_scroll) end
  M.schedule_scroll(session)
end

local function each_session(fn)
  for _, session in pairs(state.all()) do
    if valid(session) then fn(session) end
  end
end

local function clear_raw_sessions()
  each_session(function(session)
    if session.backend.name == "kitty_raw" then clear_image(session) end
  end)
end

local function refresh_raw_sessions()
  each_session(function(session)
    if session.backend.name == "kitty_raw" and not session.ui_suppressed then
      if not show_cached(session) and not update_occlusion(session) then M.schedule(session, 0) end
    end
  end)
end

local function reconcile_placement(session, force)
  if session.backend.name ~= "kitty_raw" or not session.image_id or session.ui_suppressed then return end
  local placement = preview.placement(session.preview_win, session.backend.name)
  if not force and coordinates.same(session.last_placement, placement) then return end
  local ok, moved, err = pcall(session.backend.move, session.image_id, placement)
  if not ok then
    notify_error(moved)
    return
  end
  if not moved then
    notify_error(err or "failed to update image placement")
    return
  end
  session.last_placement = placement
end

local function reconcile_occlusion()
  each_session(function(session)
    if session.backend.name ~= "cells" then
      if update_occlusion(session) then
        clear_image(session)
      elseif not session.image_id then
        if not show_cached(session) then M.schedule(session, 0) end
      else
        reconcile_placement(session)
      end
    end
  end)
end

start_ui_poll = function(session)
  if session.backend.name ~= "kitty_raw" then return end
  local interval = math.max(0, math.floor(config.get().image.ui_poll_ms or 50))
  if interval == 0 or session.ui_poll_timer then return end
  local timer = vim.uv.new_timer()
  session.ui_poll_timer = timer
  timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      if valid(session) then
        if update_occlusion(session) then
          clear_image(session)
        elseif
          not session.image_id
          and not session.ui_suppressed
          and not session.loading
          and not session.render_failed
        then
          if not show_cached(session) then M.schedule(session, 0) end
        else
          reconcile_placement(session)
        end
      else
        debounce.close(session, "ui_poll_timer")
      end
    end)
  )
end

function M.setup_autocmds()
  group = vim.api.nvim_create_augroup("md-viewer", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    callback = function(args)
      local session = state.get(args.buf)
      if session then M.schedule(session) end
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(args)
      local session = state.get(args.buf)
      if session and config.get().sync.source_to_preview and config.get().sync.cursor_follow then
        local cfg = config.get().sync
        sync.source_cursor(
          session,
          function(value) schedule_source_scroll(value, cfg.cursor_debounce_ms) end,
          cfg.alignment_tolerance
        )
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function(args)
      local scrolled_win = tonumber(args.match)
      each_session(function(session)
        if scrolled_win == session.source_win and config.get().sync.source_to_preview then
          local cfg = config.get().sync
          sync.source_cursor(
            session,
            function(value) schedule_source_scroll(value, cfg.cursor_debounce_ms) end,
            cfg.alignment_tolerance
          )
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      each_session(function(session)
        if not update_occlusion(session) then M.schedule(session, 80, "resize_timer") end
      end)
      vim.schedule(reconcile_occlusion)
    end,
  })
  -- FocusGained covers the terminal-side transitions Neovim has no direct
  -- event for (alternate-screen returns, multiplexer pane/window switches):
  -- any of them can silently drop a raw Kitty placement, so treat regained
  -- focus the same as VimResume and recreate it from the cached PNG.
  vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter", "TabEnter", "VimResume", "FocusGained" }, {
    group = group,
    callback = function(args)
      local source_session = state.get(args.buf)
      if source_session and vim.api.nvim_get_current_buf() == args.buf then
        source_session.source_win = vim.api.nvim_get_current_win()
      end
      each_session(function(session)
        if
          not session.image_id
          and not session.ui_suppressed
          and not update_occlusion(session)
          and vim.api.nvim_win_get_tabpage(session.preview_win) == vim.api.nvim_get_current_tabpage()
        then
          if not show_cached(session) then M.schedule(session, 0) end
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufFilePost", {
    group = group,
    callback = function(args)
      local session = state.get(args.buf)
      if session then preview.update_title(session) end
    end,
  })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      -- Placement is screen-relative and must not depend on the active cursor.
      -- Intentionally retain normal split images across focus changes.
    end,
  })
  vim.api.nvim_create_autocmd({ "CompleteChanged" }, {
    group = group,
    callback = function()
      each_session(function(session)
        if session.backend.name == "kitty_raw" then session.ui_suppressed = true end
      end)
      clear_raw_sessions()
    end,
  })
  vim.api.nvim_create_autocmd({ "CompleteDone", "WinClosed" }, {
    group = group,
    callback = function(args)
      if args.event ~= "WinClosed" then
        each_session(function(session)
          if session.backend.name == "kitty_raw" then session.ui_suppressed = false end
        end)
      end
      vim.schedule(function()
        if args.event == "WinClosed" then
          reconcile_occlusion()
        else
          refresh_raw_sessions()
        end
      end)
    end,
  })
  -- The command-line reserves its own screen row(s) below every window, so
  -- unlike a real floating window it can never geometrically overlap the
  -- preview under normal Neovim layout. The one exception is `cmdheight = 0`,
  -- which temporarily shrinks the window above the command line for as long
  -- as it's open. Rather than hide the image for the whole time (blanking it
  -- on every `:`, `/`, or `?`), just re-place it at the placement's current
  -- geometry -- a no-op send when nothing changed, and a same-tick resize
  -- when it did, so the image stays visible and confined instead of
  -- disappearing. `force = true` bypasses the usual same-placement skip so a
  -- terminal that erases graphics on its own cmdline redraw gets them
  -- redrawn immediately rather than waiting for the next unrelated event.
  vim.api.nvim_create_autocmd({ "CmdlineEnter", "CmdlineLeave" }, {
    group = group,
    callback = function()
      each_session(function(session) reconcile_placement(session, true) end)
    end,
  })
  vim.api.nvim_create_autocmd("WinNew", {
    group = group,
    callback = function(args)
      vim.schedule(function()
        local win = tonumber(args.match)
        if win and vim.api.nvim_win_is_valid(win) then
          local win_config = vim.api.nvim_win_get_config(win)
          if win_config.relative ~= "" then reconcile_occlusion() end
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "ColorScheme" }, {
    group = group,
    callback = function()
      each_session(function(session) M.schedule(session, 0) end)
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "background",
    callback = function()
      each_session(function(session) M.schedule(session, 0) end)
    end,
  })
  vim.api.nvim_create_autocmd("BufHidden", {
    group = group,
    callback = function(args)
      local session = state.from_preview(args.buf)
      if not session and not config.get().preview.pinned then session = state.get(args.buf) end
      if session then close_session(session) end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      local session = state.get(args.buf) or state.from_preview(args.buf)
      if session then close_session(session) end
    end,
  })
  vim.api.nvim_create_autocmd({ "TabLeave", "VimSuspend" }, {
    group = group,
    callback = function()
      each_session(function(session)
        if session.image_id then
          session.backend.clear(session.image_id)
          session.image_id = nil
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.close_all })
end

return M
