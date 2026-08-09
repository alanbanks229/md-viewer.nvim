local backends = require("md-viewer.backends")
local config = require("md-viewer.config")
local coordinates = require("md-viewer.coordinates")
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

function M.collect(renderer_result, renderer_error)
  local cfg = config.get()
  local backend = backends.health()
  local sec = security.summary(cfg, document_buf())
  local version = vim.version()
  local capability = terminal.capability(cfg.terminal)
  local discovered_executable = renderer_result and renderer_result.executable
  return {
    neovim = ("%d.%d.%d"):format(version.major, version.minor, version.patch),
    vim_ui_img = type(vim.ui and vim.ui.img) == "table",
    tui_attached = #vim.api.nvim_list_uis() > 0,
    terminal_program = vim.env.TERM_PROGRAM or "unknown",
    iterm2_version = vim.env.TERM_PROGRAM == "iTerm.app" and (vim.env.TERM_PROGRAM_VERSION or "undetectable")
      or "not detected",
    platform = capability.platform,
    multiplexer = capability.multiplexer,
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
    -- Whether a drag paints its highlight as overlay rectangles (a few hundred
    -- bytes per frame) or by re-photographing the page, and why.
    raw_graphics_overlay_supported = backend.kitty_raw.overlay_supported,
    raw_graphics_overlay_reason = backend.kitty_raw.overlay_reason,
    -- The overlay's own layer. It must sit exactly one above
    -- raw_graphics_zindex: equal numbers mean the base and the highlight are
    -- ordered by image id instead, and the highlight disappears under the base
    -- as soon as a full frame is re-uploaded.
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
    network_blocked = sec.network_blocked,
    raw_html = sec.raw_html,
    local_image_root = sec.document_root,
    document_root_source = sec.document_root_source,
    -- Set only when an explicitly configured root excludes the document being
    -- previewed. That combination refuses every local link and image in the
    -- document, and is otherwise only visible one refusal at a time.
    document_root_excludes_current = sec.document_root_excludes_current or false,
    document_root_unbounded = sec.document_root_unbounded or false,
    security_overrides = sec.overrides,
    viewport_calibration_tier = coordinates.calibration_tier(),
    interaction_enabled = cfg.interaction.enabled,
    -- The single authoritative answer to "which document is currently loaded in
    -- Chromium" (renderer/src/browser.js's `this.active`), only available once
    -- the renderer subprocess has actually answered a "health" request.
    chromium_active_document = renderer_result and (renderer_result.activeDocument or "none") or "not queried",
    chromium_cached_document_frames = renderer_result and renderer_result.cachedDocumentFrames or "not queried",
    chromium_cached_documents = renderer_result and renderer_result.cachedDocuments or "not queried",
    chromium_lane_documents = renderer_result and renderer_result.laneDocuments or "not queried",
    chromium_interaction_documents = renderer_result and renderer_result.interactionDocuments or "not queried",
  }
end

-- Named groups of `M.collect()`'s keys, in verbose display order. Every key
-- collected above must appear exactly once here -- verbose mode is the
-- guarantee that nothing the concise/checkhealth views omit is actually lost.
local verbose_sections = {
  { title = "Environment", keys = { "neovim", "vim_ui_img", "tui_attached", "terminal_program", "iterm2_version" } },
  {
    title = "Terminal & Graphics",
    keys = {
      "platform",
      "multiplexer",
      "terminal_profile",
      "terminal_profile_evidence",
      "graphics_confidence",
      "graphics_decision_reason",
      "graphics_validation",
      "graphics_caveats",
    },
  },
  {
    title = "Backend Selection",
    keys = { "kitty_graphics_probe_succeeded", "vim_ui_img_render_succeeded", "selected_backend", "backend_decision" },
  },
  {
    title = "Raw Graphics (kitty_raw)",
    keys = {
      "raw_graphics_zindex",
      "raw_graphics_zindex_source",
      "raw_graphics_overlay_supported",
      "raw_graphics_overlay_reason",
      "raw_graphics_overlay_zindex",
      "raw_graphics_cell_pixels",
      "raw_graphics_double_buffer",
      "raw_graphics_double_buffer_source",
      "raw_graphics_cell_offset_px",
      "raw_graphics_overlay_bleed_cells",
      "raw_graphics_owned_images",
      "raw_graphics_owned_placements",
    },
  },
  {
    title = "Renderer Process",
    keys = {
      "node_version",
      "playwright_package",
      "chromium_executable",
      "chromium_discovery",
      "chromium_launch",
      "temporary_directory_writable",
      "renderer_process",
    },
  },
  {
    title = "Security",
    keys = {
      "network_blocked",
      "raw_html",
      "local_image_root",
      "document_root_source",
      "document_root_excludes_current",
      "document_root_unbounded",
      "security_overrides",
    },
  },
  { title = "Interaction & Coordinates", keys = { "viewport_calibration_tier", "interaction_enabled" } },
  {
    title = "Chromium Session State",
    keys = {
      "chromium_active_document",
      "chromium_cached_document_frames",
      "chromium_cached_documents",
      "chromium_lane_documents",
      "chromium_interaction_documents",
    },
  },
}

