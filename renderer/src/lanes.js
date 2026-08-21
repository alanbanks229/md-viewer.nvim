// Per-document, per-lane staleness bookkeeping.
//
// This module replaces the single `latestByDocument` map that both `render` and
// `capture` used to write, which meant any newer request for a document
// cancelled any older one. Once interactions arrive at keyboard-repeat
// frequency that is fatal: a stream of selection-preview updates would starve
// legitimate renders.
//
// The rule set, in one place:
//
//   bump content   -> invalidates content, capture, interact, settle
//   bump capture   -> invalidates capture only
//   bump interact  -> invalidates interact only
//   bump settle    -> invalidates settle only
//
// An interaction can therefore never cancel a render or a capture, because the
// only mutable state an `interact` admission writes is `lanes.interact` and the
// content lane's staleness predicate does not read it. That is a structural
// guarantee, not a convention -- there is no code path from an interact
// admission to `lanes.content` or to `contentEpoch`.
//
// Deliberately pure: no browser, no filesystem, no timers. The staleness rules
// are the highest-risk part of the interaction transport, so they are testable
// on any machine regardless of whether Chromium is installed.

export const LANES = Object.freeze(["content", "capture", "interact", "settle"]);

// `content`, `capture`, and `settle` keep the historical `STALE_RENDER` code so
// existing Lua and existing tests are unaffected. Only `interact` gets the new
// `STALE_INTERACTION` code, which is what lets Lua tell an abandoned pointer
// update apart from an abandoned frame.
const STALE_CODES = Object.freeze({
  content: "STALE_RENDER",
  capture: "STALE_RENDER",
  settle: "STALE_RENDER",
  interact: "STALE_INTERACTION",
});

export function staleCodeForLane(lane) {
  return STALE_CODES[lane] ?? "STALE_RENDER";
}

// Lua sends `contentRevision` as the string "changedtick:epoch"; older tests and
// callers send a number. Compare one normalized form so a "1" from one caller
// and a 1 from another are not treated as different revisions.
export function normalizeRevision(value) {
  return value === undefined || value === null ? null : String(value);
}

export function createLaneError(code, message, detail) {
  const error = new Error(message);
  error.code = code;
  if (detail !== undefined) error.detail = detail;
  return error;
}

export function createLaneRegistry(options = {}) {
  const maxDocuments = Math.max(1, Number(options.maxDocuments) || 64);
  const maxPendingPerLane = Math.max(1, Number(options.maxPendingPerLane) || 64);
  const onEvict = typeof options.onEvict === "function" ? options.onEvict : null;
  const documents = new Map();
  let serial = 0;

  function newRecord() {
    return {
      contentEpoch: 0,
      revision: null,
      lanes: { content: 0, capture: 0, interact: 0, settle: 0 },
      pending: { content: 0, capture: 0, interact: 0, settle: 0 },
    };
  }

  // Map iteration order is insertion order, so delete-then-set is a
  // constant-time LRU refresh.
  function ensureRecord(documentId) {
    const existing = documents.get(documentId);
    if (existing) {
      documents.delete(documentId);
      documents.set(documentId, existing);
      return existing;
    }
    const record = newRecord();
    documents.set(documentId, record);
    while (documents.size > maxDocuments) {
      const oldest = documents.keys().next().value;
      documents.delete(oldest);
      if (onEvict) onEvict(oldest);
    }
    return record;
  }

  // Stamp a request into its lane and return its ticket. MUST be called
  // synchronously, before the caller's first `await`: the readline handler in
  // protocol.js does not await one line before reading the next, so synchronous
  // stamping is what makes arrival order equal supersession order.
  function admit({ documentId, lane, requestId, contentRevision }) {
    if (typeof documentId !== "string" || documentId === "") {
      throw createLaneError("INVALID_REQUEST", "documentId must be a non-empty string");
    }
    if (!LANES.includes(lane)) {
      throw createLaneError("INVALID_REQUEST", `unknown lane: ${lane}; expected one of ${LANES.join(", ")}`);
    }
    const revision = normalizeRevision(contentRevision);
    const record = ensureRecord(documentId);

    if (record.pending[lane] >= maxPendingPerLane) {
      throw createLaneError(
        staleCodeForLane(lane),
        `${lane} lane for ${documentId} is saturated (${maxPendingPerLane} outstanding); dropping this request`,
        { lane, documentId, reason: "overflow" }
      );
    }

    if (lane === "content") {
      // Any render can re-lay-out the page, so every content admission bumps the
      // epoch -- not only those that change the revision. A theme or viewport
      // change at an unchanged revision still invalidates in-flight coordinates.
      record.contentEpoch += 1;
      record.revision = revision;
    } else if (record.revision !== null && revision !== null && revision !== record.revision) {
      // This is the independent per-lane revision verification. It fires here,
      // at admission, where it is reachable and testable -- a caller working
      // from content the renderer has already replaced is rejected before it
      // occupies a queue slot. Drift *during* execution is caught separately by
      // the contentEpoch check in isStale().
      throw createLaneError(
        staleCodeForLane(lane),
        `${lane} request for ${documentId} targets content revision ${revision}, but the renderer holds ${record.revision}`,
        { lane, documentId, reason: "revision_mismatch", expected: record.revision, received: revision }
      );
    }

    serial += 1;
    record.lanes[lane] = serial;
    record.pending[lane] += 1;
    return {
      documentId,
      lane,
      serial,
      requestId,
      contentEpoch: record.contentEpoch,
      contentRevision: revision,
    };
  }

  // Returns null when the ticket is still current, otherwise a detail object
  // describing why it is not. Callers check this at task start AND again after
  // the expensive work, exactly as the previous single-map design did.
  function isStale(ticket) {
    const record = documents.get(ticket.documentId);
    if (!record) {
      return { lane: ticket.lane, documentId: ticket.documentId, reason: "forgotten" };
    }
    if (record.lanes[ticket.lane] !== ticket.serial) {
      return { lane: ticket.lane, documentId: ticket.documentId, reason: "superseded" };
    }
    if (record.contentEpoch !== ticket.contentEpoch) {
      return { lane: ticket.lane, documentId: ticket.documentId, reason: "content_changed" };
    }
    return null;
  }

  function staleError(ticket, detail) {
    return createLaneError(
      staleCodeForLane(ticket.lane),
      `${ticket.lane} request superseded by a newer request`,
      detail
    );
  }

  // Frees the ticket's queue slot for the overflow guard. Safe to call twice and
  // safe to call for a document that has since been evicted.
  function release(ticket) {
    if (!ticket) return;
    const record = documents.get(ticket.documentId);
    if (!record || ticket.released) return;
    ticket.released = true;
    record.pending[ticket.lane] = Math.max(0, record.pending[ticket.lane] - 1);
  }

  function forget(documentId) {
    return documents.delete(documentId);
  }

  function pendingCount(documentId, lane) {
    return documents.get(documentId)?.pending[lane] ?? 0;
  }

  function laneSerial(documentId, lane) {
    return documents.get(documentId)?.lanes[lane] ?? 0;
  }

  function snapshot() {
    const result = {};
    for (const [documentId, record] of documents) {
      result[documentId] = {
        contentEpoch: record.contentEpoch,
        revision: record.revision,
        lanes: { ...record.lanes },
        pending: { ...record.pending },
      };
    }
    return result;
  }

  return {
    admit,
    isStale,
    staleError,
    release,
    forget,
    pendingCount,
    laneSerial,
    snapshot,
    get size() {
      return documents.size;
    },
  };
}
