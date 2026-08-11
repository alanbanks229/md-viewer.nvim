return function(t)
  local backends = require("md-viewer.backends")
  local backend = assert(backends.select("cells"))
  t.eq("cells", backend.name, "explicit cells")
  local unavailable = select(1, backends.select("nvim_img"))
  t.eq(nil, unavailable, "missing vim.ui.img is actionable")

  -- ---------------------------------------------------------------------
  -- nvim_img replaces an image by creating the new one before deleting the
  -- old one, and it asks `terminal.double_buffer()` which order that is.
  --
  -- It used to read `image.double_buffer` itself. That option defaults to
  -- `nil`, meaning "ask the terminal profile", and `not nil` is `true` -- so
  -- every unconfigured user took the delete-then-create branch and got a blank
  -- frame on every render. `backends/init.lua` prefers this backend on any
  -- Neovim 0.12 with `vim.ui.img`, ahead of kitty_raw and regardless of
  -- terminal, so the defect was live everywhere rather than only where a
  -- profile happened to be missing. It showed up as the preview blinking
  -- during a drag, where a frame lands every few milliseconds.
  -- ---------------------------------------------------------------------
  local nvim_img = backends.get("nvim_img")
  local config = require("md-viewer.config")
  local placement = { row = 0, col = 0, width = 4, height = 2 }
  local original_img = vim.ui.img
  local calls = {}
  vim.ui.img = {
    set = function()
      calls[#calls + 1] = "set"
      return #calls
    end,
    del = function() calls[#calls + 1] = "del" end,
  }

  config.reset()
  config.setup({ terminal = { profile = "warp" } })
  local first = nvim_img.show("png", placement)
  calls = {}
  nvim_img.update(first, "png", placement)
  t.eq("set", calls[1], "an unconfigured double_buffer creates the replacement before deleting what it replaces")
  t.eq("del", calls[2], "and only then frees the old image")
  local health = nvim_img.health()
  t.eq("create-then-delete", health.strategy, "health reports the order that is actually used")
  t.ok(health.strategy_source:match("profile default"), "and names the terminal profile as the source")

  -- An explicit false still flips it, and is still named as the source.
  config.reset()
  config.setup({ image = { double_buffer = false } })
  local second = nvim_img.show("png", placement)
  calls = {}
  nvim_img.update(second, "png", placement)
  t.eq("del", calls[1], "an explicit double_buffer=false deletes first")
  t.eq("set", calls[2], "and creates second")
  t.ok(
    nvim_img.health().strategy_source:match("explicit override"),
    "an explicit override is named as the source, not the profile"
  )

  nvim_img.clear_all()
  vim.ui.img = original_img
  config.reset()
  config.setup({})
end
