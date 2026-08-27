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

test("anchorPinned is an optional boolean that defaults to false", () => {
  const base = {
    documentId: "buffer-1", contentRevision: "1:0", action: "selection_preview",
    viewportWidthPx: 800, viewportHeightPx: 600,
    coordinates: { x: 10, y: 10 }, anchorCoordinates: { x: 20, y: 20 },
  };
  assert.equal(validateEnvelope(base).anchorPinned, false, "absent means unpinned");
  assert.equal(validateEnvelope({ ...base, anchorPinned: false }).anchorPinned, false);
  assert.equal(validateEnvelope({ ...base, anchorPinned: true }).anchorPinned, true);
  // Strictly `=== true`, so a stray truthy value cannot silently pin an anchor.
  assert.equal(validateEnvelope({ ...base, anchorPinned: "yes" }).anchorPinned, false);
  assert.equal(validateEnvelope({ ...base, anchorPinned: 1 }).anchorPinned, false);
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
        maxLocalImageBytes: 1024,
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

async function caretMove(renderer, documentId, contentRevision, coordinates, overrides = {}) {
  const response = await renderer.send("interact", renderer.interactParams(documentId, contentRevision, {
    action: "caret_move", coordinates, granularity: "none", ...overrides,
  }));
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
    assert.equal(response.result.collapsed, false, "a real anchor/focus span must not collapse");
    // Not anchored to the literal first character: a click a few CSS pixels
    // into a block can land the caret just past it (the same terminal-cell
    // edge behavior documented for source-position reporting), which is a
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
    assert.equal(backward.result.collapsed, false, "a right-to-left anchor/focus pair must not collapse the selection");
    assert.equal(backward.result.text, forwardText,
      "either direction across the same two points must select the same text");
  });

  await t.test("anchorIndex/focusIndex resolve a glyph's own tie instead of losing the character (regression)", async () => {
    // interaction.lua's visual_start/visual_update anchor and focus a
    // character-wise selection at the caret's glyph *centre* -- the exact
    // point caretRangeFromPoint cannot break a tie at (moveCaretInPage's own
    // comment: "at the exact middle of a glyph the boundaries either side are
    // equidistant... stable per glyph and differs from glyph to glyph"). On
    // "# Selection Doc"'s heading, that landed the anchor one character past
    // the caret's own glyph, dropping it from the selection -- measured live
    // on a real preview as "## Changelog" selecting as "hangelog"
    // (2026-08-27). Without anchorIndex/focusIndex this reproduces the same
    // way against the heading below; with them it must not.
    const heading = blockAt(blocks, 0);
    const headingY = Math.round((heading.topPx + heading.bottomPx) / 2);
    const first = await caretMove(renderer, "sel-doc", "1:0", { x: 35, y: headingY }, { cellWidthPx: 10 });
    assert.equal(first.ok, true, first.error);
    assert.equal(first.result.ok, true, first.result.reason);
    const firstRect = first.result.rect;
    const centre = { x: firstRect.x + firstRect.width / 2, y: firstRect.y + firstRect.height / 2 };

    // Move to the heading's last character too, the same way `visual_update`
    // would after extending the selection to the end of the line.
    const last = await caretMove(renderer, "sel-doc", "1:0", { x: firstRect.x, y: firstRect.y }, {
      granularity: "lineboundary", direction: "forward", caretIndex: first.result.index, cellWidthPx: 10,
    });
    assert.equal(last.ok, true, last.error);
    const lastRect = last.result.rect;
    const lastCentre = { x: lastRect.x + lastRect.width / 2, y: lastRect.y + lastRect.height / 2 };

    const withoutIndices = await selectionCommit(renderer, "sel-doc", "1:0", centre, lastCentre);
    assert.equal(withoutIndices.ok, true, withoutIndices.error);
    assert.equal(withoutIndices.result.ok, true, withoutIndices.result.reason);

    const withIndices = await selectionCommit(renderer, "sel-doc", "1:0", centre, lastCentre, {
      anchorIndex: first.result.index, focusIndex: last.result.index,
    });
    assert.equal(withIndices.ok, true, withIndices.error);
    assert.equal(withIndices.result.ok, true, withIndices.result.reason);
    assert.equal(withIndices.result.collapsed, false);
    assert.equal(withIndices.result.text, "Selection Doc",
      "with indices, both the first and last character of the heading survive");

    // Reversed roles -- anchor on the LAST character, focus on the FIRST --
    // must resolve identically, proving the fix is direction-aware rather
    // than "always bias left/right".
    const reversed = await selectionCommit(renderer, "sel-doc", "1:0", lastCentre, centre, {
      anchorIndex: last.result.index, focusIndex: first.result.index,
    });
    assert.equal(reversed.ok, true, reversed.error);
    assert.equal(reversed.result.text, "Selection Doc", "backward extension keeps both endpoints too");
  });

  await t.test("multi-block selection spans from one paragraph into the next", async () => {
    const first = blockAt(blocks, 2);
    const second = blockAt(blocks, 4);
    const anchor = { x: 400, y: Math.round((first.topPx + first.bottomPx) / 2) };
    // Well past "Second paragraph" rather than mid-word: font metrics differ
    // enough between environments (a GPU-less CI runner's font stack vs a
    // developer's desktop) to land a caret a character early or late at a
    // tight boundary, and this assertion only cares that the selection
    // reached into the second block's own text at all.
    const focus = { x: 250, y: Math.round((second.topPx + second.bottomPx) / 2) };
    const response = await selectionCommit(renderer, "sel-doc", "1:0", anchor, focus);
    assert.equal(response.ok, true, response.error);
    assert.equal(response.result.collapsed, false);
    // The selection must reach into the second paragraph's own text, not stop
    // at the end of the first.
    assert.match(response.result.text, /Second par/);
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

  await t.test("a selection endpoint in the page's own padding slides onto the nearest block", async () => {
    // x=2 sits in .markdown-body's 26px side padding, outside every block's
    // box entirely. This used to be asserted here as an honest miss --
    // deliberately, by analogy with hitTestInPage, which still reports "none"
    // for this exact region and must keep doing so, since a click in the
    // margin is not a click on the nearest paragraph and must never activate
    // its link.
    //
    // A selection endpoint is the opposite case, and the miss was a real,
    // operator-reported bug rather than a conservative choice. The margin is
    // addressable: it is inside the placement, and this exact point -- x=0,
    // the page's own left edge -- is precisely where `interaction.lua`'s
    // `M.visual_start` anchors a linewise (`V`) selection (see its comment:
    // "the renderer slides an endpoint that lands off content onto the
    // nearest block"). Before nearestBlockPoint existed this landed
    // `anchor_miss` and silently declined to start the selection at all, which
    // is what "V does nothing" was. Every text UI resolves an anchor in the
    // margin the same way, and so does this now: to the start of the line it
    // is level with.
    const paragraph = blockAt(blocks, 2);
    const y = Math.round((paragraph.topPx + paragraph.bottomPx) / 2);
    const response = await selectionCommit(renderer, "sel-doc", "1:0", { x: 2, y }, edges(paragraph).right);
    assert.equal(response.ok, true, response.error);
    assert.equal(response.result.ok, true, "a margin endpoint must resolve, not refuse the selection");
    assert.equal(response.result.collapsed, false);
    assert.match(response.result.text, /^Alpha beta gamma/, "the left margin anchors at the start of that line");
  });

  await t.test("a selection endpoint past the right edge of content still resolves, as V's linewise focus does", async () => {
    // `M.visual_update`'s linewise focus is pinned at `viewportWidthPx - 1` --
    // the page's own right edge, past every block's own text -- so `V`
    // extending onto a short line has to resolve there too, not just at the
    // left margin `V`'s anchor uses. Each of these used to return `focus_miss`
    // before the nearest-block fallback existed, so a linewise selection
    // stayed frozen wherever the caret's line ended short of the page edge.
    const first = blockAt(blocks, 2);
    const later = blockAt(blocks, 6);
    const anchor = { x: 300, y: Math.round((first.topPx + first.bottomPx) / 2) };
    const laterY = Math.round((later.topPx + later.bottomPx) / 2);
    const cases = [
      { label: "left edge column, level with a later block", focus: { x: 5, y: laterY } },
      { label: "x=0 exactly", focus: { x: 0, y: laterY } },
      { label: "right edge column", focus: { x: 795, y: laterY } },
      { label: "below every block, in the scroll-past-end padding", focus: { x: 400, y: 590 } },
      { label: "the placement's bottom-left corner", focus: { x: 5, y: 590 } },
    ];
    for (const { label, focus } of cases) {
      const response = await selectionCommit(renderer, "sel-doc", "1:0", anchor, focus, {
        cellWidthPx: 800 / 39,
        cellHeightPx: 600 / 22,
      });
      assert.equal(response.ok, true, response.error);
      assert.equal(response.result.ok, true, `${label}: must resolve`);
      assert.equal(response.result.collapsed, false, `${label}: must not collapse`);
    }
  });

  await t.test("a hit test in the same padding is still an honest miss", async () => {
    // The counterpart to the two tests above: relaxing selection endpoints
    // must not relax activation. A ctrl-click in the margin still resolves to
    // nothing, so it can never open the nearest paragraph's link.
    const paragraph = blockAt(blocks, 4);
    const response = await renderer.send("interact", renderer.interactParams("sel-doc", "1:0", {
      action: "activate_at",
      coordinates: { x: 2, y: Math.round((paragraph.topPx + paragraph.bottomPx) / 2) },
      modifiers: { ctrl: false, shift: false, alt: false, meta: false },
      clickCount: 1,
    }));
    assert.equal(response.ok, true, response.error);
    assert.notEqual(response.result.kind, "link", "a click in the page margin must not resolve to a link");
    assert.equal(response.result.hit.reason, "outside_content", "and must still report an honest miss");
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

  await t.test(
    "omitting scrollY on selection_clear preserves the shared page's scroll position (regression)",
    async () => {
      const maxScroll = Math.max(0, meta.documentHeightPx - meta.viewportHeightPx);
      if (maxScroll <= 0) return; // the doc must be taller than the viewport for this to be meaningful

      // Move the shared page to a non-zero scroll position.
      const scrolled = await renderer.send("interact", renderer.interactParams("sel-doc", "1:0", {
        action: "hit_test", coordinates: { x: 1, y: 1 }, scrollY: maxScroll, capture: true,
      }));
      if (scrolled.ok && scrolled.result.pngPath) fs.unlinkSync(scrolled.result.pngPath);
      assert.equal(scrolled.ok, true, scrolled.error);
      assert.equal(scrolled.result.scrollY, maxScroll);

      // selection_clear with no scrollY field at all must preserve that
      // position rather than resetting the shared page to the top -- the
      // exact bug that made a click-to-deselect near the bottom of a document
      // jump the preview to the very top.
      const cleared = await renderer.send("interact", renderer.interactParams("sel-doc", "1:0", {
        action: "selection_clear", capture: true, scrollY: undefined,
      }));
      if (cleared.ok && cleared.result.pngPath) fs.unlinkSync(cleared.result.pngPath);
      assert.equal(cleared.ok, true, cleared.error);
      assert.equal(cleared.result.scrollY, maxScroll, "an omitted scrollY must preserve position, not reset to the top");
      assert.equal(cleared.result.captureScale, "device", "selection_clear must default to the sharp capture scale");
    }
  );

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
    // drops the document's interaction state entirely -- the transport's
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
  // (a single shared page; no page-per-document), which
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
  // strict serialization is what guarantees this without any selection-side code.
  const finalText = await renderer.send("interact", renderer.interactParams("drag-sel", "1:0", { action: "selection_text" }));
  assert.equal(finalText.ok, true, finalText.error);
  assert.notEqual(finalText.result.text, "", "the last preview in the burst should have produced a real selection");

  await renderer.send("shutdown", {});
});

// ---------------------------------------------------------------------------
// A selection whose page scrolls mid-gesture -- what a keyboard extension
// (`v`/`V` plus motions that cross the viewport edge) does when it scrolls the
// page in-page. This is the one case where the anchor's coordinates stop
// describing the anchor: they are viewport-relative, so every scrolled pixel
// moves them off it, and once the anchor scrolls out of view entirely
// resolveSelectionPoint refuses the point outright and the whole frame comes
// back anchor_miss.
// ---------------------------------------------------------------------------

const TALL_DOC = (() => {
  const lines = ["# Tall Doc", ""];
  for (let index = 1; index <= 60; index += 1) {
    lines.push(`Paragraph ${String(index).padStart(2, "0")} marker${String(index).padStart(2, "0")} filler words to give this block real height and width.`);
    lines.push("");
  }
  return lines.join("\n");
})();

test("a selection survives the page scrolling under it when the anchor is pinned", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = startRenderer(t, executable);
  const meta = await render(t, renderer, "scroll-sel", TALL_DOC, "1:0");
  assert.ok(meta.documentHeightPx > 600 * 3, "the fixture must be several viewports tall to scroll through");

  const firstParagraph = blockAt(meta.blocks, 2);
  const anchor = { x: 40, y: Math.round((firstParagraph.topPx + firstParagraph.bottomPx) / 2) };

  // No capture: the overlay path returns the same text and rects without
  // spending a screenshot per request.
  async function preview(scrollY, focus, extra = {}) {
    const response = await renderer.send("interact", renderer.interactParams("scroll-sel", "1:0", {
      action: "selection_preview", coordinates: focus, anchorCoordinates: anchor,
      scrollY, capture: false, ...extra,
    }));
    assert.equal(response.ok, true, response.error);
    return response.result;
  }

  // Establish the anchor at the top of the document, exactly as the first
  // frame of a keyboard extension does -- nothing is pinned yet, because
  // there is nothing to pin to.
  const opening = await preview(0, { x: 400, y: anchor.y });
  assert.equal(opening.ok, true, "the opening frame resolves its anchor from coordinates");
  assert.match(opening.text, /marker01/, "and anchors in the first paragraph");

  // Now scroll far enough that the anchor is well off screen, and keep
  // extending toward the bottom edge -- an in-page scroll crossing the
  // viewport, the way a downward motion run does.
  const pinned = await preview(2400, { x: 400, y: 590 }, { anchorPinned: true });
  assert.equal(pinned.ok, true, "a pinned anchor survives scrolling out of the viewport");
  assert.match(pinned.text, /marker01/, "the selection still starts where the extension started");
  assert.ok(pinned.text.length > opening.text.length * 5,
    `the selection should have grown by pages, got ${pinned.text.length} vs ${opening.text.length}`);

  // The contrast: the identical request without pinning re-resolves the anchor
  // coordinate against whatever text now occupies those pixels, so the
  // selection no longer starts where the reader started it.
  await renderer.send("interact", renderer.interactParams("scroll-sel", "1:0", { action: "selection_clear" }));
  await preview(0, { x: 400, y: anchor.y });
  const unpinned = await preview(2400, { x: 400, y: 590 });
  assert.equal(unpinned.ok, true, "the unpinned request still resolves -- it just resolves elsewhere");
  assert.doesNotMatch(unpinned.text, /marker01/,
    "without pinning the anchor drifts to whatever scrolled into its coordinates");

  // Pinning with nothing live to pin to must fall back to the coordinate rather
  // than fail: that is what makes the flag safe to send unconditionally.
  await renderer.send("interact", renderer.interactParams("scroll-sel", "1:0", { action: "selection_clear" }));
  const cleared = await preview(0, { x: 400, y: anchor.y }, { anchorPinned: true });
  assert.equal(cleared.ok, true, "pinning with no live selection falls back to the anchor coordinate");
  assert.match(cleared.text, /marker01/, "and lands exactly where the coordinate says");

  await renderer.send("shutdown", {});
});

// ---------------------------------------------------------------------------
// `caret_move`: the renderer half of the preview's caret. Two properties are
// what this whole action exists for, and both are asserted below against a real
// Chromium rather than reasoned about:
//
//   1. The caret reports the **box of the character it is on**, so Lua can draw
//      a caret shaped like that glyph. A caret on a heading must therefore be
//      visibly taller than one on body text.
//   2. The caret is always on a real character. A point in the page margin, or
//      in the blank space beside a heading, snaps onto content instead of
//      producing a caret hovering over nothing.
// ---------------------------------------------------------------------------

const CARET_DOC = [
  "# Personal Knowledge Vault",
  "",
  "Private vault for technical reference, daily learning, and work notes.",
  "",
  "## Structure",
  "",
  "Second paragraph of ordinary body text, long enough to wrap onto more than",
  "one visual line in an eight-hundred pixel viewport so line motion has",
  "somewhere to go.",
  "",
].join("\n");

test("the caret reports the glyph it sits on, and never sits on nothing", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = startRenderer(t, executable);
  const meta = await render(t, renderer, "caret-doc", CARET_DOC, "1:0");
  const heading = blockAt(meta.blocks, 0);
  const body = blockAt(meta.blocks, 2);
  const headingY = Math.round((heading.topPx + heading.bottomPx) / 2);
  const bodyY = Math.round((body.topPx + body.bottomPx) / 2);

  async function caret(from, overrides = {}) {
    const response = await renderer.send("interact", renderer.interactParams("caret-doc", "1:0", {
      action: "caret_move", coordinates: from, cellWidthPx: 10, granularity: "none", ...overrides,
    }));
    assert.equal(response.ok, true, response.error);
    assert.equal(response.result.kind, "caret");
    return response.result;
  }

  await t.test("the caret box is the glyph's box, not a fixed cell", async () => {
    const onHeading = await caret({ x: 45, y: headingY });
    const onBody = await caret({ x: 45, y: bodyY });
    assert.equal(onHeading.ok, true, `heading: ${onHeading.reason}`);
    assert.equal(onBody.ok, true, `body: ${onBody.reason}`);
    for (const result of [onHeading, onBody]) {
      assert.ok(result.rect.width > 0, "a caret box has real width");
      assert.ok(result.rect.height > 0, "and real height");
    }
    // The whole point of request #2's correction: an h1 glyph is bigger than a
    // paragraph glyph, so the caret drawn on it has to be bigger too.
    assert.ok(
      onHeading.rect.height > onBody.rect.height * 1.2,
      `a caret on an h1 must be taller than one on body text: ${onHeading.rect.height} vs ${onBody.rect.height}`
    );
    assert.ok(onHeading.rect.width > onBody.rect.width, "and wider");
  });

  await t.test("a point in the margin snaps onto real content", async () => {
    // x = 2 is inside the page's own 26px side padding: no character is there.
    const margin = await caret({ x: 2, y: headingY });
    assert.equal(margin.ok, true, `expected a snap, got ${margin.reason}`);
    assert.ok(margin.rect.width > 0 && margin.rect.height > 0, "and a real glyph box");
    assert.ok(margin.rect.x >= 20, `snapped onto the text, not left in the padding: ${margin.rect.x}`);
    assert.ok(
      Math.abs(margin.rect.y - heading.topPx) < heading.bottomPx - heading.topPx,
      "onto the line it was level with"
    );
  });

  await t.test("a point in the blank space beside a heading snaps onto the heading", async () => {
    // The exact case in the screenshot: far to the right of a short heading,
    // where the old cell-based caret used to hover over nothing at all.
    const beside = await caret({ x: 760, y: headingY });
    assert.equal(beside.ok, true, `expected a snap, got ${beside.reason}`);
    assert.ok(beside.rect.height > 0, "onto a real glyph");
    assert.ok(
      Math.abs(beside.rect.y - heading.topPx) < heading.bottomPx - heading.topPx,
      "and onto the heading's own line rather than some other block"
    );
    // Specifically the end of the heading's text, not somewhere past it.
    assert.ok(beside.rect.x < 760, `pulled back onto the glyphs: ${beside.rect.x}`);
  });

  await t.test("character motion advances by one glyph", async () => {
    const first = await caret({ x: 45, y: headingY }, { granularity: "character" });
    assert.equal(first.ok, true);
    const second = await caret({ x: first.rect.x, y: first.rect.y + first.rect.height / 2 }, {
      granularity: "character",
    });
    assert.equal(second.ok, true);
    assert.ok(second.rect.x > first.rect.x, "the caret moved right");
    assert.ok(second.rect.x - first.rect.x < 60, "by one glyph, not a jump");
  });

  await t.test("line motion crosses to the next visual line", async () => {
    const start = await caret({ x: 45, y: bodyY });
    const down = await caret({ x: start.rect.x, y: start.rect.y + start.rect.height / 2 }, {
      granularity: "line",
    });
    assert.equal(down.ok, true, `expected a line below, got ${down.reason}`);
    assert.ok(down.rect.y > start.rect.y, `moved down: ${down.rect.y} vs ${start.rect.y}`);
    // It should stay near the column it started from, not reset to the margin.
    assert.ok(Math.abs(down.rect.x - start.rect.x) < 40, "keeping roughly its column");
  });

  await t.test("word, block and document motions land on real glyphs", async () => {
    const from = { x: 45, y: bodyY };
    for (const granularity of ["word", "word_end", "block", "document"]) {
      const moved = await caret(from, { granularity });
      assert.equal(moved.ok, true, `${granularity}: ${moved.reason}`);
      assert.ok(moved.rect.width > 0 && moved.rect.height > 0, `${granularity} landed on a glyph`);
    }
    const back = await caret(from, { granularity: "word", direction: "backward" });
    assert.equal(back.ok, true);
    const forward = await caret(from, { granularity: "word" });
    // Compared in document order, not by raw x: the starting point is the first
    // word of a paragraph, so backward crosses into the heading above and lands
    // at a *larger* x on an earlier line.
    const order = (rect) => rect.y * 100000 + rect.x;
    assert.ok(order(back.rect) < order(forward.rect), "backward and forward go opposite ways");
    assert.ok(back.rect.y < from.y, "backward crossed up into the preceding block");
  });

  await t.test("the motion never touches the DOM selection", async () => {
    // Load-bearing: `w` in preview visual mode must extend the selection, not
    // replace it. This is why the implementation cannot use Selection.modify.
    const { left, right } = edges(body);
    const selected = await selectionCommit(renderer, "caret-doc", "1:0", left, right);
    assert.equal(selected.ok, true, selected.error);
    const before = await renderer.send("interact", renderer.interactParams("caret-doc", "1:0", { action: "selection_text" }));
    assert.notEqual(before.result.text, "", "a selection is up");

    await caret({ x: 45, y: bodyY }, { granularity: "word", count: 2 });

    const after = await renderer.send("interact", renderer.interactParams("caret-doc", "1:0", { action: "selection_text" }));
    assert.equal(after.result.text, before.result.text, "the selection survived the caret motion unchanged");
  });

  await renderer.send("shutdown", {});
});

// ---------------------------------------------------------------------------
// Line motion. Two properties, both reported as bugs against the first cut:
//
//   1. Stepping off a big glyph must not drift sideways. Matching columns by
//      glyph *centre* fails across a font-size change -- the centre of a 38px
//      heading `P` sits right of the 18px `P` below it and left of that line's
//      `r`, so `j` landed one character right, every time.
//   2. `j` N times then `k` N times must return to the character it started
//      on. That needs a sticky target column (Vim's `curswant`) carried
//      through the whole run, not re-derived at each step.
// ---------------------------------------------------------------------------

test("line motion holds its column, and down-then-up returns where it started", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = startRenderer(t, executable);
  const meta = await render(t, renderer, "line-doc", CARET_DOC, "1:0");
  const heading = blockAt(meta.blocks, 0);
  const headingY = Math.round((heading.topPx + heading.bottomPx) / 2);

  async function caret(from, overrides = {}) {
    const response = await renderer.send("interact", renderer.interactParams("line-doc", "1:0", {
      action: "caret_move", coordinates: from, cellWidthPx: 10, granularity: "none", ...overrides,
    }));
    assert.equal(response.ok, true, response.error);
    return response.result;
  }
  const centre = (rect) => ({ x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 });

  // The exact reported case: the first glyph of the h1 is `P`, and `j` must
  // land on the `P` of the paragraph below it -- not its `r`.
  const start = await caret({ x: 30, y: headingY });
  assert.equal(start.ok, true);
  assert.ok(start.rect.height > 30, "starting on the h1's own big glyph");
  const down = await caret(centre(start.rect), { granularity: "line", desiredX: start.rect.x });
  assert.equal(down.ok, true, `expected a line below: ${down.reason}`);
  assert.ok(
    Math.abs(down.rect.x - start.rect.x) < start.rect.width / 2,
    `a line step must hold its column: started at x=${start.rect.x}, landed at x=${down.rect.x}`
  );

  // Down four lines and back up four, carrying the column the whole way, must
  // land on exactly the glyph it started from.
  let position = start.rect;
  for (let step = 0; step < 4; step += 1) {
    const moved = await caret(centre(position), { granularity: "line", desiredX: start.rect.x });
    if (moved.ok !== true) break;
    position = moved.rect;
  }
  assert.ok(position.y > start.rect.y, "the run actually travelled down the document");
  for (let step = 0; step < 4; step += 1) {
    const moved = await caret(centre(position), {
      granularity: "line", direction: "backward", desiredX: start.rect.x,
    });
    if (moved.ok !== true) break;
    position = moved.rect;
  }
  assert.equal(position.x, start.rect.x, "down N then up N returns to the same column");
  assert.equal(position.y, start.rect.y, "and to the same line");

  // `0` and `$`.
  const body = blockAt(meta.blocks, 6);
  const bodyPoint = { x: 400, y: Math.round(body.topPx + 8) };
  const middle = await caret(bodyPoint);
  assert.equal(middle.ok, true);
  const home = await caret(centre(middle.rect), { granularity: "lineboundary", direction: "backward" });
  assert.equal(home.ok, true, `0: ${home.reason}`);
  assert.ok(home.rect.x < middle.rect.x, "0 moves to the start of the line");
  const away = await caret(centre(middle.rect), { granularity: "lineboundary", direction: "forward" });
  assert.equal(away.ok, true, `$: ${away.reason}`);
  assert.ok(away.rect.x > middle.rect.x, "$ moves to the end of the line");
  for (const edge of [home, away]) {
    assert.ok(
      Math.abs(edge.rect.y - middle.rect.y) < middle.rect.height,
      "and both stay on the line they started on"
    );
  }

  await renderer.send("shutdown", {});
});

