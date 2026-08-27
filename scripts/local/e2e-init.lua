-- The remote half of scripts/local/live-pipeline-check.sh: an init file for
-- `nvim -u` inside a helper-wrapped ssh session. It opens the document nvim
-- was started on with `render.location = "local"`, waits for the local
-- render round trip and the injector's glass confirmations, scrolls once by
-- marker, writes the evidence as JSON where the driver can fetch it, and
-- quits. Not a test-suite file: it needs a live helper on the terminal side
-- and proves the pipeline against real ssh, a real sshd forward, and a real
-- browser beside the terminal.

vim.opt.runtimepath:prepend(vim.fn.expand("~/md-viewer.nvim"))
local evidence_path = vim.fn.expand("~/mdv-e2e.json")
pcall(vim.fn.delete, evidence_path)

require("md-viewer").setup({
  render = { location = "local" },
  -- Forced: the driver runs this inside tmux, where no terminal identity
  -- survives; the marker path itself is terminal-agnostic bytes.
  terminal = { profile = "kitty" },
})

local function write_evidence(extra)
  local localrender = require("md-viewer.localrender")
  local marker = require("md-viewer.backends.kitty_marker")
  local state = require("md-viewer.state")
  local sessions = {}
  for _, session in pairs(state.all()) do
    sessions[#sessions + 1] = {
      render_path = session.render_path,
      render_path_reason = session.render_path_reason,
      backend = session.backend and session.backend.name,
      document_height_px = session.document_height_px,
      scroll_y = session.scroll_y,
      applied_scroll_y = session.applied_scroll_y,
      local_marker_frames = session.local_marker_frames or 0,
      local_presented_count = session.local_presented_count or 0,
      renderer_revision = session.renderer_revision,
    }
  end
  local handle = io.open(evidence_path, "w")
  if not handle then return end
  handle:write(vim.json.encode({
    status = localrender.status(),
    markers = marker.stats(),
    sessions = sessions,
    extra = extra or {},
    -- Provenance: which module answered, and what the attach gate saw. A
    -- wrong rtp winning the require is indistinguishable from a logic bug
    -- without these.
    debug_enabled = localrender.enabled(),
    debug_location = require("md-viewer.config").get().render.location,
    debug_controller_src = debug.getinfo(require("md-viewer.controller").open, "S").source,
    debug_notifications = _G.mdv_e2e_notifications,
  }))
  handle:close()
end

_G.mdv_e2e_notifications = {}
local real_notify = vim.notify
vim.notify = function(msg, level, opts)
  table.insert(_G.mdv_e2e_notifications, tostring(msg))
  return real_notify(msg, level, opts)
end

vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    vim.schedule(function()
      local controller = require("md-viewer.controller")
      local session = controller.open("right")
      if not session then
        write_evidence({ failed = "controller.open returned nothing" })
        vim.cmd("qa!")
        return
      end
      local deadline = vim.uv.now() + 60000
      local scrolled = false
      local timer = vim.uv.new_timer()
      timer:start(
        500,
        500,
        vim.schedule_wrap(function()
          local rendered = (session.document_height_px or 0) > 0
          local presented = session.local_presented_count or 0
          if rendered and presented >= 1 and not scrolled then
            -- The first frame reached the glass; now prove a scroll is one
            -- marker resolved beside the terminal.
            scrolled = true
            controller.navigate(session, "half_down")
            return
          end
          local done = scrolled and presented >= 2
          local timed_out = vim.uv.now() > deadline
          if done or timed_out then
            timer:stop()
            timer:close()
            write_evidence({ timed_out = timed_out })
            vim.cmd("qa!")
          end
        end)
      )
    end)
  end,
})
