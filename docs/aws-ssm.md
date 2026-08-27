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

## Validating a release candidate from the work laptop

This procedure is written to be followed top to bottom in one sitting. It was
authored against `v0.3.0-rc9`; substitute the tag being validated.

### 0. Toolchain check (minutes, fails fast)

On the **work laptop**:

```sh
node --version        # need >= 22.12
```

A system Chrome, Chromium, or Edge must be installed; the helper discovers it
and never downloads one.

### 1. Install the helper on the work laptop

```sh
git clone --branch v0.3.0-rc9 https://github.com/alanbanks229/md-viewer.nvim ~/md-viewer-local
cd ~/md-viewer-local/renderer
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts
node src/local-main.js --version    # must print v0.3.0-rc9 and a commit hash
```

### 2. Pin the VM's plugin to the same tag

In the Neovim config the VM uses, pin md-viewer to the tag and enable local
mode:

```lua
{
  "alanbanks229/md-viewer.nvim",
  version = "v0.3.0-rc9",
  opts = { render = { location = "local" } },
}
```

Then update the plugin on the VM (`:Lazy update md-viewer.nvim` or your
manager's equivalent; the build hook reinstalls the renderer's locked
dependencies). Both ends must be on the same tag — the socket hello refuses a
protocol mismatch by design, and the refusal names the fix.

`render.location = "local"` with no helper produces one warning per preview
open and falls back to rendering on the VM. If that is too loud for a config
shared across machines, gate it: `location = vim.env.MD_VIEWER_LOCAL and
"local" or "current"`, and export `MD_VIEWER_LOCAL=1` in the sessions you
launch through the helper.

### 3. Run the transport rigs over the real link

Both rigs passed on LAN SSH (ichigo, 2026-08-26); this run is their SSM leg.

```sh
# K1: the wrapped-ssh topology (raw mode, resize, ~., full-screen nvim)
~/md-viewer-local/scripts/local/topology-check.sh <vm-host>

# K2: marker transit integrity -- run the helper in echo mode, then emit
# 10,000 sequenced markers from the VM side and read the tally it prints.
node ~/md-viewer-local/renderer/src/local-main.js --marker-echo-test -- ssh <vm-host>
# ...in that session, on the VM:
<repo>/scripts/local/marker-echo-emit.sh <token printed by the helper> 10000
```

PASS is exact: `missing=0 out-of-order=0 malformed=0`. Any loss or reorder is
a kill criterion, not a tuning opportunity.

### 4. The live session

```sh
node ~/md-viewer-local/renderer/src/local-main.js -- ssh <vm-host>
```

In that session, on the VM, open `tests/fixtures/kitchen-sink.md` from the
plugin checkout (or any image-bearing document) and work through:

1. **First preview** — time from `:MdViewerOpen` to pixels.
2. **Scroll**, slow and then as fast as the wheel goes.
3. **Source sync** — cursor motion in the source follows in the preview.
4. **Edits** — type; the preview updates within the debounce.
5. **Images** — local images appear; a remote image appears after its fetch.
6. **Links** — follow one, come back (`H`).
7. **Selection and find** — drag a selection, `/` a term, step matches.
8. **Resize** the window; **close and reopen** the preview.
9. **Fallback** — kill the helper mid-session (Ctrl-C in its terminal):
   expect one warning and a working (slower) preview; the ssh session itself
   dies with the helper, so this ends the run.
10. **Reconnect** — relaunch through the helper, reopen, confirm re-attach.

### 5. Collect the evidence

While the session is healthy, capture:

- `:MdViewerDebug` — the whole buffer. The decisive numbers are
  `local_render.phase` (attached), per-session `local_marker_frames` versus
  `local_presented_count`, and `markers.direct_bytes_fallbacks` (0).
- `:MdViewerHealth` — the Rendering section's `Location` row and the
  Warnings section.
- On the laptop: `node ~/md-viewer-local/renderer/src/local-main.js --status`
  — the filter's `parser.remoteGraphicsCommands` is the count of graphics
  uploads that crossed the link as bytes; **zero while attached is the whole
  claim of the feature**.
- `:MdViewerMeasureLink` — the link rate, for the record.

### 6. Rollback

In increasing strength, none of which touch each other:

1. `render.location = "current"` — immediate, no reinstall; the remote path
   is untouched by local mode.
2. Pin back `version = "v0.3.0-rc8"` and `:Lazy update md-viewer.nvim`.
3. State removal: `rm -rf ~/.local/state/md-viewer/local` on the laptop,
   `rm -rf ${XDG_RUNTIME_DIR:-/tmp/md-viewer-$USER}/md-viewer` on the VM.

## Results template

Paste this back, filled in. "Not tested" is an answer; a guess is not.

```
RC tag / helper --version:
Laptop OS / terminal + version:
VM OS / Neovim / Node / Chrome:
Connection (ssh config form, compression on/off):
:MdViewerMeasureLink:

K1 topology-check over SSM:            PASS/FAIL (paste tail)
K2 marker echo over SSM:               received= missing= out-of-order= malformed=
Attach on open (one-time? notices?):
First preview time (rough stopwatch):
Scroll feel, slow / fast:
Source sync / edits / images / links:
Selection / find:
Resize / close-reopen:
Helper kill -> fallback behavior:
Re-attach after relaunch:

:MdViewerDebug local_render block:     (paste)
helper --status:                       (paste; remoteGraphicsCommands = ?)
:MdViewerHealth warnings:              (paste)
Failures / screenshots:
Verdict:
```

## What this page does not claim

Until a filled results template from the real SSM environment exists, local
mode's SSM behavior is a design with local evidence: the transport rigs and
the full session flow pass on LAN SSH (ichigo, 2026-08-26), and the byte-flow
invariants are pinned by tests. The release notes for any tag carrying this
feature say "AWS SSM validation pending" until that changes — do not edit
that sentence away without the evidence in hand.
