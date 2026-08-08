-- Server half of the stage-4 live drive (scripts/stage4-live/drive.lua runs
-- it). A REAL Neovim instance with the REAL plugin, REAL renderer subprocess
-- and REAL Chromium; the only fake is the terminal itself -- headless Neovim
-- has no TUI, so kitty graphics detection is forced on and nvim_ui_send is
-- replaced with a byte-counting sink. Every escape sequence the kitty_raw
-- backend would send to a real iTerm2 is built by the real code and counted
-- here. Untracked throwaway; do not commit.
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
