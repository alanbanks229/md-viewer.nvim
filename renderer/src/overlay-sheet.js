// Solid-color RGBA PNG generation for the stage-4 selection overlay.
//
// The Lua side draws the drag highlight by placing crops of one translucent
// "tint sheet" through the Kitty graphics protocol -- a moving frame then
// transmits placement commands only, no pixels. Lua cannot practically
// produce a compressed viewport-sized PNG itself (a raw stored stream would
// be tens of megabytes on the wire), so the renderer builds the sheet here
// with real deflate and hands it over once; kitty_raw.lua caches the upload
// per color and size.

import zlib from "node:zlib";

const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buffer) {
  let c = -1;
  for (let i = 0; i < buffer.length; i += 1) c = CRC_TABLE[(c ^ buffer[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, "latin1"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([length, body, crc]);
}

// Far above the production frame (a max-clamped device-scale capture is
// 3840x2880) but low enough that a malformed request cannot ask this process
// to allocate gigabytes.
export const MAX_SHEET_DIMENSION = 4096;

const cache = new Map();
const MAX_CACHED_SHEETS = 4;

/// A width x height PNG of one straight-alpha RGBA color. `tint` is
/// {r, g, b, a} with a in [0, 1]; the alpha byte is round(a * 255), which is
/// exactly the quantization Chromium applies to the ::selection rgba() --
/// measured, not assumed -- so the sheet and the browser-painted settle frame
/// composite identically.
export function buildOverlaySheetPng(width, height, tint) {
  const w = Math.floor(width);
  const h = Math.floor(height);
  if (!(w > 0 && h > 0 && w <= MAX_SHEET_DIMENSION && h <= MAX_SHEET_DIMENSION)) {
    throw new Error(`overlay sheet dimensions out of range: ${width}x${height}`);
  }
  const alpha = Math.max(0, Math.min(255, Math.round((tint?.a ?? 0) * 255)));
  const r = Math.max(0, Math.min(255, Math.round(tint?.r ?? 0)));
  const g = Math.max(0, Math.min(255, Math.round(tint?.g ?? 0)));
  const b = Math.max(0, Math.min(255, Math.round(tint?.b ?? 0)));
  const key = `${w}x${h}:${r},${g},${b},${alpha}`;
  const hit = cache.get(key);
  if (hit) return hit;

  const stride = 1 + w * 4;
  const raw = Buffer.alloc(h * stride);
  for (let y = 0; y < h; y += 1) {
    const row = y * stride;
    raw[row] = 0; // filter: none
    for (let x = 0; x < w; x += 1) {
      const offset = row + 1 + x * 4;
      raw[offset] = r;
      raw[offset + 1] = g;
      raw[offset + 2] = b;
      raw[offset + 3] = alpha;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // color type: RGBA
  const png = Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
  cache.set(key, png);
  while (cache.size > MAX_CACHED_SHEETS) {
    const oldest = cache.keys().next().value;
    cache.delete(oldest);
  }
  return png;
}
