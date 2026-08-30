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
local coordinates = require("md-viewer.coordinates")
local linkrate = require("md-viewer.linkrate")
local preview = require("md-viewer.preview")
local resident = require("md-viewer.resident")

local M = {}

local function state(session) return session and session.resident end

---How a link rate reads in a reason string. Megabytes rather than the grouped
---bytes `linkrate.describe` prints, because this is a comparison against
---another rate and two numbers are easier to compare with fewer digits.
local function mbps(bytes_per_sec) return ("%.2f MB/s"):format(bytes_per_sec / 1000000) end

---Whether this session may use resident mode, decided once when it opens.
---
---Deliberately not re-decided per scroll: a session that oscillates between two
---rendering models is one whose behaviour nobody can reproduce.
---
---Two questions in order, and the order is the point. *Can* this terminal hold a
---document resident is a fact about the terminal, and a refusal there is final
----- no link rate makes iTerm2 pan chunks. *Should* it, under `"auto"`, is a
---fact about the link, and is the question `image.resident` is really asking:
---the warm-up and the terminal memory are paid on every link, and only a slow
---one pays them back. Asking the terminal first also keeps the reason honest,
---because "your terminal cannot do this" is what a reader on iTerm2 needs to
---hear, not a rate that would have been irrelevant either way.
function M.select_path(session)
  local cfg = config.get()
  if not session or not session.backend then return "cells", "no backend" end
  if session.backend.name == "cells" then return "cells", "text-only backend" end
  -- Ahead of every resident check: a locally rendered session scrolls by
  -- marker, and resident mode's whole reason to exist -- scrolling without
  -- pixels on the wire -- is already met better. Two scroll owners would be
  -- exactly the oscillation this function exists to prevent.
  if require("md-viewer.localrender").active() then return "viewport", "local render owns scrolling" end
  if cfg.image.resident == "off" then return "viewport", "image.resident = off" end
  local backend = session.backend
  if type(backend.resident_pan_supported) ~= "function" then
    return "viewport", "backend does not support resident placements"
  end
  local ok, reason = backend.resident_pan_supported()
  if not ok then return "viewport", reason or "terminal cannot pan resident chunks" end
  if cfg.image.resident == "on" then return "resident", "terminal supports cropped placements (image.resident = on)" end
  -- "auto" from here down. `linkrate.resolve` never measures anything and never
  -- estimates: it reports the number an environment variable, this config, or a
  -- `:MdViewerMeasureLink` run on this machine left behind, and nil when there
  -- is none. nil is the ordinary state of a machine nobody has measured, and it
  -- keeps the path that costs nothing up front -- guessing "probably slow"
  -- would buy every unmeasured reader a warm-up on the strength of nothing.
  local rate = linkrate.resolve()
  if not rate then
    return "viewport",
      'link speed unknown -- :MdViewerMeasureLink measures this machine, image.resident = "on" skips the question'
  end
  local cutoff = cfg.image.resident_below_bytes_per_sec
  if rate >= cutoff then
    return "viewport",
      ("link measures %s, at or above the %s cutoff (image.resident_below_bytes_per_sec)"):format(
        mbps(rate),
        mbps(cutoff)
      )
  end
  return "resident",
    ("terminal supports cropped placements, link measures %s (under %s)"):format(mbps(rate), mbps(cutoff))
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

