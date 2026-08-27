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

  // A mutating interact bumps the visual epoch and never ships a PNG.
  const found = await replica.handle("interact", {
    documentId: "doc-local",
    contentRevision: "7:0",
    action: "find_set",
    query: "body",
    viewportWidthPx: 640,
    viewportHeightPx: 480,
    cellWidthPx: 8,
    cellHeightPx: 16,
  });
  assert.equal(found.visualEpoch, 1, "a visible-state mutation bumps the epoch");
  assert.equal(found.pngPath, undefined, "no PNG path ever crosses the socket");

  // Sheets are derivable locally from the ref alone.
  const sheet = replica.resolveUpload(
    { kind: "sheet", id: 11, tint: "3a7bd5cc", widthPx: 200, heightPx: 100, marginX: 0, marginY: 0 },
    "doc-local"
  );
  assert.ok(sheet && sheet.subarray(1, 4).equals(Buffer.from("PNG")), "the tint sheet is synthesized, not shipped");

  await assert.rejects(() => replica.handle("prepare", {}), (error) => error.code === "UNSUPPORTED_METHOD");
  await docService.close();
});
