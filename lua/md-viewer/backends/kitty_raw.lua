local M = { name = "kitty_raw" }
local owned = {}
-- Image ids the last `M.compose` left placed. Tracked separately from `owned`
-- because a chunk that scrolls off screen keeps its pixels and loses only its
-- placements, and the next screen has to know which those were.
local composed = {}
local config = require("md-viewer.config")
local terminal = require("md-viewer.terminal")
local cellpixels = require("md-viewer.cellpixels")
local next_id = 0x4d000000 + (vim.uv.os_getpid() % 0xffff) * 256
local next_placement_id = 0x5d000000 + (vim.uv.os_getpid() % 0xffff) * 256
-- Tint sheets get their own id space, above every id `next_id` can reach in a
-- session, because the Kitty protocol breaks a z-index tie by image id: the
-- lower id draws underneath. `resolve_layers` already keeps the two layers
-- apart, so this is the second of two independent guarantees rather than the
-- load-bearing one -- but it is the rule the protocol itself states, and it is
-- what keeps the highlight on top if the layers are ever pinned together.
-- Base ids would need ~536M frames to climb this far.
local next_sheet_id = 0x6d000000 + (vim.uv.os_getpid() % 0xffff) * 256
-- Animation frames sit between the base and the tint sheets in the id space
-- for the same reason they sit between them in z: if a terminal ever ignored
-- z-index entirely, the protocol's own id tie-break would still order them
-- base < animation < sheet. Base ids would need ~285M frames to reach this.
local next_animation_id = 0x5e000000 + (vim.uv.os_getpid() % 0xffff) * 256

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

---The complete upload transmission for one image id. Named because it is a
---cross-language contract, not just a convenience: the local-render helper
---re-implements exactly this function in JS (`renderer/src/local/
---kitty-writer.js`) to materialize uploads on the terminal's machine, and
---`scripts/local/dump-upload-golden.lua` dumps this one's output so the two
---can be compared byte-for-byte.
local function upload_sequence(id, image_bytes)
  return chunks(vim.base64.encode(image_bytes), ("a=t,f=100,t=d,q=2,i=%d"):format(id))
end

-- ---------------------------------------------------------------------------
-- The presenter seam. Every operation below builds a *transaction* -- uploads
-- (bytes, or a surface reference when the pixels live beside the terminal),
-- placement escapes, deletion escapes -- and one presenter turns it into one
-- terminal write. The default presenter serializes exactly the bytes this
-- backend always sent, in the same per-call boundaries the golden tests pin;
-- md-viewer.localrender installs `backends/kitty_marker`'s instead, which
-- serializes the same transaction into a ~0.3-1 KB marker APC for the local
-- helper's filter to materialize. Placement math, ids, layers, occlusion
-- cut-outs and deletion discipline are identical either way, because they
-- happen before the seam.
--
-- A transaction: { image_id?, doc?, kill?, delete_first?, uploads = { {id,
-- png = bytes} | {id, ref = descriptor} , ... }, place = escapes, delete =
-- escapes }. `kill` marks content removal (hide/retire/clear), which the
-- marker path must propagate so a pending frame dies with the content it
-- belonged to. `delete_first` preserves the non-double-buffered ordering; the
-- marker path always double-buffers and says so in kitty_marker.
-- ---------------------------------------------------------------------------

