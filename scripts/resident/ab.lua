-- Resident-region A/B, driven by hand in a real session.
--
-- What it proves: whether scrolling back through content the terminal is
-- already holding sends **no new pixels**, measured as total bytes handed to
-- `nvim_ui_send` rather than as PNG bytes alone. That distinction is the whole
-- reason this file exists rather than a column in scripts/scroll-scale/ab.lua:
-- "the payload fell to zero" and "the traffic fell to zero" are different
-- claims, and docs/local-render-design.md records this project being wrong
-- about exactly that difference once already.
--
-- What it needs: Neovim running on the far end of the link (this measures a
-- wire, and a local terminal does not have one), on iTerm2, outside tmux, with
-- a preview open on a document several viewports long. The plugin's own README
-- is the reference document every number in docs/local-render-design.md was
-- taken against.
--
-- How to run it, from inside Neovim:
--
--     :runtime scripts/resident/ab.lua     -- arms phase 1 (resident panning off)
--     ...scroll the protocol below...
--     :ResidentAB                          -- arms phase 2 (resident panning on)
--     ...scroll the same way; :ResidentABMark once a region has filled...
--     :ResidentAB                          -- prints the report
--
-- The protocol, run identically in both phases:
--
--   1. Wait for the first frame. In phase 2, wait for `regions 1` in
--      `:MdViewerDebug`, then run `:ResidentABMark`.
--   2. Wheel forward, staying inside the resident range; stop; repeat 5 times.
--   3. Wheel back through the same range.
--   4. THE CLAIM: upload bytes since the mark should be 0 and fills should be 1.
--   5. Cross a region boundary once, and keep wheeling while it fills -- this is
--      the case the shared-wire hold exists for.
--   6. Continue inside the new region.
--
-- The original configuration is restored at the end, and by :ResidentABCancel
-- if you stop partway. Nothing is written to disk.

local config = require("md-viewer.config")
local controller = require("md-viewer.controller")
local state = require("md-viewer.state")

-- Bytes on the wire are base64, so 4/3 of the payload, and the SSM tunnel's
-- measured ceiling is 0.80 MB/s. Identical to scripts/scroll-scale/ab.lua on
-- purpose: two harnesses reporting the same link in different units would be
-- two numbers nobody could compare.
local BYTES_PER_SECOND = 800000

local PHASES = {
  { key = "baseline", label = "baseline", pan = "off", note = "today's path -- every scroll is a frame" },
  { key = "treatment", label = "treatment", pan = "on", note = "resident regions -- a scroll may be a crop" },
}

local step = 0
local saved
local results = {}
-- The reading taken when a region first became resident, so the report can
-- separate the one fill that paid for it from the scrolling that spends it.
local mark_base

local function session()
  local found = state.visible_in_tab()
  if not found then error("md-viewer: no preview is open in this tab. Run :MdViewerToggle first.", 0) end
  return found
end

local phase_started = 0

---Blank the per-phase counters so each arm reports only its own traffic.
---
---Deliberately does *not* touch the regions themselves in the treatment arm:
---what is being measured is a cache, and emptying it between the counters and
---the scrolling would measure a cold start twice.
local function reset_counters(current)
  current.ui_bytes_total = 0
  current.coalesced_scroll_events = 0
  current.fast_frame_count = 0
  current.fast_bytes_total = 0
  current.retina_frame_count = 0
  current.retina_bytes_total = 0
  current.fast_png_bytes = nil
  current.retina_png_bytes = nil
  local live = current.resident
  for _, name in ipairs({
    "hits",
    "misses",
    "pans",
    "unplaced_places",
    "fills",
    "stale_fills",
    "abandoned_fills",
    "evictions",
    "blocked_by_find",
    "blocked_by_selection",
    "frames_suppressed_by_hold",
    "height_reduced",
    "upload_bytes",
    "placement_bytes",
  }) do
    live[name] = 0
  end
  mark_base = nil
  phase_started = vim.uv.hrtime()
end

