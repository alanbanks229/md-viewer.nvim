# Architecture

How md-viewer is built, and which invariants a change must not break. Statements
marked **Invariant** are load-bearing: each has a plausible-looking simplification
that reintroduces a real defect.

The preview is a browser-rendered PNG surface. Mouse and keyboard interactions
are forwarded to a persistent Chromium DOM, which performs hit-testing, search,
and link resolution before the viewport is recaptured. Text highlighting goes
through the same DOM, but only ever from a keyboard-driven vim-motion
selection (`v`/`V`) — there is no click-and-drag selection. That gives
browser-like behavior; it is not native terminal text selection and not an
embedded webview.

## Data flow

The controller reads unsaved lines from each source buffer. All buffer-specific
state — windows, backend, request serials, image ID, block geometry, scroll
value, timers, synchronization guard — lives in that buffer's session. Sessions
share one `node` process per Neovim instance.

Requests and responses are newline-delimited JSON with numeric IDs over the
renderer's stdin/stdout. The Node process keeps one headless Chromium browser,
isolated context, and page alive. It parses Markdown with markdown-it, annotates
tokens using `token.map`, applies bundled CSS and highlighting, scrolls the page,
and screenshots only the visible viewport. Lua reads the returned temporary PNG
then unlinks it. Both sides reject or supersede stale work.

No WebSocket, deliberately: the renderer is already persistent, no connection is
re-established per edit, and a WebSocket would require a listening HTTP/TCP
endpoint while leaving browser layout, PNG capture, and terminal image transfer
untouched. Scroll-only work reuses cached HTML, the live DOM, document geometry
and the token source map, then performs a page scroll and viewport screenshot
alone.

Interactive scrolling uses a two-stage capture: a moving frame at Playwright's
CSS-pixel scale, avoiding the fourfold pixel area of a 2× device-scale PNG, then
one device-scale screenshot once input settles. Capture requests name a cached
document revision and omit the Markdown body. Controller backpressure permits one
moving capture plus one newest pending position, and every completed frame is
shown — there is no fixed frame limiter, since screenshot and terminal-transfer
completion provide the pacing.

The moving frame carries a third dimension, `render.scroll_scale`, resolved by
`controller.schedule_scroll` from the session rather than from configuration
alone: unset it is full size locally and `render.ssh_scroll_scale` over SSH,
because the cost it trades sharpness against is wire time and wire time only
exists over SSH. It reaches the CDP screenshot's `clip.scale` as a numeric
factor; Playwright's own `scale` is a two-value enum, so the fallback path
silently produces the full-size frame instead. **Invariant:** the factor applies
only to the moving capture. The settle frame is the picture a reader is actually
looking at, and a preview left permanently soft is the one defect this
optimization could plausibly introduce — so the renderer refuses the factor on
the `device` tier as well as the Lua side never sending it there, and
`fast_scroll = false` (which leaves no separate moving frame) resolves to no
factor at all. **Invariant:** placement geometry is independent of capture scale.
The rectangle comes from cells and the CSS viewport, so a frame captured at 0.5×
is placed into the same cells with the same `c`/`r` keys and the terminal scales
it; `tests/lua/cases/scroll_scale.lua` asserts the two streams' cell geometry is
identical. Why the obvious alternative is wrong, and what it would take to stop
sending pixels altogether, is in [local-render-design.md](local-render-design.md).

**Image pipeline.** The page can only ever load `data:` URIs: the sanitizer
allows no other scheme on `img`, the CSP is `img-src data:`, and a Playwright
route aborts every browser request that is not `data:`/`about:`
(`renderer/src/security.js`) — all three unconditional, with nothing that
relaxes them. Local files are validated (magic bytes, size cap, document root)
and inlined during `renderMarkdown`. Remote images keep the same shape: the
Node process fetches over https unconditionally between markdown-it's parse
and render (`renderer/src/remote-images.js`), follows redirects up to three
hops, enforces the size cap while streaming, sniffs the magic bytes, and
inlines the result as another `data:` URI, cached by URL so live-preview
re-renders do not refetch. Every fetch — the URL as written and each redirect
hop alike — first resolves the host and connects only if the result is a
public network address, pinned to the specific address checked (a `lookup`
that re-resolved independently at connect time would leave a window for the
checked and connected addresses to differ). **Invariant:** remote fetching
happens only in the Node process — the browser's route, CSP, and sanitizer are
never involved and never make a network request, regardless of what a
document references. An image that is refused or fails renders as a visible
placeholder with the reason baked into an inline SVG, so showing it needs no
network and no script.

