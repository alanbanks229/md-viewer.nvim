return function(t)
  local mouse = require("md-viewer.mouse")
  local state = require("md-viewer.state")
  local interaction = require("md-viewer.interaction")

  -- §4.5: interaction must never be enabled for the `cells` backend. Opening
  -- a preview with the default (cells, in a headless test) backend must not
  -- install any of the new gesture mappings.
  require("md-viewer").setup({})
  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# One", "", "body" })
  local controller = require("md-viewer.controller")
  local cells_session = assert(controller.open("right"))
  t.eq("cells", cells_session.backend.name, "headless tests fall back to the cells backend")
  t.eq(false, mouse.is_attached(), "opening a cells-backend preview installs no mouse dispatch at all")
  controller.close(source)

  -- A graphical backend installs both the existing wheel mappings and the
  -- new gesture mappings, across all three modes, and preserves whatever was
  -- mapped there before -- the same technique the wheel mappings already use.
  vim.api.nvim_set_current_buf(source)
  local session = assert(controller.open("right"))
  session.backend = {
    name = "kitty_raw",
    clear = function() return true end,
    show = function() return 1 end,
    update = function() return 1 end,
    move = function() return true end,
  }

  local modes = { "n", "i", "v" }
  local gesture_lhs =
    { "<LeftMouse>", "<LeftDrag>", "<LeftRelease>", "<C-LeftMouse>", "<D-LeftMouse>", "<2-LeftMouse>" }
  for _, lhs in ipairs(gesture_lhs) do
    vim.keymap.set("n", lhs, "<Nop>", { desc = "test prior gesture mapping" })
  end

  mouse.attach(controller.navigate)
  t.eq(true, mouse.is_attached(), "attaching for a graphical session installs dispatch")
  for _, mode in ipairs(modes) do
    for _, lhs in ipairs(gesture_lhs) do
      local mapping = vim.fn.maparg(lhs, mode, false, true)
      t.ok(not vim.tbl_isempty(mapping), ("%s is mapped in mode %s"):format(lhs, mode))
      t.eq(true, mapping.expr == 1 or mapping.expr == true, ("%s in mode %s is an expr mapping"):format(lhs, mode))
    end
  end

  -- Falls through unmodified when there is no session under the pointer at
  -- all (e.g. a click over some other window). `maparg(..., true)` exposes
  -- the Lua callback directly for a mapping installed via vim.keymap.set, so
  -- it can be invoked deterministically without faking real terminal input.
  local original_getmousepos = vim.fn.getmousepos
  vim.fn.getmousepos = function() return { winid = 0, screenrow = 1, screencol = 1 } end
  local left_mouse_n = vim.fn.maparg("<LeftMouse>", "n", false, true)
  t.eq("<LeftMouse>", left_mouse_n.callback(), "an unresolved session falls through to the original key")
  vim.fn.getmousepos = original_getmousepos

  controller.close(source)
  t.eq(false, mouse.is_attached(), "mouse dispatch is removed once the last graphical preview closes")
  for _, mode in ipairs(modes) do
    for _, lhs in ipairs(gesture_lhs) do
      local restored = vim.fn.maparg(lhs, mode, false, true)
      if mode == "n" then
        t.eq("<Nop>", restored.rhs, ("previous %s mapping in mode n is restored"):format(lhs))
      else
        t.ok(vim.tbl_isempty(restored), ("no stray %s mapping remains in mode %s"):format(lhs, mode))
      end
    end
    for _, lhs in ipairs(gesture_lhs) do
      pcall(vim.keymap.del, mode, lhs)
    end
  end

  -- interaction.enabled = false installs no gesture mappings, even for a
  -- graphical backend, while the wheel mappings are unaffected.
  require("md-viewer").setup({ interaction = { enabled = false } })
  vim.api.nvim_set_current_buf(source)
  local disabled_session = assert(controller.open("right"))
  disabled_session.backend = {
    name = "kitty_raw",
    clear = function() return true end,
    show = function() return 1 end,
    update = function() return 1 end,
    move = function() return true end,
  }
  mouse.attach(controller.navigate)
  local down_mapping = vim.fn.maparg("<ScrollWheelDown>", "n", false, true)
  t.ok(not vim.tbl_isempty(down_mapping), "wheel mapping still installs when interaction.enabled is false")
  local left_mapping = vim.fn.maparg("<LeftMouse>", "n", false, true)
  t.ok(vim.tbl_isempty(left_mapping), "no gesture mapping installs when interaction.enabled is false")
  controller.close(source)
  require("md-viewer").setup({})

  t.eq(nil, interaction.captured_session(), "no session remains captured once every preview has closed")
end
