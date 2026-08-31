import test from "node:test";
import assert from "node:assert/strict";
import { StreamParser, MARKER_CANDIDATE_MAX } from "../../renderer/src/local/stream-parser.js";

// The property under test is the filter's whole safety argument: for any byte
// stream containing no matched-token marker, the parser's output is the input,
// byte for byte, under every chunking -- and a matched marker is removed
// exactly, leaving everything around it untouched. If this file cannot hold
// that line without modelling what sequences *mean*, the filter design is dead
// (the K5 kill criterion), so the fuzz corpus below leans on adversarial
// framing -- split escapes, aborted strings, lookalike markers, invalid UTF-8
// -- rather than on realistic terminal traffic.

const TOKEN = "00112233445566778899aabbccddeeff";
const PREFIX = `v=1;t=${TOKEN};`;
const ESC = "\x1b";
const ST = "\x1b\\";

function marker(payloadAfterPrefix) {
  return Buffer.from(`${ESC}_M${PREFIX}${payloadAfterPrefix}${ST}`, "latin1");
}

function run(input, { chunks = [input], markerPrefix = PREFIX, flush = true } = {}) {
  const out = [];
  const markers = [];
  const parser = new StreamParser({
    markerPrefix,
    onData: (buf) => out.push(Buffer.from(buf)),
    onMarker: (payload) => markers.push(payload),
  });
  for (const chunk of chunks) parser.push(chunk);
  if (flush) parser.flush();
  return { out: Buffer.concat(out), markers, parser };
}

function everySplit(input, fn) {
  for (let cut = 1; cut < input.length; cut += 1) {
    fn([input.subarray(0, cut), input.subarray(cut)], cut);
  }
}

test("plain text, escape sequences, and strings pass through byte-identically", () => {
  const input = Buffer.from(
    `plain text\r\n${ESC}[31mred${ESC}[0m ${ESC}]0;title\x07 ${ESC}]2;t${ST}` +
      `${ESC}P+q544e${ST}${ESC}(B${ESC}7 café \u{1f600} ${ESC}_Ga=p,i=5,q=2;${ST}tail`,
    "utf8"
  );
  const { out, markers } = run(input);
  assert.deepEqual(out, input);
  assert.deepEqual(markers, []);
});

test("every split point of a stream mixing escapes and text preserves identity and stats", () => {
  const input = Buffer.from(`a${ESC}[1;2Hb${ESC}]0;x\x07c${ESC}_Ga=d,d=i,q=2,i=9;${ST}dé${ESC}7e`, "utf8");
  const whole = run(input);
  assert.deepEqual(whole.out, input);
  everySplit(input, (chunks, cut) => {
    const split = run(input, { chunks });
    assert.deepEqual(split.out, input, `split at ${cut} changed bytes`);
    assert.deepEqual(split.parser.stats, whole.parser.stats, `split at ${cut} changed stats`);
  });
});

test("a matched marker is swallowed exactly, whatever the chunking", () => {
  const body = "s=41;AAAABBBB";
  const input = Buffer.concat([Buffer.from("before"), marker(body), Buffer.from(`after${ESC}[2Jrest`)]);
  const expected = Buffer.from(`before` + `after${ESC}[2Jrest`);
  const whole = run(input);
  assert.deepEqual(whole.out, expected);
  assert.deepEqual(whole.markers, [`${PREFIX}${body}`]);
  assert.equal(whole.parser.stats.markerCount, 1);
  assert.equal(whole.parser.stats.markerBytes, marker(body).length);
  everySplit(input, (chunks, cut) => {
    const split = run(input, { chunks });
    assert.deepEqual(split.out, expected, `split at ${cut}`);
    assert.deepEqual(split.markers, whole.markers, `split at ${cut}`);
  });
});

test("one-byte chunks behave identically to one big push", () => {
  const input = Buffer.concat([
    Buffer.from(`x${ESC}[31m`),
    marker("s=1;Z"),
    Buffer.from(`${ESC}_Ga=t,f=100,t=d,q=2,i=7,m=1;QUJD${ST}${ESC}_Gq=2,m=0;RUZH${ST}y`),
  ]);
  const whole = run(input);
  const bytes = run(input, { chunks: [...input].map((b) => Buffer.from([b])) });
  assert.deepEqual(bytes.out, whole.out);
  assert.deepEqual(bytes.markers, whole.markers);
  assert.deepEqual(bytes.parser.stats, whole.parser.stats);
});

