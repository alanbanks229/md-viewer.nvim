# Changelog

All notable changes to this project will be documented here. The project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **Resident panning now covers the whole document, as a grid of slices, instead
  of one region that followed you around.** The mechanism shipped in
  `0.3.0-remote.2` worked and the policy around it did not: the region was
  planned around wherever you had stopped, so its edges moved with you and
  crossing one threw it away and paid for it again. On the link this was built
  for that measured **38% more traffic than sending a frame every time** — 14
  fills and 13 evictions in 141 seconds, ~971 KB each. A small sharp window that
  kept having to be repaid for.

  The document is now cut into fixed slices of about two viewports, and a
  boundary is a property of the *document* rather than of where you happened to
  stop. A slice is captured once and kept, so going back over ground you have
  already read costs a placement command and nothing else — and unlike before,
  that stays true across boundaries, because a viewport spanning two slices is
  drawn from both, split at a whole character row, in a single write. On a
  document that fits the memory ceiling nothing is ever given up; `evictions` in
  `:MdViewerDebug` staying at zero is the property, and it is asserted directly
  rather than hoped for.

  While you are reading rather than scrolling, the idle link fills in the slices
  around you, nearest first, so the rest of the document is usually already
  there when you reach it. That never delays anything you are waiting for: a
  slice you actually need always goes first, only one payload is ever in flight,
  and a prefetch is refused outright rather than evicting to make room for a
  guess — evicting on a guess is the exact churn this release removes.

- **`image.resident_budget_px` is now `image.resident_memory_mb`, default 512.**
  Megabytes are what you are actually spending; pixels were only ever a proxy for
  them through a conversion nobody had measured, and now that the conversion is
  measured the proxy is not worth keeping. A configuration still setting the old
  key keeps working: it is converted at the measured ~13 bytes per pixel and
  warned about once, so `resident_budget_px = 8000000` becomes 99 MB — the bound
  you had, not the "~32 MB" it was documented as. Refusing the configuration
  outright would have cost you the preview over a rename, which on a slow remote
  link is the worst possible way to find out about one.

  `:MdViewerDebug`'s `resident` block changes with it: `slices_resident` against
  `grid_slices` says how much of the document is held, `resident_px` against
  `memory_px` how close the ceiling is, and `straddles` / `straddle_misses`
  whether boundaries are being drawn or falling back. `plan_refusal` becomes
  `grid_refusal`, which has only three causes and names which.

- **New `render.ssh_link_bytes_per_sec`: tell md-viewer how fast your link
  actually is.** Default `nil`, and only resident panning reads it. While an
  uploaded slice is still crossing a slow link, md-viewer declines to send moving
  frames that would only queue behind it and arrive at positions you have already
  left — and how long that lasts is arithmetic on a link speed. Set it to
  `800000` for a 0.80 MB/s tunnel; `scp` of a large file reports the same
  quantity. Unset, the pause falls back to the settle delay, which is a safe
  guess rather than an answer.

  Asked for rather than inferred, because it cannot be found out. Writing to the
  terminal returns when the operating system accepts the bytes, not when they
  arrive, so on a healthy connection the write looks instantaneous however slow
  the link is — and the terminal *can* be asked to acknowledge an upload, but its
  reply lands on Neovim's own stdin, which a plugin cannot read.

### Fixed

- **The link speed `:MdViewerDebug` reported was wrong by about 170×, and the
  anti-backlog pause it feeds had therefore never run.** A real session showed
  `measured link: 139,058 B/ms` for a tunnel doing 800 — because the figure came
  from timing md-viewer's own write to the terminal, and that write returned as
  soon as SSH had buffered the payload rather than when it had carried it. The
  pause computed from a link 170× too fast is no pause at all, so
  `frames_suppressed_by_hold` sat at 0 while the documentation claimed at most
  one image payload was outstanding per session.

  Three changes, none of which invent a measurement that does not exist. A sample
  implying a link faster than gigabit line rate is now discarded rather than
  averaged in, and counted as `wire_samples_discarded`. The rate the pause is
  computed from now prefers `render.ssh_link_bytes_per_sec` above anything
  inferred. And the diagnostics stop presenting an inference as a measurement:
  `:MdViewerDebug` reports `link_bytes_per_ms` beside `link_rate_source`
  (`configured`, `estimated` or `unknown`), and `scripts/resident/ab.lua` prints
  `link rate used` rather than `measured link` — saying `not measurable` where it
  used to print a number. `docs/architecture.md` now states what actually holds a
  session to one payload (a single fill slot, plus coalescing) and describes the
  pause as the best-effort damage control it is.

