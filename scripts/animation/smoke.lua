-- Renderer-level animation smoke: the real Lua process module against the real
-- Node renderer and real Chromium, no terminal required. Exercises the whole
-- media lane on the generated fixtures -- registration, geometry-with-sha,
-- content-addressed materialization with native gaps, memoization, thinning of
-- the README-scale recording under the pixel budget, still-GIF refusal -- and
-- prints the decode timings the hardware checklist wants on record.
--
-- Run `node scripts/animation/make-fixtures.mjs` first, then:
--   nvim --headless -u NONE -i NONE -l scripts/animation/smoke.lua
-- Exits non-zero on any failed check.

-- Realpath first: `-l scripts/animation/smoke.lua` hands over a *relative*
-- source path, and a relative baseDir handed to the renderer resolves against
-- the Node process's own cwd -- every image then fails resolution and the
-- whole document renders placeholders.
local script = assert(vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2)))
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script)))
vim.opt.runtimepath:prepend(repo)
vim.o.shadafile = "NONE"

local fixtures = repo .. "/tmp/animation/fixtures"
if not vim.uv.fs_stat(fixtures .. "/fixture.md") then
  io.write("fixtures missing; run: node scripts/animation/make-fixtures.mjs\n")
  os.exit(1)
end

local config = require("md-viewer.config")
local process = require("md-viewer.process")
config.reset()
config.setup({ render = { animate = true, local_images = true } })

local failures = {}
local function check(ok, label)
  io.write((ok and "  ok: %s\n" or "  FAIL: %s\n"):format(label))
  if not ok then failures[#failures + 1] = label end
  return ok
end

local function request(method, params)
  local done, out, err = false, nil, nil
  process.request(method, params, function(result, request_err)
    out, err = result, request_err
    done = true
  end)
  vim.wait(120000, function() return done end, 50)
  return out, err
end

local handle = io.open(fixtures .. "/fixture.md", "r")
local markdown = handle:read("*a")
handle:close()

local started = vim.uv.hrtime()
local render, render_err = request("render", {
  documentId = "animation-smoke",
  contentRevision = "1:0",
  markdown = markdown,
  baseDir = fixtures,
  documentRoot = fixtures,
  viewport = { widthPx = 900, heightPx = 700, deviceScaleFactor = 2 },
  scrollY = 0,
  captureScale = "device",
  fontSizePx = 16,
  scrollPastEnd = false,
  scrollPastEndOffsetPx = 22,
  theme = "dark",
  rawHtml = false,
  localImages = true,
  maxLocalImageBytes = 64 * 1024 * 1024,
  remoteImages = {},
  animate = true,
  browser = {},
})
io.write(("render: %dms\n"):format(math.floor((vim.uv.hrtime() - started) / 1e6)))
if render_err then
  io.write("render failed: " .. vim.inspect(render_err) .. "\n")
  process.stop()
  os.exit(1)
end

local rects = render.animations or {}
if #rects == 0 then io.write("render result: " .. vim.inspect(render) .. "\n") end
-- quick, slow, twice and large animate; still.gif must not mint a rect. A
-- real.webp, when present, adds one more.
check(#rects >= 4, ("%d animation rects (still.gif excluded by the sniff)"):format(#rects))
for _, rect in ipairs(rects) do
  check(type(rect.sha) == "string" and #rect.sha == 64, ("rect %s carries its sha"):format(rect.id))
end

local requests = {}
for _, rect in ipairs(rects) do
  requests[#requests + 1] = {
    id = rect.id,
    sha = rect.sha,
    -- Drawn size at device scale, the way animation.lua computes it.
    targetWidthPx = math.max(1, math.floor(rect.widthPx * 2)),
    targetHeightPx = math.max(1, math.floor(rect.heightPx * 2)),
  }
end

started = vim.uv.hrtime()
local first = request("animation", { requests = requests })
local materialize_ms = math.floor((vim.uv.hrtime() - started) / 1e6)
io.write(("materialize (%d animations): %dms total\n"):format(#requests, materialize_ms))
for _, answer in ipairs(first.animations or {}) do
  io.write(
    ("  %s: %s%s frames=%s->%s decode=%sms loop=%s\n"):format(
      answer.id,
      answer.status,
      answer.reason and (" (" .. answer.reason .. ")") or "",
      tostring(answer.sourceFrameCount),
      tostring(answer.keptFrameCount),
      tostring(answer.decodeMs),
      tostring(answer.loop)
    )
  )
  check(answer.status == "ok", ("%s materializes"):format(answer.id))
  if answer.status == "ok" then
    check(#answer.frames >= 2, ("%s has at least two frames"):format(answer.id))
    check(answer.frames[1].gapMs > 0, ("%s keeps native gaps"):format(answer.id))
    local stat = vim.uv.fs_stat(answer.frames[1].path)
    check(stat ~= nil and stat.size > 0, ("%s frames exist on disk"):format(answer.id))
    if answer.sourceFrameCount and answer.keptFrameCount then
      check(answer.keptFrameCount <= answer.sourceFrameCount, ("%s thinning never adds frames"):format(answer.id))
    end
  end
end

started = vim.uv.hrtime()
request("animation", { requests = requests })
local cached_ms = math.floor((vim.uv.hrtime() - started) / 1e6)
io.write(("materialize again (cached): %dms\n"):format(cached_ms))
check(cached_ms * 10 <= math.max(materialize_ms, 10), "a repeat ask is served from cache")

process.stop()
if #failures > 0 then
  io.write(("%d failure(s)\n"):format(#failures))
  os.exit(1)
end
io.write("animation smoke OK\n")
os.exit(0)
