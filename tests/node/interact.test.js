import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import zlib from "node:zlib";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";
import { BrowserRenderer } from "../../renderer/src/browser.js";
import {
  INTERACT_ACTIONS,
  RESERVED_ACTIONS,
  classifyLink,
  hitTestInPage,
  resolveSourcePosition,
  validateEnvelope,
} from "../../renderer/src/interact.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const assetsDir = path.resolve(here, "../../renderer/assets");
const main = path.resolve(here, "../../renderer/src/main.js");
const fixture = fs.readFileSync(path.join(here, "../fixtures/kitchen-sink.md"), "utf8");

function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

// A real, valid greyscale PNG. security.js checks the magic bytes and the
// extension before inlining a local image, so a placeholder byte string would be
// rejected and the image would silently not render.
function pngChunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(zlib.crc32(body) >>> 0);
  return Buffer.concat([length, body, crc]);
}

function buildPng(width, height) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8; // bit depth
  header[9] = 0; // greyscale
  const stride = width + 1;
  const raw = Buffer.alloc(height * stride);
  for (let y = 0; y < height; y += 1) {
    raw[y * stride] = 0; // filter: none
    raw.fill(128, y * stride + 1, (y + 1) * stride);
  }
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk("IHDR", header),
    pngChunk("IDAT", zlib.deflateSync(raw)),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

// ---------------------------------------------------------------------------
// Pure surface: no browser, no subprocess.
// ---------------------------------------------------------------------------

test("envelope validation rejects malformed interactions before they reach the queue", () => {
  const base = {
    documentId: "buffer-1", contentRevision: "1:0", action: "hit_test",
    viewportWidthPx: 800, viewportHeightPx: 600, coordinates: { x: 10, y: 10 },
  };
  assert.doesNotThrow(() => validateEnvelope(base));

  const cases = [
    [{ ...base, documentId: undefined }, "INVALID_INTERACTION", /documentId/],
    [{ ...base, documentId: "" }, "INVALID_INTERACTION", /documentId/],
    [{ ...base, contentRevision: undefined }, "INVALID_INTERACTION", /contentRevision/],
    [{ ...base, action: undefined }, "INVALID_INTERACTION", /action string/],
    [{ ...base, coordinates: undefined }, "INVALID_INTERACTION", /coordinates/],
    [{ ...base, coordinates: { x: NaN, y: 1 } }, "INVALID_INTERACTION", /coordinates\.x/],
    [{ ...base, coordinates: { x: 1, y: "nope" } }, "INVALID_INTERACTION", /coordinates\.y/],
    [{ ...base, viewportWidthPx: 0 }, "INVALID_INTERACTION", /positive/],
    [{ ...base, viewportHeightPx: undefined }, "INVALID_INTERACTION", /viewportHeightPx/],
    [{ ...base, strategy: "psychic" }, "INVALID_INTERACTION", /caret strategy/],
    [{ ...base, clickCount: 0 }, "INVALID_INTERACTION", /clickCount/],
    [{ ...base, clickCount: 1.5 }, "INVALID_INTERACTION", /clickCount/],
    [{ ...base, scrollY: -1 }, "INVALID_INTERACTION", /scrollY/],
    [{ ...base, modifiers: [] }, "INVALID_INTERACTION", /modifiers/],
    [{ ...base, action: "nonsense" }, "UNKNOWN_ACTION", /unknown interact action/],
  ];
  for (const [params, code, message] of cases) {
    assert.throws(() => validateEnvelope(params), (error) => {
      assert.equal(error.code, code, `wrong code for ${JSON.stringify(params.action ?? params)}`);
      assert.match(error.message, message);
      return true;
    });
  }
});

test("no interaction actions remain reserved", () => {
  // RESERVED_ACTIONS is kept as an empty array rather than removed: it is what
  // keeps validateEnvelope's reserved-vs-unknown branch structurally
  // meaningful for whatever a later change reserves next.
  assert.deepEqual(RESERVED_ACTIONS, []);
  const unknown = "definitely-not-a-real-action";
  assert.throws(() => validateEnvelope({
    documentId: "buffer-1", contentRevision: "1:0", action: unknown,
    viewportWidthPx: 800, viewportHeightPx: 600,
  }), (error) => {
    assert.equal(error.code, "UNKNOWN_ACTION");
    assert.equal(error.detail.reserved, undefined);
    return true;
  });
});

test("every interaction action is registered with the correct flags", () => {
  const expected = {
    // Read-only by design, not by omission: a caret motion runs while a visual
    // selection is up, so it must not disturb the DOM selection.
    caret_move: { mutatesVisibleState: false, requiresCoordinates: true },
    selection_preview: { mutatesVisibleState: true, requiresCoordinates: true, requiresAnchor: true },
    selection_commit: { mutatesVisibleState: true, requiresCoordinates: true, requiresAnchor: true },
    selection_clear: { mutatesVisibleState: true, requiresCoordinates: false },
    selection_text: { mutatesVisibleState: false, requiresCoordinates: false },
    find_set: { mutatesVisibleState: true, requiresCoordinates: false, requiresQuery: true },
    find_next: { mutatesVisibleState: true, requiresCoordinates: false },
    find_previous: { mutatesVisibleState: true, requiresCoordinates: false },
    find_clear: { mutatesVisibleState: true, requiresCoordinates: false },
    obsidian_scroll: { mutatesVisibleState: false, requiresCoordinates: false, requiresObsidianAnchor: true },
  };
  for (const [action, flags] of Object.entries(expected)) {
    assert.ok(INTERACT_ACTIONS[action], `${action} is not registered in INTERACT_ACTIONS`);
    for (const [flag, value] of Object.entries(flags)) {
      assert.equal(INTERACT_ACTIONS[action][flag], value, `${action}.${flag}`);
    }
  }
  assert.deepEqual([...Object.keys(INTERACT_ACTIONS)].sort(), [
    "activate_at", "caret_move", "find_clear", "find_next", "find_previous", "find_set", "hit_test",
    "obsidian_scroll", "selection_clear", "selection_commit", "selection_preview", "selection_text",
  ]);
});

