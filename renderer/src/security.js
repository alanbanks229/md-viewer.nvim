import fs from "node:fs";
import path from "node:path";

const TYPES = new Map([
  [".png", "image/png"], [".jpg", "image/jpeg"], [".jpeg", "image/jpeg"],
  [".gif", "image/gif"], [".webp", "image/webp"],
]);

function magicMatches(buffer, extension) {
  if (extension === ".png") return buffer.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  if (extension === ".jpg" || extension === ".jpeg") return buffer[0] === 0xff && buffer[1] === 0xd8;
  if (extension === ".gif") return buffer.subarray(0, 6).toString("ascii") === "GIF87a" || buffer.subarray(0, 6).toString("ascii") === "GIF89a";
  if (extension === ".webp") return buffer.subarray(0, 4).toString("ascii") === "RIFF" && buffer.subarray(8, 12).toString("ascii") === "WEBP";
  return false;
}

export function isInside(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== ".." && !path.isAbsolute(relative));
}

// Every non-rendered image reports why, in a shape shared with remote
// resolution (remote-images.js): `{ ok: true, dataUri }` when the image may
// render, else `{ ok: false, kind, label }`. `kind` is "blocked" (refused by
// policy without attempting a read) or "failed" (attempted and unusable); the
// label is short human text that ends up inside the visible placeholder.
function blocked(label) { return { ok: false, kind: "blocked", label }; }
function failed(label) { return { ok: false, kind: "failed", label }; }

export function resolveLocalImage(source, options) {
  if (!options.localImages) return blocked("local images are disabled");
  // https?: sources are dispatched to the remote resolver before this function
  // is consulted; the guard stays as defense in depth. Protocol-relative and
  // data:/file: sources are refused outright, matching the link policy.
  if (/^(?:https?:|\/\/)/i.test(source)) return blocked("remote images are disabled");
  if (/^(?:data:|file:)/i.test(source)) return blocked("unsupported URL scheme");
  let decoded;
  try { decoded = decodeURIComponent(source.split(/[?#]/, 1)[0]); } catch { return failed("malformed image path"); }
  const lexical = path.resolve(options.baseDir, decoded);
  let root;
  try { root = fs.realpathSync(options.documentRoot); } catch { return failed("document root is unavailable"); }
  let canonical;
  try { canonical = fs.realpathSync(lexical); } catch { return failed("file not found"); }
  if (!isInside(root, canonical)) return blocked("outside the document root");
  const extension = path.extname(canonical).toLowerCase();
  const mime = TYPES.get(extension);
  if (!mime) return blocked(extension === ".svg" ? "SVG is not supported" : "unsupported image type");
  let data;
  try {
    const stat = fs.statSync(canonical);
    if (!stat.isFile()) return failed("not a regular file");
    if (stat.size > options.maxLocalImageBytes) return failed("larger than max_local_image_bytes");
    data = fs.readFileSync(canonical);
  } catch { return failed("file is unreadable"); }
  if (!magicMatches(data, extension)) return failed(`contents are not a valid ${extension.slice(1).toUpperCase()} image`);
  return { ok: true, dataUri: `data:${mime};base64,${data.toString("base64")}` };
}

// Remote bytes arrive with no trusted filename, so the type is derived from
// the magic bytes alone -- the inverse of magicMatches, which checks bytes
// against a claimed extension. The JPEG check is one byte stricter (FF D8 FF)
// than the local two-byte check because the peer is untrusted.
export function sniffImageType(buffer) {
  if (buffer.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return { extension: ".png", mime: "image/png" };
  if (buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) return { extension: ".jpg", mime: "image/jpeg" };
  const head = buffer.subarray(0, 6).toString("ascii");
  if (head === "GIF87a" || head === "GIF89a") return { extension: ".gif", mime: "image/gif" };
  if (buffer.subarray(0, 4).toString("ascii") === "RIFF" && buffer.subarray(8, 12).toString("ascii") === "WEBP") return { extension: ".webp", mime: "image/webp" };
  return null;
}

// Unconditional by design: the browser never makes a network request, full
// stop. Remote images do not relax this -- they are fetched by the Node
// process (remote-images.js) and arrive at the page as data: URIs, so this
// route is the enforcement that keeps remote image fetching scoped to image
// bytes rather than becoming general page networking. There is deliberately
// no parameter to loosen it.
export function installNetworkPolicy(context) {
  return context.route("**/*", async (route) => {
    const url = route.request().url();
    if (url.startsWith("data:") || url.startsWith("about:")) {
      await route.continue();
    } else {
      await route.abort("blockedbyclient");
    }
  });
}

export const csp = [
  "default-src 'none'", "img-src data:", "style-src 'unsafe-inline'",
  "script-src 'none'", "font-src 'none'", "media-src 'none'",
  "frame-src 'none'", "connect-src 'none'", "object-src 'none'", "base-uri 'none'",
].join("; ");
