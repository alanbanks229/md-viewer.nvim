---
part: 3
title: Interaction transport — interact protocol, document isolation, DOM hit-testing
status: not-started
model: plan with Opus 5, implement with Sonnet 5
depends_on: parts 1-2
commit: ""
---

# Part 3 of 7 — Interaction Transport

> Read `prompts/00-policy.md` first.

## Objective

Build the renderer-side half of interaction: a unified `interact` NDJSON method,
per-document state isolation inside the single shared Chromium page, separate
staleness lanes so a drag cannot cancel a render, and DOM hit-testing primitives.

**Nothing user-visible changes in this part.** Part 4 connects it to the mouse.
The value here is that the concurrency design is settled and tested before any
feature depends on it.

> **Plan this part with Opus 5 before implementing.** The queueing, staleness,
> and document-isolation design is where subtle bugs live, and they will be
> expensive to find later. Settle the design in plan mode, approve it, then
> implement.

---

## Verified repository facts

**The renderer is a single serial promise chain over a single shared page.**
`renderer/src/main.js`:

```js
let renderQueue = Promise.resolve();
// ...
const queued = renderQueue.then(task, task);
renderQueue = queued.catch(() => {});
```

`renderer/src/browser.js` holds exactly one `this.page`, one `this.context`, one
`this.layout`, one `this.viewport`. There is no per-document page.

**Document switching today is implicit and destructive.** `browser.js` builds:

```js
const layoutKey = JSON.stringify([
  params.documentId, fingerprint, width, params.theme, scrollPastEnd, scrollPastEndOffsetPx,
]);
const layoutReused = this.layout?.key === layoutKey;
```

When the key differs — including on any document switch — it calls
`page.setContent(...)`, which destroys all DOM state. Any selection or search
state in the old document is silently gone. This is the central problem §3.2
must solve.

**There is exactly one staleness lane, and it is shared.** `main.js`:

```js
const latestByDocument = new Map();   // documentId -> request.id
latestByDocument.set(params.documentId, request.id);
// checked before render, and again after, with code STALE_RENDER
```

Both `render` and `capture` write to it. A high-frequency interaction stream
would therefore cancel legitimate renders. §3.3 splits this.

**The markdown cache carries no source map.** `main.js`:

```js
const markdownCache = new Map();  // documentId -> { key, html }
// LRU-capped at 64 entries
```

Part 5 needs `{ key, html, sourceMap }`. Widen the shape now (with
`sourceMap: null`) so Part 5 is a fill-in rather than a refactor.

**Methods currently dispatched:** `shutdown`, `ping`, `health`, `render`,
`capture`. Anything else throws `unknown method: ...`.

**Error codes in use:** `STALE_RENDER`, `CAPTURE_CACHE_MISS`, `RENDER_ERROR`
(the default in `protocol.js`).

**Content revision already exists.** `lua/md-viewer/renderer.lua:35` builds
`content_revision` as `("%d:%d"):format(...)` and sends it as
`params.contentRevision`. `renderer.lua:75` stores `session.renderer_revision`.
Reuse this; do not invent a parallel concept.

**`javaScriptEnabled: false`** — see policy §3. `page.evaluate()` works; the
existing `collectBlockGeometry()` proves it. Do not change the flag.

---

## Read these files first

```text
renderer/src/main.js
renderer/src/browser.js
renderer/src/source-map.js
renderer/src/protocol.js
renderer/src/markdown.js
lua/md-viewer/renderer.lua
lua/md-viewer/protocol.lua
tests/node/renderer-process.test.js
tests/node/browser.test.js
```

---

## Implement

### 3.1 The `interact` method

One new NDJSON method, `interact`, with typed actions. Start with the actions
this part and Part 4 need; Parts 5 and 6 will add more:

```text
hit_test        resolve a point to a DOM position and source metadata
activate_at     resolve a point to link metadata (no navigation)
```

Reserve — but do not implement — `selection_preview`, `selection_commit`,
`selection_clear`, `selection_text`, `word_select`, `find_set`, `find_next`,
`find_previous`, `find_clear`. Design the dispatch so adding them is additive.

Request envelope:

```js
{
  documentId, contentRevision,
  viewportWidthPx, viewportHeightPx, scrollY,
  action, coordinates, modifiers, clickCount, captureScale
}
```

Reject any request whose `contentRevision` does not match the document's current
revision, with a distinct code — `STALE_INTERACTION` — separate from
`STALE_RENDER`. Lua must be able to tell the difference.

### 3.2 Document isolation

Introduce the operation the specification calls for:

```text
ensureDocumentActive(documentId, contentRevision, cachedHtml, viewport, theme)
```

If the requested document is not the one currently loaded in the shared page:

- Rehydrate its cached HTML and (from Part 5) its source map.
- Restore its viewport and scroll position.
- Restore safe per-document interaction state where it can be reconstructed.
- If rehydration is impossible, reject with an actionable cache-miss error.

**An interaction for document A must never operate on document B's DOM.** Test
this explicitly and adversarially. Source maps must not leak across documents
either.

