local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script)))
vim.opt.runtimepath:prepend(root)
vim.opt.shadafile = "NONE"

local t = dofile(root .. "/tests/lua/harness.lua")

require("md-viewer.config").reset()

local cases_dir = root .. "/tests/lua/cases"
local files = vim.fn.glob(cases_dir .. "/*.lua", true, true)
table.sort(files)

for _, file in ipairs(files) do
  local case = dofile(file)
  local name = vim.fs.basename(file)
  local ok, err = pcall(case, t)
  if not ok then error(("md-viewer: test case %s failed: %s"):format(name, err)) end
end

t.finish()
