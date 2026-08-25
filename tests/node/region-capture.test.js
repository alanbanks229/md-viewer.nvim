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

const here = path.dirname(fileURLToPath(import.meta.url));
const assetsDir = path.resolve(here, "../../renderer/assets");

function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

const geometry = { documentHeight: 20000, viewportWidth: 990, deviceScaleFactor: 2 };

test("resolveCaptureRegion clamps to the document and refuses what Chromium cannot capture", () => {
  assert.deepEqual(resolveCaptureRegion({ yPx: 400, heightPx: 2040 }, geometry), { yPx: 400, heightPx: 2040 });

  assert.deepEqual(
    resolveCaptureRegion({ yPx: -50, heightPx: 1000 }, geometry), { yPx: 0, heightPx: 1000 },
    "a negative origin clamps to the top rather than wrapping",
  );
  assert.deepEqual(
    resolveCaptureRegion({ yPx: 19500, heightPx: 4000 }, geometry), { yPx: 19500, heightPx: 500 },
    "a region running past the end is truncated, not refused",
  );

  for (const bad of [{ yPx: NaN, heightPx: 100 }, { yPx: 0, heightPx: "tall" }, undefined]) {
    assert.throws(
      () => resolveCaptureRegion(bad, geometry),
      (error) => error.code === "INVALID_REQUEST",
      `${JSON.stringify(bad)} must be refused rather than coerced`,
    );
  }

  // 12,000,000 px / (990 * 2) is 6060 device px, so 3030 css px is the last
  // height that fits at this width.
  assert.deepEqual(resolveCaptureRegion({ yPx: 0, heightPx: 3030 }, geometry), { yPx: 0, heightPx: 3030 });
  assert.throws(
    () => resolveCaptureRegion({ yPx: 0, heightPx: 3031 }, geometry),
    (error) => error.code === "REGION_TOO_LARGE",
    "one css pixel over the pixel ceiling must be refused",
  );
  assert.throws(
    () => resolveCaptureRegion({ yPx: 0, heightPx: 9000 }, { ...geometry, viewportWidth: 100 }),
    (error) => error.code === "REGION_TOO_LARGE",
    "the height ceiling binds even when the pixel count does not",
  );
  assert.ok(MAX_REGION_PIXELS === 12000000 && MAX_REGION_HEIGHT_PX === 16384);
});

test("a region capture goes through CDP with captureBeyondViewport, and never through Playwright", async (t) => {
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
  renderer.viewport = { width: 990, height: 1020 };
  renderer.deviceScaleFactor = 2;
  renderer.primed = true;
  renderer.primerPromise = Promise.resolve();

  const sent = [];
  renderer.cdp = {
    send: async (method, params) => {
      sent.push({ method, params });
      return { data: Buffer.from("region").toString("base64") };
    },
  };
  let playwrightScreenshots = 0;
  let scrolledTo = 4800;
  renderer.page = {
    evaluate: async (fn, arg) => {
      const source = String(fn);
      if (source.includes("scrollTo")) { scrolledTo = arg ?? 0; return undefined; }
      return scrolledTo;
    },
    screenshot: async () => { playwrightScreenshots += 1; },
  };

  const pngPath = path.join(renderer.tempDir, "region.png");
  const encoder = await renderer.captureRegionPng(pngPath, { yPx: 6000, heightPx: 2040 });

  assert.equal(encoder, "cdp_region_png");
  assert.equal(playwrightScreenshots, 0, "page.screenshot({clip}) is not document-absolute and must never be reached");

  const capture = sent.find((entry) => entry.method === "Page.captureScreenshot");
  assert.ok(capture, "the capture must actually be sent");
  assert.equal(
    capture.params.captureBeyondViewport, true,
    "asserted on the sent payload: with this false Chromium returns a correctly sized PNG "
    + "whose beyond-the-fold band is only ~95% right, with no exception to notice",
  );
  assert.deepEqual(capture.params.clip, { x: 0, y: 6000, width: 990, height: 2040, scale: 2 });
  assert.equal(fs.readFileSync(pngPath, "utf8"), "region");
});

test("a region capture parks the page at the origin and puts it back", async (t) => {
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
  renderer.viewport = { width: 990, height: 1020 };
  renderer.deviceScaleFactor = 2;
  renderer.primed = true;
  renderer.primerPromise = Promise.resolve();
  renderer.active = { documentId: "d", scrollY: 4800 };

  const positions = [];
  let scrolledTo = 4800;
  renderer.cdp = { send: async () => ({ data: Buffer.from("x").toString("base64") }) };
  renderer.page = {
    evaluate: async (fn, arg) => {
      if (String(fn).includes("scrollTo")) { scrolledTo = arg ?? 0; positions.push(scrolledTo); return undefined; }
      return scrolledTo;
    },
    screenshot: async () => { throw new Error("must not be reached"); },
  };

  await renderer.captureRegionPng(path.join(renderer.tempDir, "parked.png"), { yPx: 0, heightPx: 2040 });
  assert.deepEqual(positions, [0, 4800], "parked at the origin for the capture, then restored for interaction");
});

