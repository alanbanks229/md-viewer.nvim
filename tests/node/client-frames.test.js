// The two things a client-rendered frame does differently: it comes back as a
// reference instead of a path, and it stops re-sending block geometry that has
// not changed.
//
// Both are measured here against the real renderer rather than asserted in
// principle, because both are about *size*. The reference path is worth having
// only if the response is small, and the block elision is worth having only if
// the blocks were big -- on this project's own README they are ~10KB on every
// single frame of a scroll, which would have quietly become the largest thing
// crossing the link once the pixels stopped.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createService } from "../../renderer/src/service.js";
import { createFrameStore } from "../../renderer/src/frames.js";
import { discoverChromium } from "../../renderer/src/browser-discovery.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const assetsDir = path.resolve(here, "../../renderer/assets");

function findRealChromium() {
  try {
    return discoverChromium(process.platform, process.env, fs.existsSync, {}).executable;
  } catch {
    return null;
  }
}

const MARKDOWN = ["# Title", "", "Some prose with `code` and a [link](https://example.com).", ""]
  .concat(Array.from({ length: 40 }, (_, index) => `## Section ${index}\n\nParagraph ${index} body text.\n`))
  .join("\n");

function renderRequest(executable, id, overrides = {}) {
  return {
    id,
    method: overrides.method ?? "render",
    params: {
      documentId: "client-doc",
      markdown: MARKDOWN,
      contentRevision: "1:0",
      baseDir: here,
      documentRoot: here,
      viewport: { widthPx: 400, heightPx: 300, deviceScaleFactor: 1 },
      scrollY: 0,
      theme: "dark",
      rawHtml: false,
      localImages: false,
      maxLocalImageBytes: 1024,
      browser: { executable_path: executable, launch_timeout_ms: 20000 },
      ...overrides.params,
    },
  };
}

test("a referenced frame carries no pixels in the response and no file on disk", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const frames = createFrameStore();
  const service = createService({ assetsDir, frames });
  t.after(() => service.close());

  const byPath = await service.dispatch(renderRequest(executable, 1));
  assert.equal(typeof byPath.pngPath, "string", "the default is unchanged: a path to a file");
  assert.equal(byPath.frameRef, undefined);
  assert.equal(fs.existsSync(byPath.pngPath), true);
  fs.unlinkSync(byPath.pngPath);

  // Both halves together, which is how a client-rendering session actually
  // asks: the frame by reference, and the block geometry it already holds left
  // out. Either one alone leaves kilobytes on the wire -- measured at 6,542
  // bytes with the reference but without the elision, which is why this asks
  // for both rather than assuming the reference was the whole cost.
  const byRef = await service.dispatch(
    renderRequest(executable, 2, {
      method: "capture",
      params: { frameTransport: "ref", knownBlocksRevision: byPath.blocksRevision },
    })
  );
  assert.equal(byRef.pngPath, null, "no temp file is written for a frame that never leaves this machine");
  assert.equal(typeof byRef.frameRef, "string");
  assert.equal(byRef.pngData, undefined, "the bytes go to the store, never into the response");
  assert.equal(byRef.pngBytes > 0, true);
  assert.equal(byRef.pngWidth > 0, true, "the Lua side cannot read the PNG header, so the size must be told to it");
  assert.equal(byRef.pngHeight > 0, true);

  // The reference resolves to a real PNG of exactly the announced size.
  const bytes = frames.get(byRef.frameRef);
  assert.equal(bytes.length, byRef.pngBytes);
  assert.equal(bytes.subarray(1, 4).toString("latin1"), "PNG");
  assert.equal(bytes.readUInt32BE(16), byRef.pngWidth);
  assert.equal(bytes.readUInt32BE(20), byRef.pngHeight);

  // The whole point, stated as the number it has to be: a response measured in
  // hundreds of bytes where the frame it describes is measured in hundreds of
  // kilobytes.
  const wire = Buffer.byteLength(JSON.stringify(byRef));
  assert.equal(wire < 2048, true, `a referenced render response was ${wire} bytes`);
  assert.equal(byRef.pngBytes > wire * 4, true, "and it is a small fraction of the frame it stands for");
});

test("block geometry is sent once and then only when it changes", async (t) => {
  const executable = findRealChromium();
  if (!executable) {
    t.skip("no approved Chrome, Chromium, or Edge executable found on this platform");
    return;
  }
  const service = createService({ assetsDir, frames: createFrameStore() });
  t.after(() => service.close());

  const first = await service.dispatch(renderRequest(executable, 1));
  assert.equal(Array.isArray(first.blocks), true, "a client that has said nothing gets the blocks");
  assert.equal(typeof first.blocksRevision, "string");
  const blocksBytes = Buffer.byteLength(JSON.stringify(first.blocks));

  const again = await service.dispatch(
    renderRequest(executable, 2, {
      method: "capture",
      params: { scrollY: 200, knownBlocksRevision: first.blocksRevision },
    })
  );
  assert.equal(again.blocks, undefined, "scrolling does not change the layout, so nothing is re-sent");
  assert.equal(again.blocksRevision, first.blocksRevision, "and the revision says which set is still current");
  assert.equal(blocksBytes > 2000, true, `blocks were only ${blocksBytes} bytes; this test proves nothing`);

  // A stale revision is answered with the current geometry rather than with
  // silence -- the client asking with the wrong one is exactly the client that
  // needs them.
  const stale = await service.dispatch(
    renderRequest(executable, 3, { method: "capture", params: { knownBlocksRevision: "not-the-one" } })
  );
  assert.equal(Array.isArray(stale.blocks), true);
  assert.equal(stale.blocksRevision, first.blocksRevision);

  // Changing the content changes the layout, so the revision must move even
  // though the client is asking with what was current a moment ago.
  const edited = await service.dispatch(
    renderRequest(executable, 4, {
      params: {
        markdown: `${MARKDOWN}\n\n## One more section\n\nAnd more text.\n`,
        contentRevision: "2:0",
        knownBlocksRevision: first.blocksRevision,
      },
    })
  );
  assert.notEqual(edited.blocksRevision, first.blocksRevision);
  assert.equal(Array.isArray(edited.blocks), true);
});

test("a renderer with no frame store refuses the reference path by name", async (t) => {
  // The stdio child renders on the machine Neovim is on, so a reference would
  // name bytes on the machine that cannot use them. Refusing loudly beats
  // answering with a response that has neither a path nor a reference in it.
  const service = createService({ assetsDir });
  t.after(() => service.close());
  await assert.rejects(
    () => service.dispatch({ id: 1, method: "capture", params: { documentId: "d", frameTransport: "ref" } }),
    (error) => {
      assert.equal(error.code, "NO_FRAME_STORE");
      assert.match(error.message, /frame store/);
      return true;
    }
  );
});

test("a disconnecting session's frames are not left for the next one", async (t) => {
  const frames = createFrameStore();
  const service = createService({ assetsDir, frames });
  t.after(() => service.close());
  const ref = frames.put(Buffer.from("frame"));
  assert.notEqual(frames.get(ref), null);
  service.forgetAll();
  assert.equal(frames.get(ref), null, "references are per-connection, like the document cache they travel with");
});
