return function(t)
  local backends = require("md-viewer.backends")
  local backend = assert(backends.select("cells"))
  t.eq("cells", backend.name, "explicit cells")
  local unavailable = select(1, backends.select("nvim_img"))
  t.eq(nil, unavailable, "missing vim.ui.img is actionable")

  -- ---------------------------------------------------------------------
  -- The capability matrix. Callers ask a backend what it can do, never what
  -- it is called: `backend.name ==` was doing the work of six different
  -- questions at 42 sites, and four of the six were only ever true for
  -- kitty_raw, so a new backend inherited every one of them by accident.
  --
  -- Every backend declares every flag explicitly. A missing declaration reads
  -- as `false` at the call site, which is how a graphical backend would
  -- silently become a text one -- so the absence is asserted here, where it is
  -- loud, rather than left to whichever feature noticed first.
  -- ---------------------------------------------------------------------
  local matrix = {
    cells = {
      is_graphical = false,
      places_raw_images = false,
      accepts_exclusions = false,
      needs_statusline_guard = false,
      needs_ui_poll = false,
      supports_local_markers = false,
    },
    nvim_img = {
      is_graphical = true,
      places_raw_images = false,
      accepts_exclusions = false,
      needs_statusline_guard = false,
      needs_ui_poll = false,
      supports_local_markers = false,
    },
    kitty_raw = {
      is_graphical = true,
      places_raw_images = true,
      accepts_exclusions = true,
      needs_statusline_guard = true,
      needs_ui_poll = true,
      supports_local_markers = true,
    },
  }
  for name, expected in pairs(matrix) do
    local module = backends.get(name)
    for flag, value in pairs(expected) do
      t.eq(value, module[flag], ("%s declares %s"):format(name, flag))
      t.eq("boolean", type(module[flag]), ("%s declares %s as a boolean, not by omission"):format(name, flag))
    end
    local declared = backends.capabilities(name)
    t.eq(name, declared.name, ("capabilities(%s) carries the name it was asked for"):format(name))
    for flag, value in pairs(expected) do
      t.eq(value, declared[flag], ("capabilities(%s) reports %s"):format(name, flag))
    end
    declared.is_graphical = "mutated"
    t.eq(expected.is_graphical, backends.get(name).is_graphical, ("capabilities(%s) hands back a copy"):format(name))
  end
  t.eq(nil, backends.capabilities("no_such_backend"), "an unknown backend declares nothing")

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
