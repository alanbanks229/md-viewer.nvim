-- Remote-project A/B, driven by hand in a real session.
--
-- What it proves, with the prediction fixed before any run: once a remote
-- document's images have been fetched, scrolling it performs ZERO remote
-- transport calls, and its frame cadence sits within hand-scroll noise
-- (taken as 30%) of a local document on the same machine. Those two numbers
-- are the whole architectural claim -- the render loop never touches SSH --
-- so if either misses, the claim is wrong and the printed table is the bug
-- report.
--
-- What it needs: Neovim running LOCALLY (`:MdViewerDebug` must say
-- `ssh session: no`), a way to open a remote document (remote-ssh.nvim's
-- :RemoteOpen, or netrw's :e scp://...), and a local Markdown file of
-- comparable length for the baseline. Nothing is written to disk and no
-- configuration is changed.
--
-- How to run it, from inside Neovim:
--
--     :edit /path/to/a/local/README.md
--     :MdViewerToggle                             " preview the LOCAL file
--     :runtime scripts/remote-projects/ab.lua     " arms the baseline
--     ...wheel-scroll the whole document...
--     :RemoteProjectAB                            " ends the baseline
--     :RemoteOpen rsync://host//path/README.md    " the REMOTE document
--     :MdViewerToggle                             " preview it; WAIT for
--                                                 " its images to appear
--     :RemoteProjectAB                            " arms the remote phase
--     ...wheel-scroll the same way...
--     :RemoteProjectAB                            " prints the report
--
-- :RemoteProjectABCancel abandons a run partway and unhooks the counter.

local remote_assets = require("md-viewer.remote_assets")
local state = require("md-viewer.state")

local step = 0
local results = {}
local saved_run
local transport_calls = 0
local transport_mark = 0
local phase_started = 0

local function session()
  local found = state.visible_in_tab()
  if not found then error("md-viewer: no preview is open in this tab. Run :MdViewerToggle first.", 0) end
  return found
end

local function hook_transport()
  if saved_run then return end
  saved_run = remote_assets._run
  remote_assets._run = function(argv, opts, on_exit)
    transport_calls = transport_calls + 1
    return saved_run(argv, opts, on_exit)
  end
end

local function unhook_transport()
  if saved_run then
    remote_assets._run = saved_run
    saved_run = nil
  end
end

local function reset_counters(current)
  current.fast_frame_count = 0
  current.fast_bytes_total = 0
  current.retina_frame_count = 0
  current.retina_bytes_total = 0
  current.fast_interval_min_ms = nil
  current.fast_interval_sum_ms = nil
  current.fast_interval_count = nil
  current.fast_last_ns = nil
  current.coalesced_scroll_events = 0
  phase_started = vim.uv.hrtime()
end

local function collect(current)
  return {
    remote = current.remote ~= nil,
    remote_ready = current.remote and current.remote.ready or false,
    assets = current.remote and current.remote.assets or nil,
    fast_frames = current.fast_frame_count or 0,
    retina_frames = current.retina_frame_count or 0,
    seconds = (vim.uv.hrtime() - phase_started) / 1e9,
    interval_min = current.fast_interval_min_ms,
    capture_ms = current.fast_capture_ms,
    scroll_scale = current.scroll_scale,
    scroll_scale_source = current.scroll_scale_source,
    transport_delta = transport_calls - transport_mark,
  }
end

local function rate(phase) return phase.fast_frames / math.max(phase.seconds, 0.001) end

local function ms(value)
  if not value then return "--" end
  return ("%d ms"):format(value)
end

local function report()
  local a, b = results.local_doc, results.remote_doc
  local lines = {
    "md-viewer remote-project A/B",
    "",
    ("%-28s %14s %14s"):format("", "local file", "remote file"),
    ("%-28s %14s %14s"):format("session kind", a.remote and "REMOTE(?)" or "local", b.remote and "remote" or "LOCAL(?)"),
    ("%-28s %14s %14s"):format(
      "moving frames delivered",
      ("%d in %.0fs"):format(a.fast_frames, a.seconds),
      ("%d in %.0fs"):format(b.fast_frames, b.seconds)
    ),
    ("%-28s %14s %14s"):format("  delivered rate", ("%.1f/s"):format(rate(a)), ("%.1f/s"):format(rate(b))),
    ("%-28s %14s %14s"):format("frame produced every", ms(a.interval_min), ms(b.interval_min)),
    ("%-28s %14s %14s"):format("  capture (local Chromium)", ms(a.capture_ms), ms(b.capture_ms)),
    ("%-28s %14s %14s"):format(
      "scroll_scale",
      ("%s"):format(tostring(a.scroll_scale)),
      ("%s"):format(tostring(b.scroll_scale))
    ),
    -- The headline. The whole architecture exists so this reads 0.
    ("%-28s %14s %14s"):format("REMOTE I/O DURING SCROLL", "n/a", ("%d calls"):format(b.transport_delta)),
    ("%-28s %14s %14s"):format("settle frames taken", tostring(a.retina_frames), tostring(b.retina_frames)),
  }
  if b.assets then
    lines[#lines + 1] = ("%-28s %14s %14s"):format(
      "assets (whole session)",
      "n/a",
      ("%d/%d/%d f/r/x"):format(b.assets.fetched or 0, b.assets.refused or 0, b.assets.failed or 0)
    )
  end
  lines[#lines + 1] = ""

  local verdict
  if not b.remote then
    verdict = "INCONCLUSIVE: the second phase was not a remote document. Open one "
      .. "(:RemoteOpen rsync://host//path/doc.md or :e scp://...) and run again."
  elseif b.scroll_scale ~= nil then
    verdict = ("INCONCLUSIVE: the moving frame was reduced (%s), so this Neovim is itself "):format(
      tostring(b.scroll_scale_source)
    ) .. "on the far side of SSH. This probe measures the local-Neovim arrangement; see :help md-viewer-ssh for the other one."
  elseif a.fast_frames == 0 or b.fast_frames == 0 then
    verdict = "INCONCLUSIVE: a phase captured no moving frames. Wheel-scroll (not j/k) for a few seconds in each."
  elseif b.transport_delta > 0 then
    verdict = ("NOT AS DESIGNED: %d remote transport call(s) happened during the scroll. "):format(b.transport_delta)
      .. "The prediction was zero; report this table. (If images were still appearing when the "
      .. "phase was armed, wait for them and run the whole probe again.)"
  elseif rate(b) >= 0.7 * rate(a) then
    verdict = ("WORKING as predicted: zero remote I/O in the scroll loop, %.1f/s remote vs %.1f/s local."):format(
      rate(b),
      rate(a)
    )
  else
    verdict = ("PARTIAL: zero remote I/O as predicted, but the remote document delivered %.1f/s "):format(rate(b))
      .. ("against %.1f/s local -- outside hand-scroll noise. Compare the two capture columns and report."):format(
        rate(a)
      )
  end
  lines[#lines + 1] = verdict

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(buf, "md-viewer://remote-project-ab")
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_height(0, math.min(#lines + 1, 20))
  print("md-viewer: remote-project A/B complete.")
end

local function advance()
  if step == 0 then
    hook_transport()
    reset_counters(session())
    step = 1
    print("md-viewer remote A/B 1/3 -- baseline armed on the CURRENT (local) preview. "
      .. "Wheel-scroll the whole document, then run :RemoteProjectAB")
  elseif step == 1 then
    results.local_doc = collect(session())
    step = 2
    print("md-viewer remote A/B 2/3 -- baseline recorded. Now open the preview on your REMOTE "
      .. "document, WAIT for its images to appear, then run :RemoteProjectAB to arm the scroll phase.")
  elseif step == 2 then
    local current = session()
    reset_counters(current)
    transport_mark = transport_calls
    step = 3
    print("md-viewer remote A/B 3/3 -- remote phase armed. Wheel-scroll the same way, then run :RemoteProjectAB")
  else
    results.remote_doc = collect(session())
    unhook_transport()
    step = 0
    report()
  end
end

vim.api.nvim_create_user_command("RemoteProjectAB", function()
  local ok, err = pcall(advance)
  if not ok then
    unhook_transport()
    step = 0
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
end, { desc = "md-viewer: step through the remote-project A/B" })

vim.api.nvim_create_user_command("RemoteProjectABCancel", function()
  unhook_transport()
  step = 0
  results = {}
  print("md-viewer: remote-project A/B cancelled.")
end, { desc = "md-viewer: abandon the remote-project A/B" })

-- Sourcing the file arms the baseline, so the whole run is one :runtime and
-- three :RemoteProjectAB calls.
local armed_ok, armed_err = pcall(advance)
if not armed_ok then vim.notify(tostring(armed_err), vim.log.levels.ERROR) end
