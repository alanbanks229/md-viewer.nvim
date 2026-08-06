import fs from "node:fs";
import { createHash } from "node:crypto";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { collectBlockGeometry } from "./source-map.js";
import { csp, installNetworkPolicy } from "./security.js";

const knownChromium = [
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
];

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
  }

  resolveExecutable(options = {}) {
    if (options.executable_path) {
      if (!fs.existsSync(options.executable_path)) throw new Error(`configured Chromium does not exist: ${options.executable_path}`);
      return options.executable_path;
    }
    return knownChromium.find((candidate) => fs.existsSync(candidate)) ?? null;
  }

  async ensure(options = {}, deviceScaleFactor = 2, network = false) {
    const scale = Math.max(1, Math.min(3, Number(deviceScaleFactor) || 2));
    if (!this.browser) {
      const executablePath = this.resolveExecutable(options);
      if (!executablePath) throw new Error("no approved Chrome or Chromium executable found");
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
    this.layout = this.viewport = null;
  }

  styles(theme) {
    const common = fs.readFileSync(path.join(this.assetsDir, "preview.css"), "utf8");
    const selected = fs.readFileSync(path.join(this.assetsDir, `preview-${theme === "light" ? "light" : "dark"}.css`), "utf8");
    return `${common}\n${selected}`;
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
    const layoutKey = JSON.stringify([
      params.documentId, fingerprint, width, params.theme, scrollPastEnd, scrollPastEndOffsetPx,
    ]);
    const layoutReused = this.layout?.key === layoutKey;
    const layoutStarted = performance.now();
    if (!layoutReused) {
      const bottomPadding = scrollPastEnd ? `calc(100vh - ${scrollPastEndOffsetPx}px)` : "48px";
      const documentHtml = `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${csp}"><style>:root{--md-viewer-bottom-padding:${bottomPadding}}${this.styles(params.theme)}</style></head><body><article class="markdown-body">${html}</article></body></html>`;
      await this.page.setContent(documentHtml, { waitUntil: "domcontentloaded" });
      const dimensions = await this.page.evaluate(() => ({ height: document.documentElement.scrollHeight }));
      const blocks = await collectBlockGeometry(this.page);
      this.layout = { key: layoutKey, documentHeight: dimensions.height, blocks };
    } else if (viewportChanged) {
      this.layout.documentHeight = await this.page.evaluate(() => document.documentElement.scrollHeight);
    }
    const layoutMs = performance.now() - layoutStarted;

    const documentHeight = this.layout.documentHeight;
    const scrollY = Math.max(0, Math.min(Number(params.scrollY) || 0, Math.max(0, documentHeight - height)));
    await this.page.evaluate((top) => window.scrollTo(0, top), scrollY);
    const safeDocument = String(params.documentId ?? "document").replace(/[^a-zA-Z0-9_-]/g, "_");
    const pngPath = path.join(this.tempDir, `${safeDocument}-${requestId}.png`);
    const captureScale = params.captureScale === "css" ? "css" : "device";
    const captureStarted = performance.now();
    await this.page.screenshot({
      path: pngPath,
      type: "png",
      fullPage: false,
      animations: "disabled",
      scale: captureScale,
    });
    const captureMs = performance.now() - captureStarted;
    const pngBytes = fs.statSync(pngPath).size;
    this.files.add(pngPath);
    return {
      pngPath,
      documentHeightPx: documentHeight,
      viewportHeightPx: height,
      scrollY,
      blocks: this.layout.blocks,
      layoutReused,
      captureScale,
      pngBytes,
      layoutMs: Math.round(layoutMs * 100) / 100,
      captureMs: Math.round(captureMs * 100) / 100,
      totalMs: Math.round((performance.now() - started) * 100) / 100,
    };
  }

  async health(options) {
    const executable = this.resolveExecutable(options);
    await this.ensure(options, 1, false);
    return { chromiumLaunch: "succeeded", executable, persistentPage: Boolean(this.page) };
  }

  async close() {
    try { await this.context?.close(); } catch {}
    try { await this.browser?.close(); } catch {}
    this.context = this.browser = this.page = null;
    this.deviceScaleFactor = this.networkEnabled = null;
    this.layout = this.viewport = null;
    for (const file of this.files) { try { fs.unlinkSync(file); } catch {} }
    try { fs.rmSync(this.tempDir, { recursive: true }); } catch {}
  }
}
