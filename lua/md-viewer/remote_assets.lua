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

-- ---------------------------------------------------------------------------
-- The fetch pipeline. A render reports every file-shaped image source with
-- its outcome; this turns the report into at most one stat batch and one
-- fetch per previously unseen file, then asks for one more render. Repeat
-- reports of the same document -- every scroll, every keystroke -- must cost
-- zero transport calls, which is what the in-flight set, the negative cache
-- and the once-per-session validation below exist to guarantee.
-- ---------------------------------------------------------------------------

-- The same answer renderer/src/security.js gives for a local file: only
-- these five extensions are ever read, so nothing else is worth a round trip.
local FETCHABLE_EXTENSIONS = { png = true, jpg = true, jpeg = true, gif = true, webp = true }

-- (authority .. "\0" .. absolute path) -> vim.uv.now() deadline. A file that
-- is missing, oversize, or a symlink stays refused for this long rather than
-- being re-asked on every keystroke -- the same shape and the same 60s as
-- remote-images.js's negative cache.
local NEGATIVE_TTL_MS = 60000
local negative = {}

local function negative_key(parsed, remote_abs) return parsed.authority .. "\0" .. remote_abs end

-- The renderer's own decoding, shared through source.decode_href: the two
-- sides must agree on what file a source names, or the fetch would populate
-- a path the renderer never reads. (Image sources never carry file: -- the
-- report excludes them -- so the prefix strip in there is inert here.)
local decode_source = source.decode_href

