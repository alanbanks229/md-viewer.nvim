import test, { beforeEach } from "node:test";
import assert from "node:assert/strict";
import https from "node:https";
import { Readable } from "node:stream";
import {
  _resetCacheForTests,
  buildRequestOptions,
  resolveRemoteImages,
} from "../../renderer/src/remote-images.js";

// Everything here runs against stubbed DNS resolution and a stubbed fetch,
// never a socket or a real query: tests/node/no-listening-port.test.js scans
// the whole machine for new listening TCP ports while the suite runs, so a
// local fixture server would fail it nondeterministically. Stubs also make
// redirect chains, hangs, and hostile streams exact instead of
// timing-dependent, and let a "DNS answered X" scenario be asserted directly
// rather than depending on what a real nameserver happens to return.

const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl+Zz8AAAAASUVORK5CYII=", "base64");

beforeEach(() => _resetCacheForTests());

function counting(fetchImpl) {
  const urls = [];
  const impl = async (url, init) => { urls.push(url); return fetchImpl(url, init); };
  return { urls, impl };
}

function countingResolve(resolveHost) {
  const hostnames = [];
  const impl = async (hostname) => { hostnames.push(hostname); return resolveHost(hostname); };
  return { hostnames, impl };
}

// A stand-in for "DNS said this is a normal public host" -- 93.184.216.34 is
// a real, ordinary, globally-routable address (formerly example.com's), not
// in any range this module blocks, chosen so tests that are not about the
// safety boundary itself don't need to think about resolution at all.
function publicHost(address = "93.184.216.34", family = 4) {
  return async () => [{ address, family }];
}

async function resolveOne(source, overrides = {}) {
  // `blockingMs` is what these tests are asserting *through*: resolution is
  // non-blocking by default now, so a test that wants the settled answer has to
  // say so. The production caller deliberately does not -- see the header of
  // resolveRemoteImages.
  const { results } = await resolveRemoteImages([source], {
    maxLocalImageBytes: overrides.maxBytes ?? 1024 * 1024,
    fetchImpl: overrides.fetchImpl ?? (async () => new Response(png, { status: 200 })),
    resolveHost: overrides.resolveHost ?? publicHost(),
    blockingMs: 5000,
    ...overrides.settings,
  });
  return results.get(source);
}

// -- Ordinary fetch mechanics: unchanged by the removal of the allowlist ----

test("a healthy fetch validates magic bytes and inlines a data URI", async () => {
  const result = await resolveOne("https://img.example/a.png");
  assert.equal(result.ok, true);
  assert.match(result.dataUri, /^data:image\/png;base64,/);
});

test("magic bytes are authoritative and Content-Type is ignored, both directions", async () => {
  const lying = await resolveOne("https://img.example/lying.png", {
    fetchImpl: async () => new Response(png, { status: 200, headers: { "content-type": "text/html" } }),
  });
  assert.equal(lying.ok, true, "png bytes render no matter what the header claims");
  const html = await resolveOne("https://img.example/fake.png", {
    fetchImpl: async () => new Response("<html>not an image</html>", { status: 200, headers: { "content-type": "image/png" } }),
  });
  assert.deepEqual([html.ok, html.kind], [false, "failed"], "an image/png header cannot bless non-image bytes");
});

test("HTTP errors fail with the status named", async () => {
  const result = await resolveOne("https://img.example/missing.png", {
    fetchImpl: async () => new Response("nope", { status: 404 }),
  });
  assert.deepEqual([result.ok, result.kind], [false, "failed"]);
  assert.match(result.label, /404/);
});

test("a malformed URL, and http instead of https, are refused before any fetch", async () => {
  const { urls, impl } = counting(async () => new Response(png));
  const insecure = await resolveOne("http://img.example/a.png", { fetchImpl: impl });
  assert.deepEqual([insecure.ok, insecure.kind], [false, "blocked"]);
  assert.match(insecure.label, /https only/);
  const malformed = await resolveOne("https://", { fetchImpl: impl });
  assert.equal(malformed.kind, "blocked");
  assert.deepEqual(urls, [], "no refusal here ever reached the network");
});

