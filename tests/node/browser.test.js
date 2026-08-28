import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";
import { fileURLToPath } from "node:url";
import { BrowserRenderer, CHROMIUM_LAUNCH_ARGS } from "../../renderer/src/browser.js";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";
import { resolveSelectionInPage } from "../../renderer/src/interact.js";
import { collectAnimationGeometry } from "../../renderer/src/source-map.js";

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
    browser: { executable_path: executable }, theme: "dark", scrollY: 0,
    captureScale: "device", scrollPastEnd: true, scrollPastEndOffsetPx: 22 };
  const html = '<h1 data-source-start="0" data-source-end="1">Heading</h1><p data-source-start="1" data-source-end="2">body</p>';
  const result = await renderer.render(params, html, 42);
  assert.equal(result.viewportHeightPx, 480);
  assert.ok(result.blocks.length >= 2);
  // One line per rendered visual line, not one per block: a `5j`-style count
  // motion counts these, and a heading plus a one-line paragraph is exactly
  // two of both here, but a wrapped multi-line paragraph (below) is where
  // the two diverge.
  assert.equal(result.lines.length, 2);
  const devicePng = fs.readFileSync(result.pngPath);
  assert.deepEqual(devicePng.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  assert.equal(devicePng.readUInt32BE(16), 1280);
  assert.equal(devicePng.readUInt32BE(20), 960);
  assert.equal(renderer.deviceScaleFactor, 2);
  assert.equal(await renderer.page.evaluate(() => getComputedStyle(document.body).fontSize), "16px");
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
  // The configured font size is the font size, at every width. The narrow
  // breakpoints used to add 1-2px on top, which is right for a browser window
  // and wrong here: this viewport's width stands in for a terminal split's
  // width, and the page is rasterised and scaled into cells afterwards.
  assert.equal(await renderer.page.evaluate(() => getComputedStyle(document.body).fontSize), "16px");
  for (const widthPx of [400, 600, 900]) {
    await renderer.render({ ...params, viewport: { ...params.viewport, widthPx }, fontSizePx: 14 }, html, 100 + widthPx);
    assert.equal(
      await renderer.page.evaluate(() => getComputedStyle(document.body).fontSize),
      "14px",
      `configured font size holds at ${widthPx}px`,
    );
  }
  const changed = await renderer.render({ ...params, contentRevision: 2 }, html, 44);
  assert.equal(changed.layoutReused, false);
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

test("line geometry is one entry per rendered visual line, denser than block geometry", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
  const params = {
    documentId: "line-geometry-doc", contentRevision: 1,
    viewport: { widthPx: 200, heightPx: 600, deviceScaleFactor: 1 },
    browser: { executable_path: executable }, theme: "dark", scrollY: 0,
    captureScale: "device", scrollPastEnd: true, scrollPastEndOffsetPx: 22,
  };
  // Narrow enough that this one paragraph wraps across several visual
  // lines -- the case a per-block marker (one per <p>) undercounts what a
  // `5j`-style count motion actually moves through.
  const html =
    '<h1 data-source-start="0" data-source-end="1">Heading</h1>'
    + '<p data-source-start="1" data-source-end="2">one two three four five six seven eight nine ten</p>';
  const result = await renderer.render(params, html, "line-geometry");
  assert.equal(result.blocks.length, 2, "one block per element: the heading and the paragraph");
  assert.ok(
    result.lines.length > result.blocks.length,
    `a wrapped paragraph should produce more lines (${result.lines.length}) than blocks (${result.blocks.length})`
  );
  // Every line is a real, ordered, non-overlapping band: each starts no
  // higher than the previous one ended, matching document reading order.
  for (let i = 1; i < result.lines.length; i += 1) {
    assert.ok(result.lines[i].topPx >= result.lines[i - 1].topPx, "lines are reported in document order");
    assert.ok(result.lines[i].bottomPx > result.lines[i].topPx, "each line has a positive height");
  }
});

test("a health check while a document is active does not blank it", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
  const params = { documentId: "buffer-9", contentRevision: 1, viewport: { widthPx: 640, heightPx: 480, deviceScaleFactor: 2 },
    browser: { executable_path: executable }, theme: "dark", scrollY: 0,
    captureScale: "device", scrollPastEnd: true, scrollPastEndOffsetPx: 22 };
  const html = '<h1 data-source-start="0" data-source-end="1">Heading</h1>';
  await renderer.render(params, html, 1);
  assert.equal(renderer.active.documentId, "buffer-9");
  // :MdViewerDebug/:MdViewerHealth run this against a live session; it must
  // reuse the session's own scale rather than defaulting to 1, or the scale
  // mismatch tears down the context and blanks the open preview.
  const health = await renderer.health({ executable_path: executable });
  assert.equal(health.chromiumLaunch, "succeeded");
  assert.equal(health.activeDocument, "buffer-9");
  assert.equal(renderer.active.documentId, "buffer-9");
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
    browser: { executable_path: executable }, theme: "dark", scrollY: 0,
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
    browser: { executable_path: executable }, theme: "dark", scrollY: 0,
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
    browser: { executable_path: executable }, theme: "dark",
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
    theme: "dark", scrollY: 0, captureScale: "device",
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

// Both of the following run without a browser: they are about what the
// renderer refuses to do to one.

test("Chromium is never asked to disable the compositor's frame-rate limit", () => {
  // `--disable-frame-rate-limit` shaved ~12ms off a capture on Linux and made
  // Page.captureScreenshot never answer at all on macOS -- 0 of 12 launches
  // produced a frame with it set, 12 of 12 without, on two macOS versions and
  // two Chrome builds. Since the launch args are otherwise unobservable from a
  // test, assert on the exported list so the flag cannot come back on the
  // strength of the benchmark alone.
  assert.deepEqual(CHROMIUM_LAUNCH_ARGS, [
    "--disable-extensions", "--disable-component-update", "--no-first-run", "--no-default-browser-check",
  ]);
  assert.equal(
    CHROMIUM_LAUNCH_ARGS.filter((arg) => /frame-rate|frame_rate/.test(arg)).length, 0,
    "no launch argument may alter Chromium's frame-rate limiting -- Page.captureScreenshot waits on it"
  );
});

test("a capture that never answers degrades to the Playwright path instead of hanging", async (t) => {
  // Neither `CDPSession.send` nor `page.evaluate` has a timeout of its own, so
  // without a bound of ours a wedged compositor stalls the serial request queue
  // forever -- which is precisely what the frame-rate flag caused, and what a
  // future Chromium regression could cause again.
  const forever = () => new Promise(() => {});
  const cases = [
    { name: "the CDP capture stalls", evaluateStalls: false },
    { name: "the scroll-origin evaluate stalls", evaluateStalls: true },
  ];
  for (const { name, evaluateStalls } of cases) {
    const renderer = new BrowserRenderer({ assetsDir });
    t.after(() => renderer.close());
    renderer.cdpCaptureTimeoutMs = 50;
    renderer.viewport = { width: 640, height: 480 };
    renderer.deviceScaleFactor = 2;
    renderer.cdp = { send: evaluateStalls ? async () => ({ data: "" }) : forever };
    let playwrightScreenshots = 0;
    renderer.page = {
      evaluate: evaluateStalls ? forever : async () => ({ x: 0, y: 0 }),
      screenshot: async ({ path: target }) => { playwrightScreenshots += 1; fs.writeFileSync(target, "png"); },
    };

    const pngPath = path.join(renderer.tempDir, "stall.png");
    const encoder = await renderer.captureViewportPng(pngPath, "device");
    assert.equal(encoder, "playwright_png", `${name}: expected the fallback capture path`);
    assert.equal(playwrightScreenshots, 1, `${name}: the fallback must actually take the picture`);
    assert.match(
      renderer.cdpCaptureUnavailable ?? "", /did not respond within 50ms/,
      `${name}: the stall must be recorded so later frames skip the fast path`
    );

    // Latched, so one stall costs one failed round trip rather than one per frame.
    const again = await renderer.captureViewportPng(pngPath, "device");
    assert.equal(again, "playwright_png", `${name}: the fast path must stay disabled`);
    assert.equal(playwrightScreenshots, 2, `${name}: the second frame still gets captured`);
  }
});

test("animated image geometry is reported in document coordinates, and forged ids are not", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());

  const params = {
    documentId: "anim-doc", contentRevision: 1,
    viewport: { widthPx: 640, heightPx: 480, deviceScaleFactor: 1 },
    browser: { executable_path: executable }, theme: "dark", scrollY: 0,
    captureScale: "device", scrollPastEnd: false, scrollPastEndOffsetPx: 0,
    // Only "a1" was minted by this render. "a2" is on an element that never
    // registered one, and the second "a1" is a duplicate claim.
    animationIds: ["a1"],
  };
  const pixel = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==";
  const html = '<p style="height:200px">spacer</p>'
    + `<img data-md-anim-id="a1" src="${pixel}" style="width:120px;height:80px;display:block;margin:0">`
    + `<img data-md-anim-id="a2" src="${pixel}" style="width:120px;height:80px;display:block;margin:0">`
    + `<img data-md-anim-id="a1" src="${pixel}" style="width:99px;height:99px;display:block;margin:0">`;

  const result = await renderer.render(params, html, "anim-1");
  assert.equal(result.animations.length, 1, "one id was minted, so exactly one rect is reported");

  const rect = result.animations[0];
  assert.equal(rect.id, "a1");
  assert.equal(rect.widthPx, 120);
  assert.equal(rect.heightPx, 80);
  assert.ok(rect.yPx >= 200, "the rect carries its document position, not a viewport-relative one");

  // A scroll must not move it: Lua subtracts scrollY itself, which is what lets
  // the ticker follow a scroll with no re-render.
  const scrolled = await renderer.render({ ...params, scrollY: 50 }, html, "anim-2");
  assert.deepEqual(scrolled.animations, result.animations);

  // A document with nothing registered reports nothing and asks the page nothing.
  const none = await renderer.render({ ...params, documentId: "plain", animationIds: [] }, html, "anim-3");
  assert.deepEqual(none.animations, []);
  assert.equal(none.animationsIncomplete, false);
});

// The regression for the bug where every animation in a full-screen preview
// stayed on its first frame until the window was resized. Geometry is collected
// once per layout, and a data-URI <img> has no box until Chromium has sized it,
// so a measurement taken before that happened reported *no animations* -- which
// is indistinguishable from a document that has none. That empty set was then
// cached for the life of the layout, and `layoutKey` carries width but not
// height, so nothing short of a re-key ever measured again.
test("an animation measurement that has not settled is retried, not cached as final", async () => {
  const rectFor = (id) => ({ id, xPx: 0, yPx: 0, widthPx: 10, heightPx: 10 });
  // Stands in for a page whose images gain their boxes only after some probes.
  const stub = (answers) => {
    let call = 0;
    return { evaluate: async () => answers[Math.min(call++, answers.length - 1)] };
  };

  const settles = await collectAnimationGeometry(
    stub([[], [rectFor("a1")], [rectFor("a1"), rectFor("a2")]]),
    ["a1", "a2"]
  );
  assert.equal(settles.rects.length, 2, "the poll keeps asking until every minted id has a box");
  assert.equal(settles.complete, true);

  // The case that caused the bug: the deadline expires with ids unmeasured.
  // Reporting only the short array is what let the caller treat it as settled.
  const expired = await collectAnimationGeometry(stub([[rectFor("a1")]]), ["a1", "a2"], { deadlineMs: 0 });
  assert.deepEqual(expired.rects, [rectFor("a1")], "whatever was measured is still returned");
  assert.equal(expired.complete, false, "a timed-out measurement must not pass for a settled one");

  // Nothing minted costs no round trip at all.
  const empty = await collectAnimationGeometry(
    { evaluate: () => assert.fail("a document with no animations must not be asked about them") },
    []
  );
  assert.deepEqual(empty, { rects: [], complete: true });
});

test("a layout whose animation geometry never settles re-measures, then stops asking", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());

  const pixel = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==";
  // "a2" is minted but has no element in the document, so the measurement can
  // never complete -- the same shape as an image Chromium has not sized yet,
  // and the case that must not retry forever.
  const params = {
    documentId: "unsettled", contentRevision: 1,
    viewport: { widthPx: 640, heightPx: 480, deviceScaleFactor: 1 },
    browser: { executable_path: executable }, theme: "dark", scrollY: 0,
    captureScale: "device", scrollPastEnd: false, scrollPastEndOffsetPx: 0,
    animationIds: ["a1", "a2"],
  };
  const html = `<img data-md-anim-id="a1" src="${pixel}" style="width:120px;height:80px;display:block;margin:0">`;

  const first = await renderer.render(params, html, "unsettled-1");
  assert.equal(first.animationsIncomplete, true, "an unmeasured id is reported, not hidden");
  assert.equal(first.animations.length, 1, "the id that could be measured is still delivered");

  // Every render below reuses the layout -- the path that used to hand back the
  // first measurement unchanged forever.
  let renders = 1;
  let last = first;
  while (last.animationsIncomplete && renders < 40) {
    last = await renderer.render(params, html, `unsettled-${++renders}`);
    assert.equal(last.animations.length, 1, "a retry never retracts a rect it already reported");
  }
  assert.equal(last.animationsIncomplete, false, "the retry is bounded rather than a render loop");
  assert.ok(renders <= 12, `gave up after ${renders} renders, which is the bound plus the first pass`);
});
