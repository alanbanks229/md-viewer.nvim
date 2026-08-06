local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fs.dirname(vim.fs.dirname(script))
vim.opt.runtimepath:prepend(root)
vim.opt.shadafile = "NONE"
require("md-viewer.feasibility")
vim.schedule(function()
  if not require("md-viewer.feasibility").start() then
    vim.notify("See docs/feasibility.md for this host's recorded result", vim.log.levels.WARN)
  end
end)
