---
part: 2
title: Portable rendering — generic Kitty backend and reliable geometry
status: done
model: Sonnet 5
depends_on: part 1
commit: "PENDING"
ships: v0.2.0
---

# Part 2 of 7 — Portable Rendering

> Read `prompts/00-policy.md` first.

## Objective

Remove iTerm2-specific policy from the Kitty encoder and drive placement
behaviour from the Part 1 terminal profiles instead. Make the coordinate and
geometry layer trustworthy across split positions, UI elements, and resizes.

**This part completes a shippable `v0.2.0`.** After it, the plugin should render
correctly on a Kitty-compatible terminal with no hand-tuned configuration.

---

## Verified repository facts

**`lua/md-viewer/backends/kitty_raw.lua` (190 lines)** already does most of the
hard protocol work correctly. Preserve all of it:

- Owned image IDs (`next_id`) and placement IDs (`next_placement_id`), both
  seeded from the PID so two Neovim instances cannot collide.
- Upload once (`a=t,f=100,t=d`), then place with cropped placements (`a=p`).
- Base64 chunking at 4096 bytes with `m=` continuation and `q=2` quiet mode.
- `visible_regions()` / `subtract()` / `intersect()` — rectangle subtraction that
  cuts passive floating overlays out of the placement rather than blanking the
  whole preview. This is good code. Do not rewrite it.
- Targeted deletion: `a=d,d=i` for placements, `a=d,d=I` for images.
- Cursor save/restore around placement via `\27[s ... \27[u`.
- `png_dimensions()` parses IHDR directly to size placements.

The **only** iTerm2-specific things in it are:

1. `zindex()` reads `config.get().image.raw_zindex`, a single global default of
   `-1` tuned for iTerm2.
2. `M.detect()` — being replaced in Part 1; confirm Part 1 left it coherent.
3. `M.health()` reports `advertised = vim.env.TERM_PROGRAM == "iTerm.app"`.

**`lua/md-viewer/coordinates.lua` (147 lines)** provides:
- `for_window(win)` → zero-based screen rect using `vim.fn.screenpos()`, plus
  `winbar`, `statusline`, `global_statusline`, `laststatus`, `topline` flags.
- `same(a, b)` — placement equality including exclusion rectangles.
- `intersects(a, b)`, `float_rect(win)` (includes border cells).
- `overlapping_floats(rect, win)` — focusable floats that force full suppression.
- `passive_overlays(rect, win)` — non-focusable float rects to cut out.
- `viewport(rect, render)` — cells → browser viewport. Uses env vars
  `MD_VIEWER_CELL_WIDTH_PX` / `MD_VIEWER_CELL_HEIGHT_PX` when both are set and
  positive (`calibrated = true`); otherwise falls back to
  `render.estimated_cell_width_px` and `render.cell_aspect_ratio`.

**The operator's real config** hardcodes `cell_aspect_ratio = 0.42` and
`estimated_cell_width_px = 7.5`, hand-calibrated against one iTerm2 profile. The
goal of §2.3 is to make those unnecessary.

**Config keys involved:** `image.raw_zindex` (default `-1`),
`image.raw_statusline_guard_cells` (default `1`), `image.ui_poll_ms`
(default `50`), `image.double_buffer` (default `true`).

---

## Read these files first

```text
lua/md-viewer/backends/kitty_raw.lua
lua/md-viewer/coordinates.lua
lua/md-viewer/terminal.lua          # created in Part 1
lua/md-viewer/preview.lua
lua/md-viewer/controller.lua        # 486 lines; the placement/redraw call sites
lua/md-viewer/config.lua
tests/lua/cases/                    # created in Part 1
```

---

## Implement

### 2.1 Move terminal policy out of the encoder

`kitty_raw.lua` should be a **generic** Kitty graphics encoder. Terminal-specific
behaviour becomes data supplied by the Part 1 profile:

- Default z-index (per profile, not one global `-1`).
- Whether placement replacement should delete-then-place or place-then-delete.
- Whether deleting an image implicitly removes its placements.
- Whether a redraw is required after resize.
- Whether placements must be recreated after an alternate-screen transition.
- How to behave when a focusable float overlaps the image.

Resolution order for z-index: explicit `image.raw_zindex` from user config wins;
otherwise the profile default. Make the effective value visible in health output,
along with which source supplied it.

Keep the user's ability to override every one of these. Profiles supply
defaults, not constraints.

### 2.2 Placement lifecycle

Verify and test the generic behaviours, adding whatever is missing:

