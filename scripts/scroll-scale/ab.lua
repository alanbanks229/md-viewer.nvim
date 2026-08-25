-- Scroll-scale A/B, driven by hand in a real session.
--
-- What it proves: whether `render.scroll_scale` actually shrinks the moving
-- frame on *this* host, and by how much. That cannot be answered headlessly --
-- the numbers only exist once a human has scrolled a real preview -- and it
-- cannot be answered on the machine the plugin was written on, because the
-- thing being measured is a link that machine does not have.
--
-- What it needs: a preview open (`:MdViewerToggle`) on a document long enough
-- to scroll for a few seconds. The plugin's own README is the reference
-- document every measurement in docs/local-render-design.md was taken against,
-- so use that if you want numbers comparable to the ones recorded there.
--
-- How to run it, from inside Neovim:
--
--     :runtime scripts/scroll-scale/ab.lua     -- arms phase 1
--     ...wheel-scroll the whole document...
--     :ScrollAB                                -- arms phase 2
--     ...wheel-scroll the whole document again...
--     :ScrollAB                                -- prints the report
--
-- The original configuration is restored at the end, and by :ScrollABCancel if
-- you stop partway. Nothing is written to disk.

local config = require("md-viewer.config")
local state = require("md-viewer.state")

-- Bytes on the wire are base64, so 4/3 of the PNG. The rate is the one thing
-- here that cannot be measured from inside Neovim -- nvim_ui_send appends to
-- Neovim's own UI queue and returns, so a Lua caller sees no back-pressure from
-- the link under any circumstances -- so it is taken from configuration, or
-- from the SSM tunnel's documented 0.80 MB/s when nothing is configured.
-- Measure yours with scripts/ssh-link-speed.sh, from the shell.
local BYTES_PER_SECOND = config.get().render.ssh_link_bytes_per_sec or 800000
local function wire_ms(png_bytes)
  if not png_bytes then return nil end
  return (png_bytes * 4 / 3) / BYTES_PER_SECOND * 1000
end

local PHASES = {
  { label = "baseline", scale = 1.0, note = "full size -- what the plugin did before this change" },
  { label = "treatment", scale = 0.5, note = "half size -- the new SSH default" },
}

local step = 0
local saved
local results = {}

local function session()
  local found = state.visible_in_tab()
  if not found then error("md-viewer: no preview is open in this tab. Run :MdViewerToggle first.", 0) end
  return found
end

---Clear the per-scroll counters so each phase reports only its own frames.
---These are diagnostics rather than state, so blanking them changes nothing
---about what is on screen.
local phase_started = 0
local function reset_counters(current)
  current.fast_png_bytes = nil
  current.fast_capture_ms = nil
  current.fast_image_update_ms = nil
  current.retina_png_bytes = nil
  current.retina_capture_ms = nil
  current.coalesced_scroll_events = 0
  current.fast_frame_count = 0
  current.fast_bytes_total = 0
  current.retina_frame_count = 0
  current.retina_bytes_total = 0
  current.fast_interval_min_ms = nil
  current.fast_interval_sum_ms = nil
  current.fast_interval_count = nil
  current.fast_last_ns = nil
  phase_started = vim.uv.hrtime()
end

local function apply_scale(scale)
  local next_config = vim.deepcopy(config.get())
  next_config.render.scroll_scale = scale
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
    fast_png_bytes = current.fast_png_bytes,
    retina_png_bytes = current.retina_png_bytes,
    coalesced = current.coalesced_scroll_events or 0,
    encoder = current.last_capture_encoder,
    scroll_scale = current.scroll_scale,
    settle_ms = current.scroll_settle_ms,
    -- Frames actually captured and sent, and the seconds they were sent over.
    -- The duration is what makes the two phases comparable at all: a hand-driven
    -- scroll is never the same length twice, so counts alone say nothing and a
    -- rate says everything.
    fast_frames = current.fast_frame_count or 0,
    fast_total = current.fast_bytes_total or 0,
    retina_frames = current.retina_frame_count or 0,
    retina_total = current.retina_bytes_total or 0,
    seconds = (vim.uv.hrtime() - phase_started) / 1e9,
    -- The pipeline's floor, and what is known to be in it. Everything not in
    -- capture or encode-and-send or transit is unaccounted, and a large
    -- unaccounted share is the finding -- it means the constraint is not any
    -- of the three things this change or its successor can move.
    interval_min = current.fast_interval_min_ms,
    capture_ms = current.fast_capture_ms,
    -- How long handing the frame to Neovim's UI queue took. Reported because it
    -- is part of the production floor, and deliberately NOT added to any
    -- estimate of what the frame cost the link: it is a queue insertion, and
    -- treating it as transmission is what produced link-rate estimates of
    -- 101,169 B/ms against a link doing 800.
    handoff_ms = current.fast_image_update_ms,
  }
