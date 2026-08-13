// Rendered frames, held in memory under an opaque reference.
//
// A frame rasterized on the machine the *terminal* is on must not travel to
// the machine Neovim is on -- shipping the pixels across the link is exactly
// the cost this whole design exists to stop paying. So the PNG stays here and
// only its reference crosses. The Lua side then emits that reference in the
// byte stream it was already sending to the terminal, and the splicer in front
// of the terminal swaps it back for these bytes. See renderer/src/splice.js and
// docs/local-render-design.md.
//
// Bounded, because nothing acknowledges a frame. A reference is minted for
// every capture, and a capture that is superseded before Lua emits its token --
// which is the common case during a fast scroll -- leaves its entry with no
// reader. The bound is what keeps that from being a leak.
//
// **Recency is refreshed on read, not just on write.** `restore_clean_base` on
// the Lua side re-transmits the newest selection-free frame at the start of
// every drag, sometimes minutes after it was captured. Under a write-only LRU
// that frame ages out while it is still the one being used; under this one it
// stays hot for as long as it keeps being asked for, which is the property that
// makes the drag overlay work without a renderer round trip.

import crypto from "node:crypto";

const DEFAULT_MAX_FRAMES = 96;
const DEFAULT_MAX_BYTES = 192 * 1024 * 1024;

/// A bounded, in-memory store of PNG buffers addressed by opaque reference.
///
/// `maxFrames` and `maxBytes` are both ceilings and either can evict. A scroll
/// frame at half scale measures ~47KB and a settle frame ~335KB on the link
/// this was built for, so the defaults hold a couple of minutes of continuous
/// scrolling -- far more than the one or two frames anything actually re-reads.
export function createFrameStore({ maxFrames = DEFAULT_MAX_FRAMES, maxBytes = DEFAULT_MAX_BYTES } = {}) {
  // Insertion-ordered, and re-inserted on read, so the first key is always the
  // least recently *used* rather than the least recently added.
  const entries = new Map();
  let heldBytes = 0;
  let serial = 0;
  let evicted = 0;
  let misses = 0;
  // References must not be guessable across companion restarts, and must not
  // collide with ones a Lua side is still holding from the process before this
  // one. A per-process nonce plus a counter gives both without coordination.
  const nonce = crypto.randomBytes(4).toString("hex");

  function evictOldest() {
    const oldest = entries.keys().next();
    if (oldest.done) return false;
    heldBytes -= entries.get(oldest.value).length;
    entries.delete(oldest.value);
    evicted += 1;
    return true;
  }

  return {
    /// Store one PNG and return the reference that names it.
    ///
    /// The reference is `[A-Za-z0-9_-]+` deliberately: it is embedded verbatim
    /// in a terminal escape sequence, so it may not contain the `;` that
    /// separates the token's fields or the ESC that ends it. splice.js refuses
    /// anything outside that alphabet rather than trusting this.
    put(bytes) {
      const buffer = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes);
      serial += 1;
      const ref = `${nonce}-${serial.toString(36)}`;
      entries.set(ref, buffer);
      heldBytes += buffer.length;
      while (entries.size > maxFrames || (heldBytes > maxBytes && entries.size > 1)) {
        if (!evictOldest()) break;
      }
      return ref;
    },

    /// The bytes behind a reference, or null. A hit is a use: it moves the
    /// entry to the newest end so that a frame which keeps being re-transmitted
    /// keeps being held.
    get(ref) {
      const buffer = entries.get(ref);
      if (buffer === undefined) {
        misses += 1;
        return null;
      }
      entries.delete(ref);
      entries.set(ref, buffer);
      return buffer;
    },

    /// Drop everything. Called when a companion's client disconnects, for the
    /// same reason the document cache is dropped there: the next session's
    /// references are minted fresh and nothing may answer with the last one's.
    clear() {
      entries.clear();
      heldBytes = 0;
    },

    /// What the store is doing, for `:MdViewerHealth`. `misses` is the number
    /// that matters: a non-zero count means a token reached the terminal naming
    /// a frame this process no longer had, which shows up as one frame that
    /// never appeared.
    stats() {
      return { frames: entries.size, bytes: heldBytes, minted: serial, evicted, misses };
    },
  };
}
