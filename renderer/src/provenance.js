// Inline source provenance for markdown-it.
//
// markdown-it publishes `token.map` for block tokens and nothing at all for
// inline ones -- `attachSourceMaps()`'s `token.block` guard exists precisely
// because `map` is null on every inline token. This module recovers the missing
// positions from the parser's own cursor rather than by searching the source for
// rendered text, because searching collides the moment a block contains the same
// word twice ("apple banana apple") and the collision is silent.
//
// Three layers, in the order they run:
//
//   1. span capture    (parse time)  -- every inline token records [start, end)
//                                       within the `content` string it was
//                                       parsed from
//   2. line alignment  (core rule)   -- content lines are located inside the
//                                       source lines `token.map` names
//   3. reconciliation  (render time) -- a token's *final* content is checked
//                                       against its recorded source slice, and
//                                       no region is emitted unless it matches
//
// Layer 3 is what makes this safe against other plugins. markdown-it-task-lists
// slices four characters off a list item's text long after layer 1 ran; the
// reconciliation notices the content no longer starts where the span does and
// shifts the base, instead of reporting a column four positions to the left.
// When it cannot explain the difference at all it emits nothing, and the caller
// degrades to line or block precision. An honest `block` is a correct answer; a
// confident wrong `exact` is "the cursor jumps to random places".

import { utf16ToByteOffset } from "./utf.js";

// Token -> { src, start, end }. Keyed by object identity, so a token that some
// core rule replaces simply falls out of the map and loses provenance rather
// than inheriting somebody else's position.
const spans = new WeakMap();
// Token -> the line map of the inline token it belongs to.
const lineInfos = new WeakMap();

const INSTRUMENTED = Symbol("md-viewer.provenance.instrumented");
const PENDING_START = Symbol("md-viewer.provenance.pendingStart");
export const SOURCE_MAP_BUILDER = Symbol("md-viewer.provenance.builder");

// ---------------------------------------------------------------------------
// Layer 1 -- span capture
// ---------------------------------------------------------------------------

/// Patch one `StateInline` so every token it produces records where it came
/// from. Per-state, not per-prototype: nothing global is mutated, and a state
/// that never reaches a rule is never touched.
function instrument(state) {
  if (state[INSTRUMENTED]) return;
  state[INSTRUMENTED] = true;
  state[PENDING_START] = state.pos;

  const pushPending = state.pushPending;
  state.pushPending = function instrumentedPushPending() {
    const start = this[PENDING_START];
    const position = this.pos;
    const token = pushPending.call(this);
    // The recorded slice can be *longer* than the token's content: the newline
    // rule trims trailing spaces off `pending` before pushing a break, and
    // `link` moves `pos` onto the label before flushing the text in front of
    // `[`. Both leave the content as a prefix of the slice, which is exactly
    // what reconciliation is built to accept.
    spans.set(token, { src: this.src, start, end: position });
    return token;
  };

  const push = state.push;
  state.push = function instrumentedPush(type, tag, nesting) {
    // push() flushes `pending` first, so the run being closed and the token
    // being opened share this `pos` -- that adjacency is what keeps the two
    // spans from overlapping.
    const position = this.pos;
    const token = push.call(this, type, tag, nesting);
    spans.set(token, { src: this.src, start: position, end: null });
    return token;
  };
}

/// Wrap one inline rule so we learn both where a text run began and where each
/// rule-pushed token ended.
function wrapInlineRule(rule) {
  return function provenanceRule(state, silent) {
    // Validation-mode calls (`skipToken`, and every rule's own lookahead) push
    // no tokens and must record nothing -- they move `state.pos` speculatively.
    if (silent) return rule(state, silent);
    instrument(state);
    // Rules are tried in order from the top of every tokenize iteration and
    // `text` is first, so this runs before any character can be accumulated --
    // including through tokenize's own `state.pending += state.src[state.pos++]`
    // fallback, which appends outside any rule.
    if (state.pending === "") state[PENDING_START] = state.pos;
    const before = state.tokens.length;
    const ok = rule(state, silent);
    if (!ok) return ok;
    for (let index = before; index < state.tokens.length; index += 1) {
      const span = spans.get(state.tokens[index]);
      // A token a nested rule already closed keeps its own, tighter end.
      if (span && span.end === null) span.end = state.pos;
    }
    return ok;
  };
}

function inlineRules(md) {
  const rules = md.inline.ruler.__rules__;
  if (!Array.isArray(rules) || rules.length === 0 || rules.some((rule) => typeof rule?.name !== "string")) {
    throw new Error(
      "md-viewer: markdown-it's inline ruler no longer exposes __rules__; refusing to install source provenance rather than report guessed columns"
    );
  }
  return rules;
}