test("a candidate with the wrong token flushes verbatim and costs one rejection", () => {
  const input = Buffer.from(`a${ESC}_Mv=1;t=ffff;s=1;XX${ST}b`, "latin1");
  const { out, markers, parser } = run(input);
  assert.deepEqual(out, input);
  assert.deepEqual(markers, []);
  assert.equal(parser.stats.rejectedCandidates, 1);
});

test("with no token configured every candidate is foreign", () => {
  const input = Buffer.concat([Buffer.from("a"), marker("s=1;XX"), Buffer.from("b")]);
  const { out, markers, parser } = run(input, { markerPrefix: null });
  assert.deepEqual(out, input);
  assert.deepEqual(markers, []);
  assert.equal(parser.stats.rejectedCandidates, 1);
});

test("an APC that ends before the prefix decides flushes verbatim", () => {
  for (const raw of [`${ESC}_M${ST}`, `${ESC}_Mv=1;${ST}`, `${ESC}_${ST}`, `${ESC}_Q-opaque${ST}`]) {
    const input = Buffer.from(`L${raw}R`, "latin1");
    const { out, markers } = run(input);
    assert.deepEqual(out, input, JSON.stringify(raw));
    assert.deepEqual(markers, []);
  }
});

test("a committed marker aborted by a new escape flushes verbatim as malformed", () => {
  const input = Buffer.from(`a${ESC}_M${PREFIX}s=1;AA${ESC}[31mb`, "latin1");
  const { out, markers, parser } = run(input);
  assert.deepEqual(out, input);
  assert.deepEqual(markers, []);
  assert.equal(parser.stats.malformedMarkers, 1);
});

test("a committed marker over the size cap flushes verbatim rather than buffering", () => {
  const oversized = Buffer.from(`${ESC}_M${PREFIX}${"A".repeat(MARKER_CANDIDATE_MAX + 8)}${ST}`, "latin1");
  const input = Buffer.concat([Buffer.from("a"), oversized, Buffer.from("b")]);
  const { out, markers, parser } = run(input);
  assert.deepEqual(out, input);
  assert.deepEqual(markers, []);
  assert.equal(parser.stats.malformedMarkers, 1);
});

test("flush releases a truncated candidate so teardown cannot eat bytes", () => {
  const truncated = Buffer.from(`tail${ESC}_M${PREFIX}s=9;AA`, "latin1");
  const { out } = run(truncated);
  assert.deepEqual(out, truncated);
  const bare = Buffer.from(`x${ESC}`, "latin1");
  assert.deepEqual(run(bare).out, bare);
});

test("safe boundaries: escapes, strings, split UTF-8, and open kitty trains all block injection", () => {
  const parser = new StreamParser({ markerPrefix: PREFIX, onData: () => {} });
  assert.equal(parser.atSafeBoundary(), true);
  parser.push(Buffer.from("plain "));
  assert.equal(parser.atSafeBoundary(), true);
  parser.push(Buffer.from(`${ESC}[1;`));
  assert.equal(parser.atSafeBoundary(), false, "mid-CSI is not a boundary");
  parser.push(Buffer.from("H"));
  assert.equal(parser.atSafeBoundary(), true);
  parser.push(Buffer.from(`${ESC}]0;title`));
  assert.equal(parser.atSafeBoundary(), false, "an open OSC is not a boundary");
  parser.push(Buffer.from("\x07"));
  assert.equal(parser.atSafeBoundary(), true);

  const emoji = Buffer.from("\u{1f600}", "utf8");
  parser.push(emoji.subarray(0, 2));
  assert.equal(parser.atSafeBoundary(), false, "between a UTF-8 lead and its continuations is not a boundary");
  parser.push(emoji.subarray(2));
  assert.equal(parser.atSafeBoundary(), true);

  parser.push(Buffer.from(`${ESC}_Ga=t,f=100,t=d,q=2,i=3,m=1;QUJD${ST}`, "latin1"));
  assert.equal(parser.atSafeBoundary(), false, "an open m=1 transmission is not a boundary even between APCs");
  parser.push(Buffer.from(`${ESC}_Gq=2,m=1;RUZH${ST}`, "latin1"));
  assert.equal(parser.atSafeBoundary(), false);
  parser.push(Buffer.from(`${ESC}_Gq=2,m=0;SUpL${ST}`, "latin1"));
  assert.equal(parser.atSafeBoundary(), true, "m=0 closes the train");
});

