---How fast this link carries bytes, and where that answer came from.
---
---`md-viewer.resident`'s `link_rate` answers "is there a number, or is this
---unknown" and deliberately takes exactly one parameter: every throughput sample
---a Lua caller can take measures a queue insertion rather than the link, so an
---offered estimate must never become the rate. This module is what supplies that
---one parameter. It never estimates either -- it only reports numbers a human or
---a shell put somewhere, in a fixed order of precedence.
---
---Precedence mirrors `coordinates.cell_metrics`, and for the same reason:
---
---* **env** -- `MD_VIEWER_SSH_LINK_BYTES_PER_SEC`. Ahead of configuration
---  because one `~/.config/nvim` is symlinked to many hosts, and the whole
---  problem this module exists for is that a number correct on one of them is
---  wrong on the next. An environment variable travels with the session.
---* **configured** -- a positive `render.ssh_link_bytes_per_sec`. Never capped
---  against anything.
---* **cached** -- a measurement this machine took and wrote down. Reached only
---  when the option is `"auto"`, which is the default.
---* **unobservable** -- nothing said, and nothing inferred. A legitimate answer.
---
---**`"auto"` never measures on its own.** It reads a cache file that exists only
---because someone ran `:MdViewerMeasureLink` or `scripts/ssh-link-speed.sh
-----write-cache` on this machine. Resolution costs one `stat` and, at most, one
---small file read; nothing here ever touches the link.
local M = {}

local ENV_VAR = "MD_VIEWER_SSH_LINK_BYTES_PER_SEC"

--- Bumped if the record's shape ever changes. A record from a future version is
--- ignored rather than half-read: the alternative is a wrong rate, and unknown
--- beats wrong here by the same argument the whole option rests on.
local RECORD_VERSION = 1

--- What the key is built from, and why each part is in it.
---
--- * **host** -- the obvious one.
--- * **client and server IP** -- the same VM reached from two places is two
---   links. Client IP alone cannot serve: an SSM tunnel is a loopback forward,
---   so both ends read 127.0.0.1 and only the pair distinguishes anything.
--- * **terminal** -- on a link fast enough, the terminal's own drain rate is
---   what the measurement finds, which `scripts/ssh-link-speed.sh` says out loud
---   when it stops at `--max-mb`. Two terminals are two answers.
---
--- Hashed, and only the hash is ever printed. `terminal.ssh` records which SSH
--- variable was set and deliberately never its value, because that output is
--- meant for public issues; a cache key derived from the same variables inherits
--- the same obligation. 16 hex characters is 64 bits, which is plenty to tell
--- one person's handful of hosts apart and short enough to read in a health row.
local KEY_PREFIX = "md-viewer-link-rate-1"
local KEY_LENGTH = 16

local function positive(value)
  value = tonumber(value)
  if value == nil or value ~= value or value == math.huge or value <= 0 then return nil end
  return value
end

