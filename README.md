# md-viewer.nvim

**Browser-quality Markdown previews inside terminal Neovim.**

<!--
  MOTION DEMO GOES HERE, above the still below.
  One unbroken 20-25s take: live-as-you-type -> cursor follow -> caret with Vim
  motions -> drag-select -> an animated GIF. Do not speed it up; the point is
  latency. See the release checklist for the shot list.
-->

<img width="1470" height="892" alt="md-viewer.nvim preview" src="https://github.com/user-attachments/assets/ef40d45f-a5b6-4823-b961-bc904ee1e726" />

`md-viewer.nvim` opens a read-only split beside your Markdown source. A headless
Chromium page renders the unsaved buffer to viewport-sized PNGs, which Neovim
draws in the split through the Kitty graphics protocol. The source stays a
normal, editable Neovim buffer.

Mouse and keyboard gestures over the preview are forwarded to that live Chromium
DOM, which does the hit-testing, selection, search and link resolution before the
viewport is recaptured. You get browser behaviour — but the preview is a PNG
surface, **NOT** native terminal text and not an embedded webview.

The renderer opens no window and starts no HTTP server, and the machine running
Neovim listens on nothing — it only ever dials out. The one thing that accepts a
connection is the optional [companion renderer](#rendering-on-the-machine-your-terminal-is-on),
which runs on the machine your terminal is on, listens on a `0600` unix socket,
and is never a TCP port.

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
| Warp | Experimental — markdown rendering works, but drag highlighting is buggy, animations are disabled, and visual selection may blank the rendered preview ([warp#7789](https://github.com/warpdotdev/Warp/issues/7789)) |
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
behind the wheel. md-viewer already does two things about this on an SSH session, both without
configuration:

- **`render.ssh_scroll_scale`** (default `0.5`) captures the moving frame of a
  scroll at half size — measured 2.6× to 3× fewer bytes per frame, while the
  sharp image comes back the moment scrolling stops. Lower it to `0.25` on a
  slower link, or set `render.scroll_scale` to pin one value regardless of
  session.
- **`render.ssh_scroll_settle_ms`** (default `400`, against `160` locally) waits
  longer before spending the expensive sharp capture. A mouse wheel delivers
  notches 50–150 ms apart, so a shorter delay reads an ordinary gap between two
  flicks as "stopped" and buys a full-size transfer the next notch immediately
  makes stale.

`render.debounce_ms` above its 200 ms default cuts how many refreshes an edit
produces.

> [!IMPORTANT]
> Do **not** reach for `render.device_scale_factor = 1` here. It is a
> calibration divisor, not a size knob: lowering it doubles the CSS viewport and
> makes the frame *larger* — measured at 80 KB → 224 KB — and it collapses the
> moving and settle frames into one capture, so the cheap scroll frame stops
> existing. The defaults are already the fastest configuration.

If the link is slow enough that this is still not comfortable, the bytes
themselves are the problem rather than any setting — and the next section is
about not sending them.

### Rendering on the machine your terminal is on

On a link with a hard throughput ceiling — an AWS SSM tunnel is a flat
0.80 MB/s — the wire time for one scroll frame is larger than the render and the
terminal decode put together. No setting fixes that, because the frame is the
cost. What fixes it is not sending the frame.

`bin/md-viewer-ssh` is a wrapper around `ssh` that does three things:

- runs a **companion renderer** on your local machine (a unix socket, mode
  `0600`, never a TCP port), so the remote Neovim can rasterize its preview
  where your terminal is;
- **filters ssh's stdout**, turning the ~60-byte transmission tokens the remote
  plugin then emits back into the Kitty graphics uploads your terminal expects —
  byte for byte the same stream it receives today;
- exports **`LC_MD_VIEWER`**, which is how the remote plugin finds out any of
  this exists.

> [!IMPORTANT]
> **A working `LC_TERMINAL` does not prove `LC_MD_VIEWER` will arrive.** Both
> rely on SSH's `SendEnv`/`AcceptEnv`, whose defaults are the glob `LANG LC_*` —
> but managed environments often replace that glob with an explicit list, and a
> variable this plugin invented will not be on it. The symptom is the confusing
> one: terminal detection works and client rendering silently does not happen.
> Run `echo "[$LC_MD_VIEWER]"` on the remote host before anything else. If it is
> empty, add `SendEnv LC_MD_VIEWER` to your local `~/.ssh/config` and
> `AcceptEnv LC_MD_VIEWER` to the remote `sshd_config` — **both ends**.

**Setup, once.** The wrapper runs on your *local* machine, so that machine needs
a checkout of this repository with the renderer installed — the same two
commands the plugin's build hook runs on the remote host. Your Neovim
configuration is not involved; the plugin is not being loaded here, only its
renderer:

```sh
git clone https://github.com/alanbanks229/md-viewer.nvim ~/.local/share/md-viewer.nvim
cd ~/.local/share/md-viewer.nvim
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
ln -s "$PWD/bin/md-viewer-ssh" ~/.local/bin/md-viewer-ssh   # or wherever your PATH points
```

If you already run md-viewer locally too, point the symlink at that checkout
instead of cloning a second one.

**Then start sessions through it instead of `ssh`:**

```sh
# Straightforward case: let the wrapper set up the reverse forward.
md-viewer-ssh -R 4445:"$(md-viewer-ssh --md-viewer-print-socket)" \
              --md-viewer-addr 127.0.0.1:4445 my-remote-host
```

`ssh -R <port>:<local socket path>` is a supported OpenSSH form, and it is what
keeps the invariant intact: **the machine running Neovim still opens no port.**
It dials outward to a loopback address, and the listener on that end belongs to
`sshd` because you asked for a forward.

If the forward already exists — many organizations have a wrapper script that
sets up a fixed set of them — reuse it and just name the remote-side address:

```zsh
# Whatever already builds your ssh command, add one entry:
#   -R 4445:/run/user/$UID/md-viewer-$UID.sock       (or the path printed by
#                                                     --md-viewer-print-socket)
md-viewer-ssh --md-viewer-addr 127.0.0.1:4445 my-remote-host
```

Or set it on the remote host instead, where it travels with the session:

```sh
export MD_VIEWER_CLIENT_ADDR=127.0.0.1:4445
```

**Nothing new is installed.** The companion is the renderer this plugin already
ships, run from the checkout on your local machine; it needs the same Node and
Chrome/Chromium the remote host needs, and it never downloads a browser.

**Nothing changes when it is not there.** No wrapper means no `LC_MD_VIEWER`,
which means the plugin never emits a token and behaves exactly as it does today.
A companion that dies mid-session falls back to rendering beside Neovim with one
notification. `:MdViewerHealth` reports whether client rendering is in force
and, when it is not, which of the four preconditions is missing;
`:MdViewerDebug` reports `client_frame_count` and `client_bytes_deferred` — the
pixels that stayed put.

**What it does not do yet.** Two things still need the renderer to be on the
machine the *file* is on, and fall back when it is not: a local image embedded
in the document shows its failure placeholder, and an animated image stays on
its still frame. Remote `https` images are fetched by your local machine
instead of the remote one, which is usually an improvement and is a change of
trust boundary either way — see [SECURITY.md](SECURITY.md).
`:MdViewerHealth` notes all of this whenever client rendering is on.
[docs/local-render-design.md](docs/local-render-design.md) has the measurements,
the architecture and what remains.

## Installation

The build hook installs the locked renderer dependencies. Both flags are
deliberate: `md-viewer.nvim` never runs `playwright install` and never downloads
a browser.

### lazy.nvim

```lua
{
  "alanbanks229/md-viewer.nvim",
  version = "v0.1.1",
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

> [!IMPORTANT]
> I haven't personally used vim.pack but this is the likely setup: If it does not work, please let me know!

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
  { src = "https://github.com/alanbanks229/md-viewer.nvim", version = "v0.1.1" },
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

## Features!!

- Live preview of unsaved changes, following your cursor through the document.
- (Iterm, Ghostty, Kitty only) A real caret in the preview, with Vim motions, counts, and `v`/`V` selection.
- Drag-to-select; double-click for a word, triple-click for a block; `y` copies
  to the unnamed register and the system clipboard.
- Markdown-preview search with `/`, `n` and `N`.
- Ctrl/Cmd-click follows a link. A local Markdown link opens in Neovim and the
  preview follows it, with `H`/`L` history back and forward — so a documentation
  tree can be read by clicking through it.
- Animated GIF and WebP actually animate, drawn by the terminal over the still
  frame the screenshot captured.
    - Off by default (`render.animate`) will turn it on.
- Previews will stay visible while the source split shows another file.
- A text-only fallback where no graphical backend is available, and diagnostics
  that say which backend you got and why.

## Configuration

Please see **[`lua/md-viewer/config.lua`](lua/md-viewer/config.lua)**, which carries every option and default alongside the reasoning behind each non-obvious one.
`:help md-viewer-config` describes the option groups and the handful that need more than a default value.

Terminal cell dimensions need no configuration either: `md-viewer` measures them
from the operating system and sizes the render to match. `:help
md-viewer-calibration` covers the two cases where it cannot — and what to set
by hand when that happens.

## Usage

| Command | Action |
|---|---|
| `:MdViewerToggle` | Open or close the preview |
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

- The preview is a actually a PNG surface and not an embedded webview, this obviously presents some challenges.
  - Terminal emulators that have kitty protocol are a minimum to have this working (image rendering).
  - Animated images are decoded by the same Chromium that renders the preview, at
  the size they are actually drawn. Typical GIFs start moving in well under a
  second; a very long retina-scale recording can take a few, and the still frame
  shows throughout. Long recordings are thinned to a fixed pixel budget (duration
  preserved, motion choppier) rather than allowed to grow terminal memory without
  bound.
  - Graphical confirmation is partial: image rendering and the drag overlay have
  been watched on real hardware, but most placement and occlusion behavior is
  covered by headless tests only.
  - The drag-highlight overlay is off on WezTerm pending an upstream fix, and
  animated images are off there for the same reason.
  - tmux, screen, and Zellij are not supported.
  - The `vim.ui.img` backend depends on an experimental Neovim API and is
  feature-tested at runtime.

## Documentation

**Using it**

- `:help md-viewer` — the complete command, key and configuration reference
- [Terminal support](docs/terminal-support.md) — per-terminal status, and the
  evidence behind each claim
- [Troubleshooting](docs/troubleshooting.md) — symptom by symptom
- [Security](SECURITY.md) — what the defaults enforce, and the two settings that
  widen them

**Working on it**

- [Contributing](CONTRIBUTING.md) — how to open a change
- [Development](docs/development.md) — tests, manual verification, releasing
- [Architecture](docs/architecture.md) — how it works, and which invariants matter
- [Client-side rendering](docs/local-render-design.md) — why a preview lags on a
  throttled link, and the design for rendering where the terminal is
- [Changelog](CHANGELOG.md)

## License

MIT. See [LICENSE](LICENSE).
