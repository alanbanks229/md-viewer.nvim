import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";
import { BrowserRenderer } from "../../renderer/src/browser.js";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";
import { resolveSelectionInPage } from "../../renderer/src/interact.js";

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

// ---------------------------------------------------------------------------
// The fast PNG encoder.
//
// `browser.fast_png_encode` trades PNG compression ratio for encoder time.
// Comparing the two encodings byte-for-byte would only prove they differ, which
// is the point of the change; the claim that has to hold is that they carry the
// *same picture*. So decode both back to raw samples and compare those.
// ---------------------------------------------------------------------------

/// Enough of a PNG decoder to recover the raw samples Chromium encoded: 8-bit,
/// non-interlaced, which is all `Page.captureScreenshot` emits. Deliberately
/// not a dependency -- the whole value of this check is that it does not share
/// an encoder with the thing under test.
function decodePngPixels(buffer) {
  assert.equal(buffer.readUInt32BE(0), 0x89504e47, "not a PNG");
  let offset = 8;
  let width = 0, height = 0, depth = 0, colorType = 0, interlace = 0;
  const idat = [];
  while (offset < buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString("ascii", offset + 4, offset + 8);
    const data = buffer.subarray(offset + 8, offset + 8 + length);
    if (type === "IHDR") {
      width = data.readUInt32BE(0); height = data.readUInt32BE(4);
      depth = data[8]; colorType = data[9]; interlace = data[12];
    } else if (type === "IDAT") idat.push(data);
    else if (type === "IEND") break;
    offset += 12 + length;
  }
  assert.equal(depth, 8, "expected an 8-bit PNG");
  assert.equal(interlace, 0, "expected a non-interlaced PNG");
  const channels = { 0: 1, 2: 3, 4: 2, 6: 4 }[colorType];
  assert.ok(channels, `unsupported colour type ${colorType}`);
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const pixels = Buffer.alloc(height * stride);
  let pos = 0;
  for (let y = 0; y < height; y += 1) {
    const filter = raw[pos]; pos += 1;
    const line = raw.subarray(pos, pos + stride); pos += stride;
    const current = pixels.subarray(y * stride, (y + 1) * stride);
    const prior = y > 0 ? pixels.subarray((y - 1) * stride, y * stride) : null;
    for (let x = 0; x < stride; x += 1) {
      const a = x >= channels ? current[x - channels] : 0;
      const b = prior ? prior[x] : 0;
      const c = prior && x >= channels ? prior[x - channels] : 0;
      let value = line[x];
      if (filter === 1) value += a;
      else if (filter === 2) value += b;
      else if (filter === 3) value += (a + b) >> 1;
      else if (filter === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        value += (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
      }
      current[x] = value & 0xff;
    }
  }
  return { width, height, pixels };
}

// Detailed enough that a PNG encoder has real work to do, and tall enough to
// scroll: a frame of flat colour would compress identically either way and
// would prove nothing.
function tallHtml() {
  const parts = [];
  for (let i = 0; i < 120; i += 1) {
    parts.push(
      `<h2 data-source-start="${i * 3}" data-source-end="${i * 3 + 1}">Section ${i} — 日本語 🎉</h2>`
      + `<p data-source-start="${i * 3 + 1}" data-source-end="${i * 3 + 2}">`
      + `Paragraph ${i} with <strong>bold</strong>, <em>italic</em>, and <code>inline_code_${i}()</code> `
      + "plus enough prose to wrap across several lines of the rendered preview.</p>"
    );
  }
  return parts.join("");
}

/// Count differing samples between two decoded frames of the same size.
function pixelDifference(a, b) {
  assert.equal(a.width, b.width, "frame widths differ");
  assert.equal(a.height, b.height, "frame heights differ");
  let count = 0;
  let maxDelta = 0;
  for (let i = 0; i < a.pixels.length; i += 1) {
    const delta = Math.abs(a.pixels[i] - b.pixels[i]);
    if (delta) { count += 1; if (delta > maxDelta) maxDelta = delta; }
  }
  return { count, maxDelta, total: a.pixels.length };
}

test("the fast PNG encoder changes the bytes and not one pixel", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
  const params = {
    documentId: "encode-doc", contentRevision: 1,
    viewport: { widthPx: 800, heightPx: 600, deviceScaleFactor: 2 },
    browser: { executable_path: executable }, theme: "dark", scrollY: 0, network: false,
    captureScale: "device", scrollPastEnd: true, scrollPastEndOffsetPx: 22,
  };
  const html = tallHtml();

  // Every scale, and a scrolled position as well as the top: the clip a CDP
  // capture needs is in document coordinates, so an origin that ignored scroll
  // would pass at scrollY 0 and silently screenshot the wrong band everywhere
  // else.
  for (const captureScale of ["device", "css"]) {
    for (const scrollY of [0, 1500]) {
      const label = `${captureScale} @ scrollY=${scrollY}`;
      const rendered = await renderer.render({ ...params, captureScale, scrollY }, html, `enc-${captureScale}-${scrollY}`);
      assert.ok(rendered.scrollY === scrollY, `${label}: page did not reach the requested scroll`);
      assert.equal(rendered.captureEncoder, "cdp_fast_png", `${label}: expected the fast path`);

      // Both captures are taken after the page has already been captured once
      // at this state. Chromium's first capture after a DOM change can still be
      // settling a handful of anti-aliased samples, and that is a property of
      // capture timing, not of the encoder -- isolating the encoder means
      // taking that out of the comparison. The timing behaviour itself is what
      // the next test measures.
      const shot = async (fast, tag) => {
        renderer.fastPngEncode = fast;
        const capture = await renderer.captureViewport({
          documentId: "encode-doc", requestId: `${tag}-${captureScale}-${scrollY}`, captureScale,
        });
        assert.equal(capture.captureEncoder, fast ? "cdp_fast_png" : "playwright_png", `${label}: wrong path`);
        const bytes = fs.readFileSync(capture.pngPath);
        return { bytes, pixels: decodePngPixels(bytes) };
      };
      await shot(false, "warmup");
      const fast = await shot(true, "fast");
      const slow = await shot(false, "slow");
      renderer.fastPngEncode = true;

      const difference = pixelDifference(fast.pixels, slow.pixels);
      assert.equal(
        difference.count, 0,
        `${label}: the fast encoder changed ${difference.count} samples (max delta ${difference.maxDelta}) -- it must be lossless`
      );
      // If the two files matched byte-for-byte, the fast path silently did not
      // engage and the comparison above was a file against itself.
      assert.ok(!fast.bytes.equals(slow.bytes), `${label}: expected the two encodings to differ in bytes`);
      assert.ok(fast.bytes.length > slow.bytes.length, `${label}: expected the speed-optimised PNG to be larger`);
    }
  }
});

