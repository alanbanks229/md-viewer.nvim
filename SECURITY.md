# Security policy

## Reporting a vulnerability

Use GitHub's private vulnerability-reporting flow for this repository. Do not
open a public issue for an undisclosed vulnerability. Include the affected
version, your configuration, the impact, and the smallest reproduction you can
safely provide.

Fixes are provided for `main` and the latest tagged release.

## What the defaults enforce

- Playwright aborts every browser request except `data:` and `about:`. The page
  CSP denies all, JavaScript is disabled in the render context, and CSS, fonts,
  themes, and highlighting are bundled locally.
- Raw Markdown HTML is dropped. When enabled, it goes through a sanitizer that
  still forbids scripts, event attributes, and frames. One tag is read either
  way: a bare `<img>` becomes an ordinary Markdown image carrying only `src`,
  `alt`, `title`, and integer `width`/`height`. Writing it as HTML grants no
  privilege — same resolver, same document root, same placeholder when refused.
- Images are inlined as data URIs only after validation: PNG, JPEG, GIF, or
  WebP, extension and magic bytes in agreement, regular file, size capped by
  `max_local_image_bytes`. SVG is excluded until a dedicated sanitizer exists.
  Remote images pass the same checks and are fetched over HTTPS by the renderer
  process, never the browser. Anything that fails renders as a visible
  placeholder naming the reason instead of disappearing.
- Remote fetches only ever reach public addresses. Loopback, RFC1918 and other
  private ranges, link-local addresses (including `169.254.0.0/16`, where cloud
  metadata services live), and multicast/reserved ranges are refused — on the
  URL as written and on every redirect hop, before a connection is attempted.
  There is no allowlist and no way to widen it. The resolved address is the one
  connected to, pinned at resolution time, so a second lookup cannot substitute
  a different address in between validating and connecting.
- Containment in `security.document_root` is checked lexically and against
  `realpath`, so neither `../` nor a symlink escapes. The lexical check runs
  before the filesystem is consulted, so "does not exist" and "outside the
  document root" cannot be told apart to probe for files.
- Animated images are decoded in a second browser context, never the render
  context. That context does enable JavaScript, because WebCodecs requires a
  page, but its boundary is explicit (`renderer/src/decode-context.js`): the
  only code that runs is the project's own decode function, the page is one
  synthetic internal URL served from an inline constant with a deny-all CSP,
  every other request is aborted, and the context is offline. Image bytes enter
  as data, staged through a renderer-owned file, so attacker-influenced
  GIF/WebP is parsed by Chromium's sandboxed, continuously fuzzed decoders
  rather than by hand-written LZW in the Node process. Anything malformed,
  oversized, or over the frame caps falls back to the still frame the base
  screenshot already carries.

## Deliberate trade-offs

Two settings widen the boundary on purpose. Neither is inferred from a config
file: `:MdViewerDebug` reports both under `-- Security --`, and a document root
of `/` is called out in `:MdViewerHealth` as well.

`security.raw_html = true` sends the rest of the document's HTML to the
sanitizer instead of dropping it, and shows in `:MdViewerDebug` as
`overrides: SECURITY RELAXED`. It is not needed for images: both Markdown
image syntax and a bare `<img>` tag are recognized regardless.

`security.document_root = "/"`:
The preview opens whatever Neovim itself would — which is the point of it.
The cost is that a document you did not write can point an `<img>` at any
image-shaped file on the machine. The image rules above still bound that, and
because browser networking is always blocked and image URLs are static text
in a JavaScript-free page, it is an "is this file an image" oracle rather than
a way to send one anywhere.

## Installing

Dependencies are pinned to exact versions with integrity hashes in
`renderer/package-lock.json`. The project defines no lifecycle scripts,
downloads no browser, and sends no telemetry. Rendering a preview needs no
network access beyond what the document itself asks for: one with no remote
images needs none, and one that has any causes the renderer process — never
the browser — to fetch them. Installation itself may contact your configured
npm registry; review the lockfile and your npm configuration first if that
matters where you work.
