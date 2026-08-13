local protocol = require("md-viewer.protocol")
local config = require("md-viewer.config")

local M = {}
local instance
-- Process-lifetime, registered once at plugin setup, like an augroup: nothing
-- ever needs to unregister one. In-flight requests already error correctly
-- through deliver_error() below; these listeners exist for session-level Lua
-- state (the cached selection/find display flags) that is not tied to any
-- specific in-flight request and would otherwise go stale silently across a
-- renderer restart.
local exit_listeners = {}
-- Why a configured companion was given up on, or nil while it is still worth
-- trying. Set once and never cleared for the session: a companion that was not
-- there when the preview opened is not going to appear, and retrying the
-- connect on every scroll frame would cost a timeout each. `config.setup()`
-- clearing it is the documented way back, since changing the address is the
-- only thing that makes another attempt meaningful.
local companion_refused = nil

local function plugin_root()
  local source = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function deliver_error(proc, message)
  for id, callback in pairs(proc.callbacks) do
    proc.callbacks[id] = nil
    vim.schedule(function() callback(nil, message, { code = "PROCESS_EXIT" }) end)
  end
end

local function consume(proc, data)
  if not data then return end
  proc.stdout_buffer = proc.stdout_buffer .. data
  while true do
    local newline = proc.stdout_buffer:find("\n", 1, true)
    if not newline then break end
    local line = proc.stdout_buffer:sub(1, newline - 1)
    proc.stdout_buffer = proc.stdout_buffer:sub(newline + 1)
    local response, err = protocol.decode(line)
    if not response then
      proc.last_error = err
    else
      local callback = proc.callbacks[response.id]
      proc.callbacks[response.id] = nil
      if callback then
        vim.schedule(function()
          if response.ok then
            callback(response.result, nil)
          else
            -- `code`/`detail` (see protocol.js) let a caller distinguish e.g. a
            -- STALE_INTERACTION supersession from a genuine failure without
            -- parsing the human-readable message. Third argument, so every
            -- existing two-arg callback keeps working unchanged.
            callback(nil, response.error or "renderer error", { code = response.code, detail = response.detail })
          end
        end)
      end
    end
  end
end

---Where a companion renderer is listening, and which setting said so.
---
---Configuration outranks the environment, matching terminal.profile: a value
---written into a config file is a decision about this machine, while the
---variable exists for one config shared across many hosts.
local function companion_address()
  local configured = config.get().client_render.address
  if type(configured) == "string" and configured ~= "" then return configured, "client_render.address" end
  local from_env = vim.env.MD_VIEWER_CLIENT_ADDR
  if type(from_env) == "string" and from_env ~= "" then return from_env, "$MD_VIEWER_CLIENT_ADDR" end
  -- Last, because the two above are decisions made on this host about this
  -- host, while this is whatever the wrapper on the other end of the link was
  -- told to announce. It exists so that starting a session through
  -- `md-viewer-ssh` needs no configuration on the remote at all.
  local announced = require("md-viewer.client_render").announced_address()
  if type(announced) == "string" and announced ~= "" then return announced, "$LC_MD_VIEWER" end
  return nil, nil
end

---Split a companion address into host and port, or nil when it names a unix
---socket. A path is the unambiguous case -- it contains a separator -- so the
---host:port reading is only taken when there is none.
local function tcp_target(address)
  if address:find("/", 1, true) then return nil end
  local host, port = address:match("^(.*):(%d+)$")
  if not host or host == "" then return nil end
  -- An IPv6 literal arrives bracketed, the way a URL writes it; libuv wants the
  -- address on its own.
  host = host:gsub("^%[(.*)%]$", "%1")
  return host, tonumber(port)
end

