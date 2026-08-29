-- Does a resident preview actually work end to end?
--
--   nvim --headless -u NONE -i NONE -l scripts/resident/drive.lua [document.md]
--                                                                [--slow-chunks=MS]
--
-- Spawns a second Neovim over RPC with a faked Kitty-capable terminal, opens a
-- preview, waits for the document to become resident, then scrolls it and counts
-- what reached the terminal. The claim under test is the whole feature:
--
--     after warm-up, a scroll costs no renderer request and no image bytes.
--
-- `--slow-chunks=MS` holds every chunk reply back by MS before handing it to the
-- controller. That is the whole of what a slow link does to this feature, and it
-- is what the bootstrap bug needed to be visible: on a fast host the first chunk
-- lands before anything can observe the pane, which is how a blank first paint
-- went unnoticed through several rounds of hand testing. 2000 is a good number -- it is roughly what a chunk costs on
-- an AWS SSM link, and it makes the warm-up long enough to watch.
--
-- Needs Node and a Chrome/Chromium on this host. No display and no graphics
-- terminal: the child records the byte stream instead of drawing it. Exits
-- non-zero on any failed assertion.

local script = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h:h")

local slow_chunks_ms = 0
local document = nil
for _, argument in ipairs(vim.v.argv) do
  local ms = argument:match("^%-%-slow%-chunks=(%d+)$")
  if ms then slow_chunks_ms = tonumber(ms) end
  if argument:match("%.md$") then document = argument end
end
document = document or (repo .. "/README.md")

