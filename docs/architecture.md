# Architecture

> The preview is still a browser-rendered PNG surface. Mouse and keyboard
> interactions are forwarded to the persistent Chromium DOM, which performs
> hit-testing, selection, search, and link resolution before the viewport is
> recaptured. This provides browser-like behavior but is not native terminal
> text selection or a real embedded webview.

## Data flow

The controller reads unsaved lines from each source buffer. All buffer-specific
state—windows, backend, request serials, image ID, block geometry, scroll value,
timers, and synchronization guard—lives in that buffer's session. Sessions share
one `node` process per Neovim instance.

Requests and responses are newline-delimited JSON with numeric IDs. The Node
process keeps one headless Chromium browser, isolated context, and page alive.
It parses Markdown with markdown-it, annotates tokens using `token.map`, applies
bundled CSS and syntax highlighting, scrolls the page, and screenshots only the
visible viewport. Lua reads the returned temporary PNG then unlinks it. Both
sides reject/supersede stale work.

Transport remains local NDJSON over the renderer process's stdin/stdout pipes.
No WebSocket is used: the renderer is already persistent, no connection is
re-established per edit, and adding WebSockets would require a listening
HTTP/TCP endpoint while leaving browser layout, PNG capture, and terminal image
transfer untouched. Scroll-only work instead reuses cached Markdown HTML, the
live DOM, document geometry, and token source map, then performs only a page
scroll and viewport screenshot.

Interactive scrolling uses a two-stage capture. The first image uses
Playwright's CSS-pixel screenshot scale, avoiding the fourfold pixel area of a
2× device-scale PNG. Once input settles, one device-scale screenshot restores
Retina sharpness. Capture requests identify a cached document revision and omit
the Markdown body entirely. Controller backpressure permits at most one moving
capture plus one newest pending position, and each completed frame is shown.
There is no fixed frame limiter; screenshot and terminal-transfer completion
provide the natural pacing.

## Preview surface and coordinates

`preview.lua` creates a normal read-only `nofile` scratch buffer, never a
terminal. `coordinates.lua` uses `screenpos(win, 1, 1)` for the first visible
buffer cell and Neovim's window width/height for the exact text grid. A winbar,
statusline, tabline, global statusline, separator, and command line are therefore
outside the placement rectangle. Resize and scroll events recalculate it.

During the initial persistent-renderer and Chromium startup, `preview.lua`
centers a one-line non-focusable spinner float relative to the preview window.
The scratch buffer itself stays one blank line. A successful first frame removes
the spinner before calculating Kitty placements; a renderer failure removes it
before emitting the actionable notification. Its timer is owned by the buffer
session and is closed on every preview shutdown path.

The raw backend uses z-index `-1`, which keeps the image below terminal text
while remaining visible above the Neovim backgrounds painted by iTerm2. It
reserves a one-cell bottom guard when Neovim reports a statusline. Visible
floating-window rectangles are discovered through
`nvim_tabpage_list_wins()`, `nvim_win_get_config()`, and screen coordinates. An
overlapping focusable float suppresses the placement and closing it restores the
cached PNG without another browser capture. Non-focusable passive overlays are
tracked as exclusion rectangles on the placement, which `interaction.locate`
uses to refuse a click that lands on one, and which `kitty_raw.lua` subtracts
from the placement as cropped source-image placements. That subtraction is what
gives a passive float an opaque interior: z-index `-1` is above the cell
background, so without it the image composites straight through a
notification's background and only the notification's glyphs and border
characters survive. `kitty_raw.move` writes the replacement placements and the
deletion of the ones they supersede in a single write, new first — deleting
first left the terminal with nothing to composite in between, which was visible
as the image blinking and rolling by about a row.

