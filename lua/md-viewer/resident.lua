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
--- Necessary and not sufficient: it bounds the payload, and the ceiling below
--- bounds the rate, which is the quantity that actually goes wrong.
local MIN_WIRE_SAMPLE_BYTES = 65536

--- Above this a sample did not cross a link at all, whatever its size.
---
--- The floor above guards one direction of the same failure and named it
--- correctly; it simply guards the wrong axis. A write to a pty with room in its
--- buffer returns at memory speed, so a *large* payload whose write did not
--- block produces exactly the enormous rate a tiny one does. The session this
--- was found on recorded 209,046 B/ms and 139,058 B/ms against a link doing 800:
--- SSH absorbed each payload, the write returned before a byte of it had left
--- the machine, and the hold computed from those numbers was zero every time.
---
--- 125,000 B/ms is 1 Gbit/s of line rate, and it is a ceiling rather than a
--- guess because this feature is gated to SSH sessions: a LAN is the fastest
--- link an SSH session is ever carried over, so a payload appearing to move
--- faster than one did not move over a link. Deliberately far above the 800 B/ms
--- this exists for rather than close to it -- discarding a real sample costs a
--- conservative default hold, while believing a fabricated one costs the backlog
--- the whole feature was built to remove, so the bound only rejects what is
--- impossible.
local MAX_WIRE_SAMPLE_BYTES_PER_MS = 125000

M.MAX_REGION_PIXELS = MAX_REGION_PIXELS
M.MAX_REGION_HEIGHT_PX = MAX_REGION_HEIGHT_PX
M.MIN_WIRE_SAMPLE_BYTES = MIN_WIRE_SAMPLE_BYTES
M.MAX_WIRE_SAMPLE_BYTES_PER_MS = MAX_WIRE_SAMPLE_BYTES_PER_MS

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
---The document position a whole image pixel of `region` lands on, nearest to
---`scroll_y`.
---
---The snap `source_window` applies, on its own, because a composite needs it
---before it knows what to crop: the two bands of a straddle must be derived from
---**one** document position, and that position has to be one both slices can
---express exactly. Deriving each band's crop from the raw scroll instead lets
---the two `math.floor`s in the backend disagree by a pixel, which is a
---duplicated or dropped scanline at the seam.
---
---Without `source_window`'s clamp, which exists to keep a *viewport*-tall window
---inside the image and would be wrong for a band that is a fraction of one.
function M.snap(region, scroll_y)
  if not region then return nil end
  scroll_y = finite(scroll_y)
  if scroll_y == nil then return nil end
  return region.doc_y + round((scroll_y - region.doc_y) * region.scale_y) / region.scale_y
end

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

--- How many viewports tall a slice is.
---
--- The boundary between slices is free now -- a viewport spanning two of them is
--- composited from both -- so nothing pushes this upwards except the per-capture
--- round trip. Everything pushes it down: a slice is one uninterrupted upload
--- that cannot be cancelled once handed to the terminal, so its size is the
--- longest a reader can be stuck behind bytes for somewhere they are not looking.
--- Two viewports is 810 KB at 990x1020 CSS and device scale 2, about 1.35 s on
--- the 0.80 MB/s link this exists for.
local SLICE_VIEWPORTS = 2

--- How many pane rows neighbouring slices share.
---
--- This is what makes the boundary free. The pane is split at a whole cell row:
--- the rows above it come from one slice, the rows below from the next. For that
--- split to exist, the upper slice has to reach at least to the first row
--- boundary at or after the lower slice's start -- which is less than one row
--- away. Two rows rather than one is float slack; at a 60-row pane it is 3% of a
--- slice, against the 100% a design that overlapped by a whole viewport would
--- pay.
local OVERLAP_ROWS = 2

--- How much of a slice's height survives the renderer refusing to capture it.
---
--- A quarter off rather than a half, and `SLICE_VIEWPORTS` is why: a slice must
--- still hold a viewport plus the overlap, so halving a two-viewport slice lands
--- *under* that minimum and leaves no smaller grid to retry with at all. Three
--- quarters of two viewports is one and a half, which is a legal grid and still
--- a real reduction -- and under a grid a 1.5-viewport slice is perfectly usable,
--- because its boundaries are composited rather than being cache misses.
---
--- A quarter is also as much as should ever be needed. `slice_grid` clamps to the
--- same `MAX_REGION_PIXELS` and `MAX_REGION_HEIGHT_PX` the renderer enforces, so
--- a refusal means the two sides disagree slightly about the geometry rather than
--- that the request was wildly too large.
local SLICE_SHRINK = 0.75

