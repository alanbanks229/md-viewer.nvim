# Troubleshooting

Start with `:MdViewerHealth`, which separates terminal detection, Kitty protocol
advertisement, actual probe status, `vim.ui.img` presence, and a successful image
render. `TERM_PROGRAM=iTerm.app` alone is never treated as proof.

## Preview uses styled text instead of a PNG

`auto` selected the cell fallback because the installed build did not expose a
usable `vim.ui.img` API. This is a build/API availability issue, not a Kitty.app
dependency. Explicitly select `backend = "kitty_raw"` inside a direct iTerm2 TUI
for the supported graphical path.

## Explicit backend reports unavailable

This is intentional: explicit `nvim_img` and `kitty_raw` selections do not
silently fall back. Use `:MdViewerHealth`; select `cells` while investigating.

## Renderer exits or Playwright is missing

Run the locked local install from `renderer/`:

```sh
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts
```

Do not run `playwright install`. Confirm that the approved Chrome path shown by
`:MdViewerHealth` exists and set `browser.executable_path` when needed. Renderer
stderr and request serials are available through `:MdViewerDebug`.

## Image is stretched or soft

Set the actual iTerm2 profile cell size, in pixels:

```sh
export MD_VIEWER_CELL_WIDTH_PX=10
export MD_VIEWER_CELL_HEIGHT_PX=20
```

Those numbers are examples only—measure the active profile rather than copying
them. Health should then report `viewport calibration: explicit`.

## Local image is absent

Confirm it is PNG/JPEG/GIF/WebP, below the byte limit, and canonically inside
`security.document_root`. A symlink pointing outside the root is rejected. SVG
and every remote URL are intentionally unsupported.

## Mouse wheel does not move the preview

Confirm `sync.mouse_scroll = true`, that Neovim mouse support is enabled, and
that the pointer is inside the preview content window. The handler is scoped by
the window under the pointer; it intentionally does not turn source-window
wheel events into preview motion. Vim navigation continues to work even when
mouse support is disabled.

## Preview scrolling feels slow

Run `:MdViewerDebug` after a scroll and compare the persisted `fast_*` and
`retina_*` values, especially `fast_capture_ms`, `fast_png_bytes`, and
`fast_image_update_ms`. The coalesced counter shows how much repeated input was
collapsed to the newest position. Completed frames are not deliberately
discarded. If terminal transfer remains dominant, lower
`render.device_scale_factor` to `1` as a final quality/performance tradeoff.

## Preview typography is smaller than VS Code

The browser CSS uses a 14 px system-font baseline. A visual size
mismatch usually means the estimated terminal cell width is too large, causing
iTerm2 to scale the whole screenshot down. Lower
`render.estimated_cell_width_px` gradually. Prefer exact `MD_VIEWER_CELL_WIDTH_PX` and
`MD_VIEWER_CELL_HEIGHT_PX` values when available.

## Image overlaps UI or survives close

For `kitty_raw`, confirm `:MdViewerHealth` reports raw z-index `-1` and
`:MdViewerDebug` reports `occluded = true` while an overlapping float is visible.
The overlap guard removes the image only for focusable UI. Non-focusable
notifications create cropped placement cutouts, exposing their actual background
without blanking the rest of the Markdown document. `:MdViewerDebug` reports the
active count as `passive_cutouts`.

If a provider creates windows with `noautocmd=true`, confirm debug output shows
`ui_polling = true`. The default 50 ms interval discovers focusable floats
without requiring provider-specific hooks. Passive notifications are ignored by
full suppression; the same poll updates their cutout geometry without
retransmitting the PNG.

## A notification over the preview shows Markdown through its background

