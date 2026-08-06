// UTF-16 (JavaScript strings, DOM caret offsets) <-> UTF-8 (Neovim byte columns).
//
// A DOM caret offset counts UTF-16 code units into rendered text. Neovim's
// `nvim_win_set_cursor()` wants a count of UTF-8 bytes into a source line. The
// two agree exactly for ASCII, differ by 3x for CJK, and by 2x for anything
// astral -- so a conversion that is simply missing is invisible in every test
// written in English and wrong for everyone else.
//
// This module knows nothing about markdown-it, the DOM, or the source map. It is
// the bottom of the provenance chain and is tested directly, before it is tested
// through anything above it.

const HIGH_SURROGATE_START = 0xd800;
const HIGH_SURROGATE_END = 0xdbff;
const LOW_SURROGATE_START = 0xdc00;
const LOW_SURROGATE_END = 0xdfff;

function isHighSurrogate(code) {
  return code >= HIGH_SURROGATE_START && code <= HIGH_SURROGATE_END;
}

function isLowSurrogate(code) {
  return code >= LOW_SURROGATE_START && code <= LOW_SURROGATE_END;
}

function isPairAt(text, index) {
  return isHighSurrogate(text.charCodeAt(index))
    && index + 1 < text.length
    && isLowSurrogate(text.charCodeAt(index + 1));
}

/// UTF-8 width of the code point starting at `index`. A lone surrogate is 3
/// because that is what it encodes to (U+FFFD) once it leaves the process.
function widthAt(text, index) {
  if (isPairAt(text, index)) return 4;
  const code = text.charCodeAt(index);
  if (code < 0x80) return 1;
  if (code < 0x800) return 2;
  return 3;
}

/// Clamp `offset` into `text` and move it off the middle of a surrogate pair.
///
/// Snapping *backwards* is deliberate: a caret that split an emoji belongs to
/// that emoji, and snapping forward would silently place the cursor past a
/// character the user clicked directly on.
export function snapUtf16Offset(text, offset) {
  const parsed = Number(offset);
  if (!Number.isFinite(parsed)) return 0;
  const clamped = Math.max(0, Math.min(Math.floor(parsed), text.length));
  if (clamped <= 0 || clamped >= text.length) return clamped;
  if (isHighSurrogate(text.charCodeAt(clamped - 1)) && isLowSurrogate(text.charCodeAt(clamped))) {
    return clamped - 1;
  }
  return clamped;
}

/// UTF-16 code-unit offset -> UTF-8 byte offset. The result is always a valid
/// UTF-8 boundary, which is what makes it safe to hand to `nvim_win_set_cursor`.
export function utf16ToByteOffset(text, utf16Offset) {
  const end = snapUtf16Offset(text, utf16Offset);
  let bytes = 0;
  let index = 0;
  while (index < end) {
    const pair = isPairAt(text, index);
    bytes += widthAt(text, index);
    index += pair ? 2 : 1;
  }
  return bytes;
}

/// UTF-8 byte offset -> UTF-16 code-unit offset. The inverse of the above, used
/// by the tests to check round-trips rather than only spot values. A byte offset
/// landing inside a character snaps back to that character's start.
export function byteToUtf16Offset(text, byteOffset) {
  const parsed = Number(byteOffset);
  const target = Number.isFinite(parsed) ? Math.max(0, Math.floor(parsed)) : 0;
  let bytes = 0;
  let index = 0;
  while (index < text.length && bytes < target) {
    const pair = isPairAt(text, index);
    const width = widthAt(text, index);
    if (bytes + width > target) break;
    bytes += width;
    index += pair ? 2 : 1;
  }
  return index;
}

/// UTF-8 byte length of the whole string.
export function utf8ByteLength(text) {
  return utf16ToByteOffset(text, text.length);
}
