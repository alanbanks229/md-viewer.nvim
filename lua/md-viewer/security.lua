local M = {}

M.DEFAULT_ROOT_MARKERS = { ".git", ".hg", ".svn" }

---The boundary every local link and local image is confined to.
---
---An explicit `security.document_root` always wins. Otherwise the root is the
---enclosing *project* -- the nearest ancestor holding one of `markers` --
---because Markdown inside a repository routinely links across it
---(`../README.md` from `docs/`, or a repo-root-relative `docs/x.md`). Keying
---the root to the document's own directory, as this did before, made every
---such link unreachable while the document sat in a subdirectory, and reported
---it as a security refusal.
---
---With no marker found there is no project to speak of, so the previous
---behaviour stands unchanged: the document's own directory, or the cwd for a
---buffer that has never been written.
function M.document_root(buf, configured, markers)
  if configured and configured ~= "" then return vim.fs.normalize(configured) end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return vim.uv.cwd() end
  local normalized = vim.fs.normalize(name)
  -- Search from the document's *path*, not its buffer: `vim.fs.root` begins
  -- from Neovim's current directory for any buffer with a non-empty 'buftype',
  -- which would silently root an unusual source buffer somewhere else entirely.
  local ok, root = pcall(vim.fs.root, normalized, markers or M.DEFAULT_ROOT_MARKERS)
  if ok and root and root ~= "" then return vim.fs.normalize(root) end
  return vim.fs.dirname(normalized)
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

