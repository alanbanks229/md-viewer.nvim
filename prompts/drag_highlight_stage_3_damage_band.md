---
part: follow-up
title: Drag-to-highlight, stage 3 — find the frame cost that is real, then remove it
status: shelved (2026-08-07) — stage 4's step-1 probe split the terminals.
  iTerm2 passed alpha compositing outright, so stage 4's overlay shipped there
  (per-profile gate) and this stage was not needed for it. WezTerm crashed
  under the overlay probe and keeps the stage-2 full-frame drag path; this
  file is the standing candidate if WezTerm drags ever need improving. Note
  its Design A's strip placements are themselves unvalidated on WezTerm — run
  a probe first, WezTerm's Kitty implementation mishandled natural-size
  placements and placement churn.
model: Opus 5 (max reasoning effort) for steps 2 and 3; step 1 is mechanical
depends_on: 2bcee86 (stage 1), c44e22f (round 2), 742d746 (stage 2)
commit:
---

# Drag-to-Highlight, Stage 3 — Find the Frame Cost That Is Real, Then Remove It

> Read `prompts/00-policy.md` first. Its §3 architectural invariants, §4
> honesty requirements, and §5 test gates all apply to this work unchanged.

Three rounds have now tried to make this gesture feel fast. **Two of them
succeeded at what they measured and changed nothing the operator could feel.**
This file exists so the fourth does not make that mistake again, and it is
written to be read on its own — everything needed is repeated here.

---

## The one thing to understand before anything else

Dragging to highlight is paced by something **downstream of Neovim** that
nobody has ever measured, and that scales with **how many pixels the frame
contains** — not with how fast the renderer produced them, and not with how
much of the selection actually changed.

Every previous round optimised upstream of that. Stage 2 made the renderer 2.8×
faster and the operator felt nothing at all.

**Do not write production code that makes the renderer faster.** If you finish
this session having optimised capture, encoding, the anchor cache, `applyScroll`
or `page.evaluate`, you have repeated a mistake that has already been made
twice, with measurements in the repository proving it was a mistake both times.

---

## What has been tried, and what each attempt actually proved

- **`2bcee86` (stage 1)** — removed a 40ms trailing debounce ahead of dispatch
  (correct, still stands), and made moving drag frames capture at CSS scale
  (wrong; reverted).
- **`c44e22f` (round 2)** — reverted the blurry frame after the operator saw it
  in a real terminal. Moving frames are device scale. The cheap capture survives
  as an opt-in `interaction.fast_drag`, default `false`. Also fixed a drag that
  left the preview window freezing the selection.
- **`742d746` (stage 2)** — found a fixed compositor frame-rate wait nobody had
  suspected (a **1×1-pixel screenshot cost the same ~32ms as a full frame**),
  removed it, and made PNG encoding ~3× cheaper pixel-for-pixel.
  `retina_capture_ms` fell from **103.21 to 36.51**. The gesture felt **exactly
  the same**, in iTerm2 and WezTerm alike.

Stage 2's real output was not the speedup. It was the discovery that the
renderer is not the bottleneck, plus two traps worth stating plainly:

- **`retina_image_update_ms` is not terminal cost.** It measures `nvim_ui_send`
  *returning* — handing bytes to Neovim. It reads 0.1–0.8ms and means nothing
  about what the terminal then does.
- **`captureMs` is not frame cost.** It is the renderer's share, and the
  renderer stopped being the limiter some time ago.

---

## The evidence, in full

All from real iTerm2 and WezTerm sessions, via `:MdViewerDebug` and the
operator's own eyes. This is the entire empirical basis for this stage.

