local config = require("md-viewer.config")
local interaction = require("md-viewer.interaction")

local M = {}

---`controller` requires this module, so it is resolved at call time rather than
---at the top of the file.
local function controller() return require("md-viewer.controller") end

---Every caret motion is one call: the renderer decides where the caret may go,
---because only it knows where the characters are. See
---`interaction.caret_motion`.
local function move(session, granularity, direction, count)
  interaction.caret_motion(session, granularity, direction, count or vim.v.count1)
end

---How many rendered lines fit in `fraction` of the viewport. `<C-d>` and
---friends are line motions with a count rather than raw scrolls, which is what
---Vim actually does with them -- and it means the caret leads the scroll
---instead of being left behind by it, since the renderer scrolls whatever it
---has to in order to keep the caret in view.
local function viewport_lines(session, fraction)
  local height = session.viewport_height_px or 0
  local line = config.get().sync.navigation_line_px
  if height <= 0 or line <= 0 then return 1 end
  return math.max(1, math.floor((height * fraction) / line))
end

---Preview-local motions.
---
---Caret motions ask the renderer to move the caret and to scroll whatever it
---must to keep it visible, so `j` on the last visible line scrolls exactly the
---way it does in a text buffer, and holding `j` still scrolls.
---
---CTRL-E and CTRL-Y are the two exceptions, and match Vim in being so: they
---scroll the view and leave the caret on its document position, which may take
---it off screen -- where it is simply not drawn until it comes back.
local mappings = {
  { "j", function(s) move(s, "line", "forward") end, "Caret down a line" },
  { "k", function(s) move(s, "line", "backward") end, "Caret up a line" },
  { "<Down>", function(s) move(s, "line", "forward") end, "Caret down a line" },
  { "<Up>", function(s) move(s, "line", "backward") end, "Caret up a line" },
  { "h", function(s) move(s, "character", "backward") end, "Caret left one character" },
  { "l", function(s) move(s, "character", "forward") end, "Caret right one character" },
  { "<Left>", function(s) move(s, "character", "backward") end, "Caret left one character" },
  { "<Right>", function(s) move(s, "character", "forward") end, "Caret right one character" },
  { "0", function(s) move(s, "lineboundary", "backward", 1) end, "Caret to the start of the line" },
  { "$", function(s) move(s, "lineboundary", "forward", 1) end, "Caret to the end of the line" },
  { "w", function(s) move(s, "word", "forward") end, "Caret to the next word" },
  { "b", function(s) move(s, "word", "backward") end, "Caret to the previous word" },
  { "e", function(s) move(s, "word_end", "forward") end, "Caret to the end of the word" },
  { "}", function(s) move(s, "block", "forward") end, "Caret to the next block" },
  { "{", function(s) move(s, "block", "backward") end, "Caret to the previous block" },
  {
    "<C-d>",
    function(s) move(s, "line", "forward", vim.v.count1 * viewport_lines(s, 0.5)) end,
    "Caret down half a page",
  },
  {
    "<C-u>",
    function(s) move(s, "line", "backward", vim.v.count1 * viewport_lines(s, 0.5)) end,
    "Caret up half a page",
  },
  { "<C-f>", function(s) move(s, "line", "forward", vim.v.count1 * viewport_lines(s, 0.9)) end, "Caret down a page" },
  { "<C-b>", function(s) move(s, "line", "backward", vim.v.count1 * viewport_lines(s, 0.9)) end, "Caret up a page" },
  {
    "<PageDown>",
    function(s) move(s, "line", "forward", vim.v.count1 * viewport_lines(s, 0.9)) end,
    "Caret down a page",
  },
  {
    "<PageUp>",
    function(s) move(s, "line", "backward", vim.v.count1 * viewport_lines(s, 0.9)) end,
    "Caret up a page",
  },
  { "<C-e>", function(s, go) go(s, "line_down", vim.v.count1) end, "Scroll down a line, leaving the caret" },
  { "<C-y>", function(s, go) go(s, "line_up", vim.v.count1) end, "Scroll up a line, leaving the caret" },
  -- Document ends, and only that: a count is ignored rather than meaning a
  -- line, because the lines a reader can see here are *rendered* lines and the
  -- ones they would type are *source* lines. Going to a source line is a real
  -- feature and a separate one; it is not this keystroke wearing a count.
  { "gg", function(s) move(s, "document", "backward", 1) end, "Document start" },
  { "G", function(s) move(s, "document", "forward", 1) end, "Document end" },
}

