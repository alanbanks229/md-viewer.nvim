return function(t)
  require("md-viewer").setup({ image = { backend = "cells" } })
  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# One", "", "body" })
  local controller = require("md-viewer.controller")
  local session = assert(controller.open("right"))
  local navigation = require("md-viewer.navigation")
  navigation.attach(session, function() end)
  local g_mapping = vim.api.nvim_buf_call(
    session.preview_buf,
    function() return vim.fn.maparg("G", "n", false, true) end
  )
  t.ok(not vim.tbl_isempty(g_mapping), "preview-local G mapping exists")
  controller.close(source)
end
