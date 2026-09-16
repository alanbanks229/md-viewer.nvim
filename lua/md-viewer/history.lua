local M = {}

---History belongs to the preview pane, not to whichever document happens to
---be active in it. Pane-less tables remain supported for the low-level API and
---its focused tests.
local function holder(session) return session.pane or session end

local function history_entry(buf)
  local name = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ""
  return { buf = buf, path = name ~= "" and vim.fs.normalize(name) or nil, scroll_y = 0 }
end

function M.init(session)
  local owner = holder(session)
  owner.history = { history_entry(session.source_buf) }
  owner.history_index = 1
  owner.history_boundary = nil
end

---Append `buf` as the newest entry, discarding anything ahead of the current
---position -- the same rule a browser follows: navigating from a point in the
---middle of the history abandons the forward branch rather than interleaving
---with it.
function M.push(session, buf)
  local owner = holder(session)
  if not owner.history then M.init(session) end
  local history = owner.history
  local history_index = owner.history_index
  if history[history_index] then history[history_index].scroll_y = session.scroll_y or 0 end
  for index = #history, history_index + 1, -1 do
    history[index] = nil
  end
  -- Re-entering the document that is already current is not a new entry:
  -- otherwise a fragment link, or a link back to where the reader just came
  -- from, would grow the list without adding anywhere to go.
  if history[history_index] and history[history_index].buf == buf then return end
  history[#history + 1] = history_entry(buf)
  local limit = session.config.interaction.history_limit
  while #history > limit do
    table.remove(history, 1)
  end
  owner.history_index, owner.history_boundary = #history, nil
end

---Align the pane's history cursor with the most recent visit to `session`.
function M.align(session)
  local owner = holder(session)
  if not owner.history then return end
  for index = #owner.history, 1, -1 do
    if owner.history[index].buf == session.source_buf then
      owner.history_index = index
      return
    end
  end
end

---Resolve a history entry to a buffer that can actually be displayed, reopening
---the file when the buffer it recorded is gone. Returns nil when neither is
---available any more, which is a dead entry rather than an error.
local function history_buf(entry)
  if entry.buf and vim.api.nvim_buf_is_valid(entry.buf) then return entry.buf end
  if not entry.path or not vim.uv.fs_stat(entry.path) then return nil end
  local buf = vim.fn.bufadd(entry.path)
  if buf == 0 then return nil end
  vim.fn.bufload(buf)
  entry.buf = buf
  return buf
end

---Move only the preview `step` entries through history. Dead entries are
---stepped over rather than reported: a wiped buffer whose file is also gone
---is not something the reader can act on.
local function go(session, step, direction, host)
  local owner = holder(session)
  if not owner.history then M.init(session) end
  local history = owner.history
  local index = owner.history_index
  if history[index] then history[index].scroll_y = session.scroll_y or 0 end
  while true do
    index = index + step
    local entry = history[index]
    if not entry then
      -- A repeat of the same direction's dead end is not news: only the
      -- first one is reported, and any successful move (either direction)
      -- re-arms it below.
      if owner.history_boundary ~= direction then
        owner.history_boundary = direction
        vim.notify(("md-viewer: no %s document in the preview history"):format(direction), vim.log.levels.INFO)
      end
      return false
    end
    owner.history_boundary = nil
    local buf = history_buf(entry)
    if buf then
      if buf == session.source_buf then
        owner.history_index = index
        session.scroll_y = entry.scroll_y or session.scroll_y
        host.schedule(session, 0)
        return true
      end
      if not host.retarget(session, buf, false, entry.scroll_y) then
        -- The only way this refuses is another preview already owning that
        -- document. The source window has moved by now, so saying nothing
        -- would leave the two panes describing different files with no
        -- explanation.
        vim.notify("md-viewer: another preview already owns that document", vim.log.levels.WARN)
        return false
      end
      owner.history_index = index
      local active = session.pane and session.pane.active or session
      active.scroll_y = entry.scroll_y or active.scroll_y or 0
      return true
    end
  end
end

---`session` is passed explicitly by the preview-local `H`/`L` mappings, which
---already know which preview they belong to, and omitted by the commands,
---which resolve it the same way every other :MdViewer* command does.
function M.back(session, host)
  session = session or host.current_session()
  if not host.valid(session) then
    vim.notify("md-viewer: no preview open", vim.log.levels.WARN)
    return
  end
  go(session, -1, "previous", host)
end

function M.forward(session, host)
  session = session or host.current_session()
  if not host.valid(session) then
    vim.notify("md-viewer: no preview open", vim.log.levels.WARN)
    return
  end
  go(session, 1, "next", host)
end

---Re-point the preview when the source window returns, by any means, to a
---document already in this preview's history -- `<C-o>` after a link click
---being the case that matters. `preview.pinned` stops the preview following
---arbitrary buffer switches, and that stays true: only a document the preview
---itself navigated through is followed, and the move never appends, so the
---forward branch survives to be walked back up.
function M.follow_buffer(session, buf, host)
  local owner = holder(session)
  local history = owner.history
  local history_index = owner.history_index
  if not history or buf == session.source_buf then return end
  -- One document can legitimately appear at more than one position (a link
  -- back to where the reader came from puts it there twice), so search outward
  -- from where the preview currently is rather than from the start -- landing
  -- at the far end of the list would make the next `<C-o>` jump somewhere the
  -- reader has never been. Backwards wins a tie, because the gesture this
  -- exists for is the backwards one.
  for distance = 0, #history do
    for _, index in ipairs({ history_index - distance, history_index + distance }) do
      if history[index] and history[index].buf == buf then
        if host.retarget(session, buf, false) then owner.history_index = index end
        return
      end
    end
  end
end

function M.status(session)
  local owner = holder(session)
  return owner.history and #owner.history or 0, owner.history_index or 0
end

return M
