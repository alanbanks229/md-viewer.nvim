-- Stage-4 live drive: spawn a real Neovim server, drive a drag-to-select
-- through the real input layer (nvim_input_mouse -> <LeftMouse>/<LeftDrag>/
-- <LeftRelease> mappings -> getmousepos() -> gesture dispatch), against the
-- real renderer and real Chromium. Asserts the overlay path end to end:
-- moving frames opt out of capture and are drawn as overlay placements, the
-- release settles with a true captured frame, and every overlay placement is
-- deleted after settle. Also invokes :MdViewerDebug and :MdViewerHealth --
-- the exact user commands, per policy section 5 -- since their output grew
-- overlay fields in this stage.
--
-- Run with:  nvim --headless -u NONE -i NONE -l scripts/stage4-live/drive.lua
-- Untracked throwaway; do not commit.

local script = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script)))
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
  ("luafile %s/scripts/stage4-live/setup.lua"):format(repo),
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

io.write("== stage-4 live drive ==\n")
rx(([[vim.cmd.edit(%q); vim.cmd("MdViewerOpen")]]):format(repo .. "/tests/fixtures/kitchen-sink.md"))

io.write("waiting for the first real render+capture (Chromium launch included)...\n")
local ready = poll("first rendered frame", 60000, SESSION .. [[
  if session.renderer_revision and session.image_id and session.last_placement then
    return { placement = session.last_placement, revision = session.renderer_revision }
  end
  return nil
]])
local placement = ready.placement
io.write(("rendered: revision %s, placement %dx%d cells at (%d,%d)\n"):format(
  ready.revision,
  placement.width,
  placement.height,
  placement.row,
  placement.col
))

-- The drag: press inside the upper text, then a diagonal sweep of drag
-- points, all through the real input queue. Coordinates are 0-based screen
-- cells for nvim_input_mouse.
local press_row = placement.row + math.floor(placement.height * 0.2)
local press_col = placement.col + 6
local function mouse(action, row, col)
  vim.rpcrequest(chan, "nvim_input_mouse", "left", action, "", 0, row, col)
end
mouse("press", press_row, press_col)
vim.uv.sleep(80)
-- Sample the overlay stats mid-gesture, while the selection is still
-- growing: the per-frame byte cost only exists on frames whose rect set
-- changed (an unchanged set diffs to zero bytes -- by design).
local mid = nil
for step = 1, 14 do
  mouse("drag", press_row + math.floor(step * 0.7), press_col + step * 4)
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
  mid = poll("overlay frames during the drag", 15000, SESSION .. [[
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
check(mid.frames >= 1, ("overlay frames displayed during the drag (%d)"):format(mid.frames))
check((mid.rects or 0) >= 1, ("overlay rectangles on screen mid-drag (%d)"):format(mid.rects or 0))
check(mid.health.overlay_placements >= 1, ("backend holds live overlay placements mid-drag (%d)"):format(mid.health.overlay_placements))
check((mid.bytes or 0) > 0 and (mid.bytes or 0) < 20000, ("a changed overlay frame cost %s bytes on the wire"):format(tostring(mid.bytes)))

mouse("release", press_row + 10, press_col + 56)

local settled = poll("settle after release", 20000, SESSION .. [[
  if session.selection_active and not session.overlay_set and session.retina_png_bytes then
    return {
      selection_len = session.selection_text_length,
      retina_bytes = session.retina_png_bytes,
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
check((settled.selection_len or 0) > 0, ("the committed selection has real text (%d chars)"):format(settled.selection_len or 0))
check(settled.retina_bytes > 100000, ("the settle frame is a true device-scale capture (%d bytes)"):format(settled.retina_bytes))

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
check(previews >= 2, ("the drag produced real preview envelopes (%d)"):format(previews))
check(previews_no_capture == previews, "every moving preview frame opted out of the capture")
check(sheets >= 1 and sheets <= 2, ("the tint sheet was requested once, not per frame (%d)"):format(sheets))
check(commits == 1, ("release produced exactly one settle commit (%d)"):format(commits))
check(commits_no_capture == 0, "the commit frame captured a real browser frame")

-- The exact user commands whose output changed this stage (policy section 5).
local debug_lines = rx([[
  vim.cmd("MdViewerDebug")
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  vim.cmd("bwipeout!")
  return table.concat(lines, "\n")
]])
check(debug_lines:find("overlay_frames", 1, true) ~= nil, ":MdViewerDebug reports the overlay diagnostics")
check(debug_lines:find("overlay_last_bytes", 1, true) ~= nil, ":MdViewerDebug reports the per-frame overlay bytes")
local health_ok = pcall(rx, [[vim.cmd("MdViewerHealth"); vim.cmd("bwipeout!")]])
check(health_ok, ":MdViewerHealth runs to completion with the overlay fields present")

io.write(("\nui sink: %d writes, %d total bytes (base upload + overlay traffic)\n"):format(settled.ui.writes, settled.ui.bytes))
io.write(("overlay frames %d, last frame %s bytes / %.2f ms; settle capture %d bytes\n"):format(
  settled.overlay_frames,
  tostring(mid.bytes),
  tonumber(mid.ms) or -1,
  settled.retina_bytes
))

pcall(rx, [[vim.cmd("MdViewerClose")]])
pcall(vim.rpcrequest, chan, "nvim_command", "qa!")
vim.uv.sleep(200)
server:kill(15)

if #failures > 0 then
  io.write(("\n%d FAILURES:\n  %s\n"):format(#failures, table.concat(failures, "\n  ")))
  os.exit(1)
end
io.write("\nlive drive: all checks passed\n")
os.exit(0)
