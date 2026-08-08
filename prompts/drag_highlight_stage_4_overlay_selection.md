---
part: follow-up
title: Drag-to-highlight, stage 4 — overlay the selection instead of re-photographing the page
status: done — iTerm2 only (per-profile gate; WezTerm crashed the step-1 probe).
  Operator validated on 2026-08-08: speed confirmed, but the rectangles are
  taller than Chromium's own paint. Geometry correction is stage 5. See the
  addendum at the bottom for what step 1 actually returned and which of this
  file's assumptions it corrected.
model: Fable 5 (or Opus 5 at max reasoning for the placement work)
depends_on: 2bcee86 (stage 1), c44e22f (round 2), 742d746 (stage 2)
supersedes: prompts/drag_highlight_stage_3_damage_band.md, which becomes the
  fallback if step 1 shows the terminals cannot alpha-composite
commit: 319f37e
---

# Drag-to-Highlight, Stage 4 — Overlay the Selection Instead of Re-Photographing the Page

> Read `prompts/00-policy.md` first. Its §3 architectural invariants, §4
> honesty requirements, and §5 test gates all apply to this work unchanged.

---

## The problem in one paragraph

Every time the mouse moves during a drag-to-highlight, md-viewer takes a fresh
screenshot of the **entire** preview pane — 4 million pixels — encodes it as a
~700KB PNG, base64s it to ~1MB, and pushes it through the terminal, which
decodes all 4 million pixels and recomposites. All to change the highlight on
two words. It is reprinting a page of a book to underline one sentence, fifteen
times a second.

**This stage stops taking that photograph during the drag.**

---

## What has already been tried, and what it proved

- **`2bcee86` (stage 1)** — removed a 40ms trailing debounce (correct, stands);
  made moving frames capture at CSS scale (wrong, reverted).
- **`c44e22f` (round 2)** — reverted the blur after the operator saw it. Moving
  frames are device scale. The cheap capture survives as opt-in
  `interaction.fast_drag`, default `false`.
- **`742d746` (stage 2)** — found a fixed compositor frame-rate wait (a
  **1×1-pixel screenshot cost the same ~32ms as a full frame**), removed it, and
  made PNG encoding ~3× cheaper pixel-for-pixel. `retina_capture_ms` fell from
  **103.21 to 36.51**. The operator felt **nothing at all**, in iTerm2 and
  WezTerm alike.

Two measurement traps that cost real sessions, stated so they are not repeated:

- **`retina_image_update_ms` is not terminal cost.** It measures `nvim_ui_send`
  *returning* — handing bytes to Neovim. It reads 0.1–0.8ms and says nothing
  about what the terminal then does.
- **`captureMs` is not frame cost.** It is the renderer's share, and the
  renderer has not been the limiter for some time.

**Do not spend this session making the renderer faster.** That has been done
twice, successfully, with no effect the operator could perceive.

---

## The evidence

All from real iTerm2/WezTerm sessions, via `:MdViewerDebug` and the operator's
own eyes.

| # | Observation | Verdict |
|---|---|---|
| 1 | Full preview, 99×51 cells = 990×1020 CSS px = **4.04M device px**. `retina_capture_ms` 103.21 → 36.51 | **"Feels the same"** (both terminals) |
| 2 | Preview shrunk to 20×10 cells = **0.41M device px** (10× fewer), sharpness unchanged | **"Very snappy and smooth"**; `retina_capture_ms` only 15.98 |
| 3 | Drag fast 2–3s, stop moving, hold the button | Highlight **snaps into place immediately** — nothing is queueing |
| 4 | Drag **two words** vs a **very large distance** | **Same time to appear** |
| 5 | `fast_png_encode` true vs false (755KB vs 471KB frames) | **Negligible** — byte count barely matters |

Observation 2 is the whole case: cutting pixels 10× transformed the gesture
while capture time moved 20ms. Observation 4 says the full cost is paid to
change two words, because a whole viewport is shipped either way.

---

## The non-negotiable constraint

**The preview must keep looking exactly like the VS Code Markdown preview.**

The operator has rejected two changes for degrading appearance: a CSS-scale
capture that made the preview blurry and emoji bloated (round 2), and anything
that softens the moving frame (`interaction.fast_drag` exists and stays `false`
by default because of it).

This design is built specifically to satisfy that. **The rendered page is not
touched.** No transparent background, no re-theming, no change to fonts,
anti-aliasing, code-block panels, tables or images. The base image stays exactly
the full browser-rendered, device-scale frame it is today — because it *is*
today's frame, unmodified.

