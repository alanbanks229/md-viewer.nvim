// A Kitty-graphics memory probe that knows nothing about Neovim or md-viewer.
//
// It runs *inside* the terminal under test, writes protocol bytes straight to
// stdout, and samples the terminal process's own resident size while it does.
// The point is to separate "md-viewer drives the protocol badly" from "the
// terminal retains something it should not", which no measurement taken through
// the plugin can do.
//
// Each case is one hypothesis about which part of the placement lifecycle costs
// memory; see CASES below. Every run ends by deleting placements, then image
// data, then idling, sampling after each -- a number that comes down after a
// delete is a cache, and a number that does not is a leak.
//
//   CASE=B ITERS=2000 OUT=/tmp/run node repro.mjs
//
// Safety: the probe abandons its own workload the moment the terminal's RSS
// passes CEILING_KB. An earlier generation of this work took a 16 GB machine
// down; no measurement here is worth that, so the ceiling is checked while the
// frames run and the run is abandoned rather than truncated silently.
import fs from "node:fs";
import zlib from "node:zlib";
import { execFileSync, spawn } from "node:child_process";

// An empty environment variable means "not set". Shell wrappers pass empty
// strings for absent options, and Number("") is 0, which silently turned a
// 1568x945 tint sheet into a 0x0 one and made a run look leak-free because it
// had drawn nothing at all.
const env = (name, fallback) => {
  const value = process.env[name];
  return value === undefined || value === "" ? fallback : value;
};
const num = (name, fallback) => Number(env(name, fallback));

const CASE = env("CASE", "B").toUpperCase();
const ITERS = num("ITERS", 1200);
const FPS = num("FPS", 40);
const OUT = env("OUT", "/tmp/wezterm-memory");
const CEILING_KB = num("CEILING_KB", 1200000);
const RECTS = num("RECTS", 4);
const MOVING = num("MOVING", String(RECTS));
const SAMPLE_EVERY = num("SAMPLE_EVERY", 20);
const IDLE_MS = num("IDLE_MS", 6000);
const VMMAP = env("VMMAP", "1") !== "0";
// md-viewer never places overlay rectangles onto bare cells: there is always a
// full-screen base image under them, placed with c/r. Whether that matters is
// exactly the kind of thing a probe run on an empty screen would miss.
const BASE = env("BASE", "1") !== "0";
const SAMPLE_SECONDS = num("SAMPLE_SECONDS", "0");
const MALLOC_HISTORY = env("MALLOC_HISTORY", "0") !== "0";
// Cells to push the overlay rectangles down by, so they can be aimed at rows
// the base image does not cover.
const OVERLAY_ROW_SHIFT = num("OVERLAY_ROW_SHIFT", "0");
// Rows the base image is placed across; fewer than the grid leaves bare rows.
const BASE_ROWS = num("BASE_ROWS", "0");
// RSS levels, in KB, at which to grab a vmmap while the workload is still
// running.
const thresholds = env("VMMAP_AT_KB", "")
  .split(",")
  .filter(Boolean)
  .map(Number)
  .sort((a, b) => a - b);
// Running the same workload twice in one process separates "the allocator kept
// the pages" from "the terminal kept the objects": retained pages get reused by
// the second pass, retained objects add to it.
const REPEATS = num("REPEATS", 1);

const ESC = "\x1b";
const write = (s) => fs.writeSync(1, s);
const g = (control, payload) => `${ESC}_G${control}${payload ? ";" + payload : ""}${ESC}\\`;
// Placements are positioned the way md-viewer positions them: save cursor, jump
// to the cell, place with C=1 (do not move the cursor), restore.
const at = (row, col, seq) => `${ESC}[s${ESC}[${row};${col}H${seq}${ESC}[u`;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const CASES = {
  A: "stable image id + stable placement ids, replaced in place (no explicit delete)",
  B: "stable image id + fresh placement id per frame, previous deleted (md-viewer's pattern)",
  B2: "stable image id + fresh placement id per frame, previous NEVER deleted (control)",
  C: "fresh image id + fresh placement id per frame, previous image deleted with d=I",
  D: "stable image id + stable placement id, image data retransmitted every frame",
  E: "no graphics at all: same frame rate, comparable byte volume of text",
  F: "base image left intact; one character toggled per frame to force a repaint",
};