local function format_field(output, key, value)
  if key == "graphics_caveats" and type(value) == "table" then
    output[#output + 1] = ("%-36s %s"):format("graphics caveats:", #value > 0 and "" or "none")
    for _, caveat in ipairs(value) do
      output[#output + 1] = "  - " .. caveat
    end
    return
  end
  -- nvim_buf_set_lines rejects any item containing a newline, and
  -- vim.inspect() emits multi-line output for any non-trivial table.
  if type(value) == "table" then value = vim.inspect(value, { newline = " ", indent = "" }) end
  output[#output + 1] = ("%-36s %s"):format(key:gsub("_", " ") .. ":", tostring(value))
end

local function render_verbose_text(report)
  local output = { "md-viewer.nvim health (verbose)", string.rep("=", 31) }
  for _, section in ipairs(verbose_sections) do
    output[#output + 1] = ""
    output[#output + 1] = "-- " .. section.title .. " --"
    for _, key in ipairs(section.keys) do
      format_field(output, key, report[key])
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
  if process.last_error then return "stopped: " .. tostring(process.last_error) end
  return "not started yet"
end

local function build_sections(report, cfg)
  local terminal_rows = {
    { label = "Profile", value = ("%s on %s"):format(report.terminal_profile, report.platform), level = "info" },
  }
  if report.multiplexer and report.multiplexer ~= "none" then
    terminal_rows[#terminal_rows + 1] = { label = "Multiplexer", value = report.multiplexer, level = "info" }
  end
  return {
    {
      title = "Rendering",
      rows = {
        { label = "Backend", value = backend_label(report, cfg), level = "ok" },
        { label = "Image support", value = image_support_text(report.selected_backend), level = "ok" },
        { label = "Reason", value = report.backend_decision, level = "info" },
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
    warnings[#warnings + 1] = { text = status_reason, severity = status == "broken" and "error" or "warn" }
  end
  for _, caveat in ipairs(report.graphics_caveats or {}) do
    warnings[#warnings + 1] = { text = caveat, severity = "warn" }
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
  elseif report.document_root_unbounded then
    warnings[#warnings + 1] = {
      text = 'document root is "/" -- local links and images are not confined to a project',
      severity = "warn",
      detail = {
        "Deliberate and supported: the preview opens whatever Neovim would open.",
        report.network_blocked and "Network is blocked, so a document can read a local image but cannot send it."
          or "Network is ENABLED as well; narrow security.document_root or re-block the network.",
      },
    }
  end
  if report.network_blocked == false then
    warnings[#warnings + 1] = { text = "network access is explicitly enabled", severity = "warn" }
  end
  if not report.tui_attached then warnings[#warnings + 1] = { text = "no TUI attached", severity = "warn" } end
  return warnings
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
  }
end

local status_glyph = { healthy = "✓", degraded = "⚠", broken = "✗" }
local status_health_level = { healthy = "ok", degraded = "warn", broken = "error" }

local function render_concise_text(diagnosis)
  local output = {
    "md-viewer.nvim health",
    string.rep("=", 22),
    "",
    ("%s Status: %s — %s"):format(status_glyph[diagnosis.status], diagnosis.status:upper(), diagnosis.status_reason),
  }
  for _, section in ipairs(diagnosis.sections) do
    output[#output + 1] = ""
    output[#output + 1] = section.title
    for _, row in ipairs(section.rows) do
      output[#output + 1] = ("  %-16s %s"):format(row.label .. ":", row.value)
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
  output[#output + 1] = ""
  output[#output + 1] = "Run :MdViewerHealth verbose for full diagnostic detail."
  return output
end

local function render_healthlib(diagnosis)
  vim.health.start("md-viewer.nvim")
  vim.health[status_health_level[diagnosis.status]](
    ("Status: %s — %s"):format(diagnosis.status:upper(), diagnosis.status_reason)
  )
  for _, section in ipairs(diagnosis.sections) do
    vim.health.start("md-viewer.nvim: " .. section.title)
    for _, row in ipairs(section.rows) do
      vim.health[row.level](("%s: %s"):format(row.label, row.value))
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
  -- `:checkhealth` cannot await the renderer subprocess (see M.collect's own
  -- comment), so which document Chromium currently holds is only ever known
  -- via `:MdViewerHealth`, which does the round trip.
  vim.health.info("Chromium's currently active document: see :MdViewerHealth (not queried by :checkhealth)")
end

---@param mode? string "verbose" for the full field-by-field dump; anything
---else (including nil) renders the concise, status-led summary.
function M.show(mode)
  process.request("health", { browser = config.get().browser }, function(result, err)
    vim.cmd("botright new")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, "md-viewer://health")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    local report = M.collect(result, err)
    local out = mode == "verbose" and render_verbose_text(report) or render_concise_text(diagnose(report, config.get()))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, out)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "md-viewer-health"
  end)
end

function M.check() render_healthlib(diagnose(M.collect(), config.get())) end

-- Test-only surface, mirroring backends/kitty_raw.lua's M._preconditions:
-- lets status classification get fast, deterministic coverage against a
-- fabricated report without a renderer round-trip or real env/fs mutation.
M._diagnose = diagnose

return M