This is the specific bug `image.raw_overlay_bleed_cells` and the atomic
placement-swap fix (`kitty_raw.lua`'s `M.move`) exist for. `raw_zindex = -1`
draws the image below terminal text glyphs but *above* cell background
colors, so a passive (non-focusable) float does not occlude the image on its
own -- its rectangle has to be cut out of the placement, and that cut has to
actually reach the terminal. If you see the rendered Markdown showing through
a notification instead of the notification's own background:

- Confirm you are running a build that includes the fix (`:MdViewerHealth`
  reports `raw_graphics_overlay_bleed_cells`; if that field is absent, the
  build predates it).
- Confirm `:MdViewerDebug` reports a nonzero `passive_cutouts` while the
  notification is visible. Zero means the float wasn't recognized as a
  passive overlay at all (check whether it is genuinely non-focusable).

## A gap or overhang appears beside a notification over the preview

The cutout is exact in cells, but the image's own on-screen origin need not
be: some terminals (iTerm2 confirmed) apply their horizontal window margin to
text but not to graphics placements, shifting the image a fraction of a cell
toward the origin. `image.raw_overlay_bleed_cells` (default `1`) absorbs a
small gap; `image.raw_cell_offset_px` cancels the shift outright on a
terminal that implements the Kitty protocol's `X`/`Y` placement keys. See
"Notifications over the preview" in README.md for how to measure the offset,
and `docs/manual-testing.md`'s alignment matrix for what has and has not been
measured on which terminal.

## The preview image blinks, rolls, or briefly shifts by about a row

A stale symptom of re-cropping the image non-atomically -- fixed by making
`kitty_raw.lua`'s `M.move` emit the replacement placement and the deletion of
the one it supersedes as a single write, new first. If this reappears, it
means a placement change (typically a passive overlay appearing/disappearing)
is once again being applied as two separate terminal writes. `:MdViewerDebug`
cannot observe this directly -- it is terminal compositing behavior -- but
`tests/lua/cases/backend_kitty.lua` asserts the ordering at the byte level;
a regression there is the mechanism to look for.

## The preview image persists over another plugin's windows, or on the wrong tabpage

A raw Kitty placement is absolute screen coordinates the terminal keeps
compositing until explicitly told to stop -- it does not know or care which
Neovim window or tabpage is actually on screen. `:MdViewerDebug`'s
`tabpage_hidden` field reports whether md-viewer believes the preview's
tabpage is not the one currently displayed; if a stray image is visible while
`tabpage_hidden` is `false`, the plugin whose windows the image is
overlapping likely resized or repositioned the preview split without md-viewer
noticing (`WinNew`/`WinResized` should catch this for any new or resized
window, not only floating ones -- if it doesn't, that's a real regression to
report). If the image is visible on a *different* tabpage than the preview's
own, `refresh_deferred` should be `true` until you return to the preview's
tabpage.

## Clicking, dragging, searching, or copying does nothing

Confirm `:MdViewerHealth` reports `interaction enabled: true` and that the
relevant `interaction.*` flag (`selection`, `word_select`, `paragraph_select`,
`find`, `copy`, `links`) is not disabled. Interaction is unavailable outright
for the `cells` backend (`:MdViewerHealth`'s `selected_backend` must not be
`cells`) -- there is no DOM to hit-test against without a graphical backend.
`:MdViewerDebug`'s `interaction_request_count` and `interaction_stale_count`
distinguish "nothing is being sent at all" (both stay at zero -- check the
mapping/config above) from "requests are being sent but keep losing a race"
(a nonzero, growing `interaction_stale_count` -- usually caused by editing or
scrolling continuously enough that every interaction's content revision goes
stale before the renderer answers it; this is a real requirement, not a bug,
since a selection captured against superseded content must never be shown).

## A selection or highlight does not appear after dragging

Drag distance has to cross `interaction.drag_threshold_cells` (default `1`)
before a drag is even recognized as one rather than a click; a very small,
fast drag inside one cell can register as a plain click instead, which clears
any existing selection rather than creating a new one. `:MdViewerDebug`'s
`selection_active`/`selection_text_length` report whether anything is
actually held selected server-side, independent of whether it is currently
visible on screen (a selection can be correctly held while occluded, e.g.
during a scroll-only capture).

## A click lands on the wrong character, or link activation resolves the wrong content

Confirm the active `viewport_calibration_tier` (`:MdViewerHealth`) is
`explicit`, not `estimated` -- an estimated cell size is a real source of
click-position error on a terminal/font combination the estimate doesn't
match well. Set `MD_VIEWER_CELL_WIDTH_PX`/`MD_VIEWER_CELL_HEIGHT_PX` (see
above) to remove the estimate entirely. `:MdViewerDebug`'s
`interaction_last_precision` reports what precision the *last* interaction
actually resolved at (`exact`, `line`, `block`, or `none`) -- a `none` where
you expected an exact hit usually means the click landed in padding or
whitespace the parser genuinely cannot attribute to any source position, not
a bug; see docs/architecture.md for what each precision level means. No
automated test in this repository can confirm where a real click lands on
real hardware for multibyte content -- see `docs/manual-testing.md`.

## A link to another document refuses to open

Check which message it is -- they mean different things.

*"link target does not exist"* means the path resolved fine and there is nothing
there: a typo, or a file not written yet. Nothing to configure.

*"refused to open link outside the document root (`<root>`)"* names the root it
was measured against. By default that is the project enclosing the document (the
nearest ancestor holding `.git`, `.hg`, or `.svn`). A document outside any such
project is rooted at its own directory instead, so a link to a sibling directory
is genuinely outside it. Either set `security.document_root` explicitly, or add
a marker to `security.document_root_markers`.

`:MdViewerHealth` shows both the resolved root and where it came from
(`document root source`), and warns outright when a **configured**
`security.document_root` does not contain the document being previewed --
the case where every local link and image in that document is refused and
nothing else says why.

This is worth checking first if links fail in one project but work in another:
a `security.document_root` set once, globally, in your Neovim config pins every
preview to that one directory. Unset it and let `document_root_markers` root
each document in its own project instead.

## Ctrl-click or Cmd-click does not activate a link

Both are mapped. On macOS the terminal itself often claims them first: iTerm2
uses Cmd-click to open URLs, and several terminals emulate a right-click on
Ctrl-click. If `:MdViewerDebug`'s `interaction_request_count` does not increase
when you click, the gesture never reached Neovim and the terminal's own mouse
settings are where to look. If it does increase but nothing opens, the link was
classified or refused -- see above.

## A ctrl-clicked external link does nothing

`:MdViewerDebug` records the hand-off: `last_external_open` holds the URL, when
it was attempted, and what came back.

- `"none"` -- md-viewer never got that far. Either the click did not reach
  Neovim (see the section above) or the point was not over a link; a ctrl-click
  whose hit test *fails* now says so rather than going quiet.
- `no handler: ...` -- `vim.ui.open` found nothing to run. This used to be
  silent: it reports that failure by returning `nil`, not by raising, so the
  `pcall` around it never saw anything wrong.
- `exit code N`, or a message from the handler -- the OS started a handler and
  it refused. Also reported as a notification.
- `spawned`, with nothing after it -- the handler is still running, which is the
  successful case for a browser that stays open.

md-viewer never opens a URL itself; it asks Neovim, which asks the operating
system (`open` on macOS, `xdg-open` on Linux, `start` on Windows). If
`last_external_open` says the handler exited cleanly and no window appeared, run
the same URL through your own shell -- the problem is between the OS and the
default browser, not in the preview.

## The mouse pointer never changes shape over the preview

It never will: md-viewer does not change it. The preview is a PNG, so only the
terminal itself could (through `OSC 22`), and support proved inconsistent enough
across terminals that the feature was removed rather than left half-working.
Neovim's global `'mousemoveevent'` is left alone as a result.

## Wrong terminal profile detected

`:MdViewerHealth`'s `terminal_profile` and `terminal_profile_evidence` fields
show exactly what was detected and why -- never trust `TERM_PROGRAM` alone
(policy: detection evidence is not validation). If the profile is wrong,
override it explicitly with `terminal.profile` rather than relying on
`"auto"`; `terminal.kitty_graphics` and `terminal.probe` are the finer-grained
overrides beneath it. A wrong profile most commonly affects the default
z-index/double-buffer values and the calibration tier's defaults, not
whether the preview renders at all.

Stop and record the exact backend, terminal/Neovim versions,
statusline/winbar configuration, and reproduction in a bug report. Use
`:MdViewerClose`; md-viewer deletes only IDs it owns. Do not use global
image deletion because that can damage unrelated plugins.
