// The selection tint contract and the composite-equivalence gate.
//
// Three layers, weakest to strongest:
//   1. Pure: envelope opt-out (`capture: false`), overlaySheet validation,
//      rect passthrough, and the solid tint-sheet PNG builder.
//   2. The pin: the ::selection rule in the theme CSS and SELECTION_TINT in
//      interact.js must paint the same color. Measured from real captured
//      pixels, using the compositing model Chromium actually applies (alpha
//      quantized to 8 bits, then rounded integer src-over) -- if either side
//      drifts, this fails.
//   3. The equivalence gate: compositing the tint over a selection-cleared
//      base frame at the reported rect geometry must reproduce the browser's
//      own selection_commit capture exactly on every flat-background sample
//      away from rect edges. Rect-edge bands (sub-pixel rounding) and glyph
//      pixels (the browser paints selection under glyphs; the terminal
//      overlay sits above them) are the two known, bounded approximations --
//      they are measured and reported, not asserted equal.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { decodePngPixels } from "./helpers/decode-png.mjs";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";
import { validateEnvelope, buildSelectionResult, SELECTION_TINT, MAX_SELECTION_RECTS } from "../../renderer/src/interact.js";
import { buildOverlaySheetPng, MAX_SHEET_DIMENSION } from "../../renderer/src/overlay-sheet.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const main = path.resolve(here, "../../renderer/src/main.js");

function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Pure surface.
// ---------------------------------------------------------------------------

const BASE_ENVELOPE = {
  documentId: "buffer-1", contentRevision: "1:0", action: "selection_preview",
  viewportWidthPx: 800, viewportHeightPx: 600,
  coordinates: { x: 10, y: 10 }, anchorCoordinates: { x: 5, y: 5 },
};

test("capture:false opts a mutating selection action out of the screenshot", () => {
  assert.equal(validateEnvelope({ ...BASE_ENVELOPE }).capture, true,
    "selection_preview captures by default (mutatesVisibleState)");
  assert.equal(validateEnvelope({ ...BASE_ENVELOPE, capture: false }).capture, false,
    "capture:false must be honored for the overlay path");
  assert.equal(validateEnvelope({ ...BASE_ENVELOPE, action: "selection_commit", capture: false }).capture, false);
  assert.equal(validateEnvelope({ ...BASE_ENVELOPE, capture: true }).capture, true);
});

test("overlaySheet is validated as {widthPx, heightPx} with optional margins", () => {
  assert.equal(validateEnvelope({ ...BASE_ENVELOPE }).overlaySheet, null);
  assert.deepEqual(
    validateEnvelope({ ...BASE_ENVELOPE, overlaySheet: { widthPx: 1980, heightPx: 2040 } }).overlaySheet,
    { widthPx: 1980, heightPx: 2040, marginX: 0, marginY: 0 },
    "an absent margin normalizes to zero, which builds the sheet every terminal but WezTerm gets"
  );
  assert.deepEqual(
    validateEnvelope({
      ...BASE_ENVELOPE,
      overlaySheet: { widthPx: 1980, heightPx: 2040, marginX: 14, marginY: 32 },
    }).overlaySheet,
    { widthPx: 1980, heightPx: 2040, marginX: 14, marginY: 32 }
  );
  for (const bad of [
    "sheet",
    [1, 2],
    { widthPx: 0, heightPx: 10 },
    { widthPx: 10 },
    { widthPx: 10, heightPx: NaN },
    // A margin has to leave some sheet behind, or every crop of it is empty.
    { widthPx: 10, heightPx: 10, marginX: 10 },
    { widthPx: 10, heightPx: 10, marginY: 99 },
    { widthPx: 10, heightPx: 10, marginX: -1 },
    { widthPx: 10, heightPx: 10, marginY: NaN },
  ]) {
    assert.throws(() => validateEnvelope({ ...BASE_ENVELOPE, overlaySheet: bad }), (error) => {
      assert.equal(error.code, "INVALID_INTERACTION");
      return true;
    }, `overlaySheet=${JSON.stringify(bad)}`);
  }
});

