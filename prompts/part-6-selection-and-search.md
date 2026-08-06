---
part: 6
title: DOM selection, copy, and rendered-text search
status: not-started
model: Sonnet 5
depends_on: parts 3-4 (part 5 optional)
commit: ""
---

# Part 6 of 7 — DOM Selection, Copy, and Search

> Read `prompts/00-policy.md` first.

## Objective

The headline feature: drag over rendered text and see a real Chromium selection
highlight, copy it, and search the rendered document. Selection and search are
combined because they share the same machinery — mutate DOM ranges, let the
browser paint, recapture through the coalesced pipeline.

**This part is swappable with Part 5.** It depends only on Parts 3 and 4. If Part
5 has not run, search reports match positions at block precision; that is fine
and honest.

---

## Verified repository facts

**The backpressure pattern you must reuse already exists** for scrolling. From
`lua/md-viewer/config.lua`:

```lua
render = { fast_scroll = true, scroll_settle_ms = 160, ... }
```

The existing session fields (visible in `tests/lua/run.lua`) are
`session.scroll_render_in_flight` and `session.scroll_render_pending`, and there
is a test asserting `"preview navigation requests a backpressured scroll frame"`.
Model selection on this: one request in flight, newest pending position retained,
intermediate events dropped.

Note the existing test `"scroll captures have no artificial FPS cap"` — asserting
`cfg.render.fast_scroll_fps == nil`. **Do not add a fixed frame rate.** Let
screenshot and terminal-transfer completion supply natural backpressure.

**Capture scale is already a parameter.** `browser.js`:

```js
const captureScale = params.captureScale === "css" ? "css" : "device";
await this.page.screenshot({ path, type: "png", fullPage: false,
                             animations: "disabled", scale: captureScale });
```

Use `"css"` during drag, `"device"` for the settled frame. The mechanism exists;
you are choosing when to use which.

**Part 4 already built the drag state machine** — `pressed`, `press_cell`,
`latest_cell`, `drag_started`, `newest_pending_drag_point`,
`selection_request_in_flight`, `cached_selected_text`. It tracks gestures but
creates no selection. This part fills that in; it should be additive.

**Part 3 reserved the actions** `selection_preview`, `selection_commit`,
`selection_clear`, `selection_text`, `word_select`, `find_set`, `find_next`,
`find_previous`, `find_clear`, and the per-document interaction state map. Use
them.

**Commands are registered in `lua/md-viewer/commands.lua`** — a flat `M.setup()`
of `nvim_create_user_command` calls. Preview-local mappings go through
`lua/md-viewer/navigation.lua`, which uses `nvim_buf_call(session.preview_buf, ...)`.

**`javaScriptEnabled: false`** — see policy §3. `page.evaluate()` works.

---

## Read these files first

```text
renderer/src/browser.js          # interact dispatch and capture path from Part 3
renderer/src/main.js
lua/md-viewer/mouse.lua          # drag state from Part 4
lua/md-viewer/commands.lua
lua/md-viewer/navigation.lua
lua/md-viewer/controller.lua     # the fast/settled scroll pipeline
lua/md-viewer/config.lua
```

---

## Implement

### 6.1 Real Chromium selection

Inside `page.evaluate()`:

- Resolve anchor and focus carets by hit-testing both points.
- Normalize element-boundary results to usable text boundaries.
- Prefer `Selection.setBaseAndExtent()`; otherwise construct a correctly ordered
  `Range`.
- **Support reverse dragging** — dragging up or leftward must not collapse the
  selection. This is the most commonly broken case; test it explicitly.

The browser paints the highlight itself. Do not draw your own — the entire point
is that Chromium's real selection rendering appears in the screenshot.

Support selection spanning nested emphasis, strong text, links, inline code,
multiple paragraphs, lists, tables, blockquotes, code blocks, and Unicode text.

### 6.2 Drag performance

Never take a device-scale screenshot per mouse movement.

1. At most **one** selection-preview request in flight.
2. Retain only the **newest** pending drag point; drop intermediates.
3. Coalesce events on a debounce.
4. Use `captureScale: "css"` while moving.
5. Display each completed frame; never let a stale frame replace a newer one.
6. Capture one `captureScale: "device"` frame after release or a settle delay.

Configuration:

```lua
interaction = {
  selection = true,
  drag_debounce_ms = 40,
  settle_ms = 120,
}
```

No fixed FPS cap.

### 6.3 Selection persistence and invalidation

Selection must survive: scroll-only captures, the settled high-resolution
capture, temporary image replacement, and preview focus changes.

On a content change, either clear the selection safely, or restore it only when
source provenance proves the range is still valid. **Never apply a selection from
an older content revision to newer content** — that is silent data corruption in
a copy operation.

With multiple preview sessions open, one document's selection must not leak into
another. Part 3's per-document interaction state is where this lives.

### 6.4 Copy

Commands:

```text
:MdViewerCopy
:MdViewerClearSelection
```

Preview-local `y` copies the selection.

- Write to the unnamed register `"`.
- Write to `+` when clipboard support is available.
- **Do not shell out** to `pbcopy`, `xclip`, `wl-copy`, or `clip.exe`. Neovim
  registers do this, portably, and shelling out is precisely the kind of
  platform assumption this project is removing.