end

local function ms(value)
  if not value then return "--" end
  return ("%d ms"):format(value)
end

---How much of the link's capacity a phase actually used: every byte it sent,
---as base64, over the seconds it took, against the 0.80 MB/s ceiling.
---
---This is the number that says whether transit is the constraint, and it is
---the one to trust. `interval_min` cannot say it, because `nvim_ui_send` is
---asynchronous: Lua hands a frame to the UI queue and returns, so frames are
---*produced* far faster than the wire *drains* them and the production floor
---says nothing about when a picture reaches the screen. Near 100% here means
---frames are queueing and the queue is the lag the reader sees.
local function saturation(phase)
  if not (phase.seconds and phase.seconds > 0) then return nil end
  local sent = (phase.fast_total + phase.retina_total) * 4 / 3
  return sent / phase.seconds / BYTES_PER_SECOND * 100
end

---Whether this phase produced frames faster than the link could carry them.
---An earlier version of this harness subtracted the parts of a frame from the
---interval and clamped the remainder at zero, which reported 0 ms of
---"unaccounted" time in exactly the case that matters -- a 51 ms interval
---carrying 62 ms of capture and 224 ms of transit is not accounted for, it is
---oversubscribed by a factor of five, and the clamp turned the finding into a
---row of zeroes.
---
---`handoff_ms` is deliberately absent from this sum. It measures a queue
---insertion, not transmission, and the two things that decide whether frames
---outrun the link are the capture that produces them and the wire that carries
---them.
local function overrun(phase)
  if not (phase.interval_min and phase.fast_png_bytes and phase.interval_min > 0) then return nil end
  local per_frame = (phase.capture_ms or 0) + wire_ms(phase.fast_png_bytes)
  return per_frame / phase.interval_min
end

local function number(value)
  if not value then return "--" end
  local formatted = tostring(math.floor(value))
  local separated = formatted:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return separated
end

