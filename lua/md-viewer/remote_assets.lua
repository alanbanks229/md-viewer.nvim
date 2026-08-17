local config = require("md-viewer.config")
local source = require("md-viewer.source")

local M = {}

---Every byte that moves between this machine and a remote host moves through
---this one function -- there is no second spawn site. That is what makes two
---claims testable rather than aspirational: the suite replaces it to run with
---no network at all, and the zero-transport regression *counts calls to it*
---to prove that scrolling an already-resolved document performs no remote
---I/O. The argv is executed directly, never via a local shell, so no string a
---document controls is ever locally shell-parsed.
function M._run(argv, opts, on_exit) return vim.system(argv, opts, on_exit) end

---Quote one string for a POSIX shell. Single quotes preserve every byte --
---spaces, `$`, backticks, quotes, newlines -- except the single quote itself,
---which becomes the standard close/escape/reopen sequence.
---
---This is the only escaping in the module, and it exists because the remote
---side unavoidably involves a shell: sshd hands the command line to the login
---shell. The composition is always `sh -c '<script>' md-viewer '<arg>'...`,
---so document-controlled strings only ever travel as positional parameters to
---a script that never eval's them -- provided this function is correct, which
---is why the tests run its output through a real `sh` and compare bytes.
---A fish login shell parses single quotes differently ('\'' does not close
---and reopen); that is a documented limitation shared with remote-ssh.nvim.
function M.quote(text) return "'" .. text:gsub("'", [['\'']]) .. "'" end

local function sh_command(script, args)
  local parts = { "sh", "-c", M.quote(script), "md-viewer" }
  for _, arg in ipairs(args) do
    parts[#parts + 1] = M.quote(arg)
  end
  return table.concat(parts, " ")
end

---Build the argv for one remote command. BatchMode because a headless ssh
---that finds no usable key must fail visibly, not park an invisible password
---prompt under the preview; ConnectTimeout bounds the TCP setup the same way
---`fetch_timeout_ms` bounds the whole operation. Nothing here touches
---ControlMaster or host-key policy: multiplexing and trust belong to the
---user's own ssh configuration, and a wrapper can be substituted whole
---through `remote.ssh_command`.
local function ssh_argv(cfg, parsed, command)
  local argv = {}
  vim.list_extend(argv, cfg.remote.ssh_command)
  vim.list_extend(argv, { "-o", "BatchMode=yes", "-o", "ConnectTimeout=10" })
  if parsed.port then vim.list_extend(argv, { "-p", tostring(parsed.port) }) end
  argv[#argv + 1] = parsed.ssh_target
  argv[#argv + 1] = command
  return argv
end

-- One round trip that answers everything a session needs to exist: whether
-- the document is at its absolute path or (netrw's single-slash reading)
-- relative to $HOME, the physical directory it lives in, and the enclosing
-- project root by the same markers the local side uses. `pwd -P` makes the
-- answers physical paths, so the containment judgments downstream are made
-- against symlink-resolved names -- the remote counterpart of the
-- fs_realpath discipline in security.lua.
--
-- Only the document's own path is ever echoed back (a buffer name cannot
-- contain a newline, so line-oriented parsing is safe here); asset paths
-- never appear in any remote output.
local ROOT_WALK = [[
doc="$1"; rel="$2"; shift 2
if [ ! -f "$doc" ] && [ -n "$rel" ] && [ -f "$rel" ]; then doc="$rel"; fi
if [ ! -f "$doc" ]; then echo "outcome=missing"; exit 0; fi
dir=$(dirname -- "$doc") || exit 1
name=$(basename -- "$doc") || exit 1
dir=$(cd -- "$dir" && pwd -P) || { echo "outcome=missing"; exit 0; }
root=""
probe="$dir"
while :; do
  for marker in "$@"; do
    if [ -e "$probe/$marker" ]; then root="$probe"; break 2; fi
  done
  if [ "$probe" = "/" ]; then break; fi
  probe=$(dirname -- "$probe")
done
if [ -z "$root" ]; then root="$dir"; fi
echo "outcome=ok"
echo "doc=$dir/$name"
echo "base=$dir"
echo "root=$root"
]]

local function parse_lines(stdout)
  local fields = {}
  for line in (stdout or ""):gmatch("[^\n]+") do
    local key, value = line:match("^(%w+)=(.*)$")
    if key then fields[key] = value end
  end
  return fields
end

---Resolve the remote document's physical path, base directory and project
---root in one ssh call. `on_done(info, nil)` with normalized absolute paths,
---or `on_done(nil, reason)` -- and the reason is user-facing, so it names
---what to check rather than dumping a transcript.
function M.resolve_root(parsed, on_done)
  local cfg = config.get()
  local args = { parsed.path, parsed.home_relative or "" }
  vim.list_extend(args, cfg.security.document_root_markers)
  local argv = ssh_argv(cfg, parsed, sh_command(ROOT_WALK, args))
  M._run(argv, { text = true, timeout = cfg.remote.fetch_timeout_ms }, function(out)
    vim.schedule(function()
      if out.code == 124 then
        on_done(nil, ("timed out reaching %s after %d ms"):format(parsed.ssh_target, cfg.remote.fetch_timeout_ms))
        return
      end
      if out.code ~= 0 then
        local detail = (out.stderr or ""):gsub("%s+$", "")
        on_done(
          nil,
          ("ssh to %s failed (%s)"):format(parsed.ssh_target, detail ~= "" and detail or "exit " .. out.code)
        )
        return
      end
      local fields = parse_lines(out.stdout)
      if fields.outcome == "missing" then
        on_done(nil, ("%s does not exist on %s"):format(parsed.path, parsed.ssh_target))
        return
      end
      if fields.outcome ~= "ok" or not fields.doc or not fields.base or not fields.root then
        on_done(nil, "unexpected reply from the remote shell (a POSIX sh login shell is required)")
        return
      end
      on_done({
        path = source.normalize_remote(fields.doc),
        base_dir = source.normalize_remote(fields.base),
        root = source.normalize_remote(fields.root),
      })
    end)
  end)
end

local function short_hash(text) return vim.fn.sha256(text):sub(1, 16) end

---The local directory that mirrors one remote project root, created on first
---use. Keyed by authority -- not just host -- because two accounts on one
---machine may see different files, and their mirrors must not mix.
function M.mirror_root(parsed, remote_root)
  local dir = vim.fs.joinpath(
    vim.fn.stdpath("cache"),
    "md-viewer",
    "remote",
    short_hash(parsed.authority),
    short_hash(remote_root)
  )
  vim.fn.mkdir(dir, "p")
  return dir
end

---Map an absolute remote path to its place in the mirror, or nil when it
---does not sit under the remote root. The nil is load-bearing: a path this
---function refuses can never gain a local name, so nothing outside the
---remote project can ever be written inside the mirror the renderer trusts.
function M.mirror_path(mirror_root, remote_root, remote_abs)
  if not source.inside_remote(remote_root, remote_abs) then return nil end
  if remote_root == remote_abs then return mirror_root end
  local suffix = remote_abs:sub(#remote_root + (remote_root == "/" and 1 or 2))
  return vim.fs.joinpath(mirror_root, suffix)
end

return M
