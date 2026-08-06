import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
// Reached by path rather than by name: this file lives outside renderer/, so
// bare-specifier resolution would not find renderer/node_modules.
import MarkdownIt from "../../renderer/node_modules/markdown-it/index.mjs";
import { renderMarkdown } from "../../renderer/src/markdown.js";
import {
  alignLine,
  deriveSpan,
  normalizeSource,
  provenancePlugin,
  resolveRegionPosition,
  spanOf,
} from "../../renderer/src/provenance.js";
import { resolveSourcePosition } from "../../renderer/src/interact.js";
import { BrowserRenderer } from "../../renderer/src/browser.js";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const assetsDir = path.resolve(here, "../../renderer/assets");
const fixture = fs.readFileSync(path.join(here, "../fixtures/provenance.md"), "utf8");
const kitchenSink = fs.readFileSync(path.join(here, "../fixtures/kitchen-sink.md"), "utf8");

const LINES = fixture.split("\n");
/// 1-based source line, the way a human counts them and the way Neovim does.
const line = (number) => LINES[number - 1];
/// The independent oracle for every byte column in this file: Node's own UTF-8
/// encoder, not the converter under test.
const byteColumn = (number, column16) => Buffer.byteLength(line(number).slice(0, column16), "utf8");

function render(markdown = fixture) {
  return renderMarkdown(markdown, {
    rawHtml: false, localImages: false, maxLocalImageBytes: 1024, baseDir: here, documentRoot: here,
  });
}

const { html: FIXTURE_HTML, sourceMap: FIXTURE_MAP } = render();

// ---------------------------------------------------------------------------
// Looking a run up by what it *renders*, never by where it claims to come from.
// Identifying a region by its source slice would make every column assertion
// circular; identifying it by the text the browser will show is the same thing
// the hit test does.
// ---------------------------------------------------------------------------

function decodeEntities(text) {
  return text
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, "\"").replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&");
}

/// id -> the text immediately inside the element carrying that id. The escaped
/// text of a run can never contain `<`, so "up to the next tag" is exact.
function renderedRuns(html) {
  const runs = new Map();
  const pattern = /data-md-source-id="(s\d+)"[^>]*>([^<]*)/g;
  for (const match of html.matchAll(pattern)) runs.set(match[1], decodeEntities(match[2]));
  return runs;
}

const FIXTURE_RUNS = renderedRuns(FIXTURE_HTML);

/// Find the run whose rendered text is exactly `rendered`, failing loudly when
/// that is ambiguous -- an ambiguous lookup would make the test meaningless.
/// `onLine` (1-based) disambiguates text that genuinely renders more than once.
function runByText(rendered, { onLine, sourceMap = FIXTURE_MAP, runs = FIXTURE_RUNS } = {}) {
  const matches = [...runs.entries()].filter(([id, text]) =>
    text === rendered
    && sourceMap.regions[id]?.mapping === "identity"
    && (onLine === undefined || sourceMap.regions[id].line === onLine - 1));
  assert.equal(matches.length, 1,
    `expected exactly one rendered run reading ${JSON.stringify(rendered)}, found ${matches.length}`);
  return { id: matches[0][0], rendered: matches[0][1] };
}

/// Click `occurrence`-th `needle` inside the run that renders `rendered`, and
/// report where the source cursor would land.
function click(rendered, needle, occurrence = 1, options = {}) {
  const sourceMap = options.sourceMap ?? FIXTURE_MAP;
  const run = runByText(rendered, { ...options, sourceMap });
  let offset = -1;
  for (let index = 0; index < occurrence; index += 1) offset = run.rendered.indexOf(needle, offset + 1);
  assert.ok(offset >= 0, `${JSON.stringify(needle)} #${occurrence} is not inside ${JSON.stringify(rendered)}`);
  const resolved = resolveRegionPosition(sourceMap, run.id, offset);
  assert.ok(resolved, `run ${run.id} did not resolve`);
  return { line: resolved.line + 1, byteColumn: resolved.byteColumn, precision: resolved.precision, id: run.id };
}

// ---------------------------------------------------------------------------
// The operator's five checks, as automated as they can be without a terminal.
// ---------------------------------------------------------------------------

