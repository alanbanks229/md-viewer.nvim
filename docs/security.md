# Security model

The renderer has no WebSocket, listening socket, or HTTP server. Chromium is headless, uses
an isolated temporary context, disables extensions, and never uses the regular
browser profile.

Default policy:

- Playwright aborts every request except `data:` and `about:` resources.
- CSP denies all by default and separately denies scripts, connections, frames,
  objects, fonts, and media.
- Markdown HTML parsing is off. If explicitly enabled, output is still passed
  through an allowlist sanitizer; scripts, event attributes, frames, and remote
  image sources remain forbidden.
- CSS, fonts, highlighting code, and themes are bundled locally.
- Remote images, embedded video, iframes, and browser-side interactivity are not
  supported.
- Local images are converted to data URIs before page content is set.

Local-image authorization uses both lexical resolution and `realpath`. The file
and configured root must exist, the canonical file must remain inside the
canonical root, and symlinks cannot escape it. Only PNG, JPEG, GIF, and WebP are
accepted. Both extension and magic bytes must agree, the target must be a normal
file, and its size must not exceed `max_local_image_bytes`. SVG is deliberately
excluded until a dedicated SVG sanitizer exists.

`security.network = true` and `render.raw_html = true` are reported as security
overrides by `:MdViewerHealth`. Remote Markdown images are still removed. Changing
network policy while an existing renderer context is alive requires closing all
previews so the context can restart; the stricter existing policy otherwise
remains in force.

Dependencies are exact versions with integrity hashes in the lockfile. The
documented install uses `npm ci --ignore-scripts` and
`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`. The project defines no lifecycle scripts,
downloads no browser, and includes no telemetry.
