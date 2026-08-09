return function(t)
  -- The command surface is a public API, and the two ways it goes wrong are
  -- silent: a command that quietly stops existing, and one that survives a
  -- rename in code but not in the docs. Both are cheap to pin here.
  require("md-viewer").setup({})

  local function exists(name) return vim.fn.exists(":" .. name) == 2 end

  for _, name in ipairs({
    "MdViewerToggle",
    "MdViewerRefresh",
    "MdViewerHealth",
    "MdViewerDebug",
    "MdViewerCopy",
    "MdViewerClearSelection",
    "MdViewerFind",
    "MdViewerFindNext",
    "MdViewerFindPrevious",
    "MdViewerFindClear",
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
  t.eq("function", type(require("md-viewer.controller").open), "controller.open remains callable from Lua")
  t.eq("function", type(require("md-viewer.controller").close), "controller.close remains callable from Lua")

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
  for _, gone in ipairs({ "MdViewerOpen", "MdViewerClose" }) do
    t.ok(doc:find(gone, 1, true) == nil, ("the help no longer documents %s"):format(gone))
    t.ok(readme:find(gone, 1, true) == nil, ("the README no longer documents %s"):format(gone))
  end
end