local function direct_present(tx)
  local parts = {}
  local delete = tx.delete or ""
  if tx.delete_first and delete ~= "" then parts[#parts + 1] = delete end
  for _, upload in ipairs(tx.uploads or {}) do
    if upload.png then parts[#parts + 1] = upload_sequence(upload.id, upload.png) end
    -- A ref here means a demotion raced an in-flight local-mode operation:
    -- there are no pixels on this machine to materialize. The placements
    -- still go out (an unknown id draws nothing under q=2) and the fallback
    -- re-render that every demotion triggers replaces them within a frame --
    -- degraded and visible in counters, never a crash mid-gesture.
  end
  parts[#parts + 1] = tx.place or ""
  if not tx.delete_first then parts[#parts + 1] = delete end
  local payload = table.concat(parts)
  if payload ~= "" then send(payload) end
end

local presenter = direct_present

---Install a presenter (md-viewer.localrender's marker path) or restore the
---default with nil. Global, like the backend itself: `render.location` is
---global config, so every session presents the same way.
function M.set_presenter(value) presenter = value or direct_present end

local function present(tx) return presenter(tx) end

local function active_profile()
  local capability = terminal.detect()
  return terminal.profiles[capability.profile_id] or terminal.profiles.unknown, capability.profile_id
end

--- The z-index the configuration asks for, and where it came from: an explicit
--- `image.raw_zindex` always wins; otherwise the active terminal profile's
--- default. `resolve_layers` below turns this into the layer the base image is
--- actually drawn on, which is not always the same number.
local function resolve_zindex()
  local explicit = config.get().image.raw_zindex
  if explicit ~= nil then return math.floor(explicit), "explicit override (image.raw_zindex)" end
  local profile, profile_id = active_profile()
  return math.floor(profile.default_raw_zindex or -1), ("profile default (%s)"):format(profile_id)
end

--- Effective double-buffer policy and where it came from. Delegated to
--- `terminal.double_buffer` so this backend and `nvim_img` cannot disagree
--- about it -- see the note there.
local function resolve_double_buffer() return terminal.double_buffer() end

---The layers this backend draws on -- the base image, animation frames above
---it, and the selection overlay above those -- derived together so that they can
---never collide. Returns base, animation, overlay (nil when the overlay is
---disabled outright), and where the configured value came from.
---
---They have to be derived together because the Kitty graphics protocol breaks a
---z-index tie by *image id*: "if two images with the same z-index overlap then
---the image with the lower id is considered to have the lower z-index". A base
---and an overlay sharing a layer are therefore ordered by which image was
---uploaded most recently -- and md-viewer re-uploads the base on every full
---frame, so the first settle capture after a gesture puts the base permanently
---on top of the tint sheet. That is the 2026-08-08 Ghostty defect: exactly one
---instant highlight per session, then the overlay drawn underneath every later
---one, with nothing reporting an error because every placement was accepted.
---Ghostty sorts placements by (z, image id) and rebuilds the list from an
---unordered map each frame, so it has no creation order to fall back on;
---iTerm2 happens to draw the later-created placement on top, which is the only
---reason a shared layer ever appeared to work (probe check 4c).
---
---The base keeps the layer it was configured onto, and the others stack upward
---from it one at a time. The single thing that can move it is a stack that
---would reach z=0, where the Kitty protocol draws *over* Neovim's own text
---rather than under it: then the whole stack slides down just far enough for
---its top to land on -1. Every layer involved sits in the same "under text,
---over background" band (only z < INT32_MIN/2 goes beneath a non-default cell
---background), so that slide is invisible. A base deliberately put above the
---text keeps its layer and takes the others up with it, which is the only place
---a highlight can be seen from there.
---
---The animation layer is reserved whether or not anything is animating, and
---whether or not `render.animate` is on. It costs nothing to reserve, and a
---layer that appears only when a document happens to contain an animated GIF is
---a stack that changes shape under the user -- which is the one property this
---function exists to deny.
---
---`interaction.selection_overlay = "off"` drops the overlay layer and nothing
---else, so an explicit `image.raw_zindex` still lands the base exactly where it
---was put unless the animation layer above it would reach the text. The gate is
---that config value rather than `M.overlay_supported()` so the base's layer
---cannot shift mid-session when a resize costs us the cell measurement.
local function resolve_layers()
  local configured, source = resolve_zindex()
  local overlay_enabled = config.get().interaction.selection_overlay ~= "off"
  local top = configured + (overlay_enabled and 2 or 1)
  -- Only a stack that would collide with the text is moved, and only far enough
  -- to clear it. A base already placed above the text asked to be there.
  local shift = (configured < 0 and top >= 0) and top + 1 or 0
  local base = configured - shift
  if shift > 0 then
    source = ("%s, lowered from %d to leave the layers above it their own"):format(source, configured)
  end
  return base, base + 1, overlay_enabled and base + 2 or nil, source
end

local function zindex() return (resolve_layers()) end

local function animation_zindex() return (select(2, resolve_layers())) end

local function overlay_zindex() return (select(3, resolve_layers())) end

local function png_dimensions(bytes)
  if type(bytes) ~= "string" or #bytes < 24 or bytes:sub(1, 8) ~= "\137PNG\r\n\26\n" or bytes:sub(13, 16) ~= "IHDR" then
    return nil
  end
  local function u32(offset)
    local a, b, c, d = bytes:byte(offset, offset + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  local width, height = u32(17), u32(21)
  -- A zero dimension is a valid-looking header and a real hazard: `0` is
  -- truthy in Lua, so it used to sail past every caller's `if not width` check
  -- and produce a placement cropping a region out of an image with no pixels
  -- in it. On WezTerm that is `draw_width == 0`, which is the divisor in the
  -- c/r branch of upstream issue #6344 -- a panic that takes the terminal down.
  if width < 1 or height < 1 then return nil end
  return width, height
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

-- ---------------------------------------------------------------------------
-- Placement preconditions (upstream WezTerm issue #6344).
--
-- WezTerm does not place images freely: `assign_image_to_cells`
-- (term/src/terminalstate/image.rs) slices every placement into per-cell
-- fragments, and until #6344 was fixed that function had two integer divisions
-- with nothing in front of them. They sit on *different* branches, so each of
-- the two kinds of placement this backend emits reaches exactly one:
--
--   * a placement WITHOUT c/r -- every selection-overlay rectangle -- divides
--     `draw_width / cell_pixel_width` and `draw_height / cell_pixel_height`,
--     where `cell_pixel_width = pixel_width / physical_cols`. A pty carrying no
--     pixel geometry makes that zero.
--   * a placement WITH c/r -- every base frame -- divides
--     `(cols * cell_pixel_width) * image_width / draw_width`, where
--     `draw_width = min(w, image_width - x)`. A `w=0`, or a crop origin at or
--     past the image's edge, makes that zero.
--
-- A divide by zero is a Rust panic and the panic takes the whole application
-- down -- every window, every pane, whatever was unsaved in them. That is what
-- the 2026-08-07 probe hit on 20240203-110809-5046fc22. Upstream added an
-- `anyhow::ensure!` for each condition afterwards; md-viewer enforces the same
-- two preconditions on its own side, so the February 2024 stable stays
-- supported without asking anyone to install a nightly.
--
-- Everything this backend already computes satisfies both, which is the point:
-- the guards below refuse only inputs that are never produced, so they change
-- no bytes on any terminal. `tests/lua/cases/backend_kitty.lua` pins the exact
-- output of the iTerm2/Ghostty/Kitty path as golden strings so that stays true.
-- ---------------------------------------------------------------------------

---Whether a measured cell can be placed against at all. WezTerm floors the
---cell to whole pixels and divides by it, so a cell that floors to zero is a
---crash rather than a rounding error. Nothing `cellpixels` accepts today gets
---near it (its plausibility band starts at 2px) -- this states the precondition
---rather than leaving that band to imply it.
local function cell_is_placeable(cell)
  return cell ~= nil and math.floor(cell.width) >= 1 and math.floor(cell.height) >= 1
end

---Whether one crop rectangle lies wholly inside the image it is taken from,
---and covers at least one pixel. Returns the width and height to send, or nil.
---
---Deliberately a refusal and not a clamp. Silently shrinking an out-of-bounds
---crop would draw a subtly wrong rectangle, and a subtly wrong rectangle that
---nobody is told about is the exact shape of every defect this area has
---produced so far -- the highlight bars once sized in captured rather than
---drawn pixels went unnoticed for a whole release. A refusal is visible: the
---overlay drops to the captured-frame path for the gesture and says why.
local function crop_within(image_w, image_h, x, y, w, h)
  if not (tonumber(image_w) and tonumber(image_h) and tonumber(x) and tonumber(y)) then return nil end
  if not (tonumber(w) and tonumber(h)) then return nil end
  if x < 0 or y < 0 or w < 1 or h < 1 then return nil end
  if x + w > image_w or y + h > image_h then return nil end
  return math.floor(w), math.floor(h)
end

---A finite number, or `fallback` when the field is absent, or nil when it is
---present but not a number this can be arithmetic with. Non-finite geometry
---has to be dropped rather than defaulted: NaN survives every comparison as
---false and would reach the wire as a garbage `w=`/`h=`.
local function coord(value, fallback)
  value = tonumber(value)
  if value == nil then return fallback end
  if value ~= value or value == math.huge or value == -math.huge then return nil end
  return value
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
    local x1 = math.floor(region.x * item.width_px / placement.width)
    local y1 = math.floor(region.y * item.height_px / placement.height)
    local x2 = math.floor((region.x + region.width) * item.width_px / placement.width)
    local y2 = math.floor((region.y + region.height) * item.height_px / placement.height)
    -- This is the c/r branch of #6344: a zero `w`/`h`, or a crop origin at the
    -- image's edge, is the divisor. The pid is allocated after the guard so a
    -- refused region does not consume one.
    local crop_w, crop_h =
      crop_within(item.width_px, item.height_px, x1, y1, math.max(1, x2 - x1), math.max(1, y2 - y1))
    if crop_w and region.width >= 1 and region.height >= 1 then
      local pid = new_placement_id()
      local control = ("a=p,q=2,C=1,i=%d,p=%d,x=%d,y=%d,w=%d,h=%d,c=%d,r=%d,z=%d%s"):format(
        item.id,
        pid,
        x1,
        y1,
        crop_w,
        crop_h,
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

---The command that deletes an image and frees its data. Built rather than sent
---so `M.update` can pack it into the same write as the image superseding it.
local function deletion_command(image_id) return command(("a=d,d=I,q=2,i=%d"):format(image_id)) end

---Allocate an image id, register it as owned, and build (but do not send)
---its placements. The upload itself is the presenter's job -- for the direct
---path that means `upload_sequence` over the PNG bytes; for the marker path
---it means a surface reference, because the pixels exist on the terminal's
---machine and were never here. Placement math is identical either way, and
---cropped placements are what let passive floating UI punch out only its own
---cells instead of blanking the complete preview.
local function register_item(width_px, height_px, placement)
  next_id = next_id + 1
  local id = next_id
  local item = { id = id, width_px = width_px, height_px = height_px, placement_ids = {} }
  owned[id] = item
  local sequence, ids = placement_sequences(item, placement)
  item.placement_ids = ids
  item.placement = vim.deepcopy(placement)
  return id, sequence
end

-- ---------------------------------------------------------------------------
-- Selection overlay: the selection highlight as translucent rectangles
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

---One overlay set's placement ids in a stable order (by rect key).
---
---The deletions these produce are independent of one another -- distinct
---placement ids, all in a single write -- so the terminal cannot tell the
---orders apart. `pairs` over a hash table, however, has no defined order, and
---it was observed to reorder between two builds of this file that differed
---nowhere near it. That is a trap: it makes the emitted stream unassertable,
---so the one thing this backend most needs to be able to prove -- that the
---terminals validated by hand still receive exactly what they were validated
---against -- could not be written down. Sorting costs nothing at these sizes
---and buys `tests/lua/cases/backend_kitty.lua` a golden it can trust.
local function ordered_pids(placements)
  local keys = {}
  for key in pairs(placements or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local pids = {}
  for _, key in ipairs(keys) do
    pids[#pids + 1] = placements[key]
  end
  return pids
end

---Whether this terminal may be driven with overlay placements at all.
---`interaction.selection_overlay` "on"/"off" overrides; "auto" defers to the
---profile's probe-validated `selection_overlay` flag.
---
---Knowing the terminal's cell in physical pixels is a precondition that even
---"on" cannot override, because it is a correctness requirement rather than a
---capability judgement: overlay crops carry no `c`/`r` keys and therefore
---display at natural pixel size, and without the real cell there is no way to
---know what a pixel is worth on screen. Getting that wrong does not degrade
---the highlight, it misdraws it -- see `cellpixels.lua`.
---The half of `M.overlay_supported` that is about correctness rather than
---about the selection feature, factored out so animation placements can require
---exactly the same thing without restating it. Both draw crops at natural pixel
---size, so both need to know what a pixel is worth; neither can be talked into
---it by configuration.
local function placement_precondition()
  local cell, cell_reason = cellpixels.measure()
  if not cell then
    return false,
      ("the terminal's pixel cell size is unknown (%s), and placement rectangles are sized in pixels"):format(
        cell_reason
      )
  end
  -- Also a correctness precondition rather than a capability judgement, and on
  -- WezTerm 20240203 a safety one: a cell that floors to zero pixels is the
  -- divisor in the no-c/r branch of issue #6344. See `cell_is_placeable`.
  if not cell_is_placeable(cell) then
    return false,
      ("the terminal's cell floors to %dx%d px, which no natural-size placement can be sized against"):format(
        math.floor(cell.width),
        math.floor(cell.height)
      )
  end
  return true
end

function M.overlay_supported()
  local mode = config.get().interaction.selection_overlay
  if mode == "off" then return false, "interaction.selection_overlay=off (explicit override)" end
  local ok, reason = placement_precondition()
  if not ok then return false, reason end
  if mode == "on" then return true, "interaction.selection_overlay=on (explicit override)" end
  local profile, profile_id = active_profile()
  if profile.selection_overlay == true then return true, ("profile default (%s)"):format(profile_id) end
  return false, ("profile %s is not validated for translucent overlay placements"):format(profile_id)
end

---The transparent margin this terminal's tint sheet needs, or nil.
---
---Only WezTerm asks for one, and only because it insets every cell of a
---placement by the `X`/`Y` sub-cell offset rather than the first cell alone.
---One cell on each axis is exactly enough: the crop starts `cell - offset`
---pixels into the margin, so the largest offset a cell can carry still leaves
---at least one margin pixel to crop from. See the note above `M.profiles` in
---md-viewer.terminal.
function M.overlay_margin()
  local profile = active_profile()
  if profile.overlay_encoding ~= "sheet-margin" then return nil end
  local cell = cellpixels.measure()
  if not cell then return nil end
  return { x = math.floor(cell.width), y = math.floor(cell.height) }
end

local function tint_key(tint, margin)
  local alpha = math.max(0, math.min(255, math.floor((tonumber(tint and tint.a) or 0) * 255 + 0.5)))
  local function channel(value) return math.max(0, math.min(255, math.floor(tonumber(value) or 0))) end
  -- The margin is part of the identity: a marginless sheet cannot stand in for
  -- a margined one, and cropping the wrong one would silently shift every
  -- rectangle by up to a cell.
  return ("%d,%d,%d,%d+%d,%d"):format(
    channel(tint and tint.r),
    channel(tint and tint.g),
    channel(tint and tint.b),
    alpha,
    margin and margin.x or 0,
    margin and margin.y or 0
  )
end

local function sheet_for(tint, margin, min_width, min_height)
  local sheet = sheets[tint_key(tint, margin)]
  if sheet and sheet.width_px >= min_width and sheet.height_px >= min_height then return sheet end
  return nil
end

---How large the tint sheet must be to cover any rectangle this base image can
---produce. Crops are taken in *drawn* pixels (`placement` cells times the real
---cell), which is smaller than the captured image whenever the render viewport
---over-estimated the cell and larger whenever it under-estimated it -- so the
---sheet has to cover whichever is bigger.
---
---`item` is nil for a resident screen, which owns no single base frame: it is
---one or two cropped bands and there is no one image the highlight sits over.
---The drawn box is the whole answer there, which is also what
---md-viewer.interaction sizes its sheet from -- so a resident session asks for
---exactly the sheet it builds. Passing a *chunk* instead would be worse than
---useless: a chunk is about two viewports tall, so this would demand a sheet
---that size and `overlay_apply` would refuse every one it was ever handed.
local function required_sheet_size(item, placement)
  local width, height = item and item.width_px or 0, item and item.height_px or 0
  local cell = cellpixels.measure()
  if cell and placement and placement.width and placement.height then
    width = math.max(width, math.ceil(placement.width * cell.width))
    height = math.max(height, math.ceil(placement.height * cell.height))
  end
  -- The margin sits outside the drawn box: a crop runs from `margin - offset`
  -- to `margin + rect width`, so the sheet has to be that much larger again.
  local margin = M.overlay_margin()
  if margin then
    width = width + margin.x
    height = height + margin.y
  end
  return width, height
end

---True when `M.overlay_apply` for this base image would need `sheet_png`
---supplied. With `tint` nil it answers conservatively for any color, which is
---what the caller knows before the first selection result arrives.
function M.overlay_needs_sheet(base_image_id, tint, placement)
  -- A nil id is a resident screen asking on its own behalf, not a caller that
  -- has lost track of its frame; only an id that names nothing is a refusal.
  local item = base_image_id and owned[base_image_id] or nil
  if base_image_id and not item then return false end
  local width, height = required_sheet_size(item, placement)
  local margin = M.overlay_margin()
  if tint then return sheet_for(tint, margin, width, height) == nil end
  local prefix = tint_key(nil, margin):match("^.-(%+%d+,%d+)$")
  for key, sheet in pairs(sheets) do
    -- Only a sheet with this terminal's margin can serve: same reason the
    -- margin is part of the cache key.
    if key:sub(-#prefix) == prefix and sheet.width_px >= width and sheet.height_px >= height then return false end
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
local function overlay_placement_sequence(sheet, rect, placement, cell_w, cell_h, calibration, margin)
  local col, x_offset = overlay_cell_position(rect.x, cell_w, placement.col, calibration.x)
  local row, y_offset = overlay_cell_position(rect.y, cell_h, placement.row, calibration.y)

  local crop_x, crop_y, want_w, want_h, offset = 0, 0, rect.width, rect.height, ""
  if margin then
    -- Express the sub-cell position by cropping into the sheet's transparent
    -- margin, and send no X/Y keys at all. The placement's leading `x_offset`
    -- pixels come out transparent, so the tint starts exactly where the
    -- rectangle does -- with nothing for WezTerm to inset per cell.
    crop_x, crop_y = margin.x - x_offset, margin.y - y_offset
    want_w, want_h = x_offset + rect.width, y_offset + rect.height
  elseif x_offset ~= 0 or y_offset ~= 0 then
    offset = (",X=%d,Y=%d"):format(x_offset, y_offset)
  end

  -- The no-c/r branch of #6344 divides by the cell rather than by `w`, so what
  -- matters here is that the crop stays inside the sheet: an oversized `w`
  -- would be silently clamped by the terminal to `image_width - x` anyway, and
  -- a crop starting past the edge is the one shape that cannot be drawn.
  local crop_w, crop_h = crop_within(sheet.width_px, sheet.height_px, crop_x, crop_y, want_w, want_h)
  if not crop_w then return nil end
  local pid = new_placement_id()
  local control = ("a=p,q=2,C=1,i=%d,p=%d,x=%d,y=%d,w=%d,h=%d,z=%d%s"):format(
    sheet.id,
    pid,
    crop_x,
    crop_y,
    crop_w,
    crop_h,
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
  -- Nil is legitimate: a resident screen is bands cropped out of chunks and
  -- owns no base frame at all. `item` is read for exactly two things -- this
  -- ownership check and `required_sheet_size` -- and everything below is
  -- derived from `placement`, `cell` and `viewport`, so the highlight lands on
  -- the same pixels either way.
  local item = base_image_id and owned[base_image_id] or nil
  if base_image_id and not item then return nil, "base image is not owned by md-viewer" end
  if not (viewport and tonumber(viewport.widthPx) and tonumber(viewport.heightPx)) then
    return nil, "overlay requires the viewport that produced the base image"
  end
  if not (placement and placement.width and placement.width > 0 and placement.height and placement.height > 0) then
    return nil, "overlay requires the base placement rectangle"
  end

  local cell, cell_reason = cellpixels.measure()
  if not cell then return nil, cell_reason end

  local need_w, need_h = required_sheet_size(item, placement)
  local margin = M.overlay_margin()
  local key = tint_key(tint, margin)
  local sheet = sheet_for(tint, margin, need_w, need_h)
  if not sheet then
    -- Two ways to satisfy a missing sheet: PNG bytes from the renderer (the
    -- current-host path), or a table reference (the local path, where the
    -- helper synthesizes the identical sheet from the tint and dimensions --
    -- overlay-sheet.js is the same code on both machines). Either way the
    -- upload is one presenter transaction of its own, preserving the write
    -- boundary the golden pins.
    local upload
    if type(sheet_png) == "string" then
      local width_px, height_px = png_dimensions(sheet_png)
      if not width_px then return nil, "overlay sheet is not a valid PNG" end
      if width_px < need_w or height_px < need_h then
        return nil,
          ("overlay sheet %dx%d is smaller than the %dx%d it must cover"):format(width_px, height_px, need_w, need_h)
      end
      upload = { png = sheet_png, width_px = width_px, height_px = height_px }
    elseif type(sheet_png) == "table" and sheet_png.ref then
      -- The reference is completed here rather than by the caller because the
      -- required size and this terminal's margin are knowledge this function
      -- owns; the caller only says "synthesize, don't ship bytes". The tint
      -- travels as rrggbbaa so the helper's overlay-sheet.js builds the
      -- byte-identical sheet the direct path would have been handed.
      local alpha = math.max(0, math.min(255, math.floor((tonumber(tint and tint.a) or 0) * 255 + 0.5)))
      local function channel(value) return math.max(0, math.min(255, math.floor(tonumber(value) or 0))) end
      upload = {
        ref = {
          kind = "sheet",
          tint = ("%02x%02x%02x%02x"):format(
            channel(tint and tint.r),
            channel(tint and tint.g),
            channel(tint and tint.b),
            alpha
          ),
          -- Ceiled: the marker grammar carries integers, and a sheet may
          -- only ever round up -- it has to cover the box, not fit it.
          widthPx = math.ceil(need_w),
          heightPx = math.ceil(need_h),
          marginX = margin and margin.x or 0,
          marginY = margin and margin.y or 0,
        },
        width_px = math.ceil(need_w),
        height_px = math.ceil(need_h),
      }
    else
      return nil, "need_sheet"
    end
    local previous = sheets[key]
    next_sheet_id = next_sheet_id + 1
    sheet = { id = next_sheet_id, width_px = upload.width_px, height_px = upload.height_px }
    sheets[key] = sheet
    present({
      image_id = base_image_id,
      uploads = { { id = sheet.id, png = upload.png, ref = upload.ref } },
    })
    -- A smaller predecessor for the same color is fully replaced: any set
    -- still holding placements of it keeps them until its own next apply.
    if previous and previous.id ~= sheet.id then
      local still_used = false
      for _, set in pairs(overlays) do
        if set.sheet_id == previous.id and next(set.placements) ~= nil then still_used = true end
      end
      if not still_used then
        present({ image_id = base_image_id, delete = command(("a=d,d=I,q=2,i=%d"):format(previous.id)) })
      end
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
    set = { sheet_id = sheet.id, placements = {}, superseded = previous_set, base_image_id = base_image_id }
    if set_id then overlays[set_id] = nil end
    set_id = next_overlay_set
    overlays[set_id] = set
  end
  set.base_image_id = base_image_id or set.base_image_id

  -- The base image is placed with c/r keys, so the terminal scales it to fill
  -- exactly placement.width x placement.height cells. Overlay crops carry no
  -- c/r and display at natural pixel size, so a rectangle has to be expressed
  -- in the pixels the base image is *drawn* at -- not the pixels it was
  -- *captured* at, which is all `item.width_px` knows.
  --
  -- Those two differ by however much the render viewport mis-estimated the
  -- cell: with `coordinates.viewport` on its "estimated" tier -- now the
  -- fallback for a terminal that reports no pixel geometry, but once the
  -- default -- guessing 10x20 CSS px against a real 7x16, a 1980x2040 capture
  -- is drawn into 1386x1632, and
  -- rectangles sized against the capture come out 1.41x too wide and 1.24x too
  -- tall while still sitting at the right place (cells being exact either
  -- way). That is precisely the defect the operator reported on 2026-08-08.
  --
  -- Deriving both the scale and the cell from the measured cell keeps this
  -- correct whatever the capture size is, including when the render viewport
  -- is exact and the two agree.
  local cell_w, cell_h = cell.width, cell.height
  local drawn_w = placement.width * cell_w
  local drawn_h = placement.height * cell_h
  local scale_x = drawn_w / viewport.widthPx
  local scale_y = drawn_h / viewport.heightPx
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
    -- `coord` keeps the old "absent means 0" behaviour for every finite input
    -- and drops NaN/infinite geometry outright: NaN compares false against
    -- everything, so it would slip past the `x1 > x0` guard below in one
    -- direction and reach the wire as a garbage `w=`/`h=` in the other.
    local rx, ry = coord(rect.x, 0), coord(rect.y, 0)
    local rw, rh = coord(rect.width, 0), coord(rect.height, 0)
    local x0 = rx and math.max(0, math.floor(rx * scale_x + 0.5))
    local y0 = ry and math.max(0, math.floor(ry * scale_y + 0.5))
    local x1 = rx and rw and math.min(drawn_w, math.floor((rx + rw) * scale_x + 0.5))
    local y1 = ry and rh and math.min(drawn_h, math.floor((ry + rh) * scale_y + 0.5))
    if x0 and y0 and x1 and y1 and x1 > x0 and y1 > y0 then
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

  -- Validate every rectangle against the sheet before touching `set`: a
  -- refusal partway through the diff below would strand the placements it had
  -- already moved out of `set.placements`, and they would never be deleted.
  for _, piece_key in ipairs(order) do
    local piece = wanted[piece_key]
    -- With a margin the crop runs from `margin - offset`, so the worst case is
    -- the whole margin plus the rectangle; without one it is the rectangle.
    local reach_w = piece.width + (margin and margin.x or 0)
    local reach_h = piece.height + (margin and margin.y or 0)
    if not crop_within(sheet.width_px, sheet.height_px, 0, 0, reach_w, reach_h) then
      return nil,
        ("a %dx%d rectangle does not fit the %dx%d tint sheet"):format(
          piece.width,
          piece.height,
          sheet.width_px,
          sheet.height_px
        )
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
      local pid, sequence =
        overlay_placement_sequence(sheet, wanted[piece_key], placement, cell_w, cell_h, calibration, margin)
      -- The pre-pass above already proved every rectangle fits, so this cannot
      -- be nil; if it ever is, refusing the frame is right -- the caller drops
      -- to captured frames, which are correct and merely slower.
      if not pid then return nil, "a rectangle could not be expressed as a crop of the tint sheet" end
      additions[#additions + 1] = sequence
      fresh[piece_key] = pid
    end
  end
  local deletions = {}
  for _, pid in ipairs(ordered_pids(set.placements)) do
    deletions[#deletions + 1] = command(("a=d,d=i,q=2,i=%d,p=%d"):format(set.sheet_id, pid))
  end
  local superseded = set.superseded
  set.superseded = nil
  if superseded then
    for _, pid in ipairs(ordered_pids(superseded.placements)) do
      deletions[#deletions + 1] = command(("a=d,d=i,q=2,i=%d,p=%d"):format(superseded.sheet_id, pid))
    end
  end

  -- New rectangles first, then every deletion, one write: deleting first
  -- leaves the terminal a frame with the highlight missing, which reads as
  -- flicker (the M.move hazard, and probe check 5 ran this exact order).
  present({ image_id = base_image_id, place = table.concat(additions), delete = table.concat(deletions) })
  local payload = table.concat(additions) .. table.concat(deletions)
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

-- ---------------------------------------------------------------------------
-- Animation frames
-- ---------------------------------------------------------------------------
--
-- An animated GIF cannot animate through the base image: a frame of the
-- preview is one Chromium screenshot, so whatever the browser painted is
-- frozen there by construction. Instead the renderer decodes the GIF's frames
-- to PNGs and the terminal draws them itself, on their own layer, over the
-- still frame the base already carries.
--
-- Mechanically this is the selection overlay with the tint sheet swapped for
-- one image per frame: a crop placed at natural pixel size, positioned to the
-- sub-cell with X/Y, clipped to the preview and punched through by the same
-- exclusions. The differences are that each item carries its own image id, and
-- that Node has already encoded every frame at exactly the size it is drawn --
-- so the crop is 1:1 and there is no scale factor to get wrong.

local animations = {} -- set id -> { placements = { key -> { pid, image_id } } }
local ordered_animation_placements
local animation_images = {} -- content key -> image id
local next_animation_set = 0

---The animation mode the resolved terminal capability grants, with its
---evidence string. "native" drives the terminal's own animation player,
---"frames" swaps placements from the client, "off" leaves the still frame.
---The mode itself -- profile default or `terminal.animation` override --
---resolves in terminal.capability(); this only reads the answer.
local function animation_mode()
  local capability = terminal.detect()
  local animation = capability.animation
  if type(animation) ~= "table" or type(animation.mode) ~= "string" then return "off", nil end
  return animation.mode, animation.evidence
end

---Whether this terminal may be driven with animation placements at all.
---
---Gated on the capability mode the same way the overlay is gated on its
---profile flag, and off by default everywhere it has not been watched.
---WezTerm is off for a specific, measured reason rather than caution:
---`assign_image_to_cells` clones a cell that already holds attachments and
---writes it back through a merging `set_cell`, so every repeat placement over
---a covered cell duplicates that cell's attachment list (wezterm/wezterm#7953).
---That is per placement, not per second -- a slower tick does not make it
---safe, only slower, and unlike a held selection extension that lasts seconds
---a preview stays open for as long as the file does.
function M.animation_supported()
  if config.get().render.animate ~= true then return false, "render.animate=false" end
  local ok, reason = placement_precondition()
  if not ok then return false, reason end
  local mode, evidence = animation_mode()
  local _, profile_id = active_profile()
  if mode == "off" then
    return false, evidence or ("profile %s is not validated for animation frame placements"):format(profile_id)
  end
  return true, evidence or ("profile default (%s)"):format(profile_id)
end

---Whether the terminal's own animation player may be driven: `a=f` frame data
---with per-frame gaps, `a=a` playback control, the terminal owning every tick
---thereafter. Requires everything `animation_supported` does, plus a mode
---that says this specific extension was actually qualified -- implementing
---the graphics protocol's placements says nothing about implementing its
---player, which is why "frames" is not promoted to this by reasoning.
function M.animation_native_supported()
  local ok, reason = M.animation_supported()
  if not ok then return false, reason end
  local mode, evidence = animation_mode()
  if mode ~= "native" then
    return false,
      ("animation mode %q swaps frames from the client; the terminal-driven player is unverified here"):format(mode)
  end
  return true, evidence
end

---Upload one frame PNG, or return the id it already has.
---
---`key` is the renderer's stable content key -- a hash of source bytes, drawn
---size and frame index, never a temp path -- so the same frame at the same
---drawn size is uploaded once no matter how many times the loop comes round,
---how many previews show it, or how many renderer restarts have re-written it
---to new paths. This is what makes a tick cost placement bytes only.
function M.animation_upload(key, bytes)
  local existing = animation_images[key]
  if existing then return existing.id end
  local width, height = png_dimensions(bytes)
  if not width then return nil, "frame is not a usable PNG" end
  next_animation_id = next_animation_id + 1
  local id = next_animation_id
  send(chunks(vim.base64.encode(bytes), ("a=t,f=100,t=d,q=2,i=%d"):format(id)))
  animation_images[key] = { id = id, complete = true, width_px = width, height_px = height }
  return id, { width_px = width, height_px = height }
end

---The id already uploaded under `key`, or nil. Lets a caller skip reading
---frame bytes from disk at all for content the terminal already holds --
---the common case for every loop iteration after the first, and for every
---session after the first showing the same content at the same size.
function M.animation_uploaded(key)
  local entry = animation_images[key]
  return entry and entry.id or nil
end

---Begin a terminal-driven animation upload: transmit the root frame, set its
---gap, and start playback in *loading* mode -- the terminal plays whatever
---frames have arrived and waits at the end for more, so a long upload shows
---motion from its first placement rather than after its last byte.
---
---`key` names the whole animation (the renderer derives it from source bytes
---and drawn size). A complete upload under the same key is returned as-is with
---a second return of true -- same content, same terminal-side data, whether
---the asker is a second preview or the same one after a renderer restart. An
---*incomplete* entry under the key (an upload abandoned mid-flight) is freed
---and restarted; appending to it would splice two animations together.
function M.animation_native_begin(key, bytes, gap_ms)
  local entry = animation_images[key]
  if entry and entry.complete and entry.native then return entry.id, true end
  if entry then M.animation_free({ key }) end
  local width, height = png_dimensions(bytes)
  if not width then return nil, "root frame is not a usable PNG" end
  next_animation_id = next_animation_id + 1
  local id = next_animation_id
  local parts = { chunks(vim.base64.encode(bytes), ("a=t,f=100,t=d,q=2,i=%d"):format(id)) }
  -- The root frame is created by the plain transmission above, which carries
  -- no gap of its own; the protocol sets the root's gap through the control
  -- action (a=a, frame r=1) instead.
  local gap = math.floor(tonumber(gap_ms) or 0)
  if gap > 0 then parts[#parts + 1] = command(("a=a,q=2,i=%d,r=1,z=%d"):format(id, gap)) end
  parts[#parts + 1] = command(("a=a,q=2,i=%d,s=2"):format(id))
  send(table.concat(parts))
  animation_images[key] = { id = id, native = true, complete = false, width_px = width, height_px = height }
  return id, false
end

---Transmit one additional frame of a native animation, with its display gap.
---
---One frame is one atomic send(), and must stay one: the protocol associates
---m=1 continuation chunks with the transmission in progress, so interleaving
---*any* other graphics command between one frame's chunks corrupts it. Pacing
---therefore happens at whole-frame granularity -- the caller spreads frames
---across ticks, never bytes of one frame.
function M.animation_native_frame(key, bytes, gap_ms)
  local entry = animation_images[key]
  if not entry or not entry.native then return nil, "no native upload in progress under this key" end
  if entry.complete then return nil, "this animation's upload already finished" end
  if type(bytes) ~= "string" or bytes == "" then return nil, "frame bytes are empty" end
  local gap = math.floor(tonumber(gap_ms) or 0)
  local control = gap > 0 and ("a=f,f=100,t=d,q=2,i=%d,z=%d"):format(entry.id, gap)
    or ("a=f,f=100,t=d,q=2,i=%d"):format(entry.id)
  send(chunks(vim.base64.encode(bytes), control))
  return true
end

---Every frame has arrived: leave loading mode and let the terminal loop.
---
---`loop` is the decoder's repetition count -- "infinite", or the number of
---repeats after the first play. The protocol reads the v key as: v=1 loop
---forever, v=0 ignored, any other value "loop v-1 times". Whether that counts
---plays or repeats is ambiguous in the spec; the mapping errs toward one
---extra play rather than one missing, and the scripts/animation checklist
---pins the terminal's actual behavior.
function M.animation_native_finish(key, loop)
  local entry = animation_images[key]
  if not entry or not entry.native then return nil, "no native upload in progress under this key" end
  local v = 1
  local finite = loop ~= "infinite" and tonumber(loop) or nil
  if finite then v = math.max(2, math.floor(finite) + 2) end
  send(command(("a=a,q=2,i=%d,s=3,v=%d"):format(entry.id, v)))
  entry.complete = true
  return true
end

---Free uploaded animation data by content key: the uppercase delete removes
---any placements *and* releases the stored frames, which is the half a
---placement-only delete leaves resident. Which keys are still wanted is the
---caller's knowledge -- sessions share this cache, so the caller frees
---exactly the keys no live session references, and clear_all remains the
---exit-time backstop for whatever that bookkeeping missed.
function M.animation_free(keys)
  local deletions = {}
  for _, key in ipairs(keys or {}) do
    local entry = animation_images[key]
    if entry then
      deletions[#deletions + 1] = command(("a=d,d=I,q=2,i=%d"):format(entry.id))
      animation_images[key] = nil
    end
  end
  if #deletions > 0 then send(table.concat(deletions)) end
  return #deletions
end

---Compose (but do not send) one animation frame placement.
---
---No `c`/`r` keys, so the frame displays at its natural pixel size. Using them
---would let the terminal scale the frame to fill whole cells, which quantizes
---its *position* to the cell grid -- 7 to 20 pixels of visible misregistration
---against the still frame painted underneath it. That the frame arrives
---pre-sized is what makes this expressible at all.
local function animation_placement_sequence(item, piece, placement, cell_w, cell_h, calibration)
  local col, x_offset = overlay_cell_position(piece.x, cell_w, placement.col, calibration.x)
  local row, y_offset = overlay_cell_position(piece.y, cell_h, placement.row, calibration.y)
  local crop_x = math.floor(piece.x - item.x + 0.5)
  local crop_y = math.floor(piece.y - item.y + 0.5)
  -- `piece.x` and `piece.width` were each rounded to whole pixels on their own,
  -- so a frame whose drawn origin lands exactly halfway between two pixels
  -- rounds its origin up while its width stays put, and the crop then ends one
  -- pixel past the frame it is taken from. Clamp, where the rule everywhere
  -- else in this file is to refuse: nothing about this rectangle is wrong, it
  -- is one rounding step from exact, and the refusal is not local -- it drops
  -- *every* animation in the preview, because animation_apply abandons the
  -- whole diff on the first frame it cannot express. A document froze at one
  -- pane width and played at the next entirely on this half pixel.
  --
  -- Genuinely wrong geometry still refuses below: the clamp floors at zero, so
  -- a piece larger than its own frame keeps failing `crop_within` as before.
  crop_x = math.max(0, math.min(crop_x, math.floor(item.width) - piece.width))
  crop_y = math.max(0, math.min(crop_y, math.floor(item.height) - piece.height))
  local crop_w, crop_h = crop_within(item.width, item.height, crop_x, crop_y, piece.width, piece.height)
  if not crop_w then return nil end
  local offset = ""
  if x_offset ~= 0 or y_offset ~= 0 then offset = (",X=%d,Y=%d"):format(x_offset, y_offset) end
  local pid = new_placement_id()
  local control = ("a=p,q=2,C=1,i=%d,p=%d,x=%d,y=%d,w=%d,h=%d,z=%d%s"):format(
    item.image_id,
    pid,
    crop_x,
    crop_y,
    crop_w,
    crop_h,
    animation_zindex(),
    offset
  )
  return pid, at({ row = row, col = col }, command(control))
end

---Place (or re-place) one preview's animation frames.
---
---`items` are `{ image_id, x, y, width, height }` in the pixels the base image
---is *drawn* at, relative to the placement's top-left corner. `width`/`height`
---are the frame PNG's own dimensions, which the caller must have obtained from
---`animation_upload`, because they are what the crop is validated against.
---
---Returns the set id to pass back next tick, plus counters. A refusal returns
---nil and a reason, and the caller simply leaves the still frame showing --
---which is the whole safety property of drawing animation *over* a painted
---image rather than into a hole cut for it.
function M.animation_apply(set_id, items, placement)
  local cell = cellpixels.measure()
  if not cell_is_placeable(cell) then return nil, "the terminal's pixel cell size is unknown" end

  local cell_w, cell_h = cell.width, cell.height
  local drawn_w = placement.width * cell_w
  local drawn_h = placement.height * cell_h
  local offset_cfg = config.get().image.raw_cell_offset_px or {}
  -- The same calibration the base placement applies. Anything else detaches
  -- the animation from the picture underneath it by exactly the difference.
  local calibration = {
    x = math.max(0, math.floor(tonumber(offset_cfg.x) or 0)),
    y = math.max(0, math.floor(tonumber(offset_cfg.y) or 0)),
  }

  local cuts = {}
  for _, exclusion in ipairs(placement.exclusions or {}) do
    cuts[#cuts + 1] = {
      x = (exclusion.col - placement.col) * cell_w,
      y = (exclusion.row - placement.row) * cell_h,
      width = exclusion.width * cell_w,
      height = exclusion.height * cell_h,
    }
  end

  local set = set_id and animations[set_id] or nil
  if not set then
    next_animation_set = next_animation_set + 1
    set_id = next_animation_set
    set = { placements = {} }
    animations[set_id] = set
  end

  local order, wanted = {}, {}
  for _, item in ipairs(items or {}) do
    local ix, iy = coord(item.x, 0), coord(item.y, 0)
    local iw, ih = coord(item.width, 0), coord(item.height, 0)
    if ix and iy and iw and ih and item.image_id then
      -- Clipping to the placement box is what handles an image scrolled half
      -- off the top or bottom, and it honours `raw_statusline_guard_cells` for
      -- free: preview.placement has already taken the guard out of
      -- `placement.height`.
      local x0, y0 = math.max(0, ix), math.max(0, iy)
      local x1, y1 = math.min(drawn_w, ix + iw), math.min(drawn_h, iy + ih)
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
          -- Keyed by image *and* rectangle: a tick changes the image id while
          -- the rectangle stays put, which is exactly the case that must count
          -- as a new placement rather than an unchanged one.
          local key = ("%d:%d:%d:%d:%d"):format(item.image_id, piece.x, piece.y, piece.width, piece.height)
          if not wanted[key] then
            wanted[key] = { item = item, piece = piece }
            order[#order + 1] = key
          end
        end
      end
    end
  end

  -- `set.placements` is read, never written, until every sequence has been
  -- built: a refusal partway through a diff that had already moved entries out
  -- of it would strand those placements live in the terminal with nothing left
  -- tracking them, and `animation_clear` would never delete them. Same hazard
  -- `overlay_apply` documents above its pre-pass; here the refusal depends on
  -- caller-supplied fractional geometry, so the fix is to keep the diff
  -- read-only rather than to prove the refusal unreachable.
  local additions, fresh = {}, {}
  for _, key in ipairs(order) do
    local existing = set.placements[key]
    if existing then
      fresh[key] = existing
    else
      local entry = wanted[key]
      local pid, sequence =
        animation_placement_sequence(entry.item, entry.piece, placement, cell_w, cell_h, calibration)
      -- A crop that cannot be expressed leaves this frame unplaced rather than
      -- drawing a wrong one. The still image underneath is already correct,
      -- and the set is exactly as it was before this call.
      if not pid then return nil, "an animation frame could not be expressed as a crop" end
      additions[#additions + 1] = sequence
      fresh[key] = { pid = pid, image_id = entry.item.image_id }
    end
  end

  local leftovers = {}
  for key, entry in pairs(set.placements) do
    if not fresh[key] then leftovers[key] = entry end
  end
  local deletions = {}
  for _, leftover in ipairs(ordered_animation_placements(leftovers)) do
    deletions[#deletions + 1] = command(("a=d,d=i,q=2,i=%d,p=%d"):format(leftover.image_id, leftover.pid))
  end

  -- New frame first, then the previous one's deletions, in one write. The
  -- reverse order is what md-render.nvim found necessary on WezTerm, where a
  -- placement is removed as the TUI rewrites the cells under it -- but this
  -- backend's own measured evidence runs the other way on the terminals it
  -- actually drives (see `M.move`: delete-first is a visible blink and a
  -- one-row roll), and WezTerm is gated off for animation entirely. Do not
  -- "fix" this to match theirs without re-running probe check 5.
  local payload = table.concat(additions) .. table.concat(deletions)
  if payload ~= "" then send(payload) end
  set.placements = fresh

  return set_id, { placed = #additions, deleted = #deletions, bytes = #payload, items = #order }
end

---One animation set's placements in a stable order, for the same reason
---`ordered_pids` exists: an unordered `pairs` walk makes the emitted stream
---unassertable.
function ordered_animation_placements(placements)
  local keys = {}
  for key in pairs(placements or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local out = {}
  for _, key in ipairs(keys) do
    out[#out + 1] = placements[key]
  end
  return out
end

---Remove one animation set's placements. The frame images stay uploaded: the
---loop will come round to them again, and re-uploading a frame every time the
---preview is occluded would give back the whole reason this is cheap.
function M.animation_clear(set_id)
  local set = set_id and animations[set_id] or nil
  if not set then return false end
  local deletions = {}
  for _, entry in ipairs(ordered_animation_placements(set.placements)) do
    deletions[#deletions + 1] = command(("a=d,d=i,q=2,i=%d,p=%d"):format(entry.image_id, entry.pid))
  end
  if #deletions > 0 then send(table.concat(deletions)) end
  animations[set_id] = nil
  return true
end

---Remove one selection-highlight set's placements. The tint sheet stays
---uploaded for the next gesture; `M.clear_all` frees it.
function M.overlay_clear(set_id)
  local set = set_id and overlays[set_id] or nil
  if not set then return false end
  local deletions = {}
  for _, pid in ipairs(ordered_pids(set.placements)) do
    deletions[#deletions + 1] = command(("a=d,d=i,q=2,i=%d,p=%d"):format(set.sheet_id, pid))
  end
  if #deletions > 0 then present({ image_id = set.base_image_id, delete = table.concat(deletions) }) end
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
  local width_px, height_px = png_dimensions(image_bytes)
  if not width_px then error("md-viewer: raw Kitty backend received an invalid PNG") end
  local id, sequence = register_item(width_px, height_px, placement)
  present({ image_id = id, uploads = { { id = id, png = image_bytes } }, place = sequence })
  return id
end

---`M.show` for a surface that exists only beside the terminal: `descriptor`
---carries the image's pixel dimensions (viewport CSS x device scale -- the
---same numbers a capture here would have had) for the placement math, and
---`descriptor.ref` is the surface identity the local helper resolves pixels
---from. Everything downstream -- move, hide, occlusion re-placement --
---treats the returned id exactly like a shown frame's, which is what makes
---the reconcile discipline work unchanged in local mode.
function M.show_surface(descriptor, placement)
  local id, sequence = register_item(descriptor.width_px, descriptor.height_px, placement)
  present({
    image_id = id,
    doc = descriptor.ref and descriptor.ref.doc or nil,
    uploads = { { id = id, ref = descriptor.ref } },
    place = sequence,
  })
  return id
end

---Replace the image on screen, in **one** `nvim_ui_send` write.
---
---The write boundary is the point of this function. `M.move`, `overlay_apply`
---and `animation_apply` all pack their additions and deletions into a single
---write for the same documented reason, and this path -- the one that runs on
---every captured frame, so every frame of a selection gesture -- was the one
---that did not:
---it sent the upload, the placements and the superseded image's deletion as
---three separate writes. The terminal is free to composite between them, and
---the state it composites in the middle has the old image already deleted and
---the new one not yet placed. That is a blank preview, once per frame.
---
---Which side the deletion goes on is still the double-buffer policy's call:
---create-then-delete never has a moment with nothing on screen, and is the
---default everywhere a profile does not say otherwise.
function M.update(image_id, image_bytes, placement)
  local double_buffer = resolve_double_buffer()
  local removal = ""
  if image_id and owned[image_id] then
    removal = deletion_command(image_id)
    owned[image_id] = nil
  end
  local width_px, height_px = png_dimensions(image_bytes)
  if not width_px then error("md-viewer: raw Kitty backend received an invalid PNG") end
  local new_id, sequence = register_item(width_px, height_px, placement)
  present({
    image_id = new_id,
    uploads = { { id = new_id, png = image_bytes } },
    place = sequence,
    delete = removal,
    delete_first = not double_buffer,
  })
  return new_id
end

---`M.update` for a locally rendered surface; same double-buffer discipline,
---same single write, pixels by reference.
function M.update_surface(image_id, descriptor, placement)
  local double_buffer = resolve_double_buffer()
  local removal = ""
  if image_id and owned[image_id] then
    removal = deletion_command(image_id)
    owned[image_id] = nil
  end
  local new_id, sequence = register_item(descriptor.width_px, descriptor.height_px, placement)
  present({
    image_id = new_id,
    doc = descriptor.ref and descriptor.ref.doc or nil,
    uploads = { { id = new_id, ref = descriptor.ref } },
    place = sequence,
    delete = removal,
    delete_first = not double_buffer,
  })
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
  present({ image_id = image_id, place = sequence, delete = removal })
  item.placement_ids = ids
  item.placement = vim.deepcopy(placement)
  return image_id
end

-- ---------------------------------------------------------------------------
-- Resident chunks: the document held in terminal memory, panned by re-cropping.
--
-- An ordinary frame is one image covering the pane. A resident screen is one or
-- two *bands*, each a crop of a different chunk image, stacked to fill the pane.
-- Scrolling re-emits the crops and sends no pixels at all.
-- ---------------------------------------------------------------------------

---Place one band: rows [part.row, part.row + part.rows) of the pane, drawn from
---image rows [part.src_y, part.src_y + part.src_h) of `item`.
---
---Splits on the same visible regions an ordinary frame does, so a passive float
---punches out of a band exactly as it punches out of a full frame.
local function band_sequences(item, placement, part)
  local sequences, ids = {}, {}
  local offset = cell_offset()
  local rows = math.max(1, math.floor(part.rows or 0))
  local per_row = (part.src_h or 0) / rows
  local band_top = math.floor(part.row or 0)
  for _, region in ipairs(visible_regions(placement)) do
    local top = math.max(region.y, band_top)
    local bottom = math.min(region.y + region.height, band_top + rows)
    if bottom > top then
      local x1 = math.floor(region.x * item.width_px / placement.width)
      local x2 = math.floor((region.x + region.width) * item.width_px / placement.width)
      local y1 = math.floor(part.src_y + (top - band_top) * per_row)
      local y2 = math.floor(part.src_y + (bottom - band_top) * per_row)
      local crop_w, crop_h =
        crop_within(item.width_px, item.height_px, x1, y1, math.max(1, x2 - x1), math.max(1, y2 - y1))
      if crop_w and region.width >= 1 then
        local pid = new_placement_id()
        local control = ("a=p,q=2,C=1,i=%d,p=%d,x=%d,y=%d,w=%d,h=%d,c=%d,r=%d,z=%d%s"):format(
          item.id,
          pid,
          x1,
          y1,
          crop_w,
          crop_h,
          region.width,
          bottom - top,
          zindex(),
          offset
        )
        sequences[#sequences + 1] = at({ row = placement.row + top, col = placement.col + region.x }, command(control))
        ids[#ids + 1] = pid
      end
    end
  end
  return table.concat(sequences), ids
end

---Upload an image and keep it resident without placing it.
---
---Owned exactly like any other image, so `M.compose`, `M.hide`, `M.retire` and
---`M.clear_all` all work on it unchanged; it simply starts with no placements.
function M.upload(image_bytes)
  next_id = next_id + 1
  local id = next_id
  local width_px, height_px = png_dimensions(image_bytes)
  if not width_px then return nil, "md-viewer: raw Kitty backend received an invalid PNG" end
  owned[id] = { id = id, width_px = width_px, height_px = height_px, placement_ids = {} }
  send(chunks(vim.base64.encode(image_bytes), ("a=t,f=100,t=d,q=2,i=%d"):format(id)))
  return id
end

---Draw a screen from one or two resident chunks, in a single write.
---
---New placements go out ahead of the deletions they supersede, for the reason
---`M.move` does it: deleting first leaves the terminal with nothing to
---composite until the replacement lands, and that gap is visible.
---
---`retired` is a list rather than one id because every chunk shares a z layer
---and Kitty breaks a z tie by image id. A band left placed from the previous
---screen would draw *over* the live one whenever its id happens to be higher.
function M.compose(parts, placement)
  if not parts or #parts == 0 then return nil, "compose needs at least one part" end
  local sequences, drawn = {}, {}
  for _, part in ipairs(parts) do
    local item = owned[part.image_id]
    if not item then return nil, "compose was given an image that is not resident" end
    local sequence, ids = band_sequences(item, placement, part)
    if sequence == "" then return nil, "a band produced no placeable region" end
    sequences[#sequences + 1] = sequence
    drawn[#drawn + 1] = { item = item, ids = ids }
  end

  -- Every chunk the previous screen placed, not merely the ones this screen
  -- replaces. A chunk scrolled off entirely still holds placements otherwise,
  -- and a stale band drawing over a live one is undetectable from this side.
  local removals = {}
  for image_id in pairs(composed) do
    local item = owned[image_id]
    for _, pid in ipairs(item and item.placement_ids or {}) do
      removals[#removals + 1] = command(("a=d,d=i,q=2,i=%d,p=%d"):format(image_id, pid))
    end
    if item then item.placement_ids = {} end
  end
  send(table.concat(sequences) .. table.concat(removals))

  composed = {}
  for _, entry in ipairs(drawn) do
    entry.item.placement_ids = entry.ids
    entry.item.placement = vim.deepcopy(placement)
    composed[entry.item.id] = true
  end
  return true
end

---Take the composed screen down without freeing anything, in one write.
---
---`M.hide` is this for a single chunk; this is the whole screen, and it exists
---because the caller cannot know which chunks are placed -- `composed` does, and
---it is the only thing that does. An occlusion has to reach the bands somehow:
---`clear_image` only ever knew about `session.image_id`, which a resident
---session does not have, so a float over the preview used to leave the bands
---compositing underneath it.
---
---Only placements go. The pixels stay in terminal memory, so restoring an
---occluded resident pane costs a re-crop -- a few hundred bytes -- rather than
---re-uploading the document.
---
---`composed` is module-global rather than per session, so two resident previews
---open at once would take each other's screens down. That is pre-existing --
---`M.compose` already retires every tracked placement whoever owns it -- and
---stands as a known one-preview-at-a-time limitation rather than fixed here.
function M.uncompose()
  local removals = {}
  for image_id in pairs(composed) do
    local item = owned[image_id]
    for _, pid in ipairs(item and item.placement_ids or {}) do
      removals[#removals + 1] = command(("a=d,d=i,q=2,i=%d,p=%d"):format(image_id, pid))
    end
    if item then item.placement_ids = {} end
  end
  composed = {}
  if #removals > 0 then send(table.concat(removals)) end
  return #removals
end

---Drop an image's placements but keep its pixels resident, so it can be placed
---again without re-uploading. This is what a chunk scrolled off screen gets;
---`M.retire` is what a chunk over the memory budget gets.
function M.hide(image_id)
  local item = owned[image_id]
  if not item then return false end
  local removal = deletion_sequences(item.id, item.placement_ids or {})
  present({ image_id = image_id, delete = removal, kill = true })
  item.placement_ids = {}
  composed[image_id] = nil
  return true
end

---Free the pixels of several images in one write.
function M.retire(image_ids)
  local sequences, freed = {}, 0
  local first_id
  for _, id in ipairs(image_ids or {}) do
    if owned[id] then
      first_id = first_id or id
      sequences[#sequences + 1] = deletion_command(id)
      owned[id] = nil
      composed[id] = nil
      freed = freed + 1
    end
  end
  if #sequences > 0 then present({ image_id = first_id, delete = table.concat(sequences), kill = true }) end
  return freed
end

---Whether this terminal can pan resident chunks by re-cropping placements.
function M.resident_pan_supported()
  local ok, reason = M.detect()
  if not ok then return false, reason end
  local capability = M.capability()
  if capability and capability.resident_pan == false then
    return false,
      (capability.label or capability.profile_id or "this terminal")
        .. " does not hold repeated cropped placements affordably"
  end
  return true
end

function M.clear(image_id)
  if not owned[image_id] then return false end
  present({ image_id = image_id, delete = deletion_command(image_id), kill = true })
  owned[image_id] = nil
  composed[image_id] = nil
  return true
end

function M.clear_all()
  for id in pairs(owned) do
    M.clear(id)
  end
  composed = {}
  for set_id in pairs(overlays) do
    M.overlay_clear(set_id)
  end
  for set_id in pairs(animations) do
    M.animation_clear(set_id)
  end
  for key, entry in pairs(animation_images) do
    send(command(("a=d,d=I,q=2,i=%d"):format(entry.id)))
    animation_images[key] = nil
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
  local zindex_value, animation_zindex_value, overlay_zindex_value, zindex_source = resolve_layers()
  local double_buffer_value, double_buffer_source = resolve_double_buffer()
  local offset = config.get().image.raw_cell_offset_px or {}
  local overlay_supported, overlay_reason = M.overlay_supported()
  local animation_supported, animation_reason = M.animation_supported()
  local animation_native, animation_native_reason = M.animation_native_supported()
  local animation_current_mode = (animation_mode())
  local animation_sets, animation_placements = 0, 0
  for _, set in pairs(animations) do
    animation_sets = animation_sets + 1
    for _ in pairs(set.placements) do
      animation_placements = animation_placements + 1
    end
  end
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
    -- What a pixel is worth on screen. Overlay rectangles are sized in these,
    -- so "unmeasured" here is exactly why the overlay is off.
    cell_pixels = cellpixels.describe(),
    -- Reported beside `zindex` rather than alone: the whole stack is the
    -- diagnostic. Two equal numbers anywhere in it mean something is ordered by
    -- image id instead of by layer, which is how the Ghostty defect presented
    -- (see `resolve_layers`).
    animation_supported = animation_supported,
    animation_reason = animation_reason,
    -- The resolved mode plus whether the native gate opens, so health can say
    -- which strategy a session will pick before one exists to ask.
    animation_mode = animation_current_mode,
    animation_native_supported = animation_native,
    animation_native_reason = animation_native_reason,
    animation_zindex = animation_zindex_value,
    animation_images = vim.tbl_count(animation_images),
    animation_sets = animation_sets,
    animation_placements = animation_placements,
    overlay_zindex = overlay_zindex_value,
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

-- Exported for `tests/lua/cases/backend_kitty.lua` only.
--
-- Nothing this backend computes can currently violate either precondition --
-- that is what they are for, and it is also why a test driven through the
-- public API alone cannot tell whether they do anything at all. Mutating each
-- guard to a no-op and re-running the suite is what surfaced that; asserting
-- them directly is what fixed it.
M._preconditions = { cell_is_placeable = cell_is_placeable, crop_within = crop_within }

-- Exported for `scripts/local/dump-upload-golden.lua` only: the upload
-- chunker is the one escape builder the local-render helper reimplements in
-- JS, and the dump is what pins the two implementations to the same bytes.
M._upload_sequence = upload_sequence

-- Exported for `backends/kitty_marker`'s mode-race fallback only: when a
-- transaction cannot be expressed as a marker (bytes arrived after a
-- demotion switch), it is presented directly rather than dropped.
M._direct_present = direct_present

return M
