local config = require("md-viewer.config")
local interaction = require("md-viewer.interaction")

local M = {}

local mappings = {
  { "j", "line_down", "Preview down one rendered line" },
  { "k", "line_up", "Preview up one rendered line" },
  { "<Down>", "line_down", "Preview down one rendered line" },
  { "<Up>", "line_up", "Preview up one rendered line" },
  { "<C-e>", "line_down", "Preview down one rendered line" },
  { "<C-y>", "line_up", "Preview up one rendered line" },
  { "<C-d>", "half_down", "Preview down half a page" },
  { "<C-u>", "half_up", "Preview up half a page" },
  { "<C-f>", "page_down", "Preview down one page" },
  { "<C-b>", "page_up", "Preview up one page" },
  { "<PageDown>", "page_down", "Preview down one page" },
  { "<PageUp>", "page_up", "Preview up one page" },
  { "gg", "top", "Preview document top" },
  { "G", "bottom", "Preview document bottom" },
}

---§6.4/6.6 preview-local keys. Kept as a second, small loop rather than folded
---into `mappings` above: these dispatch straight into `interaction`/`vim.ui`,
---not through the uniform `callback(session, action)` shape the scroll
---mappings share, and each is individually gated by its own
---`interaction.*` config flag.
local function interaction_mappings()
  local cfg = config.get().interaction
  local list = {}
  if cfg.copy then
    list[#list + 1] =
      { "y", function(session) interaction.copy_selection(session, false) end, "Copy preview selection" }
  end
  if cfg.find then
    list[#list + 1] = {
      "/",
      function(session)
        vim.ui.input({ prompt = "md-viewer find: " }, function(input)
          if input and input ~= "" then interaction.find_set(session, input) end
        end)
      end,
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
  return list
end

function M.attach(session, callback)
  for _, mapping in ipairs(mappings) do
    local lhs, action, description = mapping[1], mapping[2], mapping[3]
    vim.keymap.set("n", lhs, function() callback(session, action) end, {
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
