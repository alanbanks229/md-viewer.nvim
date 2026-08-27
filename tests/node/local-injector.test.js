import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { buildMarkerPayload, parseMarkerPayload, wrapMarker, markerPrefix } from "../../renderer/src/local/markers.js";
import { uploadSequence, deleteImage, chunks, command } from "../../renderer/src/local/kitty-writer.js";
import { Injector } from "../../renderer/src/local/injector.js";

const here = path.dirname(fileURLToPath(import.meta.url));

// These are the rules that keep deferred injection honest, exercised as pure
// event-order tests -- no clocks, no streams, no browser. Each scenario is a
// sequence of acceptMarker/tryInject calls against a scripted resolver, and
// the assertion is always about the exact bytes written and the exact bytes
// withheld. If one of these fails after a change to the injector, the change
// recreated a ghost-frame or blank-pane defect, not a style problem.

const TOKEN = "00112233445566778899aabbccddeeff";

function frameUpload(id, overrides = {}) {
  return { kind: "frame", id, rev: "7:0", scrollY: 120, epoch: 0, widthPx: 800, heightPx: 600, scale: 2, ...overrides };
}

function payload(fields) {
  return buildMarkerPayload({ token: TOKEN, ...fields });
}

function harness({ resolve } = {}) {
  const writes = [];
  let safe = true;
  const injector = new Injector({
    token: TOKEN,
    write: (buf) => writes.push(Buffer.from(buf)),
    resolveUpload: resolve ?? (() => null),
    boundary: () => safe,
  });
  return { injector, writes, setSafe: (value) => (safe = value) };
}

test("marker payloads round-trip through build and parse", () => {
  const built = payload({
    seq: 41,
    doc: "buffer-12",
    uploads: [frameUpload(9), { kind: "sheet", id: 11, tint: "3a7bd5cc", widthPx: 640, heightPx: 480, marginX: 2, marginY: 0 }],
    placements: Buffer.from("\x1b[s\x1b[2;3H\x1b_Ga=p,q=2,C=1,i=9,p=4;\x1b\\\x1b[u", "latin1"),
    deletions: Buffer.from("\x1b_Ga=d,d=i,q=2,i=8,p=3;\x1b\\", "latin1"),
  });
  assert.ok(built.startsWith(markerPrefix(TOKEN)), "the prefix is what the stream parser matches byte-for-byte");
  const parsed = parseMarkerPayload(built);
  assert.equal(parsed.seq, 41);
  assert.equal(parsed.doc, "buffer-12");
  assert.equal(parsed.kill, false);
  assert.equal(parsed.uploads.length, 2);
  assert.deepEqual(parsed.uploads[0], frameUpload(9));
  assert.equal(parsed.uploads[1].tint, "3a7bd5cc");
  assert.equal(parsed.placements.toString("latin1"), "\x1b[s\x1b[2;3H\x1b_Ga=p,q=2,C=1,i=9,p=4;\x1b\\\x1b[u");
  assert.equal(parsed.deletions.toString("latin1"), "\x1b_Ga=d,d=i,q=2,i=8,p=3;\x1b\\");
  // And the whole thing survives its APC framing.
  const wrapped = wrapMarker(built);
  assert.ok(wrapped.subarray(0, 3).equals(Buffer.from("\x1b_M", "latin1")));
  assert.ok(wrapped.subarray(-2).equals(Buffer.from("\x1b\\", "latin1")));
});

test("a document id that needs escaping survives the round trip", () => {
  const built = payload({ seq: 1, doc: "buffer 5;weird\x1b" });
  assert.equal(parseMarkerPayload(built).doc, "buffer 5;weird\x1b");
});

test("a ready surface transaction injects as one write: uploads, placements, deletions", () => {
  const png = Buffer.from("not-really-a-png-but-bytes");
  const { injector, writes } = harness({ resolve: () => png });
  const placements = Buffer.from("\x1b[s\x1b[1;1HPLACE\x1b[u", "latin1");
  const deletions = Buffer.from("\x1b_Ga=d,d=i,q=2,i=3,p=1;\x1b\\", "latin1");
  injector.acceptMarker(payload({ seq: 1, doc: "buffer-1", uploads: [frameUpload(7)], placements, deletions }));
  assert.equal(writes.length, 1, "one transaction is one write");
  const expected = Buffer.concat([Buffer.from(uploadSequence(7, png), "latin1"), placements, deletions]);
  assert.deepEqual(writes[0], expected);
});

