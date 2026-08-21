-- What is actually on the terminal's screen, reconstructed from the bytes.
--
--     :runtime scripts/resident/placement-trace.lua     -- start recording
--     ...reproduce...
--     :PlacementTrace                                   -- stop, and report
--
-- Writes `stdpath("cache")/md-viewer/placement-trace.log` and opens a summary
-- in a new tab.
--
-- It has to be run from the terminal that is showing the fault. A pty without
-- pixel dimensions -- which is what `ssh -tt` from a script gives you -- makes
-- `cellpixels` fall back to the estimated tier, and at that geometry the slice
-- grid is different and the resident path may not engage at all. That is why
-- this ships as something a reader runs rather than something CI does.
--
-- ## Why this exists
--
-- Every other instrument in this project reports what md-viewer *believes*.
-- `:MdViewerDebug` prints the session's own bookkeeping, `resident_e2e` asserts
-- the retire list names the right images, and both agreed the screen was correct
-- while a reader was looking at two unrelated halves of a document. That is the
-- gap: between "the right deletion was emitted" and "the pixel came off the
-- screen" there is a terminal, and nothing here had ever looked at it.
--
-- So this decodes the graphics stream itself and keeps the set of placements the
-- terminal has been told to hold: `a=t` creates an image, `a=p` adds a placement
-- to it, `a=d,d=i,p=` removes one, `a=d,d=I` removes an image and all of its
-- placements. What that set contains after each write is, as far as anything
-- here can know, what is on screen.
--
-- ## The one thing it is really looking for
--
-- Every base slice is placed on the same z layer, and the Kitty protocol breaks
-- a z-index tie by image id: "if two images with the same z-index overlap then
-- the image with the lower id is considered to have the lower z-index". A band
-- left behind by a composite therefore does not sit harmlessly underneath the
-- live one -- if its slice was uploaded later, it has the higher id and draws
-- **over** it. The report that prompted this was the top of a document with
-- block 007 spliced across the bottom of the same pane.
--
-- So the fault it names is: **more than one base image holding placements, in
-- rows that overlap**. It also records the destination rows of every placement,
-- so a pane covered twice or not at all is visible rather than inferred.
--
-- Recording costs a string match per write and nothing on the wire.

local M = {}

-- Under `stdpath("cache")` rather than the repo's `tmp/`, unlike the other
-- harnesses here. This one is meant to be run by whoever is *seeing* the fault,
-- and they are running a lazy.nvim install whose directory they should not be
-- writing into -- and may not be able to.
local LOG = vim.fn.stdpath("cache") .. "/md-viewer/placement-trace.log"

local real_send
local writes = 0
-- image id -> { pids = { [pid] = { row, rows, cols, crop } }, created_at = n }
local images = {}
local faults = {}

