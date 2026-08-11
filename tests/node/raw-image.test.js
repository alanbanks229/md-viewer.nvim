import test, { beforeEach } from "node:test";
import assert from "node:assert/strict";
import { renderMarkdown } from "../../renderer/src/markdown.js";
import { _resetCacheForTests } from "../../renderer/src/remote-images.js";

// A bare `<img>` is parsed into a real markdown-it image token, so it goes
// through the same resolver `![](...)` does. These tests are as much about what
// the rule *refuses* as what it accepts: it is the one place raw HTML is read
// while `security.raw_html` is off, so the boundary has to be exact.
//
// Everything runs against a stubbed fetch, never a socket --
// tests/node/no-listening-port.test.js scans for new listening TCP ports while
// the suite runs.

const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl+Zz8AAAAASUVORK5CYII=", "base64");

// The remote-image cache is process-global by design, so a URL fetched by an
// earlier test is served from memory in a later one and the fetch count -- the
// assertion that proves the prefetch ran at all -- silently reads zero.
beforeEach(() => _resetCacheForTests());

function render(markdown, overrides = {}) {
  const urls = [];
  const options = {
    rawHtml: false,
    localImages: true,
    maxLocalImageBytes: 1024 * 1024,
    baseDir: "/nonexistent",
    documentRoot: "/nonexistent",
    // Every fixture below uses img.allowed.example as its host; the name is a
    // holdover from when it had to be allowlisted, kept only because it is
    // already threaded through every test in this file. There is no allowlist
    // left to check it against -- this stub just answers "a normal public
    // address" for any hostname a test does not override.
    resolveHost: async () => [{ address: "93.184.216.34", family: 4 }],
    ...overrides,
    fetchImpl: async (url, init) => {
      urls.push(url);
      return (overrides.fetchImpl ?? (async () => new Response(png, { status: 200 })))(url, init);
    },
  };
  return renderMarkdown(markdown, options).then(({ html }) => ({ html, urls }));
}

test("a remote <img> renders through the resolver with raw_html off", async () => {
  // The shape of README.md's own screenshot: raw HTML, remote host, explicit
  // intrinsic dimensions.
  const { html, urls } = await render(
    '<img width="1470" height="892" alt="preview" src="https://img.allowed.example/shot.png" />'
  );

  assert.match(html, /<img src="data:image\/png;base64,[A-Za-z0-9+/=]+"/);
  assert.match(html, /alt="preview"/);
  assert.match(html, /width="1470"/);
  assert.match(html, /height="892"/);
  // Provenance, which is only there because the rule is registered ahead of
  // provenancePlugin and therefore gets span-wrapped like every builtin rule.
  assert.match(html, /<img [^>]*data-md-source-id="s\d+"/);
  // Fetched exactly once, which is the proof that collectRemoteImageSources saw
  // the token and the prefetch ran *before* rendering rather than after.
  assert.deepEqual(urls, ["https://img.allowed.example/shot.png"]);
});

test("a refused <img> says why instead of vanishing", async () => {
  const { html, urls } = await render(
    '<img src="https://tracker.invalid/beacon.png">',
    { fetchImpl: async () => new Response("nope", { status: 404 }) }
  );

  assert.deepEqual(urls, ["https://tracker.invalid/beacon.png"], "this is an attempted-and-failed fetch, not a policy refusal");
  assert.match(html, /md-viewer-image-failed/);
  assert.match(html, /title="HTTP 404[^"]*tracker\.invalid/);
  // The refused URL may appear as inert placeholder text, never as a src the
  // browser could dereference.
  assert.doesNotMatch(html, /src="https:\/\/tracker\.invalid/);
});

