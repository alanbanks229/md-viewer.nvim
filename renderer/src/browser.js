import fs from "node:fs";
import { createHash } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { collectAnimationGeometry, collectBlockGeometry } from "./source-map.js";
import { csp, installNetworkPolicy } from "./security.js";
import { discoverChromium } from "./browser-discovery.js";
import { buildOverlaySheetPng } from "./overlay-sheet.js";
import {
  CARET_TINT,
  MAX_FIND_MATCHES_REPORTED,
  MAX_SELECTION_RECTS,
  SELECTION_TINT,
  TEXT_PREVIEW_LIMIT,
  buildActionResult,
  buildCaretMoveResult,
  buildFindClearResult,
  buildFindResult,
  buildFindStepResult,
  buildSelectionClearResult,
  buildSelectionResult,
  buildSelectionTextResult,
  clearFindInPage,
  clearSelectionInPage,
  createInteractError,
  hitTestInPage,
  moveCaretInPage,
  normalizeHit,
  paragraphSelectInPage,
  readSelectionTextInPage,
  resolveSelectionInPage,
  setFindInPage,
  stepFindInPage,
  wordSelectInPage,
} from "./interact.js";

const MAX_DOCUMENT_FRAMES = 64;

// How many further renders may re-measure animation geometry that was still
// settling when its layout was built. Each retry is one page.evaluate against a
// page that has already loaded, and the Lua side schedules a render to carry it
// -- so the bound is what keeps a permanently unmeasurable image (a broken
// source has a zero box for good) from becoming a permanent render loop.
const MAX_ANIMATION_GEOMETRY_RETRIES = 10;

// How long the raw CDP capture may take before it is treated as unavailable.
// A frame that takes this long is already useless to a preview; the number only
// has to be far above a real capture (tens of milliseconds) and far below any
// wait a person would sit through.
const CDP_CAPTURE_TIMEOUT_MS = 10000;

/// The complete Chromium command line, exported so a test can assert what is
/// *not* on it.
///
/// Deliberately no `--disable-frame-rate-limit`. It was here to skip the
/// compositor's refresh-rate-paced wait that Page.captureScreenshot blocks on
/// -- a fixed ~12ms per frame, unrelated to how much is being captured. On some
/// macOS hosts it does not remove that wait, it removes the frame: with the flag
/// set, the very first Page.captureScreenshot never answers at all. Measured on
/// GitHub's macOS runners, 0 of 12 launches captured a frame with the flag and
/// 12 of 12 without it, on both macOS 15 and macOS 26 and with both Google
/// Chrome and Chrome for Testing. Twelve milliseconds is not worth a preview
/// that can silently stop producing frames.
export const CHROMIUM_LAUNCH_ARGS = [
  "--disable-extensions", "--disable-component-update", "--no-first-run", "--no-default-browser-check",
];

function round(value) {
  return Math.round(value * 100) / 100;
}

