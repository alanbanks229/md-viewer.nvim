---
part: follow-up
title: Drag-to-highlight, round 2 — the css-scale blur and the off-window freeze are both still broken
status: done
model: Opus 5
depends_on: prompts/drag_highlight_stage_1_fast_frames.md (done, commit 2bcee86, 4055eca, 9063ca3)
commit: c44e22f
---

# Drag-to-Highlight, Round 2

> Read `prompts/00-policy.md` first. Its §3 architectural invariants, §4
> honesty requirements, and §5 test gates all apply to this work unchanged.

## Why you're being handed this instead of the previous session continuing

Sonnet 5 shipped `prompts/drag_highlight_stage_1_fast_frames.md` (capture
scale + debounce/pacing fix, committed as `2bcee86`), then attempted a
follow-up round for two operator-reported bugs against that change. That
follow-up is **uncommitted, sitting in the working tree right now** —
`git status` will show it. **Do not assume it is correct.** The operator
tested it in a real terminal and reported both bugs still present. Start by
reading `git diff` in full, understand what it was trying to do and why
(explained below), and then decide for each hunk whether to keep it, fix it,
or throw it out. A wrong fix that happens to pass headless Lua tests is not
a smaller problem than no fix — this codebase's own policy (§4) exists
because "the tests pass" and "the operator sees it work" have diverged
before.

**Do not commit anything.** The operator will validate manually and report
back. Do not touch `prompts/drag_highlight_stage_2_transport.md`'s content
beyond what's already there unless your investigation genuinely lands you in
its five suspects (it might — see below).

---

## The two bugs, in the operator's own words

> Emojis get larger while I am highlighting [text]. ... I hold down left
> click -> I drag the mouse -> as I am dragging, the view and the pane seems
> to get blurry, and while dragging the emojis remain large -> When I stop
> dragging but my left click is still holding down, the cursor and the pane
> refocuses and clears up. In other words the emojis are back to a focused
> regular size -> When I finally let go of the left click, the text still
> stays highlighted and emojis and text are still the same focused clear
> size.

> if my cursor goes off of the markdown render page, into another part of
> the neovim pane (like to the left) my vertical 'y' position is clearly
> above the area where it is unhighlighted and I expect that area to be
> highlighted even if my cursor gets off the markdown render screen (while
> my cursor is still head down because I am dragging/highlighting still)
> ... It seems like the issue with trying to highlight text while the mouse
> navigates off the Render markdown view is not implemented.

Screenshots exist (referenced in the conversation this prompt was written
from) showing emoji rendered visibly larger/blurrier mid-drag versus at rest,
and a drag whose highlighted region stops extending once the mouse leaves the
preview split into a source-buffer pane to the left.

---

## What the uncommitted attempt did, and why it apparently isn't enough

### Attempt at bug 1 (emoji/blur)

Stage 1 made the moving drag-preview frame capture at `render.fast_scroll`'s
scale (`"css"` by default — half the pixel density of `"device"`), reusing
the same lever `controller.schedule_scroll` already uses for its own moving
frame. The uncommitted follow-up added an **idle-settle timer**: after
`render.scroll_settle_ms` (160ms default) with no further drag movement,
`M.schedule_selection_preview` (`lua/md-viewer/interaction.lua`) fires one
extra device-scale frame even though the mouse button is still down,
mirroring `controller.schedule_scroll`'s own `scroll_settle_timer`. New
`local function attempt_selection_preview(session, pointer, force_device)`
holds the actual dispatch; `M.schedule_selection_preview` now both paces the
ordinary preview frames and (re)arms `"drag_idle_settle_timer"` via
`debounce.call`.

