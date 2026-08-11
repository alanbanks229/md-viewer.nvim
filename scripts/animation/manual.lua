-- Init file for the in-terminal half of the animation checklist. Run INSIDE
-- the terminal being qualified:
--
--   node scripts/animation/make-fixtures.mjs           # once
--   nvim -u scripts/animation/manual.lua tmp/animation/fixtures/fixture.md
--
-- then :MdViewerToggle, and work through the checklist in scripts/README.md.
-- To qualify terminal-driven playback, edit the setup below to
-- `terminal = { animation = "native" }` and run the same list again.

local script = assert(vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2)))
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script)))
vim.opt.runtimepath:prepend(repo)
vim.o.shadafile = "NONE"

require("md-viewer").setup({
  image = { backend = "kitty_raw" },
  render = {
    animate = true,
    local_images = true,
    -- Matches smoke.lua's own limit. `large.gif` is a ~22MB README-scale
    -- recording and the default ceiling is 10MB, so without this it is dropped
    -- before it can be registered -- checklist item 6 then has nothing to watch
    -- and silently passes for the wrong reason.
    max_local_image_bytes = 64 * 1024 * 1024,
  },
  -- terminal = { animation = "native" },  -- uncomment to qualify native playback
})
