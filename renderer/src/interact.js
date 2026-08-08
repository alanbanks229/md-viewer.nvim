// The `interact` method: typed actions over the shared hidden page.
//
// Everything here is either pure (envelope validation, link classification,
// source resolution) or a self-contained function serialized into the page by
// `page.evaluate`. Nothing in this module touches the page directly -- that is
// browser.js's job, and only after ensureDocumentActive() has established which
// document is loaded.

import { resolveRegionPosition } from "./provenance.js";

export const CARET_STRATEGIES = Object.freeze(["auto", "caret-position", "caret-range", "element-only"]);

// `mutatesVisibleState` drives §3.4: an action that changes what the user sees
// must produce its screenshot inside the same queued operation, so Lua never
// has to issue a follow-up capture. `requiresAnchor` marks the two selection
// actions that need a second point (the drag's fixed start) alongside
// `coordinates`, which is the focus/moving point for those two. `requiresQuery`
// marks the one action that needs literal search text.
export const INTERACT_ACTIONS = Object.freeze({
  hit_test: Object.freeze({ mutatesVisibleState: false, requiresCoordinates: true }),
  activate_at: Object.freeze({ mutatesVisibleState: false, requiresCoordinates: true }),
  selection_preview: Object.freeze({ mutatesVisibleState: true, requiresCoordinates: true, requiresAnchor: true }),
  selection_commit: Object.freeze({ mutatesVisibleState: true, requiresCoordinates: true, requiresAnchor: true }),
  selection_clear: Object.freeze({ mutatesVisibleState: true, requiresCoordinates: false }),
  // Read-only: it re-queries the live DOM selection rather than mutating it, so
  // a copy can never itself "commit" a selection that was only ever previewed.
  selection_text: Object.freeze({ mutatesVisibleState: false, requiresCoordinates: false }),
  word_select: Object.freeze({ mutatesVisibleState: true, requiresCoordinates: true }),
  paragraph_select: Object.freeze({ mutatesVisibleState: true, requiresCoordinates: true }),
  find_set: Object.freeze({ mutatesVisibleState: true, requiresCoordinates: false, requiresQuery: true }),
  find_next: Object.freeze({ mutatesVisibleState: true, requiresCoordinates: false }),
  find_previous: Object.freeze({ mutatesVisibleState: true, requiresCoordinates: false }),
  find_clear: Object.freeze({ mutatesVisibleState: true, requiresCoordinates: false }),
});

// Kept empty rather than removed: it is what keeps validateEnvelope's
// reserved-vs-unknown branch structurally meaningful for whatever a later part
// reserves next, and a caller mid-upgrade against an old build still gets an
// honest "not implemented yet" instead of "unknown method".
export const RESERVED_ACTIONS = Object.freeze([]);

export const TEXT_PREVIEW_LIMIT = 120;

// The selection background each theme's ::selection rule paints, as one
// straight-alpha src-over constant. This is the single value the browser's
// settle frame and the Lua-drawn drag overlay must share: if they disagree,
// the highlight visibly changes color the instant the mouse is released.
// Must stay equal to --selection-bg in renderer/assets/preview-dark.css /
// preview-light.css; tests/node/selection-tint.test.js measures the captured
// pixels and fails if the CSS and this constant drift apart.
export const SELECTION_TINT = Object.freeze({
  dark: Object.freeze({ r: 220, g: 220, b: 220, a: 0.3 }),
  light: Object.freeze({ r: 128, g: 128, b: 128, a: 0.3 }),
});

// Hard ceiling on selection rectangles reported per frame. A viewport-clipped
// selection produces one rect per visible line box (~40-80 on a full preview;
// dense tables can double that), so this is far above any real frame; if it is
// ever exceeded the result says so via rectsTruncated and Lua falls back to a
// captured frame rather than drawing a highlight with missing pieces.
export const MAX_SELECTION_RECTS = 256;

