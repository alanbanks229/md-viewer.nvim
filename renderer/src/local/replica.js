// The helper's replica renderer: the session brain that turns pushed
// document state into resolvable surfaces.
//
// It owns one `createService` instance and drives it in-process through
// `dispatch`, which is the whole reuse argument: lanes, staleness, the
// serial page queue, capture semantics, and the interact envelope all behave
// exactly as they do beside a remote Neovim, because they are the same code
// answering the same requests. What this file adds is only what location
// changes: an asset store fed by pushes (verified by content hash -- the
// push channel cannot rename one image into another), a bounded surface
// cache the injector resolves uploads from, the visual epoch that lets
// selection/find DOM changes invalidate frames without a content revision,
// and the async notifications (`metrics`, `presented` is the injector's,
// `missing`) that replace response-coupling for everything off the frame
// path.
//
// Nothing here answers a marker. Markers resolve against state this file has
// already produced, or they wait; that inversion -- replicate, then present
// -- is the difference between this design and the rejected 2026 experiment
// that serialized a round trip into every frame.

import fs from "node:fs";
import { createService } from "../service.js";
import { AssetStore } from "./asset-store.js";
import { buildOverlaySheetPng } from "../overlay-sheet.js";
import { INTERACT_ACTIONS } from "../interact.js";
import { createReservoir } from "./timing.js";

const MAX_SURFACES = 16;

function surfaceKey(doc, rev, scrollY, widthPx, heightPx, scale, epoch) {
  return [doc, rev, Math.round(scrollY), `${widthPx}x${heightPx}@${scale}`, `e${epoch}`].join("\0");
}

