---Resident rendered regions: the coordinate model, and nothing else.
---
---md-viewer normally captures one viewport per scroll position and sends the
---pixels to the terminal. Over SSH those pixels are the whole cost. A *resident
---region* is a single capture covering several viewport-heights of the document,
---uploaded once, from which each scroll position is shown as a different **crop**
---of the same already-transmitted image -- so ordinary scrolling inside it costs
---a few hundred bytes of Kitty placement commands instead of a frame.
---
---This module owns the arithmetic that makes that safe, and deliberately owns
---nothing else: no `vim.api`, no backend, no timers, no session. Every function
---here is pure, so the whole coordinate model is testable headlessly -- the same
---reason `renderer/src/lanes.js` is a pure module on the Node side. Policy
---("is this a hit, should we fill, should we evict") belongs to the controller;
---graphics ("upload, place with this crop, delete") belongs to the raw Kitty
---backend, which never learns what a scroll is.
---
---# The four coordinate spaces this file converts between
---
---1. **Document CSS px** -- `scroll_y`, `document_height_px`, a region's
---   `doc_y`/`doc_h`. What Chromium scrolls in.
---2. **Viewport CSS px** -- the `Vw x Vh` box the browser renders into. Caret
---   rects, selection rects and hit-test points are already in this space and
---   stay correct under panning, because the crop presented is always exactly
---   one viewport.
---3. **Resident image px** -- the uploaded PNG's own pixels, which is the space
---   the Kitty protocol's `x,y,w,h` crop keys are in.
---4. **Placement cells** -- the terminal grid. Handled entirely by the backend;
---   this module never sees it.
---
---Space 4 is absent on purpose. A prior class of graphics defects in this project
---came from mixing document scrolling, source cropping and destination placement
---in one expression, so the split is structural: this module answers "which
---rectangle of the image is the viewport", the backend answers "which cells does
---that rectangle go in", and neither can express the other's mistake.
---
---# Why scale is measured rather than requested
---
---`scale_x`/`scale_y` are derived from the PNG's real IHDR dimensions, never from
---the `captureScale`/`device_scale_factor` that was asked for. The renderer's
---Playwright fallback cannot express a sub-1x capture factor and silently returns
---a full-size frame (`renderer/src/browser.js`, `captureViewportPng`), so a
---region built from the requested scale would be wrong on that path and right on
---the other. Measuring makes one formula correct on both.

local M = {}

--- How much of a region's usable travel is spent *behind* the reader.
---
--- Reading is forward-biased, so most of the slack should be ahead -- but not
--- all of it, or an overshoot or a glance back at the previous paragraph is
--- immediately a cache miss.
---
--- Expressed as a share of the available slack rather than as a fraction of a
--- viewport, which matters at small regions: a region only 1.25 viewports tall
--- has a quarter of a viewport of travel in total, and an anchor stated in
--- viewport units would place it outside its own region.
local BACKWARD_SHARE = 0.25

--- The smallest region worth the memory. Below this the region barely exceeds
--- the viewport, so nearly every scroll is still a miss while a full viewport of
--- decoded pixels sits in the terminal paying for it. A document that fits
--- entirely in one region is exempt -- see `M.plan_region`.
local K_MIN = 1.25

--- The largest, whatever the budget allows. A region is transmitted in one
--- uninterrupted upload that nothing can cancel once it has been handed to the
--- terminal, so its size is a stall the reader sits through. Measured on
--- Chromium 151 at 990x1020@2 (scripts/resident/probe.mjs): four viewports is
--- ~1.7 MB, about 2.8s on the 0.80 MB/s link this exists for. Eight would be
--- 5.7s, which is not a preview.
local K_MAX = 4.0

--- Refuse a region whose two axes disagree about the capture scale. They cannot
--- disagree legitimately -- the clip is uniform -- so a mismatch means the image
--- is not what it claims and every crop taken from it would be subtly wrong.
--- Refusing is the house style here: `crop_within` in the backend refuses rather
--- than clamps for the same reason.
local SCALE_TOLERANCE = 0.01

