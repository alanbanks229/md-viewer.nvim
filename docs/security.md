# Security model

The renderer has no WebSocket, listening socket, or HTTP server. Chromium is headless, uses
an isolated temporary context, disables extensions, and never uses the regular browser profile.

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

The document root is the boundary for both local images and local links, and one
implementation computes it (`lua/md-viewer/security.lua`'s `document_root`). By
default it is the **project** enclosing the document -- the nearest ancestor
directory holding one of `security.document_root_markers` (`.git`, `.hg`, `.svn`)
-- falling back to the document's own directory where no marker is found, and to
Neovim's working directory for a buffer that has never been written. Setting
`security.document_root` explicitly always wins.

The project default is wider than the per-directory default it replaced, and that
widening is deliberate: rooting the boundary at the document's own folder made
every ordinary repo-relative link (`../README.md` from `docs/`) unreachable. It
widens *where* the boundary sits, not *how* it is enforced -- `../` and symlinks
are refused exactly as before, and a repository is the unit a reader already
trusts, since every file inside it is one the preview would render anyway.

Setting `document_root = "/"` is supported and switches the containment off
deliberately: the preview then opens whatever Neovim itself would open, which
is the point of it. The trade is that a document you did not write can point an
`<img>` at any image-shaped file on the machine. That remains bounded by the
image rules below (extension and magic bytes must agree, four formats only,
size-capped) and by `security.network = false`, so it is an "is this file an
image" oracle rather than a way to send one anywhere. `:MdViewerHealth` reports
the unbounded root rather than leaving it to be inferred, and warns outright if
the network is enabled alongside it.

An out-of-root path is rejected lexically, before the filesystem is consulted, so
the distinct "does not exist" and "outside the document root" messages cannot be
used by a hostile document to probe for the existence of files outside the root.

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
- A `local_file` link is never passed to `vim.ui.open` when the target is
  something the operating system would execute rather than display: macOS
  bundles and scripts (`.app`, `.command`, `.terminal`, `.workflow`, ...),
  Windows executables and script hosts, `.desktop`/`.AppImage`/`.jar`, disk
  images and installers, or any regular file with an execute bit set
  (`lua/md-viewer/security.lua`'s `is_system_executable`). Two independent
  signals because neither suffices alone: bundles are directories, so no file
  mode applies to them, and an ordinary executable may have no telling name.
  This is deliberately independent of the document root, which was never a
  defence against it -- a repository you cloned can ship `setup.command` beside
  its README and link to it from within the root.
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
