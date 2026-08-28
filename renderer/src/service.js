// Everything the renderer does, with no opinion about how requests reach it.
//
// This was `main.js` in full. The split is along one seam and no other: *what* a
// request means is here, *where* it arrives from is `main.js`'s business. There
// is one entrypoint today, so the seam earns nothing structurally — it is kept
// because it is what makes the invariant below a property of this file rather
// than a property of whoever happens to call it.
//
// **Invariant:** nothing in this file opens, listens on, or connects to
// anything. `tests/node/no-listening-port.test.js` proves it of `main.js` and
// its real Chromium child, which is the process the plugin actually spawns.
//
// One service owns one browser, one page and one serial queue, so a single
// process could not serve two clients without having them share a document
// cache and a lane registry.

import fs from "node:fs";
import { BrowserRenderer } from "./browser.js";
import { renderMarkdown } from "./markdown.js";
import { AnimationStore } from "./animation.js";
import { LANES, createLaneError, createLaneRegistry } from "./lanes.js";
import { validateEnvelope } from "./interact.js";
import { AssetStore } from "./local/asset-store.js";

const MAX_CACHED_DOCUMENTS = 64;

// A `capture` may be promoted to the `settle` lane so a settled high-resolution
// frame and an in-flight fast frame do not cancel each other. Nothing else may
// move lanes: allowing an interaction into the content lane would hand it the
// power to cancel renders, which is exactly what this design removes.
const ALLOWED_LANES = {
  render: ["content"],
  render_prepared: ["content"],
  prepare: ["content"],
  capture: ["capture", "settle"],
  interact: ["interact"],
};

