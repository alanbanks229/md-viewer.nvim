---
part: follow-up
title: Drag-to-highlight, stage 2 — make a sharp frame cheap
status: done (renderer-side only; did not change how the gesture feels)
model: Opus 5 (max reasoning effort)
depends_on: 2bcee86 (stage 1), c44e22f (round 2 — drag frames are device scale
  again, and off-content selection endpoints resolve)
commit: 742d746
---

# Drag-to-Highlight, Stage 2 — Make a Sharp Frame Cheap

> Read `prompts/00-policy.md` first. Its §3 architectural invariants, §4
> honesty requirements, and §5 test gates all apply to this work unchanged.

This file replaces an earlier stage 2 that ranked five transport-level
suspects. Stage 1's own measurements have since exonerated four of them, and
a round of operator-reported bugs has moved the baseline. Everything that
file constrained is repeated here in full — it is gone, so nothing may be
read out of it.

---

## Where this stands, and what is already known to be wrong in the docs

Three rounds have landed on this gesture:

- **`2bcee86` (stage 1)** — measured the frame budget, then made the moving
  drag-preview frame capture at `render.fast_scroll`'s scale (CSS, half
  density) and removed the 40ms trailing debounce ahead of dispatch.
- **`c44e22f` (round 2)** — the operator reported, from a real iTerm2
  session, that the preview went blurry and emoji looked bloated for the
  whole of every drag, and that a drag leaving the preview window stopped
  extending the selection. Both were real. The capture-scale half of stage 1
  was reverted: moving drag frames are **device scale** again, with the
  cheap capture preserved as an opt-in `interaction.fast_drag` that defaults
  to `false`. Separately, `interaction.locate_for_drag` now clamps an
  out-of-window pointer to the placement's edge, and
  `resolveSelectionInPage` in `renderer/src/interact.js` slides a selection
  endpoint that landed on no block onto the nearest one — the clamp alone
  was a no-op, because the edge column is the page's own 26px side padding
  and every request from it came back `focus_miss`.

The debounce/pacing half of stage 1 was correct and still stands.

**Known-stale documentation.** `docs/cross-platform-implementation-status.md`
has not been updated for `c44e22f`. Its "Post-Part-7 follow-up: drag-highlight
responsiveness, stage 1" section still states that the drag-preview frame
captures at `render.fast_scroll and "css" or "device"` and that the Lua test
asserts `"css"` — both false as of `c44e22f`. Trust the code and this file
over that section, and bring it up to date as part of closing this stage
(policy §6.4).

---

## The goal, stated the way the operator states it

Dragging to highlight must feel **crisp, snappy, and immediate** — the way
selecting text in a browser feels. It is currently correct and sharp, but
paced by a ~68ms per-frame capture: roughly 14 frames per second with one
request in flight, before terminal transfer.

Sharpness is not negotiable. `interaction.fast_drag` exists, and defaults to
`false`, because softening the moving frame was tried, shipped, and rejected
by the operator after seeing it. **Making the moving frame cheap by making it
blurry again is not a solution to this task.** If you conclude the only
available win is a quality trade, say so plainly and stop rather than take it.

---

## Do not spend this session on the old suspect list

The superseded stage 2 ranked five suspects. Stage 1's measurements put
`captureMs` at **~95% of `totalMs`**. Suspects 3 (the drag anchor being
re-resolved every frame), 4 (`page.evaluate` re-serializing its function
source), and 5 (`applyScroll` running unconditionally) all live inside the
~1ms `rehydrateMs`. Suspect 1's Lua-side `fs_read` and base64 encode measured
0.03–0.1ms. Perfect work on all four buys roughly 3ms out of 68.

Check that arithmetic against the table below yourself before accepting it.
If it holds, **say so plainly in your report and do not spend the session
there.** The dominant cost is `page.screenshot()` itself, and it was not on
that list.

### Stage 1's measurements, inlined

Two throwaway benchmark scripts (not committed), both driving the real
renderer subprocess and real Chromium, no stubbing: a Node-side script
modeled on `tests/node/interact.test.js`'s subprocess harness, and a Lua-side
script modeled on `tests/lua/cases/process.lua`'s real (non-stubbed)
subprocess usage. Both ran the same 20-frame simulated drag sweep over the
same document (`kitchen-sink.md` + 60 filler paragraphs, 5,400 characters, 90
layout blocks) on the same machine. Use the same document so all three rounds
stay comparable.

Per-frame, `captureScale: "device"` vs `"css"` (averages over 20 frames):

