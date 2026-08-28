-- Dumps the Lua Kitty upload chunker's exact output into
-- `tests/fixtures/local-upload-golden.json`, the committed contract the
-- JS port (`renderer/src/local/kitty-writer.js`) is byte-compared against by
-- `tests/node/local-injector.test.js`.
--
-- Run after any change to `kitty_raw.lua`'s `chunks()`/`upload_sequence`:
--
--   nvim --headless -u NONE -i NONE -l scripts/local/dump-upload-golden.lua
--
-- The inputs are synthetic byte patterns chosen for their chunk arithmetic,
-- not their content: one that splits 4096+4064, one landing exactly on the
-- 4096-char base64 boundary (still `m=0` -- a single chunk says so), one a
-- single byte past it, and one tiny. Same reasoning as the golden byte tests:
-- the boundaries are where a port drifts.

local source = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
vim.opt.runtimepath:prepend(root)

local raw = require("md-viewer.backends.kitty_raw")

local function pattern_bytes(n)
  local parts = {}
  for i = 0, n - 1 do
    parts[#parts + 1] = string.char((i * 7 + 13) % 256)
  end
  return table.concat(parts)
end

local specs = {
  { id = 0x4d0000ff, len = 6120 }, -- 8160 base64 chars: chunks of 4096 + 4064
  { id = 0x4d000001, len = 3072 }, -- exactly 4096 base64 chars: one chunk, m=0
  { id = 0x4d0012ab, len = 3073 }, -- 4100 chars: 4096 + 4
  { id = 0x4d000002, len = 5 },
}

local cases = {}
for _, spec in ipairs(specs) do
  local input = pattern_bytes(spec.len)
  cases[#cases + 1] = {
    id = spec.id,
    input_b64 = vim.base64.encode(input),
    expected_b64 = vim.base64.encode(raw._upload_sequence(spec.id, input)),
  }
end

local path = root .. "/tests/fixtures/local-upload-golden.json"
local file = assert(io.open(path, "w"))
file:write(vim.json.encode({
  generated_by = "scripts/local/dump-upload-golden.lua",
  cases = cases,
}))
file:write("\n")
file:close()
print("wrote " .. path .. " (" .. #cases .. " cases)")
