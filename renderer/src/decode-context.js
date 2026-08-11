import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { MAX_TARGET_PIXELS } from "./media.js";

/// Animated-media decoding, delegated to the Chromium this project already
/// ships instead of a hand-written codec.
///
/// Security model, precisely because this is the one place JavaScript runs in
/// the browser:
///
///   * Its own BrowserContext, never the render context. The Markdown render
///     page keeps `javaScriptEnabled: false` and its deny-all CSP untouched.
///   * The page is a fixed internal URL fulfilled from the inline constant
///     below -- `context.route` serves that one URL and aborts every other
///     request, and the context is additionally `offline`. No bytes leave.
///   * The only code evaluated is `decodeInPage` below, serialized by
///     Playwright from this file. Media bytes travel as a base64 *argument* --
///     data handed to `ImageDecoder`, never text that could become code. The
///     page itself carries `default-src 'none'` so nothing else can run even
///     in principle.
///   * The actual parsing of attacker-influenced bytes happens inside
///     Chromium's sandboxed, fuzz-hardened image decoders -- the same code
///     that decodes these files in a browser tab, and the reason this file
///     contains no LZW.
///
/// A WebCodecs quirk this arrangement exists to satisfy: `ImageDecoder` is
/// SecureContext-gated, and `about:blank` has an opaque origin, so a plain
/// `setContent` page reports it undefined. The synthetic https:// origin is
/// what makes the API exist at all -- verified against the real system Chrome
/// this project launches, not assumed.
const DECODE_URL = "https://md-viewer.internal/decode";
// The <input type=file> is how media bytes enter: measured on this project's
// worst case (a 21MB source), a base64 string argument to page.evaluate costs
// ~640ms of CDP JSON serialization, while Chromium reading the same bytes from
// a scratch file costs ~40ms. The file's path is chosen by this process,
// never by the document -- same trust rule as every other temp path handed to
// an outside reader.
const DECODE_PAGE_HTML =
  '<!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src \'none\'">'
  + '<title>md-viewer decode context</title></head><body><input type="file" id="md-viewer-src"></body></html>';

/// Wall-clock ceiling for one decode. Far above a real decode (the README
/// recording's 241 frames decode and re-encode in well under two seconds) and
/// far below a wait anyone would sit through; a decoder that stalls this long
/// is treated as failed and the still frame stands.
const DECODE_TIMEOUT_MS = 30_000;

function withTimeout(promise, ms, label) {
  let timer;
  const expiry = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(label)), ms);
  });
  return Promise.race([promise, expiry]).finally(() => clearTimeout(timer));
}

export class DecodeContext {
  constructor(options = {}) {
    this.timeoutMs = options.timeoutMs ?? DECODE_TIMEOUT_MS;
    this.browser = null;
    this.context = null;
    this.page = null;
    this.scratchDir = null;
    // Decodes are serialized: the page holds per-decode scratch (the file
    // input, the canvas Chromium allocates), and two interleaved evaluates
    // would fight over it. Materialization is already deduplicated a level
    // up, so the queue is depth one or two in practice.
    this.queue = Promise.resolve();
  }