**The operator's report of stopping-but-still-held reads exactly like this
mechanism working** ("stop dragging but left click still down... emojis
back to focused regular size"). But they open by saying "it's still not
fixed" and describe the *actively moving* period as the problem: blurry,
emoji "remain large" for as long as the drag keeps moving. That period was
never meant to be sharp — it's the entire point of the css-scale reuse, the
same tradeoff scrolling already has. Two real possibilities, not mutually
exclusive:

1. **This is working as designed, and "working as designed" is not
   acceptable here.** Scrolling's blur-while-moving is tolerable because a
   scroll gesture is typically fast and transient — you're not reading text
   mid-scroll. A drag-to-select gesture is the opposite: the reader's eye is
   on the exact glyphs being selected while the mouse is still moving slowly
   across them, especially near the end of a selection. If that's the honest
   conclusion, the fix is not "sharpen it faster" but "don't soften it in
   the first place for drag" — i.e., partially or fully revert the
   capture-scale half of stage 1's own change for the *preview* frame, and
   find the speed win somewhere else (stage 2's suspects, most plausibly —
   see below). Verify this conclusion before acting on it: check whether the
   operator's actual dragging speed/pattern is "slow and deliberate" (which
   would confirm the hypothesis) by asking, or by reasoning about what
   `render.scroll_settle_ms = 160` implies about how long "actively moving"
   windows typically are for a real drag.

2. **"Remain large" is not just blur.** The operator's wording describes a
   *size* change, not only softness. Re-derive whether that's literally
   possible: `page.screenshot({ scale: "css" })` vs `{ scale: "device" }`
   changes the PNG's pixel dimensions, not the CSS layout/content depicted —
   so the same logical content at a different resolution, displayed by the
   terminal backend at the *same target cell rectangle*, should just be
   blurrier, not bigger. Confirm that assumption against the actual code:
   read `lua/md-viewer/backends/kitty_raw.lua`'s `M.show`/`place_regions`/
   `chunks` and check whether the Kitty graphics protocol placement it emits
   specifies a **fixed cell target** (independent of the PNG's own pixel
   dimensions) or something derived from the PNG's own width/height — if
   it's the latter, a css-scale PNG could genuinely be placed at different
   on-screen dimensions than a device-scale one, which would be a real
   sizing bug, not a perceptual blur. Also check `preview.placement()` and
   whatever computes the placement's cell width/height, and whether that
   computation reads anything from the image itself versus purely from the
   window's own geometry (it should be the latter — verify it actually is,
   for both code paths). If you find a genuine placement/sizing
   inconsistency between the two capture scales, that is very likely the
   real bug, independent of blur.

   Also worth checking, since it fits "emojis specifically, more than
   plain text": whether the earlier, already-shipped work on raw-image
   placement bugs is relevant here. `docs/cross-platform-implementation-status.md`
   has an extensive history of placement roll/bleed/misalignment bugs fixed
   post-Part-6 (`kitty_raw.lua`'s `move()`, double-buffer swap ordering,
   `raw_zindex`, exclusions). Consider whether *rapid* successive
   `M.update()` calls during a genuinely fast real drag (which a human
   dragging continuously produces far more of than any of the previous
   headless benchmarks simulated) could be re-triggering one of those
   already-"fixed" artifacts — a race between an old placement's deletion
   and a new one's creation, visible as a transient double-exposure or
   misaligned overlap that a human eye reasonably describes as "got bigger."
   `resolve_double_buffer()` and `M.update`'s clear-then-show vs.
   show-then-clear ordering are the place to look.

### Attempt at bug 2 (off-window freeze)

Root cause identified: `M.locate` (`lua/md-viewer/interaction.lua`) refuses
(`return nil`) whenever `mouse.winid ~= session.preview_win`, and `on_drag`
was unconditionally overwriting `pointer.newest_pending_drag_point` with
that `nil`, which then blocked `schedule_selection_preview` from ever firing
again for the rest of the gesture. The uncommitted attempt added
`M.locate_for_drag(session, mouse)`: tries the exact point first if the
window matches, otherwise (or if that still fails — e.g. same window but
below the placed image) clamps `screenrow`/`screencol` into
`session.last_placement`'s rectangle before calling
`coordinates.cell_to_css`. `on_drag` and `on_release` were switched to call
this instead of `M.locate`. `M.locate` itself was left untouched (still
strict — it also gates whether a *press* may begin a gesture at all, which
must never clamp).

