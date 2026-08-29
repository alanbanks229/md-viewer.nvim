// The byte-stream tokenizer the local helper's filter is built on.
//
// It sits between `ssh`'s stdout and the real terminal and does exactly two
// things to the stream: it deletes marker APCs whose token matches, and it
// reports where a whole graphics transaction could be inserted without landing
// inside someone else's escape sequence. Everything else is identity, and the
// identity is structural rather than hoped-for: bytes stream straight through
// unless they belong to the one bounded region that might still become a
// marker (`pending`), and that region is either flushed verbatim the moment a
// byte disagrees or dropped whole when the token matches. Nothing is ever
// rewritten. `tests/node/local-stream-parser.test.js` fuzzes the identity
// across random content and random chunkings.
//
// The machine understands sequence *framing*, never sequence *meaning*: a
// filter that needs to know what a CSI does in order to stay safe has become a
// terminal emulator, which is this design's kill criterion. The states are the
// ECMA-48 framing set (ESC, intermediates, CSI, and the string family
// OSC/DCS/SOS/PM/APC) plus two refinements inside APC: a payload starting `G`
// is Kitty graphics -- streamed through, but its control string is read so an
// open `m=1` transmission blocks injection, and transmit payload bytes are
// counted (that counter is the fallback-mode evidence that raster bytes
// crossed the remote link) -- and a payload starting `M` is a marker
// candidate, withheld until the token prefix decides swallow or flush.
//
// 8-bit C1 controls (0x9B CSI, 0x9F APC, ...) are deliberately not recognized:
// in a UTF-8 stream those bytes are continuation bytes, and treating them as
// C1 would misparse ordinary text. Neovim and every terminal this plugin
// supports emit 7-bit sequences.
//
// UTF-8 lead/continuation state is tracked in GROUND for one reason only: an
// injection landing between a lead byte and its continuations aborts the
// codepoint into a replacement glyph. Invalid UTF-8 passes through untouched
// -- the tracker exists for boundary safety, not validation.

const GROUND = "ground";
const ESC = "esc";
const ESC_INT = "esc-int";
const CSI = "csi";
const STRING = "string"; // OSC / DCS / SOS / PM / APC bodies, refined by stringKind

const KIND_OSC = "osc";
const KIND_STR = "str"; // DCS, SOS, PM: ST-terminated, otherwise opaque
const KIND_APC_INTRO = "apc-intro"; // ESC _ seen, first payload byte pending
const KIND_APC_OPAQUE = "apc";
const KIND_KITTY = "kitty";
const KIND_MARKER = "marker";

// A non-matching `ESC _ M` flood from a hostile document costs the filter
// nothing: the candidate is flushed the moment one byte disagrees with the
// token prefix, so only the genuine token holder can make the filter buffer.
// A matching candidate is still bounded -- past this, it is flushed verbatim
// and the terminal's own unknown-APC tolerance disposes of it.
const MARKER_CANDIDATE_MAX = 4096;

// Control strings on real Kitty commands are tens of bytes. A "control" that
// never reaches its `;` stops being introspected but keeps streaming.
const KITTY_CONTROL_MAX = 256;

const BEL = 0x07;
const ESC_BYTE = 0x1b;

function utf8Lead(byte) {
  if (byte >= 0xc0 && byte <= 0xdf) return 1;
  if (byte >= 0xe0 && byte <= 0xef) return 2;
  if (byte >= 0xf0 && byte <= 0xf7) return 3;
  return 0;
}

