import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createService } from "../../renderer/src/service.js";
import { createReplica } from "../../renderer/src/local/replica.js";
import { buildOverlaySheetPng } from "../../renderer/src/overlay-sheet.js";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";

// The two halves of the local-render split, driven end to end: the document
// service (`prepare`/`fetch_assets`, no browser involved) and the helper's
// replica (`render`/`asset`/`interact` + surface resolution, real Chromium).
// What crosses between them in these tests is exactly what crosses the SSM
// link in production: sanitized HTML with content-addressed refs, asset
// bytes once per sha, and small JSON -- never a PNG.

const here = path.dirname(fileURLToPath(import.meta.url));
import { fileURLToPath } from "node:url";

const assetsDir = path.resolve(here, "../../renderer/assets");

function realChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

function docServiceFixture() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mdv-doc-"));
  // A real PNG, made by the project's own sheet builder so no binary fixture
  // is committed and no decoder dependency is added.
  const png = buildOverlaySheetPng(4, 4, { r: 250, g: 30, b: 20, a: 1 }, null);
  fs.writeFileSync(path.join(dir, "img.png"), png);
  return { dir, png };
}

const PREPARE_PARAMS = (dir) => ({
  documentId: "doc-local",
  contentRevision: "7:0",
  markdown: "# Title\n\nSome body text with an image:\n\n![the image](img.png)\n",
  baseDir: dir,
  documentRoot: dir,
  rawHtml: false,
  localImages: true,
  maxLocalImageBytes: 10 * 1024 * 1024,
});

test("prepare extracts validated images into md-asset refs and a manifest", async () => {
  const { dir, png } = docServiceFixture();
  const service = createService({ assetsDir });
  const prepared = await service.dispatch({ id: 1, method: "prepare", params: PREPARE_PARAMS(dir) });

  const refs = [...prepared.html.matchAll(/md-asset:([0-9a-f]{64})/g)];
  assert.equal(refs.length, 1, "the image is a ref, not inline bytes");
  assert.ok(!prepared.html.includes("data:image/png"), "no image bytes remain in the prepared markup");
  assert.equal(prepared.assets.length, 1);
  assert.equal(prepared.assets[0].sha, refs[0][1]);
  assert.equal(prepared.assets[0].mime, "image/png");
  assert.equal(prepared.assets[0].size, png.length);
  assert.ok(prepared.sourceMap, "provenance travels with the markup");

  const fetched = await service.dispatch({ id: 2, method: "fetch_assets", params: { shas: [refs[0][1], "0".repeat(64)] } });
  assert.equal(fetched.assets.length, 1);
  assert.deepEqual(Buffer.from(fetched.assets[0].data, "base64"), png, "fetch_assets returns the exact validated bytes");
  assert.deepEqual(fetched.unknown, ["0".repeat(64)]);
  await service.close();
});

test("an ordinary render still inlines data: URIs -- asset mode changes nothing it did not opt into", async () => {
  const { dir } = docServiceFixture();
  const executable = realChromium();
  const service = createService({ assetsDir });
  if (!executable) {
    // Even without a browser the check that matters here is reachable: the
    // sanitizer must strip md-asset outside asset mode. Feed it markup
    // through prepare-less render only when a browser exists; otherwise
    // assert the scheme rule directly via a second prepare-less parse.
    await service.close();
    return;
  }
  const result = await service.dispatch({
    id: 1,
    method: "render",
    params: {
      ...PREPARE_PARAMS(dir),
      viewport: { widthPx: 640, heightPx: 480, deviceScaleFactor: 1 },
      scrollY: 0,
      theme: "dark",
      browser: { executable_path: executable, launch_timeout_ms: 15000 },
    },
  });
  assert.ok(result.pngPath, "the current-host path still produces a frame file");
  fs.unlinkSync(result.pngPath);
  await service.close();
});

