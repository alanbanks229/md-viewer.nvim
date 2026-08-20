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
    -- What an SSH session waits instead. These are two independent answers
    -- rather than a base and an adjustment, so for one delay everywhere set
    -- both to the same number -- writing `nil` here does nothing, because a
    -- key absent from `setup()` means "keep the default" and cannot mean
    -- "clear it".
    --
    -- The settle capture is the expensive one -- full `device_scale_factor`,
    -- measured at 304,666 bytes and ~508 ms of transit on the link this was
    -- built for -- and it fires whenever scrolling stops for this long. A mouse
    -- wheel does not deliver a smooth stream: notches arrive 50-150 ms apart,
    -- so at 160 ms an ordinary gap between two flicks reads as "stopped" and
    -- buys a half-second transfer that the next notch immediately makes stale.
    -- 400 ms sits above the gaps inside a scroll and below the pauses between
    -- them, so the sharp frame is spent on a reader who has actually stopped.
    --
    -- The cost is real and is the reason this is not simply raised everywhere:
    -- when you do stop, sharpness arrives about 240 ms later than it used to.
    -- That trade is only worth making when the frame itself takes half a second
    -- to arrive, which is why it is gated on the session rather than global.
    ssh_scroll_settle_ms = 400,
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
    -- How fast this session's link actually is, in bytes per second, when you
    -- know. nil means nobody has said.
    --
    -- Only resident panning reads it, and only to decide how long an uploaded
    -- slice is still crossing the wire -- for that long, a scroll that misses is
    -- coalesced rather than queued behind it. Set it to `800000` for the AWS SSM
    -- tunnel this feature was built against (0.80 MB/s, measured); use whatever
    -- `scp` of a large file reports for anything else, since that is the same
    -- quantity.
    --
    -- `scripts/ssh-link-speed.sh` measures it. Run it from the shell in the SSH
    -- session, not from inside Neovim, and paste what it prints.
    --
    -- Asked rather than inferred, which is the whole reason this key exists, and
    -- the reason is stronger than it used to be stated. It was not that a write
    -- to `nvim_ui_send` returns before the terminal has the bytes; it is that
    -- **the write never touches the terminal at all**. `nvim_ui_send` appends to
    -- Neovim's own UI queue and returns, and the TUI drains that queue onto the
    -- pty on its own time -- so a Lua caller sees no back-pressure from the link
    -- under any circumstances. Measured against a host shaped to 0.80 MB/s:
    -- 24 MB accepted from inside Neovim in 0.03s, against 8 MB in 11.0s written
    -- from the shell. A real session put an SSM tunnel at 101,169 B/ms on that
    -- basis and computed a 2 ms pause from it.
    --
    -- Nor is there anything else to ask. A terminal can be told to acknowledge
    -- an upload, but its reply lands on Neovim's own stdin, which a plugin
    -- cannot read (see md-viewer/cellpixels.lua). So the operator knows this and
    -- the plugin does not.
    ssh_link_bytes_per_sec = nil,
    -- Keeping this off improves motion and nothing else.
    -- Better GIF rendering with this architecture needs to be explored.
    -- Playback is expensive when sending constant PNG screenshots.
    animate = false,
    animate_fps = 5,
  },
  browser = {
    executable_path = nil,
    launch_timeout_ms = 10000,
    -- Set false to fall back to Playwright's default encoding.
    fast_png_encode = true,
  },
  image = {
    backend = "auto",
    -- nil defers to the terminal profile's default (see md-viewer.terminal);
    -- set explicitly to override every profile.
    double_buffer = nil,
    raw_zindex = nil,
    raw_statusline_guard_cells = 1,
    raw_overlay_bleed_cells = 1,
    raw_cell_offset_px = { x = 0, y = 0 },
    ui_poll_ms = 50,
    -- Whether scrolling may be shown by re-cropping pixels the terminal already
    -- has, instead of capturing and sending a fresh frame for every position.
    -- "auto" follows the terminal profile; "on" and "off" override it, the same
    -- three-valued shape `interaction.selection_overlay` uses and for the same
    -- two reasons -- someone has to be able to turn it on to qualify a new
    -- terminal, and off to escape a defect in one.
    --
    -- Only ever active over SSH, where the pixels are the cost. A local terminal
    -- receives a frame for free, so this would trade terminal memory for nothing.
    --
    -- Named for what it does rather than for how. This was `resident_pan`, which
    -- is not wrong -- pixels are held resident in the terminal and the crop pans
    -- across them -- but it is the mechanism's name, and a reader setting an
    -- option wants to know what they get. What they get is: **a slice is
    -- uploaded once and never uploaded again while it stays in the window.**
    --
    -- That sentence is the whole promise, and it is deliberately not "the
    -- document is held". No fixed ceiling can promise the document -- there is
    -- always a longer one -- so a name implying completeness ("keep_document",
    -- "hold_whole_document") would be unenforceable by construction. This one
    -- stays true at every size: past `resident_memory_mb` the window slides and
    -- crossing it costs an upload, and the pixels that are still there are still
    -- reused. `:MdViewerDebug` and `:MdViewerHealth` say when a document does not
    -- fit rather than leaving it to be inferred from `evictions` climbing.
    reuse_sent_pixels = "auto",
    -- How much decoded image the terminal may hold for one preview, in
    -- megabytes. 0 disables the reuse outright.
    --
    -- Keeps its name through `resident_pan`'s rename, on purpose. It was renamed
    -- itself one release ago and a second migration for one option in
    -- consecutive prereleases is a cost the reader pays for our tidiness; and
    -- "resident" is accurate here in a way it was not as a feature name -- this
    -- bounds the pixels the terminal holds resident, which is exactly what it
    -- says.
    --
    -- Megabytes rather than the pixels this used to be stated in, because
    -- megabytes are what a reader is actually spending and pixels only became a
    -- proxy for them through a conversion nobody had measured. The measurement
    -- exists now -- 12-13 bytes per resident pixel on iTerm2,
    -- scripts/resident/rss-calibrate.py -- so the honest unit is available and
    -- the proxy is not worth keeping. The key is renamed rather than
    -- reinterpreted: an existing `resident_budget_px = 8000000` silently read as
    -- 8 MB would be a twelvefold reduction nobody asked for. A configuration
    -- still setting the old key is converted at that measured rate and warned
    -- about once -- see `migrate_resident_budget` for why it is not refused.
    --
    -- 512 MB holds about 41 megapixels: roughly thirteen viewports at a typical
    -- split, or a document of ~10,400 CSS px held whole. Documents shorter than
    -- that never evict anything at all, which is the property the whole rebuild
    -- exists to buy. The same calibration showed the memory is returned when a
    -- slice is freed and that iTerm2 does not self-evict, so this is a ceiling
    -- on what is held rather than a guess at what is safe.
    --
    -- The sustained question is closed and the conversion is not.
    -- scripts/resident/rss.sh has now been run against a real session on the
    -- real link: iTerm2 plateaus. RSS rose ~10 MB above baseline over the run,
    -- with transient peaks on resize that relaxed -- no creep and no leak, which
    -- is what this ceiling was waiting on. But the same run had twelve slices
    -- resident, which at 13 B/px is ~342 MB budgeted against ~10 MB observed.
    -- Those are 34x apart and cannot both describe the same quantity, so the
    -- number this key is denominated in is not corroborated by the only real
    -- session that has ever been measured. Either the RSS sampler cannot see
    -- decoded slices (GPU textures are outside `ps -o rss=`), or 13 B/px does
    -- not generalise from rss-calibrate.py's deliberately incompressible
    -- gradients to a document that is mostly flat background. Re-running that
    -- calibration against realistic content is the cheap experiment that would
    -- tell the two apart. Until it does, this bounds a budget rather than a
    -- megabyte, and raising it on the plateau alone would be raising it on a
    -- unit nobody has confirmed.
    resident_memory_mb = 512,
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
  remote = {
    -- Preview documents whose buffer names remote-ssh.nvim or netrw own
    -- (scp://, rsync://). Neovim, the renderer and the browser all stay on
    -- this machine; files the document references are copied over once each,
    -- into a private mirror, off the render loop. Off, those buffers are
    -- refused exactly like any other special buffer.
    enabled = true,
    -- Ceiling on one remote operation -- the per-render stat batch, or one
    -- file copy. Generous because a cold connection through a relayed tunnel
    -- (AWS SSM and the like) can take seconds before the first byte moves.
    fetch_timeout_ms = 15000,
    -- Ceiling on the local mirror of fetched assets, across all hosts and
    -- projects together. Enforced after each fetch batch by deleting the
    -- oldest files first.
    cache_max_bytes = 256 * 1024 * 1024,
    -- argv prefix for every command this plugin runs against a remote host;
    -- replace it to route through a wrapper. It is always exec'd as an argv
    -- vector, never handed to a local shell, so nothing a document says can
    -- reach one.
    ssh_command = { "ssh" },
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
    type(cfg.render.scroll_settle_ms) == "number" and cfg.render.scroll_settle_ms >= 0,
    "md-viewer: render.scroll_settle_ms must be non-negative"
  )
  assert(
    cfg.render.ssh_scroll_settle_ms == nil
      or (type(cfg.render.ssh_scroll_settle_ms) == "number" and cfg.render.ssh_scroll_settle_ms >= 0),
    "md-viewer: render.ssh_scroll_settle_ms must be non-negative, or nil to use render.scroll_settle_ms over SSH"
  )
  -- Above zero rather than non-negative: zero is not a slow link, it is a link
  -- nothing can cross, and it would divide into an infinite hold. "I do not
  -- know" is spelled nil, which is the default.
  assert(
    cfg.render.ssh_link_bytes_per_sec == nil
      or (type(cfg.render.ssh_link_bytes_per_sec) == "number" and cfg.render.ssh_link_bytes_per_sec > 0),
    "md-viewer: render.ssh_link_bytes_per_sec must be a positive number of bytes per second, or nil if unknown"
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
  local reuse = cfg.image.reuse_sent_pixels
  assert(
    reuse == "auto" or reuse == "on" or reuse == "off",
    'md-viewer: image.reuse_sent_pixels must be "auto", "on", or "off"'
  )
  assert(
    type(cfg.image.resident_memory_mb) == "number" and cfg.image.resident_memory_mb >= 0,
    "md-viewer: image.resident_memory_mb must be non-negative"
  )
  -- `image.resident_budget_px` is not asserted against here. It is converted in
  -- `M.setup` before this runs, loudly and once, because refusing a whole
  -- configuration over a renamed key costs the reader their preview -- and on
  -- the slow remote link this feature exists for, "no preview at all" is the
  -- worst available way to learn about a rename.
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
  assert(type(cfg.remote.enabled) == "boolean", "md-viewer: remote.enabled must be a boolean")
  assert(
    type(cfg.remote.fetch_timeout_ms) == "number" and cfg.remote.fetch_timeout_ms > 0,
    "md-viewer: remote.fetch_timeout_ms must be positive"
  )
  assert(
    type(cfg.remote.cache_max_bytes) == "number" and cfg.remote.cache_max_bytes > 0,
    "md-viewer: remote.cache_max_bytes must be positive"
  )
  assert(
    vim.islist(cfg.remote.ssh_command) and #cfg.remote.ssh_command > 0,
    "md-viewer: remote.ssh_command must be a non-empty list of argv strings"
  )
  for _, part in ipairs(cfg.remote.ssh_command) do
    assert(type(part) == "string" and part ~= "", "md-viewer: remote.ssh_command entries must be non-empty strings")
  end
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

---Whether this Neovim has already been told about the key that was renamed.
---Once per session, not once per `setup()`: the A/B harness re-applies a whole
---configuration on every phase change, and a warning per call would be noise
---nobody reads by the third one.
local warned_about_budget_px = false

---Accept `image.resident_budget_px`, the key `image.resident_memory_mb`
---replaced, instead of refusing to load because of it.
---
---The two state the same bound in different units, so a config still setting the
---old one is a reader who believes a ceiling is in force that is not. Refusing
---outright says so loudly -- and costs them the preview entirely, which on the
---slow remote link this whole feature exists for is the worst available way to
---learn about a rename. Converting says it just as loudly and still renders the
---document.
---
---The conversion is the measured one: ~13 bytes per resident pixel
---(`scripts/resident/rss-calibrate.py`), so the old 8,000,000 px default becomes
---99 MB rather than the "~32 MB" it was documented as. That is deliberately the
---bound they *had*, not the bound they thought they had -- silently changing how
---much a working configuration holds is the thing a rename must not do.
---
---`0` converts to `0`, which is what disables the feature, so a
---configuration that had turned it off stays off.
local function migrate_resident_budget(opts)
  local image = opts.image
  local legacy = image and image.resident_budget_px
  if legacy == nil then return end
  image.resident_budget_px = nil

  local note
  if image.resident_memory_mb ~= nil then
    note = (
      "image.resident_budget_px has been replaced by image.resident_memory_mb, which you have already "
      .. "set to %s -- the old key is being ignored."
    ):format(tostring(image.resident_memory_mb))
  elseif type(legacy) ~= "number" or legacy < 0 then
    note = (
      "image.resident_budget_px has been replaced by image.resident_memory_mb, and %s is not a pixel "
      .. "count that can be converted -- the default of %d MB is in force."
    ):format(vim.inspect(legacy), M.defaults.image.resident_memory_mb)
  else
    -- Lazily, so the one module config must not depend on at load time stays
    -- that way; this runs only for a configuration that names the old key.
    local bytes_per_px = require("md-viewer.resident").BYTES_PER_RESIDENT_PX
    local megabytes = legacy == 0 and 0 or math.max(1, math.floor(legacy * bytes_per_px / 1048576 + 0.5))
    image.resident_memory_mb = megabytes
    note = (
      "image.resident_budget_px has been replaced by image.resident_memory_mb. Converted %s px to "
      .. "%d MB at the measured %d bytes per resident pixel; set image.resident_memory_mb = %d to silence "
      .. "this."
    ):format(tostring(legacy), megabytes, bytes_per_px, megabytes)
  end

  if not warned_about_budget_px then
    warned_about_budget_px = true
    vim.notify("md-viewer: " .. note, vim.log.levels.WARN)
  end
end

local warned_about_resident_pan = false

---Accept `image.resident_pan`, the key `image.reuse_sent_pixels` replaced.
---
---Converted rather than refused, for the reason written out above
---`migrate_resident_budget` and worth restating because it is the same reader:
---refusing a configuration over a renamed key costs them the preview, and on the
---slow remote link this feature exists for that is the worst available way to
---find out about a rename. This is a pure rename with the same three values, so
---the conversion is exact -- unlike the budget's, which had to change units --
---and a configuration that had turned the feature off stays off.
local function migrate_resident_pan(opts)
  local image = opts.image
  local legacy = image and image.resident_pan
  if legacy == nil then return end
  image.resident_pan = nil

  local note
  if image.reuse_sent_pixels ~= nil then
    note = (
      "image.resident_pan is now image.reuse_sent_pixels, which you have already set to %s -- the old "
      .. "key is being ignored."
    ):format(vim.inspect(image.reuse_sent_pixels))
  elseif legacy ~= "auto" and legacy ~= "on" and legacy ~= "off" then
    -- Passed through untouched rather than defaulted away, so `validate` refuses
    -- it by its new name and the reader is told about the rename *and* about the
    -- value in one go. Silently substituting the default here would turn a typo
    -- into a working configuration that does something else.
    image.reuse_sent_pixels = legacy
    note = ('image.resident_pan is now image.reuse_sent_pixels, and %s is not one of "auto", "on" or "off".'):format(
      vim.inspect(legacy)
    )
  else
    image.reuse_sent_pixels = legacy
    note = (
      "image.resident_pan is now image.reuse_sent_pixels -- named for what it does (a slice is sent once "
      .. "and never sent again while it stays in the window) rather than for how. Your %s is in force; set "
      .. "image.reuse_sent_pixels = %q to silence this."
    ):format(vim.inspect(legacy), legacy)
  end

  if not warned_about_resident_pan then
    warned_about_resident_pan = true
    vim.notify("md-viewer: " .. note, vim.log.levels.WARN)
  end
end

function M.setup(opts)
  vim.validate({ opts = { opts or {}, "table" } })
  opts = vim.deepcopy(opts or {})
  migrate_resident_budget(opts)
  migrate_resident_pan(opts)
  current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  validate(current)
  invalidate_terminal()
  return current
end

---Exposed for the one test that has to observe the warning without a second
---`setup()` having already consumed it.
function M._forget_budget_px_warning() warned_about_budget_px = false end
function M._forget_resident_pan_warning() warned_about_resident_pan = false end

function M.get() return current end

function M.reset()
  current = vim.deepcopy(M.defaults)
  invalidate_terminal()
end

return M
