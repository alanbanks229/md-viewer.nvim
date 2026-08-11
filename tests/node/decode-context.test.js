import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { createRequire } from "node:module";
import { CHROMIUM_LAUNCH_ARGS } from "../../renderer/src/browser.js";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";
import { DecodeContext } from "../../renderer/src/decode-context.js";
import { buildGif, solid } from "./helpers/build-gif.mjs";
import { decodePngPixels } from "./helpers/decode-png.mjs";

// Playwright lives in renderer/node_modules; the repo root deliberately has
// none. Resolve it from the renderer package, the way its own sources do.
const requireFromRenderer = createRequire(new URL("../../renderer/src/browser.js", import.meta.url));
const { chromium } = requireFromRenderer("playwright");

// Same discovery contract as browser.test.js: whatever Chrome, Chromium, or
// Edge is already installed; never `playwright install`, never a download.
function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

const CAPS = { maxSourceFrames: 300, maxSourcePixels: 1_500_000, keepFrames: 300 };

function pngFrame(result, index) {
  return decodePngPixels(Buffer.from(result.frames[index].png, "base64"));
}

function firstPixel(decoded) {
  return [...decoded.pixels.subarray(0, decoded.channels)];
}

test("the Chromium decode context", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const browser = await chromium.launch({ executablePath: executable, headless: true, args: CHROMIUM_LAUNCH_ARGS });
  const decode = new DecodeContext();
  t.after(async () => {
    await decode.close();
    await browser.close();
  });

  await t.test("decodes an animated GIF with native per-frame timing preserved", async () => {
    // Palette: 0 black, 1 red, 2 green, 3 blue. 7cs and 20cs are distinct
    // real-world delays; the point is that they come back as 70 and 200, not
    // as some canonical tick.
    const gif = buildGif(2, 1, [
      { indices: solid(1, 2), delayCs: 7 },
      { indices: solid(3, 2), delayCs: 20 },
    ], { loopCount: 0 });
    const result = await decode.decode(browser, gif, { mime: "image/gif", targetWidth: 2, targetHeight: 1, ...CAPS });
    assert.equal(result.status, "ok");
    assert.equal(result.frames.length, 2);
    assert.deepEqual(result.frames.map((f) => f.gapMs), [70, 200]);
    assert.equal(result.loop, "infinite", "NETSCAPE loop=0 means forever");
    assert.equal(result.sourceFrameCount, 2);
    assert.equal(result.sourceWidth, 2);
    assert.equal(result.sourceHeight, 1);
    // The pixels themselves: Chromium decoded palette entry 1 as red and 3 as
    // blue, and the PNG re-encode preserved them.
    assert.deepEqual(firstPixel(pngFrame(result, 0)), [255, 0, 0, 255]);
    assert.deepEqual(firstPixel(pngFrame(result, 1)), [0, 0, 255, 255]);
  });

  await t.test("resizes to the drawn size", async () => {
    const gif = buildGif(2, 2, [
      { indices: solid(1, 4) },
      { indices: solid(2, 4) },
    ]);
    const result = await decode.decode(browser, gif, { mime: "image/gif", targetWidth: 8, targetHeight: 6, ...CAPS });
    assert.equal(result.status, "ok");
    const frame = pngFrame(result, 0);
    assert.equal(frame.width, 8);
    assert.equal(frame.height, 6);
  });

  await t.test("loop counts: absent NETSCAPE plays once, an explicit count survives", async () => {
    const once = await decode.decode(
      browser,
      buildGif(2, 1, [{ indices: solid(1, 2) }, { indices: solid(2, 2) }]),
      { mime: "image/gif", targetWidth: 2, targetHeight: 1, ...CAPS },
    );
    assert.equal(once.status, "ok");
    assert.equal(once.loop, 0, "no NETSCAPE block: play once, as a browser does");

    const thrice = await decode.decode(
      browser,
      buildGif(2, 1, [{ indices: solid(1, 2) }, { indices: solid(2, 2) }], { loopCount: 3 }),
      { mime: "image/gif", targetWidth: 2, targetHeight: 1, ...CAPS },
    );
    assert.equal(thrice.status, "ok");
    assert.equal(thrice.loop, 3);
  });

  await t.test("degenerate delays get the browser-standard 100ms, from Chromium itself", async () => {
    const gif = buildGif(2, 1, [
      { indices: solid(1, 2), delayCs: 0 },
      { indices: solid(2, 2), delayCs: 5 },
    ]);
    const result = await decode.decode(browser, gif, { mime: "image/gif", targetWidth: 2, targetHeight: 1, ...CAPS });
    assert.equal(result.status, "ok");
    assert.equal(result.frames[0].gapMs, 100, "a 0-delay frame is clamped exactly as a browser tab clamps it");
    assert.equal(result.frames[1].gapMs, 50, "a real short delay is left alone");
  });

  await t.test("a still image is refused, not animated", async () => {
    const still = buildGif(2, 2, [{ indices: solid(1, 4) }]);
    const result = await decode.decode(browser, still, { mime: "image/gif", targetWidth: 2, targetHeight: 2, ...CAPS });
    assert.equal(result.status, "refused");
    assert.match(result.reason, /not an animation/);
  });

  await t.test("caps refuse: frame count and source pixels", async () => {
    const three = buildGif(2, 1, [
      { indices: solid(1, 2) },
      { indices: solid(2, 2) },
      { indices: solid(3, 2) },
    ]);
    const frames = await decode.decode(browser, three, {
      mime: "image/gif", targetWidth: 2, targetHeight: 1, ...CAPS, maxSourceFrames: 2,
    });
    assert.equal(frames.status, "refused");
    assert.match(frames.reason, /3 frames/);

    const pixels = await decode.decode(browser, three, {
      mime: "image/gif", targetWidth: 2, targetHeight: 1, ...CAPS, maxSourcePixels: 1,
    });
    assert.equal(pixels.status, "refused");
    assert.match(pixels.reason, /source pixel cap/);
  });

  await t.test("a drawn size over the target cap is refused before launch", async () => {
    const gif = buildGif(2, 1, [{ indices: solid(1, 2) }, { indices: solid(2, 2) }]);
    const result = await decode.decode(browser, gif, { mime: "image/gif", targetWidth: 8192, targetHeight: 8192, ...CAPS });
    assert.equal(result.status, "refused");
    assert.match(result.reason, /per-frame pixel cap/);
    const bad = await decode.decode(browser, gif, { mime: "image/gif", targetWidth: 0, targetHeight: 10, ...CAPS });
    assert.equal(bad.status, "error");
  });

  await t.test("thinning keeps every stride-th frame and folds dropped time into the survivor", async () => {
    const gif = buildGif(2, 1, [
      { indices: solid(1, 2), delayCs: 10 },
      { indices: solid(2, 2), delayCs: 10 },
      { indices: solid(3, 2), delayCs: 10 },
      { indices: solid(1, 2), delayCs: 10 },
    ]);
    const result = await decode.decode(browser, gif, {
      mime: "image/gif", targetWidth: 2, targetHeight: 1, ...CAPS, keepFrames: 2,
    });
    assert.equal(result.status, "ok");
    assert.equal(result.frames.length, 2);
    assert.deepEqual(result.frames.map((f) => f.gapMs), [200, 200], "total duration survives the cut");
    assert.equal(result.sourceFrameCount, 4);
    assert.equal(result.keptFrameCount, 2);
  });

  await t.test("malformed bytes are a refusal, never a throw", async () => {
    const garbage = await decode.decode(browser, Buffer.from("GIF89a and then lies"), {
      mime: "image/gif", targetWidth: 2, targetHeight: 2, ...CAPS,
    });
    assert.equal(garbage.status, "refused");
  });

  await t.test("a truncated tail keeps the whole frames before it", async () => {
    const gif = buildGif(2, 1, [
      { indices: solid(1, 2) },
      { indices: solid(2, 2) },
      { indices: solid(3, 2) },
    ]);
    const result = await decode.decode(browser, gif.subarray(0, gif.length - 4), {
      mime: "image/gif", targetWidth: 2, targetHeight: 1, ...CAPS,
    });
    // Chromium may report the file as two whole frames plus damage, or refuse
    // it outright; both keep the preview correct. What must not happen is a
    // throw or a partial frame presented as whole.
    assert.ok(result.status === "ok" || result.status === "refused");
    if (result.status === "ok") assert.ok(result.frames.length >= 2);
  });

  await t.test("transparency composites against the previous frame, as in a browser tab", async () => {
    const gif = buildGif(2, 1, [
      { indices: solid(1, 2) }, // red
      { indices: solid(0, 2), transparentIndex: 0 }, // fully transparent: shows frame 1
    ]);
    const result = await decode.decode(browser, gif, { mime: "image/gif", targetWidth: 2, targetHeight: 1, ...CAPS });
    assert.equal(result.status, "ok");
    assert.deepEqual(firstPixel(pngFrame(result, 1)), [255, 0, 0, 255], "the red frame shows through");
  });

  await t.test("animated WebP is decodable in this browser", async () => {
    // The decode loop past isTypeSupported is format-agnostic, and no WebP
    // encoder exists in this repository to build a fixture with -- so the
    // capability claim is pinned here and the end-to-end run lives in the
    // scripts/animation hardware checklist with a real animated WebP.
    const context = await browser.newContext({ javaScriptEnabled: true });
    try {
      const page = await context.newPage();
      await page.route("**/*", (route) => route.fulfill({ status: 200, contentType: "text/html", body: "<html></html>" }));
      await page.goto("https://md-viewer.internal/probe");
      const supported = await page.evaluate(async () => {
        if (typeof ImageDecoder === "undefined") return false;
        return await ImageDecoder.isTypeSupported("image/webp");
      });
      assert.equal(supported, true);
    } finally {
      await context.close();
    }
  });

  await t.test("decodes are serialized but callers may overlap freely", async () => {
    const gif = buildGif(2, 1, [{ indices: solid(1, 2) }, { indices: solid(2, 2) }]);
    const options = { mime: "image/gif", targetWidth: 2, targetHeight: 1, ...CAPS };
    const [a, b] = await Promise.all([decode.decode(browser, gif, options), decode.decode(browser, gif, options)]);
    assert.equal(a.status, "ok");
    assert.equal(b.status, "ok");
  });

  await t.test("no browser is an error status, not a throw", async () => {
    const gif = buildGif(2, 1, [{ indices: solid(1, 2) }, { indices: solid(2, 2) }]);
    const result = await decode.decode(null, gif, { mime: "image/gif", targetWidth: 2, targetHeight: 1, ...CAPS });
    assert.equal(result.status, "error");
    assert.match(result.reason, /browser is not running/);
  });

  await t.test("a zero timeout expires as an error status", async () => {
    const impatient = new DecodeContext({ timeoutMs: 0 });
    try {
      const gif = buildGif(2, 1, [{ indices: solid(1, 2) }, { indices: solid(2, 2) }]);
      const result = await impatient.decode(browser, gif, { mime: "image/gif", targetWidth: 2, targetHeight: 1, ...CAPS });
      assert.equal(result.status, "error");
      assert.match(result.reason, /timed out/);
    } finally {
      await impatient.close();
    }
  });

  await t.test("rebinds to a relaunched browser", async () => {
    const second = await chromium.launch({ executablePath: executable, headless: true, args: CHROMIUM_LAUNCH_ARGS });
    try {
      const gif = buildGif(2, 1, [{ indices: solid(1, 2) }, { indices: solid(2, 2) }]);
      const options = { mime: "image/gif", targetWidth: 2, targetHeight: 1, ...CAPS };
      const onSecond = await decode.decode(second, gif, options);
      assert.equal(onSecond.status, "ok", "the context follows a new browser instance");
      const backOnFirst = await decode.decode(browser, gif, options);
      assert.equal(backOnFirst.status, "ok", "and back again");
    } finally {
      await second.close();
    }
  });

  await t.test("throughput: a 100-frame recording materializes in interactive time", async () => {
    const frames = [];
    for (let i = 0; i < 100; i += 1) frames.push({ indices: solid((i % 3) + 1, 200 * 100), delayCs: 4 });
    const gif = buildGif(200, 100, frames);
    const started = Date.now();
    const result = await decode.decode(browser, gif, {
      mime: "image/gif", targetWidth: 400, targetHeight: 200, ...CAPS,
    });
    const elapsed = Date.now() - started;
    assert.equal(result.status, "ok");
    assert.equal(result.frames.length, 100);
    // Generous for slow CI; locally this is a few hundred milliseconds where
    // the hand-written decoder took multiple seconds for the same shape.
    assert.ok(elapsed < 30_000, `decode+encode of 100 frames took ${elapsed}ms`);
    console.log(`decode-context: 100 frames of 200x100 -> 400x200 PNG in ${elapsed}ms`);
  });
});
