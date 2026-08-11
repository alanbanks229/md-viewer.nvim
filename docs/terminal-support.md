# Terminal support

**This is the evidence record behind each terminal's status — what was watched,
by whom, and when.** If you only want to know whether your terminal works, the
[README's table](../README.md#terminal-support) answers that in five rows. Read
this one before promoting a terminal, qualifying a new one, or arguing that a
claim here is too weak or too strong.

md-viewer's graphical preview needs a terminal that advertises the Kitty graphics
protocol, used without a multiplexer. Kitty.app and the `kitty`/`kitten`
executables are not required — any terminal speaking the protocol works.

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
| iTerm2 3.5+ | `Supported` for image rendering and the drag-highlight overlay; client-driven animation rides the same machinery | Operator-driven, 2026-08-07. The rest of the feature set is `Protocol-compatible but unvalidated`. |
| Kitty | `Supported` for the drag-highlight overlay; client-driven animation rides the same machinery | Operator-driven, 2026-08-08, across repeated drags. |
| Ghostty 1.3.1 | `Supported` for the drag-highlight overlay; client-driven animation rides the same machinery | Operator-driven, 2026-08-08, across repeated drags. |
| WezTerm | `Supported` for image rendering; the overlay **and animation** are deliberately off | See below. |
| Warp | `Experimental` for image rendering; the drag-highlight overlay and animation are off | Operator-driven, 2026-08-11, macOS. Launched, looked at, and two defects found — see below. |

## Animated images

Playback is off by default (`render.animate = false`), and with it off the
still first frame the screenshot captured is what shows — the table below
describes what happens once it is turned on. Two playback strategies exist,
selected per profile and overridable with `terminal.animation`:

| Strategy | What it is | Status |
|---|---|---|
| `frames` (client-driven) | A shared Neovim timer swaps natural-size frame placements — the same operation as an overlay crop, one placement diff per frame shown. | The default on iTerm2, Kitty and Ghostty, riding the overlay qualification above. |
| `native` (terminal-driven) | The Kitty graphics protocol's animation extension (`a=f` frame data, `a=a` playback control): frames upload once with their own gaps and the terminal owns every tick. | `Protocol-compatible but unvalidated`, everywhere — including Kitty itself, whose spec defines the extension. Implemented and covered by golden escape-sequence tests; not yet watched on hardware. |

To qualify `native` on a terminal: run the checklist in `scripts/animation/`
in that terminal, watch it, and if it holds, set `terminal.animation =
"native"` — and open an issue or PR with what you saw so the profile default
can carry the evidence. Nothing here is promoted on protocol compatibility
alone: implementing placements says nothing about implementing the player.

WezTerm's exclusion is the overlay's, and firmer: wezterm/wezterm#7953
duplicates a covered cell's attachment list on every repeat placement — per
placement, not per second, so a slower swap rate does not make it safe. A
preview stays open far longer than a drag. Re-qualify with
`scripts/animation/` once a fixed build ships.

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
`:MdViewerHealth` warns while the overlay is forced onto a profile that is not
validated for it, and `:MdViewerDebug`'s `overlay` line marks it `(forced)`,
because the failure does not look like a setting.

Two terminals have now been through that qualification and failed, for different
reasons: **WezTerm** on cost (below) and **Warp** on correctness (below).

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

## Warp

Image rendering works. Warp was launched and watched on macOS on 2026-08-11 —
the first time anyone had — and it moved from `Protocol-compatible but
unvalidated` to `Experimental` rather than to `Supported`, because looking at it
turned up two defects. Both are now fixed or worked around, and one of them is
not md-viewer's to fix.

**Preview text rendered about twice its configured size.** That one was ours.
`coordinates.cell_metrics` divided the cell measured from `TIOCGWINSZ` by
`render.device_scale_factor` unconditionally, which assumes both that the
terminal fills `ws_xpixel` with device pixels and that the display really is
that many times logical. Where either is false the CSS viewport comes out half
size, the terminal scales the PNG up into the cells regardless, and every glyph
doubles. It now tries both divisors and keeps the one that yields a cell a font
could plausibly have; `:MdViewerHealth` reports which it chose under `cell
unit`. Nothing about this is Warp-specific — a 1x display left on the default
`device_scale_factor` of 2 produced the identical symptom.

**A Neovim Visual selection over the preview blanked the image.** Half ours. The
way *into* Visual mode was ours: Warp reports a modified left-drag that
md-viewer had not mapped, so it fell through to Vim's default, which is a
blockwise Visual selection. That is fixed by mapping every modifier combination
of every mouse gesture. But the blanking itself is Warp: this backend places at
`z = -3`, and the Kitty specification puts only `z < INT32_MIN/2` beneath a
non-default cell background, so a Visual highlight should composite *over* the
image rather than replace it. md-viewer no longer depends on that being right —
it keeps Neovim out of Visual mode over the surface, and paints the highlight
with `blend = 100` for the frame before the guard fires.

**The drag-highlight overlay was qualified here and failed.** Forced on with
`interaction.selection_overlay = "on"`, every overlay rectangle drew far larger
than the crop asked for: a one-glyph caret block covered most of the preview,
anchored at its own placement cell and running to the edge of the split.
Photographed twice on 2026-08-11.

An overlay rectangle is a crop taken out of a viewport-sized tint sheet, placed
with no `c`/`r` keys so it draws at natural pixel size and positioned with the
`x`/`y`/`w`/`h` crop keys. Warp does not honour those the way the specification
describes. The obvious workaround — upload a sheet sized to each rectangle
instead of cropping one shared sheet — would mean an upload per rectangle per
frame, which is the entire cost the overlay exists to avoid, so this is off
rather than re-encoded the way WezTerm's sub-cell offset was.

If you have set `interaction.selection_overlay = "on"` and the caret or the drag
highlight appears as a large grey block, that is this. Remove the override.

Three upstream issues bound what is possible here, all open as of 2026-08-11:

- [warp#7789](https://github.com/warpdotdev/Warp/issues/7789) — Warp ignores
  Kitty placement ids, so re-placing the same image id and placement id does not
  replace the previous placement. This is why the drag-highlight overlay stays
  off: overlay rectangles are replaced in place on every frame, and without
  placement-id semantics each replacement needs an explicit delete first, which
  is exactly the blank frame the overlay exists to avoid.
- [warp#12058](https://github.com/warpdotdev/Warp/issues/12058) — Kitty graphics
  images reported as not rendering in terminal applications.
- [warp#13737](https://github.com/warpdotdev/Warp/issues/13737) — no support for
  the graphics protocol's animation extension. Animation is `off` for Warp
  anyway, on the profile's own conservative default.

If you see the image blank under a Visual highlight despite the guard,
`image.raw_zindex = 1` places above the text layer instead and is immune to any
cell repaint. It is an experimental workaround, not a default: a positive
z-index inverts the model the rest of this backend is written against, and it
will cover a float that opens over the preview before a cut-out is computed for
it.

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
