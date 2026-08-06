---
part: 4
title: Mouse layer, click-to-source, and safe links
status: not-started
model: Sonnet 5
depends_on: parts 1-3
commit: ""
---

# Part 4 of 7 — Mouse Layer, Click Navigation, and Safe Links

> Read `prompts/00-policy.md` first.

## Objective

Connect Neovim mouse gestures to the Part 3 transport. After this part, clicking
rendered content jumps to Markdown source and modifier-clicking a link opens it
safely — **end to end, in a real terminal.**

Source precision will be block or line level. Part 5 upgrades it to exact.

---

## Verified repository facts

**`lua/md-viewer/mouse.lua` (66 lines) handles only the scroll wheel.** Its
structure is the pattern to extend, not replace:

```lua
local modes = { "n", "i", "v" }
local wheels = {
  { lhs = "<ScrollWheelDown>", action = "wheel_down" },
  { lhs = "<ScrollWheelUp>",   action = "wheel_up" },
}
```

`install()` saves the prior mapping with `vim.fn.maparg(lhs, mode, false, true)`
into `saved[mode .. lhs]`, then sets an **expr mapping** that returns
`"<Ignore>"` when the pointer is over a preview and the original `lhs` otherwise.
That fall-through is exactly right — events outside a preview must not be
swallowed. Preserve the technique.

`detach_if_unused()` deletes the mapping and restores via
`vim.fn.mapset(mode, false, previous)` only when no graphical session remains.
`has_graphical_session()` checks `session.backend.name ~= "cells"`.

There is an existing regression test asserting that a pre-existing
`<ScrollWheelDown>` mapping of `<Nop>` is restored after close. Do not break it.

**Coordinate helpers available** in `lua/md-viewer/coordinates.lua` — see the
Part 2 prompt for the full inventory. Relevant here: `for_window`, `intersects`,
`overlapping_floats`, `passive_overlays`, `viewport`.

**`lua/md-viewer/state.lua`** provides `state.all()`, `state.get(buf)`, and
`state.from_preview_win(winid)` — that last one is how a mouse position becomes
a session.

**`lua/md-viewer/navigation.lua` (32 lines)** attaches preview-local mappings via
`vim.api.nvim_buf_call(session.preview_buf, ...)`. New preview-local mappings
belong here.

**`lua/md-viewer/sync.lua` (74 lines)** holds the source↔preview synchronization
guard that prevents feedback loops. Cursor moves from clicks **must** go through
it.

**Existing config:** `sync.preview_to_source` defaults to `false`.

---

## Read these files first

```text
lua/md-viewer/mouse.lua
lua/md-viewer/coordinates.lua
lua/md-viewer/state.lua
lua/md-viewer/sync.lua
lua/md-viewer/navigation.lua
lua/md-viewer/config.lua
lua/md-viewer/controller.lua
lua/md-viewer/renderer.lua
tests/lua/cases/
```

---

## Implement

### 4.1 Coordinate conversion — cells to CSS pixels

`vim.fn.getmousepos()` returns **1-based** screen and window cell coordinates.
Image placements are **0-based**. The terminal cannot report a sub-cell pointer
position, so use the centre of the cell:

```text
localCellX = screenColumn - 1 - placementColumn
localCellY = screenRow    - 1 - placementRow

cssX = ((localCellX + 0.5) / placementWidthCells)  * viewportWidthCssPx
cssY = ((localCellY + 0.5) / placementHeightCells) * viewportHeightCssPx
```

**Never multiply by a guessed pixel constant.** No `mouse.winx * 10`. Exact
physical cell dimensions are not required and must not be assumed — normalized
geometry is the whole point, and it is why this works on terminals whose cell
size you cannot measure.

Clamp the result to the Chromium viewport.

Account for: 1-based versus 0-based origins, winbar, statusline, global
statusline, tabline, split separators, command-line rows, resized windows,
cropped placements, passive-overlay exclusion rectangles, focusable floating
windows, and hidden or suppressed images.

**Do not dispatch an interaction when the pointer is inside an excluded or
occluded rectangle.** Reuse `coordinates.passive_overlays()` and
`coordinates.overlapping_floats()`.

### 4.2 Gesture model

Extend `mouse.lua` — do not create a second mapping system elsewhere.

Add `<LeftMouse>`, `<LeftDrag>`, `<LeftRelease>`, `<2-LeftMouse>`,
`<C-LeftMouse>`, and `<D-LeftMouse>` (Command-click, macOS). Use
platform-appropriate modifiers where available.

Per-session pointer state:

```text
pressed, press_cell, latest_cell, press_time, drag_started,
interaction_serial, selection_request_in_flight, newest_pending_drag_point,
content_revision, cached_selected_text
```

**Click versus drag** is classified by cell distance against
`interaction.drag_threshold_cells` (default `1`). Use Euclidean or maximum-axis
distance — pick one and apply it consistently. Never classify on guessed pixels.

- **Below threshold** → click: convert the release position, hit-test, resolve
  the most precise available source position, move the source cursor, record the
  reported precision.
- **At or above threshold** → drag: record the gesture and maintain the pointer
  state. **Do not create a selection in this part** — Part 6 does that. Wiring
  the state machine now means Part 6 is purely additive.
