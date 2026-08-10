import test, { beforeEach } from "node:test";
import assert from "node:assert/strict";
import {
  _resetCacheForTests,
  hostAllowed,
  normalizeAllowlist,
  resolveRemoteImages,
} from "../../renderer/src/remote-images.js";

// Everything here runs against a stubbed fetch, never a socket:
// tests/node/no-listening-port.test.js scans the whole machine for new
// listening TCP ports while the suite runs, so a local fixture server would
// fail it nondeterministically. The stub also makes redirect chains, hangs,
// and hostile streams exact instead of timing-dependent.

const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl+Zz8AAAAASUVORK5CYII=", "base64");

beforeEach(() => _resetCacheForTests());

function counting(fetchImpl) {
  const urls = [];
  const impl = async (url, init) => { urls.push(url); return fetchImpl(url, init); };
  return { urls, impl };
}

async function resolveOne(source, overrides = {}) {
  const results = await resolveRemoteImages([source], {
    remoteImages: normalizeAllowlist(overrides.allowlist ?? ["img.allowed.example"]),
    maxLocalImageBytes: overrides.maxBytes ?? 1024 * 1024,
    fetchImpl: overrides.fetchImpl ?? (async () => new Response(png, { status: 200 })),
    ...overrides.settings,
  });
  return results.get(source);
}

test("allowlist entries normalize and match with a strict dot boundary", () => {
  assert.deepEqual(
    normalizeAllowlist(["GitHub.COM", "github.com", "*.GithubUserContent.com", "example.com.", "", 42, "bad host name"]),
    ["*.githubusercontent.com", "example.com", "github.com"]
  );
  const allowlist = normalizeAllowlist(["github.com", "*.githubusercontent.com"]);
  assert.equal(hostAllowed("github.com", allowlist), true);
  assert.equal(hostAllowed("GITHUB.COM.", allowlist), true, "case and a trailing resolver dot cannot dodge the comparison");
  assert.equal(hostAllowed("api.github.com", allowlist), false, "a bare entry grants nothing to subdomains");
  assert.equal(hostAllowed("raw.githubusercontent.com", allowlist), true);
  assert.equal(hostAllowed("a.b.githubusercontent.com", allowlist), true);
  assert.equal(hostAllowed("githubusercontent.com", allowlist), false, "a wildcard never matches its own bare domain");
  assert.equal(hostAllowed("evil-githubusercontent.com", allowlist), false, "the dot boundary defeats suffix spoofing");
  assert.equal(hostAllowed("anything.example", []), false);
});

test("policy refusals happen before any fetch and are never cached", async () => {
  const { urls, impl } = counting(async () => new Response(png));
  const off = await resolveOne("https://img.allowed.example/a.png", { allowlist: [], fetchImpl: impl });
  assert.deepEqual([off.ok, off.kind], [false, "blocked"]);
  const wrongHost = await resolveOne("https://other.example/a.png", { fetchImpl: impl });
  assert.deepEqual([wrongHost.ok, wrongHost.kind], [false, "blocked"]);
  const insecure = await resolveOne("http://img.allowed.example/a.png", { fetchImpl: impl });
  assert.deepEqual([insecure.ok, insecure.kind], [false, "blocked"]);
  assert.match(insecure.label, /https only/);
  const malformed = await resolveOne("https://", { fetchImpl: impl });
  assert.equal(malformed.kind, "blocked");
  assert.deepEqual(urls, [], "no policy refusal ever reached the network");
});

test("a healthy fetch validates magic bytes and inlines a data URI", async () => {
  const result = await resolveOne("https://img.allowed.example/a.png");
  assert.equal(result.ok, true);
  assert.match(result.dataUri, /^data:image\/png;base64,/);
});

test("magic bytes are authoritative and Content-Type is ignored, both directions", async () => {
  const lying = await resolveOne("https://img.allowed.example/lying.png", {
    fetchImpl: async () => new Response(png, { status: 200, headers: { "content-type": "text/html" } }),
  });
  assert.equal(lying.ok, true, "png bytes render no matter what the header claims");
  const html = await resolveOne("https://img.allowed.example/fake.png", {
    fetchImpl: async () => new Response("<html>not an image</html>", { status: 200, headers: { "content-type": "image/png" } }),
  });
  assert.deepEqual([html.ok, html.kind], [false, "failed"], "an image/png header cannot bless non-image bytes");
});