- Notify clearly when nothing is selected.
- Never put a large selected string into a notification. Report a length.

```lua
interaction = { copy = true, copy_on_select = false }
```

`copy_on_select` stays **disabled by default** — neither VS Code nor a browser
copies on every drag, and silently overwriting the user's clipboard is hostile.

### 6.5 Double-click word selection

`<2-LeftMouse>` performs browser-style word selection via `word_select`.

```lua
interaction = { word_select = true }
```

Part 4 made the binding configurable. If double-click source navigation is
preferred by some users, keep it selectable rather than silently changing
behaviour.

### 6.6 Rendered-text search

Search the **rendered** text, not raw Markdown syntax.

Commands:

```text
:MdViewerFind [query]
:MdViewerFindNext
:MdViewerFindPrevious
:MdViewerFindClear
```

Preview-local mappings: `/` prompts, `n` next, `N` previous, `Esc` clears.

**Escape precedence**, in order: clear an active find; otherwise clear the
selection; otherwise fall through to normal behaviour.

**Do not implement highlighting by HTML string replacement.** That is an
injection vector and it destroys the source IDs Part 5 depends on. Use safe DOM
traversal with `Range` objects, the CSS Custom Highlight API where adequately
supported, or controlled wrapper elements that you create programmatically.

Track per document: query, match count, active match index, and match source
position where available. Scroll the active match into view and return the
updated screenshot from the same queued operation.

A query containing HTML or regex metacharacters must be treated as literal text.
Test it.

```lua
interaction = { find = true }
```

This part adds six new commands (`:MdViewerCopy`, `:MdViewerClearSelection`,
`:MdViewerFind`, `:MdViewerFindNext`, `:MdViewerFindPrevious`,
`:MdViewerFindClear`). Before reporting the part done, invoke every one of
them directly in a headless session (policy §5) — including `:MdViewerCopy`
and `:MdViewerFindNext`/`:MdViewerFindClear` with **no active
selection/search**, which is the state most likely to be under-tested and the
one a real user hits constantly. Confirm each notifies or no-ops cleanly
rather than erroring.

---

## Do not do in this part

- Do not add inline source provenance — Part 5.
- Do not add a fixed frame-rate cap.
- Do not shell out for clipboard access.
- Do not enable `copy_on_select` by default.
- Do not paint your own selection highlight.

---

## Tests to add

**Node** (`tests/node/selection.test.js`, `tests/node/find.test.js`):

Forward selection; **backward selection**; multi-block selection; selection
across nested markup; selection inside code blocks; Unicode selection;
element-boundary anchors normalized; word selection; selection text extraction;
selection clearing; selection surviving a scroll-only capture; selection dropped
on an incompatible content revision; cross-document selection isolation; stale
frames never replacing newer ones.

Search: creation; match counting; next and previous wrapping; clearing;
scroll-into-view; a query containing HTML is literal; a query containing regex
metacharacters is literal; per-document search state isolation; search text
containing HTML is not injected into the DOM.

**Lua** (`tests/lua/cases/selection.lua`):

Drag-threshold crossing initiates selection; only one preview request in flight;
newest pending point retained and intermediates dropped; settled capture follows
release; copy writes to `"` and to `+` when available; `copy_on_select` respected
in both states; copy with nothing selected notifies and does not clobber
registers; `:MdViewerClearSelection`; Escape precedence in all three cases;
find command dispatch; cleanup on preview close and renderer restart.

---

## Acceptance criteria

- [ ] Dragging creates a real Chromium DOM `Selection`.
- [ ] The browser paints the highlight and it appears in the screenshot.
- [ ] Reverse dragging works and does not collapse the selection.
- [ ] At most one preview request in flight; newest pending point retained.
- [ ] Drag frames use CSS scale; a device-scale frame follows settle.
- [ ] No fixed FPS cap was introduced.
- [ ] Stale frames never replace newer frames.
- [ ] Selection survives scroll-only and settled captures.
- [ ] Selection from an older content revision is never applied.
- [ ] Selections do not leak across documents.
- [ ] `:MdViewerCopy` writes to `"` and to `+` when available, without shelling out.
- [ ] `copy_on_select` exists and defaults to `false`.
- [ ] Double-click performs word selection.
- [ ] Find supports set, next, previous, and clear, with `/`, `n`, `N`, `Esc`.
- [ ] Escape precedence is find → selection → normal.
- [ ] Highlighting uses DOM ranges, never HTML string replacement.
- [ ] Queries containing HTML or regex metacharacters are literal and safe.
- [ ] Existing scroll performance is unchanged.
- [ ] All Lua and Node tests pass.
- [ ] Status document updated per policy §6.

## Operator verification (manual)

In a real terminal: drag across a paragraph and confirm you see a moving
highlight, not a frozen one. Drag upward and confirm the selection does not
collapse. Press `y` and paste elsewhere. Double-click a word. Search for a term
that appears several times and cycle with `n`/`N`. Confirm dragging feels
responsive rather than stepwise. Record the results honestly.

---

## Commit

```text
feat(md-viewer): cross-platform preview part 6/7 - dom selection, copy, and search
```

Then follow `prompts/00-policy.md` §6 and §7.
