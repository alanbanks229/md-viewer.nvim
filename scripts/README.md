# Harnesses

Nothing here runs in CI. These are the checks that need something CI does not
have: a real browser, or a real terminal window with a real display behind it.
The headless suites (`tests/lua/`, `tests/node/`) cover everything that can be
covered without one — run those first.

Everything here concerns the **drag-highlight overlay**: the path where a moving
drag frame is drawn as translucent Kitty placements composited over the base
image, instead of re-photographing the page. It is the one part of md-viewer
that thinks in device pixels rather than terminal cells, so it is the one part a
headless test cannot fully prove.

Output goes to `tmp/overlay/<label>/`, which is gitignored.

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
