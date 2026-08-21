-- End-to-end regression for the selection-highlight overlay. Spawns a real
-- Neovim server and drives a `v`/motions preview visual selection through the
-- real input layer (nvim_input -> the buffer-local v/j/w/y mappings in
-- navigation.lua -> interaction.visual_start/visual_update/visual_stop),
-- against the real renderer and real Chromium. There is no mouse drag to
-- drive anymore -- highlighting only ever happens through vim-like motions --
-- so this is the keyboard equivalent of what used to be a real mouse drag.
-- Asserts the overlay path end to end: moving frames opt out of capture and
-- are drawn as overlay placements, `y` settles with a true captured frame,
-- and every overlay placement is deleted after settle. Also invokes
-- :MdViewerDebug and :MdViewerHealth -- the exact user commands -- since both
-- report overlay fields.
--
-- This is the only check that covers the whole gesture lifecycle against real
-- input and a real browser; the headless suites cover the pieces, not the
-- chain. Needs a Chrome/Chromium install and `npm ci --prefix renderer`, so it
-- is not wired into CI.
--
-- Run with:  nvim --headless -u NONE -i NONE -l scripts/overlay/live/drive.lua
-- Exits non-zero on any failed assertion.

local script = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script))))
local sock = vim.fn.tempname() .. ".sock"

local failures = {}
local function check(ok, label)
  if ok then
    io.write(("  ok: %s\n"):format(label))
  else
    failures[#failures + 1] = label
    io.write(("  FAIL: %s\n"):format(label))
  end
  return ok
end

local server = vim.system({
  vim.v.progpath,
  "--headless",
  "--listen",
  sock,
  "-u",
  "NONE",
  "-i",
  "NONE",
  "--cmd",
  ("set runtimepath+=%s"):format(repo),
  "-c",
  ("luafile %s/scripts/overlay/live/setup.lua"):format(repo),
}, { env = { MD_VIEWER_REPO = repo, PATH = vim.env.PATH, HOME = vim.env.HOME } })

local deadline = vim.uv.now() + 15000
while vim.uv.fs_stat(sock) == nil do
  if vim.uv.now() > deadline then
    io.write("server socket never appeared\n")
    server:kill(15)
    os.exit(1)
  end
  vim.uv.sleep(50)
end

local chan = vim.fn.sockconnect("pipe", sock, { rpc = true })
local function rx(code, ...) return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... }) end

local function poll(label, timeout_ms, code)
  local until_ms = vim.uv.now() + timeout_ms
  while vim.uv.now() < until_ms do
    local ok, value = pcall(rx, code)
    if ok and value ~= vim.NIL and value ~= false and value ~= nil then return value end
    vim.uv.sleep(100)
  end
  error(("timed out waiting for %s"):format(label))
end

local SESSION = [[
  local state = require("md-viewer.state")
  local _, session = next(state.all())
  if not session then return nil end
]]

io.write("== live overlay drive ==\n")
rx(([[vim.cmd.edit(%q); vim.cmd("MdViewerToggle")]]):format(repo .. "/tests/fixtures/kitchen-sink.md"))

io.write("waiting for the first real render+capture (Chromium launch included)...\n")
local ready = poll("first rendered frame", 60000, SESSION .. [[
  if session.renderer_revision and session.image_id and session.last_placement then
    return { placement = session.last_placement, revision = session.renderer_revision }
  end
  return nil
]])
local placement = ready.placement
io.write(
  ("rendered: revision %s, placement %dx%d cells at (%d,%d)\n"):format(
    ready.revision,
    placement.width,
    placement.height,
    placement.row,
    placement.col
  )
)

-- The selection: focus the preview window (`M.open` leaves focus on the
-- source window, unlike a real mouse click, which never needs it -- see
-- `caret_from_click`), place a caret with one real motion, then drive `v` and
-- a sweep of further motions, all through the real input queue.
rx(SESSION .. [[vim.api.nvim_set_current_win(session.preview_win)]])
local function input(keys) vim.rpcrequest(chan, "nvim_input", keys) end
input("l") -- no caret exists yet; this places one and moves it one character
poll("the initial caret placement", 15000, SESSION .. [[return session.caret_rect ~= nil or nil]])
input("v")
vim.uv.sleep(80)
-- Sample the overlay stats mid-extension, while the selection is still
-- growing: the per-frame byte cost only exists on frames whose rect set
-- changed (an unchanged set diffs to zero bytes -- by design).
local mid = nil
for step = 1, 14 do
  input("j2w")
  vim.uv.sleep(35)
  if step >= 6 and mid == nil then
    local ok, sample = pcall(rx, SESSION .. [[
      if (session.overlay_frames or 0) > 0 and session.overlay_set and (session.overlay_last_bytes or 0) > 0 then
        return {
          frames = session.overlay_frames,
          rects = session.overlay_rect_count,
          bytes = session.overlay_last_bytes,
          ms = session.overlay_last_ms,
          health = require("md-viewer.backends.kitty_raw").health(),
        }
      end
      return nil
    ]])
    if ok and type(sample) == "table" then mid = sample end
  end
end
if mid == nil then
  mid = poll("overlay frames during the extension", 15000, SESSION .. [[
    if (session.overlay_frames or 0) > 0 and session.overlay_set then
      return {
        frames = session.overlay_frames,
        rects = session.overlay_rect_count,
        bytes = session.overlay_last_bytes,
        ms = session.overlay_last_ms,
        health = require("md-viewer.backends.kitty_raw").health(),
      }
    end
    return nil
  ]])