test("an <img> pointed at a non-public destination is refused before any request is made", async () => {
  const { html, urls } = await render(
    '<img src="https://internal.example/beacon.png">',
    { resolveHost: async () => [{ address: "169.254.169.254", family: 4 }] }
  );

  assert.deepEqual(urls, [], "policy is decided before any request is made");
  assert.match(html, /md-viewer-image-blocked/);
  assert.match(html, /title="[^"]*public address[^"]*internal\.example/);
  assert.doesNotMatch(html, /src="https:\/\/internal\.example/);
});

test("only src, alt, title, width and height cross over", async () => {
  const { html } = await render(
    '<img onerror="alert(1)" style="position:fixed" class="markdown-alert" id="installation"'
    + ' loading="eager" srcset="https://elsewhere.invalid/x 2x" src="https://img.allowed.example/a.png">'
  );

  for (const dropped of ["onerror", "style", "srcset", "loading", "markdown-alert", "installation"]) {
    assert.doesNotMatch(html, new RegExp(dropped), `${dropped} must not reach the output`);
  }
  assert.match(html, /<img src="data:image\/png/);
});

test("width and height must be bare integers", async () => {
  // sanitize-html validates attribute names and never their values, so this
  // parser is the only guard standing between a document and an unvalidated
  // attribute value.
  const { html } = await render(
    '<img width="1 onload=alert(1)" height="123456" src="https://img.allowed.example/a.png">'
  );
  assert.doesNotMatch(html, /onload/);
  assert.doesNotMatch(html, /width=/, "a non-integer width is dropped, not sanitized");
  assert.doesNotMatch(html, /height=/, "six digits is past the five-digit cap");
});

test("the first src wins, so a duplicate cannot redirect the fetch", async () => {
  const { html, urls } = await render(
    '<img src="https://img.allowed.example/a.png" src="https://img.allowed.example/evil.png">',
  );
  assert.deepEqual(urls, ["https://img.allowed.example/a.png"]);
  assert.match(html, /<img src="data:image\/png/);
});

test("a source markdown-it would refuse in ![](...) is refused here too", async () => {
  for (const source of ["javascript:alert(1)", "vbscript:msgbox", "data:text/html;base64,PHNjcmlwdD4="]) {
    const { html } = await render(`<img src="${source}">`);
    assert.match(html, /&lt;img src=/, `${source} must render as literal text, not an image`);
    assert.doesNotMatch(html, /<img /);
  }
});

test("no tag other than <img> is recognized", async () => {
  // `<image>` is a real SVG element one letter away from `<img>`; the rest are
  // the tags that would matter most if the rule ever widened.
  const tags = [
    '<iframe src="https://img.allowed.example/x"></iframe>',
    "<script>alert(1)</script>",
    '<video src="https://img.allowed.example/a.mp4"></video>',
    '<image src="https://img.allowed.example/a.png">',
    '<imgx src="https://img.allowed.example/a.png">',
  ];
  for (const tag of tags) {
    const { html } = await render(tag);
    assert.doesNotMatch(html, /<img |<iframe|<script|<video/, `${tag} must render as escaped text`);
  }
});

test("the tag is bounded by its own quoting and by its line", async () => {
  // `alt="a > b"` is ordinary prose and is exactly what a `/<img[^>]*>/` regex
  // gets wrong.
  const quoted = await render('<img alt="a > b" src="https://img.allowed.example/a.png"> and then text');
  assert.match(quoted.html, /alt="a &gt; b"/);
  assert.match(quoted.html, /and then text/);

  // An unterminated tag must cost its own line and nothing more -- never
  // swallow the rest of the document into an attribute.
  const runaway = await render('<img src="https://img.allowed.example/a.png" alt="x\n\n# A heading\n\ntail');
  assert.deepEqual(runaway.urls, [], "an unterminated tag is not an image and fetches nothing");
  assert.match(runaway.html, /<h1[^>]*>/, "the heading after it still parses as a heading");
  assert.doesNotMatch(runaway.html, /<img /);
});

test("a standalone <img> line renders identically with raw_html on and off", async () => {
  // With html:true markdown-it's *block* html_block rule consumes a lone tag on
  // its own line before inline parsing ever runs, so the two modes reach the
  // image token by different routes. They must still converge.
  const markdown = 'text above\n\n<img width="10" alt="p" src="https://img.allowed.example/a.png" />\n\ntext below';
  const off = await render(markdown, { rawHtml: false });
  // Between the two, or the second render is served from the process-global
  // cache and the fetch count stops proving anything about the block route.
  _resetCacheForTests();
  const on = await render(markdown, { rawHtml: true });

  assert.equal(off.html, on.html);
  assert.deepEqual(off.urls, ["https://img.allowed.example/a.png"]);
  assert.deepEqual(on.urls, ["https://img.allowed.example/a.png"],
    "the block route must feed the prefetch too, not just the inline one");
  assert.match(off.html, /<img src="data:image\/png[^"]*" alt="p" width="10"/);
});

test("a line that only starts with an <img> stays one paragraph", async () => {
  // The block rule must not claim a line with trailing text; markdown-it's
  // paragraph handling already routes that to the inline rule correctly, and
  // splitting it would drop the lazy continuation onto its own paragraph.
  const markdown = '<img src="https://img.allowed.example/a.png"> caption text\nand a continuation line';
  for (const rawHtml of [false, true]) {
    const { html } = await render(markdown, { rawHtml });
    assert.equal((html.match(/<p/g) ?? []).length, 1, `raw_html=${rawHtml} must produce one paragraph`);
    assert.match(html, /caption text/);
    assert.match(html, /and a continuation line/);
  }
});

test("a local <img> is confined to the document root like any other image", async () => {
  const { html } = await render('<img src="../../../etc/passwd">', {
    baseDir: "/nonexistent/deep", documentRoot: "/nonexistent",
  });
  assert.doesNotMatch(html, /src="\.\.\//);
  assert.match(html, /md-viewer-image-(blocked|failed)/);
});
