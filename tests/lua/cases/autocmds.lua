-- The autocmd manifest.
--
-- `controller.setup()` registers 39 autocmds in one group, and until this file
-- existed nothing asserted the set: 24 of the events were never fired by a
-- test, and *deleting* a registration broke nothing anywhere in the suite. The
-- plan's last phase moves this block into its own module, which is the most
-- dangerous move it lists, precisely because a handler can go missing silently.
--
-- Three things are pinned here, in order:
--
--   1. The manifest -- every handler, the events it answers, and its pattern.
--      Handlers are identified by function *identity* in the result of
--      `nvim_get_autocmds`, which is what lets one `nvim_create_autocmd` call
--      over five events be recognised as the single handler it is.
--   2. Dispatch order for the four events with two handlers each. Order is
--      behavioral for all four, and there is a control experiment below
--      proving that the order `nvim_get_autocmds` returns is the order
--      Neovim dispatches in -- the assumption the manifest's ordering half
--      rests on.
--   3. That every event actually fires against a real session without
--      raising, and that the session survives exactly the events that are not
--      lifecycle events.
--
-- The manifest is deliberately written out in full rather than derived. A
-- generated expectation would move with the code it is supposed to hold still.

-- Each entry: the events one `nvim_create_autocmd` call registered, its
-- pattern, and what the handler is for. `events` is sorted, which is also how
-- `nvim_get_autocmds` returns them.
local MANIFEST = {
  {
    pattern = "*",
    events = { "BufEnter", "FocusGained", "TabEnter", "VimResume", "WinEnter" },
    purpose = "re-pair the source window, follow history back, restore a dropped placement",
  },
  {
    pattern = "*",
    events = { "BufEnter", "FocusGained", "WinEnter" },
    purpose = "entering a preview places the caret; entering anything else restores Neovim's cursor",
  },
  { pattern = "*", events = { "BufFilePost" }, purpose = "renamed source buffer retitles its preview" },
  { pattern = "*", events = { "BufHidden" }, purpose = "close an unpinned source's session" },
  {
    pattern = "*",
    events = { "BufLeave", "FocusLost", "TabLeave", "VimLeavePre", "VimSuspend", "WinLeave" },
    purpose = "restore Neovim's cursor and take the caret overlay down with it",
  },
  { pattern = "*", events = { "BufWipeout" }, purpose = "wiping either buffer closes the document" },
  { pattern = "*", events = { "CmdlineEnter", "CmdlineLeave" }, purpose = "cmdheight=0 re-place, forced" },
  { pattern = "*", events = { "ColorScheme" }, purpose = "re-render on a palette change" },
  { pattern = "*", events = { "CompleteChanged" }, purpose = "a popup menu is up: suppress and clear" },
  { pattern = "*", events = { "CompleteDone", "WinClosed" }, purpose = "the popup is gone: unsuppress, reconcile" },
  { pattern = "*", events = { "CursorMoved", "CursorMovedI" }, purpose = "source cursor drives preview scroll" },
  { pattern = "*:[vV\22sS\19]*", events = { "ModeChanged" }, purpose = "refuse Neovim Visual mode over an image" },
  { pattern = "background", events = { "OptionSet" }, purpose = "re-render on a background flip" },
  { pattern = "laststatus", events = { "OptionSet" }, purpose = "the statusline guard row moved: reset the surface" },
  { pattern = "*", events = { "TabLeave", "VimSuspend" }, purpose = "drop the image and forget a captured press" },
  {
    pattern = "*",
    events = { "TextChanged", "TextChangedI", "TextChangedP" },
    purpose = "the live-preview trigger",
  },
  { pattern = "*", events = { "VimLeavePre" }, purpose = "detach local render, then close every session" },
  { pattern = "*", events = { "VimResized", "WinResized" }, purpose = "the cell may have moved: re-render" },
  { pattern = "*", events = { "WinClosed" }, purpose = "closing a preview window closes its pane" },
  { pattern = "*", events = { "WinNew" }, purpose = "a new split can resize the preview before WinResized" },
  { pattern = "*", events = { "WinScrolled" }, purpose = "scrolling the source window drives the preview" },
}

