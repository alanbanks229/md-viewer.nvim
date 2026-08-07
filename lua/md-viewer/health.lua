local backends = require("md-viewer.backends")
local config = require("md-viewer.config")
local coordinates = require("md-viewer.coordinates")
local process = require("md-viewer.process")
local security = require("md-viewer.security")
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

function M.collect(renderer_result, renderer_error)
  local cfg = config.get()
  local backend = backends.health()
  local sec = security.summary(cfg, vim.api.nvim_get_current_buf())
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

local order = {
  "neovim",
  "vim_ui_img",
  "tui_attached",
  "terminal_program",
  "iterm2_version",
  "platform",
  "multiplexer",
  "terminal_profile",
  "terminal_profile_evidence",
  "graphics_confidence",
  "graphics_decision_reason",
  "graphics_validation",
  "graphics_caveats",
  "kitty_graphics_probe_succeeded",
  "vim_ui_img_render_succeeded",
  "selected_backend",
  "backend_decision",
  "raw_graphics_zindex",
  "raw_graphics_zindex_source",
  "raw_graphics_double_buffer",
  "raw_graphics_double_buffer_source",
  "raw_graphics_cell_offset_px",
  "raw_graphics_overlay_bleed_cells",
  "raw_graphics_owned_images",
  "raw_graphics_owned_placements",
  "node_version",
  "playwright_package",
  "chromium_executable",
  "chromium_discovery",
  "chromium_launch",
  "temporary_directory_writable",
  "renderer_process",
  "network_blocked",
  "raw_html",
  "local_image_root",
  "security_overrides",
  "viewport_calibration_tier",
  "interaction_enabled",
  "chromium_active_document",
  "chromium_cached_document_frames",
  "chromium_cached_documents",
  "chromium_lane_documents",
  "chromium_interaction_documents",
}

local function lines(report)
  local output = { "md-viewer.nvim health", string.rep("=", 21) }
  for _, key in ipairs(order) do
    local value = report[key]
    if key == "graphics_caveats" and type(value) == "table" then
      output[#output + 1] = ("%-36s %s"):format("graphics caveats:", #value > 0 and "" or "none")
      for _, caveat in ipairs(value) do
        output[#output + 1] = "  - " .. caveat
      end
    else
      -- nvim_buf_set_lines rejects any item containing a newline, and
      -- vim.inspect() emits multi-line output for any non-trivial table.
      if type(value) == "table" then value = vim.inspect(value, { newline = " ", indent = "" }) end
      output[#output + 1] = ("%-36s %s"):format(key:gsub("_", " ") .. ":", tostring(value))
    end
  end
  return output
end

function M.show()
  process.request("health", { browser = config.get().browser }, function(result, err)
    vim.cmd("botright new")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, "md-viewer://health")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines(M.collect(result, err)))
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "md-viewer-health"
  end)
end

function M.check()
  local report = M.collect()
  vim.health.start("md-viewer.nvim")
  vim.health.info("Neovim " .. report.neovim)
  if report.vim_ui_img then
    vim.health.ok("vim.ui.img exists")
  else
    vim.health.warn("vim.ui.img is missing; auto uses cells")
  end
  if report.tui_attached then
    vim.health.ok("TUI attached")
  else
    vim.health.warn("No TUI attached")
  end
  vim.health.info(
    ("Terminal profile: %s on %s (multiplexer: %s)"):format(
      report.terminal_profile,
      report.platform,
      report.multiplexer
    )
  )
  vim.health.info("Evidence: " .. report.terminal_profile_evidence)
  if report.graphics_confidence == "explicit" or report.graphics_confidence == "inferred" then
    vim.health.ok(("Kitty graphics: %s (%s)"):format(report.graphics_confidence, report.graphics_decision_reason))
  else
    vim.health.warn(("Kitty graphics: %s (%s)"):format(report.graphics_confidence, report.graphics_decision_reason))
  end
  for _, caveat in ipairs(report.graphics_caveats) do
    vim.health.info("Caveat: " .. caveat)
  end
  vim.health.info("Backend: " .. tostring(report.selected_backend) .. " — " .. tostring(report.backend_decision))
  if report.playwright_package == "available" then
    vim.health.ok("Playwright package available")
  else
    vim.health.error("Playwright package missing; run npm ci in renderer/")
  end
  if report.chromium_executable ~= "not found" then
    vim.health.ok("Approved Chromium: " .. report.chromium_executable)
  else
    vim.health.error("Approved Chromium executable not found")
  end
  if report.network_blocked then
    vim.health.ok("Network blocked")
  else
    vim.health.warn("Network access explicitly enabled")
  end
  if report.interaction_enabled then
    vim.health.ok("Interaction enabled")
  else
    vim.health.warn("Interaction disabled (interaction.enabled = false)")
  end
  -- `:checkhealth` cannot await the renderer subprocess (see M.collect's own
  -- comment), so which document Chromium currently holds is only ever known
  -- via `:MdViewerHealth`, which does the round trip.
  vim.health.info("Chromium's currently active document: see :MdViewerHealth (not queried by :checkhealth)")
end

return M
