# Harnesses

Nothing here runs in CI. These are the checks that need something CI does not
have: a real browser, or a real terminal window with a real display behind it.
The headless suites (`tests/lua/`, `tests/node/`) cover everything that can be
covered without one — run those first.

Two features live here because they think in device pixels rather than terminal
cells, which is what a headless test cannot fully prove: the **drag-highlight
overlay** (`overlay/`) and **animated images** (`animation/`). The rest need
neither a display nor a browser, but need a piece of hardware no test machine
has: `scroll-scale/` and `resident/` need a *slow link*, `remote-images/` needs
a *network with no direct route out*, and `remote-projects/` needs a *reachable
ssh host*. `resident/` additionally needs a *real terminal holding real
pixels*, since what it measures is that terminal's memory.

`rig/` is the odd one out: it measures nothing, it *builds* one of those pieces
of hardware. Given an SSH host it installs what md-viewer needs to run on the
far end, so the remote mode can be reproduced without a second computer.

Output goes to `tmp/<feature>/<label>/`, which is gitignored.

## `overlay/live/` — end-to-end gesture regression

```sh
nvim --headless -u NONE -i NONE -l scripts/overlay/live/drive.lua
```

Spawns a second Neovim over RPC, opens `tests/fixtures/kitchen-sink.md`, and
drives a real drag through `nvim_input_mouse` against the real renderer and real
Chromium. 16 assertions covering the whole lifecycle: moving frames opt out of
capture and cost hundreds of bytes rather than a megabyte, the tint sheet is
uploaded once and not per frame, the release settles with a true device-scale
capture, and every overlay placement is deleted afterwards. Exits non-zero on
failure.

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
2 moving, what a real drag looks like) and `churn` (all 70 moving, the worst
case the encoding can produce) — while sampling the terminal process's own CPU
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

## `resident/` — is reusing sent pixels earning its keep, and what does it cost?

Five files behind one feature: over SSH the document is cut into a grid of
slices, each uploaded once and kept, and every scroll position is drawn as a crop
of pixels the terminal already holds (`:help md-viewer-reuse-sent-pixels`). It
trades terminal memory for wire time, so it needs a harness on each side of that
trade — and neither quantity is visible from a developer machine.

### `ab.lua` — is a second pass over the same ground free?

Run inside a real Neovim on the far end of the link, on iTerm2, outside a
multiplexer, with a preview open on a document several viewports long:

```vim
:runtime scripts/resident/ab.lua   " arms phase 1, every scroll is a frame
"  ...walk the document, pausing at each screen...
:ResidentAB                        " arms phase 2, slices
"  ...walk it the same way...
:ResidentABMark                    " once slices_resident stops climbing
"  ...now walk back over the same ground...
:ResidentAB                        " prints the comparison
```

Measured in total `nvim_ui_send` bytes rather than PNG bytes, which is the whole
reason this is not a column in `scroll-scale/ab.lua`: "the payload fell to zero"
and "the traffic fell to zero" are different claims, and
`docs/local-render-design.md` records this project being wrong about exactly that
difference once already.

The mark matters. Phase 2's first pass is the grid warming up and is *expected*
to cost more than phase 1; the claim is about the second pass, which is why
`:ResidentABMark` exists and why it warns when it is set while `slices_resident`
is still climbing. `:ResidentABCancel` abandons a run partway; the configuration
in force is saved before phase 1 and restored after phase 2, including on the
error path.

Two verdicts are worth knowing before you read the numbers. **UNACCOUNTED** means
the fill identity failed —
`fills == slices_resident + stale + abandoned + undisplayed + evictions +
dropped_slices` — and the report is describing captures it cannot place, so treat
the byte counts as unsafe rather than merely disappointing. **`evictions` above
zero** means the document is larger than `image.resident_memory_mb` and the window
is sliding, so the run is measuring a ceiling rather than the feature.

The report opens in a tab, not a split. A split takes rows from the preview, which
is part of what slices are keyed on, so a report that opened in one would destroy
the grid it was reporting.

### `rss.sh` — does the terminal give the memory back over half an hour?

```sh
./scripts/resident/rss.sh [label] [seconds] [pid]
```

Attaches to the terminal you are already working in — it never launches or kills
it — and samples its resident size while you scroll a real preview on the far end
of a real link. Defaults to 30 minutes against the frontmost iTerm2. Over
`MD_VIEWER_RESIDENT_RSS_CEILING_KB` it says so and stops; closing the preview is
yours to do.

**This is the gate for qualifying a new terminal.** A terminal that grows tens of
megabytes per slice and never gives any of it back is exactly the failure this
exists to catch, and for the first sixty seconds it looks identical to a healthy
one — which is the defect WezTerm's overlay is disabled for. iTerm2 has been
through it and plateaus; Kitty and Ghostty have not, which is why they are `off,
pending` in [../docs/terminal-support.md](../docs/terminal-support.md).

### `rss-calibrate.py` — what does one resident megapixel cost?

```sh
python3 scripts/resident/rss-calibrate.py
python3 scripts/resident/rss-calibrate.py --spawn   # a fresh iTerm2 window
```

The prior question `rss.sh` cannot answer in under half an hour, answered in about
a minute with no SSH, no Neovim and no Chromium in the picture: transmit PNGs of
known pixel counts, place each one (a terminal may decode lazily, so an image
never drawn reports nothing), sample RSS, free them, sample again. This is where
`image.resident_memory_mb`'s ~13 bytes per pixel comes from, against the 4 the
project assumed for its first three releases.

