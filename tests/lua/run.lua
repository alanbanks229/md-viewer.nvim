local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script)))
vim.opt.runtimepath:prepend(root)
vim.opt.shadafile = "NONE"

local t = dofile(root .. "/tests/lua/harness.lua")

local config = require("md-viewer.config")
config.reset()
local cfg = config.setup({ split = { width = 0.4 }, image = { backend = "cells" } })
t.eq(0.4, cfg.split.width, "configuration override")
t.eq(45, cfg.split.min_width, "configuration deep merge")
t.eq(false, cfg.security.network, "network default")
t.eq(true, cfg.preview.pinned, "preview remains pinned by default")
t.eq(true, cfg.preview.loading, "graphical preview loading indicator default")
t.eq(80, cfg.preview.loading_interval_ms, "loading indicator animation interval")
t.eq(true, cfg.sync.mouse_scroll, "preview mouse scrolling default")
t.eq(true, cfg.render.scroll_past_end, "preview scrolls past its last block")
t.eq(true, cfg.render.fast_scroll, "fast scroll capture default")
t.eq(nil, cfg.render.fast_scroll_fps, "scroll captures have no artificial FPS cap")
t.eq(-1, cfg.image.raw_zindex, "raw graphics stay beneath terminal text")
t.eq(1, cfg.image.raw_statusline_guard_cells, "raw graphics reserve a statusline boundary cell")
t.eq(50, cfg.image.ui_poll_ms, "raw previews poll for no-autocmd floating UI")

local backends = require("md-viewer.backends")
local backend = assert(backends.select("cells"))
t.eq("cells", backend.name, "explicit cells")
local unavailable = select(1, backends.select("nvim_img"))
t.eq(nil, unavailable, "missing vim.ui.img is actionable")

local coords = require("md-viewer.coordinates")
local viewport = coords.viewport({ width = 80, height = 30 }, cfg.render)
t.ok(viewport.widthPx <= cfg.render.max_width_px, "bounded viewport width")
t.ok(viewport.heightPx <= cfg.render.max_height_px, "bounded viewport height")
t.eq(false, viewport.calibrated, "uncalibrated viewport is labeled")
t.ok(coords.same({ row = 1, col = 2, width = 3, height = 4 }, { row = 1, col = 2, width = 3, height = 4 }), "coordinate equality")
t.eq(false, coords.same(
  { row = 1, col = 2, width = 3, height = 4, exclusions = { { row = 1, col = 2, width = 1, height = 1 } } },
  { row = 1, col = 2, width = 3, height = 4 }), "placement equality includes overlay cutouts")

