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

function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

function startRenderer(t, executable) {
  const child = spawn(process.execPath, [main], { stdio: ["pipe", "pipe", "pipe"] });
  t.after(() => { if (child.exitCode === null) child.kill("SIGTERM"); });
  const pending = new Map();
  const stderr = [];
  child.stderr.on("data", (chunk) => stderr.push(String(chunk)));
  readline.createInterface({ input: child.stdout }).on("line", (line) => {
    const message = JSON.parse(line);
    const settle = pending.get(message.id);
    if (settle) { pending.delete(message.id); settle(message); }
  });
  let nextId = 0;
  const api = {
    stderr,
    send(method, params) {
      nextId += 1;
      const id = nextId;
      const promise = new Promise((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error(`renderer timed out on ${method}; stderr: ${stderr.join("")}`)),
          30000
        );
        pending.set(id, (message) => { clearTimeout(timer); resolve(message); });
      });
      child.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
      return promise;
    },
    renderParams(documentId, markdown, contentRevision, overrides = {}) {
      return {
        documentId, markdown, contentRevision,
        baseDir: here, documentRoot: here,
        viewport: { widthPx: 800, heightPx: 900, deviceScaleFactor: 1 },
        scrollY: 0, theme: "dark", rawHtml: false, localImages: false,
        maxLocalImageBytes: 1024, network: false,
        browser: { executable_path: executable, launch_timeout_ms: 10000 },
        ...overrides,
      };
    },
    interactParams(documentId, contentRevision, overrides = {}) {
      return {
        documentId, contentRevision, action: "hit_test",
        viewportWidthPx: 800, viewportHeightPx: 900, scrollY: 0, ...overrides,
      };
    },
  };
  return api;
}

async function render(renderer, documentId, markdown, contentRevision, overrides) {
  const response = await renderer.send("render", renderer.renderParams(documentId, markdown, contentRevision, overrides));
  assert.equal(response.ok, true, response.error);
  if (response.result.pngPath) fs.unlinkSync(response.result.pngPath);
  return response.result;
}

async function find(renderer, documentId, contentRevision, action, extra = {}) {
  const response = await renderer.send("interact", renderer.interactParams(documentId, contentRevision, { action, ...extra }));
  if (response.ok && response.result.pngPath) fs.unlinkSync(response.result.pngPath);
  return response;
}

const DOC = [
  "# Find Doc",
  "",
  "The quick brown fox jumps over the lazy dog. The fox runs fast.",
  "",
  "A second paragraph mentions fox one more time, quietly.",
  "",
  "A literal query with metacharacters: a.b and (a|b) and [0-9]+ here.",
  "",
  ...Array.from({ length: 40 }, (_, i) => `Filler line number ${i} for scroll-into-view testing.\n`),
  "The fox appears again, far down the document.",
  "",
].join("\n");

test("find: creation, counting, wrapping, clearing, scroll-into-view", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = startRenderer(t, executable);
  await render(renderer, "find-doc", DOC, "1:0");

  await t.test("find_set creates matches and reports a true count", async () => {
    const response = await find(renderer, "find-doc", "1:0", "find_set", { query: "fox", capture: true });
    assert.equal(response.ok, true, response.error);
    assert.equal(response.result.kind, "find");
    assert.equal(response.result.query, "fox");
    // "fox" appears: paragraph 1 (x2), paragraph 2 (x1), the far-down line (x1).
    assert.equal(response.result.matchCount, 4);
    assert.equal(response.result.activeIndex, 0);
    assert.ok(response.result.activeSourcePosition, "the active match should carry a source position");
    assert.equal(response.result.captureScale, "device", "find_set must default to the sharp capture scale");
  });

  await t.test("find_next and find_previous wrap in both directions", async () => {
    await find(renderer, "find-doc", "1:0", "find_set", { query: "fox" });
    const indices = [];
    let last = await find(renderer, "find-doc", "1:0", "find_next");
    indices.push(last.result.activeIndex);
    for (let i = 0; i < 3; i += 1) {
      last = await find(renderer, "find-doc", "1:0", "find_next");
      indices.push(last.result.activeIndex);
    }
    assert.deepEqual(indices, [1, 2, 3, 0], "find_next should wrap from the last match to the first");

    const back = await find(renderer, "find-doc", "1:0", "find_previous");
    assert.equal(back.result.activeIndex, 3, "find_previous from the first match should wrap to the last");
  });

  await t.test("find_clear removes the match set and resets state", async () => {
    await find(renderer, "find-doc", "1:0", "find_set", { query: "fox" });
    const cleared = await find(renderer, "find-doc", "1:0", "find_clear");
    assert.equal(cleared.ok, true, cleared.error);
    assert.equal(cleared.result.kind, "find");
    assert.equal(cleared.result.cleared, true);
    // A clear drops state.find server-side, so the next find_next sees a
    // matchCount of 0 (via cached.findState) and no-ops cleanly rather than
    // stepping into a match set that no longer exists.
    const stepAfterClear = await find(renderer, "find-doc", "1:0", "find_next");
    assert.equal(stepAfterClear.ok, true, stepAfterClear.error);
    assert.equal(stepAfterClear.result.activeIndex, null);
  });

  await t.test("a match far down the document scrolls into view", async () => {
    const response = await find(renderer, "find-doc", "1:0", "find_set", { query: "fox", capture: true });
    assert.equal(response.ok, true, response.error);
    let cursor = response.result.activeIndex;
    let last = response;
    for (let i = 0; i < response.result.matchCount - 1; i += 1) {
      last = await find(renderer, "find-doc", "1:0", "find_next", { capture: true });
      cursor = last.result.activeIndex;
    }
    void cursor;
    // The last match (the far-down "The fox appears again" line) should have
    // required a real scroll to bring into view.
    assert.ok(last.result.scrollY > 0, "scrolling to the last match should have moved the viewport");
  });

  await t.test(
    "omitting scrollY on find_clear preserves the shared page's scroll position (regression)",
    async () => {
      // Scroll to the far-down match first, via a real find_next.
      const set = await find(renderer, "find-doc", "1:0", "find_set", { query: "fox", capture: true });
      let last = set;
      for (let i = 0; i < set.result.matchCount - 1; i += 1) {
        last = await find(renderer, "find-doc", "1:0", "find_next", { capture: true });
      }
      assert.ok(last.result.scrollY > 0, "the setup scroll should have moved the viewport");
      const scrolledTo = last.result.scrollY;

      // find_clear with no scrollY field at all must not reset to the top --
      // the same bug that made clicking to deselect/clear near the bottom of
      // a document jump the preview back to the very top.
      const cleared = await find(renderer, "find-doc", "1:0", "find_clear", { capture: true, scrollY: undefined });
      assert.equal(cleared.ok, true, cleared.error);
      assert.equal(cleared.result.scrollY, scrolledTo, "an omitted scrollY must preserve position, not reset to the top");
      assert.equal(cleared.result.captureScale, "device", "find_clear must default to the sharp capture scale");
    }
  );

  await renderer.send("shutdown", {});
});

