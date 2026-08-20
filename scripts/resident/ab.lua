-- Resident-slice A/B, driven by hand in a real session.
--
-- What it proves: whether scrolling back through content the terminal is
-- already holding sends **no new pixels**, measured as total bytes handed to
-- `nvim_ui_send` rather than as PNG bytes alone. That distinction is the whole
-- reason this file exists rather than a column in scripts/scroll-scale/ab.lua:
-- "the payload fell to zero" and "the traffic fell to zero" are different
-- claims, and docs/local-render-design.md records this project being wrong
-- about exactly that difference once already.
--
-- What changed under it: the document is now covered by a *fixed grid of
-- slices* rather than by one region planned around wherever the reader stopped.
-- That moves what this harness is asking. The old question was "is scrolling
-- inside the region free", and the answer was yes while the honest whole-phase
-- number went *up*, because crossing the region's moving edge evicted and
-- refilled it -- 14 fills and 13 evictions in 141 seconds on the real link, for
-- 38% more traffic than sending a frame every time. The new question is whether
-- a **second pass over the same ground** is free, which is the one a grid can
-- answer and a bounded region could not.
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
--     ...scroll the same way; :ResidentABMark after the first pass...
--     :ResidentAB                          -- prints the report
--
-- The protocol, run identically in both phases:
--
--   1. Wait for the first frame.
--   2. Walk forward through four or five screens, pausing at each so the settle
--      fires and the slice under you fills. In phase 2, `:MdViewerDebug`'s
--      `resident` block should show `slices_resident` climbing by one per stop
--      and `evictions` staying at 0.
--   3. In phase 2, run `:ResidentABMark` here. Everything before the mark is the
--      warm-up this feature charges for; everything after is what it buys.
--   4. Walk back through exactly the same screens, then forward again.
--   5. THE CLAIM: upload bytes since the mark are 0, fills since the mark are 0,
--      and hits are however many times you scrolled.
--   6. Park on a boundary -- a position that shows the bottom of one screen and
--      the top of the next. `straddles` should climb; `straddle_misses` should
--      not, once both slices either side are held.
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
  { key = "treatment", label = "treatment", pan = "on", note = "resident slices -- a scroll may be a crop" },
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
---Deliberately does *not* touch the slices themselves in the treatment arm: what
---is being measured is pixels the terminal is holding, and giving them back
---between the counters and the scrolling would measure a cold start twice.
---
---The names are listed rather than "every numeric field", so a counter that is
---added and not listed here shows up as a phase total rather than silently
---carrying the previous phase's value into this one.
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
    "prefetches",
    "stale_fills",
    "abandoned_fills",
    "evictions",
    "straddles",
    "straddle_misses",
    "blocked_by_find",
    "blocked_by_selection",
    "frames_suppressed_by_hold",
    "superseded_by_pan",
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
  local resident = require("md-viewer.resident")
  local slices = resident.slice_records(live)
  local decoded = 0
  for _, slice in ipairs(slices) do
    decoded = decoded + resident.decoded_bytes(slice)
  end
  local grid = live.grid
  local link_rate, link_source = resident.link_rate(config.get().render.ssh_link_bytes_per_sec, live.wire_bytes_per_ms)
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
    prefetches = live.prefetches or 0,
    stale_fills = live.stale_fills,
    abandoned_fills = live.abandoned_fills,
    evictions = live.evictions,
    straddles = live.straddles or 0,
    straddle_misses = live.straddle_misses or 0,
    suppressed = live.frames_suppressed_by_hold,
    blocked_find = live.blocked_by_find,
    blocked_selection = live.blocked_by_selection,
    hold_ms = live.upload_hold_ms,
    -- The rate the holds in this phase were computed from, and whether anybody
    -- actually knows it. Reported as a pair because the number alone is not a
    -- fact: an estimate comes from timing a write to `nvim_ui_send`, and on a
    -- healthy tunnel that write returns before a byte crosses the link. This
    -- report used to print such a number under "measured link" -- 139,058 B/ms
    -- for a link doing 800.
    link_rate = link_rate,
    link_source = link_source,
    -- Below 1 means the renderer refused a slice at its full height and the
    -- whole grid was regenerated shorter.
    slice_scale = live.slice_scale,
    -- How much of the document is held, against how much there is. The pair is
    -- the point: `4 / 20` says the warm-up is a fifth done, and a phase that
    -- ends there has not yet bought anything a second pass could show.
    resident_slices = #slices,
    grid_slices = grid and grid.count or nil,
    slice_h = grid and grid.slice_h or nil,
    decoded_mb = decoded / 1048576,
    ceiling_mb = live.memory_px * resident.BYTES_PER_RESIDENT_PX / 1048576,
    -- Why no grid could be built, when there is none. Replaces the bounded
    -- region's `plan_refusal`, and means something narrower: the grid is only
    -- refused for a document that cannot scroll, a geometry with no room for a
    -- viewport plus its overlap, or a ceiling below one slice.
    grid_refusal = live.grid_refusal,
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

