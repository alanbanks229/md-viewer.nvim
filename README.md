# md-viewer.nvim

**Browser-quality Markdown previews inside terminal Neovim.**

`md-viewer.nvim` opens a read-only split beside your Markdown source. A headless
Chromium page renders the unsaved buffer to viewport-sized PNGs, which Neovim
draws in the split through the Kitty graphics protocol. The source stays a
normal, editable Neovim buffer.

Mouse and keyboard gestures over the preview are forwarded to that live Chromium
DOM, which does the hit-testing, search and link resolution before the viewport
is recaptured. You get browser behaviour — but the preview is a PNG surface,
**NOT** native terminal text and not an embedded webview. The renderer opens no
window, starts no HTTP server, and listens on no port.

<!-- <img width="1470" height="892" alt="md-viewer.nvim preview" src="https://github.com/user-attachments/assets/ef40d45f-a5b6-4823-b961-bc904ee1e726" /> -->

## Features

| Feature | Notes |
|---|---|
| **Live preview of what you are typing** | Unsaved changes re-render as you edit, and the preview follows your cursor, so the picture and the buffer never drift apart |
| **Cursor/Caret - driven by Vim motions** | `hjkl`, `w`, `}`, `gg`, `G` and counts move a caret that lives in the rendered document; `v`/`V` extend a selection from it, and `y` copies to the unnamed register and the system clipboard. There is no click-and-drag selection — this is the only way to highlight text here |
| **Search with `/`, `n` and `N`** | Runs against the rendered page rather than the source |
| **A tab per document** | Scoped to the preview pane. Ctrl/Cmd-click a Markdown link to open one without disturbing your editable split; `[b`/`]b` cycle tabs, `H`/`L` walk history, and `gf` reveals the active document back in the source pane. Tabs are clickable in the winbar |
| **Obsidian wikilinks** — optional | `[[Note]]`, aliases, heading paths and block IDs resolve through those same tabs, with no obsidian.nvim runtime dependency |
| **Animated GIF and WebP** | Actually animate, drawn by the terminal over the still frame the screenshot captured. Off by default: `render.animate = true` |
| **Local rendering** — *experimental* | One answer to a slow SSH link: move the browser to your side of the connection entirely. `render.location = "local"` (`:help md-viewer-local`) |
| **Whole-document resident mode** — *experimental* | The other answer: hold the document in the terminal's image memory, so a scroll sends 196 bytes instead of a frame. Not available on iTerm2 or WezTerm. `image.resident = "auto"` (`:help md-viewer-resident`) |
| **A text-only fallback** | Where no graphical backend is available — with diagnostics that name the backend you got and why |

## Requirements

- **Neovim 0.12+.** The graphical backend writes escape sequences through
  `nvim_ui_send()`, which is a 0.12 API. On anything older there is no graphical
  path at all, so the plugin refuses to load.
- **Node.js 22.12+**, for the renderer process.
- **An existing Google Chrome, Chromium, or Microsoft Edge installation**, on
  whichever machine Neovim itself runs on. md-viewer never downloads a browser:
  Playwright's browser download is disabled in the install hook and no test or
  runtime path re-enables it.
