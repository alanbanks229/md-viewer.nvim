// How big should a resident chunk be, and what does the first capture cost?
//
// Chunk size is a responsiveness parameter before it is a throughput one: it
// bounds how long first paint takes and how long a scroll into uncaptured
// territory waits. Picking it from the Chromium ceilings would be picking it
// from the wrong constraint.
//
// registration.mjs measured a 13,089ms first capture against 161-250ms for
// every later one on Ubuntu 22.04 / Chrome 151, and showed that rebuilding the
// page and context does not restore it. This asks what that cost is attached
// to:
//
//   A. Does it scale with region size, or is it a fixed price?
//   B. Can it be discharged on a blank page, before any document exists?
//   C. What does a warm capture of each size cost, in ms and in bytes?
//
// If A is flat and B works, chunk size stops bearing on first paint at all and
// C alone sets it.
//
//   node scripts/resident/sizing.mjs [--link-bytes-per-sec 800000]
//
// One browser launch per cold measurement, so this takes a few minutes. Writes
// nothing but a table. Run it on the host you are shipping to.

import path from "node:path";
import { fileURLToPath } from "node:url";

import { BrowserRenderer } from "../../renderer/src/browser.js";
import { renderMarkdown } from "../../renderer/src/markdown.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..", "..");
const assetsDir = path.join(repoRoot, "renderer", "assets");

const VIEWPORT_W = 990;
const VIEWPORT_H = 1020;
const DEVICE_SCALE = 2;

// A single Page.captureScreenshot is safe to about this much. 12e6 / 1980
// device px wide is 6060 device px, so ~2.97 viewports at this width.
const MAX_REGION_PIXELS = 12000000;
const MAX_REGION_HEIGHT_PX = 16384;

const WARM_MULTIPLES = [0.5, 1, 1.5, 2, 2.5, 2.9];
const COLD_MULTIPLES = [0.5, 1.5, 2.9];
const WARM_REPEATS = 3;

// What a reader waits for when they scroll into uncaptured territory. An
// in-flight capture is never cancelled, so the worst case is two of these.
const REPRIORITISE_BUDGET_MS = 700;

const linkArgIndex = process.argv.indexOf("--link-bytes-per-sec");
const LINK_BYTES_PER_SEC = linkArgIndex > -1 ? Number(process.argv[linkArgIndex + 1]) : 800000;

function fixtureMarkdown(blocks = 900) {
  const lines = ["# Chunk sizing", ""];
  for (let index = 0; index < blocks; index += 1) {
    const label = String(index).padStart(4, "0");
    if (index % 20 === 0) lines.push(`## SECTION ${label}`, "");
    lines.push(`**BLOCK ${label}** The quick brown fox jumps over the lazy dog.`, "");
  }
  return lines.join("\n");
}

function regionFor(multiple) {
  const heightPx = Math.round(VIEWPORT_H * multiple);
  const devicePixels = VIEWPORT_W * DEVICE_SCALE * heightPx * DEVICE_SCALE;
  return { multiple, heightPx, megapixels: devicePixels / 1e6,
    overCeiling: heightPx * DEVICE_SCALE > MAX_REGION_HEIGHT_PX || devicePixels > MAX_REGION_PIXELS };
}

async function openRenderer(html) {
  const renderer = new BrowserRenderer({ assetsDir });
  await renderer.ensure({}, DEVICE_SCALE);
  await renderer.page.setViewportSize({ width: VIEWPORT_W, height: VIEWPORT_H });
  renderer.viewport = { width: VIEWPORT_W, height: VIEWPORT_H };
  if (html) {
    await renderer.loadDocument({
      documentId: "sizing", contentRevision: "1", layoutKey: "sizing",
      html, theme: "dark", fontSizePx: 16, scrollPastEnd: true, scrollPastEndOffsetPx: 22,
      width: VIEWPORT_W, height: VIEWPORT_H, animationIds: [],
    });
  }
  return renderer;
}

async function capture(renderer, heightPx) {
  const started = performance.now();
  try {
    const { data } = await renderer.cdp.send("Page.captureScreenshot", {
      format: "png", optimizeForSpeed: true, captureBeyondViewport: true,
      clip: { x: 0, y: 0, width: VIEWPORT_W, height: heightPx, scale: DEVICE_SCALE },
    });
    return { ms: performance.now() - started, bytes: Buffer.from(data, "base64").length };
  } catch (error) {
    return { ms: performance.now() - started, failed: String(error.message).split("\n")[0] };
  }
}

function wireMs(bytes) {
  return (bytes / LINK_BYTES_PER_SEC) * 1000;
}

function row(cells, widths) {
  return cells.map((cell, index) => String(cell).padStart(widths[index])).join("  ");
}

