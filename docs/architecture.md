# Architecture

## Data flow

The controller reads unsaved lines from each source buffer. All buffer-specific
state—windows, backend, request serials, image ID, block geometry, scroll value,
timers, and synchronization guard—lives in that buffer's session. Sessions share
one `node` process per Neovim instance.

Requests and responses are newline-delimited JSON with numeric IDs. The Node
process keeps one headless Chromium browser, isolated context, and page alive.
It parses Markdown with markdown-it, annotates tokens using `token.map`, applies
bundled CSS and syntax highlighting, scrolls the page, and screenshots only the
visible viewport. Lua reads the returned temporary PNG then unlinks it. Both
sides reject/supersede stale work.

Transport remains local NDJSON over the renderer process's stdin/stdout pipes.
No WebSocket is used: the renderer is already persistent, no connection is
re-established per edit, and adding WebSockets would require a listening
HTTP/TCP endpoint while leaving browser layout, PNG capture, and terminal image
transfer untouched. Scroll-only work instead reuses cached Markdown HTML, the
live DOM, document geometry, and token source map, then performs only a page
scroll and viewport screenshot.

Interactive scrolling uses a two-stage capture. The first image uses
Playwright's CSS-pixel screenshot scale, avoiding the fourfold pixel area of a
2× device-scale PNG. Once input settles, one device-scale screenshot restores
Retina sharpness. Capture requests identify a cached document revision and omit
the Markdown body entirely. Controller backpressure permits at most one moving
capture plus one newest pending position, and each completed frame is shown.
There is no fixed frame limiter; screenshot and terminal-transfer completion
provide the natural pacing.

## Preview surface and coordinates

`preview.lua` creates a normal read-only `nofile` scratch buffer, never a
terminal. `coordinates.lua` uses `screenpos(win, 1, 1)` for the first visible
buffer cell and Neovim's window width/height for the exact text grid. A winbar,
statusline, tabline, global statusline, separator, and command line are therefore
outside the placement rectangle. Resize and scroll events recalculate it.

During the initial persistent-renderer and Chromium startup, `preview.lua`
centers a one-line non-focusable spinner float relative to the preview window.
The scratch buffer itself stays one blank line. A successful first frame removes
the spinner before calculating Kitty placements; a renderer failure removes it
before emitting the actionable notification. Its timer is owned by the buffer
session and is closed on every preview shutdown path.

The raw backend uses z-index `-1`, which keeps the image below terminal text
while remaining visible above the Neovim backgrounds painted by iTerm2. It
reserves a one-cell bottom guard when Neovim reports a statusline. Visible
floating-window rectangles are discovered through
`nvim_tabpage_list_wins()`, `nvim_win_get_config()`, and screen coordinates. An
overlapping focusable float suppresses the placement and closing it restores the
cached PNG without another browser capture. Non-focusable passive overlays are
tracked as exclusion rectangles on the placement, which `interaction.locate`
uses to refuse a click that lands on one. `kitty_raw.lua` can also subtract
those rectangles as cropped source-image placements, but the controller no
longer re-crops when only the exclusions change: doing so on every appearing or
disappearing notification was visible as the image rolling by about a row (see
`same_geometry` in `controller.lua`).

Because a raw placement is absolute screen coordinates the terminal keeps
compositing on its own, it must be deleted whenever the preview window stops
being displayed — including when the preview's *tabpage* is no longer the one
on screen, which no window API reports (`coordinates.window_is_displayed`).

Raw sessions perform a small periodic geometry check in addition to Neovim
window events. Some asynchronous UI providers create floats with
`noautocmd=true`; polling the current tab's window metadata catches those
without any dependency on the provider.

Pixel calibration is explicit when `MD_VIEWER_CELL_WIDTH_PX` and
`MD_VIEWER_CELL_HEIGHT_PX` exist. Otherwise the renderer chooses a bounded high-DPI
viewport using `estimated_cell_width_px` and the configured cell aspect ratio;
the terminal scales that image to cells. Screenshots are capped at 1920×1440
logical pixels, a device scale of
at most 3, and 32 MiB on the Lua boundary.

## Backends

All image implementations expose `detect`, `show`, `update`, `move`, `clear`,
`clear_all`, and `health`.

- `nvim_img` wraps only `vim.ui.img`; replacement creates the new image before
  deleting the old owned ID. It never performs wildcard deletion.
- `kitty_raw` contains the minimal direct protocol encoder: PNG/base64 chunks,
  static cell placement, cursor preservation, quiet mode, movement, and targeted
  deletion. It writes only through `nvim_ui_send`. Because Neovim owns terminal
  input, its response probe is not falsely reported as successful and auto mode
  does not select it in this build.
- `cells` writes readable Markdown-like text and extmark highlights into the
  preview buffer when graphics are unavailable.

## Scroll synchronization

The graphical preview buffer remains one blank line; it no longer pretends that
browser pixels are editable buffer lines. Buffer-local Vim motions update browser
`scrollY` directly: line, half-page, page, top, and bottom movements. Source
lines map to browser blocks through markdown-it token ranges and measured DOM
geometry. A per-session guard prevents preview/source feedback. The most specific token
range containing the cursor wins over enclosing lists, tables, and blockquotes.
Its relative source-line position is aligned to the cursor's actual screen row,
with hysteresis and a short debounce so walking adjacent lines does not produce
a screenshot on every keypress. Cursor movement within the same mapped block
does not issue another render.

Navigation allows one capture in flight and retains only the newest pending
position. Every completed frame is displayed, with no fixed FPS throttle. The
preview mappings never move the source cursor; preview-to-source movement is
disabled in the bundled iTerm2 configuration.

The browser page includes a viewport-relative bottom spacer by default. Its
height is one viewport minus a rendered line, matching editor scroll-past-end
behavior so the final Markdown block can reach the preview's top region. This
is real browser scroll range, not synthetic scratch-buffer lines.

Mouse-wheel mappings are installed only while a graphical preview exists. The
pointer's actual Neovim window ID selects the session; events outside an md-viewer
window fall through to the original Neovim wheel behavior. The mappings and any
previous user mappings are restored after the last graphical preview closes.

## Lifecycle

Text events debounce, resize events coalesce, focus stays in the source window,
and tab/suspend events remove graphical placements. Close/wipe/exit invalidates
outstanding serials, stops timers, deletes only owned images, removes files, and
shuts the shared renderer down when the last session closes.

With `preview.pinned = true`, hiding the source buffer does not end its session.
The source split can display another file while the preview split retains its
Markdown image and source-labeled winbar. Wiping the source, replacing/wiping
the preview buffer, explicitly closing the preview, or exiting Neovim still
performs full cleanup.

## Design references

The pinned document identity, labeled preview surface, retained renderer state,
stale-response guards, and manual-scroll precedence take focused inspiration
from [Markdown Preview Enhanced's preview provider](https://github.com/shd101wyy/vscode-markdown-preview-enhanced/blob/master/src/preview-provider.ts)
and its documented locked-preview workflow. md-viewer does not copy its webview,
script execution, CDN, diagram, export, or interactive command features; those
would conflict with a read-only raster surface and the version-one security
boundary.