test("buildSelectionResult passes selection rect geometry through", () => {
  const raw = {
    ok: true, text: "abc", collapsed: false,
    rects: [{ x: 1, y: 2, width: 3, height: 4 }], rectsTruncated: false,
    anchor: null, focus: null,
  };
  const result = buildSelectionResult(raw, null);
  assert.deepEqual(result.rects, [{ x: 1, y: 2, width: 3, height: 4 }]);
  assert.equal(result.rectsTruncated, false);
  const bare = buildSelectionResult({ ok: true, text: "", collapsed: true, anchor: null, focus: null }, null);
  assert.deepEqual(bare.rects, [], "actions that never measured rects report an empty list");
  assert.ok(MAX_SELECTION_RECTS >= 128, "the rect cap must comfortably exceed a real frame's 60-80 rects");
});


test("an overlay sheet margin is transparent, and absent by default", () => {
  const tint = SELECTION_TINT.dark;
  // Byte identity matters more than it looks: every terminal except WezTerm
  // keeps the marginless sheet, and those were validated against these exact
  // bytes. An optional parameter must not move them.
  assert.ok(
    buildOverlaySheetPng(64, 32, tint).equals(buildOverlaySheetPng(64, 32, tint, { x: 0, y: 0 })),
    "a zero margin produces the identical PNG"
  );

  // The margin is what lets a sub-cell offset be expressed in the image rather
  // than in the placement's X/Y keys, which is the only encoding WezTerm draws
  // as a solid bar: it insets every cell of a placement by X instead of only
  // the first, so a multi-cell bar comes out as a comb of stripes.
  const decoded = decodePngPixels(buildOverlaySheetPng(64, 32, tint, { x: 16, y: 8 }));
  const alphaAt = (x, y) => decoded.pixels[(y * decoded.width + x) * 4 + 3];
  assert.equal(alphaAt(15, 20), 0, "the left margin is fully transparent");
  assert.equal(alphaAt(20, 7), 0, "the top margin is fully transparent");
  assert.equal(alphaAt(15, 7), 0, "and so is the corner where they meet");
  assert.equal(alphaAt(16, 8), Math.round(tint.a * 255), "the body starts exactly at the margin");
  assert.equal(alphaAt(63, 31), Math.round(tint.a * 255), "and runs to the far corner");

  assert.throws(
    () => buildOverlaySheetPng(16, 32, tint, { x: 16, y: 0 }),
    /leaves nothing/,
    "a margin that consumes the whole sheet is refused rather than silently empty"
  );
});

test("buildOverlaySheetPng produces a solid straight-alpha sheet and caches it", () => {
  const tint = SELECTION_TINT.dark;
  const png = buildOverlaySheetPng(64, 32, tint);
  assert.equal(png, buildOverlaySheetPng(64, 32, tint), "same key must hit the cache");
  const decoded = decodePngPixels(png);
  assert.equal(decoded.width, 64);
  assert.equal(decoded.height, 32);
  assert.equal(decoded.channels, 4);
  const alpha = Math.round(tint.a * 255);
  for (const [x, y] of [[0, 0], [63, 0], [0, 31], [63, 31], [32, 16]]) {
    const at = (y * 64 + x) * 4;
    assert.deepEqual(
      [decoded.pixels[at], decoded.pixels[at + 1], decoded.pixels[at + 2], decoded.pixels[at + 3]],
      [tint.r, tint.g, tint.b, alpha],
      `sheet pixel at ${x},${y}`
    );
  }
  assert.throws(() => buildOverlaySheetPng(MAX_SHEET_DIMENSION + 1, 10, tint));
  assert.throws(() => buildOverlaySheetPng(0, 10, tint));
});

// ---------------------------------------------------------------------------
// Browser-backed: the pin and the equivalence gate.
// ---------------------------------------------------------------------------

function startRenderer(t, executable) {
  const child = spawn(process.execPath, [main], { stdio: ["pipe", "pipe", "pipe"] });
  t.after(() => { if (child.exitCode === null) child.kill("SIGTERM"); });
  const pending = new Map();
  const stderr = [];
  child.stderr.on("data", (chunk) => stderr.push(String(chunk)));
  readline.createInterface({ input: child.stdout }).on("line", (line) => {
    const message = JSON.parse(line);
    const settle = pending.get(message.id);
    if (settle) { pending.delete(message.id); settle(message); }
  });
  let nextId = 0;
  return {
    send(method, params) {
      nextId += 1;
      const id = nextId;
      const promise = new Promise((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error(`renderer timed out on ${method}; stderr: ${stderr.join("")}`)),
          30000
        );
        pending.set(id, (message) => { clearTimeout(timer); resolve(message); });
      });
      child.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
      return promise;
    },
  };
}

