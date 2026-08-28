local M = {}
local sessions = {}
local panes = {}
local next_pane_id = 0

local function index_session(session)
  sessions[session.source_buf] = sessions[session.source_buf] or {}
  sessions[session.source_buf][session] = true
end

local function unindex_session(session, source_buf)
  local bucket = sessions[source_buf or session.source_buf]
  if not bucket then return end
  bucket[session] = nil
  if not next(bucket) then sessions[source_buf or session.source_buf] = nil end
end

local function first_session(bucket)
  if not bucket then return nil end
  for session in pairs(bucket) do
    if session.pane and session.pane.active == session then return session end
  end
  return next(bucket)
end

function M.create(source_buf, source_win)
  local session = {
    source_buf = source_buf,
    source_win = source_win,
    document_id = "buffer-" .. source_buf,
    preview_buf = nil,
    preview_win = nil,
    image_id = nil,
    -- What the frame `image_id` names is a picture of. Read by the resident
    -- bootstrap to decide whether the frame already on screen shows the
    -- reader's position, which is the difference between leaving correct pixels
    -- up and blanking the pane. Non-nil only while `image_id` is.
    frame_scroll_y = nil,
    frame_revision = nil,
    -- Whether a resident screen (one or two cropped bands) is placed. The
    -- resident path deliberately owns no `image_id`; see M.screen_up.
    resident_screen = false,
    backend = nil,
    request_serial = 0,
    applied_serial = 0,
    render_epoch = 0,
    renderer_revision = nil,
    latest_blocks = {},
    latest_lines = {},
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
    -- A render of the document's content is in flight, so md-viewer.controller's
    -- resident warm-up holds off: a chunk capture would stale it, and a staled
    -- content render is dropped with nothing to re-issue it.
    content_render_in_flight = false,
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
    -- Preview visual mode: a selection being extended from the caret rather
    -- than from the pointer. See md-viewer.interaction's visual_start.
    visual_active = false,
    visual_linewise = false,
    visual_columns = nil,
    -- The caret's glyph box, the scroll it was measured at, and the sticky
    -- column line motions aim at (Vim's `curswant`). See md-viewer.caret.
    caret_rect = nil,
    caret_scroll_y = nil,
    caret_desired_x = nil,
    -- *Which* character the caret is on, in the renderer's own character space,
    -- and the content revision that space belonged to. The box above is how the
    -- caret is drawn; this is where it is.
    caret_index = nil,
    caret_index_revision = nil,
    -- Which interaction last established the reader's position. Caret motions
    -- report the caret's visual line; scroll-only motions report the viewport
    -- midpoint until the caret is deliberately moved again.
    progress_basis = "viewport",
    last_progress_text = nil,
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
    -- race against a newer request), and how many in-flight selection-preview
    -- updates were superseded by a newer point before they were ever sent.
    interaction_request_count = 0,
    interaction_stale_count = 0,
    coalesced_preview_events = 0,
  }
  next_pane_id = next_pane_id + 1
  local pane = {
    id = next_pane_id,
    source_win = source_win,
    preview_win = nil,
    documents = { session },
    active = session,
    history = nil,
    history_index = 0,
    activation_epoch = 0,
    owned = true,
    closed = false,
  }
  session.pane = pane
  session.document_id = ("pane-%d-buffer-%d"):format(pane.id, source_buf)
  session.active = true
  panes[pane.id] = pane
  index_session(session)
  return session
end

function M.get(source_buf) return first_session(sessions[source_buf]) end