export function createReplica({ assetsDir, onNotify = () => {}, onSurfaceReady = () => {}, now } = {}) {
  const service = createService({ assetsDir });
  const assets = new AssetStore();
  const clock = now ?? (() => performance.now());
  const surfaces = new Map(); // surfaceKey -> Buffer (PNG), insertion-LRU
  const docs = new Map(); // documentId -> { lastParams, epoch, pending, capture state }
  const missingNotified = new Set(); // doc\0rev already NACKed
  let requestSerial = 0;
  const stats = {
    renders: 0,
    captures: 0, // dispatched to the browser queue (capturesStarted)
    capturesRequested: 0, // distinct surface wants that reached the scheduler
    capturesCompleted: 0,
    capturesSupersededBeforeStart: 0, // a newer want replaced a queued one
    capturesDiscarded: 0, // completed or failed without producing a surface
    surfacesServed: 0,
    assetMisses: 0,
    assetRefused: 0,
  };
  const timing = {
    captureQueueWait: createReservoir(), // want recorded -> capture dispatched
    captureDuration: createReservoir(), // capture dispatched -> pixels stored
  };

  function docRecord(documentId) {
    let record = docs.get(documentId);
    if (!record) {
      record = { lastParams: null, epoch: 0, pending: null, laidOutRevision: null, wanted: null, capturingKey: null };
      docs.set(documentId, record);
    }
    return record;
  }

  function dispatch(method, params) {
    requestSerial += 1;
    return service.dispatch({ id: requestSerial, method, params });
  }

  function storeSurface(key, bytes) {
    surfaces.delete(key);
    surfaces.set(key, bytes);
    while (surfaces.size > MAX_SURFACES) {
      const oldest = surfaces.keys().next().value;
      surfaces.delete(oldest);
    }
  }

  // Substitute `md-asset:` refs back into data: URIs; the browser context's
  // route policy (data:/about: only) never changes. Returns the missing shas
  // instead of rendering placeholders for them: a frame with holes that will
  // be filled moments later is worse than the previous frame staying up.
  function substituteAssets(html) {
    const missing = [];
    const substituted = html.replace(/md-asset:([0-9a-f]{64})/g, (whole, sha) => {
      const uri = assets.dataUri(sha);
      if (uri) return uri;
      if (!missing.includes(sha)) missing.push(sha);
      return whole;
    });
    return { html: substituted, missing };
  }

  async function layout(record, params, html) {
    stats.renders += 1;
    // Stamped at dispatch, not at completion: the service queue is serial, so
    // any capture scheduled after this line runs after the cache holds this
    // revision's html. (A render_prepared staled by a newer revision leaves
    // the stamp ahead of the cache, but every marker for the staled revision
    // was superseded with it -- nothing can resolve a surface it poisons.)
    record.laidOutRevision = String(params.contentRevision);
    const result = await dispatch("render_prepared", { ...params, html });
    const viewport = params.viewport ?? {};
    const bytes = fs.readFileSync(result.pngPath);
    fs.unlinkSync(result.pngPath);
    const store = (scrollY) =>
      storeSurface(
        surfaceKey(
          params.documentId,
          String(params.contentRevision),
          scrollY,
          viewport.widthPx,
          viewport.heightPx,
          viewport.deviceScaleFactor ?? 1,
          record.epoch
        ),
        bytes
      );
    // Stored under the achieved scroll *and* the requested one: the browser
    // clamps past-the-end requests, and a marker naming the requested offset
    // must still resolve -- the remote learns the achieved value from
    // `presented` and reconciles, exactly as it does from `meta.scrollY`
    // today.
    store(result.scrollY ?? params.scrollY ?? 0);
    if (params.scrollY !== undefined && Math.round(params.scrollY) !== Math.round(result.scrollY ?? params.scrollY)) {
      store(params.scrollY);
    }
    onSurfaceReady();
    return {
      documentHeightPx: result.documentHeightPx,
      viewportHeightPx: result.viewportHeightPx,
      blocks: result.blocks,
      scrollY: result.scrollY,
      visualEpoch: record.epoch,
    };
  }

  async function handleRender(params) {
    if (typeof params.documentId !== "string" || typeof params.html !== "string") {
      throw new Error("render requires documentId and html");
    }
    const record = docRecord(params.documentId);
    const { html, missing } = substituteAssets(params.html);
    const bare = { ...params };
    delete bare.html;
    record.lastParams = bare;
    if (missing.length > 0) {
      stats.assetMisses += missing.length;
      record.pending = { params: bare, html: params.html };
      return { pending: true, missingAssets: missing, visualEpoch: record.epoch };
    }
    record.pending = null;
    return layout(record, bare, html);
  }

  async function handleAsset(params) {
    const pushed = Array.isArray(params.assets) ? params.assets : [];
    const refused = [];
    for (const item of pushed) {
      const data = Buffer.from(String(item.data ?? ""), "base64");
      if (!assets.putVerified(String(item.sha ?? ""), String(item.mime ?? "application/octet-stream"), data)) {
        stats.assetRefused += 1;
        refused.push(item.sha);
      }
    }
    // Anything that was waiting only on bytes can lay out now; metrics go
    // back as a notification because the render request that needed them was
    // answered `pending` long ago.
    for (const [documentId, record] of docs) {
      if (!record.pending) continue;
      const { html, missing } = substituteAssets(record.pending.html);
      if (missing.length > 0) continue;
      const pendingParams = record.pending.params;
      record.pending = null;
      layout(record, pendingParams, html)
        .then((metrics) => onNotify("metrics", { doc: documentId, rev: String(pendingParams.contentRevision), ...metrics }))
        .catch(() => {});
    }
    return { stored: pushed.length - refused.length, refused };
  }

  async function handleInteract(params) {
    // Structural, not advisory: whatever the envelope asked for, no capture
    // runs and no sheet is built. Mutations are displayed by the frame marker
    // the remote emits against the bumped epoch, and sheets are synthesized
    // from marker references -- PNG bytes have no business in any response.
    const result = await dispatch("interact", { ...params, capture: false, overlaySheet: undefined });
    const record = docRecord(params.documentId);
    if (INTERACT_ACTIONS[params.action]?.mutatesVisibleState && result) {
      // The frame on screen no longer matches the DOM; a new epoch makes
      // every existing surface unresolvable so the remote's next marker (it
      // reads the epoch from this response) forces a fresh capture.
      record.epoch += 1;
    }
    if (result && typeof result === "object") {
      // No PNG ever crosses the socket. An interact that captured anyway
      // (the remote is expected not to ask, and the dispatch above refuses
      // to) is stripped, not forwarded -- sheets included.
      if (typeof result.pngPath === "string") {
        try {
          fs.unlinkSync(result.pngPath);
        } catch {}
        delete result.pngPath;
      }
      delete result.overlaySheetPng;
      result.visualEpoch = record.epoch;
    }
    return result;
  }

  function scheduleSurface(documentId, upload) {
    const record = docs.get(documentId);
    if (!record || !record.lastParams) {
      const nack = `${documentId}\0${upload.rev}`;
      if (!missingNotified.has(nack)) {
        missingNotified.add(nack);
        onNotify("missing", { doc: documentId, rev: upload.rev });
      }
      return;
    }
    if (record.epoch !== upload.epoch) return; // a newer marker is on its way
    // A capture reuses whatever html the service has cached for the document,
    // so it is only honest when the cache holds the marker's revision. A
    // marker can name a revision whose render is still crossing the socket
    // (markers ride the terminal stream; the two channels share no ordering)
    // or whose assets are still being pushed -- capturing then would store
    // the *old* revision's pixels under the new revision's key, the exact
    // stale-pixels class the resident invariants exist to prevent. The
    // render's own layout stores its surface and re-triggers injection, and a
    // later scroll of the same revision resolves here once laidOutRevision
    // says the cache is the right one.
    if (record.laidOutRevision !== String(upload.rev)) return;
    const key = surfaceKey(documentId, upload.rev, upload.scrollY, upload.widthPx, upload.heightPx, upload.scale, upload.epoch);
    // One capture in flight per document, newest want wins. The alternative
    // -- dispatching every missed reference into the serial browser queue --
    // is what rc9 shipped, and its arithmetic on the work laptop (2026-08-27)
    // was 517 captures for 206 surfaces served: each new scroll position
    // admitted a capture that superseded the one already *running*, so the
    // finished screenshot failed its post-work staleness check and was
    // discarded, browser flat out, screen mostly still. Holding one want and
    // dispatching only when idle means the running capture stays current in
    // its lane, every completed screenshot lands, and a scroll burst costs
    // captures at the browser's own rate instead of one per position.
    if (record.capturingKey === key || record.wanted?.key === key) return;
    if (record.wanted) stats.capturesSupersededBeforeStart += 1;
    record.wanted = { upload, key, at: clock() };
    stats.capturesRequested += 1;
    pumpCapture(documentId, record);
  }

  function pumpCapture(documentId, record) {
    if (record.capturingKey || !record.wanted) return;
    const { upload, key, at } = record.wanted;
    record.wanted = null;
    // Re-validated at dispatch, not only at want time: an epoch bump or a new
    // revision may have landed while this want sat behind a running capture,
    // and pixels captured for it now could never resolve any live marker.
    if (record.epoch !== upload.epoch || record.laidOutRevision !== String(upload.rev)) return;
    record.capturingKey = key;
    stats.captures += 1;
    timing.captureQueueWait.add(clock() - at);
    const started = clock();
    // The marker's scale is the capture's scale: a moving-tier reference
    // (`c=` below the device factor) is captured reduced, exactly as the
    // direct path captures its moving frame, and only the settle reference
    // pays full device resolution. The browser clamps the css factor to
    // [0.25, 1] on its side too.
    const device = (record.lastParams.viewport ?? {}).deviceScaleFactor ?? 1;
    const scaleParams =
      upload.scale >= device
        ? { captureScale: "device" }
        : { captureScale: "css", captureScaleFactor: upload.scale };
    dispatch("capture", {
      ...record.lastParams,
      contentRevision: upload.rev,
      scrollY: upload.scrollY,
      ...scaleParams,
    })
      .then((result) => {
        timing.captureDuration.add(clock() - started);
        stats.capturesCompleted += 1;
        const bytes = fs.readFileSync(result.pngPath);
        fs.unlinkSync(result.pngPath);
        storeSurface(key, bytes);
        const achieved = surfaceKey(
          documentId,
          upload.rev,
          result.scrollY ?? upload.scrollY,
          upload.widthPx,
          upload.heightPx,
          upload.scale,
          upload.epoch
        );
        if (achieved !== key) storeSurface(achieved, bytes);
        onSurfaceReady();
      })
      .catch(() => {
        // A content render bumped the lane out from under this capture; the
        // new revision's marker brings its own.
        stats.capturesDiscarded += 1;
      })
      .finally(() => {
        record.capturingKey = null;
        pumpCapture(documentId, record);
      });
  }

  function statsSnapshot() {
    return {
      ...stats,
      surfaces: surfaces.size,
      assets: assets.stats(),
      documents: docs.size,
      timing: {
        captureQueueWait: timing.captureQueueWait.snapshot(),
        captureDuration: timing.captureDuration.snapshot(),
      },
    };
  }

  return {
    /// The socket-service request handler: everything the plugin can ask
    /// over the control socket, hello excepted.
    async handle(method, params = {}) {
      if (method === "render") return handleRender(params);
      if (method === "asset") return handleAsset(params);
      if (method === "interact") return handleInteract(params);
      if (method === "health") {
        const health = await dispatch("health", params);
        return { ...health, replica: statsSnapshot() };
      }
      if (method === "shutdown") return { shutdown: true };
      const error = new Error(`the local helper does not serve ${method}`);
      error.code = "UNSUPPORTED_METHOD";
      throw error;
    },

    /// The injector's upload resolver: bytes when the replica has them,
    /// null to defer (scheduling whatever render work the miss implies).
    resolveUpload(upload, documentId) {
      if (upload.kind === "sheet") {
        const alpha = parseInt(upload.tint.slice(6, 8), 16) / 255;
        const tint = {
          r: parseInt(upload.tint.slice(0, 2), 16),
          g: parseInt(upload.tint.slice(2, 4), 16),
          b: parseInt(upload.tint.slice(4, 6), 16),
          a: alpha,
        };
        try {
          return buildOverlaySheetPng(upload.widthPx, upload.heightPx, tint, { x: upload.marginX, y: upload.marginY });
        } catch {
          return null;
        }
      }
      const key = surfaceKey(documentId, upload.rev, upload.scrollY, upload.widthPx, upload.heightPx, upload.scale, upload.epoch);
      const bytes = surfaces.get(key);
      if (bytes) {
        stats.surfacesServed += 1;
        // Refresh recency: an actively panned-between pair of surfaces should
        // not be the ones evicted.
        surfaces.delete(key);
        surfaces.set(key, bytes);
        return bytes;
      }
      scheduleSurface(documentId, upload);
      return null;
    },

    stats: statsSnapshot,

    close() {
      return service.close();
    },
  };
}
