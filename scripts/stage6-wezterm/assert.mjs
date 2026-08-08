// Stage-6 WezTerm geometry assertions. Reads the screenshots run.sh took and
// the expectations probe.lua computed, and answers the stage's question
// numerically instead of by eye.
//
//   node assert.mjs <out-dir>
//
// The question is prompt check 3's: does a highlight bar wider than one cell,
// placed with a non-zero sub-cell X, draw as one solid rectangle, or as a comb
// of stripes with a gap at every cell boundary? "Contiguity" below is the
// falsifiable form of that -- a comb has unpainted columns strictly inside the
// bar's own bounding box, and a correct placement has none.
import fs from "node:fs";
import path from "node:path";
import { decodePngPixels, pixelAt } from "../../tests/node/helpers/decode-png.mjs";

const out = process.argv[2];
if (!out) {
  console.error("usage: assert.mjs <out-dir>");
  process.exit(2);
}
const expect = JSON.parse(fs.readFileSync(path.join(out, "expectations.json"), "utf8"));

let failures = 0;
let checks = 0;
function check(ok, label, detail) {
  checks += 1;
  if (ok) {
    console.log(`  ok   ${label}`);
  } else {
    failures += 1;
    console.log(`  FAIL ${label}${detail ? `\n         ${detail}` : ""}`);
  }
  return ok;
}

const hex = expect.fiducial.replace("#", "");
const FID = {
  r: parseInt(hex.slice(0, 2), 16),
  g: parseInt(hex.slice(2, 4), 16),
  b: parseInt(hex.slice(4, 6), 16),
};
// Screenshots come back through the display's colour profile, so an exact
// match on a saturated colour is not safe to assume. The fiducial is pure
// magenta against a black terminal, which survives any sane profile as
// "red and blue high, green low".
const isFiducial = (p) => p.r > 150 && p.b > 150 && p.g < 110;

const BASE = expect.base;
const near = (a, b, slack) => Math.abs(a - b) <= slack;
const isBaseGrey = (p) =>
  near(p.r, expect.base_rgb.r, 6) && near(p.g, expect.base_rgb.g, 6) && near(p.b, expect.base_rgb.b, 6);

/// The longest unbroken run of matching pixels along rows or columns, searched
/// from `from` onward on the scanning axis. Returns { start, length, at } in
/// pixel coordinates of the axis it ran along.
function longestRun(image, matches, axis, from) {
  const outer = axis === "row" ? image.height : image.width;
  const inner = axis === "row" ? image.width : image.height;
  let best = null;
  for (let o = axis === "row" ? from : 0; o < outer; o += 1) {
    let runStart = -1;
    for (let i = axis === "row" ? 0 : from; i <= inner; i += 1) {
      const on =
        i < inner && matches(axis === "row" ? pixelAt(image, i, o) : pixelAt(image, o, i));
      if (on && runStart < 0) runStart = i;
      else if (!on && runStart >= 0) {
        if (!best || i - runStart > best.length) best = { start: runStart, length: i - runStart, at: o };
        runStart = -1;
      }
    }
  }
  return best;
}

