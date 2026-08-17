local source = require("md-viewer.source")

return function(t)
  -- Accepted names, both slash shapes, every authority spelling. `path` is
  -- always the absolute reading; `home_relative` exists only for the
  -- single-slash shape, where netrw and remote-ssh.nvim disagree.
  local accepted = {
    {
      name = "rsync://alan@dev-vm//home/alan/project/README.md",
      parsed = {
        scheme = "rsync",
        authority = "alan@dev-vm",
        user = "alan",
        host = "dev-vm",
        port = nil,
        ssh_target = "alan@dev-vm",
        path = "/home/alan/project/README.md",
        home_relative = nil,
      },
    },
    {
      -- The single-slash shape remote-ssh.nvim's tree browser emits for every
      -- child entry. Absolute to it, $HOME-relative to netrw: both readings
      -- must survive parsing so the session's remote probe can pick one.
      name = "rsync://dev-vm/home/alan/project/README.md",
      parsed = {
        scheme = "rsync",
        authority = "dev-vm",
        user = nil,
        host = "dev-vm",
        port = nil,
        ssh_target = "dev-vm",
        path = "/home/alan/project/README.md",
        home_relative = "home/alan/project/README.md",
      },
    },
    {
      name = "scp://alan@dev-vm:2222//srv/docs/guide.md",
      parsed = {
        scheme = "scp",
        authority = "alan@dev-vm:2222",
        user = "alan",
        host = "dev-vm",
        port = 2222,
        ssh_target = "alan@dev-vm",
        path = "/srv/docs/guide.md",
        home_relative = nil,
      },
    },
    {
      name = "scp://dev-vm/notes/todo.md",
      parsed = {
        scheme = "scp",
        authority = "dev-vm",
        user = nil,
        host = "dev-vm",
        port = nil,
        ssh_target = "dev-vm",
        path = "/notes/todo.md",
        home_relative = "notes/todo.md",
      },
    },
    {
      -- Buffer names carry spaces verbatim; nothing here may shell-interpret.
      name = "rsync://dev-vm//home/alan/my docs/a b.md",
      parsed = {
        scheme = "rsync",
        authority = "dev-vm",
        user = nil,
        host = "dev-vm",
        port = nil,
        ssh_target = "dev-vm",
        path = "/home/alan/my docs/a b.md",
        home_relative = nil,
      },
    },
    {
      -- Scheme matching is case-insensitive but the result is normalized, so
      -- downstream comparisons never see mixed case.
      name = "SCP://dev-vm//x.md",
      parsed = {
        scheme = "scp",
        authority = "dev-vm",
        user = nil,
        host = "dev-vm",
        port = nil,
        ssh_target = "dev-vm",
        path = "/x.md",
        home_relative = nil,
      },
    },
  }
  for _, case in ipairs(accepted) do
    local parsed = source.parse(case.name)
    t.ok(parsed, "parses " .. case.name)
    if parsed then
      case.parsed.original = case.name
      t.eq(case.parsed, parsed, "fields for " .. case.name)
    end
  end

  -- Everything that is not an ssh-backed document must parse to nil so the
  -- existing buffer refusals keep applying to it unchanged.
  local rejected = {
    "oil:///Users/alan/project",
    "fugitive:///repo/.git//0/file.md",
    "term://~/project//12345:/bin/zsh",
    "http://example.com/readme.md",
    "https://example.com/readme.md",
    "file:///Users/alan/notes.md",
    "sftp://host//x.md",
    "md-viewer://preview/3",
    "/Users/alan/project/README.md",
    "README.md",
    "",
    "scp://",
    "scp://host-only",
    "scp://host//",
    "scp:relative/form.md",
  }
  for _, name in ipairs(rejected) do
    t.eq(nil, source.parse(name), "rejects " .. (name == "" and "<empty>" or name))
  end
  t.eq(nil, source.parse(nil), "rejects nil")

  -- build_url always emits the double-slash absolute shape, the one reading
  -- netrw and remote-ssh.nvim share.
  local parsed = source.parse("rsync://alan@dev-vm:2200//home/alan/project/docs/setup.md")
  t.eq(
    "rsync://alan@dev-vm:2200//home/alan/project/images/arch.png",
    source.build_url(parsed, "/home/alan/project/images/arch.png"),
    "build_url keeps scheme and authority verbatim"
  )
  t.eq(
    "scp://dev-vm//notes/todo.md",
    source.build_url(source.parse("scp://dev-vm/notes/other.md"), "/notes/todo.md"),
    "build_url upgrades a single-slash name to the unambiguous shape"
  )

  -- Lexical normalization: the same answers path.resolve gives the renderer,
  -- so both ends of the pipeline judge a hostile path identically.
  local normalized = {
    { "/a/b/../c", "/a/c" },
    { "/a/./b//c", "/a/b/c" },
    { "/a/b/./.", "/a/b" },
    { "/..", "/" },
    { "/../../etc/shadow", "/etc/shadow" },
    { "/a/../..", "/" },
    { "/", "/" },
    { "/a/", "/a" },
  }
  for _, case in ipairs(normalized) do
    t.eq(case[2], source.normalize_remote(case[1]), "normalize_remote " .. case[1])
  end

  local joined = {
    { "/home/alan/project", "images/arch.png", "/home/alan/project/images/arch.png" },
    { "/home/alan/project", "./images/arch.png", "/home/alan/project/images/arch.png" },
    { "/home/alan/project/docs", "../images/arch.png", "/home/alan/project/images/arch.png" },
    { "/home/alan/project", "../../../etc/shadow", "/etc/shadow" },
    { "/home/alan/project", "/etc/motd", "/etc/motd" },
    { "/home/alan/project", "images/my pic.png", "/home/alan/project/images/my pic.png" },
  }
  for _, case in ipairs(joined) do
    t.eq(case[3], source.join_remote(case[1], case[2]), ("join_remote %s + %s"):format(case[1], case[2]))
  end

  local containment = {
    { "/home/alan/project", "/home/alan/project", true },
    { "/home/alan/project", "/home/alan/project/images/a.png", true },
    { "/home/alan/project", "/home/alan/project2/a.png", false },
    { "/home/alan/project", "/home/alan", false },
    { "/home/alan/project", "/etc/shadow", false },
    { "/", "/anything/at/all", true },
    { "/", "/", true },
  }
  for _, case in ipairs(containment) do
    t.eq(case[3], source.inside_remote(case[1], case[2]), ("inside_remote %s ⊇ %s"):format(case[1], case[2]))
  end

  -- local_base_dir consolidates what renderer.lua and interaction.lua used to
  -- compute separately; pin both behaviours it inherited.
  local unnamed = vim.api.nvim_create_buf(false, true)
  t.eq(vim.uv.cwd(), source.local_base_dir(unnamed), "unnamed buffer falls back to cwd")
  local named = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(named, "/tmp/md-viewer-source-case/docs/readme.md")
  t.eq("/tmp/md-viewer-source-case/docs", source.local_base_dir(named), "named buffer uses its directory")
  vim.api.nvim_buf_delete(unnamed, { force = true })
  vim.api.nvim_buf_delete(named, { force = true })
end
