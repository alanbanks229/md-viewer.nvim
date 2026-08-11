# Security policy

## Reporting a vulnerability

Use GitHub's private vulnerability-reporting flow for this repository. Do not
open a public issue for an undisclosed vulnerability. Include the affected
version, your configuration, the impact, and the smallest reproduction you can
safely provide.

Fixes are provided for `main` and the latest tagged release.

## What the defaults enforce

Enough to judge whether a finding is a bug or a documented trade-off. `:help
md-viewer-security` summarizes the boundary; [docs/architecture.md](docs/architecture.md)
explains the mechanisms.

- Playwright aborts every browser request except `data:` and `about:`. The page
  CSP denies all by default, JavaScript is disabled in the render context, and
  CSS, fonts, themes, and highlighting are bundled locally.
- Raw Markdown HTML is off. Enabled, its output still passes an allowlist
  sanitizer; scripts, event attributes, and frames stay forbidden. One tag is
  read regardless of that setting: a bare `<img>` is parsed into an ordinary
  Markdown image and carries only `src`, `alt`, `title`, and integer
  `width`/`height`. It gains no privilege by being written as HTML — the same
  resolver, the same document root, the same visible placeholder when refused.
- Local images are inlined as data URIs only after validation: PNG, JPEG, GIF,
  or WebP, extension and magic bytes in agreement, regular files, size capped by
  `max_local_image_bytes`. SVG is excluded until a dedicated SVG sanitizer
  exists. Remote images pass the same validation, fetched over https by the
  renderer process, never by the browser, and reach the page as the same kind
  of data URI. An image that fails any of this renders as a visible
  placeholder naming the reason instead of disappearing.
- A remote image URL is only ever connected to if it resolves to a public
  network address. Loopback, RFC1918 and other private ranges, link-local
  addresses (including `169.254.0.0/16`, the range cloud metadata services
  live in), and multicast/reserved ranges are refused — on the URL as written
  and on every redirect hop, before a connection is attempted. This is not
  configurable: there is no allowlist and no way to widen it. The address a
  hostname resolves to is the exact address connected to, pinned at resolution
  time, so a hostname that would answer differently on a second lookup cannot
  slip a different address in between validating and connecting.
- Containment in `security.document_root` is checked both lexically and against
  `realpath`, so neither `../` nor a symlink escapes. The lexical rejection
  happens before the filesystem is consulted, so the difference between "does
  not exist" and "outside the document root" cannot be used to probe for files.
- Animated images are decoded in a second, dedicated browser context — never
  the render context, whose disabled JavaScript and deny-all CSP are untouched.
  That decode context does enable JavaScript, because WebCodecs requires a
  page, and its boundary is explicit (`renderer/src/decode-context.js`): the
  only code that runs is the project's own decode function; the page is one
  synthetic internal URL served from an inline constant with a deny-all CSP,
  every other request aborted, and the context offline; and the image bytes
  enter as data — staged through a renderer-owned file, handed to Chromium's
  sandboxed, continuously fuzzed image decoders. That last point is the reason
  this design exists: attacker-influenced GIF/WebP bytes are parsed by the
  same hardened decoders a browser tab uses, not by hand-written LZW in the
  Node process. Anything malformed, oversized, or over the frame caps degrades
  to the still frame the base screenshot already carries.

## Deliberate trade-offs

Two settings widen the boundary on purpose. `:MdViewerHealth` reports each as
an override rather than leaving it to be inferred.

`security.raw_html = true` sends the rest of the document's HTML to the
sanitizer instead of dropping it. It is not needed for images: both Markdown
image syntax and a bare `<img>` tag are recognized regardless.

`security.document_root = "/"` switches containment off, so the preview opens
whatever Neovim itself would — which is the point of it. The cost is that a
document you did not write can point an `<img>` at any image-shaped file on the
machine. The image rules above still bound that, and because browser networking
is always blocked and image URLs are static text in a JavaScript-free page, it
is an "is this file an image" oracle rather than a way to send one anywhere.

Remote images are not one of these two settings, because there is nothing left
to widen — fetching one is unconditional, and the public-destination check
described above is an invariant, not a setting. Two residues are inherent and
accepted regardless: previewing a document that references a remote image
sends that host a request, disclosing that the document was viewed and your
source IP, and a host that passes the public-destination check is otherwise
trusted — nothing pins its DNS beyond the connection itself, so a public host
that turns hostile later is out of scope. The check also does not attempt to
enumerate every non-globally-routable IANA allocation; it refuses the
well-known loopback, private, link-local, and reserved ranges relevant to
SSRF, which is the threat it exists for.

## Installing

Dependencies are pinned to exact versions with integrity hashes in
`renderer/package-lock.json`. The project defines no lifecycle scripts,
downloads no browser, and sends no telemetry. Rendering a preview needs no
network access beyond what the document itself asks for: one with no remote
images needs none, and one that has any causes the renderer process — never
the browser — to fetch them. Installation itself may contact your configured
npm registry; review the lockfile and your npm configuration first if that
matters where you work.