// ---------------------------------------------------------------------------
// Span arithmetic
// ---------------------------------------------------------------------------

/// Fold `from`'s span into `into`'s when markdown-it merges the two tokens'
/// content. Anything that cannot be explained -- a different source string, a
/// token some plugin created from nothing, an out-of-order pair -- drops the
/// merged run's provenance instead of inventing a span for it.
function mergeSpans(from, into) {
  const first = spans.get(from);
  const second = spans.get(into);
  if (!first || !second || first.src !== second.src || first.start > second.start) {
    spans.delete(into);
    return;
  }
  spans.set(into, { src: first.src, start: first.start, end: second.end ?? first.end });
}

/// Reserved seam for span-aware linkification.
///
/// markdown-it's core `linkify` rule replaces one text token with several new
/// ones whose contents are slices of the original at offsets it already knows.
/// A future replacement for that rule can call this to give each new token a
/// real span rather than letting it fall back to line precision. Nothing calls
/// it today, deliberately: Part 5's decision was to degrade honestly for
/// auto-linkified bare URLs rather than carry a second copy of a markdown-it
/// rule. Explicit `[label](url)` links are unaffected either way -- they never
/// go through the linkify rule at all.
export function deriveSpan(parentToken, childToken, offsetInContent, length) {
  const parent = spans.get(parentToken);
  if (!parent || parent.end === null) return false;
  const start = parent.start + offsetInContent;
  if (offsetInContent < 0 || length < 0 || start + length > parent.end) return false;
  spans.set(childToken, { src: parent.src, start, end: start + length });
  const info = lineInfos.get(parentToken);
  if (info) lineInfos.set(childToken, info);
  return true;
}

export function spanOf(token) {
  return spans.get(token) ?? null;
}

// ---------------------------------------------------------------------------
// Replacements for the two rules that merge text tokens
// ---------------------------------------------------------------------------

/// markdown-it's `fragments_join` (inline ruler2), with span merging added.
/// Emphasis and strikethrough split their delimiter runs into standalone text
/// tokens; this puts the unused ones back. Structure copied deliberately so a
/// markdown-it change shows up as a diff here rather than as wrong columns.
function fragmentsJoinWithSpans(state) {
  let curr;
  let last;
  let level = 0;
  const tokens = state.tokens;
  const max = state.tokens.length;

  for (curr = last = 0; curr < max; curr += 1) {
    if (tokens[curr].nesting < 0) level -= 1;
    tokens[curr].level = level;
    if (tokens[curr].nesting > 0) level += 1;

    if (tokens[curr].type === "text" && curr + 1 < max && tokens[curr + 1].type === "text") {
      tokens[curr + 1].content = tokens[curr].content + tokens[curr + 1].content;
      mergeSpans(tokens[curr], tokens[curr + 1]);
    } else {
      if (curr !== last) tokens[last] = tokens[curr];
      last += 1;
    }
  }

  if (curr !== last) tokens.length = last;
}

/// markdown-it's `text_join` (core), with span merging added and one deliberate
/// behavioural difference: an entity or escape is **not** merged into its
/// neighbours.
///
/// `&amp;` is five source characters rendering as one, and `\*` is two
/// rendering as one. Merging either into the surrounding prose would make the
/// whole merged run's offsets non-linear, so the run would have to be thrown
/// away entirely. Keeping them separate costs one extra `<span>` in the output
/// -- inline spans do not affect layout or whitespace collapsing -- and keeps
/// exact provenance for the prose *and* for the entity.
function textJoinWithSpans(state) {
  let curr;
  let last;
  const blockTokens = state.tokens;
  const l = blockTokens.length;

  for (let j = 0; j < l; j += 1) {
    if (blockTokens[j].type !== "inline") continue;

    const tokens = blockTokens[j].children;
    const max = tokens.length;
    const special = new Set();

    for (curr = 0; curr < max; curr += 1) {
      if (tokens[curr].type === "text_special") {
        tokens[curr].type = "text";
        special.add(tokens[curr]);
      }
    }

    for (curr = last = 0; curr < max; curr += 1) {
      if (tokens[curr].type === "text"
        && curr + 1 < max
        && tokens[curr + 1].type === "text"
        && !special.has(tokens[curr])
        && !special.has(tokens[curr + 1])) {
        tokens[curr + 1].content = tokens[curr].content + tokens[curr + 1].content;
        mergeSpans(tokens[curr], tokens[curr + 1]);
      } else {
        if (curr !== last) tokens[last] = tokens[curr];
        last += 1;
      }
    }

    if (curr !== last) tokens.length = last;
  }
}

