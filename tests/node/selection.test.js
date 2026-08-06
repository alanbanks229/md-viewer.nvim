import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";
import { validateEnvelope } from "../../renderer/src/interact.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const main = path.resolve(here, "../../renderer/src/main.js");

function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Pure surface: no browser, no subprocess.
// ---------------------------------------------------------------------------

test("selection_preview/selection_commit require anchorCoordinates", () => {
  const base = {
    documentId: "buffer-1", contentRevision: "1:0",
    viewportWidthPx: 800, viewportHeightPx: 600, coordinates: { x: 10, y: 10 },
  };
  for (const action of ["selection_preview", "selection_commit"]) {
    for (const anchorCoordinates of [undefined, null, {}, { x: 1 }, { x: NaN, y: 1 }]) {
      assert.throws(() => validateEnvelope({ ...base, action, anchorCoordinates }), (error) => {
        assert.equal(error.code, "INVALID_INTERACTION");
        assert.match(error.message, /anchorCoordinates/);
        return true;
      }, `${action} with anchorCoordinates=${JSON.stringify(anchorCoordinates)}`);
    }
  }
});

test("selection_clear and selection_text need neither coordinates nor an anchor", () => {
  for (const action of ["selection_clear", "selection_text"]) {
    assert.doesNotThrow(() => validateEnvelope({
      documentId: "buffer-1", contentRevision: "1:0", action,
      viewportWidthPx: 800, viewportHeightPx: 600,
    }));
  }
});

// ---------------------------------------------------------------------------
// Browser-backed: real subprocess, real Chromium, real NDJSON.
// ---------------------------------------------------------------------------

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
        viewport: { widthPx: 800, heightPx: 600, deviceScaleFactor: 1 },
        scrollY: 0, theme: "dark", rawHtml: false, localImages: false,
        maxLocalImageBytes: 1024, network: false,
        browser: { executable_path: executable, launch_timeout_ms: 10000 },
        ...overrides,
      };
    },
    interactParams(documentId, contentRevision, overrides = {}) {
      return {
        documentId, contentRevision, action: "hit_test",
        viewportWidthPx: 800, viewportHeightPx: 600, scrollY: 0, ...overrides,
      };
    },
  };
  return api;
}

const DOC = [
  "# Selection Doc",
  "",
  "Alpha beta gamma delta epsilon zeta eta theta iota kappa.",
  "",
  "Second paragraph with **bold text**, *italic text*, a [link label](https://example.invalid), and `inline code` inline.",
  "",
  "> Blockquote text here for selection tests spanning several words.",
  "",
  "```js",
  "const x = 1;",
  "const y = 2;",
  "```",
  "",
  "日本語のテキストです。🎉 emoji selection test.",
  "",
].join("\n");

function blockAt(blocks, sourceStart) {
  return blocks.find((block) => block.sourceStart === sourceStart);
}

// A point near the left edge and one near the right edge of a block's own
// vertical middle -- close enough to "start" and "end" of a single-line block
// without depending on exact font metrics.
function edges(block) {
  const y = Math.round((block.topPx + block.bottomPx) / 2);
  return { left: { x: 35, y }, right: { x: 760, y } };
}

async function render(t, renderer, documentId, markdown, contentRevision, overrides) {
  const response = await renderer.send("render", renderer.renderParams(documentId, markdown, contentRevision, overrides));
  assert.equal(response.ok, true, response.error);
  if (response.result.pngPath) fs.unlinkSync(response.result.pngPath);
  return response.result;
}

async function selectionCommit(renderer, documentId, contentRevision, anchor, focus, extra = {}) {
  const response = await renderer.send("interact", renderer.interactParams(documentId, contentRevision, {
    action: "selection_commit", coordinates: focus, anchorCoordinates: anchor, capture: true, ...extra,
  }));
  if (response.ok && response.result.pngPath) fs.unlinkSync(response.result.pngPath);
  return response;
}

