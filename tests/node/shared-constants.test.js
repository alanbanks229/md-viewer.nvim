import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { sharedConstants, scanCodes } from "../../scripts/dump-shared-constants.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const fixturePath = path.join(here, "../fixtures/shared-constants.json");

// `tests/fixtures/shared-constants.json` is the committed agreement between
// the two languages: the Node side emits it from the modules that own the
// values, and `tests/lua/cases/shared_constants.lua` asserts Lua matches. This
// file is the third leg -- it fails when the renderer changes one of them and
// the fixture was not regenerated, so the Lua case is never comparing against
// a stale copy of what this side believes.

test("the committed fixture matches the values the renderer defines now", () => {
  const committed = JSON.parse(fs.readFileSync(fixturePath, "utf8"));
  assert.deepEqual(
    committed,
    sharedConstants(),
    "run `node scripts/dump-shared-constants.js` and commit the result",
  );
});

test("every response code the renderer can emit is in the fixture", () => {
  const committed = JSON.parse(fs.readFileSync(fixturePath, "utf8"));
  assert.deepEqual(committed.codes, scanCodes());
  // A guard on the scan itself: it is a regex over the sources, and a scan
  // that silently found nothing would make the whole check vacuous.
  assert.ok(committed.codes.length >= 7, "the code scan found the codes that exist today");
  assert.ok(committed.codes.includes("STALE_INTERACTION"));
  assert.ok(committed.codes.includes("REGION_TOO_LARGE"));
});