test("a click inside emphasis lands past the markers, not on them", () => {
  const hit = click("bold text", "text");
  const expected = line(3).indexOf("bold text") + "bold ".length;
  assert.deepEqual(hit, { line: 3, byteColumn: expected, precision: "exact", id: hit.id });
  assert.equal(line(3).slice(expected, expected + 4), "text");
  assert.ok(line(3).slice(0, expected).endsWith("**bold "), "the markers really are in front of it");
});

test("a click on a link's label lands on the label, never in the URL", () => {
  const hit = click("link label", "label");
  const expected = line(3).indexOf("link label") + "link ".length;
  assert.deepEqual(hit, { line: 3, byteColumn: expected, precision: "exact", id: hit.id });
  assert.ok(expected < line(3).indexOf("https://"), "the resolved column is inside the label, before the URL");
});

test("CJK and astral characters resolve to byte columns, not code-unit columns", () => {
  const rendered = "Unicode line: café 日本語 🎉 done.";
  const cjk = click(rendered, "日本語");
  assert.deepEqual(cjk, { line: 5, byteColumn: byteColumn(5, line(5).indexOf("日本語")), precision: "exact", id: cjk.id });
  const emoji = click(rendered, "🎉");
  assert.deepEqual(emoji, { line: 5, byteColumn: byteColumn(5, line(5).indexOf("🎉")), precision: "exact", id: emoji.id });
  // The whole point of the conversion: these columns are not the code-unit ones.
  assert.notEqual(cjk.byteColumn, line(5).indexOf("日本語"));
  assert.notEqual(emoji.byteColumn, line(5).indexOf("🎉"));
  // ...and the byte column is a real boundary in the real line, not a position
  // inside a character.
  for (const hit of [cjk, emoji]) {
    assert.notEqual(Buffer.from(line(5), "utf8")[hit.byteColumn] & 0xc0, 0x80,
      "a byte column must never point at a UTF-8 continuation byte");
  }
});

test("repeated identical text resolves to the occurrence that was clicked", () => {
  const rendered = "Repeated: apple banana apple banana apple";
  const first = line(7).indexOf("apple");
  const second = line(7).indexOf("apple", first + 1);
  const third = line(7).indexOf("apple", second + 1);
  assert.equal(click(rendered, "apple", 1).byteColumn, first);
  assert.equal(click(rendered, "apple", 2).byteColumn, second);
  assert.equal(click(rendered, "apple", 3).byteColumn, third);
  assert.notEqual(first, second);
  assert.notEqual(second, third);
});

test("identical text in different blocks resolves to its own block", () => {
  assert.deepEqual(
    [click("Quoted apple and apple again.", "apple", 1),
      click("Quoted apple and apple again.", "apple", 2),
      click("list apple item", "apple"),
      click("nested apple item", "apple"),
      click("ordered apple item", "apple")].map((hit) => [hit.line, hit.byteColumn, hit.precision]),
    [
      [24, line(24).indexOf("apple"), "exact"],
      [24, line(24).indexOf("apple", line(24).indexOf("apple") + 1), "exact"],
      [26, line(26).indexOf("apple"), "exact"],
      [27, line(27).indexOf("apple"), "exact"],
      [29, line(29).indexOf("apple"), "exact"],
    ]
  );
});

test("the same word inside and outside a link resolves to two different columns", () => {
  const inside = click("target", "target");
  const outside = click(" and target outside.", "target");
  assert.equal(inside.line, 15);
  assert.equal(outside.line, 15);
  assert.equal(inside.byteColumn, line(15).indexOf("target"));
  assert.equal(outside.byteColumn, line(15).indexOf("target", line(15).indexOf(") ")));
  assert.notEqual(inside.byteColumn, outside.byteColumn);
});

// ---------------------------------------------------------------------------
// Syntax transformations
// ---------------------------------------------------------------------------