test("an unresolvable upload defers, and a later tryInject lands it", () => {
  let ready = false;
  const png = Buffer.from("pixels");
  const { injector, writes } = harness({ resolve: () => (ready ? png : null) });
  injector.acceptMarker(payload({ seq: 1, doc: "buffer-1", uploads: [frameUpload(7)], placements: Buffer.from("P") }));
  assert.equal(writes.length, 0, "nothing to inject while the replica is still rendering");
  injector.tryInject();
  assert.equal(writes.length, 0);
  ready = true;
  injector.tryInject();
  assert.equal(writes.length, 1);
  assert.ok(writes[0].includes("pixels".length === 6 ? Buffer.from(png).toString("base64") : ""), "the upload rode along");
});

test("supersession drops a stale frame's placements but carries its deletions", () => {
  const readiness = new Map();
  const { injector, writes } = harness({ resolve: (upload) => readiness.get(upload.id) ?? null });
  const oldDeletions = Buffer.from("\x1b_Ga=d,d=i,q=2,i=5,p=2;\x1b\\", "latin1");
  injector.acceptMarker(
    payload({ seq: 1, doc: "buffer-1", uploads: [frameUpload(6)], placements: Buffer.from("OLD"), deletions: oldDeletions })
  );
  injector.acceptMarker(
    payload({ seq: 2, doc: "buffer-1", uploads: [frameUpload(8)], placements: Buffer.from("NEW"), deletions: Buffer.from("XNEW") })
  );
  assert.equal(writes.length, 0);
  assert.equal(injector.stats.superseded, 1);

  readiness.set(8, Buffer.from("png8"));
  injector.tryInject();
  assert.equal(writes.length, 1);
  const expected = Buffer.concat([
    Buffer.from(uploadSequence(8, Buffer.from("png8")), "latin1"),
    Buffer.from("NEW"),
    Buffer.from("XNEW"),
    oldDeletions, // carried: appended after the replacing transaction's own deletions
  ]);
  assert.deepEqual(writes[0], expected);
  assert.equal(injector.stats.carriedDeletionBuffers, 1);
});

test("carried deletions are never flushed on their own", () => {
  const { injector, writes } = harness();
  injector.acceptMarker(
    payload({ seq: 1, doc: "buffer-1", uploads: [frameUpload(6)], deletions: Buffer.from("XOLD") })
  );
  injector.acceptMarker(
    payload({ seq: 2, doc: "buffer-1", uploads: [frameUpload(8)], deletions: Buffer.from("XNEW") })
  );
  injector.tryInject();
  injector.tryInject();
  assert.equal(writes.length, 0, "a standalone deletion flush would blank the pane before its replacement exists");
});

test("a kill transaction takes a pending frame down with it, deletions and all", () => {
  const { injector, writes } = harness();
  const frameDeletions = Buffer.from("XFRAME");
  injector.acceptMarker(
    payload({ seq: 5, doc: "buffer-1", uploads: [frameUpload(6)], placements: Buffer.from("PFRAME"), deletions: frameDeletions })
  );
  const hideDeletions = Buffer.from("\x1b_Ga=d,d=i,q=2,i=4,p=9;\x1b\\", "latin1");
  injector.acceptMarker(payload({ seq: 6, doc: "buffer-1", kill: true, deletions: hideDeletions }));
  assert.equal(writes.length, 1, "the hide injects immediately");
  assert.deepEqual(writes[0], Buffer.concat([hideDeletions, frameDeletions]), "pending frame died and its deletions rode along");

  // The frame's pixels becoming renderable later must not resurrect it.
  injector.tryInject();
  assert.equal(writes.length, 1);
});

test("a placement-only transaction neither waits for nor invalidates a pending frame", () => {
  let ready = false;
  const { injector, writes } = harness({ resolve: () => (ready ? Buffer.from("png") : null) });
  injector.acceptMarker(payload({ seq: 5, doc: "buffer-1", uploads: [frameUpload(6)], placements: Buffer.from("PF") }));
  injector.acceptMarker(payload({ seq: 6, doc: "buffer-1", placements: Buffer.from("REPLACE") }));
  assert.equal(writes.length, 1, "the re-place injected without waiting on the render");
  assert.deepEqual(writes[0], Buffer.from("REPLACE"));
  ready = true;
  injector.tryInject();
  assert.equal(writes.length, 2, "the frame still lands -- a re-place is not a supersession");
});