A design that renders the page differently in order to go faster is the wrong
design. One was considered and rejected before this file was written: sending
the page on a transparent background and having Neovim paint the selection as
ordinary highlighted cells. It fails this constraint three ways — the page
background, code-block fills and table fills would come from Neovim rather than
the browser CSS; any content with its own opaque background would hide the
highlight entirely; and glyphs anti-aliased against transparency then
composited over a selection colour show halos. **Do not revive it.**

---

## The design

### The idea

The selection highlight is a translucent coloured rectangle. It does not need a
screenshot — it needs a rectangle.

1. **The base image is unchanged.** Full page, device scale, opaque, captured
   exactly as today, only when the content or scroll actually changes.
2. **Upload one tiny RGBA PNG once** — a solid rectangle in the page's own
   `::selection` colour at its own alpha. A handful of bytes. The Kitty
   graphics protocol scales a placement to any cell rectangle, so one small
   image serves every selection rectangle at every size.
3. **Each drag frame, the renderer returns the selection's client rects** —
   `Range.getClientRects()`, a `page.evaluate` measured at ~0.25ms — **and takes
   no screenshot at all.**
4. **Lua re-places the tiny image** over those rectangles, at a z-index above the
   base image but below Neovim's own text, and deletes the previous set.
5. **On release**, the existing device-scale settle frame
   (`interaction.settle_selection`) captures a true browser-rendered frame with
   the highlight baked in by the browser, and the overlays are removed once it
   has landed.

Per moving frame on the wire: **a few hundred bytes of escape codes instead of
~1MB of base64**, and no PNG for the terminal to decode. The renderer round trip
drops from ~36ms to ~1–2ms (rehydrate ~0.6ms plus one `page.evaluate`).

### Why this satisfies the appearance constraint

During motion the reader sees the real browser-rendered page with a translucent
rectangle over it. On release they see the browser's own selection rendering.
The glyphs are never re-rasterised, never re-scaled, and never composited
against anything they were not rasterised against. The only approximation is the
*shape* of the highlight rectangle at its edges — see the quality gate below.

---

### What the highlight must look like, from the operator's own screenshots

The operator supplied two screenshots of the real preview with a live selection.
Match this, because it is the standard you will be judged against:

- **Ragged, per-line-box rectangles.** Each line's highlight ends exactly where
  that line's text ends — never a full-width band. This is what
  `Range.getClientRects()` already returns, one rect per line box.
- **Inline `<code>` spans get their own separate, taller rectangle**, vertically
  offset from the prose around them, because they are their own line boxes with
  their own padding. A sentence containing two inline-code spans shows three
  distinct rectangles at two different heights.
- **Blank lines inside a selected code block show a short stub rectangle**, not
  nothing and not a full-width bar.
- **The text stays completely legible** through the translucent grey — syntax
  colours read normally underneath it.
- A large selection can produce **60-80 rectangles**. Budget for that.

### The geometry trap that decides whether this looks right

**Text line height and terminal cell height do not align, and never will.**

With the operator's settings, `--md-viewer-line-height` is **25 CSS px**
(`round(16 × 22/14)`), while a terminal cell is **20 CSS px** (1020px viewport ÷
51 cells). Successive lines start at y = 0, 25, 50, 75… and cell boundaries fall
at 0, 20, 40, 60… They only re-align every 100px, so the phase drifts
continuously down the page.

Consequently **you cannot snap highlight rectangles to whole cells.** One cell is
too short for a 25px line and leaves a visible gap between highlighted lines; two
cells is too tall and bleeds into the neighbouring line. Either way it looks
obviously wrong, and inline-code rects — which are a different height again —
make it worse.

The Kitty protocol's `c`/`r` placement keys scale an image into a whole number of
cells, so **do not use them for this.** Place the image at its **natural pixel
size** (omit `c`/`r`) and position it with the sub-cell `X`/`Y` offset keys. That
gives pixel-exact rectangles on a cell-based grid.

This means one tiny image per distinct rectangle *size*, not one image total.
That is still nearly free if you do two things:

- **Cache uploaded rectangle images keyed by exact pixel size.** A document has
  only a handful of distinct line-box heights, so after a moment the cache is
  warm and no upload happens at all.
- **Diff the rect set between frames and re-place only what changed.** Extending
  a drag by one line changes one or two rectangles; the rest keep their existing
  placements untouched. Do not delete and re-place all 60 every frame.