```
                 device        css
Node  wallMs      68.40       33.23
Node  rehydrateMs  1.11        1.04
Node  captureMs   64.88       30.07
Node  totalMs     67.95       32.85
Node  pngBytes  86822.9    38397.0

Lua   wall_ms     67.90       32.52   (dispatch + IPC + renderer round trip)
Lua   pngBytes  86823        38397
Lua   fs_read_ms  0.108        0.094  (real, blocking, headless-safe)
Lua   base64_ms   0.060        0.027  (real, pure Lua, headless-safe)
```

Node- and Lua-observed wall-clock agree closely (68.4 vs 67.9, 33.2 vs 32.5),
so nothing meaningful is lost or added between the renderer's own numbers and
what Lua actually experiences.

Debounce/pacing, same machine:

```
first-dispatch latency (single on_drag call):
  drag_debounce_ms=40 (old default): 37.71 ms before the request is sent
  drag_debounce_ms=0  (new default):  0.01 ms

requests actually sent over a continuous 300ms drag (new point every 15ms):
  drag_debounce_ms=40 (old default): 1 request for the whole gesture
  drag_debounce_ms=0  (new default): 11 requests, coalesced_drag_events=19
```

**`c44e22f` moved the baseline back to the `device` column.** That is the
number to beat: ~68ms and ~87KB per moving frame, at full sharpness.

### What is genuinely unmeasured

Measure both before choosing what to build.

1. **Terminal transfer.** `kitty_raw.M.update` base64-encodes the whole PNG
   and writes ~116KB of escape bytes through `nvim_ui_send` every frame, then
   deletes the previous image. The write itself, and iTerm2's decode and
   composite, have never been timed. This cost surfaces as UI lag rather than
   Lua time, so nothing in the table above would have caught it. If you
   cannot time it headlessly, say so and ask the operator to run one specific
   measurement — do not infer it.
2. **What `captureMs` is actually made of** — Chromium rasterizing versus PNG
   encoding. This decides whether the answer is "capture less area" or
   "encode more cheaply", and those lead to completely different designs.
   Getting this wrong wastes the whole session.

---

## The levers worth evaluating, in the order I would rank them

Measure first; let the numbers reorder this. Take them one at a time with the
gates green between each — a batch that lands together is not attributable
when something goes wrong.

**A. Damage-rectangle capture and placement.** Between two drag frames, only
the band of the document whose selection changed actually differs.
`page.screenshot({ clip })` makes `captureMs` scale with area, and a Kitty
placement covering only the affected rows makes the upload scale with it too
— the one change that attacks both dominant costs at once. The renderer
already computes selection geometry it could return alongside the frame.

Watch the interaction with `visible_regions`/`exclusions` in
`lua/md-viewer/backends/kitty_raw.lua`, and with `M.move`'s
emit-replacement-before-deleting-the-superseded ordering. Both have caused
visible placement bugs before — image blinking and rolling by a row — and the
status doc's post-Part-6 history records how each was fixed. A partial
placement is exactly the shape of change that brings them back.

**B. Stop screenshotting during the drag at all.** Have the renderer return
the selection's client rects (a ~1ms `page.evaluate`) and composite the
highlight terminal-side, with one real device-scale capture on release —
which `interaction.settle_selection` already guarantees. This is the only
option that makes a moving frame effectively free.

It is also the most invasive, and it rests on an assumption you must verify
rather than believe: that Kitty-protocol alpha and z-index compose the way
the specification says **on iTerm2 specifically**. Verify that first. If
verifying it needs the operator's terminal, ask for that one measurement
before building anything on top of it. Note also that this changes what "the
image currently on screen" means for `coordinates.cell_to_css`,
`session.last_placement`, and every diagnostic that reports them.

**C. Cheaper encoding for moving frames only.** Chromium's
`Page.captureScreenshot` accepts `optimizeForSpeed`, and JPEG encodes far
faster than PNG. Establish what Playwright 1.62 actually exposes, and whether
`kitty_raw`'s `f=100` upload path can carry anything but PNG on iTerm2,
before treating this as available. Sharpness still cannot regress: this is an
encoding-cost lever, not a quality lever.

---

## What must not change

Stated in full, because this file is read on its own.

- **Staleness lanes** (`renderer/src/lanes.js`). An `interact` admission can
  never invalidate `content` or `capture`. A burst of drag frames cannot
  cancel a render. Do not add a path from one to the other.