local raw_backend = require("md-viewer.backends.kitty_raw")
local original_ui_send = vim.api.nvim_ui_send
local graphics_sequences = {}
vim.api.nvim_ui_send = function(value) graphics_sequences[#graphics_sequences + 1] = value end
local fake_png = "\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\0\100\0\0\0\100"
local raw_id = raw_backend.show(fake_png, {
  row = 0, col = 0, width = 10, height = 10,
  exclusions = { { row = 2, col = 2, width = 4, height = 4 } },
})
local graphics_output = table.concat(graphics_sequences)
t.ok(graphics_output:find("a=t,f=100", 1, true), "raw image uploads independently of placements")
local _, cropped_placements = graphics_output:gsub("\27_Ga=p", "")
t.eq(4, cropped_placements, "one passive overlay cuts the preview into four placements")
graphics_sequences = {}
raw_backend.move(raw_id, { row = 0, col = 0, width = 10, height = 10, exclusions = {} })
graphics_output = table.concat(graphics_sequences)
t.ok(graphics_output:find("a=d,d=i", 1, true), "moving deletes only owned placement IDs")
local _, restored_placements = graphics_output:gsub("\27_Ga=p", "")
t.eq(1, restored_placements, "removing the overlay restores one full placement")
raw_backend.clear(raw_id)
vim.api.nvim_ui_send = original_ui_send

local protocol = require("md-viewer.protocol")
local decoded = assert(protocol.decode('{"id":2,"ok":true,"result":{}}'))
t.eq(2, decoded.id, "valid renderer response")
local invalid, decode_error = protocol.decode("not-json")
t.eq(nil, invalid, "invalid renderer response rejected")
t.ok(decode_error:match("invalid renderer JSON"), "invalid response reason")

local sync = require("md-viewer.sync")
local blocks = { { sourceStart = 0, sourceEnd = 3, topPx = 0, bottomPx = 100 },
  { sourceStart = 3, sourceEnd = 6, topPx = 100, bottomPx = 250 } }
t.eq(blocks[2], sync.block_for_line(blocks, 5), "source-map block lookup")
local nested = { { sourceStart = 0, sourceEnd = 10, topPx = 0, bottomPx = 400 },
  { sourceStart = 3, sourceEnd = 5, topPx = 120, bottomPx = 190 } }
t.eq(nested[2], sync.block_for_line(nested, 4), "most specific source-map block wins")
t.eq(155, sync.block_target(nested[2], 5), "relative line position within block")
t.eq(0, sync.scroll_for_block(blocks[1], 200, 500), "scroll clamp")

local renderer = require("md-viewer.renderer")
t.eq(true, renderer.is_stale({ closed = false, request_serial = 3 }, 2), "stale response rejection")
t.eq(false, renderer.is_stale({ closed = false, request_serial = 3 }, 3), "latest response acceptance")

local state = require("md-viewer.state")
local first = state.create(101, 201)
local second = state.create(102, 202)
t.eq(first, state.get(101), "first buffer state")
t.eq(second, state.get(102), "second buffer state")
state.remove(101); state.remove(102)
t.eq(nil, state.get(101), "buffer state cleanup")

local debounce = require("md-viewer.debounce")
local holder, calls = {}, 0
debounce.call(holder, "timer", 5, function() calls = calls + 1 end)
debounce.call(holder, "timer", 5, function() calls = calls + 1 end)
vim.wait(100, function() return calls == 1 end)
t.eq(1, calls, "debounce coalesces callbacks")
debounce.close(holder, "timer")

-- Real split/buffer lifecycle using the always-available backend.
require("md-viewer").setup({ image = { backend = "cells" } })
local source = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source)
vim.bo[source].filetype = "markdown"
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# One", "", "body" })
local controller = require("md-viewer.controller")
local session = assert(controller.open("right"))
t.ok(vim.api.nvim_win_is_valid(session.preview_win), "preview opens in a real split")
t.eq("nofile", vim.bo[session.preview_buf].buftype, "preview scratch buffer")
t.eq(false, vim.bo[session.preview_buf].modifiable, "preview is read-only")
local winbar = vim.api.nvim_get_option_value("winbar", { win = session.preview_win })
t.ok(winbar:match("No Name"), "preview winbar names its source document")
local placement = coords.for_window(session.preview_win)
t.eq(vim.api.nvim_win_get_width(session.preview_win), placement.width, "real split coordinate width")
t.eq(vim.api.nvim_win_get_height(session.preview_win), placement.height, "real split coordinate height")
t.eq(true, placement.winbar, "image placement accounts for preview winbar")
t.ok(placement.row > placement.window_row, "image starts below preview winbar")

