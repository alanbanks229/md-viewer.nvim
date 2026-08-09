# Release testing

What to check before tagging a release, how to check it, and what to expect.

## Automated versus manual

The headless suites prove the request/response plumbing, staleness handling,
sanitization, hit-test geometry, source provenance, selection and search
semantics, placement encoding, and capability resolution. They run on every
push. They cannot see a pixel.

Nobody can automate: whether the image is actually composited where it should
be, whether a highlight is visible, whether anything flickers or rolls, whether
a real mouse click lands on the thing under the pointer, or how a terminal
behaves when the plugin exits. That is what the checklist below is for.

## 1. Run the automated suite first

```sh
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
stylua --check lua/ plugin/ tests/lua/
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
```

Optionally, the end-to-end drag regression against a real browser (not in CI —
it needs a Chrome/Chromium install):

```sh
nvim --headless -u NONE -i NONE -l scripts/overlay/live/drive.lua
```

Do not start manual testing against a red tree. Every failure you find by hand
needs to be attributable to the terminal, not to a known-broken build.

## 2. Which terminals to sanity-check

| Terminal | Status | Evidence |
|---|---|---|
| iTerm2 3.5+ | `Supported` for image rendering and the drag-highlight overlay | Operator-driven, 2026-08-07. The rest of the feature set is `Protocol-compatible but unvalidated`. |
| Kitty | `Supported` for the drag-highlight overlay | Operator-driven, 2026-08-08, across repeated drags. |
| Ghostty 1.3.1 | `Supported` for the drag-highlight overlay | Operator-driven, 2026-08-08, across repeated drags. |
| WezTerm | `Supported` for image rendering; overlay deliberately **off** | See "WezTerm" below. |
| Warp | `Protocol-compatible but unvalidated` | Never launched. Its Kitty-graphics support is newer than the others'; if it fails outright, record what broke. |

At minimum, sanity-check **one** terminal from the `Supported` set. Check
whichever others you have.

macOS Terminal.app is deliberately absent: it does not implement the Kitty
graphics protocol, there is no profile for it, and `image.backend = "auto"`
correctly degrades to the `cells` text-only fallback.

Setup for every manual run: open `tests/fixtures/kitchen-sink.md` (or
`tests/fixtures/provenance-comprehensive.md` for the multibyte and emoji cases)
with `image.backend = "kitty_raw"` set **explicitly**, outside tmux/screen/
Zellij, and record the terminal name and version, OS, `TERM`/`TERM_PROGRAM`,
Neovim version, and whether HiDPI scaling is active. A result with no
environment recorded is not usable evidence.

## 3. Pre-release checklist

Attach a screenshot for anything visual. For alignment and bleed-through, a
screenshot is the *only* acceptable evidence — the protocol specification will
not tell you (see §5).

### Rendering and sync

| Check | How | Expect |
|---|---|---|
| Image renders | `:MdViewerOpen` | A rendered page filling the split, at the right size and position, with no hand-tuned `render.*` config. |
| Live preview | Edit the buffer without `:w` | The preview follows within the debounce interval. |
| Cursor follow | Move the cursor through the source | The preview scrolls to match. |
| Scrolling | `j`/`k`, `Ctrl-d`/`u`, `Ctrl-f`/`b`, `gg`/`G`, mouse wheel over the preview | Smooth movement, no flicker, no stray image left behind. Wheel does nothing when the pointer is outside the preview. |
| Resize and font size | Resize the window, then change the terminal's font size | The image re-renders at the new geometry and stays aligned. |

### Interaction

| Check | How | Expect |
|---|---|---|
| Drag-to-select | Drag across a paragraph, forwards and backwards | Text highlights as you move, in both directions. |
| Multi-paragraph | Drag across a block boundary | The selection spans both. |
| Word / paragraph | Double-click; triple-click | The word, then the enclosing block. |
| Click-to-deselect | Click once with a selection active | The highlight clears. The **source cursor does not move** — under any gesture. |
| Copy | `y` or `:MdViewerCopy` | Unnamed register, and the system clipboard where available. Nothing is copied automatically. |
| Search | `/` or `:MdViewerFind`, then `n`/`N`, then `:MdViewerFindClear` | Matches highlight, stepping wraps, clearing removes them. |
| Multibyte columns | Ctrl/Cmd-click on `café`, `日本語`, an emoji, in `provenance-comprehensive.md` | `:MdViewerDebug` reports an exact byte column that lands inside the line it names. |

