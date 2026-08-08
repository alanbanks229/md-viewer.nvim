---
part: follow-up
title: Drag-to-highlight responsiveness, stage 1 — measure, then fast frames
status: done
model: Sonnet 5 (high)
depends_on: parts 3-7 (all done)
next: prompts/drag_highlight_stage_2_transport.md (only if this is not enough)
commit: (recorded in a follow-up doc-only commit)
---

# Drag-to-Highlight Responsiveness — Stage 1

> Read `prompts/00-policy.md` first. Its §3 architectural invariants, §4 honesty
> requirements, and §5 test gates all apply to this work unchanged.

## Objective

Drag-to-select works correctly and feels too slow. The operator's report, from
real use on iTerm2: *"dragging to highlight text is rendering so slow."*

This stage does **two things and stops**:

1. Produce real per-frame measurements.
2. Change only the capture scale and the drag pacing — the two causes that are
   cheap, local, and cannot break selection correctness.

Five further suspects exist. They are **out of scope here** and live in
`prompts/drag_highlight_stage_2_transport.md`, which is run by a different
session only if this stage turns out not to be enough. Do not touch them, and do
not read ahead for ideas: the split exists so the cheap fix is evaluated on its
own, without five riskier changes confounding the result.

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
  -> interaction.on_drag                lua/md-viewer/interaction.lua
  -> 40 ms debounce timer               config drag_debounce_ms      <-- stage 1
  -> vim.json.encode + pipe write       lua/md-viewer/process.lua:121
  -> Node readline, lane admission      renderer/src/lanes.js
  -> serial promise queue               renderer/src/main.js:103
  -> ensureDocumentActive()             renderer/src/browser.js
       -> page.evaluate(window.scrollTo)   -- unconditional        (stage 2)
  -> page.evaluate(resolveSelectionInPage) renderer/src/interact.js (stage 2)
  -> page.screenshot() FULL VIEWPORT AT DEVICE SCALE               <-- stage 1
  -> PNG written to a temp file, fs.statSync                       (stage 2)
  -> JSON reply over stdout
  -> Lua BLOCKING fs_stat + fs_read on the main loop                (stage 2)
  -> fs_unlink
  -> vim.base64.encode of the whole PNG                             (stage 2)
  -> 4096-byte APC chunks -> nvim_ui_send
  -> terminal decodes and composites