Track per-document interaction state (current selection range descriptor, active
search query, last hit) in trusted Node memory keyed by `documentId`, not on the
page. Page state is destroyed by `setContent`; your map is not.

### 3.3 Separate staleness lanes

Replace the single `latestByDocument` map with per-document, per-lane serials:

```text
content   — full renders
capture   — viewport screenshots
interact  — interaction updates
settle    — settled high-resolution frames
```

Rules:

- A newer content render invalidates all outstanding interactions for that
  document.
- A newer drag position supersedes an older drag position **without** touching
  the content or capture lanes.
- A capture must never be cancelled by an interaction.
- Every lane still verifies `contentRevision` independently.

This is the highest-value piece of the part. Write the tests first.

### 3.4 Atomic interaction results

Where an interaction mutates visible DOM state, perform the mutation and the
screenshot **in the same queued operation** and return the PNG with the semantic
result. Do not require Lua to issue a follow-up `capture` after every gesture.

Result shapes:

```js
{ kind: "source", sourcePosition: { line, byteColumn, precision } }
{ kind: "link",   link: { href, type } }
{ kind: "selection", text, collapsed, pngPath, captureScale, scrollY,
                     viewportHeightPx, documentHeightPx, contentRevision }
```

`precision` is one of `exact` | `line` | `block` | `none`. **In this part it will
never be `exact`** — inline provenance does not exist until Part 5. Return
`block` or `line` honestly.

### 3.5 DOM hit-testing

Implement inside `page.evaluate()`:

- Prefer `document.caretPositionFromPoint(x, y)`.
- Fall back to `document.caretRangeFromPoint(x, y)`.
- Use `document.elementFromPoint(x, y)` for links and non-text elements.

Normalize every hit to:

```js
{ node, offset, sourceId, sourcePosition, precision, element, link }
```

Handle, and test: text nodes, inline formatting, inline code, fenced code,
headings, links, images, tables, list markers, task-list controls, empty blocks,
whitespace, page padding, scroll-past-end padding, and coordinates outside the
article entirely (which must return `precision: "none"`, not a guess).

Resolve source position from the existing `data-source-start` /
`data-source-end` block attributes by walking up from the hit node. That gives
block precision, which is the honest ceiling for this part.

### 3.6 Widen the markdown cache

Change `markdownCache` entries to `{ key, html, sourceMap }` with
`sourceMap: null` for now, and have `renderMarkdown()` return
`{ html, sourceMap }` with `sourceMap: null`. Update call sites and the existing
`tests/node/markdown.test.js`. Part 5 fills it in.

---

## Do not do in this part

- No Neovim mouse handling, no mappings, no coordinate conversion in Lua —
  Part 4.
- No actual selection creation — Part 6.
- No search — Part 6.
- No inline source provenance and no `exact` precision — Part 5.
- Do not open a page per document. One shared page plus rehydration is the
  design; multiple pages multiply memory and defeat the persistent-page benefit.

---

## Tests to add

**Node** (`tests/node/interact.test.js`, extend `renderer-process.test.js`):

Staleness — an interaction against an old `contentRevision` returns
`STALE_INTERACTION`; a newer render invalidates pending interactions; an
interaction does **not** cancel a queued capture; a newer drag point supersedes
an older one without touching other lanes.

Isolation — an interaction naming document A while B is loaded triggers
rehydration and resolves against A; source maps do not leak; a cache miss
produces an actionable error.

Hit-testing — `caretPositionFromPoint` path and `caretRangeFromPoint` fallback;
text-node hits; element-boundary hits; coordinates outside the article yield
`precision: "none"`; block-precision source resolution from `data-source-*`;
each of the content types listed in §3.5.

Protocol — unknown actions are rejected; malformed envelopes are rejected;
`interact` results carry the PNG when they mutate visible state.

Use realistic Markdown fixtures. `tests/fixtures/kitchen-sink.md` already exists.

---

## Acceptance criteria

- [ ] One `interact` method with typed actions; future actions are additive.
- [ ] `STALE_INTERACTION` is distinct from `STALE_RENDER`.
- [ ] `ensureDocumentActive()` rehydrates cached HTML, viewport, and scroll.
- [ ] Cross-document interaction is impossible and is tested adversarially.
- [ ] Content, capture, interact, and settle lanes are independent.
- [ ] An interaction cannot cancel a render or a capture.
- [ ] Visible-state interactions return their PNG in the same queued operation.
- [ ] Hit-testing handles all listed content types and returns honest precision.
- [ ] No result reports `exact` precision in this part.
- [ ] `markdownCache` and `renderMarkdown()` carry a `sourceMap` field.
- [ ] `javaScriptEnabled` is still `false`.
- [ ] No HTTP server, WebSocket server, or listening port was added.
- [ ] All Lua and Node tests pass.
- [ ] Status document updated per policy §6.

---

## Commit

```text
feat(md-viewer): cross-platform preview part 3/7 - interaction transport
```

Then follow `prompts/00-policy.md` §6 and §7.
