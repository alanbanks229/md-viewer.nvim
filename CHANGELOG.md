# Changelog

All notable changes to this project will be documented here. The project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Optional native Obsidian wikilinks.** `obsidian.enabled` renders note,
  path, alias, heading-hierarchy, and block-id links and follows them through
  pane-scoped preview tabs. Vault lookup is case-insensitive for bare stems,
  duplicate-aware, rescanned on activation, and confined against traversal and
  symlink escapes. No obsidian.nvim runtime dependency is introduced.
- **Real pane-scoped preview document buffers and tabs.** Every followed
  Markdown document now owns a stable, unlisted `md-viewer://preview/...`
  buffer. Clickable winbar tabs, `[b`/`]b`, and the new
  `:MdViewerTabNext`/`:MdViewerTabPrevious`/`:MdViewerTabClose` commands switch
  only the preview pane; `gf` and `:MdViewerRevealSource` explicitly reveal a
  document in the editable source pane. Preview history is independent of tab
  order and recreates closed documents with their saved scroll target.
- **Manual split adoption.** Running `:MdViewerToggle` in one of exactly two
  splits showing the same Markdown adopts the current split as the preview and
  restores its original buffer, view, dimensions, and window options on close.
  Ambiguous or fixed layouts fall back to a plugin-owned preview split.
- Closing a preview document now sends a renderer `forget` request, promptly
  releasing its browser, interaction, lane, replica, and local-surface caches.

### Fixed

- **A fresh preview could show a patchwork of resolved and unresolved
  content, fixed only by scrolling.** In local mode, `apply_surface` sets
  `session.image_id` the instant a frame's marker is sent -- a reference
  that has to cross an AWS SSM round trip before any pixels exist for it,
  never true of the direct path's `apply_image`, which ships real bytes
  synchronously in the same transaction. Nothing gated the occlusion/cmdline
  reconcile (`reconcile_placement`, on a 50ms poll from the moment the
  preview opens) or the caret overlay from addressing that id before its own
  upload landed. Measured live (2026-08-27) with byte-level write logging: on
  a fresh open, both fired within one poll tick against an unresolved id,
  producing several placement-only transactions before the real upload
  arrived -- an unknown id draws nothing under Kitty's `q=2`, so the terminal
  showed a mix of resolved and unresolved regions until an unrelated later
  frame (e.g. a scroll) overwrote it clean, which is why scrolling always
  "fixed" it. Both call sites now hold off until a `presented` notification
  confirms the current image_id's upload has actually reached the terminal;
  the caret retries itself once that happens.