test("HTTP errors fail with the status named", async () => {
  const result = await resolveOne("https://img.allowed.example/missing.png", {
    fetchImpl: async () => new Response("nope", { status: 404 }),
  });
  assert.deepEqual([result.ok, result.kind], [false, "failed"]);
  assert.match(result.label, /404/);
});

test("redirects are followed with every hop re-validated against the allowlist", async () => {
  const { urls, impl } = counting(async (url) =>
    url.startsWith("https://img.allowed.example/")
      ? new Response(null, { status: 302, headers: { location: "https://cdn.allowed.example/real.png" } })
      : new Response(png, { status: 200 })
  );
  const result = await resolveOne("https://img.allowed.example/a.png", {
    allowlist: ["img.allowed.example", "cdn.allowed.example"], fetchImpl: impl,
  });
  assert.equal(result.ok, true);
  assert.deepEqual(urls, ["https://img.allowed.example/a.png", "https://cdn.allowed.example/real.png"]);
});

test("a redirect to a host outside the allowlist is refused and never fetched", async () => {
  const { urls, impl } = counting(async () =>
    new Response(null, { status: 302, headers: { location: "https://169.254.169.254/latest/meta-data" } })
  );
  const result = await resolveOne("https://img.allowed.example/a.png", { fetchImpl: impl });
  assert.deepEqual([result.ok, result.kind], [false, "blocked"]);
  assert.match(result.label, /redirect/);
  assert.deepEqual(urls, ["https://img.allowed.example/a.png"], "the redirect target itself is never contacted");
});

test("a redirect downgrading to http is refused; a relative Location resolves and works", async () => {
  const downgrade = await resolveOne("https://img.allowed.example/a.png", {
    fetchImpl: async () => new Response(null, { status: 302, headers: { location: "http://img.allowed.example/a.png" } }),
  });
  assert.deepEqual([downgrade.ok, downgrade.kind], [false, "blocked"]);
  const { urls, impl } = counting(async (url) =>
    url.endsWith("/moved.png") ? new Response(png) : new Response(null, { status: 301, headers: { location: "/moved.png" } })
  );
  const relative = await resolveOne("https://img.allowed.example/b.png", { fetchImpl: impl });
  assert.equal(relative.ok, true);
  assert.equal(urls[1], "https://img.allowed.example/moved.png");
});

test("redirect chains are capped and a missing Location fails cleanly", async () => {
  const { urls, impl } = counting(async () =>
    new Response(null, { status: 302, headers: { location: "https://img.allowed.example/again.png" } })
  );
  const loop = await resolveOne("https://img.allowed.example/loop.png", { fetchImpl: impl });
  assert.deepEqual([loop.ok, loop.kind], [false, "failed"]);
  assert.match(loop.label, /too many redirects/);
  assert.equal(urls.length, 4, "three hops are followed, the fourth 3xx stops the chain");
  const headless = await resolveOne("https://img.allowed.example/headless.png", {
    fetchImpl: async () => new Response(null, { status: 302 }),
  });
  assert.deepEqual([headless.ok, headless.kind], [false, "failed"]);
});

test("a declared oversize body fails fast; an unbounded stream is cut off mid-flight", async () => {
  const declared = await resolveOne("https://img.allowed.example/big.png", {
    maxBytes: 1024,
    fetchImpl: async () => new Response(png, { status: 200, headers: { "content-length": "999999" } }),
  });
  assert.deepEqual([declared.ok, declared.kind], [false, "failed"]);

  let cancelled = false;
  const endless = new ReadableStream({
    pull(controller) { controller.enqueue(new Uint8Array(1024)); },
    cancel() { cancelled = true; },
  });
  const streamed = await resolveOne("https://img.allowed.example/endless.png", {
    maxBytes: 4096,
    fetchImpl: async () => new Response(endless, { status: 200 }),
  });
  assert.deepEqual([streamed.ok, streamed.kind], [false, "failed"]);
  assert.match(streamed.label, /max_local_image_bytes/);
  assert.equal(cancelled, true, "the hostile stream is cancelled, not drained");
});

