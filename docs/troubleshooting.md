# Troubleshooting

Start with `:MdViewerHealth`, which separates terminal detection, Kitty protocol
advertisement, actual probe status, `vim.ui.img` presence, and a successful image
render. `TERM_PROGRAM=iTerm.app` alone is never treated as proof.

## Preview uses styled text instead of a PNG

`auto` selected the cell fallback because the installed build did not expose a
usable `vim.ui.img` API. This is a build/API availability issue, not a Kitty.app
dependency. Explicitly select `backend = "kitty_raw"` inside a direct iTerm2 TUI
for the supported graphical path.

## Explicit backend reports unavailable

This is intentional: explicit `nvim_img` and `kitty_raw` selections do not
silently fall back. Use `:MdViewerHealth`; select `cells` while investigating.

## Renderer exits or Playwright is missing

Run the locked local install from `renderer/`:

```sh
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts
```

Do not run `playwright install`. Confirm that the approved Chrome path shown by
`:MdViewerHealth` exists and set `browser.executable_path` when needed. Renderer
stderr and request serials are available through `:MdViewerDebug`.

## Image is stretched or soft

Set the actual iTerm2 profile cell size, in pixels:

```sh
export MD_VIEWER_CELL_WIDTH_PX=10
export MD_VIEWER_CELL_HEIGHT_PX=20
```

Those numbers are examples only—measure the active profile rather than copying
them. Health should then report `viewport calibration: explicit`.

## Local image is absent

Confirm it is PNG/JPEG/GIF/WebP, below the byte limit, and canonically inside
`security.document_root`. A symlink pointing outside the root is rejected. SVG
and every remote URL are intentionally unsupported.

## Mouse wheel does not move the preview

Confirm `sync.mouse_scroll = true`, that Neovim mouse support is enabled, and
that the pointer is inside the preview content window. The handler is scoped by
the window under the pointer; it intentionally does not turn source-window
wheel events into preview motion. Vim navigation continues to work even when
mouse support is disabled.

## Preview scrolling feels slow

Run `:MdViewerDebug` after a scroll and compare the persisted `fast_*` and
`retina_*` values, especially `fast_capture_ms`, `fast_png_bytes`, and
`fast_image_update_ms`. The coalesced counter shows how much repeated input was
collapsed to the newest position. Completed frames are not deliberately
discarded. If terminal transfer remains dominant, lower
`render.device_scale_factor` to `1` as a final quality/performance tradeoff.

## Preview typography is smaller than VS Code

The browser CSS uses a 14 px system-font baseline. A visual size
mismatch usually means the estimated terminal cell width is too large, causing
iTerm2 to scale the whole screenshot down. Lower
`render.estimated_cell_width_px` gradually. Prefer exact `MD_VIEWER_CELL_WIDTH_PX` and
`MD_VIEWER_CELL_HEIGHT_PX` values when available.

## Image overlaps UI or survives close

For `kitty_raw`, confirm `:MdViewerHealth` reports raw z-index `-1` and
`:MdViewerDebug` reports `occluded = true` while an overlapping float is visible.
The overlap guard removes the image only for focusable UI. Non-focusable
notifications create cropped placement cutouts, exposing their actual background
without blanking the rest of the Markdown document. `:MdViewerDebug` reports the
active count as `passive_cutouts`.

If a provider creates windows with `noautocmd=true`, confirm debug output shows
`ui_polling = true`. The default 50 ms interval discovers focusable floats
without requiring provider-specific hooks. Passive notifications are ignored by
full suppression; the same poll updates their cutout geometry without
retransmitting the PNG.

Stop and record the exact backend, iTerm2/Neovim versions, statusline/winbar
configuration, and reproduction in a bug report. Use `:MdViewerSpikeStop` or
`:MdViewerClose`; md-viewer deletes only IDs it owns. Do not use
global image deletion because that can damage unrelated plugins.
