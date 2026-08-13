import test from "node:test";
import assert from "node:assert/strict";
import { createLaneRegistry, staleCodeForLane, normalizeRevision, LANES } from "../../renderer/src/lanes.js";

// These tests need no browser and no subprocess: the staleness rules are the
// highest-risk part of the interaction transport, so they must be verifiable on
// any machine regardless of whether Chromium is installed.

const DOC = "buffer-7";

function render(lanes, requestId, contentRevision) {
  return lanes.admit({ documentId: DOC, lane: "content", requestId, contentRevision });
}

test("a newer request supersedes an older one within its own lane", () => {
  const lanes = createLaneRegistry();
  const first = render(lanes, 1, "1:0");
  assert.equal(lanes.isStale(first), null);
  const second = render(lanes, 2, "2:0");
  assert.equal(lanes.isStale(first).reason, "superseded");
  assert.equal(lanes.isStale(second), null);
  assert.equal(staleCodeForLane("content"), "STALE_RENDER");
});

test("an interaction never cancels a render, a capture, or a settled frame", () => {
  const lanes = createLaneRegistry();
  const content = render(lanes, 1, "1:0");
  const capture = lanes.admit({ documentId: DOC, lane: "capture", requestId: 2, contentRevision: "1:0" });
  const settle = lanes.admit({ documentId: DOC, lane: "settle", requestId: 3, contentRevision: "1:0" });

  const contentSerial = lanes.laneSerial(DOC, "content");
  const captureSerial = lanes.laneSerial(DOC, "capture");
  const settleSerial = lanes.laneSerial(DOC, "settle");

  // A drag: many interactions, arriving faster than anything can drain them.
  let newest;
  for (let index = 0; index < 200; index += 1) {
    newest = lanes.admit({ documentId: DOC, lane: "interact", requestId: 100 + index, contentRevision: "1:0" });
    lanes.release(newest);
  }

  // The other three lanes' serials are untouched, not merely still-valid.
  assert.equal(lanes.laneSerial(DOC, "content"), contentSerial);
  assert.equal(lanes.laneSerial(DOC, "capture"), captureSerial);
  assert.equal(lanes.laneSerial(DOC, "settle"), settleSerial);
  assert.equal(lanes.isStale(content), null);
  assert.equal(lanes.isStale(capture), null);
  assert.equal(lanes.isStale(settle), null);
  assert.equal(lanes.isStale(newest), null);
});

test("a newer drag point supersedes an older drag point", () => {
  const lanes = createLaneRegistry();
  render(lanes, 1, "1:0");
  const older = lanes.admit({ documentId: DOC, lane: "interact", requestId: 2, contentRevision: "1:0" });
  const newer = lanes.admit({ documentId: DOC, lane: "interact", requestId: 3, contentRevision: "1:0" });
  assert.equal(lanes.isStale(older).reason, "superseded");
  assert.equal(lanes.isStale(newer), null);
  assert.equal(staleCodeForLane("interact"), "STALE_INTERACTION");
});

test("a capture no longer cancels a queued render", () => {
  // Behaviour change from parts 1-2, where both wrote one shared map.
  const lanes = createLaneRegistry();
  const content = render(lanes, 1, "1:0");
  lanes.admit({ documentId: DOC, lane: "capture", requestId: 2, contentRevision: "1:0" });
  lanes.admit({ documentId: DOC, lane: "settle", requestId: 3, contentRevision: "1:0" });
  assert.equal(lanes.isStale(content), null);
});

test("a newer content render invalidates every downstream lane", () => {
  const lanes = createLaneRegistry();
  render(lanes, 1, "1:0");
  const capture = lanes.admit({ documentId: DOC, lane: "capture", requestId: 2, contentRevision: "1:0" });
  const interact = lanes.admit({ documentId: DOC, lane: "interact", requestId: 3, contentRevision: "1:0" });
  const settle = lanes.admit({ documentId: DOC, lane: "settle", requestId: 4, contentRevision: "1:0" });

  render(lanes, 5, "2:0");

  assert.equal(lanes.isStale(capture).reason, "content_changed");
  assert.equal(lanes.isStale(interact).reason, "content_changed");
  assert.equal(lanes.isStale(settle).reason, "content_changed");
});

test("a re-render at an unchanged revision still invalidates outstanding interactions", () => {
  // A theme or viewport change re-lays-out the page without changing the
  // revision. In-flight coordinates are just as invalid as after an edit.
  const lanes = createLaneRegistry();
  render(lanes, 1, "1:0");
  const interact = lanes.admit({ documentId: DOC, lane: "interact", requestId: 2, contentRevision: "1:0" });
  render(lanes, 3, "1:0");
  assert.equal(lanes.isStale(interact).reason, "content_changed");
});

