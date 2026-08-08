-- Stage-6 churn measurement: prompt check 4. Runs under nvim inside a real
-- terminal and drives the production overlay path at drag rates, so the number
-- that comes out is the terminal's cost, not the renderer's.
--
-- WezTerm pays for placements differently from iTerm2 and Ghostty. Each
-- placement rewrites every cell it covers and bumps the line's sequence
-- number, and each deletion walks those rows again across the full line width
-- (`assign_image_to_cells` and `kitty_remove_placement_from_model` in
-- term/src/terminalstate). An overlay frame is O(rows x cols) cell mutations
-- twice over, against one GPU placement elsewhere. Whether that is affordable
-- is a question for a stopwatch.
--
-- Two workloads, because they bracket what a real drag does:
--
--   * "diff"  -- 70 rectangles, two of which move each frame. This is what
--     dragging actually looks like: the selection grows at one end, so
--     `overlay_apply`'s rect-set diffing leaves almost everything untouched.
--   * "churn" -- 70 rectangles, all of which move each frame. The diff never
--     hits. This is the worst case the encoding can produce and is not a shape
--     any gesture makes, but it is the one that would fall over first.
--
-- There is deliberately no full-frame-capture baseline here any more. An
-- earlier version re-uploaded a viewport-sized PNG at 40fps for 30 seconds to
-- get a comparison number, and WezTerm grew to 15 GB and took the machine's
-- memory with it -- it caches decoded image data per image id (~5.9 MB a
-- frame) against a 320 MB prune budget that could not keep up, and a previous
-- run of the same thing died on "Failed to allocate 23962752 quads" and an
-- unwrap in draw.rs. md-viewer never generates that: the capture path
-- re-renders when a gesture settles, not forty times a second. Measuring a
-- workload the product cannot produce is not worth a machine.

local repo = assert(vim.env.MD_VIEWER_REPO, "MD_VIEWER_REPO is required")
local out = assert(vim.env.MD_VIEWER_STAGE6_OUT, "MD_VIEWER_STAGE6_OUT is required")
local seconds = tonumber(vim.env.MD_VIEWER_STAGE6_SECONDS or "30")

vim.opt.runtimepath:append(repo)
local raw = require("md-viewer.backends.kitty_raw")
local cellpixels = require("md-viewer.cellpixels")

require("md-viewer.config").setup({
  terminal = { profile = vim.env.MD_VIEWER_STAGE6_PROFILE or "wezterm" },
  interaction = { selection_overlay = "on" },
})

local TINT = { r = 220, g = 220, b = 220, a = 0.3 }
local BASE_RGB = { r = 64, g = 64, b = 64, a = 1 }
local RECTS = tonumber(vim.env.MD_VIEWER_STAGE6_RECTS or "70")

local function die(message)
  vim.fn.writefile({ message }, out .. "/error.txt")
  vim.cmd("qa!")
end

local function png(width, height, colour, path, margin_x, margin_y)
  local result = vim
    .system({
      "node",
      repo .. "/scripts/stage6-wezterm/make-png.mjs",
      tostring(width),
      tostring(height),
      tostring(colour.r),
      tostring(colour.g),
      tostring(colour.b),
      tostring(colour.a),
      path,
      tostring(margin_x or 0),
      tostring(margin_y or 0),
    }, { text = true })
    :wait()
  if result.code ~= 0 then die("make-png failed: " .. tostring(result.stderr)) end
  local handle = assert(io.open(path, "rb"), "cannot read " .. path)
  local bytes = handle:read("*a")
  handle:close()
  return bytes
end

vim.o.laststatus = 0
vim.o.showcmd = false
vim.o.ruler = false
vim.opt.fillchars = { eob = " " }

-- Same settle wait as the geometry probe: the pty's pixel size is corrected a
-- couple of seconds after launch.
local cell, previous
local deadline = vim.uv.now() + 15000
while vim.uv.now() < deadline do
  cell = cellpixels.measure()
  if cell and previous and previous.width == cell.width and previous.height == cell.height then break end
  previous = cell and { width = cell.width, height = cell.height } or nil
  vim.wait(1000, function() return false end, 100)
end
if not cell then die("cellpixels.measure() failed") end

local cw, ch = math.floor(cell.width), math.floor(cell.height)
local cols, rows = vim.o.columns, vim.o.lines
local base_cols, base_rows = cols - 2, rows - 3
local base_w, base_h = base_cols * cw, base_rows * ch
local placement = { row = 1, col = 1, width = base_cols, height = base_rows }
local margin = raw.overlay_margin()
local margin_x, margin_y = margin and margin.x or 0, margin and margin.y or 0

local base_png = png(base_w, base_h, BASE_RGB, out .. "/churn-base.png")
local sheet_png = png(base_w + margin_x, base_h + margin_y, TINT, out .. "/churn-sheet.png", margin_x, margin_y)