test("find: a query containing HTML is matched literally and injects nothing into the DOM", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = startRenderer(t, executable);
  const markdown = "# HTML Query Doc\n\nThis paragraph has no angle brackets in it at all.\n";
  await render(renderer, "html-query-doc", markdown, "1:0");

  const response = await find(renderer, "html-query-doc", "1:0", "find_set", {
    query: "<img src=x onerror=alert(1)>",
  });
  assert.equal(response.ok, true, response.error);
  assert.equal(response.result.matchCount, 0, "the literal HTML string does not appear in the rendered text");

  // Prove it directly: hit-test across the whole paragraph and confirm no
  // img/script element was ever created by the "query".
  const hit = await renderer.send("interact", renderer.interactParams("html-query-doc", "1:0", {
    action: "hit_test", coordinates: { x: 40, y: 60 },
  }));
  assert.equal(hit.ok, true, hit.error);
  assert.equal(hit.result.hit.element.isImage, false, "no image element should exist in this document");

  await renderer.send("shutdown", {});
});

test("find: a query containing regex metacharacters is matched literally, not as a pattern", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = startRenderer(t, executable);
  // Contains the literal substring "a.b" once, and "axb" (which a real regex
  // "a.b" would also match) once -- proving "." is not being treated as a
  // wildcard.
  const markdown = "# Regex Query Doc\n\nHere is a.b and also axb in the same line.\n\nAlso (a|b) appears once literally.\n";
  await render(renderer, "regex-query-doc", markdown, "1:0");

  const dot = await find(renderer, "regex-query-doc", "1:0", "find_set", { query: "a.b" });
  assert.equal(dot.ok, true, dot.error);
  assert.equal(dot.result.matchCount, 1, "a literal '.' must match only the literal period, not any character");

  const group = await find(renderer, "regex-query-doc", "1:0", "find_set", { query: "(a|b)" });
  assert.equal(group.ok, true, group.error);
  assert.equal(group.result.matchCount, 1, "a literal '(a|b)' must match only that exact substring, not 'a' or 'b' alone");

  const charClass = await find(renderer, "regex-query-doc", "1:0", "find_set", { query: "[0-9]+" });
  assert.equal(charClass.ok, true, charClass.error);
  assert.equal(charClass.result.matchCount, 0, "a literal character class must not match digits it never contains");

  await renderer.send("shutdown", {});
});

test("find: per-document search state isolation", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = startRenderer(t, executable);
  await render(renderer, "find-a", "# Doc A\n\nApple apple apple.\n", "1:0");
  await render(renderer, "find-b", "# Doc B\n\nBanana banana.\n", "1:0");

  const a = await find(renderer, "find-a", "1:0", "find_set", { query: "apple" });
  assert.equal(a.result.matchCount, 3);

  // Document B is now the one loaded in the shared page; its own find_set
  // must not see A's query results or vice versa when each is queried again.
  const b = await find(renderer, "find-b", "1:0", "find_set", { query: "banana" });
  assert.equal(b.result.matchCount, 2);

  const aAgain = await find(renderer, "find-a", "1:0", "find_set", { query: "apple" });
  assert.equal(aAgain.result.matchCount, 3, "document A's own search must still resolve correctly after rehydration");
  assert.doesNotMatch(JSON.stringify(aAgain.result), /[Bb]anana/);

  await renderer.send("shutdown", {});
});
