// The `interact` method: typed actions over the shared hidden page.
//
// Everything here is either pure (envelope validation, link classification,
// source resolution) or a self-contained function serialized into the page by
// `page.evaluate`. Nothing in this module touches the page directly -- that is
// browser.js's job, and only after ensureDocumentActive() has established which
// document is loaded.

import { resolveRegionPosition } from "./provenance.js";
import { OBSIDIAN_SCHEME } from "./obsidian.js";

export const CARET_STRATEGIES = Object.freeze(["auto", "caret-position", "caret-range", "element-only"]);

// `mutatesVisibleState` is the one-round-trip rule: an action that changes what
// the user sees must produce its screenshot inside the same queued operation, so
// Lua never has to issue a follow-up capture. `requiresAnchor` marks the two selection
// actions that need a second point (the anchor's fixed start) alongside
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
  // Read-only, and that is structural rather than incidental: a caret motion
  // happens *while* a visual selection is up, so it must not disturb the DOM
  // selection -- which rules out `Selection.modify`, the obvious primitive,
  // since it can only move a caret by moving the selection's own focus.
  caret_move: Object.freeze({ mutatesVisibleState: false, requiresCoordinates: true }),
  find_set: Object.freeze({ mutatesVisibleState: true, requiresCoordinates: false, requiresQuery: true }),
  find_next: Object.freeze({ mutatesVisibleState: true, requiresCoordinates: false }),
  find_previous: Object.freeze({ mutatesVisibleState: true, requiresCoordinates: false }),
  find_clear: Object.freeze({ mutatesVisibleState: true, requiresCoordinates: false }),
  obsidian_scroll: Object.freeze({ mutatesVisibleState: false, requiresCoordinates: false, requiresObsidianAnchor: true }),
});

// Kept empty rather than removed: it is what keeps validateEnvelope's
// reserved-vs-unknown branch structurally meaningful for whatever a later part
// reserves next, and a caller mid-upgrade against an old build still gets an
// honest "not implemented yet" instead of "unknown method".
export const RESERVED_ACTIONS = Object.freeze([]);

export const TEXT_PREVIEW_LIMIT = 120;

// The selection background each theme's ::selection rule paints, as one
// straight-alpha src-over constant. This is the single value the browser's
// settle frame and the Lua-drawn selection overlay must share: if they disagree,
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
// The caret's own tint, drawn through the same overlay path as a selection but
// deliberately heavier: a selection is a wash over a span the reader is already
// looking at, whereas a caret is a single glyph they have to *find*. At the
// selection's own alpha a one-character block is easy to lose on a busy line.
export const CARET_TINT = Object.freeze({
  dark: Object.freeze({ r: 230, g: 230, b: 230, a: 0.62 }),
  light: Object.freeze({ r: 90, g: 90, b: 90, a: 0.55 }),
});

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