```

Line numbers drift; find the code by name, not by number.

### The pattern the scroll path already uses, and drag does not

`controller.schedule_scroll` (`lua/md-viewer/controller.lua`) is the existing,
working answer to the same problem:

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

Two things to notice: the moving frame fires **immediately** (no debounce ahead
of it — one-in-flight backpressure is the only limiter), and it is captured at
**`"css"` scale**, with a single `"device"` frame after input settles.

Drag does neither. `interaction.schedule_selection_preview` hardcodes `"device"`
for every preview frame and puts a 40 ms debounce in front of the request.

Per `docs/architecture.md`, a device-scale PNG is a **fourfold pixel area**
versus CSS scale. That comment exists because this problem was already solved
once, for scrolling.

---

## What must not change

- **Staleness lanes** (`renderer/src/lanes.js`). An `interact` admission can
  never invalidate `content` or `capture`. A burst of drag frames cannot cancel
  a render. Do not add a path from one to the other.
- **One request in flight, newest pending point only** — the coalescing in
  `interaction.schedule_selection_preview`, and `session.coalesced_drag_events`
  which counts it.
- **A device-scale settle frame after release.** `interaction.settle_selection`
  already does this. Whatever the moving frames cost, the final frame the user is
  left looking at must be sharp.
- **No `innerHTML` anywhere in a selection path.** Selections use
  `setBaseAndExtent` / `Text.splitText` so a selection containing literal HTML is
  copied character-for-character. `docs/architecture.md` "Selection, search, and
  copy" is the contract.
- **`javaScriptEnabled: false`** on the browser context (policy §3).
- **The `cells` backend is unaffected** — it has no image and no selection.
- **No new process, no second transport, no listening port** (policy §3).

---

## Step 1 — Diagnose. Numbers before edits.

`:MdViewerDebug` already reports, per session:

```
capture_ms, image_update_ms, png_bytes, capture_scale
fast_capture_ms,   fast_png_bytes,   fast_image_update_ms
retina_capture_ms, retina_png_bytes, retina_image_update_ms
coalesced_drag_events, interaction_request_count, interaction_stale_count
```

Report, for a slow drag over a real document:

- wall-clock per drag frame, split into: Lua dispatch, IPC, `page.evaluate`
  (selection), `page.screenshot`, PNG read, base64, terminal write;
- how many drag events were coalesced away versus actually sent;
- the PNG byte size at `"device"` versus what it would be at `"css"`;
- whether the bottleneck is the *renderer* (capture) or the *terminal transfer*
  (image update) — `capture_ms` versus `image_update_ms` answers this directly,
  and they point at completely different fixes.

**If the numbers say the dominant cost is not the capture scale or the debounce,
say so plainly and stop.** Do not apply stage 1's changes anyway because they
were the plan. An exonerated suspect is a useful result; a change that fixed
nothing is not.

Write the measurement table into the *Measurements from stage 1* section of
`prompts/drag_highlight_stage_2_transport.md`, whether or not stage 2 is ever
run. That file is where the next session will look, and re-taking these numbers
is the most obvious waste available to it.

## Step 2 — The two changes in scope

1. **`captureScale` is `"device"` on every drag preview frame.**
   `interaction.schedule_selection_preview` passes `"device"`;
   `interaction.settle_selection` passes `"device"` for the commit, which is
   correct. Only the preview frames are wrong. The cheapest, largest win
   available.
2. **The 40 ms `drag_debounce_ms` is latency added ahead of a pipeline that
   already has backpressure.** Scrolling proves the debounce is not needed to
   stay stable. Adopt `schedule_scroll`'s shape: fire immediately, coalesce on
   the in-flight flag, settle afterwards.

Nothing else. If you find yourself editing `renderer/src/browser.js`,
`renderer/src/interact.js`, `lua/md-viewer/renderer.lua`, or
`lua/md-viewer/backends/kitty_raw.lua`, you have left this stage's scope.

## Constraints on the fix

- Any new tunable goes in `lua/md-viewer/config.lua` with a `validate()`
  assertion in the existing style, and mirrors an existing name where one fits.
  `render.fast_scroll` / `render.scroll_settle_ms` are the obvious models —
  consider whether drag should simply **reuse** them rather than inventing
  `fast_drag`.
- Preserve `interaction.drag_debounce_ms` and `interaction.settle_ms` as
  user-facing knobs even if their defaults change. Changing a default is a
  behaviour change and belongs in `CHANGELOG.md`.
- The moving-frame/settle-frame split must remain observable in `:MdViewerDebug`
  through the existing `fast_*` and `retina_*` fields.

## Tests

All four gates in policy §5 must pass. Beyond that:

- `tests/lua/cases/selection.lua` — assert the **preview** frames request the
  fast scale and the **commit** frame requests `"device"`. This is the
  regression test for the headline fix and it is pure Lua: stub
  `process.request` and inspect `params.captureScale`, exactly as the existing
  cases in that file do.
- Assert one-request-in-flight and newest-point-only survive the pacing change:
  drive `on_drag` repeatedly with a stubbed transport, check that
  `coalesced_drag_events` still counts the dropped points and that no second
  request is issued while one is outstanding.
- Assert the settle frame still fires after release, still at device scale, and
  still after any in-flight preview completes (`pointer.pending_settle`).

## Reporting

Follow policy §7. In addition, state explicitly:

- the before/after numbers, from the same document on the same terminal;
- what you changed and what you deliberately did not;
- anything on the suspect list the measurements **exonerated**;
- **that you cannot validate this.** Whether the drag now *feels* responsive is
  the operator's call, made by dragging in a real terminal. Per policy §4, do
  not describe the result as validated. Say what the numbers moved and leave the
  verdict to them.

Then hand back. The operator decides whether
`prompts/drag_highlight_stage_2_transport.md` is needed at all.