async function main() {
  const { html } = await renderMarkdown(fixtureMarkdown(), { rawHtml: false });
  const warmRegions = WARM_MULTIPLES.map(regionFor).filter((region) => !region.overCeiling);

  console.log("\nA. Is the first capture's cost attached to the region, or to the process?");
  console.log("   one browser launch per row\n");
  const coldWidths = [7, 8, 12];
  console.log(row(["vp", "Mpx", "first ms"], coldWidths));
  const cold = [];
  for (const region of COLD_MULTIPLES.map(regionFor)) {
    const renderer = await openRenderer(html);
    try {
      const first = await capture(renderer, region.heightPx);
      cold.push({ ...region, ms: first.ms, failed: first.failed });
      console.log(row([`${region.multiple}x`, region.megapixels.toFixed(1),
        first.failed ? `FAILED @${first.ms.toFixed(0)}` : first.ms.toFixed(0)], coldWidths));
    } finally { await renderer.close(); }
  }
  const spread = Math.max(...cold.map((c) => c.ms)) / Math.min(...cold.map((c) => c.ms));
  const pixelSpread = Math.max(...cold.map((c) => c.megapixels)) / Math.min(...cold.map((c) => c.megapixels));
  console.log(`\n  ${pixelSpread.toFixed(0)}x the pixels moved the cost ${spread.toFixed(1)}x.`);
  console.log(cold.some((c) => c.failed)
    ? "  At least one first capture FAILED outright -- see the note on timeouts below."
    : "");

  console.log("\nB. Can it be discharged on a blank page, before any document exists?\n");
  let dischargedMs = null;
  {
    const renderer = await openRenderer(null);
    try {
      const primer = await capture(renderer, VIEWPORT_H);
      await renderer.loadDocument({
        documentId: "sizing", contentRevision: "1", layoutKey: "sizing",
        html, theme: "dark", fontSizePx: 16, scrollPastEnd: true, scrollPastEndOffsetPx: 22,
        width: VIEWPORT_W, height: VIEWPORT_H, animationIds: [],
      });
      const largest = regionFor(WARM_MULTIPLES[WARM_MULTIPLES.length - 1]);
      const after = await capture(renderer, largest.heightPx);
      dischargedMs = after.ms;
      console.log(`  blank-page primer at 1x:        ${primer.failed ? "FAILED " : ""}${primer.ms.toFixed(0)}ms`);
      console.log(`  then ${largest.multiple}x on the real document: ${after.ms.toFixed(0)}ms`);
      const unprimed = cold.find((c) => c.multiple === largest.multiple);
      if (unprimed) console.log(`  the same capture unprimed:      ${unprimed.ms.toFixed(0)}ms`);
    } finally { await renderer.close(); }
  }

  console.log("\nC. Warm capture against region size\n");
  const widths = [7, 8, 10, 10, 10];
  console.log(row(["vp", "Mpx", "warm ms", "PNG KB", "wire ms"], widths));
  const measured = [];
  {
    const renderer = await openRenderer(html);
    try {
      await capture(renderer, VIEWPORT_H);
      for (const region of warmRegions) {
        const runs = [];
        for (let index = 0; index < WARM_REPEATS; index += 1) runs.push(await capture(renderer, region.heightPx));
        const ok = runs.filter((r) => !r.failed);
        if (ok.length === 0) { console.log(row([`${region.multiple}x`, region.megapixels.toFixed(1), "FAILED", "-", "-"], widths)); continue; }
        const warmMs = ok.reduce((sum, r) => sum + r.ms, 0) / ok.length;
        const bytes = ok[0].bytes;
        measured.push({ ...region, warmMs, bytes });
        console.log(row([`${region.multiple}x`, region.megapixels.toFixed(1), warmMs.toFixed(0),
          (bytes / 1024).toFixed(0), wireMs(bytes).toFixed(0)], widths));
      }
    } finally { await renderer.close(); }
  }

  console.log("\nDerived\n");
  const fits = measured.filter((m) => m.warmMs <= REPRIORITISE_BUDGET_MS);
  const target = fits.length ? fits[fits.length - 1] : null;
  console.log(`  reprioritisation budget ${REPRIORITISE_BUDGET_MS}ms admits up to `
    + `${target ? `${target.multiple}x viewport (${target.megapixels.toFixed(1)} Mpx, ${target.warmMs.toFixed(0)}ms)` : "nothing swept"}`);
  if (dischargedMs !== null && spread < 3) {
    console.log("  the first capture's cost is flat in region size and dischargeable on a");
    console.log("  blank page, so chunk size does not bear on first paint. Prime at startup");
    console.log("  and set the chunk target from the row above.");
  } else {
    console.log("  the first capture's cost follows the region, so chunk size is the only");
    console.log("  lever on first paint and the target must satisfy it cold, not warm.");
  }
  console.log(`\n  Any timeout must clear the first-capture cost measured in A. A capture path`);
  console.log(`  that is disabled on its first failure will be disabled for the whole process.`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
