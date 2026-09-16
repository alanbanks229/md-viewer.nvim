-- The static half of the session shape contract. The cross-case half -- that
-- no real session ever carries a field outside the manifest, and that every
-- field the manifest claims is observed really is -- lives in
-- `tests/lua/run.lua`, because only a whole run can assert it.

return function(t)
  -- Located through the runtimepath rather than the working directory, so
  -- this reads the same checkout the suite is running from wherever it is
  -- invoked.
  local state_path = assert(vim.api.nvim_get_runtime_file("lua/md-viewer/state.lua", false)[1])
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(state_path)))
  local shape = dofile(vim.fs.joinpath(root, "tests/lua/session_shape.lua"))
  local state = require("md-viewer.state")

  -- -- the manifest is well formed ---------------------------------------

  local by_category = {}
  for name, spec in pairs(shape.FIELDS) do
    t.ok(shape.CATEGORIES[spec.category], ("%s is in a category the manifest documents"):format(name))
    by_category[spec.category] = by_category[spec.category] or {}
    table.insert(by_category[spec.category], name)
  end
  for category in pairs(shape.CATEGORIES) do
    t.ok(by_category[category], ("the %s category has at least one field"):format(category))
  end

  -- -- what the constructor actually creates ------------------------------

  -- `state.create`'s table literal is 57 lines of field names, and 18 of them
  -- assign `nil`. Lua stores no key for those, so `pairs()` never sees them
  -- and neither does anything asserting the session's shape: they are
  -- documentation of intent, not declarations. Both halves are pinned here,
  -- separately, because the difference is the whole reason a shape contract
  -- has to be written down rather than read off the constructor.
  local session = state.create(9701, 1)
  local created = {}
  for name in pairs(session) do
    created[#created + 1] = name
  end
  table.sort(created)

  t.eq({
    "active",
    "applied_scroll_y",
    "applied_serial",
    "closed",
    "coalesced_preview_events",
    "config",
    "content_render_in_flight",
    "document_height_px",
    "document_id",
    "find_active",
    "find_match_count",
    "interaction_request_count",
    "interaction_stale_count",
    "lane_epoch",
    "lanes",
    "latest_blocks",
    "latest_lines",
    "loading",
    "loading_frame",
    "manual_scroll_until",
    "occluded",
    "occluding_windows",
    "pane",
    "progress_basis",
    "refresh_deferred",
    "render_epoch",
    "render_failed",
    "request_serial",
    "resident_screen",
    "scroll_render_in_flight",
    "scroll_render_pending",
    "scroll_y",
    "selection_active",
    "source_buf",
    "source_win",
    "sync_guard",
    "tabpage_hidden",
    "ui_suppressed",
    "viewport_height_px",
    "visual_active",
    "visual_linewise",
  }, created, "state.create creates exactly these keys")

  for _, name in ipairs(created) do
    t.ok(shape.FIELDS[name], ("the constructor's %s is in the manifest"):format(name))
  end

  -- The nil-assigned names, read out of the constructor itself so that adding
  -- one is caught here rather than being quietly absorbed.
  local source = table.concat(vim.fn.readfile(state_path), "\n")
  local literal = source:match("function M%.create.-\n(.-)\n%s*next_pane_id = next_pane_id %+ 1")
  t.ok(literal ~= nil, "the session literal can still be located in state.lua")
  local documented_nil = {}
  for name in (literal or ""):gmatch("\n%s+([%a_]+) = nil,") do
    documented_nil[#documented_nil + 1] = name
  end
  table.sort(documented_nil)
  t.ok(#documented_nil > 20, "the constructor documents a substantial set of fields as nil")

  for _, name in ipairs(documented_nil) do
    t.eq(nil, session[name], ("%s is documented as nil, so the constructor creates no key for it"):format(name))
    t.ok(shape.FIELDS[name], ("the nil-documented %s is still in the manifest"):format(name))
  end

  state.remove_document(session)
  state.remove_pane(session.pane)

  -- -- screen versus target ------------------------------------------------

  -- The distinction the plan singles out. `scroll_y` is where the reader asked
  -- to be and `applied_scroll_y` is the scroll the last request went out at;
  -- neither is evidence that a pixel was painted. Only `frame_scroll_y` is,
  -- and it is the field the resident bootstrap and `caret.rect` ask, because
  -- both of them mean "the picture currently on the glass".
  table.sort(by_category.screen)
  t.eq({
    "animation_assets",
    "animation_set",
    "base_selection_painted",
    "caret_overlay_set",
    "caret_tint",
    "clean_image_bytes",
    "clean_image_revision",
    "clean_image_scale",
    "clean_image_scroll_y",
    "frame_revision",
    "frame_scroll_y",
    "image_id",
    "last_image_bytes",
    "last_placement",
    "local_frame_confirmed",
    "local_last_presented_scroll_y",
    "local_viewport",
    "overlay_set",
    "resident_screen",
  }, by_category.screen, "the fields that describe what is on the glass")

  table.sort(by_category.target)
  t.eq({
    "animation_geometry_incomplete",
    "animation_pending",
    "applied_scroll_y",
    "applied_serial",
    "content_render_in_flight",
    "dirty",
    "lane_epoch",
    "lanes",
    "refresh_deferred",
    "remote_images_pending",
    "render_epoch",
    "render_failed",
    "renderer_revision",
    "request_serial",
    "scroll_render_in_flight",
    "scroll_render_pending",
    "scroll_y",
  }, by_category.target, "the fields that describe what the screen should become")

  -- -- coverage -------------------------------------------------------------

  local unobserved = {}
  for name, spec in pairs(shape.FIELDS) do
    if not spec.observed then unobserved[#unobserved + 1] = name end
  end
  t.ok(
    #unobserved < #created,
    "most of the session's surface is exercised: fewer fields go unobserved than the constructor creates"
  )
end
