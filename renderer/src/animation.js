/// Turn animated images into the PNG frames a terminal can place.
///
/// The preview is one Chromium screenshot per frame, so an animated image
/// painted into it is frozen by construction. The way out is to let the
/// terminal draw the animation itself: Chromium still lays the image out and
/// still paints its first frame, and the Kitty graphics protocol places real
/// frames on top at the same rect -- either swapped by a Lua timer or, where
/// the terminal implements the protocol's animation extension, played by the
/// terminal with no timer at all.
///
/// This file owns the Node half, and it is deliberately small: recognize
/// candidates (media.js), decode and resize them in Chromium (decode-context.js),
/// write the frames to disk, and account for every byte. Decoding itself lives
/// in the browser's sandboxed codecs; there is no LZW here and there must
/// never be again.
///
/// The store is **content-addressed**. A materialization is keyed by
/// (sha256 of the source bytes, drawn width, drawn height) and nothing else --
/// no document id, no content revision. Geometry travels with the render
/// response, where it shares the base image's staleness exactly; the frames a
/// sha produces are the frames that sha produces, whichever document or
/// revision asks. This is what deleted the stale-geometry race the previous
/// design carried: there is no second copy of the geometry to go stale.
///
/// **Every frame file lives under the renderer's own temp directory.** That is
/// the trust boundary, not an implementation detail. The terminal is told to
/// read a path, so the path must never be one the document chose: directories
/// are named by a hash of the cache key, and the whole tree is inside the one
/// `browser.close()` already removes recursively.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { DecodeContext } from "./decode-context.js";
import {
  MAX_ANIMATIONS_PER_DOCUMENT,
  MAX_SOURCE_FRAMES,
  MAX_SOURCE_PIXELS,
  UPLOAD_PIXEL_BUDGET,
  frameBudget,
  sniffAnimation,
} from "./media.js";

/// Raw source bytes retained for re-materialization (a window resize asks for
/// new dimensions without re-sending the document). Bounded because sources
/// arrive up to `max_local_image_bytes` (10MB default) each and previous
/// behavior retained every one forever; a source evicted here comes back on
/// the next render of any document that still contains it.
const MAX_SOURCE_STORE_BYTES = 32 * 1024 * 1024;

/// Encoded frame files on disk across every materialization.
const MAX_FRAME_STORE_BYTES = 48 * 1024 * 1024;

/// Remembered refusals ("this sha at this size does not animate"), so a
/// document containing a refused image costs one decode ever, not one per
/// adoption. Entries are tiny; the cap only bounds pathological churn.
const MAX_REFUSALS = 256;

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

/// Refresh-on-hit for a Map used as an LRU. The markdown cache's one missing
/// refresh let a hot document age to the eviction end of the queue; every map
/// in this file goes through here so none of them can repeat that.
function refresh(map, key) {
  const value = map.get(key);
  if (value === undefined) return undefined;
  map.delete(key);
  map.set(key, value);
  return value;
}

export class AnimationStore {
  constructor(options = {}) {
    this.dir = options.dir;
    this.maxSourcePixels = options.maxSourcePixels ?? MAX_SOURCE_PIXELS;
    this.maxSourceFrames = options.maxSourceFrames ?? MAX_SOURCE_FRAMES;
    this.uploadPixelBudget = options.uploadPixelBudget ?? UPLOAD_PIXEL_BUDGET;
    this.maxSourceStoreBytes = options.maxSourceStoreBytes ?? MAX_SOURCE_STORE_BYTES;
    this.maxFrameStoreBytes = options.maxFrameStoreBytes ?? MAX_FRAME_STORE_BYTES;
    this.maxPerDocument = options.maxPerDocument ?? MAX_ANIMATIONS_PER_DOCUMENT;
    /// How the store reaches Chromium. Injected so tests can decode without a
    /// BrowserRenderer and so the store never owns browser lifecycle.
    this.browserProvider = options.browserProvider ?? (() => null);
    this.decodeContext = options.decodeContext ?? new DecodeContext();
    // sha -> { bytes, mime, width, height, frameCount }
    this.sources = new Map();
    this.sourceBytes = 0;
    // `${sha}:${w}x${h}` -> { key, directory, frames, loop, ... , bytes }
    this.materialized = new Map();
    this.frameBytes = 0;
    // `${sha}:${w}x${h}` -> reason string
    this.refused = new Map();
    // Same key while a decode is in flight: concurrent askers share one job.
    this.pending = new Map();
    this.serial = 0;
    // For :MdViewerDebug / health, not for control flow.
    this.stats = { decodes: 0, decodeMs: 0, refusals: 0, errors: 0, evictions: 0 };
  }