/// The content origin and the device-pixel cell size, read out of one image
/// rather than computed from window arithmetic -- and recomputed for *every*
/// screenshot, because the window was observed to move between captures when
/// macOS raised it.
///
/// The magenta row locates the window; the base image supplies the numbers.
/// It is the better ruler of the two: it is a known rectangle of cells, 90 x 24
/// of them, so dividing its measured size gives a cell far more precisely than
/// a one-cell-tall strip could. The fiducial row is then a cross-check.
///
/// The strip deliberately is not trusted for the cell *width*: grid cell (0, 0)
/// holds the terminal cursor, which paints over the fiducial there, so the run
/// is one cell short and starts one cell in.
function registration(image) {
  let strip = null;
  for (let y = 0; y < image.height; y += 1) {
    let runStart = -1;
    for (let x = 0; x <= image.width; x += 1) {
      const on = x < image.width && isFiducial(pixelAt(image, x, y));
      if (on && runStart < 0) runStart = x;
      else if (!on && runStart >= 0) {
        const run = { y, x: runStart, width: x - runStart };
        if (!strip || run.width > strip.width) strip = run;
        runStart = -1;
      }
    }
  }
  // (columns - 1) cells wide at minimum, and a cell is at least the size
  // TIOCGWINSZ reported. Anything shorter is something else magenta on the
  // desktop: a 128px run off a wallpaper was accepted as a 1.28px cell before
  // this bound existed, and every downstream number was quietly nonsense.
  const minimumRun = (expect.columns - 1) * expect.cell_floor.width * 0.9;
  if (!strip || strip.width < minimumRun) return null;

  let stripTop = strip.y;
  while (stripTop > 0 && isFiducial(pixelAt(image, strip.x + 2, stripTop - 1))) stripTop -= 1;
  let stripBottom = strip.y;
  while (stripBottom + 1 < image.height && isFiducial(pixelAt(image, strip.x + 2, stripBottom + 1))) stripBottom += 1;

  // The base image, found the same way as the strip: by its longest run.
  //
  // A bounding box over every base-coloured pixel does not work -- the search
  // band reaches past the bottom of the window and other windows on the desktop
  // are grey too, which stretched the "base" to 1652 px tall. BASE.cols cells of
  // contiguous exact grey is not something else a desktop produces.
  //
  // The two axes are measured independently, and that is deliberate: in the
  // overlaid phase the highlight rectangles interrupt some rows and some
  // columns, but not all of either, so the longest run on each axis is still
  // the base image's true extent. Walking out from one point would stop at the
  // first rectangle it met.
  const widest = longestRun(image, isBaseGrey, "row", stripBottom + 1);
  const tallest = longestRun(image, isBaseGrey, "column", stripBottom + 1);
  if (!widest || widest.length < BASE.cols * expect.cell_floor.width * 0.9) return null;
  if (!tallest || tallest.length < BASE.rows * expect.cell_floor.height * 0.9) return null;
  const left = widest.start;
  const right = widest.start + widest.length - 1;
  const top = tallest.start;
  const bottom = tallest.start + tallest.length - 1;

  const cellWidth = (right - left + 1) / BASE.cols;
  const cellHeight = (bottom - top + 1) / BASE.rows;
  return {
    originX: left - BASE.col * cellWidth,
    originY: top - BASE.row * cellHeight,
    cellWidth,
    cellHeight,
    base: { left, right, top, bottom },
    strip: { x: strip.x, width: strip.width, top: stripTop, bottom: stripBottom },
  };
}

function load(phase) {
  const file = path.join(out, `phase-${phase}.png`);
  if (!fs.existsSync(file)) {
    console.error(`missing ${file}`);
    process.exit(1);
  }
  return decodePngPixels(fs.readFileSync(file));
}

const phases = [1, 2, 3].map((phase) => {
  const image = load(phase);
  const reg = registration(image);
  if (!reg) {
    console.error(
      `no window found in phase-${phase}.png.\n` +
        "The usual cause is macOS Screen Recording permission: without it,\n" +
        "screencapture returns the desktop with no windows in it."
    );
    process.exit(1);
  }
  return { phase, image, reg };
});
const [baseFrame, overlayFrame, clearedFrame] = phases;
const base = baseFrame.image;
const overlaid = overlayFrame.image;
const cleared = clearedFrame.image;
const reg = baseFrame.reg;

/// Content-relative (x, y) -> device pixel, in whichever phase's screenshot.
const at = (frame, x, y) => ({
  x: Math.round(frame.reg.originX + x),
  y: Math.round(frame.reg.originY + y),
});

console.log(`WezTerm ${expect.wezterm}`);
console.log(`grid ${expect.columns}x${expect.rows}, screenshot ${base.width}x${base.height}`);
for (const { phase, reg: r } of phases) {
  console.log(
    `  phase ${phase}: content origin (${r.originX}, ${r.originY}), ` +
      `cell ${r.cellWidth}x${r.cellHeight} device px, base image ${r.base.left}..${r.base.right}`
  );
}
console.log(
  `cell: ioctl says ${expect.cell_from_ioctl.width}x${expect.cell_from_ioctl.height}, ` +
    `pixels say ${reg.cellWidth}x${reg.cellHeight}`
);
console.log(`overlay_supported: ${expect.overlay_supported} (${expect.overlay_reason})\n`);

