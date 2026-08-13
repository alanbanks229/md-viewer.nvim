local config = require("md-viewer.config")
local process = require("md-viewer.process")
local preview = require("md-viewer.preview")
local security = require("md-viewer.security")
local client_render = require("md-viewer.client_render")

local M = {}

---Whether a response may still be displayed.
---
---`request_serial` is a session-wide "only the newest request may show a frame"
---gate, and it predates the renderer's own lane machinery by doing the same job
---one layer up. That is correct as long as exactly one request is ever in
---flight, and it silently defeats pipelining otherwise: three concurrent
---captures take serials N, N+1 and N+2, so N and N+1 are discarded on arrival
---after the link has already carried them. Measured on the real link at depth 3
---it turned 41 displayed frames into 11 while the renderer did three times the
---work -- the pipelined arm was slower than the serial one, and visibly so.
---
---So a pipelined capture is measured against `claiming_serial` instead: the
---serial of the last request that *did* claim the session. Same rule as
---`admit` in renderer/src/lanes.js, for the same reason and with the same
---narrowness -- a close, a document change, or any ordinary render still
---invalidates every capture outstanding behind it.
function M.is_stale(session, serial, pipelined)
  if session.closed then return true end
  if pipelined then return serial <= (session.claiming_serial or 0) end
  return serial ~= session.request_serial
end

---Invalidate everything in flight for this session.
---
---One function so a caller cannot bump the serial and forget the claim, which
---would leave pipelined captures from before a document change still eligible
---to draw over the document that replaced it.
function M.invalidate(session)
  session.request_serial = session.request_serial + 1
  session.claiming_serial = session.request_serial
end

---Read a PNG produced by the renderer, enforcing the configured size limit.
---Exported (not a private `read_bytes` local) so `controller.lua`'s
---`display_interact_result` can fetch an interact response's PNG the same way
---`M.request`'s own render/capture path does, without a second copy of this.
function M.read_png(path, limit)
  local stat, err = vim.uv.fs_stat(path)
  if not stat then return nil, "PNG missing: " .. tostring(err) end
  if stat.size > limit then return nil, "PNG exceeds configured size limit" end
  local fd
  fd, err = vim.uv.fs_open(path, "r", 384)
  if not fd then return nil, err end
  local data
  data, err = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  return data, err
end

---What the backend should be handed for one rendered frame.
---
---Two shapes, and every caller downstream treats them identically because
---`kitty_raw`'s `transmit` is the only thing that can tell them apart:
---
---  * PNG bytes, read from the temp file the renderer wrote and then deleted --
---    what this has always done, and what a renderer running beside Neovim
---    still does.
---  * `{ ref, width_px, height_px }`, naming a frame the renderer is holding on
---    the machine the terminal is on. Nothing is read, because there is nothing
---    here to read: the pixels never crossed the link.
---
---The configured size limit is enforced on both. On the reference path the
---bytes are not in hand, so it is checked against the size the renderer
---reported -- which is the same number, from the same buffer.
local function frame_source(result, limit)
  if type(result.frameRef) == "string" then
    if type(result.pngWidth) ~= "number" or type(result.pngHeight) ~= "number" then
      return nil, "renderer returned a frame reference without its dimensions"
    end
    if type(result.pngBytes) == "number" and result.pngBytes > limit then
      return nil, "PNG exceeds configured size limit"
    end
    return { ref = result.frameRef, width_px = result.pngWidth, height_px = result.pngHeight }
  end
  if type(result.pngPath) ~= "string" then return nil, "invalid render result" end
  local image, read_err = M.read_png(result.pngPath, limit)
  vim.uv.fs_unlink(result.pngPath)
  return image, read_err
end