**If the terminals do not honour `X`/`Y` sub-cell offsets, this design cannot
produce correct geometry — stop and fall back to stage 3.** Note that
`image.raw_cell_offset_px` already exists with the comment "when the terminal
honours it", so this is genuinely unsettled. It is the single most important
thing step 1 must answer.

---

## Step 1 — verify the terminal can do this at all, before building anything

This design rests on one assumption that no headless test can settle: **that
iTerm2 and WezTerm alpha-composite a Kitty-protocol image over another
Kitty-protocol image, in z order, the way the specification says.**

`kitty_raw` today only ever places multiple crops of a *single* opaque image at
one z-index. Layering a second, translucent image over the first has never been
tried here.

Establish with the operator, in both terminals, with an exact snippet to run and
exact things to look for:

1. A translucent RGBA image placed over the base image at a higher `z` appears,
   and the page **shows through it** rather than being blanked out.
2. `z` ordering works as needed: **base image below, highlight above it, Neovim's
   own text (winbar, statusline, notifications) above both.** `image.raw_zindex`
   currently defaults to `-1` for the base — i.e. below Neovim's text — so the
   highlight needs a value between the base and the text layer.
3. Replacing the overlay 30–60 times a second does not flicker, tear, or leave
   residue.
4. Deleting the overlay leaves the base image **intact underneath**, not punched
   through.
5. The sub-cell `X`/`Y` placement offsets behave for the overlay as they do for
   the base. (`image.raw_cell_offset_px` exists because iTerm2 applies its window
   margin to text but not to graphics.)

**If alpha compositing does not work**, stop and report. Do not substitute an
opaque overlay — it would hide the text. The fallback is
`prompts/drag_highlight_stage_3_damage_band.md`'s Design A (capture and place
only the strip that changed), which needs no alpha and no transparency, and
which is written and ready.

---

## Step 2 — the quality gate, which is the real acceptance criterion

The operator's standard is that it looks like the VS Code preview. Two things
can violate that, and both are testable.

**Colour must match the browser's own.** Read the selection colour and alpha
from the actual `::selection` rule in `renderer/assets/preview*.css` — do not
pick a colour that looks about right. If the drag overlay and the settle frame
disagree on colour, the highlight will visibly change the instant the mouse is
released, which is worse than the lag it replaces.

**Edges snap to terminal cells.** A rectangle can only be placed on a cell grid
(plus whatever sub-cell offset `X`/`Y` buys). A selection that starts or ends
mid-character will have its overlay edge rounded to the nearest cell boundary.
Full lines in the middle of a multi-line selection are exact; only the first and
last partial lines approximate.

**The headless test that measures this:** composite the base frame plus the
overlay rectangles in Node, and diff against a real browser-rendered capture of
the same selection. Report the differing-sample count and where it is
concentrated. Differences confined to a fraction of a cell at rect edges are the
expected, acceptable result. Differences across whole lines, wrong colour, or a
vertical offset are bugs. `tests/node/browser.test.js` already carries a
dependency-free PNG decoder for exactly this kind of check.

Then **show the operator a real side-by-side** — the overlay state and the
settle state, same selection — and let them judge. Per policy §4 this is their
call, not yours.

---

## Implementation notes against the repository as it is

- `renderer/src/interact.js` — `resolveSelectionInPage` already resolves the
  selection; it must additionally return the range's client rects, in CSS pixels
  relative to the viewport, clipped to it. `ACTIONS` there gates capture:
  `capture: action.mutatesVisibleState || envelope.capture === true` means
  `selection_preview` currently *always* screenshots. A moving drag frame must be
  able to opt out; do that explicitly and keep `selection_commit` capturing.
- `renderer/src/browser.js` — `evaluateAction` dispatches the in-page functions;
  `captureViewport`/`captureViewportPng` is the capture path (note its `clip` is
  in **document** coordinates and carries the page's live scroll offset — do not
  regress that, there is a test).
- `lua/md-viewer/backends/kitty_raw.lua` — `M.show`, `M.update`, `M.move`,
  `placement_sequences`, `visible_regions`, `zindex()`, `cell_offset()`. This is
  where the overlay lives and where the hazards below apply.
- `lua/md-viewer/interaction.lua` — `attempt_selection_preview` (the moving
  frame), `settle_selection` (the commit frame).
- `lua/md-viewer/controller.lua` — `display_interact_result`, `apply_image`.
- `lua/md-viewer/config.lua` — `image.raw_zindex`; any new tunable goes here with
  a `validate()` assertion in the existing style.

