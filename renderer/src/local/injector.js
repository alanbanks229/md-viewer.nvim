// Turns swallowed markers into injected byte transactions, under the three
// rules that keep deferred injection honest:
//
// 1. Deletion-carry. A superseded surface transaction loses its placements
//    but never its deletions: the remote side's books already say the old
//    placement is gone (`M.update` records the swap the moment it emits), so
//    dropping the deletion half would leave a ghost frame composited forever
//    with nothing left anywhere that knows to remove it. Carried deletions
//    are appended after the next injected transaction's own deletions -- new
//    placements always land before the deletions that supersede them, the
//    same single-write order `kitty_raw.lua` pins -- and are never flushed on
//    their own: a standalone delete would blank the pane while its
//    replacement is still rendering, and a blank pane with no explanation is
//    the exact defect the resident bootstrap work exists to prevent. If no
//    later injection ever comes, teardown() flushes them.
//
// 2. Per-document surface ordering. A surface transaction (one that uploads a
//    frame or sheet) is refused if a newer surface transaction for the same
//    document has already been injected -- a slow render must not overwrite
//    the frame that superseded it. Placement-only and deletion-only
//    transactions are exempt: they re-arrange or remove content that is
//    already on screen and must neither be dropped as "stale" nor invalidate
//    a newer frame still rendering. (A placement-only re-place injected ahead
//    of a pending frame can land that frame without the re-place's cut-outs
//    for up to one reconcile tick, ~50 ms -- the same transient the remote
//    path already exhibits between a capture and the float that appeared
//    after it. The ui_poll reconcile heals it.)
//
// 3. Boundary-only, atomic writes. Injection happens only when the stream
//    parser reports a safe boundary, and one transaction is one write():
//    uploads, then placements, then deletions, then anything carried.
//
// Uploads arrive as *references*; `resolveUpload(upload, doc)` returns the
// PNG bytes when the replica has rendered that state, or null to defer. The
// injector holds at most one pending surface transaction per document
// (newest wins), so a scroll burst costs one render, not a queue.

import { uploadSequence, deleteImage } from "./kitty-writer.js";
import { parseMarkerPayload } from "./markers.js";
import { createReservoir } from "./timing.js";

export class Injector {
  constructor({ token, write, resolveUpload, boundary, onPairing, now }) {
    this.token = token;
    this.write = write;
    this.resolveUpload = resolveUpload;
    this.boundary = boundary;
    // Injectable so the virtual-clock tests can measure the measurement;
    // production takes the monotonic clock.
    this.now = now ?? (() => performance.now());
    // Marker-arrival -> transaction-write, frame markers only, and only for
    // the transaction that actually lands: a superseded frame is never a
    // latency sample, because nothing was ever late *to the glass* -- it was
    // replaced. This is the helper's half of K4; the remote clock cannot
    // reach in here and is not asked to.
    this.frameTiming = createReservoir();
    // seq 0 is reserved: it is the pairing probe the remote plugin emits
    // through its own tty to prove which helper sits on this terminal. It
    // carries nothing and is never injected -- it is answered, over the
    // socket, by whoever constructed us with this hook.
    this.onPairing = onPairing ?? (() => {});
    // Called after a transaction's bytes reach the terminal, with the parsed
    // transaction; the session layer turns it into the `presented`
    // notification the remote reconciles scroll state from.
    this.onInjected = () => {};

    this.pendingByDoc = new Map(); // doc -> parsed surface transaction, newest only
    this.immediateQueue = []; // placement-only / deletion-only, in arrival order
    this.carriedDeletions = []; // Buffers from superseded/refused transactions
    this.lastSurfaceSeq = new Map(); // doc -> seq of the newest injected surface tx
    // Every image id this injector ever uploaded. Most are freed by later
    // injected deletions, but those bytes are opaque to us by design, so the
    // set only grows; teardown re-deletes every id, and `d=I` on an already
    // freed id is a suppressed no-op. Integers only -- memory is trivial.
    this.uploadedIds = new Set();

    this.stats = {
      accepted: 0,
      malformed: 0,
      tokenMismatch: 0,
      superseded: 0,
      injectedTransactions: 0,
      injectedBytes: 0,
      refusedStaleSurface: 0,
      carriedDeletionBuffers: 0,
    };
  }

