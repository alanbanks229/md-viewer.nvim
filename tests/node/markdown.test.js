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

  // Part 5 filled `sourceMap` in. It is the provenance record for this render:
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
