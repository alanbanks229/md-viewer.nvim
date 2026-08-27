-- The remote half of scripts/local/live-pipeline-check.sh: an init file for
-- `nvim -u` inside a helper-wrapped ssh session. It opens the document nvim
-- was started on with `render.location = "local"`, waits for the local
-- render round trip and the injector's glass confirmations, scrolls once by
-- marker, then runs the K4 workload -- a held-key-shaped burst of line
-- scrolls at 25ms intervals, every position distinct so the surface cache
-- cannot answer for the capture path -- lets it settle, pulls the helper's
-- own stage timings over the socket, writes the evidence as JSON where the
-- driver can fetch it, and quits. Not a test-suite file: it needs a live
-- helper on the terminal side and proves the pipeline against real ssh, a
-- real sshd forward, and a real browser beside the terminal.

-- The plugin root is wherever this script lives -- an rsync'd checkout on a
-- rig host, a lazy.nvim install dir on a real one. Hardcoding either breaks
-- the other.
local this_file = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(this_file)))
vim.opt.runtimepath:prepend(plugin_root)
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
      scroll_scale = session.scroll_scale,
      scroll_scale_source = session.scroll_scale_source,
      scroll_settle_ms = session.scroll_settle_ms,
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
      local deadline = vim.uv.now() + 90000
      local scrolled = false
      local BURST_STEPS = 30
      local burst_sent = 0
      local burst_done_at = nil
      local burst_timer = nil
      local collecting = false

      local function collect_and_quit(timed_out)
        if collecting then return end
        collecting = true
        local extra = {
          timed_out = timed_out,
          burst_steps = burst_sent,
          presented_after_burst = session.local_presented_count or 0,
        }
        -- The helper's half of K4 rides the same health round trip the
        -- diagnostics use: replica capture counters/timings plus the
        -- injector's frame time-to-inject, none of which the remote can
        -- measure for itself.
        local answered = false
        require("md-viewer.process").request(
          "health",
          { browser = require("md-viewer.config").get().browser },
          function(result)
            answered = true
            if type(result) == "table" then
              extra.helper = result.localHelper
              extra.replica = result.replica
            end
            write_evidence(extra)
            vim.cmd("qa!")
          end
        )
        vim.defer_fn(function()
          if answered then return end
          extra.helper_health_timed_out = true
          write_evidence(extra)
          vim.cmd("qa!")
        end, 15000)
      end

      local function start_burst()
        burst_timer = vim.uv.new_timer()
        burst_timer:start(
          0,
          25,
          vim.schedule_wrap(function()
            if burst_sent >= BURST_STEPS then
              if burst_timer then
                burst_timer:stop()
                burst_timer:close()
                burst_timer = nil
                burst_done_at = vim.uv.now()
              end
              return
            end
            burst_sent = burst_sent + 1
            controller.navigate(session, "line_down")
          end)
        )
      end

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
          if scrolled and presented >= 2 and burst_sent == 0 and not burst_timer then
            start_burst()
            return
          end
          local timed_out = vim.uv.now() > deadline
          -- Three seconds of quiet after the last burst step covers the
          -- settle re-reference and its capture on any host this runs on.
          local settled = burst_done_at ~= nil and vim.uv.now() > burst_done_at + 3000
          if settled or timed_out then
            timer:stop()
            timer:close()
            collect_and_quit(timed_out)
          end
        end)
      )
    end)
  end,
})
