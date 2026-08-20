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
      image = {
        backend = "kitty_raw",
        reuse_sent_pixels = "on",
        -- Stated rather than defaulted, so what this case holds is a property of
        -- the case: how many slices fit before the window starts sliding is the
        -- difference between "nothing is ever re-uploaded" and "everything is",
        -- and a default that moved would move that silently.
        resident_memory_mb = 4096,
      },
      -- The settle is what becomes a slice fill, so a long one would make this
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
    -- A slice fills, at the scale the capture will actually arrive at rather
    -- than the one a moving frame would have implied.
    --
    -- This is the assertion that would have caught the scale defect. The
    -- settle fires once scrolling has stopped, so the frame on screen then is
    -- always a moving one captured at `ssh_scroll_scale`; reading the capture
    -- scale off it builds a grid whose slices claim a quarter of the pixels
    -- they will really cost, so the ceiling is overrun fourfold.
    -- ------------------------------------------------------------------
    local resident = require("md-viewer.resident")
    local live = session.resident
    local function held() return resident.slice_records(live) end

    -- Every fill is accounted for, at every point in the session's life.
    --
    -- An identity rather than a counter, because a counter only catches the drop
    -- somebody thought to count. A real session reported 18 fills, 12 slices
    -- held, and `stale 0 / abandoned 0 / evictions 0` -- six captures, ~2.5 MB
    -- of wire, down a path with no counter on it, findable only by subtracting
    -- two numbers on opposite ends of the report. They had been *drained*: a
    -- viewport change invalidates the grid, which is correct, and nothing said
    -- what it cost.
    --
    -- `superseded_fills` is deliberately not a term. Those captures never
    -- reached the statement `fills` is counted at, and folding them in is
    -- exactly what made `stale_fills` two populations at once.
    local function reconcile(label)
      local accounted = #held()
        + live.stale_fills
        + live.abandoned_fills
        + live.undisplayed_fills
        + live.evictions
        + live.dropped_slices
      t.eq(
        live.fills,
        accounted,
        ("%s: %d fills == %d held + %d stale + %d abandoned + %d undisplayed + %d evicted + %d dropped"):format(
          label,
          live.fills,
          #held(),
          live.stale_fills,
          live.abandoned_fills,
          live.undisplayed_fills,
          live.evictions,
          live.dropped_slices
        )
      )
    end
    controller.scroll_to(session, math.floor(session.viewport_height_px * 0.5))
    vim.wait(20000, function() return #held() > 0 or live.fallback_reason ~= nil end, 25)
    t.ok(
      #held() > 0,
      ("a slice fills after the settle (fills %d, refusal %s, fallback %s)"):format(
        live.fills,
        tostring(live.grid_refusal),
        tostring(live.fallback_reason)
      )
    )
    t.eq(nil, live.fallback_reason, "without falling back")
    t.eq(nil, live.grid_refusal, "and without the grid declining")

    local grid = assert(controller._resident_grid(session))
    local region = held()[1]
    t.ok(region ~= nil, "a slice is resident")
    if region then
      t.eq(0, region.index, "the first fill occupies the cell the reader is in")
      t.ok(region.doc_h > session.viewport_height_px, "taller than the viewport, or it could never be a hit")
      t.ok(
        region.image_w * region.image_h <= live.memory_px,
        "and within the memory ceiling, measured from the PNG rather than predicted"
      )
      -- The scale the slice was actually captured at, against the scale the
      -- session is calibrated for. A grid planned from a reduced moving frame
      -- gets slices at twice the assumed scale and blows the ceiling.
      t.near(
        config.get().render.device_scale_factor,
        region.image_w / session.viewport_width_px,
        0.01,
        "captured at the device scale, not at the moving frame's reduced one"
      )
    end
    t.eq(1, live.slice_scale, "and the renderer took the slice at its full height")
    t.eq(0, live.evictions, "with nothing evicted, which on a document inside the ceiling must stay true")

    -- ------------------------------------------------------------------
    -- The base image every overlay is composited over is now the region.
    --
    -- This is the fact that turned a harmless over-requirement in
    -- `required_sheet_size` into a defect: it demanded a tint sheet as large as
    -- the *base image*, and once the base image became a capture several
    -- viewports tall, no sheet the renderer builds could satisfy it --
    -- `interaction.sheet_dims` sizes every one of them to a single viewport. The
    -- refusal itself is asserted in `backend_kitty.lua`, which can stub the
    -- measured cell the overlay path needs and a headless session cannot. What
    -- is asserted here is the part only a real session shows: that the image the
    -- overlay is handed is the tall one.
    -- ------------------------------------------------------------------
    if region then
      t.eq(region.image_id, session.image_id, "the image on screen is the region, so it is what an overlay sits on")
      t.ok(
        (session.image_height_px or 0) > (session.viewport_height_render_px or 0),
        ("and it is taller than a viewport (%s px of image against %s px of viewport)"):format(
          tostring(session.image_height_px),
          tostring(session.viewport_height_render_px)
        )
      )
    end

    -- ------------------------------------------------------------------
    -- The claim: a scroll inside the region costs a placement and no pixels.
    -- ------------------------------------------------------------------
    if region then
      local first, last = require("md-viewer.resident").pan_range(region, session.viewport_height_px)
      t.ok(first ~= nil and last > first, "the region has usable travel")

      local requests_before = session.request_serial
      local uploads_before = live.upload_bytes
      emitted = {}

      -- Somewhere inside the range that is not where it was filled. Whichever
      -- end is further, because a scroll to the position already displayed
      -- produces no event at all and would measure nothing.
      local at_now = session.applied_scroll_y or 0
      local target = math.abs(last - at_now) > math.abs(first - at_now) and math.floor(last) or math.floor(first)
      t.ok(math.abs(target - at_now) > 1, "sanity: that is a scroll rather than a no-op")
      controller.scroll_to(session, target)

      -- Measured with no wait at all, deliberately. A pan is synchronous inside
      -- `scroll_to`, so these are exactly the bytes the scroll itself cost --
      -- with neither the settle behind it nor the idle-time prefetch folded into
      -- the number. Both of those are real traffic and both are meant to happen;
      -- neither is what this claim is about.
      t.eq(requests_before, session.request_serial, "a scroll inside the slice asks the renderer for nothing")
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

    -- ------------------------------------------------------------------
    -- The claim the whole rebuild exists to make: a second pass over the same
    -- document sends no pixels at all.
    --
    -- The bounded region could not make it. Its edges moved with the reader, so
    -- crossing one evicted and refilled -- a real session recorded 14 fills and
    -- 13 evictions in 141 seconds, ~971 KB each, for 38% more traffic than
    -- sending a frame every time. A grid's boundaries belong to the document, so
    -- a slice is paid for once and re-reading is free.
    --
    -- Bounded to the first few slices rather than the whole fixture, and said out
    -- loud rather than left to look like whole-document coverage: this document
    -- is dozens of viewports and every slice is a real Chromium capture.
    -- ------------------------------------------------------------------
    local WALK_SLICES = 4
    if region and grid.count > WALK_SLICES then
      -- The middle of each slice's own travel, which is a position that slice
      -- alone covers -- a straddle is a miss until the composite exists, and a
      -- miss here would be measuring the boundary rather than the claim.
      local stops = {}
      for index = 0, WALK_SLICES - 1 do
        local slice = assert(resident.slice(grid, index))
        stops[#stops + 1] = math.floor(slice.doc_y + (slice.doc_h - session.viewport_height_px) / 2)
      end

      local function walk()
        for index, stop in ipairs(stops) do
          local cell = index - 1
          controller.scroll_to(session, stop)
          -- Long enough for a settle to fire, the fill to cross, and the next
          -- pan to be answered from what it left behind.
          vim.wait(20000, function() return resident.hold(live, cell) ~= nil end, 25)
          vim.wait(150, function() return false end, 25)
        end
      end

      walk()
      local filled_after_first = live.fills
      -- At least, not exactly: the idle-time prefetch fills outward from the
      -- reader whenever the wire has nothing they are waiting for, so a walk
      -- that pauses at each stop may well have picked up neighbours too.
      t.ok(#held() >= WALK_SLICES, ("each of the %d slices walked is resident"):format(WALK_SLICES))
      t.eq(0, live.evictions, "and nothing was evicted to make room, at this ceiling")
      for index = 0, WALK_SLICES - 1 do
        t.ok(resident.hold(live, index) ~= nil, ("slice %d is held, in its own cell"):format(index))
      end

      -- And back over exactly the same ground.
      --
      -- The prefetch is deliberately left running. It is idle-wire traffic for
      -- slices the reader has *not* reached, so holding it still to make the
      -- number smaller would measure a configuration nobody runs. What must be
      -- zero is any transmission for a slice this session already holds -- which
      -- is the claim, stated exactly, and survives whatever else the wire is
      -- doing.
      local held_before = {}
      for _, slice in ipairs(held()) do
        held_before[slice.image_id] = slice.index
      end
      emitted = {}
      walk()

      local transmitted = {}
      for control in table.concat(emitted):gmatch("\27_G([^;]*);") do
        local id = control:match("a=t") and control:match("i=(%d+)")
        if id then transmitted[tonumber(id)] = true end
      end
      for image_id, index in pairs(held_before) do
        t.eq(nil, transmitted[image_id], ("slice %d, already held, is never transmitted again"):format(index))
      end
      t.ok(live.fills >= filled_after_first, "sanity: the walk did not lose slices")
      t.eq(0, live.evictions, "and still nothing evicted")

      -- ----------------------------------------------------------------
      -- The boundary, in bytes the real backend produced.
      --
      -- A grid's edges never move, so a reader can park on one -- which is what
      -- the bounded region could not survive, because its edges moved with
      -- them and every crossing was an eviction and a refill. Here the viewport
      -- is written as two bands, split at a whole cell row, in one write.
      -- ----------------------------------------------------------------
      local boundary = math.floor(resident.slice(grid, 0).doc_h - session.viewport_height_px) + 1
      local at_first, at_last = resident.slices_for(grid, boundary, session.viewport_height_px)
      t.eq(0, at_first, "sanity: that position starts in slice 0")
      t.eq(1, at_last, "and genuinely needs slice 1 as well")

      local straddles_before = live.straddles
      emitted = {}
      -- Measured synchronously, like the pan above: `scroll_to` composites
      -- before it returns, so this is the composite's own bytes with neither the
      -- settle nor the idle-time prefetch folded in.
      controller.scroll_to(session, boundary)
      local seam_stream = table.concat(emitted)

      t.eq(straddles_before + 1, live.straddles, "a viewport spanning two slices is composited")
      t.eq(nil, seam_stream:match("\27_Ga=t"), "with no image transmitted for it")

      -- Both bands, not merely a call that returned true. `crop_within` refuses
      -- rather than clamps, so a band one pixel outside its slice places
      -- *nothing* while the write still reports success -- which on screen is
      -- half a preview and whatever was underneath the other half.
      local placed = {}
      for command in seam_stream:gmatch("\27_G([^\27]*)") do
        if command:match("a=p") then
          local id = command:match("i=(%d+)")
          if id then placed[id] = (placed[id] or 0) + 1 end
        end
      end
      t.eq(2, vim.tbl_count(placed), "two images are placed, which is both bands rather than one drawn twice")
      for id, count in pairs(placed) do
        t.ok(count >= 1, ("image %s places at least one region"):format(id))
      end
      local upper_id = tostring(resident.hold(live, 0).image_id)
      local lower_id = tostring(resident.hold(live, 1).image_id)
      t.ok(placed[upper_id] ~= nil, "one of them is the slice above the boundary")
      t.ok(placed[lower_id] ~= nil, "and the other is the slice below it")
      t.near(boundary, session.applied_scroll_y, 1.0, "and the position recorded is the one asked for")

      -- ----------------------------------------------------------------
      -- Idle wire fills the rest of the document.
      --
      -- A reader who stops reading is a reader whose link is doing nothing, and
      -- the slices around them are the ones they are most likely to want next.
      -- Without this the document is only ever resident where somebody has
      -- already scrolled, so the second pass this feature exists for keeps
      -- paying a warm-up at every new screen.
      -- ----------------------------------------------------------------
      -- By now the walk has paused often enough for the prefetch to have run
      -- many times over, so what is asserted is the state it reached rather than
      -- a fresh one it is asked to reach: how much of the document is held, and
      -- that none of it was bought by giving something else up.
      controller.scroll_to(session, stops[1])
      vim.wait(20000, function() return resident.next_prefetch(live, grid, 0) == nil end, 50)

      t.ok(live.prefetches > 0, "sitting still fills slices nobody scrolled to")
      t.ok(
        #held() > WALK_SLICES,
        ("so more of the document is held than was walked (%d slices of %d)"):format(#held(), grid.count)
      )
      t.eq(0, live.evictions, "without evicting anything to do it, which would be churn rather than warm-up")
      t.ok(
        live.resident_px <= live.memory_px,
        ("and never past the ceiling (%d of %d px)"):format(live.resident_px, live.memory_px)
      )

      -- The reader always outranks it. With the ceiling full there is no room
      -- for a guess, and a prefetch that evicted to make some would drop a slice
      -- the reader may come back to and pay for both again.
      local full_before = live.fills
      local roomy_ceiling = live.memory_px
      live.memory_px = live.resident_px
      require("md-viewer.debounce").close(session, "resident_prefetch_timer")
      controller._prefetch_slice(session)
      vim.wait(500, function() return false end, 25)
      t.eq(full_before, live.fills, "a full ceiling refuses the prefetch rather than evicting for it")
      t.eq(0, live.evictions, "so nothing is given up for a slice nobody asked for")
      live.memory_px = roomy_ceiling
      reconcile("after a whole-document walk")
    end

    -- ------------------------------------------------------------------
    -- Over the ceiling: a window that slides, and every slice it drops is
    -- given back rather than merely forgotten.
    -- ------------------------------------------------------------------
    if region and grid.count > WALK_SLICES then
      local records = held()
      local one_slice = records[1].image_w * records[1].image_h
      -- Room for two slices, so walking four has to drop two.
      live.memory_px = one_slice * 2
      emitted = {}
      local evictions_before = live.evictions
      local dropped = {}
      for _, gone in ipairs(resident.retain_window(live, records[#records].index)) do
        dropped[#dropped + 1] = gone.image_id
      end
      -- Said, not deduced. A document that does not fit is ordinary -- crossing
      -- the window costs an upload each time -- and until now the only sign was
      -- `evictions` climbing in a diagnostic a reader would have to know to open.
      local fitting, whole = resident.slices_that_fit(live.grid, live.memory_px)
      t.eq(false, whole, "a ceiling below the document does not claim to hold it")
      t.ok(fitting < live.grid.count, ("saying how much does: %d of %d"):format(fitting, live.grid.count))
      t.ok(#dropped > 0, "a ceiling below what is held slides the window")
      t.eq(evictions_before + #dropped, live.evictions, "counting each slice it dropped")
      t.ok(
        resident.hold(live, records[#records].index) ~= nil,
        "and never the slice the reader is in, which is what centring the window buys"
      )
      t.ok(live.resident_px <= live.memory_px, "leaving what is held inside the ceiling")

      -- The pixels, not just the bookkeeping. A slice dropped from the grid and
      -- not freed is a slice the terminal holds forever with nobody left to
      -- place it.
      for _, image_id in ipairs(dropped) do
        pcall(session.backend.clear, image_id)
      end
      local stream = table.concat(emitted)
      for _, image_id in ipairs(dropped) do
        t.ok(
          stream:find(("a=d,d=I,q=2,i=%d"):format(image_id), 1, true) ~= nil,
          ("the evicted slice %d has its pixels given back"):format(image_id)
        )
      end
      live.memory_px = one_slice * 64
      reconcile("after the window slid")
    end

    -- ------------------------------------------------------------------
    -- Slices are given back when the document changes, not when the reader
    -- next happens to scroll.
    --
    -- The key check lived in `try_pan` alone, so a resize, a colorscheme change,
    -- an edit or an explicit refresh freed nothing until the next scroll. A
    -- reader who changed the document twice and sat still held three generations
    -- of pixels. With one region that is a viewport of waste; with a grid
    -- covering the document it is the whole document, per invalidation.
    -- ------------------------------------------------------------------
    if region then
      local doomed = {}
      for _, slice in ipairs(held()) do
        doomed[#doomed + 1] = slice.image_id
      end
      t.ok(#doomed > 0, "sanity: the session is holding slices to give back")
      local drops_before, drains_before, evictions_before = live.dropped_slices, live.drains, live.evictions
      emitted = {}
      -- What an explicit refresh does, without depending on which window is
      -- current: the epoch is in the content revision, which is in the key.
      session.render_epoch = (session.render_epoch or 0) + 1
      controller.refresh(session)
      settled(function() return #held() == 0 end, "a changed document drops every slice it invalidated")
      local stream = table.concat(emitted)
      -- Every one of them, not just whichever happened to be on screen. Two
      -- slices can be resident with only one displayed, and the one nobody was
      -- looking at is the one a screen-driven free would miss.
      for _, image_id in ipairs(doomed) do
        t.ok(
          stream:find(("a=d,d=I,q=2,i=%d"):format(image_id), 1, true) ~= nil,
          ("slice %d goes back to the terminal, with no scroll to prompt it"):format(image_id)
        )
      end
      t.eq(0, live.resident_px, "with the accounting emptied to match")
      t.eq(nil, live.grid, "and the grid dropped, since its boundaries described the old document")

      -- And what it cost, which is the number that used to be missing entirely.
      -- Not an eviction: the ceiling never bound. Every one of these slices was
      -- captured, uploaded and paid for at full price, and the only trace of
      -- that on a real session's report was `fills` exceeding what was held.
      t.eq(evictions_before, live.evictions, "none of it counted as an eviction, because the ceiling did not bind")
      t.eq(
        drops_before + #doomed,
        live.dropped_slices,
        "so each slice given back is counted where it is dropped instead"
      )
      t.eq(drains_before + 1, live.drains, "with the occasion counted too, so one resize reads unlike twenty")
      reconcile("after a changed document dropped every slice")
    end

    -- ------------------------------------------------------------------
    -- Holding `j`.
    --
    -- A caret motion past the bottom of the viewport scrolls the page, which
    -- with resident regions may be a pan -- so a run of them alternates between
    -- the renderer moving the caret and the controller moving the frame, each
    -- writing the position the other derives from. Reported from a real session
    -- as the cursor vanishing partway down while the page kept scrolling: the
    -- caret is resolved from `applied_scroll_y` less the scroll it was measured
    -- at, and once those two disagree by a viewport it computes as off screen
    -- and nothing draws it, whether or not the browser still has it in view.
    -- ------------------------------------------------------------------
    do
      local caret = require("md-viewer.caret")
      local navigation = require("md-viewer.navigation")
      navigation.attach(session, controller.navigate)
      vim.api.nvim_set_current_win(session.preview_win)

      local function press(lhs)
        local mapping = vim.api.nvim_buf_call(
          session.preview_buf,
          function() return vim.fn.maparg(lhs, "n", false, true) end
        )
        if not mapping.callback then return false end
        mapping.callback()
        return true
      end

      -- Put the caret on screen to begin with, and let it settle.
      controller.place_caret(session)
      vim.wait(3000, function() return session.caret_rect ~= nil end, 25)

      t.ok(session.caret_rect ~= nil, "sanity: a caret exists to hold j against")
      if session.caret_rect then
        local lost_at, presses, moved, max_drift = nil, 60, 0, 0
        local scroll_at_start = session.applied_scroll_y or 0
        for index = 1, presses do
          t.ok(press("j"), "sanity: j is mapped in the preview")
          -- Each motion is a real round trip; the caret index moving is how the
          -- response is known to have landed.
          local seen = session.caret_index
          if vim.wait(3000, function() return session.caret_index ~= seen end, 10) then moved = moved + 1 end
          -- Sampled after everything the motion set off has settled, which is
          -- when a residue would still be there to find.
          vim.wait(60, function() return false end, 10)
          local drift = math.abs((session.applied_scroll_y or 0) - (session.caret_scroll_y or 0))
          if drift > max_drift then max_drift = drift end
          if caret.rect(session) == nil and lost_at == nil then lost_at = index end
        end
        t.ok(moved > presses / 2, ("sanity: the caret actually moved (%d of %d presses landed)"):format(moved, presses))
        t.ok(
          (session.applied_scroll_y or 0) > scroll_at_start,
          ("sanity: holding j scrolled the page (%s -> %s)"):format(
            tostring(scroll_at_start),
            tostring(session.applied_scroll_y)
          )
        )
        t.eq(
          nil,
          lost_at,
          ("the caret stays resolvable while stepping j (lost after %s of %d presses, drift %s)"):format(
            tostring(lost_at),
            presses,
            tostring((session.applied_scroll_y or 0) - (session.caret_scroll_y or 0))
          )
        )

        -- And the quantity that decides whether it is drawn at all. The caret is
        -- resolved as the rect it was measured at, less the scroll travelled
        -- since; once that drift exceeds a viewport it computes as off screen
        -- and nothing draws it -- whether or not the browser still has the caret
        -- in view. So the caret vanishing while `j` keeps scrolling is not the
        -- caret being lost, it is this number growing.
        --
        -- It must not grow at all: every motion re-measures and re-records, so
        -- each press should reset it to nothing. Anything that writes
        -- `applied_scroll_y` after the measurement and without a new one -- a
        -- pan, most obviously -- leaves a residue, and a residue that survives
        -- the next press is a residue that accumulates.
        t.ok(
          max_drift < session.viewport_height_render_px,
          ("drift stays inside a viewport across a run of motions (%.1f of %s)"):format(
            max_drift,
            tostring(session.viewport_height_render_px)
          )
        )
        t.near(0, max_drift, 2.0, "and in fact each motion resets it, so it never accumulates at all")

        -- The same run at the ratio a slow link actually produces.
        --
        -- Locally a caret motion answers in tens of milliseconds, so key repeat
        -- never gets ahead of it and only ever one motion is in flight. Over
        -- SSH the answer takes hundreds, while key repeat still arrives every
        -- thirty -- so a reader leaning on `j` stacks several motions, each
        -- resolved against the scroll the one before it left. That ratio is the
        -- environment, not the machine, and it is the one thing this suite
        -- cannot get by running faster.
        local real_request = process.request
        process.request = function(method, params, callback)
          if method ~= "interact" then return real_request(method, params, callback) end
          return real_request(method, params, function(...)
            local answer = { ... }
            vim.defer_fn(function() callback(unpack(answer)) end, 250)
          end)
        end

        local slow_scroll, slow_lost = session.applied_scroll_y or 0, nil
        for index = 1, 40 do
          press("j")
          -- Key repeat, not a round trip: the loop turns so the press is
          -- delivered, and then the next one arrives whether or not the last
          -- has been answered.
          vim.wait(30, function() return false end, 5)
          if caret.rect(session) == nil and slow_lost == nil then slow_lost = index end
        end
        vim.wait(6000, function() return false end, 50)
        process.request = real_request

        t.ok((session.applied_scroll_y or 0) > slow_scroll, "sanity: a held run on a slow link still scrolls")
        t.eq(
          nil,
          slow_lost,
          ("the caret survives a held run on a slow link (lost at press %s, final drift %.1f)"):format(
            tostring(slow_lost),
            math.abs((session.applied_scroll_y or 0) - (session.caret_scroll_y or 0))
          )
        )
      end
    end

    controller.close(source)
    state.remove(source)
    pcall(vim.api.nvim_buf_delete, source, { force = true })
  end)

  restore()
  if not ok then error(err, 0) end
end