- **A terminal that speaks the Kitty graphics protocol, used directly** — see
  [Terminal support](#terminal-support).
- **macOS or Linux.** CI runs the full suites on both, at the Node floor and at
  Node 24. Windows discovery paths have unit coverage but no CI, no live
  validation, and no terminal cell measurement — treat it as unsupported.

## Installation

### lazy.nvim

```lua
{
  "alanbanks229/md-viewer.nvim",
  version = "v0.3.0",
  ft = "markdown",
  cmd = { "MdViewerToggle", "MdViewerHealth", "MdViewerDebug" },
  opts = {},
}
```

**What the install hook is for.** md-viewer.nvim is not pure Lua. The part
that turns Markdown into an image is a Node.js program under `renderer/`, and
its third-party packages are not committed here — only a lockfile naming their
exact versions is. A freshly downloaded copy of the plugin is therefore not
runnable until `npm ci` has fetched those packages into `renderer/`.
`build.lua` is that one step. lazy.nvim finds and runs it on install and update
without being asked, which is why the spec above has no `build` key; other
plugin managers have to be pointed at it, as below.

Installing needs npm registry access, unless the locked packages are already
in npm's cache. No browser is ever downloaded — `build.lua` passes
`--ignore-scripts` and `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD`, and md-viewer drives
the Chrome, Chromium or Edge already on the machine.

<details>
<summary>Native <code>vim.pack</code> — untested by the author</summary>

`vim.pack` has no build hook, so run the same file from a `PackChanged`
autocmd. Register it before the first `vim.pack.add()` call, so it also runs on
a first-time installation:

```lua
vim.api.nvim_create_autocmd("PackChanged", {
  callback = function(event)
    local data = event.data
    if data.spec.name == "md-viewer.nvim"
        and (data.kind == "install" or data.kind == "update") then
      dofile(data.path .. "/build.lua")
    end
  end,
})

vim.pack.add({
  { src = "https://github.com/alanbanks229/md-viewer.nvim", version = "v0.3.0" },
})

require("md-viewer").setup({})
```

If the plugin was installed before the hook was added, run this once from the
repository's `renderer/` directory:

```sh
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts
```

If it does not work, please open an issue.

</details>

<details>
<summary>Other plugin managers, or running the hook by hand</summary>

Any manager that can run a Lua file after install works the same way —
`dofile` reads a Lua file and runs it immediately:

```lua
-- adjust the path to wherever your manager put the plugin
dofile(vim.fn.stdpath("data") .. "/site/pack/plugins/start/md-viewer.nvim/build.lua")
```

`vim.fn.stdpath("data")` is Neovim's data directory — `:echo stdpath("data")`
prints yours — and the rest is wherever your manager nests plugins under it.

Managers that only take a shell command can run the underlying command instead,
which installs exactly what the lockfile pins:

```sh
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
```

</details>

## First use

**`opts = {}` is a complete configuration.** Everything that can be detected is
detected: the terminal and its graphics protocol, the cell dimensions (measured
from the operating system, not estimated), the theme, and the document root that
bounds local links and images.

1. Open a Markdown file.
2. Run `:MdViewerToggle`.
3. If nothing appears, run `:MdViewerHealth` — it says why in one screen.

Then [docs/usage.md](docs/usage.md) or `:help md-viewer` has every command, key
and mouse gesture. `:MdViewerDebug` is what to attach to a bug report.

## Configuration

What `opts = {}` does *not* give you is the four features that cost something,
each off until you say otherwise:

| Off by default | Because |
|---|---|
| `render.animate` | Animation is redrawn frames; motion costs a stream of placements |
| `obsidian.enabled` | `[[Note]]` is not Markdown, and resolving it walks a vault |
| `image.resident` | Trades a long warm-up and a document of terminal memory for free scrolling — worth it only on a slow link |
| `render.location = "local"` | Needs a helper process running beside your terminal |

The handful most people set:

```lua
require("md-viewer").setup({
  split = { position = "right" },   -- right | left | below | above
  render = { animate = true },      -- animate GIF/WebP
  obsidian = { enabled = true },    -- [[wikilinks]]
})
```

That is a normal, complete setup. If your terminal is in the
[support table](#terminal-support) and Node and Chrome are installed, nothing
below is needed.

`:help md-viewer-options` lists **every option and its default** in one table,
and **[`lua/md-viewer/config.lua`](lua/md-viewer/config.lua)** carries the
reasoning behind each non-obvious one.

## Optional capabilities

The following capabilities are not setup automatically.

- **Over SSH** — run Neovim on the remote host as usual; Node.js and Chrome
  live there too, not on your laptop. [docs/ssh.md](docs/ssh.md) is the guide,
  written in the order you are likely to hit it:

  - *The preview falls back to text.* SSH does not forward `TERM_PROGRAM`, so
    the terminal has to be named:
    [make your terminal identifiable](docs/ssh.md#make-your-terminal-identifiable).
    This is the only step an SSH session actually requires.
  - *It works, but feels slow.* Every refresh ships a full-page PNG down the
    link. Start by measuring it —
    [`:MdViewerMeasureLink`](docs/ssh.md#measure-the-link), once per machine,
    cached for that machine. Several settings read that measurement instead of
    guessing, so it is worth doing before changing anything by hand.
  - *Slow enough that the picture is the whole cost.*
    [Local rendering](docs/ssh.md#local-rendering)
    (`render.location = "local"`) moves the browser to the machine your
    terminal is on, so no PNG ever crosses the link. It costs one change to how
    you connect — `ssh` launched through a small Node wrapper — and ssh.md has
    the exact command.

- **Resident mode** (`image.resident = "auto"`) — holds the whole document in
  the terminal's image memory, so a scroll sends a placement instead of a
  frame. This mode is still experimental.
  `:help md-viewer-resident`.

- **Obsidian wikilinks** (`obsidian.enabled = true`) — renders and follows
  `[[Note]]`, `[[path/to/Note]]`, `[[Note|Label]]`, `[[#Heading]]`,
  `[[Note#Parent#Child]]` and `[[Note#^block-id]]` through the same preview
  tabs. Bare names match filename stems case-insensitively, duplicates open
  `vim.ui.select`, a missing note warns rather than being created, and every
  path and symlink stays confined to the vault root. Embeds (`![[...]]`) and
  frontmatter aliases are not implemented.
  [obsidian.nvim](https://github.com/obsidian-nvim/obsidian.nvim) can point at
  the same vault — an optional companion, never a dependency.
  `:help md-viewer-obsidian`.

### Two options to leave unset

Both work out their answer per machine, and both stop being right the moment a
fixed value is written into a config that reaches more than one machine.

- **`render.ssh_link_bytes_per_sec`** — the default `"auto"` reads this
  machine's `:MdViewerMeasureLink` result, and a number outranks that on every
  machine the config file lands on. Measured 2026-08-25, two reference hosts
  sit fourteen times apart: 0.77–1.06 MB/s through an AWS SSM tunnel against
  14.7 MB/s to a LAN host. No single value is honest for both.
  [Where the AWS SSM ceiling comes from](docs/ssh.md#where-the-aws-ssm-ceiling-comes-from)
  has the working.

- **`obsidian.vault_root`** — the default `nil` detects the vault around the
  open note (the nearest ancestor holding `.git`, `.hg` or `.svn`), which
  handles any number of vaults. Setting it does not mean *the vault*, it means
  *the only vault*: notes anywhere else stop resolving. Set it only if you have
  exactly one vault and it carries no marker of its own.

## Terminal support

| Terminal | Status |
|---|---|
| iTerm2 3.5+ | Supported — full rendering, cursor navigation and highlighting. Resident mode is off here |
| Kitty | Supported — full rendering, cursor navigation and highlighting |
| Ghostty | Supported — validated on 1.3.1; there is no version gate in the code |
| WezTerm | Supported for rendering; the selection overlay, animation and resident mode are off, pending [wezterm#8035](https://github.com/wezterm/wezterm/pull/8035) |
| Warp | Experimental — rendering works, but the selection overlay and animation are off and visual selection may blank the preview ([warp#7789](https://github.com/warpdotdev/Warp/issues/7789)) |
| Any other terminal implementing the protocol | Should work, but nobody has watched it — graphical extras stay off by default |
| A terminal with no Kitty graphics support | Falls back to the text-only `cells` backend |

**tmux, GNU screen and Zellij are not supported.** No escape-sequence
passthrough is implemented for any of them; `:MdViewerHealth` detects a
multiplexer and reports it so the failure is diagnosable.

[docs/terminal-support.md](docs/terminal-support.md) holds the evidence behind
each row — read it before reporting a graphical bug or claiming a terminal works.

## Security

Runtime browser requests are always blocked, JavaScript is disabled in the render
context, and raw Markdown HTML is off. Remote images are fetched over https by
the renderer process, validated, and inlined, so the browser still makes no
requests; loopback, private and other non-public destinations are refused on the
initial URL and every redirect hop. Local images and links are confined to a
canonical document root — by default the project enclosing the document — with
symlinks resolved and executables refused.

A bare `<img src="url">` is parsed into an ordinary Markdown image whether or not
`security.raw_html` is on, carrying only `src`, `alt`, `title` and integer
`width`/`height`.

Read [SECURITY.md](SECURITY.md) before enabling `security.raw_html`, and
`:help md-viewer-security` for more.

## Known limitations

- The preview is a PNG surface, not an embedded webview, so a terminal
  implementing the Kitty graphics protocol is the floor for seeing anything.
- The first preview of a Neovim session waits for Chromium's one-off capture
  warm-up — measured at 9,874–16,335 ms on Ubuntu 22.04 / Chrome 151, and well
  under a second on macOS. Later previews in the same session do not pay it.
- Whole-document resident mode and local rendering are both experimental and off
  by default. Resident mode is additionally unavailable on iTerm2 and WezTerm,
  and animated images do not animate under it.
- Graphical confirmation is partial: image rendering and the selection overlay
  have been watched on real hardware, but most placement and occlusion behavior
  is covered by headless tests only.
- The `vim.ui.img` backend depends on an experimental Neovim API and is
  feature-tested at runtime.
- tmux, screen, and Zellij are not supported.

## Documentation

**Using it**

- [Usage](docs/usage.md) — every command, key and mouse gesture
- [Over SSH](docs/ssh.md) — terminal identification, measuring a throttled
  link, local rendering, and resident mode
- `:help md-viewer` — the same material inside Neovim, plus every option and its
  default (`:help md-viewer-options`)
- [Terminal support](docs/terminal-support.md) — per-terminal status, and the
  evidence behind each claim
- [Troubleshooting](docs/troubleshooting.md) — symptom by symptom
- [Security](SECURITY.md) — what the defaults enforce, and the two settings that
  widen them

**Working on it**

- [Contributing](CONTRIBUTING.md) — how to open a change
- [Development](docs/development.md) — tests, manual verification, releasing
- [Architecture](docs/architecture.md) — how it works, and which invariants matter
- [Changelog](CHANGELOG.md)

## License

MIT. See [LICENSE](LICENSE).
