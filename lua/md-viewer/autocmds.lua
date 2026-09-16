---The event layer: every autocmd md-viewer registers, in one group.
---
---Above controller rather than inside it, the same shape `commands.lua` has:
---this module requires controller and controller must never require it back.
---What each handler does is controller's; when it happens is this file's.
---
---Nothing else creates or clears the `md-viewer` augroup, and
---`tests/lua/cases/autocmds.lua` pins the manifest this installs -- every
---handler, its events and pattern, the dispatch order of the events more than
---one handler answers, and that each one fires against a real session without
---raising. A registration that goes missing here fails that case rather than
---failing silently, which is the whole reason this move waited for it.
local cellpixels = require("md-viewer.cellpixels")
local controller = require("md-viewer.controller")
local interaction = require("md-viewer.interaction")
local localrender = require("md-viewer.localrender")
local occlusion = require("md-viewer.occlusion")
local preview = require("md-viewer.preview")
local state = require("md-viewer.state")
local sync = require("md-viewer.sync")

local M = {}
local group

local clear_image = occlusion.clear_image
local clear_raw_sessions = occlusion.clear_raw_sessions
local close_session = controller.close_session
local each_session = occlusion.each_session
local must_hide = occlusion.must_hide
local reconcile_occlusion = occlusion.reconcile
local reconcile_placement = occlusion.reconcile_placement
local refresh_raw_sessions = occlusion.refresh_raw_sessions
local schedule_source_scroll = controller.schedule_source_scroll
local show_cached = controller.show_cached
local valid = controller.valid

