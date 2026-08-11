// Generates the animation qualification fixtures into tmp/animation/fixtures/.
// Nothing binary is committed: the GIFs come from the same builder the test
// suites use, so what the checklist plays is exactly what the decoder was
// tested against -- plus one README-recording-scale file for the load case.
//
//   node scripts/animation/make-fixtures.mjs
//
// Drop any real animated .webp into the directory as `real.webp` and re-run to
// have it included; no WebP encoder exists in this repository to make one.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { buildGif, solid } from "../../tests/node/helpers/build-gif.mjs";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const out = path.join(repo, "tmp", "animation", "fixtures");
fs.mkdirSync(out, { recursive: true });

// Palette indices: 0 black, 1 red, 2 green, 3 blue.
const cycle = (count, size, delayCs) => {
  const frames = [];
  for (let i = 0; i < count; i += 1) frames.push({ indices: solid((i % 3) + 1, size), delayCs });
  return frames;
};

// A quick loop, a slow loop, a play-twice loop, and a still control.
fs.writeFileSync(path.join(out, "quick.gif"), buildGif(64, 64, cycle(12, 64 * 64, 8), { loopCount: 0 }));
fs.writeFileSync(path.join(out, "slow.gif"), buildGif(64, 64, cycle(4, 64 * 64, 80), { loopCount: 0 }));
fs.writeFileSync(path.join(out, "twice.gif"), buildGif(64, 64, cycle(6, 64 * 64, 15), { loopCount: 1 }));
fs.writeFileSync(path.join(out, "still.gif"), buildGif(64, 64, [{ indices: solid(1, 64 * 64) }]));

// README-recording frame size: 1470x892. Twelve frames, not 241: the literal
// LZW this builder emits does not compress, so every frame costs ~1.8MB on
// disk and the file has to stay under `max_local_image_bytes` -- and twelve
// is already enough to exercise the source caps, the decode path, and (at a
// retina drawn size) the thinning budget.
{
  const W = 1470;
  const H = 892;
  const frames = [];
  for (let f = 0; f < 12; f += 1) {
    const indices = new Array(W * H);
    for (let i = 0; i < W * H; i += 1) indices[i] = (i + f) & 3;
    frames.push({ indices, delayCs: 7 });
  }
  fs.writeFileSync(path.join(out, "large.gif"), buildGif(W, H, frames, { loopCount: 0 }));
}

const hasRealWebp = fs.existsSync(path.join(out, "real.webp"));
const lines = [
  "# Animation qualification fixture",
  "",
  "Watch each item against the checklist in `scripts/README.md`.",
  "",
  "A quick loop (12 frames, 80ms each), near the top of the document:",
  "",
  "![quick](quick.gif)",
  "",
  "A still GIF -- this one must NOT move, and must look identical to its neighbours' first frames:",
  "",
  "![still](still.gif)",
  "",
  "A slow loop (4 frames, 800ms each) next to a play-twice loop (freezes on its last frame):",
  "",
  "![slow](slow.gif) ![twice](twice.gif)",
  "",
  hasRealWebp ? "A real animated WebP:\n\n![webp](real.webp)\n" : "*(drop a `real.webp` into this directory and re-run make-fixtures to test animated WebP)*",
  "",
  ...Array.from({ length: 40 }, (_, i) => `Filler paragraph ${i + 1} so the recording below starts off-screen and the quick loop above can be scrolled half off the top.`),
  "",
  "A recording at README scale (1470x892, 60 frames) -- expect thinning under the pixel budget, duration preserved:",
  "",
  "![large](large.gif)",
  "",
  "The end. Scroll fast between here and the top while everything plays.",
  "",
].join("\n");
fs.writeFileSync(path.join(out, "fixture.md"), lines);

console.log(`fixtures written to ${out}`);
