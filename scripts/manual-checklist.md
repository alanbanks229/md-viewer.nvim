# Manual verification checklist

The headless suites prove the plumbing, but they cannot see a pixel. This
checklist is the eyes-on half: run it on a real terminal before tagging a
release, and for any change touching placement, interaction, or the selection
overlay. The animation checklist lives in [README.md](README.md), beside its
harness.

**Setup.** Open `tests/fixtures/kitchen-sink.md` (or
`tests/fixtures/provenance-comprehensive.md` for multibyte and emoji) with
`image.backend = "kitty_raw"` set explicitly, outside tmux/screen/Zellij.
Record the terminal name and version, OS, Neovim version, and whether HiDPI
scaling is active — a result with no environment recorded is not usable
evidence — and attach a screenshot for anything visual. Use at least one
`Supported` terminal from
[../docs/terminal-support.md](../docs/terminal-support.md), plus whichever
others you have.

Everything below covers the default path (`render.location = "current"`,
`image.resident = "off"`). The experimental modes have their own harnesses:
`resident/drive.lua` and the rigs under `local/` — see
[README.md](README.md).

## Rendering and sync

| Check | How | Expect |
|---|---|---|
| Image renders | `:MdViewerToggle` | A rendered page filling the split, correctly sized and positioned, with no hand-tuned `render.*` config |
| Live preview | Edit without `:w` | Follows within the debounce interval |
| Cursor follow | Move through the source | The preview scrolls to match |
| Scrolling | `j`/`k`, `Ctrl-d`/`u`, `Ctrl-f`/`b`, `gg`/`G`, wheel over the preview | Smooth, no flicker, no stray image. The wheel does nothing when the pointer is outside the preview |
| Resize and font size | Resize the window, then change the terminal's font size | Re-renders at the new geometry and stays aligned |
| Scroll scale over SSH | Wheel-scroll from an SSH session, then `:MdViewerDebug` | `scroll_scale = 0.5` naming `ssh_scroll_scale`, and `fast_png_bytes` well below what the same pane reports locally |
| Settle sharpness | Scroll hard over SSH, then stop and look | The moving frame may be visibly soft; the frame that settles shortly after is sharp. A preview that stays soft at rest is the failure this option can cause |

## The preview caret

| Check | How | Expect |
|---|---|---|
| Shaped like the glyph | Caret on an `# H1`, then on body text | A block the size of the character it is on — visibly larger on the heading, not a fixed cell |
| Never on nothing | Click right of a short heading; click in the left margin | Snaps onto the nearest real character; never hovers over blank space |
| Neovim's cursor is hidden | Focus the preview, then leave it | Only the block caret while focused; the ordinary cursor returns everywhere else, including after `:q`, a tab switch, and `:qa` |
| Only one caret after refocusing | Focus the preview, switch to another app, switch back, press nothing | Still only the block caret — Neovim's own must not be sitting beside it |
| Motions look right | `h`/`l` along a heading, `w` across a block boundary, `3j`, `gg`/`G` | The drawn block moves one step per press and the view scrolls to keep it visible |
| Caret stays put under `<C-e>` | `<C-e>` until the caret leaves the view | The view moves, the caret does not; it stops being drawn off screen and returns when scrolled back |
| Click agreement | Click somewhere, then press `l` | The caret lands where you clicked and continues from there |
| Non-overlay terminal | The same on WezTerm | Falls back to the terminal's cursor: a fixed cell, but on the right character. Neovim's cursor is *not* hidden there |

## Selection, search, and links

| Check | How | Expect |
|---|---|---|
| No drag mapping | Click and drag across a paragraph | Nothing highlights. Neovim may briefly show `V-BLOCK`/`-- VISUAL --` (its own unmapped-drag fallback) and recover on its own within a tick |
| Click-to-deselect | Click once with a selection active | The highlight clears. The **source cursor does not move** — under any gesture |
| Copy | `y` or `:MdViewerCopy` | Unnamed register, and the system clipboard where available. Nothing is copied automatically |
| Search | `/` or `:MdViewerFind`, then `n`/`N`, then `/` dismissed with Escape | Matches highlight, stepping wraps, dismissing the empty prompt removes them |
| Visual mode | `v`, `3j`, `y`; then `V`, `j`; then `v`, `3j`, `o`, `k` | The highlight follows; the winbar shows `-- VISUAL --` / `-- VISUAL LINE --`; `o` swaps ends; `y` copies and leaves |
| Past the viewport | `v`, then `G` | Scrolls and keeps extending to the end of the document |
| Escape precedence | `v`, motion, `<Esc>`, `<Esc>` | First leaves visual mode keeping the highlight; second clears it |
| External link | Ctrl/Cmd-click an `http(s)` link | Opens in the system browser, or says why it did not |
| Local Markdown link | Ctrl/Cmd-click a relative `.md` link | Opens or reuses a preview tab; the editable source window and focus stay unchanged |
| Tabs and history | Follow links, cycle tabs with `[b`/`]b` or `H`/`L`, close a tab, then `:MdViewerBack` | Tabs affect only the preview; history is independent and recreates the closed document |

## Selection-highlight overlay

Only where `selection_overlay` resolves on — confirm with `:MdViewerDebug`'s
`overlay` row under `-- Raw Graphics (kitty_raw) --`, which reads `on, layer …`
or `off -- <reason>`.

| Check | How | Expect |
|---|---|---|
| Instant highlight | `v`, then extend with a motion | Appears as you move, without the page visibly re-rendering |
| Three gestures in a row | `v`, extend, `y`; repeat twice more, each starting elsewhere | Every gesture behaves like the first. A terminal can draw the overlay correctly once and then silently draw it *underneath* the preview, with every placement still reporting success — one correct gesture proves nothing |
| No stale highlight | Select, `y`, start a new selection elsewhere | The first highlight is gone for the whole second gesture |
| Settled frame | `y`, or `<Esc>` to leave visual mode | The highlight becomes the browser's own paint, without visibly shifting or changing colour |

## Placement, occlusion, and lifecycle

| Check | How | Expect |
|---|---|---|
| Notification opacity | Trigger a notification over the preview | Its background stays opaque; no Markdown shows through |
| No roll or blink | Let that notification appear and disappear | The image does not jump, roll, or blink |
| Splits and chrome | Open the preview `right`, `left`, `above`, `below`, with a winbar, a statusline, and `laststatus=3` | Correct placement in each; nothing overlaps the image |
| Float | Open a focusable float over the preview, then close it | It occludes; closing restores |
| Tabpage | `:tabnew`, switch away and back | No stranded image over the other tabpage |
| Suspend | `Ctrl-z`, then `fg` | The image comes back intact |
| Repeated open/close | Open and close several times | No stray placements accumulate |
| Teardown | `:qa` | No image left on the terminal, and no Node or Chromium process still running |
