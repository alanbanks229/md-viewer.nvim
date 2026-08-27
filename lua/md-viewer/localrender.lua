---The remote half of local rendering: find the helper's control socket,
---prove it belongs to *this* terminal, and route renderer traffic to it.
---
---Discovery is scan-and-verify, adoption is evidence. The helper's `ssh -R`
---forward lands a socket file on this machine; the plugin lists the
---candidate directories, refuses anything whose ownership or permissions are
---loose (sshd's default `StreamLocalBindMask` yields 0600, but that is the
---server's default, not a guarantee -- so verify, don't trust), performs the
---versioned hello on a candidate, and then emits a **pairing probe**: a
---seq-0 marker through this Neovim's own tty. Only the helper whose filter
---sits on this terminal can see that probe, so its `presented {seq = 0}`
---notification over the same socket is proof the socket and the terminal
---belong together. Two helper sessions to one VM can never silently
---cross-wire; a spoofed socket can say hello but can never confirm.
---
---Fallback is a state, never a silence: any socket death demotes to the
---stdio renderer (which spawns lazily on the next request, exactly as after
---a crash), notifies once, and records the reason where health and debug can
---show it.

local config = require("md-viewer.config")
local process = require("md-viewer.process")
local protocol = require("md-viewer.protocol")

local M = {}

M.PROTOCOL = 1
local PAIRING_TIMEOUT_MS = 2000
local HELLO_TIMEOUT_MS = 4000
local SOCKET_STALE_SECONDS = 24 * 60 * 60

local state = {
  phase = "off", -- off | connecting | attached | fallback
  reason = nil,
  socket_path = nil,
  token = nil,
  helper = nil, -- the hello result: helperVersion, terminal probe summary
  seq = 0,
  requests = 0,
  notifications = 0,
  fallback_notified = false,
}
local conn -- { pipe, buffer, callbacks, next_id, closed }
local listeners = {} -- event -> list of callbacks
-- One-shot consumer for the seq-0 pairing confirmation. Held apart from
-- `listeners` so repeated attach attempts cannot accumulate handlers, and so
-- the pairing ping is consumed rather than surfaced as an ordinary
-- `presented` notification.
local pairing_waiter

local function plugin_version()
  local ok, mod = pcall(require, "md-viewer")
  return ok and mod.version or "unknown"
end

-- Always delivered on the main loop: fire() is reachable from uv read
-- callbacks (socket death), and listeners are ordinary plugin code that will
-- touch nvim APIs.
local function fire(event, payload)
  for _, fn in ipairs(listeners[event] or {}) do
    vim.schedule(function() pcall(fn, payload) end)
  end
end

---Subscribe to helper notifications (`presented`, `missing`, `stats`) and
---lifecycle events (`attached`, `demoted`). Registration is for the Neovim
---session's lifetime, like process.on_exit.
function M.on(event, fn)
  listeners[event] = listeners[event] or {}
  table.insert(listeners[event], fn)
end

function M.active() return state.phase == "attached" end

function M.enabled() return config.get().render.location == "local" end

function M.token() return state.token end

---Monotonic marker sequence for this attachment. 0 is reserved for the
---pairing probe.
function M.next_seq()
  state.seq = state.seq + 1
  return state.seq
end

function M.status()
  return {
    phase = state.phase,
    reason = state.reason,
    socket_path = state.socket_path,
    helper_version = state.helper and state.helper.helperVersion or nil,
    helper_terminal = state.helper and state.helper.terminal or nil,
    protocol = M.PROTOCOL,
    seq = state.seq,
    requests = state.requests,
    notifications = state.notifications,
  }
end

-- -- permission checks ------------------------------------------------------

local function owner_only(mode)
  -- Group and other bits must all be zero; mode carries file-type bits above
  -- the permission triples, so read the two low octal digits arithmetically.
  return (math.floor(mode / 8) % 8) == 0 and (mode % 8) == 0
end

