import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { execFileSync, spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";

// The standing guarantee: this process never outlives the Neovim that spawned
// it, by any route. It is asserted against a real subprocess with a real
// Chromium child because the failure it guards is not reachable from an idle
// renderer -- an idle one exits on stdin EOF all by itself, with no help from
// any of the handlers below.
//
// The bug this replaces: `shutdown` awaited `service.close()` and called
// `process.exit(0)` only afterwards. Once Chromium's pipe was already dead
// `browser.close()` rejected, so the exit never ran and the rejection came back
// as an uncaught exception; the handler re-entered `shutdown`, found
// `service.closing` already true, and returned without exiting. The result was
// a renderer with no parent spinning at 100% of a core, formatting stack traces
// forever. Nine of them accumulated over a week before anyone looked.

const here = path.dirname(fileURLToPath(import.meta.url));
const main = path.resolve(here, "../../renderer/src/main.js");

function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

function renderParams(executable, id) {
  return {
    documentId: `orphan-${id}`,
    // Long enough that the render is still in flight when the pipes go away:
    // an in-flight reply is what turns a dead stdout into an EPIPE.
    markdown: `# Title\n\n${"body paragraph\n\n".repeat(200)}`,
    baseDir: here, documentRoot: here, contentRevision: 1,
    viewport: { widthPx: 800, heightPx: 600, deviceScaleFactor: 2 }, scrollY: 0,
    theme: "dark", rawHtml: false, localImages: false, maxLocalImageBytes: 1024,
    browser: { executable_path: executable, launch_timeout_ms: 20000 },
  };
}

function alive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

test("a renderer whose Neovim dies without warning exits instead of spinning", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }

  const child = spawn(process.execPath, [main], { stdio: ["pipe", "pipe", "pipe"] });
  const pid = child.pid;
  t.after(() => { if (alive(pid)) try { process.kill(pid, "SIGKILL"); } catch {} });
  child.stderr.resume();

  let replies = 0;
  child.stdout.on("data", (chunk) => { replies += (chunk.toString().match(/\n/g) ?? []).length; });

  // A real Chromium launch, confirmed by a real answer. Without this the test
  // proves nothing: the wedge needs a browser to fail to close.
  child.stdin.write(`${JSON.stringify({ id: 1, method: "render", params: renderParams(executable, 1) })}\n`);
  const launched = Date.now() + 40000;
  while (replies < 1 && Date.now() < launched) await new Promise((r) => setTimeout(r, 50));
  assert.equal(replies >= 1, true, "the renderer must answer once for this test to be meaningful");

  // Queue work, then take both pipes away mid-flight. This is what a SIGKILL'd
  // or crashed Neovim looks like from here: no shutdown request, no warning,
  // replies landing on a broken pipe.
  for (let id = 2; id <= 6; id++) {
    child.stdin.write(`${JSON.stringify({ id, method: "render", params: renderParams(executable, id) })}\n`);
  }
  await new Promise((r) => setTimeout(r, 120));
  child.stdout.destroy();
  child.stderr.destroy();
  child.stdin.destroy();

  const exited = await new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), 20000);
    child.on("exit", () => { clearTimeout(timer); resolve(true); });
  });

  let cpu = "unknown";
  if (!exited) {
    try { cpu = execFileSync("ps", ["-o", "%cpu=", "-p", String(pid)]).toString().trim(); } catch {}
  }
  assert.equal(exited, true, `the renderer outlived its parent, burning ${cpu}% CPU`);
});

// Cheap smoke guards, and honestly weaker than the test above: an idle
// renderer exits on any of these even without a handler, so only SIGHUP's exit
// *code* distinguishes handled from merely fatal. They are here to catch a
// handler being deleted outright; the test above is the one that catches the
// wedge.
for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  test(`${signal} stops the renderer`, async (t) => {
    const executable = findRealChromium();
    if (!executable) {
      t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
      return;
    }

    const child = spawn(process.execPath, [main], { stdio: ["pipe", "pipe", "pipe"] });
    const pid = child.pid;
    t.after(() => { if (alive(pid)) try { process.kill(pid, "SIGKILL"); } catch {} });
    child.stderr.resume();
    child.stdout.resume();

    await new Promise((r) => setTimeout(r, 800));
    child.kill(signal);

    const exited = await new Promise((resolve) => {
      const timer = setTimeout(() => resolve(false), 15000);
      child.on("exit", () => { clearTimeout(timer); resolve(true); });
    });
    assert.equal(exited, true, `${signal} left the renderer running`);
  });
}
