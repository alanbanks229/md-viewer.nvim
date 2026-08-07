local M = {}

M.defaults = {
  split = { position = "right", width = 0.48, min_width = 45 },
  preview = {
    pinned = true,
    winbar = true,
    loading = true,
    loading_interval_ms = 80,
  },
  render = {
    debounce_ms = 200,
    theme = "auto",
    raw_html = false,
    local_images = true,
    max_local_image_bytes = 10 * 1024 * 1024,
    device_scale_factor = 2,
    font_size_px = 16,
    cell_aspect_ratio = 0.5,
    estimated_cell_width_px = 10,
    max_width_px = 1920,
    max_height_px = 1440,
    max_png_bytes = 32 * 1024 * 1024,
    scroll_past_end = true,
    scroll_past_end_offset_px = 22,
    fast_scroll = true,
    scroll_settle_ms = 160,
  },
  browser = { channel = "chrome", executable_path = nil, launch_timeout_ms = 10000 },
  image = {
    backend = "auto",
    zindex = 20,
    -- nil defers to the terminal profile's default (see md-viewer.terminal);
    -- set explicitly to override every profile.
    double_buffer = nil,
    -- Raw Kitty layers use terminal semantics, not Neovim float z-indices.
    -- nil defers to the terminal profile's default_raw_zindex.
    raw_zindex = nil,
    raw_statusline_guard_cells = 1,
    -- Extra columns of cut-out added to the trailing edge of a passive overlay
    -- (a notification sitting over the preview). Some terminals apply their
    -- horizontal window margin to text but not to graphics placements, which
    -- draws the image a fraction of a cell toward the origin; without this the
    -- overhang paints across the overlay's last column. Trailing edge only: the
    -- margin is never negative, so the image can only ever be offset left/up.
    raw_overlay_bleed_cells = 1,
    -- Offset, in pixels, at which the image starts inside its first cell (the
    -- Kitty graphics protocol's X/Y placement keys). Cancels the margin
    -- described above outright, when the terminal honours it -- measure the gap
    -- once and set x to it. Zero emits no X/Y at all, so terminals that do not
    -- implement those keys see the exact same bytes as before.
    raw_cell_offset_px = { x = 0, y = 0 },
    ui_poll_ms = 50,
  },
  sync = {
    source_to_preview = true,
    preview_to_source = false,
    cursor_follow = true,
    cursor_debounce_ms = 60,
    navigation_line_px = 22,
    mouse_scroll = true,
    mouse_scroll_lines = 3,
    manual_scroll_hold_ms = 500,
    alignment_tolerance = 0.10,
  },
  security = { network = false, document_root = nil },
  interaction = {
    enabled = true,
    links = true,
    drag_threshold_cells = 1,
    -- Gates installing the <2-LeftMouse> mapping at all. Part 6 hangs
    -- word-select off that same binding; this lets it be turned off without
    -- inventing new plumbing.
    double_click = true,
    selection = true,
    drag_debounce_ms = 40,
    settle_ms = 120,
    copy = true,
    -- Disabled by default: neither VS Code nor a browser copies on every
    -- drag, and silently overwriting the user's clipboard on each selection
    -- would be hostile.
    copy_on_select = false,
    word_select = true,
    paragraph_select = true,
    find = true,
  },
  terminal = {
    profile = "auto",
    kitty_graphics = "auto",
    probe = "off",
  },
}

local terminal_profiles = {
  auto = true,
  iterm2 = true,
  kitty = true,
  wezterm = true,
  ghostty = true,
  warp = true,
  generic_kitty = true,
  unknown = true,
}
local tri_state = { auto = true, on = true, off = true }
local probe_modes = { off = true, safe = true }

local current = vim.deepcopy(M.defaults)

local function validate(cfg)
  local positions = { right = true, left = true, below = true, above = true }
  local backends = { auto = true, nvim_img = true, kitty_raw = true, cells = true }
  assert(positions[cfg.split.position], "md-viewer: invalid split.position")
  assert(
    type(cfg.split.width) == "number" and cfg.split.width > 0 and cfg.split.width < 1,
    "md-viewer: split.width must be between 0 and 1"
  )
  assert(backends[cfg.image.backend], "md-viewer: invalid image.backend")
  assert(
    cfg.render.theme == "auto" or cfg.render.theme == "light" or cfg.render.theme == "dark",
    "md-viewer: render.theme must be auto, light, or dark"
  )
  assert(
    type(cfg.render.debounce_ms) == "number" and cfg.render.debounce_ms >= 0,
    "md-viewer: render.debounce_ms must be non-negative"
  )
  assert(
    type(cfg.render.estimated_cell_width_px) == "number" and cfg.render.estimated_cell_width_px > 0,
    "md-viewer: render.estimated_cell_width_px must be positive"
  )
  assert(
    type(cfg.render.font_size_px) == "number" and cfg.render.font_size_px > 0,
    "md-viewer: render.font_size_px must be positive"
  )
  assert(
    cfg.image.raw_zindex == nil
      or (
        type(cfg.image.raw_zindex) == "number"
        and cfg.image.raw_zindex >= -2147483648
        and cfg.image.raw_zindex <= 2147483647
      ),
    "md-viewer: image.raw_zindex must be a signed 32-bit integer, or nil to use the terminal profile default"
  )
  assert(
    cfg.image.double_buffer == nil or type(cfg.image.double_buffer) == "boolean",
    "md-viewer: image.double_buffer must be a boolean, or nil to use the terminal profile default"
  )
  assert(
    type(cfg.image.raw_statusline_guard_cells) == "number" and cfg.image.raw_statusline_guard_cells >= 0,
    "md-viewer: image.raw_statusline_guard_cells must be non-negative"
  )
  assert(
    type(cfg.image.raw_overlay_bleed_cells) == "number" and cfg.image.raw_overlay_bleed_cells >= 0,
    "md-viewer: image.raw_overlay_bleed_cells must be non-negative"
  )
  assert(
    type(cfg.image.raw_cell_offset_px) == "table"
      and type(cfg.image.raw_cell_offset_px.x) == "number"
      and type(cfg.image.raw_cell_offset_px.y) == "number"
      and cfg.image.raw_cell_offset_px.x >= 0
      and cfg.image.raw_cell_offset_px.y >= 0,
    "md-viewer: image.raw_cell_offset_px must be a table of non-negative x and y pixel offsets"
  )
  assert(
    type(cfg.image.ui_poll_ms) == "number" and cfg.image.ui_poll_ms >= 0,
    "md-viewer: image.ui_poll_ms must be non-negative"
  )
  assert(type(cfg.preview.loading) == "boolean", "md-viewer: preview.loading must be boolean")
  assert(
    type(cfg.preview.loading_interval_ms) == "number" and cfg.preview.loading_interval_ms > 0,
    "md-viewer: preview.loading_interval_ms must be positive"
  )
  assert(
    terminal_profiles[cfg.terminal.profile],
    "md-viewer: terminal.profile must be one of auto, iterm2, kitty, wezterm, ghostty, warp, "
      .. "generic_kitty, unknown"
  )
  assert(tri_state[cfg.terminal.kitty_graphics], "md-viewer: terminal.kitty_graphics must be auto, on, or off")
  assert(probe_modes[cfg.terminal.probe], "md-viewer: terminal.probe must be off or safe")
  assert(type(cfg.interaction.enabled) == "boolean", "md-viewer: interaction.enabled must be boolean")
  assert(type(cfg.interaction.links) == "boolean", "md-viewer: interaction.links must be boolean")
  assert(type(cfg.interaction.double_click) == "boolean", "md-viewer: interaction.double_click must be boolean")
  assert(
    type(cfg.interaction.drag_threshold_cells) == "number" and cfg.interaction.drag_threshold_cells >= 0,
    "md-viewer: interaction.drag_threshold_cells must be non-negative"
  )
  assert(type(cfg.interaction.selection) == "boolean", "md-viewer: interaction.selection must be boolean")
  assert(
    type(cfg.interaction.drag_debounce_ms) == "number" and cfg.interaction.drag_debounce_ms >= 0,
    "md-viewer: interaction.drag_debounce_ms must be non-negative"
  )
  assert(
    type(cfg.interaction.settle_ms) == "number" and cfg.interaction.settle_ms >= 0,
    "md-viewer: interaction.settle_ms must be non-negative"
  )
  assert(type(cfg.interaction.copy) == "boolean", "md-viewer: interaction.copy must be boolean")
  assert(type(cfg.interaction.copy_on_select) == "boolean", "md-viewer: interaction.copy_on_select must be boolean")
  assert(type(cfg.interaction.word_select) == "boolean", "md-viewer: interaction.word_select must be boolean")
  assert(type(cfg.interaction.paragraph_select) == "boolean", "md-viewer: interaction.paragraph_select must be boolean")
  assert(type(cfg.interaction.find) == "boolean", "md-viewer: interaction.find must be boolean")
end

function M.setup(opts)
  vim.validate({ opts = { opts or {}, "table" } })
  current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  validate(current)
  return current
end

function M.get() return current end

function M.reset() current = vim.deepcopy(M.defaults) end

return M