M.SLICE_VIEWPORTS = SLICE_VIEWPORTS
M.OVERLAP_ROWS = OVERLAP_ROWS
M.SLICE_SHRINK = SLICE_SHRINK

---The fixed grid of slices that covers a whole document.
---
---Derived once per document generation and then held, which is the point: a
---boundary has to be a property of the *document*, not of wherever the reader
---happened to stop when a region was last planned. Re-deriving it per fill is how
---slices stop lining up and the overlap invariant below stops holding.
---
---Boundaries are whole **image** pixels. The same document position then maps to
---an integer in every slice's own image space, so the two halves of a composite
---cannot disagree by half a pixel across the seam.
---
---`slice_scale` shortens every slice by the same factor, which is what a
---renderer refusing to capture one (`REGION_TOO_LARGE`) is answered with. It is
---an input to the *whole grid* rather than to one slice on purpose: a grid whose
---slices are not all the same height has no single overlap, so a viewport
---straddling one of its boundaries has no row it can be split on.
---
---Returns `nil, reason` when no grid worth having fits.
---@return table|nil grid, string|nil reason
function M.slice_grid(opts)
  local viewport_h = positive(opts.viewport_h)
  local viewport_w = positive(opts.viewport_w)
  local document_h = positive(opts.document_height_px)
  local scale = positive(opts.scale)
  local rows = positive(opts.rows)
  local slice_scale = positive(opts.slice_scale) or 1
  if not (viewport_h and viewport_w) then return nil, "viewport dimensions are unknown" end
  if not document_h then return nil, "document height is unknown" end
  if not scale then return nil, "capture scale is unknown" end
  if not rows then return nil, "pane row count is unknown" end

  -- Nothing to pan through. Resident pixels would be correct and completely
  -- useless, so decline rather than spend terminal memory on a document that
  -- cannot scroll.
  if document_h <= viewport_h + EPS then return nil, "document fits the viewport" end

  local image_w = round(viewport_w * scale)
  if image_w < 1 then return nil, "capture would have no width" end

  -- One pane row in CSS px, without asking anyone for a measured cell size: the
  -- pane shows exactly one viewport across `rows` rows, so the two are the same
  -- fact. `docs/terminal-support.md` states that a resident crop needs no
  -- measured cell -- it is scaled by `c`/`r` -- and this keeps that true.
  local row_h = viewport_h / rows
  local overlap_img = math.max(1, math.ceil(OVERLAP_ROWS * row_h * scale))
  local slice_img = math.floor(
    math.min(SLICE_VIEWPORTS * slice_scale * viewport_h * scale, MAX_REGION_HEIGHT_PX, MAX_REGION_PIXELS / image_w)
  )
  -- A slice shorter than a viewport plus the overlap could be spanned by three
  -- placements, and a stride at or below zero would never reach the document's
  -- end. Both are the same requirement stated twice, so state it once.
  local minimum_img = math.ceil((viewport_h * scale)) + overlap_img
  if slice_img < minimum_img then
    return nil,
      ("a slice of %d image px cannot hold a viewport of %d plus %d of overlap"):format(
        slice_img,
        math.ceil(viewport_h * scale),
        overlap_img
      )
  end
  local stride_img = slice_img - overlap_img

  local slice_h = slice_img / scale
  local stride = stride_img / scale
  -- Enough slices that the last one reaches the document's end. The last is
  -- allowed to run past it -- the renderer clamps a capture to the document and
  -- reports what it actually took -- so this only has to cover, not to fit.
  local count = math.max(1, math.ceil((document_h - slice_h) / stride) + 1)

  return {
    document_h = document_h,
    viewport_h = viewport_h,
    viewport_w = viewport_w,
    scale = scale,
    rows = rows,
    image_w = image_w,
    slice_h = slice_h,
    slice_img = slice_img,
    stride = stride,
    overlap = overlap_img / scale,
    count = count,
    slice_scale = slice_scale,
  }
end

---What one slice of this grid costs the terminal, in decoded pixels.
---
---The cost of the *tallest* slice, which is every slice but the last: the last
---is clamped to the document's end and so can only be cheaper. Asked before a
---capture rather than after, because a slice that cannot be kept is several
---hundred kilobytes of wire spent to learn something the arithmetic already
---knew.
function M.slice_cost_px(grid) return grid and grid.image_w * grid.slice_img or 0 end

