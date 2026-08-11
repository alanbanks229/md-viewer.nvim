/// What counts as animated media, and how much of it the preview will carry.
///
/// This is the single home of the animation budgets, and the only production
/// file that reads media container bytes directly. The reads are deliberately
/// shallow: fixed header fields and length-prefixed block *walks*, never
/// entropy-coded data. Pixel decoding belongs to Chromium (decode-context.js),
/// whose GIF and WebP decoders are sandboxed and continuously fuzzed. A
/// hand-written LZW expander used to live in this repository; these ~100 lines
/// of bounds-checked skipping are what replaced it, and they must never grow
/// back into one.

// -- Budgets ----------------------------------------------------------------
//
// Sized against this project's own README recording -- 1470x892 (1,311,240
// px), 241 frames, 16.1 seconds -- which fits the source caps but not by
// much. A cap no real image reaches is not a cap.

/// Per-frame decoded pixels. One frame of the README recording is ~1.3M.
export const MAX_SOURCE_PIXELS = 1_500_000;

/// Frames a source may contain before it is refused outright (not thinned --
/// refused; a five-minute screen recording is a video, not a preview image).
export const MAX_SOURCE_FRAMES = 300;

/// Total pixels one animation may occupy in the terminal, across every frame
/// kept for it. The terminal stores frames as decoded RGBA, so this budget is
/// 4x its value in resident bytes: 48M px is ~192MB, sized to stay well under
/// Kitty's ~320MB default graphics quota with room for the base image and
/// other previews. When a source exceeds it, frames are dropped evenly and
/// their display time merged into the survivors -- duration is preserved, the
/// animation gets choppier, and choppy reads as choppy where blurry would read
/// as broken.
export const UPLOAD_PIXEL_BUDGET = 48_000_000;

/// Per-frame pixels at the *drawn* size. Bounds the OffscreenCanvas the decode
/// context allocates for an <img width=...> upscaled far beyond sense.
export const MAX_TARGET_PIXELS = 16_000_000;

/// Animations registered per document. The rest render as still frames.
export const MAX_ANIMATIONS_PER_DOCUMENT = 4;

/// How many frames of `targetWidth x targetHeight` fit the upload budget.
/// Returns at least 0; a value below 2 means the drawn size leaves no room to
/// animate at all and the caller must refuse rather than "animate" one frame.
export function frameBudget(targetWidth, targetHeight, budget = UPLOAD_PIXEL_BUDGET) {
  const pixels = Math.floor(targetWidth) * Math.floor(targetHeight);
  if (!Number.isFinite(pixels) || pixels < 1) return 0;
  return Math.min(MAX_SOURCE_FRAMES, Math.floor(budget / pixels));
}

// -- Candidate sniffing -----------------------------------------------------

/// Whether `bytes` are worth sending to the decode context at all. Returns
/// `{ format, mime, width, height, frameCount }` for a plausible animation,
/// else null -- for stills, for malformed input, and for sources already over
/// a cap. The distinction is deliberately not reported: a document's image
/// either animates or keeps the perfectly correct still frame Chromium already
/// painted into the base screenshot, and register-time is too early to know
/// which caption the user deserves.
///
/// `frameCount` is exact for GIF (counted up to MAX_SOURCE_FRAMES + 1, so a
/// value past the cap means "too many", not a tally) and null for WebP, whose
/// ANIM flag answers "animated?" without a walk; its frame count is enforced
/// by the decode context instead.
export function sniffAnimation(bytes, limits = {}) {
  const maxPixels = limits.maxPixels ?? MAX_SOURCE_PIXELS;
  const maxFrames = limits.maxFrames ?? MAX_SOURCE_FRAMES;
  if (!Buffer.isBuffer(bytes)) return null;
  return sniffGif(bytes, maxPixels, maxFrames) ?? sniffWebp(bytes, maxPixels);
}

function sniffGif(bytes, maxPixels, maxFrames) {
  if (bytes.length < 13) return null;
  const magic = bytes.subarray(0, 6).toString("latin1");
  if (magic !== "GIF87a" && magic !== "GIF89a") return null;
  const width = bytes.readUInt16LE(6);
  const height = bytes.readUInt16LE(8);
  if (width < 1 || height < 1 || width * height > maxPixels) return null;

  let position = 13;
  // Global color table: 3 bytes per entry, entry count from the packed field.
  if (bytes[10] & 0x80) position += (2 << (bytes[10] & 7)) * 3;

  // Step over blocks counting image descriptors. Every sub-block is
  // length-prefixed, so the walk reads lengths and positions only; a byte out
  // of place ends the count with whatever preceded it, which at worst turns an
  // animation into the still frame it would fall back to anyway.
  const skipSubBlocks = () => {
    while (position < bytes.length) {
      const length = bytes[position];
      position += 1;
      if (length === 0) return true;
      position += length;
    }
    return false;
  };

  let frameCount = 0;
  while (position < bytes.length && frameCount <= maxFrames) {
    const introducer = bytes[position];
    if (introducer === 0x3b) break; // trailer
    if (introducer === 0x21) {
      // Extension: introducer, label, then sub-blocks. The GCE's fixed block
      // and the NETSCAPE loop block both fit that shape, and nothing in them
      // is needed here -- delays and loop counts come from the decode context.
      position += 2;
      if (!skipSubBlocks()) break;
      continue;
    }
    if (introducer === 0x2c) {
      // Image descriptor: 10 fixed bytes, optional local palette, LZW minimum
      // code size, then the pixel sub-blocks -- skipped, never expanded.
      if (position + 10 > bytes.length) break;
      const flags = bytes[position + 9];
      position += 10;
      if (flags & 0x80) position += (2 << (flags & 7)) * 3;
      position += 1;
      if (!skipSubBlocks()) break;
      frameCount += 1;
      continue;
    }
    break; // unrecoverable: count what was seen
  }

  if (frameCount < 2 || frameCount > maxFrames) return null;
  return { format: "gif", mime: "image/gif", width, height, frameCount };
}

function sniffWebp(bytes, maxPixels) {
  // Animated WebP requires an extended (VP8X) header with the ANIM flag; a
  // simple VP8/VP8L file cannot animate, so one flag bit answers the whole
  // question without walking a single chunk.
  if (bytes.length < 30) return null;
  if (bytes.subarray(0, 4).toString("latin1") !== "RIFF") return null;
  if (bytes.subarray(8, 12).toString("latin1") !== "WEBP") return null;
  if (bytes.subarray(12, 16).toString("latin1") !== "VP8X") return null;
  if ((bytes[20] & 0x02) === 0) return null; // ANIM flag
  const width = 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16));
  const height = 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16));
  if (width * height > maxPixels) return null;
  return { format: "webp", mime: "image/webp", width, height, frameCount: null };
}