test("redirects are followed across different public hosts", async () => {
  const resolveHost = async (hostname) =>
    hostname === "img.example" ? [{ address: "1.2.3.4", family: 4 }] : [{ address: "5.6.7.8", family: 4 }];
  const { urls, impl } = counting(async (url) =>
    url.startsWith("https://img.example/")
      ? new Response(null, { status: 302, headers: { location: "https://cdn.example/real.png" } })
      : new Response(png, { status: 200 })
  );
  const result = await resolveOne("https://img.example/a.png", { resolveHost, fetchImpl: impl });
  assert.equal(result.ok, true);
  assert.deepEqual(urls, ["https://img.example/a.png", "https://cdn.example/real.png"]);
});

test("a redirect downgrading to http is refused; a relative Location resolves and works", async () => {
  const downgrade = await resolveOne("https://img.example/a.png", {
    fetchImpl: async () => new Response(null, { status: 302, headers: { location: "http://img.example/a.png" } }),
  });
  assert.deepEqual([downgrade.ok, downgrade.kind], [false, "blocked"]);
  const { urls, impl } = counting(async (url) =>
    url.endsWith("/moved.png") ? new Response(png) : new Response(null, { status: 301, headers: { location: "/moved.png" } })
  );
  const relative = await resolveOne("https://img.example/b.png", { fetchImpl: impl });
  assert.equal(relative.ok, true);
  assert.equal(urls[1], "https://img.example/moved.png");
});

test("redirect chains are capped and a missing Location fails cleanly", async () => {
  const { urls, impl } = counting(async () =>
    new Response(null, { status: 302, headers: { location: "https://img.example/again.png" } })
  );
  const loop = await resolveOne("https://img.example/loop.png", { fetchImpl: impl });
  assert.deepEqual([loop.ok, loop.kind], [false, "failed"]);
  assert.match(loop.label, /too many redirects/);
  assert.equal(urls.length, 4, "three hops are followed, the fourth 3xx stops the chain");
  const headless = await resolveOne("https://img.example/headless.png", {
    fetchImpl: async () => new Response(null, { status: 302 }),
  });
  assert.deepEqual([headless.ok, headless.kind], [false, "failed"]);
});

test("a declared oversize body fails fast; an unbounded stream is cut off mid-flight", async () => {
  const declared = await resolveOne("https://img.example/big.png", {
    maxBytes: 1024,
    fetchImpl: async () => new Response(png, { status: 200, headers: { "content-length": "999999" } }),
  });
  assert.deepEqual([declared.ok, declared.kind], [false, "failed"]);

  let cancelled = false;
  const endless = new ReadableStream({
    pull(controller) { controller.enqueue(new Uint8Array(1024)); },
    cancel() { cancelled = true; },
  });
  const streamed = await resolveOne("https://img.example/endless.png", {
    maxBytes: 4096,
    fetchImpl: async () => new Response(endless, { status: 200 }),
  });
  assert.deepEqual([streamed.ok, streamed.kind], [false, "failed"]);
  assert.match(streamed.label, /max_local_image_bytes/);
  assert.equal(cancelled, true, "the hostile stream is cancelled, not drained");
});

test("a hanging host times out against the shared deadline", async () => {
  const result = await resolveOne("https://img.example/hang.png", {
    settings: { timeoutMs: 30 },
    fetchImpl: (url, { signal }) => new Promise((_, reject) => {
      signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
    }),
  });
  assert.deepEqual([result.ok, result.kind], [false, "failed"]);
  assert.match(result.label, /timed out/);
});

test("a hanging DNS lookup also times out against the shared deadline, not just a hanging fetch", async () => {
  const { urls, impl } = counting(async () => new Response(png, { status: 200 }));
  const result = await resolveOne("https://img.example/hang-dns.png", {
    settings: { timeoutMs: 30 },
    resolveHost: () => new Promise(() => {}), // never resolves, never rejects
    fetchImpl: impl,
  });
  assert.deepEqual([result.ok, result.kind], [false, "failed"]);
  assert.match(result.label, /timed out/);
  assert.deepEqual(urls, [], "a lookup that never answers must not fall through to a connection attempt");
});

