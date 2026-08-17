import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { renderMarkdown } from "../../renderer/src/markdown.js";

const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl+Zz8AAAAASUVORK5CYII=", "base64");

function optionsFor(root) {
  return { rawHtml: false, localImages: true, maxLocalImageBytes: 1024 * 1024, baseDir: root, documentRoot: root };
}

test("reports every file-shaped image source with its outcome, in document order", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-assets-"));
  fs.writeFileSync(path.join(root, "good.png"), png);
  const markdown = [
    "![present](good.png)",
    "![missing](images/missing.png)",
    "![escape](../outside.png)",
    "![remote](https://example.invalid/x.png)",
    "![inline](data:image/png;base64,AA==)",
    "![fileurl](file:///etc/motd.png)",
    "![protorel](//example.invalid/y.png)",
    "![again](images/missing.png)",
  ].join("\n\n");
  const rendered = await renderMarkdown(markdown, optionsFor(root));
  // https, data:, file: and protocol-relative sources are not mirror
  // candidates and stay out; the duplicate reference dedupes to one entry.
  assert.deepEqual(rendered.localImageAssets, [
    { source: "good.png", ok: true },
    { source: "images/missing.png", ok: false },
    { source: "../outside.png", ok: false },
  ]);
  fs.rmSync(root, { recursive: true });
});

test("a raw <img> tag is reported exactly like markdown image syntax", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-assets-"));
  // rawHtml stays false: the raw-image plugin converts a bare <img> into a
  // real image token in both modes, so the report must cover it in both too.
  const rendered = await renderMarkdown('before <img src="raw/pic.png"> after', optionsFor(root));
  assert.deepEqual(rendered.localImageAssets, [{ source: "raw/pic.png", ok: false }]);
  fs.rmSync(root, { recursive: true });
});

test("sources are reported as written, percent-encoding intact", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-assets-"));
  fs.writeFileSync(path.join(root, "my pic.png"), png);
  const rendered = await renderMarkdown("![spaced](my%20pic.png)", optionsFor(root));
  // The resolver decodes to find the file; the report does not, because the
  // Lua side re-derives the decode itself rather than trusting one it cannot
  // inspect.
  assert.deepEqual(rendered.localImageAssets, [{ source: "my%20pic.png", ok: true }]);
  fs.rmSync(root, { recursive: true });
});

test("the report is capped and the markup does not change shape past the cap", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-assets-"));
  const lines = [];
  for (let i = 0; i < 140; i += 1) lines.push(`![m${i}](missing-${i}.png)`);
  const rendered = await renderMarkdown(lines.join("\n\n"), optionsFor(root));
  assert.equal(rendered.localImageAssets.length, 128);
  assert.deepEqual(rendered.localImageAssets[0], { source: "missing-0.png", ok: false });
  // Past the cap the image itself still renders its placeholder -- only the
  // report of it is dropped.
  const placeholders = rendered.html.match(/md-viewer-image-failed/g) ?? [];
  assert.equal(placeholders.length, 140);
  fs.rmSync(root, { recursive: true });
});

test("a document with no file-shaped images reports an empty list and unchanged markup", async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-assets-"));
  const markdown = "# Title\n\nplain *text* and a [link](https://example.invalid)\n";
  const first = await renderMarkdown(markdown, optionsFor(root));
  assert.deepEqual(first.localImageAssets, []);
  // The recording pass must be invisible in the rendered document: same
  // input, same bytes out.
  const second = await renderMarkdown(markdown, optionsFor(root));
  assert.equal(first.html, second.html);
  fs.rmSync(root, { recursive: true });
});
