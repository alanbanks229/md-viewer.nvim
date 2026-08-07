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
  vim.api.nvim_create_user_command("MdViewerCopy", function() controller.copy() end, {})
  vim.api.nvim_create_user_command("MdViewerClearSelection", function() controller.clear_selection() end, {})
  vim.api.nvim_create_user_command("MdViewerFind", function(args)
    if args.args ~= "" then
      controller.find(args.args)
      return
    end
    vim.ui.input({ prompt = "md-viewer find: " }, function(input)
      if input and input ~= "" then controller.find(input) end
    end)
  end, { nargs = "?" })
  vim.api.nvim_create_user_command("MdViewerFindNext", function() controller.find_next() end, {})
  vim.api.nvim_create_user_command("MdViewerFindPrevious", function() controller.find_previous() end, {})
  vim.api.nvim_create_user_command("MdViewerFindClear", function() controller.find_clear() end, {})
  vim.api.nvim_create_user_command("MdViewerBack", function() controller.history_back() end, {})
  vim.api.nvim_create_user_command("MdViewerForward", function() controller.history_forward() end, {})
end

return M
