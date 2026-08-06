local protocol = require("md-viewer.protocol")

local M = {}
local instance

local function plugin_root()
  local source = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function deliver_error(proc, message)
  for id, callback in pairs(proc.callbacks) do
    proc.callbacks[id] = nil
    vim.schedule(function() callback(nil, message) end)
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
            callback(nil, response.error or "renderer error")
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

function M.request(method, params, callback)
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
      vim.schedule(function() cb(nil, "renderer stdin: " .. tostring(write_err)) end)
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

function M.stop()
  local proc = instance
  instance = nil
  if not proc then return end
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
