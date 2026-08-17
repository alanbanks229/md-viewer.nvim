local M = {}

-- The two schemes that mean "this buffer's document lives on an ssh-reachable
-- host": what inhesrom/remote-ssh.nvim names its buffers, and what netrw has
-- named remote-edited buffers since long before it. Everything else --
-- `oil://`, `fugitive://`, `term://`, `http://` -- is some plugin's private
-- namespace, not a document address, and parses to nil here so the callers'
-- existing refusals keep applying to it.
local SCHEMES = { scp = true, rsync = true }

---Parse a remote-document buffer name. Returns nil for anything that is not
---one, including every local path.
---
---This exists because the general path toolkit cannot be pointed at these
---names: `vim.fs.normalize("scp://h//a/b")` returns `"scp:/h/a/b"` -- the
---scheme and the authority/path boundary are both destroyed -- and
---`vim.fs.root` walked from that wreckage settles on whatever project
---encloses Neovim's *cwd*, which would hand a remote document a local
---security boundary. Remote names are therefore parsed and joined as plain
---strings, never through `vim.fs`.
---
---Two path shapes exist in the wild and disagree about one of them:
---`scheme://host//path` is absolute everywhere, but `scheme://host/path` is
---an absolute path to remote-ssh.nvim (its tree browser emits this shape) and
---a $HOME-relative one to netrw. The result carries both readings -- `path`
---as the absolute interpretation, `home_relative` as the other -- and the
---session's one remote round trip decides between them by testing which file
---exists (`remote_assets`), preferring absolute on a tie because
---remote-ssh.nvim is the shape's main producer.
---
---The authority is kept verbatim for display and URL building, and split into
---`ssh_target`/`port` for spawning: `ssh user@host:2222` reads the port as
---part of the hostname, so the port must travel as `-p`/`-P` argv instead.
---IPv6 literal hosts (`[::1]`) are not recognized.
function M.parse(name)
  if type(name) ~= "string" then return nil end
  local scheme, rest = name:match("^(%a[%w+.%-]*)://(.*)$")
  if not scheme or not SCHEMES[scheme:lower()] then return nil end
  local authority, tail = rest:match("^([^/]+)(/.+)$")
  if not authority then return nil end
  local absolute_certain = tail:sub(1, 2) == "//"
  local path = absolute_certain and tail:sub(2) or tail
  if path == "/" then return nil end
  local user, host_part = authority:match("^([^@]+)@(.+)$")
  if not host_part then host_part = authority end
  local host, port = host_part:match("^(.+):(%d+)$")
  if not host then host = host_part end
  return {
    scheme = scheme:lower(),
    authority = authority,
    user = user,
    host = host,
    port = port and tonumber(port) or nil,
    ssh_target = user and (user .. "@" .. host) or host,
    path = path,
    home_relative = not absolute_certain and path:sub(2) or nil,
    original = name,
  }
end

---Build the buffer name for another document on the same host, from a parsed
---name and an absolute remote path. Always the double-slash form: it is the
---one shape remote-ssh.nvim and netrw read identically, so a URL built here
---opens the same file whichever of them answers the `BufReadCmd`.
function M.build_url(parsed, absolute_path) return parsed.scheme .. "://" .. parsed.authority .. "/" .. absolute_path end

---Lexically normalize an absolute remote path: collapse `//` and `.`, fold
---`..` into its parent. Purely textual -- the remote filesystem is never
---consulted -- which is the point: containment must be decided *before*
---anything is fetched. `..` above the root clamps to the root, the same
---answer `path.resolve` gives on the Node side, so the two ends of the
---pipeline agree about every hostile path.
function M.normalize_remote(path)
  local parts = {}
  for segment in path:gmatch("[^/]+") do
    if segment == ".." then
      if #parts > 0 then table.remove(parts) end
    elseif segment ~= "." then
      parts[#parts + 1] = segment
    end
  end
  return "/" .. table.concat(parts, "/")
end

---Resolve a document-relative reference against a remote base directory. An
---absolute reference keeps itself, exactly as `path.resolve(baseDir, ...)`
---behaves in the renderer -- and, as there, being absolute grants nothing:
---the caller judges the *result* with `inside_remote`.
function M.join_remote(base_dir, relative)
  if relative:sub(1, 1) == "/" then return M.normalize_remote(relative) end
  return M.normalize_remote(base_dir .. "/" .. relative)
end

---The parent directory of an absolute remote path; "/" is its own parent.
function M.parent_remote(path)
  local parent = path:match("^(.*)/[^/]+$")
  if parent == nil or parent == "" then return "/" end
  return parent
end

---Purely lexical containment for remote paths, both already normalized.
---Mirrors security.lua's `lexically_inside`: the root itself, or a
---descendant past a `/` boundary -- `/p` does not contain `/pq`.
function M.inside_remote(root, candidate)
  if root == candidate then return true end
  local prefix = root:sub(-1) == "/" and root or (root .. "/")
  return candidate:sub(1, #prefix) == prefix
end

---The base directory for a *local* document, shared by the render request and
---link activation so the two can never disagree about what a relative path is
---relative to (they were previously two copies). Remote documents never come
---through here -- their base is the session's mirror directory.
function M.local_base_dir(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return vim.uv.cwd() end
  return vim.fs.dirname(vim.fs.normalize(name))
end

return M
