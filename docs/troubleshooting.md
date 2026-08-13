# Troubleshooting

Start with `:MdViewerHealth`: overall status, the selected backend, the reason it
was selected, and any warnings. `:MdViewerDebug` is the full diagnostic in one
buffer — the environment field by field, then what each open preview is actually
doing — and is what to attach to a bug report. Every field name quoted below is
printed by `:MdViewerDebug` unless it says otherwise.

## The preview shows styled text instead of an image

`auto` landed on the `cells` fallback, which happens only when *neither*
graphical backend was available. `:MdViewerHealth`'s `Reason` names which:

- **No Kitty-graphics evidence in the environment.** md-viewer recognises a
  terminal by `TERM_PROGRAM`, `KITTY_WINDOW_ID`, `WEZTERM_EXECUTABLE`,
  `GHOSTTY_RESOURCES_DIR`, `WARP_*`, `LC_TERMINAL`, or a `TERM` containing
  `kitty`. macOS Terminal.app and Alacritty match none of these and correctly
  get `cells`. If your terminal does speak the protocol but is not recognised,
  set `terminal.profile` or `terminal.kitty_graphics = "on"`. Over SSH this is
  a distinct problem with a distinct fix — see
  [The preview falls back to text over SSH](#the-preview-falls-back-to-text-over-ssh).
- **`vim.ui.img` was absent or incomplete.** That is a build/API availability
  issue, not a Kitty.app dependency, and it only matters when nothing else is
  available.

Setting `image.backend = "kitty_raw"` explicitly turns a silent fallback into an
actionable error, which is why it is worth doing even where `auto` already picks
it. Use a direct TUI with no multiplexer.

## An explicit backend reports unavailable

Intentional: explicit `nvim_img` and `kitty_raw` selections never silently fall
back. Check `:MdViewerHealth` for the reason, and select `cells` while
investigating.

## The renderer exits, or Playwright is missing

Run the locked install from `renderer/`:

```sh
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts
```

Do not run `playwright install`. Confirm the Chrome path `:MdViewerHealth` shows
exists, and set `browser.executable_path` if automatic discovery misses your
installation. Renderer stderr and request serials are in `:MdViewerDebug`.

## The image is stretched, soft, or the wrong size

Check `viewport calibration` in `:MdViewerDebug`. `measured` means the cell size
came from the terminal itself and the render is already built to match it;
`estimated` means nothing could be measured — tmux and screen do not propagate
pixel geometry, and neither does a Neovim without LuaJIT — and the render is
sized from a guess the terminal then scales.

Three lines sit beside the tier. `measured cell` is what the operating system
reported. `viewport cell (CSS px)` is what the browser viewport is actually
built from. `cell unit` says how one became the other.

The reported number is *supposed* to be device pixels, in which case the CSS
cell is that divided by `render.device_scale_factor`. Not every terminal means
that, and not every display matches the configured scale, so md-viewer tries
both divisors and keeps whichever yields a cell a font could plausibly have —
roughly 5–30 CSS px wide and 10–60 tall. `cell unit` names the divisor it
settled on and whether the choice was the default or a repair. If neither
divisor works, `:MdViewerHealth` says so as a warning rather than picking one
silently.

To override the measurement, set the cell size in **CSS** pixels — the measured
size divided by `device_scale_factor`, so a 2x display measuring 14×32 wants:

```sh
export MD_VIEWER_CELL_WIDTH_PX=7
export MD_VIEWER_CELL_HEIGHT_PX=16
```

`viewport calibration` should then read `env`. On the `estimated` tier only, if
the typography is smaller than you expect, the estimated cell width is probably
too large, causing the terminal to scale the whole screenshot down. Lower
`render.estimated_cell_width_px` gradually, or prefer the exact values above.

## Preview text is about twice the size it should be

`render.font_size_px` is honoured exactly, at every viewport width, so text at
the wrong size is a measurement fault rather than a font setting. Check `cell
unit` in `:MdViewerDebug`.

The chain is short: the CSS viewport is the preview's cell rectangle times the
CSS cell size, the page is captured at `render.device_scale_factor`, and the
terminal scales the result into those same cells. A CSS cell that comes out half
its true size therefore halves the viewport, and the terminal magnifies the PNG
to fill the cells anyway — so the glyphs double while the layout stays put.

Two things get it there, and md-viewer now detects both:

- The terminal fills `ws_xpixel`/`ws_ypixel` with **logical points** rather than
  device pixels, so dividing by the device scale divides a second time. Warp
  does this.
- The display is **1x** while `render.device_scale_factor` is left at its
  default of `2`. No terminal bug required; setting `render.device_scale_factor
  = 1` is the direct fix, and also stops the renderer capturing four times the
  pixels it needs.

If the detection gets it wrong — a genuinely tiny terminal font on a HiDPI
display is the case to watch, since a real cell can then fall below the
plausible band — pin the cell by hand in **CSS** pixels:

```sh
export MD_VIEWER_CELL_WIDTH_PX=7
export MD_VIEWER_CELL_HEIGHT_PX=16
```

`viewport calibration` then reads `env` and nothing is inferred.

## The caret or the drag highlight is a huge grey block

The caret is drawn as a translucent rectangle over the frame already on screen,
cropped out of a shared tint sheet and placed at natural pixel size. A terminal
that does not honour the crop keys draws far more of that sheet than was asked
for, so a one-glyph block becomes a rectangle anchored at the caret and running
to the edge of the split.

Check the `overlay` line in `:MdViewerDebug`. If it reads `(forced -- this
profile is not validated for it)`, you have `interaction.selection_overlay =
"on"` set for a terminal that cannot do this. Remove it; the drag falls back to
full-frame captures, which are always correct and merely slower.
`:MdViewerHealth` reports the same thing as a warning.

Warp is the known case — see [terminal-support.md](terminal-support.md#warp).
The overlay is enabled by default only on iTerm2, Kitty and Ghostty, where a
human watched it work.

## The preview blinks to a blank pane while dragging a selection

If the status line reads `V-BLOCK` or `-- VISUAL --` during the drag, Neovim
itself has entered Visual mode over the preview: the terminal is reporting a
modified mouse drag, and Vim's default for `<M-LeftDrag>` is a blockwise Visual
selection. md-viewer maps every modifier combination and escapes Visual mode if
one still gets through, so this should not happen — if it does, `:MdViewerDebug`
output and the terminal name in an issue is exactly what is needed.

If the image blanks with the status line staying on `NORMAL`, the terminal is
dropping the placement during replacement. Check `double buffer` in
`:MdViewerDebug`: it should read `create-then-delete`, which never leaves a
moment with nothing on screen. `image.double_buffer = true` forces it.

On Warp specifically, see [terminal-support.md](terminal-support.md#warp) —
`image.raw_zindex = 1` is the fallback if a repaint still blanks the image.

## An image shows a placeholder instead of the picture

An image that cannot render shows a visible placeholder naming the reason;
nothing is silently hidden. A dashed border means it was refused by policy:
the URL resolves to a non-public network address (loopback, private,
link-local, or another reserved range — see [SECURITY.md](../SECURITY.md)),
the URL is not https, the file sits outside `security.document_root`, or it
is an unsupported format — SVG is intentionally excluded. A solid border means
the image was attempted and failed: the host was unreachable or timed out, the
response was not a valid image, or the size exceeds `max_local_image_bytes`. A
symlink pointing outside the document root is rejected like any other escape.

Remote fetches do not honor proxy environment variables; behind a mandatory
proxy they fail to a placeholder — see the next section. A definitive failure
(a 404, or bytes that are not a valid image) is retried on the next render
after about a minute. A timeout or an unresolved host is treated as more likely
transient — the same process launching Chromium can briefly starve a fetch of
CPU — and is retried within a few seconds instead.

An image that is merely slow shows the same placeholder while it is still being
fetched. The document is not held back for it: the render goes ahead with the
placeholder in place, and the picture appears on its own once the bytes land.

## Remote images never load, and the network needs a proxy

`$HTTP_PROXY` and `$HTTPS_PROXY` are not consulted, deliberately, so on a
network where the only route out is a proxy every `https` image fails to its
placeholder. Nothing is misconfigured and there is no setting that changes it.

The reason is the SSRF defence. `buildRequestOptions` in
`renderer/src/remote-images.js` resolves the hostname, validates every returned
address against the blocklist, and then **pins** the connection to the address
it validated, with `agent: false` so no keep-alive pool or shared agent object
can quietly reconnect somewhere else. Pinning the resolved address is what
closes the gap between the check and the connection — without it, a hostname
can answer with a public address for the check and a private one for the fetch.
A proxy makes pinning impossible: the connection goes to the proxy, and where
it goes after that is the proxy's decision, not something this process can
verify. Reaching remote images through a proxy while keeping the guarantee that
makes the check meaningful is **an open design question, not an oversight**.

What did change: this no longer costs you the whole preview. Fetches used to
resolve in a pre-pass before the document was rendered, so on a proxied network
one unreachable image paid the full 20-second timeout *before anything
appeared*. The render no longer waits — the placeholder is drawn immediately,
the fetch keeps running, and a later render picks it up if it ever lands. On a
proxied network it will not, so what you get is the placeholder, at once,
instead of a twenty-second stall and then the placeholder.

Local images and links are unaffected: they never touch the network.

A GitHub attachment URL — `https://github.com/user-attachments/…`, the form
GitHub produces when you paste an image into an issue, and what this
project's own README uses — 302-redirects to a signed S3 URL. That and
similar redirect chains resolve with no configuration; the renderer follows
up to three hops, and the destination check above applies to each hop, not
just the URL as written. The placeholder always names the reason and, for a
non-public destination, the address it resolved to, so there is nothing to
look up if a redirect target ever changes.

## An animated image is not moving

**Animation is off by default.** `:MdViewerDebug` reports
`animation: off -- render.animate=false`; turn it on with
`render.animate = true`. Nothing is broken in the meantime: the preview is a
browser-rendered PNG surface, so an animated image is a still frame until the
terminal is given the frames to draw itself, and that still frame is the
picture you are already looking at.

With it on, `:MdViewerDebug` reports `animation` with the strategy in use —
`native (terminal-driven)` or `frames (client-driven)` — or off with the reason.

Off is normal in several other cases, and none of them lose the picture: only
the `kitty_raw` backend can place frames, so `cells` and `nvim_img` cannot
animate at all; the terminal's pixel cell size has to be measurable (the same
precondition as the drag-highlight overlay); and only iTerm2, Kitty and Ghostty
are qualified for it. WezTerm is deliberately excluded — see
[terminal support](terminal-support.md).

On, but still not moving, is usually one of three things. Decoding runs in the
renderer's Chromium and a long retina-scale recording can take a few seconds
to start; `:MdViewerDebug` lists each animation as `materializing`,
`uploading`, `playing`, or with a per-frame count once frames are in. Animation
is suspended while a drag or visual selection is in progress, while the preview
is occluded by a floating window, and while the completion popup is up —
`animation_suppressed_reason` names whichever applies. And an image the renderer
*refused* — a still, one past the size or frame caps, or one whose drawn size
leaves no frame budget — stays a still frame with the refusal recorded in the
same list.

A non-looping GIF that has finished is not stuck: it froze on its last frame,
exactly as a browser leaves it.

Set `render.animate = false` to turn animation back off, `render.animate_fps`
to cap the client-driven swap rate (frames are skipped under the cap, never
stretched), or `terminal.animation` to force a strategy — including `"native"`
to qualify terminal-driven playback in a terminal the profile table does not
yet trust.

## The mouse wheel does not scroll the preview

Confirm `sync.mouse_scroll = true`, that Neovim mouse support is enabled, and
that the pointer is inside the preview window. The handler is scoped to the
window under the pointer and deliberately does not turn source-window wheel
events into preview motion. Keyboard navigation works regardless.

## Scrolling feels slow

Run `:MdViewerDebug` after a scroll and compare the `fast_*` and `retina_*`
values, especially `fast_capture_ms`, `fast_png_bytes`, and
`fast_image_update_ms`. `coalesced_scroll_events` shows how much repeated input
was collapsed to the newest position; completed frames are never deliberately
discarded. If terminal transfer still dominates, lowering
`render.scroll_scale` is the lever: it captures the moving frame at a fraction
of its natural size, which the settle frame undoes as soon as scrolling stops.
`scroll_scale` in `:MdViewerDebug` reports the factor in force and where it came
from — over SSH it is `render.ssh_scroll_scale` (default `0.5`) without any
configuration. Read it beside `capture_encoder`: the numeric factor needs the
`cdp_fast_png` path, and a session on `playwright_png` gets full-size frames no
matter what is set.

Do **not** lower `render.device_scale_factor` for this. It is a calibration
divisor, not a size knob — see the note under "The preview falls back to text
over SSH" for what it actually does to the byte count.

## A notification over the preview shows Markdown through its background

A negative `raw_zindex` draws the image below text glyphs but *above* cell
background colours, so a passive (non-focusable) float does not occlude the image
on its own — its rectangle has to be cut out of the placement.

- Confirm `:MdViewerDebug` reports a nonzero `passive_cutouts` while the
  notification is visible. Zero means the float was not recognized as a passive
  overlay at all — check whether it is genuinely non-focusable.
- Confirm the raw z-index is negative. `layer stack` prints all three; the
  default is `base -3 / animation -2 / selection -1`.

## A gap or overhang appears beside a notification

The cut-out is exact in cells, but the image's on-screen origin need not be: some
terminals (iTerm2 confirmed) apply their horizontal window margin to text but not
to graphics placements, shifting the image a fraction of a cell toward the origin.

`image.raw_overlay_bleed_cells` (default `1`) absorbs the gap.
`image.raw_cell_offset_px` cancels the shift outright on a terminal that
implements the Kitty protocol's `X`/`Y` placement keys. To measure it: screenshot
a notification over the preview and compare the x coordinate of the image's edge
with the x coordinate of the notification's edge; set `x` to the difference (10
for a 20px cell on iTerm2's defaults). When it works the gap closes completely
and you can drop `raw_overlay_bleed_cells` to `0`. `:MdViewerDebug` reports both
as `cell offset / bleed`.

If a notification over the preview bothers you at all, positioning it elsewhere
avoids the overlap entirely — for `snacks.nvim`, see `Snacks.notifier`'s
placement options.

## The image overlaps other UI, or survives closing

`:MdViewerDebug` reports `occluded = true` while an overlapping *focusable* float
is visible; the overlap guard removes the image only for those. If a provider
creates windows with `noautocmd = true`, confirm `ui_polling = true` — the
default 50 ms poll discovers them without provider-specific hooks.

If a stray image persists over another plugin's windows while `tabpage_hidden` is
`false`, that plugin most likely resized or repositioned the preview split
without md-viewer noticing. `WinNew`/`WinResized` should catch any new or resized
window, not only floating ones — if they don't, that is a real regression worth
reporting. If the image is visible on a *different* tabpage than the preview's
own, `refresh_deferred` should read `true` until you return to the preview's
tabpage.

Close the preview with `:MdViewerToggle`; md-viewer deletes only the image IDs it
owns. Do not use global image deletion — it can damage unrelated plugins.

## Clicking, dragging, searching, or copying does nothing

Confirm `:MdViewerDebug` reports `interaction enabled: yes` and that the relevant
`interaction.*` flag (`selection`, `word_select`, `paragraph_select`, `find`,
`copy`, `links`) is not disabled. Interaction is unavailable outright on the
`cells` backend — there is no DOM to hit-test against.

`interaction_request_count` and `interaction_stale_count` distinguish the two
cases. Both at zero means nothing is being sent at all: check the config above.
A growing `interaction_stale_count` means requests are being sent but losing a
race — usually from editing or scrolling continuously enough that the document
changes again before the renderer answers. A selection captured against
superseded content must never be shown, so that is a requirement rather than a
bug; [architecture.md](architecture.md) describes the mechanism.

## A selection does not appear after dragging

A drag has to cross `interaction.drag_threshold_cells` (default `1`) before it is
recognized as a drag rather than a click, so a very small, fast drag inside one
cell registers as a plain click — which clears any existing selection instead of
creating one. `:MdViewerDebug`'s `selection_active` and `selection_text_length`
report whether anything is held selected server-side, independently of whether it
is currently visible.

## A click lands on the wrong character

Confirm `:MdViewerDebug`'s `viewport calibration` reads `measured` or `env`, not
`estimated` — an estimated cell size is a real source of click-position error on
a terminal/font combination the estimate does not match well. `estimated`
normally means the terminal reports no pixel geometry, which is what a
multiplexer does; running outside tmux or screen is the fix. Setting
`MD_VIEWER_CELL_WIDTH_PX` and `MD_VIEWER_CELL_HEIGHT_PX` removes the estimate by
hand.

`interaction_last_precision` reports what the last interaction actually resolved
at: `exact`, `line`, `block`, or `none`. A `none` where you expected an exact hit
usually means the click landed in padding or whitespace the parser genuinely
cannot attribute to a source position — see
[architecture.md](architecture.md) for what each level means. No automated test
can confirm where a real click lands on real hardware; see
[development.md](development.md#manual-verification).

## A link to another document refuses to open

The message distinguishes three different things.

**"link target does not exist"** — the path resolved fine and there is nothing
there: a typo, or a file not written yet. Nothing to configure.

**"refused to open link outside the document root"** — the message names the root
it was measured against. By default that is the project enclosing the document
(the nearest ancestor holding `.git`, `.hg`, or `.svn`); a document outside any
such project is rooted at its own directory instead, so a link to a sibling
directory is genuinely outside it. Either set `security.document_root`
explicitly, or add a marker to `security.document_root_markers`.

Check this first if links fail in one project but work in another: a
`security.document_root` set once, globally, pins every preview to that one
directory. `:MdViewerHealth` warns outright when a **configured** root does not
contain the document being previewed — the case where every local link and image
is refused and nothing else says why. `:MdViewerDebug`'s `document root` line
names both the resolved root and where it came from.

**Refused as an executable** — md-viewer never hands a link to the system handler
when the target is something the OS would *run*. `:help md-viewer-security`
lists what counts.

## Ctrl-click or Cmd-click does not activate a link

Both are mapped, but on macOS the terminal often claims them first: iTerm2 uses
Cmd-click to open URLs, and several terminals emulate a right-click on
Ctrl-click. If `interaction_request_count` does not increase when you click, the
gesture never reached Neovim and the terminal's own mouse settings are where to
look. If it does increase but nothing opens, the link was classified or refused —
see above.

## A Ctrl-clicked external link does nothing

`:MdViewerDebug`'s `last_external_open` records the hand-off: the URL, when it
was attempted, and what came back.

- `"none"` — md-viewer never got that far. Either the click did not reach Neovim
  (see above) or the point was not over a link.
- `no handler: ...` — `vim.ui.open` found nothing to run.
- `exit code N`, or a message from the handler — the OS started a handler and it
  refused. Also reported as a notification.
- `spawned`, with nothing after it — the handler is still running, which is the
  successful case for a browser that stays open.

md-viewer never opens a URL itself; it asks Neovim, which asks the operating
system (`open`, `xdg-open`, `start`). If the handler exited cleanly and no window
appeared, run the same URL through your own shell — the problem is between the OS
and the default browser.

## The mouse pointer never changes shape over the preview

It never will. The preview is a PNG, so only the terminal itself could change the
pointer (through `OSC 22`), and support proved inconsistent enough across
terminals that the feature was removed rather than left half-working. Neovim's
global `'mousemoveevent'` is left alone as a result.

## The preview falls back to text over SSH

The signature, in `:MdViewerDebug`:

```
ssh session:              yes (SSH_CONNECTION)
terminal profile:         unknown (Unknown terminal) -- graphics unavailable
identified by:            none
selected backend:         cells
```

This is a terminal-identification failure, not a renderer failure. If the
`Renderer Process` section reports `chromium launch: succeeded` and
`process: running`, the renderer is fine and is not the thing to investigate —
it only produces a PNG. Painting that PNG is Neovim's job, and Neovim declines
to emit graphics escape sequences at a terminal it cannot identify.

The cause is that SSH does not forward `TERM_PROGRAM`, which is how iTerm2,
Warp and others are normally recognised. Fixes, best first:

1. **Let `LC_TERMINAL` through.** iTerm2 and WezTerm export `LC_TERMINAL` (and
   `LC_TERMINAL_VERSION`) precisely so identity survives SSH, and OpenSSH
   forwards `LC_*` by default. Run `echo $LC_TERMINAL` on the remote host. If it
   is empty, the remote `sshd` is dropping it: add `AcceptEnv LANG LC_*` to
   `/etc/ssh/sshd_config` and reload `sshd`. Nothing else is needed — detection
   is automatic once the variable arrives, and `identified by` will read
   `LC_TERMINAL=iTerm2; LC_TERMINAL_VERSION=3.6.11`.
2. **Name the profile in the environment**, for terminals that export no
   forwardable identity of their own (Kitty, Ghostty, Warp):
   `export MD_VIEWER_TERMINAL_PROFILE=kitty` on the remote host. This is
   preferable to the config option when one `~/.config/nvim` is shared across
   hosts and reached from different terminals: the variable travels with the
   session, a hardcoded profile does not. A value that is not a known profile is
   ignored and reported in `identified by`, so check there for typos.
3. **Set `terminal.profile`** in the remote Neovim config, if that config is
   only ever used from one terminal.

Two things that will not help, both common first guesses:

- **Pointing at a local browser.** `browser.executable_path` names a binary on
  the machine running Neovim; it cannot reach across the SSH connection, and the
  renderer that reads it opens no port and speaks to nothing over the network.
- **Forcing `image.backend = "kitty_raw"`.** Backend selection still calls the
  backend's `detect()`, which fails for the same reason `auto` did, so this
  converts the fallback into a hard error without changing the outcome.
  `terminal.kitty_graphics = "on"` is the switch that actually moves this,
  though naming the profile is better — it also gets the right z-index,
  double-buffer and overlay defaults.

If the preview renders but feels sluggish, that is bandwidth rather than
detection: every refresh sends a full-page PNG as base64 down the connection,
and on a throttled link the wire time per frame is larger than everything else
put together. On an AWS SSM tunnel — a flat 0.80 MB/s ceiling — one 80 KB moving
frame measured ~134 ms of pure transit, and a single wheel spin queues over a
hundred of them, so the backlog is the lag.

md-viewer already halves the moving frame on an SSH session
(`render.ssh_scroll_scale`, default `0.5`, 2.6× to 3× fewer bytes); lower it to
`0.25` if the link is slower. It also waits `render.ssh_scroll_settle_ms`
(default `400`, against `160` locally) before taking the expensive sharp
capture, so a gap between two wheel flicks does not buy a full-size transfer
that the next notch makes stale. Raising `render.debounce_ms` cuts how many
refreshes an edit produces.

`render.device_scale_factor = 1` is the tempting one and it makes this **worse**.
It is a calibration divisor: lowering it stops dividing the terminal cell down,
so the CSS viewport doubles and the frame grows — measured at 80 KB → 224 KB on
the same document and pane. It also collapses the moving and settle captures
into the same picture, so the cheap scroll frame stops existing at all. Both
were A/B'd on a live SSM link and both felt equal or worse; the defaults are
already the fastest configuration available.

When even that is not enough, the pixels themselves are the cost and no setting
removes them. [local-render-design.md](local-render-design.md) records what it
would take to render on the machine your terminal runs on and send only the
Markdown source across the link — and why that was built, measured on a real
link, and removed again.

## The wrong terminal profile was detected

`:MdViewerHealth`'s Terminal/Profile row names what was detected;
`:MdViewerDebug`'s `identified by` field shows exactly why. If it is wrong,
override it with `terminal.profile` rather than relying on `"auto"`, or with
`$MD_VIEWER_TERMINAL_PROFILE` when the config is shared across machines;
`terminal.kitty_graphics` and `terminal.probe` are the finer-grained overrides
beneath it. A wrong profile most commonly affects the default z-index and
double-buffer values and the calibration tier's defaults, not whether the preview
renders at all.

---

When reporting a graphical bug, record the exact backend, terminal and Neovim
versions, statusline/winbar configuration, and a minimal reproduction, and
confirm it reproduces outside any multiplexer. See
[terminal-support.md](terminal-support.md) for the per-terminal status.
