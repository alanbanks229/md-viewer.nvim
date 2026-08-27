local backends = require("md-viewer.backends")
local cellpixels = require("md-viewer.cellpixels")
local config = require("md-viewer.config")
local coordinates = require("md-viewer.coordinates")
local linkrate = require("md-viewer.linkrate")
local localrender = require("md-viewer.localrender")
local marker_backend = require("md-viewer.backends.kitty_marker")
local process = require("md-viewer.process")
local security = require("md-viewer.security")
local state = require("md-viewer.state")
local terminal = require("md-viewer.terminal")

local M = {}

local function root()
  local source = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function command(args)
  local result = vim.system(args, { text = true }):wait()
  return result.code == 0 and vim.trim(result.stdout or "") or nil
end

-- Best-effort, synchronous estimate used only when the renderer subprocess
-- has not been queried yet (the :checkhealth path cannot await it). The
-- renderer's own discovery (renderer/src/browser-discovery.js, driven by
-- process.request("health", ...)) is the authoritative, cross-platform
-- answer and is preferred whenever it is available.
local function chrome_path_estimate()
  local configured = config.get().browser.executable_path
  if configured then return vim.uv.fs_stat(configured) and configured or nil end
  local candidates = {
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/opt/homebrew/bin/google-chrome",
    "/opt/homebrew/bin/chromium",
    "/usr/local/bin/google-chrome",
    "/usr/local/bin/chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  }
  for _, path in ipairs(candidates) do
    if vim.uv.fs_stat(path) then return path end
  end
  for _, name in ipairs({
    "google-chrome",
    "google-chrome-stable",
    "chromium",
    "chromium-browser",
    "microsoft-edge",
    "microsoft-edge-stable",
  }) do
    local found = vim.fn.exepath(name)
    if found ~= "" then return found end
  end
  return nil
end

local function temp_writable()
  local path = vim.fn.tempname()
  local fd = vim.uv.fs_open(path, "w", 384)
  if not fd then return false end
  vim.uv.fs_close(fd)
  vim.uv.fs_unlink(path)
  return true
end

local function file_backed(buf)
  return buf
    and buf > 0
    and vim.api.nvim_buf_is_valid(buf)
    and vim.bo[buf].buftype == ""
    and vim.api.nvim_buf_get_name(buf) ~= ""
end

---The buffer this report should describe.
---
---Not simply the current one: both `:MdViewerHealth` and `:checkhealth` create
---and enter their own scratch buffer *before* collecting, so "the current
---buffer" is the report itself, and every document-relative answer in here
---would describe that instead of any document. Prefer a live preview's source,
---then a real file, then the alternate buffer the report displaced.
local function document_buf()
  for _, session in pairs(state.all()) do
    if not session.closed and file_backed(session.source_buf) then return session.source_buf end
  end
  local current = vim.api.nvim_get_current_buf()
  if file_backed(current) then return current end
  local alternate = vim.fn.bufnr("#")
  if file_backed(alternate) then return alternate end
  return current
end

---Non-empty environment variable, or nil. `vim.env` yields nil when unset, but
---an exported-and-emptied variable is just as absent for these purposes.
local function env_value(name)
  local value = vim.env[name]
  if value == nil or value == "" then return nil end
  return value
end

local function terminal_program_label()
  local direct = env_value("TERM_PROGRAM")
  if direct then return direct end
  local forwarded = env_value("LC_TERMINAL")
  if forwarded then return ("%s (via LC_TERMINAL)"):format(forwarded) end
  return "unknown"
end

---iTerm2's version, from whichever variable reached this session. The version
---is load-bearing -- Kitty graphics support starts at iTerm2 3.5 -- so an SSH
---session reporting "not detected" while LC_TERMINAL_VERSION sits in the
---environment hides the one number a reader needs to check.
local function iterm2_version_label()
  if env_value("TERM_PROGRAM") == "iTerm.app" then return env_value("TERM_PROGRAM_VERSION") or "undetectable" end
  if env_value("LC_TERMINAL") == "iTerm2" then return env_value("LC_TERMINAL_VERSION") or "undetectable" end
  return "not detected"
end

function M.collect(renderer_result, renderer_error)
  local cfg = config.get()
  local backend = backends.health()
  local sec = security.summary(cfg, document_buf())
  local version = vim.version()
  local capability = terminal.capability(cfg.terminal)
  local discovered_executable = renderer_result and renderer_result.executable
  local _, link_tier, link_detail = linkrate.resolve()
  local local_status = localrender.status()
  local marker_stats = marker_backend.stats()
  return {
    neovim = ("%d.%d.%d"):format(version.major, version.minor, version.patch),
    vim_ui_img = type(vim.ui and vim.ui.img) == "table",
    tui_attached = #vim.api.nvim_list_uis() > 0,
    -- TERM_PROGRAM does not survive SSH but LC_TERMINAL does, and over SSH the
    -- latter is what identified the terminal -- so report whichever actually
    -- exists. Printing "unknown" next to a correctly-identified iTerm2 profile
    -- reads as a contradiction and sends the reader looking for a fault.
    terminal_program = terminal_program_label(),
    iterm2_version = iterm2_version_label(),
    platform = capability.platform,
    multiplexer = capability.multiplexer,
    -- Named because it changes which evidence is even reachable: SSH forwards
    -- LC_* and almost nothing else, so TERM_PROGRAM-based identification is
    -- unavailable by construction rather than merely absent.
    ssh = capability.ssh and ("yes (%s)"):format(capability.ssh_evidence) or "no",
    -- How fast this link carries bytes, and which tier answered. Deliberately
    -- says nothing about *how* the machine was identified: the cache key is a
    -- hash precisely because this report is meant to be pasted into public
    -- issues, and the material behind it is two IP addresses.
    link_rate = linkrate.describe(),
    link_rate_tier = link_tier,
    link_rate_spread = link_detail and link_detail.spread or nil,
    terminal_profile = capability.profile_id .. " (" .. capability.label .. ")",
    terminal_profile_evidence = #capability.evidence > 0 and table.concat(capability.evidence, "; ") or "none",
    graphics_confidence = capability.graphics,
    graphics_decision_reason = capability.reason,
    graphics_validation = capability.validation,
    graphics_caveats = capability.caveats,
    kitty_graphics_probe_succeeded = backend.kitty_raw.probe_succeeded,
    vim_ui_img_render_succeeded = backend.nvim_img.render_succeeded or false,
    selected_backend = backend.selected,
    backend_decision = backend.decision,
    raw_graphics_zindex = backend.kitty_raw.zindex,
    raw_graphics_zindex_source = backend.kitty_raw.zindex_source,
    -- Whether a selection paints its highlight as overlay rectangles (a few
    -- hundred bytes per frame) or by re-photographing the page, and why.
    raw_graphics_overlay_supported = backend.kitty_raw.overlay_supported,
    raw_graphics_overlay_reason = backend.kitty_raw.overlay_reason,
    -- The overlay is on *against* the active profile's own judgement. That is a
    -- supported thing to do -- it is how a terminal gets qualified in the first
    -- place -- but it is also how a terminal that cannot do this degrades
    -- badly rather than gracefully, and until now it did so in silence.
    raw_graphics_overlay_forced = backend.kitty_raw.overlay_supported == true and capability.selection_overlay ~= true,
    -- The rest of the layer stack, reported beside the base because the three
    -- numbers together are the diagnostic: they must be distinct and ascending.
    -- Two equal numbers anywhere mean those layers are ordered by image id
    -- instead, and whichever is meant to be on top disappears under the base as
    -- soon as a full frame is re-uploaded.
    raw_graphics_animation_zindex = backend.kitty_raw.animation_zindex,
    raw_graphics_animation_supported = backend.kitty_raw.animation_supported,
    raw_graphics_animation_reason = backend.kitty_raw.animation_reason,
    raw_graphics_animation_mode = backend.kitty_raw.animation_mode,
    raw_graphics_animation_native = backend.kitty_raw.animation_native_supported,
    raw_graphics_animation_native_reason = backend.kitty_raw.animation_native_reason,
    raw_graphics_animation_images = backend.kitty_raw.animation_images,
    raw_graphics_overlay_zindex = backend.kitty_raw.overlay_zindex or "none (interaction.selection_overlay=off)",
    -- What a pixel is worth on screen. Overlay rectangles are sized in pixels,
    -- so "unmeasured" here is the whole reason the overlay is off.
    raw_graphics_cell_pixels = backend.kitty_raw.cell_pixels,
    raw_graphics_double_buffer = backend.kitty_raw.double_buffer,
    raw_graphics_double_buffer_source = backend.kitty_raw.double_buffer_source,
    raw_graphics_cell_offset_px = backend.kitty_raw.cell_offset_px,
    raw_graphics_overlay_bleed_cells = backend.kitty_raw.overlay_bleed_cells,
    raw_graphics_owned_images = backend.kitty_raw.owned_images,
    raw_graphics_owned_placements = backend.kitty_raw.owned_placements,
    node_version = command({ "node", "--version" }) or "unavailable",
    playwright_package = vim.uv.fs_stat(root() .. "/renderer/node_modules/playwright/package.json") and "available"
      or "missing",
    chromium_executable = discovered_executable or chrome_path_estimate() or "not found",
    chromium_discovery = discovered_executable and "confirmed by renderer subprocess"
      or "local estimate; run :MdViewerHealth to confirm via the renderer",
    chromium_launch = renderer_result and renderer_result.chromiumLaunch
      or (renderer_error and ("failed: " .. renderer_error) or "not tested"),
    temporary_directory_writable = temp_writable(),
    renderer_process = process.status(),
    raw_html = sec.raw_html,
    local_image_root = sec.document_root,
    document_root_source = sec.document_root_source,
    -- Set only when an explicitly configured root excludes the document being
    -- previewed. That combination refuses every local link and image in the
    -- document, and is otherwise only visible one refusal at a time.
    document_root_excludes_current = sec.document_root_excludes_current or false,
    document_root_unbounded = sec.document_root_unbounded or false,
    security_overrides = sec.overrides,
    viewport_calibration_tier = coordinates.calibration_tier(cfg.render),
    -- The two numbers behind that tier. The measurement is in device pixels
    -- (what a placement rectangle is drawn in); the CSS pair is what the
    -- browser viewport is built from, and the two differ by
    -- `device_scale_factor`. Printing both is what makes "measured" checkable:
    -- a tier name alone cannot show that the conversion went the right way.
    viewport_cell_pixels = cellpixels.describe(),
    viewport_cell_css_px = (function()
      local _, css_w, css_h, detail = coordinates.cell_metrics(cfg.render)
      return coordinates.describe_cell(css_w, css_h, detail)
    end)(),
    -- How the measurement's unit was decided. `ws_xpixel` is *supposed* to be
    -- device pixels, but a terminal that fills it with logical points, or a 1x
    -- display left on a device_scale_factor of 2, both halve the CSS viewport
    -- and double every glyph on screen. The heuristic that repairs that is a
    -- judgement call, so it says so rather than resolving silently.
    viewport_cell_unit = (function()
      local _, _, _, detail = coordinates.cell_metrics(cfg.render)
      if not detail then return "unknown" end
      return ("%s (divisor %g, %s)"):format(detail.unit, detail.divisor, detail.source)
    end)(),
    viewport_cell_implausible = (function()
      local _, _, _, detail = coordinates.cell_metrics(cfg.render)
      return detail ~= nil and detail.plausible == false
    end)(),
    interaction_enabled = cfg.interaction.enabled,
    -- The single authoritative answer to "which document is currently loaded in
    -- Chromium" (renderer/src/browser.js's `this.active`), only available once
    -- the renderer subprocess has actually answered a "health" request.
    chromium_active_document = renderer_result and (renderer_result.activeDocument or "none") or "not queried",
    chromium_cached_document_frames = renderer_result and renderer_result.cachedDocumentFrames or "not queried",
    chromium_cached_documents = renderer_result and renderer_result.cachedDocuments or "not queried",
    chromium_lane_documents = renderer_result and renderer_result.laneDocuments or "not queried",
    chromium_interaction_documents = renderer_result and renderer_result.interactionDocuments or "not queried",
    -- Where frames render and present, and the evidence trail behind it.
    -- The counters exist so "is this session actually locally rendered, or
    -- are PNG bytes still crossing the remote link?" is answered by numbers,
    -- never by how scrolling feels: markers up + zero fallbacks on this side,
    -- and zero remote `a=t` commands seen by the filter on the other.
    render_location = cfg.render.location,
    render_animate = cfg.render.animate == true,
    local_render_phase = local_status.phase,
    local_render_reason = local_status.reason,
    local_render_socket = local_status.socket_path,
    local_render_helper_version = local_status.helper_version,
    local_render_protocol = local_status.protocol,
    local_markers_emitted = marker_stats.markers,
    local_marker_bytes = marker_stats.marker_bytes,
    local_direct_byte_fallbacks = marker_stats.direct_bytes_fallbacks,
    -- The helper process's own counters, present only when the health round
    -- trip crossed the control socket. parser.remoteGraphicsCommands is the
    -- filter counting graphics uploads that arrived *from the remote
    -- stream*: zero while attached is the local-mode invariant holding.
    local_helper = renderer_result and renderer_result.localHelper or nil,
    local_remote_graphics_commands = renderer_result
        and renderer_result.localHelper
        and renderer_result.localHelper.parser
        and renderer_result.localHelper.parser.remoteGraphicsCommands
      or nil,
  }
end

-- nvim_buf_set_lines rejects any item containing a newline. Most collected
-- fields are short and deterministic, but chromium_launch/renderer_process's
-- last_error come straight from a live Playwright/Chromium failure, and
-- Playwright's own launch-failure messages are multi-paragraph diagnostics
-- (missing system deps, install hints, ASCII box art) -- exactly the kind of
-- thing a CI environment hits and a local dev machine does not.
local function split_lines(text)
  text = tostring(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = (line:gsub("\r$", ""))
  end
  while #lines > 1 and lines[#lines] == "" do
    table.remove(lines)
  end
  return lines
end

-- Verbose display. Every fact `M.collect()` gathers is reachable from here,
-- but not necessarily on a line of its own: a field that only ever restates
-- another one is merged into it, and a field that can only ever hold one value
-- is not a diagnostic at all. What is deliberately absent is provenance about
-- *this project's* testing -- which terminal was photographed working on which
-- date. That belongs in docs/terminal-support.md; it says nothing about the
-- session in front of the reader, and printing it beside real diagnostics
-- teaches them to skim.
local VERBOSE_LABEL_WIDTH = 26
local VERBOSE_WIDTH = 88

---Emit `label: value`, wrapping the value under itself rather than truncating
---it. Playwright launch failures are multi-paragraph, so this has to cope with
---real prose, and a truncated reason is a reason nobody can act on.
local function verbose_row(output, label, value)
  local text = table.concat(split_lines(value == nil and "unknown" or value), " ")
  local indent = (" "):rep(VERBOSE_LABEL_WIDTH)
  local budget = VERBOSE_WIDTH - VERBOSE_LABEL_WIDTH
  local prefix = ("%-" .. VERBOSE_LABEL_WIDTH .. "s"):format(label .. ":")
  if text == "" then
    output[#output + 1] = prefix
    return
  end
  local line = nil
  for word in text:gmatch("%S+") do
    if not line then
      line = word
    elseif #line + 1 + #word <= budget then
      line = line .. " " .. word
    else
      output[#output + 1] = prefix .. line
      prefix, line = indent, word
    end
  end
  if line then output[#output + 1] = prefix .. line end
end

local function yes_no(value) return value and "yes" or "no" end

local function verbose_environment(report)
  local rows = {
    { "neovim", report.neovim },
    {
      "terminal",
      report.iterm2_version ~= "not detected" and ("%s %s"):format(report.terminal_program, report.iterm2_version)
        or report.terminal_program,
    },
    { "TUI attached", yes_no(report.tui_attached) },
  }
  -- Two collected fields, one question: is the experimental API there, and did
  -- it work when it was tried?
  local ui_img = "absent"
  if report.vim_ui_img then
    ui_img = report.vim_ui_img_render_succeeded and "present, render succeeded" or "present, render did not succeed"
  end
  rows[#rows + 1] = { "vim.ui.img", ui_img }
  return rows
end

local function verbose_terminal(report)
  -- terminal_profile, graphics_confidence, graphics_decision_reason and
  -- terminal_profile_evidence were four lines restating one conclusion.
  return {
    { "platform", report.platform },
    { "multiplexer", report.multiplexer },
    { "ssh session", report.ssh },
    { "link rate", ("%s [%s]"):format(report.link_rate, report.link_rate_tier) },
    { "terminal profile", ("%s -- graphics %s"):format(report.terminal_profile, report.graphics_confidence) },
    { "identified by", report.terminal_profile_evidence },
  }
end

local function verbose_backend(report)
  -- kitty_graphics_probe_succeeded is not reported: this module never runs a
  -- protocol probe (Neovim owns terminal input), so the field is hardcoded
  -- false and read like a failure on every machine that ever ran it.
  return {
    { "selected backend", report.selected_backend },
    { "decision", report.backend_decision },
  }
end

local function verbose_raw_graphics(report)
  local overlay = report.raw_graphics_overlay_supported
      and ("on, layer %s over base %s%s"):format(
        report.raw_graphics_overlay_zindex,
        report.raw_graphics_zindex,
        -- Named on the line itself, not only in the warning: this is the first
        -- line anyone reads when an overlay rectangle comes out the wrong size,
        -- and "on" alone does not say that it is on against the profile's
        -- advice rather than because the profile allows it.
        report.raw_graphics_overlay_forced and " (forced -- this profile is not validated for it)" or ""
      )
    or ("off -- %s"):format(report.raw_graphics_overlay_reason or "reason not reported")
  -- The overlay line above already carries the "why" whenever the cell size is
  -- the cause, so this does not repeat the same parenthetical verbatim.
  local cell_pixels = tostring(report.raw_graphics_cell_pixels)
  if cell_pixels:match("^unmeasured") then cell_pixels = "unmeasured" end
  -- The strategy is the fact a bug report needs first: "native" means the
  -- terminal owns playback and a stutter is the terminal's, "frames" means
  -- the shared timer owns it, "off" carries its own reason.
  local animation = report.raw_graphics_animation_supported
      and ("%s, layer %s over base %s"):format(
        report.raw_graphics_animation_native and "native (terminal-driven)"
          or ("frames (client-driven, %s fps cap)"):format(require("md-viewer.config").get().render.animate_fps or 5),
        report.raw_graphics_animation_zindex,
        report.raw_graphics_zindex
      )
    or ("off -- %s"):format(report.raw_graphics_animation_reason or "reason not reported")
  return {
    { "overlay", overlay },
    { "animation", animation },
    { "cell pixels", cell_pixels },
    { "base layer", ("%s (%s)"):format(report.raw_graphics_zindex, report.raw_graphics_zindex_source) },
    -- Printed as one ascending run rather than three separate numbers, because
    -- the failure this catches is two of them being equal -- which is obvious
    -- on one line and easy to miss across three.
    {
      "layer stack",
      ("base %s / animation %s / selection %s"):format(
        report.raw_graphics_zindex,
        report.raw_graphics_animation_zindex,
        report.raw_graphics_overlay_zindex
      ),
    },
    {
      "double buffer",
      ("%s (%s)"):format(yes_no(report.raw_graphics_double_buffer), report.raw_graphics_double_buffer_source),
    },
    {
      "cell offset / bleed",
      ("%s / %s cell(s)"):format(report.raw_graphics_cell_offset_px, report.raw_graphics_overlay_bleed_cells),
    },
    {
      "owned",
      ("%s image(s), %s placement(s)"):format(report.raw_graphics_owned_images, report.raw_graphics_owned_placements),
    },
  }
end

local function verbose_renderer(report)
  local process = report.renderer_process or {}
  local process_text = process.running and ("running (pid %s)"):format(process.pid or "unknown")
    or (process.last_error and ("not running -- " .. process.last_error) or "not running")
  if process.running and process.stderr and process.stderr ~= "" then
    process_text = process_text .. "; stderr: " .. process.stderr
  end
  return {
    { "node", report.node_version },
    { "playwright", report.playwright_package },
    { "chromium", ("%s (%s)"):format(report.chromium_executable, report.chromium_discovery) },
    { "chromium launch", report.chromium_launch },
    { "temp dir writable", yes_no(report.temporary_directory_writable) },
    { "process", process_text },
  }
end

local function verbose_security(report)
  -- document_root_unbounded is not reported: it is true exactly when the
  -- document root on the line above is "/".
  local rows = {
    { "raw html", yes_no(report.raw_html) },
    { "document root", ("%s (%s)"):format(report.local_image_root, report.document_root_source) },
  }
  if report.document_root_excludes_current then
    rows[#rows + 1] = { "current document", "OUTSIDE the document root -- every local link and image is refused" }
  end
  rows[#rows + 1] = { "overrides", report.security_overrides }
  return rows
end

local function verbose_chromium(report)
  -- Collapsed while nothing is loaded: five counters reading "none" and "0"
  -- say only "no preview is open", and say it five times.
  if report.chromium_active_document == "not queried" then
    return { { "session", "not queried (:checkhealth does not round-trip to the renderer)" } }
  end
  if report.chromium_active_document == "none" then return { { "session", "no document loaded" } } end
  return {
    { "active document", report.chromium_active_document },
    { "cached frames", report.chromium_cached_document_frames },
    { "cached documents", report.chromium_cached_documents },
    {
      "lane / interaction",
      ("%s / %s"):format(report.chromium_lane_documents, report.chromium_interaction_documents),
    },
  }
end

---The full environment dump, rendered for `:MdViewerDebug`. It lives here
---rather than in debug.lua because this module already owns the vocabulary
---for describing a machine's capabilities; debug.lua owns what the running
---preview is doing with them.
---The local-render evidence trail. One row when the feature is off; the
---full counter set once anything local has happened, with the helper's own
---filter/injector numbers whenever the health round trip crossed the socket.
local function verbose_local(report)
  local rows = {
    { "render location", report.render_location },
    { "phase", report.local_render_phase },
  }
  if report.local_render_reason then rows[#rows + 1] = { "reason", report.local_render_reason } end
  if report.render_location ~= "local" and (report.local_render_phase or "off") == "off" then return rows end
  rows[#rows + 1] = { "helper", report.local_render_helper_version or "not attached" }
  rows[#rows + 1] = { "socket", report.local_render_socket or "none" }
  rows[#rows + 1] = { "protocol", report.local_render_protocol }
  rows[#rows + 1] = { "markers emitted", report.local_markers_emitted or 0 }
  rows[#rows + 1] = { "marker bytes", report.local_marker_bytes or 0 }
  rows[#rows + 1] = { "direct-byte fallbacks", report.local_direct_byte_fallbacks or 0 }
  local helper = report.local_helper
  if helper and helper.parser then
    rows[#rows + 1] = { "filter: markers seen", helper.parser.markerCount }
    rows[#rows + 1] = { "filter: remote graphics commands", helper.parser.remoteGraphicsCommands }
    rows[#rows + 1] = { "filter: passthrough bytes", helper.parser.passthroughBytes }
  end
  if helper and helper.injector then
    rows[#rows + 1] = { "injector: injected", helper.injector.injectedTransactions }
    rows[#rows + 1] = { "injector: injected bytes", helper.injector.injectedBytes }
    rows[#rows + 1] = { "injector: superseded", helper.injector.superseded }
    rows[#rows + 1] = { "injector: carried deletions", helper.injector.carriedDeletionBuffers }
  end
  return rows
end

function M.environment_lines(report)
  local output = {}
  local sections = {
    { title = "Environment", rows = verbose_environment(report) },
    { title = "Terminal & Graphics", rows = verbose_terminal(report) },
    { title = "Backend Selection", rows = verbose_backend(report) },
    { title = "Raw Graphics (kitty_raw)", rows = verbose_raw_graphics(report) },
    { title = "Local Rendering", rows = verbose_local(report) },
    { title = "Renderer Process", rows = verbose_renderer(report) },
    { title = "Security", rows = verbose_security(report) },
    {
      title = "Interaction & Coordinates",
      rows = {
        { "interaction enabled", yes_no(report.interaction_enabled) },
        { "viewport calibration", report.viewport_calibration_tier },
        { "measured cell", report.viewport_cell_pixels },
        { "viewport cell (CSS px)", report.viewport_cell_css_px },
        { "cell unit", report.viewport_cell_unit },
      },
    },
    { title = "Chromium Session State", rows = verbose_chromium(report) },
  }
  for _, section in ipairs(sections) do
    output[#output + 1] = ""
    output[#output + 1] = "-- " .. section.title .. " --"
    for _, row in ipairs(section.rows) do
      verbose_row(output, row[1], row[2])
    end
  end

  -- Only the caveats that say something may not work. The rest describe how
  -- md-viewer identified this terminal and what was validated when, which is
  -- documentation rather than diagnosis.
  local actionable = {}
  for _, caveat in ipairs(report.graphics_caveats or {}) do
    if caveat.kind == "warn" then actionable[#actionable + 1] = caveat.text end
  end
  if #actionable > 0 then
    output[#output + 1] = ""
    output[#output + 1] = "-- Terminal caveats --"
    for _, text in ipairs(actionable) do
      verbose_row(output, "caveat", text)
    end
  end
  return output
end

---What a required-dependency failure looks like vs a graceful fallback.
---
---"broken" is reserved for conditions that prevent normal operation outright
---(a missing package, an unlaunchable browser, a crashed renderer); a
---renderer that simply has not been started yet (`running = false` with no
---`last_error`) is the ordinary `:checkhealth` case, since that path never
---round-trips to the subprocess, and must not read as broken.
local function classify(report, cfg)
  if report.playwright_package == "missing" then
    return "broken", "the renderer's playwright package is missing (run npm ci in renderer/)"
  end
  if report.chromium_executable == "not found" then
    return "broken", "no approved Chromium/Chrome/Edge executable was found"
  end
  if type(report.chromium_launch) == "string" and report.chromium_launch:match("^failed:") then
    return "broken", "the renderer failed to launch Chromium: " .. report.chromium_launch
  end
  if report.temporary_directory_writable == false then return "broken", "the temporary directory is not writable" end
  if report.renderer_process and report.renderer_process.last_error then
    return "broken", "the renderer process reported an error: " .. tostring(report.renderer_process.last_error)
  end
  if report.selected_backend == nil then return "degraded", "no rendering backend could be selected" end
  -- Only an *auto* fallback to cells is a degradation. A backend the user
  -- configured directly is working exactly as asked and should not read as
  -- a yellow warning every time the plugin starts.
  if report.selected_backend == "cells" and cfg.image.backend ~= "cells" then
    return "degraded", "no image backend is available; falling back to text-cell rendering"
  end
  return "healthy", ("selected backend (%s) is working as intended"):format(report.selected_backend)
end

local function backend_label(report, cfg)
  if not report.selected_backend then return "none" end
  if report.selected_backend == "cells" then
    return cfg.image.backend == "cells" and "cells (explicit)" or "cells (fallback)"
  end
  return report.selected_backend
end

local function image_support_text(selected_backend)
  if selected_backend == "cells" then return "reduced (text-cell rendering)" end
  if selected_backend == "nvim_img" or selected_backend == "kitty_raw" then return "available" end
  return "unavailable"
end

local function process_summary(process)
  process = process or {}
  if process.running then return "running" end
  if process.last_error then return "stopped: " .. split_lines(process.last_error)[1] end
  return "not started yet"
end

---One line answering where this session's frames come from. "local" is only
---a fact while attached; any other phase names itself and its reason, so
---"configured local but rendering here" cannot read as success.
local function location_label(report)
  if report.render_location ~= "local" then return "current (this host renders and ships frames)" end
  if report.local_render_phase == "attached" then
    return ("local (attached, helper %s)"):format(report.local_render_helper_version or "version unknown")
  end
  local reason = report.local_render_reason and (": " .. split_lines(report.local_render_reason)[1]) or ""
  return ("local requested, %s%s"):format(report.local_render_phase or "off", reason)
end

local function build_sections(report, cfg)
  local terminal_rows = {
    { label = "Profile", value = ("%s on %s"):format(report.terminal_profile, report.platform), level = "info" },
  }
  if report.multiplexer and report.multiplexer ~= "none" then
    terminal_rows[#terminal_rows + 1] = { label = "Multiplexer", value = report.multiplexer, level = "info" }
  end
  -- Shown only when true, like Multiplexer above: it is context for the Profile
  -- row directly over it, not a fact worth a line in the common local case.
  if report.ssh and report.ssh ~= "no" then
    terminal_rows[#terminal_rows + 1] = { label = "SSH session", value = report.ssh, level = "info" }
  end
  return {
    {
      title = "Rendering",
      rows = {
        { label = "Backend", value = backend_label(report, cfg), level = "ok" },
        { label = "Image support", value = image_support_text(report.selected_backend), level = "ok" },
        { label = "Reason", value = report.backend_decision, level = "info" },
        -- "info" and not "ok": unknown is a legitimate value here and must not
        -- read as a green tick or as a fault. Nothing in md-viewer infers a link
        -- rate, so the absence of one is a fact rather than a degradation.
        { label = "Link rate", value = report.link_rate, level = "info" },
        { label = "Location", value = location_label(report), level = "info" },
      },
    },
    { title = "Terminal", rows = terminal_rows },
    {
      title = "Renderer",
      rows = {
        { label = "Node", value = report.node_version, level = "info" },
        { label = "Playwright", value = report.playwright_package, level = "ok" },
        { label = "Chromium", value = report.chromium_executable, level = "ok" },
        { label = "Process", value = process_summary(report.renderer_process), level = "ok" },
      },
    },
  }
end

---The single canonical list of actionable issues. Every warn/error-worthy
---condition is collected here and nowhere else, so the concise views never
---repeat the same diagnosis across a caveat, a reason, and a warning.
local function build_warnings(report, status, status_reason)
  local warnings = {}
  if status ~= "healthy" then
    -- status_reason can be a multi-paragraph Playwright launch-failure
    -- message; keep the full text, just split so no single buffer line
    -- carries an embedded newline.
    local reason_lines = split_lines(status_reason)
    warnings[#warnings + 1] = {
      text = reason_lines[1],
      severity = status == "broken" and "error" or "warn",
      detail = #reason_lines > 1 and vim.list_slice(reason_lines, 2) or nil,
    }
  end
  -- Only the caveats a reader could act on. The rest describe how md-viewer
  -- knows what it knows -- how the terminal was identified, what was
  -- photographed and when -- and are recorded in verbose output instead. A
  -- validation record is evidence that something works; listing it here taught
  -- readers that this list is noise.
  for _, caveat in ipairs(report.graphics_caveats or {}) do
    if caveat.kind == "warn" then warnings[#warnings + 1] = { text = caveat.text, severity = "warn" } end
  end
  if report.document_root_excludes_current then
    warnings[#warnings + 1] = {
      text = ("security.document_root is configured as %s, but the current document is outside it"):format(
        report.local_image_root
      ),
      severity = "error",
      detail = {
        "Every local link and local image in this document will be refused.",
        "Unset security.document_root to root each document in its own project, "
          .. "or adjust security.document_root_markers.",
      },
    }
  end
  if report.render_location == "local" and report.local_render_phase ~= "attached" then
    warnings[#warnings + 1] = {
      text = ('render.location = "local" but no helper is attached (%s)'):format(
        report.local_render_reason or report.local_render_phase or "not attached"
      ),
      severity = "warn",
      detail = {
        "Frames are rendering on this host and crossing the link as PNGs.",
        "On the machine your terminal runs on, launch ssh through the helper:",
        "  node <md-viewer>/renderer/src/local-main.js -- ssh <this-host>",
      },
    }
  end
  if (report.local_direct_byte_fallbacks or 0) > 0 then
    warnings[#warnings + 1] = {
      text = ("%d frame(s) fell back to direct PNG bytes while the marker presenter was installed"):format(
        report.local_direct_byte_fallbacks
      ),
      severity = "warn",
      detail = { "A mode race: correct pixels, expensive bytes. Recurring counts mean attach/demote is flapping." },
    }
  end
  if report.render_location == "local" and report.render_animate then
    warnings[#warnings + 1] = {
      text = "render.animate has no effect in local mode; animated images render as still frames",
      severity = "warn",
      detail = { "Animation decode needs Chromium beside the document service, which local mode deliberately splits." },
    }
  end
  -- Neither divisor produced a cell a font could plausibly have, so the
  -- viewport is being built against a number that is probably wrong -- and a
  -- wrong cell shows up as preview text at the wrong size, which reads like a
  -- font setting rather than a measurement fault. Say so, and say what settles
  -- it, because nothing here can settle it alone.
  if report.viewport_cell_implausible then
    warnings[#warnings + 1] = {
      text = ("the terminal's reported cell does not resolve to a plausible size (%s)"):format(
        report.viewport_cell_css_px
      ),
      severity = "warn",
      detail = {
        "Preview text will render at the wrong size for the split.",
        "Set MD_VIEWER_CELL_WIDTH_PX and MD_VIEWER_CELL_HEIGHT_PX to the cell in CSS pixels to pin it,",
        "or set render.device_scale_factor to this display's real scale.",
      },
    }
  end
  -- Qualifying a terminal by hand is a supported thing to do, and this is not
  -- telling the reader to stop. It is telling them they are doing it, because
  -- the failure mode is not subtle and does not look like a setting: a terminal
  -- that mishandles crop keys draws a one-glyph caret block as a rectangle
  -- covering most of the split, which reads as a rendering bug rather than as
  -- an override they turned on.
  if report.raw_graphics_overlay_forced then
    warnings[#warnings + 1] = {
      text = ("interaction.selection_overlay=on is forcing the selection overlay onto %s, which is not validated for it"):format(
        report.terminal_profile or "this terminal"
      ),
      severity = "warn",
      detail = {
        "A terminal that mishandles overlay placements degrades badly rather than gracefully:",
        "oversized or misplaced highlight and caret rectangles, or unbounded terminal memory.",
        "Remove the override to fall back to full-frame captures, which are always correct.",
      },
    }
  end
  -- A link that answered 0.8 MB/s and then 2.0 has not been measured; it has
  -- been sampled twice from something that is not a constant, and every estimate
  -- built on it inherits that. Raised only for a measurement that disagrees with
  -- itself -- never for an *unmeasured* link, which is not a fault and which
  -- nothing else here treats as one.
  if report.link_rate_spread and report.link_rate_spread > 2 then
    warnings[#warnings + 1] = {
      text = ("the cached link measurement's own samples disagree by %.1fx, so this link is not steady enough to estimate from"):format(
        report.link_rate_spread
      ),
      severity = "warn",
      detail = {
        "Re-run :MdViewerMeasureLink. If it disagrees again, the link itself is varying and no",
        "single number describes it; render.ssh_link_bytes_per_sec pins one by hand and is never",
        "capped against anything.",
      },
    }
  end
  if not report.tui_attached then warnings[#warnings + 1] = { text = "no TUI attached", severity = "warn" } end
  return warnings
end

---Statements of fact about how this session is configured: true, worth
---knowing, and nothing to fix. Kept separate from warnings so that a warning
---always means "something here may not work", and deliberately short -- a note
---that needs a paragraph of justification belongs in the documentation, not in
---a health report arguing with the reader about their own configuration.
local function build_notes(report)
  local notes = {}
  if report.document_root_unbounded then
    notes[#notes + 1] = {
      text = 'security.document_root is "/": local links and images resolve to any path on this filesystem',
      detail = { "Browser network access is always blocked, so a document can read a local file but cannot send it." },
    }
  end
  return notes
end

---Collapse the flat `report` into the structure both concise renderers
---share: an overall status, a handful of curated sections, and one warnings
---list. Verbose output renders `report` directly instead, so nothing this
---function infers or omits can cause verbose data to diverge from the raw
---collected state.
local function diagnose(report, cfg)
  cfg = cfg or config.get()
  local status, status_reason = classify(report, cfg)
  return {
    status = status,
    status_reason = status_reason,
    sections = build_sections(report, cfg),
    warnings = build_warnings(report, status, status_reason),
    notes = build_notes(report),
  }
end

local status_glyph = { healthy = "✓", degraded = "⚠", broken = "✗" }
local status_health_level = { healthy = "ok", degraded = "warn", broken = "error" }

local function render_concise_text(diagnosis)
  local output = {
    "md-viewer.nvim health",
    string.rep("=", 22),
    "",
    ("%s Status: %s — %s"):format(
      status_glyph[diagnosis.status],
      diagnosis.status:upper(),
      split_lines(diagnosis.status_reason)[1]
    ),
  }
  for _, section in ipairs(diagnosis.sections) do
    output[#output + 1] = ""
    output[#output + 1] = section.title
    for _, row in ipairs(section.rows) do
      output[#output + 1] = ("  %-16s %s"):format(row.label .. ":", split_lines(row.value)[1])
    end
  end
  output[#output + 1] = ""
  output[#output + 1] = "Warnings"
  if #diagnosis.warnings == 0 then
    output[#output + 1] = "  none"
  else
    for _, warning in ipairs(diagnosis.warnings) do
      output[#output + 1] = "  - " .. warning.text
      for _, detail in ipairs(warning.detail or {}) do
        output[#output + 1] = "    " .. detail
      end
    end
  end
  if #diagnosis.notes > 0 then
    output[#output + 1] = ""
    output[#output + 1] = "Notes"
    for _, note in ipairs(diagnosis.notes) do
      output[#output + 1] = "  - " .. note.text
      for _, detail in ipairs(note.detail or {}) do
        output[#output + 1] = "    " .. detail
      end
    end
  end
  output[#output + 1] = ""
  output[#output + 1] = "Run :MdViewerDebug for the full diagnostic."
  return output
end

local function render_healthlib(diagnosis)
  vim.health.start("md-viewer.nvim")
  vim.health[status_health_level[diagnosis.status]](
    ("Status: %s — %s"):format(diagnosis.status:upper(), split_lines(diagnosis.status_reason)[1])
  )
  for _, section in ipairs(diagnosis.sections) do
    vim.health.start("md-viewer.nvim: " .. section.title)
    for _, row in ipairs(section.rows) do
      vim.health[row.level](("%s: %s"):format(row.label, split_lines(row.value)[1]))
    end
  end
  vim.health.start("md-viewer.nvim: Warnings")
  if #diagnosis.warnings == 0 then
    vim.health.ok("No warnings")
  else
    for _, warning in ipairs(diagnosis.warnings) do
      vim.health[warning.severity](warning.text, warning.detail)
    end
  end
  for _, note in ipairs(diagnosis.notes) do
    vim.health.info(note.text, note.detail)
  end
  -- `:checkhealth` cannot await the renderer subprocess (see M.collect's own
  -- comment), so which document Chromium currently holds is only ever known
  -- via `:MdViewerHealth`, which does the round trip.
  vim.health.info("Chromium's currently active document: see :MdViewerHealth (not queried by :checkhealth)")
end

---@param mode? string "verbose" for the full field-by-field dump; anything
---else (including nil) renders the concise, status-led summary.
---The short, human-readable report: is this machine set up to work, and if
---not, what about it. Deliberately the only thing this command prints. What
---the preview is doing right now, and the full field-by-field environment
---behind these answers, is `:MdViewerDebug` -- one artifact, for pasting into
---an issue, rather than a third view splitting the same diagnosis in half.
function M.show()
  process.request("health", { browser = config.get().browser }, function(result, err)
    vim.cmd("botright new")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, "md-viewer://health")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    local report = M.collect(result, err)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, render_concise_text(diagnose(report, config.get())))
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "md-viewer-health"
  end)
end

---`:checkhealth md-viewer`. Nothing in this repository calls it -- Neovim's
---health framework finds `lua/md-viewer/health.lua` by name and calls `check()`
---itself, so it looks unreferenced to any search. Do not remove it.
function M.check() render_healthlib(diagnose(M.collect(), config.get())) end

-- Test-only surface, mirroring backends/kitty_raw.lua's M._preconditions:
-- lets status classification get fast, deterministic coverage against a
-- fabricated report without a renderer round-trip or real env/fs mutation.
M._diagnose = diagnose

return M
