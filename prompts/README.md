# Implementation Plan — Cross-Platform Rendering and Browser-Backed Interaction

Operator guide for taking `md-viewer.nvim` from a macOS/iTerm2-only beta to a
cross-terminal plugin with VS Code-like preview interaction.

This directory is the **source of truth for what to do next**. It is committed
deliberately so that a fresh Claude Code session, a different machine, or a
different model can resume work without reconstructing intent.

> **Just want to get going?** Read [`@OperatorGuide.md`](@OperatorGuide.md). It is
> a plain-language runbook with the exact terminal commands, the exact prompts to
> paste, and the manual checks to do between parts. The rest of this file explains
> *why* the plan is shaped the way it is.

---

## The two goals, and why they are sequenced this way

The reference documents bundle two independent goals:

- **Portability** — run correctly on iTerm2, Kitty, WezTerm, Ghostty, and Warp,
  across macOS and Linux (Windows best-effort).
- **Interaction** — text selection, copy, search, and safe links over the
  rasterized preview. (Click-to-source was also built this way in Part 4,
  then replaced by click-to-deselect in an out-of-band follow-up after Part
  6 — it fought the drag-to-select gesture. See CHANGELOG.md's `[0.3.0]`
  entry.)

Portability is sequenced first because it is lower-risk, shorter, and produces a
genuinely shippable release on its own. Interaction is then built as a vertical
slice — renderer plumbing, then Neovim plumbing, then features — so that every
stopping point is coherent.

---

## Status

| # | Prompt | Objective | Plan / implement model | Status | Commit |
|---|--------|-----------|------------------------|--------|--------|
| 1 | [Foundations](part-1-foundations.md) | Terminal capability layer, cross-platform Chromium discovery, CI matrix, test harness | Sonnet 5 / Sonnet 5 | done | c638674 |
| 2 | [Portable rendering](part-2-portable-rendering.md) | De-iTerm2 the Kitty backend; profile-driven placement and geometry | Sonnet 5 / Sonnet 5 | done | 03f2381 |
| 3 | [Interaction transport](part-3-interaction-transport.md) | `interact` NDJSON method, document isolation, stale lanes, DOM hit-testing | **Opus 5** / **Opus 5** | done | dbd151f |
| 4 | [Mouse and navigation](part-4-mouse-and-navigation.md) | Gesture model, cell→CSS coordinates, click-to-source, safe links | Sonnet 5 / Sonnet 5 | done | e3139e8 |
| 5 | [Source provenance](part-5-source-provenance.md) | Exact Markdown columns, UTF-16→UTF-8 byte conversion | **Opus 5** / **Opus 5** | done | 1db9cfe |
| 6 | [Selection and search](part-6-selection-and-search.md) | DOM selection, copy, rendered-text find | Sonnet 5 / Sonnet 5 | done | c06f4bc |
| 7 | [Hardening and docs](part-7-hardening-and-docs.md) | Regression, security review, compatibility matrix, documentation | Sonnet 5 / Sonnet 5 | done | 26e637d |

### Post-Part-7 follow-ups: drag-to-highlight responsiveness

| # | Prompt | Objective | Plan / implement model | Status | Commit |
|---|--------|-----------|------------------------|--------|--------|
| f1 | [Stage 1 — fast frames](drag_highlight_stage_1_fast_frames.md) | Measure the frame budget; remove the trailing debounce | **Opus 5** / **Opus 5** | done (capture-scale half reverted by `c44e22f`) | 2bcee86 |
| f2 | [Round 2 — sharp frames](drag_highlight_round_2_sharp_frames.md) | Revert the blurry moving frame; keep selecting when a drag leaves the window | **Opus 5** / **Opus 5** | done | c44e22f |
| f3 | [Stage 2 — make a sharp frame cheap](drag_highlight_stage_2_transport.md) | Remove the compositor frame-rate cap and the PNG encode cost, pixel-for-pixel | **Opus 5** / **Opus 5** | done — 2.8x faster renderer, **no felt change** | 742d746 |
| f4 | [Stage 3 — damage band](drag_highlight_stage_3_damage_band.md) | Capture and place only the strip that changed; ~10-30x fewer pixels per frame | **Opus 5** / **Opus 5** | **shelved** — step 1's probe split the terminals: iTerm2 passed everything, so stage 4 shipped there instead; remains the candidate if WezTerm drags ever need improving | — |
| f5 | [Stage 4 — overlay the selection](drag_highlight_stage_4_overlay_selection.md) | Stop screenshotting during a drag entirely; place crops of one translucent tint sheet over the selection rects | Fable 5 / **Opus 5** | done, **iTerm2 only** (per-profile gate; WezTerm crashed the step-1 probe) — operator confirmed it is fast; rectangles are too tall, fixed in f6 | 319f37e |
| f6 | Stage 5 — size the overlay in drawn pixels | Measure the terminal's cell with `TIOCGWINSZ` and size selection rectangles against the box the base image is *drawn* into, not the one it was *captured* at | **Opus 5** / **Opus 5** | done — operator validated on iTerm2 | a80bda1, 525ff5f |
| f7 | Stage 6 — the overlay's own layer | Stop the base image and the overlay sharing a z-index; enable Ghostty and Kitty; surface the overlay's diagnostics in `:MdViewerHealth` | **Opus 5** / **Opus 5** | done — operator confirmed Ghostty and Kitty, 2026-08-08 | 43bf9e9 |
| f8 | [Stage 7 — WezTerm](drag_highlight_stage_6_wezterm_probe.md) | Support WezTerm on **both** `20240203` stable and current builds: re-probe, work around the per-cell `X`/`Y` defect if it is confirmed, and select the path automatically | Fable 5 / **Opus 5** | done — geometry solved and photographed on both builds; overlay **stays off** because placement churn grows WezTerm's memory without bound. No version boundary needed. Also fixed a cell-measurement cache bug affecting every terminal | b077334, 6b7cc6d, ae47533, 3f827f9, 53ca49e, e2efc0a |