test("a hanging host times out against the shared deadline", async () => {
  const result = await resolveOne("https://img.allowed.example/hang.png", {
    settings: { timeoutMs: 30 },
    fetchImpl: (url, { signal }) => new Promise((_, reject) => {
      signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
    }),
  });
  assert.deepEqual([result.ok, result.kind], [false, "failed"]);
  assert.match(result.label, /timed out/);
});

test("successes are cached and concurrent resolutions share one in-flight fetch", async () => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const { urls, impl } = counting(async () => { await gate; return new Response(png); });
  const source = "https://img.allowed.example/shared.png";
  const first = resolveOne(source, { fetchImpl: impl });
  const second = resolveOne(source, { fetchImpl: impl });
  release();
  assert.equal((await first).ok, true);
  assert.equal((await second).ok, true);
  assert.equal(urls.length, 1, "two concurrent renders share one fetch");
  const third = await resolveOne(source, { fetchImpl: impl });
  assert.equal(third.ok, true);
  assert.equal(urls.length, 1, "a later render is served from the cache");
});

test("failures are remembered briefly, then retried", async () => {
  const { urls, impl } = counting(async () => new Response("nope", { status: 404 }));
  const source = "https://img.allowed.example/flaky.png";
  const settings = { negativeTtlMs: 20 };
  assert.equal((await resolveOne(source, { fetchImpl: impl, settings })).kind, "failed");
  assert.equal((await resolveOne(source, { fetchImpl: impl, settings })).kind, "failed");
  assert.equal(urls.length, 1, "within the TTL the failure is served from the cache");
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal((await resolveOne(source, { fetchImpl: impl, settings })).kind, "failed");
  assert.equal(urls.length, 2, "after the TTL the fetch is retried");
});

test("a cached redirect refusal expires the moment the allowlist changes", async () => {
  const { urls, impl } = counting(async (url) =>
    url.startsWith("https://img.allowed.example/")
      ? new Response(null, { status: 302, headers: { location: "https://cdn.other.example/real.png" } })
      : new Response(png)
  );
  const source = "https://img.allowed.example/a.png";
  const refused = await resolveOne(source, { fetchImpl: impl });
  assert.deepEqual([refused.ok, refused.kind], [false, "blocked"]);
  const allowed = await resolveOne(source, { allowlist: ["img.allowed.example", "cdn.other.example"], fetchImpl: impl });
  assert.equal(allowed.ok, true, "widening the allowlist retries immediately instead of waiting out the TTL");
  assert.equal(urls.length, 3);
});

test("a cached success obtained through a redirect stops being served when the allowlist narrows", async () => {
  const { urls, impl } = counting(async (url) =>
    url.startsWith("https://img.allowed.example/")
      ? new Response(null, { status: 302, headers: { location: "https://cdn.allowed.example/real.png" } })
      : new Response(png)
  );
  const source = "https://img.allowed.example/a.png";
  const wide = ["img.allowed.example", "cdn.allowed.example"];
  assert.equal((await resolveOne(source, { allowlist: wide, fetchImpl: impl })).ok, true);
  const narrowed = await resolveOne(source, { allowlist: ["img.allowed.example"], fetchImpl: impl });
  assert.deepEqual([narrowed.ok, narrowed.kind], [false, "blocked"],
    "bytes fetched via a now-refused hop are not served from the cache");
  assert.equal(urls.length, 3, "the narrowed render re-fetched and was stopped at the redirect");
  assert.equal((await resolveOne(source, { allowlist: wide, fetchImpl: impl })).ok, true,
    "restoring the allowlist restores the image");
});

test("the positive cache is bounded and evicts oldest-first", async () => {
  const { urls, impl } = counting(async () => new Response(png));
  const settings = { maxCacheBytes: 10 * 1024 * 1024, maxCacheEntries: 2 };
  const one = "https://img.allowed.example/1.png";
  const two = "https://img.allowed.example/2.png";
  const three = "https://img.allowed.example/3.png";
  for (const source of [one, two, three]) assert.equal((await resolveOne(source, { fetchImpl: impl, settings })).ok, true);
  assert.equal((await resolveOne(three, { fetchImpl: impl, settings })).ok, true);
  assert.equal(urls.length, 3, "the newest entry survived the eviction");
  assert.equal((await resolveOne(one, { fetchImpl: impl, settings })).ok, true);
  assert.equal(urls.length, 4, "the oldest entry was evicted and had to be refetched");
});
