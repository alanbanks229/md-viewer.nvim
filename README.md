# md-viewer.nvim

Browser-quality Markdown previews inside terminal Neovim.

> [!IMPORTANT]
> The preview is browser-rendered and rasterized. Preview text is not
> selectable. Source text remains editable and selectable.
>
> Rendering does not open an external browser window, start an HTTP server, or
> listen on localhost. Runtime browser network requests are blocked by default.
> The initial `npm ci` dependency installation may contact the npm registry.
> Playwright browser downloads are intentionally disabled; the plugin uses an
> existing Chrome or Chromium installation.

`md-viewer.nvim` opens a real, read-only Neovim split beside the Markdown
source. A persistent headless Chromium page renders unsaved buffer contents to
viewport-sized PNGs, which Neovim places in the preview split through the Kitty
graphics protocol. The source buffer stays a normal editable Neovim buffer.

The first public release is **v0.1.0-beta**. Its supported environment is:

- macOS
- iTerm2 3.5+ with Kitty graphics protocol support enabled, used without tmux
- Neovim 0.12+
- Node.js 22.12+
- an existing Google Chrome, Chromium, or Microsoft Edge installation

Kitty.app and the `kitty` or `kitten` executables are not required. Other
terminals, tmux, and non-macOS hosts are not part of the initial support matrix.

## Features

- Live preview of unsaved Markdown buffer changes
- Headings, lists, task lists, tables, blockquotes, alerts, fenced code, and
  local syntax highlighting
- Dark and light browser themes
- Source-to-preview cursor following
- Preview keyboard and mouse-wheel navigation
- Low-resolution moving frames followed by a Retina frame after scrolling
- Pinned previews that remain visible while the source split shows another file
- Local PNG, JPEG, GIF, and WebP images constrained to a document root
- A text-cell fallback when a graphical backend is unavailable
- Health and runtime diagnostics

## Requirements

The renderer dependencies are locked in `renderer/package-lock.json`.
Installation needs npm registry access unless those packages are already
available through a configured npm cache. Runtime rendering itself is local.

`md-viewer.nvim` never runs `playwright install` and never downloads a browser.
Set `browser.executable_path` if automatic discovery does not find an approved
installation.

## Installation

### lazy.nvim

```lua
{
  "alanbanks229/md-viewer.nvim",
  version = "v0.1.0-beta",
  ft = "markdown",
  cmd = {
    "MdViewerOpen",
    "MdViewerClose",
    "MdViewerToggle",
    "MdViewerRefresh",
    "MdViewerHealth",
    "MdViewerDebug",
  },
  build = function(plugin)
    local env = vim.fn.environ()
    env.PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1"
    local result = vim.system({ "npm", "ci", "--ignore-scripts" }, {
      cwd = plugin.dir .. "/renderer",
      env = env,
      text = true,
    }):wait()
    if result.code ~= 0 then
      error("md-viewer.nvim renderer installation failed:\n"
        .. (result.stderr or result.stdout or "unknown error"))
    end
  end,
  opts = {
    image = { backend = "kitty_raw" },
  },
}
```

The explicit `kitty_raw` selection is intentional for iTerm2. Automatic mode
will not assume raw-protocol support from `TERM_PROGRAM` alone.

### Native `vim.pack`

Register the build hook before the first `vim.pack.add()` call so it also runs
for a first-time installation:

```lua
vim.api.nvim_create_autocmd("PackChanged", {
  callback = function(event)
    local data = event.data
    if data.spec.name ~= "md-viewer.nvim"
        or (data.kind ~= "install" and data.kind ~= "update") then
      return
    end
    local env = vim.fn.environ()
    env.PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1"
    local result = vim.system({ "npm", "ci", "--ignore-scripts" }, {
      cwd = data.path .. "/renderer",
      env = env,
      text = true,
    }):wait()
    if result.code ~= 0 then
      error("md-viewer.nvim renderer installation failed:\n"
        .. (result.stderr or result.stdout or "unknown error"))
    end
  end,
})

vim.pack.add({
  {
    src = "https://github.com/alanbanks229/md-viewer.nvim",
    version = "v0.1.0-beta",
  },
})

require("md-viewer").setup({
  image = { backend = "kitty_raw" },
})
```

If the plugin was installed before the hook was added, run this once from the
repository's `renderer/` directory:

