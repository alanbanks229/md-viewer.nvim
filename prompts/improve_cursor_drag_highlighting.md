---
part: follow-up
title: Make drag-to-highlight feel responsive
status: not started
model: Sonnet 5 (high)
depends_on: parts 3-7 (all done)
commit:
---

# Follow-up — Drag-to-Highlight Responsiveness

> Read `prompts/00-policy.md` first. Its §3 architectural invariants, §4 honesty
> requirements, and §5 test gates all apply to this work unchanged.

## Objective

Drag-to-select works correctly and feels too slow. The operator's report, from
real use on iTerm2: *"dragging to highlight text is rendering so slow."*

Your job is to **diagnose first and then fix**, not to apply the list below as a
patch set. The measurements in "What is already known" are a starting point that
someone else took by reading the code — they are not a work order, and at least
one of them may turn out not to be the thing the operator is actually feeling.

Correctness is not on the table. A faster drag that occasionally highlights the
wrong range, or that lets a stale frame reach the screen, is a regression, not an
improvement.

---

## Verified repository facts

### The full round trip, per drag frame, as it exists today

```
<LeftDrag>                              lua/md-viewer/mouse.lua:54
  -> vim.fn.getmousepos()
  -> vim.schedule(...)
  -> interaction.on_drag                lua/md-viewer/interaction.lua:137
  -> 40 ms debounce timer               interaction.lua:164, config drag_debounce_ms
  -> vim.json.encode + pipe write       lua/md-viewer/process.lua:121
  -> Node readline, lane admission      renderer/src/lanes.js
  -> serial promise queue               renderer/src/main.js:103
  -> ensureDocumentActive()             renderer/src/browser.js
       -> page.evaluate(window.scrollTo)   -- unconditional, even when unchanged
  -> page.evaluate(resolveSelectionInPage) renderer/src/interact.js:529-712
       -- ~130 lines, re-serialized via fn.toString() on every call
       -- two TreeWalker scans: one per endpoint, both endpoints every frame
  -> page.screenshot() FULL VIEWPORT AT DEVICE SCALE   browser.js:155
  -> PNG written to a temp file, fs.statSync
  -> JSON reply over stdout
  -> Lua BLOCKING fs_stat + fs_read on the main loop   lua/md-viewer/renderer.lua:14-24
  -> fs_unlink
  -> vim.base64.encode of the whole PNG                backends/kitty_raw.lua:204
  -> 4096-byte APC chunks -> nvim_ui_send
  -> terminal decodes and composites
```

### The pattern the scroll path already uses, and drag does not

`controller.schedule_scroll` (`lua/md-viewer/controller.lua:257-290`) is the
existing, working answer to the same problem:

```lua
local fast_scale = render.fast_scroll and "css" or "device"
if session.scroll_render_in_flight then
  session.scroll_render_pending = true            -- coalesce, do not queue
else
  session.scroll_render_in_flight = true
  M.refresh(session, { capture_scale = fast_scale, capture_only = true, ... })
end
if render.fast_scroll then
  M.schedule(session, render.scroll_settle_ms, "scroll_settle_timer", {
    capture_scale = "device", capture_only = true,
  })
end
```

Two things to notice: the moving frame fires **immediately** (no debounce ahead of
it — one-in-flight backpressure is the only limiter), and it is captured at
**`"css"` scale**, with a single `"device"` frame after input settles.

Drag does neither. `interaction.lua:178` hardcodes `"device"` for every preview
frame, and `interaction.lua:164` puts a 40 ms debounce in front of the request.

Per `docs/architecture.md:31-38`, a device-scale PNG is a **fourfold pixel area**
versus CSS scale. That comment exists because the same problem was already solved
once, for scrolling.

### What must not change

- **Staleness lanes** (`renderer/src/lanes.js`). An `interact` admission can never
  invalidate `content` or `capture`. A burst of drag frames cannot cancel a
  render. Do not add a path from one to the other.
- **One request in flight, newest pending point only** — the coalescing at
  `interaction.lua:168-175`, and `session.coalesced_drag_events` which counts it.
- **A device-scale settle frame after release.** `settle_selection`
  (`interaction.lua:229`) already does this. Whatever the moving frames cost, the
  final frame the user is left looking at must be sharp.
- **No `innerHTML` anywhere in a selection path.** Selections use
  `setBaseAndExtent` / `Text.splitText` so a selection containing literal HTML is
  copied character-for-character. `docs/architecture.md` "Selection, search, and
  copy" is the contract.
- **`javaScriptEnabled: false`** on the browser context (policy §3). `page.evaluate`
  still works with it off; `requestAnimationFrame` inside the page does not.
- **The `cells` backend is unaffected** — it has no image and no selection.
- **No new process, no second transport, no listening port** (policy §3).

