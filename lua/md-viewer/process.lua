local protocol = require("md-viewer.protocol")

local M = {}
local instance
-- When md-viewer.localrender has attached a control-socket transport, every
-- request routes there instead of the stdio child; nil means the stdio path
-- below, which is byte-for-byte the pre-local-render behavior. Module-level
-- rather than per-session because `render.location` is global config: all
-- sessions render in the same place.
local transport
-- Process-lifetime, registered once at plugin setup, like an augroup: nothing
-- ever needs to unregister one. In-flight requests already error correctly
-- through deliver_error() below; these listeners exist for session-level Lua
-- state (the cached selection/find display flags) that is not tied to any
-- specific in-flight request and would otherwise go stale silently across a
-- renderer restart.
local exit_listeners = {}

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

function M.start()
  if instance and instance.running then return instance end
  local stdin, stdout, stderr = vim.uv.new_pipe(false), vim.uv.new_pipe(false), vim.uv.new_pipe(false)
  local proc = {
    running = false,
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
  instance = proc
  return proc
end

---Register `callback` to run whenever the renderer subprocess exits, for
---whatever reason (crash, or `M.stop()`). No
---removal API: callers register once, at plugin setup, for the lifetime of the
---Neovim session.
function M.on_exit(callback) exit_listeners[#exit_listeners + 1] = callback end

---Route requests to the local-render helper. `nil` restores the stdio
---renderer (which spawns lazily on the next request, exactly as after a
---crash). Owned by md-viewer.localrender; nothing else may call it.
function M.set_transport(value) transport = value end

---Exported for tests and diagnostics: which way requests currently go.
function M.active_transport() return transport end

function M.request(method, params, callback)
  if transport then return transport.request(method, params, callback) end
  local proc, err = M.start()
  if not proc then
    callback(nil, err)
    return nil
  end
  proc.next_id = proc.next_id + 1
  local id = proc.next_id
  proc.callbacks[id] = callback
  proc.stdin:write(protocol.encode({ id = id, method = method, params = params }), function(write_err)
    if write_err and proc.callbacks[id] then
      local cb = proc.callbacks[id]
      proc.callbacks[id] = nil
      vim.schedule(function() cb(nil, "renderer stdin: " .. tostring(write_err), { code = "PROCESS_WRITE_ERROR" }) end)
    end
  end)
  return id
end

function M.status()
  if not instance then return { running = false } end
  return {
    running = instance.running,
    pid = instance.pid,
    last_error = instance.last_error,
    exit_code = instance.exit_code,
    stderr = table.concat(instance.stderr, ""),
  }
end

---Stop the renderer.
---
---`opts.blocking` is for `VimLeavePre` and nothing else. The deferred branch
---below arms a `vim.uv` timer 1000ms out, and at Neovim exit that timer never
---fires -- Neovim is gone within milliseconds, taking its event loop and the
---pending SIGTERM with it. So the one moment the safety net existed for was the
---one moment it was guaranteed not to run, and every hard exit stranded a
---renderer. Blocking mode waits inline instead, then escalates for real.
function M.stop(opts)
  local proc = instance
  instance = nil
  if not proc then return end
  if proc.running and proc.stdin and not proc.stdin:is_closing() then
    proc.stdin:write(protocol.encode({ id = 0, method = "shutdown", params = {} }))
    proc.stdin:shutdown()
  end
  if not proc.running then return end

  if opts and opts.blocking then
    -- Closing stdin above is itself enough for a current renderer, which exits
    -- on EOF; the escalation is for one left over from an older version, or
    -- wedged past listening. `vim.wait` keeps processing the event loop, so the
    -- spawn callback still lands and clears `proc.running`.
    vim.wait(500, function() return not proc.running end, 20)
    if proc.running and proc.handle and not proc.handle:is_closing() then
      pcall(proc.handle.kill, proc.handle, "sigterm")
      vim.wait(300, function() return not proc.running end, 20)
    end
    -- Signalling the pid rather than the handle: by now the handle may be
    -- closing, and SIGKILL is the only signal a wedged renderer cannot ignore.
    if proc.running and proc.pid then pcall(vim.uv.kill, proc.pid, "sigkill") end
    return
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
