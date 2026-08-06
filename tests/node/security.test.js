import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { isInside, localImageDataUri, installNetworkPolicy } from "../../renderer/src/security.js";

const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl+Zz8AAAAASUVORK5CYII=", "base64");

test("rejects traversal, symlink escape, remote URLs, wrong MIME, and oversize files", () => {
  const parent = fs.mkdtempSync(path.join(os.tmpdir(), "md-viewer-security-"));
  const root = path.join(parent, "root"); fs.mkdirSync(root);
  const good = path.join(root, "good.png"); fs.writeFileSync(good, png);
  const outside = path.join(parent, "outside.png"); fs.writeFileSync(outside, png);
  const link = path.join(root, "escape.png"); fs.symlinkSync(outside, link);
  const fake = path.join(root, "fake.png"); fs.writeFileSync(fake, "not png");
  const options = { localImages: true, baseDir: root, documentRoot: root, maxLocalImageBytes: 1024 };
  assert.match(localImageDataUri("good.png", options), /^data:image\/png;base64,/);
  assert.equal(localImageDataUri("../outside.png", options), null);
  assert.equal(localImageDataUri("escape.png", options), null);
  assert.equal(localImageDataUri("fake.png", options), null);
  assert.equal(localImageDataUri("https://example.invalid/x.png", options), null);
  assert.equal(localImageDataUri("good.png", { ...options, maxLocalImageBytes: 1 }), null);
  assert.equal(isInside(root, root), true);
  assert.equal(isInside(root, outside), false);
  fs.rmSync(parent, { recursive: true });
});

test("network policy blocks HTTP while allowing in-memory resources", async () => {
  let handler;
  await installNetworkPolicy({ route: async (_pattern, fn) => { handler = fn; } }, false);
  for (const [url, expected] of [["https://example.invalid", "abort"], ["data:image/png;base64,AA==", "continue"], ["about:blank", "continue"]]) {
    let action;
    await handler({ request: () => ({ url: () => url }), abort: async () => { action = "abort"; }, continue: async () => { action = "continue"; } });
    assert.equal(action, expected);
  }
});