```sh
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts
```

Do not run `playwright install`.

## Configuration

```lua
require("md-viewer").setup({
  split = { position = "right", width = 0.48, min_width = 45 },
  preview = {
    pinned = true,
    winbar = true,
    loading = true,
    loading_interval_ms = 80,
  },
  render = {
    debounce_ms = 200,
    theme = "auto", -- "auto", "light", or "dark"
    raw_html = false,
    local_images = true,
    max_local_image_bytes = 10 * 1024 * 1024,
    device_scale_factor = 2,
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
  browser = {
    channel = "chrome",
    executable_path = nil,
    launch_timeout_ms = 10000,
  },
  image = {
    backend = "kitty_raw", -- "auto", "nvim_img", "kitty_raw", or "cells"
    zindex = 20,
    double_buffer = true,
    raw_zindex = -1,
    raw_statusline_guard_cells = 1,
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
    network = false,
    document_root = nil,
  },
})
```

`document_root` defaults to the Markdown file's directory. Unsaved buffers use
Neovim's current working directory. Local image authorization checks both the
lexical and canonical path, so symlinks cannot escape the root.

Exact terminal cell dimensions can be supplied with:

```sh
export MD_VIEWER_CELL_WIDTH_PX=10
export MD_VIEWER_CELL_HEIGHT_PX=20
```

Measure the active terminal profile rather than copying the example values.

### Backends

- `kitty_raw`: the supported graphical path for the initial iTerm2 release;
  explicit opt-in is required.
- `nvim_img`: uses Neovim's experimental `vim.ui.img` API when the installed
  build exposes `set` and `del`.
- `auto`: prefers a verified `vim.ui.img` API and otherwise uses `cells`; it
  does not silently select the raw protocol.
- `cells`: terminal-native text and extmark fallback without browser images.

## Usage

Open a Markdown buffer, then use:

| Command | Action |
|---|---|
| `:MdViewerOpen [right\|left\|below\|above]` | Open a preview split |
| `:MdViewerClose` | Close the active preview |
| `:MdViewerToggle [position]` | Toggle a preview |
| `:MdViewerRefresh` | Force a fresh render |
| `:MdViewerHealth` | Show environment and renderer checks |
| `:MdViewerDebug` | Show session, timing, and placement diagnostics |
| `:checkhealth md-viewer` | Run Neovim health checks |

When the preview has focus, `j`/`k`, arrow keys, Ctrl-e/Ctrl-y,
Ctrl-d/Ctrl-u, Ctrl-f/Ctrl-b, PageUp/PageDown, and `gg`/`G` move the rendered
viewport. The mouse wheel scrolls the preview only when the pointer is over it.

## How rendering works

One Node.js child process communicates with Neovim through newline-delimited
JSON over stdin/stdout. It keeps one headless Chromium browser, isolated
context, and page alive while previews are active. Markdown is parsed and
sanitized locally, the visible viewport is captured to a temporary PNG, and
only plugin-owned image IDs and temporary files are removed during cleanup.

There is no WebSocket, TCP connection, HTTP server, or listening port. See
[architecture](docs/architecture.md) and [security](docs/security.md) for the
full design.

## Security

By default, Playwright aborts browser requests except `data:` and `about:`
resources. The page uses a restrictive Content Security Policy, JavaScript is
disabled in its browser context, raw Markdown HTML is disabled, and remote
images are removed. Local images are converted to data URIs only after root,
realpath, file type, signature, and size checks.

Enabling `security.network` or `render.raw_html` relaxes the default policy and
is reported by the health command. Review [SECURITY.md](SECURITY.md) before
changing those options.

## Known beta limitations

- The rendered preview is a PNG surface, so its text cannot be selected,
  searched, copied, or interacted with. Use the source split for those actions.
- Direct iTerm2 use is the supported terminal configuration; tmux is untested.
- The `vim.ui.img` backend depends on an experimental Neovim API and is
  feature-tested at runtime.
- Graphical correctness still requires interactive terminal testing; headless
  tests cannot validate pixels, overlay behavior, or flicker.

See [troubleshooting](docs/troubleshooting.md) and the
[manual test checklist](docs/manual-testing.md) when reporting a graphical bug.

## Development

```sh
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
```

Contributor workflow, architecture notes, and release checks are in
[docs/development.md](docs/development.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
