# Manual compatibility testing

This is the repeatable procedure for validating md-viewer.nvim on real
terminal hardware. Headless automation (the Lua and Node test suites) proves
the request/response plumbing, staleness handling, sanitization, and geometry
math are correct; it cannot observe actual terminal compositing, Kitty
graphics rendering, flicker, or where a real mouse click lands. Only this
procedure, run by a human looking at a real terminal, can do that.

## Before you start

- Run the automated suite first and confirm it is green:

  ```sh
  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
  NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
  npm test --prefix renderer
  ```

  Do not start manual testing against a red tree — every failure you find
  manually needs to be attributable to the terminal, not to a known-broken
  build.
- Use `tests/fixtures/kitchen-sink.md` as the source document, open outside
  tmux/screen/Zellij (see "Multiplexers" below), with `image.backend =
  "kitty_raw"` set explicitly so a silent fallback to `cells` cannot be
  mistaken for a passing graphical test.
- Record the exact terminal name and version, OS, `TERM`/`TERM_PROGRAM`,
  Neovim version, and whether HiDPI/Retina scaling is active, alongside every
  result below. A result with no environment recorded is not usable evidence.
- Attach a screenshot for anything visual. For alignment/bleed-through rows, a
  screenshot is the *only* acceptable evidence — do not guess from the
  protocol specification (see "Passive-overlay alignment" below for exactly
  why).

## How to record a result

Every cell in every table uses exactly one of these four labels. Do not
invent others, and do not soften them.

