// The stream filter that puts the pixels back.
//
// md-viewer paints the preview by writing Kitty graphics commands into the
// terminal. The expensive half of that is one `a=t` transmission carrying a
// base64 PNG; the cheap half is a handful of ~60-byte `a=p` placements. Over a
// throttled link the transmission *is* the lag, so when the frame was
// rasterized on this machine in the first place the plugin emits a token in its
// place -- and this filter, sitting between ssh's stdout and the terminal,
// swaps that token back for exactly the bytes the plugin would have sent.
//
// **Byte equivalence is the whole correctness argument.** `kittyChunks` below
// is a port of `chunks()` in lua/md-viewer/backends/kitty_raw.lua, and
// tests/node/splice.test.js and tests/lua/cases/backend_kitty.lua assert both
// against the same checked-in golden so neither can drift alone. Every other
// property of the stream -- placement geometry, crop rectangles, z-layering,
// double-buffered deletion order -- is still computed in Lua on the machine
// running Neovim and passes through here untouched. The terminal receives the
// same stream it receives today.
//
// **Everything unrecognized passes through unchanged.** This filter sits in
// front of a live terminal carrying an interactive session, so the failure it
// must never have is eating bytes it did not mint. A token whose frame is no
// longer held, a token that never terminates, a byte sequence that merely looks
// like one: all are forwarded verbatim. A stray `ESC _ ... ESC \` is an APC
// string with an application identifier the terminal does not know, which
// conformant terminals discard -- the same fate as forwarding nothing, minus
// the risk of having swallowed something real.

const CHUNK_SIZE = 4096;

// An APC string introducer, this application's identifier, and the version, as
// one thing. Matching the whole marker at once is what lets a read boundary
// land anywhere inside it: any tail of the stream that is a *prefix* of this is
// held, and anything else is released immediately.
const MARKER = Buffer.from("\x1b_MDV1;");
const ESC = 0x1b;
const ST = Buffer.from("\x1b\\");

// A real token is under 150 bytes. This is the point past which an unterminated
// one stops being worth waiting for and gets forwarded as the ordinary APC
// string it apparently is, rather than buffering the session's output forever.
const MAX_TOKEN_BYTES = 1024;

// Both are embedded verbatim in an escape sequence, so neither may contain the
// `;` that separates the token's fields or the ESC that ends it. Checked here
// rather than trusted from the minting side: this process is the one holding
// the terminal.
const REF_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;
const CONTROL_PATTERN = /^[A-Za-z0-9=,]{1,128}$/;

/// One Kitty graphics command: `ESC _ G <control> ; <payload> ESC \`.
export function kittyCommand(control, payload = "") {
  return `\x1b_G${control};${payload}\x1b\\`;
}

/// Split a base64 payload into Kitty transmission chunks.
///
/// A byte-for-byte port of `chunks()` in kitty_raw.lua, down to the details
/// that look incidental and are not: the first chunk carries the caller's full
/// control string and every later one carries `q=2` alone, `m=1` marks that
/// more follow and `m=0` the last, and an empty payload produces no commands at
/// all. The protocol associates continuation chunks with the transmission in
/// progress, so this sequence is also indivisible -- nothing may be interleaved
/// into it, which is why the token it replaces is a single atomic unit too.
export function kittyChunks(encoded, control) {
  const out = [];
  let offset = 0;
  let head = control;
  while (offset < encoded.length) {
    const piece = encoded.slice(offset, offset + CHUNK_SIZE);
    offset += piece.length;
    const more = offset < encoded.length ? 1 : 0;
    out.push(kittyCommand(`${head},m=${more}`, piece));
    head = "q=2";
  }
  return out.join("");
}

/// The token the Lua side emits in place of a transmission.
///
/// Exported so tests can build one without reaching into the backend, and so
/// there is exactly one statement of the format on this side of the link. The
/// Lua half is `transmit()` in kitty_raw.lua; the two are asserted equal.
export function frameToken(ref, control) {
  return `\x1b_MDV1;tx;${ref};${control}\x1b\\`;
}