| # | Observation | Verdict |
|---|---|---|
| 1 | Full preview, 99×51 cells = 990×1020 CSS px = **4.04M device px**. `retina_capture_ms` 103.21 → 36.51 after stage 2 | **"Feels the same."** Also "feels the same, still laggy" on WezTerm (3.55M px) |
| 2 | Preview shrunk to 20×10 cells = 320×320 CSS px = **0.41M device px** (10× fewer), sharpness unchanged | **"Very snappy and smooth."** `retina_capture_ms` only moved to 15.98 |
| 3 | Drag rapidly 2–3s, stop moving, keep the button held | Highlight **snaps into place immediately** — no queue is growing |
| 4 | Drag across **two words** vs drag a **very large distance** | **Same time to appear** |
| 5 | `browser.fast_png_encode` `true` vs `false` (755KB vs 471KB frames) | Difference **negligible** — byte count has no demonstrated effect |

Observation 2 is the whole game: a 10× cut in pixels transformed the gesture
while capture time moved 20ms. Observation 4 says the cost is paid in full for a
two-word change, because a full viewport is captured and shipped either way.

---

## The model that explains all five

Presented as a **hypothesis with a falsification test**, not as fact. Confirm or
kill it in step 1 before designing anything around it.

The chain per drag frame is: renderer captures → Lua reads the PNG and
base64-encodes it → `nvim_ui_send` enqueues the escape stream → **Neovim's TUI
writes ~1MB to the pty** → the terminal reads it, decodes a ~4M-pixel PNG,
composites it, and deletes the previous placement.

`nvim_ui_send` returns immediately because it only enqueues. But if the terminal
drains its pty slowly — because it is busy decoding and compositing four million
pixels — the pipe fills and **Neovim's own write blocks**. That stalls Neovim's
loop, which delays it processing the next `<LeftDrag>`, which paces the entire
gesture at the terminal's rate. The pty is the backpressure nobody wrote.

It accounts for all five observations:

- **(3) no growing queue** — the pty throttles the producer instead of buffering.
- **(1) renderer savings invisible** — the limiter is downstream; shaving 67ms
  off an upstream stage that is already faster than the limiter changes nothing.
- **(2) pixel count dominates** — decode and composite scale with pixels; 4.04M
  → 0.41M is a 10× cut in the limiter itself.
- **(4) damage size irrelevant** — a full viewport is sent regardless.
- **(5) bytes barely matter** — inflate is a minority of decode; unfilter and
  composite scale with pixels, and pixel count did not change between those two
  runs.

**The falsification test, which needs the operator:** if the model is right,
Neovim *itself* should be momentarily less responsive during a laggy drag —
keystrokes queueing, a statusline or spinner hitching, the source-window cursor
stuttering. If the editor stays perfectly responsive while the highlight lags,
the model is wrong and the cost is somewhere that does not block Neovim's loop.
Ask for this; it is free.

---

## Two candidate designs — the operator has explicitly authorised a refactor

Do not assume the current architecture is fixed. The operator has said, in
these words, "I don't mind a refactor whatsoever, that is what source control is
for." Both designs below are in scope. Pick with measurement and with the
operator's eyes, not by defaulting to the smaller change.

### Design A — send only the strip that changed

Capture and place a damage band instead of the whole viewport. Roughly 10-30×
fewer pixels per moving frame.

**Quality risk: none.** The pixels are identical, there are simply fewer of them
per frame. This is the conservative option and the rest of this file is written
around it.

**Feasibility risk:** the terminal must composite a small image over a larger
already-placed one, at a higher z-index, at an exact cell offset, repeatedly.
`kitty_raw` has never done this. See step 2.

### Design B — take the highlight out of the picture entirely

Render the page with a **transparent background** (`omitBackground` on the
capture, producing an RGBA PNG), place that image *above* the text layer
(Kitty z-index `>= 0`; it currently sits at `-1`, i.e. below text), and let
**Neovim itself** paint the selection rectangles as ordinary highlighted cells
underneath. The renderer returns the selection's client rects — a ~1ms
`page.evaluate`, no screenshot — and Lua draws them.

**During a drag, no image is captured, encoded, transferred, or decoded at
all.** The highlight updates at Neovim's own redraw speed. This is not a 10×
improvement over today, it is closer to 100×, and it is the only design that
makes a moving frame genuinely free.

