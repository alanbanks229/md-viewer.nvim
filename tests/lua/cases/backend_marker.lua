-- The marker presenter: the same kitty_raw transactions, serialized as
-- authenticated APCs instead of terminal escapes. What these cases pin is
-- the local-mode byte contract -- one marker per operation, the literal
-- placement/deletion bytes riding inside it, surface references where
-- pixels would be, and *zero* upload bytes in anything nvim_ui_send writes.
-- The direct path's own bytes are pinned by backend_kitty.lua, which must
-- keep passing untouched; this file is its marker-mode sibling.

return function(t)
  local config = require("md-viewer.config")
  local raw = require("md-viewer.backends.kitty_raw")
  local marker = require("md-viewer.backends.kitty_marker")
  local localrender = require("md-viewer.localrender")
  local cellpixels = require("md-viewer.cellpixels")

  config.setup({ terminal = { profile = "kitty" } })

  local real_measure = cellpixels.measure
  cellpixels.measure = function() return { width = 10, height = 10, cols = 10, rows = 10 } end

  local real_ui_send = vim.api.nvim_ui_send
  local writes
  vim.api.nvim_ui_send = function(value) writes[#writes + 1] = value end
  local function reset_writes() writes = {} end

  local TOKEN = ("cd"):rep(16)
  local real_token, real_next_seq = localrender.token, localrender.next_seq
  local seq = 0
  localrender.token = function() return TOKEN end
  localrender.next_seq = function()
    seq = seq + 1
    return seq
  end

  marker.reset()
  raw.set_presenter(marker.present)

  -- Parse one marker write into its fields; the grammar is deterministic
  -- concatenation, so string splitting is the whole parser.
  local function parse(write)
    t.ok(write:sub(1, 3) == "\27_M" and write:sub(-2) == "\27\\", "a marker is one APC")
    local payload = write:sub(4, -3)
    local fields = { uploads = {} }
    for chunk in payload:gmatch("[^;]+") do
      local key, value = chunk:match("^(%w+)=(.*)$")
      if key == "u" then
        fields.uploads[#fields.uploads + 1] = value
      elseif key then
        fields[key] = value
      end
    end
    fields.place = vim.base64.decode(fields.p or "")
    fields.delete = vim.base64.decode(fields.x or "")
    return fields
  end

  local placement = { row = 0, col = 0, width = 10, height = 10 }
  local function frame_ref(doc, rev, scroll_y, epoch)
    return {
      width_px = 100,
      height_px = 100,
      ref = {
        doc = doc,
        rev = rev,
        scrollY = scroll_y or 0,
        epoch = epoch or 0,
        widthPx = 100,
        heightPx = 100,
        scale = 1,
      },
    }
  end

  -- A surface frame: one write, one marker, upload by reference, the literal
  -- placement escape in p=, nothing in x=.
  reset_writes()
  local image_id = raw.show_surface(frame_ref("buffer-3", "9:0"), placement)
  t.eq(1, #writes, "show_surface is one write")
  local shown = parse(writes[1])
  t.eq("1", shown.v, "marker version")
  t.eq(TOKEN, shown.t, "the session token rides every marker")
  t.eq("1", shown.s, "first frame takes seq 1; 0 is the pairing probe's")
  t.eq("buffer-3", shown.d, "the transaction names its document")
  t.eq(nil, shown.k, "a frame is not a kill")
  t.eq(1, #shown.uploads, "one upload reference")
  t.ok(
    shown.uploads[1]:match("^f,i=%d+,r=9:0,y=0,e=0,w=100,h=100,c=1$"),
    "the reference is the surface identity: " .. shown.uploads[1]
  )
  t.ok(
    shown.place:match("^\27%[s\27%[1;1H\27_Ga=p,q=2,C=1,i=%d+,p=%d+,x=0,y=0,w=100,h=100,c=10,r=10,z=%-3;\27\\\27%[u$"),
    "p= carries the exact placement escape the direct path would have sent"
  )
  t.eq("", shown.delete, "nothing to delete on a first show")
  t.eq(nil, writes[1]:find("a=t", 1, true), "no upload command in the terminal stream")
  t.eq(nil, writes[1]:find("iVBOR", 1, true), "no PNG base64 in the terminal stream")

  -- A re-place (occlusion reconcile): placement-only marker, document
  -- inherited through the image id, old placements deleted.
  reset_writes()
  raw.move(
    image_id,
    { row = 0, col = 0, width = 10, height = 10, exclusions = { { row = 2, col = 2, width = 3, height = 2 } } }
  )
  t.eq(1, #writes, "move is one write")
  local moved = parse(writes[1])
  t.eq("2", moved.s, "seq is monotonic")
  t.eq("buffer-3", moved.d, "an operation on a known image inherits its document")
  t.eq(0, #moved.uploads, "a re-place uploads nothing")
  t.ok(moved.place:find("a=p", 1, true), "new placements ride p=")
  t.ok(moved.delete:find("a=d,d=i", 1, true), "superseded placements ride x=")

  -- A frame swap: new reference, d=I of the old image in x=.
  reset_writes()
  local second_id = raw.update_surface(image_id, frame_ref("buffer-3", "9:0", 120), placement)
  local updated = parse(writes[1])
  t.eq(1, #writes, "update_surface is one write")
  t.ok(updated.uploads[1]:match("y=120"), "the new reference carries the new scroll position")
  t.ok(
    updated.delete:find(("a=d,d=I,q=2,i=%d"):format(image_id), 1, true),
    "the superseded frame's pixels are freed in x="
  )
  t.eq(nil, updated.k, "a swap is not a kill")

  -- Content removal: kill flag set, deletions only.
  reset_writes()
  raw.hide(second_id)
  local hidden = parse(writes[1])
  t.eq("1", hidden.k, "hide kills any pending frame for its document")
  t.eq("", hidden.place)
  t.ok(hidden.delete:find("a=d,d=i", 1, true), "hide deletes placements, keeps pixels")

  reset_writes()
  raw.clear(second_id)
  local cleared = parse(writes[1])
  t.eq("1", cleared.k, "clear kills too")
  t.ok(cleared.delete:find("a=d,d=I", 1, true), "clear frees the pixels")

  -- Two documents: each surface names its own, and the id map keeps their
  -- later operations apart.
  reset_writes()
  local a = raw.show_surface(frame_ref("buffer-3", "10:0"), placement)
  local b = raw.show_surface(frame_ref("buffer-7", "4:0"), placement)
  raw.move(b, placement)
  raw.move(a, placement)
  t.eq("buffer-3", parse(writes[1]).d)
  t.eq("buffer-7", parse(writes[2]).d)
  t.eq("buffer-7", parse(writes[3]).d, "b's move names b's document")
  t.eq("buffer-3", parse(writes[4]).d, "a's move names a's document")
  raw.clear(a)
  raw.clear(b)

  -- A selection overlay in marker mode: the caller passes a reference, the
  -- backend completes it (tint as rrggbbaa, required size, margin), and the
  -- sheet upload is its own transaction ahead of the crop placements --
  -- the same write boundary the direct path keeps, with zero PNG bytes.
  reset_writes()
  local overlay_base = raw.show_surface(frame_ref("buffer-9", "2:0"), placement)
  reset_writes()
  local set_id, overlay_err = raw.overlay_apply(
    nil,
    overlay_base,
    { { x = 5, y = 5, width = 20, height = 10 } },
    { widthPx = 100, heightPx = 100 },
    { r = 58, g = 123, b = 213, a = 0.8 },
    { ref = true },
    placement
  )
  t.ok(set_id, "the overlay applied against a surface base: " .. tostring(overlay_err))
  t.eq(2, #writes, "a new sheet is one transaction, the crops another")
  local sheet_marker = parse(writes[1])
  t.eq(1, #sheet_marker.uploads, "the sheet travels as one upload reference")
  t.ok(
    sheet_marker.uploads[1]:match("^s,i=%d+,g=3a7bd5cc,w=%d+,h=%d+,x=0,y=0$"),
    "the reference is tint and geometry, nothing else: " .. sheet_marker.uploads[1]
  )
  t.eq("", sheet_marker.place, "the sheet upload places nothing")
  local crops = parse(writes[2])
  t.eq(0, #crops.uploads, "the crop transaction uploads nothing")
  t.ok(crops.place:find("a=p", 1, true), "crop placements ride p= as literal escapes")
  t.eq(nil, writes[1]:find("iVBOR", 1, true), "no sheet bytes anywhere")
  raw.overlay_clear(set_id)
  raw.clear(overlay_base)
  -- The sheet cache is module state; leaving this case's sheet in it would
  -- hand later cases a warm cache they assert is cold.
  raw.clear_all()

  -- PNG bytes under the marker presenter are a mode race: the frame is
  -- presented directly -- correct pixels, expensive bytes -- and counted,
  -- never silently dropped and never wrapped in a marker.
  reset_writes()
  local png = "\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\0\100\0\0\0\100"
  local raced = raw.show(png, placement)
  t.eq(1, #writes, "the race fallback is still one write")
  t.ok(writes[1]:find("a=t,f=100", 1, true), "the fallback carries the real upload")
  t.eq(nil, writes[1]:find("\27_M", 1, true), "and is not a marker")
  t.eq(1, marker.stats().direct_bytes_fallbacks, "the race is counted for :MdViewerDebug")
  raw.clear(raced)

  local emitted = marker.stats()
  t.ok(emitted.markers >= 9, "every marker was counted")
  t.ok(
    emitted.marker_bytes > 0 and emitted.marker_bytes < emitted.markers * 1024,
    "markers stay small: " .. emitted.marker_bytes
  )

  -- Restoring the default presenter restores the direct bytes.
  raw.set_presenter(nil)
  reset_writes()
  local direct_id = raw.show(png, placement)
  t.ok(writes[1]:find("a=t,f=100", 1, true), "the direct presenter is back")
  raw.clear(direct_id)

  vim.api.nvim_ui_send = real_ui_send
  cellpixels.measure = real_measure
  localrender.token = real_token
  localrender.next_seq = real_next_seq
  marker.reset()
  config.reset()
end
