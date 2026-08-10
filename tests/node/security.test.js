import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { isInside, resolveLocalImage, sniffImageType, installNetworkPolicy } from "../../renderer/src/security.js";

const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl+Zz8AAAAASUVORK5CYII=", "base64");

test("rejects traversal, symlink escape, remote URLs, wrong MIME, and oversize files", () => {
  const parent = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-security-"));
  const root = path.join(parent, "root"); fs.mkdirSync(root);
  const good = path.join(root, "good.png"); fs.writeFileSync(good, png);
  const outside = path.join(parent, "outside.png"); fs.writeFileSync(outside, png);
  const link = path.join(root, "escape.png"); fs.symlinkSync(outside, link);
  const fake = path.join(root, "fake.png"); fs.writeFileSync(fake, "not png");
  fs.writeFileSync(path.join(root, "pic.svg"), "<svg xmlns='http://www.w3.org/2000/svg'/>");
  const options = { localImages: true, baseDir: root, documentRoot: root, maxLocalImageBytes: 1024 };
  assert.match(resolveLocalImage("good.png", options).dataUri, /^data:image\/png;base64,/);
  // Every refusal is tagged: "blocked" is a policy decision made without
  // attempting the read, "failed" means the read was attempted and the file
  // was unusable. The label feeds the visible placeholder.
  const refusal = (source, opts = options) => {
    const result = resolveLocalImage(source, opts);
    assert.equal(result.ok, false, `${source} must not resolve`);
    assert.ok(result.label.length > 0, `${source} carries a reason`);
    return result;
  };
  assert.equal(refusal("../outside.png").kind, "blocked");
  assert.equal(refusal("escape.png").kind, "blocked");
  assert.equal(refusal("pic.svg").kind, "blocked");
  assert.equal(refusal("https://example.invalid/x.png").kind, "blocked");
  assert.equal(refusal("//example.invalid/x.png").kind, "blocked");
  assert.equal(refusal("good.png", { ...options, localImages: false }).kind, "blocked");
  assert.equal(refusal("fake.png").kind, "failed");
  assert.equal(refusal("missing.png").kind, "failed");
  assert.equal(refusal("good.png", { ...options, maxLocalImageBytes: 1 }).kind, "failed");
  assert.equal(isInside(root, root), true);
  assert.equal(isInside(root, outside), false);
  fs.rmSync(parent, { recursive: true });
});

test("sniffImageType derives the format from magic bytes alone", () => {
  assert.equal(sniffImageType(png).mime, "image/png");
  assert.equal(sniffImageType(Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10])).mime, "image/jpeg");
  assert.equal(sniffImageType(Buffer.from([0xff, 0xd8, 0x00, 0xe0])), null, "the two-byte JPEG prefix alone is not enough for untrusted bytes");
  assert.equal(sniffImageType(Buffer.from("GIF89a\x01\x00\x01\x00")).mime, "image/gif");
  assert.equal(sniffImageType(Buffer.concat([Buffer.from("RIFF"), Buffer.from([16, 0, 0, 0]), Buffer.from("WEBPVP8 ")])).mime, "image/webp");
  assert.equal(sniffImageType(Buffer.from("plain text")), null);
  assert.equal(sniffImageType(Buffer.from("<svg xmlns='http://www.w3.org/2000/svg'/>")), null, "SVG stays excluded");
});

test("network policy blocks HTTP while allowing in-memory resources", async () => {
  let handler;
  await installNetworkPolicy({ route: async (_pattern, fn) => { handler = fn; } });
  for (const [url, expected] of [["https://example.invalid", "abort"], ["data:image/png;base64,AA==", "continue"], ["about:blank", "continue"]]) {
    let action;
    await handler({ request: () => ({ url: () => url }), abort: async () => { action = "abort"; }, continue: async () => { action = "continue"; } });
    assert.equal(action, expected);
  }
});

test("the network policy cannot be relaxed", async () => {
  // `security.network` once existed as a boolean second parameter here. The
  // stray `true` below sits where that knob used to be: if anyone reintroduces
  // a loosening parameter, this is the tripwire proving https must stay
  // refused no matter what is passed.
  let handler;
  await installNetworkPolicy({ route: async (_pattern, fn) => { handler = fn; } }, true);
  let action;
  await handler({ request: () => ({ url: () => "https://example.invalid/x.png" }), abort: async () => { action = "abort"; }, continue: async () => { action = "continue"; } });
  assert.equal(action, "abort");
});
