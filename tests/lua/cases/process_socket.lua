-- The socket transport: the same renderer protocol, reached over a companion's
-- unix socket instead of a child process's stdin.
--
-- Driven against a real companion rather than a stub, for the same reason
-- `process.lua` drives a real renderer: the thing worth proving is that the two
-- transports are interchangeable at the `M.request` boundary, and a stub on one
-- side of that boundary proves only that the stub was written to agree.
--
-- The refusal path matters as much as the working one. A configured companion
-- that is not there must not take the preview down with it -- md-viewer has to
-- fall back to the renderer beside Neovim and carry on, because "I set up a
-- tunnel yesterday and forgot to start it today" is the ordinary case.
return function(t)
  local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here))))
  local config = require("md-viewer.config")
  local process = require("md-viewer.process")

  local node = vim.fn.exepath("node")
  if node == "" then
    print("md-viewer: skipping socket transport case, no node on PATH")
    return
  end

  process.stop()
  vim.wait(5000, function() return not process.status().running end, 20)

  -- Short by necessity: a unix socket path is capped near 104 bytes on macOS,
  -- and `vim.fn.tempname()` alone can eat most of that.
  local socket_path = ("/tmp/mdv-test-%d.sock"):format(vim.uv.os_getpid())
  vim.uv.fs_unlink(socket_path)

  local companion = vim.uv.spawn(node, {
    args = { root .. "/renderer/src/companion.js", "--socket", socket_path },
    stdio = { nil, nil, nil },
  }, function() end)
  t.ok(companion ~= nil, "the companion process starts")

  local function cleanup()
    process.stop()
    if companion and not companion:is_closing() then
      companion:kill("sigterm")
      companion:close()
    end
    vim.uv.fs_unlink(socket_path)
    config.reset()
  end

  -- The socket file appears when the companion binds it, and binding is what
  -- makes it accept, so its existence is the readiness signal.
  local listening = vim.wait(15000, function() return vim.uv.fs_stat(socket_path) ~= nil end, 50)
  if not listening then
    cleanup()
    t.ok(false, "the companion bound its socket within 15s")
    return
  end

  config.setup({ client_render = { address = socket_path } })

  local pong, ping_err
  process.request("ping", {}, function(result, err)
    pong, ping_err = result, err
  end)
  vim.wait(10000, function() return pong ~= nil or ping_err ~= nil end, 20)
  if ping_err then print("socket transport diagnostics: " .. vim.inspect(process.status())) end
  t.eq(nil, ping_err, "a request over the companion socket succeeds")
  t.eq(true, pong and pong.pong, "and carries the renderer's own answer")

  local status = process.status()
  t.eq("socket", status.transport, "the session reports which transport answered it")
  t.eq(socket_path, status.address, "and the address it reached")
  t.eq("client_render.address", status.address_source, "and which setting chose it")
  t.eq(true, status.connected, "the socket is connected once a request has completed")
  t.eq(nil, status.pid, "a companion is not a child of this Neovim and has no pid here")

  -- Ids still have to match responses to callbacks; a transport that lost the
  -- correlation would look like a renderer that answered the wrong question.
  local first, second
  process.request("ping", {}, function(result) first = result end)
  process.request("ping", {}, function(result) second = result end)
  vim.wait(10000, function() return first ~= nil and second ~= nil end, 20)
  t.ok(first and second, "concurrent requests both resolve over one socket")

  process.stop()
  vim.wait(5000, function() return not process.status().running end, 20)

  -- --------------------------------------------------------------------
  -- A companion that is not there
  -- --------------------------------------------------------------------

  config.reset()
  config.setup({
    client_render = { address = "/tmp/mdv-test-does-not-exist.sock", connect_timeout_ms = 500 },
  })

  local fallback_result, fallback_err
  process.request("ping", {}, function(result, err)
    fallback_result, fallback_err = result, err
  end)
  vim.wait(10000, function() return fallback_result ~= nil or fallback_err ~= nil end, 20)
  -- The request that discovered the absence is allowed to fail; what must not
  -- happen is the session staying broken afterwards.
  t.ok(process.status().companion_refused ~= nil, "an unreachable companion is recorded as refused")

  local recovered, recovered_err
  process.request("ping", {}, function(result, err)
    recovered, recovered_err = result, err
  end)
  vim.wait(15000, function() return recovered ~= nil or recovered_err ~= nil end, 20)
  t.eq(nil, recovered_err, "the next request falls back to the renderer beside Neovim")
  t.eq(true, recovered and recovered.pong, "and that renderer answers normally")
  t.eq("stdio", process.status().transport, "the fallback is the child process, not another socket attempt")

  cleanup()
  vim.wait(5000, function() return not process.status().running end, 20)
end
