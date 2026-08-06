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
- **Interaction** — click-to-source, text selection, copy, search, and safe
  links over the rasterized preview.

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
| 7 | [Hardening and docs](part-7-hardening-and-docs.md) | Regression, security review, compatibility matrix, documentation | Sonnet 5 / Sonnet 5 | not-started | — |

**Release checkpoints.** Part 2 completes a shippable `v0.2.0` — genuinely
cross-terminal, with no interaction changes. Part 7 completes `v0.3.0`. Parts 3
through 6 are not individually releasable but each is independently revertible.

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
