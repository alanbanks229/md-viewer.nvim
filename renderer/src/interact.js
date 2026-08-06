// The `interact` method: typed actions over the shared hidden page.
//
// Everything here is either pure (envelope validation, link classification,
// source resolution) or a self-contained function serialized into the page by
// `page.evaluate`. Nothing in this module touches the page directly -- that is
// browser.js's job, and only after ensureDocumentActive() has established which
// document is loaded.

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

/// Convert a block's `data-source-*` attributes into a Neovim source position.
///
/// markdown-it `token.map` is `[startLine, endLine)` with **0-based** lines and
/// an **exclusive** end. Neovim lines are 1-based inclusive. This conversion
/// lives in exactly one place because Part 5 inherits it.
///
/// Precision is honest, never optimistic:
///   - a block spanning exactly one source line means we genuinely know the
///     line, so `line`;
///   - a multi-line block means we know the block only, so `block`, and `line`
///     reports the block's first line;
///   - no block at all means `none`, with no position guessed.
/// `exact` requires inline provenance, which does not exist until Part 5, so
/// this function can never return it.
export function resolveSourcePosition(block) {
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

  const element = document.elementFromPoint(x, y);
  if (!element) return miss("no_element");

  // The article carries the page padding and the scroll-past-end padding, and
  // has no data-source-* attributes of its own, so side padding, top padding,
  // bottom padding, and the gaps between blocks all land here and all honestly
  // report "none".
  const block = element.closest("[data-source-start][data-source-end]");
  if (!block) return miss("outside_content");

  let caretNode = null;
  let caretOffset = null;
  let strategy = "element-only";
  const wantPosition = input.strategy === "auto" || input.strategy === "caret-position";
  const wantRange = input.strategy === "auto" || input.strategy === "caret-range";

  if (wantPosition && typeof document.caretPositionFromPoint === "function") {
    const position = document.caretPositionFromPoint(x, y);
    if (position && position.offsetNode) {
      caretNode = position.offsetNode;
      caretOffset = position.offset;
      strategy = "caret-position";
    }
  }
  if (caretNode === null && wantRange && typeof document.caretRangeFromPoint === "function") {
    const range = document.caretRangeFromPoint(x, y);
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

  const anchor = element.closest("a[href]");
  const image = element.closest("img");
  // Always bounded: a hit descriptor must never carry an unbounded slab of
  // document text back across the process boundary.
  const limit = input.previewLimit > 0 ? input.previewLimit : 120;

  return {
    ok: true,
    reason: "hit",
    strategy,
    block: {
      sourceStart: Number(block.getAttribute("data-source-start")),
      sourceEnd: Number(block.getAttribute("data-source-end")),
      // Part 5 adds data-md-source-id; null until then.
      sourceId: block.getAttribute("data-md-source-id"),
      tagName: block.tagName,
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

/// Turn the raw in-page result into the normalized §3.5 hit shape.
export function normalizeHit(raw) {
  const sourcePosition = resolveSourcePosition(raw.block);
  return {
    node: raw.node,
    offset: raw.offset,
    sourceId: raw.block?.sourceId ?? null,
    sourcePosition,
    precision: sourcePosition.precision,
    strategy: raw.strategy,
    reason: raw.reason,
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
