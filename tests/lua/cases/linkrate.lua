-- Where the link rate comes from, and everything it must never do.
--
-- The rate itself cannot be tested here: measuring it needs a pty, a link and
-- the better part of a minute, and this suite has none of the three. What can be
-- pinned is every decision made *around* the measurement -- precedence, the
-- cache key, what a malformed record does, and the two refusals that exist
-- because the alternatives were measured and found to fail.
return function(t)
  local config = require("md-viewer.config")
  local linkrate = require("md-viewer.linkrate")
  local resident = require("md-viewer.resident")

  local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here))))
  local script = root .. "/scripts/ssh-link-speed.sh"

  ---Run a block with `vim.env` overridden, then put every variable back exactly
  ---as it was -- including back to unset, which is a different state from empty.
  local function with_env(overrides, body)
    local saved = {}
    for name, value in pairs(overrides) do
      saved[name] = { vim.env[name] }
      vim.env[name] = value ~= "" and value or nil
    end
    linkrate.invalidate()
    local ok, err = pcall(body)
    for name, value in pairs(saved) do
      vim.env[name] = value[1]
    end
    linkrate.invalidate()
    if not ok then error(err, 0) end
  end

  -- -------------------------------------------------------------------
  -- The cache key, and the second implementation of it that must agree
  -- -------------------------------------------------------------------

  -- Both IPs, because an SSM tunnel is a loopback forward and the client alone
  -- reads 127.0.0.1 on every one of them.
  local one_end = { SSH_CONNECTION = "127.0.0.1 51234 127.0.0.1 22", TERM = "xterm-256color" }
  local other_end = { SSH_CONNECTION = "10.0.0.5 51234 10.0.0.9 22", TERM = "xterm-256color" }
  t.ok(
    linkrate.key({ env = one_end }) ~= linkrate.key({ env = other_end }),
    "two links from the same host key differently"
  )
  t.ok(
    linkrate.key({ env = one_end, hostname = "a" }) ~= linkrate.key({ env = one_end, hostname = "b" }),
    "two hosts key differently"
  )
  -- A fast link measures the terminal's own drain rate rather than the network's
  -- -- the script says so when it stops at --max-mb -- so two terminals are two
  -- answers.
  t.ok(
    linkrate.key({ env = { TERM = "xterm-kitty" } }) ~= linkrate.key({ env = { TERM = "xterm-256color" } }),
    "two terminals key differently"
  )
  -- TERM_PROGRAM does not survive SSH and LC_TERMINAL does, which is the whole
  -- reason terminal.lua trusts them in this order; the key follows it.
  t.eq(
    linkrate.key({ env = { TERM_PROGRAM = "iTerm.app", LC_TERMINAL = "WezTerm" } }),
    linkrate.key({ env = { TERM_PROGRAM = "iTerm.app", TERM = "anything" } }),
    "TERM_PROGRAM wins over LC_TERMINAL and TERM"
  )
  t.eq(16, #linkrate.key({ env = one_end }), "the key is 16 hex characters")
  t.ok(linkrate.key({ env = one_end }):match("^%x+$") ~= nil, "and is hex, so it is safe in a filename")

  -- The material is hashed because it holds both ends' addresses and the key is
  -- printed in reports meant to be pasted into public issues -- the same
  -- obligation terminal.ssh takes on when it records which variable was set and
  -- never its value.
  t.ok(
    linkrate.fingerprint({ env = other_end }):find("10.0.0.5", 1, true) ~= nil,
    "the fingerprint does hold the addresses (which is why it is never printed)"
  )
  t.ok(linkrate.key({ env = other_end }):find("10.0.0", 1, true) == nil, "and the key does not")

  -- `scripts/ssh-link-speed.sh --write-cache` computes this key in POSIX sh, and
  -- a measurement taken by hand is filed where nothing reads it if the two
  -- disagree. Nothing else would notice: the failure is a cache miss, which is
  -- indistinguishable from never having measured.
  local probe = vim
    .system({ "sh", script, "--print-key" }, {
      text = true,
      env = {
        SSH_CONNECTION = "10.0.0.5 51234 10.0.0.9 22",
        TERM_PROGRAM = "",
        LC_TERMINAL = "iTerm2",
        TERM = "screen-256color",
      },
    })
    :wait()
  if probe.code == 0 then
    local from_shell = vim.trim(probe.stdout or "")
    local from_lua = linkrate.key({
      env = { SSH_CONNECTION = "10.0.0.5 51234 10.0.0.9 22", LC_TERMINAL = "iTerm2", TERM = "screen-256color" },
    })
    t.eq(from_lua, from_shell, "ssh-link-speed.sh --print-key agrees with linkrate.key")
  else
    -- Only when the host has no sha256sum, shasum or openssl at all. The script
    -- refuses to cache there rather than inventing a weaker key.
    t.ok(
      tostring(probe.stderr or ""):find("sha256", 1, true) ~= nil,
      "the shell key is unavailable only for want of a sha256 tool, and says so"
    )
  end

  -- -------------------------------------------------------------------
  -- Reading a cached record
  -- -------------------------------------------------------------------

  local key = "0123456789abcdef"
  local path = linkrate.cache_path(key)
  t.ok(path:find(vim.fn.stdpath("state"), 1, true) == 1, "the cache lives under stdpath('state')")
  t.ok(path:find("link-rate", 1, true) ~= nil and path:sub(-5) == ".json", "one file per key")

  local written = linkrate.write_cache(key, {
    version = 1,
    key = key,
    bytes_per_sec = 1032241,
    samples = { 1032241, 1058113, 1071902 },
    measured_at = os.time(),
    source = "test",
  })
  t.ok(written ~= nil, "a record can be written")
  local record = linkrate.read_cache(key)
  t.eq(1032241, record and record.bytes_per_sec, "and read back")

  local function write_raw(text)
    local fd = assert(vim.uv.fs_open(path, "w", 384))
    vim.uv.fs_write(fd, text)
    vim.uv.fs_close(fd)
  end

  -- The other writer. `scripts/ssh-link-speed.sh --write-cache` prints this
  -- record with `printf` in POSIX sh, and nothing in CI can run it -- it needs a
  -- pty. This is its output, verbatim, from a real run: if the shell's field
  -- names or shape drift, a by-hand measurement stops being readable and the
  -- only symptom is a cache that never hits.
  write_raw(
    '{"version":1,"key":"deadbeefdeadbeef","bytes_per_sec":239674542,'
      .. '"samples":[246723794,254200272,239674542],"measured_at":1787726634,'
      .. '"payload_bytes":8388609,"source":"ssh-link-speed.sh"}\n'
  )
  local from_shell = linkrate.read_cache(key)
  t.eq(239674542, from_shell and from_shell.bytes_per_sec, "a record written by the shell script reads back")
  t.eq(3, from_shell and #from_shell.samples, "with its samples intact")
  t.eq("ssh-link-speed.sh", from_shell and from_shell.source, "and says which route wrote it")
  t.near(1.06, linkrate.spread(from_shell.samples), 0.01, "so health can show its spread like any other")

  -- Every one of these is answered with "unknown" rather than a repair. A rate
  -- this plugin is not sure of is worse than no rate: unknown suppresses an
  -- estimate, and wrong prints one.
  write_raw("this is not json")
  t.eq(nil, (linkrate.read_cache(key)), "a corrupt record is not readable")
  write_raw(vim.json.encode({ version = 99, bytes_per_sec = 1000 }))
  t.eq(nil, (linkrate.read_cache(key)), "a record from a future version is refused rather than half-read")
  write_raw(vim.json.encode({ version = 1, bytes_per_sec = 0 }))
  t.eq(nil, (linkrate.read_cache(key)), "a record with a non-positive rate is refused")
  write_raw(vim.json.encode({ version = 1 }))
  t.eq(nil, (linkrate.read_cache(key)), "a record with no rate at all is refused")
  vim.uv.fs_unlink(path)
  t.eq(nil, (linkrate.read_cache(key)), "and a missing record is simply a miss")

  -- -------------------------------------------------------------------
  -- Spread: a link that disagrees with itself has not been measured
  -- -------------------------------------------------------------------

  t.eq(nil, linkrate.spread({ 800000 }), "one sample has no spread")
  t.eq(nil, linkrate.spread(nil), "and neither does no samples")
  t.near(1.04, linkrate.spread({ 1032241, 1071902 }), 0.01, "spread is max over min")
  t.near(2.5, linkrate.spread({ 800000, 2000000 }), 0.01, "a link that answered 0.8 and then 2.0 spread 2.5x")

  -- -------------------------------------------------------------------
  -- Precedence: env > configured > cached > unobservable
  -- -------------------------------------------------------------------

  -- This block writes to the real cache path for this machine, because that is
  -- the only path `resolve()` will look at. Under `make test` that is the
  -- md-viewer-tests state directory and nothing of anyone's is at stake; the
  -- backup below is for a run outside it, and it is outside the pcall so that a
  -- failing assertion cannot strand somebody's measurement under another name.
  config.reset()
  local live_key = linkrate.key()
  local live_path = linkrate.cache_path(live_key)
  local backup = vim.uv.fs_stat(live_path) and (live_path .. ".test-backup") or nil
  if backup then vim.uv.fs_rename(live_path, backup) end
  local swept, sweep_error = pcall(with_env, { MD_VIEWER_SSH_LINK_BYTES_PER_SEC = "" }, function()
    -- Nothing configured, nothing cached, no override: unknown, and no attempt
    -- is made to fill the gap. `"auto"` reads a file; it never measures.
    local rate, tier = linkrate.resolve()
    t.eq(nil, rate, 'an "auto" rate with nothing cached is unknown')
    t.eq("unobservable", tier, "and says so")
    local nothing_here = linkrate.describe()
    t.ok(nothing_here:find("unknown", 1, true) ~= nil, "and describes itself as unknown")
    t.ok(nothing_here:find("MdViewerMeasureLink", 1, true) ~= nil, "and says what would settle it")
    t.eq(nil, nothing_here:find("no measurement cached", 1, true), "without explaining the ordinary case at length")

    -- A record that exists and cannot be trusted reads exactly like one that was
    -- never written, and the two want entirely different things done about them.
    local fd = assert(vim.uv.fs_open(live_path, "w", 384))
    vim.uv.fs_write(fd, "{ truncated")
    vim.uv.fs_close(fd)
    linkrate.invalidate()
    t.eq(nil, (linkrate.resolve()), "an unreadable record is still unknown")
    t.ok(linkrate.describe():find("readable JSON", 1, true) ~= nil, "but says the record is the problem")

    -- A cached measurement is an observation somebody made from a shell, not an
    -- inference -- which is the entire reason it is allowed to become the rate.
    linkrate.write_cache(live_key, {
      version = 1,
      key = live_key,
      bytes_per_sec = 1032241,
      samples = { 1032241, 1071902 },
      measured_at = os.time() - 7200,
      source = "test",
    })
    linkrate.invalidate()
    rate, tier = linkrate.resolve()
    t.eq(1032241, rate, "a cached measurement becomes the rate")
    t.eq("cached", tier, "under the cached tier")
    local described = linkrate.describe()
    t.ok(described:find("1,032,241", 1, true) ~= nil, "health reports the figure")
    t.ok(described:find("2h ago", 1, true) ~= nil, "with its age, since nothing here expires")
    t.ok(described:find(live_key, 1, true) ~= nil, "and the key, which is how two links are told apart")

    -- Configuration outranks the cache. This is the trap the whole feature
    -- exists around: one ~/.config/nvim is symlinked to every machine, so a
    -- number left in it silently defeats per-machine detection everywhere.
    config.setup({ render = { ssh_link_bytes_per_sec = 800000 } })
    rate, tier = linkrate.resolve()
    t.eq(800000, rate, "a configured number outranks the cache")
    t.eq("configured", tier)

    -- And the environment outranks configuration, for the same reason
    -- MD_VIEWER_TERMINAL_PROFILE does: the variable travels with the session and
    -- the shared config file cannot.
    vim.env.MD_VIEWER_SSH_LINK_BYTES_PER_SEC = "2500000"
    linkrate.invalidate()
    rate, tier = linkrate.resolve()
    t.eq(2500000, rate, "the environment outranks configuration")
    t.eq("env", tier)

    -- A misspelled override is reported rather than silently ignored: it gets
    -- set on the far end of an SSH connection, where "nothing happened" is the
    -- hardest possible symptom to chase.
    vim.env.MD_VIEWER_SSH_LINK_BYTES_PER_SEC = "fast"
    linkrate.invalidate()
    rate, tier = linkrate.resolve()
    t.eq(800000, rate, "an unparseable override falls through to configuration")
    t.eq("configured", tier)
    -- Reported even though a perfectly good rate came back, which is the worst
    -- version of this: the number looks right and is not the one that was asked
    -- for, on a machine reached over SSH where "nothing happened" is the hardest
    -- symptom there is to chase.
    t.ok(linkrate.describe():find("was ignored", 1, true) ~= nil, "and a rejected override is still reported")
    vim.env.MD_VIEWER_SSH_LINK_BYTES_PER_SEC = nil
    config.reset()
    linkrate.invalidate()
    local _, _, detail = linkrate.resolve()
    t.eq("cached", detail.tier, "with the override gone the cache answers again")

    -- nil means "unknown, and do not go looking" -- the cache is not read at
    -- all. Set on the live table rather than through setup(), which cannot
    -- produce it: a key absent from setup() means "keep the default", so with
    -- the default now "auto" there is no way to write nil through that door.
    -- The branch is still reachable and still has to be right.
    config.get().render.ssh_link_bytes_per_sec = nil
    linkrate.invalidate()
    rate, tier = linkrate.resolve()
    t.eq(nil, rate, "an unset rate is unknown, and does not fall back to the cache")
    t.eq("unobservable", tier)
    config.reset()
  end)
  vim.uv.fs_unlink(live_path)
  if backup then vim.uv.fs_rename(backup, live_path) end
  linkrate.invalidate()
  if not swept then error(sweep_error, 0) end

  -- Nothing in any tier ever prints an address, however it was reached.
  with_env({ SSH_CONNECTION = "203.0.113.7 51234 198.51.100.2 22" }, function()
    t.ok(linkrate.describe():find("203.0.113", 1, true) == nil, "describe never prints the client address")
    t.ok(linkrate.describe():find("198.51.100", 1, true) == nil, "nor the server's")
  end)

  -- -------------------------------------------------------------------
  -- The device the measurement writes to
  -- -------------------------------------------------------------------

  -- Measured, not reasoned about: a vim.system child is detached from the
  -- controlling terminal by libuv, so opening /dev/tty from one fails outright
  -- with ENXIO. A fallback to it would be a fallback to a guaranteed failure.
  with_env({ SSH_TTY = "/dev/tty" }, function()
    local device, why = linkrate.device()
    t.eq(nil, device, "/dev/tty is refused even when SSH_TTY names it")
    t.ok(tostring(why):find("controlling terminal", 1, true) ~= nil, "and the refusal says why")
  end)

  with_env({ SSH_TTY = "/nonexistent/pts/0" }, function()
    local device, why = linkrate.device()
    t.eq(nil, device, "a device that is not there is refused")
    t.ok(tostring(why):find("not a terminal device", 1, true) ~= nil, "and says what it looked at")
  end)

  with_env({ SSH_TTY = "/dev/null" }, function()
    -- /dev/null is a character device, so `stat` alone cannot tell it from a
    -- pty. This is the honest limit of what is checkable without opening it,
    -- and the script's own `[ -t 1 ]` guard is what catches the rest.
    local device = linkrate.device()
    t.eq("/dev/null", device, "a character device is accepted here and refused by the script's own guard")
  end)

  -- -------------------------------------------------------------------
  -- Reading the script's answer back
  -- -------------------------------------------------------------------

  local parsed = linkrate.parse_result(table.concat({
    "version=1",
    "bytes_per_sec=1032241",
    "samples=1071902 1058113 1032241",
    "payload_bytes=8388608",
    "clock=date +%N",
  }, "\n"))
  t.eq(1032241, parsed.bytes_per_sec, "the reported rate is read back")
  t.eq({ 1071902, 1058113, 1032241 }, parsed.samples, "with every sample, so health can show the spread")
  t.eq(8388608, parsed.payload_bytes, "and how much was actually sent")
  t.eq("MdViewerMeasureLink", parsed.source, "recorded as this route rather than the shell's")
  t.eq(nil, parsed.caveats, "a clean run carries no caveat")

  -- The script writes anything a reader should act on to stderr, so that it
  -- survives --quiet and reaches a caller reading --out. The one that matters
  -- says the host barely generated the payload faster than the link carried it,
  -- which makes the answer a floor rather than a rate -- exactly the direction
  -- of error this whole option exists to correct, so it must not be swallowed
  -- just because a number also came back.
  local caveated = linkrate.parse_result(
    "version=1\nbytes_per_sec=1032241\n",
    { code = 0, stderr = "warning: this host only generates the payload 2x faster than the rate\n" }
  )
  t.eq(1032241, caveated.bytes_per_sec, "a caveated run still produces its rate")
  t.ok(tostring(caveated.caveats):match("only generates"), "and carries the caveat to the reader")

  -- The script's own refusals are worth more than any exit code: they name the
  -- condition, and the exit code for a failed redirect is the shell's to pick.
  local refused, reason = linkrate.parse_result(nil, { code = 2, stderr = "refusing: stdout is not a terminal\n" })
  t.eq(nil, refused, "no result is not a rate")
  t.eq("refusing: stdout is not a terminal", reason, "and the script's own words are the reason")
  local silent, silent_reason = linkrate.parse_result("", { code = 1, stderr = "" })
  t.eq(nil, silent, "an empty result is not a rate either")
  t.ok(tostring(silent_reason):find("exit 1", 1, true) ~= nil, "and falls back to the exit status")
  t.eq(nil, (linkrate.parse_result("version=1\nbytes_per_sec=0\n")), "a zero rate is not a rate")

  -- -------------------------------------------------------------------
  -- What the resolved rate is actually for
  -- -------------------------------------------------------------------

  -- Resolved here and passed in, which is the point: `link_rate` takes one
  -- parameter and its meaning is "a number somebody observed outside Neovim".
  -- Every tier above is such an observation, so none of them weakens it.
  config.setup({ render = { ssh_link_bytes_per_sec = 1032241 } })
  linkrate.invalidate()
  local bytes_per_sec = linkrate.resolve()
  local per_ms, source = resident.link_rate(bytes_per_sec)
  t.near(1032.241, per_ms, 0.001, "the resolved rate reaches resident.link_rate as bytes per millisecond")
  t.eq("configured", source, "and arrives as an observation, whichever tier carried it")
  config.reset()
  linkrate.invalidate()
end
