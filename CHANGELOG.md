# Changelog

All notable changes to this project will be documented here. The project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.0] - 2026-08-28

Highlighting is now exclusively a keyboard gesture, the preview pane carries a
tab per document, and on a link too slow for pictures the browser can move to
your side of it.

The breaking part is the first of those. Mouse click-drag, double-click and
triple-click selection are gone, and seven `interaction.*` keys went with them —
setting one is now a configuration error rather than a silent no-op. What
replaces them is `v`/`V` and the ordinary motion keys against a real caret in the
rendered document. Everything else here is additive: preview tabs and history,
optional Obsidian wikilink navigation through those tabs, and two independent
answers to a slow SSH link — hold the whole document in the terminal's image
memory so scrolling sends nothing, or stop sending pixels at all.

### Removed

- **Click-drag, double-click, and triple-click selection.** Dragging the mouse
  over the preview no longer highlights anything; an ordinary drag falls through
  to Neovim's own harmless default, the way an unmapped gesture always has.
  `interaction.drag_threshold_cells`, `interaction.double_click`,
  `interaction.autoscroll`, `interaction.autoscroll_interval_ms`,
  `interaction.autoscroll_max_lines`, `interaction.word_select`, and
  `interaction.paragraph_select` are gone — setting any of them is now a
  configuration error rather than a silent no-op. The mouse still places the
  caret, still opens a link on Ctrl/Cmd-click, and still scrolls with the wheel.

### Added

- **`render.location = "local"` renders and presents frames beside the
  terminal.** Launch ssh through the helper on the machine your terminal runs on
  — `node <md-viewer>/renderer/src/local-main.js -- ssh <host>` — and the
  connection carries prepared markup, each asset's bytes once, and a ~0.3–1 KB
  marker per frame instead of an ~80–305 KB PNG per frame. A scroll sends one
  marker and no request at all. The plugin adopts a helper only after a versioned
  hello *and* a probe marker through its own tty that only the helper filtering
  that terminal can see, so the two ends cannot cross-wire. The handshake
  compares the control-socket protocol version rather than the tag — ordinary
  checkout skew between two independently-updated ends is the steady state —
  and an incompatible protocol is refused with the fix in the message. No helper, a dead socket, or a mid-session
  crash produces one warning and remote rendering exactly as before, with the
  reason in `:MdViewerHealth` and `:MdViewerDebug`. See `:help md-viewer-local`.
- **Pane-scoped preview documents and tabs.** Every followed Markdown document
  owns a stable, unlisted `md-viewer://preview/...` buffer. Clickable winbar
  tabs, `[b`/`]b`, and `:MdViewerTabNext`/`:MdViewerTabPrevious`/
  `:MdViewerTabClose` switch only the preview pane; `gf` and
  `:MdViewerRevealSource` reveal a document in the editable source pane. History
  is independent of tab order and recreates a closed document with its saved
  scroll target.
- **Optional native Obsidian wikilinks.** `obsidian.enabled` renders and follows
  note, path, alias, heading-hierarchy, and block-id links through the same
  preview tabs. Vault lookup is case-insensitive for bare stems, duplicate-aware,
  rescanned on activation, and confined against traversal and symlink escapes.
  No obsidian.nvim dependency is introduced — this is syntax compatibility, not
  an integration. See `:help md-viewer-obsidian`.
- **Whole-document resident image mode, experimental and off by default.** Where
  the terminal supports it, the document is captured once as a handful of chunks
  held in the terminal's image memory, and scrolling becomes a placement command
  — no renderer request and no pixels on the wire, measured at 196 bytes per
  scroll against the ~80 KB the per-scroll path sends. It trades a long warm-up
  and a document's worth of terminal image memory for that, which only pays on a
  link slow enough that the per-scroll capture is what you are waiting on.
  `image.resident = "auto"` is that condition rather than a plain opt-in: it
  takes the resident path only where the terminal supports it *and* this machine
  has measured a link under `image.resident_below_bytes_per_sec` (4 MB/s, a gap
  between the two reference links rather than a measurement of anything). It
  never measures on its own, so run `:MdViewerMeasureLink` once per machine — an
  unmeasured link is unknown rather than slow, and keeps the ordinary path.
  `"on"` drops the rate question for exercising the mode deliberately on a
  machine that will not benefit from it. New options
  `image.resident_below_bytes_per_sec`, `image.resident_chunk_viewports`,
  `image.resident_memory_mb` and `image.resident_max_chunks` bound it;
  `:MdViewerDebug`'s `render_path_reason` names whichever condition decided.
  See `:help md-viewer-resident`.
- **`:MdViewerMeasureLink` measures this link and caches the answer for this
  machine.** Run it once from an SSH session with no preview open. It runs
  `scripts/ssh-link-speed.sh` in a subprocess writing to the pty named by
  `$SSH_TTY`, which is the only route that works: the answer is not observable
  from inside Neovim at any link rate — `nvim_ui_send` appends to Neovim's own UI
  queue and returns, and 24 MB was accepted in 0.03 s on a 0.80 MB/s link — and a
  subprocess Neovim starts has no controlling terminal, so `/dev/tty` fails with
  ENXIO. It refuses outside SSH, with a preview open, or where no terminal device
  resolves, each of which would measure something other than the link.
- **Absolute and relative rendered line numbers.**
  `:MdViewerToggleAbsoluteLineNumbers` and `:MdViewerToggleRelativeLineNumbers`
  select one three-state `preview.line_numbers` preference over the *rendered*
  visual lines. The cells backend uses Neovim's native number options.
