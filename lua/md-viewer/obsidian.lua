local config = require("md-viewer.config")
local security = require("md-viewer.security")

local M = {}

local function source_path(session)
  local name = session and session.source_buf and vim.api.nvim_buf_get_name(session.source_buf) or ""
  if name == "" then return nil end
  return vim.uv.fs_realpath(vim.fs.normalize(name))
end

function M.vault_root(session)
  if not (session and session.source_buf) then return nil, "malformed" end
  local cfg = config.get()
  local configured = cfg.obsidian.vault_root
  local root = configured and vim.fs.normalize(vim.fn.expand(configured))
    or security.document_root(session.source_buf, cfg.security.document_root, cfg.security.document_root_markers)
  local real = root and vim.uv.fs_realpath(root) or nil
  local stat = real and vim.uv.fs_stat(real) or nil
  if not stat or stat.type ~= "directory" then return nil, "missing_root" end
  local source = source_path(session)
  if not source or not security.is_inside(real, source) then return nil, "outside_root" end
  return real
end

local function markdown_files(root)
  local files = {}
  local function walk(dir)
    local scan = vim.uv.fs_scandir(dir)
    if not scan then return end
    while true do
      local name, kind = vim.uv.fs_scandir_next(scan)
      if not name then break end
      local path = vim.fs.joinpath(dir, name)
      if kind == "directory" and name ~= ".obsidian" then
        walk(path)
      elseif kind == "file" or kind == "link" then
        local stat = vim.uv.fs_stat(path)
        if stat and stat.type == "file" and name:lower():sub(-3) == ".md" and security.is_inside(root, path) then
          files[#files + 1] = vim.uv.fs_realpath(path)
        end
      end
    end
  end
  walk(root)
  table.sort(files)
  return files
end

local function relative(root, path)
  local prefix = root:sub(-1) == "/" and root or root .. "/"
  return path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or path
end

---Resolve one Obsidian note target. The callback receives `(path, reason)`;
---an ambiguous target is completed asynchronously through `vim.ui.select`.
---The vault is scanned on every activation, so no filename index survives a
---note add or rename.
function M.resolve(session, target, callback)
  if type(target) ~= "string" or target == "" or target:find("\\", 1, true) then
    callback(nil, "malformed")
    return
  end
  local root, root_reason = M.vault_root(session)
  if not root then
    callback(nil, root_reason)
    return
  end

  if target:find("/", 1, true) then
    local note = target:lower():sub(-3) == ".md" and target or (target .. ".md")
    local resolved, reason = security.resolve_local_link(note, root, root)
    if resolved and resolved:lower():sub(-3) ~= ".md" then
      resolved, reason = nil, "malformed"
    end
    callback(resolved, reason)
    return
  end

  local stem = vim.fn.tolower((target:gsub("%.[Mm][Dd]$", "")))
  local matches = {}
  for _, path in ipairs(markdown_files(root)) do
    local name = vim.fs.basename(path)
    if vim.fn.tolower(name:sub(1, -4)) == stem then matches[#matches + 1] = path end
  end
  if #matches == 0 then
    callback(nil, "missing")
  elseif #matches == 1 then
    callback(matches[1])
  else
    vim.ui.select(matches, {
      prompt = ("Md-Viewer: choose Obsidian note for [[%s]]"):format(target),
      format_item = function(path) return relative(root, path) end,
    }, function(choice)
      if choice then callback(choice) end
    end)
  end
end

function M.relative_path(session, path)
  local root = M.vault_root(session)
  return root and relative(root, path) or path
end

return M