--- Chromium and terminal safety nets, not the policy. The budget binds first in
--- every ordinary configuration; these bound the pathological ones. The probe
--- measured 32.3 Mpx and 16,320px tall both succeeding on Chromium 151, so these
--- sit below what was demonstrated rather than at it.
local MAX_REGION_PIXELS = 12000000
local MAX_REGION_HEIGHT_PX = 16384

--- Document-space comparisons are exact arithmetic on values that have been
--- through a float divide, so "the viewport ends exactly where the region does"
--- needs a tolerance to survive the last bit. Far below a pixel, so it can never
--- admit a viewport that is genuinely uncovered.
local EPS = 1e-6

--- How much of a fresh throughput sample survives into the estimate. A
--- single-pole filter rather than a running mean: the link this exists for
--- changes under the reader -- a VPN reconnect, a busier tunnel, a colleague
--- pulling a container image -- and a mean over the whole session would take
--- minutes to notice. Weighted toward history because one sample is noisy and
--- the cost of overreacting to a fast one is a resumed backlog.
local WIRE_SAMPLE_WEIGHT = 0.3

--- Below this a payload measures scheduling noise rather than a link. A moving
--- frame over SSH is ~80 KB and a settle frame ~305 KB, so this excludes only
--- things that were never a transfer -- and a rate estimated from one of those
--- would be enormous, which is the direction that silently disables the hold.
local MIN_WIRE_SAMPLE_BYTES = 65536

--- The floor on how far the adaptive PNG cap may shrink a region. A quarter of
--- the budget's height is already below `K_MIN` at any ordinary viewport, so the
--- planner will decline before this binds; it exists so a pathological document
--- cannot drive the height to zero and leave the session filling nothing forever.
local MIN_HEIGHT_SCALE = 0.25

M.BACKWARD_SHARE = BACKWARD_SHARE
M.K_MIN = K_MIN
M.K_MAX = K_MAX
M.MAX_REGION_PIXELS = MAX_REGION_PIXELS
M.MAX_REGION_HEIGHT_PX = MAX_REGION_HEIGHT_PX
M.MIN_WIRE_SAMPLE_BYTES = MIN_WIRE_SAMPLE_BYTES
M.MIN_HEIGHT_SCALE = MIN_HEIGHT_SCALE

local function finite(value)
  value = tonumber(value)
  if value == nil then return nil end
  if value ~= value or value == math.huge or value == -math.huge then return nil end
  return value
end

local function positive(value)
  value = finite(value)
  if value == nil or value <= 0 then return nil end
  return value
end

local function round(value) return math.floor(value + 0.5) end

local function clamp(value, low, high)
  if high < low then return low end
  return math.max(low, math.min(high, value))
end

---Build a region record from what was actually captured and uploaded.
---
---`image_w`/`image_h` must be the PNG's real dimensions as the backend read them
---out of its header -- not the size the capture was requested at. Returns the
---region, or `nil, reason` for anything that cannot be trusted to produce a
---correct crop. Every refusal here is a cache miss, which is slow; a region
---accepted on bad numbers is a wrong picture, which is worse.
---@return table|nil region, string|nil reason
function M.region(fields)
  local doc_y = finite(fields.doc_y)
  local doc_h = positive(fields.doc_h)
  local css_w = positive(fields.css_w)
  local image_w = positive(fields.image_w)
  local image_h = positive(fields.image_h)
  if doc_y == nil or doc_y < 0 then return nil, "region origin is not a document position" end
  if not doc_h then return nil, "region has no document height" end
  if not css_w then return nil, "region has no CSS width" end
  if not (image_w and image_h) then return nil, "region has no measured image dimensions" end

  local scale_x = image_w / css_w
  local scale_y = image_h / doc_h
  if math.abs(scale_x - scale_y) > SCALE_TOLERANCE then
    return nil, ("region scale disagrees between axes (%.4f horizontal, %.4f vertical)"):format(scale_x, scale_y)
  end

  return {
    doc_y = doc_y,
    doc_h = doc_h,
    css_w = css_w,
    image_w = image_w,
    image_h = image_h,
    scale_x = scale_x,
    scale_y = scale_y,
    key = fields.key,
    image_id = fields.image_id,
    placed = fields.placed == true,
  }
