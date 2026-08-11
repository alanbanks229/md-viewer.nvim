local M = { name = "cells" }
local ns = vim.api.nvim_create_namespace("md-viewer_cells")

function M.detect() return true, "terminal-native fallback is always available" end
function M.show() return 0 end
function M.update() return 0 end
function M.move(id) return id end
function M.clear() return true end
function M.clear_all() end
function M.health() return { available = true, reason = "terminal-native fallback" } end

local function transform(line)
  local level, title = line:match("^(#+)%s+(.+)$")
  if level then return string.rep(" ", math.max(0, #level - 1)) .. title, "MdViewerHeading" end
  if line:match("^%s*```") then return line:gsub("```.*", ""), "MdViewerCode" end
  if line:match("^%s*>%s*") then return "│ " .. line:gsub("^%s*>%s*", ""), "MdViewerQuote" end
  if line:match("^%s*[-*_]%s*[-*_]%s*[-*_]") then return string.rep("─", 40), "MdViewerRule" end
  line = line:gsub("%*%*(.-)%*%*", "%1"):gsub("`([^`]+)`", "%1")
  return line, nil
end

function M.render(buf, markdown)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local lines = vim.split(markdown, "\n", { plain = true })
  local output, highlights = {}, {}
  for index, line in ipairs(lines) do
    local rendered, group = transform(line)
    output[index] = rendered
    if group then highlights[#highlights + 1] = { index - 1, group } end
  end
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, output)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, item in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(buf, ns, item[1], 0, { end_col = #output[item[1] + 1], hl_group = item[2] })
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
end

return M