test("remote raster bytes are counted for transmit trains and only those", () => {
  const upload =
    `${ESC}_Ga=t,f=100,t=d,q=2,i=3,m=1;${"A".repeat(64)}${ST}` +
    `${ESC}_Gq=2,m=1;${"B".repeat(64)}${ST}` +
    `${ESC}_Gq=2,m=0;${"C".repeat(16)}${ST}`;
  const placementAndDelete = `${ESC}_Ga=p,q=2,C=1,i=3,p=9,x=0,y=0;${ST}${ESC}_Ga=d,d=i,q=2,i=3,p=9;${ST}`;
  const { parser, out } = run(Buffer.from(upload + placementAndDelete, "latin1"));
  assert.equal(parser.stats.remoteRasterBytes, 64 + 64 + 16, "payload bytes of the a=t train, continuations included");
  assert.equal(parser.stats.remoteGraphicsCommands, 5);
  assert.deepEqual(out, Buffer.from(upload + placementAndDelete, "latin1"));
});

test("an empty APC and a bare ST-terminated APC intro pass through", () => {
  const input = Buffer.from(`a${ESC}_${ST}b${ESC}${ESC}7c`, "latin1");
  const { out } = run(input);
  assert.deepEqual(out, input);
});

// ---------------------------------------------------------------------------
// The fuzz rig. Deterministic (seeded), so a failure names its seed and is
// reproducible; adversarial about framing, not realism.

function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function makePieces(rand) {
  const pick = (list) => list[Math.floor(rand() * list.length)];
  const int = (max) => Math.floor(rand() * max);
  const b64 = (n) => "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnop0189+/".repeat(Math.ceil(n / 48)).slice(0, n);
  return [
    () => ({ kind: "plain", bytes: Buffer.from("word ".repeat(1 + int(6)) + pick(["fox", "over", "lazy"])) }),
    () => ({ kind: "plain", bytes: Buffer.from(pick(["café", "\u{1f600}\u{1f680}", "你好", "é"]), "utf8") }),
    () => ({ kind: "plain", bytes: Buffer.from([pick([0x00, 0x07, 0x08, 0x09, 0x0a, 0x0d, 0x7f])]) }),
    // Invalid UTF-8: a stray continuation and an overlong-ish lead with no tail.
    () => ({ kind: "plain", bytes: Buffer.from([0x80 + int(0x30), 0xc3]) }),
    () => ({ kind: "plain", bytes: Buffer.from(`${ESC}[${int(99)};${int(99)}${pick(["H", "m", "r", "J"])}`, "latin1") }),
    () => ({ kind: "plain", bytes: Buffer.from(`${ESC}${pick(["7", "8", "c", "(B", ")0", "=", ">"])}`, "latin1") }),
    () => ({ kind: "plain", bytes: Buffer.from(`${ESC}]${int(9)};title-${int(999)}${pick(["\x07", ST])}`, "latin1") }),
    () => ({ kind: "plain", bytes: Buffer.from(`${ESC}P+q${b64(8)}${ST}`, "latin1") }),
    () => ({ kind: "plain", bytes: Buffer.from(`${ESC}_Q${b64(4 + int(24))}${ST}`, "latin1") }),
    () => ({ kind: "plain", bytes: Buffer.from(`${ESC}_Ga=p,q=2,C=1,i=${int(99)},p=${int(99)};${ST}`, "latin1") }),
    () => {
      const chunks = 1 + int(3);
      let s = `${ESC}_Ga=t,f=100,t=d,q=2,i=${1 + int(50)},m=${chunks > 1 ? 1 : 0};${b64(24 + int(40))}${ST}`;
      for (let c = 1; c < chunks; c += 1) s += `${ESC}_Gq=2,m=${c === chunks - 1 ? 0 : 1};${b64(24)}${ST}`;
      return { kind: "plain", bytes: Buffer.from(s, "latin1") };
    },
    // Marker lookalikes: right shape, wrong token; or the M with no prefix at all.
    () => ({ kind: "plain", bytes: Buffer.from(`${ESC}_Mv=1;t=${"f".repeat(32)};s=${int(99)};${b64(12)}${ST}`, "latin1") }),
    () => ({ kind: "plain", bytes: Buffer.from(`${ESC}_M${pick(["", "v=", "v=2;", "nonsense"])}${ST}`, "latin1") }),
    () => ({ kind: "plain", bytes: Buffer.from(b64(64 + int(512)), "latin1") }),
    () => ({ kind: "marker", bytes: marker(`s=${int(9999)};${b64(16 + int(200))}`) }),
  ];
}