test("caret_move validates its granularity, direction, count and caret index", () => {
  const base = {
    documentId: "buffer-1", contentRevision: "1:0", action: "caret_move",
    viewportWidthPx: 800, viewportHeightPx: 600, coordinates: { x: 10, y: 10 },
  };
  assert.equal(validateEnvelope(base).granularity, "character", "character is the default granularity");
  assert.equal(validateEnvelope(base).direction, "forward", "forward is the default direction");
  assert.equal(validateEnvelope(base).motionCount, 1, "one is the default count");
  // The sticky column a run of line motions aims at (Vim's `curswant`).
  assert.equal(validateEnvelope(base).desiredX, null, "absent by default");
  assert.equal(validateEnvelope({ ...base, desiredX: 0 }).desiredX, 0, "and zero is a real column, not absent");
  assert.equal(validateEnvelope({ ...base, desiredX: 42.5 }).desiredX, 42.5);
  assert.throws(() => validateEnvelope({ ...base, desiredX: "left" }), (error) => {
    assert.equal(error.code, "INVALID_INTERACTION");
    assert.match(error.message, /desiredX/);
    return true;
  });
  for (const granularity of ["none", "character", "line", "lineboundary", "word", "word_end", "block", "document"]) {
    assert.equal(validateEnvelope({ ...base, granularity }).granularity, granularity);
  }
  assert.equal(validateEnvelope({ ...base, direction: "backward" }).direction, "backward");
  // Anything that is not "backward" is forward, rather than an error: direction
  // has exactly two values and no useful third answer.
  assert.equal(validateEnvelope({ ...base, direction: "sideways" }).direction, "forward");
  assert.equal(validateEnvelope({ ...base, count: 7 }).motionCount, 7);
  assert.throws(() => validateEnvelope({ ...base, granularity: "sentence" }), (error) => {
    assert.equal(error.code, "INVALID_INTERACTION");
    assert.match(error.message, /granularity/);
    return true;
  });
  // Coerced, not rejected -- the same contract `clickCount` already has.
  assert.equal(validateEnvelope({ ...base, count: "3" }).motionCount, 3);
  for (const count of [0, -1, 1.5, "abc", null]) {
    assert.throws(() => validateEnvelope({ ...base, count }), (error) => {
      assert.equal(error.code, "INVALID_INTERACTION");
      assert.match(error.message, /count/);
      return true;
    }, `count=${count}`);
  }
  // Where the caret already is, in the renderer's own character space. Optional:
  // a click and the caret's first placement have no index and resolve from their
  // coordinates instead.
  assert.equal(validateEnvelope(base).caretIndex, null, "absent by default");
  assert.equal(validateEnvelope({ ...base, caretIndex: null }).caretIndex, null, "and explicitly absent");
  assert.equal(validateEnvelope({ ...base, caretIndex: 0 }).caretIndex, 0, "zero is the first character, not absent");
  assert.equal(validateEnvelope({ ...base, caretIndex: 7 }).caretIndex, 7);
  // Not coerced, unlike `count`: an index is an exact position into a character
  // space, so a value that is not already one is a caller bug worth reporting
  // rather than something to round into place.
  for (const caretIndex of [-1, 1.5, "3", "abc", {}]) {
    assert.throws(() => validateEnvelope({ ...base, caretIndex }), (error) => {
      assert.equal(error.code, "INVALID_INTERACTION");
      assert.match(error.message, /caretIndex/);
      return true;
    }, `caretIndex=${caretIndex}`);
  }
  // The other actions must not grow these fields.
  assert.equal(validateEnvelope({ ...base, action: "hit_test" }).granularity, null);
  assert.equal(validateEnvelope({ ...base, action: "hit_test", caretIndex: 7 }).caretIndex, null);
});

test("selection and find actions validate their required fields", () => {
  const base = {
    documentId: "buffer-1", contentRevision: "1:0",
    viewportWidthPx: 800, viewportHeightPx: 600,
  };
  for (const action of ["selection_preview", "selection_commit"]) {
    assert.throws(
      () => validateEnvelope({ ...base, action, coordinates: { x: 1, y: 1 } }),
      (error) => { assert.equal(error.code, "INVALID_INTERACTION"); assert.match(error.message, /anchorCoordinates/); return true; },
      `${action} without anchorCoordinates`
    );
    assert.doesNotThrow(() => validateEnvelope({
      ...base, action, coordinates: { x: 1, y: 1 }, anchorCoordinates: { x: 0, y: 0 },
    }));
  }
  assert.throws(
    () => validateEnvelope({ ...base, action: "find_set" }),
    (error) => { assert.equal(error.code, "INVALID_INTERACTION"); assert.match(error.message, /query/); return true; },
    "find_set without a query"
  );
  assert.throws(
    () => validateEnvelope({ ...base, action: "find_set", query: "   " }),
    (error) => { assert.equal(error.code, "INVALID_INTERACTION"); return true; },
    "find_set with a whitespace-only query"
  );
  const withQuery = validateEnvelope({ ...base, action: "find_set", query: "  hello  " });
  assert.equal(withQuery.query, "hello", "the query is trimmed");

  // Mutating actions always capture, matching every other mutatesVisibleState
  // action -- this is the seam that lets Lua never issue a follow-up capture.
  const cleared = validateEnvelope({ ...base, action: "selection_clear" });
  assert.equal(cleared.capture, true);
  const text = validateEnvelope({ ...base, action: "selection_text" });
  assert.equal(text.capture, false, "selection_text is read-only and must not capture");
});

