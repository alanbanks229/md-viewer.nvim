import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { renderMarkdown } from "../../renderer/src/markdown.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = fs.readFileSync(path.join(here, "../fixtures/kitchen-sink.md"), "utf8");

test("renders all version-one Markdown structures with source maps", async () => {
  const { html, sourceMap } = await renderMarkdown(fixture, { rawHtml: false, localImages: false,
    maxLocalImageBytes: 1024, baseDir: here, documentRoot: here });
  for (const fragment of ["<h1", "<strong>", "<s>", "task-list-item", "<blockquote", "<pre", "<table", "markdown-alert-note"]) {
    assert.match(html, new RegExp(fragment));
  }
  assert.match(html, /data-source-start="0"/);
  assert.doesNotMatch(html, /<script/);
  // The remote image URL must never appear anywhere the browser could
  // dereference it (https hrefs on links are legitimate; an https img src is
  // not). It may appear as inert text: the visible placeholder's title names
  // the refused source.
  assert.doesNotMatch(html, /(?:src|href)="https:\/\/example\.invalid\/tracker\.png/);
  assert.match(html, /md-viewer-image-blocked/);

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

test("images that cannot render become visible placeholders that name the cause", async () => {
  const options = { rawHtml: false, localImages: true, maxLocalImageBytes: 1024, baseDir: here, documentRoot: here };
  const { html } = await renderMarkdown("![remote](https://example.invalid/x.png)\n\n![missing](./nope.png)", options);
  const images = [...html.matchAll(/<img[^>]*>/g)].map((match) => match[0]);
  assert.equal(images.length, 2);
  assert.match(images[0], /md-viewer-image-blocked/);
  assert.match(images[0], /src="data:image\/svg\+xml;base64,/, "the placeholder is an inline SVG, not a hidden blank");
  assert.match(images[0], /title="[^"]*disabled/);
  assert.match(images[0], /data-md-source-id="s\d+"/, "a refused image still carries provenance");
  assert.match(images[1], /md-viewer-image-failed/);
  assert.match(images[1], /src="data:image\/svg\+xml;base64,/);
});

test("sanitizes raw HTML even when the override is enabled", async () => {
  const { html } = await renderMarkdown('<img src="https://evil.invalid/a.png" onerror="alert(1)"><iframe src="x"></iframe><script>alert(1)</script>', {
    rawHtml: true, localImages: false, maxLocalImageBytes: 1, baseDir: here, documentRoot: here,
  });
  assert.doesNotMatch(html, /onerror|iframe|script|evil\.invalid/);
});

test("allowlisted remote images are fetched by Node and inlined as data URIs", async () => {
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl+Zz8AAAAASUVORK5CYII=", "base64");
  const fetched = [];
  // A stubbed fetch, not a local HTTP server: tests/node/no-listening-port
  // asserts nothing in this repo ever opens a listening socket, and it runs
  // concurrently with this file.
  const fetchImpl = async (url) => { fetched.push(url); return new Response(png, { status: 200 }); };
  const options = { rawHtml: false, localImages: false, maxLocalImageBytes: 1024, baseDir: here, documentRoot: here,
    remoteImages: ["img.allowed.example"], fetchImpl };
  const { html } = await renderMarkdown(
    "![in](https://img.allowed.example/a.png)\n\n![out](https://other.example/b.png)", options);
  const images = [...html.matchAll(/<img[^>]*>/g)].map((match) => match[0]);
  assert.equal(images.length, 2);
  assert.match(images[0], /src="data:image\/png;base64,/);
  assert.doesNotMatch(images[0], /md-viewer-image/);
  assert.match(images[1], /md-viewer-image-blocked/, "a host outside the allowlist is refused");
  assert.deepEqual(fetched, ["https://img.allowed.example/a.png"], "only the allowlisted host is ever contacted");
});

test("arbitrary data-* attributes on raw HTML are stripped -- only the four provenance keys survive", async () => {
  const { html } = await renderMarkdown(
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

test("javascript:, data:, and vbscript: links never survive sanitization even as raw HTML", async () => {
  const { html } = await renderMarkdown(
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