- **One request in flight, newest pending point only**, and
  `session.coalesced_drag_events`, which counts what that drops.
- **A device-scale settle frame after release**
  (`interaction.settle_selection`). Whatever the moving frames cost, the
  final frame must be sharp.
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
- **`interaction.fast_drag` stays `false` by default.** See "The goal" above.
- **`resolveSelectionInPage`'s `nearestBlockPoint` fallback stays.** A drag
  that leaves the preview window must keep extending the selection toward the
  nearest content. This is a fixed, operator-validated bug with regression
  tests in `tests/node/selection.test.js`.
- **`hitTestInPage` keeps reporting an honest miss for the page's own
  padding.** A click in the margin must never activate the nearest
  paragraph's link. There is a test asserting `outside_content`; it is the
  counterweight that makes the previous point safe.

---

## Constraints on the fix

- Any new tunable goes in `lua/md-viewer/config.lua` with a `validate()`
  assertion in the existing style, mirroring an existing name where one fits.
- The moving-frame/settle-frame split must remain observable in
  `:MdViewerDebug` through the existing `fast_*` and `retina_*` fields.
- If a change makes an existing diagnostic meaningless, remove the diagnostic
  in the same commit rather than leaving it reporting a number nobody can
  use.

---

## The failure mode to fear

Not a crash. **A frame that paints a selection different from the text
`selection_text` would copy.** Every transport shortcut here — reusing a
frame, caching an anchor, skipping a repaint, compositing a highlight that
the browser does not know about — is a way for the picture and the string to
disagree, and the operator will not notice until they paste.

Any change touching what survives between frames needs a test that a
superseded request cannot be answered from a newer one's state: drive two
overlapping requests through a stubbed transport and assert the older one is
discarded, not answered from the newer one's cache.

---

## Verification you are expected to do, not skip

You have no graphical terminal. You have considerably more than headless Lua,
and the previous round's root cause was found only because these were used —
the headless Lua tests could not have found it, because they stub
`process.request` and never reach the renderer at all.

- **A live Neovim, driven through the real input layer.** Start
  `nvim --headless -u NONE -i NONE --listen /tmp/s.sock -c "luafile <setup>"`,
  then drive it with
  `nvim --headless -u NONE -i NONE --server /tmp/s.sock --remote-expr "luaeval('vim.api.nvim_input_mouse(...)')"`.
  Mappings, `getmousepos()`, gesture dispatch, and window boundaries all
  behave for real. Two dead ends already paid for: `nvim --headless -l` never
  processes the injected input, and `--embed` plus `nvim_ui_attach` from an
  `-l` client kills the server.
- **A real Chromium renderer subprocess**, via the `startRenderer` harness in
  `tests/node/selection.test.js`. `discoverChromium` finds the system browser;
  never run `playwright install`.
- **Chain the two.** Record the exact `interact` params a real drag produces
  against a real `preview.placement()`/`preview.viewport()` pair, then feed
  those verbatim into the real renderer and compare before/after. Hand-built
  fixtures encode the same assumptions as the fix and will agree with it.

## Tests

All four gates in policy §5 must pass:

```bash
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
stylua --check lua/ plugin/ tests/lua/
```

Beyond that, per lever:

- Anything touching the PNG or placement path (A, C): assert the image bytes
  reaching the backend are byte-identical to what the file path produced, so
  a transport change cannot silently truncate a frame.
- Anything touching `renderer/src/interact.js` (A, B): add to
  `tests/node/selection.test.js`, which covers the DOM half against real
  Chromium, rather than starting a new file.
- Anything that caches state across frames (B, and any anchor cache): the
  superseded-request test described above.
- Anything touching `applyScroll` or scroll position: assert a hit test after
  a find or a fragment jump still resolves against the position on screen.
  This repository has had that bug once already — see the
  `display_interact_result` `scrollY` fix — and skipping a scroll is exactly
  how it comes back.

## Reporting

Follow policy §7. In addition, state explicitly:

- before/after numbers against the same document as stage 1's table above, so
  all three rounds are comparable;
- which levers you built, which you measured and rejected, and which you left
  alone because the risk exceeded the measured gain — **that third list
  should not be empty by default**;
- whether the four exonerated suspects really are noise, with the arithmetic;
- **that you cannot validate this.** Whether the drag *feels* crisp and snappy
  is the operator's call, made by dragging in a real terminal. Per policy §4,
  do not describe the result as validated. If you used the operator as a
  measuring instrument, say exactly what you asked for and what came back,
  separately from your own headless work.