- **Double click** → reserved for word selection in Part 6. Make the binding
  configurable now so Part 6 does not have to break anything.
- **Modifier click** → link activation, §4.4.

The existing wheel dispatch must keep working unchanged.

### 4.3 Source cursor updates

Add a navigation function accepting:

```lua
{ line = number, byte_column = number, precision = string }
```

Before moving the cursor:

- Validate the source window is still valid.
- Clamp the line to the buffer line count.
- Clamp the byte column to the source line's **byte** length.
- Never place the cursor inside an invalid UTF-8 byte sequence.
- Go through the existing `sync.lua` guard. Do not create a feedback loop.

`nvim_win_set_cursor()` takes 1-based lines and **0-based byte columns**. Browser
text-node offsets and JavaScript string offsets are neither — they are UTF-16
code-unit offsets. Do not pass them through. In this part precision is block or
line level, so `byte_column` will usually be `0`; the clamping and validation
must still be correct and tested, because Part 5 starts feeding real columns
through this exact path.

Add configuration:

```lua
interaction = { focus_source_on_click = true }
```

When `false`, update the source cursor without changing the active window.

Record the last interaction's precision in debug output.

### 4.4 Safe link activation

Modifier-click resolves link metadata through the Part 3 `activate_at` action
and dispatches in **Lua**, by classification:

| Type | Behaviour |
|------|-----------|
| `fragment` | Scroll within the controlled Chromium document. |
| `http`, `https` | `vim.ui.open()`, only after an explicit user gesture. |
| `mailto` | `vim.ui.open()` where supported. |
| `local_file` | Only within the configured document root. |
| `unsafe` | Reject. Includes `javascript:`, `data:`, `file:` outside root. |

**The hidden Chromium page must never navigate away from the generated Markdown
document.** The renderer returns link metadata; it does not follow links. Reject
root escapes and symlink escapes — `lua/md-viewer/security.lua` and
`renderer/src/security.js` already do this for images; reuse that logic rather
than writing a second path validator.

An unmodified click on a link still performs source navigation.

### 4.5 Configuration

```lua
interaction = {
  enabled = true,
  click_to_source = true,
  focus_source_on_click = true,
  links = true,
  drag_threshold_cells = 1,
}
```

Validate every value with actionable errors, matching the existing `validate()`
style. **Do not enable interaction for the `cells` backend** — there is no image
to click.

---

## Do not do in this part

- No selection creation, no copy commands, no `:MdViewerCopy` — Part 6.
- No search — Part 6.
- No inline provenance; do not report `exact` precision — Part 5.
- Do not replace the expr-mapping fall-through technique in `mouse.lua`.

---

## Tests to add

**Lua** (`tests/lua/cases/mouse.lua`, `tests/lua/cases/interaction.lua`):

Stub `vim.fn.getmousepos()` to drive gestures deterministically.

Cover: press state; click-versus-drag at, below, and above threshold; forward and
reverse drag state; events outside any preview fall through unmodified; events in
excluded rectangles are not dispatched; statusline, separator, tabline, and
command-line clicks retain normal behaviour; mapping installation and exact
restoration for all of `n`/`i`/`v`; session cleanup on close, buffer wipeout, tab
leave, suspend, renderer restart, and exit; cell→CSS conversion including the
+0.5 centring; clamping at viewport edges; conversion correctness after resize;
byte-column clamping against multibyte lines; the sync guard prevents feedback;
link classification and dispatch for every type in §4.4; unsafe schemes rejected;
root escape rejected; configuration validation; health and debug fields.

Assert that a click never produces `precision = "exact"` in this part.

---

## Acceptance criteria

- [ ] Mouse positions map cells → CSS with no guessed pixel multiplication.
- [ ] Cell centring (`+0.5`) and 1-based↔0-based conversion are correct and tested.
- [ ] A click below threshold navigates to Markdown source.
- [ ] Precision is reported honestly and is never `exact`.
- [ ] Drag state is tracked but creates no selection yet.
- [ ] Cursor columns are valid 0-based UTF-8 byte offsets, clamped to the line.
- [ ] Source moves go through the existing sync guard; no feedback loop.
- [ ] `focus_source_on_click = false` moves the cursor without stealing focus.
- [ ] Modifier-click activates only approved link types.
- [ ] The hidden browser cannot navigate; unsafe schemes and root escapes rejected.
- [ ] Events outside previews retain normal Neovim behaviour.
- [ ] Mappings are saved and restored exactly, including after renderer failure.
- [ ] Interaction is disabled for the `cells` backend.
- [ ] Existing wheel scrolling and cursor-follow tests still pass.
- [ ] All Lua and Node tests pass.
- [ ] Status document updated per policy §6.

## Operator verification (manual)

In a real terminal: click a paragraph and confirm the source cursor moves to that
block. Ctrl-click an `https` link and confirm it opens. Click the statusline and
confirm normal behaviour. Close the preview and confirm your own mouse mappings
survived. Record the results — including failures.

---

## Commit

```text
feat(md-viewer): cross-platform preview part 4/7 - mouse layer and click navigation
```

Then follow `prompts/00-policy.md` §6 and §7.
