local state = require("md-viewer.state")
local process = require("md-viewer.process")
local backends = require("md-viewer.backends")
local terminal = require("md-viewer.terminal")
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
      viewport_height_px = session.viewport_height_render_px,
      viewport_calibration_tier = session.viewport_calibration_tier,
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
    }
  end
  return {
    sessions = sessions,
    interaction_enabled = config.get().interaction.enabled,
    -- The last link md-viewer handed to the operating system, and what came
    -- back. This is the difference between "the click never reached the
    -- plugin" and "the plugin ran the handler and the OS declined".
    last_external_open = require("md-viewer.interaction").last_external or "none",
    renderer = process.status(),
    backends = backends.health(),
    terminal = terminal.detect(),
    events = M.events,
  }
end

function M.show()
  local lines = vim.split(vim.inspect(M.snapshot()), "\n", { plain = true })
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, "md-viewer://debug")
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "lua"
end

return M
