import dns from "node:dns";
import https from "node:https";
import { BlockList } from "node:net";
import { sniffImageType } from "./security.js";

/// Remote images are fetched HERE, in the Node process, never by the browser:
/// the Playwright route and the page CSP stay deny-all, and what reaches the
/// page is a validated `data:` URI indistinguishable from a local image.
/// There is no allowlist and no config: any https URL is eligible. What
/// keeps this from being unrestricted networking is the destination-safety
/// check below, which runs before every connection this module makes --
/// initial URL and every redirect hop alike -- and is not something a user
/// can loosen.
export const REMOTE_IMAGES = Symbol("md-viewer.remote-images");

// All renders share one serial queue (main.js), so a slow host would freeze
// every interaction for its duration. The deadline is shared by the whole
// batch of a render's fetches -- N hanging hosts still stall one render by at
// most FETCH_TIMEOUT_MS, not N times it. Failures are remembered briefly so a
// dead host costs one stall per minute, not one per keystroke.
//
// 20s, not 5s: measured against a real multi-megabyte GitHub-attachment GIF
// (the shape this project's own README uses) resolving through two hops --
// github.com's redirect, then the signed S3 URL -- the fetch itself took
// ~1.2s in isolation, but the first render after startup also races Chromium's
// own launch for the same CPU and network, and that contention pushed one
// otherwise-healthy fetch past a 5s budget. A too-tight timeout is worse than
// a generous one here: it does not just fail once, it gets remembered as
// failed for NEGATIVE_TTL_MS, so a single slow cold start reads as "broken"
// for the next minute instead of "was briefly busy."
const MAX_REDIRECTS = 3;
const FETCH_TIMEOUT_MS = 20_000;
const NEGATIVE_TTL_MS = 60_000;
const MAX_CACHE_BYTES = 64 * 1024 * 1024;
const MAX_CACHE_ENTRIES = 256;

function blocked(label) { return { ok: false, kind: "blocked", label }; }
function failed(label) { return { ok: false, kind: "failed", label }; }

// -- Destination safety ------------------------------------------------------
//
// Not an authoritative classifier of every IANA globally-routable-vs-not
// allocation -- a hand-maintained list of the well-known loopback, private,
// link-local, multicast, and reserved ranges relevant to SSRF, which is the
// actual threat this guards against: a document naming a URL that resolves
// (directly, or via a redirect this module itself follows) to something on
// the machine running the renderer or its private network, rather than the
// public internet a remote image host is supposed to be on.
const UNSAFE_DESTINATIONS = new BlockList();
for (const [address, prefix] of [
  ["0.0.0.0", 8], // unspecified / "this network"
  ["10.0.0.0", 8], // RFC1918 private
  ["100.64.0.0", 10], // RFC6598 carrier-grade NAT
  ["127.0.0.0", 8], // loopback
  ["169.254.0.0", 16], // link-local -- cloud metadata services (169.254.169.254) live here
  ["172.16.0.0", 12], // RFC1918 private
  ["192.0.0.0", 24], // IETF protocol assignments
  ["192.0.2.0", 24], // TEST-NET-1
  ["192.88.99.0", 24], // 6to4 relay anycast
  ["192.168.0.0", 16], // RFC1918 private
  ["198.18.0.0", 15], // benchmarking
  ["198.51.100.0", 24], // TEST-NET-2
  ["203.0.113.0", 24], // TEST-NET-3
  ["224.0.0.0", 4], // multicast
  ["240.0.0.0", 4], // reserved -- upper end of this range already covers 255.255.255.255
]) UNSAFE_DESTINATIONS.addSubnet(address, prefix, "ipv4");
for (const [address, prefix] of [
  ["::1", 128], // loopback
  ["::", 128], // unspecified
  ["fe80::", 10], // link-local
  ["fc00::", 7], // unique-local (RFC4193) -- IPv6's private range
  ["ff00::", 8], // multicast
]) UNSAFE_DESTINATIONS.addSubnet(address, prefix, "ipv6");
// Known residual gap, not handled: legacy transition mechanisms (6to4
// 2002::/16, Teredo 2001::/32) can embed an IPv4 address in a way BlockList
// does not unwrap the way it does the standard ::ffff:0:0/96 form (verified:
// BlockList treats ::ffff:127.0.0.1 as 127.0.0.1 automatically). Neither is
// in active use for ordinary image hosting.

