# Terminal support

md-viewer's graphical preview needs a terminal that advertises the Kitty graphics
protocol, used without a multiplexer, with `image.backend = "kitty_raw"` selected
explicitly. Kitty.app and the `kitty`/`kitten` executables are not required — any
terminal speaking the protocol works.

`:MdViewerHealth` reports what was detected and why. `:MdViewerDebug` adds the
per-terminal capability detail, including whether the drag-highlight overlay is in
use and the reason.

## Status labels

Every claim on this page uses exactly one of four labels.

| Label | Meaning |
|---|---|
| `Supported` | Launched and looked at, on real hardware, by a human. A screenshot or recording exists. |
| `Experimental` | Launched and looked at, but with known gaps — a sub-case was not tried, or it was tried once and not thoroughly. |
| `Protocol-compatible but unvalidated` | The terminal advertises Kitty graphics and has a profile (or matches the generic one), but nobody has launched md-viewer in it and looked. This is a perfectly good, honest release state. |
| `Unsupported` | Known not to work — it does not implement what is needed, or someone tried and it visibly failed. |

**Detection evidence is not validation.** Nothing is promoted to `Supported`
because an environment variable matched, because the protocol is technically
compatible, or because a headless test passed. Only what a human watched happen on
a real screen earns it — three graphical defects this project has shipped and
fixed were each invisible to every headless test that existed at the time.

## Per-terminal status

| Terminal | Status | Evidence |
|---|---|---|
| iTerm2 3.5+ | `Supported` for image rendering and the drag-highlight overlay | Operator-driven, 2026-08-07. The rest of the feature set is `Protocol-compatible but unvalidated`. |
| Kitty | `Supported` for the drag-highlight overlay | Operator-driven, 2026-08-08, across repeated drags. |
| Ghostty 1.3.1 | `Supported` for the drag-highlight overlay | Operator-driven, 2026-08-08, across repeated drags. |
| WezTerm | `Supported` for image rendering; the overlay is deliberately **off** | See below. |
| Warp | `Protocol-compatible but unvalidated` | Never launched. Its Kitty-graphics support is newer than the others'. |

Most of md-viewer's placement and occlusion behavior — the notification cut-out,
the atomic placement swap, tabpage teardown — is covered by headless tests only.

macOS Terminal.app does not implement the Kitty graphics protocol, has no profile,
and `image.backend = "auto"` correctly degrades to the `cells` text-only fallback
there.

## The drag-highlight overlay

While the mouse is down, a selection can be painted as translucent rectangles
composited over the image already on screen, instead of re-photographing the
headless page every frame. It is enabled only where a human confirmed it in a live
terminal — today **iTerm2, Kitty, and Ghostty**. Everywhere else a drag keeps the
full-frame capture path, which stays correct and is merely slower.

`interaction.selection_overlay` (`"auto"` / `"on"` / `"off"`) overrides that.
`"on"` is how you would qualify your own terminal; read the option's notes in
`lua/md-viewer/config.lua` first, and do it on a machine you can afford to lose —
a terminal that cannot do this may degrade badly rather than gracefully.

One precondition no setting overrides: the terminal must report its pixel cell
size. Overlay rectangles are sized in pixels, and without that there is no way to
know what a pixel is worth on screen.

## WezTerm

Image rendering works and is `Supported`. The drag-highlight overlay is
deliberately disabled, on cost rather than correctness: its geometry there is
solved and was photographed correct on two builds, but sustained Kitty placement
replacement grows WezTerm's resident memory without bound. That is an upstream
defect ([wezterm#7953](https://github.com/wezterm/wezterm/issues/7953)); a fix is
proposed in [wezterm#8035](https://github.com/wezterm/wezterm/pull/8035), still
open and unmerged as of 2026-08-09.

You need do nothing to be safe — WezTerm already gets the full-frame capture path
by default, which is correct. **Do not set `interaction.selection_overlay = "on"`
there**: it will draw correctly and exhaust your memory.

Re-enabling is not automatic and is not a version check. It requires a *released*
WezTerm build carrying the fix, then a passing run of both
`scripts/overlay/geometry` and `scripts/overlay/stress` against it. See
[development.md](development.md#qualifying-a-terminal).

## Multiplexers

tmux, screen, and Zellij are **not supported and not advertised**. No
escape-sequence passthrough is implemented for any of them. `:MdViewerHealth`
detects a multiplexer and reports it so the failure mode is diagnosable, and that
is the entire extent of multiplexer support. A multiplexer that does not propagate
the terminal's pixel cell size also disables the overlay.

## Sub-cell alignment

Some terminals apply their horizontal window margin to text but not to graphics
placements, drawing the image a fraction of a cell toward the origin. The visible
symptom is a thin gap or overhang beside a notification floating over the preview.
iTerm2 is the one terminal where this has been measured; whether others share it
is unknown, and it cannot be inferred from the protocol specification.

`image.raw_overlay_bleed_cells` (default `1`) absorbs the gap by cutting one extra
column past the notification's trailing edge. `image.raw_cell_offset_px` cancels
the shift outright on a terminal that implements the protocol's `X`/`Y` placement
keys. See [troubleshooting.md](troubleshooting.md) for how to measure and set it,
and [development.md](development.md#sub-cell-calibration) for the per-terminal
calibration record.

## Reporting a terminal

Open an issue with `:MdViewerDebug` output, the terminal name and version, OS,
`TERM`/`TERM_PROGRAM`, Neovim version, and whether HiDPI scaling is active, plus a
screenshot for anything visual. Confirm the behavior reproduces outside any
multiplexer before filing it as a graphics bug.