end

---Does this region hold every pixel a viewport at `scroll_y` would show?
---
---Containment, not overlap. A region that covers only part of the viewport is a
---miss: compositing the remainder from a second image is a whole feature this
---design deliberately does not have, and showing the covered part alone would
---leave a band of stale document on screen.
function M.covers(region, scroll_y, viewport_h)
  if not region then return false end
  scroll_y = finite(scroll_y)
  viewport_h = positive(viewport_h)
  if scroll_y == nil or not viewport_h then return false end
  if scroll_y < region.doc_y - EPS then return false end
  return scroll_y + viewport_h <= region.doc_y + region.doc_h + EPS
end

---The exact scroll positions at which `region` is a hit, as `first, last`.
---
---Exported because it is the honest statement of what a region bought, and
---because it is far easier to assert directly than to infer from a sequence of
---`covers` calls. `last - first` is the region's total travel and is always
---`doc_h - viewport_h` -- the viewport itself consumes a viewport-height of the
---region, so a region two viewports tall yields *one* viewport of scrolling, not
---two. Where that travel sits relative to the reader is the anchor's doing
---(`M.plan_region`); how much of it there is, is not.
---
---Returns `nil` when the region cannot cover the viewport at all.
function M.pan_range(region, viewport_h)
  if not region then return nil end
  viewport_h = positive(viewport_h)
  if not viewport_h then return nil end
  local last = region.doc_y + region.doc_h - viewport_h
  if last < region.doc_y - EPS then return nil end
  return region.doc_y, last
end

---Which rectangle of the resident image is the viewport at `scroll_y`.
---
---Returns the crop in **image pixels** -- the space the Kitty protocol's
---`x,y,w,h` keys are in -- together with the scroll position those pixels
---actually show. Returns `nil, reason` when the region does not cover the
---viewport.
---
---## Why the vertical origin is snapped to a whole image pixel
---
---`(scroll_y - doc_y) * scale_y` is fractional in general. Left fractional, the
---backend's `floor` on each crop edge makes the emitted `h=` differ by a pixel
---between one scroll position and the next while the destination `r=` stays
---fixed, so the terminal rescales a slightly different source height into the
---same cells -- a sub-pixel vertical wobble that does not exist today, because
---today the origin is always zero. Snapping removes it: with an integer origin
---every crop edge is `origin + floor(...)`, so the height is stable.
---
---The second return is the consequence of that snap and is the value the caller
---must record as `applied_scroll_y`. It is what the pixels on screen genuinely
---show, and three things already read it as exactly that: the caret re-derives
---its position from it without a round trip (`caret.rect`), animation frames are
---placed from it (`animation.paint`), and every interact request carries it so
---Chromium scrolls to the position being pointed at. Recording the *requested*
---scroll instead would put all three half a device pixel out.
---@return table|nil source, number|string applied_scroll_y_or_reason
function M.source_window(region, scroll_y, viewport)
  if not region then return nil, "no region" end
  local viewport_h = positive(viewport and viewport.heightPx)
  local viewport_w = positive(viewport and viewport.widthPx)
  if not (viewport_h and viewport_w) then return nil, "viewport dimensions are unknown" end
  if not M.covers(region, scroll_y, viewport_h) then return nil, "region does not cover this viewport" end

  local src_h = viewport_h * region.scale_y
  local src_w = viewport_w * region.scale_x
  -- The window can never hang off the image: `covers` has already established
  -- it fits, so this only absorbs the rounding on the last row.
  local highest = math.max(0, region.image_h - src_h)
  local src_y = clamp(round((scroll_y - region.doc_y) * region.scale_y), 0, math.floor(highest))

  return {
    x = 0,
    y = src_y,
    width = math.min(src_w, region.image_w),
    height = math.min(src_h, region.image_h - src_y),
  },
    region.doc_y + src_y / region.scale_y