- Negative, zero, and positive z-index all encode correctly.
- Replacement, placement deletion, and image deletion each emit exactly the
  sequences they should, and no others.
- Resize recomputes placement and reuploads only when the PNG actually changed.
- Split movement (left / right / above / below) produces correct placement.
- Alternate-screen transitions and suspend/resume recreate placements.
- Cropped placements remain correct when exclusions change.
- Font-size change and tab switch are handled.
- `double_buffer = false` still takes the clear-then-show path.

### 2.3 Geometry reliability

This is the substantive work of the part. The conversion chain is:

```text
terminal screen cells → preview-window cells → image-placement cells
                      → Chromium CSS viewport pixels → screenshot pixels
```

Get these right, with tests, because Part 4 will invert this chain to map mouse
positions back into the browser:

- One-based Neovim coordinates versus zero-based placement coordinates.
- Winbar, statusline, global statusline (`laststatus = 3`), tabline.
- Split separators and the command-line rows.
- `image.raw_statusline_guard_cells` boundary reservation.
- Cropped placements after exclusion changes.
- Resize while a preview is open.

**Cell-metric calibration.** Replace hand-tuned `cell_aspect_ratio` and
`estimated_cell_width_px` with a derivation where one is available. Neovim can
report grid pixel dimensions on some UIs; where that is unavailable, keep the
existing env-var override and the configured estimate as the fallback chain, and
report in health output which tier supplied the numbers
(`measured` / `env` / `estimated`). Do not invent a measurement that is not real
— an honest `estimated` is fine.

### 2.4 Health and debug

Report: effective z-index and its source, placement rectangle, preview size in
cells, Chromium viewport in CSS pixels, calibration tier, owned image and
placement counts, active exclusions, and any profile caveats that apply.

Before reporting this part done, invoke `:MdViewerHealth` and `:MdViewerDebug`
directly in a headless session (policy §5) — every new field above must
actually render, not merely exist in the returned table. Part 1 shipped a
crash from exactly this gap.

---

## Do not do in this part

- No DOM selection, no search, no `interact` protocol, no mouse gestures beyond
  the existing wheel dispatch.
- No changes to `renderer/src/markdown.js` or the source-map pipeline.
- No Sixel backend.
- Do not rewrite `visible_regions()` / `subtract()` / `intersect()`. They work.

---

## Tests to add

**Lua** (`tests/lua/cases/backend_kitty.lua`, `tests/lua/cases/coordinates.lua`):

Follow the existing pattern in `run.lua` — stub `vim.api.nvim_ui_send` to capture
emitted escape sequences, then assert on their content:

```lua
vim.api.nvim_ui_send = function(value) sequences[#sequences + 1] = value end
```

Cover: z-index encoding across profiles; profile-driven default selection; user
override beating profile default; placement replacement sequences; targeted
deletion; crop recomputation when exclusions change; upload-once behaviour;
`double_buffer = false`; PNG chunking boundaries; invalid-PNG rejection.

Coordinate cases: every split position; winbar present and absent; `laststatus`
0/1/2/3; tabline present; resize; cell→viewport conversion in all three
calibration tiers; clamping at viewport bounds; the guard-cell reservation.

Use the new `t.near()` for float geometry.

---

## Acceptance criteria

- [ ] `kitty_raw.lua` contains no terminal-specific policy; all of it is profile data.
- [ ] Profiles supply defaults for z-index, replacement, deletion, crop, redraw.
- [ ] Explicit user config overrides every profile default.
- [ ] Health reports the effective z-index and which source supplied it.
- [ ] Placement, replacement, deletion, and crop are covered by sequence-level tests.
- [ ] Geometry is correct for all split positions and all `laststatus` values.
- [ ] Calibration tier is derived where possible and reported honestly.
- [ ] Existing rendering, scrolling, and cursor-follow tests still pass.
- [ ] All Lua and Node tests pass.
- [ ] Status document updated per policy §6.

## Operator verification (manual — cannot be automated)

In your own Neovim config, delete these four lines and confirm the preview still
renders correctly:

```lua
image.backend = "kitty_raw"
browser.executable_path = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
render.cell_aspect_ratio = 0.42
render.estimated_cell_width_px = 7.5
```

If any of them is still required, Parts 1 and 2 are not finished. Record the
outcome in the status document — including if it failed.

---

## Commit

```text
feat(md-viewer): cross-platform preview part 2/7 - portable kitty backend
```

Then follow `prompts/00-policy.md` §6 and §7.
