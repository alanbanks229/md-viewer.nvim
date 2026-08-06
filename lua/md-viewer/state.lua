local M = {}
local sessions = {}

function M.create(source_buf, source_win)
  local session = {
    source_buf = source_buf,
    source_win = source_win,
    document_id = "buffer-" .. source_buf,
    preview_buf = nil,
    preview_win = nil,
    image_id = nil,
    backend = nil,
    request_serial = 0,
    applied_serial = 0,
    render_epoch = 0,
    renderer_revision = nil,
    latest_blocks = {},
    document_height_px = 0,
    viewport_height_px = 0,
    scroll_y = 0,
    applied_scroll_y = 0,
    sync_guard = false,
    closed = false,
    last_source_block = nil,
    manual_scroll_until = 0,
    render_timer = nil,
    scroll_settle_timer = nil,
    cursor_scroll_timer = nil,
    scroll_render_in_flight = false,
    scroll_render_pending = false,
    resize_timer = nil,
    last_image_bytes = nil,
    occluded = false,
    occluding_windows = {},
    ui_suppressed = false,
    ui_poll_timer = nil,
    loading = false,
    loading_win = nil,
    loading_buf = nil,
    loading_timer = nil,
    loading_frame = 0,
    render_failed = false,
    obsolete_files = {},
  }
  sessions[source_buf] = session
  return session
end

function M.get(source_buf) return sessions[source_buf] end

function M.from_preview(buf)
  for _, session in pairs(sessions) do
    if session.preview_buf == buf then return session end
  end
end

function M.from_preview_win(win)
  for _, session in pairs(sessions) do
    if session.preview_win == win then return session end
  end
end

function M.from_source_win(win)
  for _, session in pairs(sessions) do
    if session.source_win == win then return session end
  end
end

function M.visible_in_tab(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  for _, session in pairs(sessions) do
    if session.preview_win and vim.api.nvim_win_is_valid(session.preview_win)
      and vim.api.nvim_win_get_tabpage(session.preview_win) == tab then
      return session
    end
  end
end

function M.remove(source_buf)
  local value = sessions[source_buf]
  sessions[source_buf] = nil
  return value
end

function M.all() return sessions end

return M
