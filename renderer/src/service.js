// Everything the renderer does, with no opinion about how requests reach it.
//
// This was `main.js` in full until the transport had to become a choice. The
// split is deliberately along one seam and no other: *what* a request means is
// here, *where* it arrives from is the entrypoint's business. `main.js` remains
// the stdin/stdout entrypoint and is the only one the plugin spawns by default;
// `companion.js` serves the same dispatch over a unix socket for a renderer
// running on the machine the terminal is on rather than the machine Neovim is
// on (see docs/local-render-design.md).
//
// **Invariant:** nothing in this file opens, listens on, or connects to
// anything. A transport that did would make "the renderer opens no port" a
// property of one entrypoint rather than of the renderer, and
// tests/node/no-listening-port.test.js proves it of `main.js` specifically for
// exactly that reason.
//
// One service owns one browser, one page and one serial queue, so one process
// serving two clients would have them share a document cache and a lane
// registry. That is why `companion.js` serves one connection at a time rather
// than accepting concurrently.

import fs from "node:fs";
import { BrowserRenderer } from "./browser.js";
import { renderMarkdown } from "./markdown.js";
import { AnimationStore } from "./animation.js";
import { LANES, createLaneError, createLaneRegistry } from "./lanes.js";
import { validateEnvelope } from "./interact.js";

const MAX_CACHED_DOCUMENTS = 64;

// A `capture` may be promoted to the `settle` lane so a settled high-resolution
// frame and an in-flight fast frame do not cancel each other. Nothing else may
// move lanes: allowing an interaction into the content lane would hand it the
// power to cancel renders, which is exactly what this design removes.
const ALLOWED_LANES = {
  render: ["content"],
  capture: ["capture", "settle"],
  interact: ["interact"],
};

