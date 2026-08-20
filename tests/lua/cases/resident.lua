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
--   * the budget boundary. The budget is the invariant and the height is derived
--     from it; nominating a height and checking afterwards is how a budget gets
--     exceeded by an amount nobody sees until the terminal is holding it.
return function(t)
  local resident = require("md-viewer.resident")

  -- The viewport docs/local-render-design.md's measurements were taken against,
  -- so the numbers below are the real ones rather than round ones.
  local VW, VH, SCALE = 990, 1020, 2
  local IMAGE_W = VW * SCALE -- 1980
  local VIEWPORT_PX = IMAGE_W * VH * SCALE -- 4,039,200 -- one viewport, decoded
  local BUDGET = 8000000
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

  -- Two viewports at this geometry is 8,078,400 decoded pixels, which is over an
  -- 8,000,000 budget. Nominating "2.0 viewports" and checking afterwards would
  -- exceed it; deriving the height from the budget cannot.
  t.ok(VIEWPORT_PX * 2 > BUDGET, "sanity: two viewports genuinely exceed this budget")

  local plan = assert(resident.plan_region({
    scroll_y = 4000,
    viewport_h = VH,
    viewport_w = VW,
    document_height_px = DOC_H,
    scale = SCALE,
    budget_px = BUDGET,
    max_regions = 1,
  }))
  t.eq(2020, plan.doc_h, "the derived region is 2020 CSS px, not two viewports")
  t.near(1.98039, plan.k, 1e-4, "which is 1.98 viewports -- an output of the budget, not an input")
  t.eq(7999200, IMAGE_W * plan.doc_h * SCALE, "and costs 7,999,200 decoded pixels")
  t.ok(IMAGE_W * plan.doc_h * SCALE <= BUDGET, "which is inside the budget, as the invariant requires")

  -- The anchor: most of the travel ahead of the reader, some behind, and the
  -- split stated as a share of the slack so it stays valid at every region size.
  t.eq(1000, plan.backward_slack + plan.forward_slack, "total travel is doc_h - viewport_h whatever the anchor")
  t.near(250, plan.backward_slack, 1e-6, "a quarter of the travel is behind the reader")
  t.near(750, plan.forward_slack, 1e-6, "and three quarters ahead of them")
  t.eq(3750, plan.doc_y, "so the region starts a quarter of its slack above the current position")

  -- The budget bound holds across sizes, not just the one that motivated it.
  for _, budget in ipairs({ 4500000, 8000000, 12000000, 40000000, 200000000 }) do
    local sized = resident.plan_region({
      scroll_y = 4000,
      viewport_h = VH,
      viewport_w = VW,
      document_height_px = DOC_H,
      scale = SCALE,
      budget_px = budget,
      max_regions = 1,
    })
    if sized then
      local pixels = IMAGE_W * sized.doc_h * SCALE
      t.ok(pixels <= budget, ("a region planned against a %d px budget costs %d"):format(budget, pixels))
      t.ok(pixels <= resident.MAX_REGION_PIXELS, "and never exceeds the absolute pixel ceiling")
      t.ok(sized.doc_h <= VH * resident.K_MAX + 1e-6, "and never exceeds K_MAX viewports")
    end
  end

  -- Sharing the budget between regions shrinks each one rather than overrunning.
  local shared = assert(resident.plan_region({
    scroll_y = 4000,
    viewport_h = VH,
    viewport_w = VW,
    document_height_px = DOC_H,
    scale = SCALE,
    budget_px = BUDGET * 3,
    max_regions = 3,
  }))
  t.eq(plan.doc_h, shared.doc_h, "three regions out of triple the budget are each the size one was")

  -- ---------------------------------------------------------------------------
  -- The refusals: better a cache miss than a useless region.
  -- ---------------------------------------------------------------------------

  local starved, starved_reason = resident.plan_region({
    scroll_y = 0,
    viewport_h = VH,
    viewport_w = VW,
    document_height_px = DOC_H,
    scale = SCALE,
    budget_px = 4400000,
    max_regions = 1,
  })
  t.eq(nil, starved, "a budget affording less than K_MIN viewports is declined")
  t.ok(starved_reason and starved_reason:match("viewports"), "and says how many it could afford")

  local unscrollable, unscrollable_reason = resident.plan_region({
    scroll_y = 0,
    viewport_h = VH,
    viewport_w = VW,
    document_height_px = VH,
    scale = SCALE,
    budget_px = BUDGET,
    max_regions = 1,
  })
  t.eq(nil, unscrollable, "a document that cannot scroll gets no region")
  t.ok(unscrollable_reason and unscrollable_reason:match("fits the viewport"), "and says so plainly")

  -- A short document is exempt from the minimum. A region holding the whole
  -- document is the best a region can be; refusing it for being under K_MIN
  -- would penalise exactly the documents this helps most.
  local short = assert(resident.plan_region({
    scroll_y = 0,
    viewport_h = VH,
    viewport_w = VW,
    document_height_px = 1100,
    scale = SCALE,
    budget_px = BUDGET,
    max_regions = 1,
  }))
  t.eq(1100, short.doc_h, "a document shorter than one region becomes a single region covering all of it")
  t.ok(short.k < resident.K_MIN, "even though that is under the minimum a partial region must meet")
  t.eq(0, short.doc_y, "and it starts at the top of the document")

  -- ---------------------------------------------------------------------------
  -- The document's ends: where the anchor cannot have what it asked for.
  -- ---------------------------------------------------------------------------

  local at_top = assert(resident.plan_region({
    scroll_y = 0,
    viewport_h = VH,
    viewport_w = VW,
    document_height_px = DOC_H,
    scale = SCALE,
    budget_px = BUDGET,
    max_regions = 1,
  }))
  t.eq(0, at_top.doc_y, "at the top of the document the region starts at zero")
  t.eq(0, at_top.backward_slack, "so none of its travel is behind the reader")
  t.eq(1000, at_top.forward_slack, "and all of it is ahead")

  local scroll_max = DOC_H - VH
  local at_bottom = assert(resident.plan_region({
    scroll_y = scroll_max,
    viewport_h = VH,
    viewport_w = VW,
    document_height_px = DOC_H,
    scale = SCALE,
    budget_px = BUDGET,
    max_regions = 1,
  }))
  t.eq(DOC_H - at_bottom.doc_h, at_bottom.doc_y, "at the bottom the region ends with the document")
  t.eq(0, at_bottom.forward_slack, "so none of its travel is ahead of the reader")
  t.eq(1000, at_bottom.backward_slack, "and all of it is behind")

  -- Maximum scroll must be a hit, or the last screen of every document falls out
  -- of the cache. This is the property that needs no special case *because* the
  -- region is clamped to end with the document.
  local bottom_region = assert(resident.region({
    doc_y = at_bottom.doc_y,
    doc_h = at_bottom.doc_h,
    css_w = VW,
    image_w = IMAGE_W,
    image_h = at_bottom.doc_h * SCALE,
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
  -- The cache: bounded, deterministic, and it hands back what it evicts.
  -- ---------------------------------------------------------------------------

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

  local cache = resident.new_state({ budget_px = BUDGET * 3, max_regions = 3 })
  t.eq(false, cache.enabled, "a fresh resident state is disabled until the controller says otherwise")
  t.eq(0, cache.used_px, "and holds nothing")

  local a = make(0, 2020, "k1", 101)
  local kept, evicted = resident.insert(cache, a)
  t.eq(a, kept, "the first region is taken")
  t.eq(0, #evicted, "and evicts nothing")
  t.eq(IMAGE_W * 4040, cache.used_px, "the budget is charged the region's real pixel count")

  local b = make(2020, 2020, "k1", 102)
  local c = make(4040, 2020, "k1", 103)
  resident.insert(cache, b)
  resident.insert(cache, c)
  t.eq(3, #cache.regions, "three regions fit in a three-region cache")
  t.ok(cache.used_px <= cache.budget_px, "and stay inside the budget")

  -- LRU, not FIFO: the region a reader keeps returning to must survive the one
  -- they passed through once.
  t.eq(a, resident.find(cache, 500, VH, "k1"), "a covered position finds its region")
  t.eq(a, cache.regions[1], "and finding it makes it the most recently used")

  local d = make(6060, 2020, "k1", 104)
  local _, spilled = resident.insert(cache, d)
  t.eq(1, #spilled, "a fourth region evicts exactly one")
  t.eq(102, spilled[1].image_id, "and it is the least recently used, not the oldest inserted")
  t.eq(3, #cache.regions, "the region count stays bounded")
  t.ok(cache.used_px <= cache.budget_px, "and so does the budget")

  -- The hard invariant, across a long random-ish sequence.
  local churn = resident.new_state({ budget_px = BUDGET * 2, max_regions = 2 })
  for index = 1, 40 do
    local height = 1100 + (index * 137) % 900
    local ok_region, dropped = resident.insert(churn, make(index * 500, height, "k1", 200 + index))
    t.ok(ok_region ~= nil, ("insert %d succeeds"):format(index))
    for _, gone in ipairs(dropped) do
      t.ok(gone.image_id ~= nil, "every evicted region is handed back with its image id so it can be freed")
    end
    t.ok(churn.used_px <= churn.budget_px, ("used_px stays within budget at step %d"):format(index))
    t.ok(#churn.regions <= churn.max_regions, ("region count stays bounded at step %d"):format(index))
  end

  -- A region larger than the whole budget is refused rather than evicting
  -- everything to make room for something that still would not fit.
  local tiny = resident.new_state({ budget_px = 1000, max_regions = 2 })
  local refused, refused_evicted, refused_reason = resident.insert(tiny, make(0, 2020, "k1", 900))
  t.eq(nil, refused, "a region larger than the entire budget is refused")
  t.eq(0, #refused_evicted, "and nothing was thrown away for it")
  t.ok(refused_reason and refused_reason:match("budget"), "with a reason naming the budget")
  t.eq(0, tiny.used_px, "and the cache is left as it was")

  -- A new content revision supersedes every region, whatever it covers.
  local rev = resident.new_state({ budget_px = BUDGET * 3, max_regions = 3 })
  resident.insert(rev, make(0, 2020, "old", 301))
  resident.insert(rev, make(2020, 2020, "old", 302))
  local _, stale = resident.insert(rev, make(4040, 2020, "new", 303))
  t.eq(2, #stale, "a region under a new key supersedes every region under the old one")
  t.eq(1, #rev.regions, "leaving only the new one")
  t.eq(nil, resident.find(rev, 100, VH, "new"), "and a stale region is not findable even where it covered")

  -- Refilling the same range replaces rather than duplicates.
  local refill = resident.new_state({ budget_px = BUDGET * 3, max_regions = 3 })
  resident.insert(refill, make(0, 2020, "k1", 401))
  local _, replaced = resident.insert(refill, make(0, 2020, "k1", 402))
  t.eq(1, #replaced, "refilling the same range supersedes the copy it replaces")
  t.eq(401, replaced[1].image_id, "handing back the old image so its pixels are freed")
  t.eq(1, #refill.regions, "rather than holding both")

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

  local ssh = resident.new_state({ budget_px = BUDGET })
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

  -- Local. The same region on a link fast enough that the write blocked longer
  -- than the transfer could possibly take is not held at all -- and it is zero
  -- by arithmetic rather than by a special case, which is what makes the local
  -- path byte-identical to the one that existed before any of this.
  local fast = resident.new_state({ budget_px = BUDGET })
  resident.note_wire_sample(fast, SSH_BYTES, LOCAL_BLOCKED_MS)
  t.eq(
    0,
    resident.wire_hold_ms(REGION_BYTES, fast.wire_bytes_per_ms, LOCAL_BLOCKED_MS, 160, 320),
    "a local link produces no hold at all"
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
  local guarded = resident.new_state({ budget_px = BUDGET })
  resident.note_wire_sample(guarded, 210, 0.01) -- a placement command
  t.eq(nil, guarded.wire_bytes_per_ms, "a placement-sized write is not a throughput measurement")
  resident.note_wire_sample(guarded, SSH_BYTES, 0)
  t.eq(nil, guarded.wire_bytes_per_ms, "nor is one that reported no elapsed time")

  -- The estimate follows the link rather than averaging over the session: a
  -- tunnel that gets slower has to be noticed in seconds, not minutes.
  local drifting = resident.new_state({ budget_px = BUDGET })
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
  local slotted = resident.new_state({ budget_px = BUDGET })
  slotted.fill.token = 7
  slotted.fill.in_flight = true
  resident.drain(slotted)
  t.eq(false, slotted.fill.in_flight, "draining releases the slot")
  t.eq(7, slotted.fill.token, "but keeps the counter monotone, so a late fill knows it is not the holder")

  -- ---------------------------------------------------------------------------
  -- The adaptive PNG cap: bounding the payload, not just the queue behind it.
  -- ---------------------------------------------------------------------------

  local CAP = 305000 * 3 -- three settle frames
  t.eq(1, resident.png_cap_scale(1, CAP - 1, CAP), "a region inside the cap changes nothing")
  t.eq(1, resident.png_cap_scale(1, CAP, CAP), "and one exactly at it is still inside")
  t.near(0.5, resident.png_cap_scale(1, CAP * 2, CAP), 1e-9, "a region twice the cap halves the height allowed")
  -- Cumulative and monotone: it is a session's accumulated evidence that this
  -- document costs more per viewport than the budget assumed, and letting one
  -- cheap region undo it would oscillate between two heights forever.
  t.near(0.25, resident.png_cap_scale(0.5, CAP * 2, CAP), 1e-9, "reductions compound")
  t.eq(0.5, resident.png_cap_scale(0.5, CAP - 1, CAP), "and a later region that fits does not undo one")
  t.eq(
    resident.MIN_HEIGHT_SCALE,
    resident.png_cap_scale(1, CAP * 1000, CAP),
    "a pathological document cannot drive the height to nothing"
  )
  t.eq(1, resident.png_cap_scale(1, 500, nil), "with no cap measured yet there is nothing to judge against")

  -- Draining is what close, retarget and fallback use: everything back, at once.
  local drained = resident.drain(cache)
  t.eq(3, #drained, "draining returns every region")
  t.eq(0, #cache.regions, "and empties the cache")
  t.eq(0, cache.used_px, "and its accounting")
  t.eq(nil, resident.find(cache, 500, VH, "k1"), "so nothing is findable afterwards")

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
