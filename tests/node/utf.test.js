import test from "node:test";
import assert from "node:assert/strict";
import {
  byteToUtf16Offset,
  snapUtf16Offset,
  utf8ByteLength,
  utf16ToByteOffset,
} from "../../renderer/src/utf.js";

// The conversion is tested here, in isolation, before it is tested through the
// source map and before it is tested through the DOM. When a provenance test
// fails, this file is what tells you whether the arithmetic or the mapping broke.

const EMOJI = "\u{1F389}"; // U+1F389 PARTY POPPER: 2 UTF-16 units, 4 UTF-8 bytes
const FAMILY = "\u{1F468}‍\u{1F469}‍\u{1F467}"; // ZWJ sequence
const COMBINING = "é"; // e + COMBINING ACUTE: 2 units, 3 bytes
const PRECOMPOSED = "é"; // é: 1 unit, 2 bytes

test("utf8ByteLength matches Buffer for every script the preview can render", () => {
  const samples = [
    "",
    "plain ascii",
    "café",
    COMBINING,
    "日本語",
    EMOJI,
    FAMILY,
    "\ttabbed\tline\t",
    `mixed \t ${PRECOMPOSED} 中 ${EMOJI} end`,
  ];
  for (const sample of samples) {
    assert.equal(utf8ByteLength(sample), Buffer.byteLength(sample, "utf8"),
      `byte length disagreed for ${JSON.stringify(sample)}`);
  }
});

test("per-script byte widths are what Neovim will index by", () => {
  assert.equal(utf16ToByteOffset("abc", 0), 0);
  assert.equal(utf16ToByteOffset("abc", 3), 3, "ASCII is 1 byte per code unit");
  assert.equal(utf16ToByteOffset(PRECOMPOSED + "x", 1), 2, "accented Latin is 2 bytes");
  assert.equal(utf16ToByteOffset(COMBINING, 1), 1, "a combining mark's base is still 1 byte");
  assert.equal(utf16ToByteOffset(COMBINING, 2), 3, "the combining mark itself is 2 more");
  assert.equal(utf16ToByteOffset("日本語", 1), 3, "CJK is 3 bytes per code unit");
  assert.equal(utf16ToByteOffset("日本語", 3), 9);
  assert.equal(utf16ToByteOffset(EMOJI + "x", 2), 4, "an astral character is 4 bytes for 2 units");
  assert.equal(utf16ToByteOffset("\t\tx", 2), 2, "a tab is one byte, not a rendered width");
  assert.equal(utf16ToByteOffset(FAMILY, FAMILY.length), 18, "ZWJ joiners are counted, not collapsed");
});

test("a caret that split a surrogate pair snaps back onto the character", () => {
  const line = `a${EMOJI}b`;
  // Offset 2 is between the high and low surrogate: not a character boundary,
  // and not a byte boundary Neovim could accept either.
  assert.equal(snapUtf16Offset(line, 2), 1, "snapping forward would skip the emoji the user clicked");
  assert.equal(utf16ToByteOffset(line, 2), 1, "the split caret resolves to the emoji's first byte");
  assert.equal(utf16ToByteOffset(line, 3), 5, "past the emoji is 1 + 4 bytes");
  assert.equal(utf16ToByteOffset(line, 4), 6);
  // Every offset must land on a real UTF-8 boundary, which is the property that
  // keeps nvim_win_set_cursor from being handed a column inside a character.
  const boundaries = new Set();
  for (let index = 0; index <= line.length; index += 1) boundaries.add(utf16ToByteOffset(line, index));
  assert.deepEqual([...boundaries].sort((a, b) => a - b), [0, 1, 5, 6]);
});

test("offsets outside the string are clamped rather than trusted", () => {
  const line = `x${EMOJI}`;
  assert.equal(utf16ToByteOffset(line, -5), 0);
  assert.equal(utf16ToByteOffset(line, 999), 5);
  assert.equal(utf16ToByteOffset(line, Number.NaN), 0);
  assert.equal(utf16ToByteOffset(line, undefined), 0);
  assert.equal(utf16ToByteOffset(line, 1.9), 1, "a fractional caret truncates, never rounds up");
  assert.equal(snapUtf16Offset("", 3), 0);
});

test("a lone surrogate is measured as the replacement character it becomes", () => {
  const broken = `a\uD83Cb`;
  assert.equal(utf16ToByteOffset(broken, 2), 4, "1 for 'a' plus 3 for U+FFFD");
  assert.equal(utf8ByteLength(broken), Buffer.byteLength(broken, "utf8"));
});

test("byte offsets round-trip back to code-unit offsets", () => {
  const lines = [
    "plain",
    `caf${PRECOMPOSED} 日本語 ${EMOJI} done.`,
    `\t${FAMILY}\t${COMBINING}`,
    "Repeated: apple banana apple",
  ];
  for (const line of lines) {
    for (let index = 0; index <= line.length; index += 1) {
      const snapped = snapUtf16Offset(line, index);
      const bytes = utf16ToByteOffset(line, index);
      assert.equal(byteToUtf16Offset(line, bytes), snapped,
        `round trip failed at ${index} of ${JSON.stringify(line)}`);
      assert.equal(bytes, Buffer.byteLength(line.slice(0, snapped), "utf8"));
    }
  }
});

test("a byte offset landing inside a character snaps back to its start", () => {
  const line = `a${EMOJI}b`;
  // Bytes 2, 3 and 4 are all interior bytes of the emoji.
  for (const inside of [2, 3, 4]) assert.equal(byteToUtf16Offset(line, inside), 1);
  assert.equal(byteToUtf16Offset(line, 5), 3);
  assert.equal(byteToUtf16Offset(line, 999), line.length);
  assert.equal(byteToUtf16Offset(line, -1), 0);
});