**Quality risk: real, and it is the thing this operator has twice rejected
changes over.** Glyphs are anti-aliased against an assumed background colour. If
Chromium rasterises text against transparency and the terminal composites a
selection colour behind it afterwards, letters can show halos or colour fringes
along their edges. Selection rectangles also snap to whole terminal cells, so
the highlight's edges become blocky rather than following the text exactly.

Mitigation worth evaluating: use the Neovim-drawn highlight only while the
pointer is moving, and let the existing device-scale settle frame after release
restore a true browser-rendered highlight. That trades "slightly blocky while
dragging" for "instant while dragging". Whether that is a good trade is the
**operator's call, not yours** — put it in front of them before building on it.

**Feasibility risk:** the terminal must alpha-composite an RGBA image over
terminal text cells. Also unverified. See step 2.

### What both share

Both depend on the same unknown: whether iTerm2 and WezTerm layer graphics the
way the Kitty specification says. **One session of testing with the operator
answers it for both**, so step 2 covers both and should be done before
committing to either design.

If step 2 says overlays work but alpha does not, build A. If both work, put the
trade in front of the operator with a real side-by-side and let them choose. If
neither works, stop and report — that is a genuine dead end and is worth saying
plainly rather than shipping something worse.

---

## Order of work

**Step 1 and step 2 are each a commit boundary. Either can invalidate the rest
of this file, which is exactly why they come first.**

1. **Measure the frame period in situ.** Diagnostics only, no behaviour change.
2. **Verify the overlay placement primitive** with the operator, in a real
   terminal. No headless test can answer it.
3. **Only then** build damage-band capture and placement.

If step 1 shows the loop is gated by something other than frame size, or step 2
shows the terminals will not composite an overlay reliably, **stop and report**.
Do not proceed into step 3 on the assumption that it will work out.

---

## Step 1 — the measurement nobody has

Add diagnostics that make the downstream cost visible from inside Neovim for the
first time. This is cheap, safe, and reversible, and it is the single highest-
value thing in this file.

Record, per drag gesture, and surface in `:MdViewerDebug`:

- **`drag_request_ms`** (min / mean / max) — wall time from
  `process.request("interact", …)` dispatch to its callback firing. This is the
  renderer round trip as *Lua* sees it. Expect roughly `captureMs` plus a
  millisecond or two.
- **`drag_frame_period_ms`** (min / mean / max) — wall time between successive
  completions of `apply_image`. This is the rate frames actually reach the
  screen.
- **`drag_events_per_second`** — `interaction.on_drag` invocations per second
  during a gesture.

**`drag_frame_period_ms` minus `drag_request_ms` is the number this whole stage
turns on.** If the round trip is ~37ms and the observed period is ~150ms, the
missing ~113ms is downstream of the renderer, in situ, on the operator's real
hardware — and the damage band is unambiguously the fix. If the two are nearly
equal, the pty model is wrong, the loop is gated elsewhere, and steps 2 and 3 as
written will not deliver.

`drag_events_per_second` is the third possibility and must be ruled out
explicitly: if Neovim only delivers `<LeftDrag>` at, say, 15/second, that is a
floor no rendering work can cross, and the answer would be something else
entirely.

Ask the operator to drag for a few seconds at their normal full window size and
report all three. Then ask them to repeat it with the preview shrunk to roughly
20×10 cells — the configuration they already confirmed feels snappy — so the
same three numbers exist for both the bad case and the known-good case. **Two
points on that line tell you what the fix has to achieve.**

---

## Step 2 — verify the placement primitive before building on it

The design in step 3 requires placing a small image **over** an already-placed
larger one, at a higher z-index, at an exact cell offset, repeatedly, without
flicker. `kitty_raw` today only ever places multiple crops of a **single**
uploaded image at one z-index. That a second image composites correctly over the
first, on iTerm2 **and** WezTerm, is an assumption and not a known.