const DOC = [
  "# Equivalence Fixture",
  "",
  "Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau.",
  "",
  "Second paragraph with `inline code spans` and **bold text** plus enough additional prose that this "
    + "paragraph wraps across more than one rendered line of the preview viewport.",
  "",
  "```js",
  "const value = 1;",
  "",
  "const after_blank = 2;",
  "```",
  "",
].join("\n");

const THEME_BACKGROUNDS = {
  dark: { bg: [0x1e, 0x1e, 0x1e], codeBg: [0x2b, 0x2b, 0x2b] },
  light: { bg: [0xff, 0xff, 0xff], codeBg: [0xf6, 0xf8, 0xfa] },
};

/// The compositing model measured from Chromium itself: the CSS alpha is
/// quantized to 8 bits first, then integer src-over with round-to-nearest.
/// (0.3 -> 77/255; e.g. light-theme page bg 255 -> 216.65 -> 217, which plain
/// floating-point 0.3 would get wrong.)
function composite(tint, bg) {
  const alpha = Math.round(tint.a * 255);
  return bg.map((channel, i) => {
    const tintChannel = [tint.r, tint.g, tint.b][i];
    return Math.round((alpha * tintChannel + (255 - alpha) * channel) / 255);
  });
}

function renderParams(executable, theme, documentId) {
  return {
    documentId, markdown: DOC, contentRevision: "1:0",
    baseDir: here, documentRoot: here,
    viewport: { widthPx: 800, heightPx: 600, deviceScaleFactor: 2 },
    scrollY: 0, theme, rawHtml: false, localImages: false,
    maxLocalImageBytes: 1024, network: false,
    browser: { executable_path: executable, launch_timeout_ms: 10000 },
  };
}

function interactParams(documentId, overrides) {
  return {
    documentId, contentRevision: "1:0",
    viewportWidthPx: 800, viewportHeightPx: 600, scrollY: 0, ...overrides,
  };
}

const SELECTION = {
  anchorCoordinates: { x: 30, y: 95 },
  coordinates: { x: 700, y: 430 },
};

async function captureState(renderer, documentId, action, extra = {}) {
  const response = await renderer.send("interact", interactParams(documentId, { action, ...extra }));
  assert.equal(response.ok, true, JSON.stringify(response.error));
  let decoded = null;
  if (response.result.pngPath) {
    decoded = decodePngPixels(fs.readFileSync(response.result.pngPath));
    fs.unlinkSync(response.result.pngPath);
  }
  return { result: response.result, frame: decoded };
}

