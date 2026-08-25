// Is a Chromium region capture document-absolute, or does it compose with the
// page's current scroll?
//
// Everything in whole-document resident mode rests on this one property. A
// renderer echoes back the region it was *asked* for, so if the clip composes
// with `window.scrollY` then every chunk holds pixels of somewhere else while
// the coordinate model, the placements and the retirement all stay provably
// correct. That is not hypothetical: measured on Ubuntu 22.04 / Chromium 151,
// `page.screenshot({clip})` asked for {yPx: 0, heightPx: 2467} with the page at
// 4800 returned 2432x2584 starting at block 012, where the answer is 2432x4934
// starting at the title.
//
//   node scripts/resident/registration.mjs
//
// Writes PNGs under tmp/resident/registration/ (gitignored). Exits non-zero if
// any go/no-go check fails.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { BrowserRenderer } from "../../renderer/src/browser.js";
import { renderMarkdown } from "../../renderer/src/markdown.js";
import { decodePngPixels } from "../../tests/node/helpers/decode-png.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..", "..");
const assetsDir = path.join(repoRoot, "renderer", "assets");
const outDir = path.join(repoRoot, "tmp", "resident", "registration");

// The viewport every number in docs/local-render-design.md was measured
// against, so what this prints is comparable to what is already on record.
const VIEWPORT_W = 990;
const VIEWPORT_H = 1020;
const DEVICE_SCALE = 2;

// Two viewports tall: 1980 x 4080 device px = 8.1 Mpx, comfortably inside the
// 12,000,000 px / 16,384 px ceilings a single captureScreenshot call allows.
const REGION_H = VIEWPORT_H * 2;

const checks = [];
const notes = [];

function check(name, passed, detail) {
  checks.push({ name, passed });
  console.log(`  [${passed ? "PASS" : "FAIL"}] ${name}${detail ? ` -- ${detail}` : ""}`);
}

function note(name, detail) {
  notes.push({ name, detail });
  console.log(`  [NOTE] ${name}${detail ? ` -- ${detail}` : ""}`);
}

function kb(bytes) {
  return `${(bytes / 1024).toFixed(1)} KB`;
}

function fixtureMarkdown(blocks = 260) {
  const lines = ["# Region registration", ""];
  for (let index = 0; index < blocks; index += 1) {
    const label = String(index).padStart(3, "0");
    if (index % 20 === 0) lines.push(`## SECTION ${label}`, "");
    lines.push(`**BLOCK ${label}** The quick brown fox jumps over the lazy dog.`, "");
  }
  return lines.join("\n");
}

function pngSize(buffer) {
  return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) };
}

/// Rows [top, top+height) of a decoded image, as a flat sample buffer.
function band(image, top, height) {
  const stride = image.width * image.channels;
  const first = Math.max(0, Math.min(image.height, top));
  const last = Math.max(first, Math.min(image.height, top + height));
  return image.pixels.subarray(first * stride, last * stride);
}

/// Fraction of samples within `tolerance`. Deliberately not a byte comparison:
/// two different compositor paths may differ by a shade on antialiased text.
/// Content at the wrong offset moves whole glyphs and lands in the tens of
/// percent, not tenths.
function agreement(a, b, tolerance = 4) {
  if (a.length !== b.length) return { comparable: false, length: `${a.length} vs ${b.length}` };
  let within = 0;
  let worst = 0;
  for (let index = 0; index < a.length; index += 1) {
    const delta = Math.abs(a[index] - b[index]);
    if (delta <= tolerance) within += 1;
    if (delta > worst) worst = delta;
  }
  return { comparable: true, fraction: within / a.length, worst };
}

async function captureViaCdp(renderer, region, { beyondViewport = true } = {}) {
  const started = performance.now();
  const { data } = await renderer.cdp.send("Page.captureScreenshot", {
    format: "png",
    optimizeForSpeed: true,
    captureBeyondViewport: beyondViewport,
    clip: { x: 0, y: region.yPx, width: VIEWPORT_W, height: region.heightPx, scale: DEVICE_SCALE },
  });
  return { buffer: Buffer.from(data, "base64"), ms: performance.now() - started };
}

