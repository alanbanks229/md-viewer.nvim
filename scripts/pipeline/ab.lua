-- Scroll-pipeline A/B, driven by hand in a real session.
--
-- What it proves: whether keeping several scroll captures in flight actually
-- raises the frame rate on *this* link, and by how much. Everything else about
-- client rendering has been measured; this is the one number that decides
-- whether the whole architecture pays off, because the operator reported that
-- removing 13.3 MB of pixels from the link felt like no change at all.
--
-- Why it should. With the renderer on the machine the terminal is on, one frame
-- costs a round trip plus a render, strictly serially -- measured at 92ms and
-- 15ms, so the renderer is idle 86% of the time and the preview updates 9 times
-- a second where the browser could manage 66. With N captures outstanding the
-- floor becomes max(render, round_trip / N).
--
-- The falsifiable claim: `interval floor` should fall from ~107ms to under
-- 40ms, and `delivered` from ~4.7/s to above 20/s. If it does not, the model of
-- this pipeline is wrong and the report says so rather than reporting a win.
--
-- What it needs: a preview open (`:MdViewerToggle`) on a document long enough
-- to scroll for several seconds, and a session started through
-- `bin/md-viewer-ssh` -- `:MdViewerHealth verbose` must say `client rendering:
-- yes`. With the renderer beside Neovim the depth is pinned to 1 and both
-- phases measure the same thing.
--
-- How to run it, from inside Neovim:
--
--     :runtime scripts/pipeline/ab.lua     -- arms phase 1
--     ...wheel-scroll the whole document, continuously...
--     :PipelineAB                          -- arms phase 2
--     ...wheel-scroll the whole document again, the same way...
--     :PipelineAB                          -- prints the report
--
-- Scroll *continuously* in both phases. A hand-driven scroll with pauses in it
-- puts idle time in the mean, which is the mistake this project has already
-- made once and spent a round trip to the operator correcting.
--
-- The original configuration is restored at the end, and by :PipelineABCancel
-- if you stop partway. Nothing is written to disk.

local config = require("md-viewer.config")
local state = require("md-viewer.state")
local client_render = require("md-viewer.client_render")

local PHASES = {
  { label = "serial", depth = 1, note = "one capture in flight -- what shipped with client rendering" },
  { label = "pipelined", depth = 3, note = "three in flight -- the round trip stops gating the frame rate" },
}

local step = 0
local saved
local results = {}

local function session()
  local found = state.visible_in_tab()
  if not found then error("md-viewer: no preview is open in this tab. Run :MdViewerToggle first.", 0) end
  return found
end

local phase_started = 0
local function reset_counters(current)
  current.fast_frame_count = 0
  current.fast_bytes_total = 0
  current.fast_interval_min_ms = nil
  current.fast_interval_sum_ms = nil
  current.fast_interval_count = nil
  current.fast_last_ns = nil
  current.fast_capture_ms = nil
  current.coalesced_scroll_events = 0
  current.client_frame_count = 0
  current.client_bytes_deferred = 0
  phase_started = vim.uv.hrtime()
end

local function apply_depth(depth)
  local next_config = vim.deepcopy(config.get())
  next_config.client_render.scroll_pipeline = depth
  config.setup(next_config)
end

local function restore()
  if saved then
    config.setup(saved)
    saved = nil
  end
end

local function collect(current)
  return {
    depth = current.scroll_pipeline_depth,
    depth_source = current.scroll_pipeline_source,
    frames = current.fast_frame_count or 0,
    bytes = current.fast_bytes_total or 0,
    coalesced = current.coalesced_scroll_events or 0,
    client_frames = current.client_frame_count or 0,
    deferred = current.client_bytes_deferred or 0,
    capture_ms = current.fast_capture_ms,
    -- The floor is the honest measure of how fast this loop can turn. The mean
    -- includes whatever the hand did; the minimum is what the pipeline managed
    -- when it was genuinely saturated.
    interval_min = current.fast_interval_min_ms,
    interval_mean = current.fast_interval_count
        and current.fast_interval_count > 0
        and (current.fast_interval_sum_ms / current.fast_interval_count)
      or nil,
    seconds = (vim.uv.hrtime() - phase_started) / 1e9,
  }
end

local function ms(value)
  if not value then return "--" end
  return ("%.0f ms"):format(value)
end

local function rate(entry)
  if not entry.interval_mean or entry.interval_mean <= 0 then return "--" end
  return ("%.1f/s"):format(1000 / entry.interval_mean)
end

local function ceiling(entry)
  if not entry.interval_min or entry.interval_min <= 0 then return "--" end
  return ("%.1f/s"):format(1000 / entry.interval_min)
end

---What the floor is made of. Everything above the capture is the link, and it
---is the whole point of the exercise: a serial loop pays a round trip per
---frame, a pipelined one pays it once and then overlaps.
local function link_share(entry)
  if not (entry.interval_min and entry.capture_ms) then return "--" end
  local link = entry.interval_min - entry.capture_ms
  if link < 0 then link = 0 end
  return ("%s (%.0f%% of the floor)"):format(ms(link), link / entry.interval_min * 100)
end