| Label | Meaning |
|---|---|
| `Supported` | Actually launched and looked at, on real hardware, by a human. A screenshot or terminal recording exists. |
| `Experimental` | Partially verified — it was launched and looked at, but with known gaps (a sub-case wasn't tried, or it was tried once and not thoroughly). |
| `Protocol-compatible but unvalidated` | The terminal advertises Kitty-graphics support and md-viewer's `terminal.lua` has a profile for it (or it matches the generic Kitty profile), but nobody has actually launched md-viewer in it and looked. This is a perfectly good, honest release state. |
| `Unsupported` | Known not to work — either the terminal doesn't implement what's needed, or someone tried and it visibly failed. |

**Never mark a cell `Supported` on the strength of an environment variable
matching, a protocol capability being technically compatible, or a headless
test passing.** Those are all necessary-but-not-sufficient signals. Only what
a human actually watched happen on a real screen earns `Supported`.

## The five terminals

| Terminal | Status as of this document |
|---|---|
| iTerm2 3.5+ | See the matrix below — a subset of scenarios (basic PNG rendering only, from Parts 1–2) has real historical confirmation; everything from Part 3 onward (click, selection, search, the placement/notification fixes) is unvalidated. See "What has actually been confirmed, and what has not" below before trusting any `Supported` cell. |
| Kitty | The drag-highlight overlay is operator-validated (2026-08-08), across repeated drags. Everything else is `Protocol-compatible but unvalidated`. |
| WezTerm | Basic PNG rendering has real historical confirmation from Part 2 (see below); everything since is unvalidated, same caveat as iTerm2. The drag-highlight overlay is **off, on cost grounds**: its geometry was photographed correct on both `20240203-110809-5046fc22` and `20260805-104032-4b1c3c15` (42 of 42 pixel assertions each) using the `sheet-margin` encoding md-viewer sends WezTerm alone, but sustained placement traffic grows the terminal's resident memory without bound — 172 MB to 786 MB in four seconds with four rectangles at 40fps. Drags therefore keep the full-frame capture path, which is correct and merely slower. The 2026-08-07 crash (issue #6344) is unreachable from md-viewer regardless. See the 2026-08-08 section in `docs/cross-platform-implementation-status.md`. |
| Ghostty | The drag-highlight overlay is operator-validated (1.3.1, 2026-08-08). Everything else is `Protocol-compatible but unvalidated`. |
| Warp | `Protocol-compatible but unvalidated` for everything. Never launched. Warp's own Kitty-graphics support is newer and less established than the other four; if it fails outright, that is useful information — record it as `Unsupported` with what specifically broke, not as a bug in md-viewer. |

macOS Terminal.app is not in this matrix: it does not implement the Kitty
graphics protocol at all, `terminal.lua` has no profile for it, and
`image.backend = "auto"` correctly and honestly degrades to the `cells`
text-only fallback. That is confirmed, expected behavior, not a gap to close.

### What has actually been confirmed, and what has not

Two operator sessions, both predating Part 3 (the interaction transport),
confirmed real rendering on real hardware:

- **iTerm2**: the preview renders correctly with no hand-tuned
  `render.cell_aspect_ratio`/`estimated_cell_width_px` and no
  `browser.executable_path` override.
- **WezTerm**: the same, with WezTerm's own profile inference and the
  `estimated` calibration tier's defaults holding up.

Both of those are **historical and scope-limited**. They confirm that a PNG
appears at roughly the right size and position, on the code as it existed at
the end of Part 2. They do **not** confirm anything added since: click
handling, drag-to-select, word/paragraph selection, search, copy, link
activation, the atomic placement-swap fix for the roll/blink bug, the
passive-overlay cutout that keeps a notification opaque, or the sub-cell
`raw_cell_offset_px`/`raw_overlay_bleed_cells` calibration — every one of
those was written and headlessly tested with **no graphical validation at
all**, on any terminal (see `docs/cross-platform-implementation-status.md`'s
seven "Post-Part-6 follow-up" sections, each of which says so explicitly).
Do not read "iTerm2: confirmed working" from Part 2 as covering any of Part
7's own subject matter.

## Scenario matrix

Run every row below in each terminal you actually have access to. Leave a
row `Protocol-compatible but unvalidated` rather than guessing.

| Scenario | iTerm2 | Kitty | WezTerm | Ghostty | Warp |
|---|---|---|---|---|---|
| Initial image renders at the correct size/position | Protocol-compatible but unvalidated¹ | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated¹ | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Live preview on unsaved edits (no `:w`) | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Source-to-preview cursor following | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Keyboard scrolling (`j/k`, `Ctrl-d/u`, `Ctrl-f/b`, `gg/G`) | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Mouse-wheel scrolling (only over the preview) | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Click-to-deselect (plain click clears a highlight; never moves the source cursor)² | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Exact source-column reporting on ctrl/cmd-click (ASCII and multibyte: `日本語`, emoji) | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Line-level precision fallback (content the parser can't give an exact column for) | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Forward drag-to-select | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Backward (reverse) drag-to-select | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Multi-paragraph selection | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Instant drag highlight (overlay rectangles, not a re-captured frame)⁴ | Supported | Supported | Unsupported — crashed the probe | Supported | Protocol-compatible but unvalidated |
| Repeated drags stay instant (the overlay is not overtaken by the base image)⁴ | Supported | Supported | Unsupported | Supported | Protocol-compatible but unvalidated |
| Double-click word selection | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Triple-click paragraph selection | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Copying a selection (`y` / `:MdViewerCopy`, both registers) | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Search (`:MdViewerFind`, `n`/`N`, match highlighting) | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Link activation (ctrl/cmd-click: http/https, mailto, local file, fragment) | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Local Markdown link opens in Neovim in the source window, preview follows, `<C-o>` returns | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Link to a nonexistent file reports *does not exist*, not *outside the document root* | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Repo-relative link from a document in a subdirectory (`../README.md`) resolves | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| An external (`http`/`https`) link opens in the system browser, or says why it did not | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| A short inline link (one word, at the start of a line) is clickable at the terminal's default font size | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| `H` (or `:MdViewerBack`) returns the preview and the source window to the previous document | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| `L` (or `:MdViewerForward`) retraces it, and `<C-o>` brings the preview back on its own | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Terminal window resize | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Terminal font-size change | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Split position: right | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Split position: left | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Split position: above | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Split position: below | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Winbar does not overlap the image | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Statusline does not overlap the image | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Global statusline (`laststatus=3`) does not overlap the image | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Focusable floating window occludes the image; closing it restores | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Passive overlay (notification) is opaque, no Markdown showing through³ | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| No roll/blink when a passive overlay appears or disappears³ | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Tab switch away and back | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| A plugin that opens its own tabpage (e.g. `:tabnew`-based UIs) does not leave a stranded image | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Suspend (`Ctrl-z`) and resume (`fg`) | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| HiDPI/Retina display | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Standard-DPI display | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| No flicker during normal scrolling/typing | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Cleanup: close/reopen repeatedly leaves no stray placements | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |
| Cleanup: `:qa` leaves no image, no Node/Chromium process | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated | Protocol-compatible but unvalidated |

¹ Basic image rendering only (no interaction) has a real, historical Part-2
confirmation on this terminal — see above. Re-verify anyway: several
placement-path changes have landed since without any graphical check.
² Replaces the "click-to-source" scenario from earlier drafts of this
document. Clicking the preview no longer moves the source cursor under any
gesture — see "Post-Part-6 follow-up: click-to-source removed" in
`docs/cross-platform-implementation-status.md`.
³ These two rows are the two bugs `image.raw_overlay_bleed_cells` and the
atomic placement-swap fix exist for (Post-Part-6 follow-ups 3, 6, and 7).
Neither has been graphically confirmed on any terminal.
⁴ The only two `Supported` rows in this document, and the only ones an
operator drove by hand and watched: iTerm2 on 2026-08-07 (stage 4) and
Ghostty 1.3.1 on 2026-08-08 (stage 6). The second row is separate on purpose —
it is the defect that made Ghostty look like it worked. The base image and
the overlay shared a z-index, the protocol breaks that tie by image id, and
md-viewer re-uploads the base on every full frame, so the highlight was
overtaken after exactly one drag while every placement still reported
success. A terminal that passes row 1 has not passed row 2; drag three times.

## Passive-overlay alignment (per terminal)

Post-Part-6 follow-up 7 found, on real iTerm2 hardware, that the raw image
lands about half a cell left and up of the text grid — iTerm2 applies its
window margin to text but not to graphics placements. `raw_cell_offset_px`
and `raw_overlay_bleed_cells` exist because of that one measurement. Whether
any of the other four terminals has the same quirk is **unknown** — this is
not something that can be inferred from the Kitty graphics protocol
specification; the whole reason the iTerm2 bug was found this late is that
the spec gave no reason to expect it.

Two questions, per terminal:

1. **Does it implement the Kitty protocol's `X`/`Y` placement keys at all?**
   Set `image.raw_cell_offset_px = { x = 10 }`, open a notification over the
   preview, and look. If the image visibly shifts, it implements the keys —
   record the offset that actually closes the gap for that terminal. If
   nothing changes, record `X`/`Y` as unimplemented there, and rely on
   `raw_overlay_bleed_cells` alone (it is on by default for exactly this
   reason).
2. **Is the offset a fixed window margin, or does it scale with cell width?**
   iTerm2 measured at 10px of a 20px cell — exactly half — so a constant-10px
   theory and a half-a-cell theory are indistinguishable from that one
   measurement alone. Change the terminal's font size once and re-measure. If
   the offset changes proportionally to the new cell width, `raw_cell_offset_px`
   is the wrong shape for this API — it should express a fraction of a cell,
   not raw pixels — and that has to be decided before `v0.3.0` freezes the
   option, not after.

The measurement itself is a screenshot, not a calculation: compare the x
coordinate of the image's edge against the x coordinate of the notification's
edge in the image. Record results here:

| Terminal | Implements `X`/`Y`? | Measured offset | Constant or scales with cell width? | Notes |
|---|---|---|---|---|
| iTerm2 | Yes (measured) | ~10px of a 20px cell (horizontal only; vertical measured exact) | Undetermined — one measurement only, see question 2 above | The only terminal measured at all. `raw_cell_offset_px`/`raw_overlay_bleed_cells` ship with `v0.3.0` on the strength of this single measurement. |
| Kitty | Unmeasured | — | — | |
| WezTerm | Yes, but applied to *every* cell of a placement rather than the first, and as an inset: each cell paints `cell - X` px. Measured 2026-08-08 on both `20240203-110809-5046fc22` and `20260805-104032-4b1c3c15`, which are identical here. | None needed: the content origin and the graphics origin coincide, so `raw_cell_offset_px` stays 0. | n/a | md-viewer therefore sends WezTerm no `X`/`Y` keys at all — see `overlay_encoding = "sheet-margin"`. Photographs: `docs/stage6-wezterm/`. |
| Ghostty | Unmeasured | — | — | |
| Warp | Unmeasured | — | — | |

**The pixels-vs-fraction decision, as shipped in `v0.3.0`:** `raw_cell_offset_px`
ships as pixels, unchanged, because the one measurement available (iTerm2)
cannot distinguish the two theories and there is no second data point to
decide with. This is recorded as open future work, not resolved — see
`docs/cross-platform-implementation-status.md`'s Part 7 section. Whoever next
has access to a second terminal, or an iTerm2 session across two font sizes,
should settle it before adding a second terminal's calibration numbers to the
table above; changing the option's shape after that would be a breaking
config change.

## Multiplexers

tmux, screen, and Zellij are **not supported and not advertised**. md-viewer
does not implement Kitty graphics passthrough for any of them. `terminal.lua`
detects a multiplexer and reports it in `:MdViewerHealth`'s `multiplexer`
field so a user inside one gets an honest diagnosis rather than a silent
failure or bogus visual, but no code path attempts to make graphics work
inside one. Do not add a `Supported`/`Experimental` row for a multiplexer
without first actually implementing and testing escape-sequence passthrough —
detecting and warning is the whole extent of the current work.

## What a `Protocol-compatible but unvalidated` row actually means

`terminal.lua` recognizes each of these five terminals by environment
variable and/or a real Kitty graphics protocol probe (gated by
`terminal.probe`), and every one of them advertises Kitty-compatible
graphics. That is real, tested (headlessly) evidence that md-viewer *should*
work. It is not evidence that it *does*: an environment-variable match is not
validation (policy §4), and several of the graphical bugs this project has
already shipped and fixed (the placement roll, the notification
bleed-through, the sub-cell misalignment) were each invisible to every
headless test that existed at the time and were found only because an
operator was looking at a real screen. Treat every unvalidated row as exactly
that — plausible, untested, and capable of hiding a bug the same shape as the
last three.