test("every inline construct maps its rendered text back to its own source text", () => {
  const cases = [
    ["heading (ATX)", "Provenance Fixture", "Provenance", 1],
    ["heading (setext)", "Setext Heading", "Setext", 19],
    ["heading (ATX with a closing sequence)", "ATX with closing", "closing", 22],
    ["nested emphasis, outer", "emphasis with ", "emphasis", 9],
    ["nested emphasis, inner", "strong", "strong", 9],
    ["text after nested emphasis", " inside", "inside", 9],
    ["inline code", "code span", "span", 11],
    ["reference link label", "reference link", "link", 13],
    ["autolink", "https://example.org/auto", "example", 13],
    ["blockquote", "Quoted apple and apple again.", "Quoted", 24],
    ["unordered list item", "list apple item", "item", 26],
    ["nested list item", "nested apple item", "nested", 27],
    ["ordered list item", "ordered apple item", "ordered", 29],
    ["table header cell", "Name", "Name", 33],
    ["table body cell", "cell apple", "cell", 35],
    ["hard break, first line", "Hard break line one", "break", 37],
    ["hard break, second line", "and line two after the break.", "after", 38],
    ["backslash break, first line", "Backslash break line one", "break", 40],
    ["backslash break, second line", "and line two after that break.", "after", 41],
    ["tabs beside multibyte", "Mixed\ttab 日本語 and 🎉 emoji here.", "emoji", 50],
  ];
  for (const [label, rendered, needle, expectedLine] of cases) {
    const hit = click(rendered, needle);
    assert.equal(hit.precision, "exact", `${label} did not resolve exactly`);
    assert.equal(hit.line, expectedLine, `${label} resolved to the wrong line`);
    assert.equal(hit.byteColumn, byteColumn(expectedLine, line(expectedLine).indexOf(needle)),
      `${label} resolved to the wrong byte column`);
  }
});

test("entities and escapes keep their own exact positions instead of poisoning the run", () => {
  // `&amp;` is five source characters rendering as one, and `\*` is two
  // rendering as one. Both stay separate runs precisely so the prose around
  // them keeps a 1:1 offset mapping.
  const ampersand = click("&", "&", 1, { onLine: 11 });
  assert.deepEqual([ampersand.line, ampersand.byteColumn, ampersand.precision],
    [11, line(11).indexOf("&amp;"), "exact"]);

  const after = click(" b and escape ", "escape");
  assert.equal(after.byteColumn, line(11).indexOf("escape"),
    "the text after an entity is still exact, five characters further along than the rendered text suggests");

  const star = click("star", "star");
  assert.deepEqual([star.line, star.byteColumn], [11, line(11).indexOf("star")]);
  const trailing = click(".", ".", 1, { onLine: 11 });
  assert.deepEqual([trailing.line, trailing.byteColumn], [11, line(11).lastIndexOf(".")]);
});

test("an entity adjacent to multibyte text does not shift the characters around it", () => {
  const before = click("Entities beside multibyte: 日本語", "日本語");
  assert.deepEqual([before.line, before.byteColumn],
    [17, byteColumn(17, line(17).indexOf("日本語"))]);
  const entity = click("&", "&", 1, { onLine: 17 });
  assert.deepEqual([entity.line, entity.byteColumn], [17, byteColumn(17, line(17).indexOf("&amp;"))]);
  const afterEntity = click("日本語 done.", "done");
  assert.deepEqual([afterEntity.line, afterEntity.byteColumn],
    [17, byteColumn(17, line(17).indexOf("done"))]);
});

test("a fenced code block resolves to a line and column inside the fence", () => {
  const region = Object.values(FIXTURE_MAP.regions).find((entry) => entry.mapping === "lines");
  assert.ok(region, "the fenced block produced no line mapping");
  const id = Object.keys(FIXTURE_MAP.regions).find((key) => FIXTURE_MAP.regions[key] === region);
  // The rendered <pre> text is the fence content verbatim, so an offset into it
  // is an offset into the source lines the fence covers. The fence opens on
  // line 43, so its content is lines 44 and 45.
  const content = `${line(44)}\n${line(45)}\n`;
  assert.equal(region.startLine + 1, 44);

  const greeting = content.indexOf("greeting");
  assert.deepEqual(resolveRegionPosition(FIXTURE_MAP, id, greeting),
    { line: 43, byteColumn: line(44).indexOf("greeting"), precision: "exact" });

  // The second line of the block: an offset that had to cross a newline.
  const print = content.indexOf("print");
  assert.deepEqual(resolveRegionPosition(FIXTURE_MAP, id, print),
    { line: 44, byteColumn: line(45).indexOf("print"), precision: "exact" });

  // Past the end of the block reports its last line rather than running off it.
  const past = resolveRegionPosition(FIXTURE_MAP, id, content.length + 500);
  assert.equal(past.line, 44);
  assert.equal(past.precision, "exact");

  // No caret offset means the block's first content line, never a column.
  assert.deepEqual(resolveRegionPosition(FIXTURE_MAP, id, null),
    { line: 43, byteColumn: 0, precision: "line" });
});

