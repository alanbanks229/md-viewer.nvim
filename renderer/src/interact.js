// The `interact` method: typed actions over the shared hidden page.
//
// Everything here is either pure (envelope validation, link classification,
// source resolution) or a self-contained function serialized into the page by
// `page.evaluate`. Nothing in this module touches the page directly -- that is
// browser.js's job, and only after ensureDocumentActive() has established which
// document is loaded.

import { resolveRegionPosition } from "./provenance.js";

export const CARET_STRATEGIES = Object.freeze(["auto", "caret-position", "caret-range", "element-only"]);

// Implemented now. `mutatesVisibleState` drives §3.4: an action that changes
// what the user sees must produce its screenshot inside the same queued
// operation, so Lua never has to issue a follow-up capture. Neither action here
// mutates anything -- both are read-only hit tests -- but the flag is the seam
// Part 6's selection actions flip.
export const INTERACT_ACTIONS = Object.freeze({
  hit_test: Object.freeze({ mutatesVisibleState: false, requiresCoordinates: true }),
  activate_at: Object.freeze({ mutatesVisibleState: false, requiresCoordinates: true }),
});

// Named so that adding them is additive and so a caller that arrives early gets
// an honest answer instead of "unknown method". Part 6 implements these.
export const RESERVED_ACTIONS = Object.freeze([
  "selection_preview",
  "selection_commit",
  "selection_clear",
  "selection_text",
  "word_select",
  "find_set",
  "find_next",
  "find_previous",
  "find_clear",
]);

export const TEXT_PREVIEW_LIMIT = 120;

export function createInteractError(code, message, detail) {
  const error = new Error(message);
  error.code = code;
  if (detail !== undefined) error.detail = detail;
  return error;
}

/// Classify a link for Part 4's dispatch table. Metadata only -- the renderer
/// never follows a link, and the hidden page never navigates away from the
/// generated document.
///
/// The sanitizer already restricts `a` schemes to http/https/mailto, so most of
/// this is defence in depth against a future change to that allowlist.
export function classifyLink(href) {
  if (typeof href !== "string") return { href: "", type: "unsafe" };
  const trimmed = href.trim();
  if (trimmed === "") return { href: "", type: "unsafe" };
  if (trimmed.startsWith("#")) return { href: trimmed, type: "fragment" };
  // Protocol-relative: inherits the page scheme, so it is a network fetch
  // wearing a relative path's clothes.
  if (trimmed.startsWith("//")) return { href: trimmed, type: "unsafe" };
  const scheme = /^([a-zA-Z][a-zA-Z0-9+.\-]*):/.exec(trimmed);
  if (!scheme) return { href: trimmed, type: "local_file" };
  switch (scheme[1].toLowerCase()) {
    case "http":
      return { href: trimmed, type: "http" };
    case "https":
      return { href: trimmed, type: "https" };
    case "mailto":
      return { href: trimmed, type: "mailto" };
    case "file":
      // Part 4 decides whether it is inside the configured document root; that
      // is the only place that knows the root.
      return { href: trimmed, type: "local_file" };
    default:
      return { href: trimmed, type: "unsafe" };
  }
}

/// Convert a hit into a Neovim source position, preferring inline provenance
/// and falling back to the block's `data-source-*` attributes.
///
/// markdown-it `token.map` is `[startLine, endLine)` with **0-based** lines and
/// an **exclusive** end, and `provenance.js` reports 0-based lines for the same
/// reason. Neovim lines are 1-based inclusive. Both conversions live here, in
/// one place, because there is exactly one `+ 1` in the whole chain.
///
/// Precision is honest, never optimistic:
///   - a region the parser placed, hit with a real caret offset, is `exact`;
///   - a region hit without a caret offset (element-only resolution) reports
///     that region's `line`, never a guessed column;
///   - a block spanning exactly one source line means we genuinely know the
///     line, so `line`;
///   - a multi-line block means we know the block only, so `block`, and `line`
///     reports the block's first line;
///   - no block at all means `none`, with no position guessed.
///
/// `inline` and `sourceMap` are optional: called with a block alone -- which is
/// what a document rendered before Part 5, or one whose markup was supplied
/// directly, produces -- this behaves exactly as it did in Parts 3 and 4.
export function resolveSourcePosition(block, inline, sourceMap) {
  const region = resolveRegionPosition(sourceMap, inline?.sourceId, inline?.offset);
  if (region) {
    return { line: region.line + 1, byteColumn: region.byteColumn, precision: region.precision };
  }
  const start = Number(block?.sourceStart);
  const end = Number(block?.sourceEnd);
  if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0) {
    return { line: null, byteColumn: null, precision: "none" };
  }
  return {
    line: start + 1,
    byteColumn: 0,
    precision: end - start === 1 ? "line" : "block",
  };
}

