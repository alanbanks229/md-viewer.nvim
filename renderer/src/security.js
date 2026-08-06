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

export function localImageDataUri(source, options) {
  if (!options.localImages || /^(?:https?:|data:|file:|\/\/)/i.test(source)) return null;
  let decoded;
  try { decoded = decodeURIComponent(source.split(/[?#]/, 1)[0]); } catch { return null; }
  const lexical = path.resolve(options.baseDir, decoded);
  let root;
  let canonical;
  try {
    root = fs.realpathSync(options.documentRoot);
    canonical = fs.realpathSync(lexical);
  } catch { return null; }
  if (!isInside(root, canonical)) return null;
  const extension = path.extname(canonical).toLowerCase();
  const mime = TYPES.get(extension);
  if (!mime) return null;
  const stat = fs.statSync(canonical);
  if (!stat.isFile() || stat.size > options.maxLocalImageBytes) return null;
  const data = fs.readFileSync(canonical);
  if (!magicMatches(data, extension)) return null;
  return `data:${mime};base64,${data.toString("base64")}`;
}

export function installNetworkPolicy(context, allowNetwork = false) {
  return context.route("**/*", async (route) => {
    const url = route.request().url();
    if (url.startsWith("data:") || url.startsWith("about:") || (allowNetwork && /^https?:/i.test(url))) {
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