end

---Where the next region should start and how tall it should be.
---
---The budget is the invariant and the height is the *output*. Stating a region
---as "two viewports" and checking the budget afterwards is how a budget gets
---quietly exceeded: at 990x1020 CSS and device scale 2 a viewport is 4,039,200
---image pixels, so two of them are 8,078,400 -- over an 8,000,000 budget, by an
---amount nobody would notice until the terminal was holding it. Deriving the
---height from the budget cannot make that mistake.
---
---Returns `{ doc_y, doc_h, k, backward_slack, forward_slack }`, or `nil, reason`
---when no region worth having fits.
---@return table|nil plan, string|nil reason
function M.plan_region(opts)
  local scroll_y = finite(opts.scroll_y) or 0
  local viewport_h = positive(opts.viewport_h)
  local viewport_w = positive(opts.viewport_w)
  local document_h = positive(opts.document_height_px)
  local scale = positive(opts.scale)
  local budget_px = positive(opts.budget_px)
  local max_regions = math.max(1, math.floor(finite(opts.max_regions) or 1))
  if not (viewport_h and viewport_w) then return nil, "viewport dimensions are unknown" end
  if not document_h then return nil, "document height is unknown" end
  if not scale then return nil, "capture scale is unknown" end
  if not budget_px then return nil, "no resident budget" end

  -- Nothing to pan through. Resident pixels would be correct and completely
  -- useless, so decline rather than spend a viewport of terminal memory on a
  -- document that cannot scroll.
  if document_h <= viewport_h + EPS then return nil, "document fits the viewport" end

  local image_w = round(viewport_w * scale)
  if image_w < 1 then return nil, "capture would have no width" end

  -- Every clamp below is a *ceiling* on the height, applied in image pixels
  -- where the limits are stated and converted back once at the end.
  local by_budget = math.floor(budget_px / max_regions / image_w)
  local by_area = math.floor(MAX_REGION_PIXELS / image_w)
  local height_img = math.min(by_budget, by_area, MAX_REGION_HEIGHT_PX)
  local height_doc = math.min(height_img / scale, viewport_h * K_MAX, document_h)
  if height_doc <= viewport_h + EPS then return nil, "budget is smaller than one viewport" end

  local k = height_doc / viewport_h
  -- A region that holds the *whole* document is exempt from the minimum: it is
  -- the best a region can possibly be, and a short document should not be
  -- refused for the crime of being short.
  local whole_document = height_doc >= document_h - EPS
  if k < K_MIN and not whole_document then
    return nil, ("budget affords only %.2f viewports (minimum %.2f)"):format(k, K_MIN)
  end

  local slack = height_doc - viewport_h
  local doc_y = clamp(scroll_y - BACKWARD_SHARE * slack, 0, math.max(0, document_h - height_doc))
  return {
    doc_y = doc_y,
    doc_h = height_doc,
    k = k,
    -- What this region actually bought, after the document's ends have clamped
    -- the anchor. Reported rather than assumed: a region pinned to the top of
    -- the document has all of its travel ahead of the reader and none behind,
    -- and a caller reasoning from the nominal share would be wrong there.
    backward_slack = scroll_y - doc_y,
    forward_slack = doc_y + height_doc - viewport_h - scroll_y,
  }
end