test("successes are cached and concurrent resolutions share one in-flight fetch", async () => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const { urls, impl } = counting(async () => { await gate; return new Response(png); });
  const source = "https://img.example/shared.png";
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
  const source = "https://img.example/flaky.png";
  const settings = { negativeTtlMs: 20 };
  assert.equal((await resolveOne(source, { fetchImpl: impl, settings })).kind, "failed");
  assert.equal((await resolveOne(source, { fetchImpl: impl, settings })).kind, "failed");
  assert.equal(urls.length, 1, "within the TTL the failure is served from the cache");
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal((await resolveOne(source, { fetchImpl: impl, settings })).kind, "failed");
  assert.equal(urls.length, 2, "after the TTL the fetch is retried");
});

test("a timeout is forgotten much sooner than a definitive failure, and retried without being asked", async () => {
  // A cold-start contention timeout is likely transient; a definitive HTTP
  // error is not. The two must not share a TTL, and this must hold with no
  // caller-provided override -- it is the production default that matters.
  let attempt = 0;
  const source = "https://img.example/cold-start.png";
  const settings = { timeoutMs: 20, transientNegativeTtlMs: 20 };
  const hanging = (url, { signal }) => new Promise((_, reject) => {
    signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
  });
  const healthy = async () => new Response(png, { status: 200 });
  const fetchImpl = (url, init) => { attempt += 1; return (attempt === 1 ? hanging : healthy)(url, init); };

  const first = await resolveOne(source, { fetchImpl, settings });
  assert.deepEqual([first.ok, first.kind], [false, "failed"]);
  assert.match(first.label, /timed out/);

  const immediate = await resolveOne(source, { fetchImpl, settings });
  assert.deepEqual([immediate.ok, immediate.kind], [false, "failed"], "still within the short transient TTL");
  assert.equal(attempt, 1, "not retried yet");

  await new Promise((resolve) => setTimeout(resolve, 30));
  const retried = await resolveOne(source, { fetchImpl, settings: { ...settings, timeoutMs: 1000 } });
  assert.equal(retried.ok, true, "a fresh attempt after the short TTL succeeds without any explicit retry request");
  assert.equal(attempt, 2);
});

test("the positive cache is bounded and evicts oldest-first", async () => {
  const { urls, impl } = counting(async () => new Response(png));
  const settings = { maxCacheBytes: 10 * 1024 * 1024, maxCacheEntries: 2 };
  const one = "https://img.example/1.png";
  const two = "https://img.example/2.png";
  const three = "https://img.example/3.png";
  for (const source of [one, two, three]) assert.equal((await resolveOne(source, { fetchImpl: impl, settings })).ok, true);
  assert.equal((await resolveOne(three, { fetchImpl: impl, settings })).ok, true);
  assert.equal(urls.length, 3, "the newest entry survived the eviction");
  assert.equal((await resolveOne(one, { fetchImpl: impl, settings })).ok, true);
  assert.equal(urls.length, 4, "the oldest entry was evicted and had to be refetched");
});

// -- Destination safety: no allowlist, but not unrestricted networking ------
//
// There is no config left to gate a host by name. What replaces it: every
// address a hostname resolves to is checked before this module connects to
// it, on the initial URL and on every redirect hop, and only loopback,
// private, link-local, multicast, and reserved destinations are refused --
// an ordinary public image host needs no setup at all.

test("an arbitrary public HTTPS host works with no configuration", async () => {
  const result = await resolveOne("https://cdn-one.example/a.png");
  assert.equal(result.ok, true);
  assert.match(result.dataUri, /^data:image\/png;base64,/);
});

test("a second, unrelated public HTTPS host works too -- there is no allowlist", async () => {
  const result = await resolveOne("https://totally-different-cdn.example/b.png");
  assert.equal(result.ok, true);
});