/// Build a renderer service.
///
/// `onShutdown` is called after resources are released in response to a
/// `shutdown` request, and is where the process exits if it is going to. The
/// service does not decide that: the child is owned by Neovim and must exit
/// when told, and whether that is the right answer belongs to the entrypoint.
export function createService({ assetsDir, onShutdown } = {}) {
  const browser = new BrowserRenderer({ assetsDir });
  // Frames are written inside the browser's own temp directory, which is the
  // trust boundary: the terminal is handed a path to read, so that path must
  // never be one the document chose. browser.close() already removes it. The
  // provider hands the store the live Browser handle so its decode context can
  // follow a relaunch; the store never owns browser lifecycle.
  const animations = new AnimationStore({ dir: browser.tempDir, browserProvider: () => browser.browser });

  // documentId -> { key, html, sourceMap, animations, remoteImagesPending }.
  // The source map is the trusted-memory half of source provenance: the page
  // holds opaque region keys, this holds what they mean. It is written and
  // evicted with the markup it describes, so the two can never disagree about
  // which render they belong to. `remoteImagesPending` rides along because it
  // describes when this markup was produced rather than what the document says,
  // and that is what disqualifies it from being reused as final.
  const markdownCache = new Map();
  // Content-addressed bytes behind the `md-asset:` refs `prepare` emits.
  // Keyed purely by content: two documents sharing an image share one entry,
  // and re-preparing a revision costs no storage.
  const documentAssets = new AssetStore();
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

  // One serial chain over one shared page: all DOM work must be mutually
  // exclusive, and a second parallel queue would let an interaction evaluate while
  // a render is mid-setContent. Head-of-line blocking is handled by the lanes
  // instead -- a superseded task fails its staleness check and returns without
  // touching the page, so a burst of selection-preview updates behind a slow
  // render costs one map lookup each rather than one screenshot each.
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
    // The local-render path: the markup was produced by a `prepare` on the
    // machine the document lives on and crossed the control link already
    // sanitized, with its images as content-addressed refs the caller has
    // substituted back to data: URIs. Same lanes, same cache, same browser
    // path -- only the "markdown -> html" step is elsewhere.
    const prepared = request.method === "render_prepared";
    if (typeof params.documentId !== "string"
      || (!captureOnly && !prepared && typeof params.markdown !== "string")
      || (prepared && typeof params.html !== "string")) {
      throw new Error("render requires documentId and markdown; render_prepared requires documentId and html; capture requires documentId");
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
      if (prepared) {
        markdownKey = JSON.stringify(["prepared", params.contentRevision ?? null]);
        // Same rule as the markdown branch below, carried across the split:
        // markup prepared while a remote image was still being fetched is not
        // final whatever the revision says, and the re-render that replaces
        // its placeholder arrives under the *same* revision. The flag travels
        // with the render request because only the preparing side knows it.
        markdownReused = previous?.key === markdownKey && !previous.remoteImagesPending;
        if (markdownReused) {
          html = previous.html;
          rememberMarkdown(params.documentId, previous);
        } else {
          html = params.html;
          rememberMarkdown(params.documentId, {
            key: markdownKey,
            html,
            sourceMap: params.sourceMap ?? null,
            animations: new Map(),
            remoteImagesPending: params.remoteImagesPending === true ? 1 : 0,
          });
          interactionState.delete(params.documentId);
        }
      } else if (captureOnly) {
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
          params.obsidianEnabled === true,
        ]);
        // Markup rendered while an image was still being fetched is not final,
        // whatever the content revision says. Reusing it would cache the
        // "loading" placeholder for the life of the document and the retry that
        // is meant to replace it would be answered with the thing it is
        // replacing -- so the one case that must re-render never would.
        markdownReused = previous?.key === markdownKey && !previous.remoteImagesPending;
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
            obsidianEnabled: params.obsidianEnabled === true,
          });
          html = rendered.html;
          rememberMarkdown(params.documentId, {
            key: markdownKey, html: rendered.html, sourceMap: rendered.sourceMap,
            animations: rendered.animations,
            remoteImagesPending: rendered.remoteImagesPending,
          });
          // New content: whatever the user had selected or searched for belongs to
          // the old document body and must not be carried forward.
          interactionState.delete(params.documentId);
        }
      }

      const cachedEntry = markdownCache.get(params.documentId);
      const result = await browser.render(
        { ...params, contentFingerprint: markdownKey, animationIds: [...(cachedEntry?.animations?.keys() ?? [])] },
        html,
        request.id
      );
      result.markdownReused = markdownReused;
      // True while some image in this document is still being fetched. The Lua
      // side answers it with one more render, because nothing else would: an
      // idle preview issues no renders at all, so without a nudge the markup
      // would keep its "loading" placeholders until the next keystroke. Same
      // shape and same reasoning as `animationsIncomplete`.
      result.remoteImagesPending = (cachedEntry?.remoteImagesPending ?? 0) > 0;
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
      // silently "commit" a selection that was never actually made. A failed
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

  /// The document-service half of local rendering: parse and sanitize the
  /// markdown exactly as `render` would -- same security pipeline, same
  /// remote-image policy, same caller-supplied roots -- but stop before the
  /// browser and extract every validated image into the content-addressed
  /// store, returning markup whose images are `md-asset:<sha>` refs plus the
  /// manifest of what those refs mean. The bytes themselves travel only
  /// through `fetch_assets`, only for the shas the far side reports missing:
  /// once per content per helper lifetime, never per revision.
  ///
  /// This method never touches Chromium, which is the point: in local mode
  /// the VM-side process runs markdown and policy and nothing heavier.
  function dispatchPrepare(request) {
    const params = request.params ?? {};
    if (typeof params.documentId !== "string" || typeof params.markdown !== "string") {
      throw new Error("prepare requires documentId and markdown strings");
    }
    const ticket = lanes.admit({
      documentId: params.documentId,
      lane: resolveLane("prepare", params.lane),
      requestId: request.id,
      contentRevision: params.contentRevision,
    });
    const task = async () => {
      const before = lanes.isStale(ticket);
      if (before) throw lanes.staleError(ticket, before);
      const rendered = await renderMarkdown(params.markdown, {
        rawHtml: params.rawHtml === true,
        localImages: params.localImages === true,
        maxLocalImageBytes: Number(params.maxLocalImageBytes) || 10 * 1024 * 1024,
        baseDir: params.baseDir,
        documentRoot: params.documentRoot,
        // Animation needs a decode context beside a browser this process is
        // not running in local mode; the config gate keeps it off, and this
        // keeps it structurally off.
        animationStore: null,
        assetStore: documentAssets,
        obsidianEnabled: params.obsidianEnabled === true,
      });
      const after = lanes.isStale(ticket);
      if (after) throw lanes.staleError(ticket, after);
      const assets = [];
      for (const match of rendered.html.matchAll(/md-asset:([0-9a-f]{64})/g)) {
        const sha = match[1];
        if (assets.some((entry) => entry.sha === sha)) continue;
        const entry = documentAssets.get(sha);
        if (entry) assets.push({ sha, mime: entry.mime, size: entry.data.length });
      }
      return {
        html: rendered.html,
        sourceMap: rendered.sourceMap,
        remoteImagesPending: rendered.remoteImagesPending > 0,
        assets,
      };
    };
    return enqueue(task, ticket);
  }

  /// Serve asset bytes by sha, for the helper-reported misses. Outside the
  /// queue: a pure cache read must never wait behind a render.
  function dispatchFetchAssets(request) {
    const shas = Array.isArray(request.params?.shas) ? request.params.shas : null;
    if (!shas) throw new Error("fetch_assets requires a shas array");
    const assets = [];
    const unknown = [];
    for (const sha of shas) {
      const entry = typeof sha === "string" ? documentAssets.get(sha) : null;
      if (entry) assets.push({ sha, mime: entry.mime, data: entry.data.toString("base64") });
      else unknown.push(sha);
    }
    return { assets, unknown };
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
    if (request.method === "forget") {
      const documentId = request.params?.documentId;
      if (typeof documentId !== "string" || documentId.length === 0) {
        throw new Error("forget requires documentId");
      }
      lanes.forget(documentId);
      forgetDocument(documentId);
      return { forgotten: true };
    }
    if (request.method === "health") {
      const result = await browser.health(request.params?.browser ?? {});
      return {
        ...result,
        cachedDocuments: markdownCache.size,
        laneDocuments: lanes.size,
        interactionDocuments: interactionState.size,
        animationStore: animations.snapshot(),
      };
    }
    if (request.method === "animation") return dispatchAnimation(request);
    if (request.method === "interact") return dispatchInteract(request);
    if (request.method === "prepare") return dispatchPrepare(request);
    if (request.method === "fetch_assets") return dispatchFetchAssets(request);
    if (request.method !== "render" && request.method !== "capture" && request.method !== "render_prepared") {
      throw new Error(`unknown method: ${request.method}`);
    }
    return dispatchRender(request);
  }

  return {
    dispatch,
    close,
    get closing() {
      return shuttingDown;
    },
  };
}