Establish, with the operator, in a real terminal:

1. A second image placed over the base at a higher `z` appears, at the right
   cell, with no gap or overhang.
2. Replacing that overlay 30–60 times a second, as a drag will, does not
   flicker, tear, or leave residue.
3. Deleting the overlay leaves the base image underneath **intact** — not
   punched through.
4. Whether the sub-cell `X`/`Y` offset keys behave the same for an overlay as
   for the base. `image.raw_cell_offset_px` exists because iTerm2 applies its
   window margin to text but not to graphics placements.

Send the operator an exact snippet to run and exact things to look for. If any
of the four fails on either terminal, **stop and report** — the fallback is not
obvious and is worth a conversation rather than a guess.

---

## Step 3 — the damage band

**Goal:** a moving drag frame puts roughly **0.3M device pixels** on screen
instead of 4.04M, at unchanged size and unchanged sharpness.

That target is derived, not invented. A slow drag — the case that matters,
because the reader's eye is on the exact glyphs being crossed — changes two or
three lines of highlight. A full-width band three lines tall is about 990×75 CSS
px = **0.30M device pixels, below the 0.41M frame the operator already judged
snappy.**

**Sharpness is not negotiable.** `interaction.fast_drag` exists and defaults to
`false` because softening the moving frame was tried, shipped, and rejected by
the operator after seeing it. Reducing pixels by reducing density is not a
solution to this task. Reducing pixels by *sending less of the screen* is the
entire point.

### Renderer side

Clip the capture to the damage band. Stage 2 already proved a band costs only
the fixed floor: a 990×260 band, a 1×1 clip, and a full frame all measured ~32ms
before the frame-rate flag.

Chromium's screenshot `clip` is in **document** coordinates and must carry the
page's live scroll offset. Stage 2 shipped that fix (`captureViewportPng` reads
`visualViewport.pageLeft/pageTop`) after an early benchmark silently
screenshotted the top of the document at every scrolled position. Do not regress
it; there is a test.

**The band must be derivable from the request alone.** "Requests are stateless
and replayable" is an invariant. Do not remember the previous selection
rectangle inside the renderer and diff against it — a superseded or replayed
request would then pick up another request's state, which is the failure this
project is most exposed to. Carry the previous focus point in the envelope
instead, so the band is a pure function of `anchorCoordinates`, `coordinates`
and `previousCoordinates`. Lua already knows the previous drag point
(`pointer.newest_pending_drag_point`).

For a selection anchored at A with focus moving F1 → F2, the changed region is
the text between F1 and F2: a full-width vertical band from `min(F1.y, F2.y)` to
`max(F1.y, F2.y)`, padded by a line height at each edge, clipped to the
viewport, and snapped outward to whole terminal cell rows.

### Lua side

The band is uploaded and placed above the base image; the base image is **not**
replaced. On release, the existing device-scale settle frame
(`interaction.settle_selection`) replaces everything and every overlay placement
is deleted.

### Fall back to a full frame whenever the band is not provably sufficient

- the band would cover most of the viewport anyway (a fast drag) — measure the
  threshold rather than guessing it,
- the page scrolled (`result.scrollY` changed), or a find or fragment jump moved
  it,
- the content revision changed,
- the placement, viewport, or occlusion state changed,
- anything at all is uncertain.

A full frame is today's behaviour: correct and merely slow. **Correct and slow
always beats fast and wrong here.**

---

## The hazards, specifically

Each of these has already caused a visible bug in this repository. The status
document's post-Part-6 history records how each was fixed.

- **`M.move` emits replacements before deleting what they supersede**, both
  halves in one `nvim_ui_send` write. Deleting first leaves the terminal with
  nothing to composite until the replacement lands, and that gap was reported as
  the image blinking and rolling by about a row while a notification was open.
  Overlay updates have exactly this shape.
