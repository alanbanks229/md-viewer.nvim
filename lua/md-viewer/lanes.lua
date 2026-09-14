-- Per-session, per-lane staleness bookkeeping: the Lua half of
-- `renderer/src/lanes.js`.
--
-- The renderer solved this on its own side and the plugin did not. One
-- `session.request_serial` was shared by every kind of request a preview
-- issues, and `renderer.is_stale` compared a reply's serial against it, so
-- *any* newer request invalidated *every* older one. The costs of that were
-- documented twice at the sites that paid them:
--
--   controller.lua's chunk callback -- "a settle capture, a resize, a
--   ColorScheme or an OptionSet is enough to stale a chunk that is in
--   flight ... the warm-up simply stopped at n/N and stayed there."
--
-- The rule set, in one place, mirroring `lanes.js`:
--
--   bump content   -> invalidates content, capture, settle, resident
--   bump capture   -> invalidates capture only
--   bump settle    -> invalidates settle only
--   bump resident  -> invalidates resident only
--
-- Content is the lane that invalidates the others, and it does so through an
-- epoch rather than by touching their serials: any render can re-lay-out the
-- page, so a frame or a chunk captured against the old layout is worthless
-- whether or not the content revision changed with it. A theme flip or a
-- viewport change at an unchanged revision is exactly that case.
--
-- The lanes are not the renderer's four. The plugin's `interact` requests do
-- not pass through here -- they carry their own `visual_epoch` and are
-- superseded by the renderer's interact lane -- and the plugin has a fourth
-- kind the renderer does not distinguish: a resident document chunk, which is
-- the one whose loss was measurable.
--
-- Deliberately pure: no `vim.api`, no timers, no module state. Everything
-- lives on the session, so the rules are testable as arithmetic, the same
-- property that makes `resident.lua`'s invariants testable.

local M = {}

M.LANES = { "content", "capture", "settle", "resident" }

---The fields a session needs to take part. Called by `state.create`, so a real
---session always has them; `M.admit` repairs a table that does not (the
---low-level API's hand-rolled session tables, and their tests).
function M.fields() return { content = 0, capture = 0, settle = 0, resident = 0 } end

local function record(session)
  if not session.lanes then
    session.lanes = M.fields()
    session.lane_epoch = session.lane_epoch or 0
  end
  return session.lanes
end

---Which lane a `renderer.request` belongs to, from the options it was given.
---One place, so the controller's four call sites and this module cannot drift
---on what a request *is*.
---
---`capture_only` is the caller's intent; `degraded` is what `renderer.request`
---resolved it to. A capture whose cached content revision no longer matches
---becomes a full render on the wire, and a full render re-lays out the page --
---so it belongs in the lane that says so, whatever asked for it.
function M.lane_for(options, degraded_to_render)
  if degraded_to_render then return "content" end
  options = options or {}
  if options.resident_chunk ~= nil then return "resident" end
  if options.capture_only == true then return options.scroll_frame == true and "capture" or "settle" end
  return "content"
end

---Stamp a request into its lane and return its ticket.
---
---`request_serial` stays the session's monotonic request count -- it is what
---`:MdViewerDebug` reports as "requested" and what tells a reader how much
---this preview has asked for -- and is also the serial each lane stores, so
---two lanes can never hold the same one.
function M.admit(session, lane)
  local lanes = record(session)
  assert(lanes[lane] ~= nil, "md-viewer: unknown lane " .. tostring(lane))
  session.request_serial = (session.request_serial or 0) + 1
  if lane == "content" then session.lane_epoch = (session.lane_epoch or 0) + 1 end
  lanes[lane] = session.request_serial
  return { lane = lane, serial = session.request_serial, epoch = session.lane_epoch or 0 }
end

---Has anything happened since `ticket` was admitted that makes its reply
---worthless? Answers only the lane question; `renderer.is_stale` adds the
---session's own liveness on top.
function M.superseded(session, ticket)
  if not ticket then return false end
  local lanes = record(session)
  if lanes[ticket.lane] ~= ticket.serial then return true end
  return (session.lane_epoch or 0) ~= ticket.epoch
end

---Void everything in flight for this session. The two callers mean the same
---thing by it -- a closing document and a pane switching to another tab both
---have nothing to do with any reply still on its way -- and it is the content
---rule doing the work: the layout those replies were captured against is gone.
function M.invalidate(session)
  record(session)
  session.lane_epoch = (session.lane_epoch or 0) + 1
end

---What `:MdViewerDebug` reports. A copy, so a diagnostics buffer can never
---write back into the bookkeeping it is describing.
function M.snapshot(session)
  local lanes = record(session)
  return {
    epoch = session.lane_epoch or 0,
    content = lanes.content,
    capture = lanes.capture,
    settle = lanes.settle,
    resident = lanes.resident,
  }
end

return M