---Give up on the companion for the rest of the session, failing everything
---already in flight and saying why exactly once.
local function refuse_companion(proc, reason)
  companion_refused = reason
  proc.running, proc.connected = false, false
  proc.last_error = reason
  if instance == proc then instance = nil end
  deliver_error(proc, reason)
  if proc.stream and not proc.stream:is_closing() then
    pcall(proc.stream.read_stop, proc.stream)
    proc.stream:close()
  end
  vim.schedule(
    function()
      vim.notify(("md-viewer: %s. Falling back to the renderer beside Neovim."):format(reason), vim.log.levels.WARN)
    end
  )
  for _, listener in ipairs(exit_listeners) do
    vim.schedule(listener)
  end
end

---Connect to a companion. Returns immediately with the connection still in
---progress: requests made before it completes are held in `outbox` and flushed
---on connect, so a caller never has to know whether the socket is up yet.
local function start_socket(address, source)
  local host, port = tcp_target(address)
  local stream = host and vim.uv.new_tcp() or vim.uv.new_pipe(false)
  if not stream then return nil, "failed to create a socket handle" end

  local proc = {
    transport = "socket",
    address = address,
    address_source = source,
    running = true,
    connected = false,
    callbacks = {},
    stdout_buffer = "",
    stderr = {},
    next_id = 0,
    outbox = {},
    stream = stream,
  }

  local settled = false
  local timer = vim.uv.new_timer()
  local function stop_timer()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    timer = nil
  end

  timer:start(config.get().client_render.connect_timeout_ms, 0, function()
    if settled then return end
    settled = true
    stop_timer()
    refuse_companion(proc, ("no companion renderer answered at %s"):format(address))
  end)

  local function on_connect(err)
    if settled then return end
    settled = true
    stop_timer()
    if err then
      refuse_companion(proc, ("could not reach a companion renderer at %s (%s)"):format(address, tostring(err)))
      return
    end
    proc.connected = true
    stream:read_start(function(read_err, data)
      if read_err then
        proc.last_error = read_err
        return
      end
      if data == nil then
        -- The companion hung up. In flight work cannot be answered, and the
        -- next request re-decides the transport from scratch.
        proc.running, proc.connected = false, false
        if instance == proc then instance = nil end
        deliver_error(proc, "companion renderer disconnected")
        if proc.stream and not proc.stream:is_closing() then proc.stream:close() end
        for _, listener in ipairs(exit_listeners) do
          vim.schedule(listener)
        end
        return
      end
      consume(proc, data)
    end)
    local queued = proc.outbox
    proc.outbox = {}
    for _, item in ipairs(queued) do
      stream:write(item.data, item.callback)
    end
  end

  if host then
    stream:connect(host, port, on_connect)
  else
    stream:connect(address, on_connect)
  end
  return proc
end