---Turn the feature on or off for a session that is already open.
---
---The gate is evaluated once, when the preview opens, so changing the option
---alone would leave both arms running whatever the session started as -- the
---shape of A/B that reports a difference of zero and looks like a null result.
---
---`controller.reevaluate_resident` is the controller's own answer, applied by
---the same code path a fresh session uses. An earlier version of this reproduced
---that logic here and got it wrong in one line, which armed the treatment arm
---with the gate's *success* message recorded as a fallback reason -- so the arm
---under test silently ran on the ordinary path and the run compared the baseline
---with itself. A harness must not reimplement the decision it is measuring.
local function apply_pan(current, value)
  local next_config = vim.deepcopy(config.get())
  next_config.image.resident_pan = value
  config.setup(next_config)
  return controller.reevaluate_resident(current)
end

local function restore()
  if saved then
    config.setup(saved)
    saved = nil
  end
end

local function snapshot(current)
  local live = current.resident
  local decoded = 0
  local resident = require("md-viewer.resident")
  for _, region in ipairs(live.regions) do
    decoded = decoded + resident.decoded_bytes(region)
  end
  return {
    -- The measure. Everything else on the report is a component of it or an
    -- explanation for it.
    ui_bytes = current.ui_bytes_total or 0,
    upload_bytes = live.upload_bytes,
    placement_bytes = live.placement_bytes,
    hits = live.hits,
    misses = live.misses,
    pans = live.pans,
    unplaced = live.unplaced_places,
    fills = live.fills,
    stale_fills = live.stale_fills,
    abandoned_fills = live.abandoned_fills,
    evictions = live.evictions,
    suppressed = live.frames_suppressed_by_hold,
    blocked_find = live.blocked_by_find,
    blocked_selection = live.blocked_by_selection,
    hold_ms = live.upload_hold_ms,
    wire_rate = live.wire_bytes_per_ms,
    height_scale = live.height_scale,
    regions = #live.regions,
    decoded_mb = decoded / 1048576,
    fallback = live.fallback_reason,
    gate = live.gate_reason,
    fast_frames = current.fast_frame_count or 0,
    fast_total = current.fast_bytes_total or 0,
    retina_frames = current.retina_frame_count or 0,
    retina_total = current.retina_bytes_total or 0,
    coalesced = current.coalesced_scroll_events or 0,
    seconds = (vim.uv.hrtime() - phase_started) / 1e9,
  }
end