---How many of this grid's slices the ceiling can hold at once, and whether that
---is all of them.
---
---Reported rather than enforced. A document larger than the memory allowed for
---it is an ordinary situation, not an error and not a refusal: the window slides
---and the reader pays an upload each time they cross it. What is *not* ordinary
---is having to infer that from `evictions` climbing, so both diagnostics say it
---directly.
---
---Deliberately not a promise that the whole document is held. No fixed ceiling
---can make that promise -- there is always a longer document -- so what the
---feature claims instead is the thing that is true at every size: a slice is
---uploaded once and never uploaded again while it stays in the window.
---@return number|nil slices, boolean|nil whole_document
function M.slices_that_fit(grid, memory_px)
  if not grid then return nil end
  local ceiling = positive(memory_px)
  local cost = M.slice_cost_px(grid)
  if not (ceiling and cost > 0) then return 0, false end
  local fit = math.floor(ceiling / cost)
  return math.min(fit, grid.count), fit >= grid.count
end

---Where slice `index` (0-based) starts and how tall it is, in document CSS px.
---@return table|nil slice
function M.slice(grid, index)
  if not grid then return nil end
  index = finite(index)
  if index == nil or index < 0 or index >= grid.count then return nil end
  local doc_y = index * grid.stride
  -- Clamped at the document's end so `doc_h` is what a capture can actually
  -- contain. A slice claiming pixels past the end would build a region whose
  -- measured scale disagrees with its nominal height, which `M.region` refuses.
  local doc_h = math.min(grid.slice_h, grid.document_h - doc_y)
  if doc_h <= 0 then return nil end
  return { index = index, doc_y = doc_y, doc_h = doc_h }
end

---Which slices a viewport at `scroll_y` is drawn from, as `first, last`.
---
---One when the viewport lies wholly inside a slice, two when it straddles a
---boundary. Never three: `slice_grid` refuses a slice shorter than a viewport
---plus the overlap, which is exactly the condition that bounds this at two.
---
---The straddle is the case the bounded-region design treated as a miss and
---answered with a screenshot. A grid cannot: its boundaries are permanent, so
---that fallback would fire forever at the same places.
---@return number|nil first, number|nil last
function M.slices_for(grid, scroll_y, viewport_h)
  if not grid then return nil end
  scroll_y = finite(scroll_y)
  viewport_h = positive(viewport_h) or (grid and grid.viewport_h)
  if scroll_y == nil or not viewport_h then return nil end
  scroll_y = clamp(scroll_y, 0, math.max(0, grid.document_h - viewport_h))

  -- The latest slice that starts at or before the reader. An earlier one would
  -- start further back and therefore end sooner, so it can never cover more of
  -- this viewport -- there is nothing to search.
  local first = clamp(math.floor(scroll_y / grid.stride + EPS), 0, grid.count - 1)
  local slice = M.slice(grid, first)
  if not slice then return nil end
  if slice.doc_y + slice.doc_h >= scroll_y + viewport_h - EPS then return first, first end
  if first + 1 >= grid.count then return first, first end
  return first, first + 1
end

---Where to split the pane between two slices, as a whole number of rows from
---its top.
---
---`upper` supplies rows `0 .. split-1` and `lower` the rest. The split has to be
---a row boundary because a Kitty placement occupies whole cells, and it has to
---lie inside both slices at once -- which is what the overlap buys: the window
---`[lower.doc_y, upper.doc_y + upper.doc_h]` is `overlap` tall, and a row is
---shorter than that, so a row boundary always falls inside it.
---
---`rows` overrides the grid's own row count, and callers that have a live
---placement should pass it. The two can differ without the document changing --
---`image.raw_statusline_guard_cells` is one way -- and a split computed against
---a pane that is not the one being drawn into lands the seam on the wrong row.
---A disagreement large enough that no row fits is refused here, which is a miss;
---guessing would be a misdrawn seam.
---
---Returns `nil, reason` when no such row exists, which must never happen for a
---grid `slice_grid` built and is a refusal rather than a guess when it does.
---@return number|nil split_rows, string|nil reason
function M.split_rows(grid, upper, lower, scroll_y, rows)
  if not (grid and upper and lower) then return nil, "no slices to split between" end
  scroll_y = finite(scroll_y)
  if scroll_y == nil then return nil, "scroll position is unknown" end
  rows = positive(rows) or grid.rows
  local row_h = grid.viewport_h / rows
  -- The first row boundary at or after the lower slice begins.
  local split = math.ceil((lower.doc_y - scroll_y) / row_h - EPS)
  if split < 1 then return nil, "the lower slice starts above the pane" end
  if split >= rows then return nil, "the lower slice starts below the pane" end
  -- And the upper slice must actually reach it, or its band would be sourced
  -- from pixels it does not have. `crop_within` would refuse the placement and
  -- the band would simply not draw, so this is checked here where it can be
  -- explained rather than there where it cannot.
  if scroll_y + split * row_h > upper.doc_y + upper.doc_h + EPS then
    return nil, "the upper slice does not reach the split"
  end
  return split
