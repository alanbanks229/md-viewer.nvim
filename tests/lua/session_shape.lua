-- The session-shape contract.
--
-- A session is a plain Lua table written directly by nine modules, and the
-- plan names the shape contract as the oracle a session accessor layer would
-- need before it could exist. This file is that oracle: every field the code
-- can put on a session, and which of ten questions it answers.
--
-- Two of the categories carry the distinction the plan singles out, because
-- getting them confused is what scroll bugs are made of:
--
--   screen  what is on the glass *right now*. `frame_scroll_y` is the scroll
--           the pixels currently painted were captured at.
--   target  what the screen should become, and what is in flight toward it.
--           `scroll_y` is where the reader asked to be; `applied_scroll_y` is
--           the scroll the last request was *issued* at. Neither is evidence
--           that anything was painted -- only `frame_scroll_y` is.
--
-- The set is enforced two ways, both from `tests/lua/run.lua`:
--
--   * every session created through `state.create` during the whole suite is
--     sampled at every assertion, and no field outside this manifest may ever
--     appear on one;
--   * every field marked `observed` must actually turn up on a session at
--     least once, so deleting one from production fails here rather than
--     silently narrowing the contract.
--
-- Fields not marked `observed` are real -- each one has a writer in `lua/` --
-- but no tracked session carried one at a sampling point. That is a coverage
-- statement, not a claim about dead code: most of them are animation and
-- fast-frame telemetry, which the cases that exercise it drive against
-- hand-rolled session tables rather than through `state.create`.

local M = {}

M.CATEGORIES = {
  identity = "which document this is, where it lives, and whether it is alive",
  screen = "what is on the glass right now",
  target = "what the screen should become, and what is in flight toward it",
  geometry = "measurements of the viewport, the document, and the cell",
  reader = "where the reader is: caret, selection, find, visual mode, source sync",
  visibility = "whether the image may be shown at all",
  timers = "debounce and libuv timer handles, closed together at teardown",
  loading = "the loading indicator's own window",
  model = "which rendering model is in force and what feeds it",
  diagnostics = "exists for :MdViewerDebug and nothing else",
}

-- field -> { category, observed = true when the suite sees it on a real
-- session }. Grouped by category for reading; the order is not meaningful.
local function fields(category, observed, names)
  local out = {}
  for _, name in ipairs(names) do
    out[name] = { category = category, observed = observed }
  end
  return out
end

M.FIELDS = {}
local function add(map)
  for name, spec in pairs(map) do
    assert(not M.FIELDS[name], "duplicate field in the session shape manifest: " .. name)
    M.FIELDS[name] = spec
  end
end

add(fields("identity", true, {
  "source_buf",
  "source_win",
  "document_id",
  "pane",
  "preview_buf",
  "preview_win",
  "active",
  "activation_epoch",
  "closed",
  "config",
}))

add(fields("screen", true, {
  "image_id",
  "frame_scroll_y",
  "frame_revision",
  "last_placement",
  "resident_screen",
  "last_image_bytes",
  "clean_image_bytes",
  "clean_image_revision",
  "clean_image_scale",
  "clean_image_scroll_y",
  "overlay_set",
  "caret_overlay_set",
  "base_selection_painted",
  "caret_tint",
  "local_viewport",
  "local_frame_confirmed",
  "local_last_presented_scroll_y",
}))
add(fields("screen", false, { "animation_set", "animation_assets" }))

add(fields("target", true, {
  "scroll_y",
  "applied_scroll_y",
  "request_serial",
  "applied_serial",
  "render_epoch",
  "renderer_revision",
  "content_render_in_flight",
  "scroll_render_in_flight",
  "scroll_render_pending",
  "refresh_deferred",
  "render_failed",
  "dirty",
  "remote_images_pending",
  "animation_geometry_incomplete",
}))
add(fields("target", false, { "animation_pending" }))

add(fields("geometry", true, {
  "document_height_px",
  "viewport_height_px",
  "viewport_width_px",
  "viewport_height_render_px",
  "viewport_cell_css_width_px",
  "viewport_cell_css_height_px",
  "viewport_cell_detail",
  "viewport_calibration_tier",
  "preview_width_cells",
  "preview_height_cells",
  "scroll_scale",
  "scroll_settle_ms",
}))