---

## The hazards, specifically

Each has already caused a visible bug in this repository.

- **`M.move` emits replacements *before* deleting what they supersede**, both in
  one `nvim_ui_send` write. Deleting first leaves the terminal with nothing to
  composite until the replacement lands, and that gap was reported as the image
  blinking and rolling by about a row. Overlay updates have exactly this shape,
  and so does removing the overlays when the settle frame lands — **emit the new
  frame first, then delete the overlays**, or the highlight will flash off.
- **`visible_regions` / `exclusions`.** A passive float over the preview punches
  cut-outs out of the placement. Overlays must respect the same cut-outs or a
  notification gets painted over.
- **Placement IDs must be fresh on every call** so old and new sets never collide
  while they briefly overlap.
- **Accumulation.** A drag produces many overlay placements. Track and delete
  every one; an untracked placement is a permanent artifact on the user's screen.
- **`coordinates.cell_to_css`, `session.last_placement`, and every diagnostic**
  describe "the image currently on screen". The base placement must stay
  authoritative for hit-testing — an overlay must never become what a click
  resolves against.
- **Scroll, find, fragment jump, content change** all invalidate the overlay
  geometry. Fall back to a full frame; correct and slow beats fast and wrong.

---

## What must not change

Stated in full, because this file is read on its own.

- **Staleness lanes** (`renderer/src/lanes.js`). An `interact` admission can
  never invalidate `content` or `capture`. A burst of drag frames cannot cancel a
  render. Do not add a path from one to the other.
- **One request in flight, newest pending point only**, and
  `session.coalesced_drag_events`, which counts what that drops.
- **A device-scale settle frame after release.** Whatever the moving frames cost,
  the final frame must be a true browser render, sharp and complete.
- **Requests are stateless and replayable.** A superseded or replayed request
  must never pick up another request's cached state.
- **No `innerHTML` anywhere in a selection path.** `setBaseAndExtent` /
  `Text.splitText` only, so a selection containing literal HTML is copied
  character-for-character.
- **`javaScriptEnabled: false`** on the browser context (policy §3).
  `page.evaluate` still works with it off; `requestAnimationFrame` inside the
  page does not.
- **The `cells` backend is unaffected** — no image, no selection.
- **No new process, no second transport, no listening port** (policy §3).
- **`interaction.fast_drag` stays `false` by default.**
- **`resolveSelectionInPage`'s `nearestBlockPoint` fallback stays.** A drag that
  leaves the preview window must keep extending the selection toward the nearest
  content. Operator-validated, with regression tests in
  `tests/node/selection.test.js`.
- **`hitTestInPage` keeps reporting an honest miss for the page's own padding.**
  A click in the margin must never activate the nearest paragraph's link.

---

## The failure mode to fear

Not a crash. **A screen showing a selection different from the text
`selection_text` would copy.** This design makes it sharper than ever, because
the highlight on screen is now drawn by Lua from geometry while the selected
string is owned by the browser. If the rects and the DOM selection ever come
from different requests, the picture and the string disagree — and the operator
will not notice until they paste.

Mitigation to build in: the rects and the selection text must come from the
**same** `page.evaluate`, in the same queued operation, never assembled from two
round trips.

---

## Verification you are expected to do, not skip

Headless Lua alone would have shipped every previous round wrong; those tests
stub `process.request` and never reach the renderer.

- **A live Neovim, driven through the real input layer.** Start
  `nvim --headless -u NONE -i NONE --listen /tmp/s.sock -c "luafile <setup>"`,
  then drive it from a separate process with `--remote-expr` calling
  `nvim_input_mouse`. Mappings, `getmousepos()`, gesture dispatch, click-count
  escalation and window boundaries all behave for real, and a real split
  reproduces the operator's 99×51 geometry exactly. Three dead ends already paid
  for: `nvim --headless -l` never processes injected input; `--embed` plus
  `nvim_ui_attach` from an `-l` client kills the server; and `nvim_ui_attach`
  over `--listen` from an `-l` client kills the channel the same way — so the
  image backend is the one part that stays faked.
- **A real Chromium renderer subprocess**, via the `startRenderer` harness in
  `tests/node/selection.test.js`. `discoverChromium` finds the system browser;
  **never run `playwright install`** and never download a browser.
- **Chain the two.** Record the exact `interact` envelopes a real drag produces,
  then replay them verbatim into the real renderer. Hand-built fixtures encode
  the same assumptions as the fix and will agree with it.
