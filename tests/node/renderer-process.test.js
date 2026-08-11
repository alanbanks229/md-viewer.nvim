import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const main = path.resolve(here, "../../renderer/src/main.js");

// This test spawns the real renderer subprocess and asks it to launch a real
// browser, so it uses whatever discovery finds on the current platform/CI
// runner rather than a hardcoded macOS path.
function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

test("supersedes stale requests and shuts the renderer down", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const child = spawn(process.execPath, [main], { stdio: ["pipe", "pipe", "pipe"] });
  t.after(() => { if (child.exitCode === null) child.kill("SIGTERM"); });
  const reader = readline.createInterface({ input: child.stdout });
  const responses = [];
  reader.on("line", (line) => responses.push(JSON.parse(line)));
  const base = {
    method: "render",
    params: {
      documentId: "ordering", markdown: "# Latest", baseDir: here, documentRoot: here,
      contentRevision: 1,
      viewport: { widthPx: 400, heightPx: 300, deviceScaleFactor: 1 }, scrollY: 0,
      theme: "dark", rawHtml: false, localImages: false, maxLocalImageBytes: 1024,
      browser: { executable_path: executable, launch_timeout_ms: 10000 },
    },
  };
  child.stdin.write(`${JSON.stringify({ ...base, id: 1 })}\n`);
  const latestParams = { ...base.params, contentRevision: 2, markdown: "# Newest" };
  child.stdin.write(`${JSON.stringify({ ...base, id: 2, params: latestParams })}\n`);
  const deadline = Date.now() + 15000;
  while (responses.length < 2 && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(responses.length, 2);
  const first = responses.find((response) => response.id === 1);
  const second = responses.find((response) => response.id === 2);
  assert.equal(first.ok, false); assert.equal(first.code, "STALE_RENDER");
  assert.equal(second.ok, true); assert.ok(fs.existsSync(second.result.pngPath));
  fs.unlinkSync(second.result.pngPath);
  const { markdown: _omitted, ...captureParams } = latestParams;
  child.stdin.write(`${JSON.stringify({ id: 3, method: "capture", params: { ...captureParams, scrollY: 20, captureScale: "css" } })}\n`);
  const scrollDeadline = Date.now() + 15000;
  while (responses.length < 3 && Date.now() < scrollDeadline) await new Promise((resolve) => setTimeout(resolve, 20));
  const third = responses.find((response) => response.id === 3);
  assert.equal(third.ok, true);
  assert.equal(third.result.markdownReused, true);
  assert.equal(third.result.layoutReused, true);
  assert.equal(third.result.captureScale, "css");
  fs.unlinkSync(third.result.pngPath);

  // A capture for a document the renderer has never rendered must fail with the
  // exact message lua/md-viewer/renderer.lua matches on to retry as a full
  // render. Changing this string silently breaks that retry.
  child.stdin.write(`${JSON.stringify({ id: 4, method: "capture", params: { ...captureParams, documentId: "never-rendered" } })}\n`);
  const missDeadline = Date.now() + 15000;
  while (responses.length < 4 && Date.now() < missDeadline) await new Promise((resolve) => setTimeout(resolve, 20));
  const fourth = responses.find((response) => response.id === 4);
  assert.equal(fourth.ok, false);
  assert.equal(fourth.code, "CAPTURE_CACHE_MISS");
  assert.match(fourth.error, /capture cache missing/);

  child.stdin.write(`${JSON.stringify({ id: 0, method: "shutdown", params: {} })}\n`);
  const exitCode = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("renderer did not shut down")), 5000);
    child.once("exit", (code) => { clearTimeout(timer); resolve(code); });
  });
  assert.equal(exitCode, 0);
});
