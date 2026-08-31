# Architecture

## The short version

md-viewer.nvim shows your Markdown the way a browser would, inside a normal
Neovim split. It does that by actually using a browser: a headless Chromium
page renders the buffer, and what you see in the preview is a screenshot of
that page, redrawn as you edit, scroll, and interact.

Three processes are involved. The Lua plugin inside Neovim owns the windows,
commands, and input. It talks to a single long-lived Node.js renderer over
stdin/stdout, and the renderer drives headless Chromium — kept alive between
frames, because starting a browser is expensive while recapturing a page is
cheap. Neither the plugin nor the renderer opens a listening port, and there
is no embedded webview; the preview is an image in a terminal.

Rendering in a real browser buys real layout — CSS, tables, syntax
highlighting — plus the things an image converter would have to fake:
clickable links, find-in-page, and real text selection. What it costs is
pixels: every frame is a PNG that has to reach your terminal, which is why
slow SSH links get their own guide in [ssh.md](ssh.md).

## How a preview reaches your terminal

```text
┌──────────────────┐
│  Markdown buffer │   the file you're editing, untouched
└────────┬─────────┘
         │ buffer text, scroll position, gestures
┌────────▼─────────┐
│  md-viewer.nvim  │   Lua: commands, windows, geometry,
│  (inside Neovim) │   input capture in the preview split
└────────┬─────────┘
         │ JSON over stdio (one long-lived process)
┌────────▼─────────┐
│  Node renderer   │──►  headless Chromium
└────────┬─────────┘     markdown-it → HTML, CSS layout,
         │               links, search, text selection
         │ screenshot of the visible viewport
      PNG bytes
         │ Kitty graphics protocol (escape sequences)
┌────────▼─────────┐
│  preview split   │   the image, sized to the window
└──────────────────┘

The same pipe runs upward: keys and mouse gestures in the
preview are forwarded to the Chromium page as DOM events,
and the viewport is recaptured to show what changed.
```

Step by step:

1. `:MdViewerToggle` opens a read-only split and starts the renderer if it
   is not already running.
2. The plugin sends the buffer's current lines — saved or not — to the
   renderer.
3. The renderer turns Markdown into HTML with markdown-it and loads it into
   the Chromium page, with the bundled CSS matching your theme.
4. Chromium lays the page out, and the renderer screenshots the part that
   fits the split.
5. The plugin encodes that PNG as Kitty graphics escape sequences and places
   it in the split, scaled to the window's cells.
6. As you edit, the changed document is re-rendered and recaptured, debounced
   so typing doesn't screenshot per keypress. Scrolling is cheaper: it
   normally moves the existing page and recaptures the viewport rather than
   rebuilding the document.
7. Both sides drop work that has been superseded — a newer edit or scroll
   wins over an older one still in flight.

## Why a browser?

Because parsing Markdown is the easy part; layout is not. Getting tables,
nested lists, code blocks, themes, and images to look right is a solved
problem inside a browser engine and an endless project outside one. Driving
Chromium means the preview looks like what a browser would show you, and
link resolution, search, and text selection come from the DOM instead of
being reimplemented.

The trade-off is a heavyweight dependency: an existing
Chrome/Chromium/Edge install, and a noticeable one-off warm-up the first
time a session captures a frame. The renderer stays resident, so everything
after that first frame is fast.

## Why a PNG and the Kitty graphics protocol?

A terminal cannot host a DOM — but several modern terminals can draw
images, and the Kitty graphics protocol is a common way to do it: the image
travels as escape sequences on the same stream as your text, which also
means it works over SSH with no extra ports or forwarding. The plugin
writes those sequences through Neovim's own UI channel and places the image
into the preview split's cells.

On terminals without Kitty graphics support, the preview falls back to a
text-only rendering. [terminal-support.md](terminal-support.md) records
exactly what works where.

## Interaction

The preview looks like an image, but gestures behave like a browser because
they are answered by one. Keys and mouse events captured in the preview
split are forwarded to the renderer and applied to the live DOM — move the
caret, extend a selection, run a search, hit-test a Ctrl/Cmd-click on a
link — and the viewport is recaptured in the same round trip, so the
picture and the page stay in agreement.

A few consequences worth knowing:

- The caret and selection live in the rendered document, not in the preview
  buffer. Highlighting is keyboard-driven (`v`/`V` from the caret); there is
  no click-and-drag selection. `y` copies the selected text back out of the
  DOM.
- The selection highlight is drawn as its own image layer above the base
  frame, so it can update instantly without a full re-render. Base image,
  animation frames, and overlay each keep their own layer.
- Link clicks are classified by the renderer, then re-checked on the Lua
  side before anything opens — the classification is a hint, not a grant.
  [SECURITY.md](../SECURITY.md) describes the trust boundary all of this
  sits inside.

<a id="render-location"></a>
## Two experimental modes

Both exist for slow links, both are off by default, and they should not be
combined.

**Local rendering** (`render.location = "local"`) moves the browser to the
machine your terminal runs on, so rendered pixels never cross the SSH link —
only small control messages do. Setup and trade-offs:
[ssh.md](ssh.md#local-rendering).

**Resident mode** (`image.resident`) captures the whole document once into
the terminal's image memory, after which scrolling sends a placement
command instead of pixels. Its terminal support is currently narrow: the
iTerm2 and WezTerm profiles disable the panning it depends on, so on those
terminals the resident path is not taken at any link speed.
`:help md-viewer-resident` has the details and tuning.

## Main pieces

| Path | What it is |
|---|---|
| `lua/md-viewer/` | The Neovim side: config, sessions, lifecycle, scroll sync, placement geometry, health checks, renderer-process control |
| `lua/md-viewer/backends/` | How images reach the terminal: `vim.ui.img`, the raw Kitty-protocol encoder, and the text-cell fallback |
| `plugin/md-viewer.lua` | Runtime entry point and default highlights |
| `build.lua` | The renderer install hook plugin managers run |
| `renderer/src/` | The Node renderer: Markdown pipeline, browser lifecycle, interaction, security policy. `service.js` is what a request *means*; `main.js` is where requests arrive |
| `renderer/assets/` | Bundled preview themes and syntax colors |
| `tests/lua/`, `tests/node/` | The headless suites (`make test`) |
| `scripts/` | Harnesses that need a real browser, a real terminal, or a second machine — never run in CI. `scripts/manual-checklist.md` is the eyes-on release checklist |
| `doc/md-viewer.txt` | `:help md-viewer` — the complete option and command reference |

## Prior art

The preview-pane model — stable per-document panes, tabs, retained state,
stale-response handling — takes inspiration from
[Markdown Preview Enhanced](https://github.com/shd101wyy/vscode-markdown-preview-enhanced)'s
preview provider. md-viewer deliberately does not adopt its webview, script
execution, or diagram/export features; those conflict with a read-only
image surface and this project's security boundary.