// ---------------------------------------------------------------------------
// Layer 2 -- line alignment
// ---------------------------------------------------------------------------

/// Locate `derived` inside `docLine`, or return null when it cannot be located
/// unambiguously.
///
/// An inline token's `content` is *derived* from its source lines: block rules
/// strip a prefix (indent, `>`, `-`, `1.`, `#`) and the enclosing `.trim()`
/// strips whitespace off the ends. So the derived text almost always sits flush
/// against the end of its source line -- anchor there first, because that test
/// stays correct even when the derived text occurs more than once on the line.
/// A unique `indexOf` covers the suffix-stripping cases (an ATX closing
/// sequence, `## Heading ##`). Anything ambiguous maps to nothing.
export function alignLine(docLine, derived) {
  if (typeof docLine !== "string" || typeof derived !== "string" || derived === "") return null;
  for (const end of [docLine.length, docLine.replace(/\s+$/, "").length]) {
    const at = end - derived.length;
    if (at >= 0 && docLine.startsWith(derived, at)) return at;
  }
  const first = docLine.indexOf(derived);
  if (first >= 0 && first === docLine.lastIndexOf(derived)) return first;
  return null;
}

/// Map every line of an inline token's `content` onto a source line and the
/// column it starts at there.
///
/// The search window only ever moves forward inside `[map[0], map[1])`, which
/// absorbs lines that vanished from the content before inline parsing -- the
/// alert plugin strips a whole `[!NOTE]` line off a blockquote's content, so
/// content line 0 belongs to source line `map[0] + 1`.
function buildLineMap(docLines, map, content) {
  if (!Array.isArray(map) || map.length < 2) return null;
  const [mapStart, mapEnd] = map;
  if (!Number.isFinite(mapStart) || !Number.isFinite(mapEnd)) return null;

  const contentLines = content.split("\n");
  const starts = [];
  const lengths = [];
  let offset = 0;
  for (const line of contentLines) {
    starts.push(offset);
    lengths.push(line.length);
    offset += line.length + 1;
  }

  const placements = [];
  let cursor = mapStart;
  for (const line of contentLines) {
    let placed = null;
    for (let index = cursor; index < mapEnd && index < docLines.length; index += 1) {
      const column = alignLine(docLines[index], line);
      if (column !== null) {
        placed = { line: index, column };
        cursor = index + 1;
        break;
      }
    }
    placements.push(placed);
  }
  return { starts, lengths, placements };
}

/// Content offset -> { line, column } in the source document, or null when the
/// content line it falls on could not be aligned.
function locate(info, offset) {
  for (let index = 0; index < info.starts.length; index += 1) {
    const start = info.starts[index];
    if (offset >= start && offset <= start + info.lengths[index]) {
      const placed = info.placements[index];
      if (!placed) return null;
      return { line: placed.line, column: placed.column + (offset - start) };
    }
  }
  return null;
}

function pristineSource(token) {
  for (const child of token.children) {
    const span = spans.get(child);
    if (span) return span.src;
  }
  // `token.content` is still pristine here -- this core rule is registered to
  // run immediately after `inline`, ahead of every plugin that rewrites it.
  return typeof token.content === "string" ? token.content : null;
}

function innermostMap(stack) {
  for (let index = stack.length - 1; index >= 0; index -= 1) {
    if (stack[index]) return stack[index];
  }
  return null;
}

function provenanceCoreRule(state) {
  const docLines = state.src.split("\n");
  // markdown-it gives a table cell's inline token no map at all (see
  // rules_block/table.mjs -- only the table, thead, tbody and tr tokens get
  // one), so an inline token with no map of its own borrows the innermost
  // enclosing block's. That widens the search window; it does not weaken the
  // check, because the alignment must still match a real source line
  // unambiguously. A row with two identical cells degrades rather than guessing
  // which one was clicked.
  const enclosing = [];
  for (const token of state.tokens) {
    if (token.nesting === 1) enclosing.push(token.map ?? null);
    if (token.type === "inline" && Array.isArray(token.children) && token.children.length > 0) {
      const src = pristineSource(token);
      const info = src === null ? null : buildLineMap(docLines, token.map ?? innermostMap(enclosing), src);
      if (info !== null) {
        for (const child of token.children) lineInfos.set(child, info);
      }
    }
    if (token.nesting === -1) enclosing.pop();
  }
}

// ---------------------------------------------------------------------------
// Layer 3 -- reconciliation and region building
// ---------------------------------------------------------------------------