function requireFiniteNumber(value, name) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    throw createInteractError("INVALID_INTERACTION", `${name} must be a finite number`);
  }
  return parsed;
}

/// Validate and normalize an `interact` envelope. Pure and synchronous, so the
/// caller can run it before its first `await` -- see the lane-stamping ordering
/// requirement in main.js.
export function validateEnvelope(params) {
  const envelope = params ?? {};
  if (typeof envelope.documentId !== "string" || envelope.documentId === "") {
    throw createInteractError("INVALID_INTERACTION", "interact requires a documentId string");
  }
  if (envelope.contentRevision === undefined || envelope.contentRevision === null) {
    throw createInteractError("INVALID_INTERACTION", "interact requires a contentRevision");
  }
  if (typeof envelope.action !== "string" || envelope.action === "") {
    throw createInteractError("INVALID_INTERACTION", "interact requires an action string");
  }

  const action = INTERACT_ACTIONS[envelope.action];
  if (!action) {
    if (RESERVED_ACTIONS.includes(envelope.action)) {
      throw createInteractError(
        "UNSUPPORTED_ACTION",
        `interact action ${envelope.action} is reserved but not implemented yet`,
        { action: envelope.action, reserved: true }
      );
    }
    throw createInteractError(
      "UNKNOWN_ACTION",
      `unknown interact action: ${envelope.action}`,
      { action: envelope.action, implemented: Object.keys(INTERACT_ACTIONS) }
    );
  }

  const viewportWidthPx = requireFiniteNumber(envelope.viewportWidthPx, "viewportWidthPx");
  const viewportHeightPx = requireFiniteNumber(envelope.viewportHeightPx, "viewportHeightPx");
  if (viewportWidthPx <= 0 || viewportHeightPx <= 0) {
    throw createInteractError("INVALID_INTERACTION", "viewportWidthPx and viewportHeightPx must be positive");
  }

  let coordinates = null;
  if (action.requiresCoordinates) {
    const point = envelope.coordinates;
    if (!point || typeof point !== "object") {
      throw createInteractError("INVALID_INTERACTION", `interact action ${envelope.action} requires coordinates {x, y}`);
    }
    // Deliberately not clamped. Clamping an out-of-bounds point would turn a
    // click past the edge of the image into a confident hit on real content;
    // out-of-viewport coordinates resolve to precision "none" instead.
    coordinates = {
      x: requireFiniteNumber(point.x, "coordinates.x"),
      y: requireFiniteNumber(point.y, "coordinates.y"),
    };
  }

  const strategy = envelope.strategy ?? "auto";
  if (!CARET_STRATEGIES.includes(strategy)) {
    throw createInteractError(
      "INVALID_INTERACTION",
      `unknown caret strategy: ${strategy}; expected one of ${CARET_STRATEGIES.join(", ")}`
    );
  }

  const clickCount = envelope.clickCount === undefined ? 1 : Number(envelope.clickCount);
  if (!Number.isInteger(clickCount) || clickCount < 1) {
    throw createInteractError("INVALID_INTERACTION", "clickCount must be a positive integer");
  }

  const modifiers = envelope.modifiers ?? {};
  if (typeof modifiers !== "object" || Array.isArray(modifiers)) {
    throw createInteractError("INVALID_INTERACTION", "modifiers must be an object of booleans");
  }

  const scrollY = envelope.scrollY === undefined ? 0 : requireFiniteNumber(envelope.scrollY, "scrollY");
  if (scrollY < 0) throw createInteractError("INVALID_INTERACTION", "scrollY must not be negative");

  // How much of the image one terminal cell covers, in CSS pixels. Optional:
  // absent or zero means "resolve the given point only", which is what every
  // caller did before this existed.
  const cellWidthPx = envelope.cellWidthPx === undefined || envelope.cellWidthPx === null
    ? 0
    : requireFiniteNumber(envelope.cellWidthPx, "cellWidthPx");
  const cellHeightPx = envelope.cellHeightPx === undefined || envelope.cellHeightPx === null
    ? 0
    : requireFiniteNumber(envelope.cellHeightPx, "cellHeightPx");
  if (cellWidthPx < 0 || cellHeightPx < 0) {
    throw createInteractError("INVALID_INTERACTION", "cellWidthPx and cellHeightPx must not be negative");
  }

  return {
    documentId: envelope.documentId,
    contentRevision: envelope.contentRevision,
    action: envelope.action,
    actionSpec: action,
    coordinates,
    modifiers: {
      ctrl: modifiers.ctrl === true,
      shift: modifiers.shift === true,
      alt: modifiers.alt === true,
      meta: modifiers.meta === true,
    },
    clickCount,
    strategy,
    scrollY,
    cellWidthPx,
    cellHeightPx,
    viewportWidthPx,
    viewportHeightPx,
    // An action that mutates visible state always captures. Anything else may
    // opt in, which is how the same-queued-operation capture path is exercised
    // before Part 6 ships the first mutating action.
    capture: action.mutatesVisibleState || envelope.capture === true,
    captureScale: envelope.captureScale === "device" ? "device" : "css",
  };
}