test("a drag frame paints the selection it reports, not the previous one", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
  const rendered = await renderer.render({
    documentId: "drag-doc", contentRevision: 1,
    viewport: { widthPx: 800, heightPx: 600, deviceScaleFactor: 1 },
    browser: { executable_path: executable }, theme: "dark", scrollY: 0, network: false,
    captureScale: "device", scrollPastEnd: true, scrollPastEndOffsetPx: 22,
  }, tallHtml(), "drag-0");
  fs.unlinkSync(rendered.pngPath);

  const capture = async (tag) => {
    const shot = await renderer.captureViewport({ documentId: "drag-doc", requestId: tag, captureScale: "device" });
    const pixels = decodePngPixels(fs.readFileSync(shot.pngPath));
    fs.unlinkSync(shot.pngPath);
    return pixels;
  };

  // The real hazard of a faster capture is not a softer frame -- it is a frame
  // that shows the *previous* selection while the response reports the current
  // one, which the operator would only discover on paste. Walk a drag and, for
  // every frame, check the frame taken the way production takes it (the first
  // capture after the mutation) against a settled capture of the same state and
  // against the previous frame's settled image.
  let previous = null;
  for (const focusY of [120, 200, 280, 360, 440]) {
    await renderer.page.evaluate(resolveSelectionInPage, {
      token: renderer.active.token,
      anchor: { x: 60, y: 60 }, focus: { x: 500, y: focusY }, cellWidthPx: 10,
    });
    const production = await capture(`prod-${focusY}`);
    await capture(`warm-${focusY}`);
    const settled = await capture(`settled-${focusY}`);

    const vsSettled = pixelDifference(production, settled);
    assert.ok(
      vsSettled.count / vsSettled.total < 0.0001,
      `focus ${focusY}: the captured frame differs from a settled capture of the same selection in `
      + `${vsSettled.count} of ${vsSettled.total} samples -- far more than anti-aliasing settling`
    );
    if (previous) {
      const vsPrevious = pixelDifference(production, previous);
      assert.ok(
        vsPrevious.count > vsSettled.count * 50,
        `focus ${focusY}: the captured frame is closer to the previous selection (${vsPrevious.count} samples) `
        + `than to this one (${vsSettled.count}) -- it painted a stale frame`
      );
    }
    previous = settled;
  }
});

