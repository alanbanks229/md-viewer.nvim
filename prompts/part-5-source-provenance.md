---
part: 5
title: Exact source provenance — inline mapping and byte-accurate columns
status: not-started
model: Opus 5 (plan and implement)
depends_on: parts 3-4
commit: ""
---

# Part 5 of 7 — Exact Source Provenance

> Read `prompts/00-policy.md` first.

## Objective

Upgrade click-to-source from block precision to **exact** Markdown line and byte
column, wherever the parser can establish one honestly — and report `line` or
`block` where it cannot.

> **Use Opus 5 for both planning and implementation.** This is the hardest
> correctness surface in the project and its failure mode is silent: a wrong byte
> column does not crash, it just puts the cursor in the wrong place, and it will
> be wrong in exactly the cases nobody tests by hand. Do not economize here.

**This part is swappable with Part 6.** Neither depends on the other. If you have
already run Part 6, adjust references accordingly.

---

## Why this is hard

A browser caret offset is an offset into **rendered DOM text**. It is not a
Markdown source column. The rendered DOM omits and transforms syntax:

```markdown
**bold**                                  → "bold"      (4 chars removed)
[visible label](https://example.com)      → "visible label"
`inline code`                             → "inline code"
&amp;                                     → "&"          (5 bytes → 1 byte)
# Heading                                 → "Heading"
> blockquote                              → "blockquote"
- list item                               → "list item"
```

And a JavaScript string offset is a **UTF-16 code-unit** offset, while Neovim
wants a **UTF-8 byte** offset. For anything outside the Basic Multilingual Plane
these differ by a factor of two; for accented and CJK characters they differ by
different factors again.

Both transformations must be composed correctly, in that order.

---

## Verified repository facts

**markdown-it gives you block positions and nothing else.** In
`renderer/src/source-map.js`, `attachSourceMaps()` is:

```js
if (token.map && token.block) {
  token.attrSet("data-source-start", String(token.map[0]));
  token.attrSet("data-source-end", String(token.map[1]));
}
```

The `token.block` guard is there because **inline tokens have `token.map === null`**
in markdown-it. The parser simply does not carry inline source positions. This is
the core obstacle, and any approach you take must confront it directly.

`token.map` values are **0-based line indices**, and `map[1]` is exclusive.
Neovim lines are 1-based. Get this conversion right once, in one place.

**Existing block attributes are consumed by geometry.** `collectBlockGeometry()`
queries `[data-source-start][data-source-end]`, computes `getBoundingClientRect()`
offsets, and dedupes by `${sourceStart}:${sourceEnd}` keeping the *smallest*
element per key. Source-to-preview scroll sync depends on this. **Keep these
attributes and keep that behaviour working.** Add to them; do not replace them.

**The sanitizer will strip anything you do not allowlist.**
`renderer/src/markdown.js`:

```js
allowedAttributes: {
  "*": ["class", "data-source-start", "data-source-end", "data-alert-title"],
  a: ["href", "title"], img: ["src", "alt", "title", "class"],
  input: ["type", "checked", "disabled"], label: ["class"],
  th: ["style"], td: ["style"],
},
```

Any new `data-*` attribute must be added here or it will silently vanish. Also
note `allowedTags` — `span` and `div` are already permitted, so wrapper elements
are available to you.

**`renderMarkdown()` returns `{ html, sourceMap }`** as of Part 3, with
`sourceMap: null`. `markdownCache` entries are `{ key, html, sourceMap }`. Fill
them in; the plumbing already exists.

**Custom renderer rules already in place** in `markdown.js`, showing the
established pattern: `md.renderer.rules.image`, `md.renderer.rules.fence`, and
the `alertPlugin` core rule using `md.core.ruler.after("block", ...)`.

---

## Read these files first

```text
renderer/src/source-map.js
renderer/src/markdown.js
renderer/src/browser.js          # the interact/hit-test paths from Part 3
lua/md-viewer/renderer.lua
lua/md-viewer/sync.lua
tests/node/markdown.test.js
tests/fixtures/kitchen-sink.md
```

---

## Implement

### 5.1 Choose the smallest reliable approach

Keep markdown-it as the renderer. Do **not** swap parsers merely to obtain
columns.

Candidate approaches, roughly in order of preference:

1. **Custom inline renderer rules that emit provenance.** Hook the inline token
   stream and track `state.pos` as inline parsing proceeds, attaching positions
   to the tokens you emit.
2. **A markdown-it plugin exposing inline positions**, if one exists that is
   maintained and auditable. Adding a dependency is acceptable if it is small
   and pinned; adding an unmaintained one is not.
3. **A second position-aware pass over the source**, used only for provenance and
   aligned against the rendered token stream.

Whatever you choose, you must **prove the alignment with tests**, and you must
**fall back conservatively when alignment is ambiguous**. Repeated identical text
within one block is the case that breaks naive approaches — if your method
re-scans a line for token content, two identical spans will collide. Test it.

Write down in the status document which approach you chose and why, and what its
known failure modes are. The next person needs that.

### 5.2 Stable source IDs

Assign stable per-render IDs to rendered blocks and inline text regions:

```html
<span data-md-source-id="s42">visible text</span>
```

