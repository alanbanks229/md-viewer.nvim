# Changelog

All notable changes to this project will be documented here. The project uses
[Semantic Versioning](https://semver.org/).

## [0.3.0-rc2] - 2026-08-20

A cursor left standing on a cell the caret had already left.

Everything in `0.3.0-rc1` still applies, including that it is a validation
prerelease and that stable `0.3.0` stays reserved until the throughput A/B has
been re-run on the 0.80 MB/s link.

### Fixed

- **Scrolling no longer leaves a second cursor behind.** Once the caret scrolled
  out of the viewport, Neovim's own block cursor came back on screen — on the
  reasoning that with no highlight drawn the real cursor is the only caret there
  is. It is not one: it cannot move while the caret is off screen, so what
  appeared was a block parked on the cell the caret occupied *before* it scrolled
  away, pointing at whatever text had since moved under it and then sitting
  perfectly still for the rest of the scroll. A caret scrolled out of view is
  simply not drawn, which is what the code said everywhere except here. Focus
  leaving the preview still gives your cursor back, from out of view as well.
- **A notification opening over the preview no longer strands the caret.** When
  the image is re-cropped around a float, the highlight rectangles measured
  against the old geometry are dropped — the drag selection's always were, the
  caret's were not, so it stayed drawn at its pre-float position until some later
  motion or frame happened to redraw it. It now comes down and goes straight back
  where it belongs, and only when the image actually moved: the same
  reconciliation runs on a 50 ms tick, and redrawing on each one would be a
  steady drip of writes down the link this release exists to keep quiet.

### Added

- **`scripts/rig/provision.sh`** turns an SSH host into a machine you can
  reproduce the remote-Neovim mode on — Neovim, Node, Chrome, your config and a
  fixed scroll fixture — so a report from that mode no longer needs a second
  computer to chase down. `--shape` puts it behind an 800 kbit/s link, because a
  LAN is not where these get reported. See `scripts/README.md`; nothing in the
  plugin itself changes.

## [0.3.0-rc1] - 2026-08-20

Two remote topologies, opposite ways round.

If Neovim runs on your own machine and only the *project* is on the far end —
`rsync://`/`scp://` buffers, as remote-ssh.nvim and netrw create them — the
preview now renders at full local quality. The document's text is already in the
local buffer, so no rendered pixel and no render request ever touches SSH; only
the files a document references cross, once each, off the interactive path.

If Neovim itself runs on the far end and your terminal is local, scrolling stops
re-sending pixels the terminal already has. 0.2.0 made each frame smaller; this
removes the frame. The two are kept deliberately distinct: SSH detection answers
for Neovim's own transport, never for a buffer's origin.

**This is a validation prerelease.** The mechanisms are proved by the suite and
the memory ceiling is measured, but the throughput A/B has not been re-run on the
0.80 MB/s link since the slice grid replaced the single region it started as.
Stable `0.3.0` stays reserved until it has.

### Added

- **Remote documents render at full local quality.** A buffer named
  `rsync://user@host//path/doc.md` or `scp://…` (remote-ssh.nvim, netrw)
  opens a preview whose renderer, Chromium and frames all stay local.
  Scrolling an already-resolved document performs zero remote I/O — asserted
  in the suite by counting calls through the one transport seam.
- **Referenced files are fetched once, into a bounded mirror.** A relative
  image renders its placeholder while md-viewer copies it from the host into
  a per-host, per-project cache, then one more render puts the picture in —
  the same loop https images already used. One batched stat refuses
  symlinks, non-files and anything over `render.max_local_image_bytes`
  before a content byte moves; failures are negative-cached for a minute; a
  new session revalidates inherited files with one stat and refetches only
  what changed; the mirror is evicted oldest-first past
  `remote.cache_max_bytes`.
- **The security boundary travels with the document.** A remote document is
  confined to its *remote* project root (same markers as local detection,
  resolved on the host with symlinked parents flattened), and the renderer's
  `documentRoot` is the mirror — a directory that can only ever hold content
  fetched from that project — so a remote document can never name a local
  file. A configured local `security.document_root` is deliberately inert
  for it. Previously a URL-shaped buffer name would have been mangled by
  local path handling and rooted in whatever project enclosed Neovim's cwd;
  such names now either open as remote sessions or are refused, never
  treated as local paths.
- **Links and history work across the host.** Ctrl/Cmd-clicking a Markdown
  or text link in a remote document opens the target as another remote
  buffer and the preview follows; non-text targets are refused rather than
  fetched for the OS. History stores remote names verbatim and revives a
  wiped entry through the provider rather than declaring it dead on a local
  stat.
- **`remote` configuration section** — `enabled` (off refuses these buffers
  outright), `fetch_timeout_ms`, `cache_max_bytes`, `ssh_command` (argv
  prefix, never a shell string; `BatchMode=yes` so missing keys fail
  visibly; ControlMaster left to your ssh config). `:MdViewerDebug` and
  `:MdViewerHealth` gained a Remote Document section; the render response
  gained `localImageAssets`, reporting each file-shaped image source and its
  outcome.
- **`docs/remote-projects.md`** — the onboarding guide for the whole
  arrangement, from SSH keys to where LSP and git run.

- **Scrolling over SSH stops re-sending pixels it has already sent.** The
  document is cut into a fixed grid of *slices*, each about two viewports tall,
  each captured once and kept — and every scroll position is shown as a **crop**
  of pixels the terminal is already holding. Scrolling back through a paragraph
  you have just read costs a few hundred bytes of placement command instead of a
  photograph, and shows sharp device-scale pixels while moving rather than the
  half-size ones `render.ssh_scroll_scale` trades for bytes. A hit issues no
  renderer request, takes no screenshot and uploads no image at all; that is
  asserted directly in the suite rather than inferred from a byte count.

  The promise, stated exactly, because it is what the option is named for: **a
  slice is sent once and never sent again while it stays in the window.**
  Deliberately not "the whole document is held" — no memory ceiling can promise
  that, because there is always a longer document, and this project does not ship
  claims it cannot enforce. Past `image.resident_memory_mb` the window slides and
  crossing it costs an upload, while pixels still in the window are still reused.

  Boundaries belong to the *document* rather than to where you happened to stop,
  which is what makes them worth having: a slice is paid for once, and that stays
  true across a boundary, because a viewport spanning two slices is drawn from
  both, split at a whole character row, in a single write. On a document that
  fits the ceiling nothing is ever given up; `evictions` staying at zero is the
  property, asserted directly rather than hoped for.

  While you are reading rather than scrolling, the idle link fills in the slices
  around you, nearest first, so the rest of the document is usually already there
  when you reach it. That never delays anything you are waiting for: a slice you
  actually need always goes first, only one payload is ever in flight, and a
  prefetch is refused outright rather than evicting to make room for a guess.

  Narrowly gated, because what it trades is terminal memory for wire time and
  only one of those is free: raw Kitty backend, over SSH, outside a multiplexer,
  on a terminal profile qualified for it — today iTerm2 alone. Everywhere else,
  including every local session, the scroll path is one boolean test longer than
  it was and byte-for-byte identical otherwise. Panning is also refused while a
  search or a selection is live, because a slice was captured without those
  highlights and panning to it would erase what the reader can see; clearing the
  search costs one placement command and no upload.

- **`image.reuse_sent_pixels`** (`"auto"` / `"on"` / `"off"`) and
  **`image.resident_memory_mb`** (default 512) — how much decoded image the
  terminal may hold for one preview. The megabyte figure converts at a *measured*
  ~13 bytes per resident pixel (`scripts/resident/rss-calibrate.py`, three runs on
  iTerm2 3.6.11 / macOS 15), against the 4 bytes this project assumed for its
  first three releases. That measurement also settled two open questions: the
  memory does come back, and iTerm2 does not self-evict. It is **not
  corroborated**, though — the only real session ever sampled held twelve slices
  budgeted at ~342 MB while `ps -o rss=` saw ~10 MB move, and nothing yet picks
  between "the sampler cannot see it" and "synthetic gradients do not generalise
  to a real document". `:MdViewerDebug` reports the figure as
  `decoded_mb_budgeted` with a `decoded_basis` line beside it for that reason.
  See `:help md-viewer-reuse-sent-pixels` and
  [docs/terminal-support.md](docs/terminal-support.md).

- **`render.ssh_link_bytes_per_sec`: tell md-viewer how fast your link actually
  is.** Default `nil`, and only the reuse path reads it. While an uploaded slice
  is still crossing a slow link, md-viewer declines to send moving frames that
  would only queue behind it and arrive at positions you have already left — and
  how long that lasts is arithmetic on a link speed. Set it to `800000` for a
  0.80 MB/s tunnel; `scp` of a large file reports the same quantity. Unset, the
  pause falls back to the settle delay, which is a safe guess rather than an
  answer.

  Asked for rather than inferred, because it cannot be found out. Writing to the
  terminal returns when the operating system accepts the bytes, not when they
  arrive, so on a healthy connection the write looks instantaneous however slow
  the link is — and the terminal *can* be asked to acknowledge an upload, but its
  reply lands on Neovim's own stdin, which a plugin cannot read.

- **Diagnostics for all of it.** `:MdViewerHealth`'s `reuse sent pixels` line
  reports the terminal's half of the gate and whether the open document fits its
  memory bound — "whole document held (N slices)" or "N of M slices fit —
  crossing the rest costs an upload each time". A document that does not fit is
  not an error and is not refused; it was simply only visible as `evictions`
  climbing, which you had to know to look for. `:MdViewerDebug`'s `resident`
  block reports the session's half: `hits` against `misses`, `slices_resident`
  against `grid_slices`, `resident_px` against `memory_px`, `straddles` /
  `straddle_misses`, `document_fits` / `slices_that_fit`, and `grid_refusal`,
  which has only three causes and names which.

  Every capture that lands is accounted for by an identity rather than a counter
  — `fills == slices_resident + stale + abandoned + undisplayed + evictions +
  dropped_slices` — asserted across a whole-document walk and printed as
  `UNACCOUNTED` by `scripts/resident/ab.lua` when it fails. A counter only
  catches the drop somebody thought to count. `dropped_slices` and `drains` are
  the quiet pair worth knowing: invalidating the grid (a resize, a colorscheme
  change, an edit, `:MdViewerRefresh`) gives every slice back at once, which is
  correct — the held pixels stop describing the document — but it is not an
  eviction, and it costs the whole warm-up again.

### Changed

- **`:MdViewerDebug` and `:MdViewerHealth` open in a new tab rather than a
  full-width split.** A split takes rows from the preview, and the preview's
  height is part of what reused pixels are keyed on, because the document reflows
  at a different viewport — so checking the numbers invalidated the whole grid and
  paid for it again, twice per look, while the report said `evictions: 0`. On a
  slow link that is the entire document re-uploaded because you wanted to see how
  it was doing. A tab leaves every window in the current tab exactly where it was.

### Fixed

- The caret overlay recorded the literal string `"nil"` as its refusal reason,
  reading the reason from the wrong return position — so the one case that field
  exists to explain was the one case it could not.

### If you were on a 0.3.0 prerelease

None of this affects an upgrade from 0.2.1. The `v0.3.0-remote.*` tags have been
withdrawn and replaced by this `-rc` channel; every configuration key they
introduced still loads, converted and warned about once per session rather than
refused, because refusing over a renamed key costs you the preview and a slow
remote link is the worst place to find out about a rename.

- `image.resident_pan` is now `image.reuse_sent_pixels` — same three values, same
  behaviour. The old name was the mechanism's; the new one is what you get.
  `:help md-viewer-resident-pan` still resolves.
- `image.resident_budget_px` is now `image.resident_memory_mb`. An existing
  `resident_budget_px = 8000000` converts to 99 MB at the measured ~13 B/px — the
  bound you actually had, not the "~32 MB" it was documented as.
- `:MdViewerDebug` field renames: `decoded_mb_estimate` → `decoded_mb_budgeted`
  (with `decoded_basis`), `wire_bytes_per_ms` → `link_bytes_per_ms` (with
  `link_rate_source`: `configured`, `estimated` or `unknown`), `plan_refusal` →
  `grid_refusal`, and `stale_fills` split so that a capture superseded before it
  landed counts as `superseded_fills` instead — it never reached the point `fills`
  is counted at, so folding it in made `stale_fills` a population `fills` did not
  contain.
- The link speed the diagnostics reported was wrong by about 170× — 139,058 B/ms
  for a tunnel doing 800 — because it came from timing md-viewer's own write,
  which returns once SSH has buffered the payload rather than when it has carried
  it. The anti-backlog pause computed from it had therefore never run. Samples
  implying a link faster than gigabit line rate are now discarded rather than
  averaged in, and the diagnostics say `unknown` rather than printing an
  inference as a measurement.
- The first shipped policy bounded *one region planned around wherever you had
  stopped*, so its edges moved with you and crossing one threw it away and paid
  for it again: 14 fills and 13 evictions in 141 seconds, ~971 KB each — **38%
  more traffic than sending a frame every time**. The fixed grid above replaced
  it.

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

[0.3.0-rc1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.3.0-rc1
[0.2.1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.2.1
[0.2.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.2.0
[0.1.1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.1
[0.1.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.0