export class StreamParser {
  /// `markerPrefix` is the exact string a marker payload must start with,
  /// after the `M` discriminator -- `v=1;t=<token>;` -- or null to treat
  /// every candidate as foreign (the fallback-counting configuration).
  /// `onData(buffer)` receives passthrough bytes in order; `onMarker(payload)`
  /// receives each swallowed marker's payload string (everything between
  /// `ESC _ M` and its ST).
  constructor({ markerPrefix = null, onData, onMarker } = {}) {
    this.prefix = markerPrefix;
    this.onData = onData ?? (() => {});
    this.onMarker = onMarker ?? (() => {});

    this.state = GROUND;
    this.stringKind = null;
    this.escPending = false; // inside STRING: ESC seen, terminator undecided
    this.utf8Remaining = 0;

    // The one withheld region: a possible marker being disambiguated (plus
    // the 1-2 framing bytes of any escape opener before its kind is known).
    // Bounded by MARKER_CANDIDATE_MAX plus framing; everything not in here
    // has already been emitted.
    this.pending = [];
    this.markerCommitted = false;
    this.markerPrefixPos = 0;

    // Kitty introspection.
    this.kittyControl = "";
    this.kittyControlDone = false;
    this.kittyPayloadIsRaster = false;
    this.kittyPayloadIsMdv = false;
    this.transmissionOpen = false; // an m=1 chunk train is in progress
    this.openIsRaster = false; // ...and it carries transmit payload
    this.openIsMdv = false; // ...attributed to an md-viewer id space

    this.stats = {
      passthroughBytes: 0,
      markerCount: 0,
      markerBytes: 0, // swallowed, including the ESC _ M ... ST framing
      rejectedCandidates: 0, // ESC _ M that failed the token prefix
      malformedMarkers: 0, // committed candidates aborted or over the cap
      remoteGraphicsCommands: 0, // Kitty APCs that arrived in the stream
      remoteRasterBytes: 0, // payload bytes of transmit trains -- fallback PNGs
      // The attribution split of the two counters above, by image id space.
      // md-viewer's direct path allocates ids in pid-seeded ranges with
      // recognizable high bytes (kitty_raw.lua: 0x4d frames, 0x5e animation,
      // 0x6d sheets), so a graphics command naming one of those ids came from
      // *some* md-viewer session rendering direct bytes through this wire --
      // an earlier PNG-mode run, a plugin instance without local mode, or a
      // demoted session. It cannot say which; the active session's own
      // fallback counters answer that. What the split settles is the other
      // direction: raster that is *not* md-viewer-shaped belongs to some
      // other program in the wrapped session, and is not this plugin's to
      // explain. (rc9's 1.7 MB on a healthy local session was exactly this
      // ambiguity, measured on the laptop 2026-08-27.)
      remoteMdvGraphicsCommands: 0,
      remoteMdvRasterBytes: 0,
    };
  }

  /// True exactly when a whole transaction can be inserted here: not inside
  /// any escape sequence, not between a UTF-8 lead and its continuations, and
  /// no Kitty transmission awaiting continuation chunks (interleaving any
  /// graphics command inside an m=1 train corrupts it -- the same rule
  /// `kitty_raw.lua` documents for its own writes).
  atSafeBoundary() {
    return this.state === GROUND && this.utf8Remaining === 0 && !this.transmissionOpen && this.pending.length === 0;
  }

  push(chunk) {
    if (!Buffer.isBuffer(chunk)) chunk = Buffer.from(chunk);
    // Bytes in states that cannot become part of a marker stream out as one
    // contiguous run per push; only the pending region does per-byte work.
    this.runStart = 0;
    for (let i = 0; i < chunk.length; i += 1) {
      this.byte(chunk, i);
    }
    this.emitRun(chunk, chunk.length);
  }

  /// Flush anything withheld, verbatim. Call on teardown so a truncated
  /// candidate can never swallow real bytes.
  flush() {
    this.releasePending();
    if (this.stringKind === KIND_MARKER) this.stringKind = KIND_APC_OPAQUE;
  }

  // -- internals ----------------------------------------------------------

  emit(buf) {
    if (buf.length === 0) return;
    this.stats.passthroughBytes += buf.length;
    this.onData(buf);
  }

  emitRun(chunk, endExclusive) {
    if (endExclusive > this.runStart) this.emit(chunk.subarray(this.runStart, endExclusive));
    this.runStart = endExclusive;
  }

  releasePending() {
    if (this.pending.length > 0) {
      this.emit(Buffer.from(this.pending));
      this.pending = [];
    }
    this.markerCommitted = false;
    this.markerPrefixPos = 0;
  }

  // The current byte leaves the streaming run and joins the withheld region.
  hold(chunk, i, byte) {
    this.emitRun(chunk, i);
    this.runStart = i + 1;
    this.pending.push(byte);
  }

  // A withheld ESC turned out to abort a string: everything before it flushes
  // verbatim, the ESC itself stays withheld as the opener of a new sequence,
  // and the current byte is re-examined in ESC state.
  abortStringToEsc(chunk, i) {
    const esc = this.pending.pop();
    this.releasePending();
    this.pending = [esc];
    this.escPending = false;
    this.stringKind = null;
    this.state = ESC;
    this.byte(chunk, i);
  }

