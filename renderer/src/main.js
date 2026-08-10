import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { LineProtocol } from "./protocol.js";
import { BrowserRenderer } from "./browser.js";
import { renderMarkdown } from "./markdown.js";
import { normalizeAllowlist } from "./remote-images.js";
import { LANES, createLaneError, createLaneRegistry } from "./lanes.js";
import { validateEnvelope } from "./interact.js";

const directory = path.dirname(fileURLToPath(import.meta.url));
const browser = new BrowserRenderer({ assetsDir: path.resolve(directory, "../assets") });

const MAX_CACHED_DOCUMENTS = 64;
// documentId -> { key, html, sourceMap }. The source map is the trusted-memory
// half of source provenance: the page holds opaque region keys, this holds what
// they mean. It is written and evicted with the markup it describes, so the two
// can never disagree about which render they belong to.
const markdownCache = new Map();
// documentId -> per-document interaction state, held in trusted Node memory
// rather than on the page. setContent destroys page state on every document
// switch; this map survives it, and it is keyed by document so one preview's
// selection can never surface in another's.
const interactionState = new Map();
const lanes = createLaneRegistry({ onEvict: forgetDocument });

let renderQueue = Promise.resolve();
let shuttingDown = false;

// A `capture` may be promoted to the `settle` lane so a settled high-resolution
// frame and an in-flight fast frame do not cancel each other. Nothing else may
// move lanes: allowing an interaction into the content lane would hand it the
// power to cancel renders, which is exactly what this design removes.
const ALLOWED_LANES = {
  render: ["content"],
  capture: ["capture", "settle"],
  interact: ["interact"],
};

function resolveLane(method, requested) {
  const allowed = ALLOWED_LANES[method];
  if (requested === undefined || requested === null) return allowed[0];
  if (!LANES.includes(requested)) {
    throw createLaneError("INVALID_REQUEST", `unknown lane: ${requested}; expected one of ${LANES.join(", ")}`);
  }
  if (!allowed.includes(requested)) {
    throw createLaneError(
      "INVALID_REQUEST",
      `method ${method} may not use the ${requested} lane; allowed: ${allowed.join(", ")}`
    );
  }
  return requested;
}

function forgetDocument(documentId) {
  markdownCache.delete(documentId);
  interactionState.delete(documentId);
  browser.forgetDocument(documentId);
}

function rememberMarkdown(documentId, entry) {
  markdownCache.delete(documentId);
  markdownCache.set(documentId, entry);
  while (markdownCache.size > MAX_CACHED_DOCUMENTS) {
    const oldest = markdownCache.keys().next().value;
    markdownCache.delete(oldest);
    interactionState.delete(oldest);
    browser.forgetDocument(oldest);
  }
}

// Interaction state never crosses a content revision. Applying a selection
// captured against older content to newer content is silent data corruption in
// a copy operation, so the state is replaced rather than migrated.
function interactionStateFor(documentId, contentRevision) {
  const existing = interactionState.get(documentId);
  if (existing && existing.contentRevision === contentRevision) return existing;
  const fresh = { contentRevision, selection: null, find: null, lastHit: null };
  interactionState.set(documentId, fresh);
  return fresh;
}

// Non-mutating counterpart of interactionStateFor(), for read-only lookups
// (forwarding find_next/find_previous's match set into browser.js) that must
// not fabricate an entry for a document whose interaction is about to fail --
// e.g. one that has never been rendered. Only a *successful* interact may
// create or touch an entry; see dispatchInteract below.
function peekInteractionState(documentId, contentRevision) {
  const existing = interactionState.get(documentId);
  return existing && existing.contentRevision === contentRevision ? existing : null;
}

function unlinkQuietly(pngPath) {
  if (typeof pngPath !== "string") return;
  try { fs.unlinkSync(pngPath); } catch {}
}

// One serial chain over one shared page: all DOM work must be mutually
// exclusive, and a second parallel queue would let an interaction evaluate while
// a render is mid-setContent. Head-of-line blocking is handled by the lanes
// instead -- a superseded task fails its staleness check and returns without
// touching the page, so a burst of drag updates behind a slow render costs one
// map lookup each rather than one screenshot each.
function enqueue(task, ticket) {
  const settle = async () => {
    try {
      return await task();
    } finally {
      lanes.release(ticket);
    }
  };
  const queued = renderQueue.then(settle, settle);
  renderQueue = queued.catch(() => {});
  return queued;
}