**Its result is not corroborated, and the docstring says so.** The only real
session ever sampled held twelve slices — ~342 MB by this conversion — while
`rss.sh` saw ~10 MB move. Re-running this against real document slices rather than
the synthetic incompressible gradients it uses today is the cheap experiment that
would separate "the sampler cannot see it" from "gradients do not generalise".

### `mutants.sh` — does the suite actually catch the defects this feature shipped?

```sh
./scripts/resident/mutants.sh [name-filter]
```

Reintroduces each of a list of real defects — every one of which reached a real
session — one at a time, and runs the Lua suite against each. `CAUGHT` is the
result wanted. `MISSED` means the defect can be put back with every test still
green.

Read a `MISSED` before acting on it: the mutation may be inert rather than
uncovered, because each pattern must be a unique substring of its file and a
mutation that does not change behaviour reports the same way as one nothing
tests. Commit before running it; it edits tracked files in place and restores
them afterwards.

### `probe.mjs` — the go/no-go this whole feature rests on

```sh
node scripts/resident/probe.mjs
```

Asserts that `Page.captureScreenshot` with `captureBeyondViewport: true` and a
document-space clip several viewports tall returns the right pixels *without*
resizing the layout viewport. md-viewer's bottom spacer makes `scrollHeight` a
function of viewport height, so a capture path that grew the viewport to reach
beyond the fold would silently change the document's own scroll extent — and every
block rect, scroll clamp and slice coordinate is derived from it.

Its question is answered, and it is kept because the answer is an assumption
`docs/architecture.md` and `docs/local-render-design.md` both still rely on:
`captureBeyondViewport: false` does *not* fail loudly on a too-tall clip, it
returns a correctly sized image whose beyond-the-fold band is only 95.5% right.
Drives the real `BrowserRenderer`, writes only PNGs under `tmp/resident/probe/`,
exits non-zero on any failed check.

## `remote-projects/ab.lua` — does scrolling a remote document really cost zero remote I/O?

The headless suite already proves it with a stubbed transport
(`tests/lua/cases/remote_assets.lua` counts calls through the one spawn
seam); this is the same claim against a real host, with the prediction fixed
in the file header before any run: **zero transport calls during the scroll,
cadence within 30% of a local baseline**. Run it inside a *local* Neovim that
can open a remote document (remote-ssh.nvim or netrw):

```vim
:edit README.md                             " a local file first
:MdViewerToggle
:runtime scripts/remote-projects/ab.lua     " arms the baseline
"  ...wheel-scroll the whole document...
:RemoteProjectAB                            " ends the baseline
:RemoteOpen rsync://host//path/README.md    " then the remote document
:MdViewerToggle
"  ...wait for its images to appear...
:RemoteProjectAB                            " arms the remote phase
"  ...wheel-scroll the same way...
:RemoteProjectAB                            " prints the comparison
```

`:RemoteProjectABCancel` abandons a run partway. No configuration is changed
and nothing is written to disk. An INCONCLUSIVE verdict names what was wrong
with the run itself — the second phase was not a remote buffer, or this
Neovim is itself over SSH, which is the other feature (`:help
md-viewer-ssh`).

## `rig/provision.sh` — a host you can reproduce the SSH mode on

Not a measurement. This is the one harness whose output is a *machine*: an SSH
host set up to run Neovim on the far end, so the mode most defects are reported
in can be reproduced without a second computer.

Note which remote mode this is. `remote-projects/` above is the other one —
Neovim local, only file contents crossing — where `terminal.detect().ssh` is
false and reusing sent pixels stays off by design. Here Neovim runs on the host,
every frame comes back through the pty, and the resident-slice machinery is
live.

```sh
scripts/rig/provision.sh              # the default host
scripts/rig/provision.sh some-host
scripts/rig/provision.sh --check      # report state, change nothing
scripts/rig/provision.sh --shape      # throttle egress to 800kbit/40ms
scripts/rig/provision.sh --unshape
```

Installs Neovim from the release tarball (jammy ships 0.6, and the snap has
already failed on one of these hosts), Node from NodeSource, and **Google
Chrome rather than the Chromium snap** — a snap is confined and Playwright hands
`chromium.launch` a profile directory outside the paths it may read, so a
confined binary fails at launch instead of degrading. Then it clones the vault,
symlinks `~/.config/nvim` at it exactly as on the Mac, and generates
`~/mdv-rig/scroll-test.md` — several viewports of mixed content, generated
rather than committed so that "scroll to the end and watch it" is the same
observation every time.

The check that matters most is the cheapest to skip. `TERM_PROGRAM` does not
survive SSH, so iTerm2 and WezTerm are identified through `LC_TERMINAL`, which
arrives only because sshd accepts `LC_*`. Without it the profile falls back,
`resident_pan` is not enabled for it, and the rig exercises a *different code
path* than the machine being reproduced — with nothing reporting a fault. Run
`--check` from the terminal you will actually test in; it reports the variable
as it arrived on that connection rather than guessing.

Confirm the host is really in the mode you wanted before trusting a run:
`:MdViewerHealth` should say `ssh session` and name your terminal's profile, and
`reuse sent pixels` should be on rather than `off -- local session`.

`--shape` throttles everything leaving the host, this ssh session included. A
LAN is not the link defects get reported over, and a timing-sensitive one will
not reproduce at LAN speed; 800 kbit/s is the rate `resident.lua`'s wire
constants were tuned against.

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
5. **Suppression**: drag a selection, open the cmdline, trigger completion --
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
