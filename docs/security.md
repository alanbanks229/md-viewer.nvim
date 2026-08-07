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

## Interaction surface

Mouse/keyboard interaction (drag-to-select, double/triple-click, search,
link activation, `activate_at` hit-testing) is a second, later door into the
same renderer process, not a new one to a different surface:

- Every `interact` request resolves against the document the renderer
  already rendered and cached (`renderMarkdown`'s sanitized output); no
  interaction re-parses Markdown, so a selection or a click cannot introduce
  anything the original sanitizer allowlist did not already permit.
- `ensureDocumentActive()` (`renderer/src/browser.js`) refuses to answer for
  any document/content-revision it cannot rebuild byte-for-byte from its own
  cached record, and every in-page action checks a fresh, opaque per-load
  token before touching the DOM (`DOCUMENT_MISMATCH`) -- one document's
  interaction can never resolve against another's page state.
- Link activation classifies the href first (`classifyLink`) and only ever
  reaches `vim.ui.open` for `http`, `https`, or `mailto`; a `local_file`
  classification is independently re-checked against the configured document
  root with the same symlink-resolved containment check image loading uses
  (`lua/md-viewer/security.lua`'s `resolve_local_link`/`is_inside`); anything
  else (`javascript:`, `data:`, `vbscript:`, protocol-relative, malformed) is
  refused with a notification and never reaches `vim.ui.open` at all.
- Search queries and selected/copied text are always treated as plain text:
  the in-page code that implements them (`renderer/src/interact.js`) uses
  `Text.splitText`/`Range`/`Selection` APIs, never `innerHTML` or
  `document.write`, so a query or a selection containing literal HTML is
  matched or copied character-for-character and never interpreted as markup.
- A request against a superseded content revision, or one that targets a
  document the renderer no longer holds, is refused (`STALE_INTERACTION`/
  `INTERACT_CACHE_MISS`) rather than answered approximately.
- `:MdViewerDebug` reports selection and search state as **lengths and
  counts only** -- `selection_text_length`, `find_match_count`, and similar
  -- never the underlying text. The one exception, `find_query`, is the
  user's own locally typed search term, shown only to that same local user
  in a scratch buffer they opened themselves.