**The media lane.** Animated images (GIF, animated WebP) get a second request
lane that never touches the render queue or its serials. Registration is a
shallow header sniff at parse time (`renderer/src/media.js`, the single home of
the animation budgets); geometry travels *with the render response*, measured
in the pass that produced the base screenshot, so rects and the picture under
them share one staleness and cannot disagree. Frames are materialized on
demand, addressed purely by `(content sha, drawn size)`: decoded and resized by
Chromium in a dedicated JavaScript-enabled context (`renderer/src/decode-context.js`
— see SECURITY.md for its boundary), written as drawn-size PNGs under the
renderer's temp directory, cached with byte-accounted LRU eviction where each
cache entry owns exactly one directory. Every frame carries a stable content
key, which is what the Lua side keys terminal uploads by — shared across
sessions and across renderer restarts, freed with the data-releasing delete
when no live session references them. Playback is a per-terminal strategy
(`lua/md-viewer/animation.lua`): the Kitty protocol's own animation extension
where qualified, a shared duration-preserving frame-swap timer elsewhere, the
still frame always underneath.

## Preview surface and coordinates

`preview.lua` creates a read-only `nofile` scratch buffer, never a terminal.
`coordinates.lua` derives the placement rectangle from `screenpos(win, topline, 1)`
plus the window's width and height, so a winbar, statusline, tabline, global
statusline, separator and command line all fall outside it. Resize and scroll
events recalculate it.

**Invariant.** The scratch buffer holds real spaces — one line per placement row,
each as wide as the placement (`preview.surface_size`, re-asserted by
`preview.reset_surface` before every frame) — not empty lines plus `virtualedit`.
Virtual space lets the cursor push `leftcol` past zero, and `screenpos()` reports
every field as `0` for a position that is not visible. The fallback to
`nvim_win_get_position` plus the winbar row must therefore test the returned
**value**, not its type: `0` is truthy in Lua, so a `tonumber(x) or fallback`
guard is dead code and places the image at the terminal's origin.

The buffer holds no document text and is not what the reader navigates. It exists
so Neovim's cursor has somewhere legal to sit, so the window cannot scroll under
the image, and so a terminal without overlay support still has a cursor on the
right cell.

### The caret

The caret is a position in the rendered document, owned by the renderer
(`caret_move` in `interact.js`) and held in `caret.lua` as the glyph box the
renderer measured. Two properties follow, and both are the point: the caret only
ever sits on a real character — never in the page margin or beside a short
heading — and it is drawn the size of that character, through the same
`overlay_apply` path as the selection highlight, in its own rect set with its own tint
(`CARET_TINT`). Neovim's cursor is hidden while a preview with a drawable caret
is focused (`preview.hide_cursor`, a global `guicursor` swap) and shadows the
caret underneath via `coordinates.css_to_cell`.

**Invariant.** Caret identity is renderer-owned and carried as a character index
(`caretIndex`), never reconstructed from geometry. `caretPositionFromPoint`
answers with the nearest boundary *between* two characters, and a glyph's middle
is equidistant from the boundaries either side of it; the tie comes down to
rounding the glyph's advance to a LayoutUnit, so it is stable per glyph and
differs between glyphs. The box is how the caret is *drawn*; the index is what it
*is*, and a motion continuing from the caret sends the index rather than a point.
The index is checked, not trusted — the renderer rebuilds that character space
from the DOM per request, and an index that no longer names a character falls
back to the point. Two granularities withhold it deliberately: `"none"`, the
snap-only case meaning "the character nearest here", and a click, which is asking
for a point to be resolved.

**Invariant.** `caret_move` is read-only. A motion in visual mode must *extend*
the selection without disturbing it, which rules out `Selection.modify` — the
obvious primitive — because that can only move a caret by moving the selection's
own focus.

**Invariant.** Character motion is line-aware: `h` and `l` compare the candidate
glyph's box against the current one and refuse to leave the rendered row, as
Vim's do under the default `whichwrap`. Word motion crosses rows and blocks, but
the flat character space must insert a separator between blocks: the whitespace
between two of them lives in their container and is never walked, and without one
`Intl.Segmenter` reads the end of one block and the start of the next as a single
word.