test("an image reports the exact position of the construct that produced it", () => {
  const [id, region] = Object.entries(FIXTURE_MAP.regions).find(([, entry]) => entry.mapping === "point");
  // An image has no rendered text to put a caret in, so a hit on it carries no
  // offset -- and the position is still exact, because the construct's own
  // first character is where it comes from.
  assert.deepEqual(resolveRegionPosition(FIXTURE_MAP, id, null),
    { line: 51, byteColumn: 0, precision: "exact" });
  assert.equal(line(52).slice(region.startCol16, region.startCol16 + 2), "![");
  assert.match(FIXTURE_HTML, new RegExp(`<img[^>]*data-md-source-id="${id}"`));
});

// ---------------------------------------------------------------------------
// Honesty: what must *not* claim to be exact
// ---------------------------------------------------------------------------

test("an auto-linkified bare URL degrades, and only it degrades", () => {
  // markdown-it's core `linkify` rule replaces the text token containing the URL
  // with tokens it builds itself, which carry no recorded span. Rather than
  // re-derive one -- which would mean maintaining a second copy of a markdown-it
  // rule -- the rewritten run reports no provenance at all and the caller falls
  // back to the block. `deriveSpan()` is the documented seam for changing that.
  const url = "http://example.org/bare";
  assert.match(FIXTURE_HTML, new RegExp(`<a href="${url}">${url}</a>`),
    "the bare URL should still render as a link");
  const runs = [...FIXTURE_RUNS.entries()].filter(([, text]) => text.includes(url));
  assert.equal(runs.length, 0, "the linkified run must not claim a source position");

  // Narrowly scoped: the prose on either side of it in the same paragraph is
  // still exact, and so is every other paragraph.
  assert.deepEqual([click("Bare url ", "Bare").line, click("Bare url ", "Bare").byteColumn], [48, 0]);
  const after = click(" inside text.", "inside");
  assert.deepEqual([after.line, after.byteColumn], [48, line(48).indexOf("inside")]);

  // And the fallback a real click gets is the honest block answer, never exact.
  const fallback = resolveSourcePosition({ sourceStart: 47, sourceEnd: 48 }, { sourceId: null, offset: null }, FIXTURE_MAP);
  assert.deepEqual(fallback, { line: 48, byteColumn: 0, precision: "line" });
});

test("a task-list item's text degrades because the plugin re-emits it as raw HTML", () => {
  // markdown-it-task-lists with `labelAfter` discards the item's text token and
  // rebuilds the text inside a raw `html_inline` <label>, so there is no text
  // token left to carry a span. Reported honestly rather than approximated.
  assert.match(FIXTURE_HTML, /<label class="task-list-item-label"> Task apple item<\/label>/);
  assert.equal([...FIXTURE_RUNS.values()].filter((text) => text.includes("Task apple item")).length, 0);
});

test("a region hit without a caret offset reports its line, never a guessed column", () => {
  const run = runByText("Repeated: apple banana apple banana apple");
  assert.deepEqual(resolveRegionPosition(FIXTURE_MAP, run.id, null),
    { line: 6, byteColumn: 0, precision: "line" });
  assert.deepEqual(resolveRegionPosition(FIXTURE_MAP, run.id, Number.NaN),
    { line: 6, byteColumn: 0, precision: "line" });
  // ...and the same hit through the public resolver, which is where the 0-based
  // to 1-based conversion happens.
  assert.deepEqual(resolveSourcePosition(null, { sourceId: run.id, offset: null }, FIXTURE_MAP),
    { line: 7, byteColumn: 0, precision: "line" });
});