This has real Lua unit-test coverage (`tests/lua/cases/selection.lua`) that
passes, including a synthetic `on_drag`/`on_release` sequence with a mouse
table whose `winid` doesn't match `session.preview_win`, asserting a request
still goes out with edge-clamped coordinates. **The operator's real terminal
says this does not happen at all.** That gap between "passes a Lua-level
simulation" and "does nothing in a real terminal" is the important signal:
it suggests the bug may not be in `interaction.lua`'s coordinate math at
all, but in whether `on_drag`/`on_release` ever get *called* once the mouse
leaves the preview window in a real terminal session. Investigate before
patching further:

1. **Does `<LeftDrag>`/`<LeftRelease>` even fire md-viewer's mapping once
   the pointer is over a different window?** `lua/md-viewer/mouse.lua`
   installs these as global (non-buffer-local) `expr` mappings for `n`/`i`/`v`
   modes via `install_gesture`. Global mappings apply regardless of which
   window the *mouse* is hovering, but mapping resolution still checks
   **buffer-local** mappings of whichever buffer currently has **editor
   focus** — which does not change just because the mouse moved over another
   window without a click. If the window the operator dragged into (a
   source-code split, per their report) has some *other* plugin's
   buffer-local `<LeftDrag>`/`<LeftRelease>` mapping for that filetype, it
   could be shadowing md-viewer's global one for exactly as long as that
   other buffer holds focus — which, during a drag that started in the
   preview and never had its own click in that window, might be the
   *entire* drag. Check with `:verbose map <LeftDrag>` and
   `:verbose map <LeftRelease>` in both `n` and `i` mode, with focus
   actually on a plausible other-pane buffer, in a real Neovim session. This
   is the most likely single point of failure and the cheapest to check
   first, before touching any Lua logic at all.
2. **Does Neovim's own built-in mouse handling intercept the event first**
   for a drag that crosses a window boundary — e.g. treating it as a
   window-resize drag if it started near a border, or extending a Visual
   selection in the window now under the pointer? If either happens, the
   event may never reach an `expr` mapping resolution at all for the second
   window's context.
3. **Only once (1) and (2) are ruled out**, suspect the clamp math itself.
   If you get this far, the likely gap is that `fake_session()` in
   `tests/lua/cases/selection.lua` hand-writes a simplified
   `last_placement` (`{row=0, col=0, width=80, height=24, exclusions={}}`)
   that may not represent what `preview.placement()` actually produces for
   a real `kitty_raw` session (statusline guard cells, overlay bleed,
   `raw_cell_offset_px` — see `lua/md-viewer/preview.lua` and
   `lua/md-viewer/config.lua`'s `image.*` fields) — a real placement's
   `row`/`col`/`width`/`height` might not be what the clamp math assumes.
   Reproduce with a **real** placement object (drive an actual
   `controller.open` + real render, read `session.last_placement` back, and
   feed *that* into `locate_for_drag` with synthetic out-of-window mouse
   input) rather than trusting the hand-built fixture.

Do not assume it's (3) just because it's the easiest one to keep debugging
in Lua without a terminal. (1) and (2) are Neovim/terminal-input-layer
questions that no amount of headless Lua testing can rule out, and the
gap between "passes headless" and "operator sees nothing happen" is
specifically the shape of bug you'd expect from (1) or (2).

---

## What must not change

Everything `prompts/drag_highlight_stage_1_fast_frames.md` and
`prompts/drag_highlight_stage_2_transport.md` already state, repeated
because those apply here too:

- Staleness lanes (`renderer/src/lanes.js`) — an `interact` admission can
  never invalidate `content` or `capture`.
- One request in flight, newest-point-only coalescing —
  `session.coalesced_drag_events` must keep counting what that drops.
- A sharp, device-scale frame is still guaranteed at the end of every
  gesture (`M.settle_selection` on release). Whatever you do to the moving
  frame, do not weaken this.
- No `innerHTML` anywhere in a selection path.
- `javaScriptEnabled: false` on the browser context.
- The `cells` backend is unaffected — no image, no selection.
- No new process, no second transport, no listening port.
- `M.locate` (used by press/click) must stay strict. Whatever you do for the
  drag-in-progress case must not let a *new* gesture begin from outside the
  window.

## Constraints on the fix

- Any new/changed tunable goes in `lua/md-viewer/config.lua` with a
  `validate()` assertion, mirroring an existing name where one fits — same
  rule stage 1 followed.
- If you conclude the css-scale reuse for drag preview frames was wrong and
  revert it (fully or partially), say so plainly in your report and explain
  why, including what you checked to rule out the alternative (a placement
  bug). Reverting a previous session's change because it turned out to be
  the wrong call is a legitimate, honest outcome — do not keep it just
  because it was already written.
- If bug 2 turns out to be a mapping-shadowing issue (hypothesis 1 above),
  the fix is very likely not in `interaction.lua` at all — resist the pull
  to keep iterating on coordinate-clamping code that already has passing
  tests just because it's the code you can most easily verify headlessly.

## Diagnostic method — measure/verify before you patch again

Neither you nor the previous session has a graphical terminal in this
environment. The previous session's mistake (per the operator's report) was
plausibly writing a plausible-sounding fix, proving it with a Lua-level
simulation that encodes the same assumptions as the fix itself, and treating
that as sufficient. Don't repeat that. Concretely:

- For bug 2, before writing any more Lua: add a temporary, extremely visible
  diagnostic (a `vim.notify` or a line appended to a buffer, not something
  that could be silently swallowed) inside `M.on_drag` and `M.on_release`
  that fires unconditionally on every call, logging `mouse.winid`,
  `session.preview_win`, and whether a point resolved. Ask the operator to
  reproduce the off-window drag once with this in place and report exactly
  what appeared (or didn't). This one piece of evidence disambiguates
  hypotheses (1)/(2) from (3) immediately and cheaply, and is exactly the
  kind of real-environment fact this repo's policy (§4, "do not claim
  graphical validation you did not observe") expects you to go get rather
  than infer. Remove the diagnostic before finishing.
- For bug 1, if you go down the "verify it's a real sizing bug, not blur"
  path, the equivalent move is: capture a `selection_preview` response's
  `pngPath` at `"css"` scale and at `"device"` scale for the *same* document
  and viewport (the existing stage-1 benchmarking pattern in
  `docs/cross-platform-implementation-status.md`'s "Post-Part-7 follow-up"
  section shows exactly how — reuse that method, don't reinvent it), and
  compare their actual pixel dimensions against what `preview.placement()`
  computes for each. If the placement math is scale-blind (as it should be)
  and the dimensions check out, that's real evidence for hypothesis 1
  (perceptual, not a bug) over hypothesis 2, and should change what you
  spend the rest of your time on.

## Tests

All four gates in `prompts/00-policy.md` §5 must pass:

```bash
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
stylua --check lua/ plugin/ tests/lua/
```

The uncommitted `tests/lua/cases/selection.lua` additions (749 assertions
total as of this writing) should be reviewed on their own merits, not kept
by default — if bug 2's real root cause is outside `interaction.lua`
entirely, some of those new assertions may be testing the wrong layer and
should be replaced or removed rather than padding the suite with tests that
pass regardless of whether the operator's actual bug is fixed. Whatever you
land on, add a regression test for the *actual* root cause once you've
confirmed it — not before.

## Reporting

Follow `prompts/00-policy.md` §7. In addition:

- State plainly, for each bug, which hypothesis turned out to be correct and
  what evidence (not assumption) established it.
- If you kept, modified, or reverted any part of the uncommitted attempt,
  say which and why.
- Per §4: you cannot validate this against a real terminal either. Say so.
  If you used the operator as a diagnostic instrument (the `vim.notify`
  approach above), say exactly what you asked them to do and what they
  reported back, distinctly from your own headless verification.
- Do not commit. Leave the working tree for the operator to review and
  decide whether to commit, amend, or discard.