local function report()
  local a, b = results.baseline, results.treatment
  local lines = {
    "md-viewer scroll A/B",
    "",
    ("%-26s %14s %14s"):format("", "baseline 1.0x", "treatment 0.5x"),
    ("%-26s %14s %14s"):format("fast_png_bytes", number(a.fast_png_bytes), number(b.fast_png_bytes)),
    ("%-26s %14s %14s"):format(
      "  transit @0.80MB/s",
      a.fast_png_bytes and ("%d ms"):format(wire_ms(a.fast_png_bytes)) or "--",
      b.fast_png_bytes and ("%d ms"):format(wire_ms(b.fast_png_bytes)) or "--"
    ),
    ("%-26s %14s %14s"):format(
      "moving frames delivered",
      ("%d in %.0fs"):format(a.fast_frames, a.seconds),
      ("%d in %.0fs"):format(b.fast_frames, b.seconds)
    ),
    -- The floor, not frames-over-wall-clock: a hand-driven scroll has pauses in
    -- it, and dividing by elapsed time charges the pipeline for a reader who
    -- stopped to look at something.
    ("%-26s %14s %14s"):format(
      "  delivered rate",
      ("%.1f/s"):format(a.fast_frames / math.max(a.seconds, 0.001)),
      ("%.1f/s"):format(b.fast_frames / math.max(b.seconds, 0.001))
    ),
    -- The headline. Everything else on this page is a component of it.
    ("%-26s %14s %14s"):format(
      "WIRE SATURATION",
      saturation(a) and ("%.0f%%"):format(saturation(a)) or "--",
      saturation(b) and ("%.0f%%"):format(saturation(b)) or "--"
    ),
    ("%-26s %14s %14s"):format("frame produced every", ms(a.interval_min), ms(b.interval_min)),
    ("%-26s %14s %14s"):format("  capture (VM Chromium)", ms(a.capture_ms), ms(b.capture_ms)),
    ("%-26s %14s %14s"):format("  hand to UI queue", ms(a.handoff_ms), ms(b.handoff_ms)),
    ("%-26s %14s %14s"):format(
      "  transit (async, queues)",
      ms(wire_ms(a.fast_png_bytes)),
      ms(wire_ms(b.fast_png_bytes))
    ),
    ("%-26s %14s %14s"):format(
      "  oversubscribed by",
      overrun(a) and ("%.1fx"):format(overrun(a)) or "--",
      overrun(b) and ("%.1fx"):format(overrun(b)) or "--"
    ),
    ("%-26s %14s %14s"):format("retina_png_bytes", number(a.retina_png_bytes), number(b.retina_png_bytes)),
    ("%-26s %14s %14s"):format("settle frames taken", number(a.retina_frames), number(b.retina_frames)),
    ("%-26s %14s %14s"):format(
      "total bytes sent",
      number(a.fast_total + a.retina_total),
      number(b.fast_total + b.retina_total)
    ),
    ("%-26s %14s %14s"):format("coalesced (never sent)", number(a.coalesced), number(b.coalesced)),
    ("%-26s %14s %14s"):format("capture_encoder", a.encoder or "--", b.encoder or "--"),
    ("%-26s %14s %14s"):format("scroll_scale", tostring(a.scroll_scale), tostring(b.scroll_scale)),
    "",
    -- Stated rather than tabulated: it is identical in both arms by
    -- construction, so a column for it would imply it was under test when this
    -- run says nothing about it at all.
    ("settle delay was %sms in both arms -- this A/B varies scroll_scale only."):format(tostring(a.settle_ms)),
    "",
  }

  local verdict
  if not (a.fast_png_bytes and b.fast_png_bytes) then
    verdict = "INCONCLUSIVE: no moving frame was captured in one of the phases. "
      .. "Scroll with the mouse wheel (not j/k) for a few seconds in each phase."
  elseif b.encoder ~= "cdp_fast_png" then
    verdict = ('INERT: capture_encoder is %q, not "cdp_fast_png". Playwright\'s own scale is a '):format(
      tostring(b.encoder)
    ) .. "two-value enum, so the numeric factor cannot apply on that path and this change does " .. "nothing on this host. Report it."
  else
    local ratio = a.fast_png_bytes / b.fast_png_bytes
    local before, after = wire_ms(a.fast_png_bytes), wire_ms(b.fast_png_bytes)
    lines[#lines + 1] = ("moving frame is %.2fx smaller: %d ms of transit instead of %d"):format(ratio, after, before)
    -- Deliberately a rate rather than a total. Multiplying the per-frame saving
    -- by coalesced_scroll_events looks like the obvious summary and is wrong by
    -- construction: a coalesced event is one that was superseded *before* it was
    -- captured, so no frame was ever produced for it and no bytes were ever sent.
    -- The saving is real per frame transmitted, and what a reader feels is how
    -- often the picture can be replaced -- which is what this says instead.
    lines[#lines + 1] = ("transit alone caps preview updates at %.1f/s, was %.1f/s"):format(1000 / after, 1000 / before)
    -- And do not expect total bytes to fall. Smaller frames mean *more* of them
    -- get through in the same time, so the wire stays about as busy; what
    -- changes is how much of the document that traffic actually shows you.
    lines[#lines + 1] = "(total bytes need not drop -- smaller frames mean more frames, not less traffic)"
    -- The question this harness now exists to answer. Fewer bytes only make
    -- scrolling smoother if bytes were what the loop was waiting on; if most of
    -- a frame interval is unaccounted, they were not, and neither this option
    -- nor moving rasterization off the far end will change how it feels.
    local before_sat, after_sat = saturation(a), saturation(b)
    if before_sat and after_sat then
      lines[#lines + 1] = ("wire saturation %.0f%% -> %.0f%%; delivered rate %.1f/s -> %.1f/s"):format(
        before_sat,
        after_sat,
        a.fast_frames / math.max(a.seconds, 0.001),
        b.fast_frames / math.max(b.seconds, 0.001)
      )
      if before_sat >= 70 then
        lines[#lines + 1] = "  -> transit WAS the constraint: the baseline had the link near capacity."
      end
      if after_sat < 55 and b.retina_frames > 0 then
        local settle_share = b.retina_total * 4 / 3 / BYTES_PER_SECOND / b.seconds * 100
        lines[#lines + 1] = ("  -> the settle frame is now the biggest single item: %d of them, %.0f%% of the link."):format(
          b.retina_frames,
          settle_share
        )
      end
    end
    lines[#lines + 1] = ""
    if ratio >= 2.0 and before_sat and before_sat < 50 then
      -- Both true at once, and reporting only the first would be the flattering
      -- half: the option did what it claims to bytes, but a baseline that never
      -- filled the link was never waiting on bytes, so nothing about how it
      -- feels can be concluded from this run.
      verdict = ("BYTES REDUCED %.2fx as designed, but the baseline used only %.0f%% of the link -- "):format(
        ratio,
        before_sat
      ) .. "it was not transit-bound, so scroll harder or for longer and run it again."
    elseif ratio >= 2.0 then
      verdict = "WORKING as designed (expected about 2.6x)."
    elseif ratio > 1.2 then
      verdict = ("PARTIAL: %.2fx, below the ~2.6x expected. Report the table."):format(ratio)
    else
      verdict = ("NOT WORKING: %.2fx. The factor is not reaching the capture. Report the table."):format(ratio)
    end
  end
  lines[#lines + 1] = verdict
  if a.retina_png_bytes and b.retina_png_bytes and a.retina_png_bytes ~= b.retina_png_bytes then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "NOTE: retina_png_bytes differs between phases. The settle frame must not be "
      .. "scaled; if the difference is large, report it."
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(buf, "md-viewer://scroll-ab")
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_height(0, math.min(#lines + 1, 20))
  print("md-viewer: A/B complete, configuration restored.")
end

local function advance()
  local current = session()
  if step == 0 then
    saved = vim.deepcopy(config.get())
    apply_scale(PHASES[1].scale)
    reset_counters(current)
    step = 1
    print(
      ("md-viewer A/B 1/2 -- %s (%s). Wheel-scroll the whole document, then run :ScrollAB"):format(
        PHASES[1].label,
        PHASES[1].note
      )
    )
  elseif step == 1 then
    results.baseline = collect(current)
    apply_scale(PHASES[2].scale)
    reset_counters(current)
    step = 2
    print(
      ("md-viewer A/B 2/2 -- %s (%s). Wheel-scroll the same way, then run :ScrollAB"):format(
        PHASES[2].label,
        PHASES[2].note
      )
    )
  else
    results.treatment = collect(current)
    restore()
    step = 0
    report()
  end
end

vim.api.nvim_create_user_command("ScrollAB", function()
  local ok, err = pcall(advance)
  if not ok then
    restore()
    step = 0
    vim.notify(tostring(err), vim.log.levels.ERROR)
  end
end, { desc = "md-viewer: step through the scroll-scale A/B" })

vim.api.nvim_create_user_command("ScrollABCancel", function()
  restore()
  step = 0
  results = {}
  print("md-viewer: A/B cancelled, configuration restored.")
end, { desc = "md-viewer: abandon the scroll-scale A/B and restore configuration" })

-- Sourcing the file arms phase 1, so the whole run is one :runtime and two
-- :ScrollAB calls rather than three of anything.
local armed_ok, armed_err = pcall(advance)
if not armed_ok then vim.notify(tostring(armed_err), vim.log.levels.ERROR) end