---Take the composed screen down, keeping every chunk resident.
---
---The resident counterpart of `controller.clear_image`: the pixels are already
---in the terminal, so an occlusion must not cost them twice -- restoring is a
---re-crop, not a re-upload. Until this existed nothing could reach the bands at
---all, because `clear_image` only knew `session.image_id` and a resident
---session has none, so a focusable float over the preview left the document
---compositing underneath it.
---
---`current.drawn` is deliberately left alone. It is the retention centre and the
---travel direction, and an occlusion is not travel; whether a screen is up is
---`session.resident_screen`.
function M.unplace(session)
  local current = state(session)
  if not current then return end
  local backend = session.backend
  if backend and backend.uncompose then pcall(backend.uncompose) end
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
  -- Retiring an image frees its placements with it, so whatever was composed is
  -- off the screen now whether or not anyone asked for that.
  session.resident_screen = false
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
    -- The *resolved* theme, not the configured one. `render.theme = "auto"` is
    -- the default and md-viewer.renderer reads `background` at request time, so
    -- keying on the literal "auto" made a light/dark switch produce an identical
    -- key -- and an identical key is exactly how `begin` decides the chunks
    -- already in the terminal are still valid. `:set background=light` left a
    -- whole document of dark-theme pixels resident and no way to notice.
    theme = cfg.render.theme == "auto" and (vim.o.background == "dark" and "dark" or "light") or cfg.render.theme,
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

  -- `session.scroll_y` may be ahead of the frame `meta` describes, when a newer
  -- scroll was requested while this render was in flight. That is the right
  -- input and not a discrepancy to be corrected: it reaches `warm_order` and
  -- nothing else, and warm order is layer three of the three-layer split at the
  -- top of md-viewer.resident -- capture *priority*, never geometry.
  -- `chunk_plan` above takes no opening position at all, so a newer position
  -- cannot move a chunk boundary; all it does is warm the chunks the reader is
  -- heading for ahead of the ones they are leaving.
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
  -- Already being captured. Queueing it again would buy nothing -- the capture
  -- is not cancelled, and `next_chunk` would pop the duplicate and skip it once
  -- the real one lands -- but it would put a chunk in two places at once, and
  -- "queue plus captured plus in-flight accounts for every chunk in the plan"
  -- is the property that makes a stalled warm-up detectable.
  if current.in_flight == index then return end
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

---The first chunk a viewport at `scroll_y` needs that is not resident yet, or
---nil when the whole screen can be drawn from what is already here.
---
---Split out of `M.draw` rather than duplicated so the controller can ask the
---question *before* the compose: the loading indicator is a passive float and
---has to come down ahead of the placements, not after them, or the screen that
---replaces it keeps a spinner-shaped hole punched out of it.
function M.missing(session, scroll_y)
  local current = state(session)
  if not current then return nil end
  local needed = resident.chunks_for(current.plan, scroll_y, current.plan.viewport_h)
  if not needed then return nil end
  for _, index in ipairs(needed) do
    if not current.images[index] then return index end
  end
  return nil
end

