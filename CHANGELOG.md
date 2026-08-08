# Changelog

All notable changes to this project will be documented here. The project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- The terminal cell size is measured fresh instead of being remembered. It was
  read once and cached, and re-checked only against the row and column counts —
  which a terminal can leave alone while changing its pixel geometry
  underneath. WezTerm does exactly that on every launch: it sizes its pty at
  half scale and corrects it about two seconds later, with the grid identical
  either side. A preview opened in that window kept a half-scale cell for the
  rest of the session and drew every drag-highlight rectangle at half size. A
  terminal font-size change did the same thing more slowly. This affected every
  terminal, not just WezTerm.

### Changed

- Drag-to-highlight no longer re-photographs the page on every frame, on
  iTerm2. While the mouse is down the highlight is drawn directly in the
  terminal as translucent rectangles composited over the frame already on
  screen — one small tint image is uploaded once, and each moving frame sends
  only placement commands. A moving frame costs roughly 91-500 bytes instead of
  about a megabyte of base64 PNG, and sends nothing at all when the selection
  has not changed. Releasing the mouse still lands a real browser-rendered
  frame, so the settled highlight is exactly what the page paints.

  **Enabled only where it was validated by hand in a real terminal**, which
  today means iTerm2, Ghostty and Kitty. Everywhere else the drag keeps the
  full-frame path, which stays correct — merely slower.
  `interaction.selection_overlay` (`"auto"` / `"on"` / `"off"`) overrides that,
  and `"on"` is how you would try another terminal.

  **WezTerm is off deliberately, and not for the reason first recorded.** The
  2026-08 investigation photographed a real window on both
  `20240203-110809-5046fc22` and a current build and found two things. Its
  geometry is fixable: WezTerm applies the protocol's sub-cell offset to every
  cell of a placement rather than the first, and as an inset, so a highlight bar
  draws as a comb of stripes — md-viewer now has an encoding that sends WezTerm
  no offset keys at all, and it draws correctly on both builds. What is not
  fixable from here is the cost: sustained placement traffic grows WezTerm's
  memory without bound, 172 MB to 786 MB in four seconds with four rectangles,
  with either encoding. Do not set `selection_overlay = "on"` in WezTerm; it
  will look right and exhaust your memory. Details and photographs in
  `docs/cross-platform-implementation-status.md`.

- Fixed: on Ghostty the instant highlight worked once per session and then
  silently stopped, so every drag after the first behaved like the old
  re-photographed path. It was not falling back — the highlight was being drawn
  *underneath* the preview image.

  The Kitty graphics protocol breaks a tie between two images on the same layer
  by image id: the lower id draws underneath. md-viewer drew the preview and the
  highlight on the same layer and numbered them from the same counter, so the
  highlight outranked the preview for exactly one drag, and the next full frame —
  the one taken when you release the mouse — took the lead back and kept it.
  iTerm2 resolves that tie by which placement was made most recently, which is
  why it never showed there. Ghostty follows the specification.

  The preview and the highlight now always sit one layer apart, and the tint
  image is numbered from a range above every preview frame, so neither the layer
  nor the tie-break can put the highlight underneath. If you had pinned
  `image.raw_zindex = -1` to work around anything here, you no longer need to;
  it is now handled for you, and `interaction.selection_overlay = "off"` is the
  only setting that still leaves that value untouched.

- Fixed: scrolling the preview while text was selected disabled the instant
  highlight for every drag afterwards, until the preview happened to re-render
  with nothing selected. Any frame that reaches the screen without a selection
  painted into it now re-arms it — including the one a click-to-deselect
  produces.

### Added

- `:MdViewerHealth` now reports whether the drag highlight is being drawn as
  overlay rectangles and why, the layer it draws on beside the preview's own,
  and the terminal's measured cell size. The Ghostty bug above was invisible
  from the outside precisely because none of this was reported: a terminal
  drawing the highlight underneath the preview looked exactly like one falling
  back to full frames.

- Fixed: those drag rectangles were drawn too large — noticeably wider than the
  text and tall enough that adjacent lines in a code block touched, where the
  real selection leaves gaps.

  md-viewer places the preview over a rectangle of terminal *cells* and lets the
  terminal scale the image to fit, so when its estimate of your cell size is
  wrong the picture is simply squeezed to the right box and only sharpness
  suffers. The drag overlay was the first thing ever placed in **pixels**, and
  pixels only mean something against the size the image is actually drawn at. It
  was sizing rectangles against the size the image was *captured* at instead.
  On a terminal whose cell is 7×16 while the estimate said 10×20, that is 1.41×
  too wide and 1.24× too tall — at exactly the right position, because positions
  were always in cells.

  The terminal's real cell size now comes from the operating system
  (`TIOCGWINSZ`), which needs no escape sequence and nothing read back — the
  reason md-viewer could not ask for it before. Where a terminal does not report
  it, the drag overlay switches itself off and the captured-frame path takes
  over rather than drawing rectangles it cannot size. `:MdViewerHealth` reports
  the measurement as `cell_pixels`.