local function number(value)
  if not value then return "--" end
  local formatted = tostring(math.floor(value))
  return (formatted:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

---How much of the link a phase actually used. The number to trust, for the
---reason scripts/scroll-scale/ab.lua states: `nvim_ui_send` is asynchronous, so
---frames are produced far faster than the wire drains them and a production
---rate says nothing about when a picture reaches the screen.
---
---Counts `ui_bytes` rather than PNG bytes, because placements, deletions and
---overlay rectangles cross the same pty -- and a feature whose entire claim is
---"it sends placements instead of pixels" cannot be measured in a unit that
---leaves the placements out.
local function saturation(phase)
  if not (phase.seconds and phase.seconds > 0) then return nil end
  return phase.ui_bytes * 4 / 3 / phase.seconds / BYTES_PER_SECOND * 100
end

local function row(label, a, b) return ("%-28s %14s %14s"):format(label, a, b) end

local function report()
  local a, b = results.baseline, results.treatment
  local lines = {
    "md-viewer resident-region A/B",
    "",
    row("", "baseline (off)", "treatment (on)"),
    row("TOTAL nvim_ui_send BYTES", number(a.ui_bytes), number(b.ui_bytes)),
    row(
      "  wire saturation",
      saturation(a) and ("%.0f%%"):format(saturation(a)) or "--",
      saturation(b) and ("%.0f%%"):format(saturation(b)) or "--"
    ),
    row("  over", ("%.0fs"):format(a.seconds), ("%.0fs"):format(b.seconds)),
    "",
    row("region uploads", number(a.upload_bytes), number(b.upload_bytes)),
    row("placement commands", number(a.placement_bytes), number(b.placement_bytes)),
    row(
      "moving frames",
      ("%d / %s B"):format(a.fast_frames, number(a.fast_total)),
      ("%d / %s B"):format(b.fast_frames, number(b.fast_total))
    ),
    row(
      "settle frames",
      ("%d / %s B"):format(a.retina_frames, number(a.retina_total)),
      ("%d / %s B"):format(b.retina_frames, number(b.retina_total))
    ),
    "",
    row("resident hits / misses", ("%d / %d"):format(a.hits, a.misses), ("%d / %d"):format(b.hits, b.misses)),
    row("  pans / re-places", ("%d / %d"):format(a.pans, a.unplaced), ("%d / %d"):format(b.pans, b.unplaced)),
    row(
      "fills (stale / abandoned)",
      ("%d (%d/%d)"):format(a.fills, a.stale_fills, a.abandoned_fills),
      ("%d (%d/%d)"):format(b.fills, b.stale_fills, b.abandoned_fills)
    ),
    row("evictions", number(a.evictions), number(b.evictions)),
    row(
      "regions / decoded",
      ("%d / %.0f MB"):format(a.regions, a.decoded_mb),
      ("%d / %.0f MB"):format(b.regions, b.decoded_mb)
    ),
    "",
    row("frames held off the wire", number(a.suppressed), number(b.suppressed)),
    row(
      "  last hold",
      a.hold_ms and ("%d ms"):format(a.hold_ms) or "--",
      b.hold_ms and ("%d ms"):format(b.hold_ms) or "--"
    ),
    row(
      "  measured link",
      a.wire_rate and ("%.0f B/ms"):format(a.wire_rate) or "--",
      b.wire_rate and ("%.0f B/ms"):format(b.wire_rate) or "--"
    ),
    row("coalesced (never sent)", number(a.coalesced), number(b.coalesced)),
    row(
      "pans refused: find/sel",
      ("%d / %d"):format(a.blocked_find, a.blocked_selection),
      ("%d / %d"):format(b.blocked_find, b.blocked_selection)
    ),
    row("region height scale", ("%.2f"):format(a.height_scale or 1), ("%.2f"):format(b.height_scale or 1)),
    "",
  }

  local verdict
  if b.fallback then
    verdict = ("FELL BACK: %s. The treatment arm ran on the ordinary path, so this run compares "):format(b.fallback)
      .. "the baseline with itself. Report the reason."
  elseif b.fills == 0 then
    -- Deliberately not "check gate_reason". The gate passing is the *common*
    -- case here and it reports its success in the same field it reports refusal,
    -- so pointing at it sends a reader to a line that looks fine. Every field
    -- below is a place a settle can decline to ask for a region while nothing
    -- has failed and nothing has been counted.
    verdict = ("NO REGION WAS EVER FILLED, though %d settle frames were taken -- so the settles ran "):format(
      b.retina_frames
    ) .. "and none of them asked for a region. In :MdViewerDebug's `resident` block, in order: " .. "`plan_refusal` (no region fits the budget at this viewport), " .. "`fallback_reason` (it gave up earlier in the session), " .. "then check whether a drag is still registered -- a click leaves state behind that a " .. "settle will not fill through. If `fills` is above 0 but `regions` is 0 instead, the " .. "capture happened and `last_insert_refusal` says why the cache would not keep it."
  elseif not mark_base then
    verdict = "NO MARK TAKEN: run :ResidentABMark in phase 2 once `regions 1` appears, then scroll "
      .. "inside the region. Without it the report cannot separate the one fill from the scrolling."
  else
    local since = {}
    for key, value in pairs(b) do
      since[key] = type(value) == "number" and (value - (mark_base[key] or 0)) or value
    end
    lines[#lines + 1] = ("Since the mark: %s upload bytes, %s placement bytes, %d hits, %d misses, %d fills."):format(
      number(since.upload_bytes),
      number(since.placement_bytes),
      since.hits,
      since.misses,
      since.fills
    )
    -- The success criterion, stated as the plan states it: not "smaller", not
    -- "fewer" -- none.
    if since.upload_bytes == 0 and since.hits > 0 then
      lines[#lines + 1] = ("%d scrolls inside resident content cost %s bytes of placement and no pixels at all."):format(
        since.hits,
        number(since.placement_bytes)
      )
      verdict = ("WORKING: repeated scrolling through resident content sent zero new pixel payload "):format()
        .. ("(%s placement bytes for %d scrolls, %.0f bytes each)."):format(
          number(since.placement_bytes),
          since.hits,
          since.placement_bytes / math.max(since.hits, 1)
        )
    elseif since.hits == 0 then
      verdict = "NOT HITTING: no scroll after the mark landed inside a resident region. Scroll a "
        .. "smaller distance -- a region is only about twice the viewport, so it holds one "
        .. "viewport of travel in total."
    else
      verdict = ("PARTIAL: %d hits but %s upload bytes since the mark. Something refilled. Check "):format(
        since.hits,
        number(since.upload_bytes)
      ) .. "`stale_fills` and `evictions` in the table above."
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = verdict

  -- The honest boundary, reported whether or not it flatters the result. A
  -- single never-repeated pass down a document costs roughly what it always did;
  -- the win is in re-reading, and a run that only went one way cannot show it.
  if a.ui_bytes > 0 then
    local delta = (b.ui_bytes - a.ui_bytes) / a.ui_bytes * 100
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("Whole-phase traffic %+.0f%% (%s -> %s bytes)."):format(
      delta,
      number(a.ui_bytes),
      number(b.ui_bytes)
    )
    if delta > 0 then
      lines[#lines + 1] = "  Higher is expected on a one-pass traversal: a region is a bigger single "
        .. "payload than the settle frame it replaces, and nothing was re-read to earn it back."
    end
  end
  if b.suppressed > 0 then
    lines[#lines + 1] = ("%d moving frames were held off the wire while a region drained -- the "):format(b.suppressed)
      .. "anti-backlog rule. Compare `coalesced` between arms: both mean a scroll that sent nothing."
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(buf, "md-viewer://resident-ab")
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_height(0, math.min(#lines + 1, 30))
  print("md-viewer: resident A/B complete, configuration restored.")
end

local function announce(phase, ok, reason)
  local gate = ok and "" or (" [GATE REFUSED: %s]"):format(tostring(reason))
  print(
    ("md-viewer resident A/B %s -- %s (%s).%s Scroll the protocol, then run :ResidentAB"):format(
      phase.key == "baseline" and "1/2" or "2/2",
      phase.label,
      phase.note,
      gate
    )
  )
end

local function advance()
  local current = session()
  if step == 0 then
    saved = vim.deepcopy(config.get())
    -- The baseline arm is *supposed* to be refused, so its gate answer is not a
    -- warning to print; only the treatment arm's is.
    local _, reason = apply_pan(current, PHASES[1].pan)
    reset_counters(current)
    step = 1
    announce(PHASES[1], true, reason)
  elseif step == 1 then
    results.baseline = snapshot(current)
    local ok, reason = apply_pan(current, PHASES[2].pan)
    reset_counters(current)
    step = 2
    announce(PHASES[2], ok, reason)
  else
    results.treatment = snapshot(current)
    restore()
    step = 0
    report()
  end
end

vim.api.nvim_create_user_command("ResidentAB", function()
  local ok, err = pcall(advance)
  if not ok then
    restore()
    step = 0
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
end, { desc = "md-viewer: step through the resident-region A/B" })

---Take the "a region is now resident" reading, so the report can separate the
---one fill that paid for it from the scrolling that spends it. Without this the
---phase total mixes the two and the claim being tested -- that the *scrolling*
---is free -- cannot be read out of it at all.
vim.api.nvim_create_user_command("ResidentABMark", function()
  local ok, err = pcall(function()
    local current = session()
    mark_base = snapshot(current)
    print(
      ("md-viewer: marked at %d region(s), %s upload bytes so far. Now scroll inside the region, then :ResidentAB."):format(
        mark_base.regions,
        number(mark_base.upload_bytes)
      )
    )
  end)
  if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
end, { desc = "md-viewer: mark the point a region became resident" })

vim.api.nvim_create_user_command("ResidentABCancel", function()
  restore()
  step = 0
  results = {}
  mark_base = nil
  print("md-viewer: resident A/B cancelled, configuration restored.")
end, { desc = "md-viewer: abandon the resident-region A/B and restore configuration" })

-- Sourcing the file arms phase 1, so the whole run is one :runtime and two
-- :ResidentAB calls rather than three of anything.
local armed_ok, armed_err = pcall(advance)
if not armed_ok then vim.notify(tostring(armed_err), vim.log.levels.ERROR) end