-- The events more than one handler answers, in dispatch order, named by the
-- handler's event set and pattern. Seven of the eight pairs are an ordering
-- question -- the plan counted six -- and one, OptionSet, is not: its two
-- handlers have disjoint patterns and never both fire for the same option.
-- Why each order is behavioral:
--
--   BufEnter/FocusGained/WinEnter  the frame is restored before the caret is
--     placed over it -- `place_caret` has nothing to composite against
--     otherwise.
--   TabLeave/VimSuspend  the caret overlay comes down before the base image
--     it sits on is cleared.
--   VimLeavePre  same, and the caret teardown must precede `close_all`.
--   WinClosed  the popup-menu handler's reconcile runs before the pane
--     teardown that may remove the window it would reconcile.
local ENTER = "BufEnter,FocusGained,TabEnter,VimResume,WinEnter @*"
local CARET_ENTER = "BufEnter,FocusGained,WinEnter @*"
local LEAVE = "BufLeave,FocusLost,TabLeave,VimLeavePre,VimSuspend,WinLeave @*"

local ORDER = {
  BufEnter = { ENTER, CARET_ENTER },
  FocusGained = { ENTER, CARET_ENTER },
  WinEnter = { ENTER, CARET_ENTER },
  TabLeave = { LEAVE, "TabLeave,VimSuspend @*" },
  VimSuspend = { LEAVE, "TabLeave,VimSuspend @*" },
  VimLeavePre = { LEAVE, "VimLeavePre @*" },
  WinClosed = { "CompleteDone,WinClosed @*", "WinClosed @*" },
  OptionSet = { "OptionSet @background", "OptionSet @laststatus" },
}

-- Every event in the manifest, fired against a real session. `closes` says
-- whether the session is expected to be gone afterwards: the three lifecycle
-- events, and nothing else.
local FIRE = {
  { event = "BufEnter" },
  { event = "BufFilePost" },
  { event = "BufHidden" }, -- preview.pinned defaults to true, so this is a no-op
  { event = "BufLeave" },
  { event = "BufWipeout", closes = true },
  { event = "CmdlineEnter" },
  { event = "CmdlineLeave" },
  { event = "ColorScheme" },
  { event = "CompleteChanged" },
  { event = "CompleteDone" },
  { event = "CursorMoved" },
  { event = "CursorMovedI" },
  { event = "FocusGained" },
  { event = "FocusLost" },
  { event = "ModeChanged", pattern = "n:v" },
  { event = "OptionSet", pattern = "background" },
  { event = "OptionSet", pattern = "laststatus" },
  { event = "TabEnter" },
  { event = "TabLeave" },
  { event = "TextChanged" },
  { event = "TextChangedI" },
  { event = "TextChangedP" },
  { event = "VimLeavePre", closes = true },
  { event = "VimResized" },
  { event = "VimResume" },
  { event = "VimSuspend" },
  { event = "WinClosed", preview_win_pattern = true, closes = true },
  { event = "WinEnter" },
  { event = "WinLeave" },
  { event = "WinNew" },
  { event = "WinResized" },
  { event = "WinScrolled", preview_win_pattern = true },
}

