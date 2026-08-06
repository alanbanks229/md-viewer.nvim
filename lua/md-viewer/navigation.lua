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
end

return M