/// Classify a link for the Lua side's dispatch table. Metadata only -- the
/// renderer never follows a link, and the hidden page never navigates away
/// from the generated document.
///
/// The sanitizer already restricts `a` schemes to http/https/mailto, so most of
/// this is defence in depth against a future change to that allowlist.
export function classifyLink(href) {
  if (typeof href !== "string") return { href: "", type: "unsafe" };
  const trimmed = href.trim();
  if (trimmed === "") return { href: "", type: "unsafe" };
  if (trimmed.startsWith("#")) return { href: trimmed, type: "fragment" };
  if (trimmed.startsWith(OBSIDIAN_SCHEME)) {
    try {
      const parsed = JSON.parse(decodeURIComponent(trimmed.slice(OBSIDIAN_SCHEME.length)));
      const validTarget = parsed && typeof parsed.target === "string";
      const validBlock = parsed?.anchor?.kind === "block"
        && typeof parsed.anchor.value === "string"
        && /^[A-Za-z0-9-]+$/u.test(parsed.anchor.value);
      const validHeading = parsed?.anchor?.kind === "heading"
        && Array.isArray(parsed.anchor.segments)
        && parsed.anchor.segments.length > 0
        && parsed.anchor.segments.every((part) => typeof part === "string" && part !== "");
      if (validTarget && (parsed.anchor === null || validBlock || validHeading)) {
        return { href: trimmed, type: "obsidian", target: parsed.target, anchor: parsed.anchor };
      }
    } catch {
      // Invalid renderer-owned metadata is unsafe, exactly like an unknown
      // scheme. It is never treated as a local path.
    }
    return { href: trimmed, type: "unsafe" };
  }
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
      // `lua/md-viewer/security.lua` decides whether it is inside the
      // configured document root; that is the only place that knows the root.
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
/// what a document rendered without a source map, or one whose markup was
/// supplied directly, produces -- this degrades to block-level precision.
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
/// requirement in service.js.
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

  // The anchor's fixed start point, alongside `coordinates` as the moving/focus
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

  // Prefer the live DOM anchor over re-resolving `anchorCoordinates` -- see
  // resolveSelectionInPage. Set by any caller whose page has scrolled since the
  // anchor was placed, which is the only case where the two disagree. Defaults
  // false, so a caller that never scrolls mid-selection sends and behaves
  // exactly as it did before this existed.
  const anchorPinned = envelope.anchorPinned === true;

  // `caretIndex`'s counterpart for a selection endpoint: which character the
  // caller already knows this point sits on, in the renderer's own character
  // space, rather than a point resolveSelectionInPage would have to hit-test
  // again. Exists for the identical reason caretIndex does -- a selection
  // anchor or focus placed at a glyph's own centre (interaction.lua's
  // `visual_start`/`visual_update`) asks caretRangeFromPoint to break a tie at
  // the exact midpoint between two characters, and the answer depends on
  // rounding that differs glyph to glyph: on the glyphs that round toward the
  // next character, a forward `V`/`v` selection anchored on a line's first
  // character lost it (measured live, 2026-08-27: "## Changelog" selected as
  // "hangelog"), and a selection extended to a line's last character lost
  // that one the same way. Optional, and deliberately: a fresh click's anchor
  // and a selection with nothing live to reuse an index from resolve from
  // coordinates the way they always did.
  let anchorIndex = null;
  let focusIndex = null;
  if (action.requiresAnchor) {
    if (envelope.anchorIndex !== undefined && envelope.anchorIndex !== null) {
      if (!Number.isInteger(envelope.anchorIndex) || envelope.anchorIndex < 0) {
        throw createInteractError("INVALID_INTERACTION", `${envelope.action} anchorIndex must be a non-negative integer`);
      }
      anchorIndex = envelope.anchorIndex;
    }
    if (envelope.focusIndex !== undefined && envelope.focusIndex !== null) {
      if (!Number.isInteger(envelope.focusIndex) || envelope.focusIndex < 0) {
        throw createInteractError("INVALID_INTERACTION", `${envelope.action} focusIndex must be a non-negative integer`);
      }
      focusIndex = envelope.focusIndex;
    }
  }

  // `caret_move`'s two axes. Validated here rather than in the page so an
  // unknown granularity is an honest INVALID_INTERACTION instead of a caret
  // that silently declines to move.
  // "none" is the snap-only case: resolve the given point onto the nearest
  // character the caret may occupy and report where that is. It is how a click,
  // and the caret's own first placement, find a legal position.
  const CARET_GRANULARITIES = [
    "none",
    "character",
    "line",
    "lineboundary",
    "word",
    "word_end",
    "block",
    "document",
  ];
  let granularity = null;
  let direction = null;
  let motionCount = 1;
  let desiredX = null;
  let caretIndex = null;
  if (envelope.action === "caret_move") {
    granularity = envelope.granularity ?? "character";
    if (!CARET_GRANULARITIES.includes(granularity)) {
      throw createInteractError(
        "INVALID_INTERACTION",
        `unknown caret granularity: ${granularity}; expected one of ${CARET_GRANULARITIES.join(", ")}`
      );
    }
    direction = envelope.direction === "backward" ? "backward" : "forward";
    motionCount = envelope.count === undefined ? 1 : Number(envelope.count);
    if (!Number.isInteger(motionCount) || motionCount < 1) {
      throw createInteractError("INVALID_INTERACTION", "caret_move count must be a positive integer");
    }
    // The sticky column a line motion aims at -- Vim's `curswant`. Owned by the
    // caller, which is what makes a run of `j` and the matching run of `k`
    // retrace the same characters instead of drifting apart.
    if (envelope.desiredX !== undefined && envelope.desiredX !== null) {
      desiredX = requireFiniteNumber(envelope.desiredX, "desiredX");
    }
    // Where the caret already is, as an index into the renderer's own character
    // space rather than a point to hit-test again -- see moveCaretInPage for
    // why a point is not good enough. Optional, and deliberately: a click and
    // the caret's first placement have no index to send, and resolve from their
    // coordinates the way everything did before this existed.
    if (envelope.caretIndex !== undefined && envelope.caretIndex !== null) {
      if (!Number.isInteger(envelope.caretIndex) || envelope.caretIndex < 0) {
        throw createInteractError("INVALID_INTERACTION", "caret_move caretIndex must be a non-negative integer");
      }
      caretIndex = envelope.caretIndex;
    }
  }

  // Matched literally, never as a regular expression -- see setFindInPage.
  let query = null;
  if (action.requiresQuery) {
    if (typeof envelope.query !== "string" || envelope.query.trim() === "") {
      throw createInteractError("INVALID_INTERACTION", `interact action ${envelope.action} requires a non-empty query`);
    }
    query = envelope.query.trim();
  }

  let obsidianAnchor = null;
  if (action.requiresObsidianAnchor) {
    const value = envelope.obsidianAnchor;
    const validBlock = value?.kind === "block"
      && typeof value.value === "string"
      && /^[A-Za-z0-9-]+$/u.test(value.value);
    const validHeading = value?.kind === "heading"
      && Array.isArray(value.segments)
      && value.segments.length > 0
      && value.segments.every((part) => typeof part === "string" && part.trim() !== "");
    if (!validBlock && !validHeading) {
      throw createInteractError(
        "INVALID_INTERACTION",
        "obsidian_scroll requires a block id or non-empty heading path"
      );
    }
    obsidianAnchor = validBlock
      ? { kind: "block", value: value.value }
      : { kind: "heading", segments: value.segments.map((part) => part.trim()) };
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
  // every selection frame. Dimensions are device pixels (the base image's own).
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
    anchorPinned,
    anchorIndex,
    focusIndex,
    granularity,
    direction,
    motionCount,
    desiredX,
    caretIndex,
    query,
    obsidianAnchor,
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
    // for actions that mutate visible state. `capture: false` is the
    // Overlay opt-out: a moving selection-preview frame displays the selection as a
    // Lua-drawn overlay built from this same operation's rect geometry, so no
    // screenshot exists to take. The one-round-trip rule -- Lua never issues a
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

/// Scroll to an Obsidian heading path or exact block id in the active page.
/// Heading paths are resolved as a hierarchy: every later segment must occur
/// below the previous heading and before its section ends.
export function scrollObsidianAnchorInPage(input) {
  const root = document.documentElement;
  if (root.getAttribute("data-md-viewer-doc") !== input.token) {
    return { error: "DOCUMENT_MISMATCH", expected: input.token, actual: root.getAttribute("data-md-viewer-doc") };
  }
  const anchor = input.anchor;
  let target = null;
  if (anchor.kind === "block") {
    target = [...document.querySelectorAll("[data-md-obsidian-block-id]")]
      .find((element) => element.getAttribute("data-md-obsidian-block-id") === anchor.value) ?? null;
  } else {
    const headings = [...document.querySelectorAll("h1,h2,h3,h4,h5,h6")];
    const wanted = anchor.segments.map((part) => part.trim().toLowerCase());
    const label = (element) => (element.textContent || "").trim().toLowerCase();
    const level = (element) => Number(element.tagName.slice(1));
    for (let start = 0; start < headings.length && target === null; start += 1) {
      if (label(headings[start]) !== wanted[0]) continue;
      let current = headings[start];
      let currentIndex = start;
      let matched = true;
      for (let segment = 1; segment < wanted.length; segment += 1) {
        let next = null;
        for (let index = currentIndex + 1; index < headings.length; index += 1) {
          if (level(headings[index]) <= level(current)) break;
          if (label(headings[index]) === wanted[segment]) {
            next = headings[index];
            currentIndex = index;
            break;
          }
        }
        if (!next) {
          matched = false;
          break;
        }
        current = next;
      }
      if (matched) target = current;
    }
  }
  if (!target) return { ok: true, found: false, scrollY: window.scrollY };
  target.scrollIntoView({ block: "start" });
  return { ok: true, found: true, scrollY: window.scrollY };
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
  // an earlier version refused: it never reached beyond half a cell, so a click in the
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
    // for diagnostics and tests; selection hit-tests both endpoints
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

/// Turn the raw in-page result into the hit shape Lua consumes. `sourceMap`
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
/// otherwise, so "an unmodified click on a link still navigates to source"
/// needs no second round trip.
export function buildActionResult(action, hit) {
  if (action === "activate_at" && hit.link) {
    return { kind: "link", link: hit.link, sourcePosition: hit.sourcePosition, hit };
  }
  return { kind: "source", sourcePosition: hit.sourcePosition, hit };
}

// ---------------------------------------------------------------------------
// Selection and search.
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
/// function rather than as siblings: `page.evaluate(fn, arg)` serializes only
/// `fn.toString()` and runs it standalone in the page, with no access to
/// sibling module-scope functions -- a top-level helper here would be a
/// ReferenceError at evaluation time, not a lint warning.
export function resolveSelectionInPage(input) {
  const token = input.token;
  const root = document.documentElement;
  if (root.getAttribute("data-md-viewer-doc") !== token) {
    return { error: "DOCUMENT_MISMATCH", expected: token, actual: root.getAttribute("data-md-viewer-doc") };
  }

  // moveCaretInPage's character-space, duplicated rather than shared -- see
  // this function's own comment for why a page.evaluate body cannot call a
  // sibling. Built only when an index was actually sent: every caller with
  // nothing live to reuse an index from (a fresh click, a selection with no
  // caret history) still resolves from a point exactly as before, and this
  // walk costs nothing on that path.
  let indexedNodes = null;
  let indexedStarts = null;
  let indexedText = "";
  function buildCharacterSpace() {
    if (indexedNodes !== null) return;
    indexedNodes = [];
    indexedStarts = [];
    const blocks = document.querySelectorAll("[data-source-start][data-source-end]");
    const seen = new Set();
    let previousInner = null;
    for (const block of blocks) {
      const rect = block.getBoundingClientRect();
      if (!(rect.width > 0 && rect.height > 0)) continue;
      const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
      let node = walker.nextNode();
      while (node !== null) {
        if (node.nodeValue.length > 0 && !seen.has(node)) {
          seen.add(node);
          const inner = node.parentElement && node.parentElement.closest("[data-source-start][data-source-end]");
          if (indexedText.length > 0 && inner !== previousInner) indexedText += "\n";
          previousInner = inner;
          indexedNodes.push(node);
          indexedStarts.push(indexedText.length);
          indexedText += node.nodeValue;
        }
        node = walker.nextNode();
      }
    }
  }
  // Resolve a flat character index to a (node, offset) Range boundary --
  // the counterpart to resolveSelectionPoint below, but exact rather than
  // hit-tested, because the caller already knows which character this is
  // (its own last caret_move answer, or the character `visual_start`
  // anchored on) and only needs the DOM position back, not a fresh guess at
  // one from a pixel. `boundary` picks which side of that character the
  // Range lands on -- "start" (before it) or "end" (after it, still the
  // same character, never the next one) -- so the caller can guarantee this
  // character survives being an endpoint regardless of which direction the
  // other endpoint sits in.
  function resolveIndex(flat, boundary) {
    if (!Number.isInteger(flat) || flat < 0) return null;
    buildCharacterSpace();
    if (flat >= indexedText.length) return null;
    let low = 0;
    let high = indexedNodes.length - 1;
    let nodeIndex = 0;
    while (low <= high) {
      const mid = (low + high) >> 1;
      if (indexedStarts[mid] <= flat) {
        nodeIndex = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    const node = indexedNodes[nodeIndex];
    const charOffset = flat - indexedStarts[nodeIndex];
    if (charOffset >= node.nodeValue.length) return null;
    // "end" is one past this character's own start, inside the same text
    // node -- a single indexed character is one UTF-16 code unit of one
    // node's value, never split across two, so charOffset + 1 always stays
    // in bounds here (the length check above already proved a character
    // exists at charOffset).
    const offset = boundary === "end" ? charOffset + 1 : charOffset;
    const element = node.parentElement;
    if (element === null) return null;
    const block = element.closest("[data-source-start][data-source-end]");
    if (block === null) return null;
    let runElement = element.closest("[data-md-source-id]");
    if (runElement !== null && !block.contains(runElement)) runElement = null;
    let runOffset = null;
    let runLength = null;
    if (runElement !== null) {
      runLength = (runElement.textContent || "").length;
      const runWalker = document.createTreeWalker(runElement, NodeFilter.SHOW_TEXT);
      let consumed = 0;
      let current = runWalker.nextNode();
      while (current !== null) {
        if (current === node) {
          runOffset = consumed + offset;
          break;
        }
        consumed += current.nodeValue.length;
        current = runWalker.nextNode();
      }
    }
    return {
      node,
      offset,
      block: {
        sourceStart: Number(block.getAttribute("data-source-start")),
        sourceEnd: Number(block.getAttribute("data-source-end")),
        sourceId: block.getAttribute("data-md-source-id"),
        tagName: block.tagName,
      },
      inline: runElement === null ? null : { sourceId: runElement.getAttribute("data-md-source-id"), offset: runOffset, textLength: runLength },
    };
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
    // This is what makes an endpoint that lands with no block under it resolve
    // to real content instead of the request being dropped. The one production
    // caller today is `V` (linewise visual selection): `interaction.visual_start`
    // anchors it at x=0, the page's own left edge, and sends that raw margin
    // point with no clamping of its own -- this function is the only thing that
    // turns it into an addressable position. It matters far more than "the odd
    // point in the margin" suggests: the page carries 26px of side padding
    // (renderer/assets/preview.css) while a terminal cell is ~10-20 CSS px, so
    // the leftmost one or two columns of the preview hold no block, `probe`
    // above found nothing, and a raw margin point would come back `focus_miss`
    // and be silently dropped by interaction.lua's `result.ok ~= false` check.
    // That is measured against a real Chromium, not reasoned: focus x=10.26 on
    // an 800px viewport returned focus_miss while x=20 did not.
    //
    // Vertical distance dominates the ranking, and heavily: an anchor level
    // with the third paragraph but out in the left margin must stay on the
    // third paragraph, not jump to whichever block happens to be nearer in raw
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
  // paints a reverse (right-to-left or bottom-to-top) selection correctly
  // regardless of which endpoint is passed first, which is what makes
  // extending a selection backward work without any extra logic here. The
  // Range fallback is
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

  // Describe an existing DOM (node, offset) pair the same way
  // resolveSelectionPoint describes one it has just resolved from a
  // coordinate. Only the pinned-anchor path below uses it: that path already
  // holds a live anchor node and has no coordinate left worth resolving.
  function describeNode(node, offset) {
    if (node === null || node === undefined) return null;
    const element = node.nodeType === 3 ? node.parentElement : node;
    if (element === null) return null;
    const block = element.closest("[data-source-start][data-source-end]");
    if (block === null) return null;
    let runElement = element.closest("[data-md-source-id]");
    if (runElement !== null && !block.contains(runElement)) runElement = null;
    let runOffset = null;
    let runLength = null;
    if (runElement !== null) {
      runLength = (runElement.textContent || "").length;
      if (node.nodeType === 3 && runElement.contains(node)) {
        const walker = document.createTreeWalker(runElement, NodeFilter.SHOW_TEXT);
        let consumed = 0;
        let current = walker.nextNode();
        while (current !== null) {
          if (current === node) {
            runOffset = consumed + offset;
            break;
          }
          consumed += current.nodeValue.length;
          current = walker.nextNode();
        }
      }
    }
    return {
      node,
      offset,
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

  const selection = window.getSelection();

  // Resolution order, most precise first:
  //
  // 1. Index. Names the exact character the caller already resolved
  //    (visual_start's caret, or a previous frame's own focus answer below)
  //    instead of a coordinate resolveSelectionPoint would have to hit-test
  //    again -- and a coordinate at a glyph's own centre is exactly the
  //    unresolvable tie caret_move's `caretIndex` exists to avoid for the
  //    caret itself; the selection anchor and focus sit on that same tie and
  //    never had an equivalent fix (measured live: "## Changelog" anchored at
  //    `v` selected as "hangelog", 2026-08-27). Checked, not trusted, like
  //    caretIndex: a re-render invalidates it, and resolveIndex reports that
  //    as null rather than a wrong character.
  //
  //    A Range boundary at offset N sits *before* character N, so a selection
  //    must land at an index's own offset to include it as its FIRST
  //    character and at (offset + 1) to include it as its LAST -- whichever
  //    endpoint is earlier in the flat index needs the former, the later
  //    needs the latter, or neither endpoint's own character survives being
  //    anchored to it. Both indices are needed to know which is which; when
  //    only one is available the other endpoint's own resolution (a
  //    coordinate, or the live DOM anchor below) already stands on its own,
  //    so this one gets the plain start offset resolveIndex returns by
  //    default -- exactly how it resolved before either index existed.
  //
  // 2. The live DOM anchor, when the page has scrolled since the anchor
  //    coordinate was measured: the anchor's viewport y shifts with every
  //    scrolled pixel, and once it leaves the viewport entirely
  //    resolveSelectionPoint refuses it outright (its first line
  //    bounds-checks against innerHeight), so the whole frame would return
  //    anchor_miss and interaction.lua's `result.ok ~= false` check would
  //    silently drop it -- the highlight freezing at the edge on a keyboard
  //    motion that scrolled the page mid-extension. The live anchor is
  //    precisely the endpoint setBaseAndExtent recorded on the previous
  //    frame, expressed as a node rather than a pixel, so scrolling cannot
  //    touch it.
  //
  // 3. The coordinate, exactly as before either of the above existed.
  let anchor = null;
  let focus = null;
  const haveBothIndices = Number.isInteger(input.anchorIndex) && Number.isInteger(input.focusIndex);
  if (haveBothIndices) {
    const anchorFirst = input.anchorIndex <= input.focusIndex;
    anchor = resolveIndex(input.anchorIndex, anchorFirst ? "start" : "end");
    focus = resolveIndex(input.focusIndex, anchorFirst ? "end" : "start");
  } else if (Number.isInteger(input.anchorIndex)) {
    anchor = resolveIndex(input.anchorIndex, "start");
  }
  if (!anchor && input.anchorPinned === true && selection.anchorNode !== null) {
    anchor = describeNode(selection.anchorNode, selection.anchorOffset);
  }
  if (!anchor) anchor = resolveSelectionPoint(input.anchor.x, input.anchor.y, input.cellWidthPx, input.strategy);
  if (!anchor) return { ok: false, reason: "anchor_miss" };
  if (!focus && !haveBothIndices && Number.isInteger(input.focusIndex)) {
    focus = resolveIndex(input.focusIndex, "start");
  }
  if (!focus) focus = resolveSelectionPoint(input.focus.x, input.focus.y, input.cellWidthPx, input.strategy);
  if (!focus) return { ok: false, reason: "focus_miss" };

  applySelectionRange(selection, anchor.node, anchor.offset, focus.node, focus.offset);

  // Selection geometry for the selection overlay: viewport-relative CSS
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

/// `caret_move`. The preview's caret, resolved entirely against the rendered
/// document: it reports the **rectangle of the character it sits on**, which is
/// what lets Lua draw a caret shaped like the glyph under it rather than a
/// fixed terminal cell floating in whitespace.
///
/// Two rules follow from that and drive everything below:
///
///   1. A caret position is always a real character. There is no such thing as
///      a caret in the page's margin or in the blank space beside a heading --
///      those are positions the reader cannot be at, so motions skip them and
///      `granularity: "none"` snaps an arbitrary point onto the nearest one.
///   2. Zero-width boxes are not characters. Collapsed inter-element
///      whitespace measures zero wide and would render as an invisible caret,
///      so it is skipped the same way the margin is.
///
/// Read-only, deliberately. `Selection.modify` is the primitive this obviously
/// wants and is unusable here: it moves a caret only by moving the DOM
/// selection's own focus, and a caret motion in preview visual mode happens
/// while a selection is up -- it would destroy the selection it is meant to
/// extend. Everything below builds throwaway Ranges and never touches
/// `window.getSelection()`.
export function moveCaretInPage(input) {
  const token = input.token;
  const root = document.documentElement;
  if (root.getAttribute("data-md-viewer-doc") !== token) {
    return { error: "DOCUMENT_MISMATCH", expected: token, actual: root.getAttribute("data-md-viewer-doc") };
  }

  // Every character of the document that a caret may occupy, in document
  // order: the text nodes inside source-mapped blocks, flattened into one
  // index space. Built per request rather than cached -- a preview document is
  // a README, not a corpus, and a stale cache across a re-render would put the
  // caret on text that no longer exists.
  const nodes = [];
  const starts = [];
  const blockOf = [];
  let text = "";
  {
    const blocks = document.querySelectorAll("[data-source-start][data-source-end]");
    const seen = new Set();
    let previousInner = null;
    for (const block of blocks) {
      const rect = block.getBoundingClientRect();
      if (!(rect.width > 0 && rect.height > 0)) continue;
      const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
      let node = walker.nextNode();
      while (node !== null) {
        // A nested block (a list item inside a list) is walked by both; the
        // first, outermost pass is the one that counts, so document order is
        // preserved and no character is indexed twice.
        if (node.nodeValue.length > 0 && !seen.has(node)) {
          seen.add(node);
          // A word boundary where the rendering has one. The whitespace between
          // two blocks lives in their container, not inside either of them, so
          // it is never walked -- and without a separator `Intl.Segmenter` reads
          // the end of one block and the start of the next as a single word
          // ("Vault" + "Private" -> "VaultPrivate"), which makes `w` jump clean
          // over the second one. The separator belongs to no node, so `rectOf`
          // reports it as null and every rect-driven motion skips it exactly the
          // way it skips collapsed whitespace.
          //
          // Keyed on the *innermost* source block, not on `blockOf` above, which
          // holds the outermost: every <li> in one list shares that, and list
          // items are where the joined words are worst. Text nodes within one
          // block are never separated -- <strong>bold</strong>face renders as one
          // word and has to stay one.
          const inner = node.parentElement && node.parentElement.closest("[data-source-start][data-source-end]");
          if (text.length > 0 && inner !== previousInner) text += "\n";
          previousInner = inner;
          nodes.push(node);
          starts.push(text.length);
          blockOf.push(block);
          text += node.nodeValue;
        }
        node = walker.nextNode();
      }
    }
  }
  if (text.length === 0) return { ok: false, reason: "no_content" };

  function nodeIndexOf(flat) {
    let low = 0;
    let high = nodes.length - 1;
    let found = 0;
    while (low <= high) {
      const mid = (low + high) >> 1;
      if (starts[mid] <= flat) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found;
  }

  // The box of the character at `flat`. Null when it has none -- a collapsed
  // whitespace run between elements, which is exactly what must never hold a
  // caret.
  const range = document.createRange();
  function rectOf(flat) {
    if (flat < 0 || flat >= text.length) return null;
    const index = nodeIndexOf(flat);
    const node = nodes[index];
    const offset = flat - starts[index];
    if (offset >= node.nodeValue.length) return null;
    range.setStart(node, offset);
    range.setEnd(node, offset + 1);
    const rect = range.getBoundingClientRect();
    if (!(rect.width > 0 && rect.height > 0)) return null;
    return rect;
  }

  // The nearest occupiable character at or after `flat` in `step` direction.
  function settle(flat, step) {
    let cursor = flat;
    while (cursor >= 0 && cursor < text.length) {
      if (rectOf(cursor) !== null) return cursor;
      cursor += step;
    }
    // Ran off that end: come back the other way rather than report failure, so
    // a motion to the very start or end of the document always lands.
    cursor = Math.max(0, Math.min(text.length - 1, flat));
    while (cursor >= 0 && cursor < text.length) {
      if (rectOf(cursor) !== null) return cursor;
      cursor -= step;
    }
    return null;
  }

  // Where the incoming point sits in that index space. `caretPositionFromPoint`
  // answers with a DOM position; mapping it back through the flat index is what
  // makes a click and a keyboard motion land on the same character.
  function flatFromPoint(x, y, cellWidthPx) {
    if (!(x >= 0 && y >= 0 && x < window.innerWidth && y < window.innerHeight)) return null;
    const cellWidth = cellWidthPx > 0 ? cellWidthPx : 0;
    const offsets = cellWidth > 0 ? [0, 0.25, -0.25, 0.45, -0.45].map((f) => f * cellWidth) : [0];
    for (const dx of offsets) {
      const px = x + dx;
      if (!(px >= 0 && px < window.innerWidth)) continue;
      let position = null;
      if (typeof document.caretPositionFromPoint === "function") {
        const found = document.caretPositionFromPoint(px, y);
        if (found && found.offsetNode) position = { node: found.offsetNode, offset: found.offset };
      }
      if (position === null && typeof document.caretRangeFromPoint === "function") {
        const found = document.caretRangeFromPoint(px, y);
        if (found && found.startContainer) position = { node: found.startContainer, offset: found.startOffset };
      }
      if (position === null) continue;
      const index = nodes.indexOf(position.node);
      if (index < 0) continue;
      return starts[index] + Math.min(position.offset, nodes[index].nodeValue.length - 1);
    }
    return null;
  }

  // No caret under the point at all (the margin, the gap beside a heading, the
  // scroll-past-end padding). Fall back to the character whose box is nearest,
  // ranking vertical distance far above horizontal so a point out in the left
  // margin stays on the line it is level with.
  function nearestFlat(x, y) {
    let best = null;
    let bestKey = Infinity;
    for (let index = 0; index < nodes.length; index += 1) {
      const node = nodes[index];
      range.setStart(node, 0);
      range.setEnd(node, node.nodeValue.length);
      const rect = range.getBoundingClientRect();
      if (!(rect.width > 0 && rect.height > 0)) continue;
      const dy = y < rect.top ? rect.top - y : y > rect.bottom ? y - rect.bottom : 0;
      const dx = x < rect.left ? rect.left - x : x > rect.right ? x - rect.right : 0;
      const key = dy * 100000 + dx;
      if (key < bestKey) {
        bestKey = key;
        best = index;
      }
    }
    if (best === null) return null;
    // Within the winning run, the character horizontally closest to the point.
    let winner = starts[best];
    let winnerDistance = Infinity;
    for (let flat = starts[best]; flat < starts[best] + nodes[best].nodeValue.length; flat += 1) {
      const rect = rectOf(flat);
      if (rect === null) continue;
      const distance = Math.abs(rect.left + rect.width / 2 - x) + (y < rect.top || y > rect.bottom ? 100000 : 0);
      if (distance < winnerDistance) {
        winnerDistance = distance;
        winner = flat;
      }
    }
    return settle(winner, 1);
  }

  function wordEdges() {
    const wordStarts = [];
    const wordEnds = [];
    if (typeof Intl !== "undefined" && typeof Intl.Segmenter === "function") {
      const segmenter = new Intl.Segmenter(undefined, { granularity: "word" });
      for (const segment of segmenter.segment(text)) {
        if (!segment.isWordLike) continue;
        wordStarts.push(segment.index);
        wordEnds.push(segment.index + segment.segment.length - 1);
      }
      return { wordStarts, wordEnds };
    }
    // Fallback for engines without Intl.Segmenter.
    const isWordChar = (ch) => typeof ch === "string" && /[\p{L}\p{N}_]/u.test(ch);
    let index = 0;
    while (index < text.length) {
      if (isWordChar(text[index])) {
        const start = index;
        while (index < text.length && isWordChar(text[index])) index += 1;
        wordStarts.push(start);
        wordEnds.push(index - 1);
      } else {
        index += 1;
      }
    }
    return { wordStarts, wordEnds };
  }

  // Two glyph boxes are on the same visual line when they overlap vertically by
  // more than half the smaller one. Comparing `top` alone is not good enough:
  // a line can mix font sizes (inline code inside a paragraph, a link inside a
  // heading), and their tops legitimately differ by several pixels.
  function sameLine(a, b) {
    const overlap = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
    return overlap > Math.min(a.height, b.height) * 0.5;
  }

  // A visual line step. Walked rather than computed: line boxes vary in height
  // across a heading, a paragraph and a code block, so "add a line height"
  // guesses wrong exactly where it matters.
  //
  // The column is matched on the glyph's **left edge**, and against a *sticky*
  // target (`wantedX`, Vim's `curswant`) rather than the current glyph's own
  // edge. Both halves are load-bearing:
  //
  //   - Centres do not survive a font-size change. Stepping off the `P` of a
  //     38px heading, that glyph's centre sits at x≈35.6, while on the 18px
  //     line below it `P` is centred at 31 and `r` at 39 -- so centre-matching
  //     lands on `r`, one character right, every single time.
  //   - Without a sticky target, each step re-derives the column from wherever
  //     the last one landed, so a run of `j` accumulates drift and the matching
  //     run of `k` cannot retrace it. Carrying the original column through the
  //     whole run is what makes down-N-then-up-N return to the character it
  //     started on.
  function lineStep(flat, forward, wantedX) {
    const from = rectOf(flat);
    if (from === null) return null;
    const wanted = typeof wantedX === "number" ? wantedX : from.left;
    const step = forward ? 1 : -1;
    let cursor = flat;
    let landing = null;
    while (true) {
      cursor += step;
      if (cursor < 0 || cursor >= text.length) return null;
      const rect = rectOf(cursor);
      if (rect === null) continue;
      if (!sameLine(rect, from)) {
        landing = rect;
        break;
      }
    }
    // Sweep that line for the character whose left edge is nearest the target
    // column. Ties go to the earlier character, which keeps the sweep's answer
    // independent of the direction it arrived from.
    let best = cursor;
    let bestDistance = Math.abs(landing.left - wanted);
    let probe = cursor;
    while (probe >= 0 && probe < text.length) {
      probe += step;
      if (probe < 0 || probe >= text.length) break;
      const rect = rectOf(probe);
      if (rect === null) continue;
      if (!sameLine(rect, landing)) break;
      const distance = Math.abs(rect.left - wanted);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = probe;
      }
    }
    return best;
  }

  // `h` and `l`: one character, and never off the visual line the caret is on.
  // Vim's `h` and `l` do not leave the line under the default `whichwrap`, and
  // `0`/`$` below already work on the visual line, so all four agree about what
  // a line is. Without the check, holding `l` walks off the right edge of a
  // rendered row and on through every block beneath it, and `h` walks back up
  // the same way.
  //
  // Null-box indices are walked through rather than stopped at, the way `settle`
  // walks them: the inter-block separator and collapsed whitespace are not
  // characters, so they are not somewhere the caret can be *or* a boundary it
  // can be stopped by. The line is what stops it.
  function charStep(flat, forward) {
    const from = rectOf(flat);
    if (from === null) return null;
    const step = forward ? 1 : -1;
    let probe = flat;
    while (true) {
      probe += step;
      if (probe < 0 || probe >= text.length) return null;
      const rect = rectOf(probe);
      if (rect === null) continue;
      return sameLine(rect, from) ? probe : null;
    }
  }

  // `0` and `$`: the first or last character of the caret's own visual line.
  function lineEdge(flat, forward) {
    const from = rectOf(flat);
    if (from === null) return null;
    const step = forward ? 1 : -1;
    let best = flat;
    let probe = flat;
    while (probe >= 0 && probe < text.length) {
      probe += step;
      if (probe < 0 || probe >= text.length) break;
      const rect = rectOf(probe);
      if (rect === null) continue;
      if (!sameLine(rect, from)) break;
      best = probe;
    }
    return best;
  }

  const forward = input.direction !== "backward";
  const count = Math.max(1, input.count || 1);
  const granularity = input.granularity || "character";

  // Where the caret already is, exactly. A motion continuing from the caret
  // sends back the index the last one returned, and that is the whole reason
  // this exists: the alternative -- re-resolving the caret's own glyph centre
  // through `caretPositionFromPoint` -- asks for the nearest *insertion point*,
  // which is a boundary between two characters, and at the exact middle of a
  // glyph the boundaries either side are equidistant. Which one Blink picks
  // comes down to rounding the glyph's advance to a LayoutUnit, so it is stable
  // per glyph and differs from glyph to glyph. On the glyphs that rounded the
  // other way the renderer decided the caret was one character right of where it
  // was drawn: `h` stepped back onto the glyph it started on and the caret never
  // moved again, and `l` skipped one.
  //
  // Checked, not trusted. This index space is rebuilt from the DOM on every
  // request, so an index from before a re-render may name nothing; one that no
  // longer resolves falls back to the point below, which is what a click and the
  // caret's first placement use anyway.
  let flat = null;
  if (Number.isInteger(input.caretIndex) && rectOf(input.caretIndex) !== null) {
    flat = input.caretIndex;
  }
  if (flat === null) {
    flat = flatFromPoint(input.x, input.y, input.cellWidthPx);
    if (flat !== null) flat = settle(flat, 1);
    if (flat === null) flat = nearestFlat(input.x, input.y);
  }
  if (flat === null) return { ok: false, reason: "no_caret" };

  if (granularity === "document") {
    flat = forward ? settle(text.length - 1, -1) : settle(0, 1);
  } else if (granularity !== "none") {
    const edges = granularity === "word" || granularity === "word_end" ? wordEdges() : null;
    for (let step = 0; step < count; step += 1) {
      let target = null;
      if (granularity === "character") {
        target = charStep(flat, forward);
      } else if (granularity === "line") {
        target = lineStep(flat, forward, input.desiredX);
      } else if (granularity === "lineboundary") {
        target = lineEdge(flat, forward);
      } else if (granularity === "block") {
        const block = blockOf[nodeIndexOf(flat)];
        let probe = flat;
        while (probe >= 0 && probe < text.length) {
          probe += forward ? 1 : -1;
          if (probe < 0 || probe >= text.length) break;
          if (blockOf[nodeIndexOf(probe)] !== block) {
            target = settle(probe, forward ? 1 : -1);
            break;
          }
        }
      } else {
        const positions = granularity === "word_end" ? edges.wordEnds : edges.wordStarts;
        if (forward) {
          for (const position of positions) {
            if (position > flat) {
              target = settle(position, 1);
              break;
            }
          }
        } else {
          for (let index = positions.length - 1; index >= 0; index -= 1) {
            if (positions[index] < flat) {
              target = settle(positions[index], -1);
              break;
            }
          }
        }
      }
      if (target === null || target === flat) break;
      flat = target;
    }
  }

  let rect = rectOf(flat);
  if (rect === null) return { ok: false, reason: "no_caret" };

  // Bring the caret into view if the motion ran off the viewport, then
  // re-measure: `browser.js` forwards a `scrollY` from here to Lua the same way
  // it does for a find step.
  let scrolled = null;
  if (rect.top < 0 || rect.bottom > window.innerHeight) {
    const above = rect.top < 0;
    const desired = above
      ? window.scrollY + rect.top - window.innerHeight * 0.25
      : window.scrollY + rect.bottom - window.innerHeight * 0.75;
    const limit = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
    window.scrollTo(0, Math.max(0, Math.min(limit, desired)));
    scrolled = window.scrollY;
    rect = rectOf(flat);
    if (rect === null) return { ok: false, reason: "no_caret" };
  }

  return {
    ok: true,
    index: flat,
    x: rect.left,
    y: rect.top,
    width: rect.width,
    height: rect.height,
    scrollY: scrolled,
  };
}

/// `find_set`. Matches `input.query` literally (never as a regular expression,
/// so HTML and regex metacharacters are inert by construction) and wraps each
/// match in a programmatically created `<span data-md-viewer-find-mark>` via
/// `Text.splitText` -- never `innerHTML`, which both would be an injection
/// vector and would destroy the source IDs exact provenance depends on.
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

  let activeRect = null;
  if (marks.length > 0) {
    marks[0].setAttribute("data-active", "");
    marks[0].scrollIntoView({ block: "center" });
    // Measured after the scroll, in the same viewport CSS pixels
    // moveCaretInPage's own rect uses -- so Lua can place the caret on the
    // match exactly the way it places one from a caret_move response.
    const rect = marks[0].getBoundingClientRect();
    activeRect = { x: rect.left, y: rect.top, width: rect.width, height: rect.height };
  }

  // scrollIntoView mutates the page's own scroll position; report it back so
  // the caller's stale pre-scroll value (from ensureDocumentActive, computed
  // before this function ran) is not what gets returned to Lua.
  return {
    ok: true,
    matchCount: marks.length,
    activeIndex: marks.length > 0 ? 0 : null,
    matches,
    scrollY: window.scrollY,
    activeRect,
  };
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
  let activeRect = null;
  if (next) {
    next.setAttribute("data-active", "");
    next.scrollIntoView({ block: "center" });
    const rect = next.getBoundingClientRect();
    activeRect = { x: rect.left, y: rect.top, width: rect.width, height: rect.height };
  }
  return { ok: true, activeIndex: nextIndex, scrollY: window.scrollY, activeRect };
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

/// `selection_preview` / `selection_commit`.
export function buildSelectionResult(raw, sourceMap) {
  if (raw.ok === false) {
    return { kind: "selection", ok: false, reason: raw.reason, text: "", collapsed: true };
  }
  return {
    kind: "selection",
    ok: true,
    text: raw.text,
    collapsed: raw.collapsed,
    // Selection geometry (CSS px, viewport-relative) for the selection overlay.
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

/// `caret_move`. The **box of the character the caret landed on**, in the same
/// viewport CSS pixels the selection rectangles use -- so Lua can draw a caret
/// shaped like the glyph beneath it through the identical overlay path, rather
/// than leaving the terminal to draw a fixed-size cell wherever it likes.
///
/// `index` is *which* character that is, in the renderer's own character space.
/// The box says how to draw the caret; the index says where it is, and Lua sends
/// it back with the next motion so the caret is never re-derived from its own
/// geometry -- see moveCaretInPage.
export function buildCaretMoveResult(raw) {
  if (!raw || raw.ok !== true) {
    return { kind: "caret", ok: false, reason: (raw && raw.reason) || "no_target" };
  }
  return {
    kind: "caret",
    ok: true,
    index: raw.index,
    rect: { x: raw.x, y: raw.y, width: raw.width, height: raw.height },
  };
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
    // The active match's on-screen box, so Lua can place the caret on it the
    // same way a caret_move response does -- see buildCaretMoveResult.
    activeRect: raw.activeRect ?? null,
    // Internal only: service.js reads this to populate per-document find state for
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
    activeRect: raw.activeRect ?? null,
    matches,
  };
}

/// `find_clear`.
export function buildFindClearResult() {
  return { kind: "find", cleared: true };
}
