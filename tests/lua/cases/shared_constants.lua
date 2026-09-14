-- The cross-language constants.
--
-- Five of the eight cross-language drifts the investigation found are the same
-- shape: a number or a string that exists once in `renderer/src` and again in
-- `lua/`, with nothing comparing them. The viewport clamps are a *comment* in
-- `coordinates.lua` citing line numbers in `browser.js`; the region ceilings
-- are two literals written twice; the response codes are string literals
-- compared against string literals across a process boundary. Drift in any of
-- them is silent -- the wrong scale, a refusal nothing recognises, a handshake
-- that half-works.
--
-- `tests/fixtures/shared-constants.json` is emitted from the Node modules that
-- own those values (`scripts/dump-shared-constants.js`), and
-- `tests/node/shared-constants.test.js` fails if it is stale. This file is the
-- other half: what Lua believes, compared against what the renderer said.

return function(t)
  local coordinates = require("md-viewer.coordinates")
  local config = require("md-viewer.config")
  local resident = require("md-viewer.resident")
  local localrender = require("md-viewer.localrender")
  local kitty_marker = require("md-viewer.backends.kitty_marker")

  local state_path = assert(vim.api.nvim_get_runtime_file("lua/md-viewer/state.lua", false)[1])
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(state_path)))
  local fixture_path = vim.fs.joinpath(root, "tests/fixtures/shared-constants.json")
  local shared = vim.json.decode(table.concat(vim.fn.readfile(fixture_path), "\n"), { luanil = { object = true } })

  t.eq("scripts/dump-shared-constants.js", shared.generated_by, "the fixture is the generated one")

  -- -- the viewport the page is laid out at --------------------------------

  -- These numbers become `session.viewport_width_px` and
  -- `viewport_height_render_px`, which are the denominator of every hit test,
  -- overlay scale and animation frame. A Lua bound wider than the browser's
  -- means Lua describes a viewport the page never got.
  t.eq({
    min_width_px = shared.viewport.min_width_px,
    max_width_px = shared.viewport.max_width_px,
    min_height_px = shared.viewport.min_height_px,
    max_height_px = shared.viewport.max_height_px,
  }, coordinates.VIEWPORT_BOUNDS, "coordinates.lua mirrors browser.js's viewport clamps")

  -- The configuration's own ceiling is the same number seen from the user's
  -- side: asking for more than the browser will lay out buys nothing.
  local defaults = config.get()
  t.eq(shared.viewport.max_width_px, defaults.render.max_width_px, "the default render width ceiling is the clamp")
  t.eq(shared.viewport.max_height_px, defaults.render.max_height_px, "and so is the height ceiling")

  -- -- the device scale factor ---------------------------------------------

  t.eq(shared.device_scale_factor.default, defaults.render.device_scale_factor, "the default scale is the shared one")

  -- Lua refuses what the browser would otherwise silently clamp, so the
  -- refusal band and the clamp band have to be the same band.
  local bounds = shared.device_scale_factor
  local function accepts(value)
    local ok = pcall(config.setup, { render = { device_scale_factor = value } })
    config.reset()
    return ok
  end
  t.eq(true, accepts(bounds.min), "the minimum scale is accepted")
  t.eq(true, accepts(bounds.max), "the maximum scale is accepted")
  t.eq(false, accepts(bounds.min - 0.01), "anything below it is refused rather than clamped")
  t.eq(false, accepts(bounds.max + 0.01), "and so is anything above it")

  -- -- the single-capture ceiling ------------------------------------------

  t.eq(shared.region.max_region_pixels, resident.MAX_REGION_PIXELS, "the resident chunker uses the renderer's ceiling")
  t.eq(shared.region.max_region_height_px, resident.MAX_REGION_HEIGHT_PX, "and its height ceiling")

  -- -- the local control socket --------------------------------------------

  -- The one protocol that crosses two independently-updated checkouts, so a
  -- mismatch here is the handshake refusing to pair rather than a bug.
  -- `shared["local"]`, not `shared.local`: the field is named for the local
  -- rendering path and `local` is a Lua keyword.
  local local_render = shared["local"]
  t.eq(local_render.protocol_version, localrender.PROTOCOL, "the plugin speaks the helper's protocol version")
  t.eq(local_render.max_marker_bytes, kitty_marker.MAX_MARKER_BYTES, "and bounds a marker at the same size")

  -- -- the response codes ---------------------------------------------------

  -- Every `REGION_`/`STALE_`/`INTERACT_` literal in `lua/` has to be a code the
  -- renderer can actually emit. The failure this catches is the quiet one: a
  -- renamed code leaves the Lua comparison in place, still compiling, never
  -- true again -- a refusal that stops being recognised, or a staleness check
  -- that stops dropping stale replies.
  local known = {}
  for _, code in ipairs(shared.codes) do
    known[code] = true
  end

  local matched, sites = {}, 0
  for _, file in ipairs(vim.fn.glob(root .. "/lua/md-viewer/**/*.lua", true, true)) do
    local source = table.concat(vim.fn.readfile(file), "\n")
    -- Only code literals, not the prose: the comments in `state.lua` and
    -- `interaction.lua` that explain STALE_INTERACTION are documentation, and
    -- renaming the code should not be gated on rewriting a sentence.
    for code in source:gmatch('"([A-Z_]+)"') do
      if code:match("^REGION_") or code:match("^STALE_") or code:match("^INTERACT_") then
        matched[code] = true
        sites = sites + 1
      end
    end
  end

  t.ok(sites > 0, "the scan found code literals in lua/ at all")
  for code in pairs(matched) do
    t.ok(known[code], ("lua/ compares against %s, which the renderer still emits"):format(code))
  end
end