test("unknown, forged, and absent region keys resolve to nothing rather than to something", () => {
  for (const id of ["s99999", "", "../etc/passwd", null, undefined, 7]) {
    assert.equal(resolveRegionPosition(FIXTURE_MAP, id, 0), null, `key ${String(id)} resolved`);
  }
  assert.equal(resolveRegionPosition(null, "s1", 0), null);
  assert.equal(resolveRegionPosition({ regions: {} }, "s1", 0), null);
  // A forged key that happens to exist can only ever point somewhere inside the
  // same document's own map -- it cannot manufacture a position out of nothing.
  const forged = resolveSourcePosition({ sourceStart: 0, sourceEnd: 1 }, { sourceId: "s1", offset: 0 }, FIXTURE_MAP);
  assert.ok(forged.line >= 1 && forged.line <= LINES.length);
});

test("multi-line inline code refuses to claim a column", () => {
  // markdown-it rewrites the newline inside `a\nb` to a space, so the rendered
  // run no longer matches any single source line. That is exactly the shape that
  // must not be reported as exact.
  const { html, sourceMap } = render("Text with `split\ncode` inside.\n");
  const runs = renderedRuns(html);
  assert.match(html, /<code[^>]*>split code<\/code>/);
  assert.equal([...runs.entries()].filter(([id, text]) =>
    text === "split code" && sourceMap.regions[id]?.mapping === "identity").length, 0,
  "a code span whose content markdown-it rewrote must not carry an identity mapping");
});

test("an ambiguous line alignment maps to nothing rather than to a plausible guess", () => {
  assert.equal(alignLine("> hello", "hello"), 2, "the common case anchors at the end of the line");
  assert.equal(alignLine("## Heading ##", "Heading"), 3, "a unique interior match is unambiguous");
  assert.equal(alignLine("# a # a #", "a"), null, "two candidates is not an answer");
  assert.equal(alignLine("- item   ", "item"), 2, "trailing whitespace the trim removed is allowed for");
  assert.equal(alignLine("keep  ", "keep  "), 0, "a hard break's own trailing spaces are kept");
  assert.equal(alignLine("nothing here", "absent"), null);
  assert.equal(alignLine("anything", ""), null, "an empty line matches everywhere, so it matches nowhere");
  assert.equal(alignLine(undefined, "x"), null);
});

test("block-only resolution still cannot report exact precision", () => {
  // Unchanged from Part 3: without a region there is no column to report, and a
  // block never becomes one.
  for (let start = 0; start < 40; start += 1) {
    for (let span = 1; span < 12; span += 1) {
      assert.notEqual(resolveSourcePosition({ sourceStart: start, sourceEnd: start + span }).precision, "exact");
    }
  }
  assert.deepEqual(resolveSourcePosition({ sourceStart: 2, sourceEnd: 3 }, null, FIXTURE_MAP),
    { line: 3, byteColumn: 0, precision: "line" });
});

// ---------------------------------------------------------------------------
// Structural guarantees
// ---------------------------------------------------------------------------

test("provenance changes the markup only by adding its own attributes", () => {
  // The tightest possible guard on the two markdown-it rules this module
  // replaces (`fragments_join` and `text_join`): a stock parser and the same
  // parser with provenance installed must produce identical HTML once the added
  // attributes and wrappers are removed. If a markdown-it upgrade changes either
  // rule, this fails rather than the columns silently drifting.
  const strip = (html) => html
    .replace(/<span data-md-source-id="s\d+">([^<]*)<\/span>/g, "$1")
    .replace(/ data-md-source-id="s\d+"/g, "");
  const samples = [fixture, kitchenSink,
    "a *b* **c** ~~d~~ `e` &amp; \\* <https://x.invalid> [f](g) ![h](i)\n",
    "para one  \nbroken\n\n> quote\n\n- x\n- y\n"];
  for (const sample of samples) {
    const stock = new MarkdownIt({ html: false, linkify: true, typographer: false, breaks: false });
    const instrumented = new MarkdownIt({ html: false, linkify: true, typographer: false, breaks: false });
    instrumented.use(provenancePlugin);
    assert.equal(strip(instrumented.render(sample)), stock.render(sample),
      "instrumenting the inline parser changed the rendered output");
  }
});

