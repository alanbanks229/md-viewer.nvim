-- The Lua suite's entry point.
--
-- Cases run alphabetically in one shared Neovim; the order is load-bearing in
-- at least one place (`controller_local.lua` must run before
-- `local_transport.lua` resets the local-render listeners), so filtering
-- narrows the list without reordering what remains.
--
--   MD_VIEWER_TEST_FILTER=history make test-lua      -- one case
--   MD_VIEWER_TEST_FILTER='^preview_' make test-lua  -- a Lua pattern
--
-- The filter is a Lua pattern matched against the case name without its
-- extension, so a bare name is a substring match. A filter that selects
-- nothing is an error rather than a silent pass.

local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script)))
vim.opt.runtimepath:prepend(root)
vim.opt.shadafile = "NONE"

local t = dofile(root .. "/tests/lua/harness.lua")
local world = dofile(root .. "/tests/lua/world.lua")
local shape = dofile(root .. "/tests/lua/session_shape.lua")

require("md-viewer.config").reset()

-- Installed before the first case, so every session the suite creates is
-- inside the shape contract. `tests/lua/cases/session_shape.lua` asserts the
-- manifest's static half; the sweep below is the half only a whole run can
-- make -- see the two assertions after the loop.
shape.track()
t.on_assert = shape.sample

local cases_dir = root .. "/tests/lua/cases"
local files = vim.fn.glob(cases_dir .. "/*.lua", true, true)
table.sort(files)

local filter = vim.env.MD_VIEWER_TEST_FILTER
if filter and filter ~= "" then
  local kept = {}
  for _, file in ipairs(files) do
    local name = vim.fs.basename(file):gsub("%.lua$", "")
    if name:find(filter) then kept[#kept + 1] = file end
  end
  if #kept == 0 then error(("md-viewer: MD_VIEWER_TEST_FILTER=%q matched no case"):format(filter)) end
  files = kept
end

for _, file in ipairs(files) do
  local case = dofile(file)
  local name = vim.fs.basename(file)
  local before = world.capture()
  local ok, err = pcall(case, t)
  if not ok then error(("md-viewer: test case %s failed: %s"):format(name, err)) end
  shape.sample()
  for _, leak in ipairs(world.diff(before, world.capture())) do
    t.eq(nil, leak, ("%s left the shared world modified"):format(name))
  end
end

-- The cross-case half of the session shape contract. A filtered run sees only
-- part of the suite, so the completeness direction cannot hold there.
t.eq({}, shape.undeclared(), "every field a real session carried is described by tests/lua/session_shape.lua")
if not (filter and filter ~= "") then
  t.eq({}, shape.missing(), "every field the manifest marks observed turned up on a real session")
end

t.finish(filter)
