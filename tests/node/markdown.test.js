import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { renderMarkdown } from "../../renderer/src/markdown.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = fs.readFileSync(path.join(here, "../fixtures/kitchen-sink.md"), "utf8");

test("renders all version-one Markdown structures with source maps", () => {
  const { html, sourceMap } = renderMarkdown(fixture, { rawHtml: false, localImages: false,
    maxLocalImageBytes: 1024, baseDir: here, documentRoot: here });
  for (const fragment of ["<h1", "<strong>", "<s>", "task-list-item", "<blockquote", "<pre", "<table", "markdown-alert-note"]) {
    assert.match(html, new RegExp(fragment));
  }
  assert.match(html, /data-source-start="0"/);
  assert.doesNotMatch(html, /<script/);
  assert.doesNotMatch(html, /https:\/\/example\.invalid\/tracker\.png/);

  // `sourceMap` is the provenance record for this render:
  // the normalized source lines plus one entry per opaque id in the markup, and
  // it never leaves Node. See tests/node/source-provenance.test.js for what the
  // entries actually claim.
  assert.equal(sourceMap.version, 1);
  assert.deepEqual(sourceMap.lines, fixture.split("\n"));
  const ids = new Set([...html.matchAll(/data-md-source-id="([^"]+)"/g)].map((match) => match[1]));
  assert.ok(ids.size > 0, "no provenance ids reached the markup");
  for (const id of ids) assert.ok(sourceMap.regions[id], `markup carries id ${id} with no region behind it`);
});

test("sanitizes raw HTML even when the override is enabled", () => {
  const { html } = renderMarkdown('<img src="https://evil.invalid/a.png" onerror="alert(1)"><iframe src="x"></iframe><script>alert(1)</script>', {
    rawHtml: true, localImages: false, maxLocalImageBytes: 1, baseDir: here, documentRoot: here,
  });
  assert.doesNotMatch(html, /onerror|iframe|script|evil\.invalid/);
});

test("arbitrary data-* attributes on raw HTML are stripped -- only the four provenance keys survive", () => {
  const { html } = renderMarkdown(
    '<div data-foo="bar" data-onclick="evil()" data-md-source-id="forged" data-source-start="99">x</div>',
    { rawHtml: true, localImages: false, maxLocalImageBytes: 1, baseDir: here, documentRoot: here }
  );
  // `data-md-source-id`/`data-source-start` are allowed *keys* by design (see
  // markdown.js's allowedAttributes comment: the worst a rawHtml document can
  // do by forging one is send its own click somewhere else in itself), so
  // this only asserts that keys outside that named set never survive.
  assert.doesNotMatch(html, /data-foo/);
  assert.doesNotMatch(html, /data-onclick/);
});

test("javascript:, data:, and vbscript: links never survive sanitization even as raw HTML", () => {
  const { html } = renderMarkdown(
    '<a href="javascript:alert(1)">a</a>'
    + '<a href="JaVaScRiPt:alert(1)">b</a>'
    + '<a href="vbscript:msgbox(1)">c</a>'
    + '<a href="data:text/html,<script>alert(1)</script>">d</a>'
    + '<a href="//evil.invalid/x">e</a>',
    { rawHtml: true, localImages: false, maxLocalImageBytes: 1, baseDir: here, documentRoot: here }
  );
  assert.doesNotMatch(html, /href="[^"]*(javascript|vbscript):/i);
  assert.doesNotMatch(html, /href="data:/i);
  assert.doesNotMatch(html, /href="\/\/evil\.invalid/i, "protocol-relative hrefs are stripped, not just blocked at fetch time");
});
