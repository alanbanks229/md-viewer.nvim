// Content-addressed image bytes, used on both ends of the local-render
// split: the VM's doc service fills one while extracting `md-asset:` refs
// from freshly validated images, and the helper fills its own from what the
// plugin pushes. Content addressing is what makes the transfer protocol
// honest -- an asset crosses the slow link at most once per content, a
// restarted helper simply reports misses, and the receiving side can verify
// that pushed bytes are the bytes their name claims.
//
// The budget mirrors remote-images.js's cache (64 MiB / 256 entries, LRU by
// insertion refresh) because it bounds the same kind of thing for the same
// reason: documents can reference more image bytes than a long-lived process
// should ever hold.

import crypto from "node:crypto";

const MAX_BYTES = 64 * 1024 * 1024;
const MAX_ENTRIES = 256;

const DATA_URI = /^data:([^;,]+);base64,(.*)$/s;

export function sha256(data) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

export class AssetStore {
  constructor({ maxBytes = MAX_BYTES, maxEntries = MAX_ENTRIES } = {}) {
    this.maxBytes = maxBytes;
    this.maxEntries = maxEntries;
    this.entries = new Map(); // sha -> { mime, data }
    this.totalBytes = 0;
  }

  /// Store already-validated bytes; returns the sha the `md-asset:` ref uses.
  put(mime, data) {
    const sha = sha256(data);
    this.putVerified(sha, mime, data);
    return sha;
  }

  /// Store bytes under a claimed sha, verifying the claim. Returns false --
  /// and stores nothing -- when the bytes are not what their name says,
  /// which is the integrity check that keeps the push channel from renaming
  /// one image into another.
  putVerified(sha, mime, data) {
    if (sha256(data) !== sha) return false;
    if (this.entries.has(sha)) {
      // Refresh recency without recounting bytes.
      const existing = this.entries.get(sha);
      this.entries.delete(sha);
      this.entries.set(sha, existing);
      return true;
    }
    this.entries.set(sha, { mime, data });
    this.totalBytes += data.length;
    while (this.entries.size > this.maxEntries || this.totalBytes > this.maxBytes) {
      const oldest = this.entries.keys().next().value;
      if (oldest === undefined) break;
      this.totalBytes -= this.entries.get(oldest).data.length;
      this.entries.delete(oldest);
    }
    return true;
  }

  /// Extract mime and bytes from a `data:` URI and store them. Returns the
  /// sha, or null when the URI is not the base64 shape every validated image
  /// in this pipeline has.
  putDataUri(uri) {
    const match = DATA_URI.exec(uri);
    if (!match) return null;
    return this.put(match[1], Buffer.from(match[2], "base64"));
  }

  get(sha) {
    const entry = this.entries.get(sha);
    if (!entry) return null;
    this.entries.delete(sha);
    this.entries.set(sha, entry);
    return entry;
  }

  has(sha) {
    return this.entries.has(sha);
  }

  dataUri(sha) {
    const entry = this.get(sha);
    return entry ? `data:${entry.mime};base64,${entry.data.toString("base64")}` : null;
  }

  stats() {
    return { entries: this.entries.size, bytes: this.totalBytes };
  }
}
