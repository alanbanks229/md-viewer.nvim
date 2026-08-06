import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { BrowserRenderer } from "../../renderer/src/browser.js";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const assetsDir = path.resolve(here, "../../renderer/assets");

// This test launches a real browser, so it uses whatever Chrome, Chromium, or
// Edge discovery finds on the current platform/CI runner rather than a
// hardcoded macOS path. Never runs `playwright install` or downloads one.
function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

test("uses approved Chromium, captures one viewport, and cleans temporary files", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
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
  assert.equal(await renderer.page.evaluate(() => getComputedStyle(document.body).fontSize), "17px");
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
  assert.equal(await renderer.page.evaluate(() => getComputedStyle(document.body).fontSize), "18px");
  const changed = await renderer.render({ ...params, contentRevision: 2 }, html, 44);
  assert.equal(changed.layoutReused, false);
  // A viewport wide enough (>720px) to avoid the responsive breakpoints, so
  // the computed font-size reflects the configured value with no override.
  const widePx = { ...params.viewport, widthPx: 900 };
  await renderer.render({ ...params, viewport: widePx, fontSizePx: 20 }, html, 46);
  assert.equal(await renderer.page.evaluate(() => getComputedStyle(document.body).fontSize), "20px");
  assert.equal(await renderer.page.evaluate(() => getComputedStyle(document.body).lineHeight), "31px");
  await renderer.render({ ...params, viewport: widePx, fontSizePx: 999 }, html, 47);
  assert.equal(await renderer.page.evaluate(() => getComputedStyle(document.body).fontSize), "28px");
  await renderer.render({ ...params, viewport: widePx, fontSizePx: 1 }, html, 48);
  assert.equal(await renderer.page.evaluate(() => getComputedStyle(document.body).fontSize), "10px");
  const tempDir = renderer.tempDir;
  await renderer.close();
  assert.equal(fs.existsSync(tempDir), false);
});

test("rejects an invalid configured Chromium path", () => {
  const renderer = new BrowserRenderer({ assetsDir });
  assert.throws(() => renderer.resolveExecutable({ executable_path: "/definitely/missing/chrome" }), /does not exist/);
  return renderer.close();
});
