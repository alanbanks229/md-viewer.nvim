local M = {}

M.defaults = {
  split = { position = "right", width = 0.48, min_width = 45 },
  preview = {
    pinned = true,
    winbar = true,
    -- The active tab's winbar underline, so it doesn't rely on TabLineSel
    -- and TabLine being distinguishable colors -- some colorschemes render
    -- them nearly identically. "#rrggbb", or `false` for the plain
    -- TabLineSel/TabLine link with no underline added.
    tab_accent = "#61afef",
    loading = true,
    loading_interval_ms = 80,
    -- Rendered visual lines, not Markdown source lines. `relative` mirrors
    -- Neovim's number+relativenumber display: the caret line stays absolute.
    line_numbers = "off",
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
    -- and bytes are the entire cost on a throughput-limited link.
    --
    -- The link that motivated the number is an AWS SSM tunnel at 0.80 MB/s,
    -- where one 80KB moving frame is ~134ms of pure wire time and a single
    -- wheel spin queues over a hundred of them -- so the backlog, not the
    -- render, is the lag. That ceiling is SSM's, not SSH's: it is the agent
    -- pacing its output at a kilobyte per millisecond, and an ordinary SSH
    -- session (measured: 16-23 MB/s to a LAN host) is twenty times faster. See
    -- docs/ssh.md, "Where that ceiling comes from".
    --
    -- Still gated on SSH generally rather than on SSM, because the plugin
    -- cannot tell the two apart -- SSM arrives as an ordinary SSH session with
    -- a ProxyCommand -- and a halved moving frame on a fast link costs
    -- sharpness the reader is unlikely to notice on a frame that is moving.
    ssh_scroll_scale = 0.5,
    -- How fast this link carries bytes, in bytes per second. A number pins it;
    -- "auto" takes a measurement this machine has already made; nil means
    -- unknown, and unknown is a legitimate answer.
    --
    -- Whatever it is, it is not inferred. `nvim_ui_send` appends to Neovim's own
    -- UI queue and returns; the TUI drains that queue later. On a 0.80 MB/s
    -- link, 96 payloads totalling 24 MB were accepted in 0.03s and no write ever
    -- waited. A plugin timing its own writes therefore measures a queue
    -- insertion and concludes the link runs at ~100 MB/s. Real sessions reported
    -- 209,046, 139,058 and 101,169 B/ms against a link doing 800. That
    -- conclusion holds at any link rate, which is why it survives the rate
    -- itself being re-checked.
    --
    -- So the number has to come from a shell, and "auto" is about *which* shell
    -- run. A single number cannot serve here: `~/.config/nvim` is one file
    -- symlinked to every machine, and measured 2026-08-25 the two behind it are
    -- fourteen times apart -- ~1,030,000 B/s through an AWS SSM tunnel against
    -- ~14,700,000 to a LAN host. Safe for the slower is nineteen times low on
    -- the faster; right for the faster is the error this option exists to
    -- correct. "auto" resolves it per machine instead.
    --
    -- It never measures on its own. It reads a small file under
    -- `stdpath("state")` that exists only because someone ran
    -- `:MdViewerMeasureLink` here, or `sh scripts/ssh-link-speed.sh
    -- --write-cache` from the shell with Neovim closed. Nothing at all happens
    -- until one of those is run, and a number set here outranks both -- which is
    -- also the trap: a rate left in a shared config defeats per-machine
    -- detection on every machine that shares it. See md-viewer.linkrate for the
    -- full precedence, `MD_VIEWER_SSH_LINK_BYTES_PER_SEC` included.
    --
    -- Used to estimate how long a resident warm-up will take. It bounds nothing,
    -- and a value set here is never capped against any other figure.
    ssh_link_bytes_per_sec = "auto",
    -- Off by default because the *first* loop of an animation is real traffic:
    -- one PNG per frame at the size it is drawn, transmitted to the terminal.
    -- Steady state is not -- frames are uploaded once under stable content keys
    -- and shared across previews, sessions and renderer restarts, so every
    -- later tick costs a placement swap and no pixels at all (`:MdViewerDebug`
    -- reports the per-tick figure as `animation_last_bytes`). What that means
    -- in practice: the cost is the document's animations once, not a stream,
    -- and it is the link this has to be weighed against rather than the CPU.
    --
    -- Nothing here re-captures the page to animate. A frame of the preview is
    -- one Chromium screenshot, so the animation is a separate layer the
    -- terminal draws over the still frame -- see animation.lua's header.
    animate = false,
    -- Ceiling on the client-driven ("frames") swap rate, 1..30. The walk skips
    -- frames rather than stretching them when the cap bites, so a capped
    -- animation keeps its real length and only gets choppier.
    animate_fps = 5,
    -- Where the renderer runs. "current" is the only behavior that existed
    -- before 0.3.0: Node and Chromium beside this Neovim. "local" runs
    -- them beside the *terminal* instead -- for sessions where this Neovim is
    -- remote and the link is the whole cost (the reference case is an AWS SSM
    -- tunnel at ~0.8 MB/s) -- and requires the md-viewer-local helper to be
    -- wrapping the ssh session; without it the session falls back to
    -- "current" loudly, never silently. There is deliberately no "auto" until
    -- the local path has been validated on the real slow link it exists for.
    location = "current",
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
    -- Whole-document resident mode: capture the document once as chunks, hold
    -- them in the terminal, and make scrolling a pure placement.
    --
    --   "off"   the per-scroll capture loop everywhere. The default.
    --   "auto"  where the terminal supports it *and* this machine has measured
    --           a link slower than `resident_below_bytes_per_sec`.
    --   "on"    wherever the terminal supports it, whatever the link is.
    --
    -- Experimental, and off by default. What it trades is a long warm-up and a
    -- document's worth of terminal image memory for scrolling that sends no
    -- pixels at all.
    --
    -- Worth it only where the per-scroll capture is what the reader is actually
    -- waiting on, which is a narrower set of links than "remote". At 0.80 MB/s
    -- -- an AWS SSM tunnel, where the agent paces its output at a kilobyte per
    -- millisecond -- a settle frame is ~508ms of wire and this feature is the
    -- difference between usable and not. At 16-23 MB/s, which is what an
    -- ordinary SSH session to a LAN host measures, the same frame is ~20ms and
    -- the warm-up is the only thing the reader will notice.
    --
    -- Which is why "auto" is the speed question and not the terminal question:
    -- a terminal that *can* hold a document resident says nothing about whether
    -- doing so helps. `resident_below_bytes_per_sec` is where that line sits and
    -- `:MdViewerMeasureLink` is what puts this machine on one side of it; an
    -- unmeasured link is not slow, it is unknown, and unknown stays off.
    -- `render_path` in :MdViewerDebug says which model a session actually chose,
    -- and names the rate when the rate is why.
    --
    -- "on" is that gate removed, not a stronger "auto": it is for exercising the
    -- resident path deliberately -- a fast desk machine, a bug report, the
    -- scripts under scripts/resident/ -- where waiting out a warm-up you gain
    -- nothing from is the point rather than a regression.
    resident = "off",
    -- The link speed `resident = "auto"` turns resident mode on *below*, in
    -- bytes per second.
    --
    -- 4 MB/s, which is not a measurement -- it is a gap. Both reference hosts
    -- sit an order of magnitude clear of it, one on each side: an AWS SSM tunnel
    -- measured 0.77-1.06 MB/s (2026-08-25), where resident mode is the
    -- difference between usable and not, and a LAN host measured 14.7 MB/s
    -- through the pty, where it is warm-up and nothing else. Anywhere in between
    -- would be a number pretending to know something about links nobody here has
    -- measured.
    --
    -- What it means in frames: the settle capture measured at 304,666 bytes is
    -- ~76ms of pure wire at 4 MB/s, which is about where waiting on bytes stops
    -- being a detail of the render and starts being the thing you are waiting
    -- for. Below that line the wait grows fast -- the same frame is ~508ms on
    -- the SSM link.
    --
    -- Raising this turns resident mode on for faster links; there is no evidence
    -- either way above 1.06 MB/s, because the next link anyone has measured is
    -- fourteen times faster than that.
    resident_below_bytes_per_sec = 4000000,
    -- How many viewports tall one chunk is.
    --
    -- Not a first-paint knob. Measured on Ubuntu 22.04 / Chrome 151, the first
    -- capture of a browser process costs 9,874-16,335ms whatever its size and
    -- every later one 116-373ms, so the renderer discharges that once at
    -- startup and chunk size does not bear on it. What this trades is
    -- per-capture overhead and overlap waste against how long a scroll into an
    -- uncaptured region waits:
    --
    --     1x    4.0 Mpx    116ms capture    396 KB    ~507ms of wire
    --     2x    8.1 Mpx    266ms capture    826 KB   ~1058ms
    --     2.9x 11.7 Mpx    373ms capture   1218 KB   ~1559ms
    --
    -- The wire column is at 0.80 MB/s, the SSM ceiling this feature exists for;
    -- on a link twenty times faster it is twenty times smaller and this knob
    -- stops mattering.
    --
    -- PNG bytes are linear in pixels across that range (94-105 KB/Mpx), so a
    -- larger chunk buys no compression. Clamped down when the document is wide
    -- enough that a chunk would exceed Chromium's per-capture ceiling.
    resident_chunk_viewports = 2,
    -- Roughly how much terminal image memory a document may occupy.
    --
    -- A heuristic, not a guarantee. It is derived from 13 bytes per resident
    -- pixel, measured on iTerm2 3.6.11 / macOS 15 against synthetic gradients;
    -- a sustained-RSS run against a real iTerm2 session disagreed with that
    -- figure by 34x and the discrepancy is unresolved. Kitty, Ghostty and
    -- WezTerm are unmeasured. `resident_max_chunks` is the bound that holds
    -- whether or not the per-pixel figure is right.
    resident_memory_mb = 512,
    -- The hard bound on how many chunks stay resident, independent of any
    -- bytes-per-pixel estimate. The reader's own chunk is never retired.
    resident_max_chunks = 24,
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
  obsidian = {
    -- Native wikilink navigation for an Obsidian vault. This is semantic
    -- compatibility only; md-viewer never loads or calls obsidian.nvim.
    enabled = false,
    -- nil uses the same detected/configured root as local-link security.
    vault_root = nil,
  },
  interaction = {
    enabled = true,
    links = true,
    selection = true,
    -- 0 fires each selection-preview frame immediately, using only the
    -- one-in-flight flag for backpressure -- the same shape
    -- controller.schedule_scroll uses for its own moving frame. A trailing
    -- debounce ahead of a pipeline that already has backpressure only adds
    -- latency, and under input faster than the debounce interval it can
    -- starve dispatch outright (it resets on every call rather than firing on
    -- a schedule). Kept as a knob rather than removed: set above 0 to
    -- deliberately throttle preview requests.
    preview_debounce_ms = 0,
    -- `v`/`V` in the preview: extend a real DOM selection from the caret with
    -- ordinary motions, instead of Neovim's own visual mode, which over a
    -- surface of blank cells would only ever select spaces.
    visual = true,
    fast_preview = false,
    -- **Do not set "on" for WezTerm.** It draws correctly there and exhausts
    -- your memory within seconds of a held-down selection extension -- an
    -- upstream defect. The measurements and the issue numbers are in
    -- terminal.lua's wezterm profile and docs/terminal-support.md.
    selection_overlay = "auto",
    settle_ms = 120,
    copy = true,
    -- Disabled by default: neither VS Code nor a browser copies on every
    -- selection change, and silently overwriting the user's clipboard on each
    -- extension would be hostile.
    copy_on_select = false,
    find = true,
    -- How many "markdown preview documents" this plugin remembers.
    -- Bounded rather than unbounded: each entry pins a buffer number and a
    -- path, and a reader following links for an hour should not accumulate an
    -- ever-growing list.
    history_limit = 32,
    -- Which physical key activates each preview-tab action. Either key can be
    -- set to `false` to leave that action unmapped.
    keymaps = {
      tab_previous = "H",
      tab_next = "L",
    },
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
  assert(
    cfg.render.location == "current" or cfg.render.location == "local",
    'md-viewer: render.location must be "current" or "local" ("auto" is deliberately not accepted '
      .. "until the local path has been validated on a real slow link)"
  )
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
    cfg.render.ssh_link_bytes_per_sec == nil
      or cfg.render.ssh_link_bytes_per_sec == "auto"
      or (type(cfg.render.ssh_link_bytes_per_sec) == "number" and cfg.render.ssh_link_bytes_per_sec > 0),
    'md-viewer: render.ssh_link_bytes_per_sec must be a positive number, "auto" to use a measurement '
      .. "cached on this machine, or nil when the link rate is unknown"
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
  assert(tri_state[cfg.image.resident], 'md-viewer: image.resident must be "off", "auto" or "on"')
  assert(
    type(cfg.image.resident_below_bytes_per_sec) == "number" and cfg.image.resident_below_bytes_per_sec > 0,
    "md-viewer: image.resident_below_bytes_per_sec must be a positive number of bytes per second"
  )
  assert(
    type(cfg.image.resident_chunk_viewports) == "number"
      and cfg.image.resident_chunk_viewports >= 1
      and cfg.image.resident_chunk_viewports <= 8,
    "md-viewer: image.resident_chunk_viewports must be a number between 1 and 8"
  )
  assert(
    type(cfg.image.resident_memory_mb) == "number" and cfg.image.resident_memory_mb > 0,
    "md-viewer: image.resident_memory_mb must be a positive number"
  )
  assert(
    type(cfg.image.resident_max_chunks) == "number" and cfg.image.resident_max_chunks >= 1,
    "md-viewer: image.resident_max_chunks must be at least 1"
  )
  assert(type(cfg.browser.fast_png_encode) == "boolean", "md-viewer: browser.fast_png_encode must be boolean")
  assert(type(cfg.preview.loading) == "boolean", "md-viewer: preview.loading must be boolean")
  assert(
    type(cfg.preview.loading_interval_ms) == "number" and cfg.preview.loading_interval_ms > 0,
    "md-viewer: preview.loading_interval_ms must be positive"
  )
  local line_number_modes = { off = true, absolute = true, relative = true }
  assert(
    line_number_modes[cfg.preview.line_numbers],
    "md-viewer: preview.line_numbers must be off, absolute, or relative"
  )
  assert(
    cfg.preview.tab_accent == false
      or (type(cfg.preview.tab_accent) == "string" and cfg.preview.tab_accent:match("^#%x%x%x%x%x%x$") ~= nil),
    'md-viewer: preview.tab_accent must be a "#rrggbb" color or false'
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
  assert(type(cfg.obsidian.enabled) == "boolean", "md-viewer: obsidian.enabled must be boolean")
  assert(
    cfg.obsidian.vault_root == nil or (type(cfg.obsidian.vault_root) == "string" and cfg.obsidian.vault_root ~= ""),
    "md-viewer: obsidian.vault_root must be a non-empty path or nil"
  )
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
  assert(type(cfg.interaction.selection) == "boolean", "md-viewer: interaction.selection must be boolean")
  assert(
    type(cfg.interaction.preview_debounce_ms) == "number" and cfg.interaction.preview_debounce_ms >= 0,
    "md-viewer: interaction.preview_debounce_ms must be non-negative"
  )
  assert(type(cfg.interaction.fast_preview) == "boolean", "md-viewer: interaction.fast_preview must be boolean")
  assert(type(cfg.interaction.visual) == "boolean", "md-viewer: interaction.visual must be boolean")
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
  assert(type(cfg.interaction.find) == "boolean", "md-viewer: interaction.find must be boolean")
  assert(
    type(cfg.interaction.history_limit) == "number"
      and cfg.interaction.history_limit >= 1
      and cfg.interaction.history_limit == math.floor(cfg.interaction.history_limit),
    "md-viewer: interaction.history_limit must be a positive integer"
  )
  assert(type(cfg.interaction.keymaps) == "table", "md-viewer: interaction.keymaps must be a table")
  for _, name in ipairs({ "tab_previous", "tab_next" }) do
    local value = cfg.interaction.keymaps[name]
    assert(
      value == false or (type(value) == "string" and value ~= ""),
      ("md-viewer: interaction.keymaps.%s must be a non-empty string or false"):format(name)
    )
  end
  assert(
    type(cfg.interaction.external_open_timeout_ms) == "number" and cfg.interaction.external_open_timeout_ms >= 0,
    "md-viewer: interaction.external_open_timeout_ms must be non-negative"
  )
end

-- Two modules memoize a snapshot taken partly from this configuration -- the
-- terminal's capabilities and the link rate's precedence tier -- and a config
-- change is the one event that can invalidate either. Guarded on package.loaded
-- so configuring md-viewer does not load them as a side effect.
local function invalidate_memoized()
  for _, name in ipairs({ "md-viewer.terminal", "md-viewer.linkrate" }) do
    local module = package.loaded[name]
    if module and module.invalidate then module.invalidate() end
  end
end

-- Removed in 0.3.0 along with mouse click-drag, double-click and triple-click
-- selection. Checked against what the caller actually wrote rather than the
-- merged table, because `vim.tbl_deep_extend` keeps keys nothing declares --
-- which is exactly how these went on being silently accepted after the code
-- reading them was deleted. A list rather than a set so the error names the
-- same option on every run.
local removed_interaction = {
  "drag_threshold_cells",
  "double_click",
  "autoscroll",
  "autoscroll_interval_ms",
  "autoscroll_max_lines",
  "word_select",
  "paragraph_select",
}

-- `~= nil` rather than truthiness: `double_click = false` is still a setting
-- carried over from a configuration written against 0.2, and reading it as
-- "not set" would keep the exact silence this exists to end.
local function reject_removed(opts)
  if type(opts.interaction) ~= "table" then return end
  for _, name in ipairs(removed_interaction) do
    assert(
      opts.interaction[name] == nil,
      ("md-viewer: interaction.%s was removed in 0.3.0 with mouse selection. "):format(name)
        .. "Highlighting is now v/V plus the preview motion keys -- see :help md-viewer-visual. "
        .. "Remove this option."
    )
  end
end

function M.setup(opts)
  vim.validate({ opts = { opts or {}, "table" } })
  opts = vim.deepcopy(opts or {})
  reject_removed(opts)
  current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  validate(current)
  invalidate_memoized()
  return current
end

function M.get() return current end

function M.reset()
  current = vim.deepcopy(M.defaults)
  invalidate_memoized()
end

return M
