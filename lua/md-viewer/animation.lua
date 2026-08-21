---Animated images in the preview.
---
---A frame of the preview is one Chromium screenshot, so an animated image
---painted into it is frozen by construction. The renderer decodes the real
---frames once -- in Chromium's own sandboxed codecs, at the size the image is
---actually drawn -- and the terminal draws them over the still frame the base
---already carries, on their own z-layer. How they move depends on what the
---active terminal was qualified for:
---
---  * "native": the Kitty graphics protocol's animation extension. Frames are
---    uploaded once with their own display gaps, the terminal is told to
---    loop, and this module goes idle -- no timer, no per-frame traffic, the
---    terminal owns every tick. Placement (scroll, occlusion cut-outs,
---    clipping) still belongs here, through the same machinery the frame-swap
---    path uses, because a placement of an animated image shows whatever
---    frame the terminal is currently on.
---  * "frames": client-driven. One shared timer walks each animation's own
---    gap timeline -- the source's native delays, not a canonical tick -- and
---    swaps which frame is placed. `render.animate_fps` caps the swap rate;
---    when the cap bites, the walk *skips* frames rather than stretching
---    them, so a capped animation stays the right length and merely gets
---    choppier.
---
---Geometry arrives with the *render response*, measured in the same pass that
---produced the base screenshot: the rects and the picture they overlay cannot
---disagree, which is what deleted the stale-rect race the previous design
---carried. Frames come over the side channel (`process.request("animation")`)
---addressed purely by content hash and drawn size. **This module never calls
---`renderer.request`** -- a frame fetch must never bump `request_serial` and
---mark a user's render stale.
---
---Terminal ownership: uploaded images are cached under stable content keys
---(hashes of source bytes and drawn size, never temp paths) and shared across
---sessions -- and across renderer restarts, whose new process derives the
---same keys. When a session stops wanting a key (close, resize, document
---change), the keys no live session references are freed with the
---data-releasing delete; `clear_all` remains the exit-time backstop.

local M = {}

local config = require("md-viewer.config")
local process = require("md-viewer.process")
local cellpixels = require("md-viewer.cellpixels")
local debug_log = require("md-viewer.debug")

-- One timer for every session, not one per session and certainly not one per
-- image. delphinus/md-render.nvim found per-image timers caused visible
-- flicker; the same argument holds per session, since N independent timers
-- write to one `nvim_ui_send` stream at N unsynchronised phases. The timer is
-- one-shot and re-armed to the next moment anything actually changes -- a
-- document of slow animations ticks slowly, and one whose animations all went
-- native (or all stopped) does not tick at all.
local ticker = nil
local sessions = {}

-- Forward-declared locals (assigned below) so the tick, the request callback
-- and the lifecycle functions can reference each other without becoming
-- accidental globals.
local tick
local arm_ticker
local ensure_ticker

-- Whole frames transmitted per session per tick while a native upload
-- streams. Pacing is at frame granularity because one frame's escape-code
-- chunks must stay one atomic write (see animation_native_frame in
-- kitty_raw.lua); this budget only decides how many whole frames ride each
-- tick so the UI stream is never starved for long.
local UPLOAD_BYTES_PER_TICK = 256 * 1024

-- Floor for the shared timer. Also the fastest the frames strategy can swap.
local MIN_TICK_MS = 33

-- How long a transient failure (renderer error, evicted source) waits before
-- the tick loop may re-ask, so a persistent failure costs a request every
-- couple of seconds rather than one per tick.
local RETRY_MS = 2000

local function now_ms() return M._internal.now() end

local function min_gap_ms()
  local fps = config.get().render.animate_fps or 5
  return math.max(MIN_TICK_MS, math.floor(1000 / fps + 0.5))
end

---Read one frame PNG, bounded by the same ceiling every other renderer file
---read honours. Synchronous by choice: each frame is read at most once per
---process (the upload cache is keyed by stable content and checked first),
---and frames are drawn-size PNGs -- tens to a few hundred KB -- not captures.
local function read_frame(path)
  local limit = config.get().render.max_png_bytes or (32 * 1024 * 1024)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.size > limit then return nil end
  local fd = vim.uv.fs_open(path, "r", 384)
  if not fd then return nil end
  local data = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  return data