The box is stored with the scroll it was measured at, so an ordinary scroll
re-places the caret locally with no round trip and a caret scrolled out of view is
simply not drawn. Motions cost one `interact` round trip each, because only the
renderer knows where the characters are.

### Raw placement and occlusion

**Invariant.** The base image, the animation frames and the selection overlay
must never share a z-layer — `-3`, `-2` and `-1` on every Kitty-graphics
profile, derived together in `resolve_layers` so they cannot drift apart. The
protocol breaks a z-index tie by image id (lower draws underneath) and md-viewer
re-uploads the base on every full frame, so a base sharing an upper layer climbs
above it and stays there. The symptom is one correct selection gesture per
session and then a highlight drawn silently *underneath* the preview, with every placement still
reporting success. The animation layer is reserved whether or not anything is
animating and whether or not `render.animate` is on: it costs nothing, and a
stack that changes shape depending on whether a document happens to contain a
GIF is exactly the property this must deny.

**Invariant.** A negative z-index keeps the image below text glyphs but *above*
cell background colours, so a passive (non-focusable) float does not occlude it —
its rectangle has to be cut out of the placement, or the image composites through
the notification's background and only its glyphs and border survive.

Floating-window rectangles are discovered through `nvim_tabpage_list_wins()`,
`nvim_win_get_config()` and screen coordinates. An overlapping *focusable* float
suppresses the placement, and closing it restores the cached PNG without another
capture. Passive overlays become exclusion rectangles, which `interaction.locate`
uses to refuse a click landing on one and which `kitty_raw.lua` subtracts from the
placement as cropped source-image placements. A one-cell bottom guard is reserved
when Neovim reports a statusline.

**Invariant.** `kitty_raw.move` writes the replacement placements and the deletion
of the ones they supersede in a single write, new first. Deleting first leaves the
terminal nothing to composite in between, visible as the image blinking and
rolling by about a row. `tests/lua/cases/backend_kitty.lua` asserts the ordering
at the byte level.

**Invariant.** The cut-out is exact in cells, but the image's origin need not be:
a terminal that applies its horizontal window margin to text while placing
graphics without it composites the image a fraction of a cell toward the origin
(measured on iTerm2). `coordinates.passive_overlays` widens each rectangle by
`image.raw_overlay_bleed_cells` on the **trailing edge only**, clipped to the
placement — a window margin is never negative, so the image can be offset left but
never right, and widening the leading edge would double the gap on the other side.
`image.raw_cell_offset_px` addresses the cause instead by emitting the protocol's
`X`/`Y` keys; it is zero by default, emitting no `X`/`Y` at all, because whether a
terminal implements them is not discoverable.

**Invariant.** A raw placement is absolute screen coordinates the terminal keeps
compositing on its own, so it must be deleted whenever the preview window stops
being displayed — including when its *tabpage* is no longer the one on screen,
which no window API reports (`coordinates.window_is_displayed`).

Raw sessions also run a small periodic geometry check alongside window events,
because some asynchronous UI providers create floats with `noautocmd = true`.

### Pixels versus cells

Everything above places images in terminal *cells* and lets the terminal scale to
fit, so a wrong cell-size estimate costs only sharpness. The selection overlay is
the one part of md-viewer that thinks in device pixels.

**Invariant.** Overlay rectangles must be sized against the size the image is
actually *drawn* at, from the OS-reported cell size (`TIOCGWINSZ`,
`cellpixels.lua`), measured fresh rather than cached — a terminal can keep its row
and column counts identical while changing its pixel geometry underneath, which
WezTerm does on every launch and any terminal does on a font-size change. Sizing
against the *capture* size instead draws every rectangle at the ratio between the
two. Where no cell size is reported the overlay disables itself and the full-frame
path takes over, rather than drawing rectangles it cannot size; `:MdViewerDebug`
reports the measurement as `cell pixels` under `-- Raw Graphics (kitty_raw) --`.

WezTerm's upstream issue #6344 (divide-by-zero panics in Kitty placement handling)
is unreachable as a consequence: a cell must floor to at least one pixel, and
every crop must be at least one pixel and wholly inside its image, before anything
is emitted.