-- Emits one line per path, by *index* -- file names never appear in remote
-- output, so a hostile name cannot corrupt the line-oriented parse. Refusals
-- happen remote-side where the facts are: a symlink is refused outright
-- (stricter than the local policy's resolved-target check, because the fetch
-- would materialize the target's bytes and hide the indirection), and a file
-- whose physical directory has escaped the root -- a symlinked parent -- is
-- refused as outside. `pwd -P` resolves what `[ -L ]` cannot see.
local STAT_BATCH = [[
root="$1"; shift
i=0
for p in "$@"; do
  i=$((i+1))
  if [ -L "$p" ]; then echo "i=$i s=symlink"; continue; fi
  if [ ! -f "$p" ]; then echo "i=$i s=missing"; continue; fi
  d=$(dirname -- "$p") || { echo "i=$i s=error"; continue; }
  d=$(cd -- "$d" 2>/dev/null && pwd -P) || { echo "i=$i s=error"; continue; }
  if [ "$root" != "/" ]; then
    case "$d/" in
      "$root"/*) ;;
      *) echo "i=$i s=outside"; continue;;
    esac
  fi
  z=$(stat -c %s -- "$p" 2>/dev/null || stat -f %z -- "$p" 2>/dev/null) || { echo "i=$i s=error"; continue; }
  m=$(stat -c %Y -- "$p" 2>/dev/null || stat -f %m -- "$p" 2>/dev/null) || { echo "i=$i s=error"; continue; }
  echo "i=$i s=ok z=$z m=$m"
done
]]

-- `--` so a leading-dash name is a file, never an option; the path itself is
-- a positional parameter, never script text.
local FETCH_ONE = [[cat -- "$1"]]

local function parse_stat_lines(stdout)
  local rows = {}
  for line in (stdout or ""):gmatch("[^\n]+") do
    local index, status = line:match("^i=(%d+) s=(%w+)")
    if index then
      rows[tonumber(index)] = {
        status = status,
        size = tonumber(line:match(" z=(%d+)")),
        mtime = tonumber(line:match(" m=(%d+)")),
      }
    end
  end
  return rows
end

local function session_live(session) return not session.closed and session.remote ~= nil end

local function bookkeeping(remote)
  remote.assets = remote.assets or { pending = {}, fetched = 0, refused = 0, failed = 0, validated = false }
  return remote.assets
end

---Write fetched bytes under the mirror path atomically: a temporary name in
---the same directory, then rename, so a concurrent Neovim sharing this mirror
---can never read a half-written image. The file's mtime is set to the remote
---mtime afterwards -- that is what lets a later session revalidate with one
---stat and no transfer. (Eviction sorts by the same mtime, so its "oldest
---first" is approximate for assets whose remote mtimes are ancient; a wrong
---guess there costs one refetch, never correctness.)
local function store(mirror_path, bytes, mtime)
  vim.fn.mkdir(vim.fs.dirname(mirror_path), "p")
  local partial = mirror_path .. ".partial-" .. tostring(vim.uv.hrtime())
  local fd = vim.uv.fs_open(partial, "w", 384)
  if not fd then return false end
  local written = vim.uv.fs_write(fd, bytes, 0)
  vim.uv.fs_close(fd)
  if written ~= #bytes then
    vim.uv.fs_unlink(partial)
    return false
  end
  if not vim.uv.fs_rename(partial, mirror_path) then
    vim.uv.fs_unlink(partial)
    return false
  end
  if mtime then vim.uv.fs_utime(mirror_path, mtime, mtime) end
  return true
end

---Delete oldest files until the whole remote mirror fits the configured
---budget again. Runs after a batch that wrote something, over the entire
---mirror tree -- all hosts, all projects -- because the budget is global.
---`keep` protects this batch's own writes from a remote mtime old enough to
---sort them "oldest".
local function evict(cfg, keep)
  local base = vim.fs.joinpath(vim.fn.stdpath("cache"), "md-viewer", "remote")
  local files, total = {}, 0
  for name, kind in vim.fs.dir(base, { depth = math.huge }) do
    if kind == "file" then
      local path = vim.fs.joinpath(base, name)
      local stat = vim.uv.fs_stat(path)
      if stat then
        files[#files + 1] = { path = path, size = stat.size, mtime = stat.mtime.sec }
        total = total + stat.size
      end
    end
  end
  if total <= cfg.remote.cache_max_bytes then return end
  table.sort(files, function(a, b) return a.mtime < b.mtime end)
  for _, file in ipairs(files) do
    if total <= cfg.remote.cache_max_bytes then break end
    if not keep[file.path] then
      vim.uv.fs_unlink(file.path)
      total = total - file.size
    end
  end
end

local function fetch_approved(session, parsed, jobs, on_changed)
  local cfg = config.get()
  local remote = session.remote
  local book = bookkeeping(remote)
  local outstanding = #jobs
  local changed = false
  local wrote = {}
  for _, job in ipairs(jobs) do
    local argv = ssh_argv(cfg, parsed, sh_command(FETCH_ONE, { job.remote_abs }))
    M._run(argv, { text = false, timeout = cfg.remote.fetch_timeout_ms }, function(out)
      vim.schedule(function()
        local bytes = out.stdout or ""
        -- The stat approved a size; the bytes must still honour the cap,
        -- because the file may have grown between the two calls.
        if
          out.code == 0
          and #bytes <= cfg.render.max_local_image_bytes
          and store(job.mirror_path, bytes, job.mtime)
        then
          changed = true
          wrote[job.mirror_path] = true
          book.fetched = book.fetched + 1
        else
          negative[negative_key(parsed, job.remote_abs)] = vim.uv.now() + NEGATIVE_TTL_MS
          book.failed = book.failed + 1
        end
        book.pending[job.remote_abs] = nil
        outstanding = outstanding - 1
        if outstanding == 0 then
          if changed then evict(config.get(), wrote) end
          if changed and session_live(session) then on_changed() end
        end
      end)
    end)
  end
end

---Digest one render's asset report. `on_changed` is called at most once, only
---when the mirror actually gained or replaced a file -- it is the caller's
---cue to re-render. Everything else -- escapes, non-images, repeats, known
---failures -- resolves to nothing, and a report whose every entry resolves to
---nothing costs zero transport calls: that is the property the scroll loop
---depends on and the suite counts.
function M.on_assets(session, assets, on_changed)
  local remote = session.remote
  if not session_live(session) or not remote.ready or remote.failed then return end
  local cfg = config.get()
  -- With local images off the renderer blocks every one of these by policy;
  -- bytes fetched now would never be shown.
  if not cfg.render.local_images then return end
  local parsed = remote.parsed
  local book = bookkeeping(remote)
  local first_report = not book.validated
  book.validated = true

  local now = vim.uv.now()
  local candidates, seen = {}, {}
  for _, asset in ipairs(assets) do
    local decoded = type(asset.source) == "string" and decode_source(asset.source) or nil
    local extension = decoded and decoded:match("%.([%a%d]+)$")
    if decoded and extension and FETCHABLE_EXTENSIONS[extension:lower()] then
      local remote_abs = source.join_remote(remote.base_dir, decoded)
      local mirror_path = M.mirror_path(remote.mirror_root, remote.root, remote_abs)
      -- mirror_path is nil exactly when the path escapes the remote root.
      -- This is the gate, not a double check: an escaping reference that
      -- names nothing locally reports as an ordinary miss ("file not
      -- found"), so nothing downstream would refuse it -- it must never
      -- enter the fetch list at all.
      if mirror_path and not seen[remote_abs] and not book.pending[remote_abs] then
        local deadline = negative[negative_key(parsed, remote_abs)]
        local refused = deadline and deadline > now
        -- ok assets are revalidated once per session; misses are always
        -- worth one look unless recently refused.
        if not refused and (not asset.ok or first_report) then
          seen[remote_abs] = true
          candidates[#candidates + 1] = { remote_abs = remote_abs, mirror_path = mirror_path, was_ok = asset.ok }
        end
      end
    end
  end
  if #candidates == 0 then return end
  for _, candidate in ipairs(candidates) do
    book.pending[candidate.remote_abs] = true
  end

  local args = { remote.root }
  for _, candidate in ipairs(candidates) do
    args[#args + 1] = candidate.remote_abs
  end
  local argv = ssh_argv(cfg, parsed, sh_command(STAT_BATCH, args))
  M._run(argv, { text = true, timeout = cfg.remote.fetch_timeout_ms }, function(out)
    vim.schedule(function()
      local rows = out.code == 0 and parse_stat_lines(out.stdout) or {}
      local jobs = {}
      for index, candidate in ipairs(candidates) do
        local row = rows[index]
        local verdict
        if not row then
          verdict = "failed"
        elseif row.status ~= "ok" then
          verdict = "refused"
        elseif row.size > cfg.render.max_local_image_bytes then
          -- Refused before a single content byte moves: the size cap would
          -- refuse it after the transfer anyway, and the transfer is the
          -- expensive part on the links this exists for.
          verdict = "refused"
        else
          local mirrored = vim.uv.fs_stat(candidate.mirror_path)
          if mirrored and mirrored.type == "file" and mirrored.size == row.size and mirrored.mtime.sec == row.mtime then
            verdict = "current"
          else
            verdict = "fetch"
          end
        end
        if verdict == "fetch" then
          jobs[#jobs + 1] =
            { remote_abs = candidate.remote_abs, mirror_path = candidate.mirror_path, mtime = row.mtime }
        else
          book.pending[candidate.remote_abs] = nil
          if verdict ~= "current" then
            negative[negative_key(parsed, candidate.remote_abs)] = vim.uv.now() + NEGATIVE_TTL_MS
            book.refused = book.refused + 1
          end
        end
      end
      if #jobs == 0 then return end
      if not session_live(session) then
        -- The session died while the stat was in flight; nothing to render
        -- for, and fetching into the shared mirror on its behalf would still
        -- have no reader to validate the result.
        for _, job in ipairs(jobs) do
          book.pending[job.remote_abs] = nil
        end
        return
      end
      fetch_approved(session, parsed, jobs, on_changed)
    end)
  end)
end

return M