test("a direct loopback destination is refused before any connection is attempted", async () => {
  const { urls, impl } = counting(async () => new Response(png, { status: 200 }));
  const result = await resolveOne("https://internal.example/a.png", {
    resolveHost: async () => [{ address: "127.0.0.1", family: 4 }],
    fetchImpl: impl,
  });
  assert.deepEqual([result.ok, result.kind], [false, "blocked"]);
  assert.deepEqual(urls, [], "refused before any connection was attempted");
});

test("direct private IPv4 destinations are refused, including the cloud-metadata range", async () => {
  for (const address of ["10.1.2.3", "172.20.1.1", "192.168.1.1", "169.254.169.254"]) {
    const { urls, impl } = counting(async () => new Response(png, { status: 200 }));
    const result = await resolveOne("https://internal.example/a.png", {
      resolveHost: async () => [{ address, family: 4 }],
      fetchImpl: impl,
    });
    assert.deepEqual([result.ok, result.kind], [false, "blocked"], address);
    assert.deepEqual(urls, [], address);
  }
});

test("private IPv6 destinations are refused: loopback, link-local, unique-local", async () => {
  for (const address of ["::1", "fe80::1", "fd12:3456:789a::1"]) {
    const { urls, impl } = counting(async () => new Response(png, { status: 200 }));
    const result = await resolveOne("https://internal6.example/a.png", {
      resolveHost: async () => [{ address, family: 6 }],
      fetchImpl: impl,
    });
    assert.deepEqual([result.ok, result.kind], [false, "blocked"], address);
    assert.deepEqual(urls, [], address);
  }
});

test("a hostname that looks ordinary but resolves to a private address is refused", async () => {
  const result = await resolveOne("https://looks-fine.example/a.png", {
    resolveHost: async () => [{ address: "169.254.169.254", family: 4 }],
  });
  assert.deepEqual([result.ok, result.kind], [false, "blocked"]);
  assert.match(result.label, /public address/);
});

test("a redirect from a public host to a private destination is refused before a second connection", async () => {
  const resolveHost = async (hostname) =>
    hostname === "img.example" ? [{ address: "1.2.3.4", family: 4 }] : [{ address: "169.254.169.254", family: 4 }];
  const { urls, impl } = counting(async () =>
    new Response(null, { status: 302, headers: { location: "https://metadata.internal/x" } })
  );
  const result = await resolveOne("https://img.example/a.png", { resolveHost, fetchImpl: impl });
  assert.deepEqual([result.ok, result.kind], [false, "blocked"]);
  assert.deepEqual(urls, ["https://img.example/a.png"], "the redirect target itself is never connected to");
});

test("IPv4-mapped IPv6 cannot smuggle a blocked IPv4 destination past the check", async () => {
  for (const address of ["::ffff:127.0.0.1", "::ffff:169.254.169.254", "::ffff:10.0.0.1"]) {
    const { urls, impl } = counting(async () => new Response(png, { status: 200 }));
    const result = await resolveOne("https://sneaky.example/a.png", {
      resolveHost: async () => [{ address, family: 6 }],
      fetchImpl: impl,
    });
    assert.deepEqual([result.ok, result.kind], [false, "blocked"], address);
    assert.deepEqual(urls, [], address);
  }
});