### Links and history

| Check | How | Expect |
|---|---|---|
| External link | Ctrl/Cmd-click an `http(s)` link | Opens in the system browser, or says why it did not. |
| Local Markdown link | Ctrl/Cmd-click a relative `.md` link | Opens in Neovim in the source window; the preview follows. |
| Repo-relative link | Follow `../README.md` from a document in a subdirectory | Resolves. It is not refused as outside the document root. |
| Missing target | Ctrl/Cmd-click a link to a nonexistent file | Reports *does not exist* — not *outside the document root*. |
| Small target | Ctrl/Cmd-click a one-word link at the start of a line, at the terminal's default font size | Activates. This is the case that used to be unreachable at some cell alignments. |
| History | `H` / `:MdViewerBack`, then `L` / `:MdViewerForward`, then `<C-o>` | Preview and source window move together; `<C-o>` brings the preview back on its own. |

### Drag-highlight overlay

Only on a terminal where `selection_overlay` resolves on — confirm with
`:MdViewerHealth verbose` (`raw graphics overlay supported`).

| Check | How | Expect |
|---|---|---|
| Instant highlight | Drag a selection | The highlight appears as you move, without the whole page visibly re-rendering. |
| **Drag three times** | Release, drag elsewhere, release, drag again | Every drag behaves like the first. |
| No stale highlight | Select text, release, then drag a new selection elsewhere | The first highlight is gone for the whole second drag. |
| Settled frame | Release the mouse | The highlight becomes the browser's own paint. It should not visibly shift or change colour. |

The third and fourth rows exist because of real defects. On Ghostty the overlay
worked once per session and then silently drew *underneath* the preview — every
placement still reported success. One correct drag proves nothing.

### Placement and occlusion

| Check | How | Expect |
|---|---|---|
| Notification opacity | Trigger a notification over the preview | Its background stays opaque. No Markdown shows through it. |
| No roll or blink | Let that notification appear and disappear | The image does not jump, roll, or blink. |
| Splits | Open the preview `right`, `left`, `above`, `below` | Correct placement in each. |
| Chrome | With a winbar, a statusline, and `laststatus=3` | None of them overlaps the image. |
| Float | Open a focusable floating window over the preview, then close it | It occludes; closing restores. |
| Tabpage | `:tabnew`, switch away and back | No stranded image over the other tabpage. |

### Lifecycle

| Check | How | Expect |
|---|---|---|
| Suspend | `Ctrl-z`, then `fg` | The image comes back intact. |
| Repeated open/close | Open and close the preview several times | No stray placements accumulate. |
| Teardown | `:qa` | No image left on the terminal, and no Node or Chromium process left running. |

## 4. WezTerm

The drag-highlight overlay is **off on WezTerm**, on cost grounds rather than
correctness.

Its geometry is solved. WezTerm applies the Kitty protocol's `X`/`Y` sub-cell
offset to *every* cell of a placement rather than only the first, and applies it
as an inset, so a multi-cell highlight bar draws as a comb of stripes. md-viewer
sends WezTerm no `X`/`Y` keys at all and expresses the offset inside the tint
sheet instead (`overlay_encoding = "sheet-margin"`); that was photographed as one
solid bar on both `20240203-110809-5046fc22` and `20260805-104032-4b1c3c15`, 42
of 42 pixel assertions each.