That subtraction is exact in cells, but the image's own origin need not be. A
terminal that applies its horizontal window margin to text while placing
graphics without it composites the image a fraction of a cell toward the origin
— measured at ~10px of a 20px cell on iTerm2, constant across columns 0, 28 and
88, and with the vertical origin exact. The cut-out inherits that shift, so the
image overhangs the overlay's trailing edge. `coordinates.passive_overlays`
widens each rectangle by `image.raw_overlay_bleed_cells` columns on that edge
only, clipped to the placement: a window margin is never negative, so the image
can be offset left but never right, and widening the leading edge would only
double the gap on the other side. `image.raw_cell_offset_px` addresses the cause
instead, emitting the protocol's `X`/`Y` placement keys so the image starts that
many pixels into its first cell; it is zero by default, which emits no `X`/`Y`
at all, because whether a given terminal implements those keys is not
discoverable.

Because a raw placement is absolute screen coordinates the terminal keeps
compositing on its own, it must be deleted whenever the preview window stops
being displayed — including when the preview's *tabpage* is no longer the one
on screen, which no window API reports (`coordinates.window_is_displayed`).

Raw sessions perform a small periodic geometry check in addition to Neovim
window events. Some asynchronous UI providers create floats with
`noautocmd=true`; polling the current tab's window metadata catches those
without any dependency on the provider.

Pixel calibration is explicit when `MD_VIEWER_CELL_WIDTH_PX` and
`MD_VIEWER_CELL_HEIGHT_PX` exist. Otherwise the renderer chooses a bounded high-DPI
viewport using `estimated_cell_width_px` and the configured cell aspect ratio;
the terminal scales that image to cells. Screenshots are capped at 1920×1440
logical pixels, a device scale of
at most 3, and 32 MiB on the Lua boundary.

## Backends

All image implementations expose `detect`, `show`, `update`, `move`, `clear`,
`clear_all`, and `health`.

- `nvim_img` wraps only `vim.ui.img`; replacement creates the new image before
  deleting the old owned ID. It never performs wildcard deletion.
- `kitty_raw` contains the minimal direct protocol encoder: PNG/base64 chunks,
  static cell placement, cursor preservation, quiet mode, movement, and targeted
  deletion. It writes only through `nvim_ui_send`. Because Neovim owns terminal
  input, its response probe is not falsely reported as successful and auto mode
  does not select it in this build.
- `cells` writes readable Markdown-like text and extmark highlights into the
  preview buffer when graphics are unavailable.

## Scroll synchronization

The graphical preview buffer remains one blank line; it no longer pretends that
browser pixels are editable buffer lines. Buffer-local Vim motions update browser
`scrollY` directly: line, half-page, page, top, and bottom movements. Source
lines map to browser blocks through markdown-it token ranges and measured DOM
geometry. A per-session guard prevents preview/source feedback. The most specific token
range containing the cursor wins over enclosing lists, tables, and blockquotes.
Its relative source-line position is aligned to the cursor's actual screen row,
with hysteresis and a short debounce so walking adjacent lines does not produce
a screenshot on every keypress. Cursor movement within the same mapped block
does not issue another render.

Navigation allows one capture in flight and retains only the newest pending
position. Every completed frame is displayed, with no fixed FPS throttle. The
preview mappings never move the source cursor; preview-to-source movement is
disabled in the bundled iTerm2 configuration.

The browser page includes a viewport-relative bottom spacer by default. Its
height is one viewport minus a rendered line, matching editor scroll-past-end
behavior so the final Markdown block can reach the preview's top region. This
is real browser scroll range, not synthetic scratch-buffer lines.

Mouse-wheel mappings are installed only while a graphical preview exists. The
pointer's actual Neovim window ID selects the session; events outside an md-viewer
window fall through to the original Neovim wheel behavior. The mappings and any
previous user mappings are restored after the last graphical preview closes.

## Interaction

Mouse gestures reach the renderer through a second NDJSON method, `interact`,
alongside `render`/`capture` on the same persistent process and the same
serial queue over the one shared Chromium page -- there is no second
transport and no second process.