Viewport calibration has three tiers, in precedence order: `env` when
`MD_VIEWER_CELL_WIDTH_PX` and `MD_VIEWER_CELL_HEIGHT_PX` both exist,
`measured` when `cellpixels.measure()` answers, and `estimated` otherwise.
The measurement is the same `TIOCGWINSZ` read the placement path already
trusts, and it reports *device* pixels; the viewport is CSS pixels, so
`coordinates.cell_metrics` divides by `device_scale_factor` — which is what
makes the captured PNG land exactly `cells × measured` device pixels, the same
count the terminal draws it into. The estimated tier chooses a bounded
high-DPI viewport from `estimated_cell_width_px` and the cell aspect ratio
instead, and the terminal scales the result. Screenshots are capped at
1920×1440 logical pixels — a bound `coordinates.viewport` mirrors from
`browser.js`, along with its 320×240 floor, so the reported viewport is always
the one the page received — a device scale of at most 3, and 32 MiB on the Lua
boundary.

## Backends

All image implementations expose `detect`, `show`, `update`, `move`, `clear`,
`clear_all` and `health`.

- `nvim_img` wraps only `vim.ui.img`; replacement creates the new image before
  deleting the old owned ID. It never performs wildcard deletion.
- `kitty_raw` contains the minimal direct protocol encoder: PNG/base64 chunks,
  static cell placement, cursor preservation, quiet mode, movement and targeted
  deletion. It writes only through `nvim_ui_send` (a Neovim 0.12 API, and the
  reason the plugin's version floor is what it is). Because Neovim owns terminal
  input, capability is *inferred* from the environment and never probed, so
  `detect()` answers from `terminal.capability` rather than from the wire.
  `auto` selects it whenever that inference finds any Kitty-graphics evidence.
- `cells` writes Markdown-like text and extmark highlights into the preview
  buffer when graphics are unavailable.

## Scroll synchronization

What a scroll *costs* depends on which rendering model the session picked; see
"Whole-document resident mode" below. What a scroll *means* is the same either
way, and is what this section describes.

The preview buffer holds blank cells, never document text; it does not pretend
browser pixels are editable lines. Buffer-local motions move the caret across
those cells and update browser `scrollY` when the caret reaches an edge.

Source lines map to browser blocks through markdown-it token ranges and measured
DOM geometry, the most specific range containing the cursor winning over
enclosing lists, tables and blockquotes. Its relative source-line position is
aligned to the cursor's screen row, with hysteresis and a short debounce so
walking adjacent lines does not screenshot per keypress; movement within the same
mapped block issues no render. A per-session guard prevents preview/source
feedback, and preview mappings never move the source cursor —
`sync.preview_to_source` is off by default.

The page includes a viewport-relative bottom spacer, one viewport minus a
rendered line, matching editor scroll-past-end behavior so the final block can
reach the preview's top region. That is real browser scroll range, not synthetic
buffer lines.

Mouse-wheel mappings exist only while a graphical preview does. The pointer's
actual window ID selects the session; events outside an md-viewer window fall
through to Neovim's own wheel behavior, and any previous user mappings are
restored after the last graphical preview closes.

## Whole-document resident mode

Two models are implemented, and a session picks one when it opens.

The **viewport** model is the original: every scroll position is a fresh
screenshot of the reader's viewport. Simple, works everywhere, and costs bytes
proportional to how far you scrolled — an ~80 KB moving frame and a ~305 KB
settle frame, which on a 0.80 MB/s link is ~134 ms and ~508 ms of wire each.

The **resident** model captures the document once as N chunks, holds every chunk
in the terminal's image memory, and turns a scroll into a cropped placement.
Measured against this repository's own README, 40 scrolls over a 12,505 px
document issued 0 renderer requests, uploaded 0 image bytes, and sent 58
placements in 7,855 bytes — 196 bytes per scroll.

Three layers, and conflating any two of them is how this feature fails:

    document + viewport geometry  ->  one canonical chunk plan
    scroll position               ->  which chunks are needed
    opening scroll position       ->  initial capture priority only

`resident.lua` is the arithmetic and touches no Neovim API, so each of those is
a test rather than a comment. `resident_session.lua` is the state machine and
`controller.lua` owns the policy.

Four constraints shape it, all measured rather than assumed:

- **A region capture must be document-absolute.** `page.screenshot({clip})` is
  not: the same clip returns different bytes at every scroll position and comes
  back at half the height asked for. Only CDP with `captureBeyondViewport: true`
  is usable, and there is deliberately no fallback to the other — a wrong
  picture of the right size cannot be detected downstream, because the reply
  echoes the region that was *asked* for. `scripts/resident/registration.mjs` is
  the standing proof.
- **Chromium cannot capture a tall document in one call.** 12,000,000 device px
  and 16,384 px tall per `Page.captureScreenshot`, so the document is
  necessarily N chunks.
- **Chunks overlap by two pane rows**, computed once per document in whole image
  pixels, so a viewport landing on a boundary composites from two chunks split
  at a whole cell row and both halves agree about the same document position.
- **Terminal memory is the budget, not the wire.** The resident set is bounded
  by a byte estimate *and* by a hard chunk count, because the byte estimate
  rests on a figure two measurements disagree about by 34x.

A position that cannot be drawn from resident chunks clears the pane rather than
leaving the previous screen up. That is the whole design goal restated: a stale
screen presents pixels of somewhere else as though they belonged to where the
reader now is, and nothing downstream — not the coordinate model, not the
placements, not the retirement — can tell.

## Interaction

Gestures reach the renderer through a second NDJSON method, `interact`, alongside
`render`/`capture` on the same persistent process, the same serial queue and the
same shared page. There is no second transport and no second process.

**Staleness lanes.** `renderer/src/lanes.js` tracks a per-document, per-lane
admission serial (`content`, `capture`, `interact`, `settle`) plus a content-epoch
counter. A newer request in the same lane supersedes an older one; a new `content`
render bumps the epoch and invalidates every downstream lane. **Invariant:** an
`interact` admission can never invalidate `content` or `capture` — there is no
code path from it to `contentEpoch` — so a burst of selection-preview updates
cannot starve a legitimate render. A superseded request fails its own staleness check, at
admission and again after the expensive work, and returns without touching the
page.

**Document isolation.** `browser.js` keeps one authoritative record, `this.active`,
of which document and content revision the shared page holds; it is cleared before
every `setContent()` and repopulated only after the new document's geometry has
been recollected, so no caller observes a half-loaded document.
`ensureDocumentActive()` is the only door into the DOM for an interaction: it
refuses (`INTERACT_CACHE_MISS`) any document/revision it cannot rebuild
byte-for-byte from its cached record, and rehydrates by replaying the exact HTML,
theme, font and viewport that produced the original screenshot rather than
approximating. A fresh, opaque per-load token is stamped on the document root and
checked by every in-page action (`DOCUMENT_MISMATCH`). **Invariant:** the
isolation guarantee comes from the serial queue — nothing can swap the page
between that check and the caller's `page.evaluate`, because both run inside it.

**Hit-testing and source precision.** A click resolves through `elementFromPoint`,
refined by caret-range APIs on real text. Source position comes from markdown-it's
own parse state (`token.map` for block tokens, an instrumented inline parser for
inline runs — `renderer/src/provenance.js`) rather than by searching rendered text
for a match, which would collide silently whenever a block contains the same word
twice. Precision degrades through `exact` (line and UTF-8 byte column), `line`,
`block` and `none`, and is never guessed past what the parser establishes.

**Invariant.** The terminal reports which *cell* was clicked, never a sub-cell
position, and a cell is neither as wide as a rendered character nor as tall as a
rendered line. `hitTestInPage` probes outward from the cell's centre in **both**
axes, bounded by that one cell and ordered nearest-first in cell fractions so a
tall cell does not make every vertical probe lose to every horizontal one.
Collapsing either axis makes real content permanently unclickable: on the
estimated calibration tier a cell is 20 CSS px while a rendered line is 25 and an
inline link's box about 18, so a link can fall entirely between two cell-row
centres at some alignments. `tests/node/hitbox.test.js` sweeps every alignment a
full cell height can take rather than sampling one. Within that cell a link wins
over prose — the cell is the resolution limit of the input device, so there is no
finer answer — but bounded by the same cell: two cells away is still prose.

**Selection, search and copy.** Highlighting text is a keyboard-only gesture —
`v`/`V` extending a real DOM selection from the caret, never a click-and-drag —
and, alongside it, search. Both produce a real `Selection`/`Range`
(`setBaseAndExtent`, `Text.splitText`) or `window.find`-equivalent matching.
**Invariant:** never `innerHTML`, so a query or
selection containing literal HTML is matched or copied character-for-character
rather than interpreted as markup. Every mutating interaction captures its own
screenshot in the same queued operation that performed the mutation, so Lua never
follows up with a second render to see the result.

**Invariant.** Per-document interaction state — the current selection, the current
search's match set — lives in trusted Node memory (`main.js`'s `interactionState`,
not the page, which `setContent` destroys on every document switch) and is
**replaced, never migrated**, across a content-revision change. Applying an old
selection to new content would be silent corruption in a copy.

