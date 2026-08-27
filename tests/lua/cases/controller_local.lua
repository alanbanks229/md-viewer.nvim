-- Controller local mode, end to end against a fake helper: attach on open,
-- prepare-over-stdio + render-over-socket with the frame marker emitted in
-- the same tick, scroll as one marker and nothing else, the pushed-asset
-- completion path, the missing-revision NACK, presented consumption, and the
-- demotion back to direct bytes.
--
-- The headline assertion is the byte-flow invariant: across the whole
-- scripted local session, no `nvim_ui_send` write contains a PNG payload or
-- an upload command. That is the structural proof that local mode removed
-- raster bytes and the per-frame request/response cycle from the remote
-- terminal stream -- the two documented failures of the rejected experiment.
--
-- Ordering note: this case relies on the localrender listeners the
-- controller registered at setup time, so it must run before any case that
-- calls `localrender._reset()` (local_transport.lua does; it sorts later).

return function(t)
  local backends = require("md-viewer.backends")
  local cellpixels = require("md-viewer.cellpixels")
  local config = require("md-viewer.config")
  local controller = require("md-viewer.controller")
  local localrender = require("md-viewer.localrender")
  local process = require("md-viewer.process")
  local resident_session = require("md-viewer.resident_session")
  local raw = require("md-viewer.backends.kitty_raw")

  -- -- rig -------------------------------------------------------------------

  local real_measure = cellpixels.measure
  cellpixels.measure = function() return { width = 10, height = 10, cols = 10, rows = 10 } end
  local real_select = backends.select
  backends.select = function() return backends.get("kitty_raw"), "forced: this case tests the raw local contract" end

  local tmp = vim.fn.tempname()
  local sock_dir = tmp .. "/md-viewer"
  vim.fn.mkdir(sock_dir, "p")
  vim.uv.fs_chmod(sock_dir, 448)
  local real_runtime = vim.env.XDG_RUNTIME_DIR
  vim.env.XDG_RUNTIME_DIR = tmp

  local TOKEN = ("ab"):rep(16)
  local helper = { requests = {}, renders = {}, assets = {}, client = nil }
  local sock_path = sock_dir .. "/r-c0ffee.sock"
  do
    local server = vim.uv.new_pipe(false)
    assert(server:bind(sock_path))
    vim.uv.fs_chmod(sock_path, 384)
    server:listen(16, function(err)
      assert(not err, err)
      local client = vim.uv.new_pipe(false)
      server:accept(client)
      helper.client = client
      local buffer = ""
      client:read_start(function(rerr, data)
        if rerr or not data then return end
        buffer = buffer .. data
        while true do
          local nl = buffer:find("\n", 1, true)
          if not nl then break end
          local line = buffer:sub(1, nl - 1)
          buffer = buffer:sub(nl + 1)
          local message = vim.json.decode(line, { luanil = { object = true } })
          helper.requests[#helper.requests + 1] = message
          if message.method == "hello" then
            helper.notify({
              id = message.id,
              ok = true,
              result = { protocol = localrender.PROTOCOL, helperVersion = "vtest", token = TOKEN, terminal = {} },
            })
          elseif message.method == "render" then
            -- Held for the test to answer: the marker-before-response
            -- assertion needs the response under manual control.
            helper.renders[#helper.renders + 1] = message
          elseif message.method == "asset" then
            helper.assets[#helper.assets + 1] = message
            helper.notify({ id = message.id, ok = true, result = { stored = #message.params.assets, refused = {} } })
          end
        end
      end)
    end)
    helper.server = server
  end
  function helper.notify(fields) helper.client:write(vim.json.encode(fields) .. "\n") end
  vim.env.MD_VIEWER_LOCAL_SOCKET = sock_path

  local writes = {}
  local real_ui_send = vim.api.nvim_ui_send
  vim.api.nvim_ui_send = function(bytes)
    writes[#writes + 1] = bytes
    -- The fake helper cannot see this terminal, so the rig answers the
    -- pairing probe for it -- the pairing mechanism itself is pinned by
    -- local_transport.lua.
    if bytes:find(";s=0;d=-;", 1, true) then
      vim.schedule(function()
        if helper.client then helper.notify({ event = "presented", seq = 0 }) end
      end)
    end
  end

  local notifications = {}
  local real_notify = vim.notify
  vim.notify = function(msg, level) notifications[#notifications + 1] = { msg = tostring(msg), level = level } end

  -- The stdio renderer, faked at the request seam. `prepare` wraps the
  -- markdown; `fetch_assets` serves one known sha; `render` (only reachable
  -- after demotion) writes a real-enough PNG file for the direct path.
  local SHA = ("cd"):rep(32)
  local ASSET_BYTES = "asset-bytes"
  local FAKE_PNG = "\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\0\100\0\0\0\100"
  local stdio_calls = {}
  local real_request_stdio = process.request_stdio
  process.request_stdio = function(method, params, callback)
    stdio_calls[#stdio_calls + 1] = { method = method, params = params }
    vim.schedule(function()
      if method == "prepare" then
        callback({
          html = "<main>" .. (params.markdown or "") .. "</main>",
          sourceMap = { blocks = {} },
          remoteImagesPending = false,
          assets = {},
        })
      elseif method == "fetch_assets" then
        callback({ assets = { { sha = SHA, mime = "image/png", data = vim.base64.encode(ASSET_BYTES) } }, unknown = {} })
      elseif method == "render" then
        local png_path = tmp .. "/direct.png"
        local file = io.open(png_path, "wb")
        file:write(FAKE_PNG)
        file:close()
        callback({
          pngPath = png_path,
          blocks = {},
          documentHeightPx = 900,
          viewportHeightPx = 450,
          scrollY = 0,
          captureScale = "device",
        })
      else
        callback(nil, "unexpected stdio method in local mode: " .. method)
      end
    end)
  end

  require("md-viewer").setup({ render = { location = "local" }, terminal = { profile = "kitty" } })

  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# Local", "", "body text" })
  local rev1 = ("%d:0"):format(vim.api.nvim_buf_get_changedtick(source))

  -- -- open: attach, then one marker and one prepare+render, same revision --

  local session = assert(controller.open("right"))
  vim.wait(4000, function() return #helper.renders >= 1 end, 10)
  t.eq(1, #helper.renders, "opening in local mode sends one render over the socket")
  t.eq(true, localrender.active(), "the open attached the helper")
  t.eq("viewport", session.render_path, "no resident path under local rendering")

  local function marker_writes()
    local found = {}
    for _, w in ipairs(writes) do
      if w:sub(1, 3) == "\27_M" and w:find("u=f", 1, true) then found[#found + 1] = w end
    end
    return found
  end

  -- The frame marker left before the render response existed -- the response
  -- is still sitting unanswered in `helper.renders`.
  local frames = marker_writes()
  t.eq(1, #frames, "exactly one frame marker, emitted in the request's own tick")
  t.ok(frames[1]:find("t=" .. TOKEN, 1, true), "the marker carries the session token")
  t.ok(frames[1]:find("d=buffer%-" .. source), "the marker names its document")
  t.ok(frames[1]:find("r=" .. rev1 .. ",y=0,", 1, true), "the reference is this revision at scroll 0")

  t.eq("prepare", stdio_calls[1].method, "markdown crossed stdio as a prepare")
  t.ok(stdio_calls[1].params.markdown:find("body text", 1, true), "prepare carries the raw markdown")
  t.eq(nil, stdio_calls[1].params.animate, "animation stays structurally off in local mode")
  local render_msg = helper.renders[1]
  t.eq(rev1, render_msg.params.contentRevision, "socket render names the same revision as the marker")
  t.ok(render_msg.params.html:find("body text", 1, true), "the socket carries prepared html")
  t.eq(nil, render_msg.params.markdown, "raw markdown never crosses the socket")
  t.eq(nil, render_msg.params.browser, "this host's browser config is not the helper's business")
  t.eq("device", render_msg.params.captureScale, "local frames are always device scale")

  helper.notify({
    id = render_msg.id,
    ok = true,
    result = { documentHeightPx = 2000, viewportHeightPx = 500, blocks = { {}, {} }, scrollY = 0, visualEpoch = 0 },
  })
  vim.wait(2000, function() return session.document_height_px == 2000 end, 10)
  t.eq(2000, session.document_height_px, "the response settles geometry")
  t.eq(2, #session.latest_blocks, "and blocks for source sync")
  t.eq(rev1, session.renderer_revision, "the revision is applied")
  t.eq(rev1, session.frame_revision, "the frame on glass is this revision's")

  -- -- scroll: one marker, no request, no settle timer ----------------------

  local stdio_before, renders_before = #stdio_calls, #helper.renders
  controller.navigate(session, "half_down")
  vim.wait(1000, function() return #marker_writes() >= 2 end, 10)
  local scrolled = marker_writes()[2]
  t.ok(scrolled:find("y=250,", 1, true), "the scroll marker names the new position")
  t.ok(scrolled:find("r=" .. rev1, 1, true), "against the frame's revision")
  local scroll_delete = vim.base64.decode(scrolled:match(";x=([%w+/=]*)\27\\$") or "")
  t.ok(scroll_delete:find("a=d", 1, true), "the superseded frame's deletion rides the marker")
  t.eq(250, session.applied_scroll_y, "the position is applied without waiting for anything")
  -- Longer than scroll_settle_ms (400 default): a settle capture would have
  -- landed by now if one were still scheduled.
  vim.wait(600)
  t.eq(stdio_before, #stdio_calls, "a local scroll sends no stdio request")
  t.eq(renders_before, #helper.renders, "and no socket render -- the marker is the whole of it")

  -- -- presented: glass confirmation retires the loading indicator ----------

  session.loading = true
  helper.notify({ event = "presented", seq = 3, doc = session.document_id, scrollY = 250 })
  vim.wait(2000, function() return (session.local_presented_count or 0) >= 1 end, 10)
  t.eq(1, session.local_presented_count, "presented notifications are consumed")
  t.ok(not session.loading, "a presented frame stops the loading indicator")

  -- -- K4: a presented ack against a stamped emit becomes a latency sample --

  local last_seq
  for _, w in ipairs(writes) do
    local s = w:match("^\27_Mv=1;t=" .. TOKEN .. ";s=(%d+);")
    if s then last_seq = tonumber(s) end
  end
  t.ok(last_seq and last_seq > 0, "the rig saw real marker seqs to acknowledge")
  helper.notify({ event = "presented", seq = last_seq, doc = session.document_id, scrollY = 250 })
  vim.wait(2000, function()
    local p = localrender.status().presented
    return p ~= nil and p.count >= 1
  end, 10)
  local presented_stats = localrender.status().presented
  t.ok(presented_stats and presented_stats.count >= 1, "marker emit -> presented ack is sampled")
  t.ok(presented_stats.p50_ms >= 0 and presented_stats.max_ms >= presented_stats.p50_ms, "the percentiles are ordered")

  -- -- moving tier: reduced-scale scroll markers, device-scale settle -------

  require("md-viewer").setup({
    render = { location = "local", scroll_scale = 0.5, scroll_settle_ms = 60 },
    terminal = { profile = "kitty" },
  })
  local device_c = marker_writes()[1]:match(",c=([%d.]+);")
  t.ok(device_c, "the base frame marker names its capture scale")
  local frames_before2 = #marker_writes()
  local stdio_before2, renders_before2 = #stdio_calls, #helper.renders
  controller.navigate(session, "half_down")
  vim.wait(1000, function() return #marker_writes() >= frames_before2 + 1 end, 10)
  local moving_frame = marker_writes()[frames_before2 + 1]
  t.ok(moving_frame:find(",c=0.5;", 1, true), "the scroll marker references the reduced moving scale")
  -- The settle re-reference is a second marker at the device factor -- still
  -- no request anywhere: sharpening the resting frame costs the helper one
  -- capture and the wire a few hundred bytes.
  vim.wait(2000, function() return #marker_writes() >= frames_before2 + 2 end, 10)
  local settle_frame = marker_writes()[frames_before2 + 2]
  t.ok(settle_frame:find(",c=" .. device_c .. ";", 1, true), "the settle marker restores the device scale")
  t.eq(
    moving_frame:match(",y=(%d+),"),
    settle_frame:match(",y=(%d+),"),
    "the settle re-references the same scroll position sharp"
  )
  t.eq(stdio_before2, #stdio_calls, "the moving/settle pair sent no stdio request")
  t.eq(renders_before2, #helper.renders, "and no socket render")
  require("md-viewer").setup({ render = { location = "local" }, terminal = { profile = "kitty" } })

  -- -- pushed assets: pending render completes through metrics --------------

  controller.refresh()
  local rev2 = ("%d:1"):format(vim.api.nvim_buf_get_changedtick(source))
  vim.wait(4000, function() return #helper.renders >= 2 end, 10)
  local pending_msg = helper.renders[2]
  t.eq(rev2, pending_msg.params.contentRevision, "an explicit refresh renders the bumped revision")
  helper.notify({
    id = pending_msg.id,
    ok = true,
    result = { pending = true, missingAssets = { SHA }, visualEpoch = 0 },
  })
  vim.wait(4000, function() return #helper.assets >= 1 end, 10)
  t.eq(1, #helper.assets, "missing assets were pushed over the socket")
  t.eq(SHA, helper.assets[1].params.assets[1].sha, "by content hash")
  t.eq(vim.base64.encode(ASSET_BYTES), helper.assets[1].params.assets[1].data, "with the stdio store's bytes")
  local fetched
  for _, call in ipairs(stdio_calls) do
    if call.method == "fetch_assets" then fetched = call end
  end
  t.ok(fetched and fetched.params.shas[1] == SHA, "the bytes came from a stdio fetch_assets")
  helper.notify({
    event = "metrics",
    doc = session.document_id,
    rev = rev2,
    documentHeightPx = 2600,
    viewportHeightPx = 500,
    blocks = { {}, {}, {} },
    scrollY = 250,
    visualEpoch = 0,
  })
  vim.wait(4000, function() return session.document_height_px == 2600 end, 10)
  t.eq(2600, session.document_height_px, "the pending render completed through the metrics notification")
  t.eq(rev2, session.renderer_revision, "at its own revision")

  -- -- missing NACK: a lost revision is re-rendered --------------------------

  local renders_before_nack = #helper.renders
  helper.notify({ event = "missing", doc = session.document_id, rev = rev2 })
  vim.wait(4000, function() return #helper.renders > renders_before_nack end, 10)
  t.ok(#helper.renders > renders_before_nack, "a missing NACK re-issues the render")
  local nack_render = helper.renders[#helper.renders]
  helper.notify({
    id = nack_render.id,
    ok = true,
    result = {
      documentHeightPx = 2600,
      viewportHeightPx = 500,
      blocks = { {}, {}, {} },
      scrollY = 250,
      visualEpoch = 0,
    },
  })
  vim.wait(2000, function() return not session.content_render_in_flight end, 10)

  -- -- interact display: a mutation is one frame marker at the new epoch ----

  session.visual_epoch = 1 -- what interaction.lua's funnel records from a mutating response
  local frames_before_interact = #marker_writes()
  controller.display_interact_result(
    session,
    { contentRevision = session.renderer_revision, scrollY = 40, visualEpoch = 1 }
  )
  local interact_frames = marker_writes()
  t.eq(frames_before_interact + 1, #interact_frames, "a PNG-less interact result displays as one frame marker")
  t.ok(
    interact_frames[#interact_frames]:find("y=40,e=1,", 1, true),
    "the marker carries the mutated epoch and the result's scroll"
  )
  t.eq(40, session.applied_scroll_y, "the interact's scroll position is applied")

  -- -- selection overlay: crops composite over a synthesized sheet ----------

  local writes_before_overlay = #writes
  local applied, overlay_reason = controller.display_selection_overlay(session, {
    rects = { { x = 4, y = 4, width = 30, height = 12 } },
    contentRevision = session.renderer_revision,
    scrollY = session.applied_scroll_y,
    selectionTint = { r = 58, g = 123, b = 213, a = 0.8 },
  })
  t.eq(true, applied, "the overlay applied without any sheet bytes: " .. tostring(overlay_reason))
  local sheet_write = writes[writes_before_overlay + 1]
  t.ok(
    sheet_write:find("u=s,", 1, true) and sheet_write:find("g=3a7bd5cc", 1, true),
    "the sheet crossed as a tint reference the helper synthesizes"
  )

  -- -- select_path: local rendering owns scrolling ---------------------------

  local path, reason = resident_session.select_path({ backend = raw })
  t.eq("viewport", path, "select_path never picks resident while local render is attached")
  t.eq("local render owns scrolling", reason, "and says why in the words health will show")

  -- -- the byte-flow invariant ----------------------------------------------

  for index, w in ipairs(writes) do
    t.ok(not w:find("iVBOR", 1, true), "no PNG base64 in any local-mode write (#" .. index .. ")")
    t.ok(not w:find("a=t", 1, true), "no upload command in any local-mode write (#" .. index .. ")")
  end

  -- -- demotion: helper dies, direct path takes over, once and loudly --------

  local writes_local = #writes
  helper.client:close()
  vim.wait(4000, function() return not localrender.active() end, 10)
  vim.wait(4000, function()
    for _, call in ipairs(stdio_calls) do
      if call.method == "render" then return true end
    end
    return false
  end, 10)
  vim.wait(4000, function() return #writes > writes_local and writes[#writes]:find("a=t", 1, true) ~= nil end, 10)
  t.eq("fallback", localrender.status().phase, "the helper dying demotes")
  local direct = writes[#writes]
  t.ok(direct:find("a=t", 1, true), "after demotion the direct upload path is back")
  t.ok(direct:find("iVBOR", 1, true), "carrying real pixels")
  t.ok(not direct:find("\27_M", 1, true), "and no markers")
  local demote_notified = false
  for _, note in ipairs(notifications) do
    if note.msg:find("rendering on this host", 1, true) then demote_notified = true end
  end
  t.ok(demote_notified, "the demotion said what happens next")

  -- -- teardown --------------------------------------------------------------

  controller.close(source)
  -- The overlay case warmed the backend's tint-sheet cache; later cases
  -- assert it cold.
  backends.get("kitty_raw").clear_all()
  helper.server:close()
  localrender._reset()
  process.request_stdio = real_request_stdio
  backends.select = real_select
  cellpixels.measure = real_measure
  vim.api.nvim_ui_send = real_ui_send
  vim.notify = real_notify
  vim.env.XDG_RUNTIME_DIR = real_runtime
  vim.env.MD_VIEWER_LOCAL_SOCKET = nil
  config.reset()
end
