---Whole-document resident image mode: the arithmetic.
---
---Pure. Nothing here touches `vim.api`, the renderer, or a session, so every
---invariant below is a test rather than a comment.
---
---Three layers, and conflating any two of them is how this feature fails:
---
---    document + viewport geometry  ->  one canonical chunk plan
---    scroll position               ->  which chunks are needed
---    opening scroll position       ->  initial capture priority only
---
---The plan is a function of the document and the viewport alone. Where the
---reader happened to open the file reaches `warm_order` and nothing else.
local M = {}

--- A single Page.captureScreenshot is safe to about this much. Mirrored from
--- renderer/src/browser.js so a plan is refused before a request is sent.
local MAX_REGION_PIXELS = 12000000
local MAX_REGION_HEIGHT_PX = 16384

--- What makes a straddled boundary free. Two pane rows of overlap is ~3% of a
--- 2x-viewport chunk at a 60-row pane, against 100% for a whole-viewport one.
local OVERLAP_ROWS = 2

--- iTerm2 3.6.11 / macOS 15, against synthetic incompressible gradients. Not a
--- terminal constant: Kitty, Ghostty and WezTerm are unmeasured, and a
--- sustained-RSS run against a real iTerm2 session disagreed with this figure by
--- 34x. `image.resident_max_chunks` is the bound that does not depend on it.
M.ITERM2_BYTES_PER_RESIDENT_PX = 13

M.MAX_REGION_PIXELS = MAX_REGION_PIXELS
M.MAX_REGION_HEIGHT_PX = MAX_REGION_HEIGHT_PX
M.OVERLAP_ROWS = OVERLAP_ROWS

local EPS = 1e-6

local function finite(value)
  value = tonumber(value)
  if value == nil or value ~= value or value == math.huge or value == -math.huge then return nil end
  return value
end

local function positive(value)
  local number = finite(value)
  if number and number > 0 then return number end
  return nil
end

local function clamp(value, low, high) return math.max(low, math.min(high, value)) end