/// Bound a CDP round trip.
///
/// `CDPSession.send` has no timeout of its own, so a compositor that never
/// commits a frame -- which is exactly what Page.captureScreenshot waits for --
/// leaves the returned promise pending forever. Unbounded, that is not a slow
/// preview but a dead one: the renderer's request queue is serial, so the stuck
/// capture blocks every later request behind it and nothing ever reports why.
/// Losing the fast path is a 12ms regression per frame; hanging is permanent.
function withTimeout(promise, ms, what) {
  let timer;
  const expiry = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} did not respond within ${ms}ms`)), ms);
  });
  return Promise.race([promise, expiry]).finally(() => clearTimeout(timer));
}

export class BrowserRenderer {
  constructor({ assetsDir }) {
    this.assetsDir = assetsDir;
    this.tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-"));
    this.browser = null;
    this.context = null;
    this.page = null;
    this.deviceScaleFactor = null;
    this.layout = null;
    this.viewport = null;
    this.discoveryReason = null;
    // The single authoritative record of which document is loaded in the shared
    // page. Mutated by exactly one code path -- loadDocument() -- and null
    // whenever no document can be trusted to be loaded, including for the whole
    // window during which setContent is in flight. Read by
    // ensureDocumentActive() before any interaction touches the DOM.
    this.active = null;
    // documentId -> the layout inputs needed to rebuild that document's page
    // byte-for-byte. The interact envelope carries no theme, font size, or
    // padding, so without this rehydration would have to guess -- and a guessed
    // theme is a page that does not match the screenshot the user is looking at.
    this.documents = new Map();
    this.documentTokenSerial = 0;
    // Raw CDP session on the shared page, used by captureViewport() for the one
    // screenshot option Playwright does not expose. Recreated with the page.
    this.cdp = null;
    // Set to the failure reason the first time the CDP capture path throws, so
    // a browser that does not support it costs one failed round trip rather
    // than one on every frame.
    this.cdpCaptureUnavailable = null;
    this.fastPngEncode = true;
    // A field rather than a constant so a test can prove the stall path without
    // waiting out the real budget.
    this.cdpCaptureTimeoutMs = CDP_CAPTURE_TIMEOUT_MS;
  }

  resolveExecutable(options = {}) {
    const { executable, reason } = discoverChromium(process.platform, process.env, fs.existsSync, options);
    this.discoveryReason = reason;
    return executable;
  }

  async ensure(options = {}, deviceScaleFactor = 2) {
    const scale = Math.max(1, Math.min(3, Number(deviceScaleFactor) || 2));
    // Re-read on every call, ahead of the early return below, so flipping the
    // setting takes effect on the next frame rather than needing a relaunch.
    this.fastPngEncode = options.fast_png_encode !== false;
    if (!this.browser) {
      const executablePath = this.resolveExecutable(options);
      this.browser = await chromium.launch({
        executablePath, headless: true, timeout: options.launch_timeout_ms ?? 10000,
        args: CHROMIUM_LAUNCH_ARGS,
      });
    }
    // The device scale factor is the only setting that can force a context
    // restart; the network policy below is unconditional and never varies.
    if (this.context && this.deviceScaleFactor === scale) return;
    try { await this.context?.close(); } catch {}
    this.deviceScaleFactor = scale;
    this.context = await this.browser.newContext({ deviceScaleFactor: this.deviceScaleFactor, javaScriptEnabled: false });
    await installNetworkPolicy(this.context);
    this.page = await this.context.newPage();
    // Bound to this page, so it is recreated with it and never outlives it.
    this.cdp = await this.context.newCDPSession(this.page).catch(() => null);
    this.cdpCaptureUnavailable = this.cdp ? null : "newCDPSession failed";
    // A brand-new page holds no document, so nothing may claim to be active.
    this.layout = this.viewport = this.active = null;
  }

  styles(theme) {
    const common = fs.readFileSync(path.join(this.assetsDir, "preview.css"), "utf8");
    const selected = fs.readFileSync(path.join(this.assetsDir, `preview-${theme === "light" ? "light" : "dark"}.css`), "utf8");
    return `${common}\n${selected}`;
  }

  /// The one document template. Both the render path and the rehydration path
  /// must go through here: two copies of this string is precisely how document A
  /// gets rehydrated into a page that does not match what was screenshotted.
  ///
  /// `token` is an opaque per-load counter stamped on the root element so that
  /// in-page code can refuse to answer from the wrong document. It sits on
  /// <html>, which the sanitizer never processes (the sanitizer only sees the
  /// markdown-derived body fragment), so it needs no allowlist entry.
  buildDocumentHtml({ html, theme, fontSizePx, scrollPastEnd, scrollPastEndOffsetPx, token }) {
    const lineHeightPx = Math.round(fontSizePx * (22 / 14));
    const bottomPadding = scrollPastEnd ? `calc(100vh - ${scrollPastEndOffsetPx}px)` : "48px";
    const rootVars = `--md-viewer-bottom-padding:${bottomPadding};--md-viewer-font-size:${fontSizePx}px;--md-viewer-line-height:${lineHeightPx}px`;
    return `<!doctype html><html data-md-viewer-doc="${token}"><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${csp}"><style>:root{${rootVars}}${this.styles(theme)}</style></head><body><article class="markdown-body">${html}</article></body></html>`;
  }

  /// Replace the page contents and take ownership of `this.active`. `active` is
  /// cleared *before* setContent and repopulated only after the geometry has
  /// been recollected, so there is no window in which a caller can read a
  /// half-loaded document and believe it.
  async loadDocument({ documentId, contentRevision, layoutKey, html, theme, fontSizePx, scrollPastEnd, scrollPastEndOffsetPx, width, height, animationIds }) {
    this.active = null;
    this.layout = null;
    this.documentTokenSerial += 1;
    const token = `d${this.documentTokenSerial}`;
    const documentHtml = this.buildDocumentHtml({ html, theme, fontSizePx, scrollPastEnd, scrollPastEndOffsetPx, token });
    await this.page.setContent(documentHtml, { waitUntil: "domcontentloaded" });
    const documentHeight = await this.page.evaluate(() => document.documentElement.scrollHeight);
    const blocks = await collectBlockGeometry(this.page);
    // Measured here, with the layout, because that is the only moment the rects
    // are known to match the document that produced them. A document with no
    // animated images pays one empty-set check and no round trip.
    //
    // `animationsComplete` rides along so `render` can take the measurement
    // again on a later pass: this one runs immediately after setContent, which
    // is the least likely moment in the document's life for every data-URI
    // image to have an intrinsic size yet.
    const { rects: animations, complete } = await collectAnimationGeometry(this.page, animationIds ?? []);
    this.layout = { key: layoutKey, documentHeight, blocks, animations, animationsComplete: complete };
    this.active = { documentId, contentRevision, layoutKey, token, width, height, scrollY: 0 };
    return { token, documentHeight, blocks, animations };
  }

  async applyScroll(documentHeight, height, requested) {
    const scrollY = Math.max(0, Math.min(Number(requested) || 0, Math.max(0, documentHeight - height)));
    await this.page.evaluate((top) => window.scrollTo(0, top), scrollY);
    this.rememberScrollY(scrollY);
    return scrollY;
  }

  /// Keep `this.active.scrollY` and the cached document record's own
  /// `scrollY` in sync, from every mechanism that can move the shared page
  /// (applyScroll, an in-page scrollIntoView for a find match, a fragment
  /// jump) -- not just applyScroll. `ensureDocumentActive()` falls back to
  /// the record's scrollY when a caller omits one, so an update recorded in
  /// only one of the two would leave that fallback answering with a stale
  /// position.
  rememberScrollY(scrollY) {
    if (this.active) {
      this.active.scrollY = scrollY;
      const record = this.documents.get(this.active.documentId);
      if (record) record.scrollY = scrollY;
    }
  }

  /// Write one viewport PNG, preferring CDP's `optimizeForSpeed`.
  ///
  /// Encoding the PNG is the largest *variable* cost of a frame -- 63-75% of a
  /// 990x1020@2 capture, measured, and linear in pixel count. `optimizeForSpeed`
  /// trades compression ratio for encoder time and produces the **same pixels**:
  /// three scroll positions were captured both ways, decoded back to raw
  /// samples, and compared -- identical every time, at a measured 84ms -> 50ms.
  /// The PNG is ~40% larger, which costs nothing that matters: the whole
  /// terminal upload of a 471KB frame measured 0.78ms.
  ///
  /// Playwright does not expose the option, so this goes through CDP directly
  /// and reproduces what `page.screenshot` does -- a test asserts the two paths
  /// return byte-identical files. If anything fails, the Playwright call is
  /// still the fallback, so a browser without the option renders normally.
  async captureViewportPng(pngPath, scale, scaleFactor) {
    // The moving frame of a scroll may be captured below its natural size. PNG
    // bytes against real content go as pixels^0.69, so half scale is about 2.6x
    // fewer bytes -- which is the whole of the lag on a link that is throughput
    // limited rather than latency limited, where one 80KB frame is ~134ms of
    // pure wire time and a wheel spin queues a hundred of them.
    //
    // Only ever applied to the `css` capture, which is the *moving* frame. The
    // `device` capture is the settle frame that lands when the wheel stops, and
    // a permanently soft idle preview is the one thing this must not produce.
    // Clamped here as well as in config.lua for the same reason
    // `deviceScaleFactor` is: this side does not trust the caller's arithmetic.
    const base = scale === "css" ? 1 : this.deviceScaleFactor;
    const factor = Number.isFinite(scaleFactor) ? Math.max(0.25, Math.min(1, scaleFactor)) : 1;
    const clipScale = scale === "css" ? base * factor : base;
    const usable = this.cdp && this.fastPngEncode && !this.cdpCaptureUnavailable && this.viewport;
    if (usable) {
      try {
        // `clip` is in CSS-pixel *document* coordinates, so it has to carry the
        // page's current scroll offset. Omitting it screenshots the top of the
        // document rather than what is on screen -- silently, and only once the
        // preview is scrolled, which is exactly how the `display_interact_result`
        // scrollY bug behaved. Read from the page rather than from
        // `active.scrollY`: a find match or a fragment jump moves the page from
        // inside the document, and the picture must follow the page, not the
        // bookkeeping.
        //
        // Bounded for the same reason the capture below is: `page.evaluate` has
        // no timeout of its own either, and a renderer that has stopped
        // answering must degrade to the Playwright path, not stall the queue.
        const origin = await withTimeout(
          this.page.evaluate(() => {
            const visual = window.visualViewport;
            return {
              x: visual ? visual.pageLeft : window.scrollX,
              y: visual ? visual.pageTop : window.scrollY,
            };
          }),
          this.cdpCaptureTimeoutMs,
          "scroll-origin evaluate",
        );
        const { data } = await withTimeout(
          this.cdp.send("Page.captureScreenshot", {
            format: "png",
            optimizeForSpeed: true,
            captureBeyondViewport: false,
            clip: {
              x: origin.x,
              y: origin.y,
              width: this.viewport.width,
              height: this.viewport.height,
              scale: clipScale,
            },
          }),
          this.cdpCaptureTimeoutMs,
          "Page.captureScreenshot",
        );
        fs.writeFileSync(pngPath, Buffer.from(data, "base64"));
        return "cdp_fast_png";
      } catch (error) {
        this.cdpCaptureUnavailable = String(error?.message ?? error);
      }
    }
    // Playwright's `scale` is the two-value enum, so a sub-1x scroll factor
    // cannot be expressed on this path. The frame comes back at its natural
    // size instead: correct, and merely as large as it was before
    // `render.scroll_scale` existed. `captureEncoder` in :MdViewerDebug is what
    // says which path a session is on.
    await this.page.screenshot({ path: pngPath, type: "png", fullPage: false, animations: "disabled", scale });
    return "playwright_png";
  }

  /// Screenshot the current viewport. Shared by render() and by any interaction
  /// that mutates visible state, so the mutation and its frame are produced by
  /// the same queued operation and Lua never has to follow up with a capture.
  async captureViewport({ documentId, requestId, captureScale, captureScaleFactor }) {
    const safeDocument = String(documentId ?? "document").replace(/[^a-zA-Z0-9_-]/g, "_");
    const pngPath = path.join(this.tempDir, `${safeDocument}-${requestId}.png`);
    const scale = captureScale === "css" ? "css" : "device";
    const started = performance.now();
    const captureEncoder = await this.captureViewportPng(pngPath, scale, captureScaleFactor);
    const captureMs = performance.now() - started;
    const pngBytes = fs.statSync(pngPath).size;
    // `captureScale` stays the two-value tier the Lua side keys its fast/settle
    // bookkeeping off; the factor rides alongside it rather than replacing it,
    // so `apply_image`'s "css" and "device" comparisons keep meaning what they
    // meant. Echoed back for :MdViewerDebug -- a frame that asked for 0.5 and
    // came back at 1 is the Playwright fallback path, and nothing else says so.
    return {
      pngPath,
      captureScale: scale,
      captureScaleFactor: scale === "css" ? captureScaleFactor : undefined,
      pngBytes,
      captureMs: round(captureMs),
      captureEncoder,
    };
  }

  rememberDocument(documentId, record) {
    this.documents.delete(documentId);
    this.documents.set(documentId, record);
    while (this.documents.size > MAX_DOCUMENT_FRAMES) {
      this.documents.delete(this.documents.keys().next().value);
    }
  }

  forgetDocument(documentId) {
    this.documents.delete(documentId);
    // `active` and `layout` are always set and cleared together; keeping that
    // invariant true means "a matching layout key implies a matching document".
    if (this.active?.documentId === documentId) this.active = this.layout = null;
  }

  async render(params, html, requestId) {
    const started = performance.now();
    const viewport = params.viewport ?? {};
    const width = Math.max(320, Math.min(1920, Math.round(viewport.widthPx ?? 960)));
    const height = Math.max(240, Math.min(1440, Math.round(viewport.heightPx ?? 900)));
    await this.ensure(params.browser, viewport.deviceScaleFactor);
    const viewportChanged = !this.viewport || this.viewport.width !== width || this.viewport.height !== height;
    if (viewportChanged) {
      await this.page.setViewportSize({ width, height });
      this.viewport = { width, height };
    }

    const fingerprint = params.contentFingerprint ?? JSON.stringify([
      params.contentRevision,
      createHash("sha256").update(html).digest("hex"),
    ]);
    const scrollPastEnd = params.scrollPastEnd !== false;
    const parsedOffset = Number(params.scrollPastEndOffsetPx);
    const scrollPastEndOffsetPx = Math.max(0, Math.min(240, Number.isFinite(parsedOffset) ? parsedOffset : 22));
    const parsedFontSize = Number(params.fontSizePx);
    const fontSizePx = Math.max(10, Math.min(28, Number.isFinite(parsedFontSize) ? parsedFontSize : 16));
    const theme = params.theme;
    const contentRevision = params.contentRevision === undefined || params.contentRevision === null
      ? null
      : String(params.contentRevision);
    const layoutKey = JSON.stringify([
      params.documentId, fingerprint, width, theme, scrollPastEnd, scrollPastEndOffsetPx, fontSizePx,
    ]);
    // `active` and `layout` are set and cleared together, so a matching layout
    // key also means the active record describes this document.
    const layoutReused = this.layout?.key === layoutKey && this.active?.documentId === params.documentId;
    const layoutStarted = performance.now();
    if (!layoutReused) {
      await this.loadDocument({
        documentId: params.documentId, contentRevision,
        layoutKey, html, theme, fontSizePx, scrollPastEnd, scrollPastEndOffsetPx, width, height,
        animationIds: params.animationIds,
      });
    } else {
      if (viewportChanged) {
        this.layout.documentHeight = await this.page.evaluate(() => document.documentElement.scrollHeight);
      }
      // Take the animation measurement again if the one built with this layout
      // timed out. Without this, that first attempt is the only one there will
      // ever be: geometry is collected in `loadDocument` alone, and `layoutKey`
      // carries width but not height -- so a document whose images had not been
      // sized within the deadline stayed on its still frames for the life of
      // the layout, and resizing the window "fixed" it only by re-keying it.
      // Costs one page.evaluate against an already-settled page, and only until
      // it succeeds, which is normally the very next render.
      if (this.layout.animationsComplete === false) {
        // One probe, no polling: a render already separates this attempt from
        // the last, so waiting here would only add latency to the render the
        // user is waiting on.
        const { rects, complete } = await collectAnimationGeometry(this.page, params.animationIds ?? [], { deadlineMs: 0 });
        // Never trade a longer set of rects for a shorter one. Nothing should
        // un-measure an image, but a retraction here would pull placements out
        // from under animations the Lua side is already running, which is worse
        // than waiting for the next pass.
        if (complete || rects.length > this.layout.animations.length) this.layout.animations = rects;
        // Bounded, because "not measured yet" and "will never measure" look
        // identical from here: an image whose source is broken keeps a zero box
        // forever, and an unbounded retry would ask Lua to re-render forever
        // chasing it. On giving up the layout is declared settled, which stops
        // both this retry and the scheduling on the Lua side.
        this.layout.animationRetries = (this.layout.animationRetries ?? 0) + 1;
        this.layout.animationsComplete = complete || this.layout.animationRetries >= MAX_ANIMATION_GEOMETRY_RETRIES;
      }
    }
    const layoutMs = performance.now() - layoutStarted;

    const documentHeight = this.layout.documentHeight;
    const scrollY = await this.applyScroll(documentHeight, height, params.scrollY);
    const capture = await this.captureViewport({
      documentId: params.documentId, requestId, captureScale: params.captureScale,
      captureScaleFactor: params.captureScaleFactor,
    });

    // The rehydration record. Written on every successful render so an
    // interaction arriving after some other document has taken over the page can
    // rebuild this exact layout rather than guess at it.
    this.rememberDocument(params.documentId, {
      layoutKey,
      token: this.active?.token ?? null,
      contentRevision,
      theme, fontSizePx, scrollPastEnd, scrollPastEndOffsetPx,
      width, height,
      deviceScaleFactor: this.deviceScaleFactor,
      browserOptions: params.browser,
      scrollY,
      documentHeight,
      blocks: this.layout.blocks,
      animations: this.layout.animations,
      animationIds: params.animationIds,
    });

    return {
      pngPath: capture.pngPath,
      documentHeightPx: documentHeight,
      viewportHeightPx: height,
      scrollY,
      blocks: this.layout.blocks,
      // Document-coordinate rects only. Frames are materialized off this path
      // (service.js's `animation` method): decoding a large GIF is seconds of CPU
      // and this is the queue every scroll and keystroke waits behind.
      animations: this.layout.animations ?? [],
      // True while some minted animation still has no measurable box. The Lua
      // side answers it with one more render, because nothing else would: an
      // idle preview issues no renders at all, so without a nudge the retry
      // above would sit waiting for a scroll or a keystroke that never comes.
      animationsIncomplete: this.layout.animationsComplete === false,
      layoutReused,
      captureScale: capture.captureScale,
      captureScaleFactor: capture.captureScaleFactor,
      captureEncoder: capture.captureEncoder,
      pngBytes: capture.pngBytes,
      layoutMs: round(layoutMs),
      captureMs: capture.captureMs,
      totalMs: round(performance.now() - started),
    };
  }

  /// Make `documentId` the document loaded in the shared page, or refuse.
  ///
  /// This is the only door into the DOM for an interaction. It never falls back
  /// to whatever happens to be loaded: a document it cannot rebuild is an error,
  /// not an approximation. Because callers run it inside the single serial
  /// queue, nothing can swap the page between this check and the caller's
  /// page.evaluate -- that co-location is the actual isolation guarantee.
  async ensureDocumentActive(envelope, cached) {
    const { documentId } = envelope;
    const contentRevision = String(envelope.contentRevision);
    const record = this.documents.get(documentId);
    if (!record) {
      throw createInteractError(
        "INTERACT_CACHE_MISS",
        `no rendered frame cached for document ${documentId}; perform a full render first`,
        { documentId, reason: "no_frame" }
      );
    }
    if (!cached || typeof cached.html !== "string") {
      throw createInteractError(
        "INTERACT_CACHE_MISS",
        `no cached markup for document ${documentId}; perform a full render first`,
        { documentId, reason: "no_markup" }
      );
    }
    if (record.contentRevision !== contentRevision) {
      throw createInteractError(
        "INTERACT_CACHE_MISS",
        `document ${documentId} is cached at content revision ${record.contentRevision}, not ${contentRevision}; render first`,
        { documentId, reason: "revision_mismatch", expected: record.contentRevision, received: contentRevision }
      );
    }
    if (envelope.viewportWidthPx !== record.width || envelope.viewportHeightPx !== record.height) {
      // Resizing here would silently invalidate the layout the incoming
      // coordinates were computed against, so refuse and let Lua re-render.
      throw createInteractError(
        "STALE_INTERACTION",
        `interaction viewport ${envelope.viewportWidthPx}x${envelope.viewportHeightPx} does not match the rendered ${record.width}x${record.height}`,
        { documentId, reason: "viewport_mismatch", lane: "interact" }
      );
    }

    // Pass the record's own browser settings so establishing an interaction can
    // never trigger a context recreation that would destroy the page.
    await this.ensure(record.browserOptions, record.deviceScaleFactor);
    if (!this.page) {
      throw createInteractError("INTERACT_NOT_READY", "no browser page is available; perform a full render first", { documentId });
    }

    const alreadyActive = this.active
      && this.active.documentId === documentId
      && this.active.contentRevision === contentRevision
      && this.active.layoutKey === record.layoutKey;

    if (this.viewport?.width !== record.width || this.viewport?.height !== record.height) {
      await this.page.setViewportSize({ width: record.width, height: record.height });
      this.viewport = { width: record.width, height: record.height };
    }

    if (alreadyActive) {
      // A request that omits scrollY preserves the document's current
      // position instead of resetting to the top -- see interact.js's
      // validateEnvelope, which passes null through rather than defaulting.
      const scrollY = await this.applyScroll(record.documentHeight, record.height, envelope.scrollY ?? record.scrollY);
      return { rehydrated: false, record, scrollY, documentHeight: record.documentHeight };
    }

    const loaded = await this.loadDocument({
      documentId,
      contentRevision,
      layoutKey: record.layoutKey,
      html: cached.html,
      theme: record.theme,
      fontSizePx: record.fontSizePx,
      scrollPastEnd: record.scrollPastEnd,
      scrollPastEndOffsetPx: record.scrollPastEndOffsetPx,
      width: record.width,
      height: record.height,
      animationIds: record.animationIds,
    });
    // Recollected rather than reused: the layout key pins everything that
    // affects geometry, so these should equal the stored values, and a test
    // asserts exactly that. If they ever diverge it is a bug worth seeing.
    record.token = loaded.token;
    record.documentHeight = loaded.documentHeight;
    record.blocks = loaded.blocks;
    record.animations = loaded.animations;
    const scrollY = await this.applyScroll(loaded.documentHeight, record.height, envelope.scrollY ?? record.scrollY);
    return { rehydrated: true, record, scrollY, documentHeight: loaded.documentHeight };
  }

  /// Scroll the shared page to an in-document anchor (`#id`) natively, i.e.
  /// via `Element.scrollIntoView()` run through `page.evaluate` -- not
  /// browser navigation. `javaScriptEnabled: false` blocks scripts the
  /// rendered Markdown could smuggle in; it does not affect this call, which
  /// runs trusted code injected by Node, the same mechanism `hitTestInPage`
  /// and `collectBlockGeometry` already rely on. The page never navigates
  /// away from the generated document.
  async scrollToFragment(href) {
    let id;
    try {
      id = decodeURIComponent(href.slice(1));
    } catch {
      return { found: false };
    }
    if (!id) return { found: false };
    const scrollY = await this.page.evaluate((rawId) => {
      const target = document.getElementById(rawId);
      if (!target) return null;
      target.scrollIntoView({ block: "start" });
      return window.scrollY;
    }, id);
    if (typeof scrollY !== "number") return { found: false };
    this.rememberScrollY(scrollY);
    return { found: true, scrollY };
  }

  /// Evaluate the in-page function for `action`. One dispatch point so the
  /// document-isolation guard, the ensureDocumentActive() call, and the
  /// same-queued-operation capture below apply uniformly to every action --
  /// hit-testing and all nine interaction actions alike -- rather than each
  /// action reimplementing that plumbing.
  async evaluateAction(action, envelope, cached) {
    const token = this.active.token;
    if (action === "selection_preview" || action === "selection_commit") {
      return this.page.evaluate(resolveSelectionInPage, {
        token, anchor: envelope.anchorCoordinates, focus: envelope.coordinates,
        anchorPinned: envelope.anchorPinned,
        cellWidthPx: envelope.cellWidthPx, strategy: envelope.strategy,
        maxRects: MAX_SELECTION_RECTS,
      });
    }
    if (action === "selection_clear") return this.page.evaluate(clearSelectionInPage, { token });
    if (action === "selection_text") return this.page.evaluate(readSelectionTextInPage, { token });
    if (action === "caret_move") {
      return this.page.evaluate(moveCaretInPage, {
        token, x: envelope.coordinates.x, y: envelope.coordinates.y,
        cellWidthPx: envelope.cellWidthPx,
        granularity: envelope.granularity, direction: envelope.direction, count: envelope.motionCount,
        desiredX: envelope.desiredX, caretIndex: envelope.caretIndex,
      });
    }
    if (action === "word_select") {
      return this.page.evaluate(wordSelectInPage, {
        token, x: envelope.coordinates.x, y: envelope.coordinates.y,
        cellWidthPx: envelope.cellWidthPx, strategy: envelope.strategy,
      });
    }
    if (action === "paragraph_select") {
      return this.page.evaluate(paragraphSelectInPage, {
        token, x: envelope.coordinates.x, y: envelope.coordinates.y,
        cellWidthPx: envelope.cellWidthPx, strategy: envelope.strategy,
      });
    }
    if (action === "find_set") {
      return this.page.evaluate(setFindInPage, { token, query: envelope.query, maxReported: MAX_FIND_MATCHES_REPORTED });
    }
    if (action === "find_next" || action === "find_previous") {
      return this.page.evaluate(stepFindInPage, {
        token,
        direction: action === "find_next" ? "next" : "previous",
        // Not owned by browser.js -- forwarded through `cached.findState` from
        // service.js's interactionState, since only find_set recomputes the match
        // set; stepping only moves which one is active.
        activeIndex: cached?.findState?.activeIndex ?? 0,
        matchCount: cached?.findState?.matchCount ?? 0,
      });
    }
    if (action === "find_clear") return this.page.evaluate(clearFindInPage, { token });
    return this.page.evaluate(hitTestInPage, {
      token, x: envelope.coordinates.x, y: envelope.coordinates.y,
      cellWidthPx: envelope.cellWidthPx, cellHeightPx: envelope.cellHeightPx,
      strategy: envelope.strategy, previewLimit: TEXT_PREVIEW_LIMIT,
    });
  }

  /// Shape the raw in-page result for `action` into the response Lua consumes.
  buildResult(action, raw, cached, envelope) {
    if (action === "hit_test" || action === "activate_at") {
      const hit = normalizeHit(raw, cached?.sourceMap);
      return { result: buildActionResult(action, hit), hit };
    }
    if (
      action === "selection_preview"
      || action === "selection_commit"
      || action === "word_select"
      || action === "paragraph_select"
    ) {
      return { result: buildSelectionResult(raw, cached?.sourceMap), hit: null };
    }
    if (action === "selection_text") return { result: buildSelectionTextResult(raw), hit: null };
    if (action === "caret_move") return { result: buildCaretMoveResult(raw), hit: null };
    if (action === "selection_clear") return { result: buildSelectionClearResult(), hit: null };
    if (action === "find_set") return { result: buildFindResult(raw, cached?.sourceMap, envelope.query), hit: null };
    if (action === "find_next" || action === "find_previous") {
      return { result: buildFindStepResult(raw, cached?.findState), hit: null };
    }
    return { result: buildFindClearResult(), hit: null };
  }

  async interact(envelope, cached, requestId) {
    const started = performance.now();
    const rehydrateStarted = performance.now();
    const { rehydrated, record, scrollY, documentHeight } = await this.ensureDocumentActive(envelope, cached);
    const rehydrateMs = round(performance.now() - rehydrateStarted);

    const raw = await this.evaluateAction(envelope.action, envelope, cached);
    if (raw?.error === "DOCUMENT_MISMATCH") {
      // Layer 3 fired: the page is not the document we believe it is. Refuse
      // rather than return a plausible answer from the wrong document, and drop
      // the active/layout pair together so the next request rebuilds from
      // scratch instead of trusting a record we have just disproved.
      this.active = this.layout = null;
      throw createInteractError(
        "DOCUMENT_MISMATCH",
        `the shared page does not hold document ${envelope.documentId}; refusing to resolve against it`,
        { documentId: envelope.documentId, expected: raw.expected, actual: raw.actual }
      );
    }

    // The source map never leaves this process: the page returned an opaque
    // region key, and the mapping that turns it into a line and byte column is
    // the cached one for exactly this document.
    const { result, hit } = this.buildResult(envelope.action, raw, cached, envelope);
    result.documentId = envelope.documentId;
    result.contentRevision = envelope.contentRevision;
    result.action = envelope.action;
    result.rehydrated = rehydrated;
    result.rehydrateMs = rehydrateMs;
    result.scrollY = scrollY;
    result.viewportHeightPx = record.height;
    result.documentHeightPx = documentHeight;
    // The caret is drawn through the same overlay path as a selection, from a
    // rectangle measured the same way, so it needs the same tint constant and
    // the same tint sheet.
    if (result.kind === "selection" || result.kind === "caret") {
      // The one constant the Lua drag overlay may paint with. Sourced from the
      // rendered document's own theme so Lua never hardcodes a color that the
      // settle frame's ::selection rule could drift away from. The caret is
      // drawn through the same path from its own, heavier constant.
      result.selectionTint = result.kind === "caret"
        ? (CARET_TINT[record.theme] ?? CARET_TINT.dark)
        : (SELECTION_TINT[record.theme] ?? SELECTION_TINT.dark);
      if (envelope.overlaySheet) {
        result.overlaySheetPng = buildOverlaySheetPng(
          envelope.overlaySheet.widthPx,
          envelope.overlaySheet.heightPx,
          result.selectionTint,
          { x: envelope.overlaySheet.marginX ?? 0, y: envelope.overlaySheet.marginY ?? 0 }
        ).toString("base64");
      }
    }

    // A fragment link scrolls within the controlled Chromium document rather
    // than opening anything: activate_at already classified it, so resolve the anchor and
    // report where the page ended up. A miss (no matching id) is reported
    // honestly rather than left unscrolled and unexplained.
    if (envelope.action === "activate_at" && hit && hit.link && hit.link.type === "fragment") {
      const fragment = await this.scrollToFragment(hit.link.href);
      result.fragmentResolved = fragment.found;
      if (fragment.found) result.scrollY = fragment.scrollY;
    }

    // find_set/find_next/find_previous scroll the active match into view
    // in-page (scrollIntoView), after `scrollY` above was already computed
    // from the pre-mutation applied scroll -- so it must be overwritten with
    // where the page actually ended up, the same way fragment scrolling is.
    if (typeof raw?.scrollY === "number") {
      result.scrollY = raw.scrollY;
      this.rememberScrollY(raw.scrollY);
    }

    if (envelope.capture) {
      const capture = await this.captureViewport({
        documentId: envelope.documentId, requestId, captureScale: envelope.captureScale,
      });
      Object.assign(result, capture);
    }
    result.totalMs = round(performance.now() - started);
    return result;
  }

  async health(options) {
    const executable = this.resolveExecutable(options);
    await this.ensure(options, 1);
    return {
      chromiumLaunch: "succeeded", executable, persistentPage: Boolean(this.page),
      discoveryReason: this.discoveryReason,
      activeDocument: this.active?.documentId ?? null,
      cachedDocumentFrames: this.documents.size,
    };
  }

  async close() {
    try { await this.context?.close(); } catch {}
    try { await this.browser?.close(); } catch {}
    this.context = this.browser = this.page = this.cdp = null;
    this.deviceScaleFactor = null;
    this.layout = this.viewport = this.active = null;
    this.documents.clear();
    // Captured PNGs (and animation frames) all live under tempDir; the
    // recursive removal is the whole cleanup. A per-file Set used to sit here
    // and grew by one path per rendered frame for the process lifetime,
    // because the Lua side deletes the files without telling this one.
    try { fs.rmSync(this.tempDir, { recursive: true }); } catch {}
  }
}