function M.setup()
  group = vim.api.nvim_create_augroup("md-viewer", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    callback = function(args)
      for _, session in ipairs(state.documents_for_source(args.buf)) do
        if state.is_active(session) then
          controller.schedule(session)
        else
          session.dirty = true
        end
      end
    end,
  })
  -- Neovim's own Visual mode is not usable inside a graphical preview, and
  -- `navigation.lua` says so where it maps `v`/`V` to a *preview* selection
  -- instead. Saying it was not the same as enforcing it: the plugin maps only
  -- a plain click and its release over the preview, not a drag, so an
  -- ordinary mouse drag -- or `<C-v>` -- still puts Neovim in Visual mode over
  -- the surface, where it selects blank cells and paints a highlight across
  -- the image. Reported from Warp as the preview blinking to a blank pane
  -- with a blue rectangle on it -- that rectangle was V-BLOCK.
  --
  -- Excluded for the `cells` backend, whose buffer holds real styled text where
  -- Visual mode and `y` do exactly what a reader would expect.
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = "*:[vV\22sS\19]*",
    callback = function(args)
      local session = state.from_preview(args.buf)
      if not session or session.closed then return end
      if not (session.backend and session.backend.is_graphical) then return end
      -- One escape per tick. Without this a stream of drag events -- each
      -- re-entering Visual as fast as the escape leaves it -- would spin.
      if session.leaving_visual then return end
      session.leaving_visual = true
      vim.schedule(function()
        session.leaving_visual = nil
        if session.closed or not vim.api.nvim_buf_is_valid(args.buf) then return end
        if vim.api.nvim_get_current_buf() ~= args.buf then return end
        if not vim.fn.mode():match("^[vV\22sS\19]") then return end
        -- "n", not "m": the buffer-local <Esc> mapping clears the reader's find
        -- and preview selection, and this is not them asking for that. "x" as
        -- well, so the mode is actually back to normal when this returns
        -- rather than whenever the typeahead next drains -- a drag delivers the
        -- next event immediately, and a queued escape would arrive after it.
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(args)
      -- Nothing to do for the preview's own buffer: the caret is a position in
      -- the rendered document, not Neovim's cursor, so it moves through
      -- `interaction.caret_motion` and never through a cursor event. Neovim's
      -- cursor only shadows it.
      if state.from_preview(args.buf) then return end
      local session = state.get(args.buf)
      if session and session.config.sync.source_to_preview and session.config.sync.cursor_follow then
        local cfg = session.config.sync
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
        -- Compared against the window the source *buffer* is in, not against
        -- `session.source_win` directly: a window keeps its id when its buffer
        -- changes, so scrolling SECURITY.md after opening it in the window a
        -- README.md preview was started from satisfied this test and scrolled
        -- README's preview. The nil check is not decoration -- an unresolvable
        -- source window and a non-numeric `args.match` would otherwise compare
        -- equal and match every scroll in the editor.
        local source_win = state.source_window(session)
        if source_win and scrolled_win == source_win and session.config.sync.source_to_preview then
          local cfg = session.config.sync
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
      -- A terminal font-size change moves the pixel cell without changing
      -- anything Neovim reports except the grid. `cellpixels` no longer caches
      -- at all for exactly that reason, so this is now a formality; it stays
      -- because a resize is genuinely the moment the cell can move.
      cellpixels.invalidate()
      each_session(function(session)
        if not must_hide(session) then controller.schedule(session, 80, "resize_timer") end
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
      -- Deferred rather than read synchronously off `args`: a compound
      -- command like `:split other.md` fires `WinEnter` for the *new*
      -- window while it still, transiently, shows the window it split
      -- from's buffer -- the buffer swap to `other.md` (and that file's own
      -- `BufEnter`) happens a moment later, in the same command. Reading
      -- `nvim_get_current_buf()` synchronously here reassigns
      -- `session.source_win` to that new window on the strength of a buffer
      -- pairing that is already gone by the time the command finishes,
      -- stranding cursor-follow (WinScrolled below compares against
      -- `source_win` by identity) on a window that no longer shows the
      -- source buffer, with nothing left to correct it since the *real*
      -- source window was never touched. Deferring to the next tick lets
      -- the whole command settle first, so this only ever fires once the
      -- window/buffer pairing is the one the user actually ended up with.
      local buf = args.buf
      vim.schedule(function()
        local source_session = state.get(buf)
        if source_session and vim.api.nvim_get_current_buf() == buf then
          state.set_source_window(source_session, vim.api.nvim_get_current_win())
        end
        -- The source window arriving back at a document this preview has
        -- already shown (`<C-o>` after following a link) takes the preview
        -- with it. Deliberately narrow: only buffers in this session's own
        -- history qualify, so `preview.pinned` still holds for every other
        -- buffer switch.
        if source_session then return end
        local win_session = state.from_source_win(vim.api.nvim_get_current_win())
        if win_session and valid(win_session) and vim.api.nvim_get_current_buf() == buf then
          controller.history_follow_buffer(win_session, buf)
        end
      end)
      each_session(function(session)
        if
          not session.image_id
          and not session.ui_suppressed
          and not must_hide(session)
          and vim.api.nvim_win_get_tabpage(session.preview_win) == vim.api.nvim_get_current_tabpage()
        then
          if not show_cached(session) then controller.schedule(session, 0) end
        end
      end)
    end,
  })
  -- Neovim's cursor is hidden only while a preview with a drawable overlay
  -- caret is focused, so these two autocmds own the whole of that state. Restore
  -- is unconditional and idempotent: leaving a reader with an invisible cursor
  -- is far worse than restoring one that was never hidden.
  --
  -- `FocusGained` is here because `FocusLost` restores the cursor without any
  -- window changing, so nothing fires `WinEnter` on the way back: leaving the
  -- terminal and returning to it left Neovim's own cursor sitting beside the
  -- overlay caret until some later motion happened to redraw it.
  --
  -- `VimSuspend`, the other event that restores without a window change, needs
  -- no counterpart here: it drops the image outright (below), and the resume
  -- that puts one back goes through display_image, which calls place_caret
  -- itself once there is something to draw the caret over.
  vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter", "FocusGained" }, {
    group = group,
    callback = function()
      local session = state.from_preview_win(vim.api.nvim_get_current_win())
      if not (session and valid(session)) then
        preview.restore_cursor()
        return
      end
      -- Focusing a preview is when a caret first becomes something the reader
      -- can see, so this is where one gets placed. Snapping with no motion puts
      -- it on the first character of whatever is on screen; drawing it is what
      -- then hides Neovim's own cursor, so the two can never both be up.
      controller.place_caret(session)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave", "TabLeave", "VimSuspend", "VimLeavePre", "FocusLost" }, {
    group = group,
    callback = function()
      preview.restore_cursor()
      -- And take the block down with it. The caret marks where the *focused*
      -- reader is, so one left drawn in a preview nobody is in claims a focus
      -- that has moved on -- and on `FocusLost`, which gives the real cursor
      -- back without any window changing, it would sit there beside it: two
      -- carets at once, the thing this pair exists to prevent. The current
      -- window is still the one being left when these fire.
      --
      -- Only the overlay. `caret_rect` is kept, so coming back redraws the
      -- caret exactly where it was, locally, through the `place_caret` on the
      -- matching enter autocmd -- no round trip and no lost position.
      local session = state.from_preview_win(vim.api.nvim_get_current_win())
      if session and valid(session) then controller.clear_caret_overlay(session) end
    end,
  })
  vim.api.nvim_create_autocmd("BufFilePost", {
    group = group,
    callback = function(args)
      for _, session in ipairs(state.documents_for_source(args.buf)) do
        preview.update_title(session)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "CompleteChanged" }, {
    group = group,
    callback = function()
      each_session(function(session)
        if session.backend.needs_ui_poll then session.ui_suppressed = true end
      end)
      clear_raw_sessions()
    end,
  })
  vim.api.nvim_create_autocmd({ "CompleteDone", "WinClosed" }, {
    group = group,
    callback = function(args)
      if args.event ~= "WinClosed" then
        each_session(function(session)
          if session.backend.needs_ui_poll then session.ui_suppressed = false end
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
  -- Any new window can legitimately resize/reposition an existing preview
  -- split -- not only a floating one. WinResized/VimResized (below) is the
  -- other, more usual way that gets caught, but a plugin that opens several
  -- plain splits "relative to editor" (codediff.nvim's diff/explorer panes,
  -- for one -- see the operator report this fixed) can shrink/move the
  -- preview window as an immediate side effect of WinNew itself, before a
  -- separate WinResized round-trip; reconciling here too closes that gap
  -- rather than depending on the 50ms ui_poll_timer to eventually catch up.
  vim.api.nvim_create_autocmd("WinNew", {
    group = group,
    callback = function() vim.schedule(reconcile_occlusion) end,
  })
  vim.api.nvim_create_autocmd({ "ColorScheme" }, {
    group = group,
    callback = function()
      each_session(function(session) controller.schedule(session, 0) end)
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "background",
    callback = function()
      each_session(function(session) controller.schedule(session, 0) end)
    end,
  })
  -- 'laststatus' decides whether the raw Kitty backend gives a statusline guard
  -- row back (coordinates.for_window, preview.placement), so it changes the
  -- caret surface's height with no resize event of any kind to announce it --
  -- and under `laststatus = 1` it does so whenever the tabpage's window count
  -- crosses one, which is not a change to the preview window at all.
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "laststatus",
    callback = function()
      each_session(function(session) preview.reset_surface(session) end)
    end,
  })
  vim.api.nvim_create_autocmd("BufHidden", {
    group = group,
    callback = function(args)
      -- Preview buffers use bufhidden=hide specifically so switching pane tabs
      -- is not lifecycle. Only the optional unpinned source behavior remains.
      local session
      if not state.from_preview(args.buf) then
        local hidden = state.get(args.buf)
        if hidden and not hidden.config.preview.pinned then session = hidden end
      end
      if session then close_session(session) end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      local preview_document = state.from_preview(args.buf)
      if preview_document then
        controller.tab_close(preview_document)
        return
      end
      for _, session in ipairs(state.documents_for_source(args.buf)) do
        controller.tab_close(session)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local closed = tonumber(args.match)
      for _, pane in pairs(state.panes()) do
        if pane.preview_win == closed and not pane.closed then
          -- The window is already invalid; teardown skips closing/restoring it
          -- and still releases every document and renderer cache.
          close_session(pane.active)
          break
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TabLeave", "VimSuspend" }, {
    group = group,
    callback = function()
      each_session(function(session)
        -- clear_image() rather than a hand-rolled clear: the placement this
        -- drops must go with the image, since interaction.locate resolves
        -- clicks against session.last_placement and there is no longer an
        -- image on screen for one to land on.
        clear_image(session)
        -- The preview survives a tab leave or suspend, but a mouse press
        -- captured against it does not: there is no guarantee the matching
        -- release ever reaches Neovim across that boundary.
        interaction.forget(session)
      end)
    end,
  })
  -- Wrapped rather than passed directly: an autocmd callback receives the event
  -- table as its first argument, which `close_all` now reads as `opts`.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      -- Detach before tearing down sessions: this closes the control-socket
      -- pipe, which the helper's socket server sees as a real `close` event
      -- on its next tick -- concrete and immediate, unlike the marker-based
      -- image deletions below it, which only reach the helper if a captured
      -- frame happens to carry them before the process exits. Without this,
      -- the operator's own workflow (one helper process wrapping many
      -- Neovim restarts in the same ssh session) leaves every per-document
      -- epoch/seq counter on the helper (replica.js's `docs`, injector.js's
      -- `lastSurfaceSeq`) sitting at whatever the outgoing session left it
      -- at, so the next Neovim session's first frame reference can be
      -- silently refused as stale -- a preview that renders solid black on
      -- reopen, measured live (2026-08-27).
      if localrender.active() then localrender.detach() end
      controller.close_all({ blocking = true })
    end,
  })
end

return M