/// The `page.evaluate` body. Serialized into the page, so it must be entirely
/// self-contained: no closures over module scope, no imports.
///
/// Precedence matters and is the subtle part. `elementFromPoint` is
/// authoritative for "is there content here"; the caret APIs only *refine* a hit
/// that already landed on content. Caret APIs snap to the nearest text node, so
/// consulting them first would turn a click in the scroll-past-end padding into
/// a confident hit on the last paragraph.
export function hitTestInPage(input) {
  const token = input.token;
  const root = document.documentElement;
  // Layer 3 of document isolation: even if every Node-side check were wrong,
  // this refuses to answer from the wrong document's DOM.
  if (root.getAttribute("data-md-viewer-doc") !== token) {
    return { error: "DOCUMENT_MISMATCH", expected: token, actual: root.getAttribute("data-md-viewer-doc") };
  }

  const x = input.x;
  const y = input.y;
  const miss = (reason) => ({
    ok: true,
    reason,
    strategy: "none",
    block: null,
    node: null,
    offset: null,
    element: null,
    link: null,
  });

  if (!(x >= 0 && y >= 0 && x < window.innerWidth && y < window.innerHeight)) {
    return miss("outside_viewport");
  }

  // A terminal reports which *cell* was clicked and never where inside it, so
  // the click genuinely covers a whole cell -- typically wider than a rendered
  // character. Resolving only the cell's centre discards that, and it discards
  // it exactly at the edges of the text: the cell holding the first character
  // of a line also holds the page's left padding, so its centre lands on the
  // article and the click does nothing at all. That was reported as "I cannot
  // click the first character of a line".
  //
  // So probe outward from the centre, bounded by the cell the user actually
  // clicked, and take the nearest content. This is not the clamping Part 3
  // refused: it never reaches beyond one cell, so a click in the middle of the
  // scroll-past-end padding still finds nothing across the whole cell and still
  // honestly reports "none". Horizontal only -- a cell is about as tall as a
  // rendered line, so probing vertically could answer from the line above or
  // below, which is a worse error than the one being fixed.
  const cellWidth = input.cellWidthPx > 0 ? input.cellWidthPx : 0;
  const offsets = cellWidth > 0 ? [0, 0.25, -0.25, 0.45, -0.45].map((f) => f * cellWidth) : [0];

  let element = null;
  let block = null;
  let pointX = x;
  let sawElement = false;
  for (const dx of offsets) {
    const px = x + dx;
    if (!(px >= 0 && px < window.innerWidth)) continue;
    const candidate = document.elementFromPoint(px, y);
    if (!candidate) continue;
    sawElement = true;
    // The article carries the page padding and the scroll-past-end padding, and
    // has no data-source-* attributes of its own, so side padding, top padding,
    // bottom padding, and the gaps between blocks all land here.
    const candidateBlock = candidate.closest("[data-source-start][data-source-end]");
    if (!candidateBlock) continue;
    element = candidate;
    block = candidateBlock;
    pointX = px;
    break;
  }
  if (!sawElement) return miss("no_element");
  if (!block) return miss("outside_content");
  const cellSnapped = pointX !== x;

  let caretNode = null;
  let caretOffset = null;
  let strategy = "element-only";
  const wantPosition = input.strategy === "auto" || input.strategy === "caret-position";
  const wantRange = input.strategy === "auto" || input.strategy === "caret-range";

  // Resolved at the point the content was actually found at, not the cell's
  // centre: a caret taken from a centre that landed in the page padding would
  // contradict the block just resolved a few pixels to its right.
  if (wantPosition && typeof document.caretPositionFromPoint === "function") {
    const position = document.caretPositionFromPoint(pointX, y);
    if (position && position.offsetNode) {
      caretNode = position.offsetNode;
      caretOffset = position.offset;
      strategy = "caret-position";
    }
  }
  if (caretNode === null && wantRange && typeof document.caretRangeFromPoint === "function") {
    const range = document.caretRangeFromPoint(pointX, y);
    if (range && range.startContainer) {
      caretNode = range.startContainer;
      caretOffset = range.startOffset;
      strategy = "caret-range";
    }
  }
  // A caret that snapped outside the block we actually hit would silently
  // relocate the answer into a neighbouring block. Discard it and fall back to
  // element-level resolution rather than report someone else's position.
  if (caretNode !== null && !block.contains(caretNode)) {
    caretNode = null;
    caretOffset = null;
    strategy = "element-only";
  }

  // The innermost provenance region under the point. Both routes to it are
  // wrong on their own: elementFromPoint can land on a container while the caret
  // sits in a specific run inside it, and a caret snaps to an *ancestor* when
  // there is no text to land in (an image's paragraph has none), which would
  // throw away the image elementFromPoint had already found. So take whichever
  // is deeper.
  let runElement = null;
  if (caretNode !== null) {
    const caretElement = caretNode.nodeType === 3 ? caretNode.parentElement : caretNode;
    runElement = caretElement === null ? null : caretElement.closest("[data-md-source-id]");
  }
  const elementRun = element.closest("[data-md-source-id]");
  if (elementRun !== null && (runElement === null || runElement.contains(elementRun))) {
    runElement = elementRun;
  }
  // A region outside the block we actually hit would relocate the answer into a
  // neighbouring block, exactly as a stray caret would. Discard it.
  if (runElement !== null && !block.contains(runElement)) runElement = null;

  // Offset of the caret within the whole region, not within one text node: a
  // highlighted code block splits its text across many nodes, and a region that
  // reported a per-node offset would resolve to the wrong column inside it.
  let runOffset = null;
  let runLength = null;
  if (runElement !== null) {
    runLength = (runElement.textContent || "").length;
    if (caretNode !== null && caretNode.nodeType === 3 && runElement.contains(caretNode)) {
      const walker = document.createTreeWalker(runElement, NodeFilter.SHOW_TEXT);
      let consumed = 0;
      let node = walker.nextNode();
      while (node !== null) {
        if (node === caretNode) {
          runOffset = consumed + caretOffset;
          break;
        }
        consumed += node.nodeValue.length;
        node = walker.nextNode();
      }
    }
  }

  const anchor = element.closest("a[href]");
  const image = element.closest("img");
  // Always bounded: a hit descriptor must never carry an unbounded slab of
  // document text back across the process boundary.
  const limit = input.previewLimit > 0 ? input.previewLimit : 120;

  return {
    ok: true,
    reason: "hit",
    strategy,
    // True when the cell's centre missed and the answer came from elsewhere
    // inside the same cell. Diagnostic only, but it is the difference between
    // "the pointer was over this" and "the pointer's cell overlapped this".
    cellSnapped,
    block: {
      sourceStart: Number(block.getAttribute("data-source-start")),
      sourceEnd: Number(block.getAttribute("data-source-end")),
      sourceId: block.getAttribute("data-md-source-id"),
      tagName: block.tagName,
    },
    // The provenance key and the caret's position inside it. Opaque: the mapping
    // itself lives in Node memory, so nothing derived from the Markdown source
    // ever travels back out of the page.
    inline: runElement === null ? null : {
      sourceId: runElement.getAttribute("data-md-source-id"),
      offset: runOffset,
      textLength: runLength,
    },
    // DOM node identity never crosses the process boundary. This descriptor is
    // for diagnostics and tests; Part 6 hit-tests both selection endpoints
    // inside a single evaluate, so it never needs to round-trip a node.
    node: caretNode === null ? null : { nodeType: caretNode.nodeType, nodeName: caretNode.nodeName },
    offset: caretOffset,
    element: {
      tagName: element.tagName,
      className: typeof element.className === "string" ? element.className : "",
      textPreview: (element.textContent || "").slice(0, limit),
      isImage: image !== null,
    },
    link: anchor === null ? null : { href: anchor.getAttribute("href") },
  };
}