  byte(chunk, i) {
    const b = chunk[i];
    switch (this.state) {
      case GROUND: {
        if (b === ESC_BYTE) {
          this.state = ESC;
          this.utf8Remaining = 0; // an ESC mid-codepoint abandons it
          this.hold(chunk, i, b);
        } else if (this.utf8Remaining > 0) {
          this.utf8Remaining = b >= 0x80 && b <= 0xbf ? this.utf8Remaining - 1 : utf8Lead(b);
        } else {
          this.utf8Remaining = utf8Lead(b);
        }
        return;
      }

      case ESC: {
        if (b === 0x5f) {
          // ESC _ : an APC whose first payload byte will pick kitty, marker,
          // or opaque. Stay withheld until then.
          this.state = STRING;
          this.stringKind = KIND_APC_INTRO;
          this.hold(chunk, i, b);
          return;
        }
        if (b === ESC_BYTE) {
          // ESC ESC: the first escape was complete on its own; restart.
          this.releasePending();
          this.hold(chunk, i, b);
          return;
        }
        // Any other opener can never become a marker: release the ESC and
        // stream from here.
        this.pending.push(b);
        this.releasePending();
        this.runStart = i + 1;
        if (b === 0x5b) this.state = CSI;
        else if (b === 0x5d) {
          this.state = STRING;
          this.stringKind = KIND_OSC;
        } else if (b === 0x50 || b === 0x58 || b === 0x5e) {
          this.state = STRING; // DCS / SOS / PM
          this.stringKind = KIND_STR;
        } else if (b >= 0x20 && b <= 0x2f) this.state = ESC_INT;
        else this.state = GROUND; // single-character sequence (ESC c, ESC 7, ...)
        return;
      }

      case ESC_INT: {
        if (b === ESC_BYTE) {
          this.state = ESC;
          this.hold(chunk, i, b);
          return;
        }
        if (!(b >= 0x20 && b <= 0x2f)) this.state = GROUND; // final byte closes it
        return;
      }

      case CSI: {
        if (b === ESC_BYTE) {
          this.state = ESC;
          this.hold(chunk, i, b);
          return;
        }
        if ((b >= 0x40 && b <= 0x7e) || b === 0x18 || b === 0x1a) this.state = GROUND;
        // Params, intermediates, and embedded C0 stay in CSI.
        return;
      }

      case STRING: {
        if (this.escPending) {
          this.escPending = false;
          if (b !== 0x5c) {
            // ESC + anything but `\` aborts the string; the ESC opens a new
            // sequence. A withheld marker flushes verbatim first -- identity
            // is the failure mode for malformed input, never interpretation.
            if (this.stringKind === KIND_MARKER) {
              if (this.markerCommitted) this.stats.malformedMarkers += 1;
              else this.stats.rejectedCandidates += 1;
            }
            this.abortStringToEsc(chunk, i);
            return;
          }
          // ST: the string ends.
          const kind = this.stringKind;
          this.state = GROUND;
          this.stringKind = null;
          if (kind === KIND_MARKER) {
            this.pending.push(b);
            if (this.markerCommitted) {
              const payload = Buffer.from(this.pending.slice(3, -2)).toString("latin1");
              this.stats.markerCount += 1;
              this.stats.markerBytes += this.pending.length;
              this.pending = [];
              this.markerCommitted = false;
              this.markerPrefixPos = 0;
              this.onMarker(payload);
            } else {
              // `ESC _ M` that ended before the prefix could match.
              this.stats.rejectedCandidates += 1;
              this.releasePending();
            }
            this.runStart = i + 1;
          } else {
            // The terminator's ESC -- and, for an APC that ended before its
            // first payload byte, the whole withheld `ESC _` -- must flow out
            // ahead of this `\`, which is still in the streaming run.
            this.releasePending();
            if (kind === KIND_KITTY) this.finishKittyControl();
          }
          return;
        }

        if (b === ESC_BYTE) {
          this.escPending = true;
          this.hold(chunk, i, b);
          return;
        }

        switch (this.stringKind) {
          case KIND_APC_INTRO: {
            if (b === 0x4d) {
              this.stringKind = KIND_MARKER;
              this.markerCommitted = this.prefix !== null && this.prefix.length === 0;
              this.markerPrefixPos = 0;
              this.hold(chunk, i, b);
              return;
            }
            // Kitty or opaque: neither is ever swallowed, so release the
            // withheld `ESC _` and stream the body.
            this.pending.push(b);
            this.releasePending();
            this.runStart = i + 1;
            if (b === 0x47) {
              this.stringKind = KIND_KITTY;
              this.kittyControl = "";
              this.kittyControlDone = false;
              this.kittyPayloadIsRaster = false;
              this.stats.remoteGraphicsCommands += 1;
            } else {
              this.stringKind = KIND_APC_OPAQUE;
            }
            return;
          }

          case KIND_MARKER: {
            this.hold(chunk, i, b);
            if (this.markerCommitted) {
              if (this.pending.length > MARKER_CANDIDATE_MAX) {
                this.stats.malformedMarkers += 1;
                this.stringKind = KIND_APC_OPAQUE;
                this.releasePending();
                this.runStart = i + 1;
              }
              return;
            }
            if (this.prefix === null || this.prefix.charCodeAt(this.markerPrefixPos) !== b) {
              this.stats.rejectedCandidates += 1;
              this.stringKind = KIND_APC_OPAQUE;
              this.releasePending();
              this.runStart = i + 1;
              return;
            }
            this.markerPrefixPos += 1;
            if (this.markerPrefixPos === this.prefix.length) this.markerCommitted = true;
            return;
          }

          case KIND_KITTY: {
            if (!this.kittyControlDone) {
              if (b === 0x3b) {
                this.kittyControlDone = true;
                this.applyKittyControl();
              } else if (this.kittyControl.length < KITTY_CONTROL_MAX) {
                this.kittyControl += String.fromCharCode(b);
              }
            } else if (this.kittyPayloadIsRaster) {
              this.stats.remoteRasterBytes += 1;
              if (this.kittyPayloadIsMdv) this.stats.remoteMdvRasterBytes += 1;
            }
            return;
          }

          default: {
            // OSC ends at BEL as well as ST; DCS/SOS/PM and opaque APC only
            // at ST. Bodies stream through untouched either way.
            if (b === BEL && this.stringKind === KIND_OSC) {
              this.state = GROUND;
              this.stringKind = null;
            }
            return;
          }
        }
      }

      default:
        throw new Error(`md-viewer stream-parser: unreachable state ${this.state}`);
    }
  }