test("a page that will not park at the origin refuses rather than capturing", async (t) => {
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
  renderer.viewport = { width: 990, height: 1020 };
  renderer.deviceScaleFactor = 2;
  renderer.primed = true;
  renderer.primerPromise = Promise.resolve();

  let captures = 0;
  renderer.cdp = { send: async () => { captures += 1; return { data: "" }; } };
  renderer.page = {
    evaluate: async (fn) => (String(fn).includes("scrollTo") ? undefined : 900),
    screenshot: async () => { throw new Error("must not be reached"); },
  };

  await assert.rejects(
    () => renderer.captureRegionPng(path.join(renderer.tempDir, "moved.png"), { yPx: 0, heightPx: 2040 }),
    (error) => error.code === "REGION_ORIGIN_MOVED",
  );
  assert.equal(captures, 0, "the refusal has to come before the capture, not after");
});

test("a renderer without a usable CDP session refuses a region instead of substituting one", async (t) => {
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
  renderer.viewport = { width: 990, height: 1020 };
  renderer.deviceScaleFactor = 2;
  renderer.cdp = null;
  renderer.cdpCaptureUnavailable = "newCDPSession failed";
  let playwrightScreenshots = 0;
  renderer.page = { screenshot: async () => { playwrightScreenshots += 1; } };

  await assert.rejects(
    () => renderer.captureRegionPng(path.join(renderer.tempDir, "no-cdp.png"), { yPx: 0, heightPx: 2040 }),
    (error) => error.code === "REGION_CAPTURE_UNSUPPORTED",
  );
  assert.equal(playwrightScreenshots, 0);
});

test("the region timeout clears the first capture's cost, and shrinks once primed", async (t) => {
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
  renderer.viewport = { width: 990, height: 1020 };
  renderer.deviceScaleFactor = 2;

  const region = { yPx: 0, heightPx: 3030 };
  renderer.primed = false;
  const unprimed = renderer.regionCaptureTimeoutMs(region);
  renderer.primed = true;
  const primed = renderer.regionCaptureTimeoutMs(region);

  // Measured on Ubuntu 22.04 / Chrome 151: an unprimed first capture costs
  // 9,874-16,335ms whatever its size. A budget under that disables the capture
  // path for the life of the process the first time it is hit.
  assert.ok(unprimed > 16335, `an unprimed 12 Mpx region allowed only ${unprimed}ms`);
  assert.ok(primed < unprimed, "a primed renderer must not keep paying for a cost it has already discharged");
  assert.ok(primed >= renderer.cdpCaptureTimeoutMs, "never below the ordinary capture budget");

  const small = renderer.regionCaptureTimeoutMs({ yPx: 0, heightPx: 100 });
  assert.equal(small, renderer.cdpCaptureTimeoutMs, "a tiny region floors at the ordinary budget rather than under it");
});

test("the same region returns the same pixels from any scroll position", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());

  const blocks = [];
  for (let index = 0; index < 220; index += 1) {
    const label = String(index).padStart(3, "0");
    blocks.push(`<p data-source-start="${index}" data-source-end="${index + 1}">BLOCK ${label} the quick brown fox</p>`);
  }
  const params = {
    documentId: "region-doc", contentRevision: 1,
    viewport: { widthPx: 640, heightPx: 480, deviceScaleFactor: 2 },
    browser: { executable_path: executable }, theme: "dark", scrollY: 0,
    captureScale: "device", scrollPastEnd: true, scrollPastEndOffsetPx: 22,
  };
  const html = `<h1 data-source-start="0" data-source-end="1">Region</h1>${blocks.join("")}`;

  const first = await renderer.render(params, html, 1);
  const documentHeight = first.documentHeightPx;
  const captureRegion = { yPx: 0, heightPx: 900 };

  const digests = [];
  for (const scrollY of [0, Math.floor((documentHeight - 480) / 2), documentHeight - 480]) {
    const result = await renderer.render({ ...params, scrollY, captureRegion }, html, 10 + digests.length);
    assert.equal(result.regionYPx, 0, "the reply must echo the region that was asked for");
    assert.equal(result.regionHeightPx, 900);
    assert.equal(result.captureEncoder, "cdp_region_png");
    digests.push(fs.readFileSync(result.pngPath));
    fs.unlinkSync(result.pngPath);
  }

  // The assertion the previous attempt at this feature never had. A clip that
  // composes with window.scrollY produces chunks of the wrong part of the
  // document while every downstream coordinate stays provably correct.
  assert.ok(digests[1].equals(digests[0]), "region captured mid-document differs from the same region at the top");
  assert.ok(digests[2].equals(digests[0]), "region captured at the end differs from the same region at the top");

  fs.unlinkSync(first.pngPath);
});
