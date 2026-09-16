-- The per-case teardown contract.
--
-- Every Lua case runs in one shared Neovim, in alphabetical order, against
-- real buffers and windows -- so what a case leaves behind is the next case's
-- starting condition. This module takes a picture of the parts of that world
-- a case must hand back unchanged, and names the differences.
--
-- What is checked, and why each one is the next case's problem:
--
--   windows / tabpages  A leaked split or float changes what `:vsplit`,
--                       `nvim_win_close` and the occlusion geometry see.
--   panes               `state.panes()` is iterated by occlusion, tabpage
--                       visibility and diagnostics; a stranded pane is a
--                       session those loops will still visit.
--   md-viewer autocmds  A second `setup()` that re-registered the group
--                       would fire every handler twice.
--   configuration       The config singleton is global. A case that opens a
--                       preview under `backend = "cells"` and does not put
--                       it back decides the backend for every case after it.
--
-- Buffers are deliberately *not* checked. Cases create fixture buffers by
-- design and rarely wipe them, but a stale buffer id influences nothing:
-- sessions are keyed by buffer, so an unreferenced one is only memory.

local M = {}

local function autocmd_count()
  local ok, list = pcall(vim.api.nvim_get_autocmds, { group = "md-viewer" })
  if not ok then return nil end
  return #list
end

---A picture of the shared world, taken before and after a case.
function M.capture()
  local panes = {}
  for id in pairs(require("md-viewer.state").panes()) do
    panes[#panes + 1] = id
  end
  table.sort(panes)
  return {
    windows = #vim.api.nvim_list_wins(),
    tabpages = #vim.api.nvim_list_tabpages(),
    panes = panes,
    autocmds = autocmd_count(),
    config = vim.inspect(require("md-viewer.config").get()),
  }
end

local function describe(before, after, key)
  return ("%s: %s -> %s"):format(key, vim.inspect(before[key]), vim.inspect(after[key]))
end

---Differences between two captures, as a list of one-line descriptions.
---Empty means the case handed the world back as it found it.
function M.diff(before, after)
  local out = {}
  for _, key in ipairs({ "windows", "tabpages", "panes" }) do
    if not vim.deep_equal(before[key], after[key]) then out[#out + 1] = describe(before, after, key) end
  end
  -- The group does not exist until the first `setup()`, so its appearance is
  -- expected; only a change to an existing group's size is a leak.
  if before.autocmds and after.autocmds ~= before.autocmds then out[#out + 1] = describe(before, after, "autocmds") end
  if before.config ~= after.config then
    out[#out + 1] = "config: left modified (call config.reset() or restore setup() at the end of the case)"
  end
  return out
end

return M