test("each lane verifies contentRevision independently at admission", () => {
  const lanes = createLaneRegistry();
  render(lanes, 1, "5:0");
  for (const lane of ["capture", "interact", "settle"]) {
    assert.throws(
      () => lanes.admit({ documentId: DOC, lane, requestId: 9, contentRevision: "4:0" }),
      (error) => {
        assert.equal(error.code, staleCodeForLane(lane));
        assert.equal(error.detail.reason, "revision_mismatch");
        assert.equal(error.detail.expected, "5:0");
        assert.equal(error.detail.received, "4:0");
        return true;
      },
      `${lane} lane accepted a stale contentRevision`
    );
  }
  // ...and the interact rejection is distinguishable from a render's.
  assert.equal(staleCodeForLane("interact"), "STALE_INTERACTION");
  assert.notEqual(staleCodeForLane("interact"), staleCodeForLane("content"));
});

test("revisions compare by normalized form, so 1 and \"1\" are the same revision", () => {
  const lanes = createLaneRegistry();
  render(lanes, 1, 1);
  assert.doesNotThrow(() => lanes.admit({ documentId: DOC, lane: "capture", requestId: 2, contentRevision: "1" }));
  assert.equal(normalizeRevision(1), "1");
  assert.equal(normalizeRevision(null), null);
  assert.equal(normalizeRevision(undefined), null);
});

test("a capture before any render is admitted, leaving the cache-miss path to the browser layer", () => {
  // Lua relies on the renderer answering CAPTURE_CACHE_MISS here so it can
  // retry with a full render; a lane-level rejection would break that retry.
  const lanes = createLaneRegistry();
  assert.doesNotThrow(() => lanes.admit({ documentId: DOC, lane: "capture", requestId: 1, contentRevision: "1:0" }));
});

test("documents are isolated from each other", () => {
  const lanes = createLaneRegistry();
  const a = lanes.admit({ documentId: "buffer-1", lane: "content", requestId: 1, contentRevision: "1:0" });
  const b = lanes.admit({ documentId: "buffer-2", lane: "content", requestId: 2, contentRevision: "9:0" });
  lanes.admit({ documentId: "buffer-2", lane: "content", requestId: 3, contentRevision: "10:0" });
  assert.equal(lanes.isStale(a), null, "document A was invalidated by document B's render");
  assert.equal(lanes.isStale(b).reason, "superseded");
});

test("the overflow guard rejects a saturated lane instead of queueing without bound", () => {
  const lanes = createLaneRegistry({ maxPendingPerLane: 3 });
  render(lanes, 1, "1:0");
  for (let index = 0; index < 3; index += 1) {
    lanes.admit({ documentId: DOC, lane: "interact", requestId: 10 + index, contentRevision: "1:0" });
  }
  assert.equal(lanes.pendingCount(DOC, "interact"), 3);
  assert.throws(
    () => lanes.admit({ documentId: DOC, lane: "interact", requestId: 99, contentRevision: "1:0" }),
    (error) => {
      assert.equal(error.code, "STALE_INTERACTION");
      assert.equal(error.detail.reason, "overflow");
      return true;
    }
  );
  // A saturated interact lane must not block a render.
  assert.doesNotThrow(() => render(lanes, 100, "2:0"));
});

test("release frees a queue slot exactly once", () => {
  const lanes = createLaneRegistry();
  const ticket = lanes.admit({ documentId: DOC, lane: "interact", requestId: 1, contentRevision: "1:0" });
  assert.equal(lanes.pendingCount(DOC, "interact"), 1);
  lanes.release(ticket);
  lanes.release(ticket);
  assert.equal(lanes.pendingCount(DOC, "interact"), 0);
});

test("least-recently-used documents are evicted and reported", () => {
  const evicted = [];
  const lanes = createLaneRegistry({ maxDocuments: 2, onEvict: (id) => evicted.push(id) });
  lanes.admit({ documentId: "a", lane: "content", requestId: 1, contentRevision: "1" });
  lanes.admit({ documentId: "b", lane: "content", requestId: 2, contentRevision: "1" });
  lanes.admit({ documentId: "a", lane: "capture", requestId: 3, contentRevision: "1" }); // refreshes a
  lanes.admit({ documentId: "c", lane: "content", requestId: 4, contentRevision: "1" });
  assert.deepEqual(evicted, ["b"]);
  assert.equal(lanes.size, 2);
});