  #scratchPath() {
    if (!this.scratchDir) this.scratchDir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-decode-"));
    return path.join(this.scratchDir, "source.bin");
  }

  /// Decode `bytes` and re-encode the kept frames as PNGs at the drawn size.
  /// Never rejects. Returns one of:
  ///   { status: "ok", frames: [{ png(base64), gapMs }], loop, ... }
  ///   { status: "refused", reason }   -- the input's fault; cache it
  ///   { status: "error", reason }     -- the environment's fault; retryable
  decode(browser, bytes, options) {
    const job = this.queue.then(() => this.#decode(browser, bytes, options)).catch((error) => ({
      status: "error",
      reason: String(error?.message ?? error),
    }));
    this.queue = job.then(
      () => {},
      () => {},
    );
    return job;
  }

  async #decode(browser, bytes, options) {
    if (!browser || !browser.isConnected?.()) return { status: "error", reason: "browser is not running" };
    const targetWidth = Math.floor(options.targetWidth);
    const targetHeight = Math.floor(options.targetHeight);
    if (!(targetWidth >= 1) || !(targetHeight >= 1)) {
      return { status: "error", reason: "target dimensions are not positive" };
    }
    if (targetWidth * targetHeight > MAX_TARGET_PIXELS) {
      return { status: "refused", reason: "drawn size exceeds the per-frame pixel cap" };
    }
    const payload = {
      mime: options.mime,
      targetWidth,
      targetHeight,
      keepFrames: Math.max(2, Math.floor(options.keepFrames)),
      maxSourceFrames: Math.floor(options.maxSourceFrames),
      maxSourcePixels: Math.floor(options.maxSourcePixels),
    };
    const scratch = this.#scratchPath();
    try {
      fs.writeFileSync(scratch, bytes);
    } catch (error) {
      return { status: "error", reason: `could not stage media bytes: ${error?.message ?? error}` };
    }
    try {
      // One recreation attempt: the browser may have been relaunched since the
      // last decode, closing this context under us. A second failure is real.
      for (let attempt = 0; attempt < 2; attempt += 1) {
        try {
          await this.#ensure(browser);
          await this.page.setInputFiles("#md-viewer-src", scratch);
          const result = await withTimeout(
            this.page.evaluate(decodeInPage, payload),
            this.timeoutMs,
            "decode timed out",
          );
          return result ?? { status: "error", reason: "decode returned nothing" };
        } catch (error) {
          const message = String(error?.message ?? error);
          this.page = null; // force #ensure to rebuild on retry
          if (attempt === 1 || !/closed|crashed|detached|destroyed/i.test(message)) {
            return { status: "error", reason: message };
          }
        }
      }
      return { status: "error", reason: "decode context could not be rebuilt" };
    } finally {
      fs.rmSync(scratch, { force: true });
    }
  }

  async #ensure(browser) {
    if (this.page && !this.page.isClosed() && this.browser === browser) return;
    try {
      await this.context?.close();
    } catch {
      // The old context dying with its browser is exactly the case being
      // handled; there is nothing further to do about it.
    }
    this.browser = browser;
    this.context = await browser.newContext({ javaScriptEnabled: true, offline: true });
    await this.context.route("**/*", (route) => {
      if (route.request().url() === DECODE_URL) {
        return route.fulfill({ status: 200, contentType: "text/html", body: DECODE_PAGE_HTML });
      }
      return route.abort("blockedbyclient");
    });
    this.page = await this.context.newPage();
    await this.page.goto(DECODE_URL, { waitUntil: "domcontentloaded" });
  }

  async close() {
    try {
      await this.context?.close();
    } catch {
      // Already gone with its browser; closing is best-effort by design.
    }
    if (this.scratchDir) fs.rmSync(this.scratchDir, { recursive: true, force: true });
    this.browser = null;
    this.context = null;
    this.page = null;
    this.scratchDir = null;
  }
}