test("envelope defaults are conservative", () => {
  const envelope = validateEnvelope({
    documentId: "buffer-1", contentRevision: "1:0", action: "hit_test",
    viewportWidthPx: 800, viewportHeightPx: 600, coordinates: { x: 1, y: 2 },
  });
  assert.equal(envelope.strategy, "auto");
  assert.equal(envelope.clickCount, 1);
  assert.equal(envelope.scrollY, null, "omitted scrollY preserves position instead of defaulting to the top");
  assert.equal(envelope.capture, false, "a read-only action must not capture unless asked");
  assert.equal(envelope.captureScale, "device", "interactions default to the sharp scale unless css is requested");
  assert.deepEqual(envelope.modifiers, { ctrl: false, shift: false, alt: false, meta: false });
});

test("classifyLink separates safe schemes from unsafe ones", () => {
  assert.deepEqual(classifyLink("#section"), { href: "#section", type: "fragment" });
  assert.equal(classifyLink("https://example.invalid/a").type, "https");
  assert.equal(classifyLink("http://example.invalid/a").type, "http");
  assert.equal(classifyLink("HTTPS://example.invalid").type, "https");
  assert.equal(classifyLink("mailto:someone@example.invalid").type, "mailto");
  assert.equal(classifyLink("./relative/notes.md").type, "local_file");
  assert.equal(classifyLink("file:///tmp/notes.md").type, "local_file");
  // The mouse layer owns the document-root check; interact only reports the kind.
  assert.equal(classifyLink("javascript:alert(1)").type, "unsafe");
  assert.equal(classifyLink("JaVaScRiPt:alert(1)").type, "unsafe");
  assert.equal(classifyLink("data:text/html,<b>x</b>").type, "unsafe");
  assert.equal(classifyLink("vbscript:msgbox").type, "unsafe");
  assert.equal(classifyLink("//example.invalid/a").type, "unsafe", "protocol-relative is a network fetch");
  assert.equal(classifyLink("").type, "unsafe");
  assert.equal(classifyLink(null).type, "unsafe");
});

test("source positions convert 0-based exclusive markdown-it maps to 1-based Neovim lines", () => {
  // A one-line block: block and line are the same fact, so "line" is honest.
  assert.deepEqual(resolveSourcePosition({ sourceStart: 0, sourceEnd: 1 }),
    { line: 1, byteColumn: 0, precision: "line" });
  assert.deepEqual(resolveSourcePosition({ sourceStart: 2, sourceEnd: 3 }),
    { line: 3, byteColumn: 0, precision: "line" });
  // A multi-line block: we know the block only, and report its first line.
  assert.deepEqual(resolveSourcePosition({ sourceStart: 36, sourceEnd: 41 }),
    { line: 37, byteColumn: 0, precision: "block" });
  // No block at all is never guessed at.
  for (const absent of [null, undefined, {}, { sourceStart: NaN, sourceEnd: 2 }, { sourceStart: -1, sourceEnd: 1 }]) {
    assert.deepEqual(resolveSourcePosition(absent), { line: null, byteColumn: null, precision: "none" });
  }
});

test("block-only resolution can never report exact precision", () => {
  // Still true with exact provenance, and still the point: a block carries no column, so
  // resolution that has only a block to work from must not manufacture one. What
  // changed is that a hit can now *also* carry an inline region -- see
  // tests/node/source-provenance.test.js for what that resolves to.
  for (let start = 0; start < 40; start += 1) {
    for (let span = 1; span < 12; span += 1) {
      assert.notEqual(resolveSourcePosition({ sourceStart: start, sourceEnd: start + span }).precision, "exact");
      assert.notEqual(
        resolveSourcePosition({ sourceStart: start, sourceEnd: start + span }, null, null).precision,
        "exact"
      );
    }
  }
});