/// Turn the raw in-page result into the normalized §3.5 hit shape. `sourceMap`
/// is the provenance record for this document, held in Node memory; without it
/// resolution falls back to block precision.
export function normalizeHit(raw, sourceMap) {
  const sourcePosition = resolveSourcePosition(raw.block, raw.inline, sourceMap);
  return {
    node: raw.node,
    offset: raw.offset,
    // The most specific region the hit landed in, which is the inline run when
    // there is one and the enclosing block otherwise.
    sourceId: raw.inline?.sourceId ?? raw.block?.sourceId ?? null,
    sourcePosition,
    precision: sourcePosition.precision,
    strategy: raw.strategy,
    reason: raw.reason,
    cellSnapped: raw.cellSnapped === true,
    element: raw.element,
    link: raw.link ? classifyLink(raw.link.href) : null,
    blockStartLine: raw.block ? raw.block.sourceStart + 1 : null,
    blockEndLine: raw.block ? raw.block.sourceEnd : null,
  };
}

/// Shape the normalized hit into the action's result. `activate_at` reports a
/// link when the point is over one and falls back to source semantics
/// otherwise, so Part 4's "an unmodified click on a link still navigates to
/// source" needs no second round trip.
export function buildActionResult(action, hit) {
  if (action === "activate_at" && hit.link) {
    return { kind: "link", link: hit.link, sourcePosition: hit.sourcePosition, hit };
  }
  return { kind: "source", sourcePosition: hit.sourcePosition, hit };
}
