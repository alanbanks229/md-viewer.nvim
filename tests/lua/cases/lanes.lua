-- Per-lane staleness: the rules, and the wiring that decides which lane a real
-- `renderer.request` lands in.
--
-- The fault this replaces is recorded twice in `controller.lua` at the sites
-- that paid for it: one `request_serial` was shared by every kind of request, so
-- a settle capture, a resize, a ColorScheme or an OptionSet was enough to stale
-- a resident chunk in flight -- and since `next_chunk` had already taken that
-- index off the queue, the warm-up stopped at n/N and stayed there.
--
-- The first half is arithmetic against a plain table, like `resident.lua`'s
-- invariants. The second half is the part arithmetic cannot reach: that
-- `renderer.request` admits each of the four option shapes the controller
-- actually sends into the lane it belongs in.

return function(t)
  local lanes = require("md-viewer.lanes")
  local config = require("md-viewer.config")
  local backends = require("md-viewer.backends")
  local process = require("md-viewer.process")
  local renderer = require("md-viewer.renderer")

  -- -- the rules ------------------------------------------------------------

  local function session() return { closed = false, request_serial = 0, lanes = lanes.fields(), lane_epoch = 0 } end

  do
    local s = session()
    local content = lanes.admit(s, "content")
    local capture = lanes.admit(s, "capture")
    local settle = lanes.admit(s, "settle")
    local chunk = lanes.admit(s, "resident")

    t.eq(false, lanes.superseded(s, content), "nothing after a content render superseded it")
    t.eq(false, lanes.superseded(s, capture), "nor the capture")
    t.eq(false, lanes.superseded(s, settle), "nor the settle")
    t.eq(false, lanes.superseded(s, chunk), "nor the chunk")
    t.eq({ 1, 2, 3, 4 }, {
      content.serial,
      capture.serial,
      settle.serial,
      chunk.serial,
    }, "one monotonic serial across the lanes, so two lanes can never hold the same one")
    t.eq(4, s.request_serial, "which is still the count of requests this document has issued")

    -- The whole point, stated as the four one-line rules `lanes.js` states.
    local second_capture = lanes.admit(s, "capture")
    t.eq(true, lanes.superseded(s, capture), "a capture supersedes the capture before it")
    t.eq(false, lanes.superseded(s, settle), "and nothing else")
    t.eq(false, lanes.superseded(s, chunk), "-- in particular not a chunk in flight")

    local second_settle = lanes.admit(s, "settle")
    t.eq(true, lanes.superseded(s, settle), "a settle supersedes the settle before it")
    t.eq(false, lanes.superseded(s, chunk), "and leaves the chunk alone, which is the regression this fixes")
    t.eq(false, lanes.superseded(s, second_capture), "and the live capture alone")

    local second_chunk = lanes.admit(s, "resident")
    t.eq(true, lanes.superseded(s, chunk), "a chunk supersedes the chunk before it")
    t.eq(false, lanes.superseded(s, second_capture), "and nothing else")
    t.eq(false, lanes.superseded(s, second_settle), "and nothing else")

    -- Content is the lane that invalidates the others, and it does it through
    -- the epoch: any render can re-lay-out the page, so a frame or a chunk
    -- captured against the old layout is worthless whether or not the content
    -- revision moved with it.
    lanes.admit(s, "content")
    t.eq(true, lanes.superseded(s, second_capture), "a content render voids a capture in flight")
    t.eq(true, lanes.superseded(s, second_settle), "and a settle")
    t.eq(true, lanes.superseded(s, second_chunk), "and a chunk")
  end

  do
    -- `invalidate` is the content rule without a request: a closing document
    -- and a pane switching away both mean every reply still on its way is
    -- worthless, for the same reason -- the layout it was captured against is
    -- gone.
    local s = session()
    local chunk = lanes.admit(s, "resident")
    local before = s.request_serial
    lanes.invalidate(s)
    t.eq(true, lanes.superseded(s, chunk), "invalidate voids every lane at once")
    t.eq(before, s.request_serial, "without counting itself as a request")
  end

  do
    -- A hand-rolled session table -- the low-level public API's shape, and
    -- several cases' -- takes part without having been through state.create.
    local bare = { closed = false }
    local ticket = lanes.admit(bare, "content")
    t.eq(1, ticket.serial, "a session with no lane fields is repaired on first admission")
    t.eq(false, lanes.superseded(bare, ticket), "and behaves like any other")
  end

  do
    t.eq("content", lanes.lane_for(nil), "a bare refresh is a content render")
    t.eq("content", lanes.lane_for({ on_complete = function() end }), "and so is one that only wants a callback")
    t.eq("capture", lanes.lane_for({ capture_only = true, scroll_frame = true }), "a moving scroll frame")
    t.eq("settle", lanes.lane_for({ capture_only = true }), "the sharp frame after the scroll stops")
    t.eq(
      "resident",
      lanes.lane_for({ capture_only = true, capture_region = {}, resident_chunk = 3 }),
      "a document chunk, which the renderer does not distinguish but the warm-up does"
    )
    t.eq(
      "content",
      lanes.lane_for({ capture_only = true, scroll_frame = true }, true),
      "a capture that had to go out as a full render is admitted as the render it became"
    )
  end

  -- -- the wiring -----------------------------------------------------------

  -- No renderer subprocess: `request_stdio` is replaced by a recorder, so a
  -- request is whatever this file decides it is.
  do
    config.reset()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# T", "", "body" })
    -- A real window: `renderer.request` measures the preview viewport before
    -- it admits anything, and that measurement is Neovim's, not a stub's.
    local preview_buf = vim.api.nvim_create_buf(false, true)
    local preview_win = vim.api.nvim_open_win(preview_buf, false, { split = "right", win = -1 })

    local live = {
      closed = false,
      source_buf = buf,
      document_id = "lanes-case",
      preview_win = preview_win,
      preview_buf = preview_buf,
      config = config.snapshot(),
      backend = backends.capabilities("cells"),
      scroll_y = 0,
      request_serial = 0,
      lanes = lanes.fields(),
      lane_epoch = 0,
      render_epoch = 0,
    }
    -- Capture-only survives only while the renderer is known to hold this
    -- revision; without that the request degrades to a full render.
    live.renderer_revision = renderer.content_revision(live)

    local sent = {}
    local original_stdio = process.request_stdio
    process.request_stdio = function(method, params, callback)
      sent[#sent + 1] = { method = method, params = params, callback = callback }
      return #sent
    end

    local function issue(options)
      renderer.request(live, "# T", options, function() end)
    end

    issue({ capture_only = true, capture_region = { yPx = 0, heightPx = 100 }, resident_chunk = 1 })
    local chunk_serial = live.lanes.resident
    issue({ capture_only = true, scroll_frame = true })
    issue({ capture_only = true })

    t.eq({ "capture", "capture", "capture" }, {
      sent[1].method,
      sent[2].method,
      sent[3].method,
    }, "all three go out as captures on the wire, which is unchanged")
    t.eq(chunk_serial, live.lanes.resident, "and neither of the later two touched the chunk's lane")
    t.eq(
      false,
      lanes.superseded(live, { lane = "resident", serial = chunk_serial, epoch = live.lane_epoch }),
      "so the chunk reply is still worth adopting -- the failure this replaces"
    )

    -- The two sides have their own supersession rules and neither is a superset
    -- of the other: the renderer keeps one `capture` lane for what this side
    -- now splits three ways, so it can drop a moving capture that a settle
    -- capture overtook while this side still considers the moving frame's lane
    -- current. Its answer has to reach the caller as staleness, or a routine
    -- supersession arrives at the reader as an error notification -- which is
    -- what the old shared serial hid by staling everything.
    local outcome
    renderer.request(
      live,
      "# T",
      { capture_only = true, scroll_frame = true },
      function(result, err, stale) outcome = { result = result, err = err, stale = stale } end
    )
    sent[#sent].callback(nil, "capture request superseded by a newer request", { code = "STALE_RENDER" })
    t.eq({ result = nil, err = nil, stale = true }, outcome, "a renderer supersession is stale, not an error")

    outcome = nil
    renderer.request(
      live,
      "# T",
      { capture_only = true, scroll_frame = true },
      function(result, err, stale) outcome = { err = err, stale = stale } end
    )
    sent[#sent].callback(nil, "chromium launch failed", { code = "BROWSER_LAUNCH_FAILED" })
    t.eq(
      { err = "chromium launch failed", stale = false },
      outcome,
      "and a real failure is still a failure the reader is told about"
    )

    issue(nil)
    t.eq("render", sent[#sent].method, "a bare refresh is a render")
    t.eq(
      true,
      lanes.superseded(live, { lane = "resident", serial = chunk_serial, epoch = 0 }),
      "and it does void the chunk, because it re-lays out the page the chunk was cut from"
    )

    process.request_stdio = original_stdio
    vim.api.nvim_win_close(preview_win, true)
    vim.api.nvim_buf_delete(preview_buf, { force = true })
    vim.api.nvim_buf_delete(buf, { force = true })
    config.reset()
  end
end