local preview = require("md-viewer.preview")
local raw_placement = preview.placement(session.preview_win, "kitty_raw")
t.eq(placement.height - 1, raw_placement.height, "raw placement keeps one row above the statusline")
t.eq(1, raw_placement.statusline_guard_cells, "raw placement reports its dynamic statusline guard")
preview.start_loading(session)
t.eq(true, session.loading, "startup indicator is active before the first graphical frame")
t.ok(vim.api.nvim_win_is_valid(session.loading_win), "startup indicator uses a real floating window")
local loading_config = vim.api.nvim_win_get_config(session.loading_win)
t.eq("win", loading_config.relative, "startup indicator is local to the preview split")
t.eq(false, loading_config.focusable, "startup indicator cannot steal focus")
local first_loading_line = vim.api.nvim_buf_get_lines(session.loading_buf, 0, 1, false)[1]
t.ok(first_loading_line:match("Rendering Markdown"), "startup indicator explains renderer activity")
vim.wait(300, function()
  local line = vim.api.nvim_buf_get_lines(session.loading_buf, 0, 1, false)[1]
  return line ~= first_loading_line
end)
local next_loading_line = vim.api.nvim_buf_get_lines(session.loading_buf, 0, 1, false)[1]
t.ok(next_loading_line ~= first_loading_line, "startup indicator animates")
preview.stop_loading(session)
t.eq(false, session.loading, "startup indicator stops before image display")
t.eq(nil, session.loading_win, "startup indicator window is cleaned up")
local original_backend = session.backend
local cleared_images, restored_images = 0, 0
session.backend = {
  name = "kitty_raw",
  clear = function() cleared_images = cleared_images + 1; return true end,
  show = function(bytes)
    t.eq("cached-png", bytes, "float restoration reuses the cached PNG")
    restored_images = restored_images + 1
    return 88
  end,
  move = function(image_id) return image_id end,
}
session.image_id = 77
session.last_image_bytes = "cached-png"
local float_buf = vim.api.nvim_create_buf(false, true)
local float_win = vim.api.nvim_open_win(float_buf, false, {
  relative = "editor", row = placement.row, col = placement.col,
  width = math.min(10, placement.width), height = math.min(3, placement.height), style = "minimal",
})
local occluded, occluding_windows = preview.occlusion(session.preview_win)
t.eq(true, occluded, "overlapping floating UI occludes the graphical preview")
t.eq(float_win, occluding_windows[1], "occlusion reports the actual floating window")
vim.wait(100, function() return session.image_id == nil end)
t.eq(1, cleared_images, "opening an overlapping float clears the raw placement")
vim.api.nvim_win_close(float_win, true)
t.eq(false, select(1, preview.occlusion(session.preview_win)), "closing a float removes occlusion")
vim.wait(100, function() return session.image_id == 88 end)
t.eq(1, restored_images, "closing the float restores the cached raw placement")

local passive_buf = vim.api.nvim_create_buf(false, true)
local passive_win = vim.api.nvim_open_win(passive_buf, false, {
  relative = "editor", row = placement.row, col = placement.col,
  width = math.min(10, placement.width), height = 1, style = "minimal",
  border = "rounded", focusable = false,
})
t.eq(false, select(1, preview.occlusion(session.preview_win)),
  "non-focusable notifications do not blank the preview")
