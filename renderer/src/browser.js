import fs from "node:fs";
import { createHash } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { collectBlockGeometry } from "./source-map.js";
import { csp, installNetworkPolicy } from "./security.js";
import { discoverChromium } from "./browser-discovery.js";
import {
  TEXT_PREVIEW_LIMIT,
  buildActionResult,
  createInteractError,
  hitTestInPage,
  normalizeHit,
} from "./interact.js";

const MAX_DOCUMENT_FRAMES = 64;

function round(value) {
  return Math.round(value * 100) / 100;
}

export class BrowserRenderer {
  constructor({ assetsDir }) {
    this.assetsDir = assetsDir;
    this.tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-"));
    this.browser = null;
    this.context = null;
    this.page = null;
    this.deviceScaleFactor = null;
    this.networkEnabled = null;
    this.files = new Set();
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
  }

  resolveExecutable(options = {}) {
    const { executable, reason } = discoverChromium(process.platform, process.env, fs.existsSync, options);
    this.discoveryReason = reason;
    return executable;
  }

  async ensure(options = {}, deviceScaleFactor = 2, network = false) {
    const scale = Math.max(1, Math.min(3, Number(deviceScaleFactor) || 2));
    if (!this.browser) {
      const executablePath = this.resolveExecutable(options);
      this.browser = await chromium.launch({
        executablePath, headless: true, timeout: options.launch_timeout_ms ?? 10000,
        args: ["--disable-extensions", "--disable-component-update", "--no-first-run", "--no-default-browser-check"],
      });
    }
    if (this.context && this.deviceScaleFactor === scale && this.networkEnabled === network) return;
    try { await this.context?.close(); } catch {}
    this.deviceScaleFactor = scale;
    this.networkEnabled = network;
    this.context = await this.browser.newContext({ deviceScaleFactor: this.deviceScaleFactor, javaScriptEnabled: false });
    await installNetworkPolicy(this.context, network);
    this.page = await this.context.newPage();
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
  async loadDocument({ documentId, contentRevision, layoutKey, html, theme, fontSizePx, scrollPastEnd, scrollPastEndOffsetPx, width, height }) {
    this.active = null;
    this.layout = null;
    this.documentTokenSerial += 1;
    const token = `d${this.documentTokenSerial}`;
    const documentHtml = this.buildDocumentHtml({ html, theme, fontSizePx, scrollPastEnd, scrollPastEndOffsetPx, token });
    await this.page.setContent(documentHtml, { waitUntil: "domcontentloaded" });
    const documentHeight = await this.page.evaluate(() => document.documentElement.scrollHeight);
    const blocks = await collectBlockGeometry(this.page);
    this.layout = { key: layoutKey, documentHeight, blocks };
    this.active = { documentId, contentRevision, layoutKey, token, width, height, scrollY: 0 };
    return { token, documentHeight, blocks };
  }

  async applyScroll(documentHeight, height, requested) {
    const scrollY = Math.max(0, Math.min(Number(requested) || 0, Math.max(0, documentHeight - height)));
    await this.page.evaluate((top) => window.scrollTo(0, top), scrollY);
    if (this.active) this.active.scrollY = scrollY;
    return scrollY;
  }

  /// Screenshot the current viewport. Shared by render() and by any interaction
  /// that mutates visible state, so the mutation and its frame are produced by
  /// the same queued operation and Lua never has to follow up with a capture.
  async captureViewport({ documentId, requestId, captureScale }) {
    const safeDocument = String(documentId ?? "document").replace(/[^a-zA-Z0-9_-]/g, "_");
    const pngPath = path.join(this.tempDir, `${safeDocument}-${requestId}.png`);
    const scale = captureScale === "css" ? "css" : "device";
    const started = performance.now();
    await this.page.screenshot({ path: pngPath, type: "png", fullPage: false, animations: "disabled", scale });
    const captureMs = performance.now() - started;
    const pngBytes = fs.statSync(pngPath).size;
    this.files.add(pngPath);
    return { pngPath, captureScale: scale, pngBytes, captureMs: round(captureMs) };
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
    await this.ensure(params.browser, viewport.deviceScaleFactor, params.network);
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
      });
    } else if (viewportChanged) {
      this.layout.documentHeight = await this.page.evaluate(() => document.documentElement.scrollHeight);
    }
    const layoutMs = performance.now() - layoutStarted;

    const documentHeight = this.layout.documentHeight;
    const scrollY = await this.applyScroll(documentHeight, height, params.scrollY);
    const capture = await this.captureViewport({
      documentId: params.documentId, requestId, captureScale: params.captureScale,
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
      network: this.networkEnabled,
      browserOptions: params.browser,
      scrollY,
      documentHeight,
      blocks: this.layout.blocks,
    });

    return {
      pngPath: capture.pngPath,
      documentHeightPx: documentHeight,
      viewportHeightPx: height,
      scrollY,
      blocks: this.layout.blocks,
      layoutReused,
      captureScale: capture.captureScale,
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
    await this.ensure(record.browserOptions, record.deviceScaleFactor, record.network);
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
      const scrollY = await this.applyScroll(record.documentHeight, record.height, envelope.scrollY);
      record.scrollY = scrollY;
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
    });
    // Recollected rather than reused: the layout key pins everything that
    // affects geometry, so these should equal the stored values, and a test
    // asserts exactly that. If they ever diverge it is a bug worth seeing.
    record.token = loaded.token;
    record.documentHeight = loaded.documentHeight;
    record.blocks = loaded.blocks;
    const scrollY = await this.applyScroll(loaded.documentHeight, record.height, envelope.scrollY);
    record.scrollY = scrollY;
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
    if (this.active) this.active.scrollY = scrollY;
    return { found: true, scrollY };
  }

  async interact(envelope, cached, requestId) {
    const started = performance.now();
    const rehydrateStarted = performance.now();
    const { rehydrated, record, scrollY, documentHeight } = await this.ensureDocumentActive(envelope, cached);
    const rehydrateMs = round(performance.now() - rehydrateStarted);

    const raw = await this.page.evaluate(hitTestInPage, {
      token: this.active.token,
      x: envelope.coordinates.x,
      y: envelope.coordinates.y,
      cellWidthPx: envelope.cellWidthPx,
      cellHeightPx: envelope.cellHeightPx,
      strategy: envelope.strategy,
      previewLimit: TEXT_PREVIEW_LIMIT,
    });
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
    const hit = normalizeHit(raw, cached?.sourceMap);
    const result = buildActionResult(envelope.action, hit);
    result.documentId = envelope.documentId;
    result.contentRevision = envelope.contentRevision;
    result.action = envelope.action;
    result.rehydrated = rehydrated;
    result.rehydrateMs = rehydrateMs;
    result.scrollY = scrollY;
    result.viewportHeightPx = record.height;
    result.documentHeightPx = documentHeight;

    // §4.4's "fragment -> scroll within the controlled Chromium document":
    // activate_at already classified the link, so resolve the anchor and
    // report where the page ended up. A miss (no matching id) is reported
    // honestly rather than left unscrolled and unexplained.
    if (envelope.action === "activate_at" && hit.link && hit.link.type === "fragment") {
      const fragment = await this.scrollToFragment(hit.link.href);
      result.fragmentResolved = fragment.found;
      if (fragment.found) result.scrollY = fragment.scrollY;
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
    await this.ensure(options, 1, false);
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
    this.context = this.browser = this.page = null;
    this.deviceScaleFactor = this.networkEnabled = null;
    this.layout = this.viewport = this.active = null;
    this.documents.clear();
    for (const file of this.files) { try { fs.unlinkSync(file); } catch {} }
    try { fs.rmSync(this.tempDir, { recursive: true }); } catch {}
  }
}