---Purely lexical containment: no filesystem access at all. Used to reject an
---escaping path *before* anything touches the disk, so the "does not exist"
---answer below is only ever computed for a path already known to be inside
---the root. Otherwise the two distinct messages would let a hostile document
---probe for the existence of files outside the root by observing which one
---came back.
local function lexically_inside(root, candidate)
  if root == candidate then return true end
  local prefix = root:sub(-1) == "/" and root or (root .. "/")
  return candidate:sub(1, #prefix) == prefix
end

---Resolve a `local_file`-classified link href (a bare relative path or a
---`file:` URI) against `base_dir`, refusing anything that escapes
---`document_root` once symlinks are resolved. Returns `nil` on any escape,
---malformed input, or a target that does not exist -- never a guess.
---
---The second return value names *which* of those it was
---(`"malformed"`/`"outside_root"`/`"missing"`), because all three used to be
---reported to the user as "outside the document root" -- which for a link to a
---file that simply is not there is untrue, and sends the reader looking for a
---security setting to change. Callers that only test the first value are
---unaffected: Lua discards extra returns.
function M.resolve_local_link(href, base_dir, document_root)
  if type(href) ~= "string" or href == "" then return nil, "malformed" end
  local raw = href
  if raw:match("^file://") then
    raw = raw:sub(8)
  elseif raw:match("^file:") then
    raw = raw:sub(6)
  end
  raw = raw:gsub("[?#].*$", "")
  local ok, decoded = pcall(percent_decode, raw)
  if ok and decoded ~= "" then raw = decoded end
  if raw == "" then return nil, "malformed" end
  local resolved = looks_absolute(raw) and vim.fs.normalize(raw) or vim.fs.normalize(vim.fs.joinpath(base_dir, raw))
  if not lexically_inside(vim.fs.normalize(document_root), resolved) then return nil, "outside_root" end
  if not vim.uv.fs_realpath(resolved) then return nil, "missing" end
  -- Inside by path, and it exists. The symlink-resolved check is what decides
  -- it: a link inside the root whose target walks outside is still an escape.
  if not M.is_inside(document_root, resolved) then return nil, "outside_root" end
  return resolved
end

-- Handing a path to the system handler (`vim.ui.open`) means asking the OS to
-- do whatever it considers appropriate with it -- which for these is "run it".
-- A Markdown document is untrusted content, so a link it contains must never be
-- able to reach one, no matter how the document root is configured. The root is
-- not a defence here: a repository you cloned can ship `setup.command` beside
-- its README and link to it from inside the root.
--
-- Extensions only cover what has a name; `.app` and `.workflow` are directories
-- rather than files, which is why this cannot be a stat check alone.
local system_executable_extensions = {
  -- macOS bundles and scripts the Finder executes
  app = true,
  action = true,
  appex = true,
  command = true,
  kext = true,
  osax = true,
  prefpane = true,
  saver = true,
  scptd = true,
  service = true,
  terminal = true,
  workflow = true,
  -- Disk images and installers: mounting or installing one is the first step
  -- of an attack, not a neutral "view this file".
  dmg = true,
  iso = true,
  mpkg = true,
  -- Windows
  bat = true,
  cmd = true,
  com = true,
  cpl = true,
  exe = true,
  hta = true,
  jse = true,
  lnk = true,
  msi = true,
  pif = true,
  reg = true,
  scr = true,
  vbe = true,
  vbs = true,
  wsf = true,
  wsh = true,
  -- Linux / cross-platform
  appimage = true,
  desktop = true,
  jar = true,
  run = true,
}

---True when `path` must not be handed to the system handler.
---
---Two independent signals, because neither alone is sufficient: the extension
---list catches bundles (which are directories, so no file mode applies) and
---platform conventions, while the execute bit catches an ordinary file with no
---telling name at all. Only ever consulted for a target Neovim itself has no
---filetype for -- a `.md`, a `.lua`, a `.png` never reaches this.
function M.is_system_executable(path)
  if type(path) ~= "string" or path == "" then return false end
  local extension = path:match("%.([%a%d_]+)$")
  if extension and system_executable_extensions[extension:lower()] then return true end
  local stat = vim.uv.fs_stat(path)
  if not stat then return false end
  -- A directory's mode bits mean "may be traversed", not "may be run".
  if stat.type ~= "file" then return false end
  return type(stat.mode) == "number" and bit.band(stat.mode, tonumber("111", 8)) ~= 0
end

function M.summary(cfg, buf)
  local configured = cfg.security.document_root
  local root = M.document_root(buf, configured, cfg.security.document_root_markers)
  local name = vim.api.nvim_buf_get_name(buf)
  -- An explicitly configured root that does not contain the document being
  -- previewed refuses every local link and image in it. That is the correct
  -- behaviour for the setting, but on its own it surfaces only one refusal at a
  -- time, which reads as a broken plugin rather than as a configured boundary.
  -- Report the condition itself so :MdViewerHealth can name it once.
  --
  -- Only ever claimed for a buffer backed by a real file. `:checkhealth` runs
  -- with its own `health://` buffer current, and a name that resolves to
  -- nothing is not a document sitting outside anything -- reporting one as
  -- excluded produced a confident warning about a file that does not exist.
  local excludes_current = false
  local real = name ~= "" and vim.uv.fs_realpath(vim.fs.normalize(name)) or nil
  if configured and configured ~= "" and real then excludes_current = not M.is_inside(root, real) end
  return {
    remote_image_hosts = cfg.security.remote_images,
    raw_html = cfg.security.raw_html,
    local_images = cfg.render.local_images,
    document_root = root,
    document_root_source = (configured and configured ~= "") and "configured (security.document_root)"
      or "detected from the project enclosing the document",
    document_root_excludes_current = excludes_current,
    -- A root of "/" is a legitimate, supported choice -- it makes the preview
    -- open whatever Neovim would open -- but it does switch off the containment
    -- that SECURITY.md describes for local images, so it is reported rather
    -- than left to be inferred from the path.
    document_root_unbounded = root == "/",
    max_local_image_bytes = cfg.render.max_local_image_bytes,
    overrides = (#cfg.security.remote_images > 0 or cfg.security.raw_html) and "SECURITY RELAXED" or "none",
  }
end

return M
