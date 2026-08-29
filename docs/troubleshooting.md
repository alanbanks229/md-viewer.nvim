# Troubleshooting

Start with `:MdViewerHealth`: overall status, the selected backend, the reason it
was selected, and any warnings. `:MdViewerDebug` is the full diagnostic in one
buffer — the environment field by field, then what each open preview is actually
doing — and is what to attach to a bug report. Every field name quoted below is
printed by `:MdViewerDebug` unless it says otherwise.

## Find your symptom

**Nothing is drawn**

- [The preview shows styled text instead of an image](#the-preview-shows-styled-text-instead-of-an-image)
- [An explicit backend reports unavailable](#an-explicit-backend-reports-unavailable)
- [The renderer exits, or Playwright is missing](#the-renderer-exits-or-playwright-is-missing)
- [The preview falls back to text over SSH](#the-preview-falls-back-to-text-over-ssh)
- [The wrong terminal profile was detected](#the-wrong-terminal-profile-was-detected)

**It draws, but wrong**

- [The image is stretched or soft, or the text is about twice the size it should be](#the-image-is-stretched-or-soft-or-the-text-is-about-twice-the-size-it-should-be)
- [The caret or the selection highlight is a huge grey block](#the-caret-or-the-selection-highlight-is-a-huge-grey-block)
- [The preview blinks to a blank pane if you drag the mouse](#the-preview-blinks-to-a-blank-pane-if-you-drag-the-mouse)
- [A resident preview jumps to the wrong position, or shows torn content](#a-resident-preview-jumps-to-the-wrong-position-or-shows-torn-content)
- [A notification over the preview shows Markdown through its background](#a-notification-over-the-preview-shows-markdown-through-its-background)
- [A gap or overhang appears beside a notification](#a-gap-or-overhang-appears-beside-a-notification)
- [The image overlaps other UI, or survives closing](#the-image-overlaps-other-ui-or-survives-closing)

**Images**

- [An image shows a placeholder instead of the picture](#an-image-shows-a-placeholder-instead-of-the-picture)
- [Remote images never load, and the network needs a proxy](#remote-images-never-load-and-the-network-needs-a-proxy)
- [An animated image is not moving](#an-animated-image-is-not-moving)

**Interaction**

- [The mouse wheel does not scroll the preview](#the-mouse-wheel-does-not-scroll-the-preview)
- [Clicking, extending a selection, searching, or copying does nothing](#clicking-extending-a-selection-searching-or-copying-does-nothing)
- [A `v`/`V` selection does not extend](#a-vv-selection-does-not-extend)
- [A click lands on the wrong character](#a-click-lands-on-the-wrong-character)
- [The mouse pointer never changes shape over the preview](#the-mouse-pointer-never-changes-shape-over-the-preview)

**Links**

- [A link to another document refuses to open](#a-link-to-another-document-refuses-to-open)
- [Ctrl-click or Cmd-click does not activate a link](#ctrl-click-or-cmd-click-does-not-activate-a-link)
- [A Ctrl-clicked external link does nothing](#a-ctrl-clicked-external-link-does-nothing)

**Speed, and remote sessions**

- [Scrolling feels slow](#scrolling-feels-slow)
- [Local rendering says "local rendering unavailable" on open](#local-rendering-says-local-rendering-unavailable-on-open)
- [Local rendering attaches but "pairing probe unanswered"](#local-rendering-attaches-but-pairing-probe-unanswered)
- [The preview works, but is it actually rendering locally?](#the-preview-works-but-is-it-actually-rendering-locally?)
- [Local rendering demoted mid-session ("rendering on this host instead")](#local-rendering-demoted-mid-session-rendering-on-this-host-instead)
- [Resident mode is configured, but `render_path` says `viewport`](#resident-mode-is-configured-but-render_path-says-viewport)

---

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

## The image is stretched or soft, or the text is about twice the size it should be

Both are the same fault: the terminal's cell was converted to CSS pixels with
the wrong divisor, or could not be measured at all. `render.font_size_px` is
honoured exactly at every viewport width, so text at the wrong size is never a
font setting.

Check `viewport calibration` in `:MdViewerDebug`, and the three lines beside it.
`measured cell` is what the operating system reported, `viewport cell (CSS px)`
is what the browser viewport was built from, and `cell unit` says how one became
the other.

- **`measured`** — the cell came from the terminal and the render is built to
  match it.
- **`env`** — `MD_VIEWER_CELL_WIDTH_PX` and `MD_VIEWER_CELL_HEIGHT_PX` are both
  set and nothing is inferred.
- **`estimated`** — nothing could be measured. tmux and screen do not propagate
  pixel geometry, and neither does a Neovim without LuaJIT; the render is sized
  from a guess the terminal then scales.

md-viewer tries both divisors and keeps whichever yields a cell a font could
plausibly have. `cell unit` names the one it settled on; if neither works,
`:MdViewerHealth` warns rather than picking silently.

**Doubled glyphs specifically** mean the CSS cell came out half size, so the
terminal magnifies the PNG to fill the cells anyway. Two causes:

- The terminal fills `ws_xpixel`/`ws_ypixel` with **logical points** rather than
  device pixels, so the device scale divides a second time. Warp does this, and
  md-viewer detects it.
- The display is **1x** while `render.device_scale_factor` is left at its default
  of `2`. Set `render.device_scale_factor = 1` — it also stops the renderer
  capturing four times the pixels it needs.

**Overriding the measurement.** Give the cell size in **CSS** pixels — the
measured size divided by `device_scale_factor`, so a 2x display measuring 14×32
wants:

```sh
export MD_VIEWER_CELL_WIDTH_PX=7
export MD_VIEWER_CELL_HEIGHT_PX=16
```

`viewport calibration` then reads `env`. Worth doing when the detection gets it
wrong — a genuinely tiny terminal font on a HiDPI display is the case to watch,
since a real cell can fall below the plausible band.

On the `estimated` tier only, if the typography is smaller than you expect, the
estimated cell width is probably too large and the terminal is scaling the whole
screenshot down. Lower `render.estimated_cell_width_px` gradually, or prefer the
exact values above.

## The caret or the selection highlight is a huge grey block

The caret is drawn as a translucent rectangle over the frame already on screen,
cropped out of a shared tint sheet and placed at natural pixel size. A terminal
that does not honour the crop keys draws far more of that sheet than was asked
for, so a one-glyph block becomes a rectangle anchored at the caret and running
to the edge of the split.

Check the `overlay` line in `:MdViewerDebug`. If it reads `(forced -- this
profile is not validated for it)`, you have `interaction.selection_overlay =
"on"` set for a terminal that cannot do this. Remove it; the selection falls
back to full-frame captures, which are always correct and merely slower.
`:MdViewerHealth` reports the same thing as a warning.

Warp is the known case — see [terminal-support.md](terminal-support.md#warp).
The overlay is enabled by default only on iTerm2, Kitty and Ghostty, where a
human watched it work.

## The preview blinks to a blank pane if you drag the mouse

The mouse never highlights text — only `v`/`V` and the motion keys do
(`:help md-viewer-visual`) — so md-viewer maps only a plain click and its release,
not a drag, for any modifier. An ordinary mouse drag therefore falls straight
through to Neovim's own default, which for an unmapped drag is a blockwise
Visual selection over the preview's blank cells: the status line reads
`V-BLOCK` or `-- VISUAL --` and the image blinks to a blank pane with a blue
rectangle over it for one tick. `controller.lua` recovers automatically (one
`<Esc>` per tick) as soon as it sees the mode change, so this is expected —
not a bug to report — and it resolves itself the moment the drag ends. If
Neovim stays stuck in Visual mode past that, `:MdViewerDebug` output and the
terminal name in an issue is exactly what is needed.

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

The reason is the SSRF defence: the fetcher resolves the hostname, validates the
address, and then **pins** the connection to the address it validated. Without
that pin a hostname can answer with a public address for the check and a private
one for the fetch. A proxy makes pinning impossible — where the connection goes
after the proxy is the proxy's decision. Keeping both is an open design question,
not an oversight.

It costs that one picture and nothing else. The placeholder draws immediately
rather than the render waiting on a fetch, and local images and links never touch
the network. Redirects are fine — up to three hops, each checked — so ordinary
GitHub attachment URLs resolve with no configuration.

## An animated image is not moving

**Animation is off by default** — set `render.animate = true`. Until then you see
the still frame, which is the picture you are already looking at.

With it on, `:MdViewerDebug`'s `animation` line names the strategy in use or the
reason it is off. Off is also normal on the `cells` and `nvim_img` backends
(neither can place frames), where the terminal's pixel cell size is not
measurable, and on any terminal but iTerm2, Kitty and Ghostty — see
[terminal support](terminal-support.md).

On but still not moving is usually one of three things, all visible in
`:MdViewerDebug`:

- **Still decoding.** A long retina-scale recording takes a few seconds; each
  animation lists as `materializing`, `uploading` or `playing`.
- **Suspended.** Animation pauses during a click or selection, under a floating
  window, and while the completion popup is up. `animation_suppressed_reason`
  names which.
- **Refused.** Past the size or frame caps, or drawn at a size that leaves no
  frame budget. The refusal is recorded in the same list.

A non-looping GIF that has finished is not stuck — it froze on its last frame,
as a browser leaves it.

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
configuration, and under `render.location = "local"` it is full size, because
no pixels cross the link and there is nothing to trade sharpness for. Read it
beside `capture_encoder`: the numeric factor needs the `cdp_fast_png` path, and
a session on `playwright_png` gets full-size frames no matter what is set.

Do **not** lower `render.device_scale_factor` for this. It is a calibration
divisor, not a size knob: lowering it doubles the CSS viewport and makes the
frame *larger*, and it collapses the moving and settle captures into one so the
cheap scroll frame stops existing. `:help md-viewer-ssh` has the measurements.

## Local rendering says "local rendering unavailable" on open

`render.location = "local"` needs the helper wrapped around the ssh session
*before* Neovim starts inside it:

```sh
node <md-viewer>/renderer/src/local-main.js -- ssh <host>
```

The warning's parenthetical is the discovery scan's own verdict, one entry
per candidate socket. "no helper socket found" means no `ssh -R` forward
landed (the helper prints a message at launch if it could not add one);
"mode ... is looser than 0600" means the remote socket file failed the
permission check; "hello refused (PROTOCOL_MISMATCH: ...)" means the two
checkouts are on different md-viewer versions — pin both to the same tag,
the refusal text says which side is older. `$MD_VIEWER_LOCAL_SOCKET` pins
the socket path explicitly when the scan picks wrong.

## Local rendering attaches but "pairing probe unanswered"

The socket answered hello but the helper filtering *this* terminal never saw
the probe marker, so the plugin refused to adopt it — most often two helper
sessions to one host, where the scan found the other session's socket first.
Close the stale session (or its socket file under
`${XDG_RUNTIME_DIR:-/tmp/md-viewer-$USER}/md-viewer/`), or point
`$MD_VIEWER_LOCAL_SOCKET` at the right one. A multiplexer between ssh and
the terminal (tmux/screen inside the session) also eats the probe: the
filter must sit directly on the byte stream Neovim writes to.

## The preview works, but is it actually rendering locally?

Do not judge by feel. `:MdViewerHealth`'s Rendering section has a `Location`
row that answers in words, and the counters prove it: `:MdViewerDebug`'s
`local_render` block shows the attachment phase and markers emitted, and on
the laptop `node .../local-main.js --status` prints the filter's counters.

Read the **attributed** one: `parser.remoteMdvGraphicsCommands` (and
`remoteMdvRasterBytes`) counts only graphics whose image ids belong to an
md-viewer session, and zero while attached is the invariant holding. Its
unattributed sibling `parser.remoteGraphicsCommands` counts every graphics
command any program in the wrapped session sends, so a nonzero value there
is not evidence of anything on its own — anything else drawing images
through the same ssh session raises it. A climbing *attributed* number means
the session demoted (the reason is in health) and frames are crossing as
pixels again.

## Local rendering demoted mid-session ("rendering on this host instead")

The control socket died — the notification appears once, and every later
frame renders remotely, correct but paying the link again. The reason is
kept in `:MdViewerHealth`'s warnings and `:MdViewerDebug`'s
`local_render.reason`. Re-attach by reopening the preview from a session
launched through the helper; a helper that died takes its ssh session with
it, so this normally means starting a fresh session rather than repairing
the old one.

## Resident mode is configured, but `render_path` says `viewport`

Run `:MdViewerDebug` and read `render_path_reason` — it names the one condition
that was not met, and there are four:

| `render_path_reason` | What to do |
|---|---|
| `link speed unknown — :MdViewerMeasureLink measures this machine…` | Run `:MdViewerMeasureLink` once on this machine. `"auto"` never measures on its own, and an unmeasured link is treated as unknown rather than slow. |
| `link measures 14.70 MB/s, at or above the 4.00 MB/s cutoff…` | Working as intended: this link is fast enough that the warm-up is the only thing you would notice. Set `image.resident = "on"` if you want it anyway, or raise `image.resident_below_bytes_per_sec`. |
| `wezterm#7953…`, or any terminal reason | Your terminal refuses resident placements. No link speed changes this — see [terminal-support.md](terminal-support.md). |
| `local render owns scrolling` | Local rendering is attached, and it already scrolls without sending pixels. The two are mutually exclusive by design and local rendering wins. |

`image.resident = "off"` reports itself as `image.resident = off`, which means
`setup()` never received what you thought it did — check for a second `setup()`
call or a plugin-manager `opts` table overriding the first.

## A resident preview jumps to the wrong position, or shows torn content

Resident mode (`image.resident = "auto"` plus a measured link under 4 MB/s, off
by default) scrolls by asking the
terminal to re-crop chunks already in its image memory. iTerm2 3.6.11 applies
that re-crop unreliably over a slow link — measured, with the escape sequences
confirmed byte-correct, so the defect is in the terminal rather than in what was
sent. iTerm2's profile therefore sets `resident_pan = false` and falls back to
the viewport model, which re-renders per scroll and re-crops nothing.

`:MdViewerDebug`'s `render_path` says which model a preview chose and
`render_path_reason` says why. If one that should be on the viewport model is
warming chunks instead, check `terminal.profile` and
`MD_VIEWER_TERMINAL_PROFILE` for an override pinning a profile other than
`iterm2`.

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
creates windows with `noautocmd = true`, confirm `:MdViewerDebug` reports
`ui_polling: true` — the poll discovers them without provider-specific hooks,
on the interval `image.ui_poll_ms` sets (default 50 ms; `0` disables it).

A stray image persisting over another plugin's windows while `tabpage_hidden` is
`false` usually means that plugin resized or moved the preview split without
md-viewer noticing — `WinNew`/`WinResized` should catch that, and a case where
they don't is worth reporting.

Close the preview with `:MdViewerToggle`; md-viewer deletes only the image IDs it
owns. Do not use global image deletion — it can damage unrelated plugins.

## Clicking, extending a selection, searching, or copying does nothing

Confirm `:MdViewerDebug` reports `interaction enabled: yes` and that the relevant
`interaction.*` flag (`selection`, `visual`, `find`, `copy`, `links`) is not
disabled. Interaction is unavailable outright on the `cells` backend — there
is no DOM to hit-test against.

`interaction_request_count` and `interaction_stale_count` distinguish the two
cases. Both at zero means nothing is being sent at all: check the config above.
A growing `interaction_stale_count` means requests are being sent but losing a
race — usually from editing or scrolling continuously enough that the document
changes again before the renderer answers. A selection captured against
superseded content must never be shown, so that is a requirement rather than a
bug; [architecture.md](architecture.md) describes the mechanism.

## A `v`/`V` selection does not extend

Highlighting only ever happens through `v`/`V` and the motion keys
(`:help md-viewer-visual`) — there is no click-and-drag fallback to fall
back to. If `v` does nothing at all, confirm `interaction.visual` and
`interaction.selection` are both on (`v` requires both), that the preview
window is actually focused (the mapping is buffer-local to the preview
buffer, so keys typed with focus still in the source window never reach
it), and that the preview has actually rendered at least once — `v` needs
an existing caret, and one is not placed until the first frame lands.
`:MdViewerDebug`'s `selection_active` and `selection_text_length` report
whether anything is held selected server-side, independently of whether it
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

This is terminal identification, not the renderer — if `chromium launch:
succeeded`, the renderer is fine and only produces a PNG. Neovim declines to
emit graphics at a terminal it cannot identify, and SSH does not forward
`TERM_PROGRAM`. Fixes, best first:

1. **Let `LC_TERMINAL` through** — iTerm2 and WezTerm export it so identity
   survives SSH, but it has to be allowed at both ends. Run `echo $LC_TERMINAL`
   on the remote host; if it prints, this is not your problem. If it is empty:
   - **Client.** `ssh -G <host> | grep sendenv` shows what is actually sent.
     Nothing, or no `LC_*`? Add to `~/.ssh/config`:
     ```
     Host *
       SendEnv LC_TERMINAL LC_TERMINAL_VERSION
     ```
     Upstream OpenSSH sends nothing by default; distributions usually add
     `SendEnv LANG LC_*`, and a `Host *` block of your own can override it.
   - **Server.** `AcceptEnv LANG LC_*` in `/etc/ssh/sshd_config`, then reload
     `sshd`. Nearly every distribution ships this already.

   Detection is automatic once the variable arrives.
2. **Name the profile in the environment**, for terminals that export no
   forwardable identity (Kitty, Ghostty, Warp):
   `export MD_VIEWER_TERMINAL_PROFILE=kitty` on the remote host. Prefer this to
   the config option when one `~/.config/nvim` is shared across hosts — the
   variable travels with the session, a hardcoded profile does not. An unknown
   value is ignored and reported in `identified by`, so check there for typos.
3. **Set `terminal.profile`** in the remote config, if it is only ever used from
   one terminal.

Two things that will not help, both common first guesses:

- **Pointing at a local browser.** `browser.executable_path` names a binary on
  the machine running Neovim; it cannot reach across the SSH connection, and the
  renderer that reads it opens no port and speaks to nothing over the network.
- **Forcing `image.backend = "kitty_raw"`.** Selection still calls the backend's
  `detect()`, which fails for the same reason `auto` did — it turns the fallback
  into a hard error without changing the outcome.
  `terminal.kitty_graphics = "on"` is the switch that moves this, but naming the
  profile is better: it also gets the right z-index, double-buffer and overlay
  defaults.

A preview that renders but feels *sluggish* is a different problem — bandwidth
rather than detection — and is covered under
[Scrolling feels slow](#scrolling-feels-slow), with the settings and the
measurements behind them in `:help md-viewer-ssh`.

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