// ---------------------------------------------------------------- terminal pid

/// Walk the process tree upward to the terminal emulator that owns this tty.
/// `ps` once, then follow ppid links -- cheaper and more reliable than shelling
/// out per generation, and it works the same for every emulator here.
function terminalProcess() {
  const rows = execFileSync("ps", ["-axo", "pid=,ppid=,comm="], { encoding: "utf8" })
    .split("\n")
    .map((line) => line.trim().match(/^(\d+)\s+(\d+)\s+(.*)$/))
    .filter(Boolean);
  const byPid = new Map(rows.map((m) => [Number(m[1]), { ppid: Number(m[2]), comm: m[3] }]));
  const known = /wezterm-gui|kitty|ghostty|iTerm2|Alacritty/i;
  let pid = process.pid;
  for (let hops = 0; hops < 12; hops += 1) {
    const entry = byPid.get(pid);
    if (!entry) break;
    if (known.test(entry.comm)) return { pid, comm: entry.comm };
    pid = entry.ppid;
    if (pid <= 1) break;
  }
  return null;
}

const rssKb = (pid) => {
  try {
    return Number(execFileSync("ps", ["-o", "rss=", "-p", String(pid)], { encoding: "utf8" }).trim());
  } catch {
    return NaN;
  }
};

// ------------------------------------------------------------------- cell size

