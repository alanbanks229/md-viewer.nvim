-- Preview history: following a link must not strand the reader on the document
-- it led to. `preview.pinned` deliberately stops the preview following an
-- ordinary buffer switch, so without this the rendered view has no way back to
-- where the reader started -- the source window's jump list moves the text and
-- leaves the picture behind.
return function(t)
  local config = require("md-viewer.config")
  local controller = require("md-viewer.controller")
  local interaction = require("md-viewer.interaction")
  local state = require("md-viewer.state")

  local project = vim.uv.fs_realpath((function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/.git", "p")
    return dir
  end)())
  vim.fn.writefile({ "# A", "", "[to b](b.md)" }, project .. "/a.md")
  vim.fn.writefile({ "# B", "", "[to c](c.md)" }, project .. "/b.md")
  vim.fn.writefile({ "# C" }, project .. "/c.md")

  require("md-viewer").setup({})
  vim.cmd.edit(vim.fn.fnameescape(project .. "/a.md"))
  local session = assert(controller.open("right"))
  local source_win = session.source_win
  local buf_a = session.source_buf

  -- A graphical backend, because retargeting is refused for `cells` (there is
  -- no image to move), and a stubbed refresh, because the renderer subprocess
  -- is not what this file is about.
  session.backend = {
    name = "kitty_raw",
    clear = function() return true end,
    show = function() return 1 end,
    update = function() return 1 end,
    move = function() return true end,
  }
  local original_refresh = controller.refresh
  controller.refresh = function() end

  local function source_path() return vim.fs.normalize(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(source_win))) end

  t.eq(1, #session.history, "a fresh preview has exactly one document in its history")
  t.eq(1, session.history_index, "and sits on it")
  t.eq(project .. "/a.md", session.history[1].path, "the first entry is the document the preview opened on")

  -- Follow two links, through the real activation path.
  interaction.activate_link(session, { link = { type = "local_file", href = "b.md" } })
  local buf_b = session.source_buf
  t.eq(project .. "/b.md", source_path(), "activating a link edits the target in the source window")
  t.eq(2, #session.history, "and appends it to the preview history")
  t.eq(2, session.history_index, "leaving the preview on the newest document")

  interaction.activate_link(session, { link = { type = "local_file", href = "c.md" } })
  local buf_c = session.source_buf
  t.eq(3, #session.history, "a second link appends again")
  t.eq(project .. "/c.md", source_path())

  -- Back, twice, then forward. The source window follows the preview, for the
  -- same reason activating a link moves it.
  controller.history_back()
  t.eq(buf_b, session.source_buf, "back returns the preview to the previous document")
  t.eq(2, session.history_index, "and moves the index rather than the list")
  t.eq(3, #session.history, "back never discards the forward branch")
  t.eq(project .. "/b.md", source_path(), "the source window follows the preview back")

  controller.history_back()
  t.eq(buf_a, session.source_buf, "back again reaches the document the preview opened on")
  t.eq(1, session.history_index)

  controller.history_forward()
  t.eq(buf_b, session.source_buf, "forward retraces the same path")
  t.eq(2, session.history_index)

  -- Walking off either end is reported, and changes nothing.
  local original_notify, notified = vim.notify, {}
  vim.notify = function(message) notified[#notified + 1] = message end
  controller.history_back()
  notified = {}
  controller.history_back()
  t.eq(1, session.history_index, "back at the oldest document stays there")
  t.eq(buf_a, session.source_buf, "and does not move the source window either")
  t.ok(notified[1] and notified[1]:find("no previous document", 1, true) ~= nil, "and says why nothing happened")

  controller.history_forward()
  controller.history_forward()
  t.eq(3, session.history_index, "forward reaches the newest document")
  notified = {}
  controller.history_forward()
  t.eq(3, session.history_index, "forward at the newest document stays there")
  t.ok(notified[1] and notified[1]:find("no next document", 1, true) ~= nil, "and says why")
  vim.notify = original_notify

  -- Navigating from the middle abandons the forward branch, exactly as a
  -- browser does: interleaving the two would make "forward" mean nothing.
  controller.history_back()
  t.eq(buf_b, session.source_buf)
  interaction.activate_link(session, { link = { type = "local_file", href = "a.md" } })
  t.eq(buf_a, session.source_buf, "a link from the middle of the history navigates normally")
  t.eq(3, #session.history, "and truncates whatever was ahead of it")
  t.eq(3, session.history_index)
  t.eq(project .. "/a.md", session.history[3].path, "leaving the new document as the newest entry")
  t.eq(nil, state.get(buf_c), "the abandoned document no longer owns a session")

  -- Re-activating the document already on screen is not a new entry: a
  -- fragment link, or a link back to where the reader just came from, must
  -- not grow the list without adding anywhere to go.
  interaction.activate_link(session, { link = { type = "local_file", href = "a.md" } })
  t.eq(3, #session.history, "re-opening the current document adds no history entry")

  -- The bound is real, not advisory.
  do
    config.reset()
    config.setup({ interaction = { history_limit = 2 } })
    local bounded = { source_buf = 1, history = nil, history_index = 0 }
    controller.history_init(bounded)
    for buf = 2, 6 do
      controller.history_push(bounded, buf)
    end
    t.eq(2, #bounded.history, "history is capped at interaction.history_limit")
    t.eq(6, bounded.history[2].buf, "keeping the newest entries")
    t.eq(2, bounded.history_index, "with the index still on the newest")
    config.reset()
    config.setup({})
  end

  -- `<C-o>` back into a document this preview navigated through takes the
  -- preview with it. Narrow on purpose: only history members qualify, so
  -- `preview.pinned` still holds for every other buffer switch.
  do
    t.eq(buf_a, session.source_buf)
    controller.history_back()
    t.eq(buf_b, session.source_buf, "positioned on b, with a ahead of it")
    vim.api.nvim_win_set_buf(source_win, buf_a)
    vim.api.nvim_set_current_win(source_win)
    vim.api.nvim_exec_autocmds("BufEnter", { buffer = buf_a })
    vim.wait(200, function() return session.source_buf == buf_a end)
    t.eq(buf_a, session.source_buf, "the preview follows the source window back to a history document")
    -- `a` sits at both ends of this history (the reader linked back to it), so
    -- the position taken is the one nearest where the preview already was,
    -- preferring backwards -- the direction `<C-o>` means.
    t.eq(1, session.history_index, "and takes the nearest matching history position with it")

    -- An unrelated buffer does not drag the preview along.
    local stranger = vim.api.nvim_create_buf(true, false)
    vim.bo[stranger].filetype = "markdown"
    vim.api.nvim_win_set_buf(source_win, stranger)
    vim.api.nvim_exec_autocmds("BufEnter", { buffer = stranger })
    vim.wait(120, function() return session.source_buf == stranger end)
    t.eq(buf_a, session.source_buf, "a buffer outside the history leaves the pinned preview alone")
    vim.api.nvim_win_set_buf(source_win, buf_a)
    vim.api.nvim_buf_delete(stranger, { force = true })
  end

  -- The preview-local H/L keys, driven the way a keypress would drive them.
  -- `controller.open` skips navigation.attach for the cells backend a headless
  -- test starts on, so it is attached here explicitly.
  do
    require("md-viewer.navigation").attach(session, controller.navigate)
    local function press(lhs)
      local mapping = vim.api.nvim_buf_call(
        session.preview_buf,
        function() return vim.fn.maparg(lhs, "n", false, true) end
      )
      assert(mapping.callback, lhs .. " has no preview-local mapping to press")
      mapping.callback()
    end

    -- The `<C-o>` case above left the preview at the oldest entry, so forward
    -- is the move with somewhere to go.
    t.eq(1, session.history_index, "starting at the oldest document")
    t.eq(buf_a, session.source_buf)
    press("L")
    t.eq(buf_b, session.source_buf, "L moves the preview forward a document")
    press("H")
    t.eq(buf_a, session.source_buf, "H moves it back again")
  end

  -- Resident regions belong to the document they were captured from, and every
  -- component of their identity changes when the preview retargets. Following a
  -- link is therefore one of the few things that must genuinely hand the pixels
  -- back rather than merely take them off the screen -- the distinction the rest
  -- of the lifecycle turns on, since occlusion and tab switches do the opposite.
  do
    local resident = require("md-viewer.resident")
    local freed = {}
    session.backend.clear = function(image_id)
      freed[#freed + 1] = image_id
      return true
    end
    local live = session.resident
    live.memory_px = 32000000
    live.key = "whatever-this-document-was"
    live.grid = { count = 4 }
    assert(resident.register(
      live,
      0,
      assert(resident.region({
        doc_y = 0,
        doc_h = 2020,
        css_w = 990,
        image_w = 1980,
        image_h = 4040,
        key = live.key,
        image_id = 6161,
      }))
    ))
    t.eq(1, #resident.slice_records(live), "sanity: the session is holding a slice")

    interaction.activate_link(session, { link = { type = "local_file", href = "b.md" } })
    t.eq({ 6161 }, freed, "following a link gives the previous document's slices back to the terminal")
    t.eq(0, #resident.slice_records(live), "and holds nothing")
    t.eq(0, live.resident_px, "so the ceiling is available to the document just opened")
    t.eq(nil, live.key, "with no stale identity left to match against")
    t.eq(nil, live.grid, "and no grid describing a document the preview has left")
    session.backend.clear = function() return true end
  end

  controller.refresh = original_refresh
  controller.close(session.source_buf)
  vim.cmd("enew!")
end