---Whether `index` is one of the chunks a viewport at `scroll_y` needs right
---now -- i.e. whether composing for `scroll_y` would place `index`, as
---opposed to a chunk landing resident for a position the reader is not at.
---
---The controller asks this right after adopting a chunk, to tell "about to
---place pixels that only just arrived" apart from "landed for later, draw
---does not touch it yet".
---
---KEEP_IN_MIND: dormant on every host this plugin runs on as of 2026-08-29.
---This function's only caller (`controller.pump_resident`'s settle-before-
---placing check) is reached only when a session is on the resident render
---path, which under the default `image.resident = "auto"` needs both a measured
---link under `image.resident_below_bytes_per_sec` (4 MB/s; see `select_path`
---above) and a terminal profile that does not refuse resident_pan (kitty,
---ghostty, generic_kitty -- not iTerm2, which now refuses it in terminal.lua,
---and not WezTerm, which always has). The SSM reference host's link qualifies
---but runs iTerm2; the LAN reference host's link does not qualify. Neither
---exercises this today. `image.resident = "on"` skips the rate half of that,
---which is what the drive script below relies on.
---
---This is reachable in principle and covered by
---tests/lua/cases/resident_placement.lua -- it is not orphaned, just
---currently unexercised. Do not delete it because grep shows no live caller.
---`scripts/resident/drive.lua` is the existing harness that exercises the
---whole resident path end to end without a real slow-linked host -- it
---stubs `terminal.detect` to force `resident_pan = true` on a fake Kitty
---profile and a slow-chunks delay to stand in for the link:
---
---   nvim --headless -u NONE -i NONE -l scripts/resident/drive.lua [doc.md] --slow-chunks=2000
---
---Once a real host exercises this path again, delete this note. If you
---believe this path should be removed outright rather than left dormant
---(e.g. resident mode is being dropped, not just currently unexercised),
---that is a product decision -- raise it with the operator/orchestrator
---before deleting it.
---
---What forces a session onto this path without a real slow-linked Kitty or
---Ghostty host, taken verbatim from scripts/resident/drive.lua's own stub --
---paste into a scratch buffer and :source it, or run the script directly:
---
---   local terminal = require("md-viewer.terminal")
---   terminal.detect = function()
---     return {
---       graphics = "supported",
---       profile_id = "kitty",
---       label = "Kitty",
---       resident_pan = true,
---       reason = "forced for local testing",
---     }
---   end
---   require("md-viewer").setup({ image = { backend = "kitty_raw", resident = "on" } })
---
---then open a markdown buffer and :MdViewerToggle; :MdViewerDebug's
---render_path should read "resident". A real link is still whatever it is --
---pair this with process.request stubbed to defer chunk replies (see
---drive.lua's --slow-chunks) to see this function's branch actually taken.
function M.is_needed(session, scroll_y, index)
  local current = state(session)
  if not current then return false end
  local needed = resident.chunks_for(current.plan, scroll_y, current.plan.viewport_h)
  if not needed then return false end
  for _, candidate in ipairs(needed) do
    if candidate == index then return true end
  end
  return false
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

  local absent = M.missing(session, scroll_y)
  if absent then
    M.prioritise(session, absent)
    return "waiting", absent
  end

  local placement = preview.placement(session.preview_win, session.backend.name)
  if not placement or placement.height ~= plan.rows then return "failed", "the pane changed size" end

  -- Every chunk landing during warm-up calls this again for the reader's
  -- unchanged position, which used to recompose the same bands over and over:
  -- once per chunk, on top of a link already busy with that chunk's own
  -- upload. Composing is cheap on this side (a few hundred bytes, no pixels),
  -- but it is not free on the wire or on the terminal parsing it, and nothing
  -- downstream distinguishes "recomposed the same picture" from "moved to a
  -- new one" -- so a reader sitting still got a placement command interleaved
  -- with every chunk's transmission for no reason. Skip it when nothing this
  -- draw would produce has changed since the last one.
  --
  -- KEEP_IN_MIND: this whole function only runs for a session on the resident
  -- render path, which is currently unreached on every host this plugin runs
  -- on -- see the longer note on M.is_needed below for why and how to
  -- exercise it deliberately. Same rule: unexercised, not orphaned; do not
  -- delete for that reason alone, and raise removing the path itself with
  -- the operator/orchestrator rather than deciding it here.
  if
    session.resident_screen
    and current.drawn
    and session.applied_scroll_y == scroll_y
    and coordinates.same(placement, session.last_placement)
  then
    return "drawn"
  end

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

  -- The resident half of what `apply_image` records for a viewport frame. Not
  -- bookkeeping: `interaction.locate` resolves clicks against `last_placement`,
  -- `caret.rect` positions the caret in it, and `coordinates.same` decides
  -- whether the screen has to follow the window. Those worked in resident mode
  -- only because `show_cached` happened to have restored a placement of a stale
  -- frame -- the accident this change removes.
  session.resident_screen = true
  session.last_placement = vim.deepcopy(placement)

  if current.drawn then
    current.travel = (needed[1] > current.drawn) and 1 or (needed[1] < current.drawn and -1 or current.travel)
  end
  current.drawn = needed[1]
  session.applied_scroll_y = scroll_y
  -- What the screen now *shows*, which in resident mode is the same number:
  -- the bands were composed for this position, so there is no window where the
  -- two disagree the way a captured frame's can. `caret.rect` measures its
  -- drift against this, and left nil it read as 0 -- a caret at any non-zero
  -- scroll drifted a whole document off screen and was never drawn.
  session.frame_scroll_y = scroll_y
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