---A selection-shaped rect set: one bar per line, ragged widths, offset by
---`phase` pixels so the geometry is never cell-aligned.
local function rect_set(phase, moving)
  local rects = {}
  -- Sized so all RECTS bars fit inside the base image. The first version
  -- spaced them 1.4 cells apart and two thirds of them fell outside it and
  -- were correctly skipped, which meant the "2 of 70 move" workload moved two
  -- rectangles that were not being drawn and measured nothing.
  local line_height = math.max(4, math.floor(base_h / RECTS))
  for index = 0, RECTS - 1 do
    local shift = (index >= RECTS - moving) and (phase % 7) or 0
    rects[#rects + 1] = {
      x = 3 + shift,
      y = index * line_height,
      width = math.max(8, base_w - 40 - (index % 11) * 17 - shift),
      height = math.max(2, line_height - 2),
    }
  end
  return rects
end

local base_id
local trace = {}
---Resident size of the terminal process, in KB, via its parent chain.
local function terminal_rss()
  local result = vim.system({ "sh", "-c", "ps -o rss= -p $(ps -o ppid= -p $(ps -o ppid= -p $$ | tr -d ' ') | tr -d ' ')" }, { text = true }):wait()
  return (result.stdout or "?"):gsub("%s", "")
end
local samples = {}
local function run_workload(label, moving)
  local set_id = nil
  local frames, bytes, placed, kept, deleted = 0, 0, 0, 0, 0
  local worst_ms, total_ms = 0, 0
  local started = vim.uv.hrtime()
  local until_ns = started + seconds * 1e9
  local phase = 0
  while vim.uv.hrtime() < until_ns do
    phase = phase + 1
    local frame_started = vim.uv.hrtime()
    local id, stats = raw.overlay_apply(
      set_id,
      base_id,
      rect_set(phase, moving),
      { widthPx = base_w, heightPx = base_h },
      TINT,
      sheet_png,
      placement
    )
    if not id then die(("%s: overlay_apply refused: %s"):format(label, tostring(stats))) end
    set_id = id
    local ms = (vim.uv.hrtime() - frame_started) / 1e6
    total_ms = total_ms + ms
    if ms > worst_ms then worst_ms = ms end
    frames = frames + 1
    bytes = bytes + (stats.bytes or 0)
    placed = placed + (stats.placed or 0)
    kept = kept + (stats.kept or 0)
    deleted = deleted + (stats.deleted or 0)
    -- md-viewer's own live-placement count, once a second. If this stays flat
    -- while the terminal's memory does not, the leak is on the terminal's side
    -- of the deletion.
    if phase % 40 == 0 then
      local h = raw.health()
      trace[#trace + 1] = ("%s frame=%d live_placements=%d sets=%d sheets=%d rss_kb=%s"):format(
        label:sub(1, 6), phase, h.overlay_placements, h.overlay_sets, h.overlay_sheets, terminal_rss()
      )
      vim.fn.writefile(trace, out .. "/trace.txt")
    end
    -- ~40fps, the rate stage 2 established for a drag.
    vim.wait(25, function() return false end, 5)
  end
  raw.overlay_clear(set_id)
  samples[#samples + 1] = {
    workload = label,
    frames = frames,
    seconds = (vim.uv.hrtime() - started) / 1e9,
    bytes_total = bytes,
    bytes_per_frame = frames > 0 and bytes / frames or 0,
    placements_per_frame = frames > 0 and placed / frames or 0,
    kept_per_frame = frames > 0 and kept / frames or 0,
    deletions_per_frame = frames > 0 and deleted / frames or 0,
    ms_mean = frames > 0 and total_ms / frames or 0,
    ms_worst = worst_ms,
  }
end

base_id = raw.show(base_png, placement)
vim.fn.writefile({ "ready" }, out .. "/churn.ready")
vim.wait(1500, function() return false end, 100)

local only = vim.env.MD_VIEWER_STAGE6_WORKLOAD
if only ~= "churn" then run_workload("diff (2 of 70 rects move -- what a drag does)", 2) end
if only ~= "diff" then run_workload("churn (70 of 70 rects move -- worst case)", RECTS) end


vim.fn.writefile({
  vim.json.encode({
    build = vim.env.MD_VIEWER_STAGE6_BUILD,
    profile = vim.env.MD_VIEWER_STAGE6_PROFILE or "wezterm",
    encoding = margin and "sheet-margin" or "sub-cell-offset",
    grid = { cols = cols, rows = rows },
    cell = { width = cw, height = ch },
    base_png_bytes = #base_png,
    rects = RECTS,
    samples = samples,
  }),
}, out .. "/churn.json")

raw.clear_all()
vim.cmd("qa!")