test("a scrolled capture shows what is on screen, not the top of the document", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
  const params = {
    documentId: "scroll-doc", contentRevision: 1,
    viewport: { widthPx: 800, heightPx: 600, deviceScaleFactor: 1 },
    browser: { executable_path: executable }, theme: "dark", network: false,
    captureScale: "device", scrollPastEnd: true, scrollPastEndOffsetPx: 22,
  };
  const html = tallHtml();
  const top = await renderer.render({ ...params, scrollY: 0 }, html, "scroll-top");
  const middle = await renderer.render({ ...params, scrollY: 1500 }, html, "scroll-mid");
  assert.equal(middle.scrollY, 1500);
  const topPixels = decodePngPixels(fs.readFileSync(top.pngPath));
  const middlePixels = decodePngPixels(fs.readFileSync(middle.pngPath));
  // A clip whose origin ignored the page's scroll position would return the
  // document's first screenful for both, which is precisely the failure this
  // repository has already shipped once through `display_interact_result`.
  assert.ok(
    !topPixels.pixels.equals(middlePixels.pixels),
    "a scrolled frame is identical to the unscrolled one; the capture ignored scroll position"
  );

  // And a fragment jump moves the page from inside the document, without
  // anything passing a scrollY at all -- the capture must follow the page.
  const jumped = await renderer.scrollToFragment("#section-nope");
  assert.equal(jumped.found, false);
  const held = await renderer.captureViewport({ documentId: "scroll-doc", requestId: "held", captureScale: "device" });
  const heldPixels = decodePngPixels(fs.readFileSync(held.pngPath));
  assert.ok(
    heldPixels.pixels.equals(middlePixels.pixels),
    "a capture taken with no scroll request did not match the position the page was left at"
  );
});

test("browser.fast_png_encode = false keeps Playwright's encoder", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
  const params = {
    documentId: "opt-out", contentRevision: 1,
    viewport: { widthPx: 640, heightPx: 480, deviceScaleFactor: 1 },
    browser: { executable_path: executable, fast_png_encode: false },
    theme: "dark", scrollY: 0, network: false, captureScale: "device",
  };
  const off = await renderer.render(params, tallHtml(), "opt-out-1");
  assert.equal(off.captureEncoder, "playwright_png");
  assert.equal(renderer.fastPngEncode, false);
  // ...and the setting is re-read per request rather than latched at launch.
  const on = await renderer.render(
    { ...params, browser: { executable_path: executable, fast_png_encode: true } },
    tallHtml(),
    "opt-out-2"
  );
  assert.equal(on.captureEncoder, "cdp_fast_png");
  assert.equal(renderer.fastPngEncode, true);
});
