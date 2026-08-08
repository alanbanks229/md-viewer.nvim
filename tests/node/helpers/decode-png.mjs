// Enough of a PNG decoder to recover raw samples. Deliberately not a
// dependency: the renderer's dependency list is a security surface (see
// SECURITY.md), and nothing here needs to survive a malicious PNG -- every
// caller feeds it either a file this repo produced or a macOS screenshot.
//
// Lifted out of tests/node/selection-tint.test.js when scripts/stage6-wezterm
// needed the same decoder to assert on screenshots of a real WezTerm window.
// tests/node/browser.test.js still carries its own copy for a different job.
import zlib from "node:zlib";

/// Returns { width, height, channels, pixels } with `pixels` a row-major
/// Buffer of 8-bit samples. Throws on anything it cannot decode rather than
/// returning something plausible and wrong.
export function decodePngPixels(buffer) {
  if (buffer.readUInt32BE(0) !== 0x89504e47) throw new Error("not a PNG");
  let offset = 8;
  let width = 0;
  let height = 0;
  let depth = 0;
  let colorType = 0;
  let interlace = 0;
  const idat = [];
  while (offset < buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString("ascii", offset + 4, offset + 8);
    const data = buffer.subarray(offset + 8, offset + 8 + length);
    if (type === "IHDR") {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      depth = data[8];
      colorType = data[9];
      interlace = data[12];
    } else if (type === "IDAT") idat.push(data);
    else if (type === "IEND") break;
    offset += 12 + length;
  }
  if (depth !== 8) throw new Error(`unsupported bit depth ${depth}`);
  if (interlace !== 0) throw new Error("interlaced PNGs are not supported");
  const channels = { 0: 1, 2: 3, 4: 2, 6: 4 }[colorType];
  if (!channels) throw new Error(`unsupported colour type ${colorType}`);

  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const pixels = Buffer.alloc(height * stride);
  let pos = 0;
  for (let y = 0; y < height; y += 1) {
    const filter = raw[pos];
    pos += 1;
    const line = raw.subarray(pos, pos + stride);
    pos += stride;
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
        const pa = Math.abs(p - a);
        const pb = Math.abs(p - b);
        const pc = Math.abs(p - c);
        value += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      }
      current[x] = value & 0xff;
    }
  }
  return { width, height, channels, pixels };
}

/// One pixel as { r, g, b }, ignoring any alpha channel.
export function pixelAt(image, x, y) {
  const base = (y * image.width + x) * image.channels;
  if (image.channels >= 3) {
    return { r: image.pixels[base], g: image.pixels[base + 1], b: image.pixels[base + 2] };
  }
  const grey = image.pixels[base];
  return { r: grey, g: grey, b: grey };
}
