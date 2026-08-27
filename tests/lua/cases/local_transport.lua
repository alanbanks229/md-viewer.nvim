-- The plugin half of the local-render control socket: discovery hygiene,
-- the versioned hello, the pairing probe, request routing, and the demotion
-- path. The helper here is a real unix-socket server running inside the test
-- process over vim.uv -- real bytes over a real pipe, with only the far
-- machine faked. Nothing in this file needs the node helper, a terminal, or
-- a browser.

return function(t)
  local localrender = require("md-viewer.localrender")
  local process = require("md-viewer.process")

  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")

  -- A fake helper: accepts one connection, answers hello, and optionally
  -- confirms the pairing probe. Scripted per scenario.
  local function fake_helper(sock_path, opts)
    opts = opts or {}
    local helper = { requests = {}, client = nil, sends = {} }
    local server = vim.uv.new_pipe(false)
    assert(server:bind(sock_path))
    vim.uv.fs_chmod(sock_path, 384) -- 0600: what sshd's default mask produces
    server:listen(16, function(err)
      assert(not err, err)
      local client = vim.uv.new_pipe(false)
      server:accept(client)
      helper.client = client
      local buffer = ""
      client:read_start(function(rerr, data)
        if rerr or not data then return end
        buffer = buffer .. data
        while true do
          local nl = buffer:find("\n", 1, true)
          if not nl then break end
          local line = buffer:sub(1, nl - 1)
          buffer = buffer:sub(nl + 1)
          local message = vim.json.decode(line, { luanil = { object = true } })
          helper.requests[#helper.requests + 1] = message
          if message.method == "hello" then
            if opts.protocol_mismatch then
              client:write(vim.json.encode({
                id = message.id,
                ok = false,
                error = "helper speaks local protocol 1, plugin sent 99",
                code = "PROTOCOL_MISMATCH",
              }) .. "\n")
            else
              client:write(vim.json.encode({
                id = message.id,
                ok = true,
                result = {
                  protocol = localrender.PROTOCOL,
                  helperVersion = "md-viewer-local vtest",
                  token = ("ab"):rep(16),
                  terminal = { kittyGraphics = "verified" },
                },
              }) .. "\n")
            end
          elseif opts.responder then
            opts.responder(helper, message)
          end
        end
      end)
    end)
    helper.server = server
    function helper.notify(fields) helper.client:write(vim.json.encode(fields) .. "\n") end
    function helper.close()
      if helper.client and not helper.client:is_closing() then helper.client:close() end
      if not server:is_closing() then server:close() end
    end
    return helper
  end

  -- Permission arithmetic is worth pinning on its own: mode carries type
  -- bits, and an off-by-one octal here silently accepts a group-readable
  -- socket.
  local owner_only = localrender._internal.owner_only
  t.eq(true, owner_only(49536), "0140600 (socket, 0600) is owner-only") -- 0140600
  t.eq(false, owner_only(49590), "0140666 is not") -- 0140666
  t.eq(true, owner_only(16832), "040700 (dir, 0700) is owner-only") -- 040700
  t.eq(false, owner_only(16877), "040755 is not") -- 040755

  -- Discovery: the scan finds fresh sockets, refuses loose ones at connect
  -- time, and garbage-collects stale files.
  vim.env.XDG_RUNTIME_DIR = tmp
  local dir = tmp .. "/md-viewer"
  vim.fn.mkdir(dir, "p")
  vim.uv.fs_chmod(dir, 448) -- 0700

  local fresh_path = dir .. "/r-abc123.sock"
  local fresh = fake_helper(fresh_path, {})
  local stale_path = dir .. "/r-0dead0.sock"
  local stale_holder = vim.uv.new_pipe(false)
  stale_holder:bind(stale_path)
  stale_holder:close()
  vim.uv.fs_utime(stale_path, os.time() - 90000, os.time() - 90000)

  local found = localrender.candidates()
  t.eq(1, #found, "one live candidate: the stale socket was aged out, the fresh one kept")
  t.eq(fresh_path, found[1], "the fresh socket is the candidate")
  t.eq(nil, vim.uv.fs_stat(stale_path), "the stale socket file was garbage-collected")
  fresh.close()

  local override = dir .. "/r-override.sock"
  vim.env.MD_VIEWER_LOCAL_SOCKET = override
  t.eq({ override }, localrender.candidates(), "the env override bypasses the scan entirely")
  vim.env.MD_VIEWER_LOCAL_SOCKET = nil

  -- verify_socket: a loose socket is refused with the mode in the reason.
  local loose_path = dir .. "/r-100se0.sock"
  local loose_holder = vim.uv.new_pipe(false)
  loose_holder:bind(loose_path)
  vim.uv.fs_chmod(loose_path, 438) -- 0666
  local ok_loose, why_loose = localrender._internal.verify_socket(loose_path)
  t.eq(nil, ok_loose, "a group/other-readable socket is refused")
  t.ok(why_loose:match("looser"), "the refusal names the mode problem")
  loose_holder:close()
  vim.uv.fs_unlink(loose_path)

  -- Full attach: hello, probe, confirmation, routed request, demotion.
  local sent_ui = {}
  local real_ui_send = vim.api.nvim_ui_send
  vim.api.nvim_ui_send = function(bytes) sent_ui[#sent_ui + 1] = bytes end
  local notifications = {}
  local real_notify = vim.notify
  vim.notify = function(msg, level) notifications[#notifications + 1] = { msg = msg, level = level } end

  local attach_path = dir .. "/r-aaaa01.sock"
  local helper = fake_helper(attach_path, {
    responder = function(h, message)
      if message.method == "test_echo" then
        h.notify({ id = message.id, ok = true, result = { echoed = message.params.x } })
      end
    end,
  })
  vim.env.MD_VIEWER_LOCAL_SOCKET = attach_path

  local attach_ok, attach_reason
  localrender.attach(function(ok, reason)
    attach_ok, attach_reason = ok, reason
  end)
  -- The probe marker must reach the terminal stream with the hello's token
  -- before any confirmation can happen.
  vim.wait(3000, function() return #sent_ui > 0 end, 10)
  t.eq(1, #sent_ui, "exactly one pairing probe was emitted")
  t.ok(
    sent_ui[1]:find("\27_Mv=1;t=" .. ("ab"):rep(16) .. ";s=0;d=-;p=;x=\27\\", 1, true),
    "the probe carries the hello's token, seq 0"
  )
  helper.notify({ event = "presented", seq = 0 })
  vim.wait(3000, function() return attach_ok ~= nil end, 10)
  t.eq(true, attach_ok, "attach completed after pairing confirmation: " .. tostring(attach_reason))
  t.eq(true, localrender.active(), "phase is attached")
  t.ok(process.active_transport(), "process routes through the socket transport")
  t.eq("md-viewer-local vtest", localrender.status().helper_version, "the hello result is retained for diagnostics")

  -- A request through the ordinary process.request funnel crosses the socket.
  local echo_result
  process.request("test_echo", { x = 41 }, function(result) echo_result = result end)
  vim.wait(3000, function() return echo_result ~= nil end, 10)
  t.eq(41, echo_result and echo_result.echoed, "process.request routed over the socket, zero caller changes")

  -- Sequence numbers are monotonic and reserve 0 for pairing.
  t.eq(1, localrender.next_seq(), "the first frame seq is 1; 0 belongs to the probe")
  t.eq(2, localrender.next_seq(), "and it is monotonic")

  -- The helper dying demotes: transport cleared, phase recorded, one loud
  -- notification, listeners fired -- and only once.
  local demoted
  localrender.on("demoted", function(payload) demoted = payload end)
  helper.close()
  vim.wait(3000, function() return demoted ~= nil end, 10)
  vim.wait(1000, function() return #notifications > 0 end, 10)
  t.eq("fallback", localrender.status().phase, "socket death demotes to fallback")
  t.eq(nil, process.active_transport(), "the stdio renderer is back in charge")
  t.ok(localrender.status().reason, "the reason is recorded for health/debug")
  t.eq(1, #notifications, "exactly one user-visible notification")
  t.ok(
    notifications[1] and notifications[1].msg:match("rendering on this host"),
    "the notification says what happens next"
  )

  -- Version skew: a mismatched hello refuses the candidate, with the code in
  -- the reason.
  localrender._reset()
  local mismatch_path = dir .. "/r-bbbb02.sock"
  local mismatch = fake_helper(mismatch_path, { protocol_mismatch = true })
  vim.env.MD_VIEWER_LOCAL_SOCKET = mismatch_path
  local skew_ok, skew_reason
  localrender.attach(function(ok, reason)
    skew_ok, skew_reason = ok, reason
  end)
  vim.wait(3000, function() return skew_ok ~= nil end, 10)
  t.eq(false, skew_ok, "a protocol mismatch refuses the candidate")
  t.ok(skew_reason:match("PROTOCOL_MISMATCH"), "the reason carries the code: " .. tostring(skew_reason))
  mismatch.close()

  -- A helper that hellos but cannot see this terminal never confirms the
  -- probe, and the candidate is not adopted -- the wrong-socket defense.
  localrender._reset()
  local deaf_path = dir .. "/r-cccc03.sock"
  local deaf = fake_helper(deaf_path, {})
  vim.env.MD_VIEWER_LOCAL_SOCKET = deaf_path
  sent_ui = {}
  vim.api.nvim_ui_send = function(bytes) sent_ui[#sent_ui + 1] = bytes end
  local deaf_ok, deaf_reason
  localrender.attach(function(ok, reason)
    deaf_ok, deaf_reason = ok, reason
  end)
  vim.wait(4000, function() return deaf_ok ~= nil end, 20)
  t.eq(false, deaf_ok, "an unconfirmed pairing is a refusal, not an adoption")
  t.ok(tostring(deaf_reason):match("pairing probe unanswered"), "the reason says what never happened")
  t.eq(false, localrender.active(), "nothing attached")
  deaf.close()

  -- With no helper at all, attach fails with the actionable launch command.
  localrender._reset()
  vim.env.MD_VIEWER_LOCAL_SOCKET = nil
  vim.env.XDG_RUNTIME_DIR = tmp .. "/empty-nothing-here"
  local none_ok, none_reason
  localrender.attach(function(ok, reason)
    none_ok, none_reason = ok, reason
  end)
  vim.wait(3000, function() return none_ok ~= nil end, 10)
  t.eq(false, none_ok, "no candidates means no attach")
  t.ok(tostring(none_reason):match("md%-viewer%-local"), "the reason names the helper to run")

  vim.api.nvim_ui_send = real_ui_send
  vim.notify = real_notify
  vim.env.XDG_RUNTIME_DIR = nil
  vim.env.MD_VIEWER_LOCAL_SOCKET = nil
  localrender._reset()
  t.eq(nil, process.active_transport(), "the suite leaves the stdio transport in charge for later cases")
end