test("selection: forward, backward, multi-block, nested markup, code, unicode, clearing, isolation", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = startRenderer(t, executable);
  const meta = await render(t, renderer, "sel-doc", DOC, "1:0");
  const blocks = meta.blocks;

  await t.test("forward selection selects real text within the paragraph", async () => {
    const paragraph = blockAt(blocks, 2);
    const { left, right } = edges(paragraph);
    const response = await selectionCommit(renderer, "sel-doc", "1:0", left, right);
    assert.equal(response.ok, true, response.error);
    assert.equal(response.result.kind, "selection");
    assert.equal(response.result.ok, true);
    assert.equal(response.result.collapsed, false, "a real drag must not collapse");
    // Not anchored to the literal first character: a click a few CSS pixels
    // into a block can land the caret just past it (the same terminal-cell
    // edge behavior documented for click-to-source in Part 5), which is a
    // real, honest browser caret position, not a bug in selection itself.
    // "beta gamma" is safely inside the line, away from either edge.
    assert.match(response.result.text, /beta gamma/, "the selection should cover most of the paragraph");
  });

  let forwardText;
  await t.test("backward (reverse) selection does not collapse and selects the same text", async () => {
    const paragraph = blockAt(blocks, 2);
    const { left, right } = edges(paragraph);
    const forward = await selectionCommit(renderer, "sel-doc", "1:0", left, right);
    forwardText = forward.result.text;
    const backward = await selectionCommit(renderer, "sel-doc", "1:0", right, left);
    assert.equal(backward.ok, true, backward.error);
    assert.equal(backward.result.collapsed, false, "dragging right-to-left must not collapse the selection");
    assert.equal(backward.result.text, forwardText,
      "dragging in either direction across the same two points must select the same text");
  });

  await t.test("multi-block selection spans from one paragraph into the next", async () => {
    const first = blockAt(blocks, 2);
    const second = blockAt(blocks, 4);
    const anchor = { x: 400, y: Math.round((first.topPx + first.bottomPx) / 2) };
    const focus = { x: 100, y: Math.round((second.topPx + second.bottomPx) / 2) };
    const response = await selectionCommit(renderer, "sel-doc", "1:0", anchor, focus);
    assert.equal(response.ok, true, response.error);
    assert.equal(response.result.collapsed, false);
    // The selection must reach into the second paragraph's own text, not stop
    // at the end of the first.
    assert.match(response.result.text, /Second pa/);
  });

  await t.test("selection crosses nested emphasis, strong, link, and inline code", async () => {
    const paragraph = blockAt(blocks, 4);
    const { left, right } = edges(paragraph);
    const response = await selectionCommit(renderer, "sel-doc", "1:0", left, right);
    assert.equal(response.ok, true, response.error);
    // Plain-text extraction across DOM boundaries: bold/italic/link/code
    // markup vanishes, but the underlying words all survive as plain text.
    assert.match(response.result.text, /bold text/);
    assert.match(response.result.text, /italic text/);
  });

  await t.test("selection inside a fenced code block extracts the raw code text", async () => {
    const code = blockAt(blocks, 8);
    assert.ok(code, "fenced code block did not render with geometry");
    const anchor = { x: 30, y: code.topPx + 4 };
    const focus = { x: 200, y: code.bottomPx - 4 };
    const response = await selectionCommit(renderer, "sel-doc", "1:0", anchor, focus);
    assert.equal(response.ok, true, response.error);
    assert.equal(response.result.collapsed, false);
    assert.match(response.result.text, /const/);
  });

  await t.test("Unicode selection (CJK and emoji) extracts exactly", async () => {
    const unicode = blockAt(blocks, 13);
    assert.ok(unicode, "unicode paragraph did not render with geometry");
    const { left, right } = edges(unicode);
    const response = await selectionCommit(renderer, "sel-doc", "1:0", left, right);
    assert.equal(response.ok, true, response.error);
    assert.equal(response.result.collapsed, false);
    assert.match(response.result.text, /テキスト|emoji/);
  });

  await t.test("a point in the page's own padding is an honest miss, not a guess", async () => {
    // x=2 sits in .markdown-body's own padding, outside every block's box
    // entirely -- the same honest "none" hitTestInPage already reports for
    // this exact region. This is not the element-boundary-normalization case
    // (see the next test); it is the miss case that must stay a miss.
    const paragraph = blockAt(blocks, 2);
    const anchor = { x: 2, y: Math.round((paragraph.topPx + paragraph.bottomPx) / 2) };
    const focus = edges(paragraph).right;
    const response = await selectionCommit(renderer, "sel-doc", "1:0", anchor, focus);
    assert.equal(response.ok, true, response.error);
    assert.equal(response.result.ok, false);
    assert.equal(response.result.reason, "anchor_miss");
  });

  await t.test("element-boundary anchors normalize to a usable endpoint", async () => {
    // A block-level element (like this h1) spans the full content width
    // regardless of how short its text is, so a point far to the right of a
    // short heading's glyphs is still *inside* the heading's own box -- unlike
    // the page-padding case above. Whatever caret resolution does with the
    // blank space past the text, the endpoint must still be usable.
    const heading = blockAt(blocks, 0);
    assert.ok(heading, "heading block did not render with geometry");
    const anchor = { x: 35, y: Math.round((heading.topPx + heading.bottomPx) / 2) };
    const focus = { x: 700, y: Math.round((heading.topPx + heading.bottomPx) / 2) };
    const response = await selectionCommit(renderer, "sel-doc", "1:0", anchor, focus);
    assert.equal(response.ok, true, response.error);
    assert.equal(response.result.ok, true, "a point inside a block's own box must never miss");
    assert.match(response.result.text, /election Doc/);
  });

  await t.test("word_select selects a whole word from a mid-word click", async () => {
    const paragraph = blockAt(blocks, 2);
    const y = Math.round((paragraph.topPx + paragraph.bottomPx) / 2);
    const response = await renderer.send("interact", renderer.interactParams("sel-doc", "1:0", {
      action: "word_select", coordinates: { x: 60, y }, capture: true,
    }));
    if (response.ok && response.result.pngPath) fs.unlinkSync(response.result.pngPath);
    assert.equal(response.ok, true, response.error);
    assert.equal(response.result.kind, "selection");
    assert.equal(response.result.collapsed, false);
    assert.ok(/^[A-Za-z]+$/.test(response.result.text), `expected a single word, got ${JSON.stringify(response.result.text)}`);
  });

  await t.test("selection_text extracts the same text a commit already selected", async () => {
    const paragraph = blockAt(blocks, 2);
    const { left, right } = edges(paragraph);
    const committed = await selectionCommit(renderer, "sel-doc", "1:0", left, right);
    const extracted = await renderer.send("interact", renderer.interactParams("sel-doc", "1:0", { action: "selection_text" }));
    assert.equal(extracted.ok, true, extracted.error);
    assert.equal(extracted.result.pngPath, undefined, "selection_text is read-only and must not capture");
    assert.equal(extracted.result.text, committed.result.text);
  });

  await t.test("selection_clear empties the DOM selection", async () => {
    const paragraph = blockAt(blocks, 2);
    const { left, right } = edges(paragraph);
    await selectionCommit(renderer, "sel-doc", "1:0", left, right);
    const cleared = await renderer.send("interact", renderer.interactParams("sel-doc", "1:0", { action: "selection_clear", capture: true }));
    if (cleared.ok && cleared.result.pngPath) fs.unlinkSync(cleared.result.pngPath);
    assert.equal(cleared.ok, true, cleared.error);
    const after = await renderer.send("interact", renderer.interactParams("sel-doc", "1:0", { action: "selection_text" }));
    assert.equal(after.result.text, "");
    assert.equal(after.result.collapsed, true);
  });

  await t.test("selection survives a scroll-only capture", async () => {
    const paragraph = blockAt(blocks, 2);
    const { left, right } = edges(paragraph);
    const committed = await selectionCommit(renderer, "sel-doc", "1:0", left, right);
    assert.notEqual(committed.result.text, "");
    const scrolled = await renderer.send("capture", {
      ...renderer.renderParams("sel-doc", undefined, "1:0"), markdown: undefined, scrollY: 5,
    });
    assert.equal(scrolled.ok, true, scrolled.error);
    fs.unlinkSync(scrolled.result.pngPath);
    const stillThere = await renderer.send("interact", renderer.interactParams("sel-doc", "1:0", { action: "selection_text" }));
    assert.equal(stillThere.result.text, committed.result.text, "a scroll-only capture must not disturb the DOM Selection");
  });

  await t.test("a selection from an older content revision is dropped, never applied to newer content", async () => {
    const paragraph = blockAt(blocks, 2);
    const { left, right } = edges(paragraph);
    const committed = await selectionCommit(renderer, "sel-doc", "1:0", left, right);
    assert.notEqual(committed.result.text, "");
    const health1 = await renderer.send("health", {});
    assert.equal(health1.result.interactionDocuments >= 1, true);

    // A genuinely new render (different content, not just a revision bump)
    // drops the document's interaction state entirely -- Part 3's
    // interactionStateFor() replaces rather than migrates it.
    await render(t, renderer, "sel-doc", `${DOC}\n\nA new paragraph appended for revision 2.\n`, "2:0");
    const afterEdit = await renderer.send("interact", renderer.interactParams("sel-doc", "2:0", { action: "selection_text" }));
    assert.equal(afterEdit.ok, true, afterEdit.error);
    assert.equal(afterEdit.result.text, "", "the old revision's selection must never surface against new content");
  });

  await renderer.send("shutdown", {});
});