---The canonical chunk plan for a document.
---
---Returns `{ chunks = { { doc_y, doc_h }, ... }, ... }` in whole **image**
---pixels, ascending by `doc_y`. `open_scroll_y` is deliberately not a parameter:
---two sessions on the same document and viewport must produce identical
---geometry whatever position they were opened at.
---
---Returns `nil, reason` when the viewport cannot be covered -- a chunk has to
---hold a whole viewport plus the overlap, and the Chromium ceilings can cut the
---target below that on a very wide document.
---@param opts table document_h, viewport_h (css px), rows, scale, chunk_viewports
function M.chunk_plan(opts)
  opts = opts or {}
  local document_h = positive(opts.document_h)
  local viewport_h = positive(opts.viewport_h)
  local rows = positive(opts.rows)
  local scale = positive(opts.scale)
  local chunk_viewports = positive(opts.chunk_viewports) or 2
  if not (document_h and viewport_h and rows and scale) then
    return nil, "chunk_plan needs positive document_h, viewport_h, rows and scale"
  end
  rows = math.floor(rows)
  if rows < 1 then return nil, "a pane needs at least one row" end

  local image_w = math.floor(positive(opts.image_w) or 0)
  local row_h = viewport_h / rows
  local overlap_img = math.max(1, math.ceil(OVERLAP_ROWS * row_h * scale))
  local viewport_img = viewport_h * scale
  local document_img = document_h * scale

  local ceiling_img = MAX_REGION_HEIGHT_PX
  if image_w > 0 then ceiling_img = math.min(ceiling_img, math.floor(MAX_REGION_PIXELS / image_w)) end
  local chunk_img = math.floor(math.min(chunk_viewports * viewport_img, ceiling_img))

  local minimum_img = math.ceil(viewport_img) + overlap_img
  if chunk_img < minimum_img then
    return nil,
      ("a chunk of %d image px cannot hold a %d px viewport plus %d px of overlap"):format(
        chunk_img,
        math.ceil(viewport_img),
        overlap_img
      )
  end

  local total_img = math.ceil(document_img)
  local stride_img = chunk_img - overlap_img
  local chunks = {}
  local doc_y = 0
  while true do
    local doc_h = math.min(chunk_img, total_img - doc_y)
    chunks[#chunks + 1] = { doc_y = doc_y, doc_h = doc_h }
    if doc_y + doc_h >= total_img then break end
    doc_y = doc_y + stride_img
  end

  return {
    chunks = chunks,
    count = #chunks,
    chunk_img = chunk_img,
    stride_img = stride_img,
    overlap_img = overlap_img,
    row_h = row_h,
    rows = rows,
    scale = scale,
    image_w = image_w,
    viewport_h = viewport_h,
    document_h = document_h,
    document_img = total_img,
  }
end

---The chunk at `index`, with its position in document (css) coordinates.
function M.chunk(plan, index)
  local entry = plan and plan.chunks and plan.chunks[index]
  if not entry then return nil end
  return {
    index = index,
    doc_y = entry.doc_y,
    doc_h = entry.doc_h,
    css_y = entry.doc_y / plan.scale,
    css_h = entry.doc_h / plan.scale,
    scale = plan.scale,
  }
end

---Which chunks a viewport at `scroll_y` needs. One index, or two adjacent ones.
---Never three: a chunk holds a whole viewport plus the overlap.
function M.chunks_for(plan, scroll_y, viewport_h)
  if not plan or plan.count == 0 then return nil, "no plan" end
  local top = math.max(0, (finite(scroll_y) or 0)) * plan.scale
  local height = (positive(viewport_h) or plan.viewport_h) * plan.scale
  local bottom = math.min(top + height, plan.document_img)
  top = math.min(top, math.max(0, plan.document_img - height))

  local first, last
  for index, entry in ipairs(plan.chunks) do
    local entry_bottom = entry.doc_y + entry.doc_h
    if entry_bottom > top + EPS and entry.doc_y < bottom - EPS then
      first = first or index
      last = index
    end
  end
  if not first then return nil, "no chunk covers this position" end
  -- Prefer a single chunk whenever one covers the whole viewport: a straddle is
  -- only forced when no chunk reaches from `top` to `bottom`.
  for index = first, last do
    local entry = plan.chunks[index]
    if entry.doc_y <= top + EPS and entry.doc_y + entry.doc_h >= bottom - EPS then return { index } end
  end
  if last > first + 1 then last = first + 1 end
  return { first, last }
end

---Where a straddled viewport is cut, as a whole pane row.
---
---Returns the number of rows drawn from the upper chunk, or `nil, reason` when
---the pair cannot compose a screen.
function M.split_rows(plan, upper_index, lower_index, scroll_y)
  local upper = plan and plan.chunks[upper_index]
  local lower = plan and plan.chunks[lower_index]
  if not (upper and lower) then return nil, "no such chunk" end
  local rows = plan.rows
  local row_img = plan.row_h * plan.scale
  local top = math.max(0, (finite(scroll_y) or 0)) * plan.scale
  top = math.min(top, math.max(0, plan.document_img - plan.viewport_h * plan.scale))

  local split = math.ceil((lower.doc_y - top) / row_img - EPS)
  if split < 1 then return nil, "the lower chunk starts at or above the top of the pane" end
  if split >= rows then return nil, "the lower chunk starts at or below the bottom of the pane" end
  if top + split * row_img > upper.doc_y + upper.doc_h + EPS then
    return nil, "the upper chunk does not reach the split"
  end
  return split
end

---The two crops that compose a straddled screen.
---
---Both bands are derived from one snapped seam, so they cannot disagree about
---where the cut is. `nil, reason` if they disagree about scale, which would mean
---the two chunks were built with different geometry.
function M.band_sources(plan, upper_index, lower_index, scroll_y)
  local split, reason = M.split_rows(plan, upper_index, lower_index, scroll_y)
  if not split then return nil, reason end
  local upper = plan.chunks[upper_index]
  local lower = plan.chunks[lower_index]
  local rows = plan.rows
  local row_img = plan.row_h * plan.scale
  local top = math.max(0, (finite(scroll_y) or 0)) * plan.scale
  top = math.min(top, math.max(0, plan.document_img - plan.viewport_h * plan.scale))

  local seam = top + split * row_img
  local bottom = top + rows * row_img

  local upper_top = math.floor(top - upper.doc_y + 0.5)
  local upper_bottom = math.floor(seam - upper.doc_y + 0.5)
  local lower_top = math.floor(seam - lower.doc_y + 0.5)
  local lower_bottom = math.floor(math.min(bottom, lower.doc_y + lower.doc_h) - lower.doc_y + 0.5)

  local upper_h = upper_bottom - upper_top
  local lower_h = lower_bottom - lower_top
  if upper_h < 1 or lower_h < 1 then return nil, "a band would be empty" end

  local per_row_upper = upper_h / split
  local per_row_lower = lower_h / (rows - split)
  if math.abs(per_row_upper - per_row_lower) > 1 then
    return nil,
      ("the bands disagree about scale (%.3f against %.3f image px per row)"):format(per_row_upper, per_row_lower)
  end

  return {
    split = split,
    upper = { index = upper_index, row = 0, rows = split, src_y = upper_top, src_h = upper_h },
    lower = { index = lower_index, row = split, rows = rows - split, src_y = lower_top, src_h = lower_h },
  }
end

---The crop for a viewport drawn entirely from one chunk.
function M.source_window(plan, index, scroll_y)
  local entry = plan and plan.chunks[index]
  if not entry then return nil, "no such chunk" end
  local rows = plan.rows
  local row_img = plan.row_h * plan.scale
  local top = math.max(0, (finite(scroll_y) or 0)) * plan.scale
  top = math.min(top, math.max(0, plan.document_img - plan.viewport_h * plan.scale))
  local src_y = math.floor(top - entry.doc_y + 0.5)
  local src_h = math.floor(rows * row_img + 0.5)
  if src_y < 0 or src_y + src_h > entry.doc_h + 1 then return nil, "the viewport does not fit inside this chunk" end
  return { index = index, row = 0, rows = rows, src_y = src_y, src_h = math.min(src_h, entry.doc_h - src_y) }
end

---The order chunks are captured in: the opening viewport's chunks first, in
---document order, then alternating outward from that block.
---
---A permutation of `1..count` and nothing else. It never reorders the plan.
function M.warm_order(plan, opening_indices)
  if not plan or plan.count == 0 then return {} end
  local count = plan.count
  local seen, order = {}, {}
  for _, index in ipairs(opening_indices or {}) do
    index = math.floor(finite(index) or 0)
    if index >= 1 and index <= count and not seen[index] then
      seen[index] = true
      order[#order + 1] = index
    end
  end
  if #order == 0 then
    seen[1] = true
    order[1] = 1
  end
  local low = order[1]
  local high = order[#order]
  for _, index in ipairs(order) do
    low = math.min(low, index)
    high = math.max(high, index)
  end
  local below, above = low - 1, high + 1
  -- Bounded by the index space rather than by `#order`: both walks can run out
  -- while chunks are still unplaced, and a loop that waits for `#order` to reach
  -- `count` under those conditions is a hung editor rather than a slow one.
  for _ = 1, count do
    if #order >= count then break end
    while above <= count and seen[above] do
      above = above + 1
    end
    while below >= 1 and seen[below] do
      below = below - 1
    end
    if above > count and below < 1 then break end
    if above <= count then
      seen[above] = true
      order[#order + 1] = above
      above = above + 1
    end
    if #order < count and below >= 1 then
      seen[below] = true
      order[#order + 1] = below
      below = below - 1
    end
  end
  -- Anything the outward walk could not reach, which is any gap enclosed by the
  -- opening set rather than outside it.
  for index = 1, count do
    if not seen[index] then
      seen[index] = true
      order[#order + 1] = index
    end
  end
  return order
end

---How many bytes a chunk is expected to occupy in the terminal.
function M.chunk_bytes(plan, index, bytes_per_px)
  local entry = plan and plan.chunks[index]
  if not entry then return 0 end
  return entry.doc_h * math.max(1, plan.image_w) * (positive(bytes_per_px) or M.ITERM2_BYTES_PER_RESIDENT_PX)
end

---The contiguous window of chunks to keep resident around `center`.
---
---Bounded by two independent limits, because one of them rests on a
---bytes-per-pixel figure that is not settled. `max_chunks` holds whether or not
---that figure is right. Extends in `direction` (+1 down, -1 up, 0 balanced) and
---never drops the reader's own chunk.
function M.retain_window(plan, center, opts)
  opts = opts or {}
  if not plan or plan.count == 0 then return {} end
  local count = plan.count
  center = math.floor(clamp(finite(center) or 1, 1, count))
  local max_chunks = math.floor(positive(opts.max_chunks) or count)
  max_chunks = math.max(1, math.min(max_chunks, count))
  local budget_bytes = positive(opts.budget_bytes)
  local bytes_per_px = positive(opts.bytes_per_px) or M.ITERM2_BYTES_PER_RESIDENT_PX
  local direction = finite(opts.direction) or 0

  local kept = { center }
  local spent = M.chunk_bytes(plan, center, bytes_per_px)
  local low, high = center - 1, center + 1
  local prefer_down = direction >= 0

  while #kept < max_chunks do
    local candidate
    if prefer_down and high <= count then
      candidate = high
    elseif low >= 1 then
      candidate = low
    elseif high <= count then
      candidate = high
    end
    if not candidate then break end
    local cost = M.chunk_bytes(plan, candidate, bytes_per_px)
    if budget_bytes and spent + cost > budget_bytes then break end
    spent = spent + cost
    kept[#kept + 1] = candidate
    if candidate == high then
      high = high + 1
    else
      low = low - 1
    end
    if direction == 0 then prefer_down = not prefer_down end
  end

  table.sort(kept)
  return kept, spent
end

---The identity of a document's chunk geometry.
---
---`height` is in here because the document's bottom padding is
---`calc(100vh - Npx)`, so `document.documentElement.scrollHeight` is a function
---of viewport height: opening a split changes every chunk's meaning without
---changing anything else in this list.
function M.key(parts)
  parts = parts or {}
  return table.concat({
    tostring(parts.document_id or ""),
    tostring(parts.revision or ""),
    tostring(parts.width or ""),
    tostring(parts.height or ""),
    tostring(parts.theme or ""),
    tostring(parts.font_size or ""),
    tostring(parts.scroll_past_end and 1 or 0),
    tostring(parts.scroll_past_end_offset or ""),
    tostring(parts.device_scale or ""),
    tostring(parts.chunk_viewports or ""),
  }, "\31")
end

---How fast the link is, in bytes per millisecond.
---
---Two answers, and there is no third. `nvim_ui_send` appends to Neovim's own UI
---queue and returns; the TUI drains that queue later, so a Lua caller sees no
---back-pressure from the link under any circumstances. 24 MB was accepted in
---0.03s on a link doing 0.80 MB/s -- and the rate does not matter to the
---argument, only the ratio: nothing here waited on anything. Every throughput
---sample this plugin can take measures a queue insertion, so an inferred rate is
---not a noisy measurement to be filtered -- it is a quantity that was never
---observed.
function M.link_rate(configured_bytes_per_sec)
  local configured = positive(configured_bytes_per_sec)
  if configured then return configured / 1000, "configured" end
  return nil, "unobservable"
end

return M
