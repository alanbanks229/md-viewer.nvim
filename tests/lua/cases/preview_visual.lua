---Neovim's own Visual mode is not usable over a graphical preview, and the
---plugin now enforces that rather than only assuming it.
---
---`navigation.lua` maps `v` and `V` to a *preview* selection and says why: the
---surface holds blank cells whose job is to carry a default background for the
---image to be composited through, so Neovim's Visual mode would select spaces
---and paint a highlight across the picture. Saying it was not the same as
---enforcing it. A mouse chord this plugin had not mapped -- Warp emits
---`<M-LeftDrag>` for an ordinary drag, and Vim's default for that is a
---blockwise Visual selection -- and `<C-v>` from the keyboard both still got
---in. It was reported as the preview blinking to a blank pane with a blue
---rectangle on it; the rectangle was V-BLOCK.
return function(t)
  local controller = require("md-viewer.controller")
  local state = require("md-viewer.state")
  local config = require("md-viewer.config")

  config.reset()
  require("md-viewer").setup({})

  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# One", "", "body" })
  local session = assert(controller.open("right"))

  -- The guard is for graphical backends only. A `cells` preview holds real
  -- styled text, where Visual mode and `y` do what a reader would expect.
  t.eq("cells", session.backend.name, "headless tests fall back to the cells backend")
  vim.api.nvim_set_current_win(session.preview_win)
  vim.cmd("normal! v")
  t.ok(vim.fn.mode():match("^v"), "the cells backend keeps Neovim's own visual mode")
  vim.cmd("normal! \27")

  -- With a graphical backend the guard fires and puts the preview back in
  -- normal mode, whichever visual flavour it was pushed into.
  session.backend = {
    name = "kitty_raw",
    clear = function() return true end,
    show = function() return 1 end,
    update = function() return 1 end,
    move = function() return true end,
  }
  for _, key in ipairs({ "v", "V", "\22" }) do
    vim.api.nvim_set_current_win(session.preview_win)
    vim.api.nvim_feedkeys(key, "x", false)
    vim.wait(200, function() return not vim.fn.mode():match("^[vV\22]") end, 10)
    t.ok(
      not vim.fn.mode():match("^[vV\22]"),
      ("a graphical preview does not stay in Neovim's visual mode after %q"):format(key)
    )
  end

  -- The guard is scoped to the preview buffer. Selecting text in the Markdown
  -- source is ordinary editing and must be left completely alone -- this is the
  -- one way a mode guard could do real damage.
  vim.api.nvim_set_current_win(session.source_win or vim.fn.win_findbuf(source)[1])
  vim.api.nvim_set_current_buf(source)
  vim.api.nvim_feedkeys("V", "x", false)
  vim.wait(120, function() return false end, 10)
  t.ok(vim.fn.mode():match("^V"), "visual mode in the Markdown source is untouched")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)

  -- Leaving visual mode must not clear the reader's find or preview selection.
  -- The buffer-local <Esc> mapping does exactly that, which is why the guard
  -- feeds <Esc> with "n" (no remap) rather than "m".
  session.find_query = "needle"
  vim.api.nvim_set_current_win(session.preview_win)
  vim.api.nvim_feedkeys("\22", "x", false)
  vim.wait(200, function() return not vim.fn.mode():match("^[vV\22]") end, 10)
  t.eq("needle", session.find_query, "escaping Neovim's visual mode does not run the preview's own Escape mapping")

  -- The keyboard route is mapped rather than left to Vim: <C-v> and gv were
  -- the two ways into blockwise Visual that no amount of mouse mapping could
  -- reach. `navigation.attach` is called for graphical backends only, and a
  -- headless test always resolves to `cells`, so it is driven directly here --
  -- the same technique the mouse case uses for `mouse.attach`.
  require("md-viewer.navigation").attach(session, controller.navigate)
  vim.api.nvim_set_current_win(session.preview_win)
  for _, lhs in ipairs({ "<C-v>", "gv" }) do
    local mapping = vim.fn.maparg(lhs, "n", false, true)
    t.ok(
      not vim.tbl_isempty(mapping) and mapping.buffer == 1,
      ("%s is mapped buffer-locally in the preview rather than starting Neovim's own visual mode"):format(lhs)
    )
  end

  controller.close(source)
  config.reset()
end