async function captureViaPlaywright(renderer, region, pngPath) {
  const started = performance.now();
  await renderer.page.screenshot({
    path: pngPath,
    type: "png",
    clip: { x: 0, y: region.yPx, width: VIEWPORT_W, height: region.heightPx },
    animations: "disabled",
  });
  return { buffer: fs.readFileSync(pngPath), ms: performance.now() - started };
}

async function scrollY(renderer) {
  return renderer.page.evaluate(() => window.scrollY);
}

async function documentHeight(renderer) {
  return renderer.page.evaluate(() => document.documentElement.scrollHeight);
}

async function main() {
  fs.rmSync(outDir, { recursive: true, force: true });
  fs.mkdirSync(outDir, { recursive: true });

  const renderer = new BrowserRenderer({ assetsDir });
  try {
    await renderer.ensure({}, DEVICE_SCALE);
    await renderer.page.setViewportSize({ width: VIEWPORT_W, height: VIEWPORT_H });
    renderer.viewport = { width: VIEWPORT_W, height: VIEWPORT_H };

    const { html } = await renderMarkdown(fixtureMarkdown(), { rawHtml: false });
    const { documentHeight: docHeight } = await renderer.loadDocument({
      documentId: "registration", contentRevision: "1", layoutKey: "registration",
      html, theme: "dark", fontSizePx: 16, scrollPastEnd: true, scrollPastEndOffsetPx: 22,
      width: VIEWPORT_W, height: VIEWPORT_H, animationIds: [],
    });

    const maxScroll = Math.max(0, docHeight - VIEWPORT_H);
    const positions = [0, Math.floor(maxScroll / 2), maxScroll];
    console.log(`\ndocument ${VIEWPORT_W}x${docHeight} css px, scroll positions ${positions.join(", ")}\n`);

    const regions = [
      { name: "top", yPx: 0, heightPx: REGION_H },
      { name: "interior", yPx: Math.floor(maxScroll / 3), heightPx: REGION_H },
    ];

    console.log("CDP, captureBeyondViewport: true");
    const reference = new Map();
    for (const region of regions) {
      const results = [];
      for (const position of positions) {
        await renderer.applyScroll(docHeight, VIEWPORT_H, position);
        const settled = await scrollY(renderer);
        const capture = await captureViaCdp(renderer, region);
        const after = await scrollY(renderer);
        const pngPath = path.join(outDir, `cdp-${region.name}-at-${position}.png`);
        fs.writeFileSync(pngPath, capture.buffer);
        results.push({ position, settled, after, ...capture });
      }

      const [first, ...rest] = results;
      const identical = rest.every((r) => r.buffer.equals(first.buffer));
      const sizes = results.map((r) => {
        const { width, height } = pngSize(r.buffer);
        return `${width}x${height}@${r.settled}`;
      });
      check(
        `region "${region.name}" is byte-identical from every scroll position`,
        identical,
        sizes.join(", "),
      );
      check(
        `region "${region.name}" capture does not move the page`,
        results.every((r) => r.settled === r.after),
        results.map((r) => `${r.settled}->${r.after}`).join(", "),
      );
      note(
        `region "${region.name}" timings`,
        `${results.map((r) => `${r.ms.toFixed(0)}ms`).join(", ")}, ${kb(first.buffer.length)}`,
      );
      reference.set(region.name, first.buffer);
    }

    const heightAfter = await documentHeight(renderer);
    check("region captures leave document height unchanged", heightAfter === docHeight, `${docHeight} -> ${heightAfter}`);

    console.log("\nPlaywright page.screenshot({clip}) at the same positions");
    for (const region of regions) {
      const results = [];
      for (const position of positions) {
        await renderer.applyScroll(docHeight, VIEWPORT_H, position);
        const pngPath = path.join(outDir, `playwright-${region.name}-at-${position}.png`);
        try {
          const capture = await captureViaPlaywright(renderer, region, pngPath);
          const { width, height } = pngSize(capture.buffer);
          results.push({ position, label: `${width}x${height}@${position}`, buffer: capture.buffer });
        } catch (error) {
          results.push({ position, label: `threw@${position} (${String(error.message).split("\n")[0]})` });
        }
      }
      const captured = results.filter((r) => r.buffer);
      const identical = captured.length > 1
        && captured.every((r) => r.buffer.equals(captured[0].buffer));
      note(
        `region "${region.name}" through Playwright`,
        `${results.map((r) => r.label).join(", ")}; identical: ${identical}`,
      );
    }

    console.log("\nCDP, captureBeyondViewport: false");
    await renderer.applyScroll(docHeight, VIEWPORT_H, 0);
    for (const region of regions) {
      const truth = decodePngPixels(reference.get(region.name));
      const off = await captureViaCdp(renderer, region, { beyondViewport: false });
      fs.writeFileSync(path.join(outDir, `beyond-viewport-false-${region.name}.png`), off.buffer);
      const decoded = decodePngPixels(off.buffer);
      const size = `${decoded.width}x${decoded.height} against ${truth.width}x${truth.height}`;
      if (decoded.width !== truth.width || decoded.height !== truth.height) {
        note(`region "${region.name}" without the flag`, `wrong size: ${size}`);
        continue;
      }
      const foldPx = VIEWPORT_H * DEVICE_SCALE;
      const beyond = agreement(
        band(truth, foldPx, truth.height - foldPx),
        band(decoded, foldPx, decoded.height - foldPx),
      );
      note(
        `region "${region.name}" without the flag`,
        `correctly sized (${size}), beyond-the-fold band agrees on `
        + `${(beyond.fraction * 100).toFixed(1)}% of samples, worst delta ${beyond.worst}`,
      );
    }

    console.log("\nCold capture penalty (fresh page each time)");
    const region = { yPx: 0, heightPx: REGION_H };
    const megapixels = (VIEWPORT_W * DEVICE_SCALE * region.heightPx * DEVICE_SCALE) / 1e6;
    for (let attempt = 1; attempt <= 3; attempt += 1) {
      // `ensure` returns early while a context is live, so the page it would
      // reuse has to be torn down here for the capture below to be genuinely cold.
      await renderer.context.close();
      renderer.context = null;
      await renderer.ensure({}, DEVICE_SCALE);
      await renderer.page.setViewportSize({ width: VIEWPORT_W, height: VIEWPORT_H });
      renderer.viewport = { width: VIEWPORT_W, height: VIEWPORT_H };
      await renderer.loadDocument({
        documentId: `cold-${attempt}`, contentRevision: "1", layoutKey: `cold-${attempt}`,
        html, theme: "dark", fontSizePx: 16, scrollPastEnd: true, scrollPastEndOffsetPx: 22,
        width: VIEWPORT_W, height: VIEWPORT_H, animationIds: [],
      });
      const cold = await captureViaCdp(renderer, region);
      const warm = await captureViaCdp(renderer, region);
      note(
        `attempt ${attempt} at ${megapixels.toFixed(1)} Mpx`,
        `cold ${cold.ms.toFixed(0)}ms, warm ${warm.ms.toFixed(0)}ms, ${kb(cold.buffer.length)}`,
      );
    }
  } finally {
    await renderer.close?.();
  }

  const failed = checks.filter((c) => !c.passed);
  console.log(`\n${checks.length - failed.length}/${checks.length} checks passed, ${notes.length} observations`);
  if (failed.length > 0) {
    console.log("\nNO-GO. A region capture that composes with the page's scroll cannot");
    console.log("carry a resident chunk: every chunk would hold pixels of wherever the");
    console.log("reader was standing, and nothing downstream could detect it.");
    process.exitCode = 1;
    return;
  }
  console.log("\nGO. The clip is document-absolute through CDP. Pin the origin anyway:");
  console.log("scroll to a fixed position before every capture and assert it afterwards.");
  console.log(`\nPNGs: ${path.relative(repoRoot, outDir)}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