/// Build a renderer service.
///
/// `onShutdown` is called after resources are released in response to a
/// `shutdown` request, and is where the process exits if it is going to. The
/// service does not decide that: the stdio child is owned by Neovim and must
/// exit when told, while a companion outlives any single Neovim session and
/// must not.
///
/// `frames` is the store that makes `frameTransport: "ref"` answerable, and is
/// injected rather than created here because the *splicer* is its other reader
/// and the two must be the same object. A service with no store simply refuses
/// the reference path, which is what the stdio child does -- it renders on the
/// machine Neovim is on, so there is nothing for a reference to save.
export function createService({ assetsDir, onShutdown, frames } = {}) {
  const browser = new BrowserRenderer({ assetsDir });
  // Frames are written inside the browser's own temp directory, which is the
  // trust boundary: the terminal is handed a path to read, so that path must
  // never be one the document chose. browser.close() already removes it. The
  // provider hands the store the live Browser handle so its decode context can
  // follow a relaunch; the store never owns browser lifecycle.
  const animations = new AnimationStore({ dir: browser.tempDir, browserProvider: () => browser.browser });

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

  /// Refuse the reference path here rather than deep inside a capture.
  ///
  /// Asked of a service with no store, `frameTransport: "ref"` would otherwise
  /// produce a response with neither a path nor a reference in it, which reads
  /// downstream as a malformed render rather than as a misconfiguration. Said
  /// once, in the words of the thing that is wrong.
  function resolveFrameTransport(requested) {
    if (requested !== "ref") return "path";
    if (!frames) {
      const error = new Error("frameTransport 'ref' needs a renderer with a frame store; this one has none");
      error.code = "NO_FRAME_STORE";
      throw error;
    }
    return "ref";
  }

  /// Move a captured frame out of the response and into the store, leaving the
  /// reference that names it. Called after the staleness check, so a frame that
  /// nobody will display never occupies a slot.
  function publishFrame(result) {
    if (!result || result.pngData === undefined || result.pngData === null) return result;
    result.frameRef = frames.put(result.pngData);
    delete result.pngData;
    return result;
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
    // Synchronous and before the ticket, so a request for a transport this
    // service cannot serve fails outright instead of superseding a good frame.
    const frameTransport = resolveFrameTransport(params.frameTransport);
    // Stamped synchronously, before this function's caller reaches any `await`.
    // protocol.js does not await one line before reading the next, so synchronous
    // stamping is what makes arrival order equal supersession order.
    const ticket = lanes.admit({
      documentId: params.documentId,
      lane,
      requestId: request.id,
      contentRevision: params.contentRevision,
      // Opt-in per request, and only ever taken by a caller that is limiting its
      // own depth. See `admit` for why a link makes supersession the wrong
      // default and what stays guaranteed regardless.
      pipelined: params.pipelined === true,
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
        // A hit must refresh recency. Captures are the scroll path -- the
        // hottest there is -- and without this a document scrolled for an hour
        // ages to the eviction end of the queue while it is on screen.
        rememberMarkdown(params.documentId, previous);
      } else {
        markdownKey = JSON.stringify([
          params.contentRevision ?? params.markdown,
          params.rawHtml === true,
          params.localImages === true,
          Number(params.maxLocalImageBytes) || 10 * 1024 * 1024,
          params.baseDir,
          params.documentRoot,
          // Whether animation is on changes the markup -- an animated image
          // carries `data-md-anim-id` or it does not -- so flipping it has to
          // invalidate the cached HTML. The drawn *size* deliberately stays out
          // of this key: resizing the window must re-encode frames, not re-parse
          // the document.
          params.animate === true,
        ]);
        markdownReused = previous?.key === markdownKey;
        if (markdownReused) {
          html = previous.html;
          // Same refresh as the capture path: a reused parse is still a use.
          rememberMarkdown(params.documentId, previous);
        } else {
          const rendered = await renderMarkdown(params.markdown, {
            rawHtml: params.rawHtml === true,
            localImages: params.localImages === true,
            maxLocalImageBytes: Number(params.maxLocalImageBytes) || 10 * 1024 * 1024,
            baseDir: params.baseDir,
            documentRoot: params.documentRoot,
            animationStore: params.animate === true ? animations : null,
          });
          html = rendered.html;
          rememberMarkdown(params.documentId, {
            key: markdownKey, html: rendered.html, sourceMap: rendered.sourceMap,
            animations: rendered.animations,
          });
          // New content: whatever the user had selected or searched for belongs to
          // the old document body and must not be carried forward.
          interactionState.delete(params.documentId);
        }
      }

      const cachedEntry = markdownCache.get(params.documentId);
      const result = await browser.render(
        {
          ...params, frameTransport, contentFingerprint: markdownKey,
          animationIds: [...(cachedEntry?.animations?.keys() ?? [])],
        },
        html,
        request.id
      );
      result.markdownReused = markdownReused;
      // Animation geometry travels with the render it was measured against --
      // same response, same staleness lane as the base image, so the two can
      // never disagree. The sha is joined here so the Lua side can ask the
      // content-addressed media lane for frames without this process keeping a
      // second, evictable copy of what the request means.
      const registry = cachedEntry?.animations;
      result.animations = (result.animations ?? []).flatMap((rect) => {
        const meta = registry?.get(rect.id);
        return meta ? [{ ...rect, sha: meta.sha }] : [];
      });
      const after = lanes.isStale(ticket);
      if (after) {
        unlinkQuietly(result.pngPath);
        throw lanes.staleError(ticket, after);
      }
      return publishFrame(result);
    };

    return enqueue(task, ticket);
  }

  function dispatchInteract(request) {
    // Pure and synchronous, so an invalid envelope never reaches the queue.
    const envelope = validateEnvelope(request.params);
    const lane = resolveLane("interact", request.params?.lane);
    resolveFrameTransport(envelope.frameTransport);
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
      return publishFrame(result);
    };

    return enqueue(task, ticket);
  }

  /// Materialize the PNG frames for animated images, addressed by content hash.
  ///
  /// Deliberately outside `enqueue`. The decode happens in the decode context's
  /// own page, never the shared render page, so the serial page queue buys
  /// nothing and joining it would put a decode in front of every scroll and
  /// keystroke.
  ///
  /// The request names (sha, drawn size) per animation and nothing else.
  /// Geometry lives in the render response it was measured for, so there is no
  /// second copy here to go stale -- the race where a decode finished against a
  /// document that had moved on is unrepresentable in this shape. Every item
  /// resolves to its own status; a sha this process no longer holds answers
  /// `unknown-source`, which the Lua side treats as "ask again after the next
  /// render re-registers the bytes", never as "this document has no animations".
  function dispatchAnimation(request) {
    const params = request.params ?? {};
    const requests = Array.isArray(params.requests) ? params.requests : null;
    if (!requests) throw new Error("animation requires a requests array");

    const jobs = requests.map(async (item) => {
      const id = typeof item?.id === "string" ? item.id : null;
      if (!id || typeof item?.sha !== "string") {
        return { id: id ?? "?", status: "error", reason: "each animation request needs id and sha strings" };
      }
      const outcome = await animations.materialize(item.sha, item.targetWidthPx, item.targetHeightPx);
      return { id, ...outcome };
    });
    return Promise.all(jobs).then((resolved) => ({ animations: resolved }));
  }

  /// Drop every document this service holds, leaving the browser running.
  ///
  /// This exists for `companion.js`, where one process serves a succession of
  /// Neovim sessions. Document ids are derived from buffer numbers
  /// (`buffer-7`), so a second session reuses the first session's ids for
  /// entirely different files -- and `capture` answers from the cache without
  /// re-reading the document, so a stale entry would render the *previous*
  /// session's file under the new session's id. Clearing on disconnect makes
  /// each connection its own document namespace.
  ///
  /// The browser deliberately survives: launching Chromium is the expensive
  /// part, and keeping it warm between sessions is the whole reason a companion
  /// is a long-lived process rather than one spawned per preview.
  function forgetAll() {
    const held = new Set([...markdownCache.keys(), ...interactionState.keys()]);
    for (const documentId of held) {
      lanes.forget(documentId);
      browser.forgetDocument(documentId);
    }
    markdownCache.clear();
    interactionState.clear();
    // Same reason, one layer down: references are minted per connection and the
    // next session's tokens name its own frames, never the last session's.
    frames?.clear();
  }

  /// Release the browser, the decode context and the temp directory. Idempotent,
  /// because both a `shutdown` request and a signal can reach it.
  async function close() {
    if (shuttingDown) return;
    shuttingDown = true;
    await animations.close().catch(() => {});
    await browser.close();
  }

  async function dispatch(request) {
    if (request.method === "shutdown") {
      await close();
      if (onShutdown) onShutdown();
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
        animationStore: animations.snapshot(),
        // Absent on a renderer that holds no frames, which is how
        // :MdViewerHealth tells a companion from the child beside Neovim
        // without asking the transport.
        frameStore: frames?.stats(),
      };
    }
    if (request.method === "animation") return dispatchAnimation(request);
    if (request.method === "interact") return dispatchInteract(request);
    if (request.method !== "render" && request.method !== "capture") {
      throw new Error(`unknown method: ${request.method}`);
    }
    return dispatchRender(request);
  }

  return {
    dispatch,
    close,
    forgetAll,
    get closing() {
      return shuttingDown;
    },
  };
}