**Release checkpoints.** Part 2 completes a shippable `v0.2.0` — genuinely
cross-terminal, with no interaction changes. Part 7 completes `v0.3.0`. Parts 3
through 6 are not individually releasable but each is independently revertible.

**Part 7 is done; `v0.3.0` is ready to tag.** All automated verification is
green (591/591 Lua assertions, 134/134 Node tests, stylua clean, including a
real security review and a real regression fix found and closed during the
pass — see `docs/cross-platform-implementation-status.md`'s "What Part 7
actually built"). What remains is exclusively the "Operator verification
(manual)" work in `prompts/part-7-hardening-and-docs.md` and
`docs/manual-testing.md`: this development environment has no graphical
terminal, so every scenario in the compatibility matrix is honestly recorded
as unvalidated pending a human actually launching md-viewer in a real
terminal and looking at it.

**Parts 5 and 6 are swappable.** Both depend only on Parts 3 and 4, and neither
depends on the other. Part 5 is placed first because it upgrades Part 4's
click precision while that code is still fresh, and because it is the riskiest
remaining work — better to hit it with budget in hand. If you would rather have
visible selection sooner, run Part 6 first; the only cost is that search reports
match positions at block precision until Part 5 lands. If you swap them, update
this table and both prompt headers.

---

## How to run a part

One part per session. Start each one clean:

```text
/clear
```

Then paste:

```text
Read prompts/00-policy.md and prompts/part-1-foundations.md, then implement Part 1.
```

Substitute the part you are on. That is the whole prompt — each part file is
self-contained and includes the verified repository facts, the file list, the
tests, the verification commands, and the commit message.

Between parts, if a session has been long or you are handing off:

```text
/clear
Read docs/cross-platform-implementation-status.md and prompts/part-N-<name>.md, then implement Part N.
```

`docs/cross-platform-implementation-status.md` is created by Part 1 and updated
by every part. It is the handoff record.

---

## Model routing

| Part | Recommendation | Reasoning |
|------|----------------|-----------|
| 1 | Sonnet 5 | Mechanical and unambiguous. Detection tables, path lists, a CI file. |
| 2 | Sonnet 5 | Bounded. The geometry math is error-prone, so the prompt demands tests before behavior changes. |
| 3 | Plan with Opus 5, implement with Opus 5 or Sonnet 5 | Concurrency, staleness lanes, and cross-document isolation are where subtle bugs hide. Get the design settled in plan mode with Opus, approve it, then write against a settled design. Run as Opus/Opus. |
| 4 | Sonnet 5 | Plumbing against a protocol that Part 3 already fixed. |
| 5 | Opus 5 throughout | Inline Markdown provenance plus UTF-16↔UTF-8 byte conversion is the hardest correctness surface in the project, and the failure mode is silent wrong cursor positions. Do not economize here. |
| 6 | Sonnet 5 | Large but patterned — it reuses Part 3's queue and the existing fast-scroll backpressure model. |
| 7 | Sonnet 5 | Includes a security review. Do not downgrade to Haiku even though much of it is documentation. |

---

## Token discipline

- **`/clear` between every part.** A completed part's context is dead weight and
  actively harmful — it invites re-litigating settled decisions.
- **The part prompt plus the status document is the complete required context.**
  Each part prompt already contains the verified repository facts it needs. Do
  not read `prompts/reference/*` unless a part prompt explicitly says to; those
  two files are 2,300 lines combined.
- **Never let an agent read `renderer/node_modules/`.**
- Plan mode is worth its cost on Parts 3 and 5 and little else.

---

## Reference documents

`prompts/reference/` holds the original planning documents, preserved verbatim:

- [`feasibility-report.md`](reference/feasibility-report.md) — architectural
  assessment. Explains the raster boundary and why browser-backed interaction is
  the right approach. Read for *why*, not *what*.
- [`full-specification.md`](reference/full-specification.md) — the complete
  requirement set. The part prompts are derived from it. Consult it only when a
  part prompt is ambiguous and you need the original wording.

`tmp/` is now git-ignored. These copies are canonical.

---

## Dogfooding

Your Neovim config pins the published tag:

```lua
-- ~/.config/nvim/lua/plugins/md-viewer.lua
"alanbanks229/md-viewer.nvim",
version = "v0.1.0-beta",
```

To exercise work in progress, point lazy.nvim at the local checkout instead:

```lua
"alanbanks229/md-viewer.nvim",
dir = "~/Documents/Github/Neovim_Plugins/md-viewer.nvim",
-- remove `version`; `dir` and `version` conflict
```

That config used to hardcode four values that existed only because the plugin
could not work them out for itself:

```lua
image.backend = "kitty_raw"                    -- capability layer should infer this
browser.executable_path = "/Applications/..."  -- discovery should find this
render.cell_aspect_ratio = 0.42                -- calibration should derive this
render.estimated_cell_width_px = 7.5           -- calibration should derive this
```

**Deleting all four and having the preview still render correctly is the real
acceptance test for Parts 1 and 2.** Automated tests cannot prove it; only a
real terminal can — and this has now been done: the operator confirmed the
preview renders correctly on both iTerm2 and WezTerm with all four lines
removed, and that macOS Terminal.app (which has no Kitty graphics protocol)
correctly falls back to text-only rendering. Kitty, Ghostty, Warp, and Linux
terminals remain untested. See `docs/cross-platform-implementation-status.md`
("Operator graphical validation") for the full results.
