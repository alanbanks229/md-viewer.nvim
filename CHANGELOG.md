# Changelog

All notable changes to this project will be documented here. The project uses
[Semantic Versioning](https://semver.org/).

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