// A find_set response over NDJSON must stay bounded: DOM highlighting marks
// every match regardless (that is a correctness requirement), but a document
// with thousands of hits for a common word must not serialize thousands of
// per-match source positions on every keystroke of a search. `matchCount`
// always reports the true total even when `matches` is capped.
export const MAX_FIND_MATCHES_REPORTED = 500;

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

  // The drag's fixed start point, alongside `coordinates` as the moving/focus
  // point. Sent explicitly on every request rather than remembered server-side,
  // so a selection request is fully self-describing and replayable on its own.
  let anchorCoordinates = null;
  if (action.requiresAnchor) {
    const point = envelope.anchorCoordinates;
    if (!point || typeof point !== "object") {
      throw createInteractError("INVALID_INTERACTION", `interact action ${envelope.action} requires anchorCoordinates {x, y}`);
    }
    anchorCoordinates = {
      x: requireFiniteNumber(point.x, "anchorCoordinates.x"),
      y: requireFiniteNumber(point.y, "anchorCoordinates.y"),
    };
  }

  // Matched literally, never as a regular expression -- see setFindInPage.
  let query = null;
  if (action.requiresQuery) {
    if (typeof envelope.query !== "string" || envelope.query.trim() === "") {
      throw createInteractError("INVALID_INTERACTION", `interact action ${envelope.action} requires a non-empty query`);
    }
    query = envelope.query.trim();
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

  // `null` (not 0) when omitted: browser.js's ensureDocumentActive() falls
  // back to the document's own last known scroll position in that case,
  // rather than snapping the shared page to the top on every action that
  // forgets to send scrollY.
  const scrollY = envelope.scrollY === undefined ? null : requireFiniteNumber(envelope.scrollY, "scrollY");
  if (scrollY !== null && scrollY < 0) throw createInteractError("INVALID_INTERACTION", "scrollY must not be negative");

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

  // Ask for the solid tint-sheet PNG the Lua overlay places crops of. Sent
  // only until kitty_raw's upload cache is warm, so the ~KB payload is not on
  // every drag frame. Dimensions are device pixels (the base image's own).
  let overlaySheet = null;
  if (envelope.overlaySheet !== undefined && envelope.overlaySheet !== null) {
    const sheet = envelope.overlaySheet;
    if (typeof sheet !== "object" || Array.isArray(sheet)) {
      throw createInteractError("INVALID_INTERACTION", "overlaySheet must be an object of {widthPx, heightPx}");
    }
    const widthPx = requireFiniteNumber(sheet.widthPx, "overlaySheet.widthPx");
    const heightPx = requireFiniteNumber(sheet.heightPx, "overlaySheet.heightPx");
    if (widthPx <= 0 || heightPx <= 0) {
      throw createInteractError("INVALID_INTERACTION", "overlaySheet dimensions must be positive");
    }
    // A transparent margin, for terminals that express a rectangle's sub-cell
    // position by cropping into it rather than with the protocol's X/Y keys.
    // Optional: absent means no margin, and no margin is byte-identical to the
    // sheet every other terminal was validated against.
    const marginX = sheet.marginX === undefined || sheet.marginX === null
      ? 0
      : requireFiniteNumber(sheet.marginX, "overlaySheet.marginX");
    const marginY = sheet.marginY === undefined || sheet.marginY === null
      ? 0
      : requireFiniteNumber(sheet.marginY, "overlaySheet.marginY");
    if (marginX < 0 || marginY < 0 || marginX >= widthPx || marginY >= heightPx) {
      throw createInteractError(
        "INVALID_INTERACTION",
        "overlaySheet margins must be non-negative and leave some sheet behind"
      );
    }
    overlaySheet = { widthPx, heightPx, marginX, marginY };
  }

  return {
    documentId: envelope.documentId,
    contentRevision: envelope.contentRevision,
    action: envelope.action,
    actionSpec: action,
    coordinates,
    anchorCoordinates,
    query,
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
    overlaySheet,
    viewportWidthPx,
    viewportHeightPx,
    // An action that mutates visible state always captures. Anything else may
    // opt in, which is how the same-queued-operation capture path is exercised
    // before Part 6 ships the first mutating action. `capture: false` is the
    // stage-4 opt-out: a moving drag-preview frame displays the selection as a
    // Lua-drawn overlay built from this same operation's rect geometry, so no
    // screenshot exists to take. §3.4's guarantee -- Lua never issues a
    // follow-up capture for a frame it displays -- still holds: the one queued
    // operation returns everything the displayed frame is made of.
    capture: envelope.capture === false
      ? false
      : action.mutatesVisibleState || envelope.capture === true,
    // "css" (the cheap, slightly-soft scroll fast-frame scale) is opt-in
    // only; anything that doesn't explicitly ask for it renders sharp.
    captureScale: envelope.captureScale === "css" ? "css" : "device",
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
  // the click genuinely covers a whole cell -- and a cell is neither as wide as
  // a rendered character nor as tall as a rendered line. Resolving only the
  // cell's centre throws that away, and it throws it away exactly where the
  // text is. Both axes have produced a reported bug:
  //
  //   - horizontally, the cell holding the first character of a line also holds
  //     the page's left padding, so its centre lands on the article and the
  //     click does nothing. Reported as "I cannot click the first character of
  //     a line".
  //   - vertically, a cell covers 20 CSS px (coordinates.lua's estimated tier)
  //     while a rendered line is 25, so an inline link's box -- 18 px for a
  //     16 px font -- can fall entirely *between* two cell-row centres. This is
  //     measured, not reasoned: on a real document a link occupying y
  //     91.6-109.6, with cell-row centres at 90 and 110, was unreachable from
  //     every cell in the window at any click position. Enlarging the terminal
  //     font changed nothing about the geometry except its phase, and made the
  //     same link clickable again -- which is exactly how it was reported.
  //
  // So probe outward from the centre in both axes, bounded by the cell the user
  // actually clicked, and take the nearest content. This is not the clamping
  // Part 3 refused: it never reaches beyond half a cell, so a click in the
  // middle of the scroll-past-end padding still finds nothing across the whole
  // cell and still honestly reports "none". Reaching half a cell vertically can
  // only ever touch a line that same cell already covers.
  const cellWidth = input.cellWidthPx > 0 ? input.cellWidthPx : 0;
  const cellHeight = input.cellHeightPx > 0 ? input.cellHeightPx : 0;
  const fractions = [0, 0.25, -0.25, 0.45, -0.45];
  const probes = [];
  for (const fx of cellWidth > 0 ? fractions : [0]) {
    for (const fy of cellHeight > 0 ? fractions : [0]) {
      // Distance in cell *fractions*, not pixels: a cell twice as tall as it is
      // wide would otherwise make every vertical probe lose to every horizontal
      // one, and "nearest" would silently mean "nearest horizontally".
      probes.push({ dx: fx * cellWidth, dy: fy * cellHeight, distance: Math.abs(fx) + Math.abs(fy) });
    }
  }
  probes.sort((a, b) => a.distance - b.distance);

  let element = null;
  let block = null;
  let pointX = x;
  let pointY = y;
  let sawElement = false;
  // Tracked apart from the nearest content: if a link is anywhere under the
  // cell the user clicked, they were clicking the link. The cell is the
  // resolution limit of the entire input device -- there is no finer answer
  // available to give -- so prose wins only when the cell holds no link at all.
  // Probes are ordered nearest-first, so a cell straddling two links still
  // resolves to the closer one.
  let linkElement = null;
  let linkBlock = null;
  let linkX = x;
  let linkY = y;
  for (const probe of probes) {
    const px = x + probe.dx;
    const py = y + probe.dy;
    if (!(px >= 0 && px < window.innerWidth && py >= 0 && py < window.innerHeight)) continue;
    const candidate = document.elementFromPoint(px, py);
    if (!candidate) continue;
    sawElement = true;
    // The article carries the page padding and the scroll-past-end padding, and
    // has no data-source-* attributes of its own, so side padding, top padding,
    // bottom padding, and the gaps between blocks all land here.
    const candidateBlock = candidate.closest("[data-source-start][data-source-end]");
    if (!candidateBlock) continue;
    if (element === null) {
      element = candidate;
      block = candidateBlock;
      pointX = px;
      pointY = py;
    }
    if (candidate.closest("a[href]") !== null) {
      linkElement = candidate;
      linkBlock = candidateBlock;
      linkX = px;
      linkY = py;
      break;
    }
  }
  if (linkElement !== null) {
    element = linkElement;
    block = linkBlock;
    pointX = linkX;
    pointY = linkY;
  }
  if (!sawElement) return miss("no_element");
  if (!block) return miss("outside_content");
  const cellSnapped = pointX !== x || pointY !== y;

  let caretNode = null;
  let caretOffset = null;
  let strategy = "element-only";
  const wantPosition = input.strategy === "auto" || input.strategy === "caret-position";
  const wantRange = input.strategy === "auto" || input.strategy === "caret-range";

  // Resolved at the point the content was actually found at, not the cell's
  // centre: a caret taken from a centre that landed in the page padding, or in
  // the leading between two lines, would contradict the block just resolved a
  // few pixels away from it.
  if (wantPosition && typeof document.caretPositionFromPoint === "function") {
    const position = document.caretPositionFromPoint(pointX, pointY);
    if (position && position.offsetNode) {
      caretNode = position.offsetNode;
      caretOffset = position.offset;
      strategy = "caret-position";
    }
  }
  if (caretNode === null && wantRange && typeof document.caretRangeFromPoint === "function") {
    const range = document.caretRangeFromPoint(pointX, pointY);
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

// ---------------------------------------------------------------------------
// Part 6 -- selection and search.
//
// Each `*InPage` function below is a second, independent `page.evaluate` body,
// self-contained for the same reason `hitTestInPage` is: `page.evaluate`
// serializes `fn.toString()` and runs it standalone in the page, with no access
// to sibling module-scope functions. The cell-probe/caret-resolution routine
// `hitTestInPage` already has is therefore duplicated here rather than shared --
// the least-risk option, and it leaves hitTestInPage itself untouched.
// ---------------------------------------------------------------------------

/// `selection_preview` / `selection_commit`. Resolves both endpoints and
/// applies a real Chromium Selection; the browser paints the highlight itself.
///
/// `resolveSelectionPoint`/`applySelectionRange` are declared *inside* this
/// function (and duplicated again inside `wordSelectInPage` below) rather than
/// as siblings: `page.evaluate(fn, arg)` serializes only `fn.toString()` and
/// runs it standalone in the page, with no access to sibling module-scope
/// functions -- a top-level helper here would be a ReferenceError at
/// evaluation time, not a lint warning.
export function resolveSelectionInPage(input) {
  const token = input.token;
  const root = document.documentElement;
  if (root.getAttribute("data-md-viewer-doc") !== token) {
    return { error: "DOCUMENT_MISMATCH", expected: token, actual: root.getAttribute("data-md-viewer-doc") };
  }

  // Resolve one point to the deepest addressable position: a block, an
  // optional inline provenance run, and a DOM (node, offset) pair usable as a
  // Range boundary. Unlike hitTestInPage's miss cases, a selection endpoint
  // must always resolve to *something* -- a selection with only one
  // resolvable endpoint is not a selection -- so a point with no usable caret
  // falls back to an element text boundary (start or end, picked by which
  // side of the element's horizontal midpoint the point fell on) rather than
  // reporting a miss, and a point over no block at all slides onto the nearest
  // one (see `nearestBlockPoint`). Returns null only when the point is outside
  // the viewport or the document holds no addressable block whatsoever.
  function resolveSelectionPoint(x, y, cellWidthPx, strategy) {
    if (!(x >= 0 && y >= 0 && x < window.innerWidth && y < window.innerHeight)) return null;
    const cellWidth = cellWidthPx > 0 ? cellWidthPx : 0;
    const offsets = cellWidth > 0 ? [0, 0.25, -0.25, 0.45, -0.45].map((f) => f * cellWidth) : [0];

    // Probe the terminal cell the point came from for addressable content --
    // half a cell either side, never further. See hitTestInPage for why the
    // cell, not its centre, is the honest resolution of the input device.
    function probe(atX, atY) {
      for (const dx of offsets) {
        const px = atX + dx;
        if (!(px >= 0 && px < window.innerWidth)) continue;
        const candidate = document.elementFromPoint(px, atY);
        if (candidate === null) continue;
        const candidateBlock = candidate.closest("[data-source-start][data-source-end]");
        if (candidateBlock === null) continue;
        return { element: candidate, block: candidateBlock, x: px, y: atY };
      }
      return null;
    }

    // Slide a point that landed on no block at all onto the edge of the block
    // nearest it, and report where on that block it now sits.
    //
    // This is what makes a drag that runs past the edge of the content behave
    // the way it does in a browser or any native text editor: the selection
    // keeps extending toward the nearest text instead of freezing. It matters
    // far more than "the odd click in the margin" suggests, because
    // `interaction.locate_for_drag` clamps an off-window drag to the *edge
    // column* of the placement -- and the edge column is page padding. The
    // page carries 26px of side padding (renderer/assets/preview.css) while a
    // terminal cell is ~10-20 CSS px, so the leftmost one or two columns of
    // the preview hold no block, `probe` above found nothing, and every
    // request from a drag that left the window came back `focus_miss` and was
    // silently dropped by interaction.lua's `result.ok ~= false` check. That
    // is measured against a real Chromium, not reasoned: focus x=10.26 on an
    // 800px viewport returned focus_miss while x=20 did not.
    //
    // Vertical distance dominates the ranking, and heavily: a drag level with
    // the third paragraph but out in the left margin must stay on the third
    // paragraph, not jump to whichever block happens to be nearer in raw
    // Euclidean terms. Blocks scrolled out of view are considered only when
    // nothing is visible at all -- scroll-past-end padding can leave a
    // viewport holding no block, and freezing there would be the same bug.
    //
    // Deliberately confined to selection endpoints: hitTestInPage must keep
    // reporting an honest miss, since a click in the margin is not a click on
    // the nearest paragraph and must never activate its link.
    function nearestBlockPoint(atX, atY) {
      const candidates = document.querySelectorAll("[data-source-start][data-source-end]");
      function pick(visibleOnly) {
        let best = null;
        let bestKey = Infinity;
        for (const candidate of candidates) {
          const rect = candidate.getBoundingClientRect();
          if (!(rect.width > 0 && rect.height > 0)) continue;
          if (visibleOnly && (rect.bottom <= 0 || rect.top >= window.innerHeight)) continue;
          const dy = atY < rect.top ? rect.top - atY : atY > rect.bottom ? atY - rect.bottom : 0;
          const dx = atX < rect.left ? rect.left - atX : atX > rect.right ? atX - rect.right : 0;
          const key = dy * 100000 + dx;
          // On a tie, prefer the deeper block: a list and its list item both
          // carry source attributes, and the item is the more specific answer.
          // querySelectorAll is in document order, so the ancestor is seen first.
          if (key < bestKey || (key === bestKey && best !== null && best.block.contains(candidate))) {
            bestKey = key;
            best = { block: candidate, rect };
          }
        }
        return best;
      }
      const best = pick(true) || pick(false);
      if (best === null) return null;
      const rect = best.rect;
      const clamp = (value, low, high) => (high < low ? low : value < low ? low : value > high ? high : value);
      return {
        block: best.block,
        x: clamp(atX, rect.left + 0.5, rect.right - 0.5),
        y: clamp(atY, rect.top + 0.5, rect.bottom - 0.5),
      };
    }

    let hit = probe(x, y);
    if (hit === null) {
      const near = nearestBlockPoint(x, y);
      // The re-probe can still miss -- a block's bounding rect covers the
      // ragged end of its last wrapped line -- so the block itself stands in
      // as the element, and the caret fallback below resolves a text boundary.
      if (near !== null) {
        hit = probe(near.x, near.y) || { element: near.block, block: near.block, x: near.x, y: near.y };
      }
    }
    if (hit === null) return null;
    const element = hit.element;
    const block = hit.block;
    const pointX = hit.x;
    const pointY = hit.y;

    let caretNode = null;
    let caretOffset = null;
    const wantPosition = strategy === "auto" || strategy === "caret-position";
    const wantRange = strategy === "auto" || strategy === "caret-range";
    if (wantPosition && typeof document.caretPositionFromPoint === "function") {
      const position = document.caretPositionFromPoint(pointX, pointY);
      if (position && position.offsetNode) {
        caretNode = position.offsetNode;
        caretOffset = position.offset;
      }
    }
    if (caretNode === null && wantRange && typeof document.caretRangeFromPoint === "function") {
      const range = document.caretRangeFromPoint(pointX, pointY);
      if (range && range.startContainer) {
        caretNode = range.startContainer;
        caretOffset = range.startOffset;
      }
    }
    if (caretNode !== null && !block.contains(caretNode)) {
      caretNode = null;
      caretOffset = null;
    }

    if (caretNode === null) {
      const rect = element.getBoundingClientRect();
      const preferEnd = pointX >= rect.left + rect.width / 2;
      const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
      let first = null;
      let last = null;
      let node = walker.nextNode();
      while (node !== null) {
        if (node.nodeValue.length > 0) {
          if (first === null) first = node;
          last = node;
        }
        node = walker.nextNode();
      }
      if (preferEnd && last !== null) {
        caretNode = last;
        caretOffset = last.nodeValue.length;
      } else if (first !== null) {
        caretNode = first;
        caretOffset = 0;
      } else {
        // No text at all in this block (e.g. a lone image): the block element
        // itself is still a valid Range boundary.
        caretNode = block;
        caretOffset = 0;
      }
    }

    let runElement = null;
    const caretElement = caretNode.nodeType === 3 ? caretNode.parentElement : caretNode;
    runElement = caretElement === null ? null : caretElement.closest("[data-md-source-id]");
    const elementRun = element.closest("[data-md-source-id]");
    if (elementRun !== null && (runElement === null || runElement.contains(elementRun))) runElement = elementRun;
    if (runElement !== null && !block.contains(runElement)) runElement = null;

    let runOffset = null;
    let runLength = null;
    if (runElement !== null) {
      runLength = (runElement.textContent || "").length;
      if (caretNode.nodeType === 3 && runElement.contains(caretNode)) {
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

    return {
      node: caretNode,
      offset: caretOffset,
      block: {
        sourceStart: Number(block.getAttribute("data-source-start")),
        sourceEnd: Number(block.getAttribute("data-source-end")),
        sourceId: block.getAttribute("data-md-source-id"),
        tagName: block.tagName,
      },
      inline: runElement === null ? null : {
        sourceId: runElement.getAttribute("data-md-source-id"),
        offset: runOffset,
        textLength: runLength,
      },
    };
  }

  // Apply `selection` to `[anchorNode, anchorOffset]` -> `[focusNode,
  // focusOffset]`, preferring the direction-aware primitive.
  //
  // `setBaseAndExtent` tracks anchor/focus direction natively -- Chromium
  // paints a reverse (right-to-left or bottom-to-top) drag correctly
  // regardless of which endpoint is passed first, which is what makes reverse
  // dragging work without any extra logic here. The Range fallback is
  // realistically unreachable against the bundled Chromium (setBaseAndExtent
  // has shipped since Chrome 27); it exists only so a future engine swap
  // fails safely instead of throwing.
  function applySelectionRange(selection, anchorNode, anchorOffset, focusNode, focusOffset) {
    if (typeof selection.setBaseAndExtent === "function") {
      selection.setBaseAndExtent(anchorNode, anchorOffset, focusNode, focusOffset);
      return;
    }
    let focusFirst = false;
    if (anchorNode === focusNode) {
      focusFirst = focusOffset < anchorOffset;
    } else {
      const relation = anchorNode.compareDocumentPosition(focusNode);
      // FOLLOWING: focus comes after anchor in the document, so anchor is
      // first. PRECEDING: focus comes before anchor, so focus is first.
      focusFirst = (relation & Node.DOCUMENT_POSITION_PRECEDING) !== 0;
    }
    const range = document.createRange();
    if (focusFirst) {
      range.setStart(focusNode, focusOffset);
      range.setEnd(anchorNode, anchorOffset);
    } else {
      range.setStart(anchorNode, anchorOffset);
      range.setEnd(focusNode, focusOffset);
    }
    selection.removeAllRanges();
    selection.addRange(range);
  }

  const anchor = resolveSelectionPoint(input.anchor.x, input.anchor.y, input.cellWidthPx, input.strategy);
  if (!anchor) return { ok: false, reason: "anchor_miss" };
  const focus = resolveSelectionPoint(input.focus.x, input.focus.y, input.cellWidthPx, input.strategy);
  if (!focus) return { ok: false, reason: "focus_miss" };

  const selection = window.getSelection();
  applySelectionRange(selection, anchor.node, anchor.offset, focus.node, focus.offset);

  // Selection geometry for the stage-4 drag overlay: viewport-relative CSS
  // rectangles matching the shape the browser itself paints. Read here, from
  // the same applied Range in the same evaluate that produces `text`, so the
  // picture on screen and the string a copy would produce can never come from
  // two different requests.
  //
  // Three facts about Chromium's selection paint, all measured from real
  // captures (tests/node/selection-tint.test.js re-measures them), drive the
  // shape of this code:
  //
  //   1. Horizontally the paint is ragged per line -- it ends where the
  //      line's text ends. `Range.getClientRects()` on the whole range also
  //      reports the border box of every element fully inside it (a selected
  //      two-line paragraph comes back as one full-width block), so quads are
  //      collected per text node instead: a sub-range clipped to one text
  //      node yields only text quads.
  //   2. Vertically the paint spans the full LINE BOX, not the text quad: a
  //      16px font in a 25px line paints 25px bands that tile with no gap
  //      between consecutive lines, and a mixed-font line (prose + inline
  //      code) paints ONE uniform band. The line box is not exposed by any
  //      DOM API directly; a collapsed caret rect at the same point is, and
  //      carries the line's selection height. Probed once per rendered line.
  //   3. A selected blank line paints a stub roughly one character advance
  //      wide, not nothing (and not a hairline): the width of a single
  //      character measured from the same block.
  const rects = [];
  let rectsTruncated = false;
  if (!selection.isCollapsed && selection.rangeCount > 0) {
    const range = selection.getRangeAt(0);
    const quads = [];
    const blankLineQuads = [];

    const scope = range.commonAncestorContainer;
    const scopeElement = scope.nodeType === 3 ? scope.parentElement : scope;
    if (scopeElement !== null) {
      const walker = document.createTreeWalker(scopeElement, NodeFilter.SHOW_TEXT);
      const sub = document.createRange();
      let node = walker.nextNode();
      while (node !== null) {
        if (node.nodeValue.length > 0 && range.intersectsNode(node)) {
          sub.selectNodeContents(node);
          if (node === range.startContainer) sub.setStart(node, range.startOffset);
          if (node === range.endContainer) sub.setEnd(node, range.endOffset);
          if (!sub.collapsed) {
            for (const rect of sub.getClientRects()) {
              if (rect.height < 0.5) continue;
              if (rect.width < 0.5) {
                // A zero-width quad is a selected line break (the blank line
                // inside a code block). Remember it with its source node so
                // the stub width can be measured from a sibling character.
                blankLineQuads.push({ left: rect.left, top: rect.top, bottom: rect.bottom, node });
                continue;
              }
              quads.push({
                left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom,
                parent: node.parentElement,
              });
            }
          }
        }
        node = walker.nextNode();
      }
      // Atomic inlines have no text: a selected image is painted over in
      // full, so its border box stands in for the text quad it lacks.
      for (const image of scopeElement.querySelectorAll("img")) {
        if (range.intersectsNode(image)) {
          const rect = image.getBoundingClientRect();
          if (rect.width >= 0.5 && rect.height >= 0.5) {
            quads.push({ left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom, atomic: true });
          }
        }
      }
    }

    // One character's advance in the block containing `node`, for blank-line
    // stub widths. Measured, never guessed: fonts differ per block.
    function characterAdvance(node) {
      const block = node.parentElement === null ? null : node.parentElement.closest("pre, [data-source-start]");
      if (block === null) return 8;
      const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
      const probe = document.createRange();
      let candidate = walker.nextNode();
      while (candidate !== null) {
        if (candidate.nodeValue.length > 0 && candidate.nodeValue !== "\n") {
          probe.setStart(candidate, 0);
          probe.setEnd(candidate, 1);
          const rect = probe.getBoundingClientRect();
          if (rect.width > 0.5) return rect.width;
        }
        candidate = walker.nextNode();
      }
      return 8;
    }

    for (const blank of blankLineQuads) {
      quads.push({
        left: blank.left,
        top: blank.top,
        right: blank.left + characterAdvance(blank.node),
        bottom: blank.bottom,
        parent: blank.node.parentElement,
      });
    }

    // Expand each quad's vertical extent from the text quad to the line box
    // (fact 2): height = the containing BLOCK's computed line-height,
    // centered on the quad. The block's line-height -- not the text's own
    // inline parent's -- so the prose and inline-code fragments of one mixed
    // line land in the same band and merge, exactly as the browser paints
    // them. Centering is a ~1px approximation of Chromium's asymmetric
    // half-leading (measured: quads sit 2.6px below / 4.4px above the real
    // 25px band edges, centering puts them 3.5/3.5), which stays inside the
    // equivalence gate's rect-edge tolerance; critically, consecutive lines
    // of one block still tile with no gap and no overlap, because band tops
    // advance by exactly the same line pitch the quads do.
    const lineHeightCache = new Map();
    function blockLineHeight(element) {
      let node = element;
      while (node !== null) {
        const cached = lineHeightCache.get(node);
        if (cached !== undefined) return cached;
        const style = window.getComputedStyle(node);
        const display = style.display || "";
        const isBlock = display !== "inline" && display !== "inline-block" && display !== "contents";
        if (isBlock) {
          const parsed = parseFloat(style.lineHeight);
          const value = Number.isFinite(parsed) ? parsed : null;
          lineHeightCache.set(element, value);
          lineHeightCache.set(node, value);
          return value;
        }
        node = node.parentElement;
      }
      return null;
    }

    const banded = [];
    for (const quad of quads) {
      if (quad.atomic) {
        banded.push({ left: quad.left, top: quad.top, right: quad.right, bottom: quad.bottom });
        continue;
      }
      const height = quad.bottom - quad.top;
      const lineHeight = quad.parent ? blockLineHeight(quad.parent) : null;
      if (lineHeight !== null && lineHeight > height) {
        const pad = (lineHeight - height) / 2;
        banded.push({ left: quad.left, top: quad.top - pad, right: quad.right, bottom: quad.bottom + (lineHeight - height - pad) });
      } else {
        banded.push({ left: quad.left, top: quad.top, right: quad.right, bottom: quad.bottom });
      }
    }

    // Clip to the viewport, then merge quads that sit on the same band:
    // syntax highlighting fragments one code line into many per-token text
    // nodes, and per-token rectangles would both bloat the set and risk
    // hairline seams between placements. After band-snapping, the prose and
    // inline-code fragments of a mixed line share one band and merge into
    // one rectangle -- which is exactly how the browser paints them.
    const clipped = [];
    for (const quad of banded) {
      const left = Math.max(0, quad.left);
      const top = Math.max(0, quad.top);
      const right = Math.min(window.innerWidth, quad.right);
      const bottom = Math.min(window.innerHeight, quad.bottom);
      if (right - left < 0.5 || bottom - top < 0.5) continue;
      clipped.push({ left, top, right, bottom });
    }
    // Cluster into bands FIRST (tops within 2px are one rendered line --
    // mixed-font fragments center to sub-pixel-different tops), normalize
    // each quad to its band's extent, and only then sort left-to-right
    // within the band. Sorting by raw top instead would interleave a
    // mixed line's fragments out of horizontal order and the left-to-right
    // merge below would skip over (and lose) the middle fragment.
    clipped.sort((a, b) => a.top - b.top);
    let band = null;
    for (const quad of clipped) {
      if (band === null || quad.top > band.anchor + 2) {
        band = { anchor: quad.top, top: quad.top, bottom: quad.bottom, index: (band ? band.index + 1 : 0) };
      }
      band.top = Math.min(band.top, quad.top);
      band.bottom = Math.max(band.bottom, quad.bottom);
      quad.band = band;
    }
    for (const quad of clipped) {
      quad.top = quad.band.top;
      quad.bottom = quad.band.bottom;
    }
    clipped.sort((a, b) => (a.band.index - b.band.index) || (a.left - b.left));
    for (const quad of clipped) {
      const previous = rects[rects.length - 1];
      // A horizontal gap up to 6px within one band is painted through by the
      // browser too (an inline code span's side padding); table cells stay
      // separate -- their padding is wider than that.
      if (
        previous
        && previous.band === quad.band
        && quad.left <= previous.right + 6
      ) {
        previous.right = Math.max(previous.right, quad.right);
        continue;
      }
      rects.push({ left: quad.left, top: quad.top, right: quad.right, bottom: quad.bottom, band: quad.band });
    }
    for (const rect of rects) delete rect.band;
    if (rects.length > input.maxRects) {
      rects.length = input.maxRects;
      rectsTruncated = true;
    }
  }
  const rectList = rects.map((rect) => ({
    x: rect.left,
    y: rect.top,
    width: rect.right - rect.left,
    height: rect.bottom - rect.top,
  }));

  return {
    ok: true,
    text: selection.toString(),
    collapsed: selection.isCollapsed,
    rects: rectList,
    rectsTruncated,
    anchor: { block: anchor.block, inline: anchor.inline },
    focus: { block: focus.block, inline: focus.inline },
  };
}

/// `selection_text`. Always re-reads the live DOM Selection rather than
/// trusting a cached string -- the DOM selection is the single source of truth
/// Chromium paints, and a cached string could drift after a scroll-only
/// capture. No mutation, so this action never triggers a screenshot.
export function readSelectionTextInPage(input) {
  const token = input.token;
  const root = document.documentElement;
  if (root.getAttribute("data-md-viewer-doc") !== token) {
    return { error: "DOCUMENT_MISMATCH", expected: token, actual: root.getAttribute("data-md-viewer-doc") };
  }
  const selection = window.getSelection();
  return { ok: true, text: selection.toString(), collapsed: selection.isCollapsed };
}

/// `selection_clear`.
export function clearSelectionInPage(input) {
  const token = input.token;
  const root = document.documentElement;
  if (root.getAttribute("data-md-viewer-doc") !== token) {
    return { error: "DOCUMENT_MISMATCH", expected: token, actual: root.getAttribute("data-md-viewer-doc") };
  }
  window.getSelection().removeAllRanges();
  return { ok: true };
}

/// `word_select`. Resolves one caret point, then expands to word boundaries via
/// `Intl.Segmenter` (word granularity) over the containing text node, falling
/// back to a Unicode word-character scan if `Intl.Segmenter` is unavailable in
/// the bundled Chromium.
export function wordSelectInPage(input) {
  const token = input.token;
  const root = document.documentElement;
  if (root.getAttribute("data-md-viewer-doc") !== token) {
    return { error: "DOCUMENT_MISMATCH", expected: token, actual: root.getAttribute("data-md-viewer-doc") };
  }

  // Duplicated from resolveSelectionInPage's own nested copy -- see that
  // function's comment for why this cannot be a shared top-level helper.
  function resolveSelectionPoint(x, y, cellWidthPx, strategy) {
    if (!(x >= 0 && y >= 0 && x < window.innerWidth && y < window.innerHeight)) return null;
    const cellWidth = cellWidthPx > 0 ? cellWidthPx : 0;
    const offsets = cellWidth > 0 ? [0, 0.25, -0.25, 0.45, -0.45].map((f) => f * cellWidth) : [0];

    let element = null;
    let block = null;
    let pointX = x;
    for (const dx of offsets) {
      const px = x + dx;
      if (!(px >= 0 && px < window.innerWidth)) continue;
      const candidate = document.elementFromPoint(px, y);
      if (!candidate) continue;
      const candidateBlock = candidate.closest("[data-source-start][data-source-end]");
      if (!candidateBlock) continue;
      element = candidate;
      block = candidateBlock;
      pointX = px;
      break;
    }
    if (!block) return null;

    let caretNode = null;
    let caretOffset = null;
    const wantPosition = strategy === "auto" || strategy === "caret-position";
    const wantRange = strategy === "auto" || strategy === "caret-range";
    if (wantPosition && typeof document.caretPositionFromPoint === "function") {
      const position = document.caretPositionFromPoint(pointX, y);
      if (position && position.offsetNode) {
        caretNode = position.offsetNode;
        caretOffset = position.offset;
      }
    }
    if (caretNode === null && wantRange && typeof document.caretRangeFromPoint === "function") {
      const range = document.caretRangeFromPoint(pointX, y);
      if (range && range.startContainer) {
        caretNode = range.startContainer;
        caretOffset = range.startOffset;
      }
    }
    if (caretNode !== null && !block.contains(caretNode)) {
      caretNode = null;
      caretOffset = null;
    }

    if (caretNode === null) {
      const rect = element.getBoundingClientRect();
      const preferEnd = pointX >= rect.left + rect.width / 2;
      const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
      let first = null;
      let last = null;
      let node = walker.nextNode();
      while (node !== null) {
        if (node.nodeValue.length > 0) {
          if (first === null) first = node;
          last = node;
        }
        node = walker.nextNode();
      }
      if (preferEnd && last !== null) {
        caretNode = last;
        caretOffset = last.nodeValue.length;
      } else if (first !== null) {
        caretNode = first;
        caretOffset = 0;
      } else {
        caretNode = block;
        caretOffset = 0;
      }
    }

    let runElement = null;
    const caretElement = caretNode.nodeType === 3 ? caretNode.parentElement : caretNode;
    runElement = caretElement === null ? null : caretElement.closest("[data-md-source-id]");
    const elementRun = element.closest("[data-md-source-id]");
    if (elementRun !== null && (runElement === null || runElement.contains(elementRun))) runElement = elementRun;
    if (runElement !== null && !block.contains(runElement)) runElement = null;

    let runOffset = null;
    let runLength = null;
    if (runElement !== null) {
      runLength = (runElement.textContent || "").length;
      if (caretNode.nodeType === 3 && runElement.contains(caretNode)) {
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

    return {
      node: caretNode,
      offset: caretOffset,
      block: {
        sourceStart: Number(block.getAttribute("data-source-start")),
        sourceEnd: Number(block.getAttribute("data-source-end")),
        sourceId: block.getAttribute("data-md-source-id"),
        tagName: block.tagName,
      },
      inline: runElement === null ? null : {
        sourceId: runElement.getAttribute("data-md-source-id"),
        offset: runOffset,
        textLength: runLength,
      },
    };
  }

  // Duplicated from resolveSelectionInPage's own nested copy.
  function applySelectionRange(selection, anchorNode, anchorOffset, focusNode, focusOffset) {
    if (typeof selection.setBaseAndExtent === "function") {
      selection.setBaseAndExtent(anchorNode, anchorOffset, focusNode, focusOffset);
      return;
    }
    let focusFirst = false;
    if (anchorNode === focusNode) {
      focusFirst = focusOffset < anchorOffset;
    } else {
      const relation = anchorNode.compareDocumentPosition(focusNode);
      focusFirst = (relation & Node.DOCUMENT_POSITION_PRECEDING) !== 0;
    }
    const range = document.createRange();
    if (focusFirst) {
      range.setStart(focusNode, focusOffset);
      range.setEnd(anchorNode, anchorOffset);
    } else {
      range.setStart(anchorNode, anchorOffset);
      range.setEnd(focusNode, focusOffset);
    }
    selection.removeAllRanges();
    selection.addRange(range);
  }

  const point = resolveSelectionPoint(input.x, input.y, input.cellWidthPx, input.strategy);
  if (!point || point.node.nodeType !== 3) return { ok: false, reason: "no_word" };

  const caretNode = point.node;
  const text = caretNode.nodeValue;
  const caretOffset = Math.max(0, Math.min(point.offset, text.length));
  let start = caretOffset;
  let end = caretOffset;

  if (typeof Intl !== "undefined" && typeof Intl.Segmenter === "function") {
    const segmenter = new Intl.Segmenter(undefined, { granularity: "word" });
    for (const segment of segmenter.segment(text)) {
      const segStart = segment.index;
      const segEnd = segStart + segment.segment.length;
      const inside = caretOffset >= segStart && caretOffset < segEnd;
      const atEnd = caretOffset === segEnd && segEnd === text.length;
      if ((inside || atEnd) && segment.isWordLike) {
        start = segStart;
        end = segEnd;
        break;
      }
      if (inside || atEnd) break; // landed on non-word text (whitespace, punctuation): no word here
    }
  } else {
    const isWordChar = (ch) => typeof ch === "string" && /[\p{L}\p{N}_]/u.test(ch);
    if (isWordChar(text[caretOffset])) {
      start = caretOffset;
      while (start > 0 && isWordChar(text[start - 1])) start -= 1;
      end = caretOffset;
      while (end < text.length && isWordChar(text[end])) end += 1;
    } else if (caretOffset > 0 && isWordChar(text[caretOffset - 1])) {
      end = caretOffset;
      start = end;
      while (start > 0 && isWordChar(text[start - 1])) start -= 1;
    }
  }
  if (start === end) return { ok: false, reason: "no_word" };

  const selection = window.getSelection();
  applySelectionRange(selection, caretNode, start, caretNode, end);

  let inline = null;
  // caretNode was already validated as inside the resolved block by
  // resolveSelectionPoint, so any data-md-source-id ancestor between it and the
  // block boundary is inside the block too -- no further containment check
  // needed here.
  const runElement = caretNode.parentElement === null ? null : caretNode.parentElement.closest("[data-md-source-id]");
  if (runElement !== null) {
    const walker = document.createTreeWalker(runElement, NodeFilter.SHOW_TEXT);
    let consumed = 0;
    let base = null;
    let node = walker.nextNode();
    while (node !== null) {
      if (node === caretNode) {
        base = consumed;
        break;
      }
      consumed += node.nodeValue.length;
      node = walker.nextNode();
    }
    if (base !== null) {
      inline = {
        sourceId: runElement.getAttribute("data-md-source-id"),
        anchorOffset: base + start,
        focusOffset: base + end,
        textLength: (runElement.textContent || "").length,
      };
    }
  }

  return {
    ok: true,
    text: selection.toString(),
    collapsed: selection.isCollapsed,
    anchor: {
      block: point.block,
      inline: inline ? { sourceId: inline.sourceId, offset: inline.anchorOffset, textLength: inline.textLength } : null,
    },
    focus: {
      block: point.block,
      inline: inline ? { sourceId: inline.sourceId, offset: inline.focusOffset, textLength: inline.textLength } : null,
    },
  };
}

/// `paragraph_select` (triple click). Resolves one caret point the same way
/// `wordSelectInPage` does, then selects the *entire* enclosing block's text
/// (its first through last non-empty text node) instead of expanding to word
/// boundaries -- the browser/VS-Code "triple click selects the paragraph"
/// behaviour.
export function paragraphSelectInPage(input) {
  const token = input.token;
  const root = document.documentElement;
  if (root.getAttribute("data-md-viewer-doc") !== token) {
    return { error: "DOCUMENT_MISMATCH", expected: token, actual: root.getAttribute("data-md-viewer-doc") };
  }

  // Duplicated from resolveSelectionInPage's own nested copy -- see that
  // function's comment for why this cannot be a shared top-level helper.
  function resolveSelectionPoint(x, y, cellWidthPx, strategy) {
    if (!(x >= 0 && y >= 0 && x < window.innerWidth && y < window.innerHeight)) return null;
    const cellWidth = cellWidthPx > 0 ? cellWidthPx : 0;
    const offsets = cellWidth > 0 ? [0, 0.25, -0.25, 0.45, -0.45].map((f) => f * cellWidth) : [0];

    let element = null;
    let block = null;
    let pointX = x;
    for (const dx of offsets) {
      const px = x + dx;
      if (!(px >= 0 && px < window.innerWidth)) continue;
      const candidate = document.elementFromPoint(px, y);
      if (!candidate) continue;
      const candidateBlock = candidate.closest("[data-source-start][data-source-end]");
      if (!candidateBlock) continue;
      element = candidate;
      block = candidateBlock;
      pointX = px;
      break;
    }
    if (!block) return null;
    return { block, element, pointX };
  }

  // Duplicated from resolveSelectionInPage's own nested copy.
  function applySelectionRange(selection, anchorNode, anchorOffset, focusNode, focusOffset) {
    if (typeof selection.setBaseAndExtent === "function") {
      selection.setBaseAndExtent(anchorNode, anchorOffset, focusNode, focusOffset);
      return;
    }
    let focusFirst = false;
    if (anchorNode === focusNode) {
      focusFirst = focusOffset < anchorOffset;
    } else {
      const relation = anchorNode.compareDocumentPosition(focusNode);
      focusFirst = (relation & Node.DOCUMENT_POSITION_PRECEDING) !== 0;
    }
    const range = document.createRange();
    if (focusFirst) {
      range.setStart(focusNode, focusOffset);
      range.setEnd(anchorNode, anchorOffset);
    } else {
      range.setStart(anchorNode, anchorOffset);
      range.setEnd(focusNode, focusOffset);
    }
    selection.removeAllRanges();
    selection.addRange(range);
  }

  // Locates the nearest `[data-md-source-id]` run ancestor for `node` and the
  // text offset of `node`/`offset` within that run's own text content -- the
  // same provenance lookup wordSelectInPage does for its single caret node,
  // generalized here for both the paragraph's first and last text node.
  function resolveInline(node, offset) {
    const runElement = node.parentElement === null ? null : node.parentElement.closest("[data-md-source-id]");
    if (runElement === null) return null;
    const walker = document.createTreeWalker(runElement, NodeFilter.SHOW_TEXT);
    let consumed = 0;
    let found = false;
    let current = walker.nextNode();
    while (current !== null) {
      if (current === node) {
        found = true;
        break;
      }
      consumed += current.nodeValue.length;
      current = walker.nextNode();
    }
    if (!found) return null;
    return {
      sourceId: runElement.getAttribute("data-md-source-id"),
      offset: consumed + offset,
      textLength: (runElement.textContent || "").length,
    };
  }

  const point = resolveSelectionPoint(input.x, input.y, input.cellWidthPx, input.strategy);
  if (!point) return { ok: false, reason: "no_paragraph" };

  const walker = document.createTreeWalker(point.block, NodeFilter.SHOW_TEXT);
  let first = null;
  let last = null;
  let node = walker.nextNode();
  while (node !== null) {
    if (node.nodeValue.length > 0) {
      if (first === null) first = node;
      last = node;
    }
    node = walker.nextNode();
  }
  if (first === null || last === null) return { ok: false, reason: "no_paragraph" };

  const selection = window.getSelection();
  applySelectionRange(selection, first, 0, last, last.nodeValue.length);

  const blockInfo = {
    sourceStart: Number(point.block.getAttribute("data-source-start")),
    sourceEnd: Number(point.block.getAttribute("data-source-end")),
    sourceId: point.block.getAttribute("data-md-source-id"),
    tagName: point.block.tagName,
  };

  return {
    ok: true,
    text: selection.toString(),
    collapsed: selection.isCollapsed,
    anchor: { block: blockInfo, inline: resolveInline(first, 0) },
    focus: { block: blockInfo, inline: resolveInline(last, last.nodeValue.length) },
  };
}

/// `find_set`. Matches `input.query` literally (never as a regular expression,
/// so HTML and regex metacharacters are inert by construction) and wraps each
/// match in a programmatically created `<span data-md-viewer-find-mark>` via
/// `Text.splitText` -- never `innerHTML`, which both would be an injection
/// vector and would destroy the source IDs Part 5's provenance depends on.
///
/// `unwrapFindMarksInPage` is declared inside this function and duplicated
/// again inside `clearFindInPage` below -- see resolveSelectionInPage's
/// comment for why a shared top-level helper cannot work here.
export function setFindInPage(input) {
  const token = input.token;
  const root = document.documentElement;
  if (root.getAttribute("data-md-viewer-doc") !== token) {
    return { error: "DOCUMENT_MISMATCH", expected: token, actual: root.getAttribute("data-md-viewer-doc") };
  }

  function unwrapFindMarksInPage(article) {
    const previous = article.querySelectorAll("[data-md-viewer-find-mark]");
    for (const mark of previous) {
      const parent = mark.parentNode;
      if (!parent) continue;
      while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
      parent.removeChild(mark);
    }
    article.normalize();
  }

  const article = document.querySelector(".markdown-body") || document.body;
  unwrapFindMarksInPage(article);

  const query = typeof input.query === "string" ? input.query : "";
  const needle = query.toLowerCase();
  const maxReported = input.maxReported > 0 ? input.maxReported : 500;
  if (needle === "") return { ok: true, matchCount: 0, activeIndex: null, matches: [] };

  // Snapshotted up front: mutating the DOM (splitText/wrap) while a TreeWalker
  // is mid-traversal would invalidate the walker's own position.
  const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT);
  const textNodes = [];
  let walked = walker.nextNode();
  while (walked !== null) {
    textNodes.push(walked);
    walked = walker.nextNode();
  }

  const marks = [];
  for (const textNode of textNodes) {
    const value = textNode.nodeValue;
    if (!value) continue;
    const lower = value.toLowerCase();
    let cursor = textNode;
    let consumedInOriginal = 0;
    let searchFrom = 0;
    while (true) {
      const at = lower.indexOf(needle, searchFrom);
      if (at < 0) break;
      const localAt = at - consumedInOriginal;
      const matchStart = cursor.splitText(localAt);
      const remainder = matchStart.splitText(needle.length);
      const wrapper = document.createElement("span");
      wrapper.setAttribute("data-md-viewer-find-mark", "");
      matchStart.parentNode.insertBefore(wrapper, matchStart);
      wrapper.appendChild(matchStart);
      marks.push(wrapper);
      cursor = remainder;
      consumedInOriginal = at + needle.length;
      searchFrom = at + needle.length;
    }
  }

  const matches = [];
  for (let index = 0; index < marks.length; index += 1) {
    if (index >= maxReported) {
      matches.push(null);
      continue;
    }
    const wrapper = marks[index];
    const runElement = wrapper.closest("[data-md-source-id]");
    let inline = null;
    if (runElement !== null) {
      const runWalker = document.createTreeWalker(runElement, NodeFilter.SHOW_TEXT);
      let consumed = 0;
      let found = null;
      let node = runWalker.nextNode();
      while (node !== null) {
        if (wrapper.contains(node)) {
          found = consumed;
          break;
        }
        consumed += node.nodeValue.length;
        node = runWalker.nextNode();
      }
      if (found !== null) {
        inline = { sourceId: runElement.getAttribute("data-md-source-id"), offset: found, textLength: (runElement.textContent || "").length };
      }
    }
    matches.push(inline);
  }

  if (marks.length > 0) {
    marks[0].setAttribute("data-active", "");
    marks[0].scrollIntoView({ block: "center" });
  }

  // scrollIntoView mutates the page's own scroll position; report it back so
  // the caller's stale pre-scroll value (from ensureDocumentActive, computed
  // before this function ran) is not what gets returned to Lua.
  return { ok: true, matchCount: marks.length, activeIndex: marks.length > 0 ? 0 : null, matches, scrollY: window.scrollY };
}

/// `find_next` / `find_previous`. Moves the `data-active` marker with
/// wraparound; the match set itself was already built by `find_set` and is not
/// recomputed here.
export function stepFindInPage(input) {
  const token = input.token;
  const root = document.documentElement;
  if (root.getAttribute("data-md-viewer-doc") !== token) {
    return { error: "DOCUMENT_MISMATCH", expected: token, actual: root.getAttribute("data-md-viewer-doc") };
  }
  const matchCount = Number(input.matchCount) || 0;
  if (matchCount <= 0) return { ok: true, activeIndex: null };
  const article = document.querySelector(".markdown-body") || document.body;
  const marks = article.querySelectorAll("[data-md-viewer-find-mark]");
  const current = article.querySelector("[data-md-viewer-find-mark][data-active]");
  if (current) current.removeAttribute("data-active");
  const activeIndex = typeof input.activeIndex === "number" ? input.activeIndex : 0;
  const delta = input.direction === "previous" ? -1 : 1;
  const nextIndex = ((activeIndex + delta) % matchCount + matchCount) % matchCount;
  const next = marks[nextIndex];
  if (next) {
    next.setAttribute("data-active", "");
    next.scrollIntoView({ block: "center" });
  }
  return { ok: true, activeIndex: nextIndex, scrollY: window.scrollY };
}

/// `find_clear`.
export function clearFindInPage(input) {
  const token = input.token;
  const root = document.documentElement;
  if (root.getAttribute("data-md-viewer-doc") !== token) {
    return { error: "DOCUMENT_MISMATCH", expected: token, actual: root.getAttribute("data-md-viewer-doc") };
  }

  function unwrapFindMarksInPage(article) {
    const previous = article.querySelectorAll("[data-md-viewer-find-mark]");
    for (const mark of previous) {
      const parent = mark.parentNode;
      if (!parent) continue;
      while (mark.firstChild) parent.insertBefore(mark.firstChild, mark);
      parent.removeChild(mark);
    }
    article.normalize();
  }

  const article = document.querySelector(".markdown-body") || document.body;
  unwrapFindMarksInPage(article);
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Result shaping for the actions above. Each mirrors buildActionResult's role
// for hit_test/activate_at: turn a raw in-page result into the shape Lua
// consumes, resolving source positions the same way hit-testing already does.
// ---------------------------------------------------------------------------

function resolveEndpoint(endpoint, sourceMap) {
  if (!endpoint) return { line: null, byteColumn: null, precision: "none" };
  return resolveSourcePosition(endpoint.block, endpoint.inline, sourceMap);
}

/// `selection_preview` / `selection_commit` / `word_select`.
export function buildSelectionResult(raw, sourceMap) {
  if (raw.ok === false) {
    return { kind: "selection", ok: false, reason: raw.reason, text: "", collapsed: true };
  }
  return {
    kind: "selection",
    ok: true,
    text: raw.text,
    collapsed: raw.collapsed,
    // Selection geometry (CSS px, viewport-relative) for the drag overlay.
    // Present only from selection_preview/selection_commit; word/paragraph
    // select go through the captured-frame path and report an empty list.
    rects: Array.isArray(raw.rects) ? raw.rects : [],
    rectsTruncated: raw.rectsTruncated === true,
    anchorSourcePosition: resolveEndpoint(raw.anchor, sourceMap),
    focusSourcePosition: resolveEndpoint(raw.focus, sourceMap),
    hit: { anchor: raw.anchor ?? null, focus: raw.focus ?? null },
  };
}

/// `selection_text`.
export function buildSelectionTextResult(raw) {
  return { kind: "selection_text", text: raw.text, collapsed: raw.collapsed };
}

/// `selection_clear`.
export function buildSelectionClearResult() {
  return { kind: "selection", cleared: true };
}

/// `find_set`. Each match's `{sourceId, offset}` resolves through
/// `resolveRegionPosition` -- the same function `resolveSourcePosition` already
/// calls for hit-testing -- so search-match resolution reuses exact provenance
/// rather than duplicating it.
export function buildFindResult(raw, sourceMap, query) {
  const matches = Array.isArray(raw.matches)
    ? raw.matches.map((inline) => (inline ? resolveRegionPosition(sourceMap, inline.sourceId, inline.offset) : null))
    : [];
  const activeIndex = raw.activeIndex ?? null;
  const activeSourcePosition = activeIndex !== null && matches[activeIndex] ? matches[activeIndex] : null;
  return {
    kind: "find",
    query,
    matchCount: raw.matchCount ?? 0,
    activeIndex,
    activeSourcePosition,
    // Internal only: main.js reads this to populate per-document find state for
    // find_next/find_previous, then strips it before the result reaches Lua --
    // a document with thousands of matches must not serialize thousands of
    // source positions to Lua on every keystroke of a search.
    matches,
  };
}

/// `find_next` / `find_previous`. The match set was already resolved by
/// `find_set` and is cached in `findState.matches`; only the active index
/// moved.
export function buildFindStepResult(raw, findState) {
  const matches = Array.isArray(findState?.matches) ? findState.matches : [];
  const activeIndex = raw.activeIndex ?? null;
  const activeSourcePosition = activeIndex !== null && matches[activeIndex] ? matches[activeIndex] : null;
  return {
    kind: "find",
    query: findState?.query ?? null,
    matchCount: findState?.matchCount ?? 0,
    activeIndex,
    activeSourcePosition,
    matches,
  };
}

/// `find_clear`.
export function buildFindClearResult() {
  return { kind: "find", cleared: true };
}