  /// How many animations a single document may carry. Beyond this the extras
  /// render as their painted first frame -- a document that is mostly GIFs is
  /// not a document this feature was built for.
  get perDocumentLimit() {
    return this.maxPerDocument;
  }

  /// Recognize an animated image and mint an opaque per-render id for it.
  ///
  /// Runs on every image the render rule emits, so it must be cheap for the
  /// common case: the sniff reads fixed header fields and, for GIF, walks
  /// length-prefixed blocks without expanding one. A still image returns null
  /// -- meaning "not animated, or not worth animating" -- rather than throwing.
  register(bytes) {
    if (!Buffer.isBuffer(bytes) || bytes.length === 0) return null;
    const sniffed = sniffAnimation(bytes, { maxPixels: this.maxSourcePixels, maxFrames: this.maxSourceFrames });
    if (!sniffed) return null;
    const sha = sha256(bytes);
    const existing = refresh(this.sources, sha);
    if (!existing) {
      this.sources.set(sha, {
        bytes: Buffer.from(bytes),
        mime: sniffed.mime,
        width: sniffed.width,
        height: sniffed.height,
        frameCount: sniffed.frameCount,
      });
      this.sourceBytes += bytes.length;
      this.#evictSources();
    }
    this.serial += 1;
    return { id: `a${this.serial}`, sha, frameCount: sniffed.frameCount };
  }

