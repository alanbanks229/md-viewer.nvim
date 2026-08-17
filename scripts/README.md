# Harnesses

Nothing here runs in CI. These are the checks that need something CI does not
have: a real browser, or a real terminal window with a real display behind it.
The headless suites (`tests/lua/`, `tests/node/`) cover everything that can be
covered without one — run those first.

Two features live here, and they are the two parts of md-viewer that think in
device pixels rather than terminal cells -- the parts a headless test cannot
fully prove: the **drag-highlight overlay** (`overlay/`) and **animated
images** (`animation/`). Three others need neither a display nor a browser:
`scroll-scale/` needs a *slow link*, `remote-images/` needs a *network with
no direct route out*, and `remote-projects/` needs a *reachable ssh host* --
the pieces of hardware no test machine has.

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