- Fixed: a highlight could survive into the next drag. Selecting some text,
  releasing, and then dragging out a new selection elsewhere left the first
  highlight on screen for the whole second drag.

  The frame underneath a drag is the browser's own capture, and after a
  selection settles it has that selection painted into it. Drag rectangles
  composite *over* that frame, so they can add a highlight but never remove one.
  A drag that starts on a frame like that now puts the cached selection-free
  frame back first — a local redraw, not another round trip to the browser — and
  falls back to full captured frames when there is no cached frame it can prove
  still matches what is on screen.

- The preview now pins its own selection colour per theme rather than inheriting
  Chromium's default. Over the page background the settled highlight is the same
  colour as before; over code blocks and table stripes it shifts by 2-7/255. The
  change exists so the drag-time overlay and the browser's own paint cannot
  disagree, and so text stays readable under an overlay that sits above it.

- Capturing a preview frame is roughly 2.3-2.8x cheaper, pixel for pixel.
  Chromium now launches with `--disable-frame-rate-limit`, removing a fixed
  compositor wait that dominated the capture regardless of how much was being
  captured (a 1x1-pixel screenshot measured the same 32ms as a full frame), and
  frames are encoded through Chromium's speed-optimised PNG path. PNG is
  lossless either way and the decoded pixels are identical; frames are about
  40-60% larger, which costs a fraction of a millisecond to reach the terminal.

  **This is a renderer-side improvement and does not, on its own, make
  drag-to-highlight feel faster.** Measured in a real iTerm2 session, capture
  time per drag frame fell from 103.2ms to 36.5ms with no perceptible change to
  the gesture, in both iTerm2 and WezTerm. The cost that governs how the drag
  feels is downstream of Neovim — the terminal decoding and compositing a fresh
  full-viewport image every frame — and is addressed separately. See
  `docs/cross-platform-implementation-status.md`.

### Added

- `interaction.selection_overlay` (default `"auto"`) to control the drag
  highlight path described above, and `overlay_frames`, `overlay_rect_count`,
  `overlay_last_bytes` and friends in `:MdViewerDebug` and `:MdViewerHealth` so
  it is visible whether the overlay is live and what a frame actually costs.

- `browser.fast_png_encode` (default `true`) to turn the speed-optimised PNG
  encoding off, and `capture_encoder` in `:MdViewerDebug` reporting which of
  the two capture paths produced the last frame.

### Fixed

- A capture taken while the preview was scrolled could have screenshotted the
  top of the document rather than what was on screen, had the new capture path
  shipped without carrying the page's scroll offset. Caught before release and
  covered by a regression test.

## [0.3.0] - 2026-08-07

### Added

- Mouse interaction over the preview, forwarded to the live Chromium DOM: a
  new `interact` NDJSON method alongside `render`/`capture`, with its own
  staleness lane so a burst of pointer input can never cancel a render.
- Drag-to-select, double-click word selection, and triple-click paragraph
  selection, all producing a real DOM selection.
- Copying the current selection (`y` / `:MdViewerCopy`) to the unnamed
  register and, when available, the system clipboard.
- In-preview search (`:MdViewerFind`, `/`) with next/previous stepping
  (`:MdViewerFindNext`/`:MdViewerFindPrevious`, `n`/`N`) and clearing
  (`:MdViewerFindClear`).
- `:MdViewerClearSelection` to clear a selection without clicking.
- Preview history: `H`/`L` in the preview window, or
  `:MdViewerBack`/`:MdViewerForward` from anywhere, move the preview (and the
  source window with it) through the documents a reader has followed links
  into, and `<C-o>` back into one of them brings the preview along on
  its own. Without it, following a link left the document it came from
  reachable only as text, because `preview.pinned` deliberately stops the
  preview following an ordinary buffer switch. Bounded by
  `interaction.history_limit`.
- `security.document_root_markers`, and a project-aware default document
  root.
- Ctrl/Cmd-click link activation for `http(s)`, `mailto`, in-document-root
  local files, and same-document `#fragment` links, each independently
  re-checked against the document root and an unsafe-scheme denylist before
  anything opens. A local Markdown link opens in Neovim, in the source
  window, and the preview follows it; other filetypes still go to the system
  handler.
- Exact source-position reporting on interaction, recovered from
  markdown-it's own parse state rather than by searching rendered text,
  degrading honestly through exact/line/block/none precision levels.
