# md-viewer.nvim

## Browser-quality Markdown previews inside terminal Neovim.

<img width="1470" height="892" alt="v0.1.0-beta" src="https://github.com/user-attachments/assets/ef40d45f-a5b6-4823-b961-bc904ee1e726" />

> [!IMPORTANT]
> The preview is still a browser-rendered PNG surface. Mouse and keyboard
> interactions are forwarded to the persistent Chromium DOM, which performs
> hit-testing, selection, search, and link resolution before the viewport is
> recaptured. This provides browser-like behavior but is **not** native
> terminal text selection or a real embedded webview. Source text remains
> separately, normally editable and selectable, as always.
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

Requirements:

- Neovim 0.12+
- Node.js 22.12+
- an existing Google Chrome, Chromium, or Microsoft Edge installation
- a terminal that advertises the Kitty graphics protocol, used without a
  multiplexer (see "Terminal support" below)

Kitty.app and the `kitty` or `kitten` executables are not required — any
terminal that speaks the Kitty graphics protocol works, not only Kitty
itself.

### Terminal support

md-viewer.nvim recognizes iTerm2, Kitty, WezTerm, Ghostty, and Warp. Only
iTerm2 and WezTerm have ever actually been launched and looked at on real
hardware, and only for basic image rendering — every interaction feature
(click, drag-to-select, search, copy, link activation) and every raw-image
placement fix shipped since has **no graphical confirmation on any
terminal**. `Protocol-compatible` is an honest, real status, not a lesser
form of "supported" — it means the terminal advertises what md-viewer needs
and nothing has been found broken, not that someone watched it work.

The full, terminal-by-terminal scenario matrix — with the four honest labels
this project uses (`Supported`, `Experimental`, `Protocol-compatible but
unvalidated`, `Unsupported`) — lives in
[docs/manual-testing.md](docs/manual-testing.md). Read it before reporting a
graphical bug or claiming a terminal works.

tmux, screen, and Zellij are **not supported and not advertised**: no
escape-sequence passthrough is implemented for any of them.
`:MdViewerHealth` detects a multiplexer and reports it so the failure mode is
diagnosable, but that is the entire extent of multiplexer support.

## Features

- Live preview of unsaved Markdown buffer changes
- Headings, lists, task lists, tables, blockquotes, alerts, fenced code, and
  local syntax highlighting
- Dark and light browser themes
- Source-to-preview cursor following
- Preview keyboard and mouse-wheel navigation
- Low-resolution moving frames followed by a Retina frame after scrolling
- Drag-to-select, double-click word selection, and triple-click paragraph
  selection, with copy to the unnamed register and (when available) the
  system clipboard
- In-preview search with match highlighting and next/previous stepping
- Ctrl/Cmd-click link activation: `http(s)`, `mailto`, in-root local files,
  and same-document fragment links, each resolved through the actual
  rendered DOM rather than the raw Markdown source
