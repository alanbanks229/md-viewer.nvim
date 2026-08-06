local backends = require("md-viewer.backends")
local config = require("md-viewer.config")
local process = require("md-viewer.process")
local security = require("md-viewer.security")

local M = {}

local function root()
  local source = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function command(args)
  local result = vim.system(args, { text = true }):wait()
  return result.code == 0 and vim.trim(result.stdout or "") or nil
end

local function chrome_path()
  local configured = config.get().browser.executable_path
  local candidates = configured and { configured } or {
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
  }
  for _, path in ipairs(candidates) do if vim.uv.fs_stat(path) then return path end end
end

local function temp_writable()
  local path = vim.fn.tempname()
  local fd = vim.uv.fs_open(path, "w", 384)
  if not fd then return false end
  vim.uv.fs_close(fd); vim.uv.fs_unlink(path)
  return true
end

function M.collect(renderer_result, renderer_error)
  local cfg = config.get()
  local backend = backends.health()
  local sec = security.summary(cfg, vim.api.nvim_get_current_buf())
  local version = vim.version()
  return {
    neovim = ("%d.%d.%d"):format(version.major, version.minor, version.patch),
    vim_ui_img = type(vim.ui and vim.ui.img) == "table",
    tui_attached = #vim.api.nvim_list_uis() > 0,
    terminal_program = vim.env.TERM_PROGRAM or "unknown",
    iterm2_version = vim.env.TERM_PROGRAM == "iTerm.app" and (vim.env.TERM_PROGRAM_VERSION or "undetectable") or "not detected",
    kitty_graphics_advertised = vim.env.TERM_PROGRAM == "iTerm.app" or (vim.env.TERM or ""):match("kitty") ~= nil,
    kitty_graphics_probe_succeeded = backend.kitty_raw.probe_succeeded,
    vim_ui_img_render_succeeded = backend.nvim_img.render_succeeded or false,
    selected_backend = backend.selected,
    backend_decision = backend.decision,
    raw_graphics_zindex = backend.kitty_raw.zindex,
    node_version = command({ "node", "--version" }) or "unavailable",
    playwright_package = vim.uv.fs_stat(root() .. "/renderer/node_modules/playwright/package.json") and "available" or "missing",
    chromium_executable = chrome_path() or "not found",
    chromium_launch = renderer_result and renderer_result.chromiumLaunch or (renderer_error and ("failed: " .. renderer_error) or "not tested"),
    temporary_directory_writable = temp_writable(),
    renderer_process = process.status(),
    network_blocked = sec.network_blocked,
    raw_html = sec.raw_html,
    local_image_root = sec.document_root,
    security_overrides = sec.overrides,
    viewport_calibration = (vim.env.MD_VIEWER_CELL_WIDTH_PX and vim.env.MD_VIEWER_CELL_HEIGHT_PX) and "explicit" or "aspect-ratio estimate",
  }
end

local order = {
  "neovim", "vim_ui_img", "tui_attached", "terminal_program", "iterm2_version",
  "kitty_graphics_advertised", "kitty_graphics_probe_succeeded", "vim_ui_img_render_succeeded",
  "selected_backend", "backend_decision", "raw_graphics_zindex", "node_version", "playwright_package",
  "chromium_executable", "chromium_launch", "temporary_directory_writable",
  "renderer_process", "network_blocked", "raw_html", "local_image_root",
  "security_overrides", "viewport_calibration",
}

local function lines(report)
  local output = { "md-viewer.nvim health", string.rep("=", 21) }
  for _, key in ipairs(order) do
    local value = report[key]
    if type(value) == "table" then value = vim.inspect(value) end
    output[#output + 1] = ("%-36s %s"):format(key:gsub("_", " ") .. ":", tostring(value))
  end
  return output
end

function M.show()
  process.request("health", { browser = config.get().browser }, function(result, err)
    vim.cmd("botright new")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, "md-viewer://health")
    vim.bo[buf].buftype = "nofile"; vim.bo[buf].bufhidden = "wipe"; vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines(M.collect(result, err)))
    vim.bo[buf].modifiable = false; vim.bo[buf].filetype = "md-viewer-health"
  end)
end

function M.check()
  local report = M.collect()
  vim.health.start("md-viewer.nvim")
  vim.health.info("Neovim " .. report.neovim)
  if report.vim_ui_img then vim.health.ok("vim.ui.img exists") else vim.health.warn("vim.ui.img is missing; auto uses cells") end
  if report.tui_attached then vim.health.ok("TUI attached") else vim.health.warn("No TUI attached") end
  vim.health.info("Backend: " .. tostring(report.selected_backend) .. " — " .. tostring(report.backend_decision))
  if report.playwright_package == "available" then vim.health.ok("Playwright package available") else vim.health.error("Playwright package missing; run npm ci in renderer/") end
  if report.chromium_executable ~= "not found" then vim.health.ok("Approved Chromium: " .. report.chromium_executable) else vim.health.error("Approved Chromium executable not found") end
  if report.network_blocked then vim.health.ok("Network blocked") else vim.health.warn("Network access explicitly enabled") end
end

return M
