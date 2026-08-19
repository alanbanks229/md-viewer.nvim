// Does Chromium let us capture a document region taller than the viewport?
//
// This is the go/no-go for resident-region crop panning. The whole design rests
// on one assumption: `Page.captureScreenshot` with `captureBeyondViewport: true`
// and a document-space clip several viewports tall returns the right pixels
// *without* resizing the layout viewport. If it does not, nothing downstream is
// worth building, and finding that out costs this file rather than a release.
//
// Why the assumption is plausible but not safe: Playwright's own Chromium
// screenshotter sends `captureBeyondViewport: !fitsViewport` for exactly this
// case (playwright-core/lib/coreBundle.js, `takeScreenshot`), so the mechanism
// is the supported route. But md-viewer's document sets its bottom padding to
// `calc(100vh - Npx)` (browser.js `buildDocumentHtml`), which makes
// `document.documentElement.scrollHeight` a function of viewport *height*. Any
// capture path that grows the viewport to reach beyond the fold would therefore
// silently change the document's own scroll extent -- and every block rect, every
// scroll clamp and every resident region's coordinate mapping is derived from it.
//
// So this probe asserts the layout is untouched, not merely that pixels come
// back. It drives the real `BrowserRenderer` rather than a mock, so what it
// measures is the object the feature will actually extend.
//
//   node scripts/resident/probe.mjs
//
// Writes nothing but PNGs under tmp/resident/probe/ (gitignored). Exits non-zero
// on any failed check.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { BrowserRenderer } from "../../renderer/src/browser.js";
import { collectBlockGeometry } from "../../renderer/src/source-map.js";
import { renderMarkdown } from "../../renderer/src/markdown.js";
import { decodePngPixels } from "../../tests/node/helpers/decode-png.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..", "..");
const assetsDir = path.join(repoRoot, "renderer", "assets");
const outDir = path.join(repoRoot, "tmp", "resident", "probe");

// The viewport every number in docs/local-render-design.md was measured
// against, so the byte counts this prints are comparable to the ones on record.
const VIEWPORT_W = 990;
const VIEWPORT_H = 1020;
const DEVICE_SCALE = 2;

const checks = [];
function check(name, passed, detail) {
  checks.push({ name, passed, detail });
  const mark = passed ? "PASS" : "FAIL";
  console.log(`  [${mark}] ${name}${detail ? ` -- ${detail}` : ""}`);
}

function kb(bytes) {
  return `${(bytes / 1024).toFixed(1)} KB`;
}

/// A document tall enough that a two-viewport region is comfortably interior:
/// numbered paragraphs so a mis-registered capture is obvious in the PNG, and
/// wide headings so block geometry has something to report.
function fixtureMarkdown(paragraphs = 240) {
  const lines = ["# Resident region probe", ""];
  for (let index = 1; index <= paragraphs; index += 1) {
    if (index % 20 === 1) lines.push(`## Section ${Math.ceil(index / 20)}`, "");
    lines.push(`**${index}.** The quick brown fox jumps over the lazy dog, paragraph number ${index}.`, "");
  }
  return lines.join("\n");
}

/// Compare two decoded images that should show the same content. Returns the
/// fraction of samples within `tolerance` and the worst single difference.
///
/// Deliberately not a byte comparison: a beyond-viewport capture and an ordinary
/// viewport capture are different compositor paths, and text anti-aliasing is
/// allowed to differ by a shade without the feature being wrong. What would make
/// it wrong is content at the *wrong offset*, which moves whole glyphs and shows
/// up here as a mismatch fraction in the tens of percent, not tenths.
function comparePixels(a, b, tolerance = 4) {
  if (a.width !== b.width || a.height !== b.height) {
    return { comparable: false, reason: `dimensions differ: ${a.width}x${a.height} vs ${b.width}x${b.height}` };
  }
  if (a.channels !== b.channels) {
    return { comparable: false, reason: `channel counts differ: ${a.channels} vs ${b.channels}` };
  }
  let within = 0;
  let worst = 0;
  const total = a.pixels.length;
  for (let index = 0; index < total; index += 1) {
    const delta = Math.abs(a.pixels[index] - b.pixels[index]);
    if (delta > worst) worst = delta;
    if (delta <= tolerance) within += 1;
  }
  return { comparable: true, fraction: within / total, worst, samples: total };
}

