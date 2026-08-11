local state = require("md-viewer.state")
local process = require("md-viewer.process")
local config = require("md-viewer.config")

local M = { events = {} }

function M.log(event, data)
  M.events[#M.events + 1] = { time = os.date("!%Y-%m-%dT%H:%M:%SZ"), event = event, data = data }
  if #M.events > 200 then table.remove(M.events, 1) end
end

function M.snapshot()
  local sessions = {}
  for buf, session in pairs(state.all()) do
    sessions[tostring(buf)] = {
      source_win = session.source_win,
      preview_buf = session.preview_buf,
      preview_win = session.preview_win,
      backend = session.backend and session.backend.name,
      image_id = session.image_id,
      requested = session.request_serial,
      applied = session.applied_serial,
      scroll_y = session.scroll_y,
      document_height_px = session.document_height_px,
      applied_scroll_y = session.applied_scroll_y,
      layout_reused = session.last_layout_reused,
      markdown_reused = session.last_markdown_reused,
      capture_scale = session.last_capture_scale,
      capture_encoder = session.last_capture_encoder,
      png_bytes = session.last_png_bytes,
      layout_ms = session.last_layout_ms,
      capture_ms = session.last_capture_ms,
      image_update_ms = session.last_image_update_ms,
      fast_png_bytes = session.fast_png_bytes,
      fast_capture_ms = session.fast_capture_ms,
      fast_image_update_ms = session.fast_image_update_ms,
      retina_png_bytes = session.retina_png_bytes,
      retina_capture_ms = session.retina_capture_ms,
      retina_image_update_ms = session.retina_image_update_ms,
      coalesced_scroll_events = session.coalesced_scroll_events or 0,
      viewport_width_px = session.viewport_width_px,
      -- How many animated images the last render *measured*, beside how many
      -- became assets. Without the first number a document whose geometry pass
      -- timed out reads exactly like a document with no animated images in it
      -- at all -- which is how that failure stayed invisible for so long. A
      -- count here with `animation_count = 0` means the rects never arrived;
      -- `incomplete` means the renderer is still trying to measure them.
      animation_geometry_count = session.animation_geometry and #session.animation_geometry or 0,
      animation_geometry_incomplete = session.animation_geometry_incomplete or false,
      animation_count = session.animation_assets and vim.tbl_count(session.animation_assets) or 0,
      animation_strategy = session.animation_strategy,
      animation_assets = (function()
        if not session.animation_assets then return nil end
        local lines = {}
        for id, asset in pairs(session.animation_assets) do
          lines[#lines + 1] = ("%s %s %dx%d %s%s"):format(
            id,
            asset.strategy,
            asset.target_w,
            asset.target_h,
            asset.refused and ("refused: " .. asset.refused)
              or (asset.frames and (asset.strategy == "native" and (asset.native_ready and "playing" or "uploading") or (#asset.frames .. " frames")))
              or "materializing",
            asset.decode_ms and (" (decoded in " .. asset.decode_ms .. "ms)") or ""
          )
        end
        table.sort(lines)
        return lines
      end)(),
      animation_ticks = session.animation_ticks,
      animation_last_bytes = session.animation_last_bytes,
      animation_last_error = session.animation_last_error,
      animation_suppressed_reason = session.animation_suppressed_reason,
      viewport_height_px = session.viewport_height_render_px,
      viewport_calibration_tier = session.viewport_calibration_tier,
      -- The cell this render was sized against, so the tier above can be
      -- checked rather than trusted: `viewport_width_px` should be
      -- `preview_width_cells` times this. nil on the estimated tier, where no
      -- exact cell exists and the aspect ratio stands in for one.
      viewport_cell_css_px = session.viewport_cell_css_width_px and require("md-viewer.coordinates").describe_cell(
        session.viewport_cell_css_width_px,
        session.viewport_cell_css_height_px,
        session.viewport_cell_detail
      ),
      preview_width_cells = session.preview_width_cells,
      preview_height_cells = session.preview_height_cells,
      occluded = session.occluded,
      occluding_windows = session.occluding_windows,
      -- Why an otherwise healthy session is showing nothing: the preview
      -- window is parked on a tabpage the terminal is not displaying.
      tabpage_hidden = session.tabpage_hidden or false,
      refresh_deferred = session.refresh_deferred or false,
      ui_suppressed = session.ui_suppressed,
      ui_polling = session.ui_poll_timer ~= nil,
      placement = session.last_placement,
      passive_cutouts = session.last_placement and #(session.last_placement.exclusions or {}) or 0,
      loading = session.loading,
      render_failed = session.render_failed,
      -- Current content revision this session's cached frame/interaction state
      -- is pinned to (renderer.lua's "changedtick:render_epoch" string) -- what
      -- a stale-interaction error is measured against.
      content_revision = session.renderer_revision,
      interaction_last_kind = session.last_interaction_kind,
      interaction_last_precision = session.last_interaction_precision,
      interaction_pointer_pressed = session.pointer ~= nil and session.pointer.pressed or false,
      -- Where this preview sits in the documents it has followed links
      -- through. Counts and an index only: no paths, which the winbar already
      -- shows for the one that matters.
      history_length = session.history and #session.history or 0,
      history_index = session.history_index or 0,
      selection_active = session.selection_active,
      -- Length only -- see interaction.lua's copy_selection comment. Never
      -- surface the selected text itself in diagnostics.
      selection_text_length = session.selection_text_length,
      find_active = session.find_active,
      find_query = session.find_query,
      find_match_count = session.find_match_count,
      find_active_index = session.find_active_index,
      interaction_request_count = session.interaction_request_count or 0,
      interaction_stale_count = session.interaction_stale_count or 0,
      coalesced_drag_events = session.coalesced_drag_events or 0,
      -- Drag overlay: whether rectangles are on screen right now, and
      -- what the last overlay frame cost. `overlay_last_bytes` is the byte
      -- count actually written to the terminal for that frame -- the number
      -- that replaced ~1MB of base64 PNG per moving frame.
      overlay_active = session.overlay_set ~= nil,
      overlay_rect_count = session.overlay_rect_count or 0,
      overlay_frames = session.overlay_frames or 0,
      overlay_last_bytes = session.overlay_last_bytes,
      overlay_last_ms = session.overlay_last_ms,
      overlay_last_error = session.overlay_last_error,
    }
  end
  -- `renderer`, `backends` and `terminal` used to be dumped here as well.
  -- They are the machine's capabilities, not this preview's behaviour, and
  -- health.environment_lines() now renders exactly the same data above the
  -- snapshot -- reporting a fact twice in one buffer only invites the reader
  -- to wonder which copy is stale.
  return {
    sessions = sessions,
    -- The last link md-viewer handed to the operating system, and what came
    -- back. This is the difference between "the click never reached the
    -- plugin" and "the plugin ran the handler and the OS declined".
    last_external_open = require("md-viewer.interaction").last_external or "none",
    events = M.events,
  }
end

---The one complete diagnostic artifact: what this machine can do, followed by
---what the running previews are actually doing with it.
---
---Both halves are needed to explain almost any real report, and while they
---lived in two separate commands every bug report arrived with one of them.
---Round-trips to the renderer for the same reason `:MdViewerHealth` does: the
---Chromium path and launch result are only trustworthy when the subprocess
---itself answers for them.
function M.show()
  local health = require("md-viewer.health")
  process.request("health", { browser = config.get().browser }, function(result, err)
    local lines = { "md-viewer.nvim debug", ("="):rep(20) }
    vim.list_extend(lines, health.environment_lines(health.collect(result, err)))
    -- The renderer has always computed and sent these counters; nothing read
    -- them, so decode failures, refusals and frame-store evictions were
    -- invisible on this side while being one field away the whole time.
    if type(result) == "table" and type(result.animationStore) == "table" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "-- Renderer animation store --"
      vim.list_extend(lines, vim.split(vim.inspect(result.animationStore), "\n", { plain = true }))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "-- Sessions & Events --"
    vim.list_extend(lines, vim.split(vim.inspect(M.snapshot()), "\n", { plain = true }))

    vim.cmd("botright new")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, "md-viewer://debug")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "md-viewer-debug"
  end)
end

return M
