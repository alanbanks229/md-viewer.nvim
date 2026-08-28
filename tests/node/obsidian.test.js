import test from "node:test";
import assert from "node:assert/strict";
import { renderMarkdown } from "../../renderer/src/markdown.js";
import { classifyLink, scrollObsidianAnchorInPage, validateEnvelope } from "../../renderer/src/interact.js";

function hrefs(html) {
  return [...html.matchAll(/<a href="([^"]+)"/g)].map((match) => match[1]);
}

test("wikilinks are opt-in and cover Obsidian note, alias, heading, path and block forms", async () => {
  const source = [
    "[[Note]] [[path/to/Note.md]] [[Note|Label]] [[#Heading]]",
    "[[Note#Parent#Child]] [[Note#^block-id]] [[日本語|表示 🎉]]",
  ].join("\n");
  const disabled = await renderMarkdown(source, { rawHtml: false, localImages: false, obsidianEnabled: false });
  assert.equal(hrefs(disabled.html).length, 0);
  assert.match(disabled.html, /\[\[Note\]\]/);

  const enabled = await renderMarkdown(source, { rawHtml: false, localImages: false, obsidianEnabled: true });
  const links = hrefs(enabled.html).map(classifyLink);
  assert.equal(links.length, 7);
  assert.deepEqual(links.map(({ target, anchor }) => ({ target, anchor })), [
    { target: "Note", anchor: null },
    { target: "path/to/Note.md", anchor: null },
    { target: "Note", anchor: null },
    { target: "", anchor: { kind: "heading", segments: ["Heading"] } },
    { target: "Note", anchor: { kind: "heading", segments: ["Parent", "Child"] } },
    { target: "Note", anchor: { kind: "block", value: "block-id" } },
    { target: "日本語", anchor: null },
  ]);
  assert.match(enabled.html, />Label<\/span><\/a>/, "pipe aliases are the visible text");
  assert.match(enabled.html, />表示 🎉<\/span><\/a>/, "Unicode aliases survive unchanged");
});

test("wikilinks exclude embeds, escapes, code, malformed syntax and explicit non-Markdown targets", async () => {
  const source = [
    String.raw`\[[Escaped]] ![[Embed]] [[image.png]] [[archive.verylongextension]] [[Bad|Alias|Again]] [[Note##Child]]`,
    "`[[InlineCode]]`",
    "```md",
    "[[FencedCode]]",
    "```",
  ].join("\n");
  const { html } = await renderMarkdown(source, { rawHtml: false, localImages: false, obsidianEnabled: true });
  assert.equal(hrefs(html).length, 0);
  assert.match(html.replace(/<[^>]+>/g, ""), /\[\[Escaped\]\]/);
  assert.match(html, /!\[\[Embed\]\]/);
  assert.match(html, /<code[^>]*>\[\[InlineCode\]\]<\/code>/);
  assert.match(html, /\[\[FencedCode\]\]/);
});

test("wikilink labels retain exact source provenance and block ids are hidden but addressable", async () => {
  const source = "Before [[Résumé|café 🎉]] after\n\nAddress me ^exact-id";
  const { html, sourceMap } = await renderMarkdown(source, {
    rawHtml: false, localImages: false, obsidianEnabled: true,
  });
  assert.match(html, /data-md-obsidian-block-id="exact-id"/);
  assert.doesNotMatch(html, /\^exact-id/);
  const label = /<span data-md-source-id="([^"]+)">café 🎉<\/span>/.exec(html);
  assert.ok(label);
  const region = sourceMap.regions[label[1]];
  assert.equal(region.mapping, "identity");
  assert.equal(region.line, 0);
  assert.equal(sourceMap.lines[0].slice(region.startCol16, region.startCol16 + region.len16), "café 🎉");
});

test("renderer-owned wikilink metadata is classified strictly", () => {
  assert.equal(classifyLink("md-viewer-obsidian:not-json").type, "unsafe");
  assert.equal(classifyLink("md-viewer-obsidian:%7B%7D").type, "unsafe");
  const envelope = validateEnvelope({
    documentId: "doc", contentRevision: "1:0", action: "obsidian_scroll",
    viewportWidthPx: 800, viewportHeightPx: 600,
    obsidianAnchor: { kind: "heading", segments: ["Parent", "Child"] },
  });
  assert.deepEqual(envelope.obsidianAnchor, { kind: "heading", segments: ["Parent", "Child"] });
  assert.throws(() => validateEnvelope({
    documentId: "doc", contentRevision: "1:0", action: "obsidian_scroll",
    viewportWidthPx: 800, viewportHeightPx: 600,
    obsidianAnchor: { kind: "block", value: "not valid" },
  }), /block id or non-empty heading path/);
});

test("Obsidian anchors match heading hierarchy case-insensitively and block ids exactly", () => {
  const savedDocument = globalThis.document;
  const savedWindow = globalThis.window;
  const makeHeading = (tagName, textContent, scrollY) => ({
    tagName, textContent,
    scrollIntoView() { globalThis.window.scrollY = scrollY; },
  });
  const headings = [
    makeHeading("H2", "Parent", 100),
    makeHeading("H3", "Wrong child", 140),
    makeHeading("H2", "PARENT", 300),
    makeHeading("H3", "Child", 360),
    makeHeading("H4", "Leaf", 400),
  ];
  const blocks = [
    { getAttribute: () => "Block-ID", scrollIntoView() { globalThis.window.scrollY = 500; } },
  ];
  try {
    globalThis.window = { scrollY: 0 };
    globalThis.document = {
      documentElement: { getAttribute: () => "d1" },
      querySelectorAll(selector) { return selector.startsWith("h1") ? headings : blocks; },
    };
    assert.deepEqual(
      scrollObsidianAnchorInPage({ token: "d1", anchor: { kind: "heading", segments: ["parent", "CHILD", "leaf"] } }),
      { ok: true, found: true, scrollY: 400 }
    );
    assert.deepEqual(
      scrollObsidianAnchorInPage({ token: "d1", anchor: { kind: "block", value: "Block-ID" } }),
      { ok: true, found: true, scrollY: 500 }
    );
    assert.equal(
      scrollObsidianAnchorInPage({ token: "d1", anchor: { kind: "block", value: "block-id" } }).found,
      false,
      "block ids are exact rather than case-folded"
    );
  } finally {
    globalThis.document = savedDocument;
    globalThis.window = savedWindow;
  }
});
