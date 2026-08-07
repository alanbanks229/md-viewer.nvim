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
- Ctrl/Cmd-click link activation for `http(s)`, `mailto`, in-document-root
  local files, and same-document `#fragment` links, each independently
  re-checked against the configured document root and an unsafe-scheme
  denylist before anything opens.
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

### Changed

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