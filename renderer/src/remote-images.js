import { sniffImageType } from "./security.js";

/// Remote images are fetched HERE, in the Node process, never by the browser:
/// the Playwright route and the page CSP stay deny-all, and what reaches the
/// page is a validated `data:` URI indistinguishable from a local image. The
/// only thing that opens this path is a non-empty `security.remote_images`
/// host allowlist, re-checked on every render *before* the cache below, so a
/// config change takes effect immediately and the cache can never launder a
/// policy decision.
export const REMOTE_IMAGES = Symbol("md-viewer.remote-images");

// All renders share one serial queue (main.js), so a slow host would freeze
// every interaction for its duration. The deadline is shared by the whole
// batch of a render's fetches -- N hanging hosts still stall one render by at
// most FETCH_TIMEOUT_MS, not N times it. Failures are remembered briefly so a
// dead host costs one stall per minute, not one per keystroke.
const MAX_REDIRECTS = 3;
const FETCH_TIMEOUT_MS = 5000;
const NEGATIVE_TTL_MS = 60_000;
const MAX_CACHE_BYTES = 64 * 1024 * 1024;
const MAX_CACHE_ENTRIES = 256;

function blocked(label) { return { ok: false, kind: "blocked", label }; }
function failed(label) { return { ok: false, kind: "failed", label }; }

/// Entries are hostnames (`github.com`) or single leading wildcards
/// (`*.githubusercontent.com`). Round-tripping through the URL parser
/// lowercases, punycodes IDNs, and drops anything unparseable; the trailing
/// dot a resolver would ignore is stripped so `github.com.` cannot dodge a
/// comparison.
export function normalizeAllowlist(list) {
  const normalized = new Set();
  for (const entry of Array.isArray(list) ? list : []) {
    if (typeof entry !== "string" || entry === "") continue;
    const wildcard = entry.startsWith("*.");
    const host = wildcard ? entry.slice(2) : entry;
    let canonical;
    try { canonical = new URL(`https://${host}`).hostname.replace(/\.$/, ""); } catch { continue; }
    if (!canonical) continue;
    normalized.add(wildcard ? `*.${canonical}` : canonical);
  }
  return [...normalized].sort();
}

/// `*.example.com` matches proper subdomains only: the required dot boundary
/// means `evil-example.com` never matches, and neither does the bare
/// `example.com` -- list both forms to allow both. Ports are not part of the
/// comparison; an allowlisted host is allowed on any port.
export function hostAllowed(hostname, allowlist) {
  const host = hostname.toLowerCase().replace(/\.$/, "");
  for (const entry of allowlist) {
    if (entry.startsWith("*.")) {
      if (host.endsWith(entry.slice(1))) return true;
    } else if (host === entry) return true;
  }
  return false;
}

// url -> { promise } while in flight, then { ok: true, dataUri, bytes, hosts }
// or { ok: false, kind, label, expiresAt, allowlistKey }. `hosts` is every
// host the fetch contacted (origin plus each redirect target): a cached
// success is only served while all of them are still allowlisted, so
// narrowing the list blanks an image obtained through a now-refused hop the
// same way it refuses its origin. Insertion order is the LRU order
// (delete-then-set on hit, evict from the front), the same idiom as main.js's
// markdownCache.
const cache = new Map();
let cacheBytes = 0;

export function _resetCacheForTests() {
  cache.clear();
  cacheBytes = 0;
}

function rememberPositive(url, result, settings) {
  const entry = { ok: true, dataUri: result.dataUri, bytes: result.dataUri.length, hosts: result.hosts };
  cache.delete(url);
  cache.set(url, entry);
  cacheBytes += entry.bytes;
  while (cache.size > 0 && (cache.size > settings.maxCacheEntries || cacheBytes > settings.maxCacheBytes)) {
    const [oldestUrl, oldest] = cache.entries().next().value;
    cache.delete(oldestUrl);
    if (oldest.bytes) cacheBytes -= oldest.bytes;
  }
}

