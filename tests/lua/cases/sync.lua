return function(t)
  local sync = require("md-viewer.sync")
  local blocks = {
    { sourceStart = 0, sourceEnd = 3, topPx = 0, bottomPx = 100 },
    { sourceStart = 3, sourceEnd = 6, topPx = 100, bottomPx = 250 },
  }
  t.eq(blocks[2], sync.block_for_line(blocks, 5), "source-map block lookup")
  local nested = {
    { sourceStart = 0, sourceEnd = 10, topPx = 0, bottomPx = 400 },
    { sourceStart = 3, sourceEnd = 5, topPx = 120, bottomPx = 190 },
  }
  t.eq(nested[2], sync.block_for_line(nested, 4), "most specific source-map block wins")
  t.eq(155, sync.block_target(nested[2], 5), "relative line position within block")
  t.eq(0, sync.scroll_for_block(blocks[1], 200, 500), "scroll clamp")

  -- ---------------------------------------------------------------------
  -- Echo suppression: a cursor move we caused must not scroll the preview.
  --
  -- `sync_guard` alone cannot cover this. Neovim dispatches CursorMoved when
  -- it next returns to the main loop, and `vim.schedule` runs on that same
  -- loop, so the guard is usually released before the echo arrives -- which
  -- is why clicking the preview used to make the preview scroll itself to
  -- re-anchor whatever was clicked. Every case below drains the scheduler
  -- first, so it reproduces that ordering rather than the convenient one.
  -- ---------------------------------------------------------------------
  do
    local source_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "one", "two", "three", "four", "five", "six" })
    vim.cmd("botright new")
    local source_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(source_win, source_buf)

    local refreshed
    local function refresh(session) refreshed = session end
    local function fresh_session()
      return {
        source_buf = source_buf,
        source_win = source_win,
        latest_blocks = blocks,
        viewport_height_px = 200,
        document_height_px = 500,
        scroll_y = 0,
        sync_guard = false,
      }
    end

    -- Our own move, observed after the guard has already been released.
    local session = fresh_session()
    vim.api.nvim_win_set_cursor(source_win, { 5, 0 })
    sync.suppress_echo(session, source_win)
    session.sync_guard = true
    vim.schedule(function() session.sync_guard = false end)
    vim.wait(200, function() return session.sync_guard == false end)
    refreshed = nil
    sync.source_cursor(session, refresh, 0.10)
    t.eq(nil, refreshed, "a cursor move we made ourselves does not scroll the preview")
    t.eq(0, session.scroll_y, "...and leaves the preview scroll position alone")

    -- One cursor move produces more than one event: moving to a line that is
    -- off screen in the source window scrolls it, so CursorMoved is followed by
    -- WinScrolled and the controller routes both here. The record has to
    -- survive being checked, or the second event scrolls the preview -- which
    -- is exactly what the operator saw when clicking a preview line that was
    -- not already visible in the editor.
    t.ok(session.sync_echo ~= nil, "the record survives being checked, because one move produces several events")
    refreshed = nil
    sync.source_cursor(session, refresh, 0.10)
    t.eq(nil, refreshed, "a second event from the same move is still recognised as an echo")
    sync.source_cursor(session, refresh, 0.10)
    t.eq(nil, refreshed, "...and a third")
    t.eq(2, session.last_source_block, "the block under the cursor is adopted without scrolling to it")

    -- The record is dropped the moment the cursor is somewhere else, so the
    -- next real move still syncs.
    vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
    refreshed = nil
    sync.source_cursor(session, refresh, 0.10)
    t.eq(session, refreshed, "a real cursor move after an echo still syncs the preview")
    t.eq(nil, session.sync_echo, "the echo record is dropped once the cursor moves for real")

    -- A stale record -- the cursor ended up somewhere other than where we put
    -- it -- must be discarded rather than swallow a genuine move.
    local stale = fresh_session()
    vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
    sync.suppress_echo(stale, source_win)
    vim.api.nvim_win_set_cursor(source_win, { 5, 0 })
    refreshed = nil
    sync.source_cursor(stale, refresh, 0.10)
    t.eq(stale, refreshed, "a stale echo record never swallows a real cursor move")

    -- suppress_echo on an invalid window records nothing rather than erroring.
    local orphan = fresh_session()
    sync.suppress_echo(orphan, 999999)
    t.eq(nil, orphan.sync_echo, "an unresolvable window records no echo")

    -- The mirror of the SECURITY.md-scrolls-README's-preview bug, and the
    -- reason update_source_from_scroll resolves the window rather than trusting
    -- `source_win`: a window keeps its id when a different file is opened in
    -- it, so this would put *this* document's line number -- clamped against
    -- *this* document's length -- into a file the preview is not rendering,
    -- yanking the reader's cursor out from under them. This direction is off by
    -- default (`sync.preview_to_source`), so no autocmd test can reach it.
    local moved = fresh_session()
    moved.preview_win = source_win
    local stranger = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(stranger, 0, -1, false, { "a", "b", "c" })
    vim.api.nvim_win_set_buf(source_win, stranger)
    vim.api.nvim_win_set_cursor(source_win, { 3, 0 })
    sync.update_source_from_scroll(moved, 0)
    t.eq(
      { 3, 0 },
      vim.api.nvim_win_get_cursor(source_win),
      "the preview never moves a cursor in a file it is not rendering"
    )
    t.eq(false, moved.sync_guard, "...and takes no guard it would then have to release")
    vim.api.nvim_win_set_buf(source_win, source_buf)
    vim.api.nvim_buf_delete(stranger, { force = true })

    vim.api.nvim_win_close(source_win, true)
  end
end