function isPublicAddress(address, family) {
  return !UNSAFE_DESTINATIONS.check(address, family === 6 ? "ipv6" : "ipv4");
}

/// The WHATWG URL parser brackets an IPv6 literal ("[::1]"); `dns.lookup`
/// rejects that form outright and `BlockList.check` silently answers "not
/// blocked" for it instead of throwing (verified) -- so this strip is a
/// correctness requirement, not a cosmetic one. IPv4 hostnames pass through
/// unchanged.
function bareHostname(url) {
  return url.hostname.startsWith("[") ? url.hostname.slice(1, -1) : url.hostname;
}

/// Every address this hostname resolves to, unfiltered -- overridable so
/// tests can hand this an arbitrary DNS answer, including one a real
/// nameserver would never actually return, with no real query. `dns.lookup`
/// (the OS resolver, not a bare DNS query) is deliberate: it is what
/// `https.request` would otherwise resolve through, and it already
/// short-circuits an IP literal without a network round trip.
async function defaultResolveHost(hostname) {
  return dns.promises.lookup(hostname, { all: true, verbatim: true });
}

/// `dns.lookup` takes no signal/timeout of its own, so left unguarded a
/// black-holed query (nothing rejects it, nothing answers it either) would
/// hang past the shared deadline the rest of this module respects -- the
/// exact per-request stall the deadline exists to cap. Racing it against the
/// same AbortSignal every fetch already carries closes that gap without a
/// second timer.
function raceAgainstAbort(promise, signal) {
  if (signal.aborted) return Promise.reject(new Error("aborted"));
  return new Promise((resolve, reject) => {
    const onAbort = () => reject(new Error("aborted"));
    signal.addEventListener("abort", onAbort, { once: true });
    promise.then(
      (value) => { signal.removeEventListener("abort", onAbort); resolve(value); },
      (error) => { signal.removeEventListener("abort", onAbort); reject(error); }
    );
  });
}

/// The real network transport: a fetch-shaped function backed by
/// `https.request` rather than global `fetch`, because only the classic
/// client takes a per-request DNS override. `addresses` -- every surviving
/// candidate from the caller's validation, never just one -- is handed
/// straight to Node's own connector and nothing is re-resolved: the `lookup`
/// below returns exactly that set (the array shape Node's Happy-Eyeballs
/// logic asks for via `options.all`, or its first entry for the plain
/// single-address shape) so the socket can only ever reach an address this
/// module already checked, and a dual-stack host keeps its real IPv4/IPv6
/// fallback instead of being pinned to one arbitrarily-chosen address.
async function defaultFetchImpl(href, { signal, addresses }) {
  return new Promise((resolve, reject) => {
    // `href` has to be the first argument, not folded into the options object:
    // https.request(options, cb) with no url leaves hostname/path/protocol at
    // Node's defaults (localhost, "/") instead of the address this call means
    // to reach -- silently requesting the wrong thing rather than failing loudly.
    const request = https.request(href, buildRequestOptions(addresses, signal), (response) => {
      resolve({
        status: response.statusCode,
        headers: { get: (name) => response.headers[name.toLowerCase()] ?? null },
        body: response,
      });
    });
    request.on("error", reject);
    request.end();
  });
}

/// Split out from `defaultFetchImpl` so the no-proxy, no-shared-agent,
/// pinned-lookup shape can be asserted directly without opening a socket.
/// `agent: false` is deliberate, not merely unset: neither a bare
/// `https.request` call nor Node's default global agent has ever consulted
/// `HTTP_PROXY`/`HTTPS_PROXY`, so this line adds no proxy-avoidance by
/// itself -- what it buys is no keep-alive pool and no shared agent object
/// for some unrelated later change to reconfigure, so the connection this
/// call makes is provably this call's alone. Deliberately holds no url/target
/// fields itself -- those come from whatever `href` is passed alongside this,
/// which is what keeps this object testable without needing one.
export function buildRequestOptions(addresses, signal) {
  return {
    method: "GET",
    signal,
    agent: false,
    lookup: (hostname, options, callback) => {
      if (options.all) callback(null, addresses.map(({ address, family }) => ({ address, family })));
      else callback(null, addresses[0].address, addresses[0].family);
    },
  };
}

