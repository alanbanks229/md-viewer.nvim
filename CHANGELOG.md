# Changelog

All notable changes to this project will be documented here. The project uses
[Semantic Versioning](https://semver.org/).

## [0.3.0-rc6] - 2026-08-25

**Prerelease.** Resident mode is now experimental and off by default, and the
bug that made it worth turning off is fixed.

The reported symptom, on a preview of `CONTRIBUTING.md` over an AWS SSM link: a
flash of yellow `waiting for this page — 0/1` next to the title, and then a
preview sitting at a position that was not the reader's — scrolling *down*
brought the top of the document back into view, bottom-first. Intermittent, and
never seen on a faster host.

### Changed

**`image.resident` now defaults to `"off"`.** It is experimental. What it trades
is a long warm-up and a document's worth of terminal image memory for scrolling
that sends nothing, and that only pays on a link slow enough that the per-scroll
capture is what you are waiting on — not on SSH generally. An ordinary SSH
session in the tens of MB/s is nowhere near needing it. `image.resident = "auto"`
opts in; `scripts/ssh-link-speed.sh` measures the link, and `:MdViewerDebug`'s
`render_path` reports which model a preview actually chose.

**Animated images do not animate under resident mode**, and now say so instead
of appearing to. Animation frames are placed once against a single base frame
and a resident screen has none — it is one or two crops that move whenever you
scroll. They only appeared to work before by riding on the stale frame the fix
below removes, over which they were drawing at the wrong position anyway.

### Fixed

**The resident bootstrap no longer throws away its own first paint.** The render
that measures the document is a picture of the reader's own position, and the
chunk plan is derived from it — but `begin_resident` ran one line after it
reached the screen, asked for a screen from zero captured chunks, and blanked
the pane. The invariant it was enforcing is about pixels of *somewhere else*,
not about which capture path produced them, so the frame now stays up while the
chunks warm and is retired after the first compose, never before. The winbar
reads grey `warming 0/1` for that, and reserves the yellow `waiting for this
page` for a pane that really is blank.

**The two rendering models no longer fight over the pane.** In the window the
blank pane opened, the 50 ms UI poll saw no image and restored a cached
full-viewport frame — into a pane the resident compositor believed it owned.
`compose` retires only the bands it tracks itself, so both stayed placed on the
same z layer, and Kitty breaks a z tie by image id: which picture the reader saw
came down to which integer was larger. `session.image_id` now means the one
frame a session owns and stays nil under resident mode; `state.screen_up`
answers "is there anything on this pane" for the callers that meant that
(selection overlay, caret, click resolution); `show_cached` restores whichever
model the session uses, which for a resident screen is a re-crop rather than a
re-upload; and an occluding float can finally reach the bands at all.

**A staled chunk capture no longer stalls the warm-up forever.** Every renderer
request bumps the session's serial, so a settle capture, a resize or a
`ColorScheme` was enough to stale a chunk that was in flight — and it had
already been taken off the queue, which nothing rebuilds. The warm-up stopped at
`n/N` and stayed there. Staled chunks are re-queued now, like failed ones always
were.

**An edit made during warm-up is no longer silently dropped.** The same serial
bump ran the other way: a chunk capture could stale the render carrying the
reader's own change, which was discarded with nothing to re-issue it. The
warm-up now defers to a content render in flight.

**A theme switch invalidates the resident chunks.** The chunk plan keyed on the
*configured* theme, which is `"auto"` by default and resolves against
`background` at request time — so `:set background=light` produced an identical
key, and an identical key is how the plan decides its chunks are still valid. A
whole document of dark-theme pixels stayed resident.

`scripts/resident/drive.lua` gained `--slow-chunks=MS`, which is the whole of
what a slow link does to this feature and what this bug needed to be visible at
all; on a fast host the first chunk lands before the pane can be observed. Under
`--slow-chunks=2000`, 61 of 75 warm-up samples showed pixels nothing could vouch
for before this change and 0 of 80 after.

### Documentation

**The 0.80 MB/s figure this project reasons from is an AWS SSM tunnel, and the
docs now say which parts of it are SSM's fault.** The number was re-validated and
stands, but the cause given for it was wrong: it credited the client,
`session-manager-plugin`, whose 1 KB/1 ms loops pace *keystrokes going up* while
its `WriteStream` is unthrottled. The pacing that governs pixels is in the SSM
**agent**, in all three of its output paths (`shell.go`, `port_basic.go`,
`port_mux.go`), and AWS states the cause and declines to raise it in
[amazon-ssm-agent#664](https://github.com/aws/amazon-ssm-agent/issues/664).

The practical consequence is that "over SSH" was never the right frame. An
ordinary SSH session touches none of that code and measures 16–23 MB/s to a host
on the same network — twenty times faster — so the wire figures throughout the
docs are now labelled as SSM's rather than as remote sessions in general, and
resident mode's guidance says so in a table instead of in a sentence. New:
`:help md-viewer-ssm-throughput`, and *Where that ceiling comes from* in
`docs/local-render-design.md`.

**`scripts/ssh-link-speed.sh` now measures with bytes a compressor cannot
help.** It sent `tr '\0' '.'` — the most compressible payload constructible —
while md-viewer sends base64 PNG, which is incompressible. Any compressing hop
upstream (`ssh -C`, `Compression yes`, a websocket negotiating
permessage-deflate) therefore carried almost nothing while the script believed
it had sent the full amount, and reported a rate the link cannot do for real
traffic. It now sends base64 over `/dev/urandom`, and times payload generation
separately so it cannot quietly report the CPU instead of the link. **Any
`render.ssh_link_bytes_per_sec` taken with an earlier version should be
re-measured** — erring high is the failure the option exists to correct.

## [0.3.0-rc5] - 2026-08-25

> Numbered rc5 rather than rc2 because `v0.3.0-rc2` through `rc4` were already
> spent on an earlier attempt at this feature — a lazily-filled slice grid that
> was abandoned. Those tags were deleted rather than released, so no version
> number in this project's history means two different things.

**Prerelease.** Scrolling a preview no longer costs a screenshot. Where the
terminal supports it the whole document is captured once, held in the
terminal's image memory, and scrolling becomes a placement command — 196 bytes
where it used to be tens or hundreds of kilobytes per frame.

This also fixes a defect that has been live since the CDP capture path was
introduced: on a slow host the first capture of a renderer process could
exceed its timeout and silently demote the session to the Playwright encoder
for the life of that process, taking `render.scroll_scale` with it.

### Added

**Whole-document resident image mode.** Where the terminal supports it, the
document is captured once as a handful of chunks, held in the terminal's image
memory, and scrolling becomes a placement command. After warm-up, scrolling
costs no renderer request and no pixels on the wire.

Measured on Ubuntu 22.04 / Chrome 151 against this repo's own README — a
12,505px document in 22 chunks:

```
  40 scrolls    0 renderer requests
                0 image uploads
               58 placements in 40 writes
            7,855 bytes total -- 196 bytes per scroll
```

The per-scroll path sends an ~80 KB moving frame and a ~305 KB settle frame,
which on the 0.80 MB/s link this exists for is ~134ms and ~508ms of wire each.

The path is chosen once when a preview opens and reported by `:MdViewerDebug`
as `render_path`. A runtime capture failure demotes it to the per-scroll path
one way, with the reason; nothing promotes back. WezTerm is excluded —
wezterm#7953 duplicates a cell's attachment list on every repeat placement over
that cell, and panning is unbounded repeat placements.

The winbar counts the warm-up. Scrolling into a chunk that has not been
captured yet shows an empty pane rather than the previous picture, and moves
that chunk to the head of the queue. Leaving the old picture up would present
pixels of somewhere else as though they belonged to where you are now.

New options: `image.resident`, `image.resident_chunk_viewports`,
`image.resident_memory_mb`, `image.resident_max_chunks`,
`render.ssh_link_bytes_per_sec`. See `:help md-viewer-resident`.

### Fixed

**The first capture no longer costs a session its fast encoder.** The first
`Page.captureScreenshot` of a browser process costs 9,874-16,335ms on Ubuntu
22.04 / Chrome 151 and every later one 116-373ms, whatever its size — a fixed
per-process warm-up that rebuilding the page does not restore. That raced
`CDP_CAPTURE_TIMEOUT_MS` at 10,000ms on the session's first frame, and
`captureViewportPng` latches `cdpCaptureUnavailable` on its first failure
without ever retrying, so losing the race silently demoted the whole renderer
process to the Playwright encoder — which is also where `render.scroll_scale`
stops working, the "INERT" verdict `scripts/README.md` documented without a
cause.

The renderer now discharges that warm-up on the blank page at startup, before
any document is loaded. Three runs each on the rig, before and after:

```
  before                          after
    15,489ms  playwright_png        16,161ms  cdp_fast_png
    21,830ms  playwright_png        22,011ms  cdp_fast_png
    (no frame at all)               24,525ms  cdp_fast_png
```

The first frame still costs 16-24 seconds on that host. What changed is that
it no longer also costs the fast path for the life of the process.

**`:MdViewerDebug` no longer presents a queue insertion as transmission cost.**
`image_update_ms` is now `ui_handoff_ms`, and `scripts/scroll-scale/ab.lua` has
dropped it from its per-frame wire estimate. `nvim_ui_send` appends to Neovim's
own UI queue and returns — 24 MB was accepted in 0.03s on a link doing
0.80 MB/s — so timing it measures the socket, not the wire. `ab.lua` now takes
its rate from `render.ssh_link_bytes_per_sec` instead of a hardcoded constant;
measure yours with `scripts/ssh-link-speed.sh`, from the shell.

## [0.3.0-rc1] - 2026-08-21

**Prerelease.** Highlighting is now exclusively a keyboard gesture. Mouse
click-drag selection, double-click word-select, and triple-click
paragraph-select are gone; `v`/`V` and the usual motion keys are the only way
to highlight text in the preview. The mouse still places the caret on a plain
click, still opens a link on Ctrl/Cmd-click, and still scrolls the preview
with the wheel — none of that changed.

The underlying request/overlay machinery is shared and unaffected: `v`/`V`
selections still get the instant translucent overlay highlight where the
terminal supports it (iTerm2, Kitty, Ghostty), the same settle frame, and the
same copy behavior a drag used to produce.

This removes and renames `interaction.*` config keys (below), which is a
breaking change for anyone setting them explicitly — the reason this ships as
a MINOR prerelease rather than a patch, per this project's own versioning
policy while pre-1.0.

### Removed

- **Click-drag, double-click, and triple-click selection.** Dragging the mouse
  over the preview no longer highlights anything; an ordinary drag now falls
  through to Neovim's own (harmless, self-recovering) default instead, the
  same way an unmapped gesture always has. `interaction.drag_threshold_cells`,
  `interaction.double_click`, `interaction.autoscroll`,
  `interaction.autoscroll_interval_ms`, `interaction.autoscroll_max_lines`,
  `interaction.word_select`, and `interaction.paragraph_select` are gone —
  setting any of them is now a configuration error rather than a silent
  no-op.

### Changed

- **`interaction.fast_drag` renamed to `interaction.fast_preview`, and
  `interaction.drag_debounce_ms` renamed to `interaction.preview_debounce_ms`.**
  Both still control the same moving-frame pacing for a `v`/`V` selection; the
  names no longer reference a mouse drag that no longer exists.

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

[0.3.0-rc5]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.3.0-rc5
[0.3.0-rc1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.3.0-rc1
[0.2.1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.2.1
[0.2.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.2.0
[0.1.1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.1
[0.1.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.0
