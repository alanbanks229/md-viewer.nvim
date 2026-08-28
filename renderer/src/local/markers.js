// The marker grammar: one of today's single-write graphics transactions,
// serialized small enough to ride the terminal stream in place of megabytes
// of base64.
//
// A marker is an APC the filter swallows: `ESC _ M <payload> ESC \`. The
// payload is deterministic field concatenation, not JSON -- the Lua emitter
// and this parser must agree byte-for-byte and neither language guarantees
// table-key order:
//
//   v=1;t=<token>;s=<seq>;d=<doc>;[k=1;][u=<upload>;...]p=<b64>;x=<b64>
//
// `d=` names the document (session) the whole transaction belongs to; the
// injector's supersession and ordering rules are per-document, and a
// deletion-only transaction has no upload to carry the name. A transaction
// with no document (global teardown) uses the sentinel `-`.
//
// `k=1` marks a transaction that *removes content* (hide, retire, clear):
// it must also kill any frame still pending for its document, or a hidden
// window gets fresh pixels injected onto it moments after being hidden. The
// flag exists because the emitter knows which operation it is building and
// the injector is forbidden to learn it by parsing the deletion bytes.
//
// `u=` describes an upload by *reference* -- pixels the helper must produce,
// never pixels on the wire. Two kinds:
//
//   u=f,i=<imageId>,r=<rev>,y=<scrollY>,e=<epoch>,w=<wCss>,h=<hCss>,c=<scale>
//   u=s,i=<imageId>,g=<rrggbbaa>,w=<wPx>,h=<hPx>,x=<marginX>,y=<marginY>
//
// `p=`/`x=` are the *literal escape bytes* the Lua placement/deletion
// builders produced, base64ed only because APC payloads cannot carry a raw
// ESC. They are split into two fields -- rather than one opaque body --
// because supersession must be able to drop a stale frame's placements while
// carrying its deletions forward; with one blob the injector could not
// separate them without parsing escapes, which is exactly what this design
// forbids it to do.
//
// Token first, version second: an old helper must pass an unrecognized-token
// marker through untouched before it ever looks at `v=`, so a future v=2
// marker from a mismatched checkout degrades to inert passthrough rather
// than a half-parse.

const DOC_SAFE = /^[A-Za-z0-9_-]+$/;
const MAX_UPLOADS = 8;
const MAX_BODY_BYTES = 64 * 1024;

export function markerPrefix(token) {
  return `v=1;t=${token};`;
}

export function encodeDoc(doc) {
  if (DOC_SAFE.test(doc)) return doc;
  return Array.from(doc, (ch) =>
    /[A-Za-z0-9_-]/.test(ch) ? ch : Array.from(Buffer.from(ch, "utf8"), (b) => `%${b.toString(16).padStart(2, "0")}`).join("")
  ).join("");
}

export function decodeDoc(encoded) {
  return encoded.replace(/%([0-9a-fA-F]{2})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));
}

function formatNumber(value) {
  if (!Number.isFinite(value)) throw new Error(`marker field is not a finite number: ${value}`);
  return String(value);
}

function encodeUpload(upload) {
  if (upload.kind === "frame") {
    return [
      "u=f",
      `i=${formatNumber(upload.id)}`,
      `r=${upload.rev}`,
      `y=${formatNumber(upload.scrollY)}`,
      `e=${formatNumber(upload.epoch)}`,
      `w=${formatNumber(upload.widthPx)}`,
      `h=${formatNumber(upload.heightPx)}`,
      `c=${formatNumber(upload.scale)}`,
    ].join(",");
  }
  if (upload.kind === "sheet") {
    return [
      "u=s",
      `i=${formatNumber(upload.id)}`,
      `g=${upload.tint}`,
      `w=${formatNumber(upload.widthPx)}`,
      `h=${formatNumber(upload.heightPx)}`,
      `x=${formatNumber(upload.marginX)}`,
      `y=${formatNumber(upload.marginY)}`,
    ].join(",");
  }
  throw new Error(`unknown upload kind: ${upload.kind}`);
}