/// A filter over a byte stream heading for the terminal.
///
/// `push` returns what should be written and holds back only what it cannot yet
/// classify -- at most a partial token. Call `flush()` at end of stream to
/// release anything still held.
///
/// `frames` is the store the references name; `onEvent` receives
/// `{kind, ...}` records for diagnostics and must never throw.
export function createSplicer({ frames, onEvent } = {}) {
  let pending = Buffer.alloc(0);
  let panicked = null;
  const counts = { tokens: 0, spliced: 0, unknown: 0, malformed: 0, bytesOut: 0, bytesIn: 0 };

  function report(record) {
    if (!onEvent) return;
    try {
      onEvent(record);
    } catch {}
  }

  /// Turn one token body (`tx;<ref>;<control>`) into the bytes to emit, or null
  /// when it is not something this understands -- in which case the caller
  /// forwards the original sequence untouched.
  function replace(body) {
    const parts = body.split(";");
    if (parts.length !== 3 || parts[0] !== "tx") {
      counts.malformed += 1;
      report({ kind: "malformed", body });
      return null;
    }
    const [, ref, control] = parts;
    if (!REF_PATTERN.test(ref) || !CONTROL_PATTERN.test(control)) {
      counts.malformed += 1;
      report({ kind: "malformed", body });
      return null;
    }
    counts.tokens += 1;
    const bytes = frames?.get(ref) ?? null;
    if (!bytes) {
      // The frame is gone: evicted, or minted by a companion that has since
      // restarted. Forwarding the token means the terminal discards an APC
      // string it does not recognize and this frame simply does not appear --
      // the next render replaces it. Emitting nothing would look the same and
      // would additionally have destroyed evidence if this was never our token.
      counts.unknown += 1;
      report({ kind: "unknown-frame", ref });
      return null;
    }
    counts.spliced += 1;
    return Buffer.from(kittyChunks(bytes.toString("base64"), control), "latin1");
  }

  /// Scan one buffer, returning what to write and what to keep for next time.
  ///
  /// Pure with respect to `pending` on purpose: the caller assigns the
  /// remainder only on success, so a throw cannot leave half a chunk consumed
  /// and half re-emitted.
  ///
  /// `cursor` is the start of what has not been written yet and `scan` is where
  /// to look next; they move independently so that an ESC which turns out to
  /// begin something ordinary costs no buffer split at all -- it is simply
  /// included in the next span written.
  function drain(input) {
    const out = [];
    let cursor = 0;
    let scan = 0;
    for (;;) {
      const start = input.indexOf(ESC, scan);
      if (start === -1) {
        out.push(input.subarray(cursor));
        cursor = input.length;
        break;
      }
      const available = input.length - start;
      if (available < MARKER.length) {
        // Too few bytes to decide. Held only if they could still *become* the
        // marker -- which a Kitty upload's own `ESC _ G` cannot, so the common
        // case is never delayed.
        if (MARKER.subarray(0, available).equals(input.subarray(start))) {
          out.push(input.subarray(cursor, start));
          cursor = start;
          break;
        }
        scan = start + 1;
        continue;
      }
      if (!input.subarray(start, start + MARKER.length).equals(MARKER)) {
        scan = start + 1;
        continue;
      }
      out.push(input.subarray(cursor, start));
      cursor = start;
      const bodyStart = start + MARKER.length;
      const end = input.indexOf(ST, bodyStart);
      if (end === -1) {
        if (available > MAX_TOKEN_BYTES) {
          // Long past any token this could be. Treat the marker as ordinary
          // output and carry on scanning inside it, rather than buffering the
          // session's output against a terminator that is not coming.
          counts.malformed += 1;
          report({ kind: "unterminated" });
          scan = start + 1;
          continue;
        }
        break;
      }
      const replacement = replace(input.toString("latin1", bodyStart, end));
      out.push(replacement ?? input.subarray(start, end + ST.length));
      cursor = scan = end + ST.length;
    }
    return { out: Buffer.concat(out), rest: input.subarray(cursor) };
  }

  return {
    /// Filter one chunk of the stream.
    ///
    /// Never throws and never rejects input. Any internal failure latches this
    /// splicer into pure passthrough for the rest of the session -- a preview
    /// that stops being fast is a nuisance, and a session whose output has
    /// stopped arriving is not.
    push(chunk) {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      counts.bytesIn += buffer.length;
      if (panicked) {
        counts.bytesOut += buffer.length;
        return buffer;
      }
      const input = pending.length === 0 ? buffer : Buffer.concat([pending, buffer]);
      let out;
      try {
        const scanned = drain(input);
        pending = scanned.rest;
        out = scanned.out;
      } catch (error) {
        panicked = String(error?.message ?? error);
        report({ kind: "panic", reason: panicked });
        // `input` is everything that was held plus everything just read, and
        // nothing has been written from it yet. Passing it through whole is the
        // only outcome that neither duplicates nor loses a byte.
        pending = Buffer.alloc(0);
        out = input;
      }
      counts.bytesOut += out.length;
      return out;
    },

    /// Release anything held back. The stream has ended, so a partial token
    /// will never complete and must not be swallowed with it.
    flush() {
      const held = pending;
      pending = Buffer.alloc(0);
      counts.bytesOut += held.length;
      return held;
    },

    stats() {
      return { ...counts, held: pending.length, panicked };
    },
  };
}
