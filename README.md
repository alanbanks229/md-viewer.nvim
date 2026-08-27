# md-viewer.nvim

**Browser-quality Markdown previews inside terminal Neovim.**

<img width="1470" height="892" alt="md-viewer.nvim preview" src="https://github.com/user-attachments/assets/ef40d45f-a5b6-4823-b961-bc904ee1e726" />

`md-viewer.nvim` opens a read-only split beside your Markdown source. A headless
Chromium page renders the unsaved buffer to viewport-sized PNGs, which Neovim
draws in the split through the Kitty graphics protocol. The source stays a
normal, editable Neovim buffer.

Mouse and keyboard gestures over the preview are forwarded to that live Chromium
DOM, which does the hit-testing, search and link resolution before the viewport
is recaptured. Text highlighting works the same way, but only through vim-like
motions (`v`/`V` and the usual motion keys) — there is no click-and-drag
selection. You get browser behaviour — but the preview is a PNG surface,
**NOT** native terminal text and not an embedded webview.

The renderer opens no window, starts no HTTP server, and listens on no port.

## Requirements

- **Neovim 0.12+.** The graphical backend writes escape sequences through
  `nvim_ui_send()`, which is a 0.12 API. On anything older there is no graphical
  path at all, so the plugin refuses to load.
- **Node.js 22.12+**, for the renderer process.
- **An existing Google Chrome, Chromium, or Microsoft Edge installation**, on
  whichever machine Neovim itself runs on — see
  [Remote sessions over SSH](#remote-sessions-over-ssh). md-viewer never
  downloads a browser: Playwright's browser download is disabled in the install
  hook and no test or runtime path re-enables it.
- **A terminal that speaks the Kitty graphics protocol, used directly** — see
  [Terminal support](#terminal-support). Kitty.app and the `kitty`/`kitten`
  executables are not required; any terminal implementing the protocol works.
- **macOS or Linux.** CI runs the full suites on both. Windows has code paths but
  no test coverage, and terminal cell measurement has no Windows implementation.

Installing needs npm registry access unless the locked packages are already
cached. Rendering is entirely local — the browser makes no network requests under
any configuration.

## Terminal support

| Terminal | Status |
|---|---|
| iTerm2 3.5+ | Supported — full markdown rendering and fast interactions |
| Kitty | Supported — full markdown rendering and fast interactions |
| Ghostty 1.3.1+ | Supported — full markdown rendering and fast interactions |
| WezTerm | Supported — full markdown rendering with **slower interactions**; fast-path support is pending [wezterm#8035](https://github.com/wezterm/wezterm/pull/8035) |
| Warp | Experimental — markdown rendering works, but the selection highlight is buggy, animations are disabled, and visual selection may blank the rendered preview ([warp#7789](https://github.com/warpdotdev/Warp/issues/7789)) |
| macOS Terminal.app | Limited — no Kitty graphics support; falls back to the text-only `cells` backend |

**tmux and Zellij are not supported.** No escape-sequence passthrough is
implemented for any of them, and they do not propagate the terminal's pixel
geometry, which the preview is sized against.

[docs/terminal-support.md](docs/terminal-support.md) holds the evidence behind
each row — read it before reporting a graphical bug or claiming a terminal works.

### Remote sessions over SSH

md-viewer works over SSH, with one thing to install and one thing to know.

**Node.js and Chrome/Chromium go on the remote host, not on your laptop.** The
renderer runs wherever Neovim runs. It produces a PNG, and Neovim then writes
that PNG to your terminal as Kitty graphics escape sequences, which travel down
the SSH connection and are drawn by the terminal in front of you. A browser on
the local machine is never consulted and cannot be substituted.

**Terminal identification is the part that needs care.** md-viewer identifies
your terminal from environment variables, and SSH does not forward
`TERM_PROGRAM`. It does forward `LC_*` by default, so:

| Terminal | Over SSH |
|---|---|
| iTerm2, WezTerm | Detected automatically — both export `LC_TERMINAL`, which is forwarded |
| Kitty, Ghostty, Warp | Not detected — set the profile explicitly (below) |

Automatic detection needs the remote `sshd` to accept the forwarded variable.
Nearly every distribution ships `AcceptEnv LANG LC_*` in `/etc/ssh/sshd_config`
already; if yours does not, add it and reload `sshd`. Confirm with
`echo $LC_TERMINAL` on the remote host.

For anything not auto-detected, name the profile on the remote host — as an
environment variable, which travels with the session:

```sh
export MD_VIEWER_TERMINAL_PROFILE=kitty
```

or in the remote Neovim config, if that config is only ever used from one
terminal:

```lua
opts = { terminal = { profile = "kitty" } }
```

`:MdViewerDebug` reports `ssh session`, the detected profile, and the evidence
that produced it. If the profile is `unknown` on an SSH session it also prints a
caveat naming these fixes.

**Bandwidth.** Every refresh ships a full-page PNG down the connection as
base64, so on a throttled link the picture arrives late and scrolling lags
behind the wheel. md-viewer already does two things about this on an SSH
session, neither of which needs configuring: it captures the moving frame of a
scroll at half size (`render.ssh_scroll_scale`, 2.6× to 3× fewer bytes) and
restores full sharpness the moment scrolling stops, and it waits longer before
spending that sharp capture (`render.ssh_scroll_settle_ms`).

How throttled the link actually is, md-viewer cannot see: `nvim_ui_send` appends
to Neovim's own UI queue and returns, so timing a write measures the queue and
not the wire. `:MdViewerMeasureLink`, run once on a machine, measures it from a
subprocess and caches the answer there — which is per-machine on purpose, since
one `~/.config/nvim` reaches hosts that measured fourteen times apart.

Do **not** reach for `render.device_scale_factor = 1` here — it is a
calibration divisor rather than a size knob, and lowering it makes the frame
*larger*. `:help md-viewer-ssh` has the measurements, the tuning, and the rest
of the reasoning.

## Installation

The build hook installs the locked renderer dependencies. Both flags are
deliberate: `md-viewer.nvim` never runs `playwright install` and never downloads
a browser.

### lazy.nvim

```lua
{
  "alanbanks229/md-viewer.nvim",
  version = "v0.3.0-rc8",
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
  opts = {}, -- Leave empty or see lua/md-viewer/config.lua
}
```

### Native `vim.pack`

> [!NOTE]
> This path is untested by the author. If it does not work, please open an
> issue.

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
  { src = "https://github.com/alanbanks229/md-viewer.nvim", version = "v0.3.0-rc8" },
})

require("md-viewer").setup({})
```

If the plugin was installed before the hook was added, run this once from the
repository's `renderer/` directory:

```sh
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts
```

Then open a Markdown buffer and run `:MdViewerToggle`. If nothing appears,
`:MdViewerHealth` says why in one screen.

## Features

- Live preview of unsaved changes, following your cursor through the document.
- **Scrolling costs no screenshot** (experimental, off by default). Where the
  terminal supports it, the whole document is captured once, kept in the
  terminal's image memory, and scrolling becomes a placement command — measured
  at 196 bytes per scroll against the ~80 KB frame the per-scroll path sends.
  It trades a long warm-up for that, so it is worth turning on only where the
  per-scroll capture is what you are actually waiting on:
  `image = { resident = "auto" }`. See `:help md-viewer-resident`.
- A real caret in the preview, with Vim motions, counts, and `v`/`V` selection
  (iTerm2, Kitty and Ghostty only) — the only way to highlight text in the
  preview, matching Vim rather than a browser; `y` copies to the unnamed
  register and the system clipboard.
- Markdown-preview search with `/`, `n` and `N`.
- Ctrl/Cmd-click follows a link. A local Markdown link opens in Neovim and the
  preview follows it, with `H`/`L` history back and forward — so a documentation
  tree can be read by clicking through it.
- Animated GIF and WebP actually animate, drawn by the terminal over the still
  frame the screenshot captured. Off by default; `render.animate = true` turns
  it on.
- The preview stays visible while the source split shows another file.
- A text-only fallback where no graphical backend is available, and diagnostics
  that say which backend you got and why.

## Configuration

md-viewer needs none. `:help md-viewer-options` lists every option with its
default; **[`lua/md-viewer/config.lua`](lua/md-viewer/config.lua)** carries the
reasoning behind each non-obvious one.

Terminal cell dimensions need no configuration either: `md-viewer` measures them
from the operating system and sizes the render to match. `:help
md-viewer-calibration` covers the two cases where it cannot — and what to set
by hand when that happens.

## Usage

| Command | Action |
|---|---|
| `:MdViewerToggle [position]` | Open or close the preview (`right`, `left`, `below`, `above`) |
| `:MdViewerCopy` | Copy the current selection |
| `:MdViewerFind [query]` | Search the rendered preview; prompts if no query is given |
| `:MdViewerFindNext` / `:MdViewerFindPrevious` | Step through matches |
| `:MdViewerBack` / `:MdViewerForward` | Move through followed-link history |
| `:MdViewerHealth` | Short status: is this set up to work, and if not, why |
| `:MdViewerDebug` | Full diagnostic — attach this to a bug report |
| `:MdViewerMeasureLink` | Measure this SSH link's speed once, and cache it for this machine |
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

The mouse never highlights text — only `v`/`V` and the motion keys above do
that. What the mouse still does:

| Gesture | Action |
|---|---|
| Plain click | Places the caret; clears an active selection; never moves the source cursor |
| Ctrl-click / Cmd-click | Activates a link under the pointer |
| Scroll wheel | Scrolls the preview |

Copying is always manual — nothing reaches your clipboard on selection unless you
ask for it.

**`:help md-viewer` is the complete reference** for every command, key, gesture,
and interaction semantic.

## Security

Runtime browser requests are always blocked, JavaScript is disabled in the render
context, and raw Markdown HTML is off. Remote images are fetched over https by
the renderer process, validated, and inlined, so the browser still makes no
requests; requests to loopback, private, link-local, and other non-public
destinations are refused, on the initial URL and on every redirect hop — not
something to configure, just how it works. Local images and local links are
confined to a canonical document root — by default the project enclosing the
document — with symlinks resolved. Interaction adds no new attack surface:
nothing re-parses Markdown or touches the filesystem on a click, and diagnostics
report selection and search state as lengths and counts only.

Both `![alt](url)` and a bare `<img src="url">` go through that same path; an
`<img>` is parsed into an ordinary Markdown image whether or not
`security.raw_html` is on, and carries only `src`, `alt`, `title`, and integer
`width`/`height`. The screenshot at the top of this file is one, fetched from
GitHub's attachment host with no setup required.

Read [SECURITY.md](SECURITY.md) before enabling `security.raw_html`;
`:MdViewerDebug` reports it as `overrides: SECURITY RELAXED` so a relaxed
boundary is never something you have to infer from a config file.

## Known limitations

- The preview is a PNG surface, not an embedded webview, so a terminal
  implementing the Kitty graphics protocol is the floor for seeing anything at
  all.
- Animated images are decoded by the same Chromium that renders the preview, at
  the size they are actually drawn. Typical GIFs start moving in well under a
  second; a very long retina-scale recording can take a few, and the still frame
  shows throughout. Long recordings are thinned to a fixed pixel budget (duration
  preserved, motion choppier) rather than allowed to grow terminal memory without
  bound.
- Graphical confirmation is partial: image rendering and the selection overlay
  have been watched on real hardware, but most placement and occlusion behavior
  is covered by headless tests only.
- The selection-highlight overlay is off on WezTerm pending an upstream fix,
  and animated images and whole-document resident mode are off there for the
  same reason.
- The first preview of a Neovim session waits for Chromium's one-off capture
  warm-up, which is a fixed cost per renderer process and measured at 16-24
  seconds on a modest Linux VM and well under a second on macOS. Later previews
  in the same session do not pay it.
- Whole-document resident mode is experimental and off by default. Animated
  images do not animate under it, and the knobs below apply only once it is on.
- `image.resident_memory_mb` is a heuristic rather than a guaranteed ceiling:
  the bytes-per-resident-pixel figure it derives from is an iTerm2 measurement
  that a sustained-RSS run disagreed with by 34x, and other terminals are
  unmeasured. `image.resident_max_chunks` is the bound that holds regardless.
- tmux, screen, and Zellij are not supported.
- The `vim.ui.img` backend depends on an experimental Neovim API and is
  feature-tested at runtime.

## Documentation

**Using it**

- `:help md-viewer` — the complete command, key and configuration reference,
  including every option and its default (`:help md-viewer-options`)
- [Terminal support](docs/terminal-support.md) — per-terminal status, and the
  evidence behind each claim
- [Troubleshooting](docs/troubleshooting.md) — symptom by symptom
- [Security](SECURITY.md) — what the defaults enforce, and the two settings that
  widen them

**Working on it**

- [Contributing](CONTRIBUTING.md) — how to open a change
- [Development](docs/development.md) — tests, manual verification, releasing
- [Architecture](docs/architecture.md) — how it works, and which invariants matter
- [Rejected: client-side rendering](docs/local-render-design.md) — rendering
  where the terminal is, measured on a throttled link and turned down
- [Changelog](CHANGELOG.md)

## License

MIT. See [LICENSE](LICENSE).