return function(t)
  local backends = require("md-viewer.backends")
  local config = require("md-viewer.config")
  local controller = require("md-viewer.controller")
  local process = require("md-viewer.process")
  local state = require("md-viewer.state")

  config.reset()
  require("md-viewer").setup({})

  -- -- 1. the manifest ---------------------------------------------------

  local registrations = vim.api.nvim_get_autocmds({ group = "md-viewer" })
  local handlers, by_callback = {}, {}
  for _, registration in ipairs(registrations) do
    local handler = by_callback[registration.callback]
    if not handler then
      handler = { pattern = registration.pattern, events = {} }
      by_callback[registration.callback] = handler
      handlers[#handlers + 1] = handler
    end
    handler.events[#handler.events + 1] = registration.event
  end

  local function signature(handler) return table.concat(handler.events, ",") .. " @" .. handler.pattern end
  local function canonical(list)
    local out = {}
    for _, handler in ipairs(list) do
      table.sort(handler.events)
      out[#out + 1] = signature(handler)
    end
    table.sort(out)
    return out
  end

  local expected = {}
  for _, entry in ipairs(MANIFEST) do
    expected[#expected + 1] = { pattern = entry.pattern, events = entry.events }
  end

  t.eq(canonical(expected), canonical(handlers), "the md-viewer autocmd group registers exactly the manifest")
  t.eq(#MANIFEST, #handlers, "one handler per nvim_create_autocmd call in the manifest")
  local total = 0
  for _, entry in ipairs(MANIFEST) do
    total = total + #entry.events
  end
  t.eq(total, #registrations, "and exactly as many registrations as the manifest's events add up to")

  -- Every handler has a stated purpose, so a future reader of a failing
  -- manifest learns what went missing rather than only that something did.
  for _, entry in ipairs(MANIFEST) do
    t.ok(entry.purpose and #entry.purpose > 0, ("the %s handler states what it is for"):format(signature(entry)))
  end

  -- -- 2. dispatch order -------------------------------------------------

  -- The control experiment. The manifest's ordering half reads the order out
  -- of `nvim_get_autocmds`; this proves that order is the dispatch order,
  -- against two handlers whose only job is to say when they ran.
  do
    local probe = vim.api.nvim_create_augroup("md-viewer-order-probe", { clear = true })
    local fired = {}
    for _, label in ipairs({ "first", "second" }) do
      vim.api.nvim_create_autocmd("User", {
        group = probe,
        pattern = "MdViewerOrderProbe",
        callback = function() fired[#fired + 1] = label end,
      })
    end
    local listed = {}
    for _, registration in ipairs(vim.api.nvim_get_autocmds({ group = "md-viewer-order-probe" })) do
      registration.callback()
      listed[#listed + 1] = fired[#fired]
    end
    fired = {}
    vim.api.nvim_exec_autocmds("User", { pattern = "MdViewerOrderProbe", modeline = false })
    t.eq(listed, fired, "nvim_get_autocmds returns handlers in the order Neovim dispatches them")
    vim.api.nvim_del_augroup_by_id(probe)
  end

  local per_event = {}
  for _, registration in ipairs(registrations) do
    local handler = by_callback[registration.callback]
    per_event[registration.event] = per_event[registration.event] or {}
    table.insert(per_event[registration.event], signature(handler))
  end
  local multi = {}
  for event, list in pairs(per_event) do
    if #list > 1 then multi[event] = list end
  end
  t.eq(ORDER, multi, "the events with more than one handler, and the order those handlers run in")

  -- -- 3. fire every event -----------------------------------------------

  -- Hermetic: firing the live-preview trigger schedules a render, and this
  -- file is about the wiring, not about what a render does.
  local original_request = process.request
  process.request = function(_, _, callback)
    if callback then callback({ ok = false, error = "autocmds.lua stub" }) end
  end

  -- Most of these handlers do their real work a tick later, and an error
  -- raised inside `vim.schedule` is printed by Neovim and otherwise ignored --
  -- a driver that only pcalls the fire itself reports a green run over a
  -- handler that threw. Wrap the deferral for the duration of the loop so a
  -- deferred failure is an assertion like any other. Timer callbacks
  -- (`M.schedule`'s render timer) are not covered; nothing here waits long
  -- enough for one to run.
  local scheduled_errors = {}
  local original_schedule = vim.schedule
  vim.schedule = function(fn)
    original_schedule(function()
      local ok, err = pcall(fn)
      if not ok then scheduled_errors[#scheduled_errors + 1] = err end
    end)
  end

  local function fixture()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_open_win(buf, true, { split = "above", win = -1 })
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# T", "", "body" })
    local source_win = vim.api.nvim_get_current_win()
    local session = assert(controller.open("right"))
    session.backend = vim.tbl_extend("force", backends.capabilities("kitty_raw"), {
      clear = function() return true end,
      show = function() return 1 end,
      update = function() return 1 end,
      move = function() return true end,
      clear_all = function() end,
    })
    session.image_id = 601
    session.last_placement = { row = 0, col = 0, width = 80, height = 24, exclusions = {} }
    return buf, session, source_win
  end

  for _, spec in ipairs(FIRE) do
    local buf, session, source_win = fixture()
    local preview_win = session.preview_win
    local pattern = spec.pattern
    if spec.preview_win_pattern then pattern = tostring(preview_win) end

    local ok, err = pcall(vim.api.nvim_exec_autocmds, spec.event, {
      buffer = (pattern == nil) and buf or nil,
      pattern = pattern,
      modeline = false,
    })
    t.ok(ok, ("%s fires against a live session without raising: %s"):format(spec.event, tostring(err)))
    -- Several handlers defer their real work a tick; let that run here rather
    -- than inside the next event's fixture.
    vim.wait(60, function() return false end, 10)

    t.eq({}, scheduled_errors, ("%s raises nothing in its deferred half either"):format(spec.event))
    scheduled_errors = {}

    local gone = state.get(buf) == nil
    t.eq(spec.closes == true, gone, ("%s %s the session"):format(spec.event, spec.closes and "closes" or "leaves open"))

    if not gone then controller.close(buf) end
    pcall(vim.api.nvim_win_close, source_win, true)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end

  vim.schedule = original_schedule
  process.request = original_request
  config.reset()
end