/// Runs inside Chromium. Self-contained by necessity -- Playwright serializes
/// the function source, so nothing here may reference module scope. Returns
/// the same status shapes as DecodeContext.decode and throws only for bugs;
/// malformed *input* is a refusal, because refusals are cached and a cached
/// crash-loop is the failure mode this shape exists to prevent.
async function decodeInPage(payload) {
  if (typeof ImageDecoder === "undefined") {
    return { status: "refused", reason: "this browser exposes no ImageDecoder (WebCodecs)" };
  }
  const supported = await ImageDecoder.isTypeSupported(payload.mime).catch(() => false);
  if (!supported) return { status: "refused", reason: `this browser cannot decode ${payload.mime}` };

  const staged = document.getElementById("md-viewer-src");
  const file = staged && staged.files && staged.files[0];
  if (!file) return { status: "error", reason: "no media bytes were staged" };
  const bytes = new Uint8Array(await file.arrayBuffer());

  let decoder = null;
  try {
    decoder = new ImageDecoder({ data: bytes, type: payload.mime });
    await decoder.tracks.ready;
    const track = decoder.tracks.selectedTrack;
    if (!track) return { status: "refused", reason: "no decodable image track" };
    // With fully buffered data `completed` settles quickly; a rejection means
    // the tail is malformed, and the loop below then keeps whatever whole
    // frames still decode -- same graceful truncation a browser tab shows.
    await decoder.completed.catch(() => null);

    const frameCount = track.frameCount;
    if (!track.animated || frameCount < 2) return { status: "refused", reason: "not an animation" };
    if (frameCount > payload.maxSourceFrames) {
      return { status: "refused", reason: `${frameCount} frames exceeds the ${payload.maxSourceFrames}-frame cap` };
    }

    // Thinning: keep every stride-th frame and fold the display time of the
    // dropped ones into the kept frame before them, so total duration -- the
    // thing a viewer actually perceives -- survives the cut.
    const stride = Math.max(1, Math.ceil(frameCount / payload.keepFrames));

    let canvas = null;
    let ctx = null;
    let sourceWidth = 0;
    let sourceHeight = 0;
    const frames = [];
    for (let index = 0; index < frameCount; index += 1) {
      let decoded;
      try {
        decoded = await decoder.decode({ frameIndex: index });
      } catch {
        break; // truncated tail: keep the whole frames already out
      }
      const frame = decoded.image;
      try {
        if (index === 0) {
          const sw = frame.codedWidth;
          const sh = frame.codedHeight;
          if (!(sw >= 1) || !(sh >= 1)) return { status: "refused", reason: "frame has no pixels" };
          if (sw * sh > payload.maxSourcePixels) {
            return { status: "refused", reason: `${sw}x${sh} exceeds the source pixel cap` };
          }
          sourceWidth = sw;
          sourceHeight = sh;
          canvas = new OffscreenCanvas(payload.targetWidth, payload.targetHeight);
          ctx = canvas.getContext("2d");
          ctx.imageSmoothingEnabled = true;
          ctx.imageSmoothingQuality = "high";
        }
        // Chromium reports the frame's display duration in microseconds and
        // has already applied the browser-standard clamp for degenerate GIF
        // delays; only a missing/zero duration needs the 100ms convention.
        let gapMs = Math.round((frame.duration ?? 0) / 1000);
        if (!Number.isFinite(gapMs) || gapMs <= 0) gapMs = 100;

        if (index % stride === 0) {
          ctx.clearRect(0, 0, payload.targetWidth, payload.targetHeight);
          ctx.drawImage(frame, 0, 0, payload.targetWidth, payload.targetHeight);
          const blob = await canvas.convertToBlob({ type: "image/png" });
          const encoded = new Uint8Array(await blob.arrayBuffer());
          let binary = "";
          for (let offset = 0; offset < encoded.length; offset += 0x8000) {
            binary += String.fromCharCode.apply(null, encoded.subarray(offset, offset + 0x8000));
          }
          frames.push({ png: btoa(binary), gapMs });
        } else if (frames.length > 0) {
          frames[frames.length - 1].gapMs += gapMs;
        }
      } finally {
        frame.close();
      }
    }

    if (frames.length < 2) return { status: "refused", reason: "fewer than two decodable frames" };

    // WebCodecs reports loop-forever as Infinity, which JSON serializes to
    // null -- hence the explicit encoding. A repetition count of 0 is a real
    // value: play once, stop on the last frame, exactly as a browser would.
    const reps = track.repetitionCount;
    const loop = reps === Infinity || reps == null || !(reps >= 0) ? "infinite" : Math.round(reps);

    return {
      status: "ok",
      frames,
      loop,
      width: payload.targetWidth,
      height: payload.targetHeight,
      sourceWidth,
      sourceHeight,
      sourceFrameCount: frameCount,
      keptFrameCount: frames.length,
    };
  } catch (error) {
    return { status: "refused", reason: `undecodable image: ${error?.message ?? error}` };
  } finally {
    try {
      decoder?.close();
    } catch {
      // A decoder that failed to construct has nothing to close.
    }
  }
}
