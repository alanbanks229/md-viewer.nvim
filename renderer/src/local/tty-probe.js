// The one moment in the whole system where querying the terminal is safe.
//
// md-viewer's Lua side can never probe: Neovim owns terminal input, so a
// query's response would land in the user's keystrokes -- which is why
// `terminal.lua` is inference-only and proudly reports "inferred", never
// "verified". The helper is different for exactly one window: before it
// spawns ssh, it is the only process on this tty, so it can ask and read the
// answer with nobody to race.
//
// Three questions, in one batch:
//   CSI 14 t        -- text-area pixel size, the number TIOCGWINSZ reports
//                      remotely only when every hop propagates it
//   kitty a=q       -- does this terminal actually implement the graphics
//                      protocol (q=1: a response is the point; the plugin's
//                      q=2-everywhere rule is about Neovim owning input,
//                      which is not true here yet)
//   DA1 (CSI c)     -- the drain fence: terminals answer queries in order,
//                      so once the DA1 reply is consumed the queue is
//                      provably empty and nothing can leak into ssh's stdin
//                      as phantom keystrokes
//
// The probe reads from its own `/dev/tty` descriptor, never from
// `process.stdin`, and closes it completely before returning. This is not
// hygiene, it is the K1 finding that shaped this file: once Node has ever
// started reading `process.stdin`, its tty watcher keeps competing with the
// ssh child for bytes on fd 0 even after `pause()`, stealing an occasional
// keystroke -- ordinary typing survives the losses, but ssh's three-byte
// `\r~.` escape does not, and the measured symptom was exactly "everything
// works except `~.`" (2026-08-26, macOS 15, ssh to a LAN host, reproduced
// and bisected to the probe). A separate fd that is opened, drained, and
// closed leaves fd 0 untouched for ssh to inherit.
//
// On timeout the probe records "unanswered" and the helper proceeds
// degraded; a terminal that never answered a fenced query will not answer it
// late in practice, and the alternative -- keep eating tty input -- would
// eat the user's first real keystroke instead.

import fs from "node:fs";
import tty from "node:tty";

const DA1_REPLY = /\x1b\[\?[0-9;]*c/;
const PIXEL_REPLY = /\x1b\[4;(\d+);(\d+)t/;
const CELL_COUNT_REPLY = /\x1b\[8;(\d+);(\d+)t/;
const KITTY_REPLY = /\x1b_Gi=31;([^\x1b]*)\x1b\\/;

// A 1x1 RGB pixel, the canonical capability query. Any i=31 response --
// including an error about the payload -- proves the protocol is implemented;
// only silence means it is not.
const KITTY_QUERY = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\";

export function probeTerminal({ output = process.stdout, timeoutMs = 500 } = {}) {
  if (!output.isTTY) {
    return Promise.resolve({ skipped: "stdout is not a terminal", cellPixels: null, kittyGraphics: "unknown", da1: null });
  }
  let fd;
  try {
    fd = fs.openSync("/dev/tty", "r");
  } catch {
    return Promise.resolve({ skipped: "no controlling terminal", cellPixels: null, kittyGraphics: "unknown", da1: null });
  }
  const input = new tty.ReadStream(fd);
  if (typeof input.setRawMode !== "function") {
    input.destroy();
    return Promise.resolve({ skipped: "/dev/tty is not a tty stream", cellPixels: null, kittyGraphics: "unknown", da1: null });
  }

  return new Promise((resolve) => {
    let buffer = "";
    let done = false;

    const finish = (timedOut) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      input.removeListener("data", onData);
      try {
        input.setRawMode(false);
      } catch {}
      // destroy() closes our private fd; fd 0 was never touched.
      input.destroy();

      const pixels = PIXEL_REPLY.exec(buffer);
      const cellCount = CELL_COUNT_REPLY.exec(buffer);
      const kitty = KITTY_REPLY.exec(buffer);
      const da1 = DA1_REPLY.exec(buffer);
      // Read from the terminal's own reply (CSI 18t), not Node's cached
      // `output.columns`/`rows`: those can still hold the 80x25 default if
      // this helper starts before the terminal has propagated its real size
      // down to the pty (observed on the SSM reference host 2026-08-27 -- a session
      // opened with `helper_terminal.cellPixels.cols/rows` at 80x25 while
      // Neovim's own preview window was already 88 columns wide, which is
      // impossible if the terminal were really that narrow). Every later
      // placement inherits this number for the session's life, so a
      // fallback read here is not a one-frame glitch, it is wrong for good.
      const cols = cellCount ? Number(cellCount[2]) : output.columns ?? null;
      const rows = cellCount ? Number(cellCount[1]) : output.rows ?? null;
      let cellPixels = null;
      if (pixels && cols && rows) {
        const heightPx = Number(pixels[1]);
        const widthPx = Number(pixels[2]);
        if (widthPx > 0 && heightPx > 0) {
          cellPixels = { widthPx: widthPx / cols, heightPx: heightPx / rows, textWidthPx: widthPx, textHeightPx: heightPx, cols, rows };
        }
      }
      resolve({
        skipped: null,
        timedOut,
        cellPixels,
        // "verified" beats every remote inference tier; "absent" means the
        // fence answered but the graphics query was discarded, which is what
        // a terminal without the protocol does; "unanswered" means the fence
        // itself timed out and nothing here can be trusted.
        kittyGraphics: kitty ? "verified" : da1 ? "absent" : "unanswered",
        kittyReply: kitty ? kitty[1] : null,
        da1: da1 ? da1[0] : null,
      });
    };

    const onData = (chunk) => {
      buffer += chunk.toString("latin1");
      if (DA1_REPLY.test(buffer)) finish(false);
    };

    const timer = setTimeout(() => finish(true), timeoutMs);
    input.setRawMode(true);
    input.on("data", onData);
    output.write(`\x1b[14t\x1b[18t${KITTY_QUERY}\x1b[c`);
  });
}
