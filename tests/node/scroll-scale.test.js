// `render.scroll_scale` on the renderer side: the numeric factor that shrinks
// the moving frame of a scroll.
//
// The saving is the entire point of the option, so it is asserted in pixels
// rather than in bytes -- PNG size depends on content, but a capture that was
// asked for half scale either came back half the size or the option did
// nothing. The three things that must hold: the factor applies to the moving
// (`css`) capture, it never reaches the settle (`device`) capture, and an
// absent factor produces the byte-identical frame it produced before this
// existed.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { BrowserRenderer } from "../../renderer/src/browser.js";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";

const assetsDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../renderer/assets");

function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

const pngWidth = (file) => fs.readFileSync(file).readUInt32BE(16);
const pngHeight = (file) => fs.readFileSync(file).readUInt32BE(20);

test("a sub-1x scroll scale shrinks the moving frame and never the settle frame", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());

  const params = {
    documentId: "scroll-scale", contentRevision: 1,
    viewport: { widthPx: 640, heightPx: 480, deviceScaleFactor: 2 },
    browser: { executable_path: executable }, theme: "dark", scrollY: 0,
    captureScale: "device", scrollPastEnd: true, scrollPastEndOffsetPx: 22,
  };
  const html = '<h1 data-source-start="0" data-source-end="1">Heading</h1>'
    + '<p data-source-start="1" data-source-end="2">body text that compresses like real prose</p>';

  let request = 0;
  const capture = (overrides) => renderer.render({ ...params, ...overrides }, html, ++request);

  // The settle frame, and the baseline every reduced frame is measured against.
  const settle = await capture({ captureScale: "device" });
  assert.equal(pngWidth(settle.pngPath), 1280);
  assert.equal(pngHeight(settle.pngPath), 960);

  const moving = await capture({ captureScale: "css" });
  assert.equal(pngWidth(moving.pngPath), 640);
  assert.equal(pngHeight(moving.pngPath), 480);
  assert.equal(moving.captureScaleFactor, undefined, "an absent factor stays absent in the response");

  // The numeric clip scale only exists on the CDP path; Playwright's own
  // `scale` is a two-value enum. A browser that refused the fast encoder
  // returns full-size frames, which is correct and merely larger -- so the
  // reduction cannot be asserted there.
  if (moving.captureEncoder !== "cdp_fast_png") {
    t.skip(`fast PNG encoder unavailable (${moving.captureEncoder}); the numeric clip scale needs it`);
    return;
  }

  const full = await capture({ captureScale: "css", captureScaleFactor: 1 });
  assert.equal(pngWidth(full.pngPath), 640);
  assert.equal(pngHeight(full.pngPath), 480);
  // Not merely the same dimensions -- the same bytes. This is the
  // backward-compatibility claim: a session that sends no factor, and a session
  // that sends 1, get the frame the plugin produced before the option existed.
  assert.equal(full.pngBytes, moving.pngBytes, "a factor of 1 is the frame that was produced before");

  const half = await capture({ captureScale: "css", captureScaleFactor: 0.5 });
  assert.equal(pngWidth(half.pngPath), 320);
  assert.equal(pngHeight(half.pngPath), 240);
  assert.equal(half.captureScale, "css", "the tier the Lua side keys its bookkeeping off is unchanged");
  assert.equal(half.captureScaleFactor, 0.5, "the factor is echoed so :MdViewerDebug can report it");
  assert.ok(half.pngBytes < moving.pngBytes, "a half-scale frame is smaller than a full one");

  const quarter = await capture({ captureScale: "css", captureScaleFactor: 0.25 });
  assert.equal(pngWidth(quarter.pngPath), 160);
  assert.equal(pngHeight(quarter.pngPath), 120);

  // The settle frame is what a reader actually looks at. A factor reaching it
  // would leave an idle preview permanently soft, which is the one failure this
  // option must not be able to cause -- so it is refused on the renderer side
  // as well as never sent by the Lua side.
  const settleWithFactor = await capture({ captureScale: "device", captureScaleFactor: 0.5 });
  assert.equal(pngWidth(settleWithFactor.pngPath), 1280, "the settle frame ignores the scroll factor");
  assert.equal(pngHeight(settleWithFactor.pngPath), 960);
  assert.equal(settleWithFactor.captureScaleFactor, undefined, "and does not claim to have applied one");

  // Clamped rather than trusted, for the same reason `deviceScaleFactor` is:
  // this side does not rely on the caller having validated anything.
  for (const [factor, width, height, label] of [
    [0.01, 160, 120, "below the floor"],
    [5, 640, 480, "above natural size"],
    ["half", 640, 480, "not a number"],
    [Number.NaN, 640, 480, "not finite"],
  ]) {
    const clamped = await capture({ captureScale: "css", captureScaleFactor: factor });
    assert.equal(pngWidth(clamped.pngPath), width, `a factor ${label} is clamped, not obeyed`);
    assert.equal(pngHeight(clamped.pngPath), height, `a factor ${label} is clamped on both axes`);
  }
});
