---
part: follow-up
title: Drag-to-highlight responsiveness, stage 2 — transport and per-frame waste
status: not started
model: Opus 5
depends_on: prompts/drag_highlight_stage_1_fast_frames.md (must be done, committed, and judged insufficient)
commit:
---

# Drag-to-Highlight Responsiveness — Stage 2

> Read `prompts/00-policy.md` first. Its §3 architectural invariants, §4 honesty
> requirements, and §5 test gates all apply to this work unchanged.

## Do not start this without checking the precondition

This stage exists only because stage 1 was not enough. Before touching anything,
confirm all three:

1. `prompts/drag_highlight_stage_1_fast_frames.md` is done and committed.
2. Its measurements are filled in below.
3. The operator has dragged in a real terminal since, and said it is **still**
   too slow.

If any of those is missing, stop and say so. Every change in this stage is more
invasive than everything in stage 1 combined, and several of them can break
selection correctness in ways that do not crash — they copy the wrong text.

## Why this stage is the risky one

Stage 1 changed how big a picture is and how often it is asked for. Stage 2
changes **how a frame gets from Chromium to the terminal**, and **what state
survives between frames**. The invariants at risk are cross-file, and their
failure mode is silent: a selection resolved against the wrong content revision
does not raise, it copies the wrong characters into the user's clipboard.

Assume any change here is wrong until a test says otherwise.

---

## Measurements from stage 1

Two throwaway benchmark scripts (not committed), both driving the real
renderer subprocess and real Chromium, no stubbing: a Node-side script
modeled on `tests/node/interact.test.js`'s subprocess harness, and a
Lua-side script modeled on `tests/lua/cases/process.lua`'s real
(non-stubbed) subprocess usage. Both ran the same 20-frame simulated drag
sweep over the same document (`kitchen-sink.md` + 60 filler paragraphs,
5,400 characters, 90 layout blocks) on the same machine. Full method and a
third pacing/starvation measurement are in
`docs/cross-platform-implementation-status.md`'s "Post-Part-7 follow-up:
drag-highlight responsiveness, stage 1" section — this is the condensed
version for this file.

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

`captureMs` (the `page.screenshot()` call) accounts for ~95% of `totalMs` at
both scales. Node- and Lua-observed wall-clock agree closely (68.4 vs 67.9,
33.2 vs 32.5), meaning nothing meaningful is being lost or added between the
renderer's own numbers and what Lua actually experiences.

Debounce/pacing, same machine:

```
first-dispatch latency (single on_drag call):
  drag_debounce_ms=40 (old default): 37.71 ms before the request is sent
  drag_debounce_ms=0  (new default):  0.01 ms

requests actually sent over a continuous 300ms drag (new point every 15ms):
  drag_debounce_ms=40 (old default): 1 request for the whole gesture
  drag_debounce_ms=0  (new default): 11 requests, coalesced_drag_events=19
```

Exonerated by stage 1's measurements:

```
- page.evaluate's selection-resolve step (rehydrateMs): ~1ms either way,
  ~1.5-3% of totalMs at either capture scale. Not a meaningful lever.
- The Lua-side PNG read (fs_read) and base64 encode: both sub-millisecond
  (~0.03-0.1ms) at either scale. Neither needed optimizing.
- Suspect 5 (applyScroll running unconditionally per interact) is plausible
  only as noise inside rehydrateMs above -- not measured directly, since it
  was out of stage 1's scope, but the ~1ms rehydrateMs total leaves little
  room for it to matter on its own.
```

Not exonerated, and still this stage's territory: suspects 1 (temp-file
`fs_read` blocking the main loop), 2 (full PNG re-upload per frame), 3
(anchor re-resolution), and 4 (`page.evaluate` re-serialization) were not
measured at all here -- they are transport/protocol-level, not
capture-scale/pacing, and stage 1 did not touch the files that would let
them be measured in isolation.

---

## What must not change

Repeated in full, because this file is read on its own:

- **Staleness lanes** (`renderer/src/lanes.js`). An `interact` admission can
  never invalidate `content` or `capture`. A burst of drag frames cannot cancel
  a render. Do not add a path from one to the other.
- **One request in flight, newest pending point only**, and
  `session.coalesced_drag_events` which counts what that drops.
