-- The arithmetic behind whole-document resident mode.
--
-- Three layers, and the tests exist because conflating any two of them is the
-- shape of every failure this feature has had:
--
--     document + viewport geometry  ->  one canonical chunk plan
--     scroll position               ->  which chunks are needed
--     opening scroll position       ->  initial capture priority only
--
-- Nothing here needs a terminal, a browser, or a session.
return function(t)
  local resident = require("md-viewer.resident")

  -- A spread wide enough that the ceilings bind on some rows and not others.
  local GEOMETRIES = {}
  for _, document_h in ipairs({ 1200, 4000, 12555, 60000 }) do
    for _, viewport_h in ipairs({ 480, 1020, 1440 }) do
      for _, rows in ipairs({ 12, 30, 61 }) do
        for _, scale in ipairs({ 1, 2 }) do
          GEOMETRIES[#GEOMETRIES + 1] = {
            document_h = document_h,
            viewport_h = viewport_h,
            rows = rows,
            scale = scale,
            image_w = 990 * scale,
          }
        end
      end
    end
  end

  local function plan_for(geometry, chunk_viewports)
    return resident.chunk_plan(vim.tbl_extend("force", geometry, {
      chunk_viewports = chunk_viewports or 2,
    }))
  end

  -- -------------------------------------------------------------------
  -- The plan is canonical
  -- -------------------------------------------------------------------

  local built = 0
  for _, geometry in ipairs(GEOMETRIES) do
    local plan = plan_for(geometry)
    if plan then
      built = built + 1
      local label = ("%dx%d rows=%d scale=%d"):format(
        geometry.document_h,
        geometry.viewport_h,
        geometry.rows,
        geometry.scale
      )

      t.ok(plan.count >= 1, label .. ": a plan has at least one chunk")
      t.eq(0, plan.chunks[1].doc_y, label .. ": the first chunk starts at the top of the document")

      local last = plan.chunks[plan.count]
      t.ok(last.doc_y + last.doc_h >= plan.document_img, label .. ": the last chunk reaches the end")

      local ascending, within_ceiling = true, true
      for index, entry in ipairs(plan.chunks) do
        if index > 1 and entry.doc_y <= plan.chunks[index - 1].doc_y then ascending = false end
        if entry.doc_h > resident.MAX_REGION_HEIGHT_PX then within_ceiling = false end
        if entry.doc_h * plan.image_w > resident.MAX_REGION_PIXELS then within_ceiling = false end
      end
      t.ok(ascending, label .. ": chunks ascend by doc_y")
      t.ok(within_ceiling, label .. ": no chunk exceeds a Chromium ceiling")

      -- Constraint: the upper chunk must reach the first whole row boundary at
      -- or after the lower chunk's start, or a straddled viewport cannot be
      -- composited from the pair.
      local row_img = plan.row_h * plan.scale
      local overlaps = true
      for index = 1, plan.count - 1 do
        local upper = plan.chunks[index]
        local lower = plan.chunks[index + 1]
        local first_boundary = math.ceil(lower.doc_y / row_img) * row_img
        if upper.doc_y + upper.doc_h < first_boundary - 1e-6 then overlaps = false end
      end
      t.ok(overlaps, label .. ": every consecutive pair overlaps by at least a whole row")
    end
  end
  t.ok(built > 40, "the sweep actually built plans (" .. built .. ")")

  -- The property the whole three-layer split rests on.
  local geometry = { document_h = 12555, viewport_h = 1020, rows = 30, scale = 2, image_w = 1980 }
  local from_top = plan_for(geometry)
  local from_middle = plan_for(geometry)
  t.eq(from_top.chunks, from_middle.chunks, "chunk_plan takes no opening position, so geometry cannot vary with one")

  -- -------------------------------------------------------------------
  -- Every scroll position is drawable
  -- -------------------------------------------------------------------

  local plan = plan_for(geometry)
  local max_scroll = geometry.document_h - geometry.viewport_h
  local undrawable, three_chunks, bad_bands = nil, 0, nil
  local straddles = 0
  for step = 0, 400 do
    local scroll_y = max_scroll * (step / 400)
    local needed = resident.chunks_for(plan, scroll_y, geometry.viewport_h)
    if not needed then
      undrawable = undrawable or scroll_y
    elseif #needed > 2 then
      three_chunks = three_chunks + 1
    elseif #needed == 2 then
      straddles = straddles + 1
      local bands, reason = resident.band_sources(plan, needed[1], needed[2], scroll_y)
      if not bands then
        bad_bands = bad_bands or ("at %.1f: %s"):format(scroll_y, reason)
      else
        local per_row_upper = bands.upper.src_h / bands.upper.rows
        local per_row_lower = bands.lower.src_h / bands.lower.rows
        if math.abs(per_row_upper - per_row_lower) > 1 then
          bad_bands = bad_bands or ("at %.1f: %.3f vs %.3f px/row"):format(scroll_y, per_row_upper, per_row_lower)
        end
        if bands.upper.rows + bands.lower.rows ~= plan.rows then
          bad_bands = bad_bands
            or ("at %.1f: bands cover %d of %d rows"):format(scroll_y, bands.upper.rows + bands.lower.rows, plan.rows)
        end
      end
    else
      local window, reason = resident.source_window(plan, needed[1], scroll_y)
      if not window then bad_bands = bad_bands or ("at %.1f: %s"):format(scroll_y, reason) end
    end
  end
  t.eq(nil, undrawable, "every scroll position resolves to at least one chunk")
  t.eq(0, three_chunks, "no viewport ever needs three chunks")
  t.eq(nil, bad_bands, "every composite is valid")
  t.ok(straddles > 0, "the sweep actually exercised straddles (" .. straddles .. ")")

  -- -------------------------------------------------------------------
  -- Capture order is a permutation, and never touches the plan
  -- -------------------------------------------------------------------

  local before = vim.deepcopy(plan.chunks)
  local orders_checked = 0
  for step = 0, 20 do
    local open_scroll = max_scroll * (step / 20)
    local opening = resident.chunks_for(plan, open_scroll, geometry.viewport_h)
    local order = resident.warm_order(plan, opening)
    orders_checked = orders_checked + 1

    t.eq(plan.count, #order, "warm_order returns every chunk exactly once")
    local seen = {}
    local duplicated = false
    for _, index in ipairs(order) do
      if seen[index] then duplicated = true end
      seen[index] = true
    end
    t.ok(not duplicated, "warm_order is a permutation, not a multiset")

    for position, index in ipairs(opening) do
      t.eq(index, order[position], "the opening viewport's chunks are captured first, in document order")
    end
  end
  t.ok(orders_checked == 21, "the warm-order sweep ran")
  t.eq(before, plan.chunks, "warm_order does not reorder or mutate the plan")

  -- warm_order must terminate for any input, not only the adjacent pairs
  -- chunks_for produces. A fill loop that can exhaust both walks with chunks
  -- still unplaced is a hung editor, and this is the input that finds it.
  for _, opening in ipairs({
    { 1, plan.count },
    { plan.count, 1 },
    { 2, 5, 9 },
    { 0, -3, plan.count + 40 },
    {},
  }) do
    local order = resident.warm_order(plan, opening)
    local seen, duplicated = {}, false
    for _, index in ipairs(order) do
      if seen[index] or index < 1 or index > plan.count then duplicated = true end
      seen[index] = true
    end
    t.eq(plan.count, #order, "a disjoint or out-of-range opening set still yields every chunk once")
    t.ok(not duplicated, "and yields no duplicate or out-of-range index")
  end

  -- -------------------------------------------------------------------
  -- Retention is bounded twice
  -- -------------------------------------------------------------------

  local tall = resident.chunk_plan({
    document_h = 200000,
    viewport_h = 1020,
    rows = 30,
    scale = 2,
    image_w = 1980,
    chunk_viewports = 2,
  })
  t.ok(tall.count > 10, "the retention fixture has enough chunks to evict from (" .. tall.count .. ")")

  local center = math.floor(tall.count / 2)
  local kept = resident.retain_window(tall, center, { max_chunks = 5, budget_bytes = math.huge })
  t.eq(5, #kept, "max_chunks bounds the window")
  local holds_center, contiguous = false, true
  for position, index in ipairs(kept) do
    if index == center then holds_center = true end
    if position > 1 and index ~= kept[position - 1] + 1 then contiguous = false end
  end
  t.ok(holds_center, "the reader's own chunk is never evicted")
  t.ok(contiguous, "the retained window is contiguous in document order")

  local down = resident.retain_window(tall, center, { max_chunks = 3, direction = 1 })
  local up = resident.retain_window(tall, center, { max_chunks = 3, direction = -1 })
  t.ok(down[#down] > up[#up], "the window extends in the direction of travel")

  -- The bound that holds when bytes-per-pixel does not. 13 B/px is an iTerm2
  -- measurement that a sustained-RSS run disagreed with by 34x.
  local absurd = resident.retain_window(tall, center, { max_chunks = 4, budget_bytes = 1, bytes_per_px = 1e9 })
  t.eq(1, #absurd, "a budget that admits nothing still keeps the reader's chunk")
  local no_budget = resident.retain_window(tall, center, { max_chunks = 4, bytes_per_px = 1e9 })
  t.eq(4, #no_budget, "with no byte budget the count bound holds alone")

  -- -------------------------------------------------------------------
  -- Refusals
  -- -------------------------------------------------------------------

  local refused, reason = resident.chunk_plan({
    document_h = 5000,
    viewport_h = 1020,
    rows = 30,
    scale = 2,
    image_w = 40000,
    chunk_viewports = 2,
  })
  t.eq(nil, refused, "a document too wide for a viewport-tall chunk is refused, not truncated")
  t.ok(type(reason) == "string" and #reason > 0, "a refusal says why")

  t.eq(
    nil,
    (resident.chunk_plan({ document_h = 0, viewport_h = 1020, rows = 30, scale = 2 })),
    "a zero-height document is refused"
  )
  t.eq(
    nil,
    (resident.chunk_plan({ document_h = 5000, viewport_h = 1020, rows = 0, scale = 2 })),
    "a zero-row pane is refused"
  )

  -- -------------------------------------------------------------------
  -- The link rate has exactly two answers
  -- -------------------------------------------------------------------

  local rate, source = resident.link_rate(800000)
  t.eq(800, rate, "a configured rate arrives in bytes per millisecond")
  t.eq("configured", source)

  for _, input in ipairs({ 0, -1, 0 / 0, nil }) do
    local unobservable, why = resident.link_rate(input)
    t.eq(nil, unobservable, "an unconfigured link rate is not guessed at")
    t.eq("unobservable", why, "and it says so, rather than reporting an estimate")
  end

  -- There is no second parameter, and adding one is the whole bug. nvim_ui_send
  -- appends to Neovim's own UI queue and returns, so every throughput sample a
  -- Lua caller can take measures a queue insertion: 24 MB was accepted in 0.03s
  -- on a link doing 0.80 MB/s. An inferred rate is not a noisy measurement to be
  -- filtered, it is a quantity that was never observed.
  for _, offered in ipairs({ 209046, 139058, 101169, 800 }) do
    local rate, why = resident.link_rate(nil, offered)
    t.eq(nil, rate, "an offered estimate must not become the link rate")
    t.eq("unobservable", why, "an offered estimate must not become a third answer")
  end
  local configured_rate, configured_why = resident.link_rate(800000, 209046)
  t.eq(800, configured_rate, "a configured rate is never capped against a heuristic")
  t.eq("configured", configured_why)

  -- -------------------------------------------------------------------
  -- Document identity
  -- -------------------------------------------------------------------

  local base = {
    document_id = "d",
    revision = "1",
    width = 990,
    height = 1020,
    theme = "dark",
    font_size = 16,
    scroll_past_end = true,
    scroll_past_end_offset = 22,
    device_scale = 2,
    chunk_viewports = 2,
  }
  t.eq(resident.key(base), resident.key(vim.deepcopy(base)), "the same inputs key the same")
  -- The bottom padding is calc(100vh - Npx), so scrollHeight is a function of
  -- viewport height: a split that changes only the height changes every chunk.
  local shorter = vim.tbl_extend("force", base, { height = 900 })
  t.ok(resident.key(base) ~= resident.key(shorter), "viewport height is part of the key")
  local rescaled = vim.tbl_extend("force", base, { device_scale = 1 })
  t.ok(resident.key(base) ~= resident.key(rescaled), "device scale is part of the key")
end
