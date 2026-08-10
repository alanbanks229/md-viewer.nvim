# Troubleshooting

Start with `:MdViewerHealth` for the overall status, the selected backend, and
any warnings. `:MdViewerDebug` is the full diagnostic in one buffer — environment
and capability detail, then what each open preview is actually doing — and is
what to attach to a bug report. It separates terminal detection, `vim.ui.img`
presence, and a successful image render; `TERM_PROGRAM=iTerm.app` alone is never
treated as proof.

## The preview shows styled text instead of an image

`auto` selected the `cells` fallback because the installed Neovim build did not
expose a usable `vim.ui.img` API. This is a build/API availability issue, not a
Kitty.app dependency. Set `image.backend = "kitty_raw"` explicitly, inside a
direct TUI with no multiplexer.

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

`:MdViewerHealth` reports `viewport calibration` as `estimated`. Set the actual
cell size of your terminal profile — measure it rather than copying these:

```sh
export MD_VIEWER_CELL_WIDTH_PX=10
export MD_VIEWER_CELL_HEIGHT_PX=20
```

Health should then report `viewport calibration: explicit`.

If the typography is smaller than you expect, the estimated cell width is
probably too large, causing the terminal to scale the whole screenshot down.
Lower `render.estimated_cell_width_px` gradually, or prefer the exact values
above.

## An image shows a placeholder instead of the picture

An image that cannot render shows a visible placeholder naming the reason;
nothing is silently hidden. A dashed border means it was refused by policy:
the host is not in `security.remote_images` (remote images are off by
default), the URL is not https, the file sits outside
`security.document_root`, or it is an unsupported format — SVG is intentionally
excluded, see [SECURITY.md](../SECURITY.md). A solid border means the image was
attempted and failed: the host was unreachable or timed out, the response was
not a valid image, or the size exceeds `max_local_image_bytes`. A symlink
pointing outside the document root is rejected like any other escape.

Remote fetches do not honor proxy environment variables; behind a mandatory
proxy they fail to a placeholder. A failed remote fetch is retried on the
next render after about a minute.

## The mouse wheel does not scroll the preview

Confirm `sync.mouse_scroll = true`, that Neovim mouse support is enabled, and
that the pointer is inside the preview window. The handler is scoped to the
window under the pointer and deliberately does not turn source-window wheel
events into preview motion. Keyboard navigation works regardless.

## Scrolling feels slow

Run `:MdViewerDebug` after a scroll and compare the `fast_*` and `retina_*`
values, especially `fast_capture_ms`, `fast_png_bytes`, and
`fast_image_update_ms`. The coalesced counter shows how much repeated input was
collapsed to the newest position; completed frames are never deliberately
discarded. If terminal transfer still dominates, lowering
`render.device_scale_factor` to `1` is the final quality/performance trade.

## A notification over the preview shows Markdown through its background

A negative `raw_zindex` draws the image below text glyphs but *above* cell
background colours, so a passive (non-focusable) float does not occlude the image
on its own — its rectangle has to be cut out of the placement.

- Confirm `:MdViewerDebug` reports a nonzero `passive_cutouts` while the
  notification is visible. Zero means the float was not recognized as a passive
  overlay at all — check whether it is genuinely non-focusable.
- Confirm the raw z-index is negative (`-2` by default).

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
race — usually from editing or scrolling continuously enough that every
interaction's content revision goes stale before the renderer answers. That is a
requirement rather than a bug: a selection captured against superseded content
must never be shown.

## A selection does not appear after dragging

A drag has to cross `interaction.drag_threshold_cells` (default `1`) before it is
recognized as a drag rather than a click, so a very small, fast drag inside one
cell registers as a plain click — which clears any existing selection instead of
creating one. `:MdViewerDebug`'s `selection_active` and `selection_text_length`
report whether anything is held selected server-side, independently of whether it
is currently visible.

## A click lands on the wrong character

Confirm `viewport calibration` reads `explicit`, not `estimated` — an estimated
cell size is a real source of click-position error on a terminal/font combination
the estimate does not match well. Setting `MD_VIEWER_CELL_WIDTH_PX` and
`MD_VIEWER_CELL_HEIGHT_PX` removes the estimate entirely.

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

## The wrong terminal profile was detected

`:MdViewerHealth`'s Terminal/Profile row names what was detected;
`:MdViewerDebug`'s `identified by` field shows exactly why. If it is wrong,
override it with `terminal.profile` rather than relying on `"auto"`;
`terminal.kitty_graphics` and `terminal.probe` are the finer-grained overrides
beneath it. A wrong profile most commonly affects the default z-index and
double-buffer values and the calibration tier's defaults, not whether the preview
renders at all.

---

When reporting a graphical bug, record the exact backend, terminal and Neovim
versions, statusline/winbar configuration, and a minimal reproduction, and
confirm it reproduces outside any multiplexer. See
[terminal-support.md](terminal-support.md) for the per-terminal status.
