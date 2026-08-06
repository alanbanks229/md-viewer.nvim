import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { BrowserRenderer } from "../../renderer/src/browser.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const assetsDir = path.resolve(here, "../../renderer/assets");

test("uses approved Chromium, captures one viewport, and cleans temporary files", async (t) => {
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
  const executable = renderer.resolveExecutable({ executable_path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" });
  const health = await renderer.health({ executable_path: executable, launch_timeout_ms: 10000 });
  assert.equal(health.chromiumLaunch, "succeeded");
  assert.equal(renderer.deviceScaleFactor, 1);
  const params = { documentId: "buffer-7", contentRevision: 1, viewport: { widthPx: 640, heightPx: 480, deviceScaleFactor: 2 },
    browser: { executable_path: executable }, theme: "dark", scrollY: 0, network: false,
    captureScale: "device", scrollPastEnd: true, scrollPastEndOffsetPx: 22 };
  const html = '<h1 data-source-start="0" data-source-end="1">Heading</h1><p data-source-start="1" data-source-end="2">body</p>';
  const result = await renderer.render(params, html, 42);
  assert.equal(result.viewportHeightPx, 480);
  assert.ok(result.blocks.length >= 2);
  const devicePng = fs.readFileSync(result.pngPath);
  assert.deepEqual(devicePng.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  assert.equal(devicePng.readUInt32BE(16), 1280);
  assert.equal(devicePng.readUInt32BE(20), 960);
  assert.equal(renderer.deviceScaleFactor, 2);
  assert.equal(await renderer.page.evaluate(() => getComputedStyle(document.body).fontSize), "15px");
  assert.ok(result.documentHeightPx - result.blocks.at(-1).bottomPx > 400);
  assert.equal(result.layoutReused, false);
  const scrolled = await renderer.render({ ...params, scrollY: 20, captureScale: "css" }, html, 43);
  assert.equal(scrolled.layoutReused, true);
  assert.equal(scrolled.captureScale, "css");
  const cssPng = fs.readFileSync(scrolled.pngPath);
  assert.equal(cssPng.readUInt32BE(16), 640);
  assert.equal(cssPng.readUInt32BE(20), 480);
  assert.ok(scrolled.pngBytes < result.pngBytes);
  const narrow = await renderer.render({ ...params, viewport: { ...params.viewport, widthPx: 600 } }, html, 45);
  assert.equal(narrow.layoutReused, false);
  assert.equal(await renderer.page.evaluate(() => getComputedStyle(document.body).fontSize), "16px");
  const changed = await renderer.render({ ...params, contentRevision: 2 }, html, 44);
  assert.equal(changed.layoutReused, false);
  const tempDir = renderer.tempDir;
  await renderer.close();
  assert.equal(fs.existsSync(tempDir), false);
});

test("rejects an invalid configured Chromium path", () => {
  const renderer = new BrowserRenderer({ assetsDir });
  assert.throws(() => renderer.resolveExecutable({ executable_path: "/definitely/missing/chrome" }), /does not exist/);
  return renderer.close();
});