- **A statusline progress API.** `statusline_progress()` reports
  `All`/`Top`/`Bot`/`NN%` from the rendered document's own geometry, and a
  deduplicated `MdViewerProgressChanged` User event lets a configured statusline
  refresh itself. md-viewer no longer writes `'statusline'` itself. See
  `:help md-viewer-statusline`.
- **Manual split adoption.** Running `:MdViewerToggle` in one of exactly two
  splits showing the same Markdown adopts the current split as the preview and
  restores its buffer, view, dimensions, and window options on close. Ambiguous
  or fixed layouts fall back to a plugin-owned split.
- **`interaction.keymaps` configures the tab-cycle keys.** `tab_previous` and
  `tab_next` default to `"H"`/`"L"`; set either to a different key, or to
  `false` to leave it unmapped.
- **`preview.tab_accent` underlines the active winbar tab.** Default
  `"#61afef"`; some colorschemes render `TabLineSel` and `TabLine` almost
  identically, which made the active tab hard to pick out. Set to `false`
  for the plain link with no underline.

### Changed

- **`render.ssh_link_bytes_per_sec` now defaults to `"auto"`,** reading a
  measurement this machine has already made. It never takes one: nothing happens
  until `:MdViewerMeasureLink` or `sh scripts/ssh-link-speed.sh --write-cache`
  has been run there. The cache lives under `stdpath("state")`, keyed by a hash
  of the host, both ends of the connection and the terminal, so several people
  sharing a bastion each get their own and no address is ever printed. Precedence
  is `MD_VIEWER_SSH_LINK_BYTES_PER_SEC` > configuration > cache > unknown, and a
  number in configuration still wins and is still never capped — which is also
  the trap, since a rate left in a shared config silently defeats per-machine
  detection on every machine sharing it. Unknown remains a legitimate answer.
- **`scripts/ssh-link-speed.sh` measures the effective rate, and any figure taken
  with an older copy should be re-measured.** It used to send `tr '\0' '.'`,
  which is maximally compressible, so any compressing hop made it report a rate
  the link cannot do. It now sends base64 over `/dev/urandom` and times payload
  generation separately.
- **Leaving Visual mode (`<Esc>`) clears the preview highlight immediately,**
  matching Vim. The final sharp frame still lands first and `copy_on_select`
  still runs, so a fast `v`…`<Esc>` copies exactly what was shown.
- **In local mode, resident mode demotes** ("local render owns scrolling"),
  `render.animate` is structurally off with a health warning if configured on,
  and the moving/settle capture split never engages — there is no wire to save.
- `:MdViewerDebug`'s `image_update_ms` is now `ui_handoff_ms`, because that is
  what it measures: `nvim_ui_send` only queues.
- **`H`/`L` cycle document tabs instead of walking history.** They now do the
  same thing as `[b`/`]b`. Preview history is still reachable through
  `:MdViewerBack`/`:MdViewerForward`, just with no default keymap.

### Fixed

- **The first capture no longer costs a session its fast encoder.** A browser
  process pays a fixed one-off capture warm-up (9,874–16,335 ms on Ubuntu 22.04
  / Chrome 151, against 116–373 ms for every later capture) that could outlast
  the capture timeout on a session's very first frame; losing that race demoted
  the whole renderer to the slower Playwright encoder for the rest of the
  session, silently, and took `render.scroll_scale` with it. The demotion is no
  longer permanent and the warm-up no longer races. Predates 0.3.0.
- **A character-wise preview selection could lose its first or last character.**
  Selections anchored at a glyph's exact centre are the one tie browser
  hit-testing cannot break; `v` on a heading's first character selected
  `## Changelog` as `hangelog`. Selection now resolves through the same
  character-index space the caret already uses, falling back to coordinates only
  when no index is available.
- **Held `j` inside the preview lagged behind release by one round trip per
  keystroke.** Caret motion asks the renderer for a real glyph box and nothing
  paced those requests. A same-direction repeat arriving while one is in flight
  now accumulates into a pending count flushed as a single follow-up, so a held
  key costs one round trip per *answer* rather than per keystroke. A different
  motion arriving mid-flight is still sent at once.
- **`:MdViewerDebug` and `:MdViewerHealth` blanked an open preview.** The health
  check forced its browser context to device-scale 1; the mismatch tore down the
  context and cleared the active document. Health now reuses the active scale.
- **A task-list item containing a link or any inline markup drew its own
  Markdown a second time.** `- [ ] see [docs](x)` rendered the item's raw source
  as literal text inside the still-open link, and `- [ ] with **bold**` lost its
  emphasis — because the task-list plugin was rebuilding each item's label from
  its source text instead of wrapping the children the parser had already
  produced. Items are now wrapped rather than rewritten, and a task item carries
  the same exact source provenance every other list item has.
- **Repeating `:MdViewerBack`/`:MdViewerForward` at either end of history no
  longer stacks notifications.** Only the first call past that end reports
  "no previous/next document in the preview history"; further repeats are
  silent until the preview actually moves, and moving re-arms it.

### Security

- The plugin and renderer still open no listening port. The optional local-render
  helper listens on one unix-domain socket — 0600 in a 0700 directory, never TCP,
  pinned by a test — on the operator's own machine, for one ssh session's
  lifetime. Asset transfer is push-only and content-addressed: the helper can
  never request a path, and every push is verified against its hash.
  Remote-image fetching stays on the document's machine. [SECURITY.md](SECURITY.md)
  has the full boundary.

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

[Unreleased]: https://github.com/alanbanks229/md-viewer.nvim/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.3.0
[0.2.1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.2.1
[0.2.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.2.0
[0.1.1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.1
[0.1.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.0
