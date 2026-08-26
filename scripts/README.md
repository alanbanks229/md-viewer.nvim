# Harnesses

Nothing here runs in CI. These are the checks that need something CI does not
have: a real browser, or a real terminal window with a real display behind it.
The headless suites (`tests/lua/`, `tests/node/`) cover everything that can be
covered without one — run those first.

Two features live here, and they are the two parts of md-viewer that think in
device pixels rather than terminal cells -- the parts a headless test cannot
fully prove: the **selection-highlight overlay** (`overlay/`) and **animated
images** (`animation/`). Two others need neither a display nor a browser:
`scroll-scale/` needs a *slow link*, and `remote-images/` needs a *network with
no direct route out* -- the two pieces of hardware no test machine has.

Output goes to `tmp/<feature>/<label>/`, which is gitignored.

## `resident/registration.mjs` — is a region capture document-absolute?

```sh
node scripts/resident/registration.mjs
```

The go/no-go for whole-document resident mode. Captures the same document region
from three different `window.scrollY` values and asserts the bytes are identical,
then characterises the two things that make that true: the capture path and the
`captureBeyondViewport` flag.

It exists because a renderer echoes back the region it was *asked* for. If a clip
composes with the page's scroll, every chunk holds pixels of wherever the reader
was standing while the coordinate model, the placements and the retirement all
stay provably correct — a fault with no downstream detector. Needs a
Chrome/Chromium install; no display.

Measured at 1980x4080 device px (8.1 Mpx) on two hosts:

```
                                    Ubuntu 22.04 / Chrome 151   macOS 15 / Chromium 142
  CDP, captureBeyondViewport: true  identical at 0/5767/11535   identical at 0/5767/11535
  page.screenshot({clip})           1980x2040, all differ       1980x2040, all differ
  captureBeyondViewport: false      94.8% of samples, delta 210 95.5% of samples, delta 210
  first capture of the process      13,089ms                    53ms
  every later capture               161-250ms                   46-79ms
```

`page.screenshot({clip})` returns half the height asked for, different bytes at
every scroll position, and throws outright on an interior region. Only the CDP
path with the flag set is usable.

Two rows do **not** generalise across hosts, and both matter:

- **The cold penalty is per browser process, not per page.** On Ubuntu the
  process's first region capture took 13,089ms and every later one 161-250ms,
  *including the first capture on a freshly rebuilt page and context*. A timeout
  keyed on "have we captured a region on this page" would re-arm an allowance it
  no longer needs, and one keyed on nothing at all would disable the capture path
  for the life of the process the first time it fired.
- **macOS does not pay it.** 53ms cold against 50ms warm. Anything derived from
  this cost has to be measured on the host it will run on.

## `resident/sizing.mjs` — how big should a chunk be?

```sh
node scripts/resident/sizing.mjs [--link-bytes-per-sec 800000]
```

One browser launch per cold measurement, so it takes a few minutes. Measured on
Ubuntu 22.04 / Chrome 151 at 990x1020 CSS, device scale 2:

```
  A. first capture of the process       B. discharging it
     0.5x viewport   2.0 Mpx  16,335ms     blank-page primer at 1x   8,988ms
     1.5x viewport   6.1 Mpx  10,407ms     then 2.9x on a document     355ms
     2.9x viewport  11.7 Mpx   9,874ms     the same, unprimed        9,874ms

  C. warm capture
     vp     Mpx   warm ms   PNG KB   wire ms @ 0.80 MB/s
     0.5x   2.0       164      188       240
     1x     4.0       116      396       507
     1.5x   6.1       168      615       788
     2x     8.1       266      826     1,058
     2.5x  10.1       285    1,059     1,355
     2.9x  11.7       373    1,218     1,559
```

**Six times the pixels moved the first capture's cost 1.7x, in the wrong
direction.** It is a fixed per-process price, not a per-region one, and a primer
on a blank page before any document is loaded discharges it completely. So chunk
size does not bear on first paint at all, and section C alone sets it.

PNG bytes are linear in pixels here — 94 to 105 KB per Mpx across the whole
sweep — so a bigger chunk buys no compression. What it trades is per-capture
overhead and overlap waste against responsiveness: on a 0.80 MB/s link a 2.9x
chunk is 373ms of capture and 1,559ms of wire, where a 1x chunk is 116ms and
507ms.