async function fetchRemoteImage(source, deadline, settings) {
  const controller = new AbortController();
  const remaining = deadline - Date.now();
  if (remaining <= 0) return failed("timed out");
  const timer = setTimeout(() => controller.abort(), remaining);
  try {
    let current = new URL(source);
    const hosts = [current.hostname];
    for (let hop = 0; ; hop += 1) {
      const response = await settings.fetchImpl(current.href, { redirect: "manual", signal: controller.signal });
      if (response.status >= 300 && response.status < 400) {
        // Every hop is re-validated against the allowlist, otherwise an
        // allowlisted host could 302 to anywhere and the list would be
        // decorative. The 3xx body is cancelled so the connection is freed.
        try { await response.body?.cancel(); } catch { /* already closed */ }
        if (hop >= MAX_REDIRECTS) return failed("too many redirects");
        const location = response.headers.get("location");
        if (!location) return failed(`redirect without a location (HTTP ${response.status})`);
        let next;
        try { next = new URL(location, current); } catch { return failed("redirect to an invalid URL"); }
        if (next.protocol !== "https:") return blocked("redirect to a non-https URL");
        if (!hostAllowed(next.hostname, settings.allowlist)) return blocked(`redirect to a host not in security.remote_images (${next.hostname})`);
        current = next;
        hosts.push(next.hostname);
        continue;
      }
      if (response.status < 200 || response.status >= 300) return failed(`HTTP ${response.status}`);
      const declared = Number(response.headers.get("content-length"));
      if (Number.isFinite(declared) && declared > settings.maxBytes) return failed("larger than max_local_image_bytes");
      // The cap is enforced while streaming (on decoded bytes -- fetch has
      // already decompressed), so a hostile server cannot push an unbounded
      // body regardless of what Content-Length claimed.
      const chunks = [];
      let total = 0;
      if (response.body) {
        for await (const chunk of response.body) {
          total += chunk.byteLength ?? chunk.length;
          if (total > settings.maxBytes) {
            controller.abort();
            return failed("larger than max_local_image_bytes");
          }
          chunks.push(Buffer.from(chunk));
        }
      }
      const data = Buffer.concat(chunks);
      const type = sniffImageType(data);
      if (!type) return failed("contents are not a supported image (PNG, JPEG, GIF, or WebP)");
      return { ok: true, dataUri: `data:${type.mime};base64,${data.toString("base64")}`, hosts };
    }
  } catch (error) {
    return failed(controller.signal.aborted ? "timed out" : `fetch failed (${error?.cause?.code ?? error?.name ?? "error"})`);
  } finally {
    clearTimeout(timer);
  }
}

async function resolveOne(source, deadline, settings, allowlistKey) {
  // Policy runs before the cache so an allowlist edit bites on the very next
  // render; only fetch outcomes are remembered, never the policy verdicts.
  let url;
  try { url = new URL(source); } catch { return blocked("invalid URL"); }
  if (url.protocol !== "https:") {
    return blocked(url.protocol === "http:" ? "http images are not fetched (https only)" : "unsupported URL scheme");
  }
  if (settings.allowlist.length === 0) return blocked("remote images are disabled (security.remote_images is empty)");
  if (!hostAllowed(url.hostname, settings.allowlist)) return blocked(`host is not in security.remote_images (${url.hostname})`);

  const cached = cache.get(source);
  if (cached) {
    if (cached.promise) return cached.promise;
    // Anything whose outcome depended on the allowlist of its day expires the
    // moment the allowlist changes: a redirect refusal so widening retries
    // immediately, and a redirect-obtained success so narrowing stops serving
    // bytes from a host the list no longer names.
    const stale = (cached.expiresAt !== undefined && Date.now() > cached.expiresAt)
      || (cached.ok === false && cached.kind === "blocked" && cached.allowlistKey !== allowlistKey)
      || (cached.ok === true && !cached.hosts.every((host) => hostAllowed(host, settings.allowlist)));
    if (!stale) {
      if (cached.ok) { cache.delete(source); cache.set(source, cached); }
      return cached;
    }
    cache.delete(source);
    if (cached.bytes) cacheBytes -= cached.bytes;
  }

  const promise = fetchRemoteImage(source, deadline, settings).then((result) => {
    if (result.ok) rememberPositive(source, result, settings);
    else cache.set(source, { ...result, expiresAt: Date.now() + settings.negativeTtlMs, allowlistKey });
    return result;
  });
  cache.set(source, { promise });
  return promise;
}

/// Resolves every source in parallel under one shared deadline and returns
/// `Map<source, result>` with the same tagged shape `resolveLocalImage` uses.
/// `fetchImpl`, `timeoutMs`, and `negativeTtlMs` exist so tests can run
/// against a stubbed fetch with no sockets (tests/node/no-listening-port
/// forbids a listener) and no real clocks.
export async function resolveRemoteImages(sources, options) {
  const results = new Map();
  const unique = [...new Set(sources)];
  if (unique.length === 0) return results;
  const allowlist = options.remoteImages ?? [];
  const settings = {
    allowlist,
    maxBytes: options.maxLocalImageBytes,
    fetchImpl: options.fetchImpl ?? globalThis.fetch,
    timeoutMs: options.timeoutMs ?? FETCH_TIMEOUT_MS,
    negativeTtlMs: options.negativeTtlMs ?? NEGATIVE_TTL_MS,
    maxCacheBytes: options.maxCacheBytes ?? MAX_CACHE_BYTES,
    maxCacheEntries: options.maxCacheEntries ?? MAX_CACHE_ENTRIES,
  };
  const allowlistKey = allowlist.join(",");
  const deadline = Date.now() + settings.timeoutMs;
  await Promise.all(unique.map(async (source) => {
    results.set(source, await resolveOne(source, deadline, settings, allowlistKey));
  }));
  return results;
}