test("a surface transaction older than one already injected is refused, not drawn", () => {
  const { injector, writes } = harness({ resolve: () => Buffer.from("png") });
  injector.acceptMarker(payload({ seq: 7, doc: "buffer-1", uploads: [frameUpload(8)], placements: Buffer.from("P7") }));
  assert.equal(writes.length, 1);
  // A lower-seq surface arriving after a higher one injected: the ordered
  // terminal stream cannot produce this, so it is defense against corruption
  // -- but the defense must hold the deletion-carry line too.
  injector.acceptMarker(
    payload({ seq: 5, doc: "buffer-1", uploads: [frameUpload(6)], placements: Buffer.from("P5"), deletions: Buffer.from("X5") })
  );
  assert.equal(writes.length, 1, "the stale frame did not draw");
  assert.equal(injector.stats.refusedStaleSurface, 1);
  injector.acceptMarker(payload({ seq: 9, doc: "buffer-1", uploads: [frameUpload(10)], placements: Buffer.from("P9") }));
  assert.equal(writes.length, 2);
  assert.ok(writes[1].includes(Buffer.from("X5")), "the refused frame's deletions were carried into the next injection");
});

test("documents are independent: one document's pending frame does not gate another's", () => {
  const readiness = new Map([[20, Buffer.from("pngB")]]);
  const { injector, writes } = harness({ resolve: (upload) => readiness.get(upload.id) ?? null });
  injector.acceptMarker(payload({ seq: 5, doc: "buffer-1", uploads: [frameUpload(10)], placements: Buffer.from("PA") }));
  injector.acceptMarker(payload({ seq: 6, doc: "buffer-2", uploads: [frameUpload(20)], placements: Buffer.from("PB") }));
  assert.equal(writes.length, 1, "buffer-2 injected while buffer-1 renders");
  readiness.set(10, Buffer.from("pngA"));
  injector.tryInject();
  assert.equal(writes.length, 2, "buffer-1's frame is not stale merely because buffer-2 moved on");
});

test("everything injectable at one boundary goes out in seq order, carried attached to the first", () => {
  const { injector, writes, setSafe } = harness({ resolve: () => Buffer.from("png") });
  setSafe(false);
  injector.acceptMarker(payload({ seq: 3, doc: "buffer-2", placements: Buffer.from("IMMEDIATE-3") }));
  injector.acceptMarker(
    payload({ seq: 1, doc: "buffer-1", uploads: [frameUpload(6)], placements: Buffer.from("SURF-1"), deletions: Buffer.from("X1") })
  );
  injector.acceptMarker(
    payload({ seq: 2, doc: "buffer-1", uploads: [frameUpload(8)], placements: Buffer.from("SURF-2") })
  );
  assert.equal(writes.length, 0, "no boundary, no writes");
  setSafe(true);
  injector.tryInject();
  assert.equal(writes.length, 2);
  assert.ok(writes[0].includes(Buffer.from("SURF-2")), "seq 2 first");
  assert.ok(writes[0].includes(Buffer.from("X1")), "superseded seq-1 deletions carried into the first write of the drain");
  assert.deepEqual(writes[1], Buffer.from("IMMEDIATE-3"));
});

test("teardown returns carried deletions plus a targeted delete for every uploaded id", () => {
  const { injector, writes } = harness({ resolve: () => Buffer.from("png") });
  injector.acceptMarker(payload({ seq: 1, doc: "buffer-1", uploads: [frameUpload(6)], placements: Buffer.from("P1") }));
  injector.acceptMarker(
    payload({ seq: 2, doc: "buffer-1", uploads: [frameUpload(8)], placements: Buffer.from("P2"), deletions: Buffer.from("X2") })
  );
  assert.equal(writes.length, 2);
  // Leave something carried behind: a superseded pending frame with deletions.
  const gate = new Map();
  injector.resolveUpload = (upload) => gate.get(upload.id) ?? null;
  injector.acceptMarker(
    payload({ seq: 3, doc: "buffer-1", uploads: [frameUpload(9)], deletions: Buffer.from("X3") })
  );
  injector.acceptMarker(payload({ seq: 4, doc: "buffer-1", uploads: [frameUpload(11)], deletions: Buffer.from("X4") }));
  const bytes = injector.teardown();
  assert.ok(bytes.includes(Buffer.from("X3")), "carried deletions flush at teardown");
  assert.ok(bytes.includes(Buffer.from(deleteImage(6), "latin1")));
  assert.ok(bytes.includes(Buffer.from(deleteImage(8), "latin1")));
  assert.ok(!bytes.includes(Buffer.from(deleteImage(11), "latin1")), "never-uploaded ids have nothing to delete");
});