local function report()
  local a, b = results[1], results[2]
  local lines = {
    "",
    "md-viewer scroll-pipeline A/B",
    "=============================",
    "",
    ("%-22s %18s %18s"):format("", PHASES[1].label, PHASES[2].label),
    ("%-22s %18s %18s"):format("captures in flight", tostring(a.depth), tostring(b.depth)),
    ("%-22s %18s %18s"):format("moving frames", tostring(a.frames), tostring(b.frames)),
    ("%-22s %18s %18s"):format("scrolled for", ("%.1f s"):format(a.seconds), ("%.1f s"):format(b.seconds)),
    "",
    ("%-22s %18s %18s"):format("interval floor", ms(a.interval_min), ms(b.interval_min)),
    ("%-22s %18s %18s"):format("  of which link", link_share(a), link_share(b)),
    ("%-22s %18s %18s"):format("  of which capture", ms(a.capture_ms), ms(b.capture_ms)),
    ("%-22s %18s %18s"):format("ceiling rate", ceiling(a), ceiling(b)),
    ("%-22s %18s %18s"):format("delivered rate", rate(a), rate(b)),
    ("%-22s %18s %18s"):format("events coalesced", tostring(a.coalesced), tostring(b.coalesced)),
    "",
  }

  if a.depth == b.depth then
    lines[#lines + 1] = "INCONCLUSIVE: both phases ran at the same depth."
    lines[#lines + 1] = ("  Depth was pinned by: %s"):format(b.depth_source or "unknown")
    lines[#lines + 1] = "  Client rendering has to be on for this to measure anything --"
    lines[#lines + 1] = "  check `client rendering` in :MdViewerHealth verbose."
    return lines
  end

  if not (a.interval_min and b.interval_min) then
    lines[#lines + 1] = "INCONCLUSIVE: one phase produced fewer than two frames."
    lines[#lines + 1] = "  Scroll continuously for several seconds in each phase."
    return lines
  end

  local speedup = a.interval_min / b.interval_min
  local delivered = (a.interval_mean and b.interval_mean) and (a.interval_mean / b.interval_mean) or nil
  lines[#lines + 1] = ("The floor moved %.2fx (%s -> %s)."):format(speedup, ms(a.interval_min), ms(b.interval_min))
  if delivered then
    lines[#lines + 1] = ("Delivered frames moved %.2fx (%s -> %s)."):format(delivered, rate(a), rate(b))
  end
  lines[#lines + 1] = ""

  -- The prediction this was built to test, stated before the run and checked
  -- against it here rather than reinterpreted afterwards.
  local floor_ok = b.interval_min < 40
  local rate_ok = b.interval_mean and (1000 / b.interval_mean) > 20
  if floor_ok and rate_ok then
    lines[#lines + 1] = "WORKING AS DESIGNED. The prediction was a floor under 40 ms and"
    lines[#lines + 1] = "delivery above 20/s, and both landed. The round trip has stopped"
    lines[#lines + 1] = "gating the frame rate; the render is the constraint now, which is"
    lines[#lines + 1] = "the same thing that constrains a local preview."
  elseif speedup > 1.5 then
    lines[#lines + 1] = ("PARTIAL. The floor did improve %.2fx, but the prediction was a floor"):format(speedup)
    lines[#lines + 1] = "under 40 ms and delivery above 20/s and it did not land. Try"
    lines[#lines + 1] = "client_render.scroll_pipeline = 6; if that does not close the gap,"
    lines[#lines + 1] = "something not in `capture` or the round trip is setting the floor."
  else
    lines[#lines + 1] = ("NOT WORKING. The floor barely moved (%.2fx), so the round trip was"):format(speedup)
    lines[#lines + 1] = "not what was setting it and the model behind this change is wrong."
    lines[#lines + 1] = ("Unaccounted per frame: %s."):format(link_share(b))
    lines[#lines + 1] = "Report this rather than raising the depth -- more requests in flight"
    lines[#lines + 1] = "against a floor that is not the link is only more wasted work."
  end
  return lines
end

local function show(lines)
  vim.api.nvim_echo(vim.tbl_map(function(line) return { line .. "\n" } end, lines), true, {})
end

local function advance()
  local ok, err = pcall(function()
    local current = session()
    if step > 0 then results[step] = collect(current) end
    if step >= #PHASES then
      restore()
      show(report())
      step = 0
      results = {}
      return
    end
    step = step + 1
    local phase = PHASES[step]
    if step == 1 then
      saved = vim.deepcopy(config.get())
      if not client_render.resolve("kitty_raw") then
        local _, reason = client_render.resolve("kitty_raw")
        show({
          "",
          "md-viewer: this session is not client rendering, so both phases would",
          "measure the same thing. Reason: " .. tostring(reason),
          "",
          "Start the session through bin/md-viewer-ssh and check",
          "`client rendering` in :MdViewerHealth verbose.",
        })
        saved = nil
        step = 0
        return
      end
    end
    apply_depth(phase.depth)
    reset_counters(current)
    show({
      "",
      ("md-viewer pipeline A/B -- phase %d of %d: %s"):format(step, #PHASES, phase.label),
      ("  %d capture(s) in flight -- %s"):format(phase.depth, phase.note),
      "",
      "Now wheel-scroll the whole document, continuously, for several seconds.",
      ("Then run :PipelineAB again%s."):format(step == #PHASES and " for the report" or ""),
    })
  end)
  if not ok then
    restore()
    step = 0
    results = {}
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
end

vim.api.nvim_create_user_command("PipelineAB", advance, { desc = "md-viewer: step the scroll-pipeline A/B" })
vim.api.nvim_create_user_command("PipelineABCancel", function()
  restore()
  step = 0
  results = {}
  vim.notify("md-viewer: pipeline A/B cancelled, configuration restored", vim.log.levels.INFO)
end, { desc = "md-viewer: abandon the scroll-pipeline A/B and restore configuration" })

advance()
