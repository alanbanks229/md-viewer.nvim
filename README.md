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
| **Whole-document resident mode** — *experimental* | The other answer: hold the document in the terminal's image memory, so a scroll sends 196 bytes instead of a frame. `image.resident = "auto"` (`:help md-viewer-resident`) |
| **A text-only fallback** | Where no graphical backend is available — with diagnostics that name the backend you got and why |

> ### ⓘ Usage
>
> See **[docs/usage.md](docs/usage.md)** or `:help md-viewer` for more details on usage.
> 
> To start off, open a markdown file buffer, focus the pane and run `:MdViewerToggle`.
> 
> If the preview does not appear `:MdViewerHealth` says why.


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
- **macOS or Linux.** CI runs the full suites on both. Windows has code paths but
  no test coverage, and terminal cell measurement has no Windows implementation.


> ### ⓘ Installation Note:
>
> Installing needs npm registry access unless the locked packages are already cached.
>
> Rendering is entirely local — the browser makes no network requests under any configuration.

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
  opts = {}, -- Leave empty or see lua/md-viewer/config.lua
}
```

Then open a Markdown buffer and run `:MdViewerToggle`. If nothing appears,
`:MdViewerHealth` says why in one screen.

<details>
<summary>Native <code>vim.pack</code> — untested by the author</summary>

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

require("md-viewer").setup({})
```

If the plugin was installed before the hook was added, run this once from the
repository's `renderer/` directory:

```sh
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts
```

If it does not work, please open an issue.

</details>

## Configuration

`opts = {}` is a complete configuration. Everything that can be detected is
detected: the terminal and its graphics protocol, the cell dimensions (measured
from the operating system, not estimated), the theme, and the document root that
bounds local links and images. `:help md-viewer-options` lists all 70 options
with their defaults, and
**[`lua/md-viewer/config.lua`](lua/md-viewer/config.lua)** carries the reasoning
behind each non-obvious one.

What `opts = {}` does *not* give you is the four features that cost something,
each off until you say otherwise:

| Off by default | Because |
|---|---|
| `render.animate` | Animation is redrawn frames; motion costs a stream of placements |
| `obsidian.enabled` | `[[Note]]` is not Markdown, and resolving it walks a vault |
| `image.resident` | Trades a long warm-up and a document of terminal memory for free scrolling — worth it only on a slow link |
| `render.location = "local"` | Needs a helper process running beside your terminal |

Two examples follow: what most people set, and what one config shared across a
fast machine and a slow one looks like.

### The handful most people set

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

### One config across several machines

The case the experimental options exist for: a single `~/.config/nvim` reaching
a fast desk machine and a slow remote one, where the right answer differs per
machine and the config file cannot know which it is on. Both machine-dependent
decisions resolve at runtime rather than being written down here.

```lua
{
  "alanbanks229/md-viewer.nvim",
  version = "v0.3.0",
  ft = "markdown",
  cmd = { "MdViewerToggle", "MdViewerHealth", "MdViewerDebug", "MdViewerMeasureLink" },
  build = build_renderer,   -- the Installation hook above, lifted to a local function
  opts = {
    obsidian = { enabled = true },
    render = {
      animate = true,
      -- Local rendering, when a helper is wrapping this ssh session. There is
      -- deliberately no autodetection, so gate it on a variable of your own and
      -- export it only in the sessions you launch through the helper:
      --
      --   laptop$ node <md-viewer>/renderer/src/local-main.js -- ssh <host>
      --   host$   MD_VIEWER_LOCAL=1 nvim notes.md
      --
      -- MD_VIEWER_LOCAL is your variable, not md-viewer's. Without it, or
      -- opened outside the wrapper, this reads "current" and nothing changes.
      location = vim.env.MD_VIEWER_LOCAL and "local" or "current",
    },
    image = {
      -- Resident mode where it pays and nowhere else. "auto" is the link
      -- question, not the terminal question: it turns on only where the
      -- terminal supports it *and* this machine has measured a link under
      -- image.resident_below_bytes_per_sec (4 MB/s). It never measures on its
      -- own — run :MdViewerMeasureLink once per machine — so an unmeasured
      -- machine keeps the ordinary path, which is the right default for one.
      resident = "auto",
      -- 512 MB held 3 of 6 chunks on a 364-line document, so every scroll past
      -- a boundary cost a fresh capture. 1024 holds it whole. :MdViewerHealth
      -- names the figure for whatever document is open.
      resident_memory_mb = 1024,
    },
  },
  keys = {
    { "<leader>mp", "<cmd>MdViewerToggle<cr>", desc = "Markdown preview" },
    { "<leader>mh", "<cmd>MdViewerHealth<cr>", desc = "Markdown preview health" },
  },
}
```

