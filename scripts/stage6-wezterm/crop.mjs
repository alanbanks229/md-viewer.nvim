// Crop a region out of one of the run's screenshots and write it as a PNG, so
// the evidence committed alongside the findings is the interesting few hundred
// pixels rather than a 6 MB photograph of somebody's desktop.
//
//   node crop.mjs <in.png> <out.png> <x> <y> <w> <h> [scale]
import fs from "node:fs";
import zlib from "node:zlib";
import { decodePngPixels, pixelAt } from "../../tests/node/helpers/decode-png.mjs";

const CRC = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();
const crc32 = (buf) => {
  let c = -1;
  for (const byte of buf) c = CRC[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
};
function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, "latin1"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([length, body, crc]);
}

const [input, output, sx, sy, sw, sh, scaleArg] = process.argv.slice(2);
if (!sh) {
  console.error("usage: crop.mjs <in.png> <out.png> <x> <y> <w> <h> [scale]");
  process.exit(2);
}
const src = decodePngPixels(fs.readFileSync(input));
const x0 = Number(sx);
const y0 = Number(sy);
const w = Number(sw);
const h = Number(sh);
// Nearest-neighbour, deliberately: this evidence is about which pixels are
// painted, and smoothing it would blur the very gaps it exists to show.
const scale = Math.max(1, Math.floor(Number(scaleArg ?? 1)));
const ow = w * scale;
const oh = h * scale;

const stride = 1 + ow * 3;
const raw = Buffer.alloc(oh * stride);
for (let y = 0; y < oh; y += 1) {
  const row = y * stride;
  raw[row] = 0;
  for (let x = 0; x < ow; x += 1) {
    const p = pixelAt(src, Math.min(src.width - 1, x0 + Math.floor(x / scale)), Math.min(src.height - 1, y0 + Math.floor(y / scale)));
    const o = row + 1 + x * 3;
    raw[o] = p.r;
    raw[o + 1] = p.g;
    raw[o + 2] = p.b;
  }
}
const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(ow, 0);
ihdr.writeUInt32BE(oh, 4);
ihdr[8] = 8;
ihdr[9] = 2; // RGB
fs.writeFileSync(
  output,
  Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ])
);
console.error(`${output}: ${ow}x${oh} from ${input} at (${x0}, ${y0}) scale ${scale}`);