test("the in-page guard refuses to answer from the wrong document's DOM", () => {
  // hitTestInPage runs inside the page, so it is exercised here against a
  // stubbed DOM. This is the last of the three isolation layers: even if every
  // Node-side check were wrong, this one still refuses.
  const savedDocument = globalThis.document;
  const savedWindow = globalThis.window;
  try {
    let elementFromPointCalls = 0;
    globalThis.window = { innerWidth: 800, innerHeight: 600 };
    globalThis.document = {
      documentElement: { getAttribute: () => "d9" },
      elementFromPoint: () => { elementFromPointCalls += 1; return null; },
    };
    const result = hitTestInPage({ token: "d1", x: 10, y: 10, strategy: "auto", previewLimit: 120 });
    assert.deepEqual(result, { error: "DOCUMENT_MISMATCH", expected: "d1", actual: "d9" });
    assert.equal(elementFromPointCalls, 0, "the guard must fire before the DOM is queried at all");

    // The matching token proceeds, and an empty point is still an honest miss.
    globalThis.document.documentElement.getAttribute = () => "d1";
    const match = hitTestInPage({ token: "d1", x: 10, y: 10, strategy: "auto", previewLimit: 120 });
    assert.equal(match.ok, true);
    assert.equal(match.reason, "no_element");
    assert.equal(match.block, null);
    assert.equal(elementFromPointCalls, 1);

    // Out-of-viewport coordinates never reach elementFromPoint either.
    assert.equal(hitTestInPage({ token: "d1", x: 900, y: 10, strategy: "auto" }).reason, "outside_viewport");
    assert.equal(hitTestInPage({ token: "d1", x: 10, y: -1, strategy: "auto" }).reason, "outside_viewport");
    assert.equal(elementFromPointCalls, 1);
  } finally {
    globalThis.document = savedDocument;
    globalThis.window = savedWindow;
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
    interactParams(documentId, contentRevision, coordinates, overrides = {}) {
      return {
        documentId, contentRevision, action: "hit_test", coordinates,
        viewportWidthPx: 800, viewportHeightPx: 600, scrollY: 0, ...overrides,
      };
    },
  };
  return api;
}

const ALPHA = "# ALPHA-ONLY heading\n\nAlpha paragraph body text.\n";
const BRAVO = "# BRAVO-ONLY heading\n\nBravo paragraph body text.\n";

test("an interaction for document A never resolves against document B's DOM", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = startRenderer(t, executable);

  const a = await renderer.send("render", renderer.renderParams("doc-a", ALPHA, "1:0"));
  assert.equal(a.ok, true, a.error);
  fs.unlinkSync(a.result.pngPath);
  const b = await renderer.send("render", renderer.renderParams("doc-b", BRAVO, "1:0"));
  assert.equal(b.ok, true, b.error);
  fs.unlinkSync(b.result.pngPath);

  // Document B is the one loaded in the shared page right now. Aim at a point
  // that, in B's layout, sits squarely over B's heading text.
  const heading = b.result.blocks.find((block) => block.sourceStart === 0);
  const point = { x: 120, y: (heading.topPx + heading.bottomPx) / 2 };

  const hit = await renderer.send("interact", renderer.interactParams("doc-a", "1:0", point));
  assert.equal(hit.ok, true, hit.error);
  assert.equal(hit.result.rehydrated, true, "document A should have been rehydrated");
  assert.equal(hit.result.documentId, "doc-a");
  assert.equal(hit.result.sourcePosition.line, 1);
  // The caret lands inside the heading's own text run, so the column is
  // resolved against document A's source map -- which is the isolation claim
  // this test exists for, now made at column precision rather than line.
  assert.equal(hit.result.sourcePosition.precision, "exact");
  assert.ok(hit.result.sourcePosition.byteColumn >= "# ".length,
    "the column resolved past the heading marker, into A's own text");
  assert.match(hit.result.hit.element.textPreview, /ALPHA-ONLY/);
  // The strongest form of the claim: nothing from B appears anywhere in the
  // response, not in the text preview, the link, or any diagnostic field.
  assert.doesNotMatch(JSON.stringify(hit.result), /BRAVO/,
    "document B's content leaked into an interaction for document A");

  // Rehydrating back is symmetric, and staying put costs nothing.
  const backToB = await renderer.send("interact", renderer.interactParams("doc-b", "1:0", point));
  assert.equal(backToB.ok, true, backToB.error);
  assert.equal(backToB.result.rehydrated, true);
  assert.match(backToB.result.hit.element.textPreview, /BRAVO-ONLY/);
  assert.doesNotMatch(JSON.stringify(backToB.result), /ALPHA/);

  const againB = await renderer.send("interact", renderer.interactParams("doc-b", "1:0", point));
  assert.equal(againB.result.rehydrated, false, "the already-active document must not be reloaded");

  // Rehydration must reproduce the geometry the render measured, not a variant
  // of it. If these ever diverge, the two document templates have drifted.
  const rehydratedA = await renderer.send("interact", renderer.interactParams("doc-a", "1:0", point));
  assert.equal(rehydratedA.result.documentHeightPx, a.result.documentHeightPx);
  assert.equal(rehydratedA.result.viewportHeightPx, a.result.viewportHeightPx);

  // A document the renderer has never rendered is an error, never a guess
  // against whatever happens to be loaded.
  const missing = await renderer.send("interact", renderer.interactParams("doc-never", "1:0", point));
  assert.equal(missing.ok, false);
  assert.equal(missing.code, "INTERACT_CACHE_MISS");
  assert.match(missing.error, /render first/);

  // Stale revision: rejected at lane admission, with a code Lua can tell apart
  // from a stale render.
  const staleRevision = await renderer.send("interact", renderer.interactParams("doc-a", "0:0", point));
  assert.equal(staleRevision.ok, false);
  assert.equal(staleRevision.code, "STALE_INTERACTION");
  assert.equal(staleRevision.detail.reason, "revision_mismatch");

  // A viewport that disagrees with the rendered layout is refused rather than
  // silently resized, because resizing would invalidate these coordinates.
  const wrongViewport = await renderer.send(
    "interact",
    renderer.interactParams("doc-a", "1:0", point, { viewportWidthPx: 640 })
  );
  assert.equal(wrongViewport.ok, false);
  assert.equal(wrongViewport.code, "STALE_INTERACTION");
  assert.equal(wrongViewport.detail.reason, "viewport_mismatch");

  // Per-document interaction state must not leak either: a render of A must not
  // disturb B's cached frame.
  const a2 = await renderer.send("render", renderer.renderParams("doc-a", ALPHA, "2:0"));
  assert.equal(a2.ok, true, a2.error);
  fs.unlinkSync(a2.result.pngPath);
  const bStillValid = await renderer.send("interact", renderer.interactParams("doc-b", "1:0", point));
  assert.equal(bStillValid.ok, true, bStillValid.error);
  assert.match(bStillValid.result.hit.element.textPreview, /BRAVO-ONLY/);

  // Per-document interaction state is tracked in Node memory (selection, find,
  // and the last hit), and never crosses a
  // content revision: applying an old selection to new content would be silent
  // corruption in a copy operation.
  // The re-render of document A above changed its content, so A's state is
  // already gone while B's -- untouched by A's render -- survives.
  const afterEdit = await renderer.send("health", {});
  assert.equal(afterEdit.ok, true, afterEdit.error);
  assert.equal(afterEdit.result.activeDocument, "doc-b");
  assert.equal(afterEdit.result.interactionDocuments, 1,
    "editing document A should drop A's interaction state and leave B's alone");

  // Interacting with A at its new revision re-establishes state for it...
  const aAgain = await renderer.send("interact", renderer.interactParams("doc-a", "2:0", point));
  assert.equal(aAgain.ok, true, aAgain.error);
  assert.equal((await renderer.send("health", {})).result.interactionDocuments, 2);

  // ...and the next edit drops it again. Interaction state never crosses a
  // content revision.
  const a3 = await renderer.send("render", renderer.renderParams("doc-a", `${ALPHA}\nNew line.\n`, "3:0"));
  assert.equal(a3.ok, true, a3.error);
  fs.unlinkSync(a3.result.pngPath);
  assert.equal((await renderer.send("health", {})).result.interactionDocuments, 1);

  await renderer.send("shutdown", {});
});

