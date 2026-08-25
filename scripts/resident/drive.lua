-- Does a resident preview actually work end to end?
--
--   nvim --headless -u NONE -i NONE -l scripts/resident/drive.lua [document.md]
--
-- Spawns a second Neovim over RPC with a faked Kitty-capable terminal, opens a
-- preview, waits for the document to become resident, then scrolls it and counts
-- what reached the terminal. The claim under test is the whole feature:
--
--     after warm-up, a scroll costs no renderer request and no image bytes.
--
-- Needs Node and a Chrome/Chromium on this host. No display and no graphics
-- terminal: the child records the byte stream instead of drawing it. Exits
-- non-zero on any failed assertion.

local script = debug.getinfo(1, "S").source:sub(2)
local repo = vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h:h")

local document = vim.v.argv[#vim.v.argv]
if not document:match("%.md$") then document = repo .. "/README.md" end

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
    local repo, document = ...
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
    process.request = function(method, params, callback)
      _G.REQUESTS = _G.REQUESTS + 1
      return real_request(method, params, callback)
    end

    require("md-viewer").setup({ image = { backend = "kitty_raw", resident = "auto" } })
    vim.cmd("edit " .. vim.fn.fnameescape(document))
    require("md-viewer.controller").toggle()
  ]],
    repo,
    document
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

  local function wait(predicate, timeout_ms, label)
    local waited = 0
    while waited < timeout_ms do
      if predicate() then return true end
      vim.wait(250)
      waited = waited + 250
    end
    print("    timed out waiting for " .. label)
    return false
  end

  local path = wait(function() return session_field("session.render_path") ~= nil end, 20000, "a session")
    and session_field("session.render_path")
  check("the session chose a rendering path", path ~= nil, tostring(path))
  check("and it chose the resident path", path == "resident", session_field("session.render_path_reason"))

  local became_resident = wait(function()
    local total = session_field("session.resident and session.resident.plan and session.resident.plan.count")
    local captured = session_field("session.resident and session.resident.captured")
    return total ~= nil and captured ~= nil and captured >= total
  end, 240000, "the document to become resident")

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
  check(
    "the only non-chunk upload is the bootstrap frame",
    uploads - chunk_uploads <= 2,
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
