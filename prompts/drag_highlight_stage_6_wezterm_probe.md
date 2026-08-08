# Stage 6 — Re-Probe and Support WezTerm Selection Overlays

> Read `prompts/00-policy.md` first. §4 (honesty) is the load-bearing one here:
> the output of this work is a *finding*, and "it looked fine when I dragged
> once" is not one. Either the checks below pass on a named build, or that build
> must use a compatibility path that passes the same correctness checks.
>
> **The goal of this stage is no longer to qualify only a current WezTerm
> nightly. Treat both `20240203-110809-5046fc22` and current WezTerm builds as
> support targets. Do not remove support for the old stable simply because
> upstream fixed its defects later. Where necessary, adapt md-viewer around
> known WezTerm behavior or select an existing safe fallback automatically.**

## Why this is being re-opened

Stage 4's step-1 probe (2026-08-07) recorded two failures in WezTerm: natural-size
placements did not render where they were placed, and the terminal **crashed**
when the placement churn began. That was enough to disqualify the raw overlay
profile as implemented at the time. But the record was thin on *why*, and both
halves now have a named cause in upstream source:

1. **The crash.** The probe ran against `20240203-110809-5046fc22` — the
   February 2024 stable. Upstream issue **#6344** ("Crash on zero-height kitty
   graphic": a divide-by-zero in `assign_image_to_cells` that "causes the
   terminal to crash, and all is lost") was filed in November 2024 and fixed
   afterwards. The guards it added — refusing a placement when the pty reports
   no cell pixel size, and when the drawable region is zero — live in exactly
   the function every overlay rectangle goes through.

   **Do not treat that upstream fix as permission to abandon the stable build.**
   Determine whether md-viewer can enforce equivalent preconditions on its side
   and therefore avoid ever sending the old build a placement that can reach
   the known crash condition. If that can be done conservatively, implement and
   test it.

2. **The geometry.** WezTerm does not place images freely; it slices a placement
   into per-cell fragments and attaches them to text cells
   (`term/src/terminalstate/image.rs`, `assign_image_to_cells`). It parses the
   `X`/`Y` sub-cell offsets we depend on — into `cell_padding_left` /
   `cell_padding_top` — but then passes the *same* padding to every cell of the
   placement, where the protocol specifies the offset applies to the first cell
   only. The per-cell texture slice (`x_delta`) is computed without accounting
   for it. **Prediction: a highlight bar wider than one cell draws as a comb of**
   **inset stripes, with an unpainted gap of** **`X`** **pixels at the left of every**
   **cell.** That is a specific, falsifiable claim, and check 3 below is
   designed to settle it.

   **If this prediction is confirmed on an affected WezTerm build, do not stop
   at "unsupported." First determine whether md-viewer can avoid exercising the
   broken geometry.** In particular, investigate whether the rectangle can be
   expressed using placements whose sub-cell offsets are valid under WezTerm's
   implementation — for example by separating a leading partial-cell fragment
   from cell-aligned interior coverage, splitting placements at cell
   boundaries, or another equivalently bounded WezTerm-specific encoding.

   Do not assume those examples are correct merely because they are suggested
   here. Inspect the existing renderer and protocol behavior, derive the
   smallest correct workaround, and validate it eyes-on-glass.

There is also a cost asymmetry worth knowing before reading any timing: each
placement rewrites every cell it covers and bumps the line sequence number, and
each deletion walks those rows again over the full line width. An overlay frame
of 60–80 rectangles is therefore O(rows × cols) cell mutations twice over, where
iTerm2 and Ghostty take a GPU placement each.

A compatibility workaround must therefore be evaluated for both **correctness
and cost**. Do not turn one rectangle into an unbounded number of placements
without measuring what that does during real drag churn.

## Goal and compatibility policy

At the end of this stage, a WezTerm user should not need to know which graphics
path is required for their build.

The desired behavior is:

```text
WezTerm 20240203 stable
        ↓
safe, correct md-viewer selection behavior
        ↓
raw overlay if it can be made correct
otherwise automatic WezTerm compatibility path / damage band

Current WezTerm
        ↓
safe, correct md-viewer selection behavior
        ↓
raw overlay when qualified
otherwise the same safe fallback
```

Prefer the raw graphics overlay where it is correct and performant, but **the
user-visible feature is the support contract, not the particular implementation
mechanism**.

Do not globally weaken or complicate the Kitty path for terminals that already
behave correctly. Any workaround for WezTerm's implementation must be narrowly
scoped.

Do not require users to manually choose between "old WezTerm" and "new WezTerm"
modes if md-viewer can reliably make that decision itself.

## What has already been fixed for it

Three defects found while fixing Ghostty were not Ghostty-specific and are
already in the tree. Do not re-derive them:

* The base image and the overlay can no longer share a z-index. Every
  Kitty-protocol profile draws its base at -2 and the overlay at -1
  (`resolve_layers` in `lua/md-viewer/backends/kitty_raw.lua`).
* Tint sheets are allocated from an id range above every base image id, so the
  protocol's own same-z tie-break (lower image id draws underneath) points the
  right way.
* `:MdViewerHealth` now reports `raw graphics overlay supported` / `reason` /
  `zindex` / `cell pixels`. Before this, a terminal drawing the highlight
  underneath the base looked identical to one falling back to full captures.

## Procedure

Run the visual steps in real WezTerm windows, by hand.
`scripts/stage4-live/drive.lua` drives the real input layer against real Chromium
and is the right harness for checks 4–6, but it fakes the terminal byte sink, so
it can prove *what md-viewer sends* and never *what WezTerm draws*. Checks 2 and
3 are eyes-on-glass.

Where practical, perform the qualification against **both**:

* `20240203-110809-5046fc22`
* a current WezTerm nightly

If implementation changes are required between those builds, keep the behaviors
separable enough that each can be tested independently.

**Step 0 — name both builds.** Record the exact version string of the existing
stable build and the exact version string of the current nightly used for
comparison. A finding against only one of them is not sufficient to declare the
other supported or unsupported.

The stable build is specifically part of this stage because md-viewer should
attempt to support users who have not moved to nightly.

**Step 1 — can the cell even be measured?** Open a preview on each build, run
`:MdViewerHealth`, and read `raw graphics cell pixels`. If it is unmeasured,
the raw overlay must not run: overlay rectangles are sized in pixels and
md-viewer refuses the overlay on correctness grounds, which no setting
overrides.

Confirm `raw graphics zindex: -2` and `raw graphics overlay zindex: -1`.

For `20240203`, explicitly verify that md-viewer cannot emit a zero-size or
otherwise unsafe placement into the known #6344 path. If the current guard is
not sufficient, add the smallest conservative application-side guard necessary
before continuing churn tests.

**Step 2 — one static rectangle.** With
`interaction.selection_overlay = "on"`, drag-select a single short line and hold
still. Does one solid translucent bar appear over that line, at that line, at
the size the text occupies? Compare against the same document in iTerm2 or
Ghostty side by side. Photograph it.

Run this on stable and current WezTerm.

**Step 3 — the multi-cell bar with a sub-cell offset (the decisive geometry
check).** Drag-select a long line — one whose highlight spans many cells and
whose left edge does not fall on a cell boundary, so the placement carries a
non-zero `X`.

Look closely for vertical striping or a repeating gap at each cell boundary.

If it is clean, record that separately for each build and continue.

If the comb artifact predicted above appears, **do not immediately classify
WezTerm as unsupported and stop.** The artifact establishes that the current
encoding is not viable on that build. Use that result to implement and test the
smallest WezTerm-specific compatibility encoding that avoids the broken
multi-cell sub-cell-offset behavior.

Candidate approaches worth evaluating include:

* splitting only the offset-bearing edge from the cell-aligned interior;
* splitting a rectangle at cell boundaries so a non-zero `X` is never
  incorrectly propagated across unrelated cells;
