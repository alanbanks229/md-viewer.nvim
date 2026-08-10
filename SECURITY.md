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
  sanitizer; scripts, event attributes, frames, and remote image sources stay
  forbidden.
- Local images are inlined as data URIs only after validation: PNG, JPEG, GIF,
  or WebP, extension and magic bytes in agreement, regular files, size capped by
  `max_local_image_bytes`. SVG is excluded until a dedicated SVG sanitizer
  exists. Remote images pass the same validation when — and only when — their
  host is allowlisted in `security.remote_images` (empty by default): they are
  fetched over https by the renderer process, never by the browser, and reach
  the page as the same kind of data URI. An image that fails any of this
  renders as a visible placeholder naming the reason instead of disappearing.
- Containment in `security.document_root` is checked both lexically and against
  `realpath`, so neither `../` nor a symlink escapes. The lexical rejection
  happens before the filesystem is consulted, so the difference between "does
  not exist" and "outside the document root" cannot be used to probe for files.

## Deliberate trade-offs

Three settings widen the boundary on purpose. `:MdViewerHealth` reports each as
an override rather than leaving it to be inferred.

`security.remote_images` names hosts whose images the renderer process may
fetch. Allowlisting a host grants exactly one thing — image bytes, size-capped
while streaming, admitted only when their magic bytes are a supported format —
because the browser's own network policy is unconditional and never consults
the list. `*.example.com` matches proper subdomains only, never the bare domain
and never `evil-example.com`; redirects are followed at most three hops with
every hop re-checked against the allowlist, so an allowlisted host cannot
bounce the fetch somewhere else. Two residues are inherent and accepted:
previewing a document that references images on an allowlisted host sends
requests there, disclosing that the document was viewed, and an allowlisted
host is trusted — nothing pins its DNS, so a malicious entry on your own list
is out of scope.

`security.raw_html = true` sends document HTML to the sanitizer instead of
dropping it; a remote `<img>` in raw HTML stays stripped regardless of the
allowlist, which governs Markdown image syntax only.

`security.document_root = "/"` switches containment off, so the preview opens
whatever Neovim itself would — which is the point of it. The cost is that a
document you did not write can point an `<img>` at any image-shaped file on the
machine. The image rules above still bound that, and because browser networking
is always blocked and image URLs are static text in a JavaScript-free page, it
is an "is this file an image" oracle rather than a way to send one anywhere.

## Installing

Dependencies are pinned to exact versions with integrity hashes in
`renderer/package-lock.json`. The project defines no lifecycle scripts,
downloads no browser, and sends no telemetry, and rendering a preview needs no
network access unless `security.remote_images` is configured — then the
renderer process, never the browser, fetches those images. Installation itself
may contact your configured npm registry; review the lockfile and your npm
configuration first if that matters where you work.