// --- registration -----------------------------------------------------------
// If a placement pixel is not a device pixel, every geometry number below is
// measuring the wrong thing, so this is asserted before anything else.
const scaleX = reg.cellWidth / expect.cell_floor.width;
const scaleY = reg.cellHeight / expect.cell_floor.height;
check(
  Math.abs(scaleX - 1) < 0.01 && Math.abs(scaleY - 1) < 0.01,
  "TIOCGWINSZ's cell is the device-pixel cell (a placement pixel is a screen pixel)",
  `measured ${reg.cellWidth}x${reg.cellHeight} device px against ioctl's ` +
    `${expect.cell_floor.width}x${expect.cell_floor.height}; scale ${scaleX.toFixed(3)}x${scaleY.toFixed(3)}`
);
check(
  Number.isInteger(reg.cellWidth) && expect.cell_from_ioctl.width === expect.cell_floor.width,
  "the cell is a whole number of pixels, so WezTerm's integer cell arithmetic loses nothing",
  `ioctl ${expect.cell_from_ioctl.width}x${expect.cell_from_ioctl.height}, measured ${reg.cellWidth}`
);

const corner = expect.fiducial_corner;
const cornerAt = at(baseFrame, corner.col * reg.cellWidth, corner.row * reg.cellHeight);
check(
  isFiducial(pixelAt(base, cornerAt.x + 1, cornerAt.y + 1)),
  "the far-corner fiducial lands where the cell pitch predicts, across the whole grid",
  `expected a mark at (${cornerAt.x}, ${cornerAt.y})`
);
check(
  near(reg.strip.top, reg.originY, 1) && near(reg.strip.bottom - reg.strip.top + 1, reg.cellHeight, 1),
  "the fiducial row agrees with the base image about the content origin and cell height",
  `strip rows ${reg.strip.top}..${reg.strip.bottom}, base-derived origin y ${reg.originY}, cell height ${reg.cellHeight}`
);

// --- what counts as painted -------------------------------------------------
// The tint is measured, not assumed: phase 1 gives the untinted base colour and
// phase 2 gives the tinted one, both through whatever colour profile the
// screenshot carries. A pixel is "tinted" if it moved most of the way from the
// first to the second.
const probeRect = expect.rects[0];
const sample = { x: probeRect.expect_x + Math.floor(probeRect.width / 2), y: probeRect.expect_y + Math.floor(probeRect.height / 2) };
const baseSample = at(baseFrame, sample.x, sample.y);
const overlaySample = at(overlayFrame, sample.x, sample.y);
const untinted = pixelAt(base, baseSample.x, baseSample.y);
const tinted = pixelAt(overlaid, overlaySample.x, overlaySample.y);
const delta = tinted.r - untinted.r;
console.log(
  `\nbase rgb(${untinted.r},${untinted.g},${untinted.b}) -> tinted rgb(${tinted.r},${tinted.g},${tinted.b}), delta ${delta}`
);
check(
  delta > 20,
  "the overlay composites translucently over the base image (prompt check 2)",
  `only ${delta} of difference between the tinted and untinted base`
);
const threshold = untinted.r + delta / 2;
const isTinted = (image, x, y) => pixelAt(image, x, y).r > threshold;

