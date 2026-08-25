---Whole-document resident mode, per session.
---
---Holds the document in the terminal as chunks and turns a scroll into a
---placement. `resident.lua` is the arithmetic; this is the state machine around
---it -- which path a session is on, what has been captured, and what is drawn.
---
---The invariant the whole thing rests on: a capture creates a durable chunk, and
---a scroll only ever crops chunks that already exist. Nothing here takes a
---picture of the reader's viewport.
local config = require("md-viewer.config")
local preview = require("md-viewer.preview")
local resident = require("md-viewer.resident")

local M = {}

local function state(session) return session and session.resident end

---Whether this session may use resident mode, decided once when it opens.
---
---Deliberately not re-decided per scroll: a session that oscillates between two
---rendering models is one whose behaviour nobody can reproduce.
function M.select_path(session)
  local cfg = config.get()
  if not session or not session.backend then return "cells", "no backend" end
  if session.backend.name == "cells" then return "cells", "text-only backend" end
  if cfg.image.resident == "off" then return "viewport", "image.resident = off" end
  local backend = session.backend
  if type(backend.resident_pan_supported) ~= "function" then
    return "viewport", "backend does not support resident placements"
  end
  local ok, reason = backend.resident_pan_supported()
  if not ok then return "viewport", reason or "terminal cannot pan resident chunks" end
  return "resident", "terminal supports cropped placements"
end

---Move a session off the resident path for good.
---
---One way. A session that could promote back would be a session that oscillates
---between two rendering models mid-scroll, which is the thing `select_path`
---exists to prevent.
function M.demote(session, reason)
  local current = state(session)
  if not current then return end
  M.release(session)
  session.render_path = "viewport"
  session.render_path_reason = "demoted: " .. tostring(reason)
  session.render_path_demoted = true
  session.resident = nil
end

