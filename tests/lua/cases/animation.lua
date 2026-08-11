-- The animation controller: what it places, when, and every reason it
-- declines to. Driven against a stub backend, a stub `process`, and a hand
-- clock, because the things worth proving here are arithmetic, ownership and
-- restraint -- none of which needs a terminal or a wall clock.
--
-- The stub `process.request` also asserts the lane: a controller that reached
-- `renderer.request` would bump `session.request_serial` on every fetch and
-- mark every user render stale before it landed, which is the single most
-- expensive mistake this module could make and the least visible.

local config = require("md-viewer.config")
local cellpixels = require("md-viewer.cellpixels")
local process = require("md-viewer.process")
local animation = require("md-viewer.animation")

local SHA = string.rep("ab", 32)
local SHA2 = string.rep("cd", 32)

local FRAME_A = vim.fn.tempname() .. "-a.png"
local FRAME_B = vim.fn.tempname() .. "-b.png"

local function write_frames()
  for _, path in ipairs({ FRAME_A, FRAME_B }) do
    local handle = io.open(path, "wb")
    handle:write("not really a png, the stub backend does not look")
    handle:close()
  end
end

return function(t)
  write_frames()

  local original_measure = cellpixels.measure
  local original_request = process.request
  local original_now = animation._internal.now
  config.reset()
  config.setup({ image = { backend = "kitty_raw" }, terminal = { profile = "kitty" }, render = { animate = true } })
  cellpixels.measure = function() return { width = 10, height = 20 } end

  local clock = 0
  animation._internal.now = function() return clock end

  -- The stub renderer: records every request, answers from `respond` (or holds
  -- the callback when `respond` is nil, for the staleness cases).
  local lanes_used, requests, held = {}, {}, nil
  local respond
  process.request = function(method, params, callback)
    lanes_used[#lanes_used + 1] = method
    requests[#requests + 1] = vim.deepcopy(params)
    if respond then
      callback(respond(params), nil)
    else
      held = callback
    end
  end

  local function frames_answer(params, overrides)
    local answers = {}
    for _, item in ipairs(params.requests) do
      answers[#answers + 1] = vim.tbl_extend("force", {
        id = item.id,
        status = "ok",
        frames = {
          { path = FRAME_A, key = "k1-" .. item.sha:sub(1, 2), gapMs = 100 },
          { path = FRAME_B, key = "k2-" .. item.sha:sub(1, 2), gapMs = 200 },
        },
        loop = "infinite",
        frameWidthPx = item.targetWidthPx,
        frameHeightPx = item.targetHeightPx,
        decodeMs = 5,
      }, overrides or {})
    end
    return { animations = answers }
  end
  respond = frames_answer

  -- The stub backend. Uploads are cached by stable key exactly like the real
  -- one; native calls record their arguments and can pretend the terminal
  -- already held the content.
  local uploads, uploaded_by_key, applied, cleared, freed = {}, {}, {}, 0, {}
  local native = { begins = {}, frames = {}, finishes = {}, supported = false, existing = false }
  local next_image_id = 500
  local backend = {
    name = "kitty_raw",
    animation_supported = function() return true end,
    animation_native_supported = function() return native.supported end,
    animation_uploaded = function(key) return uploaded_by_key[key] end,
    animation_upload = function(key)
      uploads[#uploads + 1] = key
      next_image_id = next_image_id + 1
      uploaded_by_key[key] = next_image_id
      return next_image_id
    end,
    animation_apply = function(set_id, items)
      applied[#applied + 1] = vim.deepcopy(items)
      return set_id or 7, { bytes = 120, placed = #items, deleted = 0, items = #items }
    end,
    animation_clear = function()
      cleared = cleared + 1
      return true
    end,
    animation_free = function(keys)
      freed[#freed + 1] = vim.deepcopy(keys)
      return #keys
    end,
    animation_native_begin = function(key, _, gap)
      native.begins[#native.begins + 1] = { key = key, gap = gap }
      next_image_id = next_image_id + 1
      uploaded_by_key[key] = next_image_id
      return next_image_id, native.existing
    end,
    animation_native_frame = function(key, _, gap)
      native.frames[#native.frames + 1] = { key = key, gap = gap }
      return true
    end,
    animation_native_finish = function(key, loop)
      native.finishes[#native.finishes + 1] = { key = key, loop = loop }
      return true
    end,
  }

  local function make_session(geometry)
    return {
      backend = backend,
      image_id = 1,
      -- 80x40 cells at a 10x20 cell: an 800x800 drawn box over an 800x800
      -- calibrated viewport, so both scales are exactly 1 unless a case
      -- changes them.
      last_placement = { row = 2, col = 3, width = 80, height = 40 },
      applied_scroll_y = 0,
      viewport_width_px = 800,
      viewport_height_render_px = 800,
      animation_geometry = geometry,
    }
  end

  local tick = animation._internal.tick

  -- -------------------------------------------------------------------------
  -- The frames strategy: fetch, native gaps, duration-preserving skip.
  -- -------------------------------------------------------------------------
  local session = make_session({ { id = "a1", sha = SHA, xPx = 20, yPx = 100, widthPx = 400, heightPx = 200 } })
  animation.adopt(session)
  t.eq({ "animation" }, lanes_used, "frames are fetched off the render lane, never through renderer.request")
  t.eq(SHA, requests[1].requests[1].sha, "the request is addressed by content hash")
  t.eq(400, requests[1].requests[1].targetWidthPx, "and by the drawn size, computed here")
  t.eq(200, requests[1].requests[1].targetHeightPx, "on both axes")
  t.eq(1, #applied, "the answer paints without waiting for a tick")

  local first = applied[1][1]
  t.eq(20, first.x, "x is the document rect scaled into drawn pixels")
  t.eq(100, first.y, "y is the document rect, less the applied scroll")
  t.eq(400, first.width, "the drawn width is the placement size the frames were encoded at")
  t.eq(200, first.height, "and the height")
  t.eq({ "k1-ab" }, uploads, "the frame was uploaded under its stable key, not its temp path")

  clock = 150
  tick()
  t.ok(applied[#applied][1].image_id ~= first.image_id, "the second frame shows during its own 100..300ms window")
  clock = 320
  tick()
  t.eq(first.image_id, applied[#applied][1].image_id, "and the loop wraps on the animation's own 300ms period")
  t.eq({ "k1-ab", "k2-ab" }, { uploads[1], uploads[2] }, "each frame uploads once, under its stable key")
  t.eq(2, #uploads, "and only once, however often the loop comes round")

  -- Duration is preserved under any tick pattern: jumping the clock lands on
  -- the frame the wall time says, frames between are skipped, never stretched.
  clock = 1000 -- 1000 % 300 = 100: second frame's window opens exactly here
  tick()
  local skipped = applied[#applied][1]
  t.ok(skipped.image_id ~= first.image_id, "a sparse tick shows the frame the clock says, skipping the rest")

  -- Scrolling repositions with no new request and no new upload.
  local requests_before = #requests
  session.applied_scroll_y = 60
  clock = 1210 -- back inside frame 1's window (1210 % 300 = 10)
  tick()
  t.eq(40, applied[#applied][1].y, "a scroll subtracts from the document rect (100 - 60)")
  t.eq(requests_before, #requests, "and costs no round trip")
  t.eq(2, #uploads, "and no re-upload")
  session.applied_scroll_y = 0

  -- A re-render of unchanged content re-mints ids; the same bytes at the same
  -- size are the same animation mid-play, so nothing refetches and nothing
  -- restarts.
  session.animation_geometry = { { id = "a9", sha = SHA, xPx = 20, yPx = 100, widthPx = 400, heightPx = 200 } }
  animation.adopt(session)
  t.eq(requests_before, #requests, "an id re-mint with unchanged content and size fetches nothing")
  t.eq(2, #uploads, "and re-uploads nothing")

  -- The two scales are separate axes. Halve the drawn height only: y and the
  -- target height must follow it while x and the width stay put.
  session.last_placement = { row = 2, col = 3, width = 80, height = 20 } -- drawn 800x400
  animation.adopt(session)
  local scaled_request = requests[#requests].requests[1]
  t.eq(400, scaled_request.targetWidthPx, "width is scaled by the horizontal axis")
  t.eq(100, scaled_request.targetHeightPx, "height by the vertical one -- a shared scale put frames ~14% off")
  local scaled = applied[#applied][1]
  t.eq(20, scaled.x, "x follows the horizontal scale")
  t.eq(50, scaled.y, "y follows the vertical scale")

  -- The resize freed what the old size held: its two frame keys, no longer
  -- referenced by any session.
  t.eq(1, #freed, "the superseded size's uploads were freed")
  t.eq({ "k1-ab", "k2-ab" }, freed[1], "exactly its frame keys, sorted")
  session.last_placement = { row = 2, col = 3, width = 80, height = 40 }
  animation.adopt(session)

  -- -------------------------------------------------------------------------
  -- Gating: every reason to leave the still frame alone, each with its name.
  -- -------------------------------------------------------------------------
  local cases = {
    { field = "pointer", value = { pressed = true }, expect = "drag" },
    { field = "visual_active", value = true, expect = "visual" },
    { field = "occluded", value = true, expect = "occluded" },
    { field = "ui_suppressed", value = true, expect = "suppressed" },
    { field = "loading", value = true, expect = "not showing a frame" },
    { field = "render_failed", value = true, expect = "not showing a frame" },
  }
  for _, case in ipairs(cases) do
    session[case.field] = case.value
    local ok, reason = animation._internal.permitted(session)
    t.eq(false, ok, ("%s suppresses animation"):format(case.field))
    t.ok(reason and reason:find(case.expect, 1, true), ("%s says why: %s"):format(case.field, tostring(reason)))
    session[case.field] = nil
  end

  -- The pointer table outlives the press: release leaves it behind with
  -- pressed=false, and only interaction.forget removes it. The gate is the
  -- press -- a session that was ever clicked must keep animating.
  session.pointer = { pressed = false, drag_started = true }
  t.eq(true, (animation._internal.permitted(session)), "a released pointer does not suppress animation")
  session.pointer = nil

  t.eq(false, (animation._internal.permitted({ backend = { name = "cells" } })), "the text backend never animates")
  t.eq(
    false,
    (animation._internal.permitted({ backend = { name = "nvim_img" } })),
    "nor does nvim_img, which exposes no sub-cell placement"
  )

  -- A suppressed tick clears rather than leaving a stale frame placed over a
  -- base that has moved on; resuming repaints without a fetch.
  local cleared_before = cleared
  session.occluded = true
  tick()
  t.ok(cleared > cleared_before, "a suppressed tick removes the placements it had up")
  t.ok(session.animation_suppressed_reason ~= nil, "and records the reason for :MdViewerDebug")
  session.occluded = false
  local painted_before = #applied
  local fetches_before = #requests
  animation.repaint(session)
  t.ok(#applied > painted_before, "visibility resumes with a repaint")
  t.eq(fetches_before, #requests, "not a refetch")

  -- adopt applies the same gate: mid-drag interact frames must not churn the
  -- stream the drag is fighting for.
  painted_before = #applied
  session.pointer = { pressed = true }
  animation.adopt(session)
  t.eq(painted_before, #applied, "adopt paints nothing while a drag is in progress")
  t.ok(session.animation_suppressed_reason ~= nil, "and records why")
  session.pointer = nil

  -- A backend that errors mid-paint is a skipped frame and a recorded reason,
  -- not an error notification per tick.
  local erroring = backend.animation_apply
  backend.animation_apply = function() error("terminal went away") end
  clock = clock + 40
  tick()
  t.ok(
    tostring(session.animation_last_error):find("terminal went away", 1, true),
    "a backend error is caught and recorded"
  )
  backend.animation_apply = erroring

  animation.forget(session)

  -- -------------------------------------------------------------------------
  -- Answer statuses: refusals are permanent, environment trouble retries.
  -- -------------------------------------------------------------------------
  respond = function(params) return frames_answer(params, { status = "refused", frames = nil, reason = "too big" }) end
  local refused_session = make_session({ { id = "a1", sha = SHA, xPx = 0, yPx = 0, widthPx = 400, heightPx = 200 } })
  animation.adopt(refused_session)
  local refused_fetches = #requests
  clock = clock + 5000
  tick()
  t.eq(refused_fetches, #requests, "a refusal is permanent for that content at that size: no re-ask, ever")
  animation.forget(refused_session)

  respond = function(params) return frames_answer(params, { status = "unknown-source", frames = nil }) end
  local retry_session = make_session({ { id = "a1", sha = SHA, xPx = 0, yPx = 0, widthPx = 400, heightPx = 200 } })
  animation.adopt(retry_session)
  local retry_fetches = #requests
  clock = clock + 100
  tick()
  t.eq(retry_fetches, #requests, "an unknown source waits out its retry floor")
  clock = clock + 2500
  respond = frames_answer
  tick()
  t.eq(retry_fetches + 1, #requests, "then asks again -- the next render re-registers evicted bytes")
  t.ok(retry_session.animation_assets ~= nil, "and this time the frames land")
  animation.forget(retry_session)

  -- -------------------------------------------------------------------------
  -- Staleness: late answers meet a changed world and decline to apply.
  -- -------------------------------------------------------------------------
  respond = nil -- hold every callback from here on
  local stale_session = make_session({ { id = "a1", sha = SHA, xPx = 0, yPx = 0, widthPx = 400, heightPx = 200 } })
  animation.adopt(stale_session)
  local pending_callback = held
  t.ok(pending_callback ~= nil and stale_session.animation_pending == true, "a fetch is in flight")
  animation.forget(stale_session)
  t.eq(nil, stale_session.animation_pending, "forget clears the pending flag")
  pending_callback(
    frames_answer({ requests = { { id = "a1", sha = SHA, targetWidthPx = 400, targetHeightPx = 200 } } }),
    nil
  )
  t.eq(nil, stale_session.animation_assets, "a late answer does not resurrect state onto a forgotten session")

  -- A resize between ask and answer re-keys the asset; the old answer belongs
  -- to nobody and the new size is fetched afresh.
  local resized_session = make_session({ { id = "a1", sha = SHA, xPx = 0, yPx = 0, widthPx = 400, heightPx = 200 } })
  animation.adopt(resized_session)
  local old_answer = held
  resized_session.last_placement = { row = 2, col = 3, width = 40, height = 40 } -- drawn width halves
  animation.adopt(resized_session)
  old_answer(frames_answer({ requests = { { id = "a1", sha = SHA, targetWidthPx = 400, targetHeightPx = 200 } } }), nil)
  local asset = resized_session.animation_assets["a1"]
  t.eq(nil, asset.frames, "an answer for the superseded size is dropped, not misfiled")
  local before_refetch = #requests
  clock = clock + 40
  tick()
  t.eq(before_refetch + 1, #requests, "and the tick fetches the new size")
  t.eq(200, requests[#requests].requests[1].targetWidthPx, "at its own dimensions")
  held(frames_answer(requests[#requests]), nil)
  animation.forget(resized_session)

  -- -------------------------------------------------------------------------
  -- Renderer restart: paths die, terminal-resident uploads survive by key.
  -- -------------------------------------------------------------------------
  respond = frames_answer
  local surviving = make_session({ { id = "a1", sha = SHA, xPx = 0, yPx = 0, widthPx = 400, heightPx = 200 } })
  animation.adopt(surviving)
  local uploads_before_restart = #uploads
  animation.renderer_exited()
  t.eq(nil, surviving.animation_assets["a1"].frames, "restart invalidates materialized paths")
  clock = clock + 40
  tick()
  t.ok(surviving.animation_assets["a1"].frames ~= nil, "the new process re-materializes")
  clock = clock + 40
  tick()
  t.eq(uploads_before_restart, #uploads, "and nothing re-uploads: the terminal already holds these keys")
  animation.forget(surviving)

  -- -------------------------------------------------------------------------
  -- Finite loops freeze on the last frame, exactly as a browser leaves them.
  -- -------------------------------------------------------------------------
  respond = function(params) return frames_answer(params, { loop = 1 }) end
  local finite = make_session({ { id = "a1", sha = SHA, xPx = 0, yPx = 0, widthPx = 400, heightPx = 200 } })
  clock = 10000
  animation.adopt(finite)
  local last_frame_id = uploaded_by_key["k2-ab"]
  clock = clock + 650 -- two full 300ms plays and change: loop=1 means play twice
  tick()
  t.eq(last_frame_id, applied[#applied][1].image_id, "past its final play the last frame stays")
  local applied_before_idle = #applied
  clock = clock + 900
  tick()
  t.eq(last_frame_id, applied[#applied][1].image_id, "and stays")
  t.ok(#applied >= applied_before_idle, "without error")
  animation.forget(finite)

  -- -------------------------------------------------------------------------
  -- Two animations, one document: one fetch, one apply, independent frames.
  -- -------------------------------------------------------------------------
  respond = frames_answer
  local pair = make_session({
    { id = "a1", sha = SHA, xPx = 0, yPx = 0, widthPx = 400, heightPx = 200 },
    { id = "a2", sha = SHA2, xPx = 0, yPx = 500, widthPx = 400, heightPx = 200 },
  })
  animation.adopt(pair)
  t.eq(2, #requests[#requests].requests, "both animations ride one request")
  t.eq(2, #applied[#applied], "and one placement apply carries both")
  animation.forget(pair)

  -- -------------------------------------------------------------------------
  -- The native strategy: stream once, hand the clock to the terminal.
  -- -------------------------------------------------------------------------
  native.supported = true
  local nat = make_session({ { id = "a1", sha = SHA, xPx = 20, yPx = 100, widthPx = 400, heightPx = 200 } })
  animation.adopt(nat)
  t.eq("native", nat.animation_strategy, "the strategy follows the backend's native gate")
  clock = clock + 40
  tick()
  t.eq(1, #native.begins, "the root frame begins the upload")
  t.eq(SHA .. ":400x200", native.begins[1].key, "keyed by content and drawn size")
  t.eq(100, native.begins[1].gap, "carrying the root frame's own gap")
  t.eq(1, #native.frames, "the remaining frame streamed behind it")
  t.eq(200, native.frames[1].gap, "with its own gap")
  t.eq(1, #native.finishes, "and the finish handed playback to the terminal")
  t.eq("infinite", native.finishes[1].loop, "with the loop the decoder reported")
  local native_item = applied[#applied][1]
  t.eq(uploaded_by_key[SHA .. ":400x200"], native_item.image_id, "the placement shows the animated image itself")

  local native_applied = #applied
  local native_ticks = nat.animation_ticks or 0
  clock = clock + 500
  tick()
  t.eq(native_ticks + 1, nat.animation_ticks, "one more tick ran")
  t.eq(1, #native.begins, "but streamed nothing further")
  clock = clock + 5000
  -- With the upload complete the module has nothing left to do for this
  -- session; the terminal owns playback. (The prior tick already let the
  -- timer lapse -- these manual calls stand in for "much later".)
  tick()
  t.eq(1, #native.finishes, "the terminal owns playback; no further protocol traffic")
  t.ok(#applied >= native_applied, "repaints stay no-ops the backend diffs away")

  -- A second session showing the same content reuses the terminal's copy.
  native.existing = true
  local nat2 = make_session({ { id = "a7", sha = SHA, xPx = 20, yPx = 100, widthPx = 400, heightPx = 200 } })
  animation.adopt(nat2)
  clock = clock + 40
  tick()
  t.eq(2, #native.begins, "the second session asks the cache")
  t.eq(1, #native.frames, "and streams nothing: the terminal already holds the animation")

  -- Ownership: the shared key survives the first goodbye and is freed on the
  -- last.
  local freed_before = #freed
  animation.forget(nat)
  t.eq(freed_before, #freed, "a key another session still shows is not freed")
  animation.forget(nat2)
  t.eq(freed_before + 1, #freed, "the last session frees it")
  t.eq({ SHA .. ":400x200" }, freed[#freed], "by its content key")
  native.existing = false
  native.supported = false

  -- -------------------------------------------------------------------------
  -- The default configuration. `render.animate` is off, and off has to mean
  -- *nothing*: no session is adopted, so no tick, no fetch and no placement can
  -- follow it. No picture is lost either way -- the still frame Chromium
  -- painted into the screenshot is already on screen, drawn by the base
  -- placement, which never consults this flag.
  -- -------------------------------------------------------------------------
  config.reset()
  t.eq(false, config.get().render.animate, "animation is off in the default configuration")
  local requests_before, applied_before = #requests, #applied
  local dormant = make_session({ { id = "z1", sha = SHA, xPx = 0, yPx = 0, widthPx = 100, heightPx = 100 } })
  animation.adopt(dormant)
  t.eq(nil, animation._internal.sessions[dormant], "the default configuration adopts no session")
  animation.repaint(dormant)
  clock = clock + 1000
  tick()
  t.eq(requests_before, #requests, "a session with animation off never reaches the renderer")
  t.eq(applied_before, #applied, "and never places an animation layer")
  t.eq(nil, dormant.animation_assets, "and materialises no animation assets")

  -- -------------------------------------------------------------------------
  -- Restore everything the case touched.
  -- -------------------------------------------------------------------------
  cellpixels.measure = original_measure
  process.request = original_request
  animation._internal.now = original_now
  config.reset()
  os.remove(FRAME_A)
  os.remove(FRAME_B)
end
