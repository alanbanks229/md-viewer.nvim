-- Resident regions, end to end, against a real renderer and a real Chromium.
--
-- Every other resident case stubs the renderer, which is what makes them fast
-- and what makes them blind. The bugs this feature actually shipped were all in
-- the seam those stubs replace: a region planned at the wrong scale because the
-- scale was read off the last moving frame, a byte cap that fought the pixel
-- budget and won, a page that died and was never rebuilt. None of them are
-- visible to a test that answers its own requests.
--
-- What this cannot see is a pixel. What it can see is every number that decides
-- what the pixels will be, which is where the defects have actually been. The
-- one thing it fakes is the transport: `nvim_ui_send` is captured rather than
-- written, because there is no terminal here to draw into -- but the bytes are
-- the real ones the real backend produced.
--
-- Skips itself rather than failing when the renderer cannot start, following
-- the Node suite's convention for the same reason: a machine without Chromium
-- should report "not run", not "broken".
return function(t)
  local config = require("md-viewer.config")
  local controller = require("md-viewer.controller")
  local process = require("md-viewer.process")
  local state = require("md-viewer.state")
  local terminal = require("md-viewer.terminal")

  -- ---------------------------------------------------------------------
  -- Is there a renderer at all?
  -- ---------------------------------------------------------------------
  local ping_result, ping_error
  process.request("ping", {}, function(result, err)
    ping_result, ping_error = result, err
  end)
  vim.wait(15000, function() return ping_result ~= nil or ping_error ~= nil end, 20)
  if not (ping_result and ping_result.pong) then
    print("md-viewer: resident_e2e skipped -- no renderer (" .. tostring(ping_error) .. ")")
    return
  end

  config.reset()

  -- ---------------------------------------------------------------------
  -- Make this look like the only session the feature is enabled for: raw
  -- Kitty, over SSH, outside a multiplexer. The transport answer is the one
  -- thing a developer machine cannot be, and it is a single function.
  -- ---------------------------------------------------------------------
  local real_detect = terminal.detect
  terminal.detect = function()
    local capability = vim.deepcopy(real_detect())
    capability.ssh = true
    capability.ssh_evidence = "resident_e2e"
    capability.multiplexer = "none"
    return capability
  end

  -- Nothing may reach a real terminal, but the bytes are real: this is the
  -- backend's own output, counted exactly as the session counts it.
  local real_ui_send = vim.api.nvim_ui_send
  local emitted = {}
  vim.api.nvim_ui_send = function(value) emitted[#emitted + 1] = value end

  -- The backend refuses without an attached TUI, which a headless Neovim never
  -- has. That check is about whether escape sequences would reach anything, and
  -- here they deliberately do not -- they are captured above. Everything the
  -- backend computes on the way to producing them is unaffected, and it is the
  -- computation this case exists to exercise.
  local real_list_uis = vim.api.nvim_list_uis
  vim.api.nvim_list_uis = function()
    local uis = real_list_uis()
    if #uis > 0 then return uis end
    return { { chan = 1, height = 60, width = 200, rgb = true, ext_termcolors = true } }
  end

  local function restore()
    vim.api.nvim_ui_send = real_ui_send
    vim.api.nvim_list_uis = real_list_uis
    terminal.detect = real_detect
    config.reset()
  end

  local ok, err = pcall(function()
    require("md-viewer").setup({
      image = { backend = "kitty_raw", resident_pan = "on" },
      -- The settle is what becomes a region fill, so a long one would make this
      -- case spend most of its time waiting. Everything it gates is unchanged.
      render = { scroll_settle_ms = 40, ssh_scroll_settle_ms = 40 },
    })

    -- A document several viewports long, and deliberately uniform: this case is
    -- about geometry, and content that compresses unevenly would make the byte
    -- assertions about the prose rather than about the mechanism.
    local source = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(source)
    vim.bo[source].filetype = "markdown"
    local lines = { "# Resident end to end", "" }
    for index = 1, 400 do
      lines[#lines + 1] = ("Paragraph %d. The quick brown fox jumps over the lazy dog."):format(index)
      lines[#lines + 1] = ""
    end
    vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)

    local session = assert(controller.open("right"))
    t.eq("kitty_raw", session.backend.name, "the raw Kitty backend is what this exercises")

    local function settled(predicate, label)
      local done = vim.wait(20000, predicate, 25)
      t.eq(true, done, label)
      return done
    end

    -- The first render has to land before anything else means anything.
    -- `viewport_width_px` rather than `document_height_px`: the latter is
    -- initialised to 0 on the session, so waiting on it returns immediately and
    -- everything after measures a preview that has not rendered yet.
    if not settled(function() return session.viewport_width_px ~= nil end, "the first render completes") then
      controller.close(source)
      return
    end
    t.ok(
      session.document_height_px > session.viewport_height_px * 3,
      ("the document is several viewports long (doc %s, viewport %sx%s)"):format(
        tostring(session.document_height_px),
        tostring(session.viewport_width_px),
        tostring(session.viewport_height_px)
      )
    )
    t.eq(
      true,
      session.resident.enabled,
      ("the session qualifies for resident regions (%s)"):format(tostring(session.resident.gate_reason))
    )

    -- ------------------------------------------------------------------
    -- A region fills, and it is the size the budget derived rather than the
    -- size a moving frame's scale would have implied.
    --
    -- This is the assertion that would have caught the scale defect. The
    -- settle fires once scrolling has stopped, so the frame on screen then is
    -- always a moving one captured at `ssh_scroll_scale`; reading the capture
    -- scale off it plans a region four times too tall, which is then refused
    -- by the renderer or by the cache and never becomes a region at all.
    -- ------------------------------------------------------------------
    local live = session.resident
    controller.scroll_to(session, math.floor(session.viewport_height_px * 1.5))
    vim.wait(20000, function() return #live.regions > 0 or live.fallback_reason ~= nil end, 25)
    t.ok(
      #live.regions > 0,
      ("a region fills after the settle (fills %d, refusal %s, fallback %s)"):format(
        live.fills,
        tostring(live.plan_refusal),
        tostring(live.fallback_reason)
      )
    )
    t.eq(nil, live.fallback_reason, "without falling back")
    t.eq(nil, live.plan_refusal, "and without the planner declining")

    local region = live.regions[1]
    t.ok(region ~= nil, "a region is resident")
    if region then
      t.ok(region.doc_h > session.viewport_height_px, "taller than the viewport, or it could never be a hit")
      t.ok(
        region.image_w * region.image_h <= live.budget_px,
        "and within the pixel budget, measured from the PNG rather than predicted"
      )
      -- The scale the region was actually captured at, against the scale the
      -- session is calibrated for. A region planned from a reduced moving frame
      -- comes back at twice the assumed scale and blows the budget.
      t.near(
        config.get().render.device_scale_factor,
        region.image_w / session.viewport_width_px,
        0.01,
        "captured at the device scale, not at the moving frame's reduced one"
      )
    end
    t.eq(1, live.height_scale, "and the byte cap did not fight the budget for it")

    -- ------------------------------------------------------------------
    -- The claim: a scroll inside the region costs a placement and no pixels.
    -- ------------------------------------------------------------------
    if region then
      local first, last = require("md-viewer.resident").pan_range(region, session.viewport_height_px)
      t.ok(first ~= nil and last > first, "the region has usable travel")

      local requests_before = session.request_serial
      local uploads_before = live.upload_bytes
      emitted = {}

      -- Somewhere inside the range that is not where it was filled.
      local target = math.floor(first + (last - first) * 0.5)
      controller.scroll_to(session, target)
      vim.wait(200, function() return false end, 25)

      t.eq(requests_before, session.request_serial, "a scroll inside the region asks the renderer for nothing")
      t.eq(uploads_before, live.upload_bytes, "and uploads no pixels")
      t.ok(live.hits > 0, "it is counted as a hit")

      local stream = table.concat(emitted)
      t.eq(nil, stream:match("\27_Ga=t"), "nothing on the wire is an image upload")
      t.ok(stream:match("\27_Ga=p") ~= nil, "what is on the wire is a placement")
      t.ok(#stream < 4096, ("a pan is %d bytes, which is placements rather than a frame"):format(#stream))

      -- The position recorded is the position the crop shows. Everything that
      -- reads `applied_scroll_y` -- the caret, the animation layer, every
      -- interact request -- is wrong by exactly as much as this is.
      t.near(target, session.applied_scroll_y, 1.0, "the recorded position is the one the pixels show")
    end

    -- ------------------------------------------------------------------
    -- The terminal cursor follows the caret across a pan.
    --
    -- No pixels needed: the block is a Neovim cursor position, which is a
    -- number. This is the case that was reported from a real session and could
    -- have been caught here.
    -- ------------------------------------------------------------------
    if region then
      local caret = require("md-viewer.caret")
      local first, last = require("md-viewer.resident").pan_range(region, session.viewport_height_px)
      -- Less than a viewport, and from a caret low in the frame, so the caret
      -- moves *up* the screen without leaving it. A larger jump scrolls it off,
      -- where declining to move the cursor is correct behaviour rather than the
      -- defect -- there is no row left to put it on.
      local step = math.floor(session.viewport_height_px * 0.25)
      local low = math.floor(first)
      local high = math.min(math.floor(last), low + step)
      t.ok(high > low, "the region affords a sub-viewport pan to test the caret against")

      controller.scroll_to(session, low)
      vim.wait(150, function() return false end, 25)
      -- Three quarters of the way down the visible frame, so a quarter-viewport
      -- pan leaves it halfway down rather than off the top.
      caret.set_rect(
        session,
        { x = 0, y = math.floor(session.viewport_height_px * 0.75), width = 10, height = 20 },
        session.applied_scroll_y
      )
      local before_cursor = vim.api.nvim_win_get_cursor(session.preview_win)
      local before_applied, before_pans = session.applied_scroll_y, live.pans

      controller.scroll_to(session, high)
      vim.wait(150, function() return false end, 25)
      local after_cursor = vim.api.nvim_win_get_cursor(session.preview_win)

      t.ok(live.pans > before_pans, "sanity: that scroll was a pan")
      t.ok(
        math.abs((session.applied_scroll_y or 0) - (before_applied or 0)) > 1,
        ("sanity: the position moved (%s -> %s)"):format(tostring(before_applied), tostring(session.applied_scroll_y))
      )
      t.ok(
        require("md-viewer.caret").rect(session) ~= nil,
        ("sanity: the caret is still on screen after the pan (drift %s)"):format(
          tostring((session.applied_scroll_y or 0) - (session.caret_scroll_y or 0))
        )
      )

      -- Scrolling down moves content up the screen, so the caret's row must
      -- decrease. Staying put is the defect: the block sits on the row the
      -- caret occupied before the scroll while the overlay draws it where it is
      -- now, and a reader sees the cursor a line or more out of place.
      t.ok(
        after_cursor[1] < before_cursor[1],
        ("the shadow cursor follows a pan (row %d -> %d)"):format(before_cursor[1], after_cursor[1])
      )
    end

    controller.close(source)
    state.remove(source)
    pcall(vim.api.nvim_buf_delete, source, { force = true })
  end)

  restore()
  if not ok then error(err, 0) end
end