test("a page that is not the document we believe it is refuses to answer", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
  const params = {
    documentId: "guarded", contentRevision: "1:0",
    viewport: { widthPx: 800, heightPx: 600, deviceScaleFactor: 1 },
    browser: { executable_path: executable, launch_timeout_ms: 10000 },
    theme: "dark", scrollY: 0, captureScale: "css",
    scrollPastEnd: true, scrollPastEndOffsetPx: 22,
  };
  const html = '<h1 data-source-start="0" data-source-end="1">Guarded</h1>';
  const rendered = await renderer.render(params, html, 1);
  fs.unlinkSync(rendered.pngPath);
  assert.equal(renderer.active.documentId, "guarded");

  const envelope = validateEnvelope({
    documentId: "guarded", contentRevision: "1:0", action: "hit_test",
    viewportWidthPx: 800, viewportHeightPx: 600, scrollY: 0, coordinates: { x: 100, y: 40 },
  });
  const cached = { html, sourceMap: null };
  const good = await renderer.interact(envelope, cached, 2);
  assert.equal(good.sourcePosition.line, 1);

  // Simulate every Node-side check having been fooled: the record claims a
  // document is loaded, but the page carries a different stamp.
  renderer.active.token = "d-not-this-one";
  await assert.rejects(() => renderer.interact(envelope, cached, 3), (error) => {
    assert.equal(error.code, "DOCUMENT_MISMATCH");
    assert.match(error.message, /refusing to resolve/);
    return true;
  });
  // ...and the disproved record is dropped rather than reused.
  assert.equal(renderer.active, null);
  assert.equal(renderer.layout, null);

  // The next interaction rebuilds from the frame record and succeeds again.
  const recovered = await renderer.interact(envelope, cached, 4);
  assert.equal(recovered.rehydrated, true);
  assert.equal(recovered.sourcePosition.line, 1);
});

test("a burst of interactions cannot cancel a render or a capture", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = startRenderer(t, executable);

  const first = await renderer.send("render", renderer.renderParams("drag-doc", ALPHA, "1:0"));
  assert.equal(first.ok, true, first.error);
  fs.unlinkSync(first.result.pngPath);
  const point = { x: 120, y: 30 };

  // Queue a real render, then immediately flood the interact lane behind it.
  // The render is already stamped, so nothing an interaction does can reach it.
  const renderPromise = renderer.send("render", renderer.renderParams("drag-doc", `${ALPHA}\nMore text.\n`, "2:0"));
  const capturePromise = renderer.send("capture", {
    ...renderer.renderParams("drag-doc", undefined, "2:0"), markdown: undefined, scrollY: 10,
  });
  const drags = [];
  for (let index = 0; index < 40; index += 1) {
    drags.push(renderer.send("interact", renderer.interactParams("drag-doc", "2:0", { x: 100 + index, y: 40 })));
  }

  const rendered = await renderPromise;
  assert.equal(rendered.ok, true, `a drag cancelled the render: ${rendered.error}`);
  assert.equal(rendered.result.markdownReused, false);
  fs.unlinkSync(rendered.result.pngPath);

  const captured = await capturePromise;
  assert.equal(captured.ok, true, `a drag cancelled the capture: ${captured.error}`);
  fs.unlinkSync(captured.result.pngPath);

  const settled = await Promise.all(drags);
  const succeeded = settled.filter((response) => response.ok);
  const superseded = settled.filter((response) => !response.ok && response.code === "STALE_INTERACTION");
  assert.equal(succeeded.length + superseded.length, drags.length,
    `unexpected interaction failures: ${JSON.stringify(settled.filter((r) => !r.ok && r.code !== "STALE_INTERACTION"))}`);
  assert.ok(superseded.length > 0, "a drag burst should coalesce, not run every point");
  assert.ok(succeeded.length >= 1, "the newest drag point should still resolve");
  for (const drop of superseded) {
    assert.equal(drop.detail.lane, "interact", "an abandoned drag must be reported on the interact lane");
  }

  await renderer.send("shutdown", { });
  void point;
});

