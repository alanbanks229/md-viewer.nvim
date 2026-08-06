local M = {}

function M.document_root(buf, configured)
  if configured and configured ~= "" then return vim.fs.normalize(configured) end
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and vim.fs.dirname(vim.fs.normalize(name)) or vim.uv.cwd()
end

---Mirrors renderer/src/security.js's isInside(): true when `candidate` is
---`root` itself or a real (symlink-resolved) descendant of it. Both sides are
---resolved with fs_realpath so a symlink cannot walk a link target outside
---the document root and still read as "inside".
function M.is_inside(root, candidate)
  local root_real = vim.uv.fs_realpath(root)
  local candidate_real = vim.uv.fs_realpath(candidate)
  if not root_real or not candidate_real then return false end
  if root_real == candidate_real then return true end
  local prefix = root_real:sub(-1) == "/" and root_real or (root_real .. "/")
  return candidate_real:sub(1, #prefix) == prefix
end

local function percent_decode(str)
  return (str:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

local function looks_absolute(path) return path:match("^/") ~= nil or path:match("^%a:[/\\]") ~= nil end

---Resolve a `local_file`-classified link href (a bare relative path or a
---`file:` URI) against `base_dir`, refusing anything that escapes
---`document_root` once symlinks are resolved. Returns `nil` on any escape,
---malformed input, or a target that does not exist -- never a guess.
function M.resolve_local_link(href, base_dir, document_root)
  if type(href) ~= "string" or href == "" then return nil end
  local raw = href
  if raw:match("^file://") then
    raw = raw:sub(8)
  elseif raw:match("^file:") then
    raw = raw:sub(6)
  end
  raw = raw:gsub("[?#].*$", "")
  local ok, decoded = pcall(percent_decode, raw)
  if ok and decoded ~= "" then raw = decoded end
  if raw == "" then return nil end
  local resolved = looks_absolute(raw) and vim.fs.normalize(raw) or vim.fs.normalize(vim.fs.joinpath(base_dir, raw))
  if not M.is_inside(document_root, resolved) then return nil end
  return resolved
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
