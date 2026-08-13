# Changelog

All notable changes to this project will be documented here. The project uses
[Semantic Versioning](https://semver.org/).

## [0.2.1] - 2026-08-13

Renderers that outlived the Neovim which started them, and burned a full CPU
core each until they were killed by hand.

Nine had collected on one machine over a week — 884% CPU across ten cores and
four gigabytes of resident memory, the oldest spinning for six days — because
the process could reach a state in which every route out of it was blocked,
including the signal you would send to clear it. The fix is pinned by a test
that launches a real renderer with a real Chromium, takes its pipes away
mid-render, and fails if the process is still alive fifteen seconds later; it
reproduces the spin against the previous code at 99.9% of a core.

### Fixed

- **A renderer whose Neovim died without warning ran forever at 100% of a
  core.** `shutdown` awaited `service.close()` and called `process.exit(0)` only
  after it returned. Once the editor was gone Chromium's pipe was gone too, so
  `browser.close()` rejected — the ordinary case, not an edge case — and the
  exit after it never ran. Node re-raised the unawaited rejection as an uncaught
  exception; the handler re-entered `shutdown`, found `service.closing` already
  true, and returned without exiting. The process then sat in an endless
  throw-and-format-stack-trace loop. Exiting is now unconditional and cannot
  itself fail: cleanup is attempted, its outcome is ignored, and the process
  exits either way.
- **`SIGTERM` could not stop a wedged renderer.** The same `service.closing`
  guard swallowed the signal, so the obvious way to clear one did nothing and
  `SIGKILL` was the only thing that worked. `SIGTERM`, `SIGINT`, and now
  `SIGHUP` — a closed terminal window — all exit unconditionally.
- **A renderer never noticed that its parent had gone.** Nothing watched stdin,
  so a crashed, `SIGKILL`ed, or terminal-closed Neovim left a child with no way
  to learn it had been orphaned. Stdin `close`, `end`, and `error`, and `EPIPE`
  on the response pipe, now each mean the same thing and end the process.
  Handling `EPIPE` here also keeps it from arriving as the uncaught exception
  that started the loop above.
- **The kill fallback at Neovim exit never ran.** `process.stop()` armed its
  `SIGTERM` on a 1000 ms `vim.uv` timer. At `VimLeavePre` Neovim is gone within
  milliseconds, taking its event loop and the pending signal with it — so the
  one moment the fallback existed for was the one moment it was guaranteed not
  to fire. `VimLeavePre` now tears the renderer down synchronously and
  escalates `SIGTERM` → `SIGKILL` for one that will not go.

## [0.2.0] - 2026-08-13

Scrolling over a throttled SSH link, and previews that no longer stall on a
remote image.

On a connection whose ceiling is low enough — an AWS SSM tunnel is a flat
0.80 MB/s — one scroll frame spends more time on the wire than the render and
the terminal decode put together, and a wheel spin queues frames faster than the
link drains them. Nothing was wrong with the pipeline; the frames were simply too
big for the pipe, and the two settings that looked like they would help were
measured making it worse.

### Added

- **`render.scroll_scale` and `render.ssh_scroll_scale`.** The moving frame of a
  scroll is now captured at a fraction of its natural size — halved by default
  on an SSH session, unchanged locally — for roughly 3× fewer bytes per frame on
  the link this was built for. The settle capture that lands when scrolling stops
  is never reduced, so the picture being read is still full
  `render.device_scale_factor`. `:MdViewerDebug` reports the factor in force and
  where it came from. See `:help md-viewer-ssh`.
- **`render.ssh_scroll_settle_ms`.** An SSH session now waits 400 ms rather than
  160 ms before spending the sharp settle capture, because a mouse wheel delivers
  notches 50–150 ms apart and the shorter delay read an ordinary gap between two
  flicks as "stopped". The cost is that sharpness arrives about 240 ms later when
  you do stop. Local sessions are unchanged.
- **`:help md-viewer-options`.** Every configuration option with its default and
  its accepted values, in one place. The help had been documenting nine option
  groups and a handful of individual options out of more than seventy.

### Fixed

- **One unreachable image no longer costs the whole preview twenty seconds.**
  Remote images resolved in a pre-pass between parsing and rendering, so on a
  network with no direct route out the full fetch timeout was paid *before the
  document appeared at all*. Nothing waits for a fetch now: an image that has not
  arrived renders as its placeholder, and the picture appears on its own once the
  bytes land. Remote images still do not load behind a mandatory proxy — they now
  fail fast instead of hanging, because the fetch pins the address it validated
  and a proxy makes pinning impossible. `:help md-viewer-remote-images` and
  [SECURITY.md](SECURITY.md) say so rather than leaving it to be read as an
  omission.
- **Four stray entries in Neovim's global help index.** `:help source`,
  `:help run`, `:help project` and `:help CSS` all resolved into this plugin's
  help file, because emphasis had been written as `*word*` — which `:helptags`
  reads as a tag definition.
- **Documentation recommended a setting that makes slow links worse.** The
  README, `:help md-viewer-ssh` and the troubleshooting guide all suggested
  lowering `render.device_scale_factor` on a slow connection. It is a calibration
  divisor rather than a size knob: lowering it doubles the CSS viewport, grows
  the frame, and collapses the moving and settle captures into one, so the cheap
  scroll frame stops existing. All three now say so.

### Removed

- **`browser.channel` and `image.zindex`**, neither of which was read by
  anything. Setting either has never had an effect, and leaving either in a
  `setup()` call is harmless.

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

[0.2.1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.2.1
[0.2.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.2.0
[0.1.1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.1
[0.1.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.0
