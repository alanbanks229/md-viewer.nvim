// Link hit boxes, against a real Chromium.
//
// The terminal reports a cell, never a point inside it, and a cell is not the
// same shape as anything the document renders. On the estimated calibration
// tier (lua/md-viewer/coordinates.lua) a cell covers 10x20 CSS px while a
// rendered line is 25 px tall and an inline link's box is about 18. Those three
// numbers do not divide into each other, so the alignment between the cell grid
// and the text grid depends on where the document happens to be scrolled -- and
// with only the cell's centre resolved, there were alignments at which a link
// was unreachable from every cell in the window, at any click position.
//
// That is what this file pins: not "a link is clickable" at one convenient
// alignment, but at *every* alignment, swept one pixel at a time across a full
// cell height.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";
import { BrowserRenderer } from "../../renderer/src/browser.js";
import { renderMarkdown } from "../../renderer/src/markdown.js";
import { validateEnvelope } from "../../renderer/src/interact.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const assetsDir = path.resolve(here, "../../renderer/assets");

// The estimated tier's cell box, which is what a user without
// MD_VIEWER_CELL_WIDTH_PX/_HEIGHT_PX set actually gets.
const CELL_W = 10;
const CELL_H = 20;
const COLS = 99;
const ROWS = 56;

function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

const markdown = [
  "# Heading",
  "",
  ...Array.from({ length: 12 }, (_, i) => `Filler paragraph number ${i}, long enough to occupy a line of its own.\n`),
  "[Glow](https://example.invalid/glow) renders Markdown in the terminal, and this",
  "sentence continues past the link so the paragraph is more than one line tall.",
  "",
  ...Array.from({ length: 40 }, (_, i) => `Trailing paragraph number ${i}.\n`),
].join("\n");

test("a link stays clickable at every alignment of the cell grid against the text", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const { html, sourceMap } = renderMarkdown(markdown, { rawHtml: false, localImages: false });
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());

  const widthPx = COLS * CELL_W;
  const heightPx = ROWS * CELL_H;
  const params = {
    documentId: "hitbox", contentRevision: "1:0",
    viewport: { widthPx, heightPx, deviceScaleFactor: 1 },
    browser: { executable_path: executable, launch_timeout_ms: 20000 },
    theme: "dark", scrollY: 0, network: false, captureScale: "css",
    scrollPastEnd: true, scrollPastEndOffsetPx: 22, fontSizePx: 16,
  };
  const rendered = await renderer.render(params, html, 1);
  fs.unlinkSync(rendered.pngPath);

  let serial = 10;
  const activate = async (x, y, scrollY) => {
    const envelope = validateEnvelope({
      documentId: "hitbox", contentRevision: "1:0", action: "activate_at",
      viewportWidthPx: widthPx, viewportHeightPx: heightPx, scrollY,
      coordinates: { x, y },
      cellWidthPx: CELL_W, cellHeightPx: CELL_H,
      modifiers: { ctrl: true, shift: false, alt: false, meta: false }, clickCount: 1,
    });
    serial += 1;
    return renderer.interact(envelope, { html, sourceMap }, serial);
  };

  // One full cell height of alignments, one pixel at a time. Scrolling is the
  // only thing that moves the document relative to the cell grid, so this is
  // exhaustive rather than a sample: every phase the grid can ever take is here.
  const unreachable = [];
  const boxes = [];
  for (let scrollY = 0; scrollY < CELL_H; scrollY += 1) {
    await renderer.applyScroll(renderer.layout.documentHeight, heightPx, scrollY);
    const rect = await renderer.page.evaluate(() => {
      const a = document.querySelector('a[href="https://example.invalid/glow"]');
      const r = a.getBoundingClientRect();
      return { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
    });
    // Every cell whose box overlaps the anchor's rectangle at all. A cell that
    // merely touches an edge is included on purpose: the claim being tested is
    // that the whole rendered link is a hit box, not most of it.
    const cells = [];
    for (let row = Math.floor(rect.top / CELL_H); row <= Math.floor((rect.bottom - 0.01) / CELL_H); row += 1) {
      for (let col = Math.floor(rect.left / CELL_W); col <= Math.floor((rect.right - 0.01) / CELL_W); col += 1) {
        if (row < 0 || col < 0 || row >= ROWS || col >= COLS) continue;
        cells.push({ row, col });
      }
    }
    assert.ok(cells.length > 0, `no cell overlaps the link at scrollY ${scrollY}`);

    let reachable = 0;
    for (const cell of cells) {
      const result = await activate((cell.col + 0.5) * CELL_W, (cell.row + 0.5) * CELL_H, scrollY);
      if (result.kind === "link" && result.link.href === "https://example.invalid/glow") reachable += 1;
    }
    boxes.push(reachable);
    if (reachable === 0) unreachable.push({ scrollY, rect, cells: cells.length });
  }

  assert.deepEqual(unreachable, [],
    "the link was unreachable from every overlapping cell at these scroll positions");
  // Not just "reachable somewhere": a hit box one cell wide would pass the
  // check above and still be unusable. The rendered link is ~36 x 18 px, so at
  // any alignment it overlaps at least four columns across one or two rows.
  assert.ok(Math.min(...boxes) >= 4,
    `the smallest hit box across all alignments was ${Math.min(...boxes)} cells, which is too small to click`);
});

test("cells that overlap no link still report source, not a link", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const { html, sourceMap } = renderMarkdown(markdown, { rawHtml: false, localImages: false });
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());

  const widthPx = COLS * CELL_W;
  const heightPx = ROWS * CELL_H;
  const rendered = await renderer.render({
    documentId: "hitbox-negative", contentRevision: "1:0",
    viewport: { widthPx, heightPx, deviceScaleFactor: 1 },
    browser: { executable_path: executable, launch_timeout_ms: 20000 },
    theme: "dark", scrollY: 0, network: false, captureScale: "css",
    scrollPastEnd: true, scrollPastEndOffsetPx: 22, fontSizePx: 16,
  }, html, 1);
  fs.unlinkSync(rendered.pngPath);

  const rect = await renderer.page.evaluate(() => {
    const a = document.querySelector('a[href="https://example.invalid/glow"]');
    const r = a.getBoundingClientRect();
    return { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
  });

  // Preferring a link anywhere under the clicked cell is deliberate -- the cell
  // is the resolution limit of the input device -- but it must stay bounded by
  // that one cell. Two cells clear of the link, in each direction, is prose.
  let serial = 100;
  const probe = async (x, y) => {
    serial += 1;
    return renderer.interact(validateEnvelope({
      documentId: "hitbox-negative", contentRevision: "1:0", action: "activate_at",
      viewportWidthPx: widthPx, viewportHeightPx: heightPx, scrollY: 0,
      coordinates: { x, y }, cellWidthPx: CELL_W, cellHeightPx: CELL_H,
      modifiers: { ctrl: true, shift: false, alt: false, meta: false }, clickCount: 1,
    }), { html, sourceMap }, serial);
  };

  const midY = (rect.top + rect.bottom) / 2;
  const rightOfLink = await probe(rect.right + 2 * CELL_W, midY);
  assert.equal(rightOfLink.kind, "source", "text two cells right of the link is not the link");
  assert.notEqual(rightOfLink.sourcePosition.precision, "none", "and it still resolves to a source position");

  const belowLink = await probe((rect.left + rect.right) / 2, rect.bottom + 2 * CELL_H);
  assert.equal(belowLink.kind, "source", "text two cell rows below the link is not the link");
});