**Staleness lanes.** `renderer/src/lanes.js` tracks a per-document, per-lane
admission serial (`content`, `capture`, `interact`, `settle`) plus a
content-epoch counter. A newer request in the same lane supersedes an older
one; a new `content` render bumps the epoch and invalidates every downstream
lane. Critically, an `interact` admission can never invalidate `content` or
`capture` -- there is no code path from it to `contentEpoch` -- so a burst of
drag updates cannot starve or cancel a legitimate render. A superseded
request fails its own staleness check (checked at admission and again after
the expensive work) and returns without touching the page.

**Document isolation.** `renderer/src/browser.js` keeps exactly one
authoritative record, `this.active`, of which document (and content
revision) the single shared page currently holds, cleared before every
`setContent()` and repopulated only after the new document's geometry has
been recollected -- no caller can observe a half-loaded document.
`ensureDocumentActive()` is the only door into the DOM for an interaction: it
refuses (`INTERACT_CACHE_MISS`) a document/revision it cannot rebuild
byte-for-byte from its own cached record, and rehydrates (replays the exact
same HTML/theme/font/viewport that produced the original screenshot) rather
than approximating. A fresh, opaque per-load token is stamped on the
document root and checked by every in-page action before it touches the DOM
(`DOCUMENT_MISMATCH` on a mismatch) -- the actual isolation guarantee is that
nothing can swap the page between that check and the caller's own
`page.evaluate`, since both run inside the same serial queue.

**Hit-testing and source-position precision.** A click resolves through
`elementFromPoint`, refined by caret-range APIs when the hit lands on real
text; source position is recovered from markdown-it's own parse state
(`token.map` for block tokens, an instrumented inline parser for inline
runs -- see `renderer/src/provenance.js`) rather than by searching rendered
text for a match, which would collide silently whenever a block contains the
same word twice. Precision degrades honestly through four levels and is
never guessed past what the parser can actually establish:

    exact    A precise line and UTF-8 byte column.
    line     A line, but not a column (e.g. a highlighted code span whose
             internal structure the parser does not track per-character).
    block    A containing block only (e.g. a table cell, or content the
             renderer re-emits as raw HTML, like a task-list item).
    none     No position at all -- padding, whitespace, or an out-of-bounds
             point. Reported honestly rather than resolved to the nearest
             plausible guess.

The terminal reports which *cell* was clicked, never a sub-cell position, so
a click covers a whole cell -- and a cell is neither as wide as a rendered
character nor as tall as a rendered line. `hitTestInPage` therefore probes
outward from the cell's centre in **both** axes, bounded by that one cell and
ordered nearest-first in cell fractions (so a cell twice as tall as it is wide
does not make every vertical probe lose to every horizontal one), rather than
collapsing to the centre alone. Both axes have produced a reported bug:
collapsing horizontally made the cell holding a line's first character, which
is mostly left padding, permanently unclickable; collapsing vertically made an
inline link permanently unclickable at some alignments, because on the
estimated calibration tier a cell is 20 CSS px while a line is 25 and a link's
box about 18 -- so the link can fall entirely between two cell-row centres.
That one is measured, not reasoned, and `tests/node/hitbox.test.js` sweeps
every alignment a full cell height can take rather than sampling one.

Within that cell, a link wins over prose. The cell is the resolution limit of
the whole input device -- there is no finer answer available -- so a link
anywhere under the clicked cell is what the reader was pointing at, and prose
is the answer only when the cell holds no link at all. Bounded by the same one
cell: two cells away is still prose.

**Selection, search, and copy.** Drag-to-select, double/triple-click, and
search all produce a real Chromium `Selection`/`Range` (`setBaseAndExtent`,
`Text.splitText`) or use `window.find`-equivalent text matching -- never
`innerHTML`, so a search query or a selection containing literal HTML is
matched or copied character-for-character, not interpreted as markup. Every
mutating interaction (a selection change, a search step) captures its own
screenshot in the same queued operation that performed the mutation, so Lua
never has to follow up with a second render just to see the result.
Per-document interaction state (the current selection, the current search's
match set) lives in trusted Node memory (`main.js`'s `interactionState`, not
the page, which `setContent` destroys on every document switch) and is
replaced, never migrated, across a content-revision change -- applying an old
selection to new content would be silent corruption in a copy operation.

