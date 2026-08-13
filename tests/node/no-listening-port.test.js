import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { execFileSync, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";

// The standing guarantee: no HTTP server, no WebSocket server, no listening
// TCP port, ever. This asserts it against the real renderer subprocess and
// its real Chromium child, rather than trusting that nothing in the code
// happens to call `net.createServer`/`http.createServer` -- a dependency
// (Playwright's own CDP transport, in particular) could introduce one without
// any md-viewer code changing at all.

const here = path.dirname(fileURLToPath(import.meta.url));

function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

function listeningTcpPorts() {
  // -P -n: numeric ports/hosts, no DNS/service-name lookups, so this is fast
  // and cannot itself make a network request. Available on both the macOS and
  // Ubuntu CI runners this project targets.
  try {
    const out = execFileSync("lsof", ["-iTCP", "-sTCP:LISTEN", "-P", "-n"], { encoding: "utf8" });
    return new Set(out.split("\n").filter(Boolean));
  } catch (error) {
    // lsof exits non-zero when it finds nothing to list, which is the normal
    // "no listeners at all" case -- not a real failure.
    if (error.status === 1 && !error.stdout) return new Set();
    throw error;
  }
}

test("the renderer subprocess and its Chromium child open no listening TCP port", { skip: (() => {
  try { execFileSync("lsof", ["-v"]); return false; } catch { return "lsof is not available on this runner"; }
})() }, async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const before = listeningTcpPorts();

  const main = path.resolve(here, "../../renderer/src/main.js");
  const child = spawn(process.execPath, [main], { stdio: ["pipe", "pipe", "pipe"] });
  t.after(() => { if (child.exitCode === null) child.kill("SIGTERM"); });
  const reader = readline.createInterface({ input: child.stdout });
  const responses = [];
  reader.on("line", (line) => responses.push(JSON.parse(line)));

  // Force a full Chromium launch (render), then exercise the interact surface
  // too, so every subsystem that could plausibly open a socket has had the
  // chance to.
  const renderParams = {
    documentId: "port-scan", markdown: "# Title\n\nbody", baseDir: here, documentRoot: here,
    contentRevision: 1, viewport: { widthPx: 400, heightPx: 300, deviceScaleFactor: 1 }, scrollY: 0,
    theme: "dark", rawHtml: false, localImages: false, maxLocalImageBytes: 1024,
    browser: { executable_path: executable, launch_timeout_ms: 10000 },
  };
  child.stdin.write(`${JSON.stringify({ id: 1, method: "render", params: renderParams })}\n`);
  const deadline = Date.now() + 15000;
  while (responses.length < 1 && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(responses.length, 1, "the renderer must actually answer for this scan to be meaningful");
  assert.equal(responses[0].ok, true, `render failed: ${responses[0].error}`);

  child.stdin.write(`${JSON.stringify({ id: 2, method: "health", params: { browser: renderParams.browser } })}\n`);
  while (responses.length < 2 && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(responses[1]?.ok, true, "health must also answer for this scan to be meaningful");

  const after = listeningTcpPorts();
  const opened = [...after].filter((line) => !before.has(line));
  assert.deepEqual(opened, [], "no new listening TCP port appeared while the renderer and Chromium were running");

  child.stdin.write(`${JSON.stringify({ id: 3, method: "shutdown", params: {} })}\n`);
  await new Promise((resolve) => child.once("exit", resolve));
});
