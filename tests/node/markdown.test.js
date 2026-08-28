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
  // the refused source. This fixture's remote image points at a loopback
  // literal deliberately, so it is refused by the destination-safety check
  // with no configuration and -- since a literal IP short-circuits DNS --
  // no real network attempt either, against the real default resolver/fetch.
  assert.doesNotMatch(html, /(?:src|href)="https:\/\/127\.0\.0\.1\/tracker\.png/);
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
  const options = {
    rawHtml: false, localImages: true, maxLocalImageBytes: 1024, baseDir: here, documentRoot: here,
    // A remote image pointed at the cloud-metadata range: refused by the
    // destination-safety check, not by any configuration.
    resolveHost: async () => [{ address: "169.254.169.254", family: 4 }],
  };
  const { html } = await renderMarkdown("![remote](https://internal.example/x.png)\n\n![missing](./nope.png)", options);
  const images = [...html.matchAll(/<img[^>]*>/g)].map((match) => match[0]);
  assert.equal(images.length, 2);
  assert.match(images[0], /md-viewer-image-blocked/);
  assert.match(images[0], /src="data:image\/svg\+xml;base64,/, "the placeholder is an inline SVG, not a hidden blank");
  assert.match(images[0], /title="[^"]*public address/);
  assert.match(images[0], /data-md-source-id="s\d+"/, "a refused image still carries provenance");
  assert.match(images[1], /md-viewer-image-failed/);
  assert.match(images[1], /src="data:image\/svg\+xml;base64,/);
});

test("sanitizes raw HTML even when the override is enabled", async () => {
  const { html } = await renderMarkdown('<img src="https://evil.invalid/a.png" onerror="alert(1)"><iframe src="x"></iframe><script>alert(1)</script>', {
    rawHtml: true, localImages: false, maxLocalImageBytes: 1, baseDir: here, documentRoot: here,
    // Passes the destination-safety check (a stubbed public address) so the
    // refusal below comes from the stubbed fetch actually failing, not from
    // policy -- proving the sanitizer property holds for an attempted-and-failed
    // outcome too, not just a refused one.
    resolveHost: async () => [{ address: "93.184.216.34", family: 4 }],
    fetchImpl: async () => new Response("nope", { status: 404 }),
  });
  assert.doesNotMatch(html, /onerror|iframe|script/);
  // The `<img>` is now parsed into a real image token (renderer/src/raw-image.js)
  // rather than being handed to the sanitizer with its src silently stripped, so
  // it reaches the same resolver `![](...)` does. The property that matters is
  // unchanged and is the same one the kitchen-sink test asserts: the host must
  // never appear anywhere the browser could dereference it. It may appear as
  // inert text inside the placeholder that explains the refusal.
  assert.doesNotMatch(html, /(?:src|href)="https:\/\/evil\.invalid/);
  assert.match(html, /md-viewer-image-failed/);
  assert.match(html, /title="[^"]*evil\.invalid/);
});

test("remote images are fetched and inlined regardless of host -- there is no allowlist", async () => {
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl+Zz8AAAAASUVORK5CYII=", "base64");
  const fetched = [];
  // A stubbed fetch and a stubbed DNS lookup, not a local HTTP server:
  // tests/node/no-listening-port asserts nothing in this repo ever opens a
  // listening socket, and it runs concurrently with this file.
  const fetchImpl = async (url) => { fetched.push(url); return new Response(png, { status: 200 }); };
  const resolveHost = async () => [{ address: "93.184.216.34", family: 4 }];
  const options = { rawHtml: false, localImages: false, maxLocalImageBytes: 1024, baseDir: here, documentRoot: here,
    resolveHost, fetchImpl };
  const { html } = await renderMarkdown(
    "![a](https://first-cdn.example/a.png)\n\n![b](https://second-totally-different-host.example/b.png)", options);
  const images = [...html.matchAll(/<img[^>]*>/g)].map((match) => match[0]);
  assert.equal(images.length, 2);
  assert.match(images[0], /src="data:image\/png;base64,/);
  assert.doesNotMatch(images[0], /md-viewer-image/);
  assert.match(images[1], /src="data:image\/png;base64,/, "a second, unrelated host works too -- there is no allowlist");
  assert.doesNotMatch(images[1], /md-viewer-image/);
  assert.deepEqual(fetched, ["https://first-cdn.example/a.png", "https://second-totally-different-host.example/b.png"],
    "both hosts were contacted -- neither is special-cased");
});

test("arbitrary data-* attributes on raw HTML are stripped -- only named internal keys survive", async () => {
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