test("IPv4-in-IPv6 transition forms cannot smuggle a blocked destination either", async () => {
  // BlockList unwraps ::ffff:0:0/96 by itself and nothing else, so every other
  // standardized way of carrying an IPv4 address inside an IPv6 one used to
  // resolve to "not blocked" -- an IPv6 answer that a NAT64, 6to4 or Teredo
  // network translates straight back to the IPv4 endpoint the list above
  // refuses. Each entry embeds loopback, RFC1918 or the cloud-metadata address.
  const smuggled = [
    ["::7f00:1", "IPv4-compatible ::127.0.0.1"],
    ["::a9fe:a9fe", "IPv4-compatible ::169.254.169.254"],
    ["64:ff9b::7f00:1", "NAT64 well-known prefix carrying 127.0.0.1"],
    ["64:ff9b::a9fe:a9fe", "NAT64 well-known prefix carrying the metadata service"],
    ["64:ff9b:1::a9fe:a9fe", "NAT64 local-use prefix carrying the metadata service"],
    ["2002:7f00:1::1", "6to4 embedding 127.0.0.1"],
    ["2002:ac10:1::1", "6to4 embedding 172.16.0.1"],
    ["2001:0:4136:e378:8000:63bf:3fff:fdd2", "Teredo"],
  ];
  for (const [address, why] of smuggled) {
    const { urls, impl } = counting(async () => new Response(png, { status: 200 }));
    const result = await resolveOne("https://transition.example/a.png", {
      resolveHost: async () => [{ address, family: 6 }],
      fetchImpl: impl,
    });
    assert.deepEqual([result.ok, result.kind], [false, "blocked"], why);
    assert.deepEqual(urls, [], why);
  }
});

test("blocking the transition prefixes does not cost ordinary public IPv6", async () => {
  // The prefixes above sit inside ranges real hosts do use, so this is the half
  // that has to keep working: public addresses from five networks that actually
  // serve images, including 2001:4860:: which is one hextet away from Teredo.
  for (const address of [
    "2606:4700:4700::1111",
    "2001:4860:4860::8888",
    "2a00:1450:4009:81f::200e",
    "2620:0:861:ed1a::1",
    "2600:9000:2000::1",
  ]) {
    const result = await resolveOne("https://cdn.example/a.png", {
      resolveHost: async () => [{ address, family: 6 }],
      fetchImpl: async () => new Response(png, { status: 200 }),
    });
    assert.equal(result.ok, true, address);
  }
});

test("a transition-form destination is refused on a redirect hop, not just the first URL", async () => {
  const resolveHost = async (hostname) =>
    hostname === "img.example" ? [{ address: "1.2.3.4", family: 4 }] : [{ address: "64:ff9b::a9fe:a9fe", family: 6 }];
  const { urls, impl } = counting(async () =>
    new Response(null, { status: 302, headers: { location: "https://nat64.internal/x" } })
  );
  const result = await resolveOne("https://img.example/a.png", { resolveHost, fetchImpl: impl });
  assert.deepEqual([result.ok, result.kind], [false, "blocked"]);
  assert.deepEqual(urls, ["https://img.example/a.png"], "the redirect target itself is never connected to");
});

test("URL credentials are refused before any DNS lookup or connection", async () => {
  const { hostnames, impl: resolveHost } = countingResolve(publicHost());
  const { urls, impl: fetchImpl } = counting(async () => new Response(png, { status: 200 }));
  const result = await resolveOne("https://user:pass@img.example/a.png", { resolveHost, fetchImpl });
  assert.deepEqual([result.ok, result.kind], [false, "blocked"]);
  assert.deepEqual(hostnames, [], "credentials in the URL are rejected before resolving the host at all");
  assert.deepEqual(urls, []);
});

test("a blocked IPv4 URL literal is refused", async () => {
  const { urls, impl } = counting(async () => new Response(png, { status: 200 }));
  const result = await resolveOne("https://127.0.0.1/x.png", {
    resolveHost: async (hostname) => [{ address: hostname, family: 4 }],
    fetchImpl: impl,
  });
  assert.deepEqual([result.ok, result.kind], [false, "blocked"]);
  assert.deepEqual(urls, []);
});

test("a blocked IPv6 URL literal is refused -- the IPv4-literal path does not prove this one works", async () => {
  const { urls, impl } = counting(async () => new Response(png, { status: 200 }));
  const result = await resolveOne("https://[::1]/x.png", {
    resolveHost: async (hostname) => [{ address: hostname, family: 6 }],
    fetchImpl: impl,
  });
  assert.deepEqual([result.ok, result.kind], [false, "blocked"]);
  assert.deepEqual(urls, []);
});

