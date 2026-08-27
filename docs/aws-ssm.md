# The AWS SSM reference environment

This page is the durable reference for md-viewer's hardest environment — a
laptop reaching a development VM through AWS SSM Session Manager — and the
operating manual for validating `render.location = "local"` there. Everything
below either states a measured fact with its host and date, or gives the exact
command that produces one.

## The topology, and why it is not SSH

```
work laptop ── ssh over aws ssm start-session (ProxyCommand) ── sshd ── VM
   iTerm2                                                            Neovim
```

It behaves like SSH in every way except throughput: the SSM agent paces the
VM→terminal direction at roughly 1 KB per millisecond, capping it near
0.8 MB/s regardless of the underlying network. The measurement, the
attribution, and the history are in
[local-render-design.md](local-render-design.md#ssm-ceiling); the numbers to
remember are **aide-spock 0.77–1.06 MB/s** (SSM, measured 2026-08-25) against
**ichigo 14.7 MB/s** (LAN SSH, same date, same rig). The two differ by
fourteen times, which is why nothing in this plugin hard-codes a link rate and
why "it works over SSH" predicts nothing about SSM.

## Why remote rendering struggles there

The remote path renders beside Neovim and ships each frame as PNG bytes
through that capped pipe. A ~80 KB moving frame is ~100 ms of pure wire; a
~305 KB settle frame is ~400 ms. Scrolling is therefore serialized on the
link: the page cannot move faster than its pictures can cross. The two
existing mitigations (`ssh_scroll_scale` shrinking the moving frame; resident
mode's placement-only panning) reduce the bytes but keep the shape — every
scroll still transmits, or depends on terminal-side re-crops that iTerm2
measurably gets wrong (see [terminal-support.md](terminal-support.md)).

## What local mode changes

`render.location = "local"` inverts the topology instead of shrinking the
payload. A helper on the laptop wraps the ssh session and runs the same
renderer beside the terminal; the VM runs markdown parsing and the security
pipeline and nothing heavier. What crosses the link:

```
VM ──▶ laptop   control socket (ssh -R):  prepared html, asset bytes once
                terminal stream:          frame markers, ~0.3–1 KB each
laptop ──▶ VM   control socket:           geometry, blocks, notifications
```

No raster bytes cross in either direction, and no frame waits for a
round trip: the marker that presents a frame is emitted in the same tick as
the render request, and a scroll emits a marker and nothing else. The two
documented failures of the removed 2026 experiment — PNG over the link,
serialized RTT per frame — are excluded structurally, and
`tests/lua/cases/controller_local.lua` pins both.

The trust boundary (unix socket, token, push-only assets) is documented in
[SECURITY.md](../SECURITY.md); the moving parts are in
[architecture.md](architecture.md#render-location).

## What the rc9 validation settled

The operator ran the full manual procedure against `v0.3.0-rc9` from the work
laptop over real AWS SSM on 2026-08-27, and it settled the architecture:

- **K1** (wrapped-ssh topology): PASS — raw mode, resize, escapes, and a
  full-screen Neovim all hold with the helper on stdout.
- **K2** (marker transit): PASS — 10,000/10,000 markers, zero missing, zero
  reordered, zero malformed.
- **K3** (terminal presentation): demonstrated — iTerm2 3.6.11 rendered
  filter-injected frames through the real session, across scrolling,
  selection, find, resize, and reopen. Zero direct-byte fallbacks; the
  laptop's Chrome rendered every frame and the VM's Chromium sat unused.
- The link measured 1,025,951 B/s (`:MdViewerMeasureLink`, aide alias,
  2026-08-27), consistent with the 2026-08-25 ceiling measurements.

Two findings from that run drove the rc10 work:

1. **Held-key scrolling felt laggier than the old PNG mode.** The cause was
   measured, not guessed: the replica dispatched a capture per scroll
   position into the serial browser queue, each dispatch superseding the one
   already running, so finished screenshots were discarded stale while the
   screen sat still — 517 captures for 206 surfaces served. rc10 paces one
   moving marker in flight (released by the `presented` acknowledgement),
   captures at a reduced moving scale with a device-scale settle, and holds
   one capture want per document, newest wins. On the ichigo rig the same
   30-step burst went from 4 frames presented to 24, and marker-emit→ack
   from p95 2147 ms to p95 63–167 ms (2026-08-27).
2. **`remoteGraphicsCommands` was nonzero on a healthy local session** —
   because the counter counts *every* Kitty graphics command any process
   sends through the wrapped session, and the run had also exercised the
   direct PNG path for comparison. The parser now attributes commands and
   raster bytes by image-id space (`remoteMdvGraphicsCommands`,
   `remoteMdvRasterBytes`), so "did md-viewer send raster through this
   link?" and "did something else draw graphics?" are separate answers.

## K4: time-to-glass, measured in the product

K4 is the last kill criterion: scroll time-to-glass ≥ 300 ms means a
serialized per-frame dependency crept back in. It is now a permanent
diagnostic rather than a stopwatch exercise:

- The **VM** stamps every marker at emit and samples the `presented`
  acknowledgement round against it — one clock, a strict upper bound on
  time-to-glass (glass lights one notification leg before the sample).
  `:MdViewerDebug` shows it as `local_render.presented` (p50/p95/max over a
  bounded window).
- The **helper** samples marker-arrival→frame-injection, capture queue wait,
  and capture duration on its own clock, plus the last 32 captures with
  their scroll position and scale. `--status` and the health enrichment
  carry them.
- Superseded markers are never samples on either side — nothing acknowledges
  them, so the distribution describes only frames a reader saw.

Reference numbers, ichigo (LAN SSH, tmux rig, 2026-08-27, rc10 code):
emit→ack p50 33 ms, p95 63–167 ms across runs; capture p50 27 ms at the 0.5
moving scale, 41–50 ms at device scale; the one >1 s sample in any run is
the first frame queueing behind the cold Chromium launch — first-preview
cost, not scroll cost.

## Validating a release candidate

The rc9 validation was a page of manual steps; it is now two commands and
two human judgments. Everything below runs on the **laptop**, from the
helper checkout (one-time setup: clone the repo at the RC tag, then
`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts` inside
`renderer/`).

```sh
# 1. Move both ends to the tag. The VM's Neovim config must already pin
#    version = "<tag>" -- this script updates and *verifies*, it never edits
#    your config. It refuses to run on a dirty checkout.
sh scripts/local/ssm-rc-update.sh <vm-host> <tag>

# 2. Run every automatable leg and produce one artifact.
sh scripts/local/ssm-validate.sh <vm-host>
```

`ssm-validate.sh` runs: toolchain and version agreement on both ends, K1
(`topology-check.sh`), K2 (10,000-marker echo, scripted end to end), the K4
live pipeline with its held-key burst and stage timings, the zero-raster
invariant from the run's own filter counters, and a link measurement. It
prints `AUTOMATED VALIDATION: PASS/FAIL`, writes
`artifacts/ssm-validation-<tag>-<date>.md`, and names the result file —
that file is the thing to report back. `artifacts/` is gitignored: a
validation record names private host aliases and stays on the operator's
machine.

The human part is deliberately tiny, printed by the validator and recorded
in the artifact's last section:

1. Hold `j` in a real preview for several seconds — smooth / acceptable /
   unacceptable.
2. Stop — does the frame sharpen back to full quality?

`render.location = "local"` with no helper produces one warning per preview
open and falls back to rendering on the VM. For a config shared across
machines, gate it: `location = vim.env.MD_VIEWER_LOCAL and "local" or
"current"`, and export `MD_VIEWER_LOCAL=1` in the sessions you launch
through the helper.

## Rollback

In increasing strength, none of which touch each other:

1. `render.location = "current"` (or unset `MD_VIEWER_LOCAL`) — immediate,
   no reinstall; the remote path is untouched by local mode.
2. Pin the previous tag in the VM config and re-run
   `sh scripts/local/ssm-rc-update.sh <vm-host> <previous-tag>` — it moves
   the helper checkout and the VM plugin together.
3. State removal: `rm -rf ~/.local/state/md-viewer/local` on the laptop,
   `rm -rf ${XDG_RUNTIME_DIR:-/tmp/md-viewer-$USER}/md-viewer` on the VM.

## What this page does not claim

The architecture is validated (rc9, above). What each new RC still owes is
its own feel check on the real link: the release notes for a tag say "AWS
SSM validation pending" until a filled artifact from the work laptop exists
for that tag — do not edit that sentence away without the artifact in hand.