/// Crop a horizontal band out of a decoded image, so a region capture can be
/// compared against the viewport capture of the same document coordinates.
function band(image, top, height) {
  const stride = image.width * image.channels;
  return {
    width: image.width,
    height,
    channels: image.channels,
    pixels: image.pixels.subarray(top * stride, (top + height) * stride),
  };
}

async function captureRegion(renderer, { y, height, beyondViewport = true, label }) {
  const { data } = await renderer.cdp.send("Page.captureScreenshot", {
    format: "png",
    optimizeForSpeed: true,
    captureBeyondViewport: beyondViewport,
    clip: { x: 0, y, width: VIEWPORT_W, height, scale: DEVICE_SCALE },
  });
  const buffer = Buffer.from(data, "base64");
  if (label) fs.writeFileSync(path.join(outDir, `${label}.png`), buffer);
  return buffer;
}

async function main() {
  fs.mkdirSync(outDir, { recursive: true });
  const renderer = new BrowserRenderer({ assetsDir });

  console.log("md-viewer resident-region capture probe");
  console.log(`  viewport ${VIEWPORT_W}x${VIEWPORT_H} CSS at deviceScaleFactor ${DEVICE_SCALE}`);
  console.log("");

  await renderer.ensure({}, DEVICE_SCALE);
  console.log(`  chromium: ${renderer.discoveryReason}`);
  await renderer.page.setViewportSize({ width: VIEWPORT_W, height: VIEWPORT_H });
  // `render()` normally owns this; the probe calls loadDocument directly, and
  // captureViewportPng reads it to size the clip.
  renderer.viewport = { width: VIEWPORT_W, height: VIEWPORT_H };

  const { html } = await renderMarkdown(fixtureMarkdown(), { rawHtml: false, localImages: false });
  await renderer.loadDocument({
    documentId: "probe", contentRevision: "1", layoutKey: "probe:1", html,
    theme: "dark", fontSizePx: 14, scrollPastEnd: true, scrollPastEndOffsetPx: 22,
    width: VIEWPORT_W, height: VIEWPORT_H, animationIds: [],
  });

  const heightBefore = await renderer.page.evaluate(() => document.documentElement.scrollHeight);
  const blocksBefore = await collectBlockGeometry(renderer.page);
  console.log(`  document: ${heightBefore} CSS px tall (${(heightBefore / VIEWPORT_H).toFixed(1)} viewports), ${blocksBefore.length} blocks`);
  console.log("");

  if (!renderer.cdp) {
    check("CDP session available", false, "newCDPSession failed; the fast path is unreachable on this host");
    return report(renderer);
  }

  // ---- 1. Baseline: an ordinary viewport capture at scroll 0 -----------------
  await renderer.applyScroll(heightBefore, VIEWPORT_H, 0);
  const baseline = await renderer.captureViewport({ documentId: "probe", requestId: "baseline", captureScale: "device" });
  const baselineBuffer = fs.readFileSync(baseline.pngPath);
  fs.writeFileSync(path.join(outDir, "viewport-scroll0.png"), baselineBuffer);
  const baselineImage = decodePngPixels(baselineBuffer);
  check(
    "baseline viewport capture is viewport-sized at device scale",
    baselineImage.width === VIEWPORT_W * DEVICE_SCALE && baselineImage.height === VIEWPORT_H * DEVICE_SCALE,
    `${baselineImage.width}x${baselineImage.height}, ${kb(baseline.pngBytes)}, ${baseline.captureEncoder}`,
  );

  // ---- 2. The load-bearing question: a two-viewport region -------------------
  const regionH = VIEWPORT_H * 2;
  let regionBuffer;
  let regionImage;
  try {
    regionBuffer = await captureRegion(renderer, { y: 0, height: regionH, label: "region-2viewports" });
    regionImage = decodePngPixels(regionBuffer);
    check(
      "captureBeyondViewport:true returns a region taller than the viewport",
      regionImage.width === VIEWPORT_W * DEVICE_SCALE && regionImage.height === regionH * DEVICE_SCALE,
      `${regionImage.width}x${regionImage.height}, ${kb(regionBuffer.length)}`,
    );
  } catch (error) {
    check("captureBeyondViewport:true returns a region taller than the viewport", false, String(error?.message ?? error));
    return report(renderer);
  }

  // ---- 3. The 100vh guard: layout must be untouched --------------------------
  const heightAfter = await renderer.page.evaluate(() => document.documentElement.scrollHeight);
  check(
    "document scrollHeight is unchanged by a region capture (the calc(100vh) guard)",
    heightAfter === heightBefore,
    `${heightBefore} -> ${heightAfter}`,
  );

  const blocksAfter = await collectBlockGeometry(renderer.page);
  const blocksMatch = JSON.stringify(blocksBefore) === JSON.stringify(blocksAfter);
  check("block geometry is unchanged by a region capture", blocksMatch,
    blocksMatch ? `${blocksAfter.length} blocks identical` : "block rects moved -- the layout reflowed");

  const scrollAfter = await renderer.page.evaluate(() => window.scrollY);
  check("page scroll position is unchanged by a region capture", scrollAfter === 0, `window.scrollY = ${scrollAfter}`);

  // ---- 4. The next ordinary capture must be unaffected ------------------------
  const afterRegion = await renderer.captureViewport({ documentId: "probe", requestId: "after", captureScale: "device" });
  const afterBuffer = fs.readFileSync(afterRegion.pngPath);
  fs.unlinkSync(afterRegion.pngPath);
  check(
    "an ordinary viewport capture after a region capture is byte-identical to one before",
    afterBuffer.equals(baselineBuffer),
    afterBuffer.equals(baselineBuffer) ? "identical" : `${kb(baselineBuffer.length)} vs ${kb(afterBuffer.length)}`,
  );
  fs.unlinkSync(baseline.pngPath);

  // ---- 5. Registration: do the region's pixels sit where the maths says? ------
  const topBand = band(regionImage, 0, VIEWPORT_H * DEVICE_SCALE);
  const topMatch = comparePixels(baselineImage, topBand);
  check(
    "region rows 0..Vh match the viewport capture at scroll 0",
    topMatch.comparable && topMatch.fraction > 0.995,
    topMatch.comparable ? `${(topMatch.fraction * 100).toFixed(2)}% of samples within 4, worst delta ${topMatch.worst}` : topMatch.reason,
  );

  await renderer.applyScroll(heightBefore, VIEWPORT_H, VIEWPORT_H);
  const scrolled = await renderer.captureViewport({ documentId: "probe", requestId: "scrolled", captureScale: "device" });
  const scrolledImage = decodePngPixels(fs.readFileSync(scrolled.pngPath));
  fs.unlinkSync(scrolled.pngPath);
  const bottomBand = band(regionImage, VIEWPORT_H * DEVICE_SCALE, VIEWPORT_H * DEVICE_SCALE);
  const bottomMatch = comparePixels(scrolledImage, bottomBand);
  check(
    "region rows Vh..2Vh match the viewport capture at scroll Vh (beyond-the-fold content is real)",
    bottomMatch.comparable && bottomMatch.fraction > 0.995,
    bottomMatch.comparable ? `${(bottomMatch.fraction * 100).toFixed(2)}% of samples within 4, worst delta ${bottomMatch.worst}` : bottomMatch.reason,
  );

  // ---- 6. Why the flag is needed at all --------------------------------------
  await renderer.applyScroll(heightBefore, VIEWPORT_H, 0);
  try {
    const withoutFlag = await captureRegion(renderer, { y: 0, height: regionH, beyondViewport: false, label: "region-no-flag" });
    const withoutImage = decodePngPixels(withoutFlag);
    const withoutBottom = band(withoutImage, VIEWPORT_H * DEVICE_SCALE, VIEWPORT_H * DEVICE_SCALE);
    const withoutMatch = comparePixels(scrolledImage, withoutBottom);
    // Not a pass/fail on the feature -- it records *why* the flag is required, so
    // nobody later "simplifies" it away.
    console.log(
      `  [note] captureBeyondViewport:false at the same clip -> ${withoutImage.width}x${withoutImage.height}, `
      + `beyond-the-fold band matches ${withoutMatch.comparable ? `${(withoutMatch.fraction * 100).toFixed(2)}%` : withoutMatch.reason}`,
    );
  } catch (error) {
    console.log(`  [note] captureBeyondViewport:false at the same clip threw: ${String(error?.message ?? error)}`);
  }

  // ---- 7. Bottom-of-document clipping ----------------------------------------
  const tailY = Math.max(0, heightBefore - Math.floor(VIEWPORT_H * 1.5));
  const tailH = heightBefore - tailY;
  try {
    const tail = await captureRegion(renderer, { y: tailY, height: tailH, label: "region-document-tail" });
    const tailImage = decodePngPixels(tail);
    check(
      "a region clipped to the document bottom returns the requested size",
      tailImage.height === Math.round(tailH * DEVICE_SCALE),
      `requested ${tailH} CSS px -> ${tailImage.width}x${tailImage.height}, ${kb(tail.length)}`,
    );
  } catch (error) {
    check("a region clipped to the document bottom returns the requested size", false, String(error?.message ?? error));
  }

  // ---- 8. Where does it break? ------------------------------------------------
  console.log("");
  console.log("  ceiling search (region height in CSS px -> device px -> outcome):");
  let lastGood = 0;
  for (const multiple of [2, 3, 4, 6, 8, 12, 16, 24, 32]) {
    const height = VIEWPORT_H * multiple;
    const devicePx = height * DEVICE_SCALE;
    if (height > heightBefore) {
      console.log(`    ${multiple}x (${height} -> ${devicePx}px tall): skipped, taller than the document`);
      continue;
    }
    const started = Date.now();
    try {
      const buffer = await captureRegion(renderer, { y: 0, height });
      const image = decodePngPixels(buffer);
      const ok = image.height === devicePx;
      const megapixels = (image.width * image.height) / 1e6;
      console.log(
        `    ${multiple}x (${height} -> ${devicePx}px tall): ${ok ? "ok" : `WRONG SIZE ${image.width}x${image.height}`}, `
        + `${megapixels.toFixed(1)} Mpx, ${kb(buffer.length)}, ${Date.now() - started} ms`,
      );
      if (ok) lastGood = devicePx;
      else break;
    } catch (error) {
      console.log(`    ${multiple}x (${height} -> ${devicePx}px tall): THREW -- ${String(error?.message ?? error)}`);
      break;
    }
  }
  console.log(`  largest region that came back correct: ${lastGood} device px tall`);
  check("at least a two-viewport region is capturable", lastGood >= VIEWPORT_H * 2 * DEVICE_SCALE,
    `${lastGood} device px vs ${VIEWPORT_H * 2 * DEVICE_SCALE} needed`);

  return report(renderer);
}

async function report(renderer) {
  try { await renderer.close?.(); } catch {}
  const failed = checks.filter((entry) => !entry.passed);
  console.log("");
  console.log(`  PNGs written to ${path.relative(repoRoot, outDir)}/`);
  console.log("");
  if (failed.length === 0) {
    console.log("  GO -- captureBeyondViewport returns correct pixels and leaves the layout alone.");
    console.log("  Proceed with increments 1-12.");
    return 0;
  }
  console.log(`  NO-GO -- ${failed.length} of ${checks.length} checks failed:`);
  for (const entry of failed) console.log(`    - ${entry.name}${entry.detail ? `: ${entry.detail}` : ""}`);
  console.log("");
  console.log("  Do not build on this. Either the Playwright page.screenshot({clip}) fallback has to");
  console.log("  become the primary path, or resident panning is not available on this Chromium.");
  return 1;
}

main().then(
  (code) => process.exit(code),
  (error) => {
    console.error("probe failed to run:", error);
    process.exit(2);
  },
);