**Invariant.** A selection that scrolls pins its anchor to the live DOM node
(`anchorPinned` on the `interact` envelope), not to viewport coordinates. Viewport
coordinates move under a scrolling page: the anchor drifts onto whatever text
scrolls into those pixels, and once it scrolls out of view the point is refused
and the frame dropped. A keyboard motion that scrolls the page mid-selection
(`j` past the viewport edge under `v`/`V`) is exactly this case: the scroll
frame and the selection-preview frame that follows it are two separate
`interact` round trips, so the selection frame always resolves against the
page's post-scroll position.

**Preview history.** Following a local link retargets the preview
(`controller.retarget`), and `preview.pinned` stops the preview following an
ordinary buffer switch — so without history the reader could reach a document but
not return to the one they came from as anything but text. Each session carries
the documents it has been retargeted through and an index into them.
**Invariant:** `:MdViewerBack`/`:MdViewerForward` walk the index without
appending — appending makes "back" oscillate between the last two entries — and a
`BufEnter` in the session's source window follows the preview to a buffer
*already in that list*, which is what makes `<C-o>` work without weakening
`pinned` for anything else. Entries hold a buffer and a path, so one whose buffer
has been wiped still reopens its file; navigating from the middle truncates the
forward branch, as a browser does.

**Link dispatch.** `classifyLink` (pure, `renderer/src/interact.js`) separates
`http`/`https`/`mailto`/fragment/local-file candidates from anything unsafe
(`javascript:`, `data:`, `vbscript:`, protocol-relative, malformed) before Lua
sees a decision to make. **Invariant:** that classification is a hint, not a
grant — a `local_file` candidate's containment is re-checked independently in
`lua/md-viewer/security.lua` (`resolve_local_link`/`is_inside`), the same
symlink-resolved check image loading uses. Ctrl/Cmd-click is the only gesture that
can activate a link. [SECURITY.md](../SECURITY.md) states the policy these
mechanics enforce.