**Preview history.** Following a local link retargets the preview onto another
document (`controller.retarget`), and `preview.pinned` deliberately stops the
preview following an ordinary buffer switch -- so the reader could reach a
document but not return to the one they came from as anything but text. Each
session therefore carries the list of documents it has been retargeted through
and an index into it. `:MdViewerBack`/`:MdViewerForward` walk the index without
appending (appending there would make "back" oscillate between the last two
entries), and a `BufEnter` in the session's source window follows the preview to
a buffer *already in that list* -- which is what makes `<C-o>` work without
weakening `pinned` for anything else. Entries hold a buffer and a path, so one
whose buffer has been wiped still reopens its file; navigating from the middle
truncates the forward branch, the same rule a browser follows.

**Link dispatch.** `classifyLink` (pure, `renderer/src/interact.js`)
separates `http`/`https`/`mailto`/fragment/local-file candidates from
anything unsafe (`javascript:`, `data:`, `vbscript:`, protocol-relative, or
malformed) before Lua ever sees a decision to make. A `local_file`
candidate's containment inside the document root is re-checked
independently on the Lua side (`lua/md-viewer/security.lua`'s
`resolve_local_link`/`is_inside`), the same symlink-resolved check image
loading already uses -- the renderer's classification is a hint, not a
grant. Ctrl/Cmd-click is the only gesture that can activate a link; a plain
click never does, on any hit.

That root is the enclosing project, not the document's own directory. The
narrower default refused every ordinary repo-relative link from a document in a
subdirectory, and reported it as a security violation, which is both wrong and
misleading -- the three distinct failures (escapes the root, does not exist,
malformed) are now distinguished, with the out-of-root case decided lexically so
the messages cannot be used to probe for files outside the root.

An activated local Markdown link is opened in Neovim rather than handed to the
system, and the preview follows it: `controller.retarget` re-keys the existing
session onto the new buffer and re-derives its `document_id`, reusing the
preview window instead of tearing the split down and rebuilding it. The serial
bump is what makes that safe -- every render or interact response still in
flight for the old document fails its staleness check rather than being applied
to the new one.

**Lua-side gesture dispatch.** `lua/md-viewer/mouse.lua` installs its
mappings only once a graphical (non-`cells`) session exists, saving and
later restoring whatever was mapped there before (`vim.fn.mapset`), across
all of normal/insert/visual mode. Mouse capture is button-scoped, not
window-scoped (`interaction.lua`'s module-local `captured` session): once a
press lands on preview content, the matching drag/release belongs to that
session even if the pointer later leaves the window before the button comes
up. A plain click (no drag) clears an active selection and never moves the
source cursor under any gesture -- an earlier, removed behavior did move the
cursor on click, which fought the drag-to-select gesture (dismissing a
highlight by clicking elsewhere also relocated the editor cursor); see
`docs/cross-platform-implementation-status.md`'s "click-to-source removed"
follow-up.

## Lifecycle

Text events debounce, resize events coalesce, focus stays in the source window,
and tab/suspend events remove graphical placements. Close/wipe/exit invalidates
outstanding serials, stops timers, deletes only owned images, removes files, and
shuts the shared renderer down when the last session closes.

With `preview.pinned = true`, hiding the source buffer does not end its session.
The source split can display another file while the preview split retains its
Markdown image and source-labeled winbar. Wiping the source, replacing/wiping
the preview buffer, explicitly closing the preview, or exiting Neovim still
performs full cleanup.

## Design references

The pinned document identity, labeled preview surface, retained renderer state,
stale-response guards, and manual-scroll precedence take focused inspiration
from [Markdown Preview Enhanced's preview provider](https://github.com/shd101wyy/vscode-markdown-preview-enhanced/blob/master/src/preview-provider.ts)
and its documented locked-preview workflow. md-viewer does not copy its webview,
script execution, CDN, diagram, export, or interactive command features; those
would conflict with a read-only raster surface and the version-one security
boundary.