export function buildMarkerPayload({
  token,
  seq,
  doc = "-",
  kill = false,
  uploads = [],
  placements = Buffer.alloc(0),
  deletions = Buffer.alloc(0),
}) {
  if (uploads.length > MAX_UPLOADS) throw new Error(`marker carries ${uploads.length} uploads; the bound is ${MAX_UPLOADS}`);
  const parts = [markerPrefix(token), `s=${formatNumber(seq)};d=${encodeDoc(doc)};`];
  if (kill) parts.push("k=1;");
  for (const upload of uploads) parts.push(`${encodeUpload(upload)};`);
  parts.push(`p=${Buffer.from(placements).toString("base64")};`);
  parts.push(`x=${Buffer.from(deletions).toString("base64")}`);
  return parts.join("");
}

export function wrapMarker(payload) {
  return Buffer.from(`\x1b_M${payload}\x1b\\`, "latin1");
}

function parseUpload(value) {
  const fields = value.split(",");
  const kindTag = fields.shift();
  const map = new Map();
  for (const field of fields) {
    const eq = field.indexOf("=");
    if (eq < 1) throw new Error(`malformed upload field: ${field}`);
    map.set(field.slice(0, eq), field.slice(eq + 1));
  }
  const num = (key) => {
    const raw = map.get(key);
    const value2 = Number(raw);
    if (raw === undefined || !Number.isFinite(value2)) throw new Error(`upload ${kindTag} missing numeric ${key}`);
    return value2;
  };
  if (kindTag === "f") {
    const rev = map.get("r");
    if (rev === undefined || !/^[0-9:]+$/.test(rev)) throw new Error("frame upload has no usable revision");
    return {
      kind: "frame",
      id: num("i"),
      rev,
      scrollY: num("y"),
      epoch: num("e"),
      widthPx: num("w"),
      heightPx: num("h"),
      scale: num("c"),
    };
  }
  if (kindTag === "s") {
    const tint = map.get("g");
    if (!/^[0-9a-fA-F]{8}$/.test(tint ?? "")) throw new Error("sheet upload tint is not rrggbbaa");
    return {
      kind: "sheet",
      id: num("i"),
      tint: tint.toLowerCase(),
      widthPx: num("w"),
      heightPx: num("h"),
      marginX: num("x"),
      marginY: num("y"),
    };
  }
  throw new Error(`unknown upload kind tag: ${kindTag}`);
}

/// Parse a payload the stream parser swallowed (it has already verified the
/// `v=1;t=<token>;` prefix byte-for-byte; this re-reads it for the fields and
/// validates everything behind it). Throws on anything malformed -- the
/// caller counts and drops, it never guesses.
export function parseMarkerPayload(payload) {
  const fields = payload.split(";");
  const out = { uploads: [], placements: null, deletions: null, token: null, seq: null, doc: null, kill: false };
  let sawVersion = false;
  for (let i = 0; i < fields.length; i += 1) {
    const field = fields[i];
    const eq = field.indexOf("=");
    if (eq < 1) throw new Error(`malformed marker field: ${JSON.stringify(field)}`);
    const key = field.slice(0, eq);
    const value = field.slice(eq + 1);
    switch (key) {
      case "v":
        if (value !== "1") throw new Error(`unsupported marker version: ${value}`);
        sawVersion = true;
        break;
      case "t":
        out.token = value;
        break;
      case "d":
        out.doc = decodeDoc(value);
        break;
      case "k":
        if (value !== "1") throw new Error(`marker kill flag must be 1 when present: ${value}`);
        out.kill = true;
        break;
      case "s": {
        const seq = Number(value);
        if (!Number.isInteger(seq) || seq < 0) throw new Error(`marker seq is not a non-negative integer: ${value}`);
        out.seq = seq;
        break;
      }
      case "u":
        out.uploads.push(parseUpload(value));
        if (out.uploads.length > MAX_UPLOADS) throw new Error("marker exceeds the upload bound");
        break;
      case "p":
        out.placements = Buffer.from(value, "base64");
        break;
      case "x":
        out.deletions = Buffer.from(value, "base64");
        break;
      default:
        throw new Error(`unknown marker field: ${key}`);
    }
  }
  if (!sawVersion || out.token === null || out.seq === null || out.doc === null || out.placements === null || out.deletions === null) {
    throw new Error("marker is missing a required field");
  }
  if (out.placements.length + out.deletions.length > MAX_BODY_BYTES) {
    throw new Error("marker body exceeds the size bound");
  }
  return out;
}

export { MAX_UPLOADS, MAX_BODY_BYTES };
