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
- A link to a non-Markdown file is handed to the operating system's opener, but
  never if the target is executable: macOS bundles and scripts, Windows
  executables, `.desktop`/`.AppImage`/`.jar`, disk images, or any file carrying
  an execute bit are refused with a notification rather than launched. Markdown
  targets open as a preview tab and never leave Neovim. Both checks happen after
  the document-root and symlink containment above, not instead of it.
- Remote fetches only ever reach public addresses. Loopback, RFC1918 and other
  private ranges, link-local addresses (including `169.254.0.0/16`, where cloud
  metadata services live), and multicast/reserved ranges are refused — on the
  URL as written and on every redirect hop, before a connection is attempted.
  There is no allowlist and no way to widen it. The resolved address is the one
  connected to, pinned at resolution time, so a second lookup cannot substitute
  a different address in between validating and connecting. `$HTTP_PROXY` and
  `$HTTPS_PROXY` are deliberately not consulted: a proxied connection goes where
  the proxy sends it, which this process cannot verify, so pinning — and with it
  the whole check — would become decorative. The cost is that remote images do
  not load on a network that requires a proxy; reconciling the two is an open
  design question rather than an omission.
- Containment in `security.document_root` is checked lexically and against
  `realpath`, so neither `../` nor a symlink escapes. The lexical check runs
  before the filesystem is consulted, so "does not exist" and "outside the
  document root" cannot be told apart to probe for files.
- Native Obsidian navigation is off by default. When enabled, explicit note
  paths resolve from `obsidian.vault_root` (or the document root when unset),
  and bare-name lookup scans only Markdown files under that boundary. Every
  result is checked against `realpath`, including symlinks, before a buffer is
  loaded. Missing notes are never created; embeds are never expanded.
- Animated images are decoded in a second browser context, never the render
  context. That context does enable JavaScript, because WebCodecs requires a
  page, but its boundary is explicit (`renderer/src/decode-context.js`): one
  synthetic internal URL with a deny-all CSP, offline, every other request
  aborted, and the project's own decode function the only code that runs.
  Attacker-influenced GIF/WebP is therefore parsed by Chromium's sandboxed
  decoders rather than by hand-written LZW in the Node process, and anything
  malformed or past the caps falls back to the still frame.

## The optional local-render helper

The plugin and the renderer open no listening port of any kind, ever. With
`render.location = "local"` the operator additionally runs
`renderer/src/local-main.js` by hand around their own ssh session, and that
helper is the one listener in the system. Its boundary:

- **One unix-domain socket, never TCP** (`tests/node/local-no-listening-port.test.js`
  pins the never-TCP part): mode 0600 in a 0700 directory under the
  operator's own `~/.local/state`, alive for the lifetime of one ssh session.
  The remote endpoint is the `ssh -R` forward the helper adds to its own ssh
  invocation; the plugin verifies the remote socket file's owner and
  permissions before use, and garbage-collects stale ones.
- **A per-run 128-bit token** authenticates markers. It travels only over the
  control socket's hello, never through the terminal stream, and the one-shot
  unauthenticated `status` query answers counters only — never the token,
  never document content. Adoption additionally requires the **pairing
  probe**: the plugin emits a sequence-0 marker through its own tty, and only
  the helper whose filter sits on that terminal can confirm it — a spoofed
  socket can say hello but can never pair.
- **Assets are push-only.** The helper can never request a path; the VM
  pushes content-addressed bytes that already passed the unchanged VM-side
  validation (document-root confinement, magic bytes, size caps, the SSRF
  policy above), and the helper verifies each push against its hash — the
  channel cannot rename one image into another. Remote-image fetching stays
  on the VM: the helper's Node process makes no outbound connections, and
  its Chromium runs the identical route-abort/deny-all-CSP/JavaScript-off
  configuration as the VM's.
- **Markers cannot execute anything.** A marker is a frame/placement
  description; its placement bytes are terminal graphics escapes built by
  the plugin, injected only at parse-safe boundaries, and anything without
  the token — including a hostile file `cat`ed in the session — passes
  through the filter byte-for-byte unexamined.

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