- `terminal.*` config: explicit terminal-profile and Kitty-graphics
  capability overrides, plus an opt-in runtime capability probe.
- `image.raw_cell_offset_px`/`image.raw_overlay_bleed_cells`: sub-cell
  calibration for terminals (iTerm2 confirmed) that apply their window
  margin to text but not to graphics placements, keeping a notification's
  cut-out flush against the image.
- Substantially expanded `:MdViewerHealth`/`:MdViewerDebug` diagnostics:
  interaction-enabled state, which document Chromium currently holds
  active, interaction request/stale-interaction/coalesced-drag counters,
  selection and search state (lengths and counts only, never the
  underlying text), and the raw placement's sub-cell offset/overlay bleed.
- A real (non-terminal-emulating) headless Lua/Node test suite covering the
  interaction transport, source provenance, selection, search, and every
  raw-image placement fix below.

### Fixed

- A link could be impossible to click at all. `hitTestInPage` resolved the
  clicked cell horizontally but collapsed it to a single row vertically, and on
  the estimated calibration tier a cell covers 20 CSS px while a rendered line
  is 25 and an inline link's box about 18 — so a link can fall entirely between
  two cell-row centres and become unreachable from every cell in the window, at
  any click position. Enlarging the terminal font changed nothing but the
  alignment, and made the same link work again, which is how it was reported.
  The cell is now probed in both axes, still bounded by that one cell, and a
  link anywhere under the clicked cell wins over the prose beside it — the cell
  is the resolution limit of the input device, so there is no finer answer to
  give. `tests/node/hitbox.test.js` sweeps every alignment a full cell height
  can take.

### Changed

- Every way handing an external link to the operating system can fail is now
  reported. `vim.ui.open` signals "no handler" by *returning* `nil` rather
  than raising, and never waits, so a handler that failed after starting was
  invisible too: both were discarded, which made an OS-level refusal
  indistinguishable from md-viewer never having seen the click.
  `:MdViewerDebug` records the last hand-off and its outcome
  (`last_external_open`), and a ctrl/cmd-click whose hit test fails outright
  now says so instead of going quiet (a lost race to a newer request stays
  silent, as it should).

- `security.document_root` now defaults to the **project** enclosing the
  document (the nearest ancestor holding `.git`/`.hg`/`.svn`) rather than the
  document's own directory, falling back to the old behaviour where no marker
  is found. Rooting the boundary at the folder meant an ordinary
  repo-relative link — `../README.md` from `docs/`, or a root-relative
  `docs/other.md` — was always refused as a security violation. Containment
  is unchanged: both the lexical and the symlink-resolved path are still
  checked, so `../` and symlinks still cannot escape. Local images and local
  links now also share one implementation of the root, which they previously
  did not.
- Clicking the preview no longer moves the source cursor under any gesture.
  A plain click now only clears an active selection (matching VS Code's own
  Markdown preview); Ctrl/Cmd-click still activates links. This replaces
  click-to-source, which fought the drag-to-select gesture introduced in
  the same body of work.
- `kitty_raw.lua`'s placement `move()` now emits a replacement placement and
  the deletion of the one it supersedes as a single write, new first,
  instead of two separate writes -- fixes a roll/blink visible for as long
  as a passive notification stayed open over the preview.
- Passive-overlay (notification) exclusions are cut out of the raw image
  placement again (`reconcile_placement` compares with the
  exclusion-aware `coordinates.same`) -- a notification over the preview
  now keeps its own opaque background instead of showing the rendered
  Markdown through it, since `raw_zindex = -1` draws below text glyphs but
  above cell backgrounds.
- The raw image placement is torn down whenever its window's *tabpage* is
  not the one currently displayed, not only when the window itself is
  hidden -- closes a gap where a plugin that opens its own tabpage
  (`:tabnew`-based UIs) left a stale image composited over it.
- Any new window (not only floating ones) reconciles the raw placement on
  `WinNew`, closing a gap where a plugin's plain, editor-relative splits
  could resize the preview without the image following.
- `session.source_win` reassignment (used for cursor-follow and session
  lookup) is now deferred by one event-loop tick, so a compound command
  that splits a window and then loads an unrelated file into it
  (`:split other.md`) no longer transiently steals tracking away from the
  window that is actually still showing the source buffer.

### Fixed

- `:MdViewerHealth` now warns when a configured `security.document_root` does
  not contain the document being previewed. That combination refuses every
  local link and image in the document, which is correct for the setting but
  previously surfaced only one refusal at a time and read as a broken plugin.
  The report also names where the root came from (configured or detected).
