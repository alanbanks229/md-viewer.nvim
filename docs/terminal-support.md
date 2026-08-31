# Terminal support

md-viewer's graphical preview needs a terminal that speaks the Kitty graphics
protocol, used without a multiplexer. Kitty.app and the `kitty`/`kitten`
executables are not required — any terminal implementing the protocol works.

`:MdViewerHealth` says what was detected and why; `:MdViewerDebug` adds the
per-terminal capability detail.

## Status

| Terminal | Preview | Selection overlay | Animation | Resident mode |
|---|---|---|---|---|
| iTerm2 3.5+ | Supported | Supported | Supported | Off — [measured incorrect](#iterm2) |
| Kitty | Supported | Supported | Supported | Permitted, unvalidated |
| Ghostty 1.3.1 | Supported | Supported | Supported | Permitted, unvalidated |
| WezTerm | Supported | Off — [upstream memory defect](#wezterm) | Off, same cause | Off, same cause |
| Warp | Experimental | Off — [upstream defects](#warp) | Off | Permitted, unvalidated |
| macOS Terminal.app | Text-only `cells` fallback | — | — | — |
| Anything else speaking the protocol | Should work, unvalidated | Off by default | Off by default | Permitted, unvalidated |

Resident mode is experimental and off by default everywhere
(`image.resident = "off"`); the column says whether the terminal would be
allowed to take that path at all if you turned it on. Where it reads *Off*, a
preview silently keeps the ordinary per-scroll path and `:MdViewerDebug`'s
`render_path_reason` says so.

**Supported** means a human launched it and watched it on real hardware —
iTerm2 2026-08-07, Kitty and Ghostty 2026-08-08, Warp 2026-08-11.
**Experimental** means the same, with known gaps. Nothing is promoted because an
environment variable matched or a headless test passed: three graphical defects
this project has fixed were invisible to every headless test that existed at the
time. A terminal nobody has watched is left unvalidated rather than assumed
working, which is an honest state, not a broken one.

Where the overlay or animation is off, the feature still works — it just takes
the slower, always-correct path.

## Detection

Each terminal is identified from its own native variable (`TERM_PROGRAM`,
`KITTY_WINDOW_ID`, `WEZTERM_EXECUTABLE`, `GHOSTTY_RESOURCES_DIR`, `WARP_*`),
none of which SSH forwards. iTerm2 and WezTerm also export `LC_TERMINAL`, which
OpenSSH *can* carry — but only where the client's `SendEnv` and the server's
`AcceptEnv` both allow it, which most distributions ship but upstream OpenSSH
does not. Where that holds, those two identify themselves on remote hosts.
Everything else needs `MD_VIEWER_TERMINAL_PROFILE` set on the remote host — see
[ssh.md](ssh.md#make-your-terminal-identifiable) for the configuration and
[troubleshooting.md](troubleshooting.md#the-preview-falls-back-to-text-over-ssh)
for the symptom.

`LC_TERMINAL` is ranked below every native variable and ignored when another
terminal has set `TERM_PROGRAM`, because it is inherited: a VS Code window
launched from iTerm2 carries a stale `LC_TERMINAL=iTerm2` into a terminal with
no graphics support at all.

## The selection-highlight overlay

While a `v`/`V` selection is being extended, it can be painted as translucent
rectangles over the image already on screen instead of re-photographing the page
every frame. It is on only where a human confirmed it live. Everywhere else the
selection still works and simply re-captures.

`interaction.selection_overlay` (`"auto"` / `"on"` / `"off"`) overrides that, and
`"on"` is how you would qualify your own terminal — read the option's notes in
`lua/md-viewer/config.lua` first and do it somewhere you can afford to lose, as a
terminal that cannot do this may degrade badly. The terminal must report its
pixel cell size; no setting works around that.

## Animated images

Off by default (`render.animate = false`), showing the still frame the screenshot
captured. Two playback strategies exist, selected per profile and overridable
with `terminal.animation`:

| Strategy | What it is | Status |
|---|---|---|
| `frames` | A Neovim timer swaps frame placements — one placement diff per frame. | Default on iTerm2, Kitty and Ghostty. |
| `native` | The protocol's own animation extension: frames upload once and the terminal owns every tick. | Implemented and covered by escape-sequence tests, but unvalidated on hardware everywhere — including Kitty, whose spec defines it. |

To qualify `native`, run the checklist in `scripts/animation/` in that terminal,
watch it, and if it holds set `terminal.animation = "native"` and open an issue
with what you saw. Implementing placements says nothing about implementing a
player.

## Local rendering

`render.location = "local"` changes which machine draws, not the escape
sequences drawn. It is nonetheless unvalidated on every terminal, because local
injection inverts the upload timing and byte-correct sequences can still misdraw
under timing a terminal did not expect. What has been validated is the transport
itself — topology and 10,000-marker transit integrity over LAN SSH, zero loss and
zero reorder, 2026-08-26 — which is evidence about the pipe, not about any
terminal's compositor.

## iTerm2

Preview rendering, the selection overlay and animation are all supported and
operator-validated (2026-08-07).

Resident mode is the exception, and it is off on measurement rather than on
caution: re-cropping a resident image was seen drawing the wrong position over
a real AWS SSM link (2026-08-26), with the placements and uploaded pixels
verified correct — so the defect sits on the terminal side, and there is no
upstream issue to cite yet. Selection-overlay placements are smaller, less
frequent, not implicated, and stay on. Previews fall back to the per-scroll
path, which is unaffected.

## WezTerm

Preview rendering is fully supported. The overlay and animation are off on cost,
not correctness: overlay geometry was photographed correct on two builds, but
sustained Kitty placement replacement grows WezTerm's resident memory without
bound ([wezterm#7953](https://github.com/wezterm/wezterm/issues/7953); fix
proposed in [wezterm#8035](https://github.com/wezterm/wezterm/pull/8035), open as
of 2026-08-09).

You need do nothing — the default path is already the safe one. **Do not set
`interaction.selection_overlay = "on"` here**: it draws correctly and exhausts
your memory. Re-enabling needs a released build with the fix plus passing runs of
`scripts/overlay/geometry` and `scripts/overlay/stress`.

## Warp

Preview rendering works, which is why the status is `Experimental` rather than
unvalidated. Three upstream defects bound what is possible, all open as of
2026-08-11:

- [warp#7789](https://github.com/warpdotdev/Warp/issues/7789) — placement ids are
  ignored, so re-placing an image does not replace the previous placement. This
  is why the overlay is off: each replacement would need an explicit delete
  first, which is the blank frame the overlay exists to avoid.
- [warp#12058](https://github.com/warpdotdev/Warp/issues/12058) — Kitty graphics
  images reported as not rendering in terminal applications.
- [warp#13737](https://github.com/warpdotdev/Warp/issues/13737) — no support for
  the animation extension.

Forcing `interaction.selection_overlay = "on"` here draws every rectangle far
larger than its crop — a one-glyph caret covers most of the preview. Warp does
not honour the `x`/`y`/`w`/`h` crop keys as specified. If you see a large grey
block, that is this; remove the override.

If a Neovim Visual highlight blanks the image, `image.raw_zindex = 1` places
above the text layer instead and is immune to any cell repaint. It is an
experimental workaround: a positive z-index inverts the model this backend is
written against, and it will cover a float opened over the preview.

## Multiplexers

tmux, screen, and Zellij are **not supported**. No escape-sequence passthrough is
implemented for any of them. `:MdViewerHealth` detects a multiplexer and reports
it so the failure is diagnosable, and that is the whole of it. A multiplexer that
does not propagate the terminal's pixel cell size also disables the overlay.

## Sub-cell alignment

Some terminals apply their horizontal window margin to text but not to graphics,
drawing the image a fraction of a cell toward the origin. The symptom is a thin
gap or overhang beside a notification floating over the preview. iTerm2 is the
one terminal where this has been measured.

`image.raw_overlay_bleed_cells` (default `1`) absorbs the gap;
`image.raw_cell_offset_px` cancels the shift outright where the terminal
implements the protocol's `X`/`Y` placement keys.
[troubleshooting.md](troubleshooting.md) has how to measure it.

## Reporting a terminal

Open an issue with `:MdViewerDebug` output, the terminal name and version, OS,
`TERM`/`TERM_PROGRAM`, Neovim version, and whether HiDPI scaling is active, plus
a screenshot for anything visual. Confirm it reproduces outside any multiplexer
first.
