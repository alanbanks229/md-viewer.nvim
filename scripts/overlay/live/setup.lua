-- Server half of the live overlay drive (scripts/overlay/live/drive.lua runs
-- it). A REAL Neovim instance with the REAL plugin, REAL renderer subprocess
-- and REAL Chromium; the only fake is the terminal itself -- headless Neovim
-- has no TUI, so kitty graphics detection is forced on and nvim_ui_send is
-- replaced with a byte-counting sink. Every escape sequence the kitty_raw
-- backend would send to a real terminal is built by the real code and counted
-- here.
--
-- This file reaches into three internal names on purpose --
-- `backends.kitty_raw.detect`, `cellpixels.measure` and `process.request` --
-- so renaming any of them will break this harness silently rather than loudly.
local repo = vim.env.MD_VIEWER_REPO
vim.opt.runtimepath:append(repo)

vim.o.mouse = "a"
vim.o.columns = 190
vim.o.lines = 53
vim.o.laststatus = 2

local sink = { writes = 0, bytes = 0, timeline = {} }
_G.__mdviewer_live = { ui = sink, envelopes = {} }
vim.api.nvim_ui_send = function(data)
  sink.writes = sink.writes + 1
  sink.bytes = sink.bytes + #data
  sink.timeline[#sink.timeline + 1] = #data
end

local kitty = require("md-viewer.backends.kitty_raw")
kitty.detect = function() return true, "faked for the live drive (headless Neovim has no TUI)" end

-- The second consequence of having no TUI: TIOCGWINSZ is refused on a stdout
-- that is not a terminal, so `measure` returns nil and the overlay correctly
-- refuses to size rectangles it cannot size -- which makes the whole overlay
-- path unreachable here.
--
-- Only the ioctl itself is faked, not `measure`: the plausibility bounds, the
-- pixels-per-cell division and `describe`'s formatting all still run for real,
-- so a defect in any of them still fails this drive.
-- tests/lua/cases/cellpixels.lua owns the reader's own behaviour.
-- 10x20 is iTerm2's default cell, matching the profile below.
local cellpixels = require("md-viewer.cellpixels")
cellpixels.read_winsize = function()
  return vim.o.columns, vim.o.lines, vim.o.columns * 10, vim.o.lines * 20
end

require("md-viewer").setup({
  image = { backend = "kitty_raw" },
  terminal = { profile = "iterm2" },
  render = { debounce_ms = 20 },
})

-- Record every renderer envelope, then pass it through to the real renderer.
local process = require("md-viewer.process")
local original_request = process.request
process.request = function(method, params, callback)
  _G.__mdviewer_live.envelopes[#_G.__mdviewer_live.envelopes + 1] = {
    method = method,
    params = vim.deepcopy(params),
  }
  return original_request(method, params, callback)
end