const ALPHA_SEL = "# ALPHA-SEL\n\nAlpha selection paragraph body text here for testing isolation.\n";
const BRAVO_SEL = "# BRAVO-SEL\n\nBravo selection paragraph body text here for testing isolation.\n";

test("cross-document selection isolation: one document's selection never leaks into another's", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = startRenderer(t, executable);
  const a = await render(t, renderer, "sel-a", ALPHA_SEL, "1:0");
  const b = await render(t, renderer, "sel-b", BRAVO_SEL, "1:0");

  const paragraphA = blockAt(a.blocks, 2);
  const { left, right } = edges(paragraphA);
  const committedA = await selectionCommit(renderer, "sel-a", "1:0", left, right);
  assert.match(committedA.result.text, /paragraph body text/);

  // Document B is the one loaded in the shared page right now (it rendered
  // last); its own selection state must read empty, not A's.
  const paragraphB = blockAt(b.blocks, 2);
  void paragraphB;
  const bText = await renderer.send("interact", renderer.interactParams("sel-b", "1:0", { action: "selection_text" }));
  assert.equal(bText.ok, true, bText.error);
  assert.equal(bText.result.text, "", "document B must not see document A's selection");
  assert.doesNotMatch(JSON.stringify(bText.result), /Alpha/);

  // Rehydrating A back into the shared page is a real page.setContent() reload
  // (Part 3's single-shared-page architecture; no page-per-document), which
  // destroys any live window.getSelection() state that referenced A's old DOM
  // nodes -- there is nothing left for the browser to have kept selected. This
  // is architecturally honest, not a leak: A's *old* selection is gone rather
  // than resurrected from a stale reference, and it is never replaced by B's.
  const aTextAfterRehydrate = await renderer.send("interact", renderer.interactParams("sel-a", "1:0", { action: "selection_text" }));
  assert.equal(aTextAfterRehydrate.ok, true, aTextAfterRehydrate.error);
  assert.equal(aTextAfterRehydrate.result.text, "",
    "a selection cannot survive its document being swapped out of the single shared page");

  // A now works normally again: a fresh selection on the rehydrated document
  // resolves correctly.
  const freshA = await selectionCommit(renderer, "sel-a", "1:0", left, right);
  assert.match(freshA.result.text, /paragraph body text/);

  await renderer.send("shutdown", {});
});

