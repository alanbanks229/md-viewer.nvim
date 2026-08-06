local controller = require("md-viewer.controller")

local M = {}

function M.setup()
  vim.api.nvim_create_user_command(
    "MdViewerOpen",
    function(args) controller.open(args.args ~= "" and args.args or nil) end,
    { nargs = "?", complete = function() return { "right", "left", "below", "above" } end }
  )
  vim.api.nvim_create_user_command("MdViewerClose", function() controller.close() end, {})
  vim.api.nvim_create_user_command(
    "MdViewerToggle",
    function(args) controller.toggle(args.args ~= "" and args.args or nil) end,
    { nargs = "?", complete = function() return { "right", "left", "below", "above" } end }
  )
  vim.api.nvim_create_user_command("MdViewerRefresh", function() controller.refresh() end, {})
  vim.api.nvim_create_user_command("MdViewerHealth", function() require("md-viewer.health").show() end, {})
  vim.api.nvim_create_user_command("MdViewerDebug", function() require("md-viewer.debug").show() end, {})
end

return M