  /// Payload of a marker the stream parser swallowed. Malformed markers are
  /// counted and dropped -- the parser already matched the token prefix, so
  /// anything unparseable past it is a bug upstream, never a guess here.
  acceptMarker(payload) {
    let parsed;
    try {
      parsed = parseMarkerPayload(payload);
    } catch {
      this.stats.malformed += 1;
      return;
    }
    if (parsed.token !== this.token) {
      this.stats.tokenMismatch += 1;
      return;
    }
    this.stats.accepted += 1;

    if (parsed.seq === 0) {
      this.onPairing(parsed);
      return;
    }

    if (parsed.uploads.some((upload) => upload.kind === "frame")) {
      parsed.receivedAt = this.now();
    }

    if (parsed.uploads.length === 0) {
      if (parsed.kill) {
        // Content removal: a frame still pending for this document must die
        // with it, or a hidden window gets fresh pixels injected onto it
        // moments later -- and nothing would ever remove them, because the
        // remote stops reconciling a window it believes is hidden.
        const pending = this.pendingByDoc.get(parsed.doc);
        if (pending) {
          this.pendingByDoc.delete(parsed.doc);
          this.stats.superseded += 1;
          this.carryDeletions(pending);
        }
      }
      this.immediateQueue.push(parsed);
    } else {
      const previous = this.pendingByDoc.get(parsed.doc);
      if (previous) {
        this.stats.superseded += 1;
        this.carryDeletions(previous);
      }
      this.pendingByDoc.set(parsed.doc, parsed);
    }
    this.tryInject();
  }

  /// The replica finished rendering something; whatever is pending may now
  /// resolve. Also called by the filter after every parser push that ends at
  /// a safe boundary.
  tryInject() {
    if (!this.boundary()) return;

    const injectable = [];
    for (const tx of this.immediateQueue) injectable.push({ tx, uploads: null });
    this.immediateQueue = [];

    for (const [doc, tx] of [...this.pendingByDoc]) {
      const resolved = [];
      let ready = true;
      for (const upload of tx.uploads) {
        const bytes = this.resolveUpload(upload, tx.doc);
        if (bytes === null || bytes === undefined) {
          ready = false;
          break;
        }
        resolved.push({ id: upload.id, bytes });
      }
      if (!ready) continue;
      this.pendingByDoc.delete(doc);
      const floor = this.lastSurfaceSeq.get(tx.doc);
      if (floor !== undefined && tx.seq < floor) {
        // A newer frame already landed; this one's pixels must not overwrite
        // it, but its deletions still name real placements.
        this.stats.refusedStaleSurface += 1;
        this.carryDeletions(tx);
        continue;
      }
      injectable.push({ tx, uploads: resolved });
    }

    injectable.sort((a, b) => a.tx.seq - b.tx.seq);

    for (let i = 0; i < injectable.length; i += 1) {
      const { tx, uploads } = injectable[i];
      const parts = [];
      if (uploads) {
        for (const { id, bytes } of uploads) {
          parts.push(Buffer.from(uploadSequence(id, bytes), "latin1"));
          this.uploadedIds.add(id);
        }
        this.lastSurfaceSeq.set(tx.doc, Math.max(tx.seq, this.lastSurfaceSeq.get(tx.doc) ?? -1));
      }
      parts.push(tx.placements, tx.deletions);
      if (i === 0 && this.carriedDeletions.length > 0) {
        parts.push(...this.carriedDeletions);
        this.carriedDeletions = [];
      }
      const transaction = Buffer.concat(parts);
      if (transaction.length === 0) continue;
      this.stats.injectedTransactions += 1;
      this.stats.injectedBytes += transaction.length;
      if (tx.receivedAt !== undefined) this.frameTiming.add(this.now() - tx.receivedAt);
      this.write(transaction);
      this.onInjected(tx);
    }
  }

  /// The K4 stage timings, snapshotted as plain data for `--status` and the
  /// health enrichment. `frameTimeToInject` covers marker arrival at this
  /// filter to the frame transaction's write -- resolve wait, capture, and
  /// injection, everything on this side of the wire.
  timingSnapshot() {
    return { frameTimeToInject: this.frameTiming.snapshot() };
  }

  carryDeletions(tx) {
    if (tx.deletions.length === 0) return;
    this.carriedDeletions.push(tx.deletions);
    this.stats.carriedDeletionBuffers += 1;
  }

  /// Everything that must reach the terminal to retire this injector's
  /// placements: deletions still being carried, plus a targeted delete for
  /// every image id it ever put up. Named for the helper's own process exit,
  /// its original caller -- writing the return value there, while the
  /// process still owns the tty -- but reused verbatim on a control-socket
  /// client disconnect: the same placements a dying process would clean up
  /// are exactly the ones an outgoing Neovim session leaves behind when a
  /// new one is about to attach to the same terminal, and a second call
  /// after the first (whichever ran first) is a safe no-op over already
  /// -emptied sets.
  ///
  /// `lastSurfaceSeq` is cleared here too: it is the per-document seq floor
  /// that refuses an "older" frame once a newer one has landed
  /// (`tryInject`'s `refusedStaleSurface` check), and a fresh Neovim
  /// session's markers restart near seq=1 -- left at the outgoing session's
  /// high-water mark, they would refuse every one of the new session's early
  /// frames as stale.
  teardown() {
    const parts = [...this.carriedDeletions];
    for (const id of this.uploadedIds) parts.push(Buffer.from(deleteImage(id), "latin1"));
    this.carriedDeletions = [];
    this.uploadedIds.clear();
    this.pendingByDoc.clear();
    this.immediateQueue = [];
    this.lastSurfaceSeq.clear();
    return Buffer.concat(parts);
  }
}