---Selection, search, history and Escape keys. Kept as a second, small loop
---rather than folded into `mappings` above: each is individually gated by its
---own `interaction.*` config flag, where the caret motions are not.
local function interaction_mappings()
  local cfg = config.get().interaction
  local list = {}
  if cfg.visual and cfg.selection then
    -- Neovim stays in normal mode throughout: `v` here starts a *preview*
    -- visual selection, extended by the ordinary motions above. Its own visual
    -- mode is not usable for this -- the surface holds blank cells, so it would
    -- select spaces -- and leaving Neovim in normal mode also keeps every
    -- motion mapping and the mouse gestures working unchanged.
    list[#list + 1] = {
      "v",
      function(session)
        if not interaction.visual_stop(session, true) then interaction.visual_start(session, false) end
      end,
      "Start or end a preview visual selection",
    }
    list[#list + 1] = {
      "V",
      function(session)
        if not interaction.visual_stop(session, true) then interaction.visual_start(session, true) end
      end,
      "Start or end a line-wise preview visual selection",
    }
    list[#list + 1] = {
      "o",
      function(session) interaction.visual_swap(session) end,
      "Swap which end of the visual selection the caret holds",
    }
  end
  -- Mapped whether or not preview selection is enabled, and mapped to nothing
  -- when it is not. `v` and `V` above exist partly to keep Neovim out of its
  -- own visual mode over the surface; `<C-v>` and `gv` were the two ways left
  -- in, and blockwise Visual over blank cells paints a rectangle across the
  -- image. See the `ModeChanged` guard in controller.lua for the backstop.
  list[#list + 1] = {
    "<C-v>",
    function(session)
      if cfg.visual and cfg.selection then
        if not interaction.visual_stop(session, true) then interaction.visual_start(session, false) end
      end
    end,
    "Start or end a preview visual selection (Neovim's blockwise Visual is not usable here)",
  }
  list[#list + 1] = {
    "gv",
    function() end,
    "Reserved: Neovim's visual mode is not usable over the preview surface",
  }
  if cfg.copy then
    list[#list + 1] = {
      "y",
      function(session)
        -- In visual mode `y` yanks and leaves it, as it does in a text buffer.
        -- The settle frame lands first so the copy reads the same selection the
        -- reader is looking at, rather than one preview frame behind it.
        interaction.visual_stop(session, true)
        interaction.copy_selection(session, false)
      end,
      "Copy preview selection",
    }
  end
  if cfg.find then
    -- Same entry point as `:MdViewerFind` with no argument, so the prompt
    -- behaves identically from either: always empty, and clearing the search
    -- and selection when it is dismissed without a query. `controller` is
    -- required at call time, not at the top of the file: it requires this
    -- module.
    list[#list + 1] = {
      "/",
      function(session) controller().find_prompt(session) end,
      "Search rendered preview",
    }
    list[#list + 1] = { "n", function(session) interaction.find_next(session) end, "Next search match" }
    list[#list + 1] = { "N", function(session) interaction.find_previous(session) end, "Previous search match" }
  end
  -- Always installed, regardless of which features are enabled above, so it
  -- can fall through cleanly to normal Escape behaviour when neither a find
  -- nor a selection is active: interaction.escape() returns false in that
  -- case rather than this mapping simply not existing.
  list[#list + 1] = {
    "<Esc>",
    function(session)
      if not interaction.escape(session) then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
      end
    end,
    "Clear search, then selection, then normal Escape",
  }
  list[#list + 1] = {
    "]b",
    function(session) controller().tab_next(session) end,
    "Next document tab in this preview pane",
  }
  list[#list + 1] = {
    "[b",
    function(session) controller().tab_previous(session) end,
    "Previous document tab in this preview pane",
  }
  if cfg.keymaps.tab_previous then
    list[#list + 1] = {
      cfg.keymaps.tab_previous,
      function(session) controller().tab_previous(session) end,
      "Previous document tab in this preview pane",
    }
  end
  if cfg.keymaps.tab_next then
    list[#list + 1] = {
      cfg.keymaps.tab_next,
      function(session) controller().tab_next(session) end,
      "Next document tab in this preview pane",
    }
  end
  list[#list + 1] = {
    "gf",
    function(session) controller().reveal_source(session) end,
    "Reveal this preview document in the source pane",
  }
  return list
end

function M.attach(session, callback)
  for _, mapping in ipairs(mappings) do
    local lhs, fn, description = mapping[1], mapping[2], mapping[3]
    vim.keymap.set("n", lhs, function() fn(session, callback) end, {
      buffer = session.preview_buf,
      silent = true,
      nowait = lhs ~= "gg",
      desc = description,
    })
  end
  for _, mapping in ipairs(interaction_mappings()) do
    local lhs, fn, description = mapping[1], mapping[2], mapping[3]
    vim.keymap.set("n", lhs, function() fn(session) end, {
      buffer = session.preview_buf,
      silent = true,
      desc = description,
    })
  end
end

return M