end

---Whether this session may place animation frames right now.
---
---Every condition here is a reason to leave the still frame alone, and each is
---checked every tick rather than latched: a preview that is occluded now may be
---visible in 200ms, and the cost of asking is a few table lookups.
local function permitted(session)
  local backend = session.backend
  -- `cells` has no pixels at all, and `nvim_img` exposes no sub-cell placement
  -- API to position a frame with.
  if not backend or backend.name ~= "kitty_raw" then return false, "backend does not place raw images" end
  if not backend.animation_supported then return false, "backend has no animation support" end
  local ok, reason = backend.animation_supported()
  if not ok then return false, reason end
  -- Nothing to composite over. A frame placed with no base under it would be a
  -- picture floating on the terminal background.
  if not session.image_id or not session.last_placement then return false, "no frame is on screen" end
  if session.loading or session.render_failed then return false, "the preview is not showing a frame" end
  if session.ui_suppressed then return false, "the UI is suppressed" end
  if session.occluded then return false, "the preview is occluded" end
  -- Covers the brief window between a mouse press and its release, during
  -- which `M.caret_from_click`'s round trip is landing a new base frame. The
  -- gate is the *press*, not the pointer table: releasing leaves the table
  -- alive (only interaction.forget nils it), and a visual-mode synthetic
  -- pointer exists with pressed=false -- gating on the table's existence
  -- killed animation for the rest of the session after one click.
  if session.pointer and session.pointer.pressed then return false, "a click is in progress" end
  -- The one gate that actually matters for a sustained gesture: a keyboard
  -- selection extension re-uploads the base and repaints tint rectangles at
  -- up to 40fps, and interleaving animation writes fights it for the same
  -- stream and composites over a base that is one frame stale.
  if session.visual_active then return false, "a visual selection is active" end
  return true
end

---The drawn-pixels-per-CSS-pixel scale, per axis. Separate axes on purpose:
---under the estimated calibration tier the viewport's height derives from
---`render.cell_aspect_ratio`, which generally does not equal the measured
---cell's own ratio -- one shared scale put every frame ~14% off vertically.
---Same derivation as overlay_apply's, for the same reason.
local function scales(session)
  local placement = session.last_placement
  local cell = cellpixels.measure()
  if not placement or not cell then return nil end
  local width_px = session.viewport_width_px
  local height_px = session.viewport_height_render_px or session.viewport_height_px
  if not width_px or width_px <= 0 or not height_px or height_px <= 0 then return nil end
  return (placement.width * cell.width) / width_px, (placement.height * cell.height) / height_px
end

local function strategy_for(session)
  local backend = session.backend
  if backend.animation_native_supported and (backend.animation_native_supported()) then return "native" end
  return "frames"
end

---Which sessions still reference `key`, other than `excluding`. Sessions
---share the backend's upload cache, so freeing is a question about every live
---session, not about the one letting go.
local function key_referenced(key, excluding)
  for session in pairs(sessions) do
    if session ~= excluding then
      for _, asset in pairs(session.animation_assets or {}) do
        if asset.terminal_keys and asset.terminal_keys[key] then return true end
      end
    end
  end
  return false
end