local checks, failures = 0, {}
local function check(name, passed, detail)
  checks = checks + 1
  local mark = passed and "PASS" or "FAIL"
  print(("  [%s] %s%s"):format(mark, name, detail and (" -- " .. detail) or ""))
  if not passed then failures[#failures + 1] = name end
end

local child = vim.fn.jobstart({ "nvim", "--embed", "--headless", "-u", "NONE", "-i", "NONE" }, { rpc = true })
if child <= 0 then
  print("could not start the child Neovim")
  vim.cmd("cq")
end

local function call(code, ...) return vim.rpcrequest(child, "nvim_exec_lua", code, { ... }) end

local ok, err = pcall(function()
  call(
    [[
    local repo, document, slow_chunks_ms = ...
    vim.opt.runtimepath:prepend(repo)
    -- No real terminal here, so the graphics probe and the cell measurement have
    -- to be stood in for. Everything downstream of them is the real code.
    local terminal = require("md-viewer.terminal")
    local real_detect = terminal.detect
    terminal.detect = function()
      local capability = real_detect()
      capability.graphics = "supported"
      capability.profile_id = "kitty"
      capability.label = "Kitty"
      capability.resident_pan = true
      capability.reason = "forced by scripts/resident/drive.lua"
      return capability
    end
    require("md-viewer.cellpixels").measure = function()
      return { width = 10, height = 20, cols = 200, rows = 50 }
    end
    local raw = require("md-viewer.backends.kitty_raw")
    raw.detect = function() return true, "forced" end
    -- Chunk uploads specifically. The wire counter below also catches the one
    -- bootstrap frame -- the render that measures the document doubles as first
    -- paint -- and conflating the two would hide a chunk being uploaded twice.
    _G.CHUNK_UPLOADS = 0
    local real_upload = raw.upload
    raw.upload = function(bytes)
      _G.CHUNK_UPLOADS = _G.CHUNK_UPLOADS + 1
      return real_upload(bytes)
    end

    -- Record the wire instead of drawing it.
    _G.WIRE = { writes = 0, bytes = 0, uploads = 0, placements = 0, deletions = 0 }
    vim.api.nvim_ui_send = function(value)
      _G.WIRE.writes = _G.WIRE.writes + 1
      _G.WIRE.bytes = _G.WIRE.bytes + #value
      for _ in value:gmatch("a=t,f=100") do _G.WIRE.uploads = _G.WIRE.uploads + 1 end
      for _ in value:gmatch("a=p,") do _G.WIRE.placements = _G.WIRE.placements + 1 end
      for _ in value:gmatch("a=d,") do _G.WIRE.deletions = _G.WIRE.deletions + 1 end
    end
    _G.REQUESTS = 0
    local process = require("md-viewer.process")
    local real_request = process.request
    -- A chunk request is the one that carries a document-absolute region; every
    -- other request is the reader's own content. Delaying only the former is
    -- what makes this a slow *warm-up* rather than a slow renderer.
    local slow = tonumber(slow_chunks_ms) or 0
    process.request = function(method, params, callback)
      _G.REQUESTS = _G.REQUESTS + 1
      if slow > 0 and params and params.captureRegion then
        return real_request(method, params, function(result, err)
          vim.defer_fn(function() callback(result, err) end, slow)
        end)
      end
      return real_request(method, params, callback)
    end

    -- "on", not "auto": "auto" additionally wants a link measured under
    -- image.resident_below_bytes_per_sec, and the whole point of this harness is
    -- to exercise the resident path on a machine that has no such link. The
    -- terminal half is stubbed above; this is the rate half.
    require("md-viewer").setup({ image = { backend = "kitty_raw", resident = "on" } })
    vim.cmd("edit " .. vim.fn.fnameescape(document))
    require("md-viewer.controller").toggle()
  ]],
    repo,
    document,
    slow_chunks_ms
  )

  local function nilify(value)
    if value == vim.NIL then return nil end
    return value
  end

  local function session_field(expression)
    return nilify(call(
      [[
      local expression = ...
      local state = require("md-viewer.state")
      local session = select(2, next(state.all()))
      if not session then return nil end
      return load("local session = ... return " .. expression)(session)
    ]],
      expression
    ))
  end

  local function wait(predicate, timeout_ms, label, on_tick)
    local step = on_tick and 100 or 250
    local waited = 0
    while waited < timeout_ms do
      if predicate() then return true end
      if on_tick then on_tick() end
      vim.wait(step)
      waited = waited + step
    end
    print("    timed out waiting for " .. label)
    return false
  end

  -- The reported bug, as an invariant rather than as a story.
  --
  -- At every moment during warm-up the pane must be one of: occluded, showing
  -- resident bands, showing a frame this session can vouch for, or blank with a
  -- spinner saying why. Nothing else.
  --
  -- The last clause is the one that matters, and "blank" was not it. What the
  -- reader on the slow link actually saw was a pane that was *not* blank -- the
  -- viewport model's restore path had put a cached full-viewport frame back on
  -- it, with no record of what position that frame was a picture of, into a pane
  -- the resident compositor believed it owned. So the test is provenance:
  -- `apply_image` records `frame_revision` for a frame it can account for, and
  -- `show_cached` deliberately nils it. A frame on screen with no revision is a
  -- picture nobody can vouch for, which is the whole fault.
  --
  -- Sampled from the driver because the child records the wire rather than
  -- drawing it, so this needs no graphics terminal.
  local samples, unaccounted = 0, 0
  local function sample_pane()
    samples = samples + 1
    local up = nilify(call([[
      local session = select(2, next(require("md-viewer.state").all()))
      if not session or session.occluded or session.tabpage_hidden or session.ui_suppressed then return true end
      if session.resident_screen == true then return true end
      if session.image_id ~= nil then return session.frame_revision ~= nil end
      return session.loading == true
    ]]))
    if up == false then unaccounted = unaccounted + 1 end
  end

  local path = wait(function() return session_field("session.render_path") ~= nil end, 20000, "a session")
    and session_field("session.render_path")
  check("the session chose a rendering path", path ~= nil, tostring(path))
  check("and it chose the resident path", path == "resident", session_field("session.render_path_reason"))

  local became_resident = wait(function()
    local total = session_field("session.resident and session.resident.plan and session.resident.plan.count")
    local captured = session_field("session.resident and session.resident.captured")
    return total ~= nil and captured ~= nil and captured >= total
  end, 240000, "the document to become resident", sample_pane)

  check(
    "the pane only ever shows a picture this session can account for",
    unaccounted == 0,
    ("%d of %d warm-up samples showed pixels nobody could vouch for"):format(unaccounted, samples)
  )

  local total = session_field("session.resident and session.resident.plan.count")
  local captured = session_field("session.resident and session.resident.captured")
  check(
    "the whole document became resident",
    became_resident,
    ("%s/%s chunks"):format(tostring(captured), tostring(total))
  )

  local chunk_uploads = call([[ return _G.CHUNK_UPLOADS ]])
  check(
    "every chunk was uploaded exactly once",
    chunk_uploads == total,
    ("%d chunk uploads for %s chunks"):format(chunk_uploads, tostring(total))
  )
  local uploads = call([[ return _G.WIRE.uploads ]])
  -- Exactly one, not "at most two". The slack used to cover `show_cached`
  -- re-uploading a full-viewport frame into a pane the resident compositor
  -- owned -- which is the bug, so the slack has to go with it.
  check(
    "the only non-chunk upload is the bootstrap frame",
    uploads - chunk_uploads <= 1,
    ("%d images on the wire, %d of them chunks"):format(uploads, chunk_uploads)
  )

  -- The claim.
  call([[ _G.WIRE = { writes = 0, bytes = 0, uploads = 0, placements = 0, deletions = 0 }; _G.REQUESTS = 0 ]])
  local height = session_field("session.document_height_px") or 0
  local scrolled = 0
  for _ = 1, 40 do
    call([[ require("md-viewer.controller").scroll_by(select(2, next(require("md-viewer.state").all())), 120) ]])
    scrolled = scrolled + 1
    vim.wait(40)
  end
  vim.wait(1500)

  local after = call([[ return { _G.WIRE.writes, _G.WIRE.bytes, _G.WIRE.uploads, _G.WIRE.placements, _G.REQUESTS } ]])
  local writes, bytes, scroll_uploads, placements, requests = after[1], after[2], after[3], after[4], after[5]
  print(
    ("    %d scrolls over a %dpx document: %d writes, %d bytes, %d placements"):format(
      scrolled,
      height,
      writes,
      bytes,
      placements
    )
  )

  check("scrolling sent no renderer request", requests == 0, ("%d requests"):format(requests))
  check(
    "scrolling uploaded no chunk",
    call([[ return _G.CHUNK_UPLOADS ]]) == chunk_uploads,
    "the document was already resident"
  )
  check("scrolling uploaded no image bytes", scroll_uploads == 0, ("%d uploads"):format(scroll_uploads))
  check("scrolling did draw", placements > 0, ("%d placements"):format(placements))
  check(
    "a pan costs hundreds of bytes, not hundreds of kilobytes",
    writes > 0 and (bytes / writes) < 4096,
    ("%d bytes per write"):format(writes > 0 and math.floor(bytes / writes) or 0)
  )

  local drawn = session_field("session.resident and session.resident.drawn")
  check("the preview followed the reader", drawn ~= nil and drawn > 1, "chunk " .. tostring(drawn))
end)

pcall(vim.fn.jobstop, child)

if not ok then
  print("\n  driver error: " .. tostring(err))
  vim.cmd("cq")
end

print(("\n  %d/%d checks passed"):format(checks - #failures, checks))
if #failures > 0 then
  print("  failed: " .. table.concat(failures, ", "))
  vim.cmd("cq")
end
vim.cmd("qa!")