// url -> { promise } while in flight, then { ok: true, dataUri, bytes } or
// { ok: false, kind, label, expiresAt }. Insertion order is the LRU order
// (delete-then-set on hit, evict from the front), the same idiom as main.js's
// markdownCache. A positive entry needs no re-validation on a cache hit: it
// holds already-fetched, already-checked bytes, not a live connection, so
// replaying it exposes nothing further.
const cache = new Map();
let cacheBytes = 0;

export function _resetCacheForTests() {
  cache.clear();
  cacheBytes = 0;
}

function rememberPositive(url, result, settings) {
  const entry = { ok: true, dataUri: result.dataUri, bytes: result.dataUri.length };
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
    let current;
    try { current = new URL(source); } catch { return blocked("invalid URL"); }
    for (let hop = 0; ; hop += 1) {
      // Every hop, not just the first: a redirect target is exactly as
      // capable of naming credentials or a non-public destination as the
      // original URL, and the loop reaching back to the top is what applies
      // this identically to both.
      if (current.username !== "" || current.password !== "") return blocked("URL credentials are not sent");
      if (current.protocol !== "https:") {
        const reason = current.protocol === "http:" ? "http images are not fetched (https only)" : "unsupported URL scheme";
        return blocked(hop === 0 ? reason : `redirect to a non-https URL`);
      }

      let candidates;
      try {
        candidates = await raceAgainstAbort(settings.resolveHost(bareHostname(current)), controller.signal);
      } catch {
        return failed(controller.signal.aborted ? "timed out" : `could not resolve ${current.hostname}`);
      }
      const addresses = candidates.filter((c) => isPublicAddress(c.address, c.family));
      if (addresses.length === 0) return blocked(`${current.hostname} does not resolve to a public address`);

      const response = await settings.fetchImpl(current.href, { signal: controller.signal, addresses });
      if (response.status >= 300 && response.status < 400) {
        // The 3xx body is abandoned, never read, so the connection is freed.
        // A Node stream (the real transport) exposes destroy(); a Web
        // ReadableStream (test stubs built on Response) exposes cancel()
        // instead -- both are handled since either can reach here.
        try { response.body?.destroy ? response.body.destroy() : response.body?.cancel?.(); } catch { /* already closed */ }
        if (hop >= MAX_REDIRECTS) return failed("too many redirects");
        const location = response.headers.get("location");
        if (!location) return failed(`redirect without a location (HTTP ${response.status})`);
        try { current = new URL(location, current); } catch { return failed("redirect to an invalid URL"); }
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
      return { ok: true, dataUri: `data:${type.mime};base64,${data.toString("base64")}` };
    }
  } catch (error) {
    return failed(controller.signal.aborted ? "timed out" : `fetch failed (${error?.cause?.code ?? error?.name ?? "error"})`);
  } finally {
    clearTimeout(timer);
  }
}

// A timeout or an unanswered DNS query says nothing definitive -- unlike an
// HTTP 404 or invalid image bytes, both are exactly as likely to be a
// passing hiccup (this process racing Chromium's own launch for the same
// CPU, a momentarily slow resolver) as a dead host, and a retry moments
// later is genuinely likely to succeed. Remembering one for the same minute
// a definitive refusal earns turns one slow cold start into a placeholder
// that outlives the condition that caused it.
const TRANSIENT_NEGATIVE_TTL_MS = 3_000;
function isTransientFailure(result) {
  return result.kind === "failed" && (result.label === "timed out" || result.label.startsWith("could not resolve "));
}