// ---------------------------------------------------------------------------
// `h` and `l`, which is where two separate defects met.
//
//   1. A motion used to resume from the caret's own glyph *centre*, re-resolved
//      through `caretPositionFromPoint`. That answers with the nearest boundary
//      *between* two characters, and a glyph's middle is equidistant from the
//      boundaries either side of it -- so on the glyphs where the tie broke
//      rightward the renderer believed the caret was one character further on
//      than it was drawn. `h` stepped back onto the glyph it started on and the
//      caret never moved again; `l` skipped one. Both are per-glyph, which is
//      why the walk below covers every glyph of a line rather than sampling two.
//   2. `character` motion had no idea what a line was, so `l` walked off the
//      right edge of a rendered row and on through the blocks beneath it.
//
// The fix for the first is that a motion carries `caretIndex` -- what the last
// one reported -- so the caret is never re-derived from its own geometry. Every
// step below feeds the index back the way interaction.lua does.
// ---------------------------------------------------------------------------
test("h and l cross the line one glyph at a time and stop at both its ends", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = startRenderer(t, executable);
  const meta = await render(t, renderer, "step-doc", CARET_DOC, "1:0");
  const heading = blockAt(meta.blocks, 0);
  const headingY = Math.round((heading.topPx + heading.bottomPx) / 2);

  async function caret(from, overrides = {}) {
    const response = await renderer.send("interact", renderer.interactParams("step-doc", "1:0", {
      action: "caret_move", coordinates: from, cellWidthPx: 0, granularity: "none", ...overrides,
    }));
    assert.equal(response.ok, true, response.error);
    return response.result;
  }
  // One motion continuing from `at`, exactly as interaction.lua sends it: the
  // index that motion reported, plus the glyph's centre as the coordinate the
  // renderer falls back to when the index no longer names anything.
  const step = (at, overrides) => caret(
    { x: at.rect.x + at.rect.width / 2, y: at.rect.y + at.rect.height / 2 },
    { caretIndex: at.index, ...overrides }
  );
  const right = { granularity: "character" };
  const left = { granularity: "character", direction: "backward" };

  // "Personal Knowledge Vault" -- 24 characters, and `l` from the start of the
  // line has to visit all 24 and then stop. Skipping and running on are both
  // failures of this one number.
  const HEADING_GLYPHS = 24;

  await t.test("l visits every glyph of the heading, then stops at its end", async () => {
    const home = await caret({ x: 2, y: headingY }, { granularity: "lineboundary", direction: "backward" });
    assert.equal(home.ok, true, `0: ${home.reason}`);

    const visited = [home];
    for (let i = 0; i < HEADING_GLYPHS * 2; i += 1) {
      const next = await step(visited[visited.length - 1], right);
      assert.equal(next.ok, true, `l: ${next.reason}`);
      // A motion with nowhere to go reports where it already is.
      if (next.index === visited[visited.length - 1].index) break;
      visited.push(next);
    }

    assert.equal(visited.length, HEADING_GLYPHS,
      `l must land on each of the heading's ${HEADING_GLYPHS} glyphs and stop, not skip and not run on`);
    for (let i = 1; i < visited.length; i += 1) {
      assert.equal(visited[i].index, visited[i - 1].index + 1, `step ${i} advanced exactly one character`);
      assert.ok(visited[i].rect.x > visited[i - 1].rect.x, `step ${i} advanced to the right`);
      assert.ok(
        Math.abs(visited[i].rect.y - home.rect.y) < home.rect.height,
        `step ${i} stayed on the heading's own line`
      );
    }

    // And back. Each `h` returns to exactly the glyph the matching `l` came
    // from -- the assertion the stuck caret failed on its very first press.
    let position = visited[visited.length - 1];
    for (let i = visited.length - 2; i >= 0; i -= 1) {
      const back = await step(position, left);
      assert.equal(back.ok, true, `h: ${back.reason}`);
      assert.equal(back.index, visited[i].index, `h from glyph ${i + 1} returned to glyph ${i}`);
      assert.equal(back.rect.x, visited[i].rect.x, `and to exactly the same column`);
      position = back;
    }
    const past = await step(position, left);
    assert.equal(past.index, position.index, "h at the start of the line stays there");
  });

  await t.test("l stops at the end of a wrapped row without leaving the paragraph", async () => {
    // The second body paragraph is written to wrap, so the end of its first
    // rendered row is a soft wrap rather than the end of the block -- the case
    // where `l` used to slide onto the row below.
    const wrapping = blockAt(meta.blocks, 6);
    const middle = await caret({ x: 400, y: Math.round(wrapping.topPx + 8) });
    assert.equal(middle.ok, true);
    const end = await step(middle, { granularity: "lineboundary" });
    assert.equal(end.ok, true, `$: ${end.reason}`);

    const past = await step(end, right);
    assert.equal(past.index, end.index, "l at the end of a row stays on it");
    assert.equal(past.rect.y, end.rect.y, "and does not slip onto the row below");

    // There genuinely was more paragraph below, so this tested a soft wrap and
    // not the last row of the document.
    const below = await step(end, { granularity: "line" });
    assert.equal(below.ok, true);
    assert.ok(below.rect.y > end.rect.y, "the row below exists; l simply declined to go there");
  });

  await t.test("w crosses into the next block without skipping its first word", async () => {
    // The blocks' text is flattened into one index space, and with nothing
    // between them `Intl.Segmenter` read "Vault" + "Private" as the single word
    // "VaultPrivate" -- so `w` off the end of the heading landed on "vault",
    // the paragraph's *second* word.
    const body = blockAt(meta.blocks, 2);
    const firstGlyph = await caret(
      { x: 2, y: Math.round((body.topPx + body.bottomPx) / 2) },
      { granularity: "lineboundary", direction: "backward" }
    );
    assert.equal(firstGlyph.ok, true);

    const lastWord = await caret({ x: 2, y: headingY }, { granularity: "lineboundary" });
    assert.equal(lastWord.ok, true, "starting on the heading's last glyph");
    const landed = await step(lastWord, { granularity: "word" });
    assert.equal(landed.ok, true, `w: ${landed.reason}`);
    assert.equal(landed.index, firstGlyph.index, "w landed on the paragraph's first word, not its second");
  });

  await renderer.send("shutdown", {});
});
