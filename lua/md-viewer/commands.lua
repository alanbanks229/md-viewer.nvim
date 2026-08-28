local controller = require("md-viewer.controller")

local M = {}

function M.setup()
  -- One command for the preview's visibility, not three. `controller.open()`
  -- and `controller.close()` remain the Lua API and are what to call from an
  -- autocmd or another plugin: `open()` is idempotent and never closes an
  -- existing preview, which `MdViewerToggle` deliberately does.
  vim.api.nvim_create_user_command(
    "MdViewerToggle",
    function(args) controller.toggle(args.args ~= "" and args.args or nil) end,
    { nargs = "?", complete = function() return { "right", "left", "below", "above" } end }
  )
  vim.api.nvim_create_user_command("MdViewerHealth", function() require("md-viewer.health").show() end, {})
  vim.api.nvim_create_user_command("MdViewerDebug", function() require("md-viewer.debug").show() end, {})
  -- A command, and never something a preview does on its own: it floods the
  -- terminal for the better part of a minute. Run once per machine; the answer
  -- is cached there and `render.ssh_link_bytes_per_sec = "auto"` reads it.
  vim.api.nvim_create_user_command(
    "MdViewerMeasureLink",
    function() require("md-viewer.linkrate").measure_command() end,
    { desc = "md-viewer: measure this SSH link's throughput and cache it for this machine" }
  )
  vim.api.nvim_create_user_command("MdViewerCopy", function() controller.copy() end, {})
  -- No :MdViewerClearSelection or :MdViewerFindClear. Closing this prompt
  -- without a query clears both, and `<Esc>` in the preview window still does
  -- the same one press at a time -- see controller.find_prompt().
  vim.api.nvim_create_user_command("MdViewerFind", function(args)
    if args.args ~= "" then
      controller.find(args.args)
      return
    end
    controller.find_prompt()
  end, { nargs = "?" })
  vim.api.nvim_create_user_command("MdViewerFindNext", function() controller.find_next() end, {})
  vim.api.nvim_create_user_command("MdViewerFindPrevious", function() controller.find_previous() end, {})
  vim.api.nvim_create_user_command("MdViewerBack", function() controller.history_back() end, {})
  vim.api.nvim_create_user_command("MdViewerForward", function() controller.history_forward() end, {})
  vim.api.nvim_create_user_command(
    "MdViewerToggleAbsoluteLineNumbers",
    function() controller.toggle_line_numbers("absolute") end,
    {}
  )
  vim.api.nvim_create_user_command(
    "MdViewerToggleRelativeLineNumbers",
    function() controller.toggle_line_numbers("relative") end,
    {}
  )
end

return M