async function resolveOne(source, deadline, settings) {
  const cached = cache.get(source);
  if (cached) {
    if (cached.promise) return cached.promise;
    const stale = cached.expiresAt !== undefined && Date.now() > cached.expiresAt;
    if (!stale) {
      if (cached.ok) { cache.delete(source); cache.set(source, cached); }
      return cached;
    }
    cache.delete(source);
    if (cached.bytes) cacheBytes -= cached.bytes;
  }

  const promise = fetchRemoteImage(source, deadline, settings).then((result) => {
    if (result.ok) rememberPositive(source, result, settings);
    else {
      const ttl = isTransientFailure(result) ? settings.transientNegativeTtlMs : settings.negativeTtlMs;
      cache.set(source, { ...result, expiresAt: Date.now() + ttl });
    }
    return result;
  });
  cache.set(source, { promise });
  return promise;
}

/// Resolves every source in parallel under one shared deadline and returns
/// `Map<source, result>` with the same tagged shape `resolveLocalImage` uses.
/// `fetchImpl`, `resolveHost`, `timeoutMs`, `negativeTtlMs`, and
/// `transientNegativeTtlMs` exist so tests can run with no real sockets or DNS
/// queries (tests/node/no-listening-port forbids a listener) and no real
/// clocks.
/// Returns `{ results, pending }`.
///
/// `pending` is the count of sources still being fetched when this returned,
/// and it exists because waiting for them was making the preview unusable. A
/// fetch is given `blockingMs` to finish; anything slower is reported as
/// `kind: "pending"` and the render proceeds without it, while the fetch keeps
/// running in the module cache below. The next render picks up whatever has
/// landed, and the Lua side asks for one because the response says something is
/// still outstanding -- the same mechanism `animationsIncomplete` already uses.
///
/// Measured on a corporate VM with no direct egress: `buildRequestOptions`
/// connects straight out with a pinned address and deliberately never consults
/// `HTTP_PROXY`, so on that network the connection cannot complete and the
/// 20-second timeout was paid *before the document appeared at all*. One
/// unreachable image made every preview of that document hang for 20 seconds.
/// The timeout is still 20 seconds, because a slow image on a working network
/// deserves it; what changed is that nobody waits for it.
export async function resolveRemoteImages(sources, options) {
  const results = new Map();
  const unique = [...new Set(sources)];
  if (unique.length === 0) return { results, pending: 0 };
  const settings = {
    maxBytes: options.maxLocalImageBytes,
    fetchImpl: options.fetchImpl ?? defaultFetchImpl,
    resolveHost: options.resolveHost ?? defaultResolveHost,
    timeoutMs: options.timeoutMs ?? FETCH_TIMEOUT_MS,
    negativeTtlMs: options.negativeTtlMs ?? NEGATIVE_TTL_MS,
    transientNegativeTtlMs: options.transientNegativeTtlMs ?? TRANSIENT_NEGATIVE_TTL_MS,
    maxCacheBytes: options.maxCacheBytes ?? MAX_CACHE_BYTES,
    maxCacheEntries: options.maxCacheEntries ?? MAX_CACHE_ENTRIES,
  };
  const deadline = Date.now() + settings.timeoutMs;
  // Default 0: do not block at all. A cache hit still lands, because
  // `resolveOne` returns an already-settled promise for one and a zero-delay
  // timer fires only after the microtask queue has drained -- so a document
  // whose images are already held renders complete on the first pass, exactly
  // as it did before. Tests and any caller that genuinely wants to wait pass a
  // number.
  const blockingMs = Math.max(0, Number(options.blockingMs) || 0);
  const outstanding = new Set(unique);
  const jobs = unique.map(async (source) => {
    const result = await resolveOne(source, deadline, settings);
    results.set(source, result);
    outstanding.delete(source);
  });
  // `Promise.all` is awaited either way rather than abandoned: an unhandled
  // rejection from a fetch nobody is waiting for would take the process down.
  const settled = Promise.all(jobs).catch(() => {});
  await Promise.race([settled, new Promise((resolve) => setTimeout(resolve, blockingMs))]);
  for (const source of outstanding) {
    // Not "failed": a failure is a fact about the image and is cached and
    // shown as such, while this is a fact about *when this render happened*.
    // Conflating them would cache a negative result for an image that is
    // merely slow, and the placeholder would then stick for its whole TTL.
    results.set(source, { ok: false, kind: "pending", label: "loading" });
  }
  return { results, pending: outstanding.size };
}
