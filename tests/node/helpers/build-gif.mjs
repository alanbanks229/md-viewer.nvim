// A real GIF89a encoder, small enough to read. GIFs are built here rather than
// committed as binary fixtures: the cases that matter are malformed ones, and a
// hand-built file is the only way to say exactly *how* it is malformed. The
// LZW below emits literal codes with correct dictionary growth and clear-code
// resets, so a consumer sees a genuine stream rather than a special case.
//
// Lifted out of tests/node/gif.test.js when the Chromium decode context needed
// the same inputs the hand-written decoder was tested against.

export function lzwEncodeLiterals(indices, minimumCodeSize) {
  const clearCode = 1 << minimumCodeSize;
  const endCode = clearCode + 1;
  const bytes = [];
  let bits = 0;
  let bitCount = 0;
  let codeSize = minimumCodeSize + 1;
  let nextCode = endCode + 1;
  let sinceClear = 0;

  const emit = (code) => {
    bits |= code << bitCount;
    bitCount += codeSize;
    while (bitCount >= 8) {
      bytes.push(bits & 0xff);
      bits >>= 8;
      bitCount -= 8;
    }
  };
  const reset = () => {
    emit(clearCode);
    codeSize = minimumCodeSize + 1;
    nextCode = endCode + 1;
    sinceClear = 0;
  };

  reset();
  for (let i = 0; i < indices.length; i += 1) {
    emit(indices[i]);
    // The decoder adds a dictionary entry for every code after the first
    // following a clear -- *each* clear, not just the stream's first --
    // and widens on the power-of-two boundary. An earlier version counted
    // from the start of the stream, which desynchronized the code width one
    // entry after every mid-stream reset; nothing noticed until Chromium's
    // spec-correct decoder met a frame longer than 4000 codes.
    sinceClear += 1;
    if (sinceClear > 1) {
      nextCode += 1;
      if (nextCode === 1 << codeSize && codeSize < 12) codeSize += 1;
    }
    if (nextCode >= 4000) reset();
  }
  emit(endCode);
  if (bitCount > 0) bytes.push(bits & 0xff);

  // Wrap in sub-blocks, terminated by a zero-length one.
  const out = [minimumCodeSize];
  for (let offset = 0; offset < bytes.length; offset += 255) {
    const slice = bytes.slice(offset, offset + 255);
    out.push(slice.length, ...slice);
  }
  out.push(0);
  return out;
}

/// `frames` is [{ indices, delayCs, disposal, transparentIndex, left, top,
/// width, height, interlaced }]. Palette is four colours: black, red, green,
/// blue.
export function buildGif(width, height, frames, options = {}) {
  const bytes = [];
  bytes.push(...Buffer.from(options.magic ?? "GIF89a", "latin1"));
  bytes.push(width & 0xff, width >> 8, height & 0xff, height >> 8);
  bytes.push(0x80 | 0x01, 0, 0); // global palette, 4 entries
  bytes.push(0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255);

  if (options.loopCount !== undefined) {
    bytes.push(0x21, 0xff, 11, ...Buffer.from("NETSCAPE2.0", "latin1"));
    bytes.push(3, 1, options.loopCount & 0xff, options.loopCount >> 8, 0);
  }

  for (const frame of frames) {
    const delayCs = frame.delayCs ?? 10;
    const transparent = frame.transparentIndex ?? -1;
    const flags = ((frame.disposal ?? 0) << 2) | (transparent >= 0 ? 1 : 0);
    bytes.push(0x21, 0xf9, 4, flags, delayCs & 0xff, delayCs >> 8, transparent >= 0 ? transparent : 0, 0);

    const left = frame.left ?? 0;
    const top = frame.top ?? 0;
    const fw = frame.width ?? width;
    const fh = frame.height ?? height;
    bytes.push(0x2c, left & 0xff, left >> 8, top & 0xff, top >> 8, fw & 0xff, fw >> 8, fh & 0xff, fh >> 8);
    bytes.push(frame.interlaced ? 0x40 : 0x00);
    // Appended element-wise: spreading a megapixel frame's LZW stream into one
    // push() call overflows the JS argument stack.
    const data = lzwEncodeLiterals(frame.indices, 2);
    for (let i = 0; i < data.length; i += 1) bytes.push(data[i]);
  }

  bytes.push(0x3b);
  return Buffer.from(bytes);
}

export const solid = (value, count) => new Array(count).fill(value);
