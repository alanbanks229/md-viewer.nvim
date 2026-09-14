-- Is there a browser for the Lua suite to round-trip through?
--
-- CONTRIBUTING promises that "browser-dependent tests skip where none is
-- present", and the Node suite keeps that promise -- it calls the renderer's
-- own `discoverChromium` and calls `t.skip` when it comes back empty. The Lua
-- suite did not: `debug.lua` and `health.lua` drive a real renderer subprocess
-- that launches a real Chromium and wait 30 seconds for the answer, so on a
-- machine without one (or without the renderer's dependencies installed) they
-- burn a minute and then fail an assertion about a report that was never
-- produced.
--
-- The question is answered the same way the Node suite answers it, by asking
-- the renderer's own discovery module rather than by a second list of paths
-- that could disagree with it. Two cheaper checks come first, because both are
-- also reasons the round-trip cannot happen.
--
-- `MD_VIEWER_TEST_NO_BROWSER=1` forces the unavailable answer, so the skip
-- path can be exercised on a machine that does have a browser.

local M = {}

local DISCOVERY = table.concat({
  'import fs from "node:fs";',
  'const { discoverChromium } = await import("./renderer/src/browser-discovery.js");',
  "const found = discoverChromium(process.platform, process.env, fs.existsSync, {});",
  'process.stdout.write(found.executable ?? "");',
}, " ")

local answer

---Returns the executable path, or nil and the reason to print in the skip.
---Memoized: the discovery spawns a Node process, and the answer cannot change
---during a run.
function M.available(root)
  if answer then return answer[1], answer[2] end

  local function decide(executable, reason)
    answer = { executable, reason }
    return executable, reason
  end

  if vim.env.MD_VIEWER_TEST_NO_BROWSER == "1" then return decide(nil, "MD_VIEWER_TEST_NO_BROWSER=1") end
  if vim.fn.exepath("node") == "" then return decide(nil, "no node on PATH") end
  if not vim.uv.fs_stat(vim.fs.joinpath(root, "renderer/node_modules/playwright")) then
    return decide(nil, "renderer dependencies are not installed (see CONTRIBUTING)")
  end

  local result = vim.system({ "node", "--input-type=module", "-e", DISCOVERY }, { cwd = root, text = true }):wait(30000)
  local executable = (result.stdout or ""):gsub("%s+$", "")
  if result.code ~= 0 or executable == "" then
    return decide(nil, "no approved Chrome, Chromium, or Edge executable found on this platform")
  end
  return decide(executable, nil)
end

return M