/// Where does `rendered` sit inside the source slice this token recorded?
///
/// All three branches guarantee `slice.slice(offset, offset + rendered.length)
/// === rendered`, which is what makes the offset mapping a plain identity: a
/// caret `n` code units into the rendered run is `n` code units into the source
/// from that base. Nothing else is accepted.
function reconcile(span, rendered) {
  if (!span || typeof rendered !== "string" || rendered === "") return null;
  const end = span.end === null ? span.start : Math.max(span.start, span.end);
  const slice = span.src.slice(span.start, end);
  if (slice === "" || rendered.length > slice.length) return null;
  // Prefix: the plain case, plus trailing whitespace the newline rule trimmed
  // and the `[` a link's flush swallowed.
  if (slice.startsWith(rendered)) return 0;
  // Suffix: a plugin removed a prefix after parsing. markdown-it-task-lists
  // slicing "[x] " off a list item is the case that matters.
  if (slice.endsWith(rendered)) return slice.length - rendered.length;
  // Interior, but only when there is exactly one candidate. `code_inline`
  // (backticks around the content) and `<autolink>` (angle brackets) land here.
  const first = slice.indexOf(rendered);
  if (first >= 0 && first === slice.lastIndexOf(rendered)) return first;
  return null;
}

export function createSourceMapBuilder(markdown) {
  const lines = normalizeSource(markdown).split("\n");
  const regions = Object.create(null);
  let serial = 0;
  return {
    lines,
    register(region) {
      if (!region) return null;
      serial += 1;
      const id = `s${serial}`;
      regions[id] = region;
      return id;
    },
    build() {
      return { version: 1, lines, regions };
    },
  };
}

/// Mirrors markdown-it's `normalize` core rule. `token.map` indexes into the
/// normalized source, so every column this module reports must be measured
/// against the same string.
export function normalizeSource(markdown) {
  return String(markdown).replace(/\r\n?|\n/g, "\n").replace(/\0/g, "�");
}

function builderFor(env) {
  return env && env[SOURCE_MAP_BUILDER] ? env[SOURCE_MAP_BUILDER] : null;
}

/// Register a region for a rendered text run and return its opaque id, or null
/// when this run cannot be placed honestly.
export function registerTextRegion(env, token, rendered) {
  const builder = builderFor(env);
  const span = spans.get(token);
  const info = lineInfos.get(token);
  if (!builder || !span || !info) return null;
  const base = reconcile(span, rendered);
  if (base === null) return null;
  const start = locate(info, span.start + base);
  const end = locate(info, span.start + base + rendered.length);
  // A run that straddles a line boundary has no single start column. Text runs
  // never contain a newline (the newline rule breaks them), so this only fires
  // for a multi-line `code_inline`, whose newlines markdown-it has already
  // rewritten to spaces -- which is exactly the case that must not claim exact.
  if (!start || !end || start.line !== end.line) return null;
  return builder.register({
    kind: "inline",
    mapping: "identity",
    line: start.line,
    startCol16: start.column,
    len16: rendered.length,
  });
}

/// Register a region for a construct that renders no text of its own (an image).
/// The position is the construct's first source character, which is exact -- it
/// is simply not divisible any further.
export function registerPointRegion(env, token) {
  const builder = builderFor(env);
  const span = spans.get(token);
  const info = lineInfos.get(token);
  if (!builder || !span || !info) return null;
  const start = locate(info, span.start);
  if (!start) return null;
  return builder.register({
    kind: "point",
    mapping: "point",
    line: start.line,
    startCol16: start.column,
  });
}

/// Register a block region. This carries no more information than
/// `data-source-start`/`data-source-end` already do; it exists so every rendered
/// block has a stable id and so a hit that lands on a block rather than a run
/// resolves through the same lookup.
export function registerBlockRegion(env, map) {
  const builder = builderFor(env);
  if (!builder || !Array.isArray(map) || map.length < 2) return null;
  return builder.register({ kind: "block", mapping: "block", line: map[0], endLine: map[1] });
}

/// Register a code block. Its content is the source verbatim apart from the
/// block's own indent, so each rendered line maps straight back -- but only if
/// every line really does match, which is checked here rather than assumed.
/// `getLines()` re-expands a deeper indent as *spaces*, so a tab-indented line
/// inside a fence fails this check and the whole block degrades to `block`.
export function registerCodeRegion(env, token, docLines) {
  const builder = builderFor(env);
  if (!builder || !Array.isArray(token.map) || typeof token.content !== "string") return null;
  const contentLines = token.content.split("\n");
  // getLines(..., keepLastLF) leaves a trailing newline, so the split has a
  // final empty element that is not a real line.
  if (contentLines.length > 0 && contentLines[contentLines.length - 1] === "") contentLines.pop();
  if (contentLines.length === 0) return null;
  const startLine = token.type === "fence" ? token.map[0] + 1 : token.map[0];
  const columns = [];
  const lengths = [];
  for (let index = 0; index < contentLines.length; index += 1) {
    const docLine = docLines[startLine + index];
    const text = contentLines[index];
    if (typeof docLine !== "string" || !docLine.endsWith(text)) return null;
    columns.push(docLine.length - text.length);
    lengths.push(text.length);
  }
  return builder.register({ kind: "code", mapping: "lines", startLine, columns, lengths });
}

