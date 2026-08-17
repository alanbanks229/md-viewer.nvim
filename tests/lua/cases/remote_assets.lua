local config = require("md-viewer.config")
local remote_assets = require("md-viewer.remote_assets")
local source = require("md-viewer.source")

return function(t)
  config.reset()

  -- The quoting helper is the one piece of escaping between document-derived
  -- strings and a remote shell, so it is not inspected -- it is executed.
  -- Each string goes through a real local `sh` exactly the way the remote
  -- login shell will see it, and must come back byte for byte.
  local nasty = {
    "plain.png",
    "with space.png",
    "single'quote.png",
    [[double"quote.png]],
    "dollar$HOME.png",
    "backtick`id`.png",
    "semicolon;rm -rf.png",
    "newline\nname.png",
    "naïve – ★.png",
    "-leading-dash.png",
    "back\\slash.png",
    "",
  }
  for _, text in ipairs(nasty) do
    local out = vim.system({ "sh", "-c", "printf '%s' " .. remote_assets.quote(text) }, { text = false }):wait()
    t.eq(0, out.code, "sh accepts the quoting of " .. vim.inspect(text))
    t.eq(text, out.stdout, "round-trips through sh: " .. vim.inspect(text))
  end

  -- The full composition ssh carries: `sh -c '<script>' md-viewer '<arg>'`,
  -- parsed once by the login shell (played here by a local sh), with the
  -- document-controlled string arriving as a positional parameter the script
  -- never eval's.
  for _, text in ipairs(nasty) do
    local command = "sh -c " .. remote_assets.quote([[printf '%s' "$1"]]) .. " md-viewer " .. remote_assets.quote(text)
    local out = vim.system({ "sh", "-c", command }, { text = false }):wait()
    t.eq(text, out.stdout, "positional parameter survives the login-shell hop: " .. vim.inspect(text))
  end

  -- Transport argv shape, captured through the one seam every remote command
  -- uses. The stub records and answers; no ssh binary is ever invoked.
  local parsed = source.parse("rsync://alan@dev-vm:2200//home/alan/project/README.md")
  local captured = {}
  local saved_run = remote_assets._run
  local reply
  remote_assets._run = function(argv, _opts, on_exit)
    captured[#captured + 1] = argv
    on_exit(reply)
  end

  local function resolve(target)
    local finished, info, err = false, nil, nil
    remote_assets.resolve_root(target, function(got, why)
      info, err, finished = got, why, true
    end)
    vim.wait(1000, function() return finished end)
    return info, err
  end

  reply = {
    code = 0,
    stdout = "outcome=ok\ndoc=/home/alan/project/README.md\nbase=/home/alan/project\nroot=/home/alan\n",
  }
  local info, err = resolve(parsed)
  t.eq(nil, err, "a clean walk reports no error")
  t.eq(
    { path = "/home/alan/project/README.md", base_dir = "/home/alan/project", root = "/home/alan" },
    info,
    "resolve_root returns the walked paths"
  )
  local argv = captured[1]
  t.eq("ssh", argv[1], "default transport is ssh")
  t.eq({ "-o", "BatchMode=yes" }, { argv[2], argv[3] }, "a missing key must fail, not prompt invisibly")
  t.eq({ "-o", "ConnectTimeout=10" }, { argv[4], argv[5] }, "TCP setup is bounded")
  t.eq({ "-p", "2200" }, { argv[6], argv[7] }, "an authority port travels as argv, not as part of the host")
  t.eq("alan@dev-vm", argv[8], "the ssh target keeps the user and drops the port")
  t.ok(argv[9]:find("sh -c ", 1, true) == 1, "the remote command is a positional-parameter sh script")
  t.ok(argv[9]:find("'.git'", 1, true) ~= nil, "the configured root markers ride along as parameters")
  t.eq(9, #argv, "nothing else is passed")

  -- A root at "/" must not produce doubled slashes in the parsed paths.
  reply = { code = 0, stdout = "outcome=ok\ndoc=//x.md\nbase=/\nroot=/\n" }
  info = resolve(parsed)
  t.eq({ path = "/x.md", base_dir = "/", root = "/" }, info, "paths from a root filesystem are normalized")

  reply = { code = 0, stdout = "outcome=missing\n" }
  info, err = resolve(parsed)
  t.eq(nil, info, "a missing document resolves to nothing")
  t.ok(err:find("does not exist", 1, true) ~= nil, "the reason names the actual condition")

  reply = { code = 124, stdout = "", stderr = "" }
  info, err = resolve(parsed)
  t.eq(nil, info, "a timeout resolves to nothing")
  t.ok(err:find("timed out", 1, true) ~= nil, "the reason says it timed out")

  reply = { code = 255, stdout = "", stderr = "Permission denied (publickey)." }
  info, err = resolve(parsed)
  t.ok(err:find("Permission denied", 1, true) ~= nil, "ssh's own diagnostic is surfaced")

  reply = { code = 0, stdout = "Welcome to fish, the friendly interactive shell\n" }
  info, err = resolve(parsed)
  t.ok(err:find("POSIX", 1, true) ~= nil, "an unparseable reply names the shell requirement")

  -- Custom transport prefix replaces the binary but not the discipline.
  config.setup({ remote = { ssh_command = { "ssh", "-F", "/tmp/corp-config" } } })
  captured = {}
  reply = { code = 0, stdout = "outcome=ok\ndoc=/a/b.md\nbase=/a\nroot=/a\n" }
  resolve(source.parse("scp://dev-vm//a/b.md"))
  t.eq(
    { "ssh", "-F", "/tmp/corp-config" },
    { captured[1][1], captured[1][2], captured[1][3] },
    "ssh_command prefixes the argv"
  )
  config.reset()

  remote_assets._run = saved_run

  -- Mirror layout: keyed by authority and remote root, distinct across both,
  -- created on first use, stable across calls.
  local one = remote_assets.mirror_root(parsed, "/home/alan/project")
  local two = remote_assets.mirror_root(parsed, "/home/alan/other")
  local other_account =
    remote_assets.mirror_root(source.parse("rsync://root@dev-vm//home/alan/project/x.md"), "/home/alan/project")
  t.ok(vim.uv.fs_stat(one) ~= nil, "the mirror directory exists after first use")
  t.ok(one ~= two, "different roots get different mirrors")
  t.ok(one ~= other_account, "different accounts on one host get different mirrors")
  t.eq(one, remote_assets.mirror_root(parsed, "/home/alan/project"), "the mapping is stable")

  t.eq(
    vim.fs.joinpath(one, "images/arch.png"),
    remote_assets.mirror_path(one, "/home/alan/project", "/home/alan/project/images/arch.png"),
    "a contained path maps under the mirror"
  )
  t.eq(
    one,
    remote_assets.mirror_path(one, "/home/alan/project", "/home/alan/project"),
    "the root maps to the mirror root"
  )
  t.eq(
    nil,
    remote_assets.mirror_path(one, "/home/alan/project", "/etc/shadow"),
    "a path outside the remote root can never gain a local name"
  )
  t.eq(
    nil,
    remote_assets.mirror_path(one, "/home/alan/project", "/home/alan/project2/x.png"),
    "a sibling sharing the root as a string prefix stays outside"
  )
  t.eq(
    vim.fs.joinpath(one, "etc/motd"),
    remote_assets.mirror_path(one, "/", "/etc/motd"),
    "a root of / maps without doubling the separator"
  )

  -- Only the leaf directories this case created: a developer running the file
  -- under their own profile must not lose an unrelated mirror.
  for _, dir in ipairs({ one, two, other_account }) do
    vim.fn.delete(dir, "rf")
  end

  -- --------------------------------------------------------------------
  -- The fetch pipeline. A canned transport answers the stat batch and the
  -- per-file fetch; the assertions count its calls, because "a scroll burst
  -- costs zero transport calls" is the property the whole architecture is
  -- for.
  -- --------------------------------------------------------------------
  local png =
    vim.base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl+Zz8AAAAASUVORK5CYII=")
  local calls, stat_commands = 0, {}
  local stat_reply, cat_reply
  remote_assets._run = function(argv, _opts, on_exit)
    calls = calls + 1
    local command = argv[#argv]
    if command:find("cat %-%- ") then
      on_exit(cat_reply(command))
    else
      stat_commands[#stat_commands + 1] = command
      on_exit(stat_reply(command))
    end
  end

  local function make_session(mirror_root)
    return {
      closed = false,
      remote = {
        parsed = parsed,
        ready = true,
        failed = nil,
        base_dir = "/home/alan/project/docs",
        root = "/home/alan/project",
        mirror_root = mirror_root,
        mirror_base_dir = mirror_root .. "/docs",
      },
    }
  end
  local function settle()
    vim.wait(200, function() return false end, 10)
  end

  local mirror = vim.fn.tempname()
  vim.fn.mkdir(mirror, "p")
  local session = make_session(mirror)
  local done = 0
  local on_changed = function() done = done + 1 end

  -- One miss worth fetching, plus every kind of reference that must never
  -- reach the wire: a duplicate, two escapes, and two non-image extensions.
  stat_reply = function() return { code = 0, stdout = ("i=1 s=ok z=%d m=1712345678\n"):format(#png) } end
  cat_reply = function() return { code = 0, stdout = png } end
  remote_assets.on_assets(session, {
    { source = "images/arch.png", ok = false },
    { source = "images/arch.png", ok = false },
    { source = "../../../etc/passwd.png", ok = false },
    { source = "/etc/shadow.png", ok = false },
    { source = "script.sh", ok = false },
    { source = "notes.txt", ok = false },
  }, on_changed)
  vim.wait(2000, function() return done == 1 end)
  t.eq(1, done, "a landed fetch asks for exactly one more render")
  t.eq(2, calls, "one stat batch plus one fetch, nothing else")
  t.ok(
    stat_commands[1]:find("'/home/alan/project/docs/images/arch.png'", 1, true) ~= nil,
    "the stat batch names the contained candidate"
  )
  t.eq(nil, stat_commands[1]:find("passwd", 1, true), "a traversal escape never reaches the wire")
  t.eq(nil, stat_commands[1]:find("shadow", 1, true), "an absolute escape never reaches the wire")
  t.eq(nil, stat_commands[1]:find("script", 1, true), "a non-image extension never reaches the wire")
  local fetched = vim.fs.joinpath(mirror, "docs/images/arch.png")
  local stat = vim.uv.fs_stat(fetched)
  t.ok(stat ~= nil and stat.size == #png, "the bytes landed at the mirrored project position")
  t.eq(1712345678, stat and stat.mtime.sec, "the mirror file carries the remote mtime for later revalidation")

  -- The scroll burst: the same document reported over and over, now whole.
  for _ = 1, 10 do
    remote_assets.on_assets(session, { { source = "images/arch.png", ok = true } }, on_changed)
  end
  settle()
  t.eq(2, calls, "ten repeat reports cost zero transport calls")
  t.eq(1, done, "and ask for no further renders")

  -- Remote-side refusals: a symlink, an oversize file, a missing file. One
  -- stat batch decides all three; nothing is fetched; the negative cache
  -- absorbs the repeats a live preview will send.
  local refusals = make_session(mirror)
  stat_reply = function()
    return { code = 0, stdout = ("i=1 s=symlink\ni=2 s=ok z=%d m=5\ni=3 s=missing\n"):format(64 * 1024 * 1024) }
  end
  local refused_done = 0
  remote_assets.on_assets(refusals, {
    { source = "sym.png", ok = false },
    { source = "big.png", ok = false },
    { source = "ghost.png", ok = false },
  }, function() refused_done = refused_done + 1 end)
  settle()
  t.eq(3, calls, "three refusals cost one stat batch and zero fetches")
  t.eq(0, refused_done, "nothing changed, so nothing re-renders")
  t.eq(3, refusals.remote.assets.refused, "each refusal is counted for diagnostics")
  remote_assets.on_assets(refusals, {
    { source = "sym.png", ok = false },
    { source = "big.png", ok = false },
    { source = "ghost.png", ok = false },
  }, function() refused_done = refused_done + 1 end)
  settle()
  t.eq(3, calls, "refused files are not re-asked while the negative cache holds")

  -- Freshness: a new session revalidates what it inherited from the mirror --
  -- one stat, no transfer when nothing changed, a refetch when the remote
  -- file moved on.
  local second = make_session(mirror)
  stat_reply = function() return { code = 0, stdout = ("i=1 s=ok z=%d m=1712345678\n"):format(#png) } end
  local second_done = 0
  remote_assets.on_assets(
    second,
    { { source = "images/arch.png", ok = true } },
    function() second_done = second_done + 1 end
  )
  settle()
  t.eq(4, calls, "a new session pays one stat to trust the inherited mirror")
  t.eq(0, second_done, "an unchanged file is not refetched and not re-rendered")

  local third = make_session(mirror)
  local bigger = png .. "PADDING"
  stat_reply = function() return { code = 0, stdout = ("i=1 s=ok z=%d m=1799999999\n"):format(#bigger) } end
  cat_reply = function() return { code = 0, stdout = bigger } end
  local third_done = 0
  remote_assets.on_assets(
    third,
    { { source = "images/arch.png", ok = true } },
    function() third_done = third_done + 1 end
  )
  vim.wait(2000, function() return third_done == 1 end)
  t.eq(1, third_done, "a changed remote file is refetched and re-rendered")
  local replaced = vim.uv.fs_stat(fetched)
  t.eq(#bigger, replaced and replaced.size, "the mirror holds the new bytes")
  t.eq(1799999999, replaced and replaced.mtime.sec, "and the new mtime")

  -- A fetch that dies on the wire leaves the placeholder standing, counts as
  -- a failure, and is not retried per keystroke.
  local failing = make_session(mirror)
  stat_reply = function() return { code = 0, stdout = "i=1 s=ok z=10 m=9\n" } end
  cat_reply = function() return { code = 255, stdout = "", stderr = "Connection closed" } end
  local failing_done = 0
  remote_assets.on_assets(
    failing,
    { { source = "images/lost.png", ok = false } },
    function() failing_done = failing_done + 1 end
  )
  settle()
  t.eq(0, failing_done, "a failed fetch never claims the mirror changed")
  t.eq(1, failing.remote.assets.failed, "and is counted")
  t.eq(nil, vim.uv.fs_stat(vim.fs.joinpath(mirror, "docs/images/lost.png")), "no partial file appears")
  local calls_after_failure = calls
  remote_assets.on_assets(failing, { { source = "images/lost.png", ok = false } }, function() end)
  settle()
  t.eq(calls_after_failure, calls, "the failure is negative-cached, not retried per report")

  -- With local images off, the renderer blocks everything by policy, so the
  -- pipeline must not move bytes that will never be shown.
  config.setup({ render = { local_images = false } })
  local disabled = make_session(mirror)
  local calls_before_disabled = calls
  remote_assets.on_assets(disabled, { { source = "images/other.png", ok = false } }, function() end)
  settle()
  t.eq(calls_before_disabled, calls, "render.local_images = false stops the pipeline cold")
  config.reset()

  -- Eviction: the mirror budget is global, enforced after a batch that wrote,
  -- oldest mtime first, never this batch's own writes.
  config.setup({ remote = { cache_max_bytes = #png + 8 } })
  local evict_parsed = source.parse("rsync://evict@dev-vm//proj/doc.md")
  local evict_mirror = remote_assets.mirror_root(evict_parsed, "/proj")
  local evict_session = {
    closed = false,
    remote = {
      parsed = evict_parsed,
      ready = true,
      base_dir = "/proj",
      root = "/proj",
      mirror_root = evict_mirror,
      mirror_base_dir = evict_mirror,
    },
  }
  stat_reply = function() return { code = 0, stdout = ("i=1 s=ok z=%d m=100\n"):format(#png) } end
  cat_reply = function() return { code = 0, stdout = png } end
  local evict_done = 0
  remote_assets.on_assets(
    evict_session,
    { { source = "first.png", ok = false } },
    function() evict_done = evict_done + 1 end
  )
  vim.wait(2000, function() return evict_done == 1 end)
  stat_reply = function() return { code = 0, stdout = ("i=1 s=ok z=%d m=200\n"):format(#png) } end
  remote_assets.on_assets(
    evict_session,
    { { source = "second.png", ok = false } },
    function() evict_done = evict_done + 1 end
  )
  vim.wait(2000, function() return evict_done == 2 end)
  t.eq(nil, vim.uv.fs_stat(vim.fs.joinpath(evict_mirror, "first.png")), "the oldest file paid for the budget")
  t.ok(vim.uv.fs_stat(vim.fs.joinpath(evict_mirror, "second.png")) ~= nil, "this batch's own write is protected")
  config.reset()
  vim.fn.delete(evict_mirror, "rf")

  remote_assets._run = saved_run
  vim.fn.delete(mirror, "rf")
end