end

---The two crops a straddling viewport is drawn from, in each slice's own image
---pixels.
---
---Both derived from **one** document position -- `applied`, which `M.snap` has
---already put on a whole image pixel -- and never independently. The backend
---floors each crop edge, so two rects computed from two numbers that ought to be
---the same can end up a pixel apart: a scanline shown twice, or one dropped, at
---exactly the seam. Deriving them together makes that unstateable.
---
---The seam itself is a document position, `applied + split * row_h`, converted
---into each slice's image space. Grid boundaries are whole image pixels and both
---slices were captured at the same scale, so the same document position has the
---same fractional part in both and rounds the same way in both.
---
---Returns `nil, reason` for anything that cannot be drawn -- and every one of
---those is a cache miss for the caller, never a fallback: a slice can
---legitimately be shorter than the grid cell it occupies, because the renderer
---clamps a capture to the document's end.
---@return table|nil bands, string|nil reason
function M.band_sources(upper, lower, applied, viewport, rows, split)
  if not (upper and lower) then return nil, "a composite needs two slices" end
  local viewport_h = positive(viewport and viewport.heightPx)
  local viewport_w = positive(viewport and viewport.widthPx)
  rows = positive(rows)
  applied = finite(applied)
  split = finite(split)
  if not (viewport_h and viewport_w and rows) then return nil, "viewport or pane dimensions are unknown" end
  if applied == nil then return nil, "scroll position is unknown" end
  if split == nil or split < 1 or split >= rows then return nil, "the split is not a row inside the pane" end

  local row_h = viewport_h / rows
  local seam = applied + split * row_h
  local bottom = applied + viewport_h

  local upper_top = round((applied - upper.doc_y) * upper.scale_y)
  local upper_bottom = round((seam - upper.doc_y) * upper.scale_y)
  local lower_top = round((seam - lower.doc_y) * lower.scale_y)
  local lower_bottom = round((bottom - lower.doc_y) * lower.scale_y)
  if upper_top < 0 or upper_bottom > upper.image_h then return nil, "the upper band is not inside its slice" end
  if lower_top < 0 or lower_bottom > lower.image_h then return nil, "the lower band is not inside its slice" end

  local upper_h, lower_h = upper_bottom - upper_top, lower_bottom - lower_top
  if upper_h < 1 or lower_h < 1 then return nil, "a band would draw no pixels" end

  -- Each band's source height is scaled into its own row count by the terminal,
  -- so the two have to agree about what a row is worth or the seam is a visible
  -- change of scale. Rounding costs at most half a pixel at each edge; more than
  -- a whole image pixel per row means the two were derived from different
  -- numbers, which is exactly the mistake this function exists to prevent.
  local per_row_upper, per_row_lower = upper_h / split, lower_h / (rows - split)
  if math.abs(per_row_upper - per_row_lower) > 1 then
    return nil,
      ("the bands disagree about scale (%.3f against %.3f image px per row)"):format(per_row_upper, per_row_lower)
  end

  return {
    upper = {
      x = 0,
      y = upper_top,
      width = math.min(round(viewport_w * upper.scale_x), upper.image_w),
      height = upper_h,
    },
    lower = {
      x = 0,
      y = lower_top,
      width = math.min(round(viewport_w * lower.scale_x), lower.image_w),
      height = lower_h,
    },
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
-- What a session is holding.
--
-- Still pure with respect to Neovim: these functions move records between Lua
-- tables and *return* the regions whose pixels the caller must now free. They
-- never talk to a terminal, so the whole retention policy is testable without
-- one -- and the caller cannot forget to free an evicted image, because the
-- eviction is what hands it to them.
--
-- This was an LRU of at most `max_regions` regions, and that is the policy the
-- rebuild exists to remove. A region planned around wherever the reader stopped
-- has edges that move, so crossing one evicted and refilled: a real session
-- recorded 14 fills and 13 evictions in 141 seconds, ~971 KB each, for 38% more
-- traffic than sending a frame every time. What replaces it is a *fixed cell per
-- slice*, so a slice is either the one at its index or absent, and the only
-- thing that can displace it is the memory ceiling -- which ordinary documents
-- never reach.
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
    -- The grid this session's slices are cells of, and which generation of it.
    -- Derived once and held: a boundary has to be a property of the *document*,
    -- or "uploaded once and kept" is not a claim anyone can make. The counter
    -- exists because one thing regenerates a grid without changing the document
    -- -- a renderer refusing to capture a slice -- and a fill in flight across
    -- that names a cell of a grid that no longer exists.
    grid = nil,
    generation = 0,
    -- Slice index -> region. A hash rather than a list because the index *is*
    -- the identity: there is no ordering to maintain, no position to search for,
    -- and nothing that can be in the structure twice.
    slices = {},
    resident_px = 0,
    -- The ceiling, in decoded pixels rather than bytes so it is the same unit
    -- the images are measured in. `image.resident_memory_mb` states it in
    -- megabytes because that is the quantity a reader is actually spending;
    -- `BYTES_PER_RESIDENT_PX` is the measured conversion between them.
    memory_px = positive(opts.memory_px) or 0,
    -- How short this session's slices have had to become because the renderer
    -- refused to capture one, and how many times that has happened. Bounded at
    -- one halving: a second refusal means the geometry is outside what this
    -- Chromium will take at all, which a third attempt would only rediscover.
    slice_scale = 1,
    slice_shrinks = 0,
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
    -- Samples that implied a link faster than one could be. Above zero means
    -- this session's writes are being absorbed rather than transmitted, so the
    -- estimator has nothing to say and `render.ssh_link_bytes_per_sec` is the
    -- only way the hold gets a real number.
    wire_samples_discarded = 0,
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
    -- A capture superseded before it came back, which is a *third* thing and is
    -- deliberately not folded into `stale_fills`: it never reached the point
    -- `fills` is counted at, so adding it there would make `stale_fills` a
    -- population `fills` does not contain and quietly break the reconciliation
    -- the drop counters exist to support.
    superseded_fills = 0,
    -- A fill the backend would not put on screen. It has crossed the wire by
    -- then, so it is the most expensive way to lose one -- and it was the single
    -- path out of the fill branch with no counter on it at all.
    undisplayed_fills = 0,
    evictions = 0,
    -- Slices given back wholesale by `M.drain` -- an invalidation, a fallback, a
    -- retarget, a close -- and how many occasions did it. Not evictions: the
    -- ceiling did not bind, the pixels simply stopped describing the document.
    -- See `M.drain` for why this is counted rather than inferred.
    dropped_slices = 0,
    drains = 0,
    prefetches = 0,
    blocked_by_find = 0,
    blocked_by_selection = 0,
    frames_suppressed_by_hold = 0,
    -- Captures thrown away because the reader panned while they were in flight.
    -- A pan issues no request, so nothing else can notice it happened.
    superseded_by_pan = 0,
    -- Scroll positions that spanned two slices, drawn as two bands in one
    -- write; and those that spanned two of which only one was held, which fall
    -- to a captured frame. Kept apart from `misses` and from each other because
    -- they are the one case a fixed grid creates and a bounded region could not:
    -- a boundary that never moves is a boundary the reader can park on. The
    -- first is the composite working; the second is transient, and the settle
    -- behind it is already filling the slice that was absent.
    straddles = 0,
    straddle_misses = 0,
    upload_bytes = 0,
    placement_bytes = 0,
  }
