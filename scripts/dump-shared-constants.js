// Emits `tests/fixtures/shared-constants.json`: the constants both sides of
// the protocol have to agree on, taken from the Node side, which owns them.
//
//   node scripts/dump-shared-constants.js
//
// Every value here is duplicated in Lua, and nothing made the duplication
// checkable: the viewport clamps are a comment in `coordinates.lua` citing
// line numbers in `browser.js`, the region ceilings are two literals written
// twice, and the response codes are string literals compared against string
// literals across a process boundary. A drift in any of them is silent --
// the wrong scale, a refusal that is never recognised, a handshake that
// half-works.
//
// The numbers are imported from the modules that define them, so this file
// cannot drift from the code by being edited. The response codes have no
// registry to import -- they are assigned at their throw sites -- so they are
// scanned out of `renderer/src`, which is the same thing one step removed:
// adding a code to the renderer changes this fixture, and a Lua site matching
// on a code that is no longer here fails the Lua case.
//
// `tests/node/shared-constants.test.js` fails if the committed fixture and the
// live values disagree, so regenerating is a step in a change, never a fixup.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  MAX_REGION_PIXELS,
  MAX_REGION_HEIGHT_PX,
  VIEWPORT_BOUNDS,
  DEVICE_SCALE_FACTOR_BOUNDS,
} from "../renderer/src/browser.js";
import { MAX_MARKER_BYTES } from "../renderer/src/local/markers.js";
import { LOCAL_PROTOCOL } from "../renderer/src/local/version.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(here);

const CODE_PATTERN = /"((?:REGION|STALE|INTERACT)_[A-Z_]+)"/g;

/// Every response/error code the renderer can put on the wire, scanned out of
/// its own source. Sorted, so the fixture is stable across filesystem order.
export function scanCodes(sourceRoot = path.join(root, "renderer/src")) {
  const found = new Set();
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith(".js")) {
        for (const match of fs.readFileSync(full, "utf8").matchAll(CODE_PATTERN)) found.add(match[1]);
      }
    }
  };
  walk(sourceRoot);
  return [...found].sort();
}

export function sharedConstants() {
  return {
    generated_by: "scripts/dump-shared-constants.js",
    viewport: {
      min_width_px: VIEWPORT_BOUNDS.minWidthPx,
      max_width_px: VIEWPORT_BOUNDS.maxWidthPx,
      min_height_px: VIEWPORT_BOUNDS.minHeightPx,
      max_height_px: VIEWPORT_BOUNDS.maxHeightPx,
      default_width_px: VIEWPORT_BOUNDS.defaultWidthPx,
      default_height_px: VIEWPORT_BOUNDS.defaultHeightPx,
    },
    device_scale_factor: {
      min: DEVICE_SCALE_FACTOR_BOUNDS.min,
      max: DEVICE_SCALE_FACTOR_BOUNDS.max,
      default: DEVICE_SCALE_FACTOR_BOUNDS.default,
    },
    region: {
      max_region_pixels: MAX_REGION_PIXELS,
      max_region_height_px: MAX_REGION_HEIGHT_PX,
    },
    local: {
      protocol_version: LOCAL_PROTOCOL,
      max_marker_bytes: MAX_MARKER_BYTES,
    },
    codes: scanCodes(),
  };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const target = path.join(root, "tests/fixtures/shared-constants.json");
  fs.writeFileSync(target, `${JSON.stringify(sharedConstants(), null, 2)}\n`);
  process.stdout.write(`wrote ${target}\n`);
}
