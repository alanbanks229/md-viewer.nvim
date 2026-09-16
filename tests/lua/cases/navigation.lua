return function(t)
  require("md-viewer").setup({ image = { backend = "cells" } })
  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# One", "", "body" })
  local controller = require("md-viewer.controller")
  local session = assert(controller.open("right"))
  local navigation = require("md-viewer.navigation")
  navigation.attach(session, function() end)
  local g_mapping = vim.api.nvim_buf_call(
    session.preview_buf,
    function() return vim.fn.maparg("G", "n", false, true) end
  )
  t.ok(not vim.tbl_isempty(g_mapping), "preview-local G mapping exists")

  -- H/L cycle document tabs, the same action as [b/]b. Buffer-local, so they
  -- only ever shadow "top/bottom of screen" inside the preview's own scratch
  -- buffer -- which holds no text for those to address in the first place.
  local function preview_map(lhs, buf)
    return vim.api.nvim_buf_call(buf or session.preview_buf, function() return vim.fn.maparg(lhs, "n", false, true) end)
  end
  local expected_desc = {
    H = "Previous document tab in this preview pane",
    L = "Next document tab in this preview pane",
  }
  for _, lhs in ipairs({ "H", "L" }) do
    local mapping = preview_map(lhs)
    t.ok(not vim.tbl_isempty(mapping), ("preview-local %s mapping exists"):format(lhs))
    t.eq(session.preview_buf, mapping.buffer ~= 0 and session.preview_buf or nil, lhs .. " is buffer-local")
    t.eq(expected_desc[lhs], mapping.desc, lhs .. " matches the [b/]b tab-cycle description")
  end
  controller.close(source)

  -- Tabs are not gated on interaction.links -- [b/]b are already unconditional,
  -- and H/L now do the same thing, so they stay mapped with links off too.
  require("md-viewer").setup({ image = { backend = "cells" }, interaction = { links = false } })
  vim.api.nvim_set_current_buf(source)
  local without_links = assert(controller.open("right"))
  navigation.attach(without_links, function() end)
  for _, lhs in ipairs({ "H", "L" }) do
    local mapping = preview_map(lhs, without_links.preview_buf)
    t.ok(not vim.tbl_isempty(mapping), ("%s is still mapped when interaction.links is false"):format(lhs))
  end
  controller.close(source)

  -- interaction.keymaps lets a reader move the tab-cycle keys off H/L
  -- entirely: the configured key replaces the default, it does not add to it.
  require("md-viewer").setup({
    image = { backend = "cells" },
    interaction = { keymaps = { tab_previous = "gh", tab_next = "gl" } },
  })
  vim.api.nvim_set_current_buf(source)
  local remapped = assert(controller.open("right"))
  navigation.attach(remapped, function() end)
  for _, lhs in ipairs({ "gh", "gl" }) do
    t.ok(not vim.tbl_isempty(preview_map(lhs, remapped.preview_buf)), ("preview-local %s mapping exists"):format(lhs))
  end
  for _, lhs in ipairs({ "H", "L" }) do
    t.ok(
      vim.tbl_isempty(preview_map(lhs, remapped.preview_buf)),
      (lhs .. " is not mapped once interaction.keymaps moves it to a different key")
    )
  end
  controller.close(source)

  -- Setting one of the two to `false` unmaps only that action.
  require("md-viewer").setup({
    image = { backend = "cells" },
    interaction = { keymaps = { tab_previous = false } },
  })
  vim.api.nvim_set_current_buf(source)
  local disabled = assert(controller.open("right"))
  navigation.attach(disabled, function() end)
  t.ok(vim.tbl_isempty(preview_map("H", disabled.preview_buf)), "H is unmapped when tab_previous is false")
  t.ok(
    not vim.tbl_isempty(preview_map("L", disabled.preview_buf)),
    "L keeps its default when only tab_previous is false"
  )
  controller.close(source)

  -- keymaps.copy names the key(s) that copy the preview selection. A list
  -- maps every one of them to the same handler, which is how a reader keeps
  -- `y` and adds the `<leader>y` their own `"+y` noremap would otherwise
  -- swallow before it ever reached this buffer.
  require("md-viewer").setup({
    image = { backend = "cells" },
    interaction = { keymaps = { copy = { "y", "<leader>y" } } },
  })
  -- Pinned rather than assumed: `<leader>` is expanded by `vim.keymap.set`
  -- from whatever `mapleader` is at the moment the preview opens, so the lhs
  -- to look up afterwards is only knowable if the test sets it. Restored
  -- below, since a case hands the world back as it found it.
  local saved_mapleader = vim.g.mapleader
  vim.g.mapleader = ","
  vim.api.nvim_set_current_buf(source)
  local copy_keys = assert(controller.open("right"))
  navigation.attach(copy_keys, function() end)
  for _, lhs in ipairs({ "y", ",y" }) do
    local mapping = preview_map(lhs, copy_keys.preview_buf)
    t.ok(not vim.tbl_isempty(mapping), ("preview-local %q copy mapping exists"):format(lhs))
    t.eq("Copy preview selection", mapping.desc, ("%q carries the copy description"):format(lhs))
  end
  controller.close(source)
  vim.g.mapleader = saved_mapleader

  -- And `false` leaves the action unmapped, the same as the tab entries.
  require("md-viewer").setup({
    image = { backend = "cells" },
    interaction = { keymaps = { copy = false } },
  })
  vim.api.nvim_set_current_buf(source)
  local no_copy = assert(controller.open("right"))
  navigation.attach(no_copy, function() end)
  t.ok(vim.tbl_isempty(preview_map("y", no_copy.preview_buf)), "y is unmapped when keymaps.copy is false")
  controller.close(source)

  require("md-viewer.config").reset()
end
