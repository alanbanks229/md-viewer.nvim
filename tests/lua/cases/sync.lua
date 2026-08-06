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

    -- The record is consumed, so the *next* real move still syncs.
    vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
    refreshed = nil
    sync.source_cursor(session, refresh, 0.10)
    t.eq(session, refreshed, "a real cursor move after an echo still syncs the preview")

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

    vim.api.nvim_win_close(source_win, true)
  end
end