What is not solved is the cost. Sustained placement traffic grows WezTerm's
resident memory without bound — 172 MB to 786 MB in four seconds with four
rectangles at 40 fps. The cause is upstream: `assign_image_to_cells` writes a
cell that already carries its image attachments back through a merging
`set_cell`, duplicating the attachment list on every repeat placement, and the
renderer emits a quad per attachment. Reported as
[wezterm/wezterm#7953][wez-issue]; a fix is proposed in
[wezterm/wezterm#8035][wez-pr].

Until that fix ships in a released build, WezTerm drags keep the full-frame
capture path, which is correct and merely slower. **Do not set
`interaction.selection_overlay = "on"` on WezTerm** — it will draw correctly and
exhaust your memory.

To re-open the decision once a fixed build exists, run both harnesses against it
and flip `selection_overlay` in `lua/md-viewer/terminal.lua`'s WezTerm profile
only if both pass:

```sh
scripts/overlay/geometry/run.sh /path/to/WezTerm.app
scripts/overlay/stress/run.sh   /path/to/WezTerm.app
```

See [scripts/README.md](../scripts/README.md). Upstream issue #6344's
divide-by-zero panics are unreachable from md-viewer regardless: a cell must
floor to at least one pixel and every crop must be at least one pixel and wholly
inside its image before anything is emitted.

[wez-issue]: https://github.com/wezterm/wezterm/issues/7953
[wez-pr]: https://github.com/wezterm/wezterm/pull/8035

## 5. Per-terminal sub-cell calibration

On real iTerm2 hardware the raw image lands about half a cell left and up of the
text grid: iTerm2 applies its window margin to text but not to graphics
placements. `image.raw_cell_offset_px` and `image.raw_overlay_bleed_cells` exist
because of that one measurement. Whether any other terminal has the same quirk
is **unknown**, and it cannot be inferred from the protocol specification — the
whole reason the iTerm2 bug was found so late is that the spec gave no reason to
expect it.

Two questions, per terminal:

1. **Does it implement the `X`/`Y` placement keys at all?** Set
   `image.raw_cell_offset_px = { x = 10 }`, open a notification over the
   preview, and look. If the image visibly shifts, it does — record the offset
   that closes the gap. If nothing changes, record `X`/`Y` as unimplemented
   there and rely on `raw_overlay_bleed_cells` alone (on by default for exactly
   this reason).
2. **Is the offset a fixed window margin, or does it scale with cell width?**
   Change the terminal's font size once and re-measure.

The measurement is a screenshot, not a calculation: compare the x coordinate of
the image's edge against the x coordinate of the notification's edge.

| Terminal | Implements `X`/`Y`? | Measured offset | Constant or scales? |
|---|---|---|---|
| iTerm2 | Yes | ~10px of a 20px cell, horizontal; vertical measured exact | Undetermined — one measurement only |
| WezTerm | Yes, but inset per cell rather than on the first cell only (see §4) | None needed; content and graphics origins coincide, so `raw_cell_offset_px` stays 0 | n/a |
| Kitty | Unmeasured | — | — |
| Ghostty | Unmeasured | — | — |
| Warp | Unmeasured | — | — |

**Open question.** `raw_cell_offset_px` ships as pixels because iTerm2 measured
at exactly half a cell, which cannot distinguish a constant-10px theory from a
half-a-cell theory, and there is no second data point. If a second terminal (or
iTerm2 across two font sizes) shows the offset scaling with cell width, the
option is the wrong shape and should express a fraction of a cell instead.
Settle that before adding another terminal's calibration numbers; changing the
option's shape afterwards would be a breaking config change.

## 6. Multiplexers

tmux, screen, and Zellij are **not supported and not advertised**. No Kitty
graphics passthrough is implemented for any of them. `terminal.lua` detects a
multiplexer and reports it in `:MdViewerHealth`'s `multiplexer` field so a user
inside one gets an honest diagnosis rather than a silent failure, and that is
the entire extent of the work. Do not add a `Supported` row for a multiplexer
without first implementing and testing passthrough.

## 7. Recording a result

Every status uses exactly one of these four labels. Do not invent others, and do
not soften them.

| Label | Meaning |
|---|---|
| `Supported` | Actually launched and looked at, on real hardware, by a human. A screenshot or recording exists. |
| `Experimental` | Launched and looked at, but with known gaps — a sub-case was not tried, or it was tried once and not thoroughly. |
| `Protocol-compatible but unvalidated` | The terminal advertises Kitty-graphics support and has a profile (or matches the generic Kitty one), but nobody has launched md-viewer in it and looked. This is a perfectly good, honest release state. |
| `Unsupported` | Known not to work — it does not implement what is needed, or someone tried and it visibly failed. |

**Never mark something `Supported` on the strength of an environment variable
matching, a protocol capability being technically compatible, or a headless test
passing.** Detection evidence is not validation. Only what a human watched
happen on a real screen earns `Supported`.

This matters more than it looks. Three graphical bugs this project has shipped
and fixed — the placement roll, the notification bleed-through, and the sub-cell
misalignment — were each invisible to every headless test that existed at the
time, and were found only because someone was looking at a real screen.