end
check(mid.frames >= 1, ("overlay frames displayed during the extension (%d)"):format(mid.frames))
check((mid.rects or 0) >= 1, ("overlay rectangles on screen mid-extension (%d)"):format(mid.rects or 0))
check(
  mid.health.overlay_placements >= 1,
  ("backend holds live overlay placements mid-extension (%d)"):format(mid.health.overlay_placements)
)
check(
  (mid.bytes or 0) > 0 and (mid.bytes or 0) < 20000,
  ("a changed overlay frame cost %s bytes on the wire"):format(tostring(mid.bytes))
)

-- `y`: the same key a reader presses to finish a selection. It settles (the
-- keyboard equivalent of a mouse release) and copies in one motion.
input("y")

local settled = poll("settle after y", 20000, SESSION .. [[
  if session.selection_active and not session.overlay_set and session.retina_png_bytes then
    return {
      selection_len = session.selection_text_length,
      retina_bytes = session.retina_png_bytes,
      capture_scale = session.last_capture_scale,
      viewport_w = session.viewport_width_px,
      viewport_h = session.viewport_height_render_px,
      capture_ms = session.retina_capture_ms,
      overlay_frames = session.overlay_frames,
      health = require("md-viewer.backends.kitty_raw").health(),
      envelopes = _G.__mdviewer_live.envelopes,
      ui = _G.__mdviewer_live.ui,
    }
  end
  return nil
]])
check(settled.health.overlay_placements == 0, "every overlay placement is deleted after the settle frame")
check(settled.health.overlay_sheets >= 1, "the tint sheet stays cached for the next gesture")
check(
  (settled.selection_len or 0) > 0,
  ("the committed selection has real text (%d chars)"):format(settled.selection_len or 0)
)
-- Not an absolute byte count: PNG size is a function of the fixture, the pane
-- and the font, so a threshold picked on one machine reads as a regression on
-- the next. What "a true device-scale capture" means is that the frame on
-- screen is the device tier and carries the full device-pixel viewport, which
-- is checkable without knowing how well this particular page compresses.
check(
  settled.capture_scale == "device",
  ("the settle frame is the device tier, not the CSS one (%s)"):format(tostring(settled.capture_scale))
)
check(
  settled.retina_bytes > 20000,
  ("and it is a real full-viewport picture (%d bytes over %dx%d px)"):format(
    settled.retina_bytes,
    settled.viewport_w or -1,
    settled.viewport_h or -1
  )
)

-- Envelope audit: recorded from the real gesture, answered by the real
-- renderer. Moving frames opt out of capture; the commit does not.
local previews, previews_no_capture, commits, commits_no_capture, sheets = 0, 0, 0, 0, 0
for _, envelope in ipairs(settled.envelopes) do
  if envelope.method == "interact" and envelope.params.action == "selection_preview" then
    previews = previews + 1
    if envelope.params.capture == false then previews_no_capture = previews_no_capture + 1 end
    if envelope.params.overlaySheet then sheets = sheets + 1 end
  end
  if envelope.method == "interact" and envelope.params.action == "selection_commit" then
    commits = commits + 1
    if envelope.params.capture == false then commits_no_capture = commits_no_capture + 1 end
  end
end
check(previews >= 2, ("the extension produced real preview envelopes (%d)"):format(previews))
check(previews_no_capture == previews, "every moving preview frame opted out of the capture")
check(sheets >= 1 and sheets <= 2, ("the tint sheet was requested once, not per frame (%d)"):format(sheets))
check(commits == 1, ("y produced exactly one settle commit (%d)"):format(commits))
check(commits_no_capture == 0, "the commit frame captured a real browser frame")

-- The exact commands a user would run, since both report overlay fields.
--
-- Both are asynchronous: each issues a `health` request to the renderer and
-- writes its buffer in the callback, so reading buffer 0 on the next line reads
-- whatever was already current and finds nothing. Wait for the named buffer
-- instead. A `pcall` around `vim.cmd` proves nothing here for the same reason --
-- the command returns long before the report exists.
local function command_output(command, name)
  rx(("vim.cmd(%q)"):format(command))
  return poll(
    command,
    30000,
    ([[
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):find(%q, 1, true) then
        local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
        if #text > 0 then
          pcall(vim.api.nvim_buf_delete, b, { force = true })
          return text
        end
      end
    end
    return nil
  ]]):format(name)
  )
end

local debug_lines = command_output("MdViewerDebug", "md-viewer://debug")
check(debug_lines:find("overlay_frames", 1, true) ~= nil, ":MdViewerDebug reports the overlay diagnostics")
check(debug_lines:find("overlay_last_bytes", 1, true) ~= nil, ":MdViewerDebug reports the per-frame overlay bytes")
local health_lines = command_output("MdViewerHealth", "md-viewer://health")
check(#health_lines > 0, ":MdViewerHealth runs to completion with the overlay fields present")

io.write(
  ("\nui sink: %d writes, %d total bytes (base upload + overlay traffic)\n"):format(settled.ui.writes, settled.ui.bytes)
)
io.write(
  ("overlay frames %d, last frame %s bytes / %.2f ms; settle capture %d bytes\n"):format(
    settled.overlay_frames,
    tostring(mid.bytes),
    tonumber(mid.ms) or -1,
    settled.retina_bytes
  )
)

-- `MdViewerToggle` is the only visibility command; there is no MdViewerClose.
pcall(rx, [[vim.cmd("MdViewerToggle")]])
pcall(vim.rpcrequest, chan, "nvim_command", "qa!")
vim.uv.sleep(200)
server:kill(15)

if #failures > 0 then
  io.write(("\n%d FAILURES:\n  %s\n"):format(#failures, table.concat(failures, "\n  ")))
  os.exit(1)
end
io.write("\nlive drive: all checks passed\n")
os.exit(0)
