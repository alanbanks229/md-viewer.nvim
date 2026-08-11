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

test("register accepts an animated GIF and mints per-render ids over one shared sha", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-store-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const store = new AnimationStore({ dir });

  const first = store.register(animatedGif());
  const second = store.register(animatedGif());
  assert.match(first.id, /^a\d+$/);
  assert.notEqual(first.id, second.id, "ids are per render");
  assert.equal(first.sha, second.sha, "content shares one sha");
  assert.equal(first.frameCount, 2);
  assert.equal(store.sources.size, 1, "one copy of the bytes is retained");
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
  // Without a store the markup is byte-for-byte what it was: no ids at all.
  // This is the `render.animate = false` path -- main.js passes a null store --
  // and it is why turning animation off costs motion and never a picture. The
  // GIF is still inlined and still painted, so the screenshot keeps the first
  // frame; the only difference is the attribute the terminal would have used
  // to draw a layer over it.
  const plain = await renderMarkdown(markdown, { ...options, animationStore: null });
  assert.doesNotMatch(plain.html, /data-md-anim-id/);
  assert.match(plain.html, /src="data:image\/gif;base64,/, "the animated image is still inlined for the still frame");
  assert.equal(
    rendered.html.replace(/ data-md-anim-id="a\d+"/g, ""),
    plain.html,
    "the id is the only difference: nothing else about the document changes with animation off",
  );
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
