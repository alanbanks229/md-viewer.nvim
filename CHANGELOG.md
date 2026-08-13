# Changelog

All notable changes to this project will be documented here. The project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

Scrolling over a throttled SSH link. On a connection whose ceiling is low
enough — an AWS SSM tunnel is a flat 0.80 MB/s — the wire time for one scroll
frame is larger than the render and the terminal decode put together, and a
wheel spin queues frames faster than the link drains them. The preview then
catches up about half a second late. Nothing was wrong with the pipeline; the
frames were simply too big for the pipe, and the two settings that looked like
they would help were measured making it worse.

Two answers ship here. The smaller one needs no setup and helps every SSH user:
capture the moving frame of a scroll at half size. The larger one stops sending
the frame at all — render it on the machine your terminal is on and send a
reference across the link instead of the picture.

### Added

- **`render.scroll_scale` and `render.ssh_scroll_scale`.** The moving frame of a
  scroll is now captured at a fraction of its natural size, halved by default on
  an SSH session and unchanged on a local one. PNG bytes go as `pixels^0.69`, so
  half scale measures 2.6× fewer bytes per frame locally and 3.0× on the SSM
  link it was built for — 224 ms of transit per moving frame down to 74 ms. The
  settle capture that lands when scrolling stops is never reduced, so the
  picture being read is still full `render.device_scale_factor`.
  `:MdViewerDebug` reports the factor in force and where it came from.
- **`render.ssh_scroll_settle_ms`.** An SSH session now waits 400 ms rather than
  160 ms before taking the sharp settle capture. A mouse wheel delivers notches
  50–150 ms apart, so the shorter delay read an ordinary gap between two flicks
  as "stopped" and bought a full-size transfer — half a second of transit on the
  link this was measured against — that the next notch immediately made stale.
  Local sessions are unchanged.
- **A renderer that can run somewhere other than beside Neovim.**
  `renderer/src/companion.js` serves the existing renderer protocol over a unix
  domain socket (mode 0600, never TCP), and `client_render.address` points the
  plugin at one instead of spawning a child. The machine running Neovim still
  opens no listening port — it dials out, and when the address is a forwarded
  port the listener belongs to sshd. A companion that cannot be reached is
  reported in `:MdViewerHealth` and falls back to the local renderer rather than
  failing the preview.
- **`bin/md-viewer-ssh`: the preview rendered where your terminal is.** A
  wrapper around `ssh` that runs the companion locally, filters ssh's stdout,
  and exports `LC_MD_VIEWER` so the remote plugin knows it is there. The remote
  preview then asks for its frames *by reference*: the PNG stays on the machine
  that drew it and a ~56-byte token crosses the link, which the filter swaps
  back for the identical Kitty upload the terminal receives today. On the SSM
  link this was built for, a moving scroll frame was 47 KB of wire time.
  Placement geometry, crops, z-layering and the double-buffered deletion order
  are all still computed in Lua and are asserted byte-for-byte equal between the
  two modes; `chunks()` and its JavaScript port are asserted against one pinned
  artifact so neither can drift alone.

  It adds nothing to install, needs no new inbound connection — `ssh -R` is an
  ordinary reverse forward, and the listener on the Neovim side is sshd's — and
  changes nothing when it is absent: no wrapper means no handshake means no
  token. A companion that dies mid-session falls back with one notification, a
  leaked token is an APC string conformant terminals discard, and any failure in
  the filter latches it into plain passthrough for the rest of the session.

  Two things still need the renderer beside the *file* and therefore fall back
  under it: a local image embedded in the document shows its failure
  placeholder, and an animated image stays on its still frame. Remote `https`
  images are fetched by your local machine instead of the remote host, which
  moves a trust boundary — [SECURITY.md](SECURITY.md) says exactly which.
  `:MdViewerHealth` notes all of this whenever client rendering is on, reports
  which of the four preconditions is missing when it is not, and warns if a
  frame was ever referenced after the renderer had dropped it.
- **`client_render.enabled`**, `"auto"` by default: reference a frame only when
  a companion is answering, the raw Kitty backend is in use, and a filter has
  announced itself. `"on"` waives the handshake alone, for a setup whose
  environment cannot reach the remote host; `"off"` never references a frame.
  `$MD_VIEWER_CLIENT_ADDR` joins `client_render.address` as a way to name the
  companion from the remote side.

### Changed

- **Block geometry is no longer re-sent on every frame of a scroll.** It is
  identical from one scroll frame to the next and is 10,477 B on this project's
  own README — 1.4 MB across a single wheel spin, which would have become the
  largest thing on the link the moment the pixels stopped travelling. A render
  request may now name the `blocksRevision` it already holds and get nothing
  back when that is still current. Only client-rendering sessions do; the
  request a local session sends is unchanged.
- **A design record for client-side rendering**, in
  [docs/local-render-design.md](docs/local-render-design.md): the measurements
  behind the slow-link case and the architecture for rendering on the machine
  the terminal runs on, sending Markdown across the link instead of pixels.

### Fixed

- **Documentation recommended a setting that makes slow links worse.** The
  README, `:help md-viewer-ssh` and the troubleshooting guide all suggested
  lowering `render.device_scale_factor` on a slow connection. It is a
  calibration divisor rather than a size knob: lowering it doubles the CSS
  viewport and grows the frame — 80 KB to 224 KB on the document it was measured
  against — while collapsing the moving and settle captures into one, so the
  cheap scroll frame stops existing. All three now say so.

## [0.1.1] - 2026-08-11

Terminal detection over SSH. v0.1.0 identified terminals only from variables
SSH does not forward, so a remote Neovim reached from a fully supported
terminal identified nothing and fell back to the text-cell preview — with a
diagnostic that pointed at the renderer, which was working fine.

### Added

- **Terminal detection over SSH.** iTerm2 and WezTerm are now identified from
  `LC_TERMINAL`, which OpenSSH forwards by default, so a remote Neovim reached
  from either terminal renders images instead of dropping to the text fallback.
  Previously detection relied solely on variables SSH does not forward, and
  every SSH session identified no terminal at all. The forwarded value is ranked
  below every native variable and ignored when another terminal has set
  `TERM_PROGRAM`, so an inherited `LC_TERMINAL` cannot misidentify a nested
  terminal that has no graphics support.
- **`$MD_VIEWER_TERMINAL_PROFILE`.** Selects a terminal profile from the
  environment, for terminals that export no SSH-forwardable identity and for one
  Neovim config shared across many hosts. `terminal.profile` still outranks it;
  an unrecognized value is ignored and reported in `:MdViewerDebug` rather than
  dropped silently.
- **SSH awareness in diagnostics.** `:MdViewerDebug` and `:MdViewerHealth` report
  whether the session is remote, and an unidentified terminal on an SSH session
  now carries a warning naming the fixes. `:MdViewerDebug`'s `terminal` field
  falls back to `LC_TERMINAL` instead of reporting `unknown` beside a correctly
  identified profile. The evidence names the SSH variable but never its value,
  which holds the client's IP address.
- **SSH documentation** in the README, `:help md-viewer-ssh`, and a
  troubleshooting section covering the exact `profile: unknown` /
  `backend: cells` signature — including why a working Chromium and a forced
  `image.backend` are both the wrong lever.

### Fixed

- An invalid `terminal.profile` passed directly to `terminal.capability()`
  reported the literal string `"unknown"` as the offending value instead of the
  value actually given.

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

[0.1.1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.1
[0.1.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.0
