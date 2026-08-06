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
  // Part 5 fills this in; the field exists now so the plumbing is already there.
  assert.equal(sourceMap, null);
  for (const fragment of ["<h1", "<strong>", "<s>", "task-list-item", "<blockquote", "<pre", "<table", "markdown-alert-note"]) {
    assert.match(html, new RegExp(fragment));
  }
  assert.match(html, /data-source-start="0"/);
  assert.doesNotMatch(html, /<script/);
  assert.doesNotMatch(html, /https:\/\/example\.invalid\/tracker\.png/);
});

test("sanitizes raw HTML even when the override is enabled", () => {
  const { html } = renderMarkdown('<img src="https://evil.invalid/a.png" onerror="alert(1)"><iframe src="x"></iframe><script>alert(1)</script>', {
    rawHtml: true, localImages: false, maxLocalImageBytes: 1, baseDir: here, documentRoot: here,
  });
  assert.doesNotMatch(html, /onerror|iframe|script|evil\.invalid/);
});