- Allowlist `data-md-source-id` in the sanitizer.
- **Never put raw Markdown content into an attribute.** IDs are opaque keys.
- Keep the full mapping in **trusted Node memory**, keyed by document ID. The DOM
  carries only the key.
- Do not wrap so aggressively that you distort layout. Wrapping every text node
  in a `span` changes nothing visually, but wrapping across block boundaries
  will. Verify rendering is unchanged.

### 5.3 Source map entries

An entry must support converting a DOM text-node boundary to a source byte
position. A workable shape:

```js
{
  id,
  startLine, startByteColumn,
  endLine,   endByteColumn,
  startByteOffset, endByteOffset,
  renderedBoundaryToSourceByte   // rendered offset -> source byte offset
}
```

The exact representation may differ. The requirement is reliable conversion, and
a per-region precision label:

```text
exact | line | block | none
```

**Do not guess an exact column.** If the parser cannot establish one, degrade to
`line`, then `block`, then `none`. An honest `block` is a correct answer; a
confident wrong `exact` is a bug that will be reported as "the cursor jumps to
random places."

### 5.4 UTF-16 to UTF-8 byte conversion

Implement as a single, separately-tested utility. Compose in this order:

```text
DOM caret offset (UTF-16 code units, rendered text)
  → rendered character boundary
  → source character offset      (via the source map)
  → source UTF-8 byte offset
  → { line: 1-based, byteColumn: 0-based }
```

Handle: emoji and other astral-plane characters (surrogate pairs), combining
characters, accented Latin, CJK, tabs, HTML entities (`&amp;` is 5 source bytes
and 1 rendered character), and mixed content on one line.

Beware the two off-by-one traps this project is exposed to:
- markdown-it `token.map` is 0-based with an exclusive end; Neovim lines are
  1-based inclusive.
- `nvim_win_set_cursor()` takes a 1-based line and a **0-based byte** column.

### 5.5 Upgrade Part 4's click navigation

Route the Part 4 click path through the new provenance so it reports `exact`
where available. The Lua side should need no change beyond accepting real byte
columns — Part 4 already built and tested the clamping and validation for
exactly this.

Verify the Part 4 assertion that "precision is never exact" is now updated rather
than deleted: it should assert `exact` *is* returned for cases that support it.

### 5.6 Preserve block-level behaviour

`collectBlockGeometry()` and source-to-preview scroll sync must keep working
unchanged. Run the existing sync tests and confirm.

---

## Do not do in this part

- Do not replace markdown-it.
- Do not remove `data-source-start` / `data-source-end`.
- Do not add selection, copy, or search.
- Do not report `exact` for a position you inferred rather than derived.

---

## Tests to add

**Node** (`tests/node/source-provenance.test.js`, `tests/node/utf.test.js`):

*Conversion, in isolation:* UTF-16↔UTF-8 for ASCII, accented Latin, CJK, emoji
(surrogate pairs), combining characters, zero-width joiners, and tabs. Test the
converter directly before testing it through the DOM — when a provenance test
fails you need to know which layer broke.

*Syntax transformations:* emphasis, strong, nested emphasis, inline code, fenced
code, links (label versus URL), reference links, autolinks, images, headings
(ATX and setext), blockquotes, ordered and unordered lists, nested lists,
task-list items, tables, HTML entities, hard line breaks, and escaped
characters.

*The hard cases:* repeated identical text within one block; identical text across
blocks; text that appears both inside and outside a link; entities adjacent to
multibyte characters; a line mixing tabs, emoji, and CJK.

*Precision honesty:* every fixture asserts the precision label it should get, and
at least one asserts a deliberate fall back to `line` or `block` rather than a
wrong `exact`.

*Integration:* click at a known CSS coordinate over known content yields the
expected `{ line, byteColumn, precision }`.

**Regression:** `collectBlockGeometry()` output is unchanged for the existing
fixtures; source-to-preview sync tests still pass; sanitization tests still pass
with the new attributes allowlisted; malicious attribute injection is still
stripped.

---

## Acceptance criteria

- [ ] markdown-it is still the renderer.
- [ ] Stable `data-md-source-id` attributes exist and are allowlisted.
- [ ] No raw Markdown content is placed in any DOM attribute.
- [ ] The source map lives in trusted Node memory, keyed per document.
- [ ] Exact columns are returned only where inline provenance supports them.
- [ ] Fallback reports `line` or `block` honestly; ambiguity never yields `exact`.
- [ ] UTF-16→UTF-8 conversion is a separately tested utility.
- [ ] Emoji, combining characters, CJK, tabs, entities, and repeated text pass.
- [ ] Lines are 1-based; cursor columns are 0-based byte offsets.
- [ ] Part 4's click path reports `exact` where available.
- [ ] `data-source-start` / `data-source-end` and scroll sync are unchanged.
- [ ] The chosen approach and its failure modes are recorded in the status doc.
- [ ] All Lua and Node tests pass.
- [ ] Status document updated per policy §6.

---

## Commit

```text
feat(md-viewer): cross-platform preview part 5/7 - exact source provenance
```

Then follow `prompts/00-policy.md` §6 and §7.
