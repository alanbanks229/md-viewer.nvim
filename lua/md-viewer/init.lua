local M = { version = "0.3.0" }
local initialized = false

function M.setup(opts)
  if vim.fn.has("nvim-0.12") ~= 1 then error("md-viewer.nvim requires Neovim 0.12+") end
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