Nothing above needs a `config = function` or a per-host branch you maintain
yourself. `:MdViewerDebug`'s `render_path` and `render_path_reason` say which
rendering model a preview actually chose and why, in the same words as the
options that decided it.

One option is a trap in a config like that, and it is
**`render.ssh_link_bytes_per_sec`**: leave it unset. The default, `"auto"`, reads
a per-machine measurement, and a number written here outranks that on *every*
machine the file reaches. The two hosts behind the config above are fourteen
times apart — 0.77–1.06 MB/s through an AWS SSM tunnel against 14.7 MB/s to a
LAN host, both measured 2026-08-25 — so no single value is honest, and erring
high is the exact failure the option exists to correct.

### Obsidian wikilinks (optional)

With `obsidian.enabled`, md-viewer renders and follows `[[Note]]`,
`[[path/to/Note]]`, `[[Note|Label]]`, `[[#Heading]]`, `[[Note#Parent#Child]]`,
and `[[Note#^block-id]]` through the same preview tabs. Bare note names match
case-insensitively by filename stem; duplicates open `vim.ui.select`. Missing
notes are never created, and every path and symlink stays confined to the vault
root. Embeds (`![[...]]`) and frontmatter aliases are not implemented.

`obsidian.vault_root` defaults to the same root local-link security uses — the
nearest ancestor holding `.git`, `.hg` or `.svn` — which makes every git-rooted
vault work. Setting it does not mean "the vault", it means "the only vault":
md-viewer then requires the open file to sit inside it, and notes outside resolve
`outside_root` with each wikilink refusing to follow. Set it only if you have
exactly one vault and it has no marker of its own.

[obsidian.nvim](https://github.com/obsidian-nvim/obsidian.nvim) is an optional
editing companion, not a dependency, and can point at the same vault. The
responsibilities stay separate: md-viewer owns rendered previews and preview-tab
wikilinks; obsidian.nvim provides completion, LSP navigation, backlinks, rename,
and note operations.

Reference: `:help md-viewer-obsidian`.

## Working over SSH

To have this working you need Node.js and Chrome on the **remote** host.
Your local terminal also needs to be identifiable when connecting — AFAIK, SSH does not forward `TERM_PROGRAM`. 
- **[docs/ssh.md](docs/ssh.md)** has the
`~/.ssh/config` sample, the profile override for terminals that export no identity, and what to do when it works but you have a slow ssh bandwidth.

## Terminal support

| Terminal | Status |
|---|---|
| iTerm2 3.5+ | Supported — full rendering, cursor navigation and highlighting. |
| Kitty | Supported — full rendering, cursor navigation and highlighting. |
| Ghostty 1.3.1+ | Supported — full rendering, cursor navigation and highlighting. |
| WezTerm | Supported only for rendering; the selection overlay and animations are off, pending [wezterm#8035](https://github.com/wezterm/wezterm/pull/8035) |
| Warp | Experimental — rendering works, but the selection overlay and animation are off and visual selection may blank the preview ([warp#7789](https://github.com/warpdotdev/Warp/issues/7789)) |
| other... | Potentially Limited, if terminal has no Kitty graphics support. Will fall back to text-only `cells` backend |

**tmux and Zellij are not supported for now...** No escape-sequence passthrough is implemented for either, more research needs to be looked into for this.

[docs/terminal-support.md](docs/terminal-support.md) holds the evidence behind each row — read it before reporting a graphical bug or claiming a terminal works.


## Security

Runtime browser requests are always blocked, JavaScript is disabled in the render context, and raw Markdown HTML is off. Remote images are fetched over https by the renderer process, validated, and inlined, so the browser still makes no requests; loopback, private and other non-public destinations are refused on the initial URL and every redirect hop. Local images and links are confined to a
canonical document root — by default the project enclosing the document — with symlinks resolved and executables refused.

A bare `<img src="url">` is parsed into an ordinary Markdown image whether or not
`security.raw_html` is on, carrying only `src`, `alt`, `title` and integer
`width`/`height`.

Read [SECURITY.md](SECURITY.md) before enabling `security.raw_html` and 
reference: `:help md-viewer-security` for more information.

## Known limitations

- The preview is a PNG surface, not an embedded webview, so a terminal
  implementing the Kitty graphics protocol is the floor for seeing anything.
- The first preview of a Neovim session waits for Chromium's one-off capture
  warm-up — measured at 9,874–16,335 ms on Ubuntu 22.04 / Chrome 151, and well
  under a second on macOS. Later previews in the same session do not pay it.
- Whole-document resident mode and local rendering are both experimental and off
  by default. Animated images do not animate under resident mode.
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