test("hit-testing resolves real content honestly and refuses to guess elsewhere", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = startRenderer(t, executable);
  const rendered = await renderer.send("render", renderer.renderParams("sink", fixture, "1:0"));
  assert.equal(rendered.ok, true, rendered.error);
  fs.unlinkSync(rendered.result.pngPath);
  const meta = rendered.result;
  const blocks = meta.blocks;
  const maxScroll = Math.max(0, meta.documentHeightPx - meta.viewportHeightPx);

  const blockAt = (sourceStart, sourceEnd) =>
    blocks.find((block) => block.sourceStart === sourceStart
      && (sourceEnd === undefined || block.sourceEnd === sourceEnd));

  // Scroll the block into view and aim at its vertical middle. Using the
  // renderer's own reported geometry keeps this independent of font metrics.
  async function hit(block, { x = 120, action = "hit_test", strategy = "auto", extra = {} } = {}) {
    const middle = (block.topPx + block.bottomPx) / 2;
    const scrollY = Math.max(0, Math.min(Math.round(middle - meta.viewportHeightPx / 2), maxScroll));
    const response = await renderer.send("interact", renderer.interactParams("sink", "1:0",
      { x, y: middle - scrollY }, { scrollY, action, strategy, ...extra }));
    assert.equal(response.ok, true, `${action} failed: ${response.error}`);
    return response.result;
  }

  await t.test("headings, paragraphs, and inline formatting resolve to their own block", async () => {
    const heading = await hit(blockAt(0, 1));
    assert.equal(heading.sourcePosition.line, 1);
    // The caret is inside "Kitchen Sink", so the column is real. Before
    // it, this reported the block's line with column 0.
    assert.equal(heading.sourcePosition.precision, "exact");
    assert.ok(heading.sourcePosition.byteColumn >= 2, "resolved past the '# ' marker");
    assert.match(heading.hit.element.textPreview, /Kitchen Sink/);

    // The paragraph spans source lines 3-4 (0-based [2,4]). Block resolution
    // could only ever say "line 3, somewhere"; inline provenance names the line
    // the clicked text is actually on and where on it.
    const paragraph = await hit(blockAt(2, 4));
    assert.equal(paragraph.sourcePosition.precision, "exact");
    assert.ok([3, 4].includes(paragraph.sourcePosition.line),
      `the paragraph's rendered text comes from lines 3-4, not ${paragraph.sourcePosition.line}`);
  });

  await t.test("every listed content type resolves inside its own source range", async () => {
    // Source ranges come from markdown-it's own token maps, verified against the
    // geometry this fixture actually produces -- a nested list item is [9,11),
    // not [9,10), because the nested list closes the outer item.
    const targets = {
      "h2 heading": blockAt(5, 6),
      "unordered list item": blockAt(7, 8),
      "nested list item": blockAt(9, 11),
      "ordered list item": blockAt(11, 12),
      "task list item": blockAt(14, 15),
      blockquote: blockAt(17, 18),
      "alert blockquote": blockAt(19, 21),
      "fenced code": blockAt(36, 41),
      "thematic break (an empty block)": blockAt(42, 43),
      table: blockAt(46, 50),
      "table body row": blockAt(48, 49),
    };
    // Exact provenance upgraded the claim here. Every hit still has to land inside its own
    // source range -- that is the containment property this test has always been
    // for -- but a hit that lands on real text now also carries a real column,
    // and the two content types that cannot carry one say so rather than
    // guessing.
    const cannotBeExact = new Set([
      // A thematic break has no text at all. It is the only entry: a task list
      // item used to be here too, because markdown-it-task-lists' `labelAfter`
      // re-emitted the item text as raw html_inline and left no text token to
      // carry a position. That option is gone, the children survive, and the
      // item resolves exactly like any other list item -- which is what the
      // `else` branch below now checks for it.
      "thematic break (an empty block)",
    ]);
    for (const [label, block] of Object.entries(targets)) {
      assert.ok(block, `fixture block for ${label} was not rendered with geometry`);
      const result = await hit(block);
      const { line, precision, byteColumn } = result.sourcePosition;
      assert.notEqual(precision, "none", `${label} resolved to nothing`);
      // The innermost block wins, so assert containment rather than equality:
      // hitting a list resolves to the list item, not the list.
      assert.ok(line >= block.sourceStart + 1 && line <= block.sourceEnd,
        `${label} resolved to line ${line}, outside its source range ${block.sourceStart + 1}-${block.sourceEnd}`);
      if (cannotBeExact.has(label)) {
        assert.notEqual(precision, "exact", `${label} claimed a precision it cannot support`);
        assert.equal(byteColumn, 0, `${label} invented a byte column`);
      } else {
        assert.equal(precision, "exact", `${label} lost the column exact provenance should give it`);
        const text = fixture.split("\n")[line - 1];
        assert.ok(byteColumn >= 0 && byteColumn <= Buffer.byteLength(text, "utf8"),
          `${label} resolved to byte column ${byteColumn}, off the end of line ${line}`);
      }
    }
  });

  await t.test("a link reports metadata without the renderer following it", async () => {
    const paragraph = blockAt(2, 4);
    // Sweep the whole paragraph box rather than assuming which rendered line
    // the link wraps onto -- that depends on font metrics we do not control.
    const scrollY = Math.max(0, Math.min(
      Math.round((paragraph.topPx + paragraph.bottomPx) / 2 - meta.viewportHeightPx / 2), maxScroll));
    let found = null;
    let sawPlainText = false;
    for (let y = paragraph.topPx + 4; y < paragraph.bottomPx && !found; y += 8) {
      for (let x = 30; x < 780 && !found; x += 8) {
        const response = await renderer.send("interact", renderer.interactParams("sink", "1:0",
          { x, y: y - scrollY }, { scrollY, action: "activate_at" }));
        assert.equal(response.ok, true, response.error);
        if (response.result.kind === "link") found = response.result;
        else if (response.result.sourcePosition.line === 3) sawPlainText = true;
      }
    }
    assert.ok(found, "the safe link in the fixture was never hit by activate_at");
    assert.equal(found.link.type, "https");
    assert.equal(found.link.href, "https://example.invalid");
    // activate_at still carries a source position, so an unmodified click can
    // navigate to source without a second round trip. Exact provenance made that position
    // the link *label's* -- which lives on source line 4, `[safe link](...)`,
    // not on line 3 where the paragraph starts.
    assert.equal(found.sourcePosition.line, 4);
    assert.equal(found.sourcePosition.precision, "exact");
    const label = fixture.split("\n")[3];
    assert.ok(found.sourcePosition.byteColumn >= label.indexOf("safe")
      && found.sourcePosition.byteColumn < label.indexOf("]"),
    `the resolved column ${found.sourcePosition.byteColumn} is not inside the link label`);
    // ...and non-link text in the same paragraph reports source, not a link,
    // so `kind` genuinely discriminates rather than always saying "link".
    assert.ok(sawPlainText, "activate_at never reported plain source inside the linked paragraph");
  });

  await t.test("a fragment link scrolls the shared page to its heading anchor", async () => {
    const markdown = [
      "# Fragment Doc",
      "",
      "[jump to target](#target-heading)",
      "",
      ...Array.from({ length: 60 }, (_, i) => `Filler paragraph number ${i}.\n`),
      "## Target Heading",
      "",
      "Landing text.",
      "",
    ].join("\n");
    const rendered = await renderer.send("render", renderer.renderParams("fragment-doc", markdown, "1:0"));
    assert.equal(rendered.ok, true, rendered.error);
    fs.unlinkSync(rendered.result.pngPath);

    const linkParagraph = rendered.result.blocks.find((block) => block.sourceStart === 2);
    assert.ok(linkParagraph, "fragment link paragraph rendered with no geometry");
    const response = await renderer.send("interact", renderer.interactParams("fragment-doc", "1:0",
      { x: 40, y: (linkParagraph.topPx + linkParagraph.bottomPx) / 2 }, { action: "activate_at", capture: true }));
    assert.equal(response.ok, true, response.error);
    assert.equal(response.result.kind, "link");
    assert.equal(response.result.link.type, "fragment");
    assert.equal(response.result.link.href, "#target-heading");
    assert.equal(response.result.fragmentResolved, true, "the heading anchor generated by markdown.js was not found");
    // The target heading is far down a document taller than the viewport, so
    // a genuine scroll had to happen -- this is not just "stayed at 0".
    assert.ok(response.result.scrollY > 0, "fragment activation did not actually scroll");
    if (response.result.pngPath) fs.unlinkSync(response.result.pngPath);

    const missing = await renderer.send("interact", renderer.interactParams("fragment-doc", "1:0",
      { x: 40, y: (linkParagraph.topPx + linkParagraph.bottomPx) / 2 },
      { action: "activate_at", scrollY: response.result.scrollY }));
    assert.equal(missing.ok, true, missing.error);
    // Same click again after having scrolled: the link is still resolvable
    // (activate_at re-hit-tests at the current scroll position each time),
    // proving the fragment resolution didn't corrupt subsequent interactions.
    assert.equal(missing.result.kind, "source", "the paragraph should have scrolled out of view by now");
  });

  await t.test("an unresolvable fragment reports the miss honestly instead of guessing", async () => {
    const markdown = "# Doc\n\n[dead link](#does-not-exist)\n";
    const rendered = await renderer.send("render", renderer.renderParams("dead-fragment-doc", markdown, "1:0"));
    assert.equal(rendered.ok, true, rendered.error);
    fs.unlinkSync(rendered.result.pngPath);
    const paragraph = rendered.result.blocks.find((block) => block.sourceStart === 2);
    const response = await renderer.send("interact", renderer.interactParams("dead-fragment-doc", "1:0",
      { x: 40, y: (paragraph.topPx + paragraph.bottomPx) / 2 }, { action: "activate_at" }));
    assert.equal(response.ok, true, response.error);
    assert.equal(response.result.link.type, "fragment");
    assert.equal(response.result.fragmentResolved, false);
    assert.equal(response.result.scrollY, 0, "an unresolved fragment must not move the scroll position");
  });

  await t.test("a rendered image resolves to its own block", async () => {
    // The fixture's images are both blocked, and blocked images are
    // `display: none`, so their paragraphs have zero height and carry no
    // geometry at all. Testing images honestly needs an image that renders.
    const imageDir = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-interact-"));
    t.after(() => fs.rmSync(imageDir, { recursive: true, force: true }));
    fs.writeFileSync(path.join(imageDir, "probe.png"), buildPng(160, 90));
    const markdown = "# Image doc\n\n![a local image](./probe.png)\n";
    const shown = await renderer.send("render", renderer.renderParams("image-doc", markdown, "1:0", {
      baseDir: imageDir, documentRoot: imageDir, localImages: true, maxLocalImageBytes: 1024 * 1024,
    }));
    assert.equal(shown.ok, true, shown.error);
    fs.unlinkSync(shown.result.pngPath);

    const paragraph = shown.result.blocks.find((block) => block.sourceStart === 2);
    assert.ok(paragraph, "the image paragraph rendered with no geometry; it was probably blocked");
    const response = await renderer.send("interact", renderer.interactParams("image-doc", "1:0",
      { x: 400, y: (paragraph.topPx + paragraph.bottomPx) / 2 }));
    assert.equal(response.ok, true, response.error);
    // An image renders no text, so there is no caret offset to map -- but its
    // position is still exact, because `![` is where the whole construct starts
    // and it cannot be subdivided further.
    assert.deepEqual(response.result.sourcePosition, { line: 3, byteColumn: 0, precision: "exact" });
    assert.equal(response.result.hit.element.isImage, true, "the hit did not land on the image");
    assert.equal(response.result.hit.element.tagName, "IMG");
  });

  await t.test("both caret strategies agree, and element-only still resolves the block", async () => {
    const paragraph = blockAt(2, 4);
    const viaPosition = await hit(paragraph, { strategy: "caret-position" });
    const viaRange = await hit(paragraph, { strategy: "caret-range" });
    const viaElement = await hit(paragraph, { strategy: "element-only" });
    assert.equal(viaPosition.hit.strategy, "caret-position");
    assert.equal(viaRange.hit.strategy, "caret-range");
    assert.equal(viaElement.hit.strategy, "element-only");
    assert.equal(viaPosition.sourcePosition.line, viaRange.sourcePosition.line);
    assert.equal(viaElement.sourcePosition.line, viaRange.sourcePosition.line);
    assert.equal(viaPosition.hit.node.nodeType, 3, "a caret hit on text should report a text node");
    assert.equal(viaElement.hit.node, null, "element-only resolution reports no caret node");
    assert.ok(Number.isInteger(viaRange.hit.offset));
  });

  await t.test("coordinates off the content report precision none rather than a guess", async () => {
    const paragraph = blockAt(2, 4);
    const y = (paragraph.topPx + paragraph.bottomPx) / 2;
    const cases = {
      "left page padding": { x: 2, y },
      "right page padding": { x: 798, y },
      "above the article": { x: 120, y: 1 },
      "negative x": { x: -5, y },
      "beyond the viewport width": { x: 4000, y },
      "beyond the viewport height": { x: 120, y: 4000 },
    };
    for (const [label, point] of Object.entries(cases)) {
      const response = await renderer.send("interact", renderer.interactParams("sink", "1:0", point));
      assert.equal(response.ok, true, `${label}: ${response.error}`);
      assert.equal(response.result.sourcePosition.precision, "none", `${label} guessed a position`);
      assert.equal(response.result.sourcePosition.line, null, `${label} invented a line`);
      assert.equal(response.result.kind, "source");
    }

    // Scroll-past-end padding: at the bottom of the document the viewport is
    // almost entirely the article's bottom padding.
    const bottom = await renderer.send("interact", renderer.interactParams("sink", "1:0",
      { x: 120, y: meta.viewportHeightPx - 10 }, { scrollY: maxScroll }));
    assert.equal(bottom.ok, true, bottom.error);
    assert.equal(bottom.result.sourcePosition.precision, "none", "scroll-past-end padding guessed a position");
  });

  await t.test("a mutating-style interaction returns its PNG from the same queued operation", async () => {
    const paragraph = blockAt(2, 4);
    const middle = (paragraph.topPx + paragraph.bottomPx) / 2;
    const scrollY = Math.max(0, Math.min(Math.round(middle - meta.viewportHeightPx / 2), maxScroll));
    const response = await renderer.send("interact", renderer.interactParams("sink", "1:0",
      { x: 120, y: middle - scrollY }, { scrollY, capture: true }));
    assert.equal(response.ok, true, response.error);
    // Semantic result and frame arrive together; Lua never issues a follow-up.
    assert.equal(response.result.kind, "source");
    assert.equal(response.result.sourcePosition.line, 3);
    assert.equal(response.result.captureScale, "device", "interactions default to the sharp scale");
    assert.equal(response.result.scrollY, scrollY);
    assert.ok(response.result.documentHeightPx > 0);
    assert.ok(fs.existsSync(response.result.pngPath));
    const png = fs.readFileSync(response.result.pngPath);
    assert.deepEqual(png.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
    assert.equal(png.readUInt32BE(16), 800, "device scale factor 1 should match the CSS viewport width");
    fs.unlinkSync(response.result.pngPath);

    const cheap = await renderer.send("interact", renderer.interactParams("sink", "1:0",
      { x: 120, y: middle - scrollY }, { scrollY, capture: true, captureScale: "css" }));
    assert.equal(cheap.ok, true, cheap.error);
    assert.equal(cheap.result.captureScale, "css", "css scale is opt-in only");
    fs.unlinkSync(cheap.result.pngPath);

    // A read-only interaction that did not ask for a frame must not produce one.
    const readOnly = await renderer.send("interact", renderer.interactParams("sink", "1:0",
      { x: 120, y: middle - scrollY }, { scrollY }));
    assert.equal(readOnly.result.pngPath, undefined);
  });

  await t.test("the protocol rejects unknown actions and lane laundering", async () => {
    const unknown = await renderer.send("interact", renderer.interactParams("sink", "1:0", { x: 1, y: 1 },
      { action: "teleport" }));
    assert.equal(unknown.ok, false);
    assert.equal(unknown.code, "UNKNOWN_ACTION");

    // Every previously-reserved action is now implemented; an incomplete
    // envelope for one of them is now a validation error, not "not built yet".
    const incomplete = await renderer.send("interact", renderer.interactParams("sink", "1:0", { x: 1, y: 1 },
      { action: "selection_preview" }));
    assert.equal(incomplete.ok, false);
    assert.equal(incomplete.code, "INVALID_INTERACTION");
    assert.match(incomplete.error, /anchorCoordinates/);

    // An interaction must not be able to buy its way into the content lane,
    // which is where the power to cancel renders lives.
    const laundered = await renderer.send("interact", renderer.interactParams("sink", "1:0", { x: 1, y: 1 },
      { lane: "content" }));
    assert.equal(laundered.ok, false);
    assert.equal(laundered.code, "INVALID_REQUEST");
    assert.match(laundered.error, /may not use the content lane/);

    // A capture may legitimately be promoted to the settle lane.
    const settled = await renderer.send("capture", {
      ...renderer.renderParams("sink", undefined, "1:0"), markdown: undefined,
      lane: "settle", captureScale: "device",
    });
    assert.equal(settled.ok, true, settled.error);
    fs.unlinkSync(settled.result.pngPath);

    const badLane = await renderer.send("interact", renderer.interactParams("sink", "1:0", { x: 1, y: 1 },
      { lane: "wormhole" }));
    assert.equal(badLane.ok, false);
    assert.equal(badLane.code, "INVALID_REQUEST");
  });

  await t.test("exact precision is reported where the parser supports it, and only there", async () => {
    // This assertion is the inverse of the one that shipped before source
    // provenance existed ("no interaction reports exact precision"), and it is
    // deliberately still a sweep over every block the fixture renders: the risk
    // exact provenance introduces is a *confidently wrong* column, so the check
    // is that every label is one of the four honest ones, that a claimed column
    // is inside the line it names, and that most of the document gained one.
    const sourceLines = fixture.split("\n");
    let exact = 0;
    for (const block of blocks) {
      const { line, byteColumn, precision } = (await hit(block)).sourcePosition;
      assert.ok(["exact", "line", "block", "none"].includes(precision),
        `block at source line ${block.sourceStart + 1} reported precision ${precision}`);
      if (precision === "none") {
        assert.equal(line, null);
        continue;
      }
      assert.ok(line >= 1 && line <= sourceLines.length, `line ${line} is outside the document`);
      assert.ok(byteColumn >= 0 && byteColumn <= Buffer.byteLength(sourceLines[line - 1], "utf8"),
        `byte column ${byteColumn} is off the end of line ${line}`);
      if (precision === "exact") exact += 1;
      else assert.equal(byteColumn, 0, "a non-exact position must not carry a column");
    }
    assert.ok(exact >= blocks.length / 2,
      `only ${exact} of ${blocks.length} blocks resolved exactly; provenance is not reaching most content`);
  });

  await renderer.send("shutdown", {});
});