// --- geometry, per rectangle ------------------------------------------------
console.log("");
for (const rect of expect.rects) {
  const origin = at(overlayFrame, rect.expect_x, rect.expect_y);
  const x0 = origin.x;
  const y0 = origin.y;
  const midY = y0 + Math.floor(rect.height / 2);
  const midX = x0 + Math.floor(rect.width / 2);
  console.log(`${rect.name}  (${rect.note})`);
  console.log(
    `  want ${rect.width}x${rect.height} px at device (${x0}, ${y0}), ` +
      `sub-cell offset X=${rect.expect_sub_cell_x} Y=${rect.expect_sub_cell_y}`
  );

  // Horizontal extent: scan the row through the middle of the bar and find the
  // painted run that contains its expected centre.
  let left = midX;
  while (left > 0 && isTinted(overlaid, left - 1, midY)) left -= 1;
  let right = midX;
  while (right + 1 < overlaid.width && isTinted(overlaid, right + 1, midY)) right += 1;
  let top = midY;
  while (top > 0 && isTinted(overlaid, midX, top - 1)) top -= 1;
  let bottom = midY;
  while (bottom + 1 < overlaid.height && isTinted(overlaid, midX, bottom + 1)) bottom += 1;

  check(
    Math.abs(left - x0) <= 1,
    `${rect.name}: left edge`,
    `expected ${x0}, measured ${left} (${left - x0} px out)`
  );
  check(
    Math.abs(right - (x0 + rect.width - 1)) <= 1,
    `${rect.name}: right edge`,
    `expected ${x0 + rect.width - 1}, measured ${right} (${right - (x0 + rect.width - 1)} px out)`
  );
  check(Math.abs(top - y0) <= 1, `${rect.name}: top edge`, `expected ${y0}, measured ${top}`);
  check(
    Math.abs(bottom - (y0 + rect.height - 1)) <= 1,
    `${rect.name}: bottom edge`,
    `expected ${y0 + rect.height - 1}, measured ${bottom}`
  );

  // Contiguity: the comb. If WezTerm's per-cell padding were an inset rather
  // than a translation, every cell boundary inside the bar would carry an
  // unpainted gap of X pixels. Scan the whole interior, not just one row.
  let holes = 0;
  let firstHole = null;
  for (let y = top; y <= bottom; y += 1) {
    for (let x = left; x <= right; x += 1) {
      if (!isTinted(overlaid, x, y)) {
        holes += 1;
        if (!firstHole) firstHole = { x: x - overlayFrame.reg.originX, y: y - overlayFrame.reg.originY };
      }
    }
  }
  check(
    holes === 0,
    `${rect.name}: solid, with no gap at any cell boundary (the comb check)`,
    `${holes} unpainted pixels inside the bar, first at content (${firstHole?.x}, ${firstHole?.y}); ` +
      `a comb would put a gap of ${rect.expect_sub_cell_x} px at each of ~${Math.ceil(rect.width / reg.cellWidth)} cell boundaries`
  );
}

// --- adjacent bars must not merge -------------------------------------------
const upper = expect.rects.find((r) => r.name === "E-upper");
const lower = expect.rects.find((r) => r.name === "E-lower");
if (upper && lower) {
  const gapTop = at(overlayFrame, 0, upper.expect_y + upper.height).y;
  const gapBottom = at(overlayFrame, 0, lower.expect_y).y - 1;
  const x = at(overlayFrame, upper.expect_x + 10, 0).x;
  let painted = 0;
  for (let y = gapTop; y <= gapBottom; y += 1) if (isTinted(overlaid, x, y)) painted += 1;
  check(
    painted === 0,
    "adjacent bars keep the gap between them (they do not run together)",
    `${painted} of ${gapBottom - gapTop + 1} gap rows are painted`
  );
}

// --- deletion ---------------------------------------------------------------
// Prompt check 5. Compared against phase 1 rather than against "no tint
// anywhere", so a highlight that survived as a single stray fragment fails.
let residue = 0;
let firstResidue = null;
for (const rect of expect.rects) {
  const origin = at(clearedFrame, rect.expect_x, rect.expect_y);
  for (let y = origin.y; y < origin.y + rect.height; y += 1) {
    for (let x = origin.x; x < origin.x + rect.width; x += 1) {
      if (isTinted(cleared, x, y)) {
        residue += 1;
        if (!firstResidue) firstResidue = { x: x - clearedFrame.reg.originX, y: y - clearedFrame.reg.originY };
      }
    }
  }
}
const clearedSample = at(clearedFrame, sample.x, sample.y);
const afterDeletion = pixelAt(cleared, clearedSample.x, clearedSample.y);
console.log("");
check(
  residue === 0,
  "every rectangle is gone after overlay_clear, with the base intact (prompt check 5)",
  `${residue} tinted pixels survived, first at content (${firstResidue?.x}, ${firstResidue?.y})`
);
check(
  Math.abs(afterDeletion.r - untinted.r) <= 2,
  "the base image is unchanged where the highlight was",
  `base was ${untinted.r}, after deletion ${afterDeletion.r}`
);

console.log(`\n${checks - failures}/${checks} checks passed`);
process.exit(failures === 0 ? 0 : 1);
