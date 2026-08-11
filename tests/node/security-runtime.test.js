import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { BrowserRenderer } from "../../renderer/src/browser.js";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";

// Part 7 §7.2: actually attempt the attacks against a real Chromium instance,
// rather than re-asserting the sanitizer/classifyLink unit tests that already
// cover the input side. These tests exercise what happens if a script somehow
// reached the page anyway, and whether the hidden page can be driven away from
// the document md-viewer generated for it.

const here = path.dirname(fileURLToPath(import.meta.url));
const assetsDir = path.resolve(here, "../../renderer/assets");

function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

test("javaScriptEnabled: false stops a <script> from running even if one reached the page", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
  const params = {
    documentId: "js-disabled", contentRevision: 1,
    viewport: { widthPx: 640, heightPx: 480, deviceScaleFactor: 1 },
    browser: { executable_path: executable }, theme: "dark", scrollY: 0,
    captureScale: "css", scrollPastEnd: true, scrollPastEndOffsetPx: 22,
  };
  // renderMarkdown/sanitizeHtml would never let this through in the real
  // pipeline (see markdown.test.js) -- this bypasses that layer on purpose and
  // hands browser.js a `<script>` directly, exactly as if the sanitizer had a
  // bug, to prove the second, independent layer (javaScriptEnabled: false)
  // actually stops execution rather than merely being configured.
  const html = '<p id="marker">untouched</p>'
    + '<script>window.__pwned = true; document.getElementById("marker").textContent = "pwned";</script>'
    + '<img src=x onerror="window.__pwned = true">';
  await renderer.render(params, html, 1);
  const pwned = await renderer.page.evaluate(() => window.__pwned);
  assert.equal(pwned, undefined, "no script or event-handler ran on the page");
  const markerText = await renderer.page.evaluate(() => document.getElementById("marker")?.textContent);
  assert.equal(markerText, "untouched", "the DOM was never mutated by the injected script");
  const scriptStillInDom = await renderer.page.evaluate(() => document.querySelectorAll("script").length);
  assert.equal(scriptStillInDom, 1, "the <script> element sits inertly in the DOM -- it parses, but Chromium never executes it");
});

test("the hidden page cannot be navigated away from the generated document", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
  const params = {
    documentId: "no-navigate", contentRevision: 1,
    viewport: { widthPx: 640, heightPx: 480, deviceScaleFactor: 1 },
    browser: { executable_path: executable }, theme: "dark", scrollY: 0,
    captureScale: "css", scrollPastEnd: true, scrollPastEndOffsetPx: 22,
  };
  const html = '<p id="marker">the generated document</p>';
  await renderer.render(params, html, 1);

  // No code path in browser.js ever calls page.goto/page.reload -- the only
  // things that can move the shared page are setContent() (loadDocument),
  // page.evaluate() (trusted, in-page code), and window.scrollTo/
  // scrollIntoView run through evaluate. This attempts the navigation md-viewer
  // itself never performs, to prove that even if something forced one (a
  // supply-chain compromise of a dependency with access to `page`, say), it
  // could not make the hidden page display a real external site: the network
  // policy (renderer/src/security.js's installNetworkPolicy) blocks every
  // non-data/about request regardless of what triggered it, main navigations
  // included.
  await assert.rejects(
    renderer.page.goto("https://example.invalid/somewhere-else", { timeout: 5000 }),
    "a navigation to a real URL is refused by the network policy rather than succeeding"
  );
  assert.notEqual(
    renderer.page.url(),
    "https://example.invalid/somewhere-else",
    "the page never actually lands on the external site -- Chromium settles on its own error page instead"
  );
});

test("browser.js itself never calls a navigating Playwright API", () => {
  // Structural, not behavioural: the previous test proves the network policy
  // would refuse a navigation if one were attempted; this proves md-viewer's
  // own code never attempts one in the first place. `page.setContent()` (used
  // exclusively for loadDocument) does not count as a navigation for this
  // purpose -- it replaces the document in place and is what every render
  // goes through; `goto`/`reload`/`goBack`/`goForward` are the APIs that
  // would actually move the page to a different URL.
  const source = fs.readFileSync(path.resolve(here, "../../renderer/src/browser.js"), "utf8");
  for (const api of [".goto(", ".reload(", ".goBack(", ".goForward("]) {
    assert.ok(!source.includes(api), `browser.js must never call page${api}...)`);
  }
});
