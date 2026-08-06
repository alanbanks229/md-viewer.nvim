local config = require("md-viewer.config")
local process = require("md-viewer.process")
local preview = require("md-viewer.preview")

local M = {}

function M.is_stale(session, serial)
  return session.closed or serial ~= session.request_serial
end

local function read_bytes(path, limit)
  local stat, err = vim.uv.fs_stat(path)
  if not stat then return nil, "PNG missing: " .. tostring(err) end
  if stat.size > limit then return nil, "PNG exceeds configured size limit" end
  local fd; fd, err = vim.uv.fs_open(path, "r", 384)
  if not fd then return nil, err end
  local data; data, err = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  return data, err
end

local function base_dir(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return vim.uv.cwd() end
  return vim.fs.dirname(vim.fs.normalize(name))
end

function M.request(session, markdown, options, callback)
  options = options or {}
  local cfg = config.get()
  session.request_serial = session.request_serial + 1
  local serial = session.request_serial
  local viewport = preview.viewport(session.preview_win, session.backend and session.backend.name)
  local root = cfg.security.document_root or base_dir(session.source_buf)
  local content_revision = ("%d:%d"):format(
    vim.api.nvim_buf_get_changedtick(session.source_buf), session.render_epoch or 0)
  local capture_only = options.capture_only == true and session.renderer_revision == content_revision
  local params = {
    documentId = session.document_id,
    contentRevision = content_revision,
    baseDir = base_dir(session.source_buf),
    documentRoot = root,
    viewport = viewport,
    scrollY = session.scroll_y or 0,
    captureScale = options.capture_scale or "device",
    scrollPastEnd = cfg.render.scroll_past_end,
    scrollPastEndOffsetPx = cfg.render.scroll_past_end_offset_px,
    theme = cfg.render.theme == "auto" and (vim.o.background == "dark" and "dark" or "light") or cfg.render.theme,
    rawHtml = cfg.render.raw_html,
    localImages = cfg.render.local_images,
    maxLocalImageBytes = cfg.render.max_local_image_bytes,
    network = cfg.security.network,
    browser = cfg.browser,
  }
  if not capture_only then params.markdown = markdown end
  local request_id = process.request(capture_only and "capture" or "render", params, function(result, err)
    if M.is_stale(session, serial) then
      if result and result.pngPath then vim.uv.fs_unlink(result.pngPath) end
      callback(nil, nil, true)
      return
    end
    if err and capture_only and tostring(err):match("capture cache missing") then
      local retry_options = vim.tbl_extend("force", {}, options, { capture_only = false })
      M.request(session, markdown, retry_options, callback)
      return
    end
    if err then callback(nil, err, false); return end
    if type(result) ~= "table" or type(result.pngPath) ~= "string" or type(result.blocks) ~= "table" then
      callback(nil, "invalid render result", false); return
    end
    local image, read_err = read_bytes(result.pngPath, cfg.render.max_png_bytes)
    vim.uv.fs_unlink(result.pngPath)
    if not image then callback(nil, read_err, false); return end
    session.applied_serial = serial
    session.renderer_revision = content_revision
    callback({ image = image, metadata = result, viewport = viewport }, nil, false)
  end)
  return request_id
end

return M