test("the source map carries keys, never Markdown, into the page", () => {
  // §5.2: ids are opaque. Nothing derived from the document body may appear in
  // an attribute, because attributes are the one part of the map the page sees.
  for (const match of FIXTURE_HTML.matchAll(/data-md-source-id="([^"]*)"/g)) {
    assert.match(match[1], /^s\d+$/, `non-opaque source id: ${match[1]}`);
  }
  // Meanwhile the Node-side map does hold the source, which is what makes the
  // byte conversion possible at all.
  assert.deepEqual(FIXTURE_MAP.lines, normalizeSource(fixture).split("\n"));
  assert.equal(FIXTURE_MAP.version, 1);
});

test("the sanitizer keeps provenance ids and still strips everything else", () => {
  assert.match(FIXTURE_HTML, /<span data-md-source-id="s\d+">/);
  const { html } = renderMarkdown(
    '<span data-md-source-id="s1" onclick="alert(1)" style="x">a</span><script>alert(1)</script>'
    + '<iframe src="x"></iframe><b data-md-source-id="../../etc">b</b>',
    { rawHtml: true, localImages: false, maxLocalImageBytes: 1, baseDir: here, documentRoot: here }
  );
  assert.doesNotMatch(html, /onclick|script|iframe|style=/);
  // A forged id survives sanitization -- it is an ordinary data attribute, the
  // same as data-source-start already was -- and is bounded by resolving only
  // against this document's own map. The `<b>` is not an allowed tag, so its
  // attribute goes with it.
  assert.doesNotMatch(html, /etc/);
});

test("every fixture region points at a real position in the real document", () => {
  for (const [id, region] of Object.entries(FIXTURE_MAP.regions)) {
    const start = region.mapping === "lines" ? region.startLine : region.line;
    assert.ok(Number.isInteger(start) && start >= 0 && start < FIXTURE_MAP.lines.length,
      `${id} points outside the document`);
    if (region.mapping === "identity" || region.mapping === "point") {
      const text = FIXTURE_MAP.lines[start];
      assert.ok(region.startCol16 >= 0 && region.startCol16 <= text.length,
        `${id} points outside line ${start + 1}`);
      assert.ok(region.startCol16 + (region.len16 ?? 0) <= text.length,
        `${id} runs off the end of line ${start + 1}`);
    }
    if (region.mapping === "lines") {
      for (let index = 0; index < region.lengths.length; index += 1) {
        const text = FIXTURE_MAP.lines[start + index];
        assert.equal(region.columns[index] + region.lengths[index], text.length,
          `${id} line ${index} does not cover its source line`);
      }
    }
  }
});

test("deriveSpan is a usable seam for a future span-aware linkify", () => {
  // Nothing calls this in Part 5; it exists so span-aware linkification is an
  // addition rather than a redesign. Tested so it is a real seam, not a comment.
  const md = new MarkdownIt({ html: false, linkify: false });
  md.use(provenancePlugin);
  const tokens = md.parse("hello brave world\n", {});
  const parent = tokens.find((token) => token.type === "inline").children[0];
  const span = spanOf(parent);
  assert.deepEqual([span.start, span.end], [0, "hello brave world".length]);

  const child = new (Object.getPrototypeOf(parent).constructor)("text", "", 0);
  assert.equal(deriveSpan(parent, child, 6, 5), true);
  assert.deepEqual([spanOf(child).start, spanOf(child).end], [6, 11]);
  assert.equal(span.src.slice(6, 11), "brave");
  // A slice that escapes the parent is refused rather than clamped.
  assert.equal(deriveSpan(parent, child, 6, 500), false);
  assert.equal(deriveSpan(parent, child, -1, 2), false);
});

test("installation fails loudly if markdown-it moves the rules it depends on", () => {
  const md = new MarkdownIt();
  const rules = md.inline.ruler.__rules__;
  Object.defineProperty(md.inline.ruler, "__rules__", { value: undefined, configurable: true });
  assert.throws(() => provenancePlugin(md), /no longer exposes __rules__/);
  Object.defineProperty(md.inline.ruler, "__rules__", { value: rules, configurable: true });

  const missing = new MarkdownIt();
  missing.core.ruler.__rules__ = missing.core.ruler.__rules__.filter((rule) => rule.name !== "text_join");
  assert.throws(() => provenancePlugin(missing), /Parser rule not found: text_join/);
});