local function start_child()
  local stdin, stdout, stderr = vim.uv.new_pipe(false), vim.uv.new_pipe(false), vim.uv.new_pipe(false)
  local proc = {
    transport = "stdio",
    running = false,
    connected = true,
    callbacks = {},
    stdout_buffer = "",
    stderr = {},
    next_id = 0,
    stdin = stdin,
    stdout = stdout,
    stderr_pipe = stderr,
  }
  local executable = vim.fn.exepath("node")
  if executable == "" then return nil, "Node.js executable not found" end
  local main = plugin_root() .. "/renderer/src/main.js"
  local handle, pid_or_err = vim.uv.spawn(executable, {
    args = { main },
    stdio = { stdin, stdout, stderr },
    cwd = plugin_root() .. "/renderer",
  }, function(code, signal)
    proc.running = false
    proc.exit_code, proc.exit_signal = code, signal
    deliver_error(proc, ("renderer exited (code=%s signal=%s)"):format(code, signal))
    for _, listener in ipairs(exit_listeners) do
      vim.schedule(listener)
    end
    for _, pipe in ipairs({ proc.stdin, proc.stdout, proc.stderr_pipe }) do
      if pipe and not pipe:is_closing() then
        pcall(pipe.read_stop, pipe)
        pipe:close()
      end
    end
    if proc.handle and not proc.handle:is_closing() then proc.handle:close() end
  end)
  if not handle then
    stdin:close()
    stdout:close()
    stderr:close()
    return nil, "failed to start renderer: " .. tostring(pid_or_err)
  end
  proc.handle, proc.pid, proc.running = handle, pid_or_err, true
  proc.stream = stdin
  stdout:read_start(function(err, data)
    if err then
      proc.last_error = err
    else
      consume(proc, data)
    end
  end)
  stderr:read_start(function(_, data)
    if data then
      proc.stderr[#proc.stderr + 1] = data
      if #proc.stderr > 20 then table.remove(proc.stderr, 1) end
    end
  end)
  return proc
end

function M.start()
  if instance and instance.running then return instance end
  local address, source = companion_address()
  if address and not companion_refused then
    local proc, err = start_socket(address, source)
    if proc then
      instance = proc
      return proc
    end
    companion_refused = err
  end
  local proc, err = start_child()
  if not proc then return nil, err end
  instance = proc
  return proc
end

---Register `callback` to run whenever the renderer subprocess exits, for
---whatever reason (crash, or `M.stop()`). No
---removal API: callers register once, at plugin setup, for the lifetime of the
---Neovim session.
function M.on_exit(callback) exit_listeners[#exit_listeners + 1] = callback end

---Clear the "this companion is not there" latch, so the next request tries the
---configured address again. Called by config.setup(), because changing the
---address is the only event that makes another attempt worth a timeout.
function M.reset_companion() companion_refused = nil end

local function write(proc, data, callback)
  -- Held rather than dropped while a socket is still connecting: the preview
  -- issues its first render immediately on open, and failing it because the
  -- handshake had not finished would make every companion session start with a
  -- visible error it would then silently recover from.
  if proc.transport == "socket" and not proc.connected then
    proc.outbox[#proc.outbox + 1] = { data = data, callback = callback }
    return
  end
  proc.stream:write(data, callback)
end

function M.request(method, params, callback)
  local proc, err = M.start()
  if not proc then
    callback(nil, err)
    return nil
  end
  proc.next_id = proc.next_id + 1
  local id = proc.next_id
  proc.callbacks[id] = callback
  write(proc, protocol.encode({ id = id, method = method, params = params }), function(write_err)
    if write_err and proc.callbacks[id] then
      local cb = proc.callbacks[id]
      proc.callbacks[id] = nil
      vim.schedule(function() cb(nil, "renderer stdin: " .. tostring(write_err), { code = "PROCESS_WRITE_ERROR" }) end)
    end
  end)
  return id
end

function M.status()
  if not instance then return { running = false, companion_refused = companion_refused } end
  return {
    running = instance.running,
    pid = instance.pid,
    last_error = instance.last_error,
    exit_code = instance.exit_code,
    stderr = table.concat(instance.stderr, ""),
    -- Which renderer is answering, and how it was chosen. A session that
    -- silently fell back to the child would otherwise look identical to one
    -- that was never configured for a companion at all.
    transport = instance.transport,
    address = instance.address,
    address_source = instance.address_source,
    connected = instance.connected,
    companion_refused = companion_refused,
  }
end

function M.stop()
  local proc = instance
  instance = nil
  if not proc then return end
  if proc.transport == "socket" then
    -- Tell the companion this session is over, then let go of the socket. It is
    -- not ours to kill: it serves whatever Neovim connects next, and holding a
    -- browser warm between sessions is the reason it is a long-lived process.
    if proc.running and proc.stream and not proc.stream:is_closing() then
      write(proc, protocol.encode({ id = 0, method = "shutdown", params = {} }))
      pcall(proc.stream.read_stop, proc.stream)
      proc.stream:close()
    end
    proc.running, proc.connected = false, false
    return
  end
  if proc.running and proc.stdin and not proc.stdin:is_closing() then
    proc.stdin:write(protocol.encode({ id = 0, method = "shutdown", params = {} }))
    proc.stdin:shutdown()
  end
  if proc.handle and not proc.handle:is_closing() then
    local timer = vim.uv.new_timer()
    timer:start(1000, 0, function()
      timer:stop()
      timer:close()
      if proc.running and proc.handle and not proc.handle:is_closing() then proc.handle:kill("sigterm") end
    end)
  end
end

return M