end

---The slice this session holds at `index`, or nil.
---
---No search and no touch-on-read. The index *is* the identity, and there is no
---ordering to maintain: what replaced the LRU is arithmetic on a fixed grid, so
---"which slice covers this scroll" is answered by `M.slices_for` before anything
---looks in here at all.
function M.hold(state, index)
  if not (state and state.slices) then return nil end
  return state.slices[index]
end

---Every slice this session holds, in document order.
---
---Ordered because several callers hand the result to a terminal -- freeing,
---hiding, re-placing -- and `pairs` over a hash has no defined order, which
---makes an emitted stream unassertable. The same reasoning as `ordered_pids` in
---the raw Kitty backend, and the same cost: nothing, at these sizes.
function M.slice_records(state)
  local out = {}
  if not (state and state.slices) then return out end
  local indices = {}
  for index in pairs(state.slices) do
    indices[#indices + 1] = index
  end
  table.sort(indices)
  for _, index in ipairs(indices) do
    out[#out + 1] = state.slices[index]
  end
  return out
end

---Give back slices until what is held fits the ceiling, farthest from `center`
---first. Returns the evicted regions so the caller can free their pixels.
---
---A window rather than an LRU, and the difference is the whole point. An LRU
---asks "which of these was least recently useful", which needs a history and
---gets it wrong at exactly the moment a reader turns around. A window asks "how
---far is this from where they are reading", which on a fixed grid is
---subtraction. Documents under the ceiling never reach this at all: at the
---default it is about thirteen viewports, and ordinary reading does not leave a
---band that wide.
---
---`center` is never evicted -- it is the slice being read -- and a tie in
---distance is broken *behind* the reader, because reading is forward-biased and
---the slice ahead is the one more likely to be wanted next.
function M.retain_window(state, center)
  local evicted = {}
  local ceiling = positive(state and state.memory_px)
  if not ceiling then return evicted end
  center = finite(center) or 0

  while state.resident_px > ceiling do
    local worst, worst_distance = nil, -1
    for index in pairs(state.slices) do
      if index ~= center then
        local distance = math.abs(index - center)
        -- `>=` with the scan ordered by index would be arbitrary, so the tie is
        -- broken explicitly: at equal distance the lower index -- the one behind
        -- the reader -- goes.
        if distance > worst_distance or (distance == worst_distance and index < worst) then
          worst, worst_distance = index, distance
        end
      end
    end
    -- Only the centre is left and it is still over: that is a ceiling smaller
    -- than one slice, which `M.register` refuses up front and `slice_cost_px`
    -- lets the controller decline before spending any wire at all.
    if not worst then break end
    local gone = state.slices[worst]
    state.slices[worst] = nil
    state.resident_px = state.resident_px - gone.image_w * gone.image_h
    state.evictions = state.evictions + 1
    evicted[#evicted + 1] = gone
  end
  return evicted
end

---Put `region` in grid cell `index`, evicting whatever has to go to make room.
---
---Returns `region, evicted` on success and `nil, evicted, reason` on refusal --
---`evicted` in both positions because a refusal can still have had to drop the
---cell's previous occupant on the way, and an image nobody frees is an image the
---terminal holds forever.
---
---There is deliberately no half-registered state. A slice either occupies its
---cell or does not exist: the bounded-region cache had a "kept on screen but
---refused by the cache" case, and every question anyone asked of it afterwards
---("is this a hit", "may this be freed", "how much are we holding") had a third
---answer nobody had thought about.
---
---The cost is the region's **actual** pixel count, from the PNG's own header --
---not a size predicted from the scale that was requested, which is wrong on the
---renderer's Playwright fallback path.
function M.register(state, index, region)
  local evicted = {}
  index = finite(index)
  if index == nil or index < 0 then return nil, evicted, "a slice needs a grid index" end
  if not region then return nil, evicted, "no region to register" end

  -- Whatever was in this cell is superseded outright, before the ceiling is
  -- consulted -- so a refill of the same slice is never blocked by the copy it
  -- is replacing.
  --
  -- Deliberately counted by nothing. It cannot happen: one fill is in flight at
  -- a time (`fill.in_flight`, which both the settle and the prefetch refuse to
  -- take), and neither of them ever chooses a cell this session already holds.
  -- So a displacement here means one of those two invariants has gone, and the
  -- reconciliation identity in `tests/lua/cases/resident_e2e.lua` fails --
  -- which is the point. Counting it would balance the books over a defect
  -- instead of reporting one.
  local existing = state.slices[index]
  if existing then
    state.slices[index] = nil
    state.resident_px = state.resident_px - existing.image_w * existing.image_h
    evicted[#evicted + 1] = existing
  end

  local cost = region.image_w * region.image_h
  local ceiling = positive(state.memory_px)
  if ceiling and cost > ceiling then
    return nil, evicted, ("a slice of %d px exceeds the whole %d px ceiling"):format(cost, ceiling)
  end

  region.index = index
  state.slices[index] = region
  state.resident_px = state.resident_px + cost

  -- Centred on the slice just filled, which is where the reader is: that is what
  -- makes "the slice under the reader is never the one evicted" arithmetic
  -- rather than a rule someone has to remember.
  for _, gone in ipairs(M.retain_window(state, index)) do
    evicted[#evicted + 1] = gone
  end
  return region, evicted
end

---Would one more slice of `cost` pixels fit without evicting anything?
---
---The question a *prefetch* has to ask and a fill does not. A fill is for a
---slice the reader is looking at, so it is worth evicting something for; a
---prefetch is a guess, and a guess that evicts is worse than no guess at all --
---it uploads a slice, drops one the reader may come back to, and pays for both
---again. That is precisely the upload-evict-reupload churn this whole rebuild
---removed, and reintroducing it speculatively would be the least defensible way
---to bring it back.
function M.has_room(state, cost)
  local ceiling = positive(state and state.memory_px)
  if not ceiling then return false end
  return (state.resident_px or 0) + math.max(0, finite(cost) or 0) <= ceiling
end

---The nearest slice to `center` this session does not hold, or nil.
---
---Nearest by index, so the document fills outward from the reader and the
---slices most likely to be wanted next arrive first. At equal distance the one
---*ahead* wins, for the reason `retain_window` breaks its tie the other way:
---reading is forward-biased, so the slice ahead is the better guess and the
---slice behind is the better thing to give up.
---
---nil means every slice of this grid is already held, which on a document
---inside the ceiling is the state this feature is trying to reach.
function M.next_prefetch(state, grid, center)
  if not (state and state.slices and grid) then return nil end
  center = finite(center)
  if center == nil then return nil end
  -- Clamped so `center - distance >= 0` is the only bound the loop needs; a
  -- centre outside the grid would otherwise walk backwards into cells that do
  -- not exist and hand one of them back as a slice to capture.
  center = clamp(center, 0, grid.count - 1)
  -- From one, never zero: the slice the reader is *in* belongs to the settle,
  -- and a prefetch taking the shared fill slot for it would be exactly
  -- backwards.
  for distance = 1, grid.count do
    local ahead, behind = center + distance, center - distance
    if ahead <= grid.count - 1 and state.slices[ahead] == nil then return ahead end
    if behind >= 0 and state.slices[behind] == nil then return behind end
  end
  return nil
end

---Give up every slice, returning them so the caller can free their pixels.
---Used by close, retarget, invalidation and fallback -- the paths that end a
---session's claim on the terminal's memory.
---
---**What this costs is counted here, because nothing else can see it.** Every
---slice given back was captured, uploaded and paid for at full wire price, and
---none of that is an *eviction*: `evictions` means the ceiling bound, and stays
---at zero through a drain of the entire document. So a real session reported 18
---fills, 12 slices held, and `stale 0 / abandoned 0 / evictions 0` -- the six
---that went missing, ~2.5 MB of them, were visible only by subtracting two
---numbers nobody subtracts. `dropped_slices` is that subtraction, performed
---where the drop happens.
---
---`drains` counts the *occasions* rather than the slices, and only the ones that
---cost something. One drain of twelve is a resize; twelve drains of one is
---something invalidating under the reader, and the two want different answers.
function M.drain(state)
  local slices = M.slice_records(state)
  state.slices = {}
  state.resident_px = 0
  state.key = nil
  state.dropped_slices = (state.dropped_slices or 0) + #slices
  if #slices > 0 then state.drains = (state.drains or 0) + 1 end
  -- The grid goes with them, and the generation moves. A fill in flight was
  -- planned against cell `n` of the grid that has just stopped existing, and
  -- nothing else could tell it so: the document key it also carries is unchanged
  -- when what regenerated the grid was a renderer refusing to capture a slice.
  state.grid = nil
  state.generation = (state.generation or 0) + 1
  -- The token carries over rather than resetting, so a fill issued before this
  -- drain cannot release the slot a fill issued after it is holding. Without
  -- that, retargeting mid-capture leaves two fills believing they are the one.
  state.fill = { in_flight = false, token = state.fill and state.fill.token or 0 }
  state.desired_scroll_y = nil
  -- `upload_hold_until` and `wire_bytes_per_ms` are deliberately untouched: they
  -- describe the link, and closing a document does not make the bytes still
  -- crossing it arrive any sooner.
  return slices
end

--- What one resident pixel costs the terminal once decoded, in bytes.
---
--- **Measured, not assumed.** `scripts/resident/rss-calibrate.py` transmits
--- PNGs of known pixel counts, places each one (a terminal may decode lazily,
--- so an image never drawn would report nothing), samples iTerm2's RSS and then
--- frees them. Three runs of 6/8/10 slices at 1980x4080 on iTerm2 3.6.11 /
--- macOS 15 put it at **12-13 bytes per pixel**, and this budgets at the top of
--- that band.
---
--- Everything here previously assumed 4, which is what a naive RGBA surface
--- would cost. It is not what a terminal actually holds, and the difference is
--- not a rounding error: every diagnostic and every budget stated in these
--- units understated the real cost by more than 3x. The shipped
--- `resident_budget_px` default of 8,000,000 px was documented as "~32 MB" and
--- is ~100 MB.
local BYTES_PER_RESIDENT_PX = 13

M.BYTES_PER_RESIDENT_PX = BYTES_PER_RESIDENT_PX

---What a region costs the terminal once decoded, in bytes.
---
---Still called an estimate, because the number it multiplies by is a
---measurement of one terminal on one platform rather than a documented
---representation -- but a measured estimate, not a guessed one. Budgeting is
---done in pixels so the figure has exactly one home:
---`renderer/src/media.js` already states the animation upload budget the same
---way, so the two are comparable.
function M.decoded_bytes(region) return (region.image_w or 0) * (region.image_h or 0) * BYTES_PER_RESIDENT_PX end

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
---**This is not a measurement of transit, and nothing in a Neovim plugin can
---be.** `elapsed_ms` is how long the backend's write to `nvim_ui_send` blocked,
---which is back-pressure and not arrival: the pty buffer takes the head of a
---payload immediately, so a write returning says only that the kernel accepted
---the bytes. When there is room for all of them it says nothing whatsoever.
---
---There is no second thing to ask. The terminal can be *told* to answer -- a
---Kitty `q=0` upload replies `OK` when it has the pixels -- but that reply
---arrives on Neovim's own stdin, and a plugin cannot read a terminal's reply at
---all: Neovim owns terminal input, which is why `cellpixels.lua` goes through
---`TIOCGWINSZ` rather than asking with `CSI 14 t`, and why
---`docs/local-render-design.md`'s "alternatives that cannot work" already
---includes returning data through `TermResponse`. So the honest sources for a
---link rate are, in order: the operator stating it
---(`render.ssh_link_bytes_per_sec`, which is what `M.link_rate` prefers), and
---this, which is a lower bound on a bad day and meaningless on a good one.
---
---Both guards therefore reject rather than believe. Small payloads measure the
---scheduler; enormous rates measure a write that did not block. The reverted
---client-render measurements recorded a 471 KB frame taking ~350 ms of blocked
---write on the 0.80 MB/s link this exists for -- a sample worth keeping -- where
---the same frame takes 0.78 ms locally, which is not.
function M.note_wire_sample(state, bytes, elapsed_ms)
  if not state then return end
  bytes = positive(bytes)
  elapsed_ms = positive(elapsed_ms)
  if not (bytes and elapsed_ms) or bytes < MIN_WIRE_SAMPLE_BYTES then return end
  local sample = bytes / elapsed_ms
  -- Counted, unlike the floor's rejections. A payload below the floor is an
  -- ordinary placement command and there are thousands of them; a sample over
  -- the ceiling means this session cannot observe its link at all, which is the
  -- one thing the operator would want to know before trusting a hold.
  if sample > MAX_WIRE_SAMPLE_BYTES_PER_MS then
    state.wire_samples_discarded = (state.wire_samples_discarded or 0) + 1
    return
  end
  local previous = positive(state.wire_bytes_per_ms)
  state.wire_bytes_per_ms = previous and (previous + (sample - previous) * WIRE_SAMPLE_WEIGHT) or sample
  state.wire_samples = (state.wire_samples or 0) + 1
end

---The link rate the hold must be computed from, in bytes per millisecond, and
---where the number came from.
---
---Configured first. The operator knows their tunnel and the plugin cannot find
---it out -- see `M.note_wire_sample` for why there is no observation to make --
---so a stated rate is the only figure here that is a fact rather than an
---inference, and it wins outright rather than being averaged with one.
---
---`"estimated"` is a fallback and must be labelled as one wherever it is shown.
---It comes from writes that blocked, which is a *part* of a transfer, so it runs
---fast; the value of keeping it is that a session with no rate configured still
---holds the wire for something better than a fixed delay.
---
---`nil, "unknown"` is the honest third answer, and `M.wire_hold_ms` turns it
---into the session's settle delay rather than into no hold at all.
---@return number|nil bytes_per_ms, string source
function M.link_rate(configured_bytes_per_sec, estimated_bytes_per_ms)
  local configured = positive(configured_bytes_per_sec)
  if configured then return configured / 1000, "configured" end
  local estimated = positive(estimated_bytes_per_ms)
  if estimated then return estimated, "estimated" end
  return nil, "unknown"
end

---How long to keep the wire to itself after handing `bytes` to the terminal.
---
---The blocked write is *some* of the transfer and can be none of it: the pty
---buffer takes the head of the payload immediately, and where there is room for
---the whole thing the write returns before a byte has left the machine. So the
---hold is the whole-payload wire time at `bytes_per_ms` *less the part already
---spent blocking*, which is what makes it zero by arithmetic rather than by
---exception on a link fast enough not to need it -- there the rate is high
---enough that the subtraction lands below zero.
---
---`bytes_per_ms` comes from `M.link_rate`, which prefers the operator's stated
---rate to anything inferred. With no rate at all the answer is `default_ms`,
---which the caller passes as the session's settle delay: a number already tuned
---for this link rather than a new constant nobody has measured. `max_ms` is the
---guarantee that a wrong rate costs staleness and never a wedged preview.
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

return M