- A link is never handed to the system handler when the target is something
  the OS would *run*: macOS bundles and scripts (`.app`, `.command`,
  `.terminal`, `.workflow`), Windows executables, `.desktop`/`.AppImage`/
  `.jar`, disk images and installers, or any ordinary file carrying an execute
  bit. It is refused with a notification instead. The document root was never
  a defence here -- a cloned repository can ship `setup.command` beside its
  README and link to it from inside the root.
- `:MdViewerHealth`/`:checkhealth` now describe the document rather than
  themselves. Both create and enter their own scratch buffer before collecting,
  so every document-relative answer -- including the document root -- described
  the report buffer. The report now resolves a live preview's source buffer,
  then a real file, then the buffer the report displaced.
- A refused local link now says which refusal it was. A link to a file that
  does not exist reported "refused to open link outside the document root",
  which was untrue and sent the reader looking for a security setting; it now
  reports that the target does not exist. A genuine escape still names the
  root it was measured against. An out-of-root path is still rejected without
  the filesystem being consulted at all, so the two messages cannot be used to
  probe for files outside the root.
- A find step or fragment jump now records where it scrolled the page to.
  `interact` responses carry the resulting `scrollY`, but it was never stored,
  so the next interaction sent a stale position and the shared page was
  scrolled back before hit-testing — a click after a search resolved against a
  different position than the image on screen showed.
- A click outside rendered text no longer crashes
  (`vim.json.decode`'s JSON-`null` sentinel is now decoded as an absent
  Lua value at the protocol boundary, not a truthy userdata).
- Clicking preview text no longer scrolls the preview itself.
- The first character of a line is now clickable (hit-testing probes the
  clicked terminal cell's full width, not just its center).
- `selection_clear`/`find_*`/copy actions now carry the session's real
  scroll position instead of silently resetting the shared page to the top
  as a side effect.
- Drag-select and post-clear capture frames render at full (device) scale
  instead of inheriting scroll's low-resolution fast-frame default.

### Changed

- Drag-to-select's moving preview frame now captures at `render.fast_scroll`'s
  cheap scale (`"css"` by default) instead of always `"device"`, the same
  moving/settled split scrolling already uses. This is a deliberate,
  narrower reuse of the earlier "post-clear capture frames render at full
  (device) scale" fix above, not a reversion of it: that fix stopped
  *every* interact capture (including the settled commit) from silently
  inheriting whatever scale a recent scroll had cached. Only the drag
  *preview* frame changes here -- `M.settle_selection`'s commit, fired on
  release, is still always `"device"`, so what the reader is left looking
  at is unchanged. Measured on this machine: a real per-frame screenshot at
  device scale averaged ~65-68ms and ~87KB; at CSS scale, ~30-33ms and
  ~38KB -- the capture step, not IPC or the Lua-side PNG read/encode,
  dominates per-frame cost.
- `interaction.drag_debounce_ms` now defaults to `0` (was `40`). The old
  default gated every drag-preview request behind a *trailing* debounce that
  resets on every `<LeftDrag>` event, ahead of a pipeline that already has
  its own one-in-flight backpressure (mirroring `controller.schedule_scroll`,
  which has no such gate). Under continuous drag input faster than the
  debounce interval this could starve dispatch far worse than adding 40ms of
  latency: measured with a simulated 300ms continuous drag (a new point
  every 15ms), the old default sent exactly **one** request for the whole
  gesture, while immediate dispatch with in-flight coalescing sent eleven.
  The knob still works if set above `0`, for anyone who wants deliberate
  throttling back.

## [0.2.0] - 2026-08-06

### Added

- Portable Kitty backend: works on any terminal advertising Kitty graphics,
  not just iTerm2.
- Cell-metric calibration reporting (`env` / `estimated` tiers).
- A preview title notice when auto-selection falls back to text-only
  rendering because no graphical backend was available.
- `render.font_size_px` config option; the default preview font size is
  larger (14px → 16px).

### Changed

- Explicitly requesting `image.backend = "kitty_raw"` on a terminal with no
  Kitty-graphics evidence now fails with an actionable error instead of
  silently rendering nothing.

### Fixed

- The command line no longer hides the preview while it's open.

## [0.1.0-beta] - 2026-08-05

### Added

- Live browser-rendered Markdown previews in a Neovim split
- Raw Kitty graphics support for direct iTerm2 use
- Optional experimental `vim.ui.img` backend and text-cell fallback
- Source synchronization, preview navigation, and fast scroll captures
- Persistent local Node.js/Chromium renderer over stdin/stdout
- Default-deny runtime network policy and confined local-image loading
- Health, debug, automated, and manual verification tooling

[0.3.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.3.0
[0.2.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.2.0
[0.1.0-beta]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.0-beta