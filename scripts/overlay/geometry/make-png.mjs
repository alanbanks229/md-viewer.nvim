// Write a solid RGBA PNG using the renderer's own sheet builder, so the probe
// measures the exact bytes production uploads rather than a lookalike.
//
//   node make-png.mjs <width> <height> <r> <g> <b> <a> <path> [marginX] [marginY]
//
// `a` is 0..1, matching buildOverlaySheetPng's straight-alpha contract.
import fs from "node:fs";
import path from "node:path";
import { buildOverlaySheetPng } from "../../../renderer/src/overlay-sheet.js";

const [width, height, r, g, b, a, out, marginX, marginY] = process.argv.slice(2);
if (!out) {
  console.error("usage: make-png.mjs <width> <height> <r> <g> <b> <a> <path>");
  process.exit(2);
}
const png = buildOverlaySheetPng(
  Number(width),
  Number(height),
  { r: Number(r), g: Number(g), b: Number(b), a: Number(a) },
  { x: Number(marginX ?? 0), y: Number(marginY ?? 0) }
);
fs.mkdirSync(path.dirname(path.resolve(out)), { recursive: true });
fs.writeFileSync(out, png);
console.error(`wrote ${out}: ${width}x${height} rgba(${r},${g},${b},${a}) ${png.length} bytes`);