- **A resident pixel costs about 13 bytes in the terminal, not 4, so
  `image.resident_budget_px` has always been worth roughly three times what it
  was documented as.** The default of 8,000,000 px was described here and in
  `:help md-viewer-resident-pan` as "~32 MB"; measured, it is ~100 MB. Nothing
  about how much the plugin actually holds has changed — only what it told you
  it was holding, which was wrong by a factor of three in the reassuring
  direction. `:MdViewerDebug`'s `decoded_mb_estimate` now reports the measured
  figure. `scripts/resident/rss-calibrate.py` is the measurement: PNGs of known
  pixel counts transmitted *and placed* (a terminal may decode lazily, so an
  image never drawn reports nothing), iTerm2's RSS sampled, then freed and
  sampled again. Three runs on iTerm2 3.6.11 / macOS 15 put it at 12–13 B/px,
  and it also settled two open questions: 94% of a first pass's pages were
  served to an identical second pass, so the memory does come back, and a slice
  still answered a placement after ten more had arrived, so iTerm2 does not
  self-evict. The sustained-memory question — does it plateau over half an hour
  on a real link — is still unanswered; `scripts/resident/rss.sh` has never
  been run.

## [0.3.0-remote.2] - 2026-08-19

Prerelease, on the same validation channel as `0.3.0-remote.1`. This is the
resident-region work built and verified locally, tagged so it can be exercised
on a real throttled link. **Nothing here has been measured on that link yet:**
the entry below describes a mechanism the suite proves, not a throughput result,
and `image.resident_budget_px` is still the deliberately small provisional value
rather than a measured one. Stable `0.3.0` stays reserved until both the A/B and
the sustained-memory run exist.

### Added

- **Resident regions: scrolling over SSH stops re-sending pixels it has already
  sent.** Where the earlier SSH work made each frame smaller, this removes the
  frame. One capture a couple of viewports tall is uploaded once, and every
  scroll position inside it is shown as a different *crop* of the same image — so
  scrolling back through a paragraph you have just read costs a few hundred bytes
  of placement command instead of a photograph, and shows sharp device-scale
  pixels while moving rather than the half-size ones `render.ssh_scroll_scale`
  trades for bytes. A hit issues no renderer request, takes no screenshot and
  uploads no image at all; that is asserted directly in the suite rather than
  inferred from a byte count.

  Narrowly gated, because what it trades is terminal memory for wire time and
  only one of those is free: raw Kitty backend, over SSH, outside a multiplexer,
  on a terminal profile qualified for it — today iTerm2 alone. Everywhere else,
  including every local session, the scroll path is one boolean test longer than
  it was and byte-for-byte identical otherwise.

  Two bounds are load-bearing and both are stated as invariants rather than
  intentions. `image.resident_budget_px` (default 8,000,000 px — stated here as
  "~32 MB estimated" on an assumed 4 bytes a pixel, and since **measured** at
  ~100 MB; see the Unreleased entry above)
  is the *invariant* and the region's height is derived from it, checked against
  the PNG's real dimensions at upload — a region nominated as "two viewports" and
  checked afterwards is how a budget gets exceeded by an amount nobody sees until
  the terminal is holding it. And because a region and the moving frames it
  replaces share one `nvim_ui_send` queue and one pty, **at most one image payload
  is outstanding per session**: a scroll that misses while a region is still
  crossing the link emits nothing at all and resumes once, at the newest position,
  when the wire is free. Without that the feature would rebuild the very backlog
  it exists to remove.

  Panning is refused, and today's capture path used instead, while a search or a
  selection is live — a resident region was captured without them, so panning to
  it would erase highlights the reader can see. Clearing the search costs one
  placement command and no upload: the region was never discarded.

- `image.resident_pan` (`"auto"` / `"on"` / `"off"`) and
  `image.resident_budget_px`. `:MdViewerHealth` reports the terminal's half of the
  gate, `:MdViewerDebug`'s `resident` block the session's half, including why it
  refused. `scripts/resident/ab.lua` is the two-phase harness that measures the
  claim on a real link, in total `nvim_ui_send` bytes rather than PNG bytes —
  "the payload fell to zero" and "the traffic fell to zero" are different claims.

### Fixed

- The caret overlay recorded the literal string `"nil"` as its refusal reason,
  reading the reason from the wrong return position — so the one case that field
  exists to explain was the one case it could not.

## [0.3.0-remote.1] - 2026-08-18

Prerelease. Stable `0.3.0` is reserved until this work has had real-world
validation and `main` represents it.

Remote projects, local Neovim: previews of `rsync://`/`scp://` buffers at
full local quality.

0.2.0 made the preview survivable when Neovim runs on the far side of a slow
link by shrinking what crosses it. This release removes that traffic from the
render loop altogether for the opposite topology — Neovim, the renderer and
Chromium on your machine, only the project on the other one, as
remote-ssh.nvim and netrw arrange it. The document's text is already in the
local buffer, so no rendered pixel and no render request ever touches SSH;
only the files a document references cross, once each, off the interactive
path. The existing SSH-session behavior is untouched, and the two are kept
deliberately distinct: SSH detection answers for Neovim's own transport,
never for a buffer's origin.

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

[0.3.0-remote.2]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.3.0-remote.2
[0.3.0-remote.1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.3.0-remote.1
[0.2.1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.2.1
[0.2.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.2.0
[0.1.1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.1
[0.1.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.0