---Free every chunk this session holds in the terminal.
function M.release(session)
  local current = state(session)
  if not current then return end
  local ids = {}
  for _, image_id in pairs(current.images) do
    ids[#ids + 1] = image_id
  end
  if #ids > 0 and session.backend and session.backend.retire then pcall(session.backend.retire, ids) end
  current.images = {}
  current.queue = {}
  current.drawn = nil
end

---Build the chunk plan for the document as it now stands, and queue every chunk
---for capture with the reader's own chunks first.
---
---`meta` is a render reply: it carries the document height the plan is derived
---from. Returns false when no plan is possible, which is a demotion.
function M.begin(session, meta)
  local cfg = config.get()
  local placement = preview.placement(session.preview_win, session.backend.name)
  if not placement or (placement.height or 0) < 1 then return false, "no preview placement" end

  local scale = cfg.render.device_scale_factor
  local key = resident.key({
    document_id = session.document_id,
    revision = session.renderer_revision,
    width = session.viewport_width_px,
    height = session.viewport_height_render_px,
    theme = cfg.render.theme,
    font_size = cfg.render.font_size_px,
    scroll_past_end = cfg.render.scroll_past_end,
    scroll_past_end_offset = cfg.render.scroll_past_end_offset_px,
    device_scale = scale,
    chunk_viewports = cfg.image.resident_chunk_viewports,
  })

  local existing = state(session)
  if existing and existing.key == key then return true end
  if existing then M.release(session) end

  local plan, reason = resident.chunk_plan({
    document_h = meta.documentHeightPx,
    viewport_h = meta.viewportHeightPx,
    rows = placement.height,
    scale = scale,
    image_w = math.floor((session.viewport_width_px or 0) * scale),
    chunk_viewports = cfg.image.resident_chunk_viewports,
  })
  if not plan then return false, reason end

  local opening = resident.chunks_for(plan, session.scroll_y or 0, meta.viewportHeightPx) or { 1 }
  session.resident = {
    key = key,
    plan = plan,
    images = {},
    queue = resident.warm_order(plan, opening),
    in_flight = nil,
    captured = 0,
    bytes = 0,
    drawn = nil,
    travel = 0,
  }
  return true
end

---How many chunks are resident out of how many the document needs.
function M.progress(session)
  local current = state(session)
  if not current then return nil end
  return current.captured, current.plan.count
end

function M.warming(session)
  local current = state(session)
  return current ~= nil and current.captured < current.plan.count
end

---The next chunk to capture, or nil when the document is fully resident.
function M.next_chunk(session)
  local current = state(session)
  if not current or current.in_flight then return nil end
  while #current.queue > 0 do
    local index = table.remove(current.queue, 1)
    if not current.images[index] then return index end
  end
  return nil
end

---Move `index` to the head of the capture queue.
---
---The capture already in flight is deliberately not cancelled: a half-finished
---capture that is thrown away is wire and compositor time spent for nothing, and
---the reader waits at most one more chunk for letting it land.
function M.prioritise(session, index)
  local current = state(session)
  if not current or current.images[index] then return end
  for position, queued in ipairs(current.queue) do
    if queued == index then
      table.remove(current.queue, position)
      break
    end
  end
  table.insert(current.queue, 1, index)
end

---Record a captured chunk as resident.
function M.adopt(session, index, image_bytes, meta)
  local current = state(session)
  if not current then return false, "no resident state" end
  local chunk = resident.chunk(current.plan, index)
  if not chunk then return false, "no such chunk" end
  -- The renderer echoes back the region it was asked for. A reply that does not
  -- match is a chunk of somewhere else, which nothing downstream could detect.
  local want_y = math.floor(chunk.css_y + 0.5)
  local got_y = math.floor((meta.regionYPx or -1) + 0.5)
  if math.abs(want_y - got_y) > 1 then
    return false, ("region reply is for %s, not %s"):format(tostring(meta.regionYPx), tostring(chunk.css_y))
  end

  local image_id, err = session.backend.upload(image_bytes)
  if not image_id then return false, err or "upload failed" end
  current.images[index] = image_id
  current.captured = current.captured + 1
  current.bytes = current.bytes + (meta.pngBytes or #image_bytes)
  return true
end

---Retire chunks outside the window the reader needs, newest travel first.
function M.retain(session, center)
  local current = state(session)
  if not current then return end
  local cfg = config.get()
  local keep = resident.retain_window(current.plan, center, {
    max_chunks = cfg.image.resident_max_chunks,
    budget_bytes = cfg.image.resident_memory_mb * 1024 * 1024,
    bytes_per_px = resident.ITERM2_BYTES_PER_RESIDENT_PX,
    direction = current.travel,
  })
  local wanted = {}
  for _, index in ipairs(keep) do
    wanted[index] = true
  end
  local retire, requeue = {}, {}
  for index, image_id in pairs(current.images) do
    if not wanted[index] then
      retire[#retire + 1] = image_id
      requeue[#requeue + 1] = index
    end
  end
  if #retire == 0 then return end
  session.backend.retire(retire)
  for _, index in ipairs(requeue) do
    current.images[index] = nil
    current.captured = current.captured - 1
    current.queue[#current.queue + 1] = index
  end
end

---Draw the screen for `scroll_y` from resident chunks.
---
---Returns "drawn", or "waiting" with the chunk the reader needs next, or
---"failed" with a reason. Never returns a stale screen: a position that cannot
---be drawn from what is resident clears the preview instead, because leaving the
---previous picture up presents pixels of somewhere else as though they were this
---position.
function M.draw(session, scroll_y)
  local current = state(session)
  if not current then return "failed", "no resident state" end
  local plan = current.plan
  local needed, reason = resident.chunks_for(plan, scroll_y, plan.viewport_h)
  if not needed then return "failed", reason end

  for _, index in ipairs(needed) do
    if not current.images[index] then
      M.prioritise(session, index)
      return "waiting", index
    end
  end

  local placement = preview.placement(session.preview_win, session.backend.name)
  if not placement or placement.height ~= plan.rows then return "failed", "the pane changed size" end

  local parts
  if #needed == 1 then
    local window, window_reason = resident.source_window(plan, needed[1], scroll_y)
    if not window then return "failed", window_reason end
    parts = {
      { image_id = current.images[needed[1]], row = 0, rows = window.rows, src_y = window.src_y, src_h = window.src_h },
    }
  else
    local bands, bands_reason = resident.band_sources(plan, needed[1], needed[2], scroll_y)
    if not bands then return "failed", bands_reason end
    parts = {
      {
        image_id = current.images[bands.upper.index],
        row = bands.upper.row,
        rows = bands.upper.rows,
        src_y = bands.upper.src_y,
        src_h = bands.upper.src_h,
      },
      {
        image_id = current.images[bands.lower.index],
        row = bands.lower.row,
        rows = bands.lower.rows,
        src_y = bands.lower.src_y,
        src_h = bands.lower.src_h,
      },
    }
  end

  local ok, compose_reason = session.backend.compose(parts, placement)
  if not ok then return "failed", compose_reason end

  if current.drawn then
    current.travel = (needed[1] > current.drawn) and 1 or (needed[1] < current.drawn and -1 or current.travel)
  end
  current.drawn = needed[1]
  session.applied_scroll_y = scroll_y
  return "drawn"
end

---What the capture request for `index` looks like.
function M.capture_options(session, index)
  local current = state(session)
  local chunk = current and resident.chunk(current.plan, index)
  if not chunk then return nil end
  return {
    capture_only = true,
    capture_scale = "device",
    capture_region = { yPx = chunk.css_y, heightPx = chunk.css_h },
    resident_chunk = index,
  }
end

return M
