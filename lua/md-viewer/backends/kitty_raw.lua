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

local function place_regions(item, placement)
  local sequences = {}
  item.placement_ids = {}
  for _, region in ipairs(visible_regions(placement)) do
    local pid = new_placement_id()
    local x1 = math.floor(region.x * item.width_px / placement.width)
    local y1 = math.floor(region.y * item.height_px / placement.height)
    local x2 = math.floor((region.x + region.width) * item.width_px / placement.width)
    local y2 = math.floor((region.y + region.height) * item.height_px / placement.height)
    local control = ("a=p,q=2,C=1,i=%d,p=%d,x=%d,y=%d,w=%d,h=%d,c=%d,r=%d,z=%d"):format(
      item.id,
      pid,
      x1,
      y1,
      math.max(1, x2 - x1),
      math.max(1, y2 - y1),
      region.width,
      region.height,
      zindex()
    )
    sequences[#sequences + 1] = at({
      row = placement.row + region.y,
      col = placement.col + region.x,
    }, command(control))
    item.placement_ids[#item.placement_ids + 1] = pid
  end
  if #sequences > 0 then send(table.concat(sequences)) end
  item.placement = vim.deepcopy(placement)
end

local function delete_placements(item)
  local sequences = {}
  for _, pid in ipairs(item.placement_ids or {}) do
    sequences[#sequences + 1] = command(("a=d,d=i,q=2,i=%d,p=%d"):format(item.id, pid))
  end
  if #sequences > 0 then send(table.concat(sequences)) end
  item.placement_ids = {}
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

function M.move(image_id, placement)
  local item = owned[image_id]
  if not item then return nil, "image is not owned by md-viewer" end
  delete_placements(item)
  place_regions(item, placement)
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
  return {
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