// ---------------------------------------------------------------------------
// Integration: a real click at a real coordinate in a real browser.
// ---------------------------------------------------------------------------

function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

test("clicking a known character in a real browser yields its exact source column", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const renderer = new BrowserRenderer({ assetsDir });
  t.after(() => renderer.close());
  const cached = { html: FIXTURE_HTML, sourceMap: FIXTURE_MAP };
  const rendered = await renderer.render({
    documentId: "provenance", contentRevision: "1:0",
    viewport: { widthPx: 900, heightPx: 700, deviceScaleFactor: 1 },
    browser: { executable_path: executable, launch_timeout_ms: 10000 },
    theme: "dark", scrollY: 0, network: false, captureScale: "css",
    scrollPastEnd: true, scrollPastEndOffsetPx: 22, fontSizePx: 16,
  }, FIXTURE_HTML, 1);
  fs.unlinkSync(rendered.pngPath);

  let requestId = 1;

  /// Measured points are kept in *document* space. The page holds whatever
  /// scroll position the previous interaction left behind, so a viewport-relative
  /// y measured now would be wrong the moment this request scrolls somewhere
  /// else -- and it would be wrong silently, by landing on a neighbouring line.
  async function interactAt(located, strategy) {
    assert.ok(located, "the target was not found in the rendered document");
    const scrollY = Math.max(0, Math.min(
      Math.round(located.absoluteY - 350), Math.max(0, rendered.documentHeightPx - 700)));
    requestId += 1;
    const result = await renderer.interact({
      documentId: "provenance", contentRevision: "1:0", action: "hit_test",
      coordinates: { x: located.x, y: located.absoluteY - scrollY },
      cellWidthPx: located.cellWidthPx ?? 0, cellHeightPx: 0,
      modifiers: {}, clickCount: 1, strategy, scrollY,
      viewportWidthPx: 900, viewportHeightPx: 700, capture: false, captureScale: "css",
      actionSpec: { mutatesVisibleState: false, requiresCoordinates: true },
    }, cached, requestId);
    return result.sourcePosition;
  }

  /// Aim at one specific character of one specific run, the way an eye does:
  /// take that character's own rectangle and click a quarter of the way into it,
  /// which is unambiguously on its left half and therefore before it.
  async function hit(rendered_, needle, occurrence = 1) {
    const run = runByText(rendered_);
    const located = await renderer.page.evaluate(({ id, text, nth }) => {
      const element = document.querySelector(`[data-md-source-id="${id}"]`);
      if (!element) return null;
      const node = element.firstChild;
      let index = -1;
      for (let i = 0; i < nth; i += 1) index = node.nodeValue.indexOf(text, index + 1);
      if (index < 0) return null;
      const range = document.createRange();
      range.setStart(node, index);
      range.setEnd(node, index + 1);
      const box = range.getBoundingClientRect();
      return {
        x: box.left + box.width / 4,
        absoluteY: box.top + box.height / 2 + window.scrollY,
      };
    }, { id: run.id, text: needle, nth: occurrence });
    assert.ok(located, `could not locate ${JSON.stringify(needle)} in ${JSON.stringify(rendered_)}`);
    return interactAt(located, "auto");
  }

  await t.test("the five operator checks, resolved through the DOM", async () => {
    assert.deepEqual(await hit("bold text", "text"),
      { line: 3, byteColumn: line(3).indexOf("bold text") + 5, precision: "exact" });
    assert.deepEqual(await hit("link label", "label"),
      { line: 3, byteColumn: line(3).indexOf("link label") + 5, precision: "exact" });
    assert.deepEqual(await hit("Unicode line: café 日本語 🎉 done.", "日"),
      { line: 5, byteColumn: byteColumn(5, line(5).indexOf("日本語")), precision: "exact" });
    assert.deepEqual(await hit("Unicode line: café 日本語 🎉 done.", "🎉"),
      { line: 5, byteColumn: byteColumn(5, line(5).indexOf("🎉")), precision: "exact" });
    const second = line(7).indexOf("apple", line(7).indexOf("apple") + 1);
    assert.deepEqual(await hit("Repeated: apple banana apple banana apple", "apple", 2),
      { line: 7, byteColumn: second, precision: "exact" });
  });

  await t.test("a highlighted code block resolves through its syntax spans", async () => {
    const located = await renderer.page.evaluate(() => {
      const pre = [...document.querySelectorAll("pre[data-md-source-id]")][0];
      const walker = document.createTreeWalker(pre, NodeFilter.SHOW_TEXT);
      let consumed = 0;
      let node = walker.nextNode();
      while (node !== null) {
        const index = node.nodeValue.indexOf("print");
        // The word sits inside a highlight.js span, several text nodes in --
        // which is the case a per-node offset would get wrong.
        if (index >= 0) {
          const range = document.createRange();
          range.setStart(node, index);
          range.setEnd(node, index + 1);
          const box = range.getBoundingClientRect();
          return {
            x: box.left + box.width / 4,
            absoluteY: box.top + box.height / 2 + window.scrollY,
            consumed,
          };
        }
        consumed += node.nodeValue.length;
        node = walker.nextNode();
      }
      return null;
    });
    assert.ok(located, "the fenced block did not render with highlight spans");
    assert.ok(located.consumed > 0, "the target text node was not preceded by other nodes");
    assert.deepEqual(await interactAt(located, "auto"),
      { line: 45, byteColumn: line(45).indexOf("print"), precision: "exact" });
  });

  await t.test("a click on the cell holding a line's first character resolves it", async () => {
    // The reported bug: a terminal reports a cell, not a position inside it, so
    // the cell containing the first character of a line also contains the
    // page's left padding. Resolving only that cell's centre lands on the
    // article, reports "none", and the click does nothing -- "I cannot select
    // the first character of a line".
    const located = await renderer.page.evaluate(() => {
      const span = [...document.querySelectorAll("span[data-md-source-id]")]
        .find((node) => node.textContent === "Repeated: apple banana apple banana apple");
      const box = span.getBoundingClientRect();
      const article = document.querySelector(".markdown-body").getBoundingClientRect();
      return {
        textLeft: box.left,
        paddingLeft: box.left - article.left,
        absoluteY: box.top + box.height / 2 + window.scrollY,
      };
    });
    assert.ok(located.paddingLeft > 4, "the fixture has no left padding to straddle; the test proves nothing");

    // A cell wide enough to span the padding *and* the first character, centred
    // in the padding -- exactly the geometry that used to resolve to nothing.
    const cellWidthPx = located.paddingLeft * 1.6;
    const centre = located.textLeft - cellWidthPx * 0.35;

    const withoutCell = await interactAt({ x: centre, absoluteY: located.absoluteY }, "auto");
    assert.deepEqual(withoutCell, { line: null, byteColumn: null, precision: "none" },
      "resolving the centre alone still misses, which is what the cell extent is for");

    const withCell = await interactAt(
      { x: centre, absoluteY: located.absoluteY, cellWidthPx }, "auto");
    assert.deepEqual(withCell, { line: 7, byteColumn: 0, precision: "exact" },
      "the same click, told how wide the cell is, lands on the line's first character");

    // Still bounded: a cell entirely inside the padding finds nothing across
    // its whole width and is still reported honestly rather than snapped to the
    // nearest text. This is the property that keeps it from being the blanket
    // clamping Part 3 refused.
    const deepInPadding = await interactAt(
      { x: Math.max(1, located.textLeft - located.paddingLeft * 3), absoluteY: located.absoluteY, cellWidthPx: 2 },
      "auto");
    assert.equal(deepInPadding.precision, "none", "a cell that is entirely padding still resolves to nothing");
  });

  await t.test("element-only resolution reports the run's line without inventing a column", async () => {
    const located = await renderer.page.evaluate(() => {
      const element = [...document.querySelectorAll("span[data-md-source-id]")]
        .find((node) => node.textContent.startsWith("Repeated: "));
      const box = element.getBoundingClientRect();
      return { x: box.left + box.width / 2, absoluteY: box.top + box.height / 2 + window.scrollY };
    });
    // No caret is consulted at all, so the run is known and the column is not.
    assert.deepEqual(await interactAt(located, "element-only"),
      { line: 7, byteColumn: 0, precision: "line" });
  });
});
