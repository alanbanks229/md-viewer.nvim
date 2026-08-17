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
end