local function free_keys(backend, keys, excluding)
  if not backend or not backend.animation_free then return end
  local unreferenced = {}
  for key in pairs(keys) do
    if not key_referenced(key, excluding) then unreferenced[#unreferenced + 1] = key end
  end
  table.sort(unreferenced)
  if #unreferenced > 0 then pcall(backend.animation_free, unreferenced) end
end

---Cumulative end-times of each frame, for position lookups. Built once per
---materialization; the walk below then advances from the last index instead
---of searching, so a tick costs O(frames skipped), not O(frames).
local function build_timeline(asset)
  local cumulative, total = {}, 0
  for index, frame in ipairs(asset.frames) do
    total = total + math.max(1, frame.gapMs or 1)
    cumulative[index] = total
  end
  asset.cumulative = cumulative
  asset.total_ms = total
end

---The frame a frames-strategy asset shows at `now`, honouring the loop count:
---a finite animation freezes on its last frame, exactly as a browser leaves a
---non-looping GIF.
local function frame_index_at(asset, now)
  if asset.stopped then return #asset.frames end
  local elapsed = math.max(0, now - (asset.started_ms or now))
  if asset.loop ~= "infinite" then
    local plays = math.floor(elapsed / asset.total_ms)
    if plays > (tonumber(asset.loop) or 0) then
      asset.stopped = true
      return #asset.frames
    end
  end
  local position = elapsed % asset.total_ms
  local index = asset.scan_index or 1
  if position < (index > 1 and asset.cumulative[index - 1] or 0) then index = 1 end
  while position >= asset.cumulative[index] and index < #asset.frames do
    index = index + 1
  end
  asset.scan_index = index
  return index
end

---When this asset next changes appearance, in absolute ms; nil once stopped.
local function next_change_at(asset, now)
  if asset.stopped then return nil end
  local elapsed = math.max(0, now - (asset.started_ms or now))
  local position = elapsed % asset.total_ms
  local boundary = asset.cumulative[asset.scan_index or 1] or asset.total_ms
  if boundary <= position then boundary = asset.total_ms end
  return now + (boundary - position)
end

-- ---------------------------------------------------------------------------
-- Materialization
-- ---------------------------------------------------------------------------

---Reconcile the session's assets with the geometry its latest render
---reported. Assets whose content and drawn size are unchanged carry their
---runtime state across -- a re-render must not restart every animation, and
---an edit that re-mints ids does not change what is playing: the same bytes
---at the same size are the same animation mid-motion. Everything no longer
---wanted is dropped and its terminal keys freed if no other session holds
---them.
local function reconcile(session)
  local sx, sy = scales(session)
  local geometry = session.animation_geometry
  -- A transiently unmeasurable cell (or a session that has not rendered yet)
  -- says nothing about what is wanted; freeing on it would churn uploads on
  -- every hiccup. Only real geometry may shrink the asset set.
  if not sx or type(geometry) ~= "table" then return end

  local previous = session.animation_assets or {}
  local by_key = {}
  for _, asset in pairs(previous) do
    by_key[asset.key] = asset
  end

  local strategy = strategy_for(session)
  local assets = {}
  for _, rect in ipairs(geometry) do
    if rect.id and rect.sha then
      local target_w = math.floor(rect.widthPx * sx + 0.5)
      local target_h = math.floor(rect.heightPx * sy + 0.5)
      if target_w >= 1 and target_h >= 1 then
        local key = ("%s:%dx%d"):format(rect.sha, target_w, target_h)
        local carried = by_key[key]
        local asset
        if carried and carried.strategy == strategy then
          asset = carried
          by_key[key] = nil -- claimed; whatever remains is unwanted
        else
          asset = { key = key, sha = rect.sha, strategy = strategy, terminal_keys = {} }
        end
        asset.id = rect.id
        asset.rect = rect
        asset.target_w = target_w
        asset.target_h = target_h
        assets[rect.id] = asset
      end
    end
  end

  local freed = {}
  for _, leftover in pairs(by_key) do
    if leftover.terminal_keys then
      for key in pairs(leftover.terminal_keys) do
        freed[key] = true
      end
    end
  end
  session.animation_assets = assets
  -- On change only: reconcile runs once per render, and a preview being
  -- scrolled renders often enough to push everything else out of a 200-entry
  -- ring. `rects` beside `assets` is the pair that names this module's two
  -- silent failures -- no geometry measured, or geometry that scaled to a
  -- sub-pixel target and was dropped.
  local count = vim.tbl_count(assets)
  if count ~= session.animation_asset_count then
    debug_log.log("animation.reconcile", { rects = #geometry, assets = count, strategy = strategy })
    session.animation_asset_count = count
  end
  if next(freed) then free_keys(session.backend, freed, session) end
end

---Ask the renderer for any assets that still lack frames. Addressed by
---(sha, drawn size); each answer is applied only if the asset that asked still
---wants that exact content at that exact size -- geometry can move on while a
---decode runs, and an answer for a size nobody wants anymore is dropped, not
---misfiled.
local function request_frames(session)
  if session.animation_pending then return end
  local now = now_ms()
  local wanted, by_id = {}, {}
  for _, asset in pairs(session.animation_assets or {}) do
    if not asset.frames and not asset.refused and (asset.retry_at or 0) <= now then
      local item = { id = asset.id, sha = asset.sha, targetWidthPx = asset.target_w, targetHeightPx = asset.target_h }
      wanted[#wanted + 1] = item
      by_id[asset.id] = item
    end
  end
  if #wanted == 0 then return end
  -- By the id's number, not its text: ids are `a1`, `a2`, ... `a10`, and a
  -- string sort puts `a10` between `a1` and `a2`. Only an ordering wobble
  -- today, since the renderer mints at most MAX_ANIMATIONS_PER_DOCUMENT = 4 of
  -- them -- but the sort exists to make the request deterministic, and above
  -- nine it silently would not be.
  table.sort(wanted, function(a, b)
    local an, bn = tonumber(a.id:match("%d+")), tonumber(b.id:match("%d+"))
    if an and bn and an ~= bn then return an < bn end
    return a.id < b.id
  end)

  session.animation_pending = true
  local generation = session.animation_generation or 0
  process.request("animation", { requests = wanted }, function(result, err)
    -- A session forgotten, retargeted, or restarted mid-flight must not have
    -- state resurrected onto it by this late answer.
    if not sessions[session] or (session.animation_generation or 0) ~= generation then return end
    session.animation_pending = false
    if err or not result or type(result.animations) ~= "table" then
      session.animation_last_error = err and tostring(err) or "no answer"
      debug_log.log("animation.request_failed", { reason = session.animation_last_error, wanted = #wanted })
      for _, item in ipairs(wanted) do
        local asset = (session.animation_assets or {})[item.id]
        if asset then asset.retry_at = now_ms() + RETRY_MS end
      end
      ensure_ticker()
      return
    end
    for _, answer in ipairs(result.animations) do
      local item = by_id[answer.id]
      local asset = (session.animation_assets or {})[answer.id]
      -- Same asset, same size it asked for: a resize between ask and answer
      -- re-keys the asset, and this answer then belongs to nobody.
      if
        item
        and asset
        and not asset.frames
        and asset.target_w == item.targetWidthPx
        and asset.target_h == item.targetHeightPx
      then
        if answer.status == "ok" then
          asset.frames = answer.frames
          asset.loop = answer.loop
          asset.decode_ms = answer.decodeMs
          asset.refused = nil
          build_timeline(asset)
          if asset.strategy == "frames" then
            asset.started_ms = now_ms()
            asset.scan_index = nil
            asset.stopped = nil
          end
          debug_log.log("animation.frames", {
            key = asset.key,
            frames = #(asset.frames or {}),
            loop = asset.loop,
            decode_ms = asset.decode_ms,
          })
        elseif answer.status == "refused" then
          -- The input's own fault (too big, not animated, over budget):
          -- permanent for this content at this size. The still frame stands.
          asset.refused = answer.reason or "refused"
          debug_log.log("animation.refused", { key = asset.key, reason = asset.refused })
        else
          -- unknown-source or error: the environment's fault. The next render
          -- re-registers evicted bytes; until then, retry with a floor.
          asset.retry_at = now_ms() + RETRY_MS
          session.animation_last_error = answer.reason or answer.status
          debug_log.log("animation.decode_error", { key = asset.key, reason = session.animation_last_error })
        end
      end
    end
    M.repaint(session)
    ensure_ticker()
  end)
end

-- ---------------------------------------------------------------------------
-- Native upload and painting
-- ---------------------------------------------------------------------------

---Stream the next slice of a native asset to the terminal. Returns whether it
---advanced, and the remaining byte budget. Always admits at least one frame
---per call so a frame larger than the whole budget still makes progress.
local function pump_native(session, asset, budget)
  local backend = session.backend
  if asset.native_ready or not asset.frames then return false, budget end
  local advanced = false

  if not asset.native_begun then
    local first = asset.frames[1]
    local bytes = read_frame(first.path)
    if not bytes then
      -- Paths die with a renderer restart or an eviction; re-materialize.
      asset.frames = nil
      asset.retry_at = now_ms() + RETRY_MS
      return false, budget
    end
    local call_ok, id, existing = pcall(backend.animation_native_begin, asset.key, bytes, first.gapMs)
    if not call_ok or not id then
      -- `existing` holds the refusal reason when the call itself succeeded.
      session.animation_last_error = tostring(call_ok and existing or id)
      asset.refused = "native upload failed: " .. tostring(call_ok and existing or id)
      return false, budget
    end
    asset.native_id = id
    asset.native_begun = true
    asset.native_sent = 1
    asset.terminal_keys[asset.key] = true
    if existing then
      -- The terminal already holds this whole animation -- a second preview,
      -- or this one from before a renderer restart. Nothing to stream.
      asset.native_ready = true
      return true, budget
    end
    budget = budget - #bytes
    advanced = true
  end

  while asset.native_sent < #asset.frames and (budget > 0 or not advanced) do
    local frame = asset.frames[asset.native_sent + 1]
    local bytes = read_frame(frame.path)
    if not bytes then
      -- A frame evicted mid-upload must not finish as a shorter loop: free
      -- the half and start over through a fresh materialization.
      pcall(backend.animation_free, { asset.key })
      asset.terminal_keys[asset.key] = nil
      asset.frames, asset.native_begun, asset.native_sent = nil, nil, nil
      asset.retry_at = now_ms() + RETRY_MS
      return advanced, budget
    end
    local call_ok, sent, why = pcall(backend.animation_native_frame, asset.key, bytes, frame.gapMs)
    if not call_ok or not sent then
      session.animation_last_error = tostring(call_ok and why or sent)
      return advanced, budget
    end
    asset.native_sent = asset.native_sent + 1
    budget = budget - #bytes
    advanced = true
  end

  if asset.native_sent >= #asset.frames then
    local call_ok, done, why = pcall(backend.animation_native_finish, asset.key, asset.loop)
    if call_ok and done then
      asset.native_ready = true
    else
      session.animation_last_error = tostring(call_ok and why or done)
    end
  end
  return advanced, budget
end

---Place every asset that has something to show. One `animation_apply` per
---session per call; the backend diffs, so an unchanged repaint emits nothing.
local function paint(session)
  local assets = session.animation_assets
  if not assets or not next(assets) then return false end
  local placement = session.last_placement
  if not placement then return false end
  local sx, sy = scales(session)
  if not sx then return false end
  local backend = session.backend
  local scroll_y = session.applied_scroll_y or 0
  local now = now_ms()

  local order = {}
  for id in pairs(assets) do
    order[#order + 1] = id
  end
  table.sort(order)

  local items = {}
  for _, id in ipairs(order) do
    local asset = assets[id]
    local image_id = nil
    if asset.strategy == "native" then
      if asset.native_ready then image_id = asset.native_id end
    elseif asset.frames then
      local frame = asset.frames[frame_index_at(asset, now)]
      if frame then
        image_id = backend.animation_uploaded and backend.animation_uploaded(frame.key) or nil
        if not image_id then
          local bytes = read_frame(frame.path)
          if bytes then
            local call_ok, uploaded = pcall(backend.animation_upload, frame.key, bytes)
            if call_ok and uploaded then image_id = uploaded end
          end
        end
        if image_id then asset.terminal_keys[frame.key] = true end
      end
    end
    if image_id then
      items[#items + 1] = {
        image_id = image_id,
        -- Document CSS coordinates minus the scroll, scaled per axis into
        -- drawn pixels: the renderer reported the rect once, and every later
        -- position is this arithmetic. That is what lets a scroll move the
        -- animation with no round trip.
        x = asset.rect.xPx * sx,
        y = (asset.rect.yPx - scroll_y) * sy,
        width = asset.target_w,
        height = asset.target_h,
      }
    end
  end

  if #items == 0 then return false end
  local call_ok, set_id, stats = pcall(backend.animation_apply, session.animation_set, items, placement)
  if not call_ok then
    session.animation_last_error = tostring(set_id)
    return false
  end
  if not set_id then
    session.animation_last_error = stats
    return false
  end
  session.animation_set = set_id
  session.animation_last_bytes = stats and stats.bytes
  return true
end

-- ---------------------------------------------------------------------------
-- The shared timer
-- ---------------------------------------------------------------------------

---When this session next needs a tick, in absolute ms; nil when nothing would
---move without one. Native-ready assets need no ticks at all -- that is the
---entire point of the native strategy.
local function next_due(session, now)
  local due = nil
  for _, asset in pairs(session.animation_assets or {}) do
    if asset.frames then
      if asset.strategy == "native" then
        if not asset.native_ready then due = now end
      elseif not asset.stopped then
        local at = next_change_at(asset, now)
        if at then due = math.min(due or at, at) end
      end
    elseif not asset.refused then
      local retry = math.max(asset.retry_at or now, now)
      due = math.min(due or retry, retry)
    end
  end
  return due
end

tick = function()
  local now = now_ms()
  local earliest = nil
  local uploading = false
  for session in pairs(sessions) do
    local ok, reason = permitted(session)
    -- Edges only. This runs every tick, so logging the state rather than the
    -- change would fill the ring with one repeated line while a selection is held.
    if reason ~= session.animation_suppressed_reason then
      debug_log.log("animation.suppression", { reason = reason or "resumed" })
    end
    session.animation_suppressed_reason = ok and nil or reason
    if not ok then
      -- Placements come down rather than sitting stale over a base that has
      -- moved on; uploaded data stays, so resuming costs placement bytes only
      -- (and a native animation keeps playing invisibly, ready to be
      -- re-placed mid-motion).
      M.clear(session)
    else
      local budget = UPLOAD_BYTES_PER_TICK
      for _, asset in pairs(session.animation_assets or {}) do
        if asset.strategy == "native" and asset.frames and not asset.native_ready then
          local _, remaining = pump_native(session, asset, budget)
          budget = remaining
          uploading = uploading or not asset.native_ready
          if budget <= 0 then break end
        end
      end
      paint(session)
      -- After the paint: a fetch answered on this very stack (tests; a warm
      -- Node cache) repaints from its own callback rather than doubling here.
      request_frames(session)
      session.animation_ticks = (session.animation_ticks or 0) + 1
    end
    local due = next_due(session, now)
    if due then earliest = math.min(earliest or due, due) end
  end

  if not earliest then
    M.stop()
    return
  end
  -- The fps cap is the frames-strategy floor; a streaming upload ticks at the
  -- timer's own floor so a multi-MB set does not crawl in one slice per gap.
  local floor = uploading and MIN_TICK_MS or min_gap_ms()
  arm_ticker(math.max(floor, math.min(math.max(earliest - now, 0), 1000)))
end

arm_ticker = function(delay)
  if not ticker then ticker = vim.uv.new_timer() end
  ticker:stop()
  -- One-shot, re-armed after every tick: the next due moment depends on which
  -- frame each animation is showing, so any fixed period is always wrong in
  -- one direction or the other.
  ticker:start(math.max(1, math.floor(delay)), 0, vim.schedule_wrap(tick))
end

ensure_ticker = function()
  local now = now_ms()
  for session in pairs(sessions) do
    if next_due(session, now) then
      arm_ticker(MIN_TICK_MS)
      return
    end
  end
end

-- ---------------------------------------------------------------------------
-- Lifecycle, called by controller.lua
-- ---------------------------------------------------------------------------

---Start (or refresh) animating `session`. Called from `apply_image` after a
---full frame lands, because that is the moment both facts are true: a base is
---on screen, and the geometry that arrived with it is the geometry the frames
---must be positioned against.
function M.adopt(session)
  if config.get().render.animate ~= true then return end
  sessions[session] = true
  -- Placements from the superseded frame refer to a base that has just been
  -- replaced, so they go before anything else is drawn -- and the current
  -- state is re-placed immediately below, in the same call, so nothing blinks.
  M.clear(session)
  reconcile(session)
  session.animation_strategy = next(session.animation_assets or {}) and strategy_for(session) or nil
  -- The same gate the tick applies. apply_image also lands interact frames --
  -- settle captures among them -- and painting those places a frame the very
  -- next tick tears down, churning the exact stream a selection extension is
  -- fighting for.
  local ok, reason = permitted(session)
  session.animation_suppressed_reason = ok and nil or reason
  if ok then
    -- Paint what is already here, then ask for what is missing: the answer's
    -- own repaint covers the arrival, so nothing paints twice.
    paint(session)
    request_frames(session)
  end
  ensure_ticker()
end

---Re-place the current state without advancing it. For anything that moves
---the base image but does not change the document: a float opening over the
---preview, a cmdline, a restore from cache, a scroll reconcile.
function M.repaint(session)
  if not sessions[session] then return end
  local ok, reason = permitted(session)
  session.animation_suppressed_reason = ok and nil or reason
  if not ok then return end
  paint(session)
end

---Delete this session's placements. Uploaded data stays: the loop comes round
---again (or the terminal is still playing it), and re-uploading on every
---occlusion would give back the whole reason this is affordable.
function M.clear(session)
  if session.animation_set and session.backend and session.backend.animation_clear then
    pcall(session.backend.animation_clear, session.animation_set)
  end
  session.animation_set = nil
end

---Drop `session` entirely: placements down, terminal keys nothing else
---references freed, the shared timer stopped when it was the last session.
function M.forget(session)
  M.clear(session)
  local freed = {}
  for _, asset in pairs(session.animation_assets or {}) do
    if asset.terminal_keys then
      for key in pairs(asset.terminal_keys) do
        freed[key] = true
      end
    end
  end
  sessions[session] = nil
  if next(freed) then free_keys(session.backend, freed, session) end
  session.animation_assets = nil
  session.animation_geometry = nil
  session.animation_strategy = nil
  -- An answer still in flight must find a clean slate: left true, a re-adopted
  -- session would never ask again -- and the generation bump refuses the
  -- answer itself.
  session.animation_pending = nil
  session.animation_generation = (session.animation_generation or 0) + 1
  if next(sessions) == nil then M.stop() end
end

---The renderer process died. Materialized frame *paths* died with its temp
---directory, so every asset must re-materialize -- but the terminal-side
---uploads are keyed by stable content, so when the new process answers with
---new paths under the same keys, nothing is re-transmitted -- and a native
---animation never even stops playing.
function M.renderer_exited()
  for session in pairs(sessions) do
    session.animation_pending = nil
    session.animation_generation = (session.animation_generation or 0) + 1
    for _, asset in pairs(session.animation_assets or {}) do
      if not asset.native_ready then
        -- A native upload interrupted mid-stream is a half animation the new
        -- process must not append to; drop it for a clean re-begin.
        asset.native_begun, asset.native_sent = nil, nil
      end
      asset.frames = nil
      asset.retry_at = 0
    end
  end
end

function M.stop()
  if not ticker then return end
  ticker:stop()
  ticker:close()
  ticker = nil
end

---Exported for tests only. `now` is the module's one clock so a test can
---drive time by hand instead of sleeping.
M._internal = {
  tick = function() tick() end,
  permitted = permitted,
  sessions = sessions,
  paint = paint,
  reconcile = reconcile,
  now = function() return vim.uv.now() end,
}

return M