for (const theme of ["dark", "light"]) {
  test(`the ::selection rule and SELECTION_TINT.${theme} paint identical pixels (the pin)`, async (t) => {
    const executable = findRealChromium();
    if (!executable) {
      t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
      return;
    }
    const renderer = startRenderer(t, executable);
    const documentId = `tint-${theme}`;
    const rendered = await renderer.send("render", renderParams(executable, theme, documentId));
    assert.equal(rendered.ok, true, JSON.stringify(rendered.error));
    fs.unlinkSync(rendered.result.pngPath);

    const committed = await captureState(renderer, documentId, "selection_commit", SELECTION);
    assert.equal(committed.result.ok, true);
    assert.ok(committed.result.text.length > 40, "the fixture selection must cover real text");
    assert.deepEqual(committed.result.selectionTint, SELECTION_TINT[theme]);
    const cleared = await captureState(renderer, documentId, "selection_clear", { capture: true });

    const { bg, codeBg } = THEME_BACKGROUNDS[theme];
    const tint = SELECTION_TINT[theme];
    const base = cleared.frame;
    const sel = committed.frame;
    // A pixel is "flat background" only when its whole 3x3 neighbourhood is:
    // a lone glyph-antialiasing pixel can coincidentally hit the exact flat
    // color while its selection-frame counterpart composites differently.
    function flatAt(frame, x, y, flat) {
      for (let dy = -1; dy <= 1; dy += 1) {
        for (let dx = -1; dx <= 1; dx += 1) {
          const px = x + dx, py = y + dy;
          if (px < 0 || py < 0 || px >= frame.width || py >= frame.height) return false;
          const at = (py * frame.width + px) * frame.channels;
          if (frame.pixels[at] !== flat[0] || frame.pixels[at + 1] !== flat[1] || frame.pixels[at + 2] !== flat[2]) {
            return false;
          }
        }
      }
      return true;
    }
    for (const [label, flat] of [["page bg", bg], ["code bg", codeBg]]) {
      const expected = composite(tint, flat);
      let matching = 0;
      let mismatching = 0;
      for (let y = 0; y < base.height; y += 1) {
        for (let x = 0; x < base.width; x += 1) {
          if (!flatAt(base, x, y, flat)) continue;
          const at = (y * base.width + x) * base.channels;
          const r = sel.pixels[at], g = sel.pixels[at + 1], b = sel.pixels[at + 2];
          if (r === flat[0] && g === flat[1] && b === flat[2]) continue; // outside the selection
          if (r === expected[0] && g === expected[1] && b === expected[2]) matching += 1;
          else mismatching += 1;
        }
      }
      assert.ok(matching > 1000, `${theme}/${label}: expected a large tinted area, saw ${matching}`);
      // A wrong constant mismatches essentially every sample; the only
      // tolerated residue is the handful of anti-aliased pixels at the
      // fractional edges of Chromium's end-of-line/blank-line stubs, which
      // sit on flat background but composite partially. Measured at ~36 of
      // ~50k samples; 0.5% is far below any real color drift.
      assert.ok(mismatching <= matching * 0.005,
        `${theme}/${label}: selection-tinted flat pixels must equal rgb(${expected}); ${mismatching} of ${matching + mismatching} did not`);
    }
    await renderer.send("shutdown", {});
  });
}

test("overlay preview: no capture, rects present, sheet only on request", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = startRenderer(t, executable);
  const rendered = await renderer.send("render", renderParams(executable, "dark", "overlay-doc"));
  assert.equal(rendered.ok, true, JSON.stringify(rendered.error));
  fs.unlinkSync(rendered.result.pngPath);

  const preview = await renderer.send("interact", interactParams("overlay-doc", {
    action: "selection_preview", ...SELECTION, capture: false,
  }));
  assert.equal(preview.ok, true, JSON.stringify(preview.error));
  assert.equal(preview.result.pngPath, undefined, "capture:false must not screenshot");
  assert.equal(preview.result.ok, true);
  assert.ok(preview.result.rects.length >= 5, `expected several line rects, got ${preview.result.rects.length}`);
  assert.equal(preview.result.rectsTruncated, false);
  assert.equal(preview.result.overlaySheetPng, undefined, "the sheet is only built when asked for");
  assert.ok(preview.result.text.length > 40);
  for (const rect of preview.result.rects) {
    assert.ok(rect.x >= 0 && rect.y >= 0 && rect.width > 0 && rect.height > 0);
    assert.ok(rect.x + rect.width <= 800 + 0.5 && rect.y + rect.height <= 600 + 0.5, "rects are viewport-clipped");
    assert.ok(rect.height < 30, `a per-line rect must never be a block's border box (h=${rect.height})`);
    assert.ok(rect.height >= 15, `a rect must span the line box, not collapse (h=${rect.height})`);
  }
  // Shape regression guards, matching the measured browser paint: consecutive
  // lines of one block tile with no gap (their shared boundary appears as one
  // rect's bottom equalling the next one's top), and the highlight is ragged
  // -- rect widths differ line to line, never one full-width band.
  const sorted = [...preview.result.rects].sort((a, b) => a.y - b.y);
  let tiled = 0;
  for (let i = 1; i < sorted.length; i += 1) {
    if (Math.abs(sorted[i].y - (sorted[i - 1].y + sorted[i - 1].height)) < 0.6) tiled += 1;
  }
  assert.ok(tiled >= 2, `consecutive selected lines must tile (saw ${tiled} shared boundaries)`);
  const widths = new Set(sorted.map((rect) => Math.round(rect.width)));
  assert.ok(widths.size >= 3, "line rects must end where each line's text ends (ragged), not at one uniform width");

  const withSheet = await renderer.send("interact", interactParams("overlay-doc", {
    action: "selection_preview", ...SELECTION, capture: false,
    overlaySheet: { widthPx: 320, heightPx: 160 },
  }));
  assert.equal(withSheet.ok, true, JSON.stringify(withSheet.error));
  const sheet = decodePngPixels(Buffer.from(withSheet.result.overlaySheetPng, "base64"));
  assert.equal(sheet.width, 320);
  assert.equal(sheet.height, 160);
  const tint = SELECTION_TINT.dark;
  const centre = ((80 * 320) + 160) * 4;
  assert.deepEqual(
    [sheet.pixels[centre], sheet.pixels[centre + 1], sheet.pixels[centre + 2], sheet.pixels[centre + 3]],
    [tint.r, tint.g, tint.b, Math.round(tint.a * 255)]
  );
  await renderer.send("shutdown", {});
});

