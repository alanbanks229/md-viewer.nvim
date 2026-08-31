-- Does an unreachable remote image still cost the whole preview?
--
-- What it proves: how long the *document* takes to appear when it contains an
-- https image this host cannot fetch. Before v0.2.0 that was the renderer's
-- full 20-second timeout, paid before anything was drawn, because remote
-- images resolved in a pre-pass between parse and render. Nothing waits now:
-- the image renders as its placeholder, the fetch continues in the renderer's
-- module cache, and a later render picks it up if it ever lands.
--
-- Why it cannot be answered on the machine this was written on: the failure
-- needs a network where the connection cannot complete. `remote-images.js`
-- pins the address it validated and deliberately never consults `HTTP_PROXY`
-- (that pinning is what makes the SSRF check meaningful), so a network whose
-- only route out is a proxy is exactly the shape that reproduces it -- and is
-- the shape a developer machine does not have.
--
-- What it needs: nothing open. It creates its own scratch documents, opens a
-- preview on each in turn, and closes them again.
--
-- How to run it, from inside Neovim:
--
--     :runtime scripts/remote-images/probe.lua
--     :RemoteImageProbe
--
-- Reads the result off `:MdViewerDebug`'s own fields, so anything it reports
-- can be confirmed by hand afterwards.

local config = require("md-viewer.config")
local state = require("md-viewer.state")
local controller = require("md-viewer.controller")

-- A real, public, small PNG that also exercises the redirect path GitHub
-- attachment URLs take (github.com -> avatars.githubusercontent.com), since
-- every hop is re-checked against the destination blocklist. GitHub's own
-- account rather than anyone's in particular: the probe needs the redirect, not
-- an identity. Change it if this host reaches the internet by some route that
-- does not include GitHub.
local IMAGE_URL = "https://github.com/github.png"

-- The renderer remembers a failure for NEGATIVE_TTL_MS (60s) and a success for
-- as long as the cache holds it, so a second run would measure the cache
-- rather than the network. A unique query per run makes each probe a genuine
-- fetch; the blocklist does not care about the query string.
local function fresh_url() return ("%s?md-viewer-probe=%d"):format(IMAGE_URL, vim.uv.hrtime() % 1000000) end

local BODY = table.concat({
  "# Remote image probe",
  "",
  "Body text above the image, so the document has something to draw that does",
  "not depend on the network at all. If the preview is working the way v0.2.0",
  "claims, this paragraph appears immediately whether or not the image below",
  "ever arrives.",
  "",
}, "\n")

local function write_doc(name, lines)
  local path = ("%s/%s"):format(vim.fn.tempname(), name)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(vim.split(lines, "\n", { plain = true }), path)
  return path
end

---Open a preview on `path`, and answer with how long the first frame took.
---
---Timed from the moment the preview is opened rather than from the render
---request, because "how long until I see the document" is the question, and a
---reader waiting on a blocked fetch is not interested in which of the stages
---in front of it was responsible.
local function measure(path, label, done)
  local doc = vim.fn.bufadd(path)
  vim.fn.bufload(doc)
  vim.api.nvim_set_current_buf(doc)
  local started = vim.uv.hrtime()
  controller.open()

  local deadline = started + 60 * 1e9
  local timer = vim.uv.new_timer()
  timer:start(
    20,
    20,
    vim.schedule_wrap(function()
      local session = state.get(doc)
      local landed = session and session.image_id and session.renderer_revision
      if not landed and vim.uv.hrtime() < deadline then return end
      timer:stop()
      timer:close()
      local elapsed = (vim.uv.hrtime() - started) / 1e6
      local result = {
        label = label,
        first_frame_ms = landed and elapsed or nil,
        pending = session and session.remote_images_pending or false,
        png_bytes = session and session.last_png_bytes,
      }
      if session then controller.close(doc) end
      pcall(vim.api.nvim_buf_delete, doc, { force = true })
      done(result)
    end)
  )
end

local function ms(value) return value and ("%.0f ms"):format(value) or "never appeared" end

local function report(control, blocked_probe)
  local lines = {
    "",
    "== remote-image probe ==",
    "",
    ("%-34s %14s %10s"):format("", "first frame", "still fetching"),
    ("%-34s %14s %10s"):format("no images at all (control)", ms(control.first_frame_ms), tostring(control.pending)),
    ("%-34s %14s %10s"):format("one remote image", ms(blocked_probe.first_frame_ms), tostring(blocked_probe.pending)),
    "",
  }

  local control_ms = control.first_frame_ms
  local probe_ms = blocked_probe.first_frame_ms

  if not probe_ms then
    lines[#lines + 1] = "VERDICT: the document never appeared at all within 60 s. That is worse than the"
    lines[#lines + 1] = "behaviour this release claims to fix -- capture :MdViewerDebug and report it."
  elseif probe_ms >= 15000 then
    lines[#lines + 1] = ("VERDICT: FAIL. The document took %s, which is the renderer's 20 s fetch"):format(ms(probe_ms))
    lines[#lines + 1] = "timeout being paid before anything was drawn -- the exact behaviour v0.2.0"
    lines[#lines + 1] = "removes. Something is still waiting on the fetch."
  elseif control_ms and probe_ms > control_ms * 3 + 2000 then
    lines[#lines + 1] = ("VERDICT: SUSPECT. %s against %s with no images is a bigger gap than a"):format(
      ms(probe_ms),
      ms(control_ms)
    )
    lines[#lines + 1] = "placeholder should cost. Not the 20 s stall, but worth reporting."
  else
    lines[#lines + 1] = ("VERDICT: PASS. The document appeared in %s, against %s for a document"):format(
      ms(probe_ms),
      ms(control_ms)
    )
    lines[#lines + 1] = "with no images at all. Nothing waited for the network."
  end

  lines[#lines + 1] = ""
  if blocked_probe.pending then
    lines[#lines + 1] = "`remote_images_pending` is true: the fetch is still running and the preview"
    lines[#lines + 1] = "will re-render on its own if it lands. On a network that cannot reach the"
    lines[#lines + 1] = "host this is the expected steady state -- the image stays a placeholder."
  else
    lines[#lines + 1] = "`remote_images_pending` is false: the fetch had already settled. Either this"
    lines[#lines + 1] = "host can reach the image (look at the preview -- is the picture there?), or"
    lines[#lines + 1] = "it failed fast, which a refused connection does."
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Remote images do not load behind a mandatory proxy and are not meant to."
  lines[#lines + 1] = 'See docs/troubleshooting.md, "Remote images never load, and the network'
  lines[#lines + 1] = 'needs a proxy" -- what this measures is the stall, not the picture.'

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

vim.api.nvim_create_user_command("RemoteImageProbe", function()
  if config.get().render.local_images == false then
    vim.notify("md-viewer: this probe needs render.local_images left on", vim.log.levels.WARN)
    return
  end
  local control_doc = write_doc("probe-control.md", BODY)
  local image_doc = write_doc("probe-image.md", ("%s\n![a remote image](%s)\n"):format(BODY, fresh_url()))
  vim.notify("md-viewer: probing... (up to a minute if something is genuinely stalling)", vim.log.levels.INFO)
  measure(control_doc, "control", function(control)
    measure(image_doc, "remote image", function(probe) report(control, probe) end)
  end)
end, {})

vim.notify("md-viewer: run :RemoteImageProbe", vim.log.levels.INFO)
