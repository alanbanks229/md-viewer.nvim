local M = {}

function M.document_root(buf, configured)
  if configured and configured ~= "" then return vim.fs.normalize(configured) end
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and vim.fs.dirname(vim.fs.normalize(name)) or vim.uv.cwd()
end

function M.summary(cfg, buf)
  return {
    network_blocked = not cfg.security.network,
    raw_html = cfg.render.raw_html,
    local_images = cfg.render.local_images,
    document_root = M.document_root(buf, cfg.security.document_root),
    max_local_image_bytes = cfg.render.max_local_image_bytes,
    overrides = (cfg.security.network or cfg.render.raw_html) and "SECURITY RELAXED" or "none",
  }
end

return M
