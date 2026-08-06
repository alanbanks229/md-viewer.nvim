import path from "node:path";
import { fileURLToPath } from "node:url";
import { LineProtocol } from "./protocol.js";
import { BrowserRenderer } from "./browser.js";
import { renderMarkdown } from "./markdown.js";

const directory = path.dirname(fileURLToPath(import.meta.url));
const browser = new BrowserRenderer({ assetsDir: path.resolve(directory, "../assets") });
const latestByDocument = new Map();
const markdownCache = new Map();
let renderQueue = Promise.resolve();
let shuttingDown = false;

async function dispatch(request) {
  if (request.method === "shutdown") {
    shuttingDown = true;
    await browser.close();
    setImmediate(() => process.exit(0));
    return { shutdown: true };
  }
  if (request.method === "ping") return { pong: true };
  if (request.method === "health") return browser.health(request.params?.browser ?? {});
  if (request.method !== "render" && request.method !== "capture") {
    throw new Error(`unknown method: ${request.method}`);
  }

  const params = request.params ?? {};
  const captureOnly = request.method === "capture";
  if (typeof params.documentId !== "string"
    || (!captureOnly && typeof params.markdown !== "string")) {
    throw new Error("render requires documentId and markdown strings; capture requires documentId");
  }
  latestByDocument.set(params.documentId, request.id);
  const task = async () => {
    if (latestByDocument.get(params.documentId) !== request.id) {
      const error = new Error("render superseded by a newer request"); error.code = "STALE_RENDER"; throw error;
    }
    const previous = markdownCache.get(params.documentId);
    let markdownKey;
    let markdownReused;
    let html;
    if (captureOnly) {
      if (!previous) {
        const error = new Error("capture cache missing; perform a full render first");
        error.code = "CAPTURE_CACHE_MISS";
        throw error;
      }
      markdownKey = previous.key;
      markdownReused = true;
      html = previous.html;
    } else {
      markdownKey = JSON.stringify([
        params.contentRevision ?? params.markdown,
        params.rawHtml === true,
        params.localImages === true,
        Number(params.maxLocalImageBytes) || 10 * 1024 * 1024,
        params.baseDir,
        params.documentRoot,
      ]);
      markdownReused = previous?.key === markdownKey;
      html = markdownReused ? previous.html : renderMarkdown(params.markdown, {
        rawHtml: params.rawHtml === true,
        localImages: params.localImages === true,
        maxLocalImageBytes: Number(params.maxLocalImageBytes) || 10 * 1024 * 1024,
        baseDir: params.baseDir,
        documentRoot: params.documentRoot,
      });
      if (!markdownReused) {
        markdownCache.delete(params.documentId);
        markdownCache.set(params.documentId, { key: markdownKey, html });
        while (markdownCache.size > 64) markdownCache.delete(markdownCache.keys().next().value);
      }
    }
    const result = await browser.render({ ...params, contentFingerprint: markdownKey }, html, request.id);
    result.markdownReused = markdownReused;
    if (latestByDocument.get(params.documentId) !== request.id) {
      try { (await import("node:fs")).unlinkSync(result.pngPath); } catch {}
      const error = new Error("render superseded by a newer request"); error.code = "STALE_RENDER"; throw error;
    }
    return result;
  };
  const queued = renderQueue.then(task, task);
  renderQueue = queued.catch(() => {});
  return queued;
}

const protocol = new LineProtocol(process.stdin, process.stdout, dispatch);
protocol.start();

async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  await browser.close();
  process.exit(0);
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
process.on("uncaughtException", (error) => {
  process.stderr.write(`md-viewer renderer fatal: ${error.stack ?? error.message}\n`);
  shutdown();
});
