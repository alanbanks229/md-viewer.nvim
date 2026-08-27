local M = { version = "0.3.0-rc9" }
local initialized = false
local configured = false

function M.setup(opts)
  if vim.fn.has("nvim-0.12") ~= 1 then error("md-viewer.nvim requires Neovim 0.12+") end
  -- plugin/md-viewer.lua calls this with no arguments so zero-config works.
  -- Plugin files load *after* a manual init file has already called setup
  -- with real options, so the argless call must defer to an explicit
  -- configuration rather than clobber it back to defaults -- measured doing
  -- exactly that through `nvim -u` in the live-pipeline rig. An explicit
  -- setup({...}) still reconfigures every time, as documented.
  if opts == nil and configured then return M end
  configured = configured or opts ~= nil
  require("md-viewer.config").setup(opts or {})
  if not initialized then
    initialized = true
    require("md-viewer.commands").setup()
    require("md-viewer.controller").setup_autocmds()
  end
  return M
end

function M.open(position) return require("md-viewer.controller").open(position) end
function M.close() return require("md-viewer.controller").close() end
function M.toggle(position) return require("md-viewer.controller").toggle(position) end
function M.refresh() return require("md-viewer.controller").refresh() end

return M
