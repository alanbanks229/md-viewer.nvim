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
    local_images = true,
    max_local_image_bytes = 10 * 1024 * 1024,
    device_scale_factor = 2,
    font_size_px = 14,
    cell_aspect_ratio = 0.5,
    estimated_cell_width_px = 10,
    max_width_px = 1920,
    max_height_px = 1440,
    max_png_bytes = 32 * 1024 * 1024,
    scroll_past_end = true,
    scroll_past_end_offset_px = 22,
    fast_scroll = true,
    scroll_settle_ms = 160,
    -- How much of its natural size the *moving* frame of a scroll is captured
    -- at. nil defers to `ssh_scroll_scale` over SSH and to full size locally;
    -- set it to pin one factor everywhere.
    --
    -- Only the moving frame is affected. The settle capture that lands when
    -- the wheel stops is always full `device_scale_factor`, so the picture a
    -- reader actually looks at is never the reduced one. With
    -- `fast_scroll = false` there is no separate moving frame and this does
    -- nothing, deliberately: scaling the only frame there is would leave the
    -- preview permanently soft.
    scroll_scale = nil,
    -- What `scroll_scale` resolves to when Neovim is running over SSH.
    --
    -- 0.5 rather than something smaller because PNG bytes against real content
    -- go as pixels^0.69: quartering the pixels costs about 2.6x fewer bytes,
    -- and bytes are the entire cost on a throughput-limited link. Measured on
    -- an AWS SSM tunnel with a flat 0.80 MB/s ceiling, one 80KB moving frame is
    -- ~134ms of pure wire time and a single wheel spin queues over a hundred of
    -- them -- so the backlog, not the render, is the lag. See
    -- docs/local-render-design.md.
    ssh_scroll_scale = 0.5,
    -- Keeping this off improves motion and nothing else.
    -- Better GIF rendering with this architecture needs to be explored.
    -- Playback is expensive when sending constant PNG screenshots.
    animate = false,
    animate_fps = 5,
  },
  browser = {
    channel = "chrome",
    executable_path = nil,
    launch_timeout_ms = 10000,
    -- Set false to fall back to Playwright's default encoding.
    fast_png_encode = true,
  },
  image = {
    backend = "auto",
    zindex = 20,
    -- nil defers to the terminal profile's default (see md-viewer.terminal);
    -- set explicitly to override every profile.
    double_buffer = nil,
    raw_zindex = nil,
    raw_statusline_guard_cells = 1,
    raw_overlay_bleed_cells = 1,
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
  security = {
    -- Off by default. When true, the internal processor `markdown-it` parses
    -- raw HTML embedded in the markdown document instead of dropping it.
    -- The output still passes the allowlist sanitizer, so <scripts>, event attributes,
    -- and frames stay forbidden either way. See SECURITY.md before enabling.
    raw_html = false,
    -- Markers that identify the project enclosing the document when
    -- `document_root` is unset. See md-viewer.security.document_root for why
    -- the default boundary is the project rather than the document's folder.
    document_root_markers = { ".git", ".hg", ".svn" },
    document_root = nil,
  },
  interaction = {
    enabled = true,
    links = true,
    drag_threshold_cells = 1,
    -- Gates installing the <2-LeftMouse> mapping at all. Word-select hangs
    -- off that same binding; this lets it be turned off without inventing new
    -- plumbing.
    double_click = true,
    selection = true,
    -- 0 fires each drag-preview frame immediately, using only the
    -- one-in-flight flag for backpressure -- the same shape
    -- controller.schedule_scroll uses for its own moving frame. A trailing
    -- debounce ahead of a pipeline that already has backpressure only adds
    -- latency, and under input faster than the debounce interval it can
    -- starve dispatch outright (it resets on every call rather than firing on
    -- a schedule). Kept as a knob rather than removed: set above 0 to
    -- deliberately throttle preview requests.
    drag_debounce_ms = 0,
    -- `v`/`V` in the preview: extend a real DOM selection from the caret with
    -- ordinary motions, instead of Neovim's own visual mode, which over a
    -- surface of blank cells would only ever select spaces.
    visual = true,
    -- Keep scrolling the document while a drag holds past the top or bottom
    -- edge of the preview, so a selection can run past what is on screen the
    -- way it does on a web page. Off, a drag that leaves the window freezes at
    -- the edge -- `locate_for_drag` clamps the point to the placement, and the
    -- placement is the visible document.
    autoscroll = true,
    -- How often an edge-scrolling drag takes a step. Each step is one interact
    -- round trip that scrolls, extends the selection and captures the frame
    -- together, so this is a floor on latency, not a fixed frame rate: a step
    -- slower than the interval simply paces the next one.
    autoscroll_interval_ms = 60,
    -- Ceiling on lines scrolled per step. Speed otherwise scales with how far
    -- past the edge the pointer is; without a cap, flinging the pointer to the
    -- far corner of the screen would skip whole pages between frames.
    autoscroll_max_lines = 6,
    fast_drag = false,
    -- **Do not set "on" for WezTerm.** It draws correctly there and exhausts
    -- your memory within seconds of a drag -- an upstream defect.
    -- The measurements and the issue numbers are in terminal.lua's
    -- wezterm profile and docs/terminal-support.md.
    selection_overlay = "auto",
    settle_ms = 120,
    copy = true,
    -- Disabled by default: neither VS Code nor a browser copies on every
    -- drag, and silently overwriting the user's clipboard on each selection
    -- would be hostile.
    copy_on_select = false,
    word_select = true,
    paragraph_select = true,
    find = true,
    -- How many "markdown preview documents" this plugin remembers.
    -- Bounded rather than unbounded: each entry pins a buffer number and a
    -- path, and a reader following links for an hour should not accumulate an
    -- ever-growing list.
    history_limit = 32,
    -- How long to keep watching a system handler md-viewer started for an
    -- external link before assuming it is running normally. Only failures that
    -- happen inside this window can be reported; past it, a still-running
    -- handler *is* the success case.
    external_open_timeout_ms = 5000,
  },
  terminal = {
    profile = "auto",
    kitty_graphics = "auto",
    probe = "off",
    -- How animated images are played. "auto" takes the profile's validated
    -- mode; "native" forces the terminal's own animation player (the Kitty
    -- protocol's a=f/a=a extension -- use to qualify a terminal the profile
    -- table does not yet trust); "frames" forces client-driven frame
    -- placements; "off" leaves every animation as its still first frame.
    animation = "auto",
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
  -- Both of these are divisors, and neither was checked before the measured
  -- calibration tier made `device_scale_factor` one. The 1..3 bound is the one
  -- browser.js applies to the same value when it creates the browser context;
  -- accepting a wider range here only produces a viewport that disagrees with
  -- the page.
  assert(
    type(cfg.render.device_scale_factor) == "number"
      and cfg.render.device_scale_factor >= 1
      and cfg.render.device_scale_factor <= 3,
    "md-viewer: render.device_scale_factor must be between 1 and 3"
  )
  assert(
    type(cfg.render.cell_aspect_ratio) == "number" and cfg.render.cell_aspect_ratio > 0,
    "md-viewer: render.cell_aspect_ratio must be positive"
  )
  assert(
    type(cfg.render.font_size_px) == "number" and cfg.render.font_size_px > 0,
    "md-viewer: render.font_size_px must be positive"
  )
  assert(type(cfg.render.animate) == "boolean", "md-viewer: render.animate must be a boolean")
  -- Bounded at both ends. Below 1 the timer would never fire; above 30 the
  -- placement traffic stops being negligible, which is the only reason drawing
  -- frames this way is affordable at all.
  assert(
    type(cfg.render.animate_fps) == "number" and cfg.render.animate_fps >= 1 and cfg.render.animate_fps <= 30,
    "md-viewer: render.animate_fps must be between 1 and 30"
  )
  -- Both bounded at 0.25: below that the moving frame stops being legible even
  -- in motion, which defeats the point of drawing one. Bounded at 1 because
  -- this only ever *reduces* -- capturing the moving frame above its natural
  -- size spends bytes to gain nothing, `device_scale_factor` being the knob
  -- that decides what natural means.
  assert(
    cfg.render.scroll_scale == nil
      or (
        type(cfg.render.scroll_scale) == "number"
        and cfg.render.scroll_scale >= 0.25
        and cfg.render.scroll_scale <= 1
      ),
    "md-viewer: render.scroll_scale must be a number between 0.25 and 1, or nil to follow "
      .. "render.ssh_scroll_scale over SSH"
  )
  assert(
    type(cfg.render.ssh_scroll_scale) == "number"
      and cfg.render.ssh_scroll_scale >= 0.25
      and cfg.render.ssh_scroll_scale <= 1,
    "md-viewer: render.ssh_scroll_scale must be a number between 0.25 and 1"
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
  assert(type(cfg.browser.fast_png_encode) == "boolean", "md-viewer: browser.fast_png_encode must be boolean")
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
  local animation_modes = { auto = true, native = true, frames = true, off = true }
  assert(animation_modes[cfg.terminal.animation], "md-viewer: terminal.animation must be auto, native, frames, or off")
  assert(type(cfg.security.raw_html) == "boolean", "md-viewer: security.raw_html must be boolean")
  assert(
    vim.islist(cfg.security.document_root_markers),
    "md-viewer: security.document_root_markers must be a list of marker names"
  )
  for _, marker in ipairs(cfg.security.document_root_markers) do
    assert(
      type(marker) == "string" and marker ~= "",
      "md-viewer: security.document_root_markers entries must be non-empty strings"
    )
  end
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
  assert(type(cfg.interaction.fast_drag) == "boolean", "md-viewer: interaction.fast_drag must be boolean")
  assert(type(cfg.interaction.visual) == "boolean", "md-viewer: interaction.visual must be boolean")
  assert(type(cfg.interaction.autoscroll) == "boolean", "md-viewer: interaction.autoscroll must be boolean")
  assert(
    type(cfg.interaction.autoscroll_interval_ms) == "number" and cfg.interaction.autoscroll_interval_ms >= 0,
    "md-viewer: interaction.autoscroll_interval_ms must be non-negative"
  )
  assert(
    type(cfg.interaction.autoscroll_max_lines) == "number" and cfg.interaction.autoscroll_max_lines > 0,
    "md-viewer: interaction.autoscroll_max_lines must be positive"
  )
  assert(
    cfg.interaction.selection_overlay == "auto"
      or cfg.interaction.selection_overlay == "on"
      or cfg.interaction.selection_overlay == "off",
    "md-viewer: interaction.selection_overlay must be auto, on, or off"
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
  assert(
    type(cfg.interaction.history_limit) == "number"
      and cfg.interaction.history_limit >= 1
      and cfg.interaction.history_limit == math.floor(cfg.interaction.history_limit),
    "md-viewer: interaction.history_limit must be a positive integer"
  )
  assert(
    type(cfg.interaction.external_open_timeout_ms) == "number" and cfg.interaction.external_open_timeout_ms >= 0,
    "md-viewer: interaction.external_open_timeout_ms must be non-negative"
  )
end

-- The terminal module memoizes its capability snapshot against the `terminal`
-- config section; a config change is the one event that can invalidate it.
-- Guarded on package.loaded so configuring md-viewer does not load the
-- terminal module as a side effect.
local function invalidate_terminal()
  local terminal = package.loaded["md-viewer.terminal"]
  if terminal and terminal.invalidate then terminal.invalidate() end
end

function M.setup(opts)
  vim.validate({ opts = { opts or {}, "table" } })
  opts = vim.deepcopy(opts or {})
  current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  validate(current)
  invalidate_terminal()
  return current
end

function M.get() return current end

function M.reset()
  current = vim.deepcopy(M.defaults)
  invalidate_terminal()
end

return M
