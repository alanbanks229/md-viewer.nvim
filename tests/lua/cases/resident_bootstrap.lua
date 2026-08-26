-- The resident bootstrap: what is on the pane between the render that measured
-- the document and the first chunk that can replace it.
--
-- The reported fault was a flash of yellow "waiting for this page" over a blank
-- pane on a slow link, after which the preview showed a position that was not
-- the reader's. Three things had to go wrong together: the bootstrap frame was
-- destroyed the moment the plan was built, the viewport model's recovery path
-- then restored a stale frame into a pane the resident compositor believed it
-- owned, and the two placements shared a z layer that Kitty ties by image id.
-- Every assertion below is one of those three, or the invariant it broke.
--
-- Nothing here spawns a renderer: `renderer.request` is stubbed, so a chunk
-- capture is whatever this file decides it is, including a slow or a lost one.
return function(t)
  local config = require("md-viewer.config")
  local controller = require("md-viewer.controller")
  local preview = require("md-viewer.preview")
  local renderer = require("md-viewer.renderer")
  local resident = require("md-viewer.resident")
  local resident_session = require("md-viewer.resident_session")

  local entry_win = vim.api.nvim_get_current_win()
  config.reset()
  require("md-viewer").setup({ image = { backend = "cells" } })

  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# One", "", "body" })

  local real_request = renderer.request
  local requests = {}
  renderer.request = function(session, markdown, options, callback)
    requests[#requests + 1] = { session = session, options = options, callback = callback }
    return #requests
  end

  local log = {}
  local function step(name)
    for index, entry in ipairs(log) do
      if entry == name then return index end
    end
    return nil
  end

  local function stub_backend()
    return {
      name = "kitty_raw",
      clear = function(id)
        log[#log + 1] = "clear:" .. tostring(id)
        return true
      end,
      show = function()
        log[#log + 1] = "show"
        return 55
      end,
      update = function(id)
        log[#log + 1] = "update"
        return id
      end,
      move = function(id) return id end,
      compose = function()
        log[#log + 1] = "compose"
        return true
      end,
      uncompose = function()
        log[#log + 1] = "uncompose"
        return 1
      end,
      upload = function()
        log[#log + 1] = "upload"
        return 900
      end,
      retire = function() return 0 end,
      overlay_clear = function(set) log[#log + 1] = "overlay_clear:" .. tostring(set) end,
      overlay_supported = function() return true end,
    }
  end

  -- A session on the resident path with a real chunk plan and no chunks yet:
  -- exactly the state `begin_resident` hands to `draw_resident`.
  --
  -- The geometry is chosen so the document is one chunk (`0/1`, which is what
  -- the reader reported on CONTRIBUTING.md) and so `rows` matches the split's
  -- real placement -- a plan built against a different pane height is a hard
  -- demotion, which would test something else entirely.
  local function open_resident()
    vim.api.nvim_set_current_buf(source)
    local session = assert(controller.open("right"))
    log = {}
    session.backend = stub_backend()
    session.render_path = "resident"
    session.render_path_reason = "forced by tests"
    session.renderer_revision = "1:0"
    local placement = preview.placement(session.preview_win, "kitty_raw")
    local rows = placement.height
    local plan = assert(resident.chunk_plan({
      document_h = 30 * rows,
      viewport_h = 20 * rows,
      rows = rows,
      scale = 2,
      image_w = 400,
      chunk_viewports = 2,
    }))
    session.resident = {
      key = "test",
      plan = plan,
      images = {},
      queue = { 1 },
      in_flight = nil,
      captured = 0,
      bytes = 0,
      drawn = nil,
      travel = 0,
    }
    session.document_height_px = 30 * rows
    session.viewport_height_px = 20 * rows
    session.scroll_y, session.applied_scroll_y = 0, 0
    return session, plan, rows
  end

  local function winbar(session) return vim.api.nvim_get_option_value("winbar", { win = session.preview_win }) end

  -- ---------------------------------------------------------------------
  -- The bootstrap frame is a picture of this position, so it stays
  -- ---------------------------------------------------------------------
  do
    local session, plan, rows = open_resident()
    t.ok(rows >= 4, "sanity: the test split is tall enough to plan against")
    t.eq(1, plan.count, "sanity: this document is a single chunk, so the notice reads 0/1")

    session.image_id = 5
    session.frame_scroll_y = 0
    session.frame_revision = "1:0"
    session.last_placement = preview.placement(session.preview_win, "kitty_raw")

    controller.draw_resident(session)

    t.eq(5, session.image_id, "the frame that measured the document is still on screen")
    t.eq(nil, step("clear:5"), "nothing took it down")
    t.eq(nil, session.resident_waiting, "and the reader is not waiting on anything they can see")
    t.ok(winbar(session):match("warming 0/1"), "the winbar says more is coming")
    t.eq(nil, winbar(session):match("waiting for this page"), "and does not claim the pane is blank")
    t.eq(false, session.loading, "no spinner over a frame that is already correct")
    t.ok(#requests > 0, "the warm-up started")

    -- ---------------------------------------------------------------------
    -- A frame of somewhere else does not stay. This is the invariant the
    -- feature exists for, and the reason the branch above is a narrowing of it
    -- rather than an exception to it.
    -- ---------------------------------------------------------------------
    log = {}
    session.scroll_y = 10 * rows -- the document bottom; the frame shows the top
    controller.draw_resident(session)

    t.eq(nil, session.image_id, "a frame from another position comes down")
    t.ok(step("clear:5"), "and is deleted from the terminal, not merely forgotten")
    t.eq(1, session.resident_waiting, "the chunk the reader now needs is recorded")
    t.ok(winbar(session):match("waiting for this page"), "and the winbar says the pane is blank")
    t.eq(true, session.loading, "a genuinely blank bootstrap gets the spinner back")
    preview.stop_loading(session)

    -- ---------------------------------------------------------------------
    -- Same position, other content. `holding_position` is not just a scroll
    -- comparison: a frame of this scroll in the *previous* revision of the
    -- document is a picture of somewhere else too.
    -- ---------------------------------------------------------------------
    log = {}
    session.scroll_y = 0
    session.image_id = 5
    session.frame_scroll_y = 0
    session.frame_revision = "0:9"
    controller.draw_resident(session)

    t.eq(nil, session.image_id, "a frame captured against other content comes down")
    t.eq(1, session.resident_waiting, "and the reader is told the pane is blank")
    preview.stop_loading(session)

    controller.close(source)
  end

  -- ---------------------------------------------------------------------
  -- Handover: the first chunk replaces the bootstrap frame, and the frame is
  -- retired *after* the compose. Deleting first is a blank pane for one write;
  -- not deleting at all is the z-fight that put the wrong page on screen.
  -- ---------------------------------------------------------------------
  do
    local session = open_resident()
    session.image_id = 5
    session.frame_scroll_y = 0
    session.frame_revision = "1:0"
    session.last_placement = preview.placement(session.preview_win, "kitty_raw")
    session.resident.images[1] = 900
    session.resident.captured = 1
    session.resident.queue = {}
    preview.start_loading(session)

    controller.draw_resident(session)

    t.ok(step("compose"), "the screen is drawn from the chunk")
    t.ok(step("clear:5"), "and the bootstrap frame is retired")
    t.ok(step("compose") < step("clear:5"), "in that order: nothing blanks between the two writes")
    t.eq(nil, session.image_id, "the resident path owns no frame id of its own")
    t.eq(true, session.resident_screen, "it records that bands are placed instead")
    t.ok(session.last_placement ~= nil, "and the placement clicks and the caret resolve against")
    t.eq(nil, session.resident_waiting, "nothing is being waited on")
    t.eq(false, session.loading, "and the spinner is down")

    -- A pan moves the base every rectangle was measured against.
    log = {}
    session.overlay_set = 91
    session.scroll_y = session.viewport_height_px * 0.5
    controller.draw_resident(session)
    t.ok(step("overlay_clear:91"), "panning drops the selection overlay rather than leaving it on the wrong text")

    -- An occluding float has to reach the bands. Until `uncompose` existed
    -- nothing could: `clear_image` only knew `session.image_id`, which a
    -- resident session does not have, so the document went on compositing
    -- underneath the float.
    log = {}
    local float_placement = preview.placement(session.preview_win, "kitty_raw")
    local float_buf = vim.api.nvim_create_buf(false, true)
    local float_win = vim.api.nvim_open_win(float_buf, false, {
      relative = "editor",
      row = float_placement.row,
      col = float_placement.col,
      width = math.min(10, float_placement.width),
      height = math.min(3, float_placement.height),
      style = "minimal",
    })
    controller.draw_resident(session)
    t.ok(step("uncompose"), "an occlusion takes the resident screen down")
    t.eq(false, session.resident_screen, "and records that nothing is placed")
    t.eq(nil, session.last_placement, "so no click resolves against a screen that is not there")
    t.eq(nil, step("compose"), "and nothing was drawn under the float")

    -- Closing it puts the screen back through the same restore path the
    -- viewport model uses -- and that path must not re-upload the cached
    -- full-viewport PNG into a pane the resident compositor owns. That upload
    -- is the reported bug: `compose` retires only the bands it tracks, so the
    -- restored frame stayed placed alongside them, and Kitty broke the z tie by
    -- image id.
    log = {}
    session.last_image_bytes = "cached-png"
    vim.api.nvim_win_close(float_win, true)
    vim.wait(300, function() return step("compose") ~= nil end, 10)
    t.ok(step("compose"), "the resident screen is restored by re-cropping the chunks it still holds")
    t.eq(nil, step("show"), "and never by re-uploading a frame from the other rendering model")
    t.eq(true, session.resident_screen, "the pane is accounted for again")

    controller.close(source)
  end

  -- ---------------------------------------------------------------------
  -- A stale chunk reply must not lose the chunk.
  --
  -- Every renderer.request bumps `request_serial`, so a settle capture, a
  -- resize or a ColorScheme is enough to stale a chunk in flight -- and
  -- `next_chunk` has already taken it off the queue. The invariant asserted
  -- here is the one that was broken: queue + captured + in-flight accounts for
  -- every chunk in the plan, at every step.
  -- ---------------------------------------------------------------------
  do
    local session, plan = open_resident()
    local function accounted()
      local live = session.resident
      return #live.queue + live.captured + (live.in_flight and 1 or 0)
    end
    t.eq(plan.count, accounted(), "every chunk is accounted for before the pump starts")

    requests = {}
    controller.pump_resident(session)
    t.eq(1, #requests, "the pump asked for a chunk")
    t.eq(1, session.resident.in_flight, "which is in flight")
    t.eq(plan.count, accounted(), "and still accounted for while it is")

    requests[1].callback(nil, nil, true)
    t.eq(nil, session.resident.in_flight, "a staled reply releases the slot")
    t.eq(plan.count, accounted(), "and puts the chunk back rather than dropping it")

    requests = {}
    vim.wait(200, function() return #requests > 0 end, 10)
    t.eq(1, #requests, "the warm-up carries on instead of stalling at 0/1 forever")

    -- A reader scrolling into the chunk that is already being captured must not
    -- put it in two places at once. The capture is deliberately not cancelled,
    -- so there is nothing to prioritise -- and a duplicate would make the
    -- accounting above stop meaning anything.
    resident_session.prioritise(session, 1)
    t.eq(plan.count, accounted(), "prioritising a chunk already in flight changes nothing")

    requests[1].callback({ image = "png", metadata = { regionYPx = 0, pngBytes = 10 } }, nil, false)
    t.eq(1, session.resident.captured, "and the retried chunk is adopted")
    t.eq(plan.count, accounted(), "with the accounting still exact")

    controller.close(source)
  end

  -- ---------------------------------------------------------------------
  -- resident_session.missing: the question `draw` asks, asked ahead of the
  -- compose so the spinner can come down before the placements go out.
  -- ---------------------------------------------------------------------
  do
    local session, _, rows = open_resident()
    t.eq(1, resident_session.missing(session, 0), "with nothing captured, the first needed chunk is missing")
    session.resident.images[1] = 900
    t.eq(nil, resident_session.missing(session, 0), "with it captured, nothing is")
    t.eq(nil, resident_session.missing(session, 10 * rows), "including at the far end of a single-chunk document")
    session.resident = nil
    t.eq(nil, resident_session.missing(session, 0), "a session with no resident state is not waiting on a chunk")
    controller.close(source)
  end

  -- ---------------------------------------------------------------------
  -- The chunk plan is keyed on the theme the renderer will actually use.
  --
  -- `render.theme = "auto"` is the default and resolves against `background` at
  -- request time, so keying on the literal "auto" made `:set background=light`
  -- produce an identical key -- and an identical key is exactly how `begin`
  -- decides the chunks already in the terminal are still valid. A whole document
  -- of dark-theme pixels stayed resident with nothing able to notice.
  -- ---------------------------------------------------------------------
  do
    local session, _, rows = open_resident()
    local entry_background = vim.o.background
    session.viewport_width_px = 400
    session.viewport_height_render_px = 20 * rows
    local meta = { documentHeightPx = 30 * rows, viewportHeightPx = 20 * rows }

    session.resident = nil
    vim.o.background = "dark"
    t.ok((resident_session.begin(session, meta)), "a plan is built for the dark theme")
    local dark_key = session.resident.key
    session.resident.images[1] = 900
    session.resident.captured = 1

    t.ok((resident_session.begin(session, meta)), "the same theme keeps the same plan")
    t.eq(dark_key, session.resident.key, "and the same key")
    t.eq(1, session.resident.captured, "so nothing is recaptured")

    vim.o.background = "light"
    t.ok((resident_session.begin(session, meta)), "a plan is built for the light theme")
    t.ok(session.resident.key ~= dark_key, "which is a different document as far as the chunks are concerned")
    t.eq(0, session.resident.captured, "so the dark theme's chunks are released rather than shown as light ones")

    vim.o.background = entry_background
    controller.close(source)
  end

  renderer.request = real_request
  pcall(vim.api.nvim_buf_delete, source, { force = true })
  pcall(vim.api.nvim_set_current_win, entry_win)
  config.reset()
end