---Everything that must match for a resident region to be reusable.
---
---A region outlives the frame it was captured with by minutes, so the key has to
---name every input that changes what the document *paints*, not merely what it
---says. Width because the body is centred with a max-width, so a narrower
---preview reflows every line. Height because the document's bottom padding is
---`calc(100vh - Npx)`, which makes the document's own scroll extent a function
---of viewport height. The content revision already folds in `render_epoch`, so
---an edit, an explicit refresh, and a remote image arriving are all covered by
---one component.
---
---Selection, find and caret state are deliberately absent. A region must never be
---captured with any of them painted in, which is a *scheduling* rule the
---controller enforces by declining to fill; putting them in the key instead would
---throw away a perfectly good region every time someone pressed escape.
function M.key(parts)
  return table.concat({
    tostring(parts.document_id),
    tostring(parts.renderer_revision),
    tostring(parts.viewport_width_px),
    tostring(parts.viewport_height_px),
    tostring(parts.theme),
    tostring(parts.background),
    tostring(parts.font_size_px),
    tostring(parts.scroll_past_end),
    tostring(parts.scroll_past_end_offset_px),
    tostring(parts.device_scale_factor),
  }, "\30")
end

-- ---------------------------------------------------------------------------
-- The cache.
--
-- Still pure with respect to Neovim: these functions move records between Lua
-- tables and *return* the regions whose pixels the caller must now free. They
-- never talk to a terminal, so the whole eviction policy is testable without
-- one -- and the caller cannot forget to free an evicted image, because the
-- eviction is what hands it to them.
-- ---------------------------------------------------------------------------

---A session's resident state. Created for every session, enabled for almost
---none: the gate is the controller's, and a disabled state costs one boolean
---test on the scroll path.
function M.new_state(opts)
  opts = opts or {}
  return {
    enabled = false,
    fallback_reason = nil,
    key = nil,
    -- Most recently used first, so eviction is `table.remove` from the end.
    regions = {},
    budget_px = positive(opts.budget_px) or 0,
    max_regions = math.max(1, math.floor(finite(opts.max_regions) or 1)),
    used_px = 0,
    -- `token` identifies which fill holds the one fill slot, so a superseded one
    -- returning late cannot release a slot it no longer owns.
    fill = { in_flight = false, token = 0 },
    desired_scroll_y = nil,
    -- The wire, as opposed to the cache. `upload_hold_until` is the millisecond
    -- after which another image payload may be emitted; `wire_bytes_per_ms` is
    -- what the link has been observed to do. Both describe the *link*, so they
    -- deliberately survive `M.drain` -- a document being closed does not make
    -- the bytes still crossing it arrive any sooner.
    upload_hold_until = 0,
    upload_hold_ms = 0,
    wire_bytes_per_ms = nil,
    wire_samples = 0,
    -- What fraction of the budget's height fills are currently allowed to use,
    -- reduced when a region's PNG comes back larger than the cap. Monotone
    -- downward on purpose: it is a session's accumulated evidence that this
    -- document costs more per viewport than the budget assumed, and letting one
    -- cheap region undo it would oscillate.
    height_scale = 1,
    -- How many times this session has halved its regions because the renderer
    -- refused to capture one. Bounded at one: a second refusal means the
    -- geometry is outside what this Chromium will take, which a third attempt
    -- would only rediscover.
    region_shrinks = 0,
    -- Diagnostics. Counts and bytes are kept apart deliberately: the size says
    -- what an operation costs, the count says how many were actually paid for,
    -- and neither implies the other.
    hits = 0,
    misses = 0,
    pans = 0,
    unplaced_places = 0,
    fills = 0,
    -- Two different discards, kept apart because they mean opposite things
    -- about the machinery. A *stale* fill could have been wrong -- it was
    -- superseded, or the document changed under it -- and dropping it is a
    -- correctness guard. An *abandoned* fill was merely useless: the reader
    -- left its range while it captured, so it is a wasted capture and nothing
    -- worse. One climbing is a defect; the other is a fast reader.
    stale_fills = 0,
    abandoned_fills = 0,
    evictions = 0,
    prefetches = 0,
    blocked_by_find = 0,
    blocked_by_selection = 0,
    frames_suppressed_by_hold = 0,
    -- Captures thrown away because the reader panned while they were in flight.
    -- A pan issues no request, so nothing else can notice it happened.
    superseded_by_pan = 0,
    height_reduced = 0,
    upload_bytes = 0,
    placement_bytes = 0,
  }
end

