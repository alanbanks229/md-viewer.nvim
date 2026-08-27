local config = require("md-viewer.config")
local localrender = require("md-viewer.localrender")
local process = require("md-viewer.process")
local preview = require("md-viewer.preview")
local security = require("md-viewer.security")

local M = {}

function M.is_stale(session, serial) return session.closed or serial ~= session.request_serial end

---The revision every request, cache key and frame reference names. Exported
---because local mode's frame marker is emitted by the controller in the same
---tick the request goes out, and the two must not compute this twice
---differently.
function M.content_revision(session)
  return ("%d:%d"):format(vim.api.nvim_buf_get_changedtick(session.source_buf), session.render_epoch or 0)
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

local function base_dir(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return vim.uv.cwd() end
  return vim.fs.dirname(vim.fs.normalize(name))
end

-- -- the local-mode request path -------------------------------------------
--
-- In local mode a render is two hops instead of one: `prepare` on this
-- machine's stdio renderer (markdown -> sanitized html + content-addressed
-- asset refs; the whole security pipeline, no Chromium), then `render` with
-- the prepared html over the control socket to the helper beside the
-- terminal. No PNG exists anywhere in it. The frame's pixels are the frame
-- marker's business -- the controller emitted it in the same tick this was
-- called -- so this response carries only geometry, blocks and the visual
-- epoch, and nothing here waits on pixels.

-- Renders whose assets the helper was missing complete through an id-less
-- `metrics` notification once the pushed bytes arrive, keyed by document and
-- revision. One waiter per key: a newer render for the same revision simply
-- replaces the older's continuation.
local pending_metrics = {}
local metrics_hooked = false
local ASSET_TIMEOUT_MS = 30000

local function ensure_metrics_hook()
  if metrics_hooked then return end
  metrics_hooked = true
  localrender.on("metrics", function(event)
    local key = tostring(event.doc) .. "\0" .. tostring(event.rev)
    local waiter = pending_metrics[key]
    if waiter then
      pending_metrics[key] = nil
      waiter(event)
    end
  end)
end

local function await_metrics(session, serial, doc, rev, on_metrics, callback)
  ensure_metrics_hook()
  local key = tostring(doc) .. "\0" .. tostring(rev)
  local timer = vim.uv.new_timer()
  local function settle()
    timer:stop()
    if not timer:is_closing() then timer:close() end
  end
  local waiter
  waiter = function(event)
    settle()
    on_metrics(event)
  end
  pending_metrics[key] = waiter
  timer:start(ASSET_TIMEOUT_MS, 0, function()
    settle()
    vim.schedule(function()
      -- Only this waiter's own timeout may clear it; a newer render for the
      -- same revision has replaced the entry with its own continuation.
      if pending_metrics[key] ~= waiter then return end
      pending_metrics[key] = nil
      if M.is_stale(session, serial) then return end
      callback(nil, "local render timed out waiting for pushed assets", false)
    end)
  end)
end