test("a ticket for a forgotten document is stale rather than silently valid", () => {
  const lanes = createLaneRegistry();
  const ticket = render(lanes, 1, "1:0");
  lanes.forget(DOC);
  assert.equal(lanes.isStale(ticket).reason, "forgotten");
});

test("rejects an unknown lane and a missing documentId", () => {
  const lanes = createLaneRegistry();
  assert.throws(() => lanes.admit({ documentId: DOC, lane: "nope", requestId: 1 }), /unknown lane/);
  assert.throws(() => lanes.admit({ documentId: "", lane: "content", requestId: 1 }), /non-empty string/);
  assert.deepEqual([...LANES], ["content", "capture", "interact", "settle"]);
});

// ---------------------------------------------------------------------------
// Pipelined admissions.
//
// Supersession is right when the renderer is a pipe away and wrong across a
// link: it holds the pipeline to one frame per round trip, which on the
// connection this was built for is 92ms of the 107ms it takes to show a frame.
// What must survive is the guarantee that actually protects correctness -- a
// content change invalidates everything in flight, because those frames
// describe a layout that no longer exists.
// ---------------------------------------------------------------------------

function pipelinedCapture(lanes, requestId, contentRevision = "1:0") {
  return lanes.admit({ documentId: DOC, lane: "capture", requestId, contentRevision, pipelined: true });
}

test("pipelined captures do not cancel each other", () => {
  const lanes = createLaneRegistry();
  render(lanes, 1, "1:0");
  const first = pipelinedCapture(lanes, 2);
  const second = pipelinedCapture(lanes, 3);
  const third = pipelinedCapture(lanes, 4);
  for (const ticket of [first, second, third]) {
    assert.equal(lanes.isStale(ticket), null, "every position in flight is one the caller intends to display");
  }
});

test("a content change still invalidates every pipelined capture in flight", () => {
  // The guarantee the whole exemption rests on. These frames describe a layout
  // that no longer exists; rendering them would draw the wrong document.
  const lanes = createLaneRegistry();
  render(lanes, 1, "1:0");
  const inFlight = [pipelinedCapture(lanes, 2), pipelinedCapture(lanes, 3)];
  render(lanes, 4, "2:0");
  for (const ticket of inFlight) {
    assert.equal(lanes.isStale(ticket).reason, "content_changed");
  }
});

test("a re-render at an unchanged revision also invalidates pipelined captures", () => {
  // A resize or a theme change re-lays-out the page without changing the
  // revision, and the coordinates in flight are measured against the old one.
  const lanes = createLaneRegistry();
  render(lanes, 1, "1:0");
  const inFlight = pipelinedCapture(lanes, 2);
  render(lanes, 3, "1:0");
  assert.equal(lanes.isStale(inFlight).reason, "content_changed");
});

test("a non-pipelined capture still supersedes, including pipelined ones", () => {
  // The settle capture and every local session take this path, so it has to
  // keep behaving exactly as it did. A claiming request takes the lane, which
  // strands the pipelined tickets that were counting on it not to.
  const lanes = createLaneRegistry();
  render(lanes, 1, "1:0");
  const pipelined = pipelinedCapture(lanes, 2);
  const claiming = lanes.admit({ documentId: DOC, lane: "capture", requestId: 3, contentRevision: "1:0" });
  assert.equal(lanes.isStale(pipelined).reason, "superseded");
  assert.equal(lanes.isStale(claiming), null);
});

test("pipelining cannot be used to bypass the revision check or the overflow guard", () => {
  const lanes = createLaneRegistry({ maxPendingPerLane: 2 });
  render(lanes, 1, "1:0");
  assert.throws(
    () => pipelinedCapture(lanes, 2, "9:0"),
    (error) => error.detail.reason === "revision_mismatch"
  );
  pipelinedCapture(lanes, 3);
  pipelinedCapture(lanes, 4);
  assert.throws(
    () => pipelinedCapture(lanes, 5),
    (error) => error.detail.reason === "overflow",
    "a caller that forgets to bound its own depth is refused, not allowed to queue without end"
  );
});

test("a render is never pipelined, whatever the request says", () => {
  // Asking for it would let two renders be in flight with neither cancelling
  // the other, and the second's layout would be built on top of the first's.
  const lanes = createLaneRegistry();
  const first = lanes.admit({ documentId: DOC, lane: "content", requestId: 1, contentRevision: "1:0", pipelined: true });
  const second = lanes.admit({ documentId: DOC, lane: "content", requestId: 2, contentRevision: "2:0", pipelined: true });
  assert.equal(first.claims, true);
  assert.equal(lanes.isStale(first).reason, "superseded");
  assert.equal(lanes.isStale(second), null);
});