---

## What is already known (a starting point, not a work order)

Ranked by expected value from a code reading. **Measure before you accept any of
them.**

1. **`captureScale` is `"device"` on every drag preview frame.** `interaction.lua:178`
   passes `"device"`; `interaction.lua:237` passes `"device"` again for the commit,
   which is correct. Only the preview frames are wrong. The cheapest, largest win
   available, and it is a one-word change plus a config knob to match
   `render.fast_scroll`.
2. **The 40 ms `drag_debounce_ms` is latency added ahead of a pipeline that already
   has backpressure.** Scrolling proves the debounce is not needed to stay stable.
3. **A temp file per frame**, including a synchronous blocking `fs_read` on Neovim's
   main loop (`renderer.lua:14-24`). Every frame: create, stat, read, unlink.
4. **Full PNG re-encode and full base64 re-upload per frame** (`kitty_raw.lua:199-223`;
   `M.update` uploads a whole new image and deletes the old). Largely mitigated by
   (1) since the PNG shrinks; a damage-rectangle upload would be the deeper fix and
   is considerably more work — do not start there.
5. **The drag anchor is re-resolved from scratch every frame** (`interact.js:697`)
   even though it is fixed for the whole gesture. Two `TreeWalker` scans per frame
   where one would do. Note the deliberate design constraint at `interact.js:188-190`:
   requests are stateless and replayable, so any anchor cache must be keyed such
   that a superseded or replayed request cannot pick up the wrong one.
6. **`page.evaluate` re-serializes ~130 lines of function source every frame.**
   `addInitScript` could install it once. Interacts with `javaScriptEnabled: false`
   — verify that path actually works before committing to it.
7. **`applyScroll` runs unconditionally per interact** (`browser.js`), a wasted CDP
   round trip when `scrollY` has not moved.

---

## Diagnose first

Before changing anything, produce numbers. `:MdViewerDebug` already reports, per
session:

```
capture_ms, image_update_ms, png_bytes, capture_scale
fast_capture_ms,   fast_png_bytes,   fast_image_update_ms
retina_capture_ms, retina_png_bytes, retina_image_update_ms
coalesced_drag_events, interaction_request_count, interaction_stale_count
```

Report, for a slow drag over a real document on real hardware:

- wall-clock per drag frame, split into: Lua dispatch, IPC, `page.evaluate`
  (selection), `page.screenshot`, PNG read, base64, terminal write;
- how many drag events were coalesced away versus actually sent;
- the PNG byte size at `"device"` versus what it would be at `"css"`;
- whether the bottleneck is the *renderer* (capture) or the *terminal transfer*
  (image update) — `capture_ms` versus `image_update_ms` answers this directly,
  and they point at completely different fixes.

If the numbers say the dominant cost is somewhere not on the list above, follow
the numbers. Say so plainly in your report.

---

## Constraints on the fix

- Any new tunable goes in `lua/md-viewer/config.lua` with a `validate()` assertion
  in the existing style, and mirrors an existing name where one fits
  (`render.fast_scroll` / `render.scroll_settle_ms` are the obvious models —
  consider whether drag should simply *reuse* them rather than inventing
  `fast_drag`).
- Preserve `interaction.drag_debounce_ms` and `interaction.settle_ms` as
  user-facing knobs even if their defaults change. Changing a default is a
  behaviour change and belongs in `CHANGELOG.md`.
- The moving-frame/settle-frame split must remain observable in `:MdViewerDebug`
  through the existing `fast_*` and `retina_*` fields.

## Tests

All four gates in policy §5 must pass. Beyond that:

- `tests/lua/cases/selection.lua` — assert the **preview** frames request the fast
  scale and the **commit** frame requests `"device"`. This is the regression test
  for the headline fix and it is pure Lua: stub `process.request` and inspect
  `params.captureScale`, exactly as the existing cases in that file do.
- Assert one-request-in-flight and newest-point-only survive whatever pacing
  changes: drive `on_drag` repeatedly with a stubbed transport and check that
  `coalesced_drag_events` still counts the dropped points and that no second
  request is issued while one is outstanding.
- Assert the settle frame still fires after release, still at device scale, and
  still after any in-flight preview completes (`pointer.pending_settle`).
- If you touch `interact.js`, `tests/node/selection.test.js` covers the DOM half
  against real Chromium; add to it rather than starting a new file.

## Reporting

Follow policy §7. In addition, state explicitly:

- the before/after numbers, from the same document on the same terminal;
- what you changed and what you deliberately did not;
- anything on the "already known" list that the measurements **exonerated** — that
  is as useful to record as the fix, and it stops the next session re-treading it;
- that no graphical validation was performed unless you personally ran it in a
  terminal and looked, per policy §4.