* expressing the affected edge as a bounded additional placement while keeping
  the bulk of the bar cell-aligned;
* if raw graphics cannot be made both correct and performant, automatically
  selecting Stage 3's damage-band implementation for affected WezTerm builds.

These are hypotheses, not instructions to force a particular implementation.
Choose based on the code and observed terminal behavior.

After implementing a candidate, repeat checks 2 and 3. A workaround that merely
changes the shape of the artifact is not a fix.

**Step 4 — churn.** Only after static geometry is correct. Drag continuously
across a large selection (60–80 rectangles) for 30 seconds. Watch for the crash,
for rectangles that lag the pointer, and for the terminal's own CPU.

Run this on every WezTerm path that this stage proposes to support.

For `20240203`, do this with something unsaved in another pane only after the
static checks and #6344 application-side guards give good reason to believe the
known crash cannot be reached.

If the compatibility encoding increases placement count, specifically compare
its churn behavior against the normal path. Correct but unusably expensive is
not a passing result.

**Step 5 — deletion.** Release, then click elsewhere. No highlight fragment may
survive. Scroll with a selection up: the highlight must not detach from the text
it belongs to.

Repeat for stable and current paths.

**Step 6 — z-order.** Confirm the highlight sits above the base image and below
Neovim's own text: the statusline and any notification float must stay legible
over the preview, and the selected glyphs must stay readable through the tint.

Repeat for stable and current paths.

**Step 7 — automatic path selection and regression coverage.** Once the working
behavior is known, make md-viewer select it without requiring users to know the
implementation details.

Prefer capability/behavior-based selection where the existing architecture can
support it reliably. If a WezTerm version boundary is necessary because the
terminal behavior itself changed upstream, keep that boundary explicit,
documented, and tested.

Add or update tests covering at minimum:

* the old stable profile/path;
* the current-qualified profile/path;
* failure to obtain usable cell pixel dimensions;
* whichever compatibility/fallback decision is introduced;
* no change to the existing Kitty/Ghostty/iTerm2 behavior.

Do not make `wezterm = true` mean "we once observed one nightly behaving
correctly" if stable and current require materially different paths.

## Deliverable

Append a dated section to `docs/cross-platform-implementation-status.md`
recording:

* both exact WezTerm build strings;
* each check's outcome on each build;
* photographs for checks 2 and 3;
* whether each build uses the normal raw overlay, a WezTerm compatibility
  encoding, or the damage-band fallback;
* any measured churn/performance difference caused by the compatibility path.

Then update `lua/md-viewer/terminal.lua`,
`tests/lua/cases/terminal.lua`, `docs/manual-testing.md`, `README.md`, and
`doc/md-viewer.txt` to describe the behavior that actually passed.

The acceptable outcomes, in preference order, are:

1. **Stable and current both pass with the normal raw overlay.**
   Enable the profile accordingly and record both validated builds.

2. **Stable requires a narrow raw-graphics compatibility encoding while current
   can use the normal raw overlay.**
   Implement automatic selection between them, validate both, and mark both
   supported.

3. **One or both WezTerm generations cannot correctly implement the raw overlay,
   but Stage 3's damage-band path provides correct selection behavior.**
   Automatically use the damage-band path for the affected build(s), retain raw
   overlay for builds where it passes, and mark WezTerm supported with the
   implementation distinction documented.

4. **A build still cannot be made safe and correct using either the raw overlay,
   a bounded WezTerm workaround, or the existing damage-band path.**
   Do not lie about support. Record the exact blocker, the attempted
   compatibility approaches, and the smallest upstream defect or missing local
   capability preventing support.

If the per-cell padding bug is confirmed, prepare a minimal upstream reproduction
regardless of whether md-viewer successfully works around it. A local workaround
does not make the upstream protocol defect cease to exist.

If `20240203` can be protected from #6344 by enforcing the same preconditions
upstream later added, document that explicitly: it is useful evidence that the
stable build can remain supported without asking users to install nightly.