test("a public IPv4 URL literal is allowed", async () => {
  const result = await resolveOne("https://93.184.216.34/x.png", {
    resolveHost: async (hostname) => [{ address: hostname, family: 4 }],
  });
  assert.equal(result.ok, true);
});

test("a public IPv6 URL literal is allowed", async () => {
  const result = await resolveOne("https://[2606:4700:4700::1111]/x.png", {
    resolveHost: async (hostname) => [{ address: hostname, family: 6 }],
  });
  assert.equal(result.ok, true);
});

test("resolveHost is called exactly once per hop, and the transport receives exactly what it returned", async () => {
  const { hostnames, impl: resolveHost } = countingResolve(async () => [{ address: "1.2.3.4", family: 4 }]);
  const seen = [];
  const fetchImpl = async (url, init) => { seen.push(init.addresses); return new Response(png, { status: 200 }); };
  const result = await resolveOne("https://cdn.example/a.png", { resolveHost, fetchImpl });
  assert.equal(result.ok, true);
  assert.deepEqual(hostnames, ["cdn.example"],
    "resolved exactly once -- never once to validate and a second, independent time to connect");
  assert.deepEqual(seen, [[{ address: "1.2.3.4", family: 4 }]],
    "the addresses handed to the transport are exactly what resolution returned, with nothing re-resolved in between");
});

test("a redirect between two public hosts resolves each hostname exactly once", async () => {
  const { hostnames, impl: resolveHost } = countingResolve(async (hostname) =>
    hostname === "a.example" ? [{ address: "1.2.3.4", family: 4 }] : [{ address: "5.6.7.8", family: 4 }]
  );
  const { impl: fetchImpl } = counting(async (url) =>
    url.startsWith("https://a.example/")
      ? new Response(null, { status: 302, headers: { location: "https://b.example/real.png" } })
      : new Response(png, { status: 200 })
  );
  const result = await resolveOne("https://a.example/x.png", { resolveHost, fetchImpl });
  assert.equal(result.ok, true);
  assert.deepEqual(hostnames, ["a.example", "b.example"]);
});

test("the real transport pins the connection to validated addresses and uses no shared or proxy-aware agent", () => {
  const addresses = [{ address: "1.2.3.4", family: 4 }, { address: "2606:4700:4700::1111", family: 6 }];
  const options = buildRequestOptions(addresses, undefined);
  // Neither a bare https.request call nor Node's default global agent has
  // ever consulted HTTP_PROXY/HTTPS_PROXY -- what agent:false adds on top is
  // no keep-alive pool and no shared agent object some unrelated later
  // change could reconfigure to add a proxy path.
  assert.equal(options.agent, false);
  assert.equal(typeof options.lookup, "function");

  const single = [];
  options.lookup("cdn.example", { all: false }, (err, address, family) => single.push([err, address, family]));
  assert.deepEqual(single, [[null, "1.2.3.4", 4]], "the single-address callback shape gets the first validated candidate");

  const all = [];
  options.lookup("cdn.example", { all: true }, (err, list) => all.push([err, list]));
  assert.deepEqual(all, [[null, addresses]],
    "the array callback shape (Node's Happy-Eyeballs dual-stack path) gets every validated candidate, not just one");
});

test("the default transport requests the URL it was actually given, not Node's connection defaults", async (t) => {
  // Regression coverage for a real bug: `buildRequestOptions`'s return value
  // was previously passed as https.request's *only* argument, with `href`
  // folded in nowhere -- so every real fetch silently targeted Node's
  // defaults (localhost, path "/") instead of the URL this module resolved
  // and validated. Every other test here stubs fetchImpl, so none of them
  // could have caught that; this one mocks https.request itself instead,
  // opening no real socket, specifically so the real default transport gets
  // exercised end-to-end at least once.
  const calls = [];
  t.mock.method(https, "request", (...args) => {
    const callback = args.find((arg) => typeof arg === "function");
    calls.push(args.slice(0, args.indexOf(callback)));
    const response = Readable.from([png]);
    response.statusCode = 200;
    response.headers = {};
    queueMicrotask(() => callback(response));
    return { on() {}, end() {} };
  });

  const { results } = await resolveRemoteImages(["https://cdn.example/a.png"], {
    maxLocalImageBytes: 1024 * 1024,
    resolveHost: async () => [{ address: "1.2.3.4", family: 4 }],
    blockingMs: 5000,
  });
  const result = results.get("https://cdn.example/a.png");
  assert.equal(result.ok, true, result.label);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], "https://cdn.example/a.png",
    "the resolved URL must be the request target, not left for https.request to default");
});

