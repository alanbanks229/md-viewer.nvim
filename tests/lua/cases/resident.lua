-- The resident-region coordinate model.
--
-- Every number here is arithmetic with no Neovim, no backend and no browser in
-- it, which is the point: a wrong crop is a wrong picture, and this is the one
-- place the wrongness can be caught before pixels are involved. Two families of
-- assertion earn their keep specifically:
--
--   * the usable pan range, asserted as the *exact* last-hit and first-miss
--     scroll position in each direction. A region two viewports tall yields one
--     viewport of travel, not two -- the viewport itself occupies the other one.
--     That is easy to state wrongly and impossible to notice from a screenshot.
--
--   * the retention window. A slice occupies a fixed cell of a fixed grid, and
--     the only thing that can displace it is the memory ceiling -- so what gets
--     evicted is decided by distance from the reader rather than by a history,
--     and "this document never evicts anything" is a property that can be
--     asserted rather than hoped for.
return function(t)
  local resident = require("md-viewer.resident")

  -- The viewport docs/local-render-design.md's measurements were taken against,
  -- so the numbers below are the real ones rather than round ones.
  local VW, VH, SCALE = 990, 1020, 2
  local IMAGE_W = VW * SCALE -- 1980
  local CEILING = 8000000
  local DOC_H = 10891
  local viewport = { widthPx = VW, heightPx = VH }

  -- ---------------------------------------------------------------------------
  -- Region construction: scale is measured, never assumed.
  -- ---------------------------------------------------------------------------

  local region = assert(resident.region({
    doc_y = 1000,
    doc_h = 2020,
    css_w = VW,
    image_w = IMAGE_W,
    image_h = 4040,
    key = "k",
    image_id = 7,
  }))
  t.eq(2, region.scale_x, "horizontal scale comes from the image's own width")
  t.eq(2, region.scale_y, "vertical scale comes from the image's own height")

  -- A non-integer scale is ordinary, not exceptional: the Playwright fallback
  -- returns a full-size frame whatever factor was requested, so the two paths
  -- disagree and only the measured value is right on both.
  local odd = assert(resident.region({ doc_y = 0, doc_h = 2020, css_w = VW, image_w = 1485, image_h = 3030 }))
  t.eq(1.5, odd.scale_x, "a fractional capture scale is derived, not rounded away")
  t.eq(1.5, odd.scale_y, "and agrees on both axes")

  local skewed, skew_reason = resident.region({ doc_y = 0, doc_h = 2020, css_w = VW, image_w = 1980, image_h = 3030 })
  t.eq(nil, skewed, "a region whose axes disagree about scale is refused, not clamped")
  t.ok(skew_reason and skew_reason:match("scale disagrees"), "and says which axes disagreed")

  t.eq(
    nil,
    (resident.region({ doc_y = 0, doc_h = 0, css_w = VW, image_w = 1, image_h = 1 })),
    "a zero-height region is refused"
  )
  t.eq(
    nil,
    (resident.region({ doc_y = -1, doc_h = 10, css_w = VW, image_w = 1, image_h = 1 })),
    "a negative origin is refused"
  )
  t.eq(
    nil,
    (resident.region({ doc_y = 0, doc_h = 10, css_w = VW, image_w = 0 / 0, image_h = 1 })),
    "a non-finite dimension is refused rather than defaulted"
  )

  -- ---------------------------------------------------------------------------
  -- Coverage and the exact pan range.
  -- ---------------------------------------------------------------------------

  -- region: doc_y 1000, doc_h 2020, viewport 1020 => travel is 1000, ending at 2000.
  local first, last = resident.pan_range(region, VH)
  t.eq(1000, first, "the first covered scroll position is the region's own origin")
  t.eq(2000, last, "and the last is doc_y + doc_h - viewport_h")
  t.eq(1000, last - first, "a region 1.98 viewports tall yields 0.98 viewports of travel")

  t.ok(resident.covers(region, first, VH), "the first covered position is a hit")
  t.ok(resident.covers(region, last, VH), "the last covered position is a hit")
  t.eq(false, resident.covers(region, first - 0.5, VH), "half a pixel above the region is a miss")
  t.eq(false, resident.covers(region, last + 0.5, VH), "half a pixel below the last covered position is a miss")
  t.eq(false, resident.covers(region, last + 1, VH), "and a whole pixel past it certainly is")

  -- The claim that is easiest to get wrong, pinned across the whole range of
  -- region sizes this design can produce: the viewport consumes a viewport, so
  -- total travel is (k - 1) viewports and never k.
  for _, k in ipairs({ 1.25, 1.5, 1.98, 2.0, 3.0, 4.0 }) do
    local sized = assert(resident.region({
      doc_y = 500,
      doc_h = VH * k,
      css_w = VW,
      image_w = IMAGE_W,
      image_h = VH * k * SCALE,
    }))
    local low, high = resident.pan_range(sized, VH)
    t.near(VH * (k - 1), high - low, 1e-6, ("a region %.2f viewports tall gives %.2f of travel"):format(k, k - 1))
    t.eq(500, low, ("travel starts at the region origin at k=%.2f"):format(k))
  end

  -- ---------------------------------------------------------------------------
  -- The source window: which pixels of the resident image the viewport is.
  -- ---------------------------------------------------------------------------

  local top_src, top_applied = resident.source_window(region, 1000, viewport)
  t.eq(0, top_src.y, "at the region's origin the crop starts at the top of the image")
  t.eq(0, top_src.x, "a region is always full width, so the crop never moves horizontally")
  t.eq(IMAGE_W, top_src.width, "and spans the whole image width")
  t.eq(2040, top_src.height, "the crop is exactly one viewport tall, in image pixels")
  t.eq(1000, top_applied, "and shows exactly the scroll position that was asked for")

  local mid_src, mid_applied = resident.source_window(region, 1500, viewport)
  t.eq(1000, mid_src.y, "500 CSS px into the region is 1000 image px at scale 2")
  t.eq(1500, mid_applied, "an exactly-representable position is shown exactly")

  local end_src = resident.source_window(region, 2000, viewport)
  t.eq(2000, end_src.y, "the last covered position crops the bottom of the image")
  t.eq(4040, end_src.y + end_src.height, "and the crop ends exactly at the image's last row")

  t.eq(
    nil,
    (resident.source_window(region, 2001, viewport)),
    "a position the region does not cover has no source window"
  )

  -- Snapping. A fractional scroll lands between image pixels; left fractional it
  -- makes the emitted crop height wobble by a pixel between frames while the
  -- destination cell count stays fixed, which the terminal renders as a sub-pixel
  -- vertical judder. The origin is snapped instead, and the *snapped* position is
  -- reported back as what the pixels actually show.
  local snapped_src, snapped_applied = resident.source_window(region, 1500.3, viewport)
  t.eq(1001, snapped_src.y, "a fractional scroll snaps to a whole image pixel")
  t.eq(1500.5, snapped_applied, "and the position reported back is the one the pixels show")
  local again_src, again_applied = resident.source_window(region, snapped_applied, viewport)
  t.eq(snapped_src.y, again_src.y, "re-asking at the applied position is a fixed point")
  t.eq(snapped_applied, again_applied, "so the snap can never drift by accumulating")

  -- The wobble this all exists to prevent, stated directly.
  local heights = {}
  for offset = 0, 20 do
    local src = resident.source_window(region, 1500 + offset * 0.137, viewport)
    heights[src.height] = true
  end
  t.eq(1, vim.tbl_count(heights), "the crop height is identical at every scroll position within a region")

  -- ---------------------------------------------------------------------------
  -- Budget: the invariant, and the case that produced it.
  -- ---------------------------------------------------------------------------

  -- Maximum scroll must be a hit, or the last screen of every document is a
  -- permanent miss. This is the property that needs no special case *because*
  -- the last slice is clamped to end with the document.
  local scroll_max = DOC_H - VH
  local bottom_region = assert(resident.region({
    doc_y = DOC_H - 2020,
    doc_h = 2020,
    css_w = VW,
    image_w = IMAGE_W,
    image_h = 2020 * SCALE,
  }))
  t.ok(resident.covers(bottom_region, scroll_max, VH), "the document's maximum scroll position is covered")
  local bottom_src = resident.source_window(bottom_region, scroll_max, viewport)
  t.eq(bottom_region.image_h, bottom_src.y + bottom_src.height, "and its crop reaches the image's last row exactly")

  -- ---------------------------------------------------------------------------
  -- Region identity.
  -- ---------------------------------------------------------------------------

  local parts = {
    document_id = "buffer-1",
    renderer_revision = "9:1",
    viewport_width_px = VW,
    viewport_height_px = VH,
    theme = "dark",
    background = "dark",
    font_size_px = 14,
    scroll_past_end = true,
    scroll_past_end_offset_px = 22,
    device_scale_factor = 2,
  }
  local baseline = resident.key(parts)
  t.eq(baseline, resident.key(vim.deepcopy(parts)), "the same inputs produce the same key")
  for field, changed in pairs({
    document_id = "buffer-2",
    renderer_revision = "10:1",
    -- Width reflows the centred, max-width body; height changes the
    -- `calc(100vh - Npx)` bottom padding and so the document's own extent.
    viewport_width_px = 991,
    viewport_height_px = 1021,
    theme = "light",
    background = "light",
    font_size_px = 15,
    scroll_past_end = false,
    scroll_past_end_offset_px = 23,
    device_scale_factor = 3,
  }) do
    local altered = vim.deepcopy(parts)
    altered[field] = changed
    t.ok(resident.key(altered) ~= baseline, ("a change to %s invalidates every resident region"):format(field))
  end

  -- Selection and find are deliberately absent: a region must never be captured
  -- with them painted in, which is a scheduling rule, and keying on them would
  -- discard a good region every time one was cleared.
  local with_selection = vim.deepcopy(parts)
  with_selection.selection_active = true
  t.eq(baseline, resident.key(with_selection), "selection state is not part of a region's identity")

  -- Measured by scripts/resident/rss-calibrate.py rather than assumed: iTerm2
  -- holds 12-13 bytes for every resident pixel, not the 4 a naive RGBA surface
  -- would suggest. Pinned here because every budget and every diagnostic stated
  -- in these units was understating the real cost by more than 3x.
  t.eq(13, resident.BYTES_PER_RESIDENT_PX, "a resident pixel costs what the calibration measured")
  t.eq(
    13 * IMAGE_W * 4040,
    resident.decoded_bytes(region),
    "so the decoded-size estimate is thirteen bytes a pixel, measured"
  )

  -- ---------------------------------------------------------------------------
  -- What a session holds: a fixed cell per slice, and a window around the reader.
  --
  -- This replaced an LRU of at most `max_regions` regions, and the difference is
  -- the whole rebuild. An LRU asks "which of these was least recently useful",
  -- which needs a history and gets it wrong exactly when a reader turns around;
  -- a fixed grid asks "how far is this slice from where they are reading", which
  -- is subtraction. A slice is either the one at its index or absent, so the
  -- "kept on screen but refused by the cache" state -- a third answer to every
  -- question anyone asked -- cannot be reached.
  -- ---------------------------------------------------------------------------

  local SLICE_PX = IMAGE_W * 2020 * SCALE -- one two-viewport slice, decoded
  local function make(doc_y, doc_h, key, id)
    return assert(resident.region({
      doc_y = doc_y,
      doc_h = doc_h,
      css_w = VW,
      image_w = IMAGE_W,
      image_h = doc_h * SCALE,
      key = key or "k1",
      image_id = id,
    }))
  end

  local held = resident.new_state({ memory_px = SLICE_PX * 3 })
  t.eq(false, held.enabled, "a fresh resident state is disabled until the controller says otherwise")
  t.eq(0, held.resident_px, "and holds nothing")
  t.eq(0, #resident.slice_records(held), "with no slices in it")

  local a = make(0, 2020, "k1", 101)
  local kept, evicted = resident.register(held, 0, a)
  t.eq(a, kept, "the first slice is taken")
  t.eq(0, #evicted, "and evicts nothing")
  t.eq(SLICE_PX, held.resident_px, "charged the slice's real pixel count, from the PNG's own header")
  t.eq(a, resident.hold(held, 0), "and it is what cell 0 holds")
  t.eq(0, a.index, "the region knows which cell it is in")
  t.eq(nil, resident.hold(held, 1), "a cell nothing has filled holds nothing")

  resident.register(held, 1, make(2020, 2020, "k1", 102))
  resident.register(held, 2, make(4040, 2020, "k1", 103))
  t.eq(3, #resident.slice_records(held), "three slices are held")
  t.ok(held.resident_px <= held.memory_px, "and stay inside the ceiling")
  t.eq(0, held.evictions, "with nothing evicted, which is the property the rebuild is for")

  -- Ordered by index, because several callers hand this list straight to a
  -- terminal and `pairs` over a hash makes the emitted stream unassertable.
  local ordered = resident.slice_records(held)
  t.eq(101, ordered[1].image_id, "slice records come back in document order")
  t.eq(103, ordered[3].image_id, "lowest index first, whatever order they were filled in")

  -- The window: farthest from the reader goes, and the reader's own slice never
  -- does. Not an LRU -- nothing here records when anything was last used.
  local fourth = make(6060, 2020, "k1", 104)
  local _, spilled = resident.register(held, 3, fourth)
  t.eq(1, #spilled, "a fourth slice over the ceiling evicts exactly one")
  t.eq(101, spilled[1].image_id, "the farthest from the slice just filled, not the oldest or the least used")
  t.eq(fourth, resident.hold(held, 3), "and the slice just filled is still held")
  t.eq(1, held.evictions, "counted, because on a document inside the ceiling this must stay at zero")
  t.eq(SLICE_PX * 3, held.resident_px, "the accounting follows what was actually dropped")

  -- Returning to a slice already held costs nothing and evicts nothing: it is a
  -- lookup, not a use that has to be recorded.
  t.eq(nil, resident.hold(held, 0), "the evicted cell is empty")
  for _ = 1, 3 do
    t.ok(resident.hold(held, 2) ~= nil, "and re-reading a held slice neither moves nor drops anything")
  end
  t.eq(1, held.evictions, "so repeated reads evict nothing")

  -- A tie in distance is broken behind the reader: reading is forward-biased, so
  -- at equal distance the slice ahead is the one more likely to be wanted next.
  local tied = resident.new_state({ memory_px = SLICE_PX * 2 })
  resident.register(tied, 0, make(0, 2020, "k1", 501))
  resident.register(tied, 2, make(4040, 2020, "k1", 502))
  local _, tie_spill = resident.register(tied, 1, make(2020, 2020, "k1", 503))
  t.eq(1, #tie_spill, "a third slice over the ceiling drops one of the two equidistant neighbours")
  t.eq(501, tie_spill[1].image_id, "the one behind the reader")
  t.eq(nil, resident.hold(tied, 0), "so the cell behind them is empty")
  t.ok(resident.hold(tied, 2) ~= nil, "and the one ahead of them is kept")

  -- The hard invariant, across a long walk: the ceiling is never exceeded, and
  -- everything dropped comes back with an image id so its pixels can be freed.
  local walk = resident.new_state({ memory_px = SLICE_PX * 2 })
  for index = 0, 40 do
    local stored, dropped = resident.register(walk, index, make(index * 2020, 2020, "k1", 200 + index))
    t.ok(stored ~= nil, ("registering slice %d succeeds"):format(index))
    for _, gone in ipairs(dropped) do
      t.ok(gone.image_id ~= nil, "every evicted slice is handed back with its image id so it can be freed")
    end
    t.ok(walk.resident_px <= walk.memory_px, ("resident_px stays within the ceiling at slice %d"):format(index))
    t.ok(resident.hold(walk, index) ~= nil, ("and the slice just filled is the one kept at %d"):format(index))
  end

  -- A slice larger than the whole ceiling is refused rather than evicting
  -- everything to make room for something that still would not fit. The
  -- controller declines the grid before spending any wire on this, so reaching
  -- it means the two disagree -- but it is a refusal either way, never a
  -- half-registered slice.
  local tiny = resident.new_state({ memory_px = 1000 })
  local refused, refused_evicted, refused_reason = resident.register(tiny, 0, make(0, 2020, "k1", 900))
  t.eq(nil, refused, "a slice larger than the entire ceiling is refused")
  t.eq(0, #refused_evicted, "and nothing was thrown away for it")
  t.ok(refused_reason and refused_reason:match("ceiling"), "with a reason naming the ceiling")
  t.eq(0, tiny.resident_px, "leaving the session holding exactly what it held before")
  t.eq(nil, resident.hold(tiny, 0), "and cell 0 empty rather than half filled")

  -- Refilling a cell replaces its occupant rather than holding both.
  local refill = resident.new_state({ memory_px = SLICE_PX * 3 })
  resident.register(refill, 1, make(2020, 2020, "k1", 401))
  local _, replaced = resident.register(refill, 1, make(2020, 2020, "k1", 402))
  t.eq(1, #replaced, "refilling a cell supersedes the copy it replaces")
  t.eq(401, replaced[1].image_id, "handing back the old image so its pixels are freed")
  t.eq(1, #resident.slice_records(refill), "rather than holding both")
  t.eq(SLICE_PX, refill.resident_px, "and the accounting is the one slice, not two")

  -- ---------------------------------------------------------------------
  -- What the idle-time prefetch is allowed to do.
  --
  -- A fill is for a slice the reader is looking at, so it is worth evicting
  -- something for. A prefetch is a guess, and a guess that evicts is worse than
  -- no guess: it uploads a slice, drops one the reader may come back to, and
  -- pays for both again -- the upload-evict-reupload churn this whole rebuild
  -- removed, brought back speculatively.
  -- ---------------------------------------------------------------------
  local room = resident.new_state({ memory_px = SLICE_PX * 3 })
  t.eq(true, resident.has_room(room, SLICE_PX), "an empty session has room for a slice")
  resident.register(room, 0, make(0, 2020, "k1", 601))
  resident.register(room, 1, make(2020, 2020, "k1", 602))
  t.eq(true, resident.has_room(room, SLICE_PX), "and still does with one left")
  resident.register(room, 2, make(4040, 2020, "k1", 603))
  t.eq(false, resident.has_room(room, SLICE_PX), "but not once the ceiling is reached")
  t.eq(0, room.evictions, "asking never evicts anything -- it is a question, not a reservation")
  t.eq(false, resident.has_room(resident.new_state({ memory_px = 0 }), 1), "and a session with no ceiling has no room")

  -- Nearest first, so the document fills outward from the reader.
  local order = resident.new_state({ memory_px = SLICE_PX * 100 })
  local grid_of_ten = { count = 10 }
  resident.register(order, 5, make(0, 2020, "k1", 700))
  -- Ahead before behind at *equal* distance: reading is forward-biased, which is
  -- also why `retain_window` breaks its own tie the other way. Distance still
  -- wins over direction, though -- a slice one screen back is a better guess
  -- than one three screens on.
  t.eq(6, resident.next_prefetch(order, grid_of_ten, 5), "at equal distance the slice ahead goes first")
  resident.register(order, 6, make(0, 2020, "k1", 701))
  t.eq(4, resident.next_prefetch(order, grid_of_ten, 5), "but a nearer slice behind beats a further one ahead")
  resident.register(order, 4, make(0, 2020, "k1", 702))
  t.eq(7, resident.next_prefetch(order, grid_of_ten, 5), "and then outward again, ahead first")
  t.eq(9, resident.next_prefetch(order, grid_of_ten, 8), "from wherever the reader actually is")
  -- The reader's own cell is never a prefetch target -- it belongs to the
  -- settle, and taking the shared fill slot for it would be backwards. So a
  -- one-slice grid has nothing to prefetch whether or not that slice is held,
  -- and a centre outside the grid is clamped rather than walked off the end.
  t.eq(nil, resident.next_prefetch(resident.new_state({ memory_px = 1 }), { count = 1 }, 5), "clamped to the grid")

  local complete = resident.new_state({ memory_px = SLICE_PX * 100 })
  for index = 0, 3 do
    resident.register(complete, index, make(index * 2020, 2020, "k1", 800 + index))
  end
  t.eq(nil, resident.next_prefetch(complete, { count = 4 }, 0), "a fully held grid has nothing left to prefetch")
  t.eq(nil, resident.next_prefetch(complete, { count = 4 }, 3), "from either end of it")

  -- Draining is what close, retarget, invalidation and fallback use: everything
  -- back at once, and the grid goes with it.
  refill.grid = { count = 4 }
  local before_generation = refill.generation
  local drained = resident.drain(refill)
  t.eq(1, #drained, "draining returns every slice")
  t.eq(0, #resident.slice_records(refill), "and empties the state")
  t.eq(0, refill.resident_px, "and its accounting")
  t.eq(nil, refill.grid, "the grid goes too, so the next fill re-derives it")
  t.eq(before_generation + 1, refill.generation, "and the generation moves, so a fill in flight knows it is orphaned")
  -- What it cost. Every slice given back was captured, uploaded and paid for at
  -- full wire price, and none of it is an eviction -- the ceiling did not bind.
  -- A real session lost six slices and ~2.5 MB this way with `evictions`,
  -- `stale_fills` and `abandoned_fills` all reading zero, and the only trace was
  -- `fills` exceeding what was held.
  t.eq(1, refill.dropped_slices, "the slices given back are counted, since nothing else can see them go")
  t.eq(0, refill.evictions, "and not as evictions, which mean the ceiling bound and it did not")
  t.eq(1, refill.drains, "the occasion is counted as well -- one resize reads unlike twenty invalidations")
  -- A drain with nothing to give back is not an occasion. Every session has two
  -- of those before its first slice exists -- the gate being evaluated at open,
  -- and the first scroll finding no key to compare against -- and counting them
  -- would put every healthy session at two invalidations before it started.
  local empty_drain = resident.new_state({ memory_px = SLICE_PX * 4 })
  resident.drain(empty_drain)
  t.eq(0, empty_drain.dropped_slices, "draining an empty session drops nothing")
  t.eq(0, empty_drain.drains, "and is not counted as an occasion at all")

  -- ---------------------------------------------------------------------------
  -- The wire.
  --
  -- The second constrained resource, and the one the renderer's lanes say
  -- nothing about. A region and the moving frames it replaces share one
  -- `nvim_ui_send` queue and one pty, and bytes handed to that queue cannot be
  -- recalled -- so a region draining for a second will collect every frame
  -- produced during that second unless something declines to produce them.
  -- ---------------------------------------------------------------------------

  -- Measured on the link this feature exists for: a 471 KB frame whose write
  -- blocked ~350ms, against the same frame taking 0.78ms locally.
  local SSH_BYTES, SSH_BLOCKED_MS = 471000, 350
  local LOCAL_BLOCKED_MS = 0.78
  local REGION_BYTES = 810000 -- two viewports, from scripts/resident/probe.mjs
  local SETTLE_MS = 400 -- render.ssh_scroll_settle_ms

  -- With nothing observed yet the answer is the session's settle delay: a number
  -- this link has already been tuned around, rather than a new constant nobody
  -- has measured.
  t.eq(
    SETTLE_MS,
    resident.wire_hold_ms(REGION_BYTES, nil, 0, SETTLE_MS, SETTLE_MS * 2),
    "with no rate estimate the hold is the settle delay"
  )
  t.eq(
    0,
    resident.wire_hold_ms(REGION_BYTES, nil, 0, 0, 0),
    "and a session that asked not to settle is not held either"
  )

  local ssh = resident.new_state({ memory_px = CEILING })
  resident.note_wire_sample(ssh, SSH_BYTES, SSH_BLOCKED_MS)
  t.near(1345.7, ssh.wire_bytes_per_ms, 0.1, "the first sample is the estimate outright")
  t.eq(1, ssh.wire_samples, "and is counted")

  -- 810,000 bytes at ~1,346 B/ms is ~602ms of wire; the write itself blocked
  -- 500 of them, so ~102 are still crossing the link after it returned. That
  -- residual is the whole quantity being estimated -- the pty buffer takes the
  -- head of a payload immediately, so a write returning is not an arrival.
  local held = resident.wire_hold_ms(REGION_BYTES, ssh.wire_bytes_per_ms, 500, SETTLE_MS, SETTLE_MS * 2)
  t.eq(101, held, "the hold is the estimated wire time less the part already spent blocking")

  -- The direction that matters for safety: a wrong estimate costs staleness,
  -- never a wedged preview.
  t.eq(
    SETTLE_MS * 2,
    resident.wire_hold_ms(REGION_BYTES, 0.001, 0, SETTLE_MS, SETTLE_MS * 2),
    "an absurdly slow estimate is clamped rather than believed"
  )

  -- A rate high enough not to need a hold produces none, by arithmetic rather
  -- than by a special case: 810,000 bytes at 100,000 B/ms is 8.1 ms of wire and
  -- the write blocked for 10, so the payload is already across and the
  -- subtraction lands below zero.
  t.eq(
    0,
    resident.wire_hold_ms(REGION_BYTES, 100000, 10, 160, 320),
    "a link fast enough that the payload is already across is not held"
  )

  -- The ceiling, and the failure it is for. A write that did not block returns
  -- at memory speed, so a *large* payload fabricates a rate exactly as enormous
  -- as a tiny one does -- and enormous is the direction that silently disables
  -- the hold. Measured on the real session: 139,058 B/ms and 209,046 B/ms
  -- reported for a link doing 800.
  local absorbed = resident.new_state({ memory_px = CEILING })
  resident.note_wire_sample(absorbed, SSH_BYTES, LOCAL_BLOCKED_MS)
  t.ok(
    SSH_BYTES / LOCAL_BLOCKED_MS > resident.MAX_WIRE_SAMPLE_BYTES_PER_MS,
    "sanity: a 471 KB frame written in 0.78 ms implies a rate no link can have"
  )
  t.eq(nil, absorbed.wire_bytes_per_ms, "so it is discarded rather than folded into the estimate")
  t.eq(0, absorbed.wire_samples, "and never counted as an observation of the link")
  t.eq(1, absorbed.wire_samples_discarded, "it is counted as a sample thrown out, which is the visible part")
  resident.note_wire_sample(absorbed, SSH_BYTES, SSH_BYTES / 139058)
  t.eq(nil, absorbed.wire_bytes_per_ms, "the rate the real session reported is above the ceiling too")

  -- What the estimate is worth once it is guarded: a payload whose write
  -- genuinely blocked still lands, so a session with no configured rate is not
  -- left with nothing.
  local blocked = resident.new_state({ memory_px = CEILING })
  resident.note_wire_sample(blocked, SSH_BYTES, SSH_BLOCKED_MS)
  t.ok(blocked.wire_bytes_per_ms > 0, "a write that blocked for 350 ms is still an observation")
  t.eq(0, blocked.wire_samples_discarded, "and is not thrown out")

  -- Which of the two the hold is computed from, and it is not close: a stated
  -- rate is a fact and an inferred one is a lower bound on a bad day. Both
  -- present, the stated one wins outright rather than being averaged in.
  local rate, source = resident.link_rate(800000, 139058)
  t.eq(800, rate, "a configured bytes-per-second becomes bytes per millisecond and takes precedence")
  t.eq("configured", source, "and says so, because the number alone is not the fact")
  rate, source = resident.link_rate(nil, 1345.7)
  t.near(1345.7, rate, 0.001, "with nothing configured the estimate is the fallback")
  t.eq("estimated", source, "labelled as inferred wherever it is shown")
  rate, source = resident.link_rate(nil, nil)
  t.eq(nil, rate, "and neither available is an honest third answer")
  t.eq("unknown", source, "rather than a number nobody measured")
  t.eq(
    SETTLE_MS,
    resident.wire_hold_ms(REGION_BYTES, resident.link_rate(nil, nil), 0, SETTLE_MS, SETTLE_MS * 2),
    "which the hold turns into the settle delay, not into no hold at all"
  )

  -- The fourth answer, and the one a real tunnel gives. An estimate is only
  -- worth anything while most of this session's samples were credible: a
  -- discarded sample and a kept one are the same event -- a write returning once
  -- a buffer took the bytes -- and differ only in whether the number they
  -- produced landed under the ceiling. The session that reported these counts
  -- put an SSM tunnel at 101,169 B/ms and computed a 2 ms hold from it, so the
  -- one-payload invariant never fired once.
  rate, source = resident.link_rate(nil, 101169, 25, 147)
  t.eq(nil, rate, "an estimate whose session threw out most of its samples is not a rate")
  t.eq("unobservable", source, "and says the link could not be seen, rather than printing what survived")
  t.eq(
    SETTLE_MS,
    resident.wire_hold_ms(REGION_BYTES, rate, 0, SETTLE_MS, SETTLE_MS * 2, source),
    "so the hold falls back to the settle delay instead of the 2 ms that disabled it"
  )
  rate, source = resident.link_rate(nil, 1345.7, 25, 3)
  t.near(1345.7, rate, 0.001, "a minority of discards still leaves an estimate worth having")
  t.eq("estimated", source, "and it is still labelled an inference")
  rate, source = resident.link_rate(800000, 101169, 25, 147)
  t.eq(800, rate, "a stated rate is unaffected by any of this -- it was never an inference")
  t.eq("configured", source, "and keeps saying so")

  -- 810,000 bytes at the stated 800 B/ms is 1,012 ms of wire. That is how long
  -- the wire is genuinely busy, so it is not clamped: `max_ms` bounds a number
  -- this module worked out for itself, and truncating a measurement does not
  -- make the bytes arrive sooner, it just resumes sending on top of them.
  local stated, stated_source = resident.link_rate(800000, 139058)
  t.eq(
    1012,
    resident.wire_hold_ms(REGION_BYTES, stated, 0, SETTLE_MS, SETTLE_MS * 2, stated_source),
    "a stated rate holds for the whole transfer rather than for twice the settle delay"
  )
  t.eq(
    SETTLE_MS * 2,
    resident.wire_hold_ms(REGION_BYTES, stated, 0, SETTLE_MS, SETTLE_MS * 2, "estimated"),
    "while the same number inferred is still capped, because then it is a guess"
  )
  t.eq(
    SETTLE_MS * 2,
    resident.wire_hold_ms(REGION_BYTES, stated, 0, SETTLE_MS, SETTLE_MS * 2),
    "and a caller that names no source gets the cap, which is the safe direction"
  )

  -- Whole milliseconds, because that is the only resolution the clock it will be
  -- compared against has. A hold of half a millisecond would suppress a frame
  -- for a duration `vim.uv.now()` cannot represent.
  t.eq(
    0,
    resident.wire_hold_ms(1000, 1000, 0.4, SETTLE_MS, SETTLE_MS * 2),
    "a sub-millisecond hold is no hold, not a rounded-up one"
  )

  -- Small payloads measure the scheduler, not the link. Admitting one would put
  -- the estimate up by orders of magnitude, which is the direction that silently
  -- disables the hold rather than the one that makes it visible.
  local guarded = resident.new_state({ memory_px = CEILING })
  resident.note_wire_sample(guarded, 210, 0.01) -- a placement command
  t.eq(nil, guarded.wire_bytes_per_ms, "a placement-sized write is not a throughput measurement")
  resident.note_wire_sample(guarded, SSH_BYTES, 0)
  t.eq(nil, guarded.wire_bytes_per_ms, "nor is one that reported no elapsed time")

  -- The estimate follows the link rather than averaging over the session: a
  -- tunnel that gets slower has to be noticed in seconds, not minutes.
  local drifting = resident.new_state({ memory_px = CEILING })
  resident.note_wire_sample(drifting, SSH_BYTES, SSH_BLOCKED_MS)
  local before = drifting.wire_bytes_per_ms
  resident.note_wire_sample(drifting, SSH_BYTES, SSH_BLOCKED_MS * 4)
  t.ok(drifting.wire_bytes_per_ms < before, "a slower sample moves the estimate down")
  t.ok(drifting.wire_bytes_per_ms > SSH_BYTES / (SSH_BLOCKED_MS * 4), "but not all the way, on one sample")

  -- The link outlives the document. Closing or retargeting does not make bytes
  -- still crossing the wire arrive any sooner, so draining leaves the estimate
  -- and the outstanding hold exactly where they were.
  drifting.upload_hold_until = 12345
  resident.drain(drifting)
  t.eq(12345, drifting.upload_hold_until, "draining the cache does not release the wire")
  t.ok(drifting.wire_bytes_per_ms > 0, "nor forget what the link was measured to do")

  -- The fill slot survives a drain as a token rather than a boolean, so a fill
  -- issued before a retarget cannot release the slot a later one is holding.
  local slotted = resident.new_state({ memory_px = CEILING })
  slotted.fill.token = 7
  slotted.fill.in_flight = true
  resident.drain(slotted)
  t.eq(false, slotted.fill.in_flight, "draining releases the slot")
  t.eq(7, slotted.fill.token, "but keeps the counter monotone, so a late fill knows it is not the holder")

  -- ---------------------------------------------------------------------
  -- The slice grid: a fixed cover of the whole document.
  --
  -- The bounded region was planned around wherever the reader stopped, so its
  -- edges moved and crossing one meant an eviction and a refill. A grid's
  -- boundaries belong to the document instead, which is what makes them
  -- permanent -- and permanent boundaries can only work if a viewport that
  -- straddles one is *composited* rather than treated as a miss.
  -- ---------------------------------------------------------------------
  local ROWS = 60
  local grid = assert(resident.slice_grid({
    viewport_h = 1020,
    viewport_w = 990,
    document_height_px = 10891,
    scale = 2,
    rows = ROWS,
  }))

  t.eq(1980, grid.image_w, "a slice is as wide as the viewport at the capture scale")
  t.near(2040, grid.slice_h, 0.5, "and two viewports tall")
  local row_h = 1020 / ROWS
  t.ok(grid.overlap >= row_h, "neighbours overlap by at least one pane row, which is what makes a split possible")
  t.ok(grid.overlap < grid.slice_h * 0.05, ("and by little: %.1f of %.1f CSS px"):format(grid.overlap, grid.slice_h))
  t.near(grid.slice_h - grid.overlap, grid.stride, 1e-9, "the stride is what a slice adds beyond its predecessor")

  -- How much of this document the ceiling can hold, which the diagnostics report
  -- rather than enforce. A document larger than the memory allowed for it is an
  -- ordinary situation -- the window slides and crossing it costs an upload --
  -- and the alternative to saying so is leaving a reader to deduce it from
  -- `evictions` climbing in a diagnostic they would have to know to open.
  local slice_px = resident.slice_cost_px(grid)
  local all, whole = resident.slices_that_fit(grid, slice_px * grid.count)
  t.eq(grid.count, all, "a ceiling with room for every slice fits every slice")
  t.eq(true, whole, "and says the whole document is held")
  local some, partial = resident.slices_that_fit(grid, slice_px * 3)
  t.eq(3, some, "a smaller ceiling fits what it fits")
  t.eq(false, partial, "and does not claim the document")
  -- Never more of the document than there is: this is the answer to "how much of
  -- *this* document", not "how many slices could the ceiling hold in general",
  -- and reporting `12 of 8 slices fit` would be worse than reporting nothing.
  local roomy = resident.slices_that_fit(grid, slice_px * (grid.count + 40))
  t.eq(grid.count, roomy, "and never more slices than the document has")
  t.eq(0, (resident.slices_that_fit(grid, 0)), "no ceiling at all fits nothing")
  t.eq(false, (select(2, resident.slices_that_fit(grid, 0))), "and does not report a document that is held")
  t.eq(nil, resident.slices_that_fit(nil, slice_px), "and with no grid there is no answer rather than a zero")

  -- Boundaries are whole image pixels, so the same document position is an
  -- integer in every slice's own image space and the two halves of a composite
  -- cannot disagree by half a pixel across the seam.
  for index = 0, grid.count - 1 do
    local slice = assert(resident.slice(grid, index))
    t.near(
      math.floor(slice.doc_y * grid.scale + 0.5),
      slice.doc_y * grid.scale,
      1e-6,
      ("slice %d starts on a whole image pixel"):format(index)
    )
  end

  -- The property the whole design rests on: every scroll position a reader can
  -- reach is drawn from slices that exist, and never more than two of them.
  local last_scroll = grid.document_h - grid.viewport_h
  local straddles, singles = 0, 0
  for step = 0, 400 do
    local scroll_y = last_scroll * step / 400
    local first, last = resident.slices_for(grid, scroll_y, grid.viewport_h)
    t.ok(first ~= nil, ("a slice covers scroll %.1f"):format(scroll_y))
    if first then
      t.ok(last - first <= 1, ("at most two slices at scroll %.1f"):format(scroll_y))
      local upper = assert(resident.slice(grid, first))
      if first == last then
        singles = singles + 1
        t.ok(
          upper.doc_y <= scroll_y + 1e-6 and upper.doc_y + upper.doc_h >= scroll_y + grid.viewport_h - 1e-6,
          ("a single slice genuinely contains the viewport at %.1f"):format(scroll_y)
        )
      else
        straddles = straddles + 1
        local lower = assert(resident.slice(grid, last))
        local split, why = resident.split_rows(grid, upper, lower, scroll_y)
        t.ok(split ~= nil, ("a straddle at %.1f has a row to split on: %s"):format(scroll_y, tostring(why)))
        if split then
          -- The two bands are complementary in the document: the upper supplies
          -- rows 0..split-1 and the lower the rest, and the document position at
          -- the seam is inside both. No scanline is shown twice or skipped.
          local seam = scroll_y + split * row_h
          t.ok(seam >= lower.doc_y - 1e-6, ("the seam at %.1f is inside the lower slice"):format(scroll_y))
          t.ok(
            seam <= upper.doc_y + upper.doc_h + 1e-6,
            ("and still inside the upper one, which is what the overlap buys"):format()
          )
        end
      end
    end
  end
  t.ok(straddles > 0, ("straddles are exercised, not hypothetical (%d of 401 positions)"):format(straddles))
  t.ok(singles > 0, ("and so is the single-slice case (%d)"):format(singles))

  -- ---------------------------------------------------------------------
  -- The two bands of a straddle, in each slice's own image pixels.
  --
  -- The property a screenshot could not show: the upper band ends at exactly
  -- the document position the lower one begins at, so no scanline is drawn
  -- twice and none is skipped. Both are derived from one snapped position; two
  -- independently snapped positions is precisely how the backend's two floors
  -- end up a pixel apart.
  -- ---------------------------------------------------------------------
  local band_positions = 0
  for step = 0, 400 do
    local scroll_y = last_scroll * step / 400
    local first, last = resident.slices_for(grid, scroll_y, grid.viewport_h)
    if first and last > first then
      local upper = assert(resident.region({
        doc_y = assert(resident.slice(grid, first)).doc_y,
        doc_h = assert(resident.slice(grid, first)).doc_h,
        css_w = grid.viewport_w,
        image_w = grid.image_w,
        image_h = assert(resident.slice(grid, first)).doc_h * grid.scale,
      }))
      local lower = assert(resident.region({
        doc_y = assert(resident.slice(grid, last)).doc_y,
        doc_h = assert(resident.slice(grid, last)).doc_h,
        css_w = grid.viewport_w,
        image_w = grid.image_w,
        image_h = assert(resident.slice(grid, last)).doc_h * grid.scale,
      }))
      local applied = resident.snap(upper, scroll_y)
      t.near(scroll_y, applied, 1 / grid.scale, ("the snap moves less than an image pixel at %.1f"):format(scroll_y))
      local split = assert(resident.split_rows(grid, upper, lower, applied, ROWS))
      local bands, why = resident.band_sources(
        upper,
        lower,
        applied,
        { widthPx = grid.viewport_w, heightPx = grid.viewport_h },
        ROWS,
        split
      )
      t.ok(bands ~= nil, ("a straddle at %.1f has two bands: %s"):format(scroll_y, tostring(why)))
      if bands then
        band_positions = band_positions + 1
        -- Back into document space, where the two are comparable.
        local upper_top = upper.doc_y + bands.upper.y / upper.scale_y
        local upper_end = upper.doc_y + (bands.upper.y + bands.upper.height) / upper.scale_y
        local lower_top = lower.doc_y + bands.lower.y / lower.scale_y
        local lower_end = lower.doc_y + (bands.lower.y + bands.lower.height) / lower.scale_y
        -- Exactly, not approximately, and that is what quantising the grid's
        -- boundaries to whole image pixels buys. Both slices start on an integer
        -- image pixel and share a scale, so the same document position rounds
        -- the same way in both -- there is no half-pixel of slack to hide a
        -- band that was snapped on its own, which is a scanline drawn twice or
        -- skipped at the seam.
        t.near(applied, upper_top, 1e-6, ("the pane's top row shows the applied position at %.1f"):format(scroll_y))
        t.near(upper_end, lower_top, 1e-6, ("the bands meet exactly, with no gap or overlap, at %.1f"):format(scroll_y))
        t.near(
          applied + grid.viewport_h,
          lower_end,
          1e-6,
          ("and the bottom row is one viewport below the top at %.1f"):format(scroll_y)
        )
        -- Both bands are inside the slices they are cropped from -- `crop_within`
        -- refuses rather than clamps, so one pixel outside draws nothing at all
        -- while the write still reports success.
        t.ok(
          bands.upper.y >= 0 and bands.upper.y + bands.upper.height <= upper.image_h,
          "the upper band fits its slice"
        )
        t.ok(
          bands.lower.y >= 0 and bands.lower.y + bands.lower.height <= lower.image_h,
          "the lower band fits its slice"
        )
      end
    end
  end
  t.ok(band_positions > 0, ("every straddle produced two bands (%d positions)"):format(band_positions))

  -- The refusals, each naming what it could not do rather than guessing.
  local viewport_box = { widthPx = grid.viewport_w, heightPx = grid.viewport_h }
  local upper_one = assert(resident.slice(grid, 0))
  local lower_one = assert(resident.slice(grid, 1))
  local pair_upper = assert(resident.region({
    doc_y = upper_one.doc_y,
    doc_h = upper_one.doc_h,
    css_w = grid.viewport_w,
    image_w = grid.image_w,
    image_h = upper_one.doc_h * grid.scale,
  }))
  local pair_lower = assert(resident.region({
    doc_y = lower_one.doc_y,
    doc_h = lower_one.doc_h,
    css_w = grid.viewport_w,
    image_w = grid.image_w,
    image_h = lower_one.doc_h * grid.scale,
  }))
  t.eq(
    nil,
    (resident.band_sources(pair_upper, pair_lower, 0, viewport_box, ROWS, 0)),
    "a split at row zero is not a split -- one band would be a placement of nothing"
  )
  t.eq(
    nil,
    (resident.band_sources(pair_upper, pair_lower, 0, viewport_box, ROWS, ROWS)),
    "and neither is a split at the last row"
  )
  local outside = select(2, resident.band_sources(pair_upper, pair_lower, -grid.viewport_h, viewport_box, ROWS, 5))
  t.ok(tostring(outside):match("inside its slice"), "a band outside its slice is refused: " .. tostring(outside))

  -- The last slice reaches the document's end, or the final screen would be a
  -- permanent miss.
  local final = assert(resident.slice(grid, grid.count - 1))
  t.ok(
    final.doc_y + final.doc_h >= grid.document_h - 1e-6,
    ("the grid reaches the document's end (%.1f of %.1f)"):format(final.doc_y + final.doc_h, grid.document_h)
  )
  t.eq(nil, resident.slice(grid, grid.count), "and there is nothing past the last slice")
  t.eq(nil, resident.slice(grid, -1), "or before the first")

  -- Refusals, each naming the thing it could not do.
  t.eq(nil, resident.slice_grid({ viewport_h = 1020, viewport_w = 990, scale = 2, rows = ROWS }))
  local short_reason = select(
    2,
    resident.slice_grid({
      viewport_h = 1020,
      viewport_w = 990,
      document_height_px = 900,
      scale = 2,
      rows = ROWS,
    })
  )
  t.ok(
    tostring(short_reason):match("fits the viewport"),
    "a document that cannot scroll is declined: " .. tostring(short_reason)
  )
  -- A pane of one row makes the overlap a whole viewport, which leaves no slice
  -- height that can hold a viewport as well.
  local thin_reason = select(
    2,
    resident.slice_grid({
      viewport_h = 1020,
      viewport_w = 990,
      document_height_px = 10891,
      scale = 8,
      rows = 1,
    })
  )
  t.ok(thin_reason ~= nil, "and a geometry with no room for a viewport plus its overlap: " .. tostring(thin_reason))
end