/// Ask the terminal for its text-area pixel size (XTWINOPS 14) and divide by the
/// grid. Deliberately not TIOCGWINSZ: this probe has to run in terminals whose
/// pty geometry md-viewer never reads, and the reply is the terminal's own
/// opinion of the cell, which is the number the placement arithmetic uses.
///
/// The window's pixel size is corrected a second or two after launch on some
/// builds, so the caller settles first and this is asked once, late.
function queryCell(timeoutMs = 2500) {
  return new Promise((resolve) => {
    const cols = process.stdout.columns;
    const rows = process.stdout.rows;
    if (!process.stdin.isTTY || !cols || !rows) return resolve(null);
    let text = "";
    const done = (value) => {
      clearTimeout(timer);
      process.stdin.off("data", onData);
      process.stdin.pause();
      try {
        process.stdin.setRawMode(false);
      } catch {}
      resolve(value);
    };
    const onData = (buf) => {
      text += buf.toString("latin1");
      const m = text.match(/\x1b\[4;(\d+);(\d+)t/);
      if (m) done({ cols, rows, pxW: Number(m[2]), pxH: Number(m[1]) });
    };
    const timer = setTimeout(() => done(null), timeoutMs);
    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdin.on("data", onData);
    write(`${ESC}[14t`);
  });
}

// ------------------------------------------------------------------ png encoder

const CRC = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n += 1) {
    let c = n;
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();
const crc32 = (b) => {
  let c = -1;
  for (const byte of b) c = CRC[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
};
const chunk = (type, data) => {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, "latin1"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([len, body, crc]);
};
/// A flat RGBA sheet. `seed` perturbs one pixel so cases that retransmit can
/// produce genuinely distinct bytes -- WezTerm hashes image data and hands back
/// the same Arc for a repeat, which would quietly turn case D into case A.
function sheetPng(w, h, rgba, seed = 0) {
  const stride = 1 + w * 4;
  const raw = Buffer.alloc(h * stride);
  for (let y = 0; y < h; y += 1) {
    const row = y * stride;
    raw[row] = 0;
    for (let x = 0; x < w; x += 1) {
      const o = row + 1 + x * 4;
      raw[o] = rgba[0];
      raw[o + 1] = rgba[1];
      raw[o + 2] = rgba[2];
      raw[o + 3] = rgba[3];
    }
  }
  if (seed) raw[1] = seed & 0xff;
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = 6; // RGBA
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw, { level: 1 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

/// Kitty transmission is chunked at 4096 base64 characters per escape.
function transmit(id, png) {
  const b64 = png.toString("base64");
  const size = 4096;
  let out = "";
  for (let i = 0; i < b64.length; i += size) {
    const piece = b64.slice(i, i + size);
    const more = i + size < b64.length ? 1 : 0;
    const control = i === 0 ? `a=t,f=100,t=d,q=2,i=${id},m=${more}` : `m=${more}`;
    out += g(control, piece);
  }
  return out;
}

// ------------------------------------------------------------------------ run

const started = Date.now();
const samples = [];
const marks = [];
const notes = [];
let aborted = null;
let term = null;
let cell = null;

fs.mkdirSync(OUT, { recursive: true });
const finish = (extra = {}) => {
  fs.writeFileSync(
    `${OUT}/result.json`,
    JSON.stringify(
      { case: CASE, description: CASES[CASE], terminal: term, cell, iters: ITERS, fps: FPS,
        rects: RECTS, moving: MOVING, aborted, notes, marks, samples, ...extra },
      null,
      2
    )
  );
};

// Samples are appended to disk as they are taken, not just held for the final
// write: a run that has to be killed from outside is exactly the run whose
// numbers matter most, and it never reaches the final write.
const trail = fs.openSync(`${OUT}/samples.jsonl`, "a");
const record = (row) => fs.writeSync(trail, JSON.stringify(row) + "\n");

const mark = (label) => {
  const rss = rssKb(term.pid);
  const row = { kind: "mark", label, t_ms: Date.now() - started, rss_kb: rss };
  marks.push({ label, t_ms: row.t_ms, rss_kb: rss });
  record(row);
  return rss;
};

/// Wait, sampling as we go and writing nothing to the terminal.
const sampleFor = async (ms, label) => {
  const until = Date.now() + ms;
  while (Date.now() < until) {
    await sleep(500);
    record({ kind: "idle", label, t_ms: Date.now() - started, rss_kb: rssKb(term.pid) });
  }
};

/// vmmap tells us which allocator the growth lives in -- malloc heap, the Metal
/// / IOAccelerator regions, or plain anonymous VM. That distinction is the whole
/// difference between "terminal bookkeeping" and "GPU resources", and no RSS
/// number can make it.
const vmmapSnapshot = (label) => {
  if (!VMMAP) return;
  try {
    const text = execFileSync("vmmap", ["-summary", String(term.pid)], {
      encoding: "utf8",
      timeout: 30000,
      maxBuffer: 8 << 20,
    });
    fs.writeFileSync(`${OUT}/vmmap-${label}.txt`, text);
    if (label === "peak" || label.startsWith("at")) {
      // The summary hides how the growth is shaped: one huge region or ten
      // thousand small ones are different bugs.
      const full = execFileSync("vmmap", [String(term.pid)], {
        encoding: "utf8", timeout: 60000, maxBuffer: 64 << 20,
      });
      fs.writeFileSync(`${OUT}/vmmap-full-${label}.txt`, full);
    }
  } catch (err) {
    notes.push(`vmmap ${label} failed: ${err.message}`);
  }
};

async function main() {
  term = terminalProcess();
  if (!term) {
    notes.push("could not identify the terminal process from the ps tree");
    finish();
    process.exit(3);
  }

  write(`${ESC}[2J${ESC}[H`);
  write(`kitty graphics memory probe -- case ${CASE}: ${CASES[CASE] ?? "unknown"}\r\n`);
  // Let the window settle before asking its size: on WezTerm the pty's pixel
  // dimensions are wrong for the first couple of seconds after launch.
  await sleep(2500);

  cell = await queryCell();
  if (!cell) {
    notes.push("terminal did not answer CSI 14 t; cannot size placements in cells");
    finish();
    process.exit(4);
  }
  const cw = Math.floor(cell.pxW / cell.cols);
  const ch = Math.floor(cell.pxH / cell.rows);
  if (!(cw >= 1 && ch >= 1)) {
    notes.push(`nonsensical cell ${cw}x${ch} from ${cell.pxW}x${cell.pxH} / ${cell.cols}x${cell.rows}`);
    finish();
    process.exit(5);
  }

  // The sheet is sized like md-viewer's: the preview area, in the pixels it is
  // drawn at. A small sheet is a different experiment, so it is a knob.
  const sheetW = num("SHEET_W", String((cell.cols - 2) * cw));
  const sheetH = num("SHEET_H", String((cell.rows - 3) * ch));
  const png = sheetPng(sheetW, sheetH, [220, 220, 220, 77]);
  notes.push(`sheet ${sheetW}x${sheetH} rgba, ${png.length} B png, cell ${cw}x${ch}, grid ${cell.cols}x${cell.rows}`);

  const IMAGE_BASE = 0x5a0000;
  const PLACEMENT_BASE = 0x6b0000;
  let nextImage = IMAGE_BASE;
  let nextPlacement = PLACEMENT_BASE;

  /// One frame's worth of rectangles: `MOVING` of them shift horizontally so the
  /// crop origin, and therefore the placement, genuinely changes.
  const rects = (frame) => {
    const out = [];
    const lineH = Math.max(4, Math.floor(sheetH / Math.max(1, RECTS)));
    for (let i = 0; i < RECTS; i += 1) {
      const shift = i >= RECTS - MOVING ? frame % 7 : 0;
      out.push({
        x: 3 + shift,
        y: i * lineH,
        w: Math.max(8, sheetW - 40 - (i % 11) * 17 - shift),
        h: Math.max(2, lineH - 2),
      });
    }
    return out;
  };

  /// Where a rectangle lands: the cell containing its origin, plus the sub-cell
  /// remainder, expressed by cropping into the sheet exactly as md-viewer's
  /// sheet-margin encoding does. Row/col are 1-based for CUP.
  const placeFor = (r, id, pid) => {
    const col = Math.floor(r.x / cw);
    const row = Math.floor(r.y / ch);
    const xOff = r.x - col * cw;
    const yOff = r.y - row * ch;
    const cropX = r.x - xOff;
    const cropY = r.y - yOff;
    const cropW = Math.min(sheetW - cropX, xOff + r.w);
    const cropH = Math.min(sheetH - cropY, yOff + r.h);
    const control = `a=p,q=2,C=1,i=${id},p=${pid},x=${cropX},y=${cropY},w=${cropW},h=${cropH},z=-1`;
    return at(row + 2 + OVERLAY_ROW_SHIFT, col + 2, g(control));
  };

  const del = (id, pid) => g(`a=d,d=i,q=2,i=${id},p=${pid}`);

  write(`terminal pid ${term.pid} (${term.comm}), cell ${cw}x${ch}, sheet ${sheetW}x${sheetH}\r\n`);
  await sleep(800);
  mark("baseline");
  vmmapSnapshot("baseline");

  // The base frame: a full-screen image placed with c/r, exactly as md-viewer
  // places a rendered preview. Every overlay cell therefore already holds one
  // ImageCell before the overlay attaches a second.
  const BASE_IMAGE = 0x4a0000;
  const BASE_PLACEMENT = 0x4b0000;
  if (BASE) {
    // The base image is placed with c/r, so it fills the same cells whatever
    // its pixel size. That makes its decoded size an independent variable.
    const baseW = num("BASE_W", String(sheetW));
    const baseH = num("BASE_H", String(sheetH));
    const BASE_CROP = env("BASE_CROP", "1") !== "0";
    notes.push(`base image ${baseW}x${baseH} rgba (${((baseW * baseH * 4) / 1048576).toFixed(1)} MB decoded)`);
    write(transmit(BASE_IMAGE, sheetPng(baseW, baseH, [64, 64, 64, 255])));
    await sleep(400);
    write(
      at(2, 2, g(`a=p,q=2,C=1,i=${BASE_IMAGE},p=${BASE_PLACEMENT},` +
        // md-viewer always sends the crop keys on the base frame, even when the
        // crop is the whole image, because the same code path also emits the
        // cut-out regions around floating windows. Whether that costs anything
        // is exactly what this knob is for.
        (BASE_CROP ? `x=0,y=0,w=${baseW},h=${baseH},` : "") +
        `c=${cell.cols - 2},r=${BASE_ROWS || cell.rows - 3},z=-2`))
    );
    await sleep(600);
    mark("after_base_image");
  }

  let live = []; // [{id, pid}] currently on screen
  if (CASE !== "C" && CASE !== "E") {
    // D also needs the id to exist before its first placement; the retransmit
    // inside the loop supplies the changing bytes.
    write(transmit(nextImage, png));
    await sleep(600);
    mark("after_transmit");
  }

  const frameMs = 1000 / FPS;
  let pass = 0;
  let frame = 0;
  const runFrame = async (frameIndex) => {
    const t0 = Date.now();
    let payload = "";
    const frame = frameIndex;

    if (CASE === "A") {
      // Placement ids are stable, so kitty_img_place's own replace path runs:
      // it removes the existing (image_id, placement_id) before installing.
      const set = rects(frame);
      if (live.length === 0) live = set.map((_, i) => ({ id: nextImage, pid: PLACEMENT_BASE + i }));
      set.forEach((r, i) => (payload += placeFor(r, live[i].id, live[i].pid)));
    } else if (CASE === "B" || CASE === "B2") {
      const fresh = [];
      for (const r of rects(frame)) {
        nextPlacement += 1;
        fresh.push({ id: nextImage, pid: nextPlacement });
        payload += placeFor(r, nextImage, nextPlacement);
      }
      if (CASE === "B") for (const p of live) payload += del(p.id, p.pid);
      live = fresh;
    } else if (CASE === "C") {
      nextImage += 1;
      nextPlacement += 1;
      payload += transmit(nextImage, sheetPng(sheetW, sheetH, [220, 220, 220, 77], (frame % 250) + 1));
      payload += placeFor(rects(frame)[0], nextImage, nextPlacement);
      for (const p of live) payload += g(`a=d,d=I,q=2,i=${p.id}`);
      live = [{ id: nextImage, pid: nextPlacement }];
    } else if (CASE === "D") {
      // Same ids throughout, but the bytes differ every frame, so the terminal
      // cannot short-circuit on its data hash.
      payload += transmit(nextImage, sheetPng(sheetW, sheetH, [220, 220, 220, 77], (frame % 250) + 1));
      payload += placeFor(rects(frame)[0], nextImage, PLACEMENT_BASE);
      live = [{ id: nextImage, pid: PLACEMENT_BASE }];
    } else if (CASE === "F") {
      // Damage one cell in the last row, which the base image does not cover.
      // The screen still contains a full-size image every frame, so this
      // separates "rendering a frame that has an image in it" from "processing
      // a placement command".
      payload += at(cell.rows, 1, String.fromCharCode(97 + (frame % 26)));
    } else if (CASE === "E") {
      // A comparable volume of ordinary output at the same rate: the control
      // that says whether any high-frequency writing does this.
      const line = "█".repeat(Math.max(1, cell.cols - 4));
      for (let i = 0; i < RECTS; i += 1) {
        payload += at(2 + (i % (cell.rows - 3)), 2, `${ESC}[38;5;${240 + (frame % 6)}m${line}${ESC}[0m`);
      }
    }

    write(payload);

    if (frame % SAMPLE_EVERY === 0) {
      const rss = rssKb(term.pid);
      const row = { kind: "sample", pass, frame, t_ms: Date.now() - started, rss_kb: rss };
      samples.push(row);
      record(row);
      // Snapshot the region breakdown mid-climb. Waiting until the workload
      // ends is too late when the climb outruns the teardown: the run that
      // needs a vmmap is the one that never reaches the end.
      while (thresholds.length && rss > thresholds[0]) {
        const kb = thresholds.shift();
        vmmapSnapshot(`at${Math.round(kb / 1024)}mb`);
        // Stacks, not just totals: the code that is hot while the number climbs
        // is the code allocating, and `sample` names it without a rebuild.
        if (SAMPLE_SECONDS > 0) {
          // Detached, not awaited: a synchronous `sample` stops the frame loop,
          // which stops the terminal, which is how you photograph an idle
          // process and conclude nothing.
          spawn("sample", [String(term.pid), String(SAMPLE_SECONDS), "-file",
            `${OUT}/sample-at${Math.round(kb / 1024)}mb.txt`, "-mayDie"],
            { detached: true, stdio: "ignore" }).unref();
        }
        if (MALLOC_HISTORY) {
          // With MallocStackLogging enabled on the terminal, this names the
          // call sites holding the high-water mark -- the one measurement that
          // does not require guessing which layer allocated.
          const hist = fs.openSync(`${OUT}/malloc-history-at${Math.round(kb / 1024)}mb.txt`, "w");
          spawn("malloc_history", [String(term.pid), "-callTree", "-consolidateSystemFramesBySymbol"],
            { detached: true, stdio: ["ignore", hist, hist] }).unref();
        }
      }
      if (Number.isFinite(rss) && rss > CEILING_KB) {
        aborted = `terminal RSS ${rss} KB passed the ${CEILING_KB} KB ceiling at frame ${frame}`;
        return false;
      }
    }
    const spent = Date.now() - t0;
    if (spent < frameMs) await sleep(frameMs - spent);
    return true;
  };

  for (pass = 0; pass < REPEATS; pass += 1) {
    for (let i = 0; i < ITERS; i += 1) {
      frame += 1;
      if (!(await runFrame(frame))) break;
    }
    mark(`after_workload_pass${pass}`);
    if (aborted) break;
    if (pass + 1 < REPEATS) {
      // Between passes: drop every placement and let it settle, so the next
      // pass starts from the same screen state the first one did.
      write(g("a=d,d=a,q=2"));
      live = [];
      await sleep(2500);
      mark(`after_clear_pass${pass}`);
    }
  }

  mark("after_workload");
  vmmapSnapshot("peak");

  // Sample continuously with nothing being sent. If the number keeps climbing
  // here, the terminal is doing the work to itself and the input rate was only
  // the trigger; if it settles, we were watching a backlog drain.
  await sampleFor(IDLE_MS, "idle");
  mark(`after_idle_${IDLE_MS}ms`);

  // Deleting placements should release everything the model holds; deleting the
  // data as well should release everything the terminal holds. Whatever remains
  // above baseline after both is retained somewhere else.
  write(g("a=d,d=a,q=2"));
  await sleep(1500);
  mark("after_delete_placements");

  write(g("a=d,d=A,q=2"));
  await sleep(1500);
  mark("after_delete_all");

  await sleep(IDLE_MS);
  mark(`after_delete_idle_${IDLE_MS}ms`);

  // Force a full repaint and scroll the screen away: some of what is retained
  // is only released when the renderer next rebuilds, and "it comes back on
  // redraw" is a different bug from "it never comes back".
  write(`${ESC}[2J${ESC}[H`);
  await sleep(2500);
  mark("after_clear_screen");
  vmmapSnapshot("final");

  finish({ frames: frame });
  write(`\r\ndone: ${frame} frames -> ${OUT}/result.json\r\n`);
  await sleep(300);
  process.exit(0);
}

main().catch((err) => {
  notes.push(`crashed: ${err.stack ?? err.message}`);
  finish();
  process.exit(1);
});
