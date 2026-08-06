local M = {}

function M.encode(value)
  return vim.json.encode(value) .. "\n"
end

function M.decode(line)
  if type(line) ~= "string" or line == "" then return nil, "empty renderer response" end
  local ok, value = pcall(vim.json.decode, line)
  if not ok then return nil, "invalid renderer JSON: " .. tostring(value) end
  if type(value) ~= "table" or type(value.id) ~= "number" or type(value.ok) ~= "boolean" then
    return nil, "renderer response missing id/ok"
  end
  return value
end

return M