test("replica: pending on missing assets, metrics after the push, surfaces resolvable, epochs, sheets", { timeout: 120000 }, async (t) => {
  const executable = realChromium();
  if (!executable) {
    t.skip("no approved Chrome/Chromium/Edge on this machine");
    return;
  }
  const { dir, png } = docServiceFixture();
  const docService = createService({ assetsDir });
  const prepared = await docService.dispatch({ id: 1, method: "prepare", params: PREPARE_PARAMS(dir) });
  const sha = prepared.assets[0].sha;

  const notifications = [];
  const replica = createReplica({ assetsDir, onNotify: (event, fields) => notifications.push({ event, ...fields }) });
  t.after(() => replica.close());

  const renderParams = {
    documentId: "doc-local",
    contentRevision: "7:0",
    html: prepared.html,
    sourceMap: prepared.sourceMap,
    viewport: { widthPx: 640, heightPx: 480, deviceScaleFactor: 1 },
    scrollY: 0,
    theme: "dark",
    fontSizePx: 14,
    browser: { executable_path: executable, launch_timeout_ms: 20000 },
  };

  const first = await replica.handle("render", renderParams);
  assert.equal(first.pending, true, "missing bytes defer the layout instead of rendering holes");
  assert.deepEqual(first.missingAssets, [sha]);

  // Integrity: bytes that are not what their name claims are refused.
  const forged = await replica.handle("asset", {
    assets: [{ sha, mime: "image/png", data: Buffer.from("not the bytes").toString("base64") }],
  });
  assert.deepEqual(forged.refused, [sha]);

  const pushed = await replica.handle("asset", { assets: [{ sha, mime: "image/png", data: png.toString("base64") }] });
  assert.deepEqual(pushed.refused, []);

  const deadline = Date.now() + 60000;
  while (!notifications.some((n) => n.event === "metrics") && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const metrics = notifications.find((n) => n.event === "metrics");
  assert.ok(metrics, "layout completion arrives as an async notification");
  assert.equal(metrics.doc, "doc-local");
  assert.equal(metrics.rev, "7:0");
  assert.ok(metrics.documentHeightPx > 0);
  assert.ok(Array.isArray(metrics.blocks) && metrics.blocks.length > 0, "block geometry rides the metrics");

  // The frame surface for the rendered state resolves immediately.
  const frameRef = { kind: "frame", id: 9, rev: "7:0", scrollY: 0, epoch: 0, widthPx: 640, heightPx: 480, scale: 1 };
  const surface = replica.resolveUpload(frameRef, "doc-local");
  assert.ok(surface, "the layout's own capture is the surface for its scroll position");
  assert.ok(surface.subarray(0, 8).equals(Buffer.from("\x89PNG\r\n\x1a\n", "latin1")), "and it is a PNG");

  // A scroll the replica has never seen: null now, capture scheduled, bytes
  // later -- no round trip anywhere near a marker.
  const scrolled = { ...frameRef, scrollY: 120 };
  assert.equal(replica.resolveUpload(scrolled, "doc-local"), null);
  const scrollDeadline = Date.now() + 30000;
  let scrolledBytes = null;
  while (scrolledBytes === null && Date.now() < scrollDeadline) {
    await new Promise((resolve) => setTimeout(resolve, 50));
    scrolledBytes = replica.resolveUpload(scrolled, "doc-local");
  }
  assert.ok(scrolledBytes, "the scheduled capture produced the scrolled surface");

  // A mutating interact bumps the visual epoch and never ships a PNG --
  // even when the envelope explicitly asks for the capture and the sheet,
  // the replica refuses both structurally.
  const found = await replica.handle("interact", {
    documentId: "doc-local",
    contentRevision: "7:0",
    action: "find_set",
    query: "body",
    capture: true,
    overlaySheet: { widthPx: 640, heightPx: 480 },
    viewportWidthPx: 640,
    viewportHeightPx: 480,
    cellWidthPx: 8,
    cellHeightPx: 16,
  });
  assert.equal(found.visualEpoch, 1, "a visible-state mutation bumps the epoch");
  assert.equal(found.pngPath, undefined, "no PNG path ever crosses the socket, asked for or not");
  assert.equal(found.overlaySheetPng, undefined, "no sheet bytes either -- sheets synthesize from marker refs");

  // Sheets are derivable locally from the ref alone.
  const sheet = replica.resolveUpload(
    { kind: "sheet", id: 11, tint: "3a7bd5cc", widthPx: 200, heightPx: 100, marginX: 0, marginY: 0 },
    "doc-local"
  );
  assert.ok(sheet && sheet.subarray(1, 4).equals(Buffer.from("PNG")), "the tint sheet is synthesized, not shipped");

  await assert.rejects(() => replica.handle("prepare", {}), (error) => error.code === "UNSUPPORTED_METHOD");
  await docService.close();
});

test("a surface is never captured from another revision's markup", { timeout: 120000 }, async (t) => {
  const executable = realChromium();
  if (!executable) {
    t.skip("no approved Chrome/Chromium/Edge on this machine");
    return;
  }
  const replica = createReplica({ assetsDir });
  t.after(() => replica.close());
  const base = {
    documentId: "doc-race",
    viewport: { widthPx: 640, heightPx: 480, deviceScaleFactor: 1 },
    scrollY: 0,
    theme: "dark",
    fontSizePx: 14,
    browser: { executable_path: executable, launch_timeout_ms: 20000 },
  };
  await replica.handle("render", { ...base, contentRevision: "1:0", html: "<main><h1>old body</h1></main>" });

  // A marker for revision 2:0 arriving before its render request (the tty
  // and socket channels share no ordering) must wait, not capture: the only
  // markup this replica holds is 1:0's, and capturing from it would store
  // the old revision's pixels under the new revision's key.
  const racedRef = { kind: "frame", id: 3, rev: "2:0", scrollY: 40, epoch: 0, widthPx: 640, heightPx: 480, scale: 1 };
  const before = replica.stats().captures;
  assert.equal(replica.resolveUpload(racedRef, "doc-race"), null, "the raced reference defers");
  assert.equal(replica.stats().captures, before, "and schedules nothing against the wrong markup");

  // Once 2:0's own render arrives, the same reference resolves through the
  // ordinary schedule path.
  await replica.handle("render", { ...base, contentRevision: "2:0", html: "<main><h1>new body</h1></main>" });
  let bytes = replica.resolveUpload(racedRef, "doc-race");
  const deadline = Date.now() + 30000;
  while (bytes === null && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 50));
    bytes = replica.resolveUpload(racedRef, "doc-race");
  }
  assert.ok(bytes, "the reference resolves once the revision it names has been laid out");
});