add(fields("reader", true, {
  "caret_rect",
  "caret_scroll_y",
  "caret_desired_x",
  "caret_index",
  "caret_index_revision",
  "caret_motion_inflight",
  "selection_active",
  "selection_content_revision",
  "selection_text_length",
  "visual_active",
  "visual_linewise",
  "visual_epoch",
  "find_active",
  "find_query",
  "find_match_count",
  "find_active_index",
  "pointer",
  "manual_scroll_until",
  "progress_basis",
  "last_progress_text",
  "last_source_block",
  "sync_guard",
}))
add(fields("reader", false, { "sync_echo", "pending_obsidian_anchor", "leaving_visual" }))

add(fields("visibility", true, { "occluded", "occluding_windows", "tabpage_hidden", "ui_suppressed" }))

add(fields("timers", true, {
  "render_timer",
  "resize_timer",
  "scroll_settle_timer",
  "cursor_scroll_timer",
  "selection_settle_timer",
  "ui_poll_timer",
  "loading_timer",
}))
add(fields("timers", false, {
  "animation_geometry_timer",
  "remote_image_timer",
  "selection_debounce_timer",
  "selection_idle_settle_timer",
}))

add(fields("loading", true, { "loading", "loading_win", "loading_buf", "loading_frame" }))

add(fields("model", true, {
  "backend",
  "backend_reason",
  "render_path",
  "render_path_reason",
  "resident",
  "resident_waiting",
  "latest_blocks",
  "latest_lines",
  "animation_geometry",
  "animation_generation",
}))
add(fields("model", false, { "render_path_demoted", "animation_strategy", "animation_suppressed_reason" }))

add(fields("diagnostics", true, {
  "coalesced_preview_events",
  "coalesced_scroll_events",
  "interaction_request_count",
  "interaction_stale_count",
  "last_capture_scale",
  "last_image_update_ms",
  "last_interaction_kind",
  "last_interaction_precision",
  "last_layout_reused",
  "last_markdown_reused",
  "last_png_bytes",
  "retina_bytes_total",
  "retina_frame_count",
  "retina_image_update_ms",
  "retina_png_bytes",
  "overlay_frames",
  "overlay_last_bytes",
  "overlay_last_ms",
  "overlay_rect_count",
  "local_marker_frames",
  "local_presented_count",
  "scroll_scale_source",
  "scroll_settle_source",
  "animation_geometry_unmeasured",
}))
add(fields("diagnostics", false, {
  "last_capture_ms",
  "last_capture_encoder",
  "last_layout_ms",
  "retina_capture_ms",
  "fast_bytes_total",
  "fast_capture_ms",
  "fast_frame_count",
  "fast_image_update_ms",
  "fast_interval_count",
  "fast_interval_min_ms",
  "fast_interval_sum_ms",
  "fast_last_ns",
  "fast_png_bytes",
  "overlay_last_error",
  "caret_overlay_error",
  "animation_ticks",
  "animation_last_bytes",
  "animation_last_error",
  "animation_asset_count",
}))

-- -- sampling ---------------------------------------------------------------

local tracked = setmetatable({}, { __mode = "k" })
local seen = {}

---Wrap `state.create` so every real session is sampled from here on. Idempotent.
function M.track()
  local state = require("md-viewer.state")
  if state._shape_tracked then return end
  local create = state.create
  state.create = function(...)
    local session = create(...)
    tracked[session] = true
    return session
  end
  state._shape_tracked = true
end

---Record the fields every tracked session carries at this instant. Called at
---every assertion, so a field that exists only between two lines of one
---handler is still seen. Closed sessions are sampled once more and then
---dropped: nothing writes to a session after it is released, and keeping them
---would make the sweep grow with the length of the suite.
function M.sample()
  for session in pairs(tracked) do
    for name in pairs(session) do
      seen[name] = true
    end
    if session.closed then tracked[session] = nil end
  end
end

function M.observed()
  local names = {}
  for name in pairs(seen) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

---Fields seen on a real session that the manifest does not describe.
function M.undeclared()
  local out = {}
  for _, name in ipairs(M.observed()) do
    if not M.FIELDS[name] then out[#out + 1] = name end
  end
  return out
end

---Fields the manifest says the suite observes that it did not.
function M.missing()
  local out = {}
  for name, spec in pairs(M.FIELDS) do
    if spec.observed and not seen[name] then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

return M