The wire column throughout is 0.80 MB/s, which is an **AWS SSM tunnel** and not
remote sessions in general — see
[Where that ceiling comes from](../docs/local-render-design.md#ssm-ceiling). An
ordinary SSH session measures 16–23 MB/s, where every wire figure above drops
below the capture time next to it and this whole sweep stops being interesting.

**This section is not only about resident mode.** `CDP_CAPTURE_TIMEOUT_MS` is
10,000ms and the first capture on this host takes 9,874-16,335ms — including an
ordinary `captureBeyondViewport: false` viewport capture, which is what every
session already does on its first render. One of these runs failed outright at
15,215ms. `captureViewportPng` latches `cdpCaptureUnavailable` on its first
failure and never retries, so losing that race demotes a session to the
Playwright encoder for the life of the renderer process. Priming at startup is
what removes the race.

## `resident/drive.lua` — does a resident preview actually work?

```sh
nvim --headless -u NONE -i NONE -l scripts/resident/drive.lua [document.md] [--slow-chunks=MS]
```

Spawns a second Neovim over RPC with a faked Kitty-capable terminal, opens a
preview, waits for the document to become resident, then scrolls it and counts
what reached the terminal. The child records the byte stream instead of drawing
it, so this needs no display and no graphics terminal — only Node and a
Chrome/Chromium. Exits non-zero on any failed assertion.

`--slow-chunks=MS` holds every chunk reply back by `MS` before handing it to the
controller, which is the whole of what a slow link does to this feature. Use it
for anything about the *warm-up*: on a fast host the first chunk lands before
the pane can be observed at all, which is how a blank first paint survived to
0.3.0-rc5. `--slow-chunks=2000` is roughly a chunk's cost on an AWS SSM link.

One of the assertions is the bug that motivated the knob, stated as an
invariant: **the pane is never both blank and quiet.** Sampled every 100 ms from
preview open until residency, there is always either a frame placed, or resident
bands placed, or a spinner saying why there is neither.

The claim under test is the whole feature: **after warm-up, a scroll costs no
renderer request and no image bytes.** Against this repo's own README on Ubuntu
22.04 / Chrome 151:

```
  22 chunks resident, each uploaded exactly once
  40 scrolls over a 12,505px document
    0 renderer requests
    0 image uploads
   58 placements in 40 writes, 7,855 bytes total -- 196 bytes per scroll
```

**Run this after touching `resident.lua`, `resident_session.lua`,
`controller.lua` or the backend's compose path.** It is the only check that
exercises the chain rather than the links.

## `rig/first-frame.lua` — did the first capture keep the fast encoder?

```sh
nvim --headless -u NONE -i NONE -l scripts/rig/first-frame.lua
```

Drives the renderer directly, reports what the first frame cost and which
encoder produced it, and exits non-zero if the fast path was lost. Headless, so
it works over a link that cannot draw. `cdp_fast_png` is the answer you want;
`playwright_png` means the process lost the CDP encoder on its first capture and
will not get it back, which is also where `render.scroll_scale` stops working.

## `rig/deploy.sh` — put this tree on the machine that runs Neovim

```sh
scripts/rig/deploy.sh <ssh-host> [remote-path]
```

rsyncs the working tree and installs the renderer's locked dependencies on the
far side, for testing a branch that is not pushed yet or a tree with uncommitted
changes. Prints the `dir = ` line to put in the lazy.nvim spec on that machine.

## `overlay/live/` — end-to-end gesture regression

```sh
nvim --headless -u NONE -i NONE -l scripts/overlay/live/drive.lua
```

Spawns a second Neovim over RPC, opens `tests/fixtures/kitchen-sink.md`, and
drives a real `v`/motions preview visual selection through `nvim_input`
against the real renderer and real Chromium -- the keyboard equivalent of
what used to be a real mouse drag, since highlighting only happens through
vim-like motions now. 16 assertions covering the whole lifecycle: moving
frames opt out of capture and cost hundreds of bytes rather than a megabyte,
the tint sheet is uploaded once and not per frame, `y` settles with a true
device-scale capture, and every overlay placement is deleted afterwards.
Exits non-zero on failure.

Needs `npm ci --prefix renderer` and a Chrome/Chromium install. No display
required. **Run this after touching `interaction.lua`, `controller.lua`, or
`backends/kitty_raw.lua`** — it is the only check that exercises the chain
rather than the links.

It reaches into `backends.kitty_raw.detect` and `process.request` to fake the
terminal, so renaming either will break it silently.

## `overlay/geometry/` — does the highlight land where the arithmetic says?

```sh
scripts/overlay/geometry/run.sh /Applications/WezTerm.app [label]
```

Launches one terminal window with a pinned config (`overlay/wezterm.lua`), draws
six named rectangles through the production placement path, screenshots each of
three phases, and asserts 42 pixel facts: the OS-reported cell equals the
device-pixel cell, every rectangle's four edges land within ±1 px, each bar is
one *solid* run rather than a comb of per-cell stripes, adjacent bars keep their
gap, and `overlay_clear` leaves zero tinted pixels with the base unchanged.

Registration is re-derived from the pixels of each screenshot rather than from
window arithmetic, so it survives the window being moved between captures.

**Run this before setting `selection_overlay = true` for a terminal profile, or
after changing `overlay_encoding`, `raw_cell_offset_px`, or the placement
encoder.** It is written around WezTerm because that is where the geometry
defect was found; nothing in it is WezTerm-specific beyond the launcher.

macOS only (`screencapture`), and the invoking terminal needs Screen Recording
permission — without it the captures come back as wallpaper, which the harness
reports rather than silently passing.

## `overlay/stress/` — is it affordable?

```sh
scripts/overlay/stress/run.sh /Applications/WezTerm.app [label] [seconds]
```

Drives `overlay_apply` at ~40 fps under two workloads — `diff` (70 rectangles,
2 moving, what a real selection extension looks like) and `churn` (all 70
moving, the worst case the encoding can produce) — while sampling the terminal process's own CPU
and resident size once a second. Aborts if resident size crosses
`MD_VIEWER_OVERLAY_RSS_CEILING_KB` (default 2 GB).

Drawing correctly and drawing affordably are separate questions. WezTerm answers
the first yes and the second no, which is why its overlay is off; see
`docs/terminal-support.md`.

That ceiling is not a nicety. Do not remove it and do not raise it casually.

## `overlay/kitty-memory-repro.py` — the upstream reproduction

```sh
python3 scripts/overlay/kitty-memory-repro.py          # overlay over the base image
python3 scripts/overlay/kitty-memory-repro.py --clear  # identical, aimed at bare rows
```

Stdlib Python, no md-viewer and no Neovim in the loop — it writes Kitty graphics
escapes to `/dev/tty` directly and samples the terminal's RSS. The two modes
differ only in *where* the second placement lands, which is what isolates the
defect: a placement overlapping another image costs WezTerm tens of megabytes
per frame and never gives them back; the same placement on bare rows plateaus.
Kitty and Ghostty hold flat in both modes.

This is the reproduction behind [wezterm/wezterm#7953][issue] and the fix
proposed in [wezterm/wezterm#8035][pr]. Keep it until that fix ships in a
released WezTerm build and md-viewer's WezTerm profile is re-qualified with the
geometry and stress harnesses above.

[issue]: https://github.com/wezterm/wezterm/issues/7953
[pr]: https://github.com/wezterm/wezterm/pull/8035

## `scroll-scale/ab.lua` — does a smaller moving frame actually help?

Run inside a real Neovim, on the far end of the connection you care about,
with a preview already open (`:MdViewerToggle`) on a document long enough to
scroll for a few seconds:

```vim
:runtime scripts/scroll-scale/ab.lua   " arms phase 1, full-size frames
"  ...wheel-scroll the whole document...
:ScrollAB                              " arms phase 2, half-size frames
"  ...wheel-scroll the same way again...
:ScrollAB                              " prints the comparison
```

Reports `fast_png_bytes` for each phase, the transit each implies at the
0.80 MB/s ceiling `docs/local-render-design.md` was measured against, and a
verdict. `:ScrollABCancel` abandons a run partway. The configuration in force
is saved before the first phase and restored after the last, including by the
error path -- nothing is written to disk and no file is edited.

Use the plugin's own README as the document if you want numbers comparable to
the ones recorded in `docs/local-render-design.md`.

The verdict worth watching for is **INERT**: `capture_encoder` is
`playwright_png` rather than `cdp_fast_png`. Playwright's own `scale` is a
two-value enum, so the numeric factor cannot reach the capture on that path and
`render.scroll_scale` does nothing on that host, whatever it is set to.

## `remote-images/probe.lua` — does a blocked image still cost the whole preview?

Answers one question: when a document contains an https image this host cannot
fetch, how long until the **document** appears? Before v0.2.0 that was the
renderer's full 20-second timeout, paid before anything was drawn, because
remote images resolved in a pre-pass between parse and render.

Needs a network where the connection cannot complete — which in practice means
one whose only route out is a proxy. `remote-images.js` pins the address it
validated and deliberately never consults `HTTP_PROXY`, because that pinning is
what makes the SSRF check meaningful, so a proxied network reproduces this
exactly and a developer machine cannot.

```vim
:runtime scripts/remote-images/probe.lua
:RemoteImageProbe
```

It writes its own two scratch documents — one with a remote image, one with
none — opens a preview on each, and reports first-frame time for both with a
verdict against the 20-second stall. The control is what makes the number
readable: what matters is that the two are close, not that either is fast.

Each run appends a unique query to the image URL, because the renderer caches a
failure for a minute and a success for as long as it holds it — without that, a
second run would measure the cache rather than the network. A `true` in the
`still fetching` column is the expected steady state on a network that cannot
reach the host: the image stays a placeholder and the document does not wait
for it.

## `animation/` — animated-image qualification

Run this before flipping a terminal profile's animation mode -- especially
before promoting anything to `native`, which drives a protocol extension
("frames" placements say nothing about) the headless suites can only
golden-test the bytes of.

```sh
node scripts/animation/make-fixtures.mjs
nvim --headless -u NONE -i NONE -l scripts/animation/smoke.lua
```

The smoke half needs no terminal: it drives the real renderer and real
Chromium through the whole media lane (registration, geometry-with-sha,
content-addressed materialization, native gap preservation, thinning of the
README-scale recording, cache hits) and prints the decode timings worth
keeping on record. Exits non-zero on failure.

The half that needs eyes, **inside the terminal being qualified**:

```sh
nvim -u scripts/animation/manual.lua tmp/animation/fixtures/fixture.md
```

`:MdViewerToggle`, then watch, in order:

1. **Playback**: the quick loop cycles red/green/blue smoothly; the slow loop
   steps ~every 800ms; the still GIF never moves; the play-twice loop runs
   twice and freezes on its last frame (this also pins the protocol's
   ambiguous `v` loop-count semantics -- note the actual play count).
2. **Alignment**: every animation sits exactly over its own still frame -- no
   offset at rest, none at any scroll position, none after a window resize.
3. **Scroll**: scroll fast top to bottom and back. Animations follow with the
   text, clip cleanly at the preview's top and bottom edges (half-visible is
   half-drawn, never overdrawn into other windows), and never smear or ghost.
4. **Resize**: resize the split while everything plays. Frames re-materialize
   at the new size (a brief still is fine, a wrongly-scaled animation is not),
   and `:MdViewerDebug`'s asset list settles back to `playing`/frame counts.
5. **Suppression**: extend a selection with `v`/`V`, open the cmdline, trigger completion --
   animation pauses (still frame stays) and resumes afterwards.
6. **The large recording**: expect thinning (choppier, same total duration)
   and a few seconds to first motion; the still frame shows throughout.
7. **Lifecycle**: `:MdViewerToggle` closed and reopened several times;
   `:qa` at the end. Watch the terminal's memory across all of it (Activity
   Monitor / `top` on the terminal process): it must plateau, not stair-step
   with each reopen. On Kitty, `kitty +kitten icat --print-window-size` or
   `kitty @ ls` (with remote control) can list resident images -- after a
   close there should be none of md-viewer's.
8. **Responsiveness**: typing and scrolling in the source split stays smooth
   while everything plays.

For `native`: uncomment the `terminal.animation = "native"` line in
`manual.lua` and repeat the whole list. Additionally confirm the animation
keeps playing across a renderer restart (`:lua require("md-viewer.process").stop()`
then edit the buffer) -- terminal-driven playback should not so much as
stutter, because the uploads survive by content key.

Record what you watched (terminal, version, date, play-count observed in
item 1) in `docs/terminal-support.md` when promoting a profile.
