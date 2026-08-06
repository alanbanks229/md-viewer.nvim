# Changelog

All notable changes to this project will be documented here. The project uses
[Semantic Versioning](https://semver.org/).

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

[0.2.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.2.0
[0.1.0-beta]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.0-beta