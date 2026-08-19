// Capturing a document region taller than the viewport.
//
// The whole resident-panning design rests on one assumption about Chromium: that
// a document-space clip several viewports tall returns the right pixels *without*
// resizing the layout viewport. That assumption is not safe to hold implicitly,
// for two reasons this file exists to pin.
//
// The document's bottom padding is `calc(100vh - Npx)`, so `scrollHeight` is a
// function of viewport height -- any capture path that grew the viewport to reach
// past the fold would move the coordinate space out from under every block rect
// and every resident region's crop arithmetic.
//
// And the failure is quiet. With `captureBeyondViewport: false` at the same tall
// clip, Chromium returns a correctly *sized* PNG whose beyond-the-fold band is
// only about 95% right -- no exception, no short image, just subtly wrong pixels.
// So the flag has to be asserted, not inferred from the absence of an error.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  BrowserRenderer,
  MAX_REGION_HEIGHT_PX,
  MAX_REGION_PIXELS,
  resolveCaptureRegion,
} from "../../renderer/src/browser.js";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";
import { decodePngPixels } from "./helpers/decode-png.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const assetsDir = path.resolve(here, "../../renderer/assets");

function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

const WIDTH = 640;
const HEIGHT = 480;

function fixtureHtml(paragraphs = 200) {
  const parts = [];
  for (let index = 1; index <= paragraphs; index += 1) {
    parts.push(`<p data-source-start="${index}" data-source-end="${index + 1}">Paragraph number ${index}.</p>`);
  }
  return parts.join("");
}

// Pure guard arithmetic: no browser, so it runs on every machine including the
// ones where the capture tests skip.
test("a capture region is clamped to the document and refused when it is too large", () => {
  const context = { documentHeight: 5000, viewportWidth: 990, deviceScaleFactor: 2 };

  assert.deepEqual(resolveCaptureRegion({ yPx: 1000, heightPx: 2000 }, context), { yPx: 1000, heightPx: 2000 });

  // The last region of every document runs past the end, so overrun is ordinary
  // and is clamped rather than refused -- and the caller is told what it got.
  assert.deepEqual(resolveCaptureRegion({ yPx: 4000, heightPx: 2000 }, context), { yPx: 4000, heightPx: 1000 });
  assert.deepEqual(resolveCaptureRegion({ yPx: 9000, heightPx: 500 }, context), { yPx: 5000, heightPx: 1 });
  assert.deepEqual(resolveCaptureRegion({ yPx: -50, heightPx: 100 }, context), { yPx: 0, heightPx: 100 });

  // Too large is not ordinary, so it is refused with a code the Lua side acts on
  // rather than silently reduced to something nobody asked for.
  const tooTall = () => resolveCaptureRegion({ yPx: 0, heightPx: 40000 }, { ...context, documentHeight: 100000 });
  assert.throws(tooTall, (error) => error.code === "REGION_TOO_LARGE");

  const tooWide = () =>
    resolveCaptureRegion({ yPx: 0, heightPx: 8000 }, { documentHeight: 100000, viewportWidth: 1920, deviceScaleFactor: 3 });
  assert.throws(tooWide, (error) => error.code === "REGION_TOO_LARGE");

  assert.throws(() => resolveCaptureRegion({ yPx: 0 }, context), (error) => error.code === "INVALID_REQUEST");
  assert.throws(() => resolveCaptureRegion({ yPx: "x", heightPx: 1 }, context), (error) => error.code === "INVALID_REQUEST");

  // The ceilings sit below what Chromium 151 was measured to manage
  // (scripts/resident/probe.mjs: 32.3 Mpx, 16,320 px tall), not at it.
  assert.ok(MAX_REGION_PIXELS <= 32000000);
  assert.ok(MAX_REGION_HEIGHT_PX <= 16384);
});

test("a region capture returns beyond-the-fold pixels and leaves the layout untouched", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());

  const params = {
    documentId: "region-1",
    contentRevision: 1,
    viewport: { widthPx: WIDTH, heightPx: HEIGHT, deviceScaleFactor: 2 },
    browser: { executable_path: executable },
    theme: "dark",
    scrollY: 0,
    captureScale: "device",
    scrollPastEnd: true,
    scrollPastEndOffsetPx: 22,
  };
  const html = fixtureHtml();

  const baseline = await renderer.render(params, html, 1);
  const documentHeight = baseline.documentHeightPx;
  assert.ok(documentHeight > HEIGHT * 3, "the fixture is several viewports tall");
  assert.equal(baseline.regionYPx, undefined, "an ordinary capture reports no region");
  assert.equal(baseline.regionHeightPx, undefined);
  const baselinePng = fs.readFileSync(baseline.pngPath);
  assert.equal(baselinePng.readUInt32BE(20), HEIGHT * 2, "and is exactly one viewport tall");

  // Two viewports, from the top of the document.
  const region = await renderer.render(
    { ...params, captureRegion: { yPx: 0, heightPx: HEIGHT * 2 } },
    html,
    2,
  );
  assert.equal(region.regionYPx, 0);
  assert.equal(region.regionHeightPx, HEIGHT * 2);
  assert.equal(region.captureScale, "device", "a region is always the settle tier");
  const regionImage = decodePngPixels(fs.readFileSync(region.pngPath));
  assert.equal(regionImage.width, WIDTH * 2);
  assert.equal(regionImage.height, HEIGHT * 2 * 2, "the PNG is as tall as the region asked for");

  // The 100vh guard. If the capture had grown the viewport to reach past the
  // fold, the document's own extent would have moved with it.
  assert.equal(
    await renderer.page.evaluate(() => document.documentElement.scrollHeight),
    documentHeight,
    "a region capture does not change the document's scroll height",
  );
  assert.equal(await renderer.page.evaluate(() => window.scrollY), 0, "nor the page's scroll position");

  // ...and the next ordinary frame is unaffected, byte for byte.
  const after = await renderer.render(params, html, 3);
  assert.deepEqual(fs.readFileSync(after.pngPath), baselinePng, "an ordinary capture after a region capture is identical");
  assert.deepEqual(after.blocks, baseline.blocks, "and block geometry is unchanged");

  // Registration: the region's second viewport must be the same pixels an
  // ordinary capture at that scroll position produces. This is what makes the
  // crop arithmetic in lua/md-viewer/resident.lua checkable against reality.
  const scrolled = await renderer.render({ ...params, scrollY: HEIGHT }, html, 4);
  const scrolledImage = decodePngPixels(fs.readFileSync(scrolled.pngPath));
  const stride = regionImage.width * regionImage.channels;
  const band = regionImage.pixels.subarray(HEIGHT * 2 * stride, HEIGHT * 2 * 2 * stride);
  assert.equal(band.length, scrolledImage.pixels.length);
  let mismatched = 0;
  for (let index = 0; index < band.length; index += 1) {
    if (Math.abs(band[index] - scrolledImage.pixels[index]) > 4) mismatched += 1;
  }
  assert.ok(
    mismatched / band.length < 0.005,
    `beyond-the-fold band matches the viewport capture at the same scroll (${mismatched} of ${band.length} samples differ)`,
  );

  for (const result of [baseline, region, after, scrolled]) fs.unlinkSync(result.pngPath);
});

test("a region is clamped to the document's end and refused when too large", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());

  const params = {
    documentId: "region-2",
    contentRevision: 1,
    viewport: { widthPx: WIDTH, heightPx: HEIGHT, deviceScaleFactor: 2 },
    browser: { executable_path: executable },
    theme: "dark",
    scrollY: 0,
    captureScale: "device",
    scrollPastEnd: true,
    scrollPastEndOffsetPx: 22,
  };
  // Tall enough that the whole document exceeds the device-pixel ceiling. That
  // matters: because a region is clamped to what the document actually has,
  // the only way to reach the ceiling through `render` at all is a document
  // genuinely larger than it -- asking for 60,000 px of a short document is a
  // clamp, not a refusal, and a test that confused the two would assert nothing.
  const html = fixtureHtml(600);

  const first = await renderer.render(params, html, 10);
  const documentHeight = first.documentHeightPx;
  fs.unlinkSync(first.pngPath);
  assert.ok(
    documentHeight * 2 > MAX_REGION_HEIGHT_PX,
    `fixture must exceed the ceiling to exercise it (${documentHeight} CSS px at scale 2)`,
  );

  // Asking for more than remains returns what remains, and says so -- the Lua
  // side derives the region's scale from this height, so a request echoed back
  // unclamped would misplace every crop in the document's last region.
  const tail = await renderer.render(
    { ...params, captureRegion: { yPx: documentHeight - 200, heightPx: HEIGHT * 3 } },
    html,
    11,
  );
  assert.equal(tail.regionHeightPx, 200);
  const tailImage = decodePngPixels(fs.readFileSync(tail.pngPath));
  assert.equal(tailImage.height, 400, "the PNG matches the clamped height, not the requested one");
  fs.unlinkSync(tail.pngPath);

  await assert.rejects(
    renderer.render({ ...params, captureRegion: { yPx: 0, heightPx: documentHeight } }, html, 12),
    (error) => error.code === "REGION_TOO_LARGE",
    "a region larger than the ceiling is refused with a code rather than captured",
  );

  // A refused region must not poison the ordinary path: the next frame is a
  // normal capture on the normal encoder.
  const recovered = await renderer.render(params, html, 13);
  assert.equal(recovered.regionYPx, undefined);
  assert.equal(recovered.captureEncoder, "cdp_fast_png", "the fast viewport encoder survives a region refusal");
  fs.unlinkSync(recovered.pngPath);
});

test("captureBeyondViewport is what makes a tall clip correct", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());

  const params = {
    documentId: "region-3",
    contentRevision: 1,
    viewport: { widthPx: WIDTH, heightPx: HEIGHT, deviceScaleFactor: 2 },
    browser: { executable_path: executable },
    theme: "dark",
    scrollY: 0,
    captureScale: "device",
    scrollPastEnd: true,
    scrollPastEndOffsetPx: 22,
  };
  const html = fixtureHtml();
  const region = await renderer.render({ ...params, captureRegion: { yPx: 0, heightPx: HEIGHT * 2 } }, html, 20);
  const correct = decodePngPixels(fs.readFileSync(region.pngPath));
  fs.unlinkSync(region.pngPath);

  // The same clip with the flag off. It does not throw and does not come back
  // short -- it comes back *wrong*, which is precisely why the production path
  // may never be "simplified" into sharing the viewport branch's flag.
  const { data } = await renderer.cdp.send("Page.captureScreenshot", {
    format: "png",
    optimizeForSpeed: true,
    captureBeyondViewport: false,
    clip: { x: 0, y: 0, width: WIDTH, height: HEIGHT * 2, scale: 2 },
  });
  const without = decodePngPixels(Buffer.from(data, "base64"));
  assert.equal(without.height, correct.height, "the flag does not change the image's size");

  let mismatched = 0;
  for (let index = 0; index < correct.pixels.length; index += 1) {
    if (Math.abs(correct.pixels[index] - without.pixels[index]) > 4) mismatched += 1;
  }
  assert.ok(
    mismatched > 0,
    "with captureBeyondViewport off the same clip returns different pixels -- a quiet failure, not a loud one",
  );
});

// A renderer tab can die under the process. A region is the only capture here
// large enough to take one with it, and the pixel ceiling it is bounded by was
// measured on one machine while the code runs on another -- so this is a limit
// that differs by host rather than a contradiction to explain away.
//
// What made it a permanent failure rather than a hiccup was `ensure` returning
// early on the presence of a context, never asking whether the page was still
// alive. A dead page leaves the context handle in place, so nothing rebuilt it
// and every later capture failed the same way -- including on freshly opened
// documents, which is how it was reported: "Target page, context or browser has
// been closed" on a file that had nothing to do with whatever broke.
//
// Closing the page here stands in for the crash. What is under test is not why
// a page dies but that the next capture rebuilds it.
test("a dead page is rebuilt rather than failing for the life of the process", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());

  const params = {
    documentId: "dead-page",
    contentRevision: 1,
    viewport: { widthPx: WIDTH, heightPx: HEIGHT, deviceScaleFactor: 2 },
    browser: { executable_path: executable },
    theme: "dark",
    scrollY: 0,
    captureScale: "device",
    scrollPastEnd: true,
    scrollPastEndOffsetPx: 22,
  };
  const html = fixtureHtml(20);

  const before = await renderer.render(params, html, 1);
  assert.ok(fs.existsSync(before.pngPath), "sanity: a capture works to begin with");
  fs.unlinkSync(before.pngPath);

  const deadPage = renderer.page;
  await deadPage.close();
  assert.ok(deadPage.isClosed(), "sanity: the page really is gone");

  // The next request must not inherit the corpse. A second render with a fresh
  // document id is the ordinary thing a reader does after this happens.
  const after = await renderer.render({ ...params, documentId: "dead-page-2", contentRevision: 2 }, html, 2);
  assert.ok(fs.existsSync(after.pngPath), "a capture after the page died still produces a PNG");
  assert.notEqual(renderer.page, deadPage, "on a rebuilt page rather than the dead one");
  assert.ok(!renderer.page.isClosed(), "which is alive");
  fs.unlinkSync(after.pngPath);
});