---The region covering `scroll_y`, or nil.
---
---Touches on read, because that is what makes the ordering an LRU rather than a
---queue: the region a reader keeps returning to must not be the one evicted to
---make room for the one they passed through once.
function M.find(state, scroll_y, viewport_h, key)
  if not (state and state.regions) then return nil end
  for index, region in ipairs(state.regions) do
    if region.key == key and M.covers(region, scroll_y, viewport_h) then
      if index > 1 then
        table.remove(state.regions, index)
        table.insert(state.regions, 1, region)
      end
      return region
    end
  end
  return nil
end

---Take `region` into the cache, evicting whatever has to go to make room.
---
---Returns `region, evicted` on success and `nil, evicted, reason` on refusal --
---`evicted` in both positions because a refusal can still have had to drop a
---superseded region on the way, and an image nobody frees is an image the
---terminal holds forever.
---
---The budget is checked against the region's **actual** pixel count, which is
---the whole point: a size predicted from the scale that was requested is wrong
---on the renderer's Playwright fallback path, and a budget checked against a
---prediction is a budget that can be exceeded without anyone noticing.
function M.insert(state, region)
  local evicted = {}
  local cost = region.image_w * region.image_h

  -- Anything that is no longer valid, and anything this region replaces
  -- outright, goes first -- before the budget is consulted, so a refill of the
  -- same range is never blocked by the copy it is replacing.
  for index = #state.regions, 1, -1 do
    local existing = state.regions[index]
    local superseded = existing.key ~= region.key or (existing.doc_y == region.doc_y and existing.doc_h == region.doc_h)
    if superseded then
      table.remove(state.regions, index)
      state.used_px = state.used_px - existing.image_w * existing.image_h
      evicted[#evicted + 1] = existing
    end
  end

  if cost > state.budget_px then
    return nil, evicted, ("region of %d px exceeds the whole %d px budget"):format(cost, state.budget_px)
  end

  while #state.regions > 0 and (#state.regions >= state.max_regions or state.used_px + cost > state.budget_px) do
    local oldest = table.remove(state.regions)
    state.used_px = state.used_px - oldest.image_w * oldest.image_h
    state.evictions = state.evictions + 1
    evicted[#evicted + 1] = oldest
  end

  table.insert(state.regions, 1, region)
  state.used_px = state.used_px + cost
  return region, evicted
end

---Empty the cache, returning every region so the caller can free its pixels.
---Used by close, retarget and fallback -- the paths that end a session's claim
---on the terminal's memory.
function M.drain(state)
  local regions = state.regions
  state.regions = {}
  state.used_px = 0
  state.key = nil
  -- The token carries over rather than resetting, so a fill issued before this
  -- drain cannot release the slot a fill issued after it is holding. Without
  -- that, retargeting mid-capture leaves two fills believing they are the one.
  state.fill = { in_flight = false, token = state.fill and state.fill.token or 0 }
  state.desired_scroll_y = nil
  -- `upload_hold_until` and `wire_bytes_per_ms` are deliberately untouched: they
  -- describe the link, and closing a document does not make the bytes still
  -- crossing it arrive any sooner.
  return regions
end

---An estimate of what a region costs the terminal once decoded, in bytes.
---
---Labelled an estimate because it is one: iTerm2's internal representation is
---not documented, and 4 bytes per pixel is the assumption a measurement has to
---check rather than a fact it can rest on. Budgeting is done in pixels for
---exactly that reason -- `renderer/src/media.js` already states the animation
---upload budget the same way, so the two are comparable.
function M.decoded_bytes(region) return (region.image_w or 0) * (region.image_h or 0) * 4 end

-- ---------------------------------------------------------------------------
-- The wire.
--
-- A region is not free to send. It is several hundred kilobytes of base64 down
-- the same pty as every other frame, and once `nvim_ui_send` has taken them
-- nothing can recall them -- the UI queue is asynchronous, so Lua can hand the
-- terminal twenty more frames while the first is still crossing the link.
--
-- The renderer's `settle` lane does not help with this. It stops a region fill
-- and a moving capture from cancelling each other *inside Node*; it creates no
-- second transport. So the region and the frames it was meant to replace share
-- one constrained resource, and without the arithmetic below the feature would
-- rebuild the very backlog it exists to remove.
--
-- These are pure so the policy above them can be tested against a simulated
-- link rather than a real one.
-- ---------------------------------------------------------------------------

---Fold one observed payload into the session's throughput estimate.
---
---`elapsed_ms` is how long the backend's write to `nvim_ui_send` actually
---blocked. On a saturated pty that is real back-pressure and most of the
---transfer: the reverted client-render measurements recorded a 471 KB frame
---taking ~350 ms of blocked write on the 0.80 MB/s link this exists for, where
---the same frame takes 0.78 ms locally. Small payloads are ignored -- they
---measure the scheduler, not the link, and an inflated rate is the direction
---that silently disables the hold.
function M.note_wire_sample(state, bytes, elapsed_ms)
  if not state then return end
  bytes = positive(bytes)
  elapsed_ms = positive(elapsed_ms)
  if not (bytes and elapsed_ms) or bytes < MIN_WIRE_SAMPLE_BYTES then return end
  local sample = bytes / elapsed_ms
  local previous = positive(state.wire_bytes_per_ms)
  state.wire_bytes_per_ms = previous and (previous + (sample - previous) * WIRE_SAMPLE_WEIGHT) or sample
  state.wire_samples = (state.wire_samples or 0) + 1
end

---How long to keep the wire to itself after handing `bytes` to the terminal.
---
---The blocked write is most of the transfer but not all of it: the pty buffer
---takes the head of the payload immediately, so a tail is still crossing the
---link after the call returns. The hold is the estimated whole-payload wire
---time *less the part already spent*, which is what makes it zero by arithmetic
---rather than by exception on a fast link -- there the estimate is smaller than
---the elapsed time and the subtraction lands below zero.
---
---With no estimate yet the answer is `default_ms`, which the caller passes as
---the session's settle delay: a number already tuned for this link rather than
---a new constant nobody has measured. `max_ms` is the guarantee that a wrong
---estimate costs staleness and never a wedged preview.
---
---Whole milliseconds, and a sub-millisecond hold is no hold at all: the caller
---compares against `vim.uv.now()`, which counts in whole milliseconds, so a
---fractional hold would suppress a frame for a duration the clock cannot even
---represent.
function M.wire_hold_ms(bytes, bytes_per_ms, elapsed_ms, default_ms, max_ms)
  bytes = positive(bytes)
  elapsed_ms = math.max(0, finite(elapsed_ms) or 0)
  default_ms = math.max(0, finite(default_ms) or 0)
  max_ms = math.max(0, finite(max_ms) or default_ms)
  if not bytes then return 0 end
  local rate = positive(bytes_per_ms)
  if not rate then return math.floor(clamp(default_ms, 0, max_ms)) end
  return math.floor(clamp(bytes / rate - elapsed_ms, 0, max_ms))
end

---The new height scale after a region came back at `png_bytes` against a cap.
---
---A hold is damage control; a smaller region is prevention. The cap is stated
---in bytes by the caller because what a viewport costs to encode is a property
---of the document -- a page of prose and a page of syntax-highlighted code are
---not within a factor of each other -- so a constant here would be wrong for
---every document but the one it was measured on.
---
---Only ever reduces. Returning the scale unchanged when the region fits is what
---keeps it from oscillating between two heights on a document whose regions
---straddle the cap.
function M.png_cap_scale(scale, png_bytes, cap_bytes)
  scale = positive(scale) or 1
  png_bytes = positive(png_bytes)
  cap_bytes = positive(cap_bytes)
  if not (png_bytes and cap_bytes) or png_bytes <= cap_bytes then return scale end
  return clamp(scale * (cap_bytes / png_bytes), MIN_HEIGHT_SCALE, scale)
end

return M
