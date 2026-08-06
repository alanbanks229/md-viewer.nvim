return function(t)
  -- The preview title should distinguish "I asked for text-cell rendering"
  -- from "auto-selection silently fell back to text-cell rendering because
  -- no graphical backend was available" (e.g. macOS Terminal.app, or any
  -- terminal with no Kitty-graphics evidence) -- the latter looks like a bug
  -- if the preview gives no indication why it's degraded.
  local config = require("md-viewer.config")
  local controller = require("md-viewer.controller")

  config.reset()
  require("md-viewer").setup({ image = { backend = "cells" } })
  local explicit_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(explicit_buf)
  vim.bo[explicit_buf].filetype = "markdown"
  local explicit_session = assert(controller.open("right"))
  local explicit_winbar = vim.api.nvim_get_option_value("winbar", { win = explicit_session.preview_win })
  t.eq(false, not not explicit_winbar:match("text%-only"), "explicit cells backend shows no fallback warning")
  controller.close(explicit_buf)

  config.reset()
  require("md-viewer").setup({ image = { backend = "auto" }, terminal = { profile = "unknown" } })
  local fallback_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(fallback_buf)
  vim.bo[fallback_buf].filetype = "markdown"
  local fallback_session = assert(controller.open("right"))
  t.eq("cells", fallback_session.backend.name, "auto selection lands on cells with no graphics evidence")
  local fallback_winbar = vim.api.nvim_get_option_value("winbar", { win = fallback_session.preview_win })
  t.ok(fallback_winbar:match("text%-only"), "auto fallback to cells shows a warning in the preview title")
  t.ok(fallback_winbar:match("MdViewerHealth"), "warning points at :MdViewerHealth for diagnosis")
  controller.close(fallback_buf)
  config.reset()
end