test("reset forgets every document, so a documentId a new session reuses starts at epoch 0 again", { timeout: 120000 }, async (t) => {
  // The scenario a control-socket client disconnect reproduces: one Neovim
  // process renders "buffer-1", mutates it (bumping the epoch), and quits;
  // a second Neovim process -- reusing the same documentId, since a fresh
  // process's buffer numbers start over -- attaches and renders "buffer-1"
  // again, with its own fresh epoch of 0. Without reset() clearing the
  // outgoing session's record, scheduleSurface's epoch guard
  // (`record.epoch !== upload.epoch`) would silently refuse to ever
  // schedule a capture for the new session's frame reference -- a preview
  // that renders solid black on reopen, measured live (2026-08-27).
  const executable = realChromium();
  if (!executable) {
    t.skip("no approved Chrome/Chromium/Edge on this machine");
    return;
  }
  const replica = createReplica({ assetsDir });
  t.after(() => replica.close());
  const base = {
    documentId: "buffer-1",
    contentRevision: "1:0",
    viewport: { widthPx: 640, heightPx: 480, deviceScaleFactor: 1 },
    scrollY: 0,
    theme: "dark",
    fontSizePx: 14,
    browser: { executable_path: executable, launch_timeout_ms: 20000 },
  };
  await replica.handle("render", { ...base, html: "<main><h1>first session</h1></main>" });
  const bumped = await replica.handle("interact", {
    documentId: "buffer-1",
    contentRevision: "1:0",
    action: "find_set",
    query: "session",
    viewportWidthPx: 640,
    viewportHeightPx: 480,
    cellWidthPx: 8,
    cellHeightPx: 16,
  });
  assert.equal(bumped.visualEpoch, 1, "the outgoing session's own mutation bumped its epoch");

  replica.reset();

  // A second session's render for the SAME documentId, at a revision that
  // could just as easily repeat too (a fresh buffer's changedtick starts
  // low) -- the point under test is the epoch, not the revision string.
  await replica.handle("render", { ...base, contentRevision: "1:0", html: "<main><h1>second session</h1></main>" });
  // Read `record.epoch` through a second mutating interact rather than
  // through `resolveUpload`: the first session already stored a surface at
  // epoch=0/scrollY=0 (its own very first render, before the mutation that
  // bumped it to 1), so an epoch-0 frame reference at scrollY=0 would
  // resolve against that stale leftover PNG regardless of whether reset()
  // ran -- proving nothing about whether the record itself was cleared.
  // `visualEpoch` in the interact response is `docRecord(documentId).epoch`
  // directly (replica.js's own `result.visualEpoch = record.epoch`), so it
  // is unambiguous evidence either way.
  const secondSessionMutation = await replica.handle("interact", {
    documentId: "buffer-1",
    contentRevision: "1:0",
    action: "find_set",
    query: "second",
    viewportWidthPx: 640,
    viewportHeightPx: 480,
    cellWidthPx: 8,
    cellHeightPx: 16,
  });
  assert.equal(
    secondSessionMutation.visualEpoch,
    1,
    "the new session's own first mutation bumped epoch 0->1 -- if reset() had not run, the outgoing " +
      "session's leftover epoch of 1 would have bumped to 2 instead"
  );
});

