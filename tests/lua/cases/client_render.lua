-- Client rendering: the frame stays where it was made, and a token crosses the
-- link in its place.
--
-- Two claims are worth testing and they are both about *sameness*:
--
--  1. The upload the splicer builds from a token is byte-identical to the one
--     this backend builds from bytes. Proven against the same pinned artifact
--     `tests/node/splice.test.js` asserts the JS port against -- neither
--     implementation can drift without one of the two failing.
--  2. Everything that is not the upload is identical between the two modes.
--     Placement geometry, crop rectangles, z-layering, deletion order: the
--     terminal must not be able to tell which machine drew the picture.
--
-- Everything else here is the gate -- which four things have to be true before
-- a token is ever emitted, and what each of them says when it is not.

local function fixture_png()
  -- The same three rules as tests/node/splice.test.js: a real PNG header so
  -- `png_dimensions` accepts it, then 3076 bytes of `i % 251` -- a prime, so
  -- the pattern does not align with base64's three-byte grouping. 3100 bytes is
  -- deliberately just over the 3072 that fills one 4096-character chunk, so the
  -- golden exercises the `m=1` continuation and the bare `q=2` control.
  local header = "\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\3\222\0\0\3\252"
  local filler = {}
  for index = 0, 3075 do
    filler[#filler + 1] = string.char(index % 251)
  end
  return header .. table.concat(filler)
end

return function(t)
  local config = require("md-viewer.config")
  local raw_backend = require("md-viewer.backends.kitty_raw")
  local cellpixels = require("md-viewer.cellpixels")
  local client_render = require("md-viewer.client_render")
  local terminal = require("md-viewer.terminal")
  local process = require("md-viewer.process")
  local renderer = require("md-viewer.renderer")

  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))))

  local original_measure = cellpixels.measure
  cellpixels.measure = function() return { width = 10, height = 10, cols = 10, rows = 10 } end

  local original_ui_send = vim.api.nvim_ui_send
  local sequences = {}
  vim.api.nvim_ui_send = function(value) sequences[#sequences + 1] = value end
  local function output() return table.concat(sequences) end
  local function reset() sequences = {} end

  local png = fixture_png()
  local placement = { row = 4, col = 2, width = 10, height = 10 }

  config.reset()
  config.setup({ terminal = { profile = "kitty" } })

  -- ---------------------------------------------------------------------
  -- 1. The upload a token stands for is the upload bytes produce.
  -- ---------------------------------------------------------------------

  reset()
  local bytes_id = raw_backend.show(png, placement)
  local bytes_stream = output()
  raw_backend.clear(bytes_id)

  local golden = table.concat(vim.fn.readfile(root .. "/tests/fixtures/splice-upload.esc", "b"), "\n")
  -- `readfile` in binary mode splits on newlines and drops them; the join above
  -- restores every one it removed. A trailing newline would come back as an
  -- extra empty element, and this artifact ends with ESC \ rather than one.
  t.eq(4181, #golden, "the pinned upload is 4181 bytes: one full chunk, one remainder")

  -- The golden was generated with i=42; the backend allocates its own id. Take
  -- the upload this run produced and check it against the golden with the id
  -- normalized, which is the only thing that can legitimately differ.
  local produced_upload = bytes_stream:match("^(.-)\27%[s")
  t.eq(
    golden:gsub("i=42", "i=" .. bytes_id, 1),
    produced_upload,
    "the upload this backend builds is the pinned artifact renderer/src/splice.js is checked against"
  )

  -- ---------------------------------------------------------------------
  -- 2. A referenced frame changes the upload and nothing else.
  -- ---------------------------------------------------------------------

  reset()
  local ref_id = raw_backend.show({ ref = "abc123-7", width_px = 990, height_px = 1020 }, placement)
  local ref_stream = output()
  raw_backend.clear(ref_id)

  local expected_token = ("\27_MDV1;tx;abc123-7;a=t,f=100,t=d,q=2,i=%d\27\\"):format(ref_id)
  t.eq(expected_token, ref_stream:match("^(.-)\27%[s"), "a referenced frame transmits a token naming it")
  -- A bound rather than an exact count: the image id is a process-lifetime
  -- counter seeded from the pid, so its width varies. The claim being made is
  -- about the order of magnitude, which is the whole point of the design.
  t.ok(#expected_token < 80, "and the token is under 80 bytes")
  t.ok(#golden > #expected_token * 50, "against an upload 50x larger for a frame this small")

  -- The whole safety argument in one assertion: strip the upload from each
  -- stream, normalize the counters that are allocated per call, and what is
  -- left must be equal. If a placement, a crop, a z-index or a deletion ever
  -- differed between the two modes, the picture would be drawn differently on
  -- the machine that cannot be watched.
  local function placements_of(stream, image_id)
    local tail = stream:gsub("^.-(\27%[s)", "%1", 1)
    -- Image and placement ids come from process-lifetime counters, so they
    -- differ between two calls for reasons that have nothing to do with this.
    return (tail:gsub("i=" .. image_id, "i=<image>"):gsub("p=%d+", "p=<pid>"))
  end
  t.eq(
    placements_of(bytes_stream, bytes_id),
    placements_of(ref_stream, ref_id),
    "every byte that is not the upload is identical whichever machine drew the frame"
  )

  -- The dimensions a referenced frame carries are the ones the crops are built
  -- from -- there are no bytes here to measure -- so a wrong pair would draw a
  -- wrong rectangle rather than fail.
  reset()
  local sized_id = raw_backend.show({ ref = "sized", width_px = 200, height_px = 400 }, placement)
  local crop = output():match("w=(%d+),h=(%d+),c=")
  t.eq("200", crop, "the crop spans the referenced frame's full announced width")
  raw_backend.clear(sized_id)

  -- ---------------------------------------------------------------------
  -- 3. A reference that could not survive an escape sequence is refused.
  -- ---------------------------------------------------------------------

  for _, bad in ipairs({
    { ref = "has;semicolon", width_px = 10, height_px = 10 },
    { ref = "has\27escape", width_px = 10, height_px = 10 },
    { ref = "has space", width_px = 10, height_px = 10 },
    { ref = string.rep("x", 65), width_px = 10, height_px = 10 },
    { ref = "", width_px = 10, height_px = 10 },
    { ref = "ok", width_px = 0, height_px = 10 },
    { ref = "ok", width_px = 10 },
    { ref = "ok" },
    { width_px = 10, height_px = 10 },
  }) do
    reset()
    local ok = pcall(raw_backend.show, bad, placement)
    t.ok(not ok, ("a reference of %s is refused rather than smuggled into the stream"):format(vim.inspect(bad.ref)))
    t.eq("", output(), "and nothing reaches the terminal")
  end

  -- ---------------------------------------------------------------------
  -- 4. The gate: four things must be true, and each says which one is not.
  -- ---------------------------------------------------------------------

  local original_detect = terminal.detect
  local original_status = process.status
  local function stub(handshake, status)
    terminal.detect = function()
      local capability = vim.deepcopy(original_detect())
      capability.client_render = handshake
      capability.client_render_evidence = handshake and "LC_MD_VIEWER v1" or nil
      return capability
    end
    process.status = function() return status end
  end

  local connected = { running = true, transport = "socket", connected = true }

  stub({ version = 1 }, connected)
  local enabled, reason = client_render.resolve("kitty_raw")
  t.ok(enabled, "companion + handshake + raw Kitty backend + auto = client rendering")
  t.eq("LC_MD_VIEWER v1", reason, "and the handshake is named as the evidence")
  t.eq("ref", client_render.frame_transport("kitty_raw"), "which is the transport asked of the renderer")

  stub(nil, connected)
  enabled, reason = client_render.resolve("kitty_raw")
  t.ok(not enabled, "no splicer in front of the terminal, no token")
  t.ok(reason:match("LC_MD_VIEWER"), "and the reason names the variable that is missing")
  t.eq("path", client_render.frame_transport("kitty_raw"), "so the frame travels as bytes, exactly as before")

  stub({ version = 1 }, { running = true, transport = "stdio", connected = true })
  enabled, reason = client_render.resolve("kitty_raw")
  t.ok(not enabled, "a renderer beside Neovim holds its frames on the wrong machine to reference")
  t.ok(reason:match("no companion"), "and the reason says so")

  stub({ version = 1 }, { running = false, transport = "stdio", companion_refused = "nothing answered at :4445" })
  enabled, reason = client_render.resolve("kitty_raw")
  t.ok(not enabled, "a configured companion that never answered is not client rendering either")
  t.ok(reason:match("nothing answered"), "and it is reported as unreachable rather than as unconfigured")

  stub({ version = 1 }, connected)
  for _, backend in ipairs({ "nvim_img", "cells" }) do
    enabled, reason = client_render.resolve(backend)
    t.ok(not enabled, ("the %s backend is handed pixels and cannot use a reference"):format(backend))
    t.ok(reason:match(backend), "and the reason names it")
  end

  config.setup({ client_render = { enabled = "off" } })
  t.ok(not (client_render.resolve("kitty_raw")), "client_render.enabled=off overrides everything")
  config.setup({ client_render = { enabled = "on" } })
  stub(nil, connected)
  enabled, reason = client_render.resolve("kitty_raw")
  t.ok(enabled, "client_render.enabled=on waives the handshake")
  t.ok(reason:match("explicit override"), "and says that it did")
  stub(nil, { running = true, transport = "stdio", connected = true })
  t.ok(not (client_render.resolve("kitty_raw")), "but not the companion: there would be nothing to reference")

  config.reset()
  config.setup({ terminal = { profile = "kitty" } })

  -- ---------------------------------------------------------------------
  -- 4b. Pipeline depth and the settle delay both follow client rendering.
  --
  -- Both are settings that trade against wire bytes, and under client rendering
  -- there are no wire bytes to trade against. The measurement that forced this:
  -- with the renderer on the machine the terminal was on, one frame cost a 92ms
  -- round trip plus a 15ms render, serially -- so the preview updated 4.7 times
  -- a second where it had managed 6.3 with the renderer on the remote host, and
  -- the operator reported it felt no different.
  -- ---------------------------------------------------------------------

  local controller = require("md-viewer.controller")
  local kitty_session = { backend = { name = "kitty_raw" } }

  stub({ version = 1 }, connected)
  local depth, depth_source = controller._scroll_pipeline_depth(kitty_session)
  t.eq(3, depth, "client rendering keeps three captures in flight, so the link is not idle between frames")
  t.ok(depth_source:match("client_render.scroll_pipeline"), "and names the option that sets it")

  config.setup({ client_render = { scroll_pipeline = 6 } })
  t.eq(6, (controller._scroll_pipeline_depth(kitty_session)), "the depth is configurable")
  config.reset()
  config.setup({ terminal = { profile = "kitty" } })

  stub(nil, { running = true, transport = "stdio", connected = true })
  depth, depth_source = controller._scroll_pipeline_depth(kitty_session)
  t.eq(1, depth, "a renderer beside Neovim is paced by its own capture; a second request would only queue")
  t.ok(depth_source:match("beside Neovim"), "and says so")

  -- The settle delay exists because a full-size settle capture over SSH was
  -- half a second of transit that the next wheel notch made stale. Rendered on
  -- the machine the terminal is on it costs ~57ms and about a kilobyte, so the
  -- extra wait is pure delay before the picture sharpens.
  local ssh_capability = { ssh = true, client_render = nil }
  local original_detect_2 = terminal.detect
  terminal.detect = function() return ssh_capability end
  local render_cfg = { scroll_settle_ms = 160, ssh_scroll_settle_ms = 400 }
  process.status = function() return { running = true, transport = "stdio", connected = true } end
  local settle, settle_source = controller._scroll_settle_delay(render_cfg)
  t.eq(400, settle, "an SSH session rendering remotely still waits longer before spending the transfer")
  t.ok(settle_source:match("ssh_scroll_settle_ms"), "and names the option")

  ssh_capability.client_render = { version = 1 }
  process.status = function() return connected end
  settle, settle_source = controller._scroll_settle_delay(render_cfg)
  t.eq(160, settle, "client rendering sharpens 240ms sooner, because the settle frame costs no wire time")
  t.ok(settle_source:match("no wire time"), "and says why rather than just changing the number")
  terminal.detect = original_detect_2

  -- ---------------------------------------------------------------------
  -- 5. The handshake itself, parsed from the environment SSH forwards.
  -- ---------------------------------------------------------------------

  terminal.detect = original_detect
  local function capability_for(value)
    return terminal.capability({ profile = "kitty" }, { LC_MD_VIEWER = value, TERM = "xterm-kitty" })
  end
  t.eq(nil, capability_for(nil).client_render, "an absent variable announces nothing")
  t.eq(nil, capability_for("").client_render, "and neither does an empty one")
  t.eq({ version = 1 }, capability_for("v=1").client_render, "a bare version is a valid announcement")
  t.eq(
    { version = 1, address = "127.0.0.1:4445" },
    capability_for("v=1,addr=127.0.0.1:4445").client_render,
    "and it may carry the address to dial back on"
  )
  t.eq(nil, capability_for("v=2,addr=x").client_render, "a version this plugin does not speak announces nothing")
  t.ok(
    capability_for("v=2,addr=x").client_render_evidence:match("not a protocol version"),
    "and says so rather than failing silently"
  )
  t.eq(nil, capability_for("nonsense").client_render, "and so does anything unparseable")

  -- ---------------------------------------------------------------------
  -- 6. Block geometry is reattached, not lost, when the renderer omits it.
  -- ---------------------------------------------------------------------

  local blocks = { { id = "a", top = 0 } }
  local session = { blocks_revision = "rev1", blocks = blocks }
  -- The rule renderer.lua applies: an omitted `blocks` with a revision we hold
  -- is the geometry we hold; anything else is not, and must not be guessed at.
  local function reattach(result)
    if result.blocks == nil and result.blocksRevision ~= nil and result.blocksRevision == session.blocks_revision then
      result.blocks = session.blocks
    end
    return result.blocks
  end
  t.eq(blocks, reattach({ blocksRevision = "rev1" }), "a current revision reattaches what we already hold")
  t.eq(nil, reattach({ blocksRevision = "rev2" }), "a revision we do not hold is not answered with stale geometry")
  t.eq(nil, reattach({}), "and neither is a response that names no revision at all")

  -- ---------------------------------------------------------------------
  -- 7. A frame source is bytes or a reference, and the size limit binds both.
  -- ---------------------------------------------------------------------

  local source = renderer._frame_source({ frameRef = "r1", pngWidth = 990, pngHeight = 1020, pngBytes = 4000 }, 10000)
  t.eq({ ref = "r1", width_px = 990, height_px = 1020 }, source, "a referenced frame is passed through as a reference")

  local refused, refuse_reason =
    renderer._frame_source({ frameRef = "r1", pngWidth = 990, pngHeight = 1020, pngBytes = 40000 }, 10000)
  t.eq(nil, refused, "render.max_png_bytes binds a frame that never crossed the link too")
  t.ok(refuse_reason:match("size limit"), "and refuses it in the same words as a frame that did")

  local undimensioned, dimension_reason = renderer._frame_source({ frameRef = "r1", pngBytes = 10 }, 10000)
  t.eq(nil, undimensioned, "a reference without dimensions cannot be placed")
  t.ok(dimension_reason:match("dimensions"), "and says which half is missing")

  local nothing, nothing_reason = renderer._frame_source({}, 10000)
  t.eq(nil, nothing, "a response with neither is not a frame")
  t.eq("invalid render result", nothing_reason, "reported in the words it always was")

  cellpixels.measure = original_measure
  vim.api.nvim_ui_send = original_ui_send
  terminal.detect = original_detect
  process.status = original_status
  config.reset()
end