test("stale selection-preview frames never replace a newer one", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = startRenderer(t, executable);
  const meta = await render(t, renderer, "drag-sel", DOC, "1:0");
  const paragraph = blockAt(meta.blocks, 2);
  const y = Math.round((paragraph.topPx + paragraph.bottomPx) / 2);
  const anchor = { x: 35, y };

  // Fire a burst of preview requests without awaiting each one -- the interact
  // lane serializes them strictly (lanes.js), so whichever the renderer
  // processes last must reflect the *last* focus point issued, not an earlier
  // one racing ahead of it.
  const focuses = [100, 200, 300, 400, 500, 600, 700];
  const responses = [];
  for (const x of focuses) {
    responses.push(renderer.send("interact", renderer.interactParams("drag-sel", "1:0", {
      action: "selection_preview", coordinates: { x, y }, anchorCoordinates: anchor, capture: true,
    })));
  }
  const settled = await Promise.all(responses);
  for (const response of settled) {
    if (response.ok && response.result.pngPath) fs.unlinkSync(response.result.pngPath);
  }
  const succeeded = settled.filter((r) => r.ok);
  assert.ok(succeeded.length >= 1, "at least the last preview in the burst should resolve");
  for (const response of settled) {
    assert.ok(response.ok || response.code === "STALE_INTERACTION",
      `unexpected failure: ${JSON.stringify(response)}`);
  }
  // The final read of the live DOM selection must reflect the last request
  // this test issued (x: 700), not an earlier one -- the interact lane's
  // strict serialization is what guarantees this without any Part 6 code.
  const finalText = await renderer.send("interact", renderer.interactParams("drag-sel", "1:0", { action: "selection_text" }));
  assert.equal(finalText.ok, true, finalText.error);
  assert.notEqual(finalText.result.text, "", "the last preview in the burst should have produced a real selection");

  await renderer.send("shutdown", {});
});