local passive_placement = preview.placement(session.preview_win, "kitty_raw")
t.ok(#passive_placement.exclusions > 0, "non-focusable notification creates a raw-image cutout")
local passive_rect = passive_placement.exclusions[1]
t.eq(math.min(10, placement.width) + 2, passive_rect.width,
  "notification cutout includes both border columns")
vim.api.nvim_win_close(passive_win, true)

local mouse = require("md-viewer.mouse")
vim.keymap.set("n", "<ScrollWheelDown>", "<Nop>", { desc = "test prior wheel mapping" })
mouse.attach(controller.navigate)
t.eq(true, mouse.is_attached(), "mouse wheel dispatch attaches for graphical preview")
session.document_height_px = 1000
session.viewport_height_px = 200
session.scroll_y = 0
preview.reset_surface(session)
local source_cursor = vim.api.nvim_win_get_cursor(session.source_win)
local original_schedule = controller.schedule
local original_refresh = controller.refresh
local scheduled = {}
controller.refresh = function(_, options) scheduled.scroll_timer = { delay = 0, options = options } end
controller.schedule = function(_, delay, timer_name, options)
  scheduled[timer_name] = { delay = delay, options = options }
end
session.scroll_render_in_flight = false
controller.schedule_scroll(session)
session.scroll_render_in_flight = false
controller.refresh = original_refresh
controller.schedule = original_schedule
t.eq("css", scheduled.scroll_timer.options.capture_scale, "moving preview uses CSS-resolution frame")
t.eq(true, scheduled.scroll_timer.options.capture_only, "scroll capture omits unchanged Markdown payload")
t.eq(true, scheduled.scroll_timer.options.scroll_frame, "moving capture is identified for scroll ordering")
t.eq("device", scheduled.scroll_settle_timer.options.capture_scale, "settled preview restores Retina frame")
t.ok(scheduled.scroll_timer.delay < scheduled.scroll_settle_timer.delay, "fast frame precedes settled frame")

local fast_requests, latest_fast_options = 0, nil
controller.refresh = function(_, options)
  fast_requests = fast_requests + 1
  latest_fast_options = options
end
controller.schedule = function() end
session.scroll_render_in_flight = false
session.scroll_render_pending = false
controller.schedule_scroll(session)
controller.schedule_scroll(session)
t.eq(1, fast_requests, "only one scroll capture is in flight")
t.eq(true, session.scroll_render_pending, "newest scroll position is retained as one pending frame")
latest_fast_options.on_complete()
vim.wait(100, function() return fast_requests == 2 end)
t.eq(2, fast_requests, "pending scroll position renders after current capture")
session.scroll_render_in_flight = false
session.scroll_render_pending = false
controller.refresh = original_refresh
controller.schedule = original_schedule

local original_schedule_scroll = controller.schedule_scroll
local scroll_requests = 0
controller.schedule_scroll = function() scroll_requests = scroll_requests + 1 end
controller.navigate(session, "line_down")
controller.schedule_scroll = original_schedule_scroll
t.eq(22, session.scroll_y, "j advances one rendered line")
t.ok(session.manual_scroll_until > vim.uv.now(), "manual navigation pauses cursor-follow briefly")
t.eq(1, scroll_requests, "preview navigation requests a backpressured scroll frame")
t.eq(source_cursor, vim.api.nvim_win_get_cursor(session.source_win), "preview motion preserves source cursor")
t.eq(88, (function()
  controller.schedule_scroll = function() end
  controller.navigate(session, "wheel_down")
  controller.schedule_scroll = original_schedule_scroll
  return session.scroll_y
end)(), "mouse wheel advances configured rendered lines")
t.eq(1, vim.api.nvim_buf_line_count(session.preview_buf), "preview has no synthetic extra lines")
controller.schedule_scroll = function() end
controller.navigate(session, "bottom")
controller.schedule_scroll = original_schedule_scroll
t.eq(800, session.scroll_y, "G moves browser viewport to document bottom")

local navigation = require("md-viewer.navigation")
navigation.attach(session, function() end)
local g_mapping = vim.api.nvim_buf_call(session.preview_buf, function()
  return vim.fn.maparg("G", "n", false, true)
end)
t.ok(not vim.tbl_isempty(g_mapping), "preview-local G mapping exists")
session.backend = original_backend
local other = vim.api.nvim_create_buf(true, false)
vim.api.nvim_win_set_buf(session.source_win, other)
t.eq(session, state.get(source), "preview survives source buffer becoming hidden")
t.ok(vim.api.nvim_win_is_valid(session.preview_win), "pinned preview remains visible while browsing files")
controller.close()
t.eq(nil, state.get(source), "preview close removes session")
t.eq(false, mouse.is_attached(), "mouse dispatch is removed with the last graphical preview")
local restored_wheel = vim.fn.maparg("<ScrollWheelDown>", "n", false, true)
t.eq("<Nop>", restored_wheel.rhs, "previous mouse mapping is restored")
vim.keymap.del("n", "<ScrollWheelDown>")
vim.api.nvim_set_current_buf(source)
local reopened = assert(controller.open("right"))
t.ok(reopened.preview_buf ~= session.preview_buf, "preview close and reopen")
controller.close(source)

local process = require("md-viewer.process")
local ping_result, ping_error
process.request("ping", {}, function(result, err) ping_result, ping_error = result, err end)
vim.wait(5000, function() return ping_result ~= nil or ping_error ~= nil end, 20)
if ping_error then print("renderer integration diagnostics: " .. vim.inspect(process.status())) end
t.eq(nil, ping_error, "Lua renderer protocol error")
t.eq(true, ping_result and ping_result.pong, "Lua renderer protocol ping")
process.stop()
vim.wait(5000, function() return not process.status().running end, 20)
t.eq(false, process.status().running, "Lua renderer shutdown")

t.finish()