---What a phase's holds were computed from, said in a way that cannot be read as
---a measurement of the link.
---
---There is no measurement to report. `nvim_ui_send` hands bytes to a pty and
---returns when the kernel accepts them, which on a link with buffer to spare is
---before any of them have crossed it; a terminal can be asked to acknowledge an
---upload, but its reply arrives on Neovim's own stdin and a plugin cannot read
---it. So the only honest figures are the one the operator states in
---`render.ssh_link_bytes_per_sec` and a lower bound inferred from writes that
---did block -- and "none of the above", which is the common case and now says so
---rather than printing whatever the memory bus managed.
local function link_rate_cell(phase)
  if phase.link_source == "configured" then
    return ("%.0f B/ms stated"):format(phase.link_rate)
  elseif phase.link_source == "estimated" then
    return ("%.0f B/ms inferred"):format(phase.link_rate)
  end
  return "not measurable"
end

local function report()
  local a, b = results.baseline, results.treatment
  local lines = {
    "md-viewer resident-slice A/B",
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
    row("slice uploads", number(a.upload_bytes), number(b.upload_bytes)),
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
    -- A viewport spanning two slices, drawn as two bands in one write, against
    -- one that had to fall back to a captured frame because only one of the two
    -- was held. A grid's boundaries never move, so a reader can park on one --
    -- which is exactly what the bounded region could not survive.
    row(
      "boundaries: drawn / missed",
      ("%d / %d"):format(a.straddles, a.straddle_misses),
      ("%d / %d"):format(b.straddles, b.straddle_misses)
    ),
    row(
      "fills (stale / abandoned)",
      ("%d (%d/%d)"):format(a.fills, a.stale_fills, a.abandoned_fills),
      ("%d (%d/%d)"):format(b.fills, b.stale_fills, b.abandoned_fills)
    ),
    row("  of those, prefetched", number(a.prefetches), number(b.prefetches)),
    -- The number the whole rebuild was for. Under the bounded region this
    -- climbed with every boundary crossing; under a grid, a document inside the
    -- ceiling should never evict at all.
    row("evictions", number(a.evictions), number(b.evictions)),
    row(
      "slices held / in grid",
      ("%d / %s"):format(a.resident_slices, a.grid_slices and tostring(a.grid_slices) or "--"),
      ("%d / %s"):format(b.resident_slices, b.grid_slices and tostring(b.grid_slices) or "--")
    ),
    row(
      "  decoded / ceiling",
      ("%.0f / %.0f MB"):format(a.decoded_mb, a.ceiling_mb),
      ("%.0f / %.0f MB"):format(b.decoded_mb, b.ceiling_mb)
    ),
    "",
    row("frames held off the wire", number(a.suppressed), number(b.suppressed)),
    row(
      "  last hold",
      a.hold_ms and ("%d ms"):format(a.hold_ms) or "--",
      b.hold_ms and ("%d ms"):format(b.hold_ms) or "--"
    ),
    row("  link rate used", link_rate_cell(a), link_rate_cell(b)),
    row("coalesced (never sent)", number(a.coalesced), number(b.coalesced)),
    row(
      "pans refused: find/sel",
      ("%d / %d"):format(a.blocked_find, a.blocked_selection),
      ("%d / %d"):format(b.blocked_find, b.blocked_selection)
    ),
    row("slice height scale", ("%.2f"):format(a.slice_scale or 1), ("%.2f"):format(b.slice_scale or 1)),
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
    -- below is a place a settle can decline to ask for a slice while nothing has
    -- failed and nothing has been counted.
    verdict = ("NO SLICE WAS EVER FILLED, though %d settle frames were taken -- so the settles ran "):format(
      b.retina_frames
    ) .. "and none of them asked for a slice. In :MdViewerDebug's `resident` block, in order: " .. ("`grid_refusal` (no grid fits this geometry%s), "):format(
      b.grid_refusal and (": " .. b.grid_refusal) or ""
    ) .. "`fallback_reason` (it gave up earlier in the session), " .. "then check whether a drag is still registered -- a click leaves state behind that a " .. "settle will not fill through. A slice already held is also never asked for again, so " .. "if `slices_resident` is above 0 this arm simply never left the ground it had."
  elseif not mark_base then
    verdict = ("NO MARK TAKEN: walk forward a few screens until `slices_resident` reaches 3 or 4 "):format()
      .. "(it is "
      .. tostring(b.resident_slices)
      .. " now), run :ResidentABMark, and only then walk back over "
      .. "the same ground. Without the mark the report cannot separate the warm-up this feature "
      .. "charges for from the re-reading it buys, and those are the two halves of the claim."
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
    -- "fewer" -- none. Under a grid this is a claim about a *second pass*, which
    -- is what the bounded region could not make: its edges moved with the
    -- reader, so returning to ground already paid for refilled it.
    if since.upload_bytes == 0 and since.hits > 0 then
      lines[#lines + 1] = ("%d scrolls over ground already paid for cost %s bytes of placement and no pixels."):format(
        since.hits,
        number(since.placement_bytes)
      )
      verdict = ("WORKING: re-reading resident content sent zero new pixel payload "):format()
        .. ("(%s placement bytes for %d scrolls, %.0f bytes each), across %d boundaries drawn as "):format(
          number(since.placement_bytes),
          since.hits,
          since.placement_bytes / math.max(since.hits, 1),
          since.straddles
        )
        .. ("two bands, with %d evictions."):format(since.evictions)
      if since.evictions > 0 then
        verdict = verdict
          .. " Evictions above zero after the mark means this document is larger than "
          .. ("image.resident_memory_mb (%.0f MB) and the window is sliding -- the second pass "):format(b.ceiling_mb)
          .. "was free only because you stayed inside what survived."
      end
    elseif since.hits == 0 then
      verdict = "NOT HITTING: no scroll after the mark landed on a slice this session holds. Walk "
        .. "back over ground you covered *before* the mark -- the claim is about re-reading, and "
        .. "new ground costs a slice however good the cache is."
    elseif since.straddle_misses > 0 and since.fills > 0 then
      verdict = ("WARMING UP: %d hits and %d fills since the mark, %d of them at a boundary with only "):format(
        since.hits,
        since.fills,
        since.straddle_misses
      ) .. "one of its two slices held. That is the grid still filling in, not a defect -- mark again " .. "once `slices_resident` has stopped climbing and repeat the walk."
    else
      verdict = ("PARTIAL: %d hits but %s upload bytes since the mark. Something refilled. `evictions` "):format(
        since.hits,
        number(since.upload_bytes)
      ) .. ("is %d and `stale_fills` %d in the table above; evictions mean the document is over the "):format(
        since.evictions,
        since.stale_fills
      ) .. "ceiling, stale fills mean something invalidated the grid mid-capture."
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
      lines[#lines + 1] = "  Higher is expected on a one-pass traversal: a slice is a bigger single "
        .. "payload than the settle frame it replaces, and nothing was re-read to earn it back. "
        .. "The whole-phase number only turns over once a reader covers ground twice."
    end
    -- The specific failure the grid replaced, named so a run that still shows it
    -- is not read as ordinary warm-up. Under the bounded region this was the
    -- result: 14 fills and 13 evictions in 141 seconds, +38% traffic.
    if b.evictions > 0 and b.fills > b.resident_slices then
      lines[#lines + 1] = ("  %d fills for %d slices held, with %d evictions -- this document is over "):format(
        b.fills,
        b.resident_slices,
        b.evictions
      ) .. ("image.resident_memory_mb (%.0f MB) and slices are being uploaded, evicted and uploaded "):format(
        b.ceiling_mb
      ) .. "again. That is the churn the grid exists to remove; raise the ceiling or test a shorter " .. "document."
    end
  end
  if b.suppressed > 0 then
    lines[#lines + 1] = ("%d moving frames were held off the wire while a slice drained -- the "):format(b.suppressed)
      .. "anti-backlog rule. Compare `coalesced` between arms: both mean a scroll that sent nothing."
  elseif b.link_source ~= "configured" then
    -- The one reading this report cannot make on its own, and the one it got
    -- wrong: zero frames held is either "nothing needed holding" or "the hold
    -- never ran", and without a stated rate it is the second.
    lines[#lines + 1] = "No moving frame was held off the wire, and this run cannot tell you whether that is "
      .. "because none needed to be. The hold is computed from a link rate, nothing here can measure one, and "
      .. "none was configured -- so it fell back to the settle delay. Set render.ssh_link_bytes_per_sec (800000 "
      .. "for the SSM tunnel) and run again to measure the anti-backlog rule rather than its absence."
  end
  if b.grid_slices and b.resident_slices < b.grid_slices then
    lines[#lines + 1] = ("%d of %d slices are held (%.0f of %.0f MB). The rest of the document has not "):format(
      b.resident_slices,
      b.grid_slices,
      b.decoded_mb,
      b.ceiling_mb
    ) .. "been visited or prefetched yet, so this run measures the part that has."
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

---Take the "this much of the document is now resident" reading, so the report
---can separate the warm-up this feature charges for from the re-reading it buys.
---Without it the phase total mixes the two, and the claim being tested -- that
---the *second pass* is free -- cannot be read out of it at all.
vim.api.nvim_create_user_command("ResidentABMark", function()
  local ok, err = pcall(function()
    local current = session()
    mark_base = snapshot(current)
    print(
      ("md-viewer: marked at %d of %s slices (%.0f MB), %s upload bytes so far. Now walk back over the "):format(
        mark_base.resident_slices,
        mark_base.grid_slices and tostring(mark_base.grid_slices) or "?",
        mark_base.decoded_mb,
        number(mark_base.upload_bytes)
      ) .. "same ground, then :ResidentAB."
    )
  end)
  if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
end, { desc = "md-viewer: mark the point the warm-up is done and re-reading begins" })

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
