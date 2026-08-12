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

-- Bytes on the wire are base64, so 4/3 of the PNG, and the SSM tunnel's
-- measured ceiling is 0.80 MB/s. That makes the transit cost of a frame
-- pngBytes/600 milliseconds. Stated here rather than inline because it is the
-- only reason any of this matters.
local BYTES_PER_SECOND = 800000
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
  if not found then
    error("md-viewer: no preview is open in this tab. Run :MdViewerToggle first.", 0)
  end
  return found
end

---Clear the per-scroll counters so each phase reports only its own frames.
---These are diagnostics rather than state, so blanking them changes nothing
---about what is on screen.
local function reset_counters(current)
  current.fast_png_bytes = nil
  current.fast_capture_ms = nil
  current.fast_image_update_ms = nil
  current.retina_png_bytes = nil
  current.retina_capture_ms = nil
  current.coalesced_scroll_events = 0
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
    scroll_scale_source = current.scroll_scale_source,
  }
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
    ("%-26s %14s %14s"):format("retina_png_bytes", number(a.retina_png_bytes), number(b.retina_png_bytes)),
    ("%-26s %14s %14s"):format("coalesced_scroll_events", number(a.coalesced), number(b.coalesced)),
    ("%-26s %14s %14s"):format("capture_encoder", a.encoder or "--", b.encoder or "--"),
    ("%-26s %14s %14s"):format("scroll_scale", tostring(a.scroll_scale), tostring(b.scroll_scale)),
    "",
  }

  local verdict
  if not (a.fast_png_bytes and b.fast_png_bytes) then
    verdict = "INCONCLUSIVE: no moving frame was captured in one of the phases. "
      .. "Scroll with the mouse wheel (not j/k) for a few seconds in each phase."
  elseif b.encoder ~= "cdp_fast_png" then
    verdict = ("INERT: capture_encoder is %q, not \"cdp_fast_png\". Playwright's own scale is a "):format(
      tostring(b.encoder)
    ) .. "two-value enum, so the numeric factor cannot apply on that path and this change does "
      .. "nothing on this host. Report this -- it also affects the client-render design."
  else
    local ratio = a.fast_png_bytes / b.fast_png_bytes
    local before, after = wire_ms(a.fast_png_bytes), wire_ms(b.fast_png_bytes)
    lines[#lines + 1] = ("moving frame is %.2fx smaller: %d ms of transit instead of %d"):format(
      ratio,
      after,
      before
    )
    -- Deliberately a rate rather than a total. Multiplying the per-frame saving
    -- by coalesced_scroll_events looks like the obvious summary and is wrong by
    -- construction: a coalesced event is one that was superseded *before* it was
    -- captured, so no frame was ever produced for it and no bytes were ever sent.
    -- The saving is real per frame transmitted, and what a reader feels is how
    -- often the picture can be replaced -- which is what this says instead.
    lines[#lines + 1] = ("transit alone caps preview updates at %.1f/s, was %.1f/s"):format(
      1000 / after,
      1000 / before
    )
    lines[#lines + 1] = ""
    if ratio >= 2.0 then
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