// ---------------------------------------------------------------------------
// Resolution -- the only consumer-facing entry point
// ---------------------------------------------------------------------------

/// Resolve an opaque region id plus a rendered offset into a source position.
///
/// `line` is a **0-based** document line index; the single conversion to
/// Neovim's 1-based lines lives in `interact.js:resolveSourcePosition()`, where
/// the block conversion has lived since Part 3. `byteColumn` is a 0-based UTF-8
/// byte offset, which is what `nvim_win_set_cursor()` takes.
///
/// A region with no caret offset resolves to its own line with `line`
/// precision, never to a guessed column.
export function resolveRegionPosition(sourceMap, sourceId, renderedOffset) {
  if (!sourceMap || typeof sourceId !== "string" || sourceId === "") return null;
  const region = sourceMap.regions ? sourceMap.regions[sourceId] : null;
  if (!region) return null;
  const lines = Array.isArray(sourceMap.lines) ? sourceMap.lines : [];
  // Strictly a number, because `Number(null)` is 0 and "no caret landed here"
  // must never be mistaken for "the caret landed at the start of the run" --
  // that is the difference between reporting `line` and claiming `exact`.
  const offset = renderedOffset;
  const hasOffset = typeof offset === "number" && Number.isFinite(offset);

  if (region.mapping === "point") {
    const text = lines[region.line];
    if (typeof text !== "string") return null;
    return { line: region.line, byteColumn: utf16ToByteOffset(text, region.startCol16), precision: "exact" };
  }

  if (region.mapping === "identity") {
    const text = lines[region.line];
    if (typeof text !== "string") return null;
    if (!hasOffset) return { line: region.line, byteColumn: 0, precision: "line" };
    const within = Math.max(0, Math.min(Math.floor(offset), region.len16));
    return {
      line: region.line,
      byteColumn: utf16ToByteOffset(text, region.startCol16 + within),
      precision: "exact",
    };
  }

  if (region.mapping === "lines") {
    if (!hasOffset) return { line: region.startLine, byteColumn: 0, precision: "line" };
    let remaining = Math.max(0, Math.floor(offset));
    for (let index = 0; index < region.lengths.length; index += 1) {
      const line = region.startLine + index;
      const text = lines[line];
      if (typeof text !== "string") return null;
      if (remaining <= region.lengths[index]) {
        return {
          line,
          byteColumn: utf16ToByteOffset(text, region.columns[index] + remaining),
          precision: "exact",
        };
      }
      remaining -= region.lengths[index] + 1;
    }
    // Past the end of the block: report its last line rather than run off it.
    const last = region.lengths.length - 1;
    const text = lines[region.startLine + last];
    if (typeof text !== "string") return null;
    return {
      line: region.startLine + last,
      byteColumn: utf16ToByteOffset(text, region.columns[last] + region.lengths[last]),
      precision: "exact",
    };
  }

  if (region.mapping === "block") {
    return {
      line: region.line,
      byteColumn: 0,
      precision: region.endLine - region.line === 1 ? "line" : "block",
    };
  }

  return null;
}

// ---------------------------------------------------------------------------
// Installation
// ---------------------------------------------------------------------------

export function provenancePlugin(md) {
  for (const rule of inlineRules(md)) {
    md.inline.ruler.at(rule.name, wrapInlineRule(rule.fn), { alt: rule.alt });
  }
  // `Ruler.at()` throws "Parser rule not found" if either name ever disappears,
  // so a markdown-it upgrade that reorganises these fails loudly at construction
  // instead of silently reporting stale columns.
  md.inline.ruler2.at("fragments_join", fragmentsJoinWithSpans);
  md.core.ruler.at("text_join", textJoinWithSpans);
  // Registered after `inline` and therefore ahead of every core rule registered
  // earlier -- `Ruler.after()` inserts at index+1 -- so the line maps are built
  // from pristine inline content, before markdown-it-task-lists rewrites it.
  md.core.ruler.after("inline", "md-viewer_provenance", provenanceCoreRule);
}