test("fuzz: identity minus matched markers, stable across chunkings", () => {
  const rand = mulberry32(0x6d642d76); // "md-v"
  const pieces = makePieces(rand);
  for (let round = 0; round < 250; round += 1) {
    const chosen = [];
    const count = 3 + Math.floor(rand() * 20);
    for (let p = 0; p < count; p += 1) chosen.push(pieces[Math.floor(rand() * pieces.length)]());
    const input = Buffer.concat(chosen.map((piece) => piece.bytes));
    const expected = Buffer.concat(chosen.filter((piece) => piece.kind !== "marker").map((piece) => piece.bytes));
    const markerCount = chosen.filter((piece) => piece.kind === "marker").length;

    const chunkings = [[input], [...input].map((b) => Buffer.from([b]))];
    for (let variant = 0; variant < 2; variant += 1) {
      const cuts = [];
      let at = 0;
      while (at < input.length) {
        at += 1 + Math.floor(rand() * 17);
        cuts.push(Math.min(at, input.length));
      }
      let prev = 0;
      chunkings.push(cuts.map((cut) => {
        const piece = input.subarray(prev, cut);
        prev = cut;
        return piece;
      }));
    }

    let reference = null;
    for (const chunks of chunkings) {
      const { out, markers, parser } = run(input, { chunks });
      assert.deepEqual(out, expected, `round ${round}: output diverged from input-minus-markers`);
      assert.equal(markers.length, markerCount, `round ${round}: marker count`);
      if (reference === null) reference = parser.stats;
      else assert.deepEqual(parser.stats, reference, `round ${round}: stats changed with chunking`);
    }
  }
});

test("remote graphics are attributed by image-id space: md-viewer's direct path vs everything else", () => {
  // 0x4d000100: a frame id exactly as kitty_raw.lua allocates them
  // (0x4d000000 + pid-seeded offset). The split answers what rc9's single
  // counter could not (laptop, 2026-08-27): whether raster arriving
  // through the remote stream came from an md-viewer session rendering
  // direct bytes, or from some unrelated program in the same wrapped
  // session.
  const mdvId = 0x4d000100;
  const mdvTrain =
    `${ESC}_Ga=t,f=100,t=d,q=2,i=${mdvId},m=1;${"A".repeat(64)}${ST}` + `${ESC}_Gq=2,m=0;${"B".repeat(32)}${ST}`;
  const mdvPlacement = `${ESC}_Ga=p,q=2,C=1,i=${mdvId},p=9,x=0,y=0;${ST}`;
  const foreign = `${ESC}_Ga=t,f=100,t=d,q=2,i=7,m=0;${"C".repeat(16)}${ST}`;
  const { parser } = run(Buffer.from(mdvTrain + mdvPlacement + foreign, "latin1"));
  assert.equal(parser.stats.remoteGraphicsCommands, 4, "the totals keep counting everything");
  assert.equal(parser.stats.remoteRasterBytes, 64 + 32 + 16);
  assert.equal(parser.stats.remoteMdvGraphicsCommands, 3, "train, its continuation, and the placement");
  assert.equal(parser.stats.remoteMdvRasterBytes, 64 + 32, "the foreign transmit is not md-viewer's to explain");
});
