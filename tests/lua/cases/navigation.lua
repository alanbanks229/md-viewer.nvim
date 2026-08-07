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

  -- H/L drive the preview history. Buffer-local, so they only ever shadow
  -- "top/bottom of screen" inside the preview's own scratch buffer -- which
  -- holds no text for those to address in the first place.
  local function preview_map(lhs)
    return vim.api.nvim_buf_call(session.preview_buf, function() return vim.fn.maparg(lhs, "n", false, true) end)
  end
  for _, lhs in ipairs({ "H", "L" }) do
    local mapping = preview_map(lhs)
    t.ok(not vim.tbl_isempty(mapping), ("preview-local %s mapping exists"):format(lhs))
    t.eq(session.preview_buf, mapping.buffer ~= 0 and session.preview_buf or nil, lhs .. " is buffer-local")
  end
  controller.close(source)

  -- interaction.links = false leaves them off: a link activation is the only
  -- thing that ever puts a second document in the history.
  require("md-viewer").setup({ image = { backend = "cells" }, interaction = { links = false } })
  vim.api.nvim_set_current_buf(source)
  local without_links = assert(controller.open("right"))
  navigation.attach(without_links, function() end)
  for _, lhs in ipairs({ "H", "L" }) do
    local mapping = vim.api.nvim_buf_call(
      without_links.preview_buf,
      function() return vim.fn.maparg(lhs, "n", false, true) end
    )
    t.ok(vim.tbl_isempty(mapping), ("%s is not mapped when interaction.links is false"):format(lhs))
  end
  controller.close(source)
  require("md-viewer").setup({ image = { backend = "cells" } })
end