---One graphics command, as the terminal will read it.
---
---The cursor position that frames a placement arrives as a separate escape
---(`kitty_raw`'s `at`), so the row is carried in from the enclosing write rather
---than parsed out of the APC payload -- which is why this takes it as an
---argument instead of finding it.
local function apply(control, row)
  local id = tonumber(control:match("i=(%d+)") or "")
  if not id then return end
  if control:match("a=t") then
    images[id] = images[id] or { pids = {}, created_at = writes }
  elseif control:match("a=p") then
    local entry = images[id] or { pids = {}, created_at = writes }
    images[id] = entry
    local pid = tonumber(control:match("p=(%d+)") or "")
    if pid then
      entry.pids[pid] = {
        row = row,
        rows = tonumber(control:match("r=(%d+)") or "") or 0,
        cols = tonumber(control:match("c=(%d+)") or "") or 0,
        crop = ("x=%s,y=%s,w=%s,h=%s"):format(
          control:match("x=(%d+)") or "?",
          control:match("y=(%d+)") or "?",
          control:match("w=(%d+)") or "?",
          control:match("h=(%d+)") or "?"
        ),
        z = tonumber(control:match("z=(%-?%d+)") or "") or 0,
      }
    end
  elseif control:match("a=d,d=I") then
    images[id] = nil
  elseif control:match("a=d,d=i") then
    local pid = tonumber(control:match("p=(%d+)") or "")
    if pid and images[id] then images[id].pids[pid] = nil end
  end
end

---Which images are currently holding placements, and on which rows.
---
---Only the base layer is interesting here. The caret and the drag highlight are
---placements too, and they are *supposed* to overlap the base -- that is what an
---overlay is -- so counting them as a collision would report a fault on every
---frame. They are separated by z: `kitty_raw`'s `layers()` puts the base
---lowest, so anything above it is an overlay and not this instrument's business.
local function occupancy()
  local base_z = math.huge
  for _, entry in pairs(images) do
    for _, p in pairs(entry.pids) do
      base_z = math.min(base_z, p.z)
    end
  end
  local owners = {}
  for id, entry in pairs(images) do
    local rows = {}
    for _, p in pairs(entry.pids) do
      if p.z == base_z and p.rows > 0 then rows[#rows + 1] = p end
    end
    if #rows > 0 then owners[#owners + 1] = { id = id, rows = rows } end
  end
  table.sort(owners, function(a, b) return a.id < b.id end)
  return owners, base_z
end

---Do two base images claim any of the same rows?
---
---Not merely "is more than one placed": a composite legitimately places two, in
---disjoint bands, in one write. What is never legitimate is two of them wanting
---the same row, because then which one the reader sees is decided by image id
---and nothing else.
local function collision(owners)
  local claimed = {}
  for _, owner in ipairs(owners) do
    for _, p in ipairs(owner.rows) do
      for row = p.row, p.row + p.rows - 1 do
        local previous = claimed[row]
        if previous and previous ~= owner.id then
          return ("row %d claimed by images %d and %d"):format(row, previous, owner.id)
        end
        claimed[row] = owner.id
      end
    end
  end
  return nil
end

local function log(line)
  vim.fn.mkdir(vim.fn.fnamemodify(LOG, ":h"), "p")
  local handle = io.open(LOG, "a")
  if handle then
    handle:write(line .. "\n")
    handle:close()
  end
end

---Where the reader is, and which slice each placed image actually is.
---
---Added after the first real capture came back clean. That log proved the
---placements were correct *relative to each other* -- every composite put the
---lower slice index on top, every seam was continuous, nothing was left behind
---— and could not answer the question that was actually being asked, which is
---whether the pixels being drawn are the ones the reader's scroll position calls
---for. "Image 460 cropped at y=0" is the top of the document if 460 is slice 0
---and is somewhere else entirely if it is not, and the stream alone cannot say
---which.
local function session_context()
  local ok, state = pcall(require, "md-viewer.state")
  if not ok then return "", {} end
  for _, session in pairs(state.all()) do
    local live = not session.closed and session.resident
    if live then
      local by_image = {}
      local resident = require("md-viewer.resident")
      for _, region in ipairs(resident.slice_records(live)) do
        if region.image_id then by_image[region.image_id] = region end
      end
      return ("scroll %s applied %s"):format(
        tostring(math.floor((session.scroll_y or 0) + 0.5)),
        tostring(math.floor((session.applied_scroll_y or 0) + 0.5))
      ),
        by_image
    end
  end
  return "", {}
end

local function record(value)
  writes = writes + 1
  -- A write may frame several placements, each with its own cursor escape.
  local row = nil
  for chunk in value:gmatch("[^\27]*") do
    local at_row = chunk:match("^%[(%d+);%d+H")
    if at_row then row = tonumber(at_row) end
    local control = chunk:match("^_G([^;]*)")
    if control then apply(control, row) end
  end
  local owners = occupancy()
  local clash = collision(owners)
  local context, by_image = session_context()
  local parts = {}
  for _, owner in ipairs(owners) do
    local spans = {}
    for _, p in ipairs(owner.rows) do
      spans[#spans + 1] = ("rows %d..%d (%s)"):format(p.row, p.row + p.rows - 1, p.crop)
    end
    -- The slice this image *is*, so a crop can be turned back into a document
    -- position. Absent means the image is not a resident slice at all -- an
    -- ordinary captured frame, or one this session has already given up.
    local region = by_image[owner.id]
    local named = region
        and ("image %d [slice %s doc_y %d]"):format(owner.id, tostring(region.index), math.floor(region.doc_y + 0.5))
      or ("image %d [frame]"):format(owner.id)
    parts[#parts + 1] = ("%s: %s"):format(named, table.concat(spans, " + "))
  end
  local line = ("[%05d] %s | %d byte(s) | %s"):format(writes, context, #value, table.concat(parts, " | "))
  if clash then
    faults[#faults + 1] = ("write %d: %s"):format(writes, clash)
    line = line .. "  <<< COLLISION: " .. clash
  end
  log(line)
end

function M.start()
  if real_send then
    vim.notify("md-viewer: placement trace already running", vim.log.levels.WARN)
    return
  end
  vim.fn.mkdir(vim.fn.fnamemodify(LOG, ":h"), "p")
  os.remove(LOG)
  writes, images, faults = 0, {}, {}
  real_send = vim.api.nvim_ui_send
  vim.api.nvim_ui_send = function(value)
    pcall(record, value)
    return real_send(value)
  end
  log("md-viewer placement trace")
  log(("started %s"):format(os.date("!%Y-%m-%dT%H:%M:%SZ")))
  log("")
  vim.notify("md-viewer: placement trace recording. Reproduce, then :PlacementTrace", vim.log.levels.INFO)
end

function M.stop()
  if not real_send then
    vim.notify("md-viewer: placement trace is not running", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_ui_send = real_send
  real_send = nil

  local owners = occupancy()
  local lines = {
    "md-viewer: placement trace",
    "",
    ("  writes recorded      %d"):format(writes),
    ("  base images placed   %d  (a composite is 2; anything else at rest is a fault)"):format(#owners),
    ("  row collisions       %d"):format(#faults),
    "",
    ("  full log: %s"):format(LOG),
    "",
  }
  if #faults > 0 then
    lines[#lines + 1] = "-- Collisions -----------------------------------------------------------"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Two base images claimed the same rows. The reader sees whichever has the"
    lines[#lines + 1] = "higher image id, because the Kitty protocol breaks a z tie that way -- so"
    lines[#lines + 1] = "a band that should have come down draws over the one that should be there."
    lines[#lines + 1] = ""
    for index = math.max(1, #faults - 20), #faults do
      lines[#lines + 1] = "  " .. faults[index]
    end
  else
    lines[#lines + 1] = "No two base images ever claimed the same row."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "If the preview still showed two unrelated halves of the document, then the"
    lines[#lines + 1] = "deletions were emitted and the terminal did not act on them -- which is a"
    lines[#lines + 1] = "terminal capability question, not a bookkeeping one. The log has the exact"
    lines[#lines + 1] = "sequence to replay by hand."
  end
  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, "md-viewer://placement-trace")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

vim.api.nvim_create_user_command("PlacementTrace", function() M.stop() end, {})
M.start()

return M