// ---------------------------------------------------------------------------
// Nobody waits for an image.
//
// The failure this fixes, measured on a corporate VM with no direct egress:
// `buildRequestOptions` connects straight out with a pinned address and never
// consults HTTP_PROXY, so on that network the connection cannot complete -- and
// the 20 second timeout was paid *before the document appeared at all*. One
// unreachable image made every preview of that document hang for 20 seconds.
// The timeout is unchanged; what changed is that the render stopped waiting.
// ---------------------------------------------------------------------------

test("a slow image does not delay the render, and is reported as still pending", async () => {
  let release;
  const stalled = new Promise((resolve) => { release = resolve; });
  const started = Date.now();
  const { results, pending } = await resolveRemoteImages(["https://cdn.example/slow.png"], {
    maxLocalImageBytes: 1024 * 1024,
    fetchImpl: async () => { await stalled; return new Response(png, { status: 200 }); },
    resolveHost: publicHost(),
  });
  assert.equal(Date.now() - started < 500, true, "the render is not held up by a fetch that has not answered");
  assert.equal(pending, 1);
  const result = results.get("https://cdn.example/slow.png");
  assert.equal(result.ok, false);
  assert.equal(result.kind, "pending", "and it is 'pending', never 'failed' -- a slow image is not a broken one");
  release();
});

test("an image already held renders complete on the first pass, with no wait", async () => {
  // The common case, and the one that must not regress: a document reopened
  // after its images have been fetched once has to come up whole immediately,
  // exactly as it did before any of this.
  const source = "https://cdn.example/cached.png";
  const warm = await resolveRemoteImages([source], {
    maxLocalImageBytes: 1024 * 1024,
    fetchImpl: async () => new Response(png, { status: 200 }),
    resolveHost: publicHost(),
    blockingMs: 5000,
  });
  assert.equal(warm.pending, 0);
  assert.equal(warm.results.get(source).ok, true);

  const again = await resolveRemoteImages([source], {
    maxLocalImageBytes: 1024 * 1024,
    fetchImpl: async () => { throw new Error("a cached image must not be re-fetched"); },
    resolveHost: publicHost(),
  });
  assert.equal(again.pending, 0, "a cache hit settles within the microtask turn, so nothing is left pending");
  assert.equal(again.results.get(source).ok, true);
});

test("a pending result is never cached as a failure", async () => {
  // The trap: caching "pending" as a negative would pin the placeholder for the
  // whole negative TTL, so the retry that is meant to replace it would be
  // answered with the thing it is replacing.
  const source = "https://cdn.example/eventually.png";
  let release;
  const stalled = new Promise((resolve) => { release = resolve; });
  const first = await resolveRemoteImages([source], {
    maxLocalImageBytes: 1024 * 1024,
    fetchImpl: async () => { await stalled; return new Response(png, { status: 200 }); },
    resolveHost: publicHost(),
  });
  assert.equal(first.pending, 1);
  release();
  // The fetch was never abandoned -- it is still running in the module cache --
  // so the next pass finds it done rather than starting over.
  const second = await resolveRemoteImages([source], {
    maxLocalImageBytes: 1024 * 1024,
    fetchImpl: async () => { throw new Error("the in-flight fetch must be reused, not restarted"); },
    resolveHost: publicHost(),
    blockingMs: 5000,
  });
  assert.equal(second.pending, 0);
  assert.equal(second.results.get(source).ok, true, "and the image lands on the retry");
});