M._frame_source = frame_source

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
  -- A pipelined scroll capture is one of several the caller intends to display;
  -- anything else is the newest thing this session wants and supersedes what
  -- came before it.
  if not options.pipelined then session.claiming_serial = serial end
  local viewport = preview.viewport(session.preview_win, session.backend and session.backend.name)
  -- One root, one implementation. This used to compute its own
  -- (`cfg.security.document_root or base_dir(...)`), which skipped the
  -- normalization and the project-root detection that the link path gets --
  -- so a local image and a local link disagreed about the same boundary.
  local root =
    security.document_root(session.source_buf, cfg.security.document_root, cfg.security.document_root_markers)
  local content_revision = ("%d:%d"):format(
    vim.api.nvim_buf_get_changedtick(session.source_buf),
    session.render_epoch or 0
  )
  local capture_only = options.capture_only == true and session.renderer_revision == content_revision
  local params = {
    documentId = session.document_id,
    contentRevision = content_revision,
    baseDir = base_dir(session.source_buf),
    documentRoot = root,
    viewport = viewport,
    scrollY = session.scroll_y or 0,
    captureScale = options.capture_scale or "device",
    -- The tier above says which of the two frames this is; this says how much
    -- of its natural size to actually capture. Absent on everything but a
    -- moving scroll frame, and ignored by the renderer on the "device" tier --
    -- see `captureViewportPng` for why the settle frame is never scaled.
    captureScaleFactor = options.capture_scale_factor,
    fontSizePx = cfg.render.font_size_px,
    scrollPastEnd = cfg.render.scroll_past_end,
    scrollPastEndOffsetPx = cfg.render.scroll_past_end_offset_px,
    theme = cfg.render.theme == "auto" and (vim.o.background == "dark" and "dark" or "light") or cfg.render.theme,
    rawHtml = cfg.security.raw_html,
    localImages = cfg.render.local_images,
    maxLocalImageBytes = cfg.render.max_local_image_bytes,
    -- Whether animated GIFs are marked for the terminal to draw. It joins the
    -- render request rather than the animation one because it changes the
    -- markup -- an animated image carries an opaque animation id or it does
    -- not -- and the renderer's markdown cache keys on it.
    animate = cfg.render.animate == true,
    browser = cfg.browser,
  }
  -- Absent on every session that is not client rendering, so the request is
  -- byte-identical to what it was before this existed.
  local transport, transport_reason = client_render.frame_transport(session.backend and session.backend.name)
  session.client_render_reason = transport_reason
  if transport == "ref" then
    params.frameTransport = "ref"
    -- Block geometry is identical on every frame of a scroll and is ~10KB of
    -- it, so on a link where the pixels have stopped travelling it would
    -- otherwise become the largest thing that still does. Naming what we hold
    -- is what lets the renderer send nothing back.
    params.knownBlocksRevision = session.blocks_revision
  end
  -- Several scroll captures may be outstanding at once across a link, and each
  -- is a distinct position the reader passed through rather than a stale one to
  -- be cancelled. Absent everywhere else, so the request a local session sends
  -- is unchanged.
  if options.pipelined then params.pipelined = true end
  if not capture_only then params.markdown = markdown end
  local request_id = process.request(capture_only and "capture" or "render", params, function(result, err)
    if M.is_stale(session, serial, options.pipelined) then
      if result and result.pngPath then vim.uv.fs_unlink(result.pngPath) end
      callback(nil, nil, true)
      return
    end
    if err and capture_only and tostring(err):match("capture cache missing") then
      local retry_options = vim.tbl_extend("force", {}, options, { capture_only = false })
      M.request(session, markdown, retry_options, callback)
      return
    end
    if err then
      callback(nil, err, false)
      return
    end
    if type(result) ~= "table" then
      callback(nil, "invalid render result", false)
      return
    end
    -- The renderer omits block geometry it knows we already hold, so reattach
    -- what we hold here -- in the one place that knows the revision -- and
    -- every caller downstream still receives a complete result. A response
    -- naming a revision we do not have is a bug in this bookkeeping rather than
    -- something to paper over, so it falls through to the check below.
    if result.blocks == nil and result.blocksRevision ~= nil and result.blocksRevision == session.blocks_revision then
      result.blocks = session.blocks
    end
    if type(result.blocks) ~= "table" then
      callback(nil, "invalid render result", false)
      return
    end
    local image, read_err = frame_source(result, cfg.render.max_png_bytes)
    if not image then
      callback(nil, read_err, false)
      return
    end
    session.applied_serial = serial
    session.renderer_revision = content_revision
    session.blocks_revision, session.blocks = result.blocksRevision, result.blocks
    callback({ image = image, metadata = result, viewport = viewport }, nil, false)
  end)
  return request_id
end

return M