- **A device-scale settle frame after release** (`interaction.settle_selection`).
  Whatever the moving frames cost, the final frame must be sharp.
- **Requests are stateless and replayable.** This is the constraint that makes
  suspect 3 below dangerous: a superseded or replayed request must never pick up
  another request's cached state.
- **No `innerHTML` anywhere in a selection path.** `setBaseAndExtent` /
  `Text.splitText` only, so a selection containing literal HTML is copied
  character-for-character.
- **`javaScriptEnabled: false`** on the browser context (policy §3).
  `page.evaluate` still works with it off; `requestAnimationFrame` inside the
  page does not.
- **The `cells` backend is unaffected** — no image, no selection.
- **No new process, no second transport, no listening port** (policy §3).

---

## The five remaining suspects

Ranked by expected value from a code reading, which stage 1's numbers may have
already reordered. **Follow the numbers, not this list.** Take them one at a
time, with the gates green between each — a batch of five that lands together is
not attributable when something goes wrong.

1. **A temp file per frame**, including a synchronous blocking `fs_read` on
   Neovim's main loop (`lua/md-viewer/renderer.lua`). Every frame: create, stat,
   read, unlink. The blocking read is the part that stalls the editor rather
   than merely costing time.
2. **Full PNG re-encode and full base64 re-upload per frame**
   (`lua/md-viewer/backends/kitty_raw.lua` — `M.update` uploads a whole new
   image and deletes the old). Largely mitigated by stage 1, since the PNG
   shrank. A damage-rectangle upload is the deeper fix and is considerably more
   work; do not start there.
3. **The drag anchor is re-resolved from scratch every frame**
   (`renderer/src/interact.js`) even though it is fixed for the whole gesture.
   Two `TreeWalker` scans per frame where one would do. The stateless/replayable
   constraint above is the trap: any anchor cache must be keyed so a superseded
   or replayed request cannot pick up the wrong one. If you cannot state that key
   in one sentence, do not build the cache.
4. **`page.evaluate` re-serializes ~130 lines of function source every frame.**
   `addInitScript` could install it once. Interacts with
   `javaScriptEnabled: false` — verify that path actually works before
   committing to it, and note that `setContent` destroys page state on every
   document switch.
5. **`applyScroll` runs unconditionally per interact**
   (`renderer/src/browser.js`), a wasted CDP round trip when `scrollY` has not
   moved. The cheapest item here, and the one most likely to be measurable only
   in aggregate.

## Constraints on the fix

- Any new tunable goes in `lua/md-viewer/config.lua` with a `validate()`
  assertion in the existing style, mirroring an existing name where one fits.
- The moving-frame/settle-frame split must remain observable in
  `:MdViewerDebug` through the existing `fast_*` and `retina_*` fields.
- If a change makes an existing diagnostic meaningless, remove the diagnostic in
  the same commit rather than leaving it reporting a number nobody can use.

## Tests

All four gates in policy §5 must pass. Beyond that, per suspect:

- Anything touching the anchor cache (3) needs a test that a **superseded**
  request cannot consume a later request's anchor. Drive two overlapping
  requests with a stubbed transport and assert the older one is discarded, not
  answered from the newer one's state.
- Anything touching `interact.js` (3, 4): `tests/node/selection.test.js` covers
  the DOM half against real Chromium. Add to it rather than starting a new file.
- Anything touching the PNG path (1, 2): assert the image bytes that reach the
  backend are byte-identical to what the file path produced, so a transport
  change cannot silently truncate a frame.
- Anything touching `applyScroll` (5): assert a hit test after a find or a
  fragment jump still resolves against the position on screen. That is a bug
  this repository has already had once — see the `display_interact_result`
  `scrollY` fix — and skipping a scroll is exactly how it comes back.

## Reporting

Follow policy §7. In addition, state explicitly:

- before/after numbers against the same document and terminal as stage 1's, so
  the two stages are comparable;
- which suspects you changed, which you exonerated, and which you left alone
  because the risk was not worth the measured gain — the third category is a
  real answer and should not be empty by default;
- **that you cannot validate this.** Whether the drag feels responsive is the
  operator's call, made by dragging in a real terminal. Per policy §4, do not
  describe the result as validated.
