local M = {}

function M.encode(value) return vim.json.encode(value) .. "\n" end

function M.decode(line)
  if type(line) ~= "string" or line == "" then return nil, "empty renderer response" end
  -- `luanil.object` is load-bearing, not tidiness. Without it a JSON `null`
  -- decodes to `vim.NIL`, a userdata sentinel that is **truthy** and compares
  -- `~= nil`, so both `if not value.x` and `value.x ~= nil` read a null field as
  -- present and the first arithmetic on it throws. The renderer sends null for
  -- everything it honestly cannot resolve -- `sourcePosition.line` and
  -- `byteColumn` for a click on empty space, `link` for a hit that is not on
  -- one -- so decoding null as absent is what makes ordinary Lua nil checks
  -- correct. Only object values are converted: `luanil.array` would leave holes
  -- in arrays like `blocks`.
  local ok, value = pcall(vim.json.decode, line, { luanil = { object = true } })
  if not ok then return nil, "invalid renderer JSON: " .. tostring(value) end
  if type(value) ~= "table" or type(value.id) ~= "number" or type(value.ok) ~= "boolean" then
    return nil, "renderer response missing id/ok"
  end
  return value
end

---Decode one NDJSON line from the local-render control socket. Unlike
---`M.decode` it enforces no envelope: the socket carries `{id, ok, ...}`
---responses and id-less `{event = ...}` notification lines, and the
---transport classifies them after decoding. Same `luanil` rule as above, for
---the same reason.
function M.decode_line(line)
  if type(line) ~= "string" or line == "" then return nil, "empty line" end
  local ok, value = pcall(vim.json.decode, line, { luanil = { object = true } })
  if not ok then return nil, "invalid JSON: " .. tostring(value) end
  if type(value) ~= "table" then return nil, "line is not an object" end
  return value
end

return M