function dispatchRender(request) {
  const params = request.params ?? {};
  const captureOnly = request.method === "capture";
  if (typeof params.documentId !== "string"
    || (!captureOnly && typeof params.markdown !== "string")) {
    throw new Error("render requires documentId and markdown strings; capture requires documentId");
  }
  const lane = resolveLane(request.method, params.lane);
  // Stamped synchronously, before this function's caller reaches any `await`.
  // protocol.js does not await one line before reading the next, so synchronous
  // stamping is what makes arrival order equal supersession order.
  const ticket = lanes.admit({
    documentId: params.documentId,
    lane,
    requestId: request.id,
    contentRevision: params.contentRevision,
  });

  const task = async () => {
    const before = lanes.isStale(ticket);
    if (before) throw lanes.staleError(ticket, before);

    const previous = markdownCache.get(params.documentId);
    let markdownKey;
    let markdownReused;
    let html;
    if (captureOnly) {
      if (!previous) {
        const error = new Error("capture cache missing; perform a full render first");
        error.code = "CAPTURE_CACHE_MISS";
        throw error;
      }
      markdownKey = previous.key;
      markdownReused = true;
      html = previous.html;
    } else {
      // Normalized (sorted, deduplicated) so it can join the cache key: an
      // allowlist edit must invalidate the cached HTML, and a mere reordering
      // must not.
      const remoteImages = normalizeAllowlist(params.remoteImages);
      markdownKey = JSON.stringify([
        params.contentRevision ?? params.markdown,
        params.rawHtml === true,
        params.localImages === true,
        Number(params.maxLocalImageBytes) || 10 * 1024 * 1024,
        params.baseDir,
        params.documentRoot,
        remoteImages,
      ]);
      markdownReused = previous?.key === markdownKey;
      if (markdownReused) {
        html = previous.html;
      } else {
        const rendered = await renderMarkdown(params.markdown, {
          rawHtml: params.rawHtml === true,
          localImages: params.localImages === true,
          maxLocalImageBytes: Number(params.maxLocalImageBytes) || 10 * 1024 * 1024,
          baseDir: params.baseDir,
          documentRoot: params.documentRoot,
          remoteImages,
        });
        html = rendered.html;
        rememberMarkdown(params.documentId, {
          key: markdownKey, html: rendered.html, sourceMap: rendered.sourceMap,
        });
        // New content: whatever the user had selected or searched for belongs to
        // the old document body and must not be carried forward.
        interactionState.delete(params.documentId);
      }
    }

    const result = await browser.render({ ...params, contentFingerprint: markdownKey }, html, request.id);
    result.markdownReused = markdownReused;
    const after = lanes.isStale(ticket);
    if (after) {
      unlinkQuietly(result.pngPath);
      throw lanes.staleError(ticket, after);
    }
    return result;
  };

  return enqueue(task, ticket);
}

function dispatchInteract(request) {
  // Pure and synchronous, so an invalid envelope never reaches the queue.
  const envelope = validateEnvelope(request.params);
  const lane = resolveLane("interact", request.params?.lane);
  const ticket = lanes.admit({
    documentId: envelope.documentId,
    lane,
    requestId: request.id,
    contentRevision: envelope.contentRevision,
  });

  const task = async () => {
    const before = lanes.isStale(ticket);
    if (before) throw lanes.staleError(ticket, before);
    const markdown = markdownCache.get(envelope.documentId);
    // Read-only: a request that is about to fail (a never-rendered document, a
    // revision mismatch) must not fabricate or disturb interaction state for
    // it. find_next/find_previous need the match set find_set already
    // resolved -- browser.js does not own interactionState, so it is
    // forwarded through `cached` alongside the markup and source map it
    // already carries.
    const priorState = peekInteractionState(envelope.documentId, String(envelope.contentRevision));
    const cached = markdown ? { ...markdown, findState: priorState?.find } : markdown;
    const result = await browser.interact(envelope, cached, request.id);
    const after = lanes.isStale(ticket);
    if (after) {
      unlinkQuietly(result.pngPath);
      throw lanes.staleError(ticket, after);
    }
    // Only a successful interact may create or touch interaction state.
    const state = interactionStateFor(envelope.documentId, String(envelope.contentRevision));
    state.lastHit = result.hit ?? null;
    // selection_text is read-only (mutatesVisibleState: false) and must never
    // write state.selection -- a stray write here would let a copy operation
    // silently "commit" a selection that was never actually dragged. A failed
    // resolution (anchor/focus miss) must not overwrite a prior valid
    // selection with an empty one either.
    if (result.kind === "selection" && envelope.action !== "selection_text" && result.ok !== false) {
      state.selection = result.cleared
        ? null
        : {
          text: result.text,
          collapsed: result.collapsed,
          anchorSourcePosition: result.anchorSourcePosition,
          focusSourcePosition: result.focusSourcePosition,
        };
    }
    if (result.kind === "find") {
      state.find = result.cleared
        ? null
        : {
          query: result.query,
          matchCount: result.matchCount,
          activeIndex: result.activeIndex,
          activeSourcePosition: result.activeSourcePosition,
          matches: result.matches ?? [],
        };
      // Internal only -- see buildFindResult's comment in interact.js. Lua only
      // ever needs the active match's position, not the whole capped array.
      delete result.matches;
    }
    return result;
  };

  return enqueue(task, ticket);
}

async function dispatch(request) {
  if (request.method === "shutdown") {
    shuttingDown = true;
    await browser.close();
    setImmediate(() => process.exit(0));
    return { shutdown: true };
  }
  if (request.method === "ping") return { pong: true };
  if (request.method === "health") {
    const result = await browser.health(request.params?.browser ?? {});
    return {
      ...result,
      cachedDocuments: markdownCache.size,
      laneDocuments: lanes.size,
      interactionDocuments: interactionState.size,
    };
  }
  if (request.method === "interact") return dispatchInteract(request);
  if (request.method !== "render" && request.method !== "capture") {
    throw new Error(`unknown method: ${request.method}`);
  }
  return dispatchRender(request);
}

const protocol = new LineProtocol(process.stdin, process.stdout, dispatch);
protocol.start();

async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  await browser.close();
  process.exit(0);
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
process.on("uncaughtException", (error) => {
  process.stderr.write(`md-viewer renderer fatal: ${error.stack ?? error.message}\n`);
  shutdown();
});
