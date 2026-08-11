import test from "node:test";
import assert from "node:assert/strict";
import {
  MAX_SOURCE_FRAMES,
  MAX_SOURCE_PIXELS,
  UPLOAD_PIXEL_BUDGET,
  frameBudget,
  sniffAnimation,
} from "../../renderer/src/media.js";
import { buildGif, solid } from "./helpers/build-gif.mjs";

// A 30-byte extended WebP header. Real animated WebP needs VP8X with the ANIM
// flag; everything the sniffer reads lives in these fixed bytes, so a header
// is a complete fixture for it.
function webpHeader({ fourcc = "VP8X", animated = true, width = 4, height = 4 } = {}) {
  const bytes = Buffer.alloc(30);
  bytes.write("RIFF", 0, "latin1");
  bytes.writeUInt32LE(22, 4);
  bytes.write("WEBP", 8, "latin1");
  bytes.write(fourcc, 12, "latin1");
  bytes.writeUInt32LE(10, 16);
  bytes[20] = animated ? 0x02 : 0x00;
  const w = width - 1;
  const h = height - 1;
  bytes[24] = w & 0xff;
  bytes[25] = (w >> 8) & 0xff;
  bytes[26] = (w >> 16) & 0xff;
  bytes[27] = h & 0xff;
  bytes[28] = (h >> 8) & 0xff;
  bytes[29] = (h >> 16) & 0xff;
  return bytes;
}

test("an animated GIF is a candidate, with exact frame count and dimensions", () => {
  const gif = buildGif(3, 2, [
    { indices: solid(1, 6) },
    { indices: solid(2, 6) },
    { indices: solid(3, 6) },
  ]);
  assert.deepEqual(sniffAnimation(gif), {
    format: "gif",
    mime: "image/gif",
    width: 3,
    height: 2,
    frameCount: 3,
  });
});

test("a still GIF is not a candidate -- it must not mint an animation id", () => {
  const still = buildGif(2, 2, [{ indices: solid(1, 4) }]);
  assert.equal(sniffAnimation(still), null);
});

test("garbage is not a candidate and never throws", () => {
  assert.equal(sniffAnimation(Buffer.from("not an image")), null);
  assert.equal(sniffAnimation(Buffer.alloc(0)), null);
  assert.equal(sniffAnimation("a string, not a buffer"), null);
  assert.equal(sniffAnimation(Buffer.from("GIF89a")), null); // header, no body
});

test("a truncated GIF counts the whole frames it still contains", () => {
  const gif = buildGif(2, 2, [
    { indices: solid(1, 4) },
    { indices: solid(2, 4) },
    { indices: solid(3, 4) },
  ]);
  // Cut inside the third frame's pixel data: two whole frames remain, which is
  // still an animation.
  const truncated = gif.subarray(0, gif.length - 6);
  const sniffed = sniffAnimation(truncated);
  assert.equal(sniffed.frameCount, 2);
});

test("dimensions past the source pixel cap refuse before any walk", () => {
  // A header claiming 60000x60000 is 3.6 billion pixels; the walk must not
  // even start, so the frame payload can be tiny.
  const gif = buildGif(60000, 60000, [{ indices: solid(1, 4) }, { indices: solid(2, 4) }]);
  assert.equal(sniffAnimation(gif), null);
  assert.ok(60000 * 60000 > MAX_SOURCE_PIXELS, "the fixture is actually over the cap");
});

test("a frame count past the cap refuses, and the walk stops counting there", () => {
  const gif = buildGif(2, 2, [
    { indices: solid(1, 4) },
    { indices: solid(2, 4) },
    { indices: solid(3, 4) },
  ]);
  assert.equal(sniffAnimation(gif, { maxFrames: 2 }), null);
  assert.ok(MAX_SOURCE_FRAMES >= 241, "the cap admits the README recording");
});

test("animated WebP is recognized from the VP8X ANIM flag alone", () => {
  assert.deepEqual(sniffAnimation(webpHeader({ width: 10, height: 6 })), {
    format: "webp",
    mime: "image/webp",
    width: 10,
    height: 6,
    frameCount: null,
  });
});

test("still and malformed WebP are not candidates", () => {
  assert.equal(sniffAnimation(webpHeader({ animated: false })), null, "VP8X without ANIM");
  assert.equal(sniffAnimation(webpHeader({ fourcc: "VP8 " })), null, "simple lossy WebP");
  assert.equal(sniffAnimation(webpHeader({ fourcc: "VP8L" })), null, "simple lossless WebP");
  assert.equal(sniffAnimation(webpHeader().subarray(0, 20)), null, "short buffer");
  assert.equal(sniffAnimation(webpHeader({ width: 20000, height: 20000 })), null, "over the pixel cap");
});

test("frameBudget divides the upload budget by the drawn frame size", () => {
  // 640x360 = 230,400 px/frame; 48M / 230,400 = 208 frames.
  assert.equal(frameBudget(640, 360), Math.floor(UPLOAD_PIXEL_BUDGET / (640 * 360)));
  // A tiny frame is capped by the source frame limit, not the budget.
  assert.equal(frameBudget(10, 10), MAX_SOURCE_FRAMES);
  // A frame so large the budget fits fewer than two is the caller's cue to
  // refuse -- "animating" one frame is a still image with extra steps.
  assert.ok(frameBudget(5000, 5000) < 2);
  assert.equal(frameBudget(0, 100), 0);
  assert.equal(frameBudget(Number.NaN, 100), 0);
});