An activated local Markdown link opens in Neovim and the preview follows:
`controller.retarget` re-keys the existing session onto the new buffer and
re-derives its `document_id`, reusing the preview window instead of rebuilding the
split. The serial bump is what makes that safe — responses still in flight for the
old document fail their staleness check rather than being applied to the new one.

**Lua-side dispatch.** `mouse.lua` installs its mappings only once a graphical
(non-`cells`) session exists, saving and restoring whatever was mapped there
before (`vim.fn.mapset`) across normal, insert and visual mode. It maps a plain
click, its release, and Ctrl/Cmd-click link activation — there is no drag
mapping, for any modifier, and no multi-click word/paragraph-select mapping:
highlighting is exclusively a keyboard gesture (`interaction.visual_start`,
triggered by `v`/`V` in `navigation.lua`). **Invariant:** mouse capture is
still button-scoped, not window-scoped (`interaction.lua`'s module-local
`captured` session) — once a press lands on preview content, its release
belongs to that session even if the pointer leaves the window first, which
matters because a release with no matching capture would otherwise leave
`session.pointer` stuck "pressed". A plain click places the caret and clears
an active selection, but never moves the source cursor.

## Lifecycle

Text events debounce, resize events coalesce, focus stays in the source window,
and tab/suspend events remove graphical placements. Close, wipe and exit
invalidate outstanding serials, stop timers, delete only owned images, remove
files, and shut the shared renderer down when the last session closes. The
startup spinner float's timer is owned by the buffer session and closed on every
shutdown path.

With `preview.pinned = true`, hiding the source buffer does not end its session:
the source split can display another file while the preview retains its image and
source-labeled winbar. Wiping the source, replacing or wiping the preview buffer,
closing the preview, or exiting Neovim still performs full cleanup.

## Design references

The pinned document identity, labeled preview surface, retained renderer state,
stale-response guards and manual-scroll precedence take focused inspiration from
[Markdown Preview Enhanced's preview provider](https://github.com/shd101wyy/vscode-markdown-preview-enhanced/blob/master/src/preview-provider.ts)
and its documented locked-preview workflow. md-viewer does not copy its webview,
script execution, CDN, diagram, export or interactive command features; those
would conflict with a read-only raster surface and this security boundary.
