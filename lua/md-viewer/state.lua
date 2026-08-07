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
    tabpage_hidden = false,
    refresh_deferred = false,
    ui_suppressed = false,
    ui_poll_timer = nil,
    loading = false,
    loading_win = nil,
    loading_buf = nil,
    loading_timer = nil,
    loading_frame = 0,
    render_failed = false,
    obsolete_files = {},
    -- Selection/find display state, distinct from the button-scoped
    -- `session.pointer` gesture state: it must survive focus changes (a
    -- pointer press does not), so it is never touched by the
    -- TabLeave/VimSuspend autocmd that clears `pointer` via
    -- interaction.forget().
    selection_active = false,
    selection_content_revision = nil,
    selection_text_length = nil,
    selection_render_in_flight = false,
    selection_render_pending = false,
    selection_debounce_timer = nil,
    selection_settle_timer = nil,
    -- Documents this preview has followed links through, oldest first, and
    -- where in that list it currently sits. Entry 1 is the document the
    -- preview was opened on; `M.retarget` appends, and md-viewer.controller's
    -- back/forward walk the index without appending.
    history = nil,
    history_index = 0,
    find_active = false,
    find_query = nil,
    find_match_count = 0,
    find_active_index = nil,
    -- Diagnostics-only counters (:MdViewerDebug): every `interact` request sent
    -- for this session, how many of those came back STALE_INTERACTION (lost a
    -- race against a newer request), and how many in-flight drag updates were
    -- superseded by a newer pointer position before they were ever sent.
    interaction_request_count = 0,
    interaction_stale_count = 0,
    coalesced_drag_events = 0,
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
    if
      session.preview_win
      and vim.api.nvim_win_is_valid(session.preview_win)
      and vim.api.nvim_win_get_tabpage(session.preview_win) == tab
    then
      return session
    end
  end
end

---Re-key `session` onto `new_buf`, so one preview window can follow a link to
---another document instead of being torn down and rebuilt. Sessions are keyed
---by source buffer and `document_id` is derived from it, so both move together
---or neither does.
---
---Refuses (returns nil) when `new_buf` already owns a session: that preview is
---the legitimate owner of the buffer and silently stealing it would leave two
---sessions believing they render the same document.
function M.retarget(session, new_buf)
  if not session or new_buf == session.source_buf then return nil end
  if sessions[new_buf] then return nil end
  sessions[session.source_buf] = nil
  session.source_buf = new_buf
  session.document_id = "buffer-" .. new_buf
  sessions[new_buf] = session
  return session
end

function M.remove(source_buf)
  local value = sessions[source_buf]
  sessions[source_buf] = nil
  return value
end

function M.all() return sessions end

return M