local function request_local(session, markdown, options, callback, ctx)
  local cfg, serial, viewport, revision = ctx.cfg, ctx.serial, ctx.viewport, ctx.revision
  process.request_stdio("prepare", {
    documentId = session.document_id,
    contentRevision = revision,
    markdown = markdown,
    baseDir = base_dir(session.source_buf),
    documentRoot = ctx.root,
    rawHtml = cfg.security.raw_html,
    localImages = cfg.render.local_images,
    maxLocalImageBytes = cfg.render.max_local_image_bytes,
  }, function(prepared, prepare_err)
    if M.is_stale(session, serial) then return callback(nil, nil, true) end
    if prepare_err then return callback(nil, prepare_err, false) end
    if type(prepared) ~= "table" or type(prepared.html) ~= "string" then
      return callback(nil, "invalid prepare result", false)
    end
    local remote_pending = prepared.remoteImagesPending == true
    local requested_scroll = session.scroll_y or 0
    local function finish(metrics)
      if M.is_stale(session, serial) then return callback(nil, nil, true) end
      session.applied_serial = serial
      session.renderer_revision = revision
      callback({
        metadata = {
          local_render = true,
          requestedScrollY = requested_scroll,
          blocks = metrics.blocks or {},
          documentHeightPx = metrics.documentHeightPx,
          viewportHeightPx = metrics.viewportHeightPx,
          scrollY = metrics.scrollY,
          visualEpoch = metrics.visualEpoch,
          captureScale = "device",
          remoteImagesPending = remote_pending,
        },
        viewport = viewport,
      }, nil, false)
    end
    -- `process.request` routes over the socket while attached. The browser
    -- config is deliberately not forwarded: it describes this machine's
    -- browser, and a VM executable path handed to the laptop would break the
    -- helper's own discovery.
    process.request("render", {
      documentId = session.document_id,
      contentRevision = revision,
      html = prepared.html,
      sourceMap = prepared.sourceMap,
      remoteImagesPending = remote_pending,
      viewport = viewport,
      scrollY = requested_scroll,
      captureScale = "device",
      fontSizePx = cfg.render.font_size_px,
      scrollPastEnd = cfg.render.scroll_past_end,
      scrollPastEndOffsetPx = cfg.render.scroll_past_end_offset_px,
      theme = cfg.render.theme == "auto" and (vim.o.background == "dark" and "dark" or "light") or cfg.render.theme,
    }, function(result, render_err, meta)
      if M.is_stale(session, serial) then return callback(nil, nil, true) end
      if render_err then
        if meta and meta.code == "LOCAL_DISCONNECT" and not options.local_retry then
          -- The helper died between the controller's mode check and this
          -- write. The demotion has already restored the stdio transport, so
          -- one retry takes the direct path instead of failing the frame.
          local retry = vim.tbl_extend("force", {}, options, { local_retry = true })
          M.request(session, markdown, retry, callback)
          return
        end
        return callback(nil, render_err, false)
      end
      if type(result) ~= "table" then return callback(nil, "invalid local render result", false) end
      if result.pending then
        -- The helper is missing asset bytes. Register the continuation
        -- before pushing, so the metrics notification cannot race it; the
        -- bytes go content-addressed from the stdio renderer's store, which
        -- is the only path SECURITY.md allows them to travel.
        await_metrics(session, serial, session.document_id, revision, finish, callback)
        process.request_stdio("fetch_assets", { shas = result.missingAssets or {} }, function(fetched)
          if type(fetched) ~= "table" or type(fetched.assets) ~= "table" then return end
          process.request("asset", { assets = fetched.assets }, function() end)
        end)
        return
      end
      finish(result)
    end)
  end)
end

function M.request(session, markdown, options, callback)
  options = options or {}
  local cfg = config.get()
  session.request_serial = session.request_serial + 1
  local serial = session.request_serial
  local viewport = preview.viewport(session.preview_win, session.backend and session.backend.name)
  -- One root, one implementation. This used to compute its own
  -- (`cfg.security.document_root or base_dir(...)`), which skipped the
  -- normalization and the project-root detection that the link path gets --
  -- so a local image and a local link disagreed about the same boundary.
  local root =
    security.document_root(session.source_buf, cfg.security.document_root, cfg.security.document_root_markers)
  local content_revision = M.content_revision(session)
  if localrender.active() and session.backend and session.backend.name == "kitty_raw" then
    return request_local(session, markdown, options, callback, {
      cfg = cfg,
      serial = serial,
      viewport = viewport,
      root = root,
      revision = content_revision,
    })
  end
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
    -- A durable document chunk rather than a frame of the reader's viewport.
    -- Its clip is document-absolute, so it does not consult `scrollY` above and
    -- the reply echoes the region back for the caller to check.
    captureRegion = options.capture_region,
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
  if not capture_only then params.markdown = markdown end
  -- Explicitly the stdio child: while a local transport is attached, direct
  -- render/capture must not leak markdown to the helper (which could not
  -- serve it anyway -- it renders prepared html, never raw markdown).
  local request_id = process.request_stdio(capture_only and "capture" or "render", params, function(result, err)
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
    if err then
      callback(nil, err, false)
      return
    end
    if type(result) ~= "table" or type(result.pngPath) ~= "string" or type(result.blocks) ~= "table" then
      callback(nil, "invalid render result", false)
      return
    end
    local image, read_err = M.read_png(result.pngPath, cfg.render.max_png_bytes)
    vim.uv.fs_unlink(result.pngPath)
    if not image then
      callback(nil, read_err, false)
      return
    end
    session.applied_serial = serial
    session.renderer_revision = content_revision
    callback({ image = image, metadata = result, viewport = viewport }, nil, false)
  end)
  return request_id
end

return M