local function verify_socket(path)
  local st = vim.uv.fs_stat(path)
  if not st then return nil, "vanished" end
  if st.type ~= "socket" then return nil, "not a socket" end
  if st.uid ~= vim.uv.getuid() then return nil, "owned by another user" end
  if not owner_only(st.mode) then return nil, ("mode %o is looser than 0600"):format(st.mode % 512) end
  local parent = vim.fs.dirname(path)
  local dstat = vim.uv.fs_stat(parent)
  if not dstat then return nil, "parent directory vanished" end
  if dstat.uid ~= vim.uv.getuid() then return nil, "parent directory owned by another user" end
  if not owner_only(dstat.mode) then
    return nil, ("parent directory mode %o is looser than 0700"):format(dstat.mode % 512)
  end
  return st
end

local function username()
  local ok, passwd = pcall(vim.uv.os_get_passwd)
  if ok and passwd and passwd.username then return passwd.username end
  return os.getenv("USER") or "unknown"
end

local function socket_dirs()
  local dirs = {}
  local runtime = os.getenv("XDG_RUNTIME_DIR")
  if runtime and runtime ~= "" then dirs[#dirs + 1] = runtime .. "/md-viewer" end
  dirs[#dirs + 1] = "/tmp/md-viewer-" .. username()
  return dirs
end

---Create the directories the helper's `ssh -R` bind needs, 0700. Called at
---plugin setup in every mode, because sshd will not mkdir and the bind
---happens before the plugin ever runs in the session -- the directory has to
---exist from a *previous* life. Refuses (leaving a warning to health) if a
---directory exists but is not exclusively ours.
function M.ensure_socket_dirs()
  for _, dir in ipairs(socket_dirs()) do
    local st = vim.uv.fs_stat(dir)
    if not st then
      vim.fn.mkdir(dir, "p")
      vim.uv.fs_chmod(dir, 448) -- 0700; mkdir honours umask, this does not
    end
  end
end

---Candidate socket paths, newest first. `$MD_VIEWER_LOCAL_SOCKET` overrides
---the scan entirely (the same per-machine escape hatch shape as the other
---MD_VIEWER_* variables). Stale files are garbage-collected here because
---nothing else ever will: the helper that created a socket is on another
---machine and may be long gone.
function M.candidates()
  local override = os.getenv("MD_VIEWER_LOCAL_SOCKET")
  if override and override ~= "" then return { override } end
  local found = {}
  local now = os.time()
  for _, dir in ipairs(socket_dirs()) do
    local scanner = vim.uv.fs_scandir(dir)
    while scanner do
      local name, kind = vim.uv.fs_scandir_next(scanner)
      if not name then break end
      if name:match("^r%-%x+%.sock$") and (kind == "socket" or kind == nil) then
        local path = dir .. "/" .. name
        local st = vim.uv.fs_stat(path)
        if st then
          if now - (st.mtime.sec or 0) > SOCKET_STALE_SECONDS then
            vim.uv.fs_unlink(path)
          else
            found[#found + 1] = { path = path, mtime = st.mtime.sec or 0 }
          end
        end
      end
    end
  end
  table.sort(found, function(a, b) return a.mtime > b.mtime end)
  return vim.tbl_map(function(entry) return entry.path end, found)
end

-- -- connection ------------------------------------------------------------

-- While attached, kitty_raw's transactions leave through the marker
-- presenter; detaching for any reason puts the direct byte path back. The
-- requires live inside these functions because kitty_marker requires this
-- module at load time -- a top-level require here would be a cycle.
local function install_marker_presenter()
  local raw = require("md-viewer.backends.kitty_raw")
  raw.set_presenter(require("md-viewer.backends.kitty_marker").present)
end

local function restore_direct_presenter()
  local ok_raw, raw = pcall(require, "md-viewer.backends.kitty_raw")
  if ok_raw then raw.set_presenter(nil) end
  local ok_marker, marker = pcall(require, "md-viewer.backends.kitty_marker")
  if ok_marker then marker.reset() end
end

local function close_conn()
  if not conn then return end
  local closing = conn
  conn = nil
  if closing.pipe and not closing.pipe:is_closing() then
    pcall(closing.pipe.read_stop, closing.pipe)
    closing.pipe:close()
  end
  for id, callback in pairs(closing.callbacks) do
    closing.callbacks[id] = nil
    vim.schedule(function() callback(nil, "local renderer disconnected", { code = "LOCAL_DISCONNECT" }) end)
  end
end

local function demote(reason)
  if state.phase ~= "attached" and state.phase ~= "connecting" then return end
  close_conn()
  process.set_transport(nil)
  -- Before the "demoted" listeners fire: they re-render, and those renders
  -- must leave as direct bytes, not as markers nobody is filtering for.
  restore_direct_presenter()
  state.phase = "fallback"
  state.reason = reason
  state.helper = nil
  if not state.fallback_notified then
    state.fallback_notified = true
    vim.schedule(
      function()
        vim.notify(
          ("md-viewer: local renderer detached (%s); rendering on this host instead"):format(reason),
          vim.log.levels.WARN
        )
      end
    )
  end
  fire("demoted", { reason = reason })
end

local function dispatch_line(line)
  local value = protocol.decode_line(line)
  if not value then return end
  if type(value.id) == "number" and conn then
    local callback = conn.callbacks[value.id]
    conn.callbacks[value.id] = nil
    if callback then
      vim.schedule(function()
        if value.ok then
          callback(value.result, nil)
        else
          callback(nil, value.error or "local renderer error", { code = value.code, detail = value.detail })
        end
      end)
    end
    return
  end
  if type(value.event) == "string" then
    state.notifications = state.notifications + 1
    if value.event == "presented" and value.seq == 0 then
      local waiter = pairing_waiter
      pairing_waiter = nil
      if waiter then vim.schedule(waiter) end
      return
    end
    fire(value.event, value)
  end
end

local function send_request(method, params, callback)
  if not conn or conn.closed then
    vim.schedule(function() callback(nil, "local renderer disconnected", { code = "LOCAL_DISCONNECT" }) end)
    return nil
  end
  conn.next_id = conn.next_id + 1
  local id = conn.next_id
  conn.callbacks[id] = callback
  state.requests = state.requests + 1
  conn.pipe:write(protocol.encode({ id = id, method = method, params = params }), function(err)
    if err then
      local cb = conn and conn.callbacks[id]
      if conn then conn.callbacks[id] = nil end
      if cb then
        vim.schedule(function() cb(nil, "local socket write: " .. tostring(err), { code = "LOCAL_DISCONNECT" }) end)
      end
      demote("socket write failed: " .. tostring(err))
    end
  end)
  return id
end

---The transport handed to md-viewer.process while attached. Requests keep
---the exact `process.request` contract (callback gets result, err, meta), so
---renderer.lua, interaction.lua, animation.lua and health.lua cross the
---socket with zero caller changes.
local function transport()
  return {
    kind = "local-socket",
    request = send_request,
  }
end

---Emit the seq-0 pairing probe through this Neovim's own tty. This is the
---one marker not routed through the backend presenter: it exists before any
---backend is selected, draws nothing, and its whole job is to traverse the
---terminal byte path. Invisible everywhere -- a terminal without the helper
---discards an unknown APC.
local function emit_probe(token) vim.api.nvim_ui_send(("\27_Mv=1;t=%s;s=0;d=-;p=;x=\27\\"):format(token)) end

local function try_candidate(path, on_done)
  local pipe = vim.uv.new_pipe(false)
  local finished = false
  local function finish(ok, reason)
    if finished then return end
    finished = true
    if not ok then
      close_conn()
      if pipe and not pipe:is_closing() then pipe:close() end
    end
    on_done(ok, reason)
  end

  local st, why = verify_socket(path)
  if not st then return finish(false, ("%s: %s"):format(path, why)) end

  pipe:connect(path, function(err)
    if err then return finish(false, ("%s: connect failed (%s)"):format(path, err)) end
    conn = { pipe = pipe, buffer = "", callbacks = {}, next_id = 0, closed = false }
    pipe:read_start(function(read_err, data)
      if read_err or data == nil then
        if state.phase == "attached" then
          demote(read_err and ("socket read failed: " .. tostring(read_err)) or "helper closed the socket")
        else
          finish(false, ("%s: closed during handshake"):format(path))
        end
        return
      end
      conn.buffer = conn.buffer .. data
      while true do
        local newline = conn.buffer:find("\n", 1, true)
        if not newline then break end
        local line = conn.buffer:sub(1, newline - 1)
        conn.buffer = conn.buffer:sub(newline + 1)
        dispatch_line(line)
      end
    end)

    vim.schedule(function()
      local hello_timer = vim.uv.new_timer()
      hello_timer:start(HELLO_TIMEOUT_MS, 0, function()
        hello_timer:close()
        vim.schedule(function() finish(false, ("%s: hello timed out"):format(path)) end)
      end)
      send_request("hello", { protocol = M.PROTOCOL, pluginVersion = plugin_version() }, function(result, err, meta)
        hello_timer:stop()
        if not hello_timer:is_closing() then hello_timer:close() end
        if not result then
          local code = meta and meta.code or "?"
          return finish(false, ("%s: hello refused (%s: %s)"):format(path, code, tostring(err)))
        end
        state.token = result.token
        state.helper = result

        -- Hello proved versions agree; the probe proves this socket's helper
        -- sits on this terminal. Without it, two concurrent sessions to one
        -- VM could adopt each other's sockets and render on the wrong laptop
        -- with no error anywhere.
        local pairing_timer = vim.uv.new_timer()
        local function settle_pairing()
          pairing_timer:stop()
          if not pairing_timer:is_closing() then pairing_timer:close() end
        end
        pairing_waiter = function()
          settle_pairing()
          state.phase = "attached"
          state.socket_path = path
          process.set_transport(transport())
          install_marker_presenter()
          fire("attached", { helper = state.helper })
          finish(true)
        end
        pairing_timer:start(PAIRING_TIMEOUT_MS, 0, function()
          vim.schedule(function()
            if pairing_waiter then
              pairing_waiter = nil
              settle_pairing()
              finish(false, ("%s: pairing probe unanswered (helper on another terminal?)"):format(path))
            end
          end)
        end)
        emit_probe(result.token)
      end)
    end)
  end)
end

---Discover, verify, hello, pair. `on_done(ok, reason)` runs once, scheduled.
---Candidates are tried newest-first; the reasons for every refusal are
---joined into the failure message so ":checkhealth" has something concrete
---to show. A second attach while one is in flight joins it rather than
---starting a competing scan -- two concurrent hellos against a single-client
---helper would refuse each other.
local attach_waiters = {}
function M.attach(on_done)
  on_done = on_done or function() end
  if state.phase == "attached" then return on_done(true) end
  attach_waiters[#attach_waiters + 1] = on_done
  if state.phase == "connecting" then return end
  state.phase = "connecting"
  state.reason = nil
  local function settle(ok, reason)
    local waiters = attach_waiters
    attach_waiters = {}
    for _, waiter in ipairs(waiters) do
      waiter(ok, reason)
    end
  end
  local paths = M.candidates()
  if #paths == 0 then
    state.phase = "fallback"
    state.reason = "no helper socket found (run md-viewer-local around your ssh session)"
    return settle(false, state.reason)
  end
  local reasons = {}
  local index = 0
  local function try_next()
    index = index + 1
    if index > #paths then
      state.phase = "fallback"
      state.reason = table.concat(reasons, "; ")
      return settle(false, state.reason)
    end
    try_candidate(paths[index], function(ok, reason)
      if ok then return settle(true) end
      reasons[#reasons + 1] = reason
      try_next()
    end)
  end
  try_next()
end

---Detach deliberately (config change, VimLeave). Unlike demote() this is not
---a failure: no notification, phase returns to "off".
function M.detach()
  close_conn()
  process.set_transport(nil)
  restore_direct_presenter()
  state.phase = "off"
  state.reason = nil
  state.helper = nil
end

---Test seam: full reset, listeners included.
function M._reset()
  M.detach()
  listeners = {}
  attach_waiters = {}
  pairing_waiter = nil
  state.seq = 0
  state.requests = 0
  state.notifications = 0
  state.fallback_notified = false
end

---Test seam: the internals a fake helper needs to poke.
M._internal = { demote = demote, verify_socket = verify_socket, owner_only = owner_only }

return M
