local M = { name = "kitty_raw" }
local owned = {}
local config = require("md-viewer.config")
local terminal = require("md-viewer.terminal")
local next_id = 0x4d000000 + (vim.uv.os_getpid() % 0xffff) * 256
local next_placement_id = 0x5d000000 + (vim.uv.os_getpid() % 0xffff) * 256

local function command(control, payload) return "\27_G" .. control .. ";" .. (payload or "") .. "\27\\" end

local function send(value) vim.api.nvim_ui_send(value) end

local function chunks(encoded, control)
  local size, offset = 4096, 1
  local out = {}
  while offset <= #encoded do
    local piece = encoded:sub(offset, offset + size - 1)
    offset = offset + #piece
    local more = offset <= #encoded and 1 or 0
    out[#out + 1] = command(control .. ",m=" .. more, piece)
    control = "q=2"
  end
  return table.concat(out)
end

local function at(placement, sequence)
  return ("\27[s\27[%d;%dH%s\27[u"):format(placement.row + 1, placement.col + 1, sequence)
end

local function active_profile()
  local capability = terminal.detect()
  return terminal.profiles[capability.profile_id] or terminal.profiles.unknown, capability.profile_id
end

--- Effective z-index and where it came from: an explicit `image.raw_zindex`
--- always wins; otherwise the active terminal profile's default.
local function resolve_zindex()
  local explicit = config.get().image.raw_zindex
  if explicit ~= nil then return math.floor(explicit), "explicit override (image.raw_zindex)" end
  local profile, profile_id = active_profile()
  return math.floor(profile.default_raw_zindex or -1), ("profile default (%s)"):format(profile_id)
end

--- Effective double-buffer policy and where it came from: an explicit
--- `image.double_buffer` always wins; otherwise the active terminal
--- profile's default.
local function resolve_double_buffer()
  local explicit = config.get().image.double_buffer
  if explicit ~= nil then return explicit, "explicit override (image.double_buffer)" end
  local profile, profile_id = active_profile()
  local default = profile.default_double_buffer
  if default == nil then default = true end
  return default, ("profile default (%s)"):format(profile_id)
end

local function zindex() return (resolve_zindex()) end

local function png_dimensions(bytes)
  if type(bytes) ~= "string" or #bytes < 24 or bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" or bytes:sub(13, 16) ~= "IHDR" then
    return nil
  end
  local function u32(offset)
    local a, b, c, d = bytes:byte(offset, offset + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return u32(17), u32(21)
end

local function intersect(a, b)
  local left, top = math.max(a.x, b.x), math.max(a.y, b.y)
  local right = math.min(a.x + a.width, b.x + b.width)
  local bottom = math.min(a.y + a.height, b.y + b.height)
  if left >= right or top >= bottom then return nil end
  return { x = left, y = top, width = right - left, height = bottom - top }
end

local function subtract(region, cut)
  local hit = intersect(region, cut)
  if not hit then return { region } end
  local result = {}
  local function add(x, y, width, height)
    if width > 0 and height > 0 then result[#result + 1] = { x = x, y = y, width = width, height = height } end
  end
  add(region.x, region.y, region.width, hit.y - region.y)
  add(region.x, hit.y + hit.height, region.width, region.y + region.height - hit.y - hit.height)
  add(region.x, hit.y, hit.x - region.x, hit.height)
  add(hit.x + hit.width, hit.y, region.x + region.width - hit.x - hit.width, hit.height)
  return result
end

local function visible_regions(placement)
  local regions = { { x = 0, y = 0, width = placement.width, height = placement.height } }
  for _, exclusion in ipairs(placement.exclusions or {}) do
    local cut = {
      x = exclusion.col - placement.col,
      y = exclusion.row - placement.row,
      width = exclusion.width,
      height = exclusion.height,
    }
    local next_regions = {}
    for _, region in ipairs(regions) do
      for _, piece in ipairs(subtract(region, cut)) do
        next_regions[#next_regions + 1] = piece
      end
    end
    regions = next_regions
  end
  return regions
end

local function new_placement_id()
  next_placement_id = next_placement_id + 1
  return next_placement_id
end

--- Sub-cell offset at which the image starts inside its first cell, as the
--- Kitty graphics protocol's `X`/`Y` placement keys. Returns "" when both are
--- zero so a terminal that does not implement those keys receives exactly the
--- bytes it received before this existed.
---
--- This cancels an origin offset the terminal itself introduces: iTerm2 applies
--- its horizontal window margin to text but not to graphics placements, which
--- lands the image ~10px of a 20px cell left of the text grid. Every cropped
--- region gets the same offset, since each is positioned by its own cursor
--- escape and so has its own "first cell".
local function cell_offset()
  local offset = config.get().image.raw_cell_offset_px or {}
  local x = math.max(0, math.floor(tonumber(offset.x) or 0))
  local y = math.max(0, math.floor(tonumber(offset.y) or 0))
  if x == 0 and y == 0 then return "" end
  return (",X=%d,Y=%d"):format(x, y)
end

---Build (but do not send) the placement commands for one cropped region set,
---along with the fresh placement IDs they use. Kept separate from sending so
---`M.move` can emit a replacement and the deletion it supersedes in a single
---write -- see there for why that matters.
local function placement_sequences(item, placement)
  local sequences, ids = {}, {}
  local offset = cell_offset()
  for _, region in ipairs(visible_regions(placement)) do
    local pid = new_placement_id()
    local x1 = math.floor(region.x * item.width_px / placement.width)
    local y1 = math.floor(region.y * item.height_px / placement.height)
    local x2 = math.floor((region.x + region.width) * item.width_px / placement.width)
    local y2 = math.floor((region.y + region.height) * item.height_px / placement.height)
    local control = ("a=p,q=2,C=1,i=%d,p=%d,x=%d,y=%d,w=%d,h=%d,c=%d,r=%d,z=%d%s"):format(
      item.id,
      pid,
      x1,
      y1,
      math.max(1, x2 - x1),
      math.max(1, y2 - y1),
      region.width,
      region.height,
      zindex(),
      offset
    )
    sequences[#sequences + 1] = at({
      row = placement.row + region.y,
      col = placement.col + region.x,
    }, command(control))
    ids[#ids + 1] = pid
  end
  return table.concat(sequences), ids
end

local function deletion_sequences(image_id, placement_ids)
  local sequences = {}
  for _, pid in ipairs(placement_ids or {}) do
    sequences[#sequences + 1] = command(("a=d,d=i,q=2,i=%d,p=%d"):format(image_id, pid))
  end
  return table.concat(sequences)
end

local function place_regions(item, placement)
  local sequence, ids = placement_sequences(item, placement)
  if sequence ~= "" then send(sequence) end
  item.placement_ids = ids
  item.placement = vim.deepcopy(placement)
end

-- ---------------------------------------------------------------------------
-- Stage-4 selection overlay: the drag highlight as translucent rectangles
-- composited over the base image, so a moving selection frame ships a few
-- hundred bytes of placement commands instead of a full re-captured PNG.
--
-- One solid "tint sheet" image per color is uploaded once (the renderer
-- generates its PNG; Lua cannot practically deflate a viewport-sized image),
-- and every selection rectangle is a *crop* of that sheet placed at natural
-- pixel size -- no c/r keys, because cell-quantized scaling cannot express
-- rectangle geometry that is deliberately not cell-aligned (a 25px line grid
-- against a 20px cell grid). Position inside the first cell uses the X/Y
-- sub-cell keys. All of this is exactly what the operator's 2026-08-07 probe
-- validated on iTerm2 and what crashed WezTerm, hence the per-profile gate in
-- md-viewer.terminal.
-- ---------------------------------------------------------------------------

local sheets = {} -- tint key -> { id, width_px, height_px }
local overlays = {} -- set id -> { sheet_key, placements = { rect key -> placement id } }
local next_overlay_set = 0

---Whether this terminal may be driven with overlay placements at all.
---`interaction.selection_overlay` "on"/"off" overrides; "auto" defers to the
---profile's probe-validated `selection_overlay` flag.
function M.overlay_supported()
  local mode = config.get().interaction.selection_overlay
  if mode == "off" then return false, "interaction.selection_overlay=off (explicit override)" end
  if mode == "on" then return true, "interaction.selection_overlay=on (explicit override)" end
  local profile, profile_id = active_profile()
  if profile.selection_overlay == true then return true, ("profile default (%s)"):format(profile_id) end
  return false, ("profile %s is not validated for translucent overlay placements"):format(profile_id)
end

---One layer above the base, clamped below 0 so the overlay stays under
---Neovim's own text (statusline, notifications) the way the base does. With
---the iTerm2 profile's base at -2 this is -1, the exact pair the probe
---validated; an explicit `image.raw_zindex = -1` degrades to same-z, where
---iTerm2 draws the later-created placement on top (probe check 4c).
local function overlay_zindex() return math.min(-1, zindex() + 1) end

local function tint_key(tint)
  local alpha = math.max(0, math.min(255, math.floor((tonumber(tint and tint.a) or 0) * 255 + 0.5)))
  local function channel(value) return math.max(0, math.min(255, math.floor(tonumber(value) or 0))) end
  return ("%d,%d,%d,%d"):format(channel(tint and tint.r), channel(tint and tint.g), channel(tint and tint.b), alpha)
end

local function sheet_for(tint, min_width, min_height)
  local sheet = sheets[tint_key(tint)]
  if sheet and sheet.width_px >= min_width and sheet.height_px >= min_height then return sheet end
  return nil
end

---True when `M.overlay_apply` for this base image would need `sheet_png`
---supplied. With `tint` nil it answers conservatively for any color, which is
---what the caller knows before the first selection result arrives.
function M.overlay_needs_sheet(base_image_id, tint)
  local item = owned[base_image_id]
  if not item then return false end
  if tint then return sheet_for(tint, item.width_px, item.height_px) == nil end
  for _, sheet in pairs(sheets) do
    if sheet.width_px >= item.width_px and sheet.height_px >= item.height_px then return false end
  end
  return true
end

---Cursor cell and sub-cell pixel offset for image-pixel coordinate `px` along
---one axis, folding in the configured `raw_cell_offset_px` calibration the
---base placement already applies -- both layers must shift by the same amount
---or the highlight detaches from the page under it. The offset can carry the
---position into the next cell; X/Y must stay smaller than the cell.
local function overlay_cell_position(px, cell_size, base_cell, calibration)
  local index = math.floor(px / cell_size)
  local remainder = (px - index * cell_size) + calibration
  local carry = math.floor(remainder / cell_size)
  index = index + carry
  remainder = remainder - carry * cell_size
  local offset = math.floor(remainder + 0.5)
  if offset >= math.floor(cell_size) then
    index = index + 1
    offset = 0
  end
  return base_cell + index, math.max(0, offset)
end

---Compose (but do not send) one overlay crop placement. The crop keys select
---the rectangle's size out of the sheet; no c/r keys, so it displays at
---natural pixel size.
local function overlay_placement_sequence(sheet, rect, placement, cell_w, cell_h, calibration)
  local pid = new_placement_id()
  local col, x_offset = overlay_cell_position(rect.x, cell_w, placement.col, calibration.x)
  local row, y_offset = overlay_cell_position(rect.y, cell_h, placement.row, calibration.y)
  local offset = ""
  if x_offset ~= 0 or y_offset ~= 0 then offset = (",X=%d,Y=%d"):format(x_offset, y_offset) end
  local control = ("a=p,q=2,C=1,i=%d,p=%d,x=0,y=0,w=%d,h=%d,z=%d%s"):format(
    sheet.id,
    pid,
    math.max(1, rect.width),
    math.max(1, rect.height),
    overlay_zindex(),
    offset
  )
  return pid, at({ row = row, col = col }, command(control))
end

---Show (or update) the selection-highlight rectangles for one preview.
---
---`rects` are CSS pixels relative to `viewport` (the browser viewport that
---produced the base image); they are scaled here against the base image's own
---pixel dimensions, so the mapping is exact whatever scale the last capture
---used. `tint` picks the sheet; `sheet_png` must be supplied when
---`M.overlay_needs_sheet` says so and is uploaded once. The rect set is
---diffed against what is already on screen: unchanged rectangles keep their
---existing placements untouched, new ones are emitted *before* the ones they
---supersede are deleted, and both go out in a single write -- the same
---blink-avoidance rule M.move follows.
---
---Returns the set id (stable across calls that pass it back in) plus a stats
---table, or nil and a reason ("need_sheet" is the caller-actionable one).
function M.overlay_apply(set_id, base_image_id, rects, viewport, tint, sheet_png, placement)
  local ok_supported, support_reason = M.overlay_supported()
  if not ok_supported then return nil, support_reason end
  local item = owned[base_image_id]
  if not item then return nil, "base image is not owned by md-viewer" end
  if not (viewport and tonumber(viewport.widthPx) and tonumber(viewport.heightPx)) then
    return nil, "overlay requires the viewport that produced the base image"
  end
  if not (placement and placement.width and placement.width > 0 and placement.height and placement.height > 0) then
    return nil, "overlay requires the base placement rectangle"
  end

  local key = tint_key(tint)
  local sheet = sheet_for(tint, item.width_px, item.height_px)
  if not sheet then
    if type(sheet_png) ~= "string" then return nil, "need_sheet" end
    local width_px, height_px = png_dimensions(sheet_png)
    if not width_px then return nil, "overlay sheet is not a valid PNG" end
    if width_px < item.width_px or height_px < item.height_px then
      return nil,
        ("overlay sheet %dx%d is smaller than the base image %dx%d"):format(
          width_px,
          height_px,
          item.width_px,
          item.height_px
        )
    end
    local previous = sheets[key]
    next_id = next_id + 1
    sheet = { id = next_id, width_px = width_px, height_px = height_px }
    sheets[key] = sheet
    send(chunks(vim.base64.encode(sheet_png), ("a=t,f=100,t=d,q=2,i=%d"):format(sheet.id)))
    -- A smaller predecessor for the same color is fully replaced: any set
    -- still holding placements of it keeps them until its own next apply.
    if previous and previous.id ~= sheet.id then
      local still_used = false
      for _, set in pairs(overlays) do
        if set.sheet_id == previous.id and next(set.placements) ~= nil then still_used = true end
      end
      if not still_used then send(command(("a=d,d=I,q=2,i=%d"):format(previous.id))) end
    end
  end

  local set = set_id and overlays[set_id] or nil
  if set and set.sheet_id ~= sheet.id then
    -- Color or sheet changed mid-flight (theme switch): drop the old set's
    -- placements after the new frame lands, below.
    set = nil
  end
  if not set then
    next_overlay_set = next_overlay_set + 1
    local previous_set = set_id and overlays[set_id] or nil
    set = { sheet_id = sheet.id, placements = {}, superseded = previous_set }
    if set_id then overlays[set_id] = nil end
    set_id = next_overlay_set
    overlays[set_id] = set
  end

  local scale_x = item.width_px / viewport.widthPx
  local scale_y = item.height_px / viewport.heightPx
  local cell_w = item.width_px / placement.width
  local cell_h = item.height_px / placement.height
  local offset_cfg = config.get().image.raw_cell_offset_px or {}
  local calibration = {
    x = math.max(0, math.floor(tonumber(offset_cfg.x) or 0)),
    y = math.max(0, math.floor(tonumber(offset_cfg.y) or 0)),
  }

  -- Exclusions (passive floats punched out of the base placement) in image
  -- pixels, so the overlay honours the same cut-outs and never paints across
  -- a notification.
  local cuts = {}
  for _, exclusion in ipairs(placement.exclusions or {}) do
    cuts[#cuts + 1] = {
      x = (exclusion.col - placement.col) * cell_w,
      y = (exclusion.row - placement.row) * cell_h,
      width = exclusion.width * cell_w,
      height = exclusion.height * cell_h,
    }
  end

  local wanted = {}
  local order = {}
  for _, rect in ipairs(rects or {}) do
    local x0 = math.max(0, math.floor((tonumber(rect.x) or 0) * scale_x + 0.5))
    local y0 = math.max(0, math.floor((tonumber(rect.y) or 0) * scale_y + 0.5))
    local x1 =
      math.min(item.width_px, math.floor(((tonumber(rect.x) or 0) + (tonumber(rect.width) or 0)) * scale_x + 0.5))
    local y1 =
      math.min(item.height_px, math.floor(((tonumber(rect.y) or 0) + (tonumber(rect.height) or 0)) * scale_y + 0.5))
    if x1 > x0 and y1 > y0 then
      local pieces = { { x = x0, y = y0, width = x1 - x0, height = y1 - y0 } }
      for _, cut in ipairs(cuts) do
        local next_pieces = {}
        for _, piece in ipairs(pieces) do
          for _, kept in ipairs(subtract(piece, cut)) do
            next_pieces[#next_pieces + 1] = kept
          end
        end
        pieces = next_pieces
      end
      for _, piece in ipairs(pieces) do
        piece.x = math.floor(piece.x + 0.5)
        piece.y = math.floor(piece.y + 0.5)
        piece.width = math.max(1, math.floor(piece.width + 0.5))
        piece.height = math.max(1, math.floor(piece.height + 0.5))
        local piece_key = ("%d:%d:%d:%d"):format(piece.x, piece.y, piece.width, piece.height)
        if not wanted[piece_key] then
          wanted[piece_key] = piece
          order[#order + 1] = piece_key
        end
      end
    end
  end

  local additions = {}
  local fresh = {}
  for _, piece_key in ipairs(order) do
    local existing = set.placements[piece_key]
    if existing then
      fresh[piece_key] = existing
      set.placements[piece_key] = nil
    else
      local pid, sequence = overlay_placement_sequence(sheet, wanted[piece_key], placement, cell_w, cell_h, calibration)
      additions[#additions + 1] = sequence
      fresh[piece_key] = pid
    end
  end
  local deletions = {}
  for _, pid in pairs(set.placements) do
    deletions[#deletions + 1] = command(("a=d,d=i,q=2,i=%d,p=%d"):format(set.sheet_id, pid))
  end
  local superseded = set.superseded
  set.superseded = nil
  if superseded then
    for _, pid in pairs(superseded.placements) do
      deletions[#deletions + 1] = command(("a=d,d=i,q=2,i=%d,p=%d"):format(superseded.sheet_id, pid))
    end
  end

  -- New rectangles first, then every deletion, one write: deleting first
  -- leaves the terminal a frame with the highlight missing, which reads as
  -- flicker (the M.move hazard, and probe check 5 ran this exact order).
  local payload = table.concat(additions) .. table.concat(deletions)
  if payload ~= "" then send(payload) end
  set.placements = fresh

  local kept, placed = 0, #additions
  for _ in pairs(fresh) do
    kept = kept + 1
  end
  return set_id,
    {
      placed = placed,
      kept = kept - placed,
      deleted = #deletions,
      bytes = #payload,
      rects = #order,
    }
end

---Remove one selection-highlight set's placements. The tint sheet stays
---uploaded for the next gesture; `M.clear_all` frees it.
function M.overlay_clear(set_id)
  local set = set_id and overlays[set_id] or nil
  if not set then return false end
  local deletions = {}
  for _, pid in pairs(set.placements) do
    deletions[#deletions + 1] = command(("a=d,d=i,q=2,i=%d,p=%d"):format(set.sheet_id, pid))
  end
  if #deletions > 0 then send(table.concat(deletions)) end
  overlays[set_id] = nil
  return true
end

function M.capability() return terminal.detect() end

function M.detect()
  if type(vim.api.nvim_ui_send) ~= "function" then return false, "nvim_ui_send unavailable" end
  if #vim.api.nvim_list_uis() == 0 then return false, "no attached TUI" end
  local capability = M.capability()
  if capability.graphics == "unavailable" then
    return false, ("Kitty graphics unavailable: %s (profile: %s)"):format(capability.reason, capability.profile_id)
  end
  return true,
    ("Kitty graphics %s (profile: %s, evidence: %s)"):format(
      capability.graphics,
      capability.profile_id,
      #capability.evidence > 0 and table.concat(capability.evidence, "; ") or "none"
    )
end

function M.show(image_bytes, placement)
  next_id = next_id + 1
  local id = next_id
  local width_px, height_px = png_dimensions(image_bytes)
  if not width_px then error("md-viewer: raw Kitty backend received an invalid PNG") end
  local encoded = vim.base64.encode(image_bytes)
  local item = { id = id, width_px = width_px, height_px = height_px, placement_ids = {} }
  owned[id] = item
  -- Upload once, then use cropped placements so passive floating UI can punch
  -- out only its own cells instead of blanking the complete preview.
  send(chunks(encoded, ("a=t,f=100,t=d,q=2,i=%d"):format(id)))
  place_regions(item, placement)
  return id
end

function M.update(image_id, image_bytes, placement)
  local double_buffer = resolve_double_buffer()
  if image_id and not double_buffer then
    M.clear(image_id)
    return M.show(image_bytes, placement)
  end
  local new_id = M.show(image_bytes, placement)
  if image_id then M.clear(image_id) end
  return new_id
end

---Re-place an already-uploaded image, typically because its crop changed: a
---passive float opened or closed over the preview and its rectangle has to be
---cut out of (or restored to) the placement.
---
---The new placements are emitted *before* the ones they supersede are deleted,
---and both halves go out in one `nvim_ui_send` write. Deleting first leaves the
---terminal with nothing to composite until the replacement arrives, and that
---gap is visible: it was reported as the image blinking and rolling by about a
---row for as long as a notification stayed open. Placement IDs are fresh on
---every call, so the old and new sets never collide while they briefly overlap.
function M.move(image_id, placement)
  local item = owned[image_id]
  if not item then return nil, "image is not owned by md-viewer" end
  local superseded = item.placement_ids or {}
  local sequence, ids = placement_sequences(item, placement)
  local removal = deletion_sequences(item.id, superseded)
  if sequence ~= "" or removal ~= "" then send(sequence .. removal) end
  item.placement_ids = ids
  item.placement = vim.deepcopy(placement)
  return image_id
end

function M.clear(image_id)
  if not owned[image_id] then return false end
  send(command(("a=d,d=I,q=2,i=%d"):format(image_id)))
  owned[image_id] = nil
  return true
end

function M.clear_all()
  for id in pairs(owned) do
    M.clear(id)
  end
  for set_id in pairs(overlays) do
    M.overlay_clear(set_id)
  end
  for key, sheet in pairs(sheets) do
    send(command(("a=d,d=I,q=2,i=%d"):format(sheet.id)))
    sheets[key] = nil
  end
end

function M.health()
  local ok, reason = M.detect()
  local capability = M.capability()
  local placements = 0
  for _, item in pairs(owned) do
    placements = placements + #(item.placement_ids or {})
  end
  local zindex_value, zindex_source = resolve_zindex()
  local double_buffer_value, double_buffer_source = resolve_double_buffer()
  local offset = config.get().image.raw_cell_offset_px or {}
  local overlay_supported, overlay_reason = M.overlay_supported()
  local overlay_sets, overlay_placements = 0, 0
  for _, set in pairs(overlays) do
    overlay_sets = overlay_sets + 1
    for _ in pairs(set.placements) do
      overlay_placements = overlay_placements + 1
    end
  end
  return {
    overlay_supported = overlay_supported,
    overlay_reason = overlay_reason,
    overlay_zindex = math.min(-1, zindex_value + 1),
    overlay_sheets = vim.tbl_count(sheets),
    overlay_sets = overlay_sets,
    overlay_placements = overlay_placements,
    cell_offset_px = ("x=%d, y=%d"):format(tonumber(offset.x) or 0, tonumber(offset.y) or 0),
    overlay_bleed_cells = config.get().image.raw_overlay_bleed_cells,
    available = ok,
    reason = reason,
    -- Whether the terminal advertises Kitty-compatible graphics at all; no
    -- longer hardcoded to iTerm2's own advertisement string.
    advertised = capability.graphics ~= "unavailable",
    -- Neovim owns terminal input, so md-viewer never runs a synchronous
    -- response probe; this stays false even when graphics are available.
    probe_succeeded = false,
    owned_images = vim.tbl_count(owned),
    owned_placements = placements,
    zindex = zindex_value,
    zindex_source = zindex_source,
    double_buffer = double_buffer_value,
    double_buffer_source = double_buffer_source,
    profile = capability.profile_id,
    profile_label = capability.label,
    evidence = capability.evidence,
    graphics_confidence = capability.graphics,
    decision_reason = capability.reason,
    platform = capability.platform,
    multiplexer = capability.multiplexer,
    validation = capability.validation,
    caveats = capability.caveats,
  }
end

return M
