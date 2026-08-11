# md-viewer.nvim

**Browser-quality Markdown previews inside terminal Neovim.**

<img width="1470" height="892" alt="md-viewer.nvim preview" src="https://github.com/user-attachments/assets/ef40d45f-a5b6-4823-b961-bc904ee1e726" />

`md-viewer.nvim` opens a read-only Neovim split beside your Markdown source. A
persistent headless Chromium page renders unsaved buffer contents to
viewport-sized PNGs, which Neovim places in the preview split through the Kitty
graphics protocol. The source buffer stays a normal, editable Neovim buffer.

> [!IMPORTANT]
> The preview is a browser-rendered PNG surface. Mouse and keyboard gestures are
> forwarded to the persistent Chromium DOM, which performs hit-testing,
> selection, search, and link resolution before the viewport is recaptured. That
> gives browser-like behavior — but it is **not** native terminal text selection
> or an embedded webview.
>
> Nothing opens an external browser window, starts an HTTP server, or listens on
> a port. Runtime browser network requests are always blocked; remote images
> are fetched by the renderer process and inlined, never loaded by the browser.
> Playwright browser downloads are disabled; the plugin uses an existing Chrome
> or Chromium installation.

## Features

- Live preview of unsaved buffer changes, with source-to-preview cursor following
- Headings, lists, task lists, tables, blockquotes, alerts, fenced code, and
  local syntax highlighting, in dark and light themes
- A real caret in the preview with Vim motions, counts, and keyboard selection
- Drag-to-select, double-click word and triple-click paragraph selection, with
  copy to the unnamed register and the system clipboard
- In-preview search with match highlighting and next/previous stepping
- Ctrl/Cmd-click link activation — `http(s)`, `mailto`, in-root local files, and
  same-document fragments — resolved through the rendered DOM, with back/forward
  history through the documents you follow
- Exact source-position reporting where the parser supports it, degrading
  honestly to line- or block-level precision rather than guessing
- Pinned previews that stay visible while the source split shows another file
- Local PNG, JPEG, GIF, and WebP images constrained to a document root, and
  remote images from any public HTTPS host — no configuration needed
- Animated GIFs and animated WebP can actually animate, with their own frame
  timing, drawn by the terminal on their own layer over the browser-painted
  still frame — terminal-driven playback where qualified, client-driven frame
  placement elsewhere. Off by default (`render.animate`); with it off the still
  first frame is what shows, so turning it on adds motion and nothing else
- Visible placeholders that say why an image was refused or failed instead of
  hiding it
- A text-cell fallback when no graphical backend is available
- Health and runtime diagnostics

## Requirements

- Neovim 0.12+
- Node.js 22.12+
- An existing Google Chrome, Chromium, or Microsoft Edge installation
- A terminal that advertises the Kitty graphics protocol, used without a
  multiplexer — see [terminal support](#terminal-support)

Kitty.app and the `kitty`/`kitten` executables are **not** required; any terminal
speaking the Kitty graphics protocol works. Installation needs npm registry
access unless the locked packages are already in a configured npm cache. Runtime
rendering is entirely local.

## Installation

The build hook installs the locked renderer dependencies. Both flags are
deliberate: `md-viewer.nvim` never runs `playwright install` and never downloads
a browser.

### lazy.nvim

```lua
{
  "alanbanks229/md-viewer.nvim",
  version = "v0.3.0",
  ft = "markdown",
  cmd = { "MdViewerToggle", "MdViewerHealth", "MdViewerDebug" },
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

### Native `vim.pack`

Register the build hook before the first `vim.pack.add()` call, so it also runs
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
  { src = "https://github.com/alanbanks229/md-viewer.nvim", version = "v0.3.0" },
})

require("md-viewer").setup({ image = { backend = "kitty_raw" } })
```

If the plugin was installed before the hook was added, run this once from the
repository's `renderer/` directory:

```sh
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts
```

## Configuration

The minimal setup is one option:

```lua
require("md-viewer").setup({
  image = { backend = "kitty_raw" },
})
```

The explicit `kitty_raw` is intentional. `auto` will not assume raw-protocol
support from `TERM_PROGRAM` alone, so it falls back to text-only rendering
instead of guessing.

A few overrides people commonly want:

```lua
require("md-viewer").setup({
  image = { backend = "kitty_raw" },
  split = { position = "right", width = 0.48 },
  render = { theme = "auto" },           -- "auto", "light", or "dark"
  sync  = { cursor_follow = true },
})
```

**Everything else lives in
[`lua/md-viewer/config.lua`](lua/md-viewer/config.lua)**, which carries every
option and default alongside the reasoning behind each non-obvious one. That is
the reference — this README does not duplicate it. `:help md-viewer-config`
describes the option groups and the handful that need more than a default value.

Terminal cell dimensions need no configuration: md-viewer measures them from
the operating system and sizes the render to match, which `:MdViewerHealth`
reports as `viewport calibration: measured`. Where nothing can be measured —
tmux and screen do not propagate pixel geometry — it reports `estimated` and
falls back to a bounded guess, which still renders but is not pixel-exact.

To override the measurement, supply the cell size in **CSS** pixels, which is
the measured size divided by `render.device_scale_factor` (so a 2x display
measuring 14×32 wants 7 and 16):

```sh
export MD_VIEWER_CELL_WIDTH_PX=7
export MD_VIEWER_CELL_HEIGHT_PX=16
```

## Usage

Open a Markdown buffer and run `:MdViewerToggle`.

| Command | Action |
|---|---|
| `:MdViewerToggle [right\|left\|below\|above]` | Open or close the preview |
| `:MdViewerCopy` | Copy the current selection |
| `:MdViewerFind [query]` | Search the rendered preview; prompts if no query is given |
| `:MdViewerFindNext` / `:MdViewerFindPrevious` | Step through matches |
| `:MdViewerBack` / `:MdViewerForward` | Move through followed-link history |
| `:MdViewerHealth` | Short status: is this set up to work, and if not, why |
| `:MdViewerDebug` | Full diagnostic — attach this to a bug report |
| `:checkhealth md-viewer` | Run Neovim health checks |

### Keys, with the preview focused

The preview has a real caret. It is a position in the rendered document rather
than a terminal cell, so it only ever sits on an actual character and is drawn
the size of the glyph it is on.

| Key | Action |
|---|---|
| `h` `l` `j` `k`, arrows | One character; one rendered line, holding its column |
| `0` `$` | Start and end of the rendered line |
| `w` `b` `e` | Next word, previous word, end of word |
| `{` `}` | Previous / next block |
| `Ctrl-d` `Ctrl-u` `Ctrl-f` `Ctrl-b` | Half a page, a page |
| `Ctrl-e` `Ctrl-y` | Scroll the view, leaving the caret where it is |
| `gg` `G` | Start and end of the document |
| `v` `V` `o` | Start a selection at the caret; line-wise; swap ends |
| `y` | Copy the selection |
| `/` `n` `N` | Search, next match, previous match |
| `H` `L` | Back / forward through followed-link history |

Counts work on every motion except `gg`/`G` — `10j`, `5w`, `3l`.

### Mouse

| Gesture | Action |
|---|---|
| Click and drag | Selects the dragged text (a real DOM selection) |
| Drag past the top/bottom edge | Keeps scrolling and extending the selection |
| Plain click | Clears an active selection; never moves the source cursor |
| Double-click / triple-click | Selects the word / the enclosing block |
| Ctrl-click / Cmd-click | Activates a link under the pointer |

A local Markdown link opens in Neovim, in the source window, and the preview
follows it, so a documentation tree can be read by clicking through it; `<C-o>`
returns. Copying is always manual — nothing reaches your clipboard on selection
unless you ask for it.

**`:help md-viewer` is the complete reference** for every command, key, gesture,
and interaction semantic.

## Terminal support

| Terminal | Status |
|---|---|
| iTerm2 3.5+ | Supported — image rendering and the drag-highlight overlay |
| Kitty | Supported — drag-highlight overlay confirmed |
| Ghostty 1.3.1 | Supported — drag-highlight overlay confirmed |
| WezTerm | Supported for image rendering; the overlay is deliberately off |
| Warp | Protocol-compatible, but never launched and unvalidated |

Every claim above carries an evidence label, and none is promoted on the strength
of an environment variable matching. macOS Terminal.app does not implement the
protocol and correctly degrades to the text-only `cells` backend. tmux, screen,
and Zellij are **not supported** — no escape-sequence passthrough is implemented
for any of them.

On WezTerm the instant drag-highlight overlay is off pending an upstream fix
([wezterm#8035](https://github.com/wezterm/wezterm/pull/8035), open as of
2026-08-09); drags there use the slower full-frame path, which is correct, and
you need do nothing.

See [docs/terminal-support.md](docs/terminal-support.md) before reporting a
graphical bug or claiming a terminal works.

## Security

Runtime browser requests are always blocked, JavaScript is disabled in the
render context, and raw Markdown HTML is off. Remote images are fetched over
https by the renderer process, validated, and inlined, so the browser still
makes no requests; requests to loopback, private, link-local, and other
non-public network destinations are refused, on the initial URL and on every
redirect hop — not something to configure, just how it works. Local images and
local links are confined to a canonical document root — by default the project
enclosing the document — with symlinks resolved. Interaction adds no new
attack surface: nothing re-parses Markdown or touches the filesystem on a
click, and diagnostics report selection and search state as lengths and counts
only.

Both `![alt](url)` and a bare `<img src="url">` go through that same path; an
`<img>` is parsed into an ordinary Markdown image whether or not
`security.raw_html` is on, and carries only `src`, `alt`, `title`, and integer
`width`/`height`. The screenshot at the top of this file is one, fetched from
GitHub's attachment host with no setup required.

Read [SECURITY.md](SECURITY.md) before enabling `security.raw_html`; it is
reported as an override by `:MdViewerHealth`.

## Known limitations

- The preview is a PNG surface, not native terminal text or an embedded webview.
- Source-position precision degrades honestly (exact byte column → line → block →
  none) depending on what the Markdown parser can establish; it is never guessed.
- Graphical confirmation is partial: image rendering and the drag overlay have
  been watched on real hardware, but most placement and occlusion behavior is
  covered by headless tests only.
- The drag-highlight overlay is off on WezTerm pending an upstream fix, and
  animated images are off there for the same reason.
- Animated images are decoded by the same Chromium that renders the preview,
  at the size they are actually drawn. Typical GIFs start moving in well under
  a second; a very long retina-scale recording can take a few, and the still
  frame shows throughout. Long recordings are thinned to a fixed pixel budget
  (duration preserved, motion choppier) rather than allowed to grow terminal
  memory without bound.
- tmux, screen, and Zellij are not supported.
- The `vim.ui.img` backend depends on an experimental Neovim API and is
  feature-tested at runtime.

## Documentation

- `:help md-viewer` — complete command, key, and configuration reference
- [Terminal support](docs/terminal-support.md) — does it work in your environment
- [Troubleshooting](docs/troubleshooting.md) — what to do when it doesn't
- [Architecture](docs/architecture.md) — how it works, and which invariants matter
- [Security](SECURITY.md) — the trust boundary
- [Development](docs/development.md) and [Contributing](CONTRIBUTING.md) — how to
  work on it
- [Changelog](CHANGELOG.md)

## License

MIT. See [LICENSE](LICENSE).
