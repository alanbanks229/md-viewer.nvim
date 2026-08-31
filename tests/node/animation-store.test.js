import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { AnimationStore } from "../../renderer/src/animation.js";
import { CHROMIUM_LAUNCH_ARGS } from "../../renderer/src/browser.js";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";
import { renderMarkdown } from "../../renderer/src/markdown.js";
import { buildGif, solid } from "./helpers/build-gif.mjs";

const requireFromRenderer = createRequire(new URL("../../renderer/src/browser.js", import.meta.url));
const { chromium } = requireFromRenderer("playwright");

function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

const animatedGif = () =>
  buildGif(2, 1, [
    { indices: solid(1, 2), delayCs: 7 },
    { indices: solid(3, 2), delayCs: 20 },
  ], { loopCount: 0 });

// -- Registration: pure, no browser required --------------------------------

test("register recognizes an animated GIF, retains it once, and mints no id", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-store-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const store = new AnimationStore({ dir });

  const first = store.register(animatedGif());
  const second = store.register(animatedGif());
  // The store deliberately does not name animations. An id has to be a pure
  // function of the document so that re-parsing it produces the same ids -- the
  // page and the registry are not rebuilt together -- and only the render rule
  // knows a document's ordering. See registerAnimation in markdown.js.
  assert.equal(first.id, undefined, "the store mints no id");
  assert.equal(first.sha, second.sha, "content shares one sha");
  assert.equal(first.frameCount, 2);
  // The sniffed intrinsic size comes back because the render rule has to state
  // it on the tag. Without it the <img> has a zero layout box until Chromium
  // decodes the data URI, and the geometry pass drops zero-area rects.
  assert.equal(first.width, 2, "the sniffed width comes back to the caller");
  assert.equal(first.height, 1, "and the sniffed height with it");
  assert.equal(store.sources.size, 1, "one copy of the bytes is retained");
});

test("re-parsing a document yields the same animation ids", async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-store-"));
  const docDir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-doc-"));
  t.after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
    fs.rmSync(docDir, { recursive: true, force: true });
  });
  fs.writeFileSync(path.join(docDir, "one.gif"), animatedGif());
  fs.writeFileSync(path.join(docDir, "two.gif"), buildGif(3, 1, [
    { indices: solid(1, 3), delayCs: 5 },
    { indices: solid(2, 3), delayCs: 5 },
  ], { loopCount: 0 }));

  const store = new AnimationStore({ dir });
  const options = {
    localImages: true,
    maxLocalImageBytes: 10 * 1024 * 1024,
    baseDir: docDir,
    documentRoot: docDir,
    animationStore: store,
  };
  const markdown = "![a](one.gif)\n\n![b](two.gif)\n";

  const first = await renderMarkdown(markdown, options);
  const second = await renderMarkdown(markdown, options);

  // The property the whole scheme exists for. `layoutKey` is keyed on the
  // markdown cache key, and a remote image finishing its fetch produces new
  // markup under that same key: the markdown is re-parsed and the page is not
  // reloaded. With a store-wide serial the DOM held `a1` while the fresh
  // registry knew only `a2`, service.js's sha join dropped the rect it could
  // not name, and the document reported zero animations from then on.
  assert.deepEqual([...second.animations.keys()], [...first.animations.keys()]);
  assert.deepEqual([...second.animations.keys()], ["a1", "a2"], "ids are the document's own ordering");
  for (const [id, meta] of first.animations) {
    assert.equal(second.animations.get(id).sha, meta.sha, "and each id still means the same image");
  }
});

test("register refuses stills, garbage, and over-cap sources", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-store-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const store = new AnimationStore({ dir });

  assert.equal(store.register(buildGif(2, 2, [{ indices: solid(1, 4) }])), null, "still GIF");
  assert.equal(store.register(Buffer.from("not an image")), null, "garbage");
  assert.equal(store.register(Buffer.alloc(0)), null, "empty");

  const capped = new AnimationStore({ dir, maxSourceFrames: 1 });
  assert.equal(capped.register(animatedGif()), null, "over the frame cap");
  const tiny = new AnimationStore({ dir, maxSourcePixels: 1 });
  assert.equal(tiny.register(animatedGif()), null, "over the pixel cap");
});

test("register recognizes the animated-WebP header", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-store-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const store = new AnimationStore({ dir });
  const webp = Buffer.alloc(30);
  webp.write("RIFF", 0, "latin1");
  webp.writeUInt32LE(22, 4);
  webp.write("WEBP", 8, "latin1");
  webp.write("VP8X", 12, "latin1");
  webp.writeUInt32LE(10, 16);
  webp[20] = 0x02; // ANIM
  webp[24] = 3; // width 4
  webp[27] = 3; // height 4
  const registered = store.register(webp);
  assert.ok(registered, "an ANIM-flagged VP8X header registers");
  assert.equal(registered.frameCount, null, "WebP frame count is the decoder's to learn");
});

test("the source cache is bounded: old bytes leave, and come back on re-register", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-store-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  // Budget of one byte: every insertion evicts the previous source.
  const store = new AnimationStore({ dir, maxSourceStoreBytes: 1 });
  const a = store.register(animatedGif());
  const b = store.register(buildGif(2, 1, [
    { indices: solid(2, 2) },
    { indices: solid(3, 2) },
  ]));
  assert.notEqual(a.sha, b.sha);
  assert.equal(store.sources.size, 1, "over budget, only the newest source is retained");
  assert.ok(store.sources.has(b.sha));
  // The evicted source is not an error state -- the next render re-registers.
  const again = store.register(animatedGif());
  assert.equal(again.sha, a.sha);
  assert.ok(store.sources.has(a.sha));
});

test("renderMarkdown mints data-md-anim-id through the image rule, capped per document", async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-store-"));
  const docDir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-doc-"));
  t.after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
    fs.rmSync(docDir, { recursive: true, force: true });
  });
  fs.writeFileSync(path.join(docDir, "anim.gif"), animatedGif());
  fs.writeFileSync(path.join(docDir, "still.gif"), buildGif(2, 2, [{ indices: solid(1, 4) }]));

  const store = new AnimationStore({ dir, maxPerDocument: 2 });
  const options = {
    localImages: true,
    maxLocalImageBytes: 10 * 1024 * 1024,
    baseDir: docDir,
    documentRoot: docDir,
    animationStore: store,
  };
  const markdown = "![a](anim.gif)\n\n![b](still.gif)\n\n![c](anim.gif)\n\n![d](anim.gif)\n";
  const rendered = await renderMarkdown(markdown, options);

  const minted = [...rendered.html.matchAll(/data-md-anim-id="(a\d+)"/g)].map((m) => m[1]);
  assert.equal(minted.length, 2, "two animated instances minted; the still one and the over-cap one did not");
  assert.equal(rendered.animations.size, 2);
  for (const meta of rendered.animations.values()) {
    assert.match(meta.sha, /^[0-9a-f]{64}$/, "the registry carries the sha the media lane is addressed by");
  }
  // Every minted image states the size sniffed from its own header. This is
  // what keeps the geometry pass off a race: an <img> with no dimensions has a
  // zero layout box until Chromium has decoded enough of the data URI to know
  // them, collectAnimationGeometry drops zero-area rects, and browser.js's
  // bounded retry can run out while that is still true -- after which the still
  // frame stands for the life of the layout and only a resize appears to fix it.
  const sized = [...rendered.html.matchAll(/<img [^>]*data-md-anim-id="a\d+"[^>]*>/g)].map((m) => m[0]);
  assert.equal(sized.length, 2, "both minted images were matched");
  for (const tag of sized) {
    assert.match(tag, /width="2"/, "the sniffed width is stated on the tag");
    assert.match(tag, /height="1"/, "and the sniffed height with it");
  }

  // Without a store there are no ids and no stated sizes. This is the
  // `render.animate = false` path -- service.js passes a null store -- and it is
  // why turning animation off costs motion and never a picture. The GIF is
  // still inlined and still painted, so the screenshot keeps whichever frame
  // Chromium was on; the only differences are the attribute the terminal would
  // have used to draw a layer over it and the size it would have measured.
  const plain = await renderMarkdown(markdown, { ...options, animationStore: null });
  assert.doesNotMatch(plain.html, /data-md-anim-id/);
  assert.match(plain.html, /src="data:image\/gif;base64,/, "the animated image is still inlined for the still frame");
  assert.equal(
    rendered.html.replace(/ data-md-anim-id="a\d+"/g, "").replace(/ width="2" height="1"/g, ""),
    plain.html,
    "the id and the stated size are the only differences: nothing else changes with animation off",
  );
});

test("an author's own width/height outranks the sniffed one", async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-store-"));
  const docDir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-doc-"));
  t.after(() => {
    fs.rmSync(dir, { recursive: true, force: true });
    fs.rmSync(docDir, { recursive: true, force: true });
  });
  fs.writeFileSync(path.join(docDir, "anim.gif"), animatedGif());

  const store = new AnimationStore({ dir });
  const rendered = await renderMarkdown('<img width="120" height="60" src="anim.gif" />\n', {
    rawHtml: true,
    localImages: true,
    maxLocalImageBytes: 10 * 1024 * 1024,
    baseDir: docDir,
    documentRoot: docDir,
    animationStore: store,
  });

  // The point of stating a size is to give the box one before the bytes decode.
  // An author who already gave it one has done that job, and overwriting their
  // number would resize their picture -- so the id is minted and the dimensions
  // are left exactly as written.
  assert.match(rendered.html, /data-md-anim-id="a\d+"/, "a raw <img> still animates");
  assert.match(rendered.html, /width="120"/, "the author's width stands");
  assert.match(rendered.html, /height="60"/, "and the author's height with it");
  assert.doesNotMatch(rendered.html, /width="2"/, "the sniffed size did not overwrite it");
});

test("one animation cannot evict the rest: entries are bounded to their share of the store", async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-store-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));

  // A stub decode context: the point is the byte accounting, not the pixels.
  // 12 frames of 1MB is 12MB, three times the 4MB share below.
  const frame = (index) => ({ png: Buffer.alloc(1024 * 1024, index).toString("base64"), gapMs: 50 });
  const store = new AnimationStore({
    dir,
    maxFrameStoreBytes: 16 * 1024 * 1024,
    maxPerDocument: 4, // -> a 4MB share per animation
    decodeContext: {
      decode: async () => ({
        status: "ok",
        frames: Array.from({ length: 12 }, (_, index) => frame(index)),
        loop: "infinite",
        sourceFrameCount: 12,
        keptFrameCount: 12,
      }),
    },
  });

  const shas = [];
  for (let n = 0; n < 4; n += 1) {
    // Distinct bytes so each is its own sha, all four the same shape.
    const bytes = Buffer.concat([animatedGif(), Buffer.from([n])]);
    const registered = store.register(bytes);
    assert.ok(registered, "each source registers");
    shas.push(registered.sha);
  }

  const results = [];
  for (const sha of shas) results.push(await store.materialize(sha, 100, 100));

  for (const result of results) {
    assert.equal(result.status, "ok");
    // 12 x 1MB does not fit a 4MB share; the cut is even and duration survives.
    assert.ok(result.frames.length >= 2 && result.frames.length < 12, `thinned to ${result.frames.length}`);
    assert.equal(result.keptFrameCount, result.frames.length, "the reported count is what reached disk");
    const total = result.frames.reduce((sum, f) => sum + fs.statSync(f.path).size, 0);
    assert.ok(total <= store.maxEntryBytes, `${total} bytes is within the ${store.maxEntryBytes}-byte share`);
    assert.equal(
      result.frames.reduce((sum, f) => sum + f.gapMs, 0),
      12 * 50,
      "dropped frames fold their display time into the survivor before them",
    );
  }

  // The property that matters. Before the share bound, one oversized animation
  // filled the store on its own and evicted its siblings -- whose frame paths
  // the Lua side then read as missing and re-materialized after RETRY_MS,
  // evicting whatever had displaced them. A loop, not a degradation.
  assert.equal(store.stats.evictions, 0, "a full document's animations coexist");
  for (const result of results) {
    for (const f of result.frames) assert.ok(fs.existsSync(f.path), "every frame of every animation is still on disk");
  }
});

// -- Materialization: needs the real Chromium -------------------------------

test("materialize against the real Chromium", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const browser = await chromium.launch({ executablePath: executable, headless: true, args: CHROMIUM_LAUNCH_ARGS });
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-store-"));
  const store = new AnimationStore({ dir, browserProvider: () => browser });
  t.after(async () => {
    await store.close();
    await browser.close();
    fs.rmSync(dir, { recursive: true, force: true });
  });

  const { sha } = store.register(animatedGif());

  await t.test("writes real frames with native gaps, loop, and stable keys", async () => {
    const made = await store.materialize(sha, 4, 2);
    assert.equal(made.status, "ok");
    assert.equal(made.frames.length, 2);
    assert.deepEqual(made.frames.map((f) => f.gapMs), [70, 200]);
    assert.equal(made.loop, "infinite");
    assert.equal(made.frameWidthPx, 4);
    assert.equal(made.frameHeightPx, 2);
    assert.ok(made.decodeMs >= 0);
    for (const frame of made.frames) {
      assert.ok(frame.path.startsWith(dir), "every frame lives under the store's own directory");
      const bytes = fs.readFileSync(frame.path);
      assert.deepEqual(bytes.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), "a real PNG");
      assert.match(frame.key, /^[0-9a-f]{16}$/);
    }
  });

  await t.test("memoizes by (sha, size); a resize is a distinct entry", async () => {
    const decodesBefore = store.stats.decodes;
    const again = await store.materialize(sha, 4, 2);
    assert.equal(again.status, "ok");
    assert.equal(store.stats.decodes, decodesBefore, "a repeat ask decodes nothing");
    const resized = await store.materialize(sha, 8, 4);
    assert.equal(resized.status, "ok");
    assert.equal(store.stats.decodes, decodesBefore + 1, "a new size decodes once");
    assert.notEqual(resized.frames[0].path, again.frames[0].path);
  });

  await t.test("frame keys are stable across store instances -- the renderer-restart property", async () => {
    const dir2 = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-store2-"));
    const store2 = new AnimationStore({ dir: dir2, browserProvider: () => browser });
    try {
      store2.register(animatedGif());
      const made2 = await store2.materialize(sha, 4, 2);
      const made1 = await store.materialize(sha, 4, 2);
      assert.equal(made2.status, "ok");
      assert.deepEqual(
        made2.frames.map((f) => f.key),
        made1.frames.map((f) => f.key),
        "same content at the same size names the same terminal-side frames, whatever the temp paths"
      );
      assert.notEqual(made2.frames[0].path, made1.frames[0].path, "while the paths are process-local");
    } finally {
      await store2.close();
      fs.rmSync(dir2, { recursive: true, force: true });
    }
  });

  await t.test("an unknown sha is unknown-source, never an empty success", async () => {
    const missing = await store.materialize("f".repeat(64), 4, 2);
    assert.equal(missing.status, "unknown-source");
  });

  await t.test("a refusal is remembered and costs one decode ever", async () => {
    const cramped = new AnimationStore({ dir, browserProvider: () => browser, uploadPixelBudget: 1 });
    try {
      cramped.register(animatedGif());
      const first = await cramped.materialize(sha, 4, 2);
      assert.equal(first.status, "refused");
      assert.match(first.reason, /frame budget/);
      assert.equal(cramped.stats.decodes, 0, "the budget refusal never reached Chromium");
      const second = await cramped.materialize(sha, 4, 2);
      assert.equal(second.status, "refused");
      assert.equal(second.reason, first.reason);
    } finally {
      await cramped.close();
    }
  });

  await t.test("bad target dimensions are an error status, not a throw", async () => {
    const bad = await store.materialize(sha, 0, 2);
    assert.equal(bad.status, "error");
    const nan = await store.materialize(sha, Number.NaN, 2);
    assert.equal(nan.status, "error");
  });

  await t.test("environment errors are not cached: the next ask retries", async () => {
    let live = null;
    const flaky = new AnimationStore({ dir, browserProvider: () => live });
    try {
      flaky.register(animatedGif());
      const down = await flaky.materialize(sha, 4, 2);
      assert.equal(down.status, "error", "no browser is an error");
      live = browser;
      const up = await flaky.materialize(sha, 4, 2);
      assert.equal(up.status, "ok", "the same ask succeeds once the environment recovers");
    } finally {
      await flaky.close();
    }
  });

  await t.test("eviction removes whole entries with their whole directories, oldest first", async () => {
    const small = new AnimationStore({ dir, browserProvider: () => browser, maxFrameStoreBytes: 1 });
    try {
      small.register(animatedGif());
      const first = await small.materialize(sha, 4, 2);
      assert.equal(first.status, "ok");
      const firstDir = path.dirname(first.frames[0].path);
      const second = await small.materialize(sha, 6, 3);
      assert.equal(second.status, "ok");
      assert.equal(fs.existsSync(firstDir), false, "the superseded entry's directory is gone");
      assert.equal(fs.existsSync(path.dirname(second.frames[0].path)), true, "the live one is not");
      assert.equal(small.stats.evictions, 1);
      // The evicted size is not poisoned: asking again re-materializes.
      const revived = await small.materialize(sha, 4, 2);
      assert.equal(revived.status, "ok");
      assert.ok(fs.existsSync(revived.frames[0].path));
    } finally {
      await small.close();
    }
  });

  await t.test("concurrent asks for one key share one decode", async () => {
    const shared = new AnimationStore({ dir, browserProvider: () => browser });
    try {
      shared.register(animatedGif());
      const [a, b] = await Promise.all([shared.materialize(sha, 10, 5), shared.materialize(sha, 10, 5)]);
      assert.equal(a.status, "ok");
      assert.equal(b.status, "ok");
      assert.equal(shared.stats.decodes, 1, "the second asker joined the first's job");
    } finally {
      await shared.close();
    }
  });

  await t.test("the health snapshot is numbers, not handles", async () => {
    const snapshot = store.snapshot();
    assert.equal(typeof snapshot.sources, "number");
    assert.equal(typeof snapshot.frameBytes, "number");
    assert.ok(snapshot.decodes >= 1);
    assert.ok(snapshot.decodeMs >= 0);
  });
});