local function grouped(value)
  local text = tostring(math.floor(value + 0.5))
  return (text:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

---The terminal identity both this module and `scripts/ssh-link-speed.sh` key on.
---
---Deliberately the raw evidence rather than `terminal.match_profile`'s verdict:
---the shell script has to compute the same string when it is run by hand, and a
---second implementation of the profile table living in POSIX sh is a divergence
---waiting to happen. TERM_PROGRAM first, LC_TERMINAL next -- which is the one
---that survives SSH, and the same order `terminal.lua` trusts them in -- then
---TERM.
local function terminal_id(env)
  for _, name in ipairs({ "TERM_PROGRAM", "LC_TERMINAL", "TERM" }) do
    local value = env[name]
    if value and value ~= "" then return value end
  end
  return ""
end

---The unhashed key material. Never printed, never logged: it holds both IPs.
function M.fingerprint(opts)
  opts = opts or {}
  local env = opts.env or vim.env
  local connection = env.SSH_CONNECTION or ""
  local client, server = connection:match("^(%S+)%s+%S+%s+(%S+)")
  return table.concat({
    KEY_PREFIX,
    "host=" .. (opts.hostname or vim.fn.hostname()),
    "client=" .. (client or ""),
    "server=" .. (server or ""),
    "term=" .. terminal_id(env),
  }, "\n")
end

---The cache key: 16 hex characters, safe to print anywhere.
function M.key(opts) return vim.fn.sha256(M.fingerprint(opts)):sub(1, KEY_LENGTH) end

---Where a measurement for `key` lives.
---
---One file per key rather than one file holding every key, because
---`scripts/ssh-link-speed.sh --write-cache` writes here too and merging JSON in
---POSIX sh is either a dependency on a JSON tool or a format nobody should have
---to keep parseable by `awk`. A whole-file write of a single record is correct
---in both languages with no merge at all, and connecting from a second terminal
---no longer costs the first one its measurement.
---
---`stdpath("state")` and not the config directory: this is a fact about one
---machine, and the configuration is the thing being shared across all of them.
function M.cache_path(key)
  return table.concat({ vim.fn.stdpath("state"), "md-viewer", "link-rate", (key or M.key()) .. ".json" }, "/")
end

local function read_file(path)
  local fd = vim.uv.fs_open(path, "r", 420)
  if not fd then return nil end
  local stat = vim.uv.fs_fstat(fd)
  local data = stat and vim.uv.fs_read(fd, stat.size, 0) or nil
  vim.uv.fs_close(fd)
  return data
end

-- The one "nothing is wrong, there is simply nothing here" answer. Every other
-- reason `read_cache` gives describes a record that exists and cannot be
-- trusted, which is worth telling a reader about; this one is the ordinary case
-- on every machine that has not been measured yet.
local NO_RECORD = "no measurement cached for this machine"

---The stored measurement for `key`, or nil and a reason.
function M.read_cache(key)
  local path = M.cache_path(key)
  local data = read_file(path)
  if not data or data == "" then return nil, NO_RECORD end
  local ok, record = pcall(vim.json.decode, data)
  if not ok or type(record) ~= "table" then return nil, "the cached measurement is not readable JSON" end
  if record.version ~= RECORD_VERSION then
    return nil, ("the cached measurement is version %s, not %d"):format(tostring(record.version), RECORD_VERSION)
  end
  if not positive(record.bytes_per_sec) then return nil, "the cached measurement has no positive rate" end
  return record
end

---Replace the measurement for `key`. Written whole through a temporary file, so
---a reader never sees half a record.
function M.write_cache(key, record)
  local path = M.cache_path(key)
  local dir = vim.fs.dirname(path)
  vim.fn.mkdir(dir, "p")
  local temporary = path .. "." .. tostring(vim.uv.os_getpid())
  local fd = vim.uv.fs_open(temporary, "w", 384)
  if not fd then return nil, "could not write to " .. dir end
  vim.uv.fs_write(fd, vim.json.encode(record))
  vim.uv.fs_close(fd)
  local renamed, rename_error = vim.uv.fs_rename(temporary, path)
  if not renamed then
    vim.uv.fs_unlink(temporary)
    return nil, tostring(rename_error)
  end
  return path
end

---max/min across the samples a measurement kept, or nil when it kept fewer than
---two. A link that answers 0.8 and then 2.0 MB/s has not been measured; it has
---been sampled twice from something that is not a constant.
function M.spread(samples)
  if type(samples) ~= "table" or #samples < 2 then return nil end
  local low, high
  for _, sample in ipairs(samples) do
    local rate = positive(sample)
    if rate then
      low = math.min(low or rate, rate)
      high = math.max(high or rate, rate)
    end
  end
  if not (low and high) or low <= 0 then return nil end
  return high / low
end

-- Resolution reads configuration, the environment and a file; the winbar's
-- warm-up estimate asks on every redraw. The environment cannot change under a
-- running Neovim, configuration invalidates this itself, and a measurement
-- invalidates it on the way out.
local resolved = nil

function M.invalidate() resolved = nil end

---The link rate in bytes per second, the tier it came from, and the detail
---behind it. `nil` for the rate is the honest answer and not a failure.
function M.resolve()
  if resolved then return resolved.bytes_per_sec, resolved.tier, resolved.detail end

  local key = M.key()
  local detail = { key = key, path = M.cache_path(key) }
  local answer

  -- A misspelled or absurd override is reported rather than silently ignored,
  -- for the same reason MD_VIEWER_TERMINAL_PROFILE is: it is set on the far end
  -- of an SSH connection, where "nothing happened" is the hardest possible
  -- symptom to chase.
  local raw_env = vim.env[ENV_VAR]
  if raw_env ~= nil and raw_env ~= "" then
    local from_env = positive(raw_env)
    if from_env then
      answer, detail.tier, detail.reason = from_env, "env", ENV_VAR
    else
      detail.rejected_env = tostring(raw_env)
    end
  end

  if not answer then
    local configured = require("md-viewer.config").get().render.ssh_link_bytes_per_sec
    local pinned = positive(configured)
    if pinned then
      answer, detail.tier, detail.reason = pinned, "configured", "render.ssh_link_bytes_per_sec"
    elseif configured == "auto" then
      local record, why = M.read_cache(key)
      if record then
        answer, detail.tier, detail.reason = positive(record.bytes_per_sec), "cached", "measured on this machine"
        detail.measured_at = tonumber(record.measured_at)
        detail.samples = type(record.samples) == "table" and record.samples or nil
        detail.spread = M.spread(detail.samples)
        detail.source = record.source
      else
        detail.tier, detail.reason = "unobservable", why
      end
    else
      -- Neither a rate nor "auto", which in practice means nil: unknown, and do
      -- not go looking. No cache read at all. Unreachable through `setup()` now
      -- that the default is "auto" -- a key absent from setup() means "keep the
      -- default" and cannot mean "clear it" -- but it is still a legal state of
      -- the table and still has to have an answer.
      detail.tier, detail.reason = "unobservable", NO_RECORD
    end
  end

  detail.bytes_per_sec = answer
  resolved = { bytes_per_sec = answer, tier = detail.tier, detail = detail }
  return answer, detail.tier, detail
end

local function age_text(measured_at)
  local stamp = tonumber(measured_at)
  if not stamp then return "at an unknown time" end
  local seconds = os.time() - stamp
  if seconds < 0 then return "at an unknown time" end
  if seconds < 90 then return "just now" end
  if seconds < 5400 then return ("%dm ago"):format(math.floor(seconds / 60)) end
  if seconds < 172800 then return ("%dh ago"):format(math.floor(seconds / 3600)) end
  return ("%dd ago"):format(math.floor(seconds / 86400))
end

---One line for `:MdViewerHealth` and `:MdViewerDebug`, so the two cannot
---describe the same decision differently. Never prints an address: the tier is
---the diagnostic and the key is how two sessions are told apart.
function M.describe()
  local rate, tier, detail = M.resolve()
  local text
  if tier == "env" then
    text = ("%s B/s (%s)"):format(grouped(rate), ENV_VAR)
  elseif tier == "configured" then
    text = ("%s B/s (render.ssh_link_bytes_per_sec)"):format(grouped(rate))
  elseif tier == "cached" then
    local parts = { ("measured %s"):format(age_text(detail.measured_at)) }
    if detail.spread then parts[#parts + 1] = ("spread %.2fx"):format(detail.spread) end
    parts[#parts + 1] = "key " .. detail.key
    text = ("%s B/s (%s)"):format(grouped(rate), table.concat(parts, ", "))
  else
    text = "unknown -- :MdViewerMeasureLink measures it, render.ssh_link_bytes_per_sec pins it"
    -- A cache that is present and unusable reads exactly like one that was never
    -- written, and the two want completely different things done about them.
    if detail.reason and detail.reason ~= NO_RECORD then text = ("%s (%s)"):format(text, detail.reason) end
  end
  -- Appended to every tier and not only the unknown one: a rejected override
  -- with a usable rate behind it is the worst version of this, because the
  -- number looks right and is not the one that was asked for.
  if detail.rejected_env then
    text = ("%s -- %s=%q is not a positive number and was ignored"):format(text, ENV_VAR, detail.rejected_env)
  end
  return text
end

-- Said once per Neovim, never once per preview. Fires where a resident warm-up
-- would have carried an estimate -- and it is a suggestion, not a warning: an
-- unmeasured link is not a fault, and `:MdViewerHealth` deliberately raises
-- nothing for it.
--
-- Deliberately not raised where the *other* consumer of the rate is: an
-- unmeasured link keeps `image.resident = "auto"` on the per-scroll path
-- (resident_session.select_path), which is the default behaviour and the
-- correct one, so there is nothing there to tell anybody about. Whoever wants
-- to know why asks :MdViewerDebug, and `render_path` says it in the same words
-- as this.
local told = false

function M.notice_unknown()
  if told then return end
  local _, tier = M.resolve()
  if tier ~= "unobservable" then return end
  told = true
  vim.notify(
    "md-viewer: this link's speed is unknown, so the warm-up cannot estimate how long it will take.\n"
      .. "Run :MdViewerMeasureLink once on this machine to measure it.",
    vim.log.levels.INFO
  )
end

local function root()
  local source = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

---Which terminal device the measurement should be written to, or nil and why.
---
---**Never `/dev/tty`.** `vim.system` children are detached from the controlling
---terminal by libuv, and `/dev/tty` resolves through it: opening it from the
---child fails outright with ENXIO ("No such device or address"), and `ps` agrees
---there is no controlling terminal to resolve. Measured, not reasoned about.
---
---`SSH_TTY` is the route that works, because sshd puts the pty's *path* there
---and opening a pty by name needs no controlling terminal. `/proc/self/fd/1` is
---the Linux fallback for a session that has one but no `SSH_TTY`, and it has to
---be resolved *here*, in Neovim's own process: passed to the child as a path it
---would name the child's stdout, which is the pipe `vim.system` created.
function M.device()
  local from_env = vim.env.SSH_TTY
  local path = (from_env and from_env ~= "") and from_env or nil
  local source = "SSH_TTY"
  if not path and require("md-viewer.terminal").platform() == "linux" then
    path, source = vim.uv.fs_readlink("/proc/self/fd/1"), "/proc/self/fd/1"
  end
  if not path or path == "" then
    return nil, "no terminal device: SSH_TTY is unset and this platform has no /proc/self/fd/1 to resolve"
  end
  if path == "/dev/tty" then return nil, "refusing /dev/tty: a vim.system child has no controlling terminal" end
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= "char" then return nil, ("%s is not a terminal device (%s)"):format(source, path) end
  return path, source
end

local measuring = false

---Measure this link by writing to the terminal from a subprocess, and cache the
---answer.
---
---A subprocess, and not Lua, because the answer is not observable from inside
---Neovim at all: `nvim_ui_send` appends to Neovim's own UI queue and returns, so
---a Lua caller sees no back-pressure whatever the link is doing. The measurement
---itself is `scripts/ssh-link-speed.sh`, unchanged in what it sends, so a run
---from here and a run from the shell are the same measurement.
---
---`callback(record, err)` runs on the main loop.
function M.measure(opts, callback)
  opts = opts or {}
  callback = callback or function() end
  if measuring then return callback(nil, "a measurement is already running") end

  local terminal = require("md-viewer.terminal")
  if not terminal.ssh() then return callback(nil, "this is not an SSH session, so there is no link to measure") end

  -- Neovim cannot be closed for this the way the script's own instructions ask,
  -- but an open preview is the one thing that would put real traffic on the wire
  -- underneath the measurement: a resize, a scroll or a colorscheme is a full
  -- capture, and it would land as a slower link rather than as an error.
  for _, session in pairs(require("md-viewer.state").all()) do
    if not session.closed and session.preview_win and vim.api.nvim_win_is_valid(session.preview_win) then
      return callback(nil, "close the preview first (:MdViewerToggle): its captures would be measured as the link")
    end
  end

  local device, why = M.device()
  if not device then return callback(nil, why) end

  local key = M.key()
  local out = vim.fn.tempname()
  local script = root() .. "/scripts/ssh-link-speed.sh"
  local samples = math.max(1, math.floor(tonumber(opts.samples) or 3))

  -- stdout has to *be* the terminal for two reasons: it is what is being timed,
  -- and the script refuses to run at all when it is not (`[ -t 1 ]`), because a
  -- redirected run measures the redirection. `vim.system` cannot hand a child an
  -- arbitrary file descriptor, so the redirect is done by the shell that starts
  -- it. stderr stays on the pipe, where warnings are readable.
  --
  -- Not `--write-cache`: the script's own cache writer is for a run by hand,
  -- where nothing else knows the key. Here the key has already been computed, so
  -- the script reports through `--out` and this module files it, which keeps the
  -- one place that can disagree with `read_cache` down to one.
  local command = {
    "sh",
    "-c",
    'device=$1; shift; exec >"$device" || exit 3; exec sh "$@"',
    "md-viewer-measure-link",
    device,
    script,
    "--quiet",
    "--out",
    out,
    "--samples",
    tostring(samples),
  }
  if opts.seconds then
    command[#command + 1] = "--seconds"
    command[#command + 1] = tostring(opts.seconds)
  end

  measuring = true
  -- Announced here rather than by the caller, and deliberately after every
  -- refusal above: "measuring this link" followed a moment later by "this is not
  -- an SSH session" reads as a failure during the measurement rather than as the
  -- measurement never having started.
  vim.notify(
    "md-viewer: measuring this link. The screen will flood and then clear; please do not type.",
    vim.log.levels.INFO
  )
  -- The script clears the screen and then floods it. Neovim redrawing into the
  -- same pty while that happens both corrupts the picture and spends the wire
  -- time being measured. This is as much suppression as a plugin has -- the
  -- script's own instruction is "please do not type" -- and `:mode` puts the
  -- screen back afterwards either way.
  local lazy = vim.o.lazyredraw
  vim.o.lazyredraw = true

  vim.system(command, { text = true, timeout = 300000 }, function(result)
    vim.schedule(function()
      measuring = false
      vim.o.lazyredraw = lazy
      pcall(vim.cmd, "mode")
      pcall(vim.cmd, "redraw!")

      local record, err = M.parse_result(read_file(out), result)
      vim.uv.fs_unlink(out)
      if not record then return callback(nil, err) end

      record.key = key
      -- The caveats belong to this run rather than to this link, so they reach
      -- the reader and not the record.
      local caveats = record.caveats
      record.caveats = nil
      local path, write_error = M.write_cache(key, record)
      record.caveats = caveats
      M.invalidate()
      if not path then return callback(record, "measured, but could not cache it: " .. tostring(write_error)) end
      callback(record, nil)
    end)
  end)
end

---Turn the script's `--out` file into a cache record, or nil and a reason.
---
---Split out and left on the module so the parsing has a test that needs no link,
---no pty and no subprocess -- which is every machine this is developed on.
function M.parse_result(data, result)
  result = result or {}
  if not data or data == "" then
    -- The script's own refusals go to stderr and say exactly what is wrong, so
    -- they are worth more than any exit code. A failed `exec >"$device"` also
    -- lands here: the shell exits with a status of its own choosing before the
    -- `|| exit 3` can run, but it says why on stderr first.
    local stderr = vim.trim(tostring(result.stderr or ""))
    if stderr ~= "" then return nil, stderr end
    return nil, ("the measurement produced no result (exit %s)"):format(tostring(result.code))
  end

  local fields = {}
  for line in (data .. "\n"):gmatch("([^\n]*)\n") do
    local name, value = line:match("^([%w_]+)=(.*)$")
    if name then fields[name] = value end
  end

  local rate = positive(fields.bytes_per_sec)
  if not rate then return nil, "the measurement reported no rate" end

  local samples = {}
  for sample in tostring(fields.samples or ""):gmatch("%S+") do
    samples[#samples + 1] = positive(sample)
  end
  if #samples == 0 then samples = { rate } end

  return {
    version = RECORD_VERSION,
    bytes_per_sec = math.floor(rate),
    samples = samples,
    measured_at = os.time(),
    payload_bytes = tonumber(fields.payload_bytes),
    source = "MdViewerMeasureLink",
    -- Everything the script wanted a human to act on, which it writes to stderr
    -- precisely so that it survives --quiet and reaches a caller reading --out.
    -- Not stored in the cache: it describes this run, not this link. The one
    -- that matters says the payload was generated barely faster than it was
    -- carried, which makes the answer a floor rather than a rate -- and a
    -- measurement reported as a rate when it is a floor is the failure mode this
    -- whole option exists to correct.
    caveats = (function()
      local text = vim.trim(tostring(result.stderr or ""))
      return text ~= "" and text or nil
    end)(),
  }
end

---`:MdViewerMeasureLink`. Reports the result, once, to whoever asked for it.
function M.measure_command(opts)
  M.measure(opts or {}, function(record, err)
    if not record then return vim.notify("md-viewer: " .. tostring(err), vim.log.levels.WARN) end
    local spread = M.spread(record.samples)
    local text = ("md-viewer: this link carries %s B/s"):format(grouped(record.bytes_per_sec))
    if spread then text = text .. (", lowest of %d samples spread %.2fx"):format(#record.samples, spread) end
    text = text .. ".\nCached for this machine as " .. record.key .. "; it applies from the next preview."
    if err then
      text = text .. "\n" .. err
      return vim.notify(text, vim.log.levels.WARN)
    end
    if spread and spread > 2 then
      text = text .. "\nThe samples disagree by more than 2x, so this link is not steady enough to predict."
    end
    if record.caveats then return vim.notify(text .. "\n" .. record.caveats, vim.log.levels.WARN) end
    vim.notify(text, vim.log.levels.INFO)
  end)
end

return M