- **Composite equivalence** — the quality gate in step 2, and the test this stage
  lives or dies by.

---

## Tests

All four gates in policy §5 must pass:

```bash
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
stylua --check lua/ plugin/ tests/lua/
```

Beyond that:

- Composite equivalence: base + overlay rects versus a real browser-rendered
  selection frame, with the differing-sample count reported and shown to be
  confined to cell-edge rounding.
- The rects and the selection text come from one `page.evaluate` — assert a
  superseded request cannot be answered from a newer one's state by driving two
  overlapping requests through a stubbed transport.
- Every fall-back-to-full-frame trigger produces a full frame: scroll, find,
  fragment jump, content-revision change.
- Overlay placements are all deleted after settle — assert none leak, and assert
  the settle frame is emitted before the overlays are removed.
- A hit test after a find or fragment jump still resolves against the position on
  screen (`display_interact_result`'s `scrollY` bug once shipped here).
- If any `:MdViewer*` command's output changes, invoke that exact command in
  headless Neovim, not the library function beneath it (policy §5).

---

## Reporting

Follow policy §7. In addition, state explicitly:

- **bytes and pixels per moving frame, before and after** — milliseconds
  upstream of the terminal have twice failed to predict what the operator feels;
- what the step 1 terminal verification returned: quote exactly what was asked of
  the operator and exactly what came back;
- the composite-equivalence numbers, and where the differences are concentrated;
- which levers you rejected, and which you left alone because the risk exceeded
  the measured gain. **That third list should not be empty.**
- **that you cannot validate this.** Whether it looks like the VS Code preview,
  and whether the drag feels crisp, is the operator's call, made by dragging in a
  real terminal. Per policy §4, do not describe the result as validated.

---

## Addendum — what implementation actually found (2026-08-07)

Recorded per policy §6.5. Four of this file's assumptions did not survive
contact with the terminals and the browser; the implementation reflects
reality, not the text above.

1. **The terminals split.** Step 1's probe (a throwaway script, run by the
   operator in both terminals): iTerm2 passed every check — alpha
   compositing, crop placements without c/r, X/Y sub-cell offsets (in device
   pixels; its CSI 14t cell report is in points), inter-image z order, 40fps
   churn, clean deletion. WezTerm failed to render natural-size placements at
   all and the terminal application **crashed** when the churn began. Operator
   decision: ship the overlay behind a per-profile gate
   (`terminal.lua` `selection_overlay`, config `interaction.selection_overlay`)
   — enabled for iTerm2 alone; WezTerm keeps the stage-2 full-frame path.
   Stage 3 was NOT implemented; it remains the candidate if WezTerm drags ever
   need improving.
2. **There was no `::selection` rule to read.** `preview*.css` had none; the
   highlight was Chromium's default paint (measured: dark ≈ rgba(97,97,97,.846),
   light ≈ rgba(189,189,189,.576) — too opaque for an overlay that sits above
   the glyphs). The rule is now pinned per theme (`--selection-bg`, dark
   rgba(220,220,220,.3) / light rgba(128,128,128,.3)), chosen so the composited
   result over the page background is bit-identical to what the operator already
   saw; `SELECTION_TINT` in `renderer/src/interact.js` is the same constant and
   `tests/node/selection-tint.test.js` fails if CSS and constant ever drift.
3. **"Inline `<code>` gets its own taller rectangle" is not what this Chromium
   paints.** Measured from real captures: selection paint spans the full LINE
   BOX, uniformly across mixed-font lines, tiling between consecutive lines of
   a block; blank lines paint a one-character-advance stub; lines that flow on
   paint a ~4.8px end-of-line stub. The rect geometry reproduces the first
   three (line-box bands from the containing block's line-height, ~1px from
   Chromium's asymmetric half-leading; measured char-advance stubs) and
   deliberately skips the end-of-line stub (a fraction of a cell at a rect
   edge — this file's stated acceptable approximation).
4. **"One tiny image per distinct rectangle size" was the wrong transport.**
   One solid tint sheet is uploaded once (renderer-generated PNG, ~27KB base64,
   `overlaySheetPng` on request) and every rectangle is a *crop* of it at
   natural pixel size — zero pixels per moving frame, no per-size image cache
   to bound. Measured end to end through the real input layer, renderer, and
   Chromium (`scripts/stage4-live/drive.lua`): a changed frame costs ~91-500
   bytes of placements, an unchanged frame diffs to zero bytes, and the settle
   frame remains a true ~196KB device-scale capture.
