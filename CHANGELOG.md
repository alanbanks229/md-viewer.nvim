# Changelog

All notable changes to this project will be documented here. The project uses
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-08-11

First public release.

### Added

- **Live preview.** A browser-rendered Markdown preview in a Neovim split,
  updating as you type, painted into the terminal as an image. Backed by a
  persistent local Node.js/Chromium renderer over stdin/stdout.
- **Image backends.** Raw Kitty graphics on any terminal advertising the
  protocol, `vim.ui.img` on Neovim 0.12, and a text-cell fallback. Selected
  automatically; `image.backend` overrides.
- **A caret with Vim motions.** Character, line, word, block and page motions
  with counts; `v`/`V`/`o` start and steer a selection, `y` copies it. The caret
  is a position in the rendered document, not a terminal cell. See
  `:help md-viewer-navigation`.
- **Mouse selection.** Drag-to-select, double-click for a word, triple-click for
  a block, all producing a real browser selection. A drag held past the edge
  keeps scrolling and extending (`interaction.autoscroll*`). On validated
  terminals — iTerm2, Ghostty, Kitty — the drag highlight is drawn instantly in
  the terminal rather than re-photographing the page; elsewhere the slower
  full-frame path is used. `interaction.selection_overlay` overrides that.
- **Search** (`:MdViewerFind`, `/`) with next/previous stepping (`n`/`N`).
- **Links and history.** Ctrl/Cmd-click activates `http(s)`, `mailto`, in-root
  local file and `#fragment` links, each re-checked against the document root
  and an unsafe-scheme denylist first. `H`/`L` move through followed documents.
- **Images.** Local and https images are validated and inlined as data URIs;
  remote ones are fetched by the renderer process, never the browser. Animated
  GIF and WebP can be played by the terminal over the still frame — **off by
  default**, set `render.animate = true`. See `:help md-viewer-animation` and
  `:help md-viewer-remote-images`.
- **Security defaults.** Browser networking is always blocked, the page CSP
  denies all, JavaScript is disabled in the render context, and file access is
  confined to `security.document_root` (defaults to the enclosing project).
  See [SECURITY.md](SECURITY.md).
- **Diagnostics.** `:MdViewerHealth` answers *can this work here*;
  `:MdViewerDebug` answers *what did it just do*, and is what to attach to a bug
  report. Per-terminal validation records live in
  [docs/terminal-support.md](docs/terminal-support.md).

[0.1.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.0
