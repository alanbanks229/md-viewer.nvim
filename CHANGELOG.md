# Changelog

All notable changes to this project will be documented here. The project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Remote images.** A Markdown image or bare `<img>` whose URL is https is
  fetched by the *renderer process*, validated exactly like a local image
  (magic bytes, `max_local_image_bytes` enforced while streaming), and inlined
  as a data URI. No configuration is needed for an ordinary public host. The
  browser still makes no network requests — its route, CSP, and sanitizer are
  unchanged and unconditional. Requests to loopback, private, link-local, and
  other non-public network destinations are refused, on the initial URL and on
  every redirect hop; redirects are otherwise followed at most three hops.
  Fetches are cached in the renderer process so live-preview re-renders do not
  refetch. See `:help md-viewer-remote-images` and SECURITY.md.
- **Animated images.** An animated GIF or WebP can be played by the terminal on
  its own layer over the browser-painted still frame, with each frame keeping
  its own display time. Two strategies: terminal-driven playback through the
  Kitty graphics protocol's animation extension, and client-driven frame
  placement from one shared timer, capped by `render.animate_fps` (default 5)
  and chosen per terminal profile (`terminal.animation`, default `"auto"`).
  **Off by default** — set `render.animate = true` to turn it on. With it off
  nothing about the document changes: the image is still inlined and painted,
  and the still first frame the screenshot captured is what stays on screen, so
  the default costs motion and never a picture. See
  `:help md-viewer-animation`.

### Changed

- **Viewport calibration is measured from the terminal.** The cell size used to
  size the browser render now comes from the operating system — the pixel
  geometry `TIOCGWINSZ` carries beside the row and column counts, the same
  measurement the image-placement path already trusted. `:MdViewerHealth`
  reports the tier as `measured` alongside the numbers behind it, and
  `estimated` now means the terminal genuinely reports no pixel geometry,
  chiefly under tmux and screen. `MD_VIEWER_CELL_WIDTH_PX` and
  `MD_VIEWER_CELL_HEIGHT_PX` still take precedence over the measurement, and
  are still read as CSS pixels — that is the measured size divided by
  `render.device_scale_factor`, so a 2x display measuring 14×32 wants 7 and 16.
- **The preview looks different, and `render.font_size_px` now defaults to 14.**
  A measured cell on a 2x display is about 7 CSS pixels wide against the 10 the
  estimate assumed, so the viewport is roughly 30% narrower and the same font
  size renders visibly larger relative to the preview. The default font drops
  from 22 to 14 to compensate, which puts preview text at roughly one character
  per terminal cell. If you have pinned `render.font_size_px`, scale your value
  by about 0.7 to keep the density you had. Vertical aspect improves in the
  same change: a real 14×32 cell is 0.4375 against the assumed 0.5, a 14%
  stretch that is now gone.
- **`render.device_scale_factor` and `render.cell_aspect_ratio` are validated.**
  Both are divisors on the viewport path and neither was checked before. The
  device scale must be between 1 and 3, matching the bound the renderer applies
  to the same value; the aspect ratio must be positive. A configuration outside
  those now fails at `setup()` instead of producing a viewport that disagrees
  with the page.
- **Images that cannot render are now visible.** A blocked or failed image
  shows a placeholder naming the reason (dashed border for a policy refusal,
  solid for an attempted fetch or read that failed, with the source in the
  tooltip) instead of being silently hidden. Documents whose images were
  previously collapsed to nothing now reserve layout space for the
  placeholders, so previews of such documents lay out slightly differently
  than before.
- **Breaking: `security.network` was removed.** It had no effect on page
  content — the page CSP already refused every remote subresource. Browser
  networking is now always blocked with no configuration that relaxes it; a
  leftover `security.network` key in your config is silently ignored. As a
  side effect, flipping network policy no longer forces a browser-context
  restart; only a device-scale change does.
- **Breaking: `render.raw_html` moved to `security.raw_html`.** Raw-HTML
  parsing is security-relevant in the same way `security.document_root` is,
  and now lives alongside it instead of under `render`; `:MdViewerHealth`
  already reported it as a security override before this move. Update
  `render.raw_html = true` to `security.raw_html = true` in your config.

### Fixed

- **Small previews reported a viewport the page never used.** The renderer
  floors its page viewport at 320×240 CSS pixels, and md-viewer did not mirror
  that floor — a preview under about 15 rows tall reported a height up to 20%
  short of the one the page actually rendered at. Those numbers are the
  denominator of every click hit-test, drag-overlay rectangle, and animation
  frame position, so all three were proportionally off in a short split. The
  1920×1440 cap is mirrored the same way, so raising `render.max_width_px` or
  `max_height_px` past what the renderer honours can no longer desynchronise
  them either.

## [0.3.0] - 2026-08-09

### Added

- **A real caret in the preview, with Vim motions and keyboard selection.** The
  caret is a position in the rendered document rather than a terminal cell, drawn
  as a block the size of the glyph it sits on. Character, line, word, block and
  page motions all work, with counts; `v`/`V`/`o` start and steer a selection and
  `y` copies it. See `:help md-viewer-navigation`.
- **Mouse interaction over the preview**, forwarded to the live Chromium DOM
  through a new `interact` NDJSON method with its own staleness lane, so a burst
  of pointer input can never cancel a render. Drag-to-select, double-click word
  selection and triple-click paragraph selection all produce a real DOM selection.
- **Drag-select past the edge of the preview.** A drag held past the top or
  bottom keeps scrolling and keeps extending the selection into what it reveals,
  stopping at the start or end of the document. Speed grows with distance past
  the edge, capped by `interaction.autoscroll_max_lines`;
  `interaction.autoscroll = false` restores the old freeze-at-the-edge
  behaviour, and `interaction.autoscroll_interval_ms` paces the steps.
- **An instant drag highlight.** While the mouse is down the highlight is drawn
  in the terminal as translucent rectangles over the frame already on screen,
  rather than re-photographing the page every frame. Releasing still lands a real
  browser-rendered frame. Enabled only where it was validated by hand in a live
  terminal — today iTerm2, Ghostty and Kitty; everywhere else a drag keeps the
  correct, slower full-frame path. `interaction.selection_overlay` overrides
  that. **WezTerm is off deliberately, on cost rather than correctness**, pending
  an upstream fix ([wezterm#7953], proposed in [wezterm#8035]); do not force it
  on there.
- Copying the current selection (`y` / `:MdViewerCopy`) to the unnamed register
  and, where available, the system clipboard. Manual by default;
  `interaction.copy_on_select` opts in.
- In-preview search (`:MdViewerFind`, `/`) with next/previous stepping
  (`:MdViewerFindNext`/`:MdViewerFindPrevious`, `n`/`N`). The prompt always opens
  empty, and dismissing it without a query clears both the search and any
  selection.
- Ctrl/Cmd-click link activation for `http(s)`, `mailto`, in-root local files and
  same-document `#fragment` links, each re-checked against the document root and
  an unsafe-scheme denylist before anything opens. A local Markdown link opens in
  Neovim and the preview follows it; other filetypes go to the system handler.
- Preview history: `H`/`L` in the preview, or `:MdViewerBack`/`:MdViewerForward`
  from anywhere, move the preview and the source window through the documents a
  reader has followed links into; `<C-o>` brings the preview along too. Bounded
  by `interaction.history_limit`.
- Exact source-position reporting on interaction, recovered from markdown-it's
  own parse state rather than by searching rendered text, degrading honestly
  through exact/line/block/none precision levels.
- `security.document_root_markers`, and a project-aware default document root.
- `terminal.*` config: explicit terminal-profile and Kitty-graphics capability
  overrides, plus an opt-in runtime capability probe.
- `image.raw_cell_offset_px` and `image.raw_overlay_bleed_cells`: sub-cell
  calibration for terminals (iTerm2 confirmed) that apply their window margin to
  text but not to graphics placements, keeping a notification's cut-out flush
  against the image.
- `interaction.fast_drag` (default `false`) to let a moving drag frame capture at
  CSS scale for a cheaper capture.
- `browser.fast_png_encode` (default `true`), making frame capture materially
  cheaper via Chromium's speed-optimised PNG path. Lossless either way.
- **Two diagnostics, split by the question they answer.** `:MdViewerHealth` is
  short and answers *can this work here*; `:MdViewerDebug` answers *what did it
  just do*, and is what to attach to a bug report. A warning now means one thing:
  something may not work, and you can act on it. Per-terminal validation records
  moved to [docs/terminal-support.md](docs/terminal-support.md).
- Substantially expanded diagnostics: interaction state, the active document,
  request/stale/coalesced counters, selection and search state (lengths and
  counts only, never the underlying text), overlay counters, sub-cell offset and
  bleed, the measured terminal cell size, and the last frame's capture path.
- The preview now pins its own selection colour per theme rather than inheriting
  Chromium's, so the drag-time overlay and the browser's own paint cannot
  disagree.
- A headless Lua and Node test suite covering the interaction transport, source
  provenance, selection, search, and every raw-image placement fix below.

### Changed

- `security.document_root` now defaults to the **project** enclosing the document
  (the nearest ancestor holding `.git`/`.hg`/`.svn`) rather than the document's
  own directory, which refused every ordinary repo-relative link as a security
  violation. Containment is unchanged, and local images and local links now share
  one implementation of the root.
- Clicking the preview no longer moves the source cursor under any gesture. A
  plain click only clears an active selection; Ctrl/Cmd-click still activates
  links. This replaces click-to-source, which fought drag-to-select.
- Every way handing an external link to the OS can fail is now reported: an
  OS-level refusal was previously indistinguishable from md-viewer never seeing
  the click. `:MdViewerDebug` records the last hand-off and its outcome
  (`last_external_open`), and a Ctrl/Cmd-click whose hit test fails now says so.
- Moving drag frames stay sharp: the reduced-resolution capture that scrolling
  uses is no longer shared with drag-to-select, where the reader's eye is on the
  exact glyphs being crossed. `interaction.fast_drag` opts back in.
- `interaction.drag_debounce_ms` now defaults to `0` (was `40`): the trailing
  debounce sat ahead of a pipeline that already has backpressure, and under
  continuous drag input could starve dispatch outright. Set it above `0` for
  deliberate throttling.
- Passive-overlay (notification) exclusions are cut out of the raw placement
  again, so a notification over the preview keeps its own opaque background
  instead of showing the rendered Markdown through it.
- `kitty_raw.lua`'s `move()` now emits a replacement placement and the deletion
  of the one it supersedes as a single write, new first — fixes a roll/blink
  visible for as long as a notification stayed open over the preview.
- The raw placement is torn down whenever its window's *tabpage* is not the one
  displayed, not only when the window is hidden — a plugin opening its own
  tabpage previously left a stale image composited over it.
- Any new window, not only floating ones, reconciles the raw placement on
  `WinNew`; plain splits could previously resize the preview without the image
  following.
- `session.source_win` reassignment is deferred by one event-loop tick, so
  `:split other.md` no longer transiently steals tracking from the window still
  showing the source buffer.

### Fixed

- **A horizontally scrolled preview window no longer paints its image over the
  top-left corner of the terminal.** A bare `zl` was enough to trigger it.
- **The preview no longer stops producing frames on macOS.** Chromium was
  launched with `--disable-frame-rate-limit`, which on some macOS hosts stopped
  frames being committed at all. The fast capture path is now bounded on both
  halves, so a browser that stops answering costs one slow frame instead of
  wedging the renderer's request queue.
- **The terminal cell size is measured fresh rather than remembered.** A
  terminal can change its pixel geometry while leaving its row and column counts
  alone, which left a preview drawing every highlight rectangle at the wrong size
  for the rest of the session.
- **Drag rectangles were drawn too large** — wider than the text, and tall enough
  that adjacent lines in a code block touched. The terminal's real cell size now
  comes from the operating system; where a terminal does not report it, the
  overlay switches itself off rather than drawing rectangles it cannot size.
- **On Ghostty the instant highlight worked once per session and then silently
  drew underneath the preview**, which looked exactly like falling back. The
  preview and the highlight now always sit one layer apart. If you pinned
  `image.raw_zindex = -1` to work around this, you no longer need to.
- A highlight could survive into the next drag. A drag starting on a frame with a
  settled selection painted into it now restores the cached selection-free frame
  first.
- Scrolling the preview while text was selected disabled the instant highlight
  for every drag afterwards. Any frame reaching the screen without a selection
  painted into it now re-arms it.
- A drag that left the preview window stopped selecting. The gesture now stays
  owned by the session that started it until the button comes up.
- **A link could be impossible to click at all**, at any position, because
  hit-testing collapsed the clicked cell to a single row vertically and an inline
  link can fall entirely between two cell-row centres. The cell is now probed in
  both axes, and a link anywhere under it wins over adjacent prose.
- The first character of a line is now clickable; hit-testing probes the clicked
  cell's full width, not just its centre.
- A click outside rendered text no longer crashes, and clicking preview text no
  longer scrolls the preview itself.
- A refused local link now says which refusal it was: a link to a missing file
  reported "outside the document root", which was untrue and sent readers looking
  for a security setting. An out-of-root path is still rejected without consulting
  the filesystem, so the two messages cannot be used to probe for files outside
  the root.
- A link is never handed to the system handler when the target is something the
  OS would *run*: macOS bundles and scripts, Windows executables,
  `.desktop`/`.AppImage`/`.jar`, disk images, or any file carrying an execute
  bit. The document root was never a defence here — a cloned repository can ship
  `setup.command` beside its README.
- `:MdViewerHealth` now warns when a configured `security.document_root` does not
  contain the document being previewed — a combination that refuses every local
  link and image, and previously surfaced only one refusal at a time. The report
  also names where the root came from.
- `:MdViewerHealth`/`:checkhealth` now describe the document rather than
  themselves; every document-relative answer previously described the report's
  own scratch buffer.
- A find step or fragment jump now records where it scrolled the page to, so a
  click after a search no longer resolves against a different position than the
  image on screen shows. `selection_clear`, `find_*` and copy likewise carry the
  session's real scroll position instead of resetting the page to the top.
- Interaction capture frames no longer inherit whatever scale a recent scroll had
  cached; a settled selection and a post-clear frame are always device scale.
- WezTerm's upstream issue #6344 (divide-by-zero panics in Kitty placement
  handling) is unreachable from md-viewer.

### Removed

- `:MdViewerRefresh`, `:MdViewerClearSelection` and `:MdViewerFindClear`.
  Refreshing is already automatic, and the other two each did one thing the
  search prompt now expresses by being dismissed. `<Esc>` with the preview
  focused clears the same two, and `controller.refresh()`,
  `controller.clear_selection()` and `controller.find_clear()` remain callable
  from Lua.
- `:MdViewerOpen` and `:MdViewerClose`. One command now owns whether a preview is
  showing: `:MdViewerToggle`. `controller.open()` and `controller.close()` remain
  as the Lua API — `open()` is idempotent and never closes a live preview, which
  is exactly where it differs from the toggle.
- The `vim.ui.img` feasibility spike and its `:MdViewerSpike*` commands, only
  ever reachable via a dedicated init file. The `nvim_img` backend they explored
  is unaffected.

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

[wezterm#7953]: https://github.com/wezterm/wezterm/issues/7953
[wezterm#8035]: https://github.com/wezterm/wezterm/pull/8035

[0.3.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.3.0
[0.2.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.2.0
[0.1.0-beta]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.0-beta