- Exact source-position reporting where the parser supports it, degrading
  honestly to line- or block-level precision rather than guessing
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
  version = "v0.3.0",
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
    version = "v0.3.0",
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
    -- Extra columns cut out past the trailing edge of a notification sitting
    -- over the preview. See "Notifications over the preview" below.
    raw_overlay_bleed_cells = 1,
    -- Pixel offset at which the image starts inside its first cell. Cancels a
    -- terminal that applies its window margin to text but not to graphics.
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
    network = false,
    document_root = nil,
    -- Identify the project enclosing the document when document_root is unset.
    document_root_markers = { ".git", ".hg", ".svn" },
  },
  terminal = {
    profile = "auto", -- "auto", or an explicit override: "iterm2", "kitty", "wezterm", "ghostty", "warp", "generic_kitty", "unknown"
    kitty_graphics = "auto", -- "auto", "on", or "off"
    probe = "off", -- "off" or "safe" -- an active runtime capability probe
  },
  interaction = {
    enabled = true,
    links = true,
    -- Cells the pointer must move past `press` before it counts as a drag
    -- rather than a click.
    drag_threshold_cells = 1,
    -- Gates installing the double/triple-click mappings at all.
    double_click = true,
    selection = true,
    drag_debounce_ms = 40,
    settle_ms = 120,
    copy = true,
    -- A plain click clears an existing selection; it never moves the source
    -- cursor under any gesture.
    copy_on_select = false,
    word_select = true,
    paragraph_select = true,
    find = true,
    -- How many documents back a preview remembers when a link retargets it.
    history_limit = 32,
    -- How long to watch a system handler started for an external link before
    -- assuming it is running normally.
    external_open_timeout_ms = 5000,
  },
})
```

`document_root` defaults to the **project** enclosing the Markdown file — the
nearest ancestor directory holding one of `document_root_markers`. With no
marker found it falls back to the file's own directory, and an unsaved buffer
uses Neovim's current working directory. Setting `document_root` explicitly
always wins.

The project default is what makes an ordinary repo-relative link work: a
document in `docs/` linking to `../README.md`, or to `docs/other.md` written
relative to the repository root, resolves rather than being refused. Containment
itself is unchanged — authorization checks both the lexical and the canonical
path, so a symlink still cannot escape the root, and neither can `../`.

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

### Notifications over the preview

With `kitty_raw`, the image is drawn by the terminal, not by Neovim, and
`raw_zindex = -1` puts it below text glyphs but *above* cell background colours.
A notification floating over the preview would therefore lose its own background
and show the Markdown through it, so md-viewer cuts the notification's rectangle
out of the image.

That cut is exact in cells, but some terminals — iTerm2 among them — apply their
horizontal window margin to text while placing graphics without it, which draws
the image a fraction of a cell toward the origin. Two settings deal with the
leftover:

- `raw_overlay_bleed_cells` (default `1`) cuts one extra column past the
  notification's trailing edge, so the overhang can never paint across it. The
  cost is a thin blank gap beside the notification instead of a flush edge.
- `raw_cell_offset_px` cancels the offset outright, if your terminal implements
  the Kitty protocol's `X`/`Y` placement keys. Measure it once: screenshot a
  notification over the preview and compare the x of the image's edge with the x
  of the notification's edge. Set `x` to the difference (10 for a 20px cell on
  iTerm2's defaults). When it works, the gap closes completely and you can drop
  `raw_overlay_bleed_cells` to `0`. `:MdViewerHealth` reports both values.

If a notification over the preview bothers you at all, positioning it elsewhere
(for `snacks.nvim`, `Snacks.notifier`'s placement options) avoids the overlap
entirely.

## Usage

Open a Markdown buffer, then use:

| Command | Action |
|---|---|
| `:MdViewerOpen [right\|left\|below\|above]` | Open a preview split |
| `:MdViewerClose` | Close the active preview |
| `:MdViewerToggle [position]` | Toggle a preview |
| `:MdViewerRefresh` | Force a fresh render |
| `:MdViewerCopy` | Copy the current selection (also `y` with the preview focused) |
| `:MdViewerClearSelection` | Clear the current selection without clicking |
| `:MdViewerFind [query]` | Search the rendered preview; prompts if no query is given (also `/`) |
| `:MdViewerFindNext` | Jump to the next match (also `n`) |
| `:MdViewerFindPrevious` | Jump to the previous match (also `N`) |
| `:MdViewerFindClear` | Clear the active search |
| `:MdViewerHealth` | Show environment and renderer checks |
| `:MdViewerDebug` | Show session, timing, and placement diagnostics |
| `:checkhealth md-viewer` | Run Neovim health checks |

When the preview has focus, `j`/`k`, arrow keys, Ctrl-e/Ctrl-y,
Ctrl-d/Ctrl-u, Ctrl-f/Ctrl-b, PageUp/PageDown, and `gg`/`G` move the rendered
viewport; `H`/`L` move back and forward through the documents you have followed
links into. The mouse wheel scrolls the preview only when the pointer is over
it.

### Mouse gestures

All of these are dispatched through the `interact` transport to the live
Chromium DOM — see the important note at the top of this document. Every
gesture is gated by its own `interaction.*` config flag; setting one to
`false` disables just that gesture without touching the others.

| Gesture | Action |
|---|---|
| Click and drag | Selects the dragged text (real DOM selection), matching browser/VS Code drag-select |
| Plain click | Clears an active selection. Never moves the source cursor, whether or not anything is selected. |
| Double-click | Selects the word under the pointer |
| Triple-click | Selects the enclosing paragraph/block |
| Ctrl-click / Cmd-click | Activates a link under the pointer: opens `http(s)`/`mailto` externally via `vim.ui.open`, opens an in-document-root local file, or scrolls to a same-document `#fragment`. Refuses (with a notification) any link resolving to an unsafe scheme (`javascript:`, `data:`, etc.) or escaping the document root. Over non-link text, it does nothing. |

The mouse pointer does **not** change shape over the preview. The preview is a
PNG, so only the terminal itself could change it (through `OSC 22`), and support
is inconsistent enough across terminals that the result was worse than no
feedback at all. Nothing is sent, and Neovim's global `'mousemoveevent'` is left
alone.