test("composite equivalence: base + tint at reported rects reproduces the browser's own selection frame", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = startRenderer(t, executable);
  const rendered = await renderer.send("render", renderParams(executable, "dark", "equiv-doc"));
  assert.equal(rendered.ok, true, JSON.stringify(rendered.error));
  fs.unlinkSync(rendered.result.pngPath);

  // Order matters: the settle capture and the rect geometry come from the
  // same committed selection; the base is captured after clearing it.
  const committed = await captureState(renderer, "equiv-doc", "selection_commit", SELECTION);
  assert.equal(committed.result.ok, true);
  const rects = committed.result.rects;
  assert.ok(rects.length >= 5, `fixture should produce several rects, got ${rects.length}`);
  const cleared = await captureState(renderer, "equiv-doc", "selection_clear", { capture: true });

  const base = cleared.frame;
  const settle = committed.frame;
  assert.equal(base.width, settle.width);
  assert.equal(base.height, settle.height);
  const scale = 2; // deviceScaleFactor of the render, matching production

  // Device-pixel rect grid, rounded exactly the way kitty_raw.overlay_apply
  // rounds (floor(v * scale + 0.5)).
  const deviceRects = rects.map((rect) => {
    const x0 = Math.floor(rect.x * scale + 0.5);
    const y0 = Math.floor(rect.y * scale + 0.5);
    const x1 = Math.floor((rect.x + rect.width) * scale + 0.5);
    const y1 = Math.floor((rect.y + rect.height) * scale + 0.5);
    return { x0, y0, x1, y1 };
  });

  const inside = new Uint8Array(base.width * base.height);
  const edgeBand = new Uint8Array(base.width * base.height);
  // 3 device px around every rect edge: the symmetric-half-leading
  // approximation places band edges within ~1 CSS px (2 device px) of
  // Chromium's own, and rect edges round to whole device pixels on top of
  // that. The right edge gets a wider 12px band: Chromium paints a ~4.8 CSS
  // px end-of-line continuation stub past the last glyph of every line that
  // flows on into the next, which the overlay deliberately does not
  // reproduce (a fraction of a cell, at a rect edge -- the stage's stated
  // acceptable approximation). Both remain *measured*: they land in
  // edgeDiffs, which has its own ceiling.
  const EDGE = 4;
  const EDGE_RIGHT = 12;
  for (const rect of deviceRects) {
    for (let y = Math.max(0, rect.y0 - EDGE); y < Math.min(base.height, rect.y1 + EDGE); y += 1) {
      for (let x = Math.max(0, rect.x0 - EDGE); x < Math.min(base.width, rect.x1 + EDGE_RIGHT); x += 1) {
        const index = y * base.width + x;
        const interior = x >= rect.x0 && x < rect.x1 && y >= rect.y0 && y < rect.y1;
        if (interior) inside[index] = 1;
        const nearEdge = x < rect.x0 + EDGE || x >= rect.x1 - EDGE || y < rect.y0 + EDGE || y >= rect.y1 - EDGE;
        if (nearEdge) edgeBand[index] = 1;
      }
    }
  }

  const tint = SELECTION_TINT.dark;
  const alpha = Math.round(tint.a * 255);
  const flats = [THEME_BACKGROUNDS.dark.bg, THEME_BACKGROUNDS.dark.codeBg];
  // A pixel counts as flat background only when its whole 3x3 neighbourhood
  // holds the same flat color -- a lone antialiasing pixel can coincidentally
  // equal the flat color while compositing differently in the settle frame.
  const flatMask = new Uint8Array(base.width * base.height);
  {
    const exact = new Uint8Array(base.width * base.height);
    for (let i = 0; i < base.width * base.height; i += 1) {
      const at = i * base.channels;
      for (let f = 0; f < flats.length; f += 1) {
        const flat = flats[f];
        if (base.pixels[at] === flat[0] && base.pixels[at + 1] === flat[1] && base.pixels[at + 2] === flat[2]) {
          exact[i] = f + 1;
          break;
        }
      }
    }
    for (let y = 1; y < base.height - 1; y += 1) {
      for (let x = 1; x < base.width - 1; x += 1) {
        const index = y * base.width + x;
        const kind = exact[index];
        if (!kind) continue;
        let uniform = true;
        for (let dy = -1; dy <= 1 && uniform; dy += 1) {
          for (let dx = -1; dx <= 1; dx += 1) {
            if (exact[index + dy * base.width + dx] !== kind) { uniform = false; break; }
          }
        }
        if (uniform) flatMask[index] = 1;
      }
    }
  }
  let flatChecked = 0;
  let flatMismatch = 0;
  let glyphDiffs = 0;
  let edgeDiffs = 0;
  let checkedAll = 0;
  const mismatchSamples = [];
  for (let y = 0; y < base.height; y += 1) {
    for (let x = 0; x < base.width; x += 1) {
      const index = y * base.width + x;
      const at = index * base.channels;
      const b0 = base.pixels[at], b1 = base.pixels[at + 1], b2 = base.pixels[at + 2];
      let expected0 = b0, expected1 = b1, expected2 = b2;
      if (inside[index]) {
        expected0 = Math.round((alpha * tint.r + (255 - alpha) * b0) / 255);
        expected1 = Math.round((alpha * tint.g + (255 - alpha) * b1) / 255);
        expected2 = Math.round((alpha * tint.b + (255 - alpha) * b2) / 255);
      }
      if (flatMask[index] && !edgeBand[index]) flatChecked += 1;
      const s0 = settle.pixels[at], s1 = settle.pixels[at + 1], s2 = settle.pixels[at + 2];
      const differs = s0 !== expected0 || s1 !== expected1 || s2 !== expected2;
      checkedAll += 1;
      if (!differs) continue;
      if (edgeBand[index]) { edgeDiffs += 1; continue; }
      if (flatMask[index]) {
        flatMismatch += 1;
        if (mismatchSamples.length < 8) {
          mismatchSamples.push({ x, y, base: [b0, b1, b2], settle: [s0, s1, s2], expected: [expected0, expected1, expected2], inside: inside[index] });
        }
      } else {
        glyphDiffs += 1;
      }
    }
  }

  // The report the stage prompt asks for, in the test output itself.
  const total = checkedAll;
  console.log(
    `composite equivalence: ${rects.length} rects; flat samples checked ${flatChecked}, mismatched ${flatMismatch}; `
      + `edge-band diffs ${edgeDiffs}; glyph-pixel diffs ${glyphDiffs} (of ${total} samples)`
  );
  assert.equal(flatMismatch, 0,
    `every flat-background sample away from rect edges must match exactly; ${flatMismatch} did not. `
      + `first samples: ${JSON.stringify(mismatchSamples)}`);
  assert.ok(flatChecked > 100000, "the fixture must actually exercise large flat regions");
  // Loose ceilings: these are the two known approximations, and they must
  // stay confined -- a wholesale geometry error would explode both.
  assert.ok(edgeDiffs < total * 0.01, `edge-band differences must stay confined (${edgeDiffs} of ${total})`);
  assert.ok(glyphDiffs < total * 0.03, `glyph-pixel differences must stay confined (${glyphDiffs} of ${total})`);

  await renderer.send("shutdown", {});
});