function M.documents_for_source(source_buf)
  local result = {}
  for session in pairs(sessions[source_buf] or {}) do
    result[#result + 1] = session
  end
  return result
end

---Return the document for `source_buf` in `pane`, if it is already open there.
function M.document(pane, source_buf)
  if not pane then return nil end
  for _, session in ipairs(pane.documents) do
    if session.source_buf == source_buf and not session.closed then return session end
  end
end

---Add a document-shaped session to an existing pane. The rendering fields are
---created by the same constructor as the first document, then the throwaway
---pane produced by that constructor is discarded.
function M.create_document(pane, source_buf)
  local session = M.create(source_buf, pane.source_win)
  panes[session.pane.id] = nil
  unindex_session(session)
  session.pane = pane
  session.document_id = ("pane-%d-buffer-%d"):format(pane.id, source_buf)
  session.active = false
  session.preview_win = pane.preview_win
  session.source_win = pane.source_win
  pane.documents[#pane.documents + 1] = session
  index_session(session)
  return session
end

---Is there a rendered screen on this pane right now, under either rendering
---model?
---
---`session.image_id` answers only for the viewport model. A resident screen is
---one or two cropped bands and deliberately owns no single frame id, because
---that field is also the id `clear_image` deletes and `apply_image` updates in
---place -- and a chunk must never be either. Freeing a chunk out from under
---`resident_session.images` would leave the next compose refusing an image the
---terminal no longer has; updating one in place would replace a chunk with a
---viewport frame.
---
---So callers that mean "is there something here to composite an overlay over"
---ask here. Callers that mean "the frame this session owns and may delete" want
---`session.image_id` itself and are right to keep using it.
function M.screen_up(session)
  if not session then return false end
  return session.image_id ~= nil or session.resident_screen == true
end

function M.from_preview(buf)
  for _, pane in pairs(panes) do
    for _, session in ipairs(pane.documents) do
      if session.preview_buf == buf then return session end
    end
  end
end

function M.from_preview_win(win)
  for _, pane in pairs(panes) do
    if pane.preview_win == win then return pane.active end
  end
end

function M.from_source_win(win)
  for _, pane in pairs(panes) do
    if pane.source_win == win then return pane.active end
  end
end

function M.set_source_window(session, win)
  if not session then return end
  session.source_win = win
  if not session.pane then return end
  session.pane.source_win = win
  for _, document in ipairs(session.pane.documents) do
    document.source_win = win
  end
end

---The window `session`'s source document is displayed in right now, or nil.
---
---`from_source_win` above cannot answer this and deliberately does not try: a
---window keeps its id when a different file is opened in it, so a preview
---started on README.md kept matching the window SECURITY.md was later loaded
---into, and scrolling SECURITY.md drove README's preview -- SECURITY.md's line
---numbers looked up in README's source map. Callers reacting to something that
---happened *in a window* (a scroll, a cursor line) must ask here. Callers that
---mean "the window this preview is paired with" -- following a link, walking
---the preview history -- want `session.source_win` itself and are right to keep
---using it.
---
---Adopts a new window when the document has moved to one, so a preview whose
---source buffer was reopened in a split keeps working, and refuses when two or
---more windows show it. That refusal is the point rather than caution: during a
---compound `:vsplit other.md` there is a moment when the new window and the one
---it split from both show the source buffer, and taking either on that evidence
---is exactly the mispairing md-viewer.controller's WinEnter handler defers a
---tick to avoid. A scroll event cannot defer, since its whole job is to answer
---now, so it declines instead; entering either window heals the pairing there.
function M.source_window(session)
  local win = session.source_win
  if
    type(win) == "number"
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_buf(win) == session.source_buf
  then
    return win
  end
  if not (session.preview_win and vim.api.nvim_win_is_valid(session.preview_win)) then return nil end
  local found
  for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(session.preview_win))) do
    if vim.api.nvim_win_get_buf(candidate) == session.source_buf then
      if found then return nil end
      found = candidate
    end
  end
  if found then M.set_source_window(session, found) end
  return found
end

function M.visible_in_tab(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  for _, pane in pairs(panes) do
    local session = pane.active
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
  if M.document(session.pane, new_buf) then return nil end
  unindex_session(session)
  session.source_buf = new_buf
  session.document_id = ("pane-%d-buffer-%d"):format(session.pane and session.pane.id or 0, new_buf)
  index_session(session)
  return session
end

function M.remove(source_buf)
  local value = M.get(source_buf)
  if value then
    M.remove_document(value)
    if value.pane and #value.pane.documents == 0 then M.remove_pane(value.pane) end
  end
  return value
end

function M.remove_document(session)
  if not session then return end
  unindex_session(session)
  local pane = session.pane
  if pane then
    for index, candidate in ipairs(pane.documents) do
      if candidate == session then
        table.remove(pane.documents, index)
        break
      end
    end
  end
  return session
end

function M.remove_pane(pane)
  if not pane then return end
  panes[pane.id] = nil
  pane.closed = true
end

function M.is_active(session)
  -- Pane-less document tables remain supported for the public low-level APIs
  -- and their focused tests; every real controller-created document has a
  -- pane and therefore takes the strict branch.
  return session and (not session.pane or (not session.pane.closed and session.pane.active == session))
end

function M.activate(session)
  local pane = session and session.pane
  if not pane or pane.closed then return nil end
  if pane.active then pane.active.active = false end
  pane.activation_epoch = pane.activation_epoch + 1
  pane.active = session
  session.active = true
  session.activation_epoch = pane.activation_epoch
  session.preview_win = pane.preview_win
  session.source_win = pane.source_win
  return session
end

function M.panes() return panes end

---Compatibility view used by the rendering loops and diagnostics: one entry
---per open document, keyed by its stable preview buffer when available.
function M.all()
  local all = {}
  for _, pane in pairs(panes) do
    for _, session in ipairs(pane.documents) do
      all[session.preview_buf or session.source_buf] = session
    end
  end
  return all
end

function M.active_documents()
  local active = {}
  for id, pane in pairs(panes) do
    if pane.active and not pane.closed then active[id] = pane.active end
  end
  return active
end

return M