- **A preview could render solid black after reopening Neovim inside the same
  local-render helper session.** The operator's workflow -- one laptop-side
  helper process (`node renderer/src/local-main.js -- ssh <host>`) wrapping
  one long-lived ssh session, with Neovim itself quit and reopened many times
  inside it -- left the control-socket connection to die from the OS on
  `:qa` (an unhandled EOF) rather than a real close the helper could react
  to. The helper's per-document state (`replica.js`'s `docs` map, epoch and
  laid-out revision included; `injector.js`'s `lastSurfaceSeq`) is keyed only
  by `documentId`, which a fresh Neovim process regenerates identically for
  the same file (e.g. "buffer-1") -- so it persisted across every restart,
  and a fresh session's first frame reference (epoch 0, per a fresh Lua
  session's own state) could be silently refused forever by
  `scheduleSurface`'s epoch guard against a counter the outgoing session left
  elevated. Measured live (2026-08-27). `VimLeavePre` now calls
  `localrender.detach()` when attached, closing the control-socket pipe for
  real; the helper's socket server answers with a real `onClientChange(false)`
  handler that retires the outgoing session's terminal placements
  (`injector.teardown()`, reused from the helper's own process-exit path) and
  clears the replica's per-document state (`replica.reset()`), so the next
  session's `docRecord` starts fresh.
- **A character-wise preview selection could lose its first or last
  character.** `visual_start`/`visual_update` anchor and extend a selection at
  the caret's own glyph *centre* -- exactly the tie `caretRangeFromPoint`
  cannot break (the same ambiguity `caret_move`'s `caretIndex` exists to avoid
  for the caret itself, documented in `moveCaretInPage`: "at the exact middle
  of a glyph the boundaries either side are equidistant... differs from glyph
  to glyph"). Measured live: `v` on a heading's first character selected
  "## Changelog" as "hangelog". `selection_preview`/`selection_commit` now
  accept `anchorIndex`/`focusIndex`, resolved against the exact character
  space `caret_move` already uses instead of re-hit-testing an ambiguous
  point, and the boundary chosen for each (before vs. after its character)
  is picked from which endpoint is earlier in the document -- correct for
  both forward and backward extension. Falls back to coordinate resolution
  exactly as before whenever an index is absent (a click, or content that
  has re-rendered since).
- **Held-key scrolling paced on a round trip it did not need.** rc10 gated
  the next moving marker on the `presented` acknowledgement, so throughput
  in local mode was capped at one AWS SSM round trip per frame regardless of
  capture cost. Measured live against aide-spock (2026-08-27): capture
  itself took 15–50 ms (`--status` → `replica.timing.captureDuration`) but
  the round trip the ack added put end-to-end frame time (`:MdViewerDebug`
  → `local_render.presented`) at p50 116 ms / p95 180 ms — an SSM tunnel
  round trip, not the browser, was the held-`j` bottleneck. The gate is
  removed: every scroll emits its marker immediately. The backpressure it
  existed to provide is already in `replica.js`'s `scheduleSurface` /
  `pumpCapture` (one capture want per document, newest wins, a superseded
  want never dispatched), so a burst still costs captures at the helper's
  own rate, just without waiting a network round trip between them.
- **Local-mode scrolling was pixelated for no reason.** `render.ssh_scroll_scale`
  (default 0.5) shrank every moving scroll frame to save bytes crossing SSH --
  a trade that makes sense on the direct path, which puts the captured frame
  on the wire. Local mode never does that regardless of resolution (only a
  ~0.3-1 KB marker crosses SSH either way), so scrolling inherited the
  blur-while-moving/sharpen-at-rest behavior for a byte saving it never spent.
  Measured on aide-spock (2026-08-27): full-resolution local capture cost
  31-52 ms against 15-34 ms at half scale (`--status` ->
  `replica.timing.captureDuration`) -- a ~15-20 ms difference, dwarfed by the
  ~85-120 ms round trip the fix above already removed. Local mode now always
  captures scroll frames at full device scale; `render.scroll_scale` still
  overrides it explicitly if a laptop's own capture time becomes the
  constraint.
- **`:MdViewerDebug`/`:MdViewerHealth` blanked an open preview.** The health
  check forced its Chromium context to device-scale 1 regardless of what a
  live session was already rendering at; the mismatch against the session's
  actual scale (2 by default) tore down the context and cleared the active
  document, so running either command while a preview was open blanked it.
  Health now reuses whatever scale is already active.
- **The startup terminal probe could read the wrong window size for the
  whole session.** `tty-probe.js` paired a live pixel-size query to the
  terminal (`CSI 14t`) with Node's cached `process.stdout.columns`/`rows`,
  which can still hold Node's `80x25` default if the helper starts before
  the terminal has propagated its real size to the pty. Observed on
  aide-spock (2026-08-27): a session's `helper_terminal.cellPixels` reported
  `80x25` while Neovim's own preview window was already 88 columns wide in
  the same session -- impossible if the terminal were really that narrow,
  and every placement for the rest of the session inherited the wrong cell
  size, producing a garbled rectangle partway down the pane. The probe now
  also sends `CSI 18t` (text-area size in characters) and reads columns/rows
  from that live reply instead of Node's cache, so both numbers come from
  the terminal at the same moment and can never disagree.
- **Held-`j` inside the preview lagged behind release by as many round trips
  as keys pressed while one was already in flight.** Moving the caret is not
  a marker -- `caret_move` asks the renderer for a real glyph box and waits
  for the answer, so it crosses the same AWS SSM tunnel a scroll marker does
  (~85-120 ms each way, measured on aide-spock 2026-08-27) -- and nothing
  paced it: every keystroke queued its own `interact` request, so a held key
  visibly lagged behind release by as many round trips as keys fired while
  one was still outstanding. `caret_move` already takes a `count`
  (`renderer/src/interact.js` steps it in a loop), so a same-direction repeat
  arriving while one is in flight no longer sends its own request: it
  accumulates into a pending count, flushed as one follow-up the moment the
  in-flight request resolves. A single tap still costs exactly one request; a
  held key now costs one round trip per *answer*, not one per keystroke. A
  different motion arriving mid-flight (`w` then `l` before `w` answers) is
  not held back -- it fires at once, and the interact lane's existing
  supersession (`lanes.js`) drops a stale answer if the interrupted request's
  reply lands late.

- **Preview motion made the global Lualine bar blink and still reported the
  wrong percentage.** md-viewer and Lualine alternately replaced the preview
  window's `'statusline'`: md-viewer briefly wrote a bare ruler, then Lualine
  restored the complete bar and recomputed progress from the viewport-sized
  shadow buffer (`3/56`, the `5%` visible in the report) rather than from the
  rendered document. md-viewer no longer writes `'statusline'` at all. Its
  `statusline_progress()` API reports `All`/`Top`/`Bot`/`NN%` from the same
  full-document visual-line geometry navigation uses, following the caret
  after caret motion and the viewport midpoint after scroll-only motion. A
  deduplicated `MdViewerProgressChanged` User event lets the configured
  statusline refresh without two renderers fighting over one option.

### Added

- **Absolute and relative rendered line numbers.**
  `:MdViewerToggleAbsoluteLineNumbers` and
  `:MdViewerToggleRelativeLineNumbers` select one three-state preference
  (`preview.line_numbers = "off" | "absolute" | "relative"`). Repeating the
  active mode turns numbering off; invoking the other command switches modes
  directly. Relative mode shows distance around the caret while retaining the
  caret line's absolute visual-line index. Numbers now use each browser line
  box's vertical midpoint through the caret's pixel-to-cell transform instead
  of its top edge, removing the upward bias visible beside headings and tall
  lines. The cells backend uses Neovim's native number options.

### Changed

- **Leaving Visual mode (`<Esc>`) now clears the preview's highlight
  immediately, matching real Vim.** `visual_stop` used to leave the
  highlight up -- its own comment said a second `<Esc>` was needed to clear
  it through `M.escape`'s ordinary precedence. `settle_selection` still
  lands the final sharp frame first (and still runs `copy_on_select`, if
  configured, so a fast `v`...`<Esc>` still copies exactly what was shown),
  but the clear now rides its completion via a new `on_settled` callback
  parameter, so it never races a settle a coalesced `pointer.pending_settle`
  was about to re-target. A plain click ending a selection with no settle to
  wait on (`M.on_press`'s `visual_stop(session, false)`) clears immediately
  for the same reason -- nothing displayed needs preserving. Since every
  selection in this plugin is reached through Visual mode (there is no
  mouse-drag path), a later separate click now has nothing left to clear.

## [0.3.0-rc10] - 2026-08-27

**Prerelease, tagged on the unmerged `feat/adaptive-local-render` branch.**
rc9's AWS SSM validation passed on the work laptop (2026-08-27): K1 topology,
K2 marker transit (10,000/10,000), and iTerm2 presenting filter-injected
frames through the real link, with zero raster bytes crossing it. rc10 is the
performance and operator-experience pass that run asked for: held-key
scrolling is fixed from measurements, time-to-glass is a permanent
diagnostic, and RC validation is two commands instead of an afternoon.
**The rc10 feel check on the real SSM link is pending**; nothing else is.

### Fixed

- **Held-key scrolling in local mode.** rc9 dispatched a capture per scroll
  position into the helper's serial browser queue; each dispatch superseded
  the capture already running, so finished screenshots were discarded stale
  while the screen sat still — the work laptop measured 517 captures for 206
  surfaces served. Three changes, all measured on the ichigo rig
  (2026-08-27): the replica holds one capture want per document (newest
  wins, one in flight — completed screenshots always land); moving frames
  are captured at the direct path's reduced scroll scale with a device-scale
  settle re-reference when motion stops (the resting frame is never the soft
  one); and the controller paces moving markers on the `presented`
  acknowledgement, so held-key motion is visible at the browser's own frame
  rate. A 30-step scroll burst went from 4 frames on glass to 24, and
  marker-emit→presented from p95 2147 ms to p95 63–167 ms.

### Added

- **K4 time-to-glass, measured in the product.** The VM samples marker
  emit → `presented` acknowledgement on its own clock
  (`:MdViewerDebug` → `local_render.presented`, p50/p95/max); the helper
  samples marker-arrival → injection, capture queue wait, and capture
  duration, and keeps its last 32 captures with scroll position and scale
  (`--status`, health enrichment). Superseded frames are never samples —
  the distribution describes only frames a reader saw.
- **Remote-graphics attribution.** The filter splits its remote-stream
  graphics counters by image-id space (`remoteMdvGraphicsCommands`,
  `remoteMdvRasterBytes`), so raster from an md-viewer direct session and
  graphics from unrelated programs in the same wrapped session stop sharing
  one ambiguous number — the exact ambiguity rc9's validation hit.
- **Two-command RC validation.** `scripts/local/ssm-rc-update.sh` moves the
  laptop helper and the VM plugin to one tag and verifies they agree;
  `scripts/local/ssm-validate.sh` runs K1, K2, the K4 burst workload,
  version and zero-raster checks, and the link measurement, then writes one
  gitignored Markdown artifact and leaves the human exactly two judgments.
  docs/aws-ssm.md now documents this workflow and records what rc9 settled.

## [0.3.0-rc9] - 2026-08-27

**Prerelease, tagged on the unmerged `feat/adaptive-local-render` branch.**
Adds opt-in local rendering: the browser runs beside your terminal, and no
frame crosses the connection as pixels. Built for the AWS SSM environment's
measured ~0.8 MB/s ceiling; **AWS SSM validation is pending** — the transport
and the full session flow are validated on LAN SSH, and docs/aws-ssm.md
carries the exact procedure and results template for the real-link run.
`render.location` defaults to `"current"`; nothing changes unless you opt in.

### Added

- **`render.location = "local"`** renders and presents frames beside the
  terminal. Launch ssh through the helper on the machine your terminal runs
  on — `node <md-viewer>/renderer/src/local-main.js -- ssh <host>` — and the
  connection carries prepared markup, each asset's bytes once, and a
  ~0.3–1 KB marker per frame instead of an ~80–305 KB PNG per frame. A
  scroll sends one marker and no request at all. See `:help md-viewer-local`.
- **A pairing handshake that cannot cross-wire.** The plugin adopts a helper
  only after a versioned hello *and* a probe marker through its own tty that
  only the helper filtering that terminal can see. Version skew between the
  two checkouts is refused with the fix in the message.
- **Loud, reversible fallback.** No helper, a dead socket, or a mid-session
  crash produces one warning and remote rendering exactly as before; the
  reason lands in `:MdViewerHealth` and `:MdViewerDebug`.
- **Diagnostics that answer "is anything still crossing as pixels?"** with
  counters on both ends: marker and fallback counts in health/debug, and a
  helper `--status` flag whose `parser.remoteGraphicsCommands` counts
  graphics uploads that arrived from the remote stream — zero while attached
  is the invariant holding.
- **`docs/aws-ssm.md`**: the reference-environment manual — topology, why SSM
  is not SSH, the trust boundary, the validation procedure, and the results
  template.

### Security

- The plugin and renderer still open no listening port. The optional helper
  listens on one unix-domain socket (0600 in a 0700 directory, never TCP — a
  test pins it) on the operator's own machine, for one ssh session's
  lifetime. Asset transfer is push-only and content-addressed: the helper
  can never request a path, and every push is verified against its hash.
  Remote-image fetching stays on the document's machine. SECURITY.md has the
  full boundary.

### Changed

- In local mode, resident mode demotes ("local render owns scrolling"),
  `render.animate` is structurally off (still frames, with a health warning
  if configured on), and the moving/settle capture split never engages —
  there is no wire to save.

## [0.3.0-rc8] - 2026-08-26

**Prerelease.** iTerm2 no longer re-crops a resident image in place — measured
live over a real SSM link to show the wrong scroll position, sometimes on a
chunk's very first placement.

### Fixed

- **Resident mode no longer re-crops in place on iTerm2.** Reproduced against
  a real slow link: a resident chunk's first placement, or a re-crop of an
  already-shown chunk to a new position, could display content from a
  different scroll position than the one requested. Every escape sequence was
  hand-verified byte-correct against the chunk plan's own arithmetic, and a
  real-Chromium test confirms the rendered pixels were also correct — the
  defect is iTerm2 applying the crop, not what was asked for. iTerm2's
  terminal profile now carries `resident_pan = false`, which falls back to
  the viewport model (re-render per scroll, never re-crop) there.

### Changed

- **Two measured reductions in resident warm-up traffic**, both currently
  dormant on every host in active use: a chunk landing during warm-up no
  longer recomposes the pane if nothing it would draw has changed since the
  last compose, and the very first placement of a freshly-uploaded chunk now
  waits roughly as long as its own upload takes to cross the measured link
  before compositing it, instead of compositing the instant `nvim_ui_send`
  returns (which only queues bytes for Neovim's UI channel — it does not wait
  for them to reach the wire).

## [0.3.0-rc7] - 2026-08-26

**Prerelease.** How fast the link is, measured per machine instead of pasted into
a config file that is symlinked to all of them — and the reasoning behind that
measurement, corrected.

Both halves come out of the same afternoon of measuring. An AWS SSM tunnel
carries **~1,030,000 B/s**; a LAN host on plain TCP/22 carries **~14,700,000**.
Fourteen times apart, and one `~/.config/nvim` reaches both: safe-for-the-slower
is nineteen times low on the faster, and right-for-the-faster is the error
`render.ssh_link_bytes_per_sec` exists to correct. There is no constant to pick.

### Added

**`:MdViewerMeasureLink` measures this link and caches the answer for this
machine.** Run it once, from an SSH session, with no preview open; the screen
floods and clears and it takes up to about a minute. It runs the same
`scripts/ssh-link-speed.sh` the shell does, in a subprocess writing to the pty
named by `$SSH_TTY` — the only route that works. The answer is not observable
from inside Neovim at any link rate (`nvim_ui_send` appends to Neovim's own UI
queue and returns; 24 MB was accepted in 0.03 s on a 0.80 MB/s link), and a
subprocess Neovim starts has no controlling terminal to reach `/dev/tty`
through: opening it fails outright with ENXIO, measured. `$SSH_TTY` names the
pty by path, and a path needs no controlling terminal.

It refuses outside SSH, with a preview open, or where no terminal device
resolves — each of which would measure something other than the link.

**`render.ssh_link_bytes_per_sec` now defaults to `"auto"`,** which reads a
measurement this machine has already made. It never takes one: nothing happens
at all until `:MdViewerMeasureLink` or `sh scripts/ssh-link-speed.sh
--write-cache` has been run there. The cache lives under `stdpath("state")`,
keyed by a hash of the host, both ends of the connection and the terminal, so
several people sharing a bastion each get their own and no address is ever
printed. Nothing expires; the age is reported instead.

Precedence is `MD_VIEWER_SSH_LINK_BYTES_PER_SEC` > configuration > cache >
unknown, mirroring how the cell metrics resolve and for the same reason: the
environment travels with a session and a shared config file cannot. **A number
in configuration still wins and is still never capped** — which is also the
trap, since a rate left in a shared config silently defeats per-machine
detection on every machine that shares it.

Unknown remains a legitimate answer. `:MdViewerHealth` raises nothing for it.

### Changed

**The resident warm-up says how long it has left,** when the link has been
measured: `warming 3/12 ~14s` rather than `warming 3/12`. Extrapolated from the
chunks that document has already produced rather than from its pixel count,
because PNG against real content is not predictable from geometry — and silent
unless a chunk has landed *and* the rate came from a measurement. There is no
honest estimate to build on an inferred one.

**`scripts/ssh-link-speed.sh` gained `--write-cache`, `--samples N`, `--out
FILE`, `--quiet` and `--print-key`.** `--write-cache` files the answer where
md-viewer reads it, so a by-hand run needs nothing pasted anywhere; it computes
the same key in POSIX sh that `md-viewer.linkrate` computes in Lua, and the test
suite runs `--print-key` against a fabricated environment and compares, because
a disagreement would file the measurement where nothing reads it and look
exactly like never having measured. `--samples N` repeats the settled transfer
and keeps the **lowest**: every way this measurement goes wrong makes it look
faster, and there is no mechanism that makes it look slower, so averaging keeps
the inflated samples and the minimum discards them.

**`:MdViewerHealth` reports the link rate** with its tier, its age and how far
its own samples disagreed, and warns when they disagree by more than 2× — a link
that answered 0.8 MB/s and then 2.0 has not been measured, and every estimate
built on it inherits that. Never for an unmeasured link.

**`scripts/scroll-scale/ab.lua` takes its rate from the resolver** instead of a
hardcoded 800000, and says on the report which tier answered. On the LAN host
that constant was eighteen times low, which would report a link at 5% of
capacity as oversubscribed.

### Fixed

**base64 is not incompressible, and `scripts/ssh-link-speed.sh` said it was.**
Its comment reasoned that PNG is already deflated, so base64 of it cannot be
compressed. That is about the wrong layer: base64 is 64 symbols carried in
8-bit bytes — six bits of entropy per byte — so deflate takes it to about 75%
whatever is inside it.

Not pedantry. It is exactly the gap between `aide-spock`'s raw channel at
774,000 B/s and the 1,010,000–1,070,000 the same host reports through a pty:
774,000 ÷ 0.75 = 1,032,000. A reader who believed the old comment would take the
pty figure for a channel figure and conclude the documented SSM ceiling had been
beaten. The payload is unchanged — Kitty graphics genuinely puts base64 on the
wire — but the script now says what it measures: the **effective** rate, with
whatever a compressing hop gives back already in it, which is the figure that
predicts a frame's transit time and the one that belongs in configuration.

`docs/local-render-design.md` carries that as a third way to measure an SSM link
faster than its ceiling, and its ceiling section stops being a prediction: the
1 KB/ms arithmetic was a reading of the agent's source plus a stranger's
numbers, and has now been measured against the channel itself with
`Compression yes` live and excluded by payload choice — 64 MiB of incompressible
bytes three times, 0.77–0.78 MB/s, 76% of theoretical. The same 64 MiB sent
compressible took 6.36 s against 86.23 s. That 13.6× is where every inflated SSM
figure in this repository came from, its own 8.0–10.3 included.

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

[0.3.0-rc10]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.3.0-rc10
[0.3.0-rc9]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.3.0-rc9
[0.3.0-rc8]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.3.0-rc8
[0.3.0-rc7]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.3.0-rc7
[0.3.0-rc6]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.3.0-rc6
[0.3.0-rc5]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.3.0-rc5
[0.3.0-rc1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.3.0-rc1
[0.2.1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.2.1
[0.2.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.2.0
[0.1.1]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.1
[0.1.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.1.0