A link to a local file **opens in Neovim**, in the source window, and the preview
follows it, so a documentation tree can be read by clicking through it. `<C-o>`
returns. Files Neovim has no filetype for (a `.png`, a `.zip`) and PDFs still go
to the system handler via `vim.ui.open`; only Markdown re-points the preview.

A link is never handed to the system handler when the target is something the OS
would *run* — `.app`, `.command`, `.terminal`, `.workflow`, Windows executables,
`.desktop`/`.AppImage`/`.jar`, disk images, or any file with an execute bit. Those
are refused with a notification. The document root is not a defence here: a
repository you cloned can ship `setup.command` beside its README.

To make the preview open anything Neovim could open, set
`security.document_root = "/"`. That is supported and switches containment off
deliberately; keep `security.network = false` alongside it, and see
`docs/security.md` for the trade.

> **macOS note.** Both Ctrl-click and Cmd-click are mapped, but a terminal may
> claim either one before Neovim sees it — iTerm2 uses Cmd-click to open URLs
> itself, and some terminals emulate a right-click on Ctrl-click. If neither
> gesture activates a link, that binding is being intercepted by the terminal,
> not by md-viewer; check the terminal's own mouse settings.

#### Going back and forth between documents

Following a link retargets the preview, so without a way back the document the
reader came from is simply gone: `preview.pinned` deliberately stops the preview
following an ordinary buffer switch, so the source window's jump list moves the
*text* back and leaves the rendered view behind.

| Key / command | Action |
|---|---|
| `H` (preview window) / `:MdViewerBack` | Previous document in this preview's history. Moves the source window too. |
| `L` (preview window) / `:MdViewerForward` | Next document, after going back. |

`H` and `L` are installed by md-viewer in the preview window itself, beside the
keys it already owns there (`y`, `/`, `n`, `N`, `gg`, `G`) — nothing to add to
your config, and no leader prefix to collide with. They shadow "top/bottom of
screen", which addresses nothing in a scratch buffer holding no text. Both
commands work from either window if you would rather bind them globally.

`<C-o>` also works on its own: when the source window returns to a document this
preview has already shown, the preview follows it back. That is deliberately
narrow — only documents in this preview's own history qualify, so `pinned` still
holds for every other buffer switch.

Navigating from the middle of the history abandons the forward branch, the same
rule a browser follows. The list is capped at `interaction.history_limit` (32)
and holds a buffer and a path per entry, so an entry whose buffer has been wiped
still reopens its file.

Copying (`y` / `:MdViewerCopy`) is always manual — nothing is copied
automatically on selection unless `interaction.copy_on_select = true`, which
is off by default (silently overwriting the system clipboard on every drag
would be hostile).

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

Mouse and keyboard interaction adds no new attack surface of its own: every
gesture resolves against the same sanitized, already-rendered document —
nothing re-parses Markdown or re-touches the filesystem on a click, a drag,
or a search. Link activation and local-file opening independently re-check
the document root (mirroring the image-loading check, symlinks included) and
refuse anything outside it or carrying an unsafe scheme, and every search
match or selection is handled as plain text — a query or a selection
containing HTML is matched/copied literally, never interpreted as markup.
Diagnostics (`:MdViewerDebug`) report selection/search **lengths and counts
only**, never the selected or searched text itself.

Enabling `security.network` or `render.raw_html` relaxes the default policy and
is reported by the health command. Review [SECURITY.md](SECURITY.md) before
changing those options.

## Known beta limitations

- The rendered preview is a PNG surface, not native terminal text or a real
  embedded webview — see the note at the top of this document. Interaction
  is real, browser-backed hit-testing and DOM manipulation forwarded over
  the same local NDJSON transport as rendering, not terminal text selection.
- Source-position precision degrades honestly (exact byte column → line →
  block → none) depending on what the Markdown parser can establish for a
  given piece of content; it is never guessed or interpolated.
- Only iTerm2 and WezTerm have real historical confirmation, and only for
  basic image rendering — every interaction feature and every raw-image
  placement fix is graphically unvalidated on every terminal. See
  [Terminal support](#terminal-support) and
  [docs/manual-testing.md](docs/manual-testing.md).
- tmux, screen, and Zellij are not supported.
- The `vim.ui.img` backend depends on an experimental Neovim API and is
  feature-tested at runtime.
- Graphical correctness still requires interactive terminal testing; headless
  tests cannot validate pixels, overlay behavior, click accuracy, or flicker.

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
How this project versions and cuts releases, in plain language with worked
examples, is in [VERSIONING.md](VERSIONING.md).

## License

MIT. See [LICENSE](LICENSE).