  /// Produce the PNG frames for one animation at one drawn size.
  ///
  /// Always resolves to a status object, never rejects:
  ///   { status: "ok", frames: [{ path, key, gapMs }], loop, ... }
  ///   { status: "refused", reason }         -- the input's fault; remembered
  ///   { status: "error", reason }           -- the environment's; retryable
  ///   { status: "unknown-source" }          -- sha not held; re-render restores it
  ///
  /// `frames[i].key` is stable across renderer restarts (derived from content
  /// and size, never from the temp path), which is what lets the Lua side
  /// re-use frames already resident in the terminal instead of re-uploading a
  /// set the new process wrote to new paths.
  materialize(sha, targetWidth, targetHeight) {
    const width = Math.round(Number(targetWidth));
    const height = Math.round(Number(targetHeight));
    if (!(width >= 1) || !(height >= 1)) {
      return Promise.resolve({ status: "error", reason: "target dimensions are not positive" });
    }
    const key = `${sha}:${width}x${height}`;

    const cached = refresh(this.materialized, key);
    if (cached) return Promise.resolve({ status: "ok", ...cached.payload });
    const priorRefusal = this.refused.get(key);
    if (priorRefusal) return Promise.resolve({ status: "refused", reason: priorRefusal });
    const inFlight = this.pending.get(key);
    if (inFlight) return inFlight;

    const source = refresh(this.sources, sha);
    if (!source) return Promise.resolve({ status: "unknown-source" });

    const job = this.#build(key, sha, source, width, height).then((outcome) => {
      this.pending.delete(key);
      return outcome;
    });
    this.pending.set(key, job);
    return job;
  }

  async #build(key, sha, source, width, height) {
    const keepFrames = frameBudget(width, height, this.uploadPixelBudget);
    if (keepFrames < 2) {
      return this.#refuse(key, "drawn size leaves no frame budget");
    }

    const started = Date.now();
    const decoded = await this.decodeContext.decode(this.browserProvider(), source.bytes, {
      mime: source.mime,
      targetWidth: width,
      targetHeight: height,
      keepFrames,
      maxSourceFrames: this.maxSourceFrames,
      maxSourcePixels: this.maxSourcePixels,
    });
    const decodeMs = Date.now() - started;
    this.stats.decodes += 1;
    this.stats.decodeMs += decodeMs;

    if (decoded.status === "refused") return this.#refuse(key, decoded.reason);
    if (decoded.status !== "ok") {
      // Environment trouble (browser restarting, timeout) is deliberately NOT
      // remembered: the next adoption retries against a healthier world.
      this.stats.errors += 1;
      return { status: "error", reason: decoded.reason ?? "decode failed" };
    }

    // Directory named by a hash of the *whole* cache key. The previous scheme
    // omitted part of the key from the directory name, so evicting one entry
    // deleted files a surviving entry still pointed at; a bijection between
    // entries and directories makes that impossible by construction.
    const directory = path.join(this.dir, "anim", sha256(key).slice(0, 24));
    let bytes = 0;
    const frames = [];
    try {
      fs.mkdirSync(directory, { recursive: true });
      for (let index = 0; index < decoded.frames.length; index += 1) {
        const file = path.join(directory, `${String(index).padStart(4, "0")}.png`);
        const png = Buffer.from(decoded.frames[index].png, "base64");
        fs.writeFileSync(file, png);
        bytes += png.length;
        frames.push({
          path: file,
          key: sha256(`${key}:${index}`).slice(0, 16),
          gapMs: decoded.frames[index].gapMs,
        });
      }
    } catch (error) {
      // A partial set must not survive: files without an entry are bytes the
      // budget cannot see and a directory eviction can never reclaim.
      fs.rmSync(directory, { recursive: true, force: true });
      this.stats.errors += 1;
      return { status: "error", reason: `could not write frames: ${error?.message ?? error}` };
    }

    const payload = {
      frames,
      loop: decoded.loop,
      frameWidthPx: width,
      frameHeightPx: height,
      sourceFrameCount: decoded.sourceFrameCount,
      keptFrameCount: decoded.keptFrameCount,
      decodeMs,
      bytes,
    };
    this.materialized.set(key, { key, directory, bytes, payload });
    this.frameBytes += bytes;
    this.#evictMaterialized();
    return { status: "ok", ...payload };
  }

  #refuse(key, reason) {
    this.stats.refusals += 1;
    this.refused.set(key, reason);
    while (this.refused.size > MAX_REFUSALS) {
      this.refused.delete(this.refused.keys().next().value);
    }
    return { status: "refused", reason };
  }

  /// Oldest-first, and only ever whole entries with their whole directories:
  /// the entry-to-directory bijection is what makes this safe.
  #evictMaterialized() {
    while (this.frameBytes > this.maxFrameStoreBytes && this.materialized.size > 1) {
      const oldestKey = this.materialized.keys().next().value;
      const oldest = this.materialized.get(oldestKey);
      this.materialized.delete(oldestKey);
      this.frameBytes -= oldest.bytes;
      this.stats.evictions += 1;
      fs.rmSync(oldest.directory, { recursive: true, force: true });
    }
  }

  #evictSources() {
    while (this.sourceBytes > this.maxSourceStoreBytes && this.sources.size > 1) {
      const oldestKey = this.sources.keys().next().value;
      const oldest = this.sources.get(oldestKey);
      this.sources.delete(oldestKey);
      this.sourceBytes -= oldest.bytes.length;
      this.stats.evictions += 1;
    }
  }

  /// One line of numbers for health/debug output. Counts and bytes only --
  /// nothing here is a handle.
  snapshot() {
    return {
      sources: this.sources.size,
      sourceBytes: this.sourceBytes,
      materialized: this.materialized.size,
      frameBytes: this.frameBytes,
      refusals: this.refused.size,
      pending: this.pending.size,
      decodes: this.stats.decodes,
      decodeMs: this.stats.decodeMs,
      errors: this.stats.errors,
      evictions: this.stats.evictions,
    };
  }

  async close() {
    this.sources.clear();
    this.materialized.clear();
    this.refused.clear();
    this.pending.clear();
    this.sourceBytes = 0;
    this.frameBytes = 0;
    await this.decodeContext.close();
    // Frame directories live inside browser.tempDir, which browser.close()
    // removes recursively; removing them twice is not worth the code.
  }
}
