return function(t)
  -- The command surface is a public API, and the two ways it goes wrong are
  -- silent: a command that quietly stops existing, and one that survives a
  -- rename in code but not in the docs. Both are cheap to pin here.
  require("md-viewer").setup({})

  local function exists(name) return vim.fn.exists(":" .. name) == 2 end

  for _, name in ipairs({
    "MdViewerToggle",
    "MdViewerHealth",
    "MdViewerDebug",
    "MdViewerCopy",
    "MdViewerFind",
    "MdViewerFindNext",
    "MdViewerFindPrevious",
    "MdViewerBack",
    "MdViewerForward",
  }) do
    t.ok(exists(name), ("%s is registered"):format(name))
  end

  -- One command owns the preview's visibility. `controller.open()` and
  -- `controller.close()` stay as the Lua API for autocmds and other plugins,
  -- and are what to call when the intent is "ensure open" -- open() is
  -- idempotent and never closes a live preview, which is exactly where it
  -- differs from the toggle.
  t.ok(not exists("MdViewerOpen"), "MdViewerOpen is not a command; controller.open() is the Lua API")
  t.ok(not exists("MdViewerClose"), "MdViewerClose is not a command; controller.close() is the Lua API")

  -- :MdViewerHealth stopped taking `verbose` when the full dump moved into
  -- :MdViewerDebug. A command that still accepted an argument it now ignores
  -- would fail silently for anyone with it in a keymap.
  t.eq("0", tostring(vim.api.nvim_get_commands({})["MdViewerHealth"].nargs), ":MdViewerHealth takes no arguments")
  t.eq("?", tostring(vim.api.nvim_get_commands({})["MdViewerToggle"].nargs), ":MdViewerToggle still takes a position")

  -- Every command this plugin registers must be documented, or it does not
  -- really exist for anyone but its author.
  -- Derived from this file rather than the working directory, so the check
  -- holds wherever the suite is invoked from.
  local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here))))
  local doc = table.concat(vim.fn.readfile(root .. "/doc/md-viewer.txt"), "\n")
  local readme = table.concat(vim.fn.readfile(root .. "/README.md"), "\n")
  for name in pairs(vim.api.nvim_get_commands({})) do
    if name:match("^MdViewer") then
      t.ok(doc:find("*:" .. name .. "*", 1, true) ~= nil, ("%s has a help tag"):format(name))
      t.ok(readme:find(":" .. name, 1, true) ~= nil, ("%s appears in the README"):format(name))
    end
  end
  -- Removed commands must lose their help *tag* and their row in the README
  -- command table -- the two things that make a name look live. Prose
  -- explaining where a command went is not only allowed but wanted, so this
  -- deliberately does not forbid the name appearing at all.
  for _, gone in ipairs({
    "MdViewerOpen",
    "MdViewerClose",
    "MdViewerRefresh",
    "MdViewerClearSelection",
    "MdViewerFindClear",
    -- Going to a *source* line from the preview: deferred rather than shipped
    -- half-considered. Removed outright, code and all, so nothing claims it
    -- works -- `{count}G` no longer means it either.
    "MdViewerGoto",
  }) do
    t.ok(not exists(gone), ("%s is no longer a command"):format(gone))
    t.ok(doc:find("*:" .. gone .. "*", 1, true) == nil, ("the help has no tag for %s"):format(gone))
    t.ok(readme:find("| `:" .. gone .. "`", 1, true) == nil, ("the README command table omits %s"):format(gone))
  end

  -- The functions behind them stay reachable from Lua: removing a command is a
  -- decision about the command surface, not about what the plugin can do.
  local controller = require("md-viewer.controller")
  for _, fn in ipairs({ "open", "close", "refresh", "clear_selection", "find_clear", "find_prompt" }) do
    t.eq("function", type(controller[fn]), ("controller.%s remains callable from Lua"):format(fn))
  end

  -- The find prompt is now the whole clearing story, so its dismissal path is
  -- worth pinning: :MdViewerFindClear and :MdViewerClearSelection were removed
  -- on the strength of it. Driven through a stubbed vim.ui.input and stubbed
  -- interaction functions, so this exercises controller.find_prompt's own
  -- decisions and never reaches the renderer.
  do
    local controller = require("md-viewer.controller")
    local interaction = require("md-viewer.interaction")

    local source_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(source_buf)
    local source_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local preview_win = vim.api.nvim_get_current_win()
    local preview_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(preview_win, preview_buf)
    local session = {
      source_buf = source_buf,
      source_win = source_win,
      preview_buf = preview_buf,
      preview_win = preview_win,
      closed = false,
    }

    local calls = {}
    local original = {
      find_set = interaction.find_set,
      find_clear = interaction.find_clear,
      clear_selection = interaction.clear_selection,
    }
    interaction.find_set = function(_, query) calls[#calls + 1] = "find_set:" .. query end
    interaction.find_clear = function() calls[#calls + 1] = "find_clear" end
    interaction.clear_selection = function() calls[#calls + 1] = "clear_selection" end

    local answer, prompt_opts
    local original_input = vim.ui.input
    vim.ui.input = function(opts, callback)
      prompt_opts = opts
      callback(answer)
    end

    -- A query runs the search, and the prompt is never seeded with the last
    -- one: every search starts from nothing.
    answer, calls = "needle", {}
    session.find_active, session.selection_active = true, true
    controller.find_prompt(session)
    t.eq(nil, prompt_opts.default, "the find prompt never prefills a previous query")
    t.eq(1, #calls, "a query issues exactly one action")
    t.eq("find_set:needle", calls[1], "and that action is the search")

    -- Dismissed with Escape: clears the search, then the selection.
    answer, calls = nil, {}
    session.find_active, session.selection_active = true, true
    controller.find_prompt(session)
    t.eq(2, #calls, "dismissing the prompt clears both the search and the selection")
    t.eq("find_clear", calls[1], "the search clears first")
    t.eq("clear_selection", calls[2], "then the selection")

    -- Submitting an empty line is the same gesture as Escape.
    answer, calls = "", {}
    session.find_active, session.selection_active = true, false
    controller.find_prompt(session)
    t.eq(1, #calls, "an empty query clears only what is actually active")
    t.eq("find_clear", calls[1], "and here that is the search alone")

    -- Nothing active: dismissing costs no round trip at all.
    answer, calls = nil, {}
    session.find_active, session.selection_active = false, false
    controller.find_prompt(session)
    t.eq(0, #calls, "dismissing an empty prompt with nothing active sends nothing")

    vim.ui.input = original_input
    interaction.find_set = original.find_set
    interaction.find_clear = original.find_clear
    interaction.clear_selection = original.clear_selection
    vim.api.nvim_win_close(preview_win, true)
    vim.api.nvim_buf_delete(preview_buf, { force = true })
    vim.api.nvim_buf_delete(source_buf, { force = true })
  end
end