test("malformed payloads and token mismatches are counted and dropped, never guessed at", () => {
  const { injector, writes } = harness();
  injector.acceptMarker("v=1;t=beef;s=nope");
  injector.acceptMarker(buildMarkerPayload({ token: "f".repeat(32), seq: 1, doc: "buffer-1" }));
  assert.equal(writes.length, 0);
  assert.equal(injector.stats.malformed, 1);
  assert.equal(injector.stats.tokenMismatch, 1);
});

test("the chunker port matches its own documented framing", () => {
  // 6120 bytes of payload -> 8160 base64 chars -> a 4096 chunk then 4064.
  const png = Buffer.alloc(6120, 0xab);
  const stream = uploadSequence(31, png);
  const encoded = png.toString("base64");
  assert.equal(
    stream,
    command(`a=t,f=100,t=d,q=2,i=31,m=1`, encoded.slice(0, 4096)) + command("q=2,m=0", encoded.slice(4096))
  );
  const single = uploadSequence(31, Buffer.from("tiny"));
  assert.equal(single, command("a=t,f=100,t=d,q=2,i=31,m=0", Buffer.from("tiny").toString("base64")));
  assert.equal(chunks("", "a=t"), "", "an empty payload emits nothing, exactly like the Lua original");
});

test("the JS chunker reproduces the real Lua chunker byte-for-byte", () => {
  // The fixture is dumped from `kitty_raw.lua`'s own `upload_sequence` by
  // `scripts/local/dump-upload-golden.lua`. If this fails, one of the two
  // implementations drifted; regenerate the fixture only when the *Lua* side
  // changed deliberately, and fix the JS side otherwise.
  const fixture = JSON.parse(fs.readFileSync(path.join(here, "../fixtures/local-upload-golden.json"), "utf8"));
  assert.ok(fixture.cases.length >= 4, "the fixture covers the chunk-boundary cases");
  for (const { id, input_b64, expected_b64 } of fixture.cases) {
    const produced = Buffer.from(uploadSequence(id, Buffer.from(input_b64, "base64")), "latin1");
    assert.deepEqual(produced, Buffer.from(expected_b64, "base64"), `id ${id} diverged from the Lua chunker`);
  }
});

test("K4: frame time-to-inject is sampled for landed frames and never for superseded ones", () => {
  // A virtual clock measures the measurement: the sample must cover marker
  // arrival to transaction write for exactly the frames that reached the
  // terminal. A superseded frame is not late -- it is gone -- and letting it
  // into the distribution would understate the lag a user actually saw.
  let clock = 1000;
  const writes = [];
  let resolvable = false;
  const injector = new Injector({
    token: TOKEN,
    write: (buf) => writes.push(Buffer.from(buf)),
    resolveUpload: () => (resolvable ? Buffer.from("PNGBYTES") : null),
    boundary: () => true,
    now: () => clock,
  });

  assert.equal(injector.timingSnapshot().frameTimeToInject, null, "no samples before any frame lands");

  // seq 1 arrives, defers (surface not rendered), and is superseded by seq 2.
  injector.acceptMarker(payload({ seq: 1, doc: "buffer-1", uploads: [frameUpload(7)], placements: Buffer.from("P1") }));
  clock = 1010;
  injector.acceptMarker(payload({ seq: 2, doc: "buffer-1", uploads: [frameUpload(8)], placements: Buffer.from("P2") }));
  clock = 1052;
  resolvable = true;
  injector.tryInject();

  const snap = injector.timingSnapshot().frameTimeToInject;
  assert.equal(snap.count, 1, "one frame landed, one sample -- the superseded frame contributed nothing");
  assert.equal(snap.p50Ms, 42, "arrival at 1010, injected at 1052");
  assert.equal(snap.maxMs, 42);

  // A placement-only transaction is not a frame and takes no sample.
  clock = 2000;
  injector.acceptMarker(payload({ seq: 3, doc: "buffer-1", placements: Buffer.from("MOVE") }));
  assert.equal(injector.timingSnapshot().frameTimeToInject.count, 1);
});