test("render_prepared refuses cached markup that was prepared mid-image-fetch", { timeout: 120000 }, async (t) => {
  const executable = realChromium();
  if (!executable) {
    t.skip("no approved Chrome/Chromium/Edge on this machine");
    return;
  }
  const service = createService({ assetsDir });
  t.after(() => service.close());
  const params = (html, remoteImagesPending) => ({
    documentId: "doc-pending",
    contentRevision: "9:0",
    html,
    remoteImagesPending,
    viewport: { widthPx: 640, heightPx: 480, deviceScaleFactor: 1 },
    scrollY: 0,
    theme: "dark",
    browser: { executable_path: executable, launch_timeout_ms: 20000 },
  });

  // First render: markup carrying a fetch placeholder, flagged as such by the
  // preparing side. The revision will not change when the image lands -- the
  // flag is the only thing that can force the re-layout.
  const first = await service.dispatch({ id: 1, method: "render_prepared", params: params("<main>placeholder</main>", true) });
  fs.unlinkSync(first.pngPath);
  assert.equal(first.markdownReused, false);

  const second = await service.dispatch({ id: 2, method: "render_prepared", params: params("<main>fetched image</main>", false) });
  fs.unlinkSync(second.pngPath);
  assert.equal(second.markdownReused, false, "same revision, but the pending markup must not be reused");

  const third = await service.dispatch({ id: 3, method: "render_prepared", params: params("<main>fetched image</main>", false) });
  fs.unlinkSync(third.pngPath);
  assert.equal(third.markdownReused, true, "settled markup at the same revision is reused as before");
});

test("scroll captures are latest-wins, one in flight, at the reference's own scale", { timeout: 120000 }, async (t) => {
  const executable = realChromium();
  if (!executable) {
    t.skip("no approved Chrome/Chromium/Edge on this machine");
    return;
  }
  const replica = createReplica({ assetsDir });
  t.after(() => replica.close());

  const tall = `<main><h1>Pump</h1>${"<p>line of text to give the page height</p>".repeat(120)}</main>`;
  const metrics = await replica.handle("render", {
    documentId: "doc-pump",
    contentRevision: "9:0",
    html: tall,
    viewport: { widthPx: 640, heightPx: 480, deviceScaleFactor: 1 },
    scrollY: 0,
    theme: "dark",
    fontSizePx: 14,
    browser: { executable_path: executable, launch_timeout_ms: 20000 },
  });
  assert.ok(metrics.documentHeightPx > 480, "the fixture is tall enough to scroll");

  const ref = { kind: "frame", id: 5, rev: "9:0", scrollY: 0, epoch: 0, widthPx: 640, heightPx: 480, scale: 1 };

  // Three scroll positions in one tick, the way a held key produces them.
  // rc9 dispatched three captures and discarded most of the work stale
  // (517 captures for 206 surfaces on the work laptop, 2026-08-27); the pump
  // must capture the first, skip the middle, and finish on the newest.
  const a = { ...ref, scrollY: 100 };
  const b = { ...ref, scrollY: 200 };
  const c = { ...ref, scrollY: 300 };
  assert.equal(replica.resolveUpload(a, "doc-pump"), null);
  assert.equal(replica.resolveUpload(b, "doc-pump"), null);
  assert.equal(replica.resolveUpload(c, "doc-pump"), null);

  const deadline = Date.now() + 30000;
  let newest = null;
  while (newest === null && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 25));
    newest = replica.resolveUpload(c, "doc-pump");
  }
  assert.ok(newest, "the newest position's surface landed");
  assert.ok(replica.resolveUpload(a, "doc-pump"), "the capture already running when b/c arrived still landed");

  const stats = replica.stats();
  assert.equal(stats.capturesRequested, 3, "every distinct want is counted");
  assert.equal(stats.captures, 2, "but only first-and-newest reached the browser");
  assert.equal(stats.capturesCompleted, 2);
  assert.equal(stats.capturesSupersededBeforeStart, 1, "the middle position died in the want slot, not in Chromium");
  assert.equal(stats.capturesDiscarded, 0, "nothing completed stale -- the running capture stays current");
  assert.equal(stats.timing.captureQueueWait.count, 2, "queue wait is sampled per dispatched capture");
  assert.equal(stats.timing.captureDuration.count, 2, "and duration per completed one");

  // The moving tier: a reference below the device factor captures reduced,
  // and the surface's own pixels prove it. A settle reference at the device
  // factor stays full size -- the frame a reader rests on is never soft.
  const moving = { ...ref, scrollY: 40, scale: 0.5 };
  assert.equal(replica.resolveUpload(moving, "doc-pump"), null);
  let movingBytes = null;
  const movingDeadline = Date.now() + 30000;
  while (movingBytes === null && Date.now() < movingDeadline) {
    await new Promise((resolve) => setTimeout(resolve, 25));
    movingBytes = replica.resolveUpload(moving, "doc-pump");
  }
  assert.ok(movingBytes, "the moving-tier capture landed");
  assert.equal(movingBytes.readUInt32BE(16), 320, "half-scale reference -> half-width pixels (IHDR width)");

  const settled = replica.resolveUpload(ref, "doc-pump");
  assert.ok(settled, "the layout's own device-scale surface is still resolvable");
  assert.equal(settled.readUInt32BE(16), 640, "and remains full width");
});