- **`visible_regions` / `exclusions`.** A passive float over the preview punches
  cut-outs out of the placement. An overlay must respect the same cut-outs or a
  notification will get painted over.
- **Placement IDs must be fresh on every call**, so old and new sets never
  collide while they briefly overlap.
- **Accumulation.** A drag produces many overlay placements. Track and delete
  every one; an untracked placement is a permanent artifact on the user's
  screen.
- **`image.double_buffer`** (the operator runs with it explicitly `true`)
  currently uploads a new image and deletes the old one every frame. The base
  image must survive a band update.
- **`coordinates.cell_to_css`, `session.last_placement`, and every diagnostic**
  describe "the image currently on screen". The base placement must stay
  authoritative for hit-testing; an overlay must never become what a click
  resolves against.

---

## What must not change

Stated in full, because this file is read on its own.

- **Staleness lanes** (`renderer/src/lanes.js`). An `interact` admission can
  never invalidate `content` or `capture`. A burst of drag frames cannot cancel
  a render. Do not add a path from one to the other.
- **One request in flight, newest pending point only**, and
  `session.coalesced_drag_events`, which counts what that drops.
- **A device-scale settle frame after release**
  (`interaction.settle_selection`). Whatever the moving frames cost, the final
  frame must be sharp and complete.
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
  A click in the margin must never activate the nearest paragraph's link. The
  `outside_content` test is the counterweight that makes the previous point
  safe.

---

## The failure mode to fear

Not a crash. **A screen that shows a selection different from the text
`selection_text` would copy.** Partial updates make this sharp: a band that is
too small, misaligned by a row, or silently dropped leaves **stale highlight on
screen** while the response reports the new selection — and the operator will
not notice until they paste.

---

## Verification you are expected to do, not skip

You have no graphical terminal. Headless Lua alone would have shipped every one
of the previous rounds wrong, because those tests stub `process.request` and
never reach the renderer.

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
- **Composite equivalence — the test this stage lives or dies by.** In Node,
  composite the base frame plus the sequence of band PNGs at their intended
  offsets, and assert the result is pixel-identical to a full capture of the
  same final selection state. That is the terminal's job, simulated honestly,
  and it catches misalignment, drift, an off-by-one row, and a band that was too
  small. `tests/node/browser.test.js` already carries a dependency-free PNG
  decoder for exactly this kind of check.

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

- Composite equivalence, as above.
- A superseded request cannot be answered from a newer one's state: drive two
  overlapping requests through a stubbed transport and assert the older is
  discarded, not answered from the newer one's cache.
- Every fall-back-to-full-frame trigger, each asserted to produce a full frame:
  scroll, find, fragment jump, content-revision change, oversized band.
- Overlay placements are all deleted at settle — assert none leak.
- A hit test after a find or a fragment jump still resolves against the position
  on screen. This repository has had that bug once already; see the
  `display_interact_result` `scrollY` fix.
- If step 1 adds diagnostics, `:MdViewerDebug` must be invoked as the real
  command, not the library function beneath it (policy §5).

---

## Reporting

Follow policy §7. In addition, state explicitly:

- **`drag_frame_period_ms` minus `drag_request_ms`**, at full size and at the
  known-good small size. This is the number that justifies or refutes the whole
  stage.
- before/after **pixels per moving frame**, not only milliseconds — milliseconds
  upstream of the terminal have twice now failed to predict what the operator
  feels.
- what the placement-primitive verification returned: quote exactly what was
  asked of the operator and exactly what came back.
- which fall-back triggers you implemented, and what fraction of a real recorded
  drag took the band path versus the full-frame path.
- which levers you rejected, and which you left alone because the risk exceeded
  the measured gain. **That third list should not be empty.**
- **that you cannot validate this.** Whether the drag feels crisp is the
  operator's call, made by dragging in a real terminal. Per policy §4, do not
  describe the result as validated. If you used the operator as a measuring
  instrument, say exactly what you asked for and exactly what came back,
  separately from your own headless work.
