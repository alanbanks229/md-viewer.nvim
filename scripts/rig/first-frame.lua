-- What did the first frame cost, and which encoder produced it?
--
--   nvim --headless -u NONE -i NONE -l scripts/rig/first-frame.lua
--
-- Headless on purpose: it drives the renderer directly and never draws
-- anything, so it works over a link with no graphics terminal at the far end
-- and needs no preview window. Run it on the machine that runs Neovim.
--
-- The answer that matters is `encoder`:
--
--   cdp_fast_png    the fast path survived the first capture
--   playwright_png  it did not, and this process has lost the fast path for good
--
-- The first Page.captureScreenshot of a browser process costs 9,874-16,335ms on
-- Ubuntu 22.04 / Chrome 151 and 116-373ms thereafter, whatever its size. That
-- used to race a 10,000ms timeout on the session's first real frame, and
-- captureViewportPng latches `cdpCaptureUnavailable` on its first failure
-- without ever retrying -- so losing the race demotes the whole renderer
-- process to the Playwright encoder, which is also where `render.scroll_scale`
-- silently stops working.
--
-- Exits non-zero if the fast path was lost.

-- `-l` gives no <sfile>, so the repo root comes from the invoking path.
local script = debug.getinfo(1, "S").source:sub(2)
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(vim.fn.fnamemodify(script, ":p"), ":h:h:h"))

local config = require("md-viewer.config")
local process = require("md-viewer.process")

config.setup({})
local cfg = config.get()

local lines = { "# First frame", "" }
for index = 0, 400 do
  if index % 20 == 0 then lines[#lines + 1] = ("## SECTION %03d"):format(index) end
  lines[#lines + 1] = ("**BLOCK %03d** The quick brown fox jumps over the lazy dog."):format(index)
  lines[#lines + 1] = ""
end
local markdown = table.concat(lines, "\n")

local function request(params, label, callback)
  local started = vim.uv.hrtime()
  process.request("render", params, function(result, err)
    local elapsed = (vim.uv.hrtime() - started) / 1e6
    callback(result, err, elapsed, label)
  end)
end

local base = {
  documentId = "first-frame",
  markdown = markdown,
  contentRevision = "1:0",
  viewport = { widthPx = 990, heightPx = 1020, deviceScaleFactor = cfg.render.device_scale_factor },
  theme = "dark",
  scrollY = 0,
  captureScale = "device",
  scrollPastEnd = cfg.render.scroll_past_end,
  scrollPastEndOffsetPx = cfg.render.scroll_past_end_offset_px,
  fontSizePx = cfg.render.font_size_px,
  browser = { executable_path = cfg.browser.executable_path, launch_timeout_ms = cfg.browser.launch_timeout_ms },
}

local report = {}
local failed = false

local function finish()
  print("")
  print("  " .. string.rep("-", 62))
  for _, line in ipairs(report) do
    print("  " .. line)
  end
  print("  " .. string.rep("-", 62))
  print("")
  process.stop({ blocking = true })
  vim.cmd(failed and "cq" or "qa!")
end

request(base, "first frame", function(result, err, elapsed)
  if not result then
    report[#report + 1] = "FAILED: " .. tostring(err)
    failed = true
    return finish()
  end
  local encoder = result.captureEncoder or "unknown"
  report[#report + 1] = ("first frame   %8.0f ms   capture %8.0f ms   %s"):format(
    elapsed,
    result.captureMs or 0,
    encoder
  )

  request(vim.tbl_extend("force", base, { scrollY = 400 }), "second", function(second, second_err, second_elapsed)
    if second then
      report[#report + 1] = ("second frame  %8.0f ms   capture %8.0f ms   %s"):format(
        second_elapsed,
        second.captureMs or 0,
        second.captureEncoder or "unknown"
      )
    else
      report[#report + 1] = "second frame FAILED: " .. tostring(second_err)
    end

    local region = vim.tbl_extend("force", base, { captureRegion = { yPx = 0, heightPx = 2040 } })
    request(region, "region", function(third, third_err, third_elapsed)
      if third then
        report[#report + 1] = ("region 2040   %8.0f ms   capture %8.0f ms   %s"):format(
          third_elapsed,
          third.captureMs or 0,
          third.captureEncoder or "unknown"
        )
        report[#report + 1] = ("region echoed y=%s h=%s"):format(
          tostring(third.regionYPx),
          tostring(third.regionHeightPx)
        )
      else
        report[#report + 1] = "region capture unavailable: " .. tostring(third_err)
      end

      report[#report + 1] = ""
      if encoder == "cdp_fast_png" then
        report[#report + 1] = "OK -- the fast path survived the first capture."
      else
        report[#report + 1] = "LOST -- the first capture fell back to " .. encoder .. "."
        report[#report + 1] = "render.scroll_scale does nothing on this path."
        failed = true
      end
      finish()
    end)
  end)
end)

vim.wait(180000, function() return false end, 200)
print("timed out waiting for the renderer")
vim.cmd("cq")