  applyKittyControl() {
    const control = this.kittyControl;
    const action = /(?:^|,)a=([a-zA-Z])(?:,|$)/.exec(control)?.[1] ?? null;
    const more = /(?:^|,)m=([01])(?:,|$)/.exec(control)?.[1] ?? null;

    if (action !== null || !this.transmissionOpen) {
      // A fresh command. Transmit-family actions (`t`, `T`, and frame data
      // `f`) are the ones whose payload is pixels.
      const raster = action === "t" || action === "T" || action === "f";
      // Attribution by id space: the high byte of `i=` tells an md-viewer
      // direct session's command apart from any other program's. Ids are
      // 32-bit, so the arithmetic stays exact in a double.
      const id = /(?:^|,)i=(\d+)(?:,|$)/.exec(control)?.[1] ?? null;
      const high = id === null ? null : Math.floor(Number(id) / 0x1000000);
      const mdv = high === 0x4d || high === 0x5e || high === 0x6d;
      this.kittyPayloadIsRaster = raster;
      this.kittyPayloadIsMdv = mdv;
      if (mdv) this.stats.remoteMdvGraphicsCommands += 1;
      if (more === "1") {
        this.transmissionOpen = true;
        this.openIsRaster = raster;
        this.openIsMdv = mdv;
      } else {
        this.transmissionOpen = false;
        this.openIsRaster = false;
        this.openIsMdv = false;
      }
    } else {
      // Continuation chunk of the open train (control like `q=2,m=N`). It
      // carries no id of its own; it belongs to whoever opened the train.
      this.kittyPayloadIsRaster = this.openIsRaster;
      this.kittyPayloadIsMdv = this.openIsMdv;
      if (this.openIsMdv) this.stats.remoteMdvGraphicsCommands += 1;
      if (more !== "1") {
        this.transmissionOpen = false;
        this.openIsRaster = false;
        this.openIsMdv = false;
      }
    }
  }

  finishKittyControl() {
    // ST arrived. A command whose control never reached `;` still affects
    // transmission state (`a=t,m=1` with no payload is legal).
    if (!this.kittyControlDone) this.applyKittyControl();
    this.kittyControlDone = false;
    this.kittyPayloadIsRaster = false;
    this.kittyPayloadIsMdv = false;
  }
}

export { MARKER_CANDIDATE_MAX };
