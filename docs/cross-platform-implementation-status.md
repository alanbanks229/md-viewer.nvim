# Cross-Platform Implementation Status

This document is the handoff record for `prompts/`. It is created by Part 1 and
updated by every subsequent part. It records what is actually true of the
repository right now, not what was planned.

---

## Completed parts

| # | Part | Commit |
|---|------|--------|
| 1 | Foundations — capability layer, browser discovery, CI, test harness | `0d62c1f` (initial), `b2ceaf9` (post-commit `:MdViewerHealth` crash fix — see below) |
| 2 | Portable rendering — generic Kitty backend, profile-driven placement, calibration tiers | `03f2381` |
| 3 | Interaction transport — `interact` method, document isolation, staleness lanes, DOM hit-testing | `dbd151f` |
| 4 | Mouse layer, click-to-source (later removed — see Part 7), safe links | `e3139e8` |
| 5 | Exact source provenance — inline mapping, byte-accurate columns | `1db9cfe` |
| 6 | Selection and search — DOM selection, copy, rendered-text find | `c06f4bc` |
| 7 | Hardening and docs — regression, security review, lifecycle coverage, expanded diagnostics, honest compatibility matrix, full documentation pass | `26e637d` |

Parts 1–2 were merged to `main` via PR #1. Parts 3–7, seven post-Part-6
follow-up fixes, and one out-of-band UX change (click-to-source removal) are
on the branch `feat/interaction-transport`, cut from `main`, and have not
been pushed as of Part 7's completion.

---

## What Part 1 actually built

### Test harness restructure

`tests/lua/run.lua` was a single 285-line linear script. It is now a loader:
it globs `tests/lua/cases/*.lua`, sorts filenames, `dofile`s each one to get a
function, and calls it with the shared harness table. Each case file is
self-contained — it builds whatever buffers/windows/config it needs and cleans
up after itself — rather than relying on local variables from a previous case
file. This matters because module-level singleton state (config, mouse,
process) *does* persist across case files in the same `nvim --headless`
process, but Lua locals do not, and the split had to not silently depend on
run order beyond what module singletons already impose.

Case files, in the sorted order they actually run:
`backends`, `config`, `controller`, `coordinates`, `debounce`, `navigation`,
`process`, `protocol`, `renderer`, `state`, `sync`, `terminal`.

`controller.lua` carries the large integration scenario (session lifecycle,
loading indicator, occlusion, passive-overlay cutouts, mouse wheel dispatch,
scroll backpressure, navigation actions, hide/pinned persistence, close and
reopen) essentially unchanged from the original script — splitting it further
across "controller" and "navigation" files would have required either passing
hidden state between files or duplicating the entire session setup for no
safety benefit. `navigation.lua` instead holds a small, fully independent test
of keymap registration with its own session.

`harness.lua` gained `t.near(expected, actual, tolerance, label)` for Part 2's
geometry work. No existing assertion was dropped — the suite still reports
**124 assertions passed** (up from the original count because of new
`terminal` and config-default assertions).

### Terminal capability module

`lua/md-viewer/terminal.lua` is new. It exposes:

- `M.profiles` — static metadata for `iterm2`, `kitty`, `wezterm`, `ghostty`,
  `warp`, `generic_kitty`, `unknown` (default z-index, placement assumptions,
  validation string, caveats).
- `M.match_profile(env)` — pure environment → profile-id inference, evidence
  is the literal `VAR=value` string that matched. Injectable `env` table for
  tests; defaults to `vim.fn.environ()`.
- `M.multiplexer(env)` — detects `tmux`/`zellij`/`screen` from `TMUX`/
  `ZELLIJ`/`STY`.
- `M.platform()` — `macos`/`linux`/`windows` from `vim.uv.os_uname()`.
- `M.capability(cfg, env)` — the full resolution: explicit
  `terminal.kitty_graphics` on/off pins `graphics` outright; otherwise an
  explicit `terminal.profile` picks the profile deterministically; otherwise
  environment evidence infers a profile. `graphics` is `"explicit"`,
  `"inferred"`, or `"unavailable"` — **never `"verified"`**. `"verified"` is
  reserved for `vim.ui.img`, which this module does not decide.
- `M.detect()` — convenience wrapper reading live `config.get().terminal`.

No synchronous protocol probe is implemented. `terminal.probe` stays `"off"`
in the defaults; the resolution-order comment in the module explains why
(Neovim owns terminal input, so a probe would race user keystrokes).

### Backend selection rewired

`lua/md-viewer/backends/kitty_raw.lua` `M.detect()` no longer hardcodes
`false` on every path. It checks the two hard structural requirements
(`nvim_ui_send` exists, a TUI is attached), then consults
`terminal.detect()`. If `graphics == "unavailable"` it fails with a reason
naming the profile and why; otherwise it succeeds and reports the confidence
level (`explicit`/`inferred`) and the evidence in its reason string.
`M.health()` now also reports `profile`, `evidence`, `graphics_confidence`,
`decision_reason`, `platform`, `multiplexer`, `validation`.

`lua/md-viewer/backends/init.lua` `M.select("auto")` no longer matches on the
string `"active response probe"`. It tries `nvim_img` (verified), then
`kitty_raw` (explicit/inferred), then falls back to `cells`. Explicitly
requesting any backend (`image.backend = "kitty_raw"` etc.) still works via
the same `detect()` used by auto-selection — the previous unconditional
escape hatch is gone; forcing `kitty_raw` on a terminal with zero evidence and
no explicit `terminal.kitty_graphics = "on"` override now correctly fails
instead of always succeeding. This is an intentional behavior change: the old
hatch let forced Raw-Kitty "succeed" on any terminal, honesty be damned. The
new one requires either real evidence or an explicit user override.

### Configuration

`lua/md-viewer/config.lua` gained a `terminal` section:

```lua
terminal = {
  profile = "auto",         -- or an explicit profile id
  kitty_graphics = "auto",  -- "auto" | "on" | "off"
  probe = "off",            -- "off" | "safe" (unimplemented; see terminal.lua)
}
```

`validate()` rejects unknown profile ids, non-tri-state `kitty_graphics`
values, and unknown `probe` modes with `assert()`-style actionable messages,
matching the existing convention.

**Known pre-existing quirk, not introduced by Part 1 and not fixed here:**
`config.setup()` reassigns the module-level `current` table *before* calling
`validate(current)`. If validation fails, `current` is left holding the
invalid merged config rather than the last-known-good one. This affects every
section, not just `terminal`. The new terminal-validation tests work around it
by calling `config.reset()` after each expected-failure case. Worth fixing in
a later part if it ever causes a real symptom; flagging it here so it isn't
mistaken for a new bug.

### Cross-platform Chromium discovery

`renderer/src/browser-discovery.js` is new and pure: `discoverChromium(
platform, env, exists, options)` takes an injected platform string, an
environment object, a file-existence predicate, and options
(`executable_path`), and either returns `{ executable, reason }` or throws an
`Error` naming every location it searched. It never shells out, never touches
the real filesystem in tests, and never invokes `playwright install`.

- **Explicit `executable_path`** always wins; a configured-but-missing path
  throws `configured Chromium does not exist: <path>` (unchanged message, now
  centralized).
- **macOS** — the three original hardcoded app paths, then Homebrew
  (`/opt/homebrew/bin`, `/usr/local/bin` × `google-chrome`/`chromium`/
  `microsoft-edge`), then `~/Applications/<App>.app/...` equivalents.
- **Linux** — `PATH` search for `google-chrome`, `google-chrome-stable`,
  `chromium`, `chromium-browser`, `microsoft-edge`, `microsoft-edge-stable`;
  then `/usr/bin`, `/usr/local/bin`, `/snap/bin`; then Flatpak system exports
  and per-user Flatpak exports under `$HOME/.local/share/flatpak/...`.
- **Windows (best-effort, not advertised as supported)** — `PATH` search
  honoring `PATHEXT`, using `path.win32` semantics throughout; then
  `PROGRAMFILES`/`PROGRAMFILES(X86)` and `LOCALAPPDATA` Chrome/Edge
  directories.

`renderer/src/browser.js` `resolveExecutable()` now delegates entirely to
`discoverChromium(process.platform, process.env, fs.existsSync, options)` and
stores the discovery reason on the instance; `health()` surfaces it as
`discoveryReason`. The old hardcoded three-path `knownChromium` list and the
`ensure()`-side "no approved Chrome or Chromium executable found" fallback
(now unreachable — `resolveExecutable` always returns a path or throws) were
removed.

Two existing Node integration tests (`tests/node/browser.test.js`,
`tests/node/renderer-process.test.js`) previously hardcoded the macOS Chrome
path directly in test parameters, which would have failed outright on Linux
CI regardless of what the plugin itself could discover. Both now call
`discoverChromium(process.platform, process.env, fs.existsSync, {})` at the
top of the test and `t.skip(...)` with a named reason if nothing is found,
rather than hardcoding a path or silently weakening the assertions. On this
development machine (macOS, Google Chrome installed) both still run and pass.

### CI matrix

`.github/workflows/ci.yml` now runs a `strategy.matrix` of `macos-latest` and
`ubuntu-latest` with `fail-fast: false`. Linux gets a Neovim install via the
`neovim-ppa/unstable` PPA (Ubuntu's default repo Neovim is far too old for
this plugin's `nvim-0.12+` requirement) and stylua via the published
`stylua-linux-x86_64.zip` release asset (no cargo build, no `playwright
install`, no browser download). Both platforms run a new `stylua --check`
step before the test steps.

**This CI change is unvalidated** — I have not triggered an Actions run. I
have reasoned from GitHub-hosted runner images documented to include Google
Chrome/Chromium/Edge on both `macos-latest` and `ubuntu-latest`, and from the
`browser.test.js`/`renderer-process.test.js` skip-on-not-found behavior above
as a safety net if that assumption is wrong for a given runner image
snapshot. Per policy §4, I am not claiming this is confirmed — only that it
is implemented and locally self-consistent.

### stylua

`stylua.toml` existed but had never been run — `stylua --check` on the
pre-Part-1 tree failed on 27 of ~30 Lua files (missing `collapse_simple_statement
= "Always"`, which is the only config gap; the codebase's actual style is
dense single-line `if`/`for`/function bodies that stock stylua defaults would
otherwise expand). Since adding `stylua --check` to CI as instructed by this
part would otherwise make every future PR red on day one, `stylua.toml` was
updated (`collapse_simple_statement = "Always"` added) and `stylua lua/
plugin/ tests/lua/` was run once, in write mode, across the whole tree. This
is a mechanical, whitespace-only pass — semantics are unchanged, and both the
Lua and Node suites were re-run afterward to confirm (124/124 and 24/24
respectively). `plugin/md-viewer.lua` was already compliant and picked up no
changes. `lua/md-viewer/feasibility.lua`, an unreferenced file not part of the
runtime plugin, was reformatted along with everything else since it lives
under `lua/` and stylua's glob does not distinguish it; this is harmless
(whitespace only) and out of scope to investigate further in this part.

### Diagnostics

`lua/md-viewer/health.lua` `M.collect()` now reports (new fields):
`platform`, `multiplexer`, `terminal_profile` (id + label),
`terminal_profile_evidence`, `graphics_confidence`, `graphics_decision_reason`,
`graphics_validation`, `graphics_caveats`, `chromium_discovery` (whether the
executable path shown was confirmed by the renderer subprocess's real
cross-platform discovery, or is a synchronous local estimate used only before
`:MdViewerHealth` has queried the renderer once). `:checkhealth md-viewer`
(`M.check()`) prints the same profile/evidence/confidence/caveats, and now
marks Kitty graphics `ok` for `explicit`/`inferred` confidence and `warn` for
`unavailable` rather than an unconditional pass/fail on `TERM_PROGRAM`
string-matching.

`lua/md-viewer/debug.lua` `M.snapshot()` gained a top-level `terminal` key
(`terminal.detect()`) alongside the existing `backends.health()` (which
itself now carries the same capability fields via `kitty_raw.health()`).

The old `chrome_path()` helper in `health.lua` (three hardcoded macOS paths)
is renamed `chrome_path_estimate()` and documented as a **synchronous,
best-effort fallback only** — `:MdViewerHealth` prefers the actual
cross-platform result returned by the renderer subprocess
(`renderer_result.executable`, populated via `discoverChromium` in
`browser.js`) and only falls back to the local estimate when the renderer
hasn't been queried yet. The local estimate itself was broadened modestly
(Homebrew paths, a few common Linux paths, `vim.fn.exepath()` for PATH
lookups) so it isn't actively misleading on Linux, but it does not attempt to
replicate the full Node-side search (Flatpak, Windows, `~/Applications`) —
that would duplicate `browser-discovery.js` in Lua for a fallback path that's
rarely hit.

### Post-commit fix: `:MdViewerHealth` crashed in a real session

The initial Part 1 commit (`0d62c1f`) reported all automated checks passing,
but the operator hit a real crash running `:MdViewerHealth` interactively:

```
'replacement string' item contains newlines
  at health.lua:162 nvim_buf_set_lines
```

Root cause: `lines()` called `vim.inspect(value)` on any table-valued report
field, and `vim.inspect` produces multi-line output by default for anything
non-trivial (`graphics_caveats`, `renderer_process`). That multi-line string
was then embedded in a single formatted line and handed to
`nvim_buf_set_lines`, which rejects any item containing `\n`.

**This is a real gap in Part 1's own testing, not just an edge case.** My
smoke test called `health.check()` (the `:checkhealth` path, which uses
`vim.health.*` and never touches `nvim_buf_set_lines`) and never actually
invoked `health.show()` — the literal `:MdViewerHealth` code path — end to
end. The Lua unit suite had no coverage of `health.lua` at all before this.
Both gaps are now closed:

- `lines()` (`lua/md-viewer/health.lua`) special-cases `graphics_caveats` to
  render as its own indented lines, and collapses any other table value with
  `vim.inspect(value, { newline = " ", indent = "" })` instead of the
  multi-line default.
- `tests/lua/cases/health.lua` is new: it calls `health.show()` for real
  (forcing a multiplexer env var so the multi-entry-caveats branch is
  actually exercised), asserts no buffer line contains `\n`, and asserts the
  multiplexer caveat renders as a separate indented line. Verified this test
  actually fails against the buggy code (reverted it locally, confirmed the
  same crash reproduces and the assertions fail) before confirming it passes
  against the fix.

Fixed in a follow-up commit (see table above) on the same branch. 128/128 Lua
assertions and 24/24 Node tests pass after the fix; `stylua --check` is
clean.

---

## Tests run and results (Part 1)

```
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
  -> added 30 packages, 0 vulnerabilities

NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
  -> md-viewer Lua tests: 128 assertions passed (124 at the initial commit,
     +4 from tests/lua/cases/health.lua added in the post-commit crash fix)

npm test --prefix renderer   (node --test ../tests/node/*.test.js)
  -> tests 24, pass 24, fail 0

stylua --check lua/ plugin/ tests/lua/
  -> clean (no diff)
```

All four commands were run on this development machine (macOS, Apple
Silicon, Neovim 0.12.4, Node 24, Google Chrome installed at the standard
`/Applications` path). The Ubuntu leg of the new CI matrix has not been
executed anywhere — see the CI section above.

A manual headless smoke test (`nvim --headless` with `require("md-viewer").setup(...)`,
`health.check()`, and `terminal.detect()` called directly) ran without error.
This machine's actual shell reports `TERM_PROGRAM=vscode`, which is not one of
the seven modeled profiles, so `terminal.detect()` correctly resolved to
`unknown`/`graphics = "unavailable"` in that smoke test — this is the honest,
expected result for this terminal, not a bug.

---

## Known limitations and unresolved risks (Part 1)

- **No graphical validation was performed for any real terminal** — not
  iTerm2, not Kitty, not WezTerm, not Ghostty, not Warp. Only the synthetic-
  environment Lua unit tests in `tests/lua/cases/terminal.lua` exercise the
  profile-matching logic per terminal. Per policy §4, this must not be
  reported as validated. The dogfooding config referenced in
  `prompts/README.md` (`image.backend = "kitty_raw"` and
  `browser.executable_path` hardcoded) has not yet been changed to test
  auto-inference in a real terminal — that is the actual acceptance test for
  Parts 1 and 2 together and should happen once Part 2 lands.
- **The CI matrix change is unvalidated** (see above).
- **The pre-existing `config.setup()` reassign-before-validate quirk** is
  unfixed (see Configuration section above).
- **`terminal.probe = "safe"` is not implemented.** The config value is
  accepted and validated but nothing currently branches on it; `M.capability`
  does not consult it at all. This matches the part prompt's explicit
  permission to leave it unimplemented rather than ship something
  unconfident, but a later part (or a follow-up to Part 1) should either
  implement it or remove the dead config surface.
- **Windows discovery is implemented and unit-tested but not advertised as
  supported**, per the part prompt's explicit instruction. Nothing in the
  plugin currently blocks a Windows user from trying it; it simply has zero
  real-world validation.
- **The `chrome_path_estimate()` synchronous fallback in `health.lua` can
  disagree with the renderer's actual discovery** in the (expected) window
  before `:MdViewerHealth` has been run once. It's clearly labeled as an
  estimate in the `chromium_discovery` field.

---

## Decisions that changed assumptions in the original specification (Part 1)

- **Explicitly forcing `image.backend = "kitty_raw"` can now fail.** The
  original behavior (any explicit `kitty_raw` request always "succeeded" via
  the string-match hatch) was exactly the fragile mechanism this part was
  asked to replace. The prompt's own acceptance criteria ("the
  `reason:match("active response probe")` hatch is gone") make this the
  intended outcome, but it is a real behavior change worth flagging loudly:
  a user with `image.backend = "kitty_raw"` set and a genuinely unknown
  terminal will now see an error where they previously saw (unverified)
  success. The fix, if they hit it, is `terminal.kitty_graphics = "on"`.
- **`stylua.toml` needed a config addition (`collapse_simple_statement =
  "Always"`), and the whole tree needed one mechanical reformat pass** to
  make the newly-required `stylua --check` CI step meaningful rather than
  permanently red. This was not anticipated by the part prompt's "verified
  repository facts" section, which didn't mention that `stylua.toml` being
  "unused" meant the codebase was never actually compliant with it. No
  behavior changed; only whitespace. See the stylua section above for the
  file list.
- **Two existing Node integration tests hardcoded a macOS-only Chrome path**
  (`tests/node/browser.test.js`, `tests/node/renderer-process.test.js`). This
  wasn't mentioned in the prompt's verified-facts section either, but it
  directly contradicts the CI matrix goal — a test with a hardcoded macOS
  path cannot pass on `ubuntu-latest` regardless of how good cross-platform
  discovery is. Both were switched to use `discoverChromium` at runtime with
  an explicit named skip if nothing is found, per policy §1.6's instruction
  for exactly this situation.

No part boundaries moved. No downstream prompt (`part-2` through `part-7`)
needed edits — nothing discovered here invalidates their stated approach.
Part 2 should note that `terminal.lua`'s `M.capability()` return shape
(`profile_id`, `graphics`, `evidence`, `platform`, `multiplexer`, `placement`,
`default_raw_zindex`, `validation`, `caveats`) is now the stable contract for
profile-driven placement/geometry work.

---

## Safe stopping point after Part 1 (historical)

The tree is green: all four policy §5 commands pass (128/128 Lua assertions,
24/24 Node tests, stylua clean), and `:MdViewerHealth` has now actually been
exercised end-to-end in a real headless session, not just its automated-test
proxy. Two commits make up Part 1: `0d62c1f` (the original implementation)
and `b2ceaf9` (a same-day fix for the `:MdViewerHealth` crash the operator
found by actually running the command — see "Post-commit fix" above). Both
are on `feat/cross-platform-markdown-preview`; neither has been pushed.

**Lesson for future parts' testing, not just this document:** "all automated
tests pass" is not the same claim as "the actual user-facing command was
run." Before reporting a part done, run every new or changed `:MdViewer*`
command interactively in a real headless session (or ask the operator to),
not just its underlying library function.

---

## What Part 2 actually built

### Profile-driven z-index and double-buffer resolution

`lua/md-viewer/backends/kitty_raw.lua` no longer reads `image.raw_zindex`
directly as a value that's always a number. `config.lua`'s defaults for
`image.raw_zindex` and `image.double_buffer` changed from hardcoded values
(`-1`, `true`) to `nil` — a sentinel meaning "the terminal profile decides."
Two new local functions, `resolve_zindex()` and `resolve_double_buffer()`,
implement the resolution order the part asked for: an explicit, non-nil
`image.raw_zindex`/`image.double_buffer` in user config always wins; otherwise
the active profile's `default_raw_zindex`/`default_double_buffer` (from
`terminal.lua`, consulted via `terminal.detect()`) supplies the value. Both
functions return the resolved value **and** a human-readable source string
(`"explicit override (image.raw_zindex)"` or `"profile default (kitty)"`),
and both are exercised end-to-end (not just at the config layer) by
`tests/lua/cases/backend_kitty.lua`, which asserts the literal `z=<value>`
encoded into the placement escape sequence for negative, zero, and positive
explicit overrides, plus profile-default and override-beats-profile cases.

`terminal.lua`'s `M.profiles` table gained `default_double_buffer = true` on
every profile (including `unknown`, though it's unreachable there since
`unknown`'s `placement.deletion = "unsupported"` already fails `M.detect()`
before any image is shown). This value is uniform across every profile today
— see "Decisions" below for why no profile was given a different default.

`kitty_raw.lua`'s `M.health()` now reports `zindex`, `zindex_source`,
`double_buffer`, `double_buffer_source` (in addition to the existing
`owned_images`/`owned_placements`/`profile`/`evidence`/etc.), and its
`advertised` field no longer hardcodes `vim.env.TERM_PROGRAM == "iTerm.app"`
(the last iTerm2-specific check named in the part prompt) — it's now
`capability.graphics ~= "unavailable"`, true for any profile with graphics
support, not just iTerm2's own advertisement string.

### Cell-metric calibration: two real tiers, not three

`lua/md-viewer/coordinates.lua` gained `M.calibration_tier()`, a pure
function with no window argument, returning `"env"` when both
`MD_VIEWER_CELL_WIDTH_PX`/`MD_VIEWER_CELL_HEIGHT_PX` are set to positive
numbers, else `"estimated"`. `M.viewport()` now reports this as a `tier`
string field instead of the old `calibrated` boolean, propagated unchanged
through `renderer.request()`'s round-trip (`params.viewport` is echoed back
verbatim as `result.viewport` — the Node renderer only reads `widthPx`/
`heightPx`/`deviceScaleFactor` from it, never `tier`/`calibrated`, so no
Node-side change was needed) into `session.viewport_calibration_tier`
(`controller.lua`), `debug.lua`'s per-session snapshot, and
`health.lua`'s `viewport_calibration_tier` (computed directly via
`coordinates.calibration_tier()` rather than health.lua's own copy of the
env-var check it had before).

**A third "measured" tier — deriving real cell-pixel dimensions from the
terminal itself, with zero configuration — was investigated and is not
implemented, because it is not currently possible.** This is the most
important finding of this part and is worth stating precisely: Neovim's
`TermResponse` autocmd (confirmed via `$VIMRUNTIME/doc/autocmd.txt` in this
session's Neovim 0.12.4) fires **only** for DA1, OSC, DCS, or APC terminal
responses. The escape sequences that would answer "how many pixels is one
cell" — XTWINOPS `CSI 14 t` (text area size in pixels) and `CSI 18 t` (text
area size in characters) — are plain CSI responses, a category `TermResponse`
does not expose, confirmed by reading Neovim's own documented event scope
rather than by trial and error against a live terminal. `nvim_list_uis()`
was also checked (via `:help nvim_list_uis()`) and returns only `height`/
`width` in **cells**, `rgb`, and `ext_...` flags — no pixel geometry, for any
UI type. There is no `vim.g.*` or `vim.o.*` value that carries a
GUI-independent real cell-pixel size either. Per policy §4 ("do not invent a
measurement that is not real"), this part implements exactly the two tiers
that are honestly reachable — `env` (user-supplied, exact) and `estimated`
(configured aspect ratio and width guess) — and documents this investigation
directly in `coordinates.lua`'s `M.calibration_tier()` doc comment so a
future Neovim version that exposes real pixel geometry has a named place to
add `"measured"` ahead of `"env"`. This does not move any part boundary:
Part 4's mouse-coordinate inversion (cell → CSS pixels → back to cells) works
identically regardless of which of the two tiers supplied the original
conversion.

One practical consequence, reasoned through rather than reduced to a code
change: because Kitty placements specify width/height in **cells** (`c=`/`r=`
in `kitty_raw.lua`'s `place_regions()`), the terminal always stretches the
rendered PNG to exactly fill the placement regardless of the PNG's actual
pixel dimensions. `estimated_cell_width_px` therefore only affects overall
render resolution (a bigger number is a crisper, slower capture), not
correctness; only `cell_aspect_ratio` affects visual correctness, by
controlling whether rendered content is horizontally squished or vertically
stretched relative to the terminal's real cell shape. This is why the
"estimated" tier's *default* values (not hand-tuned per terminal) are a
reasonable universal fallback rather than a guess that only happens to work
on one profile — the operator's hand-tuned `0.42` and the shipped default
`0.5` are close enough that the visual difference should be minor, though
this has not been graphically confirmed (see Known limitations).

### Alt-screen and focus-regain placement recreation

`controller.lua`'s `WinEnter`/`BufEnter`/`TabEnter`/`VimResume` autocmd
(already responsible for recreating a cleared raw-Kitty placement from the
cached PNG via `show_cached()`) now also fires on `FocusGained`. Neovim has
no direct event for "the outer terminal returned from an alternate screen"
or "a multiplexer pane/window regained focus" — both can silently drop a
Kitty placement depending on the terminal — so `FocusGained` is the closest
generic, real Neovim event that correlates with those transitions, and it
reuses the exact same reconciliation path already covered by
`tests/lua/cases/controller.lua`'s float-occlusion-restore assertions.
Resize-triggered redraw, tab-switch recreation, and font-size-change handling
(all listed in the part prompt's placement-lifecycle checklist) required no
new code: `WinResized`/`VimResized` already schedules a full re-render and
`reconcile_placement()` always does a full delete-then-place via
`kitty_raw.M.move()` (there is no incremental placement patch in the Kitty
protocol as used here), so any geometry change — including a font-size
change, which changes `vim.o.columns`/`vim.o.lines` and fires `VimResized`
— already produces a correct, complete replacement. This was not new
behavior to add, only to verify and document; see `M.move()`/`place_regions()`
in `kitty_raw.lua`, unchanged from Part 1.

The part prompt also asked about "whether deleting an image implicitly
removes its placements" and "how to behave when a focusable float overlaps
the image" as profile-data candidates. Both remain uniform, generic behavior
rather than new per-profile fields: the Kitty graphics protocol guarantees
`a=d,d=I` deletes an image and all its placements for any compliant
implementation (every profile here claims protocol compatibility), and full
suppression of focusable-float overlaps is an architectural choice already
implemented generically in `preview.lua`'s `M.occlusion()` /
`controller.lua`'s `reconcile_occlusion()`, not something any of the six
profiles has a documented, verified reason to do differently. Adding
profile-specific booleans for either would have been unverified
differentiation with no evidence behind it — see "Decisions" below.

### Health, debug, and test coverage

`health.lua` gained `raw_graphics_zindex_source`, `raw_graphics_double_buffer`,
`raw_graphics_double_buffer_source`, `raw_graphics_owned_images`,
`raw_graphics_owned_placements`, and replaced its own env-var-based
`viewport_calibration` string with `viewport_calibration_tier` sourced from
`coordinates.calibration_tier()`. `debug.lua`'s per-session snapshot gained a
`placement` field (the full last-applied placement rectangle, including
`exclusions`) and renamed `viewport_calibrated` to
`viewport_calibration_tier`.

**`:MdViewerDebug` had zero automated test coverage before this part** — the
same class of gap Part 1 found and fixed for `:MdViewerHealth`. This was
checked for directly (not assumed) by grepping the test suite for
`md-viewer.debug`/`MdViewerDebug` before touching the file, since a
crash-only-in-a-real-session bug in a widely-used report command was exactly
Part 1's lesson. `tests/lua/cases/debug.lua` is new: it opens a real
`controller.open()` session, manually sets `session.last_placement` and
`session.viewport_calibration_tier` (since headless tests have no attached
TUI to drive a real raw-Kitty render), invokes the actual `:MdViewerDebug`
command, and asserts the new fields render without error — this would have
caught a crash the same way `tests/lua/cases/health.lua` caught Part 1's.

`tests/lua/cases/backend_kitty.lua` is new, per the part prompt's explicit
request for a dedicated file: it absorbed the raw-Kitty-specific assertions
that used to live inline in `tests/lua/cases/backends.lua` (which now only
covers backend *selection*) and adds z-index encoding across explicit
negative/zero/positive overrides, profile-default selection, override-beats-
profile-default, double-buffer ordering in both directions (verified by
locating the byte offsets of the delete and upload escape sequences within
the captured output and asserting their relative order), base64 chunking at
the exact 4096-byte boundary (an upload whose encoded form is exactly two
full chunks) and one byte past it (two full chunks plus a four-character
remainder chunk, verified by counting `,m=1` vs `q=2,m=0` occurrences), and
invalid-PNG rejection.

`tests/lua/cases/coordinates.lua` expanded substantially: every split
position (right/left/below/above) via real `vim.cmd()` splits, winbar
presence shifting the reported row by exactly one screen cell, all four
`laststatus` values (0/1/2/3, including the single-window edge case where
`laststatus=1` shows no statusline), a forced tabline shifting every window's
row down by one, live resize changing reported cell width, calibration-tier
behavior (env/estimated, including a zero env value correctly not counting
as calibrated), viewport clamping at both configured bounds, and guard-cell
reservation via `preview.placement()` (kitty_raw only, non-raw backends
unaffected).

`tests/lua/cases/config.lua`'s default-value assertions for
`image.raw_zindex` and `image.double_buffer` were updated from `-1`/`true` to
`nil`, since the config layer itself no longer owns those defaults — the
active terminal profile does.

---

## Tests run and results (Part 2)

```
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
  -> added 30 packages, 0 vulnerabilities

NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
  -> md-viewer Lua tests: 195 assertions passed (128 at the end of Part 1; the
     net +67 comes from the new backend_kitty.lua and debug.lua files and the
     expanded coordinates.lua, minus the handful of raw-Kitty assertions moved
     out of backends.lua into backend_kitty.lua)

npm test --prefix renderer   (node --test ../tests/node/*.test.js)
  -> tests 24, pass 24, fail 0 (unchanged; this part touched no renderer/ code)

stylua --check lua/ plugin/ tests/lua/
  -> clean (no diff)
```

All four commands were run on this development machine (macOS, Apple
Silicon, Neovim 0.12.4, Node 24, Google Chrome installed at the standard
`/Applications` path). The Ubuntu leg of CI remains untriggered (unchanged
from Part 1's status).

Per policy §5, both `:MdViewerHealth` and `:MdViewerDebug` — the two
commands this part actually changed the output of — were invoked directly
(not just their library functions) in headless sessions:

```
nvim --headless -u NONE -i NONE -c "set runtimepath+=." \
  -c "lua require('md-viewer').setup({})" -c "MdViewerHealth" \
  -c "lua vim.wait(8000, function() return vim.bo.filetype=='md-viewer-health' end, 50)" ...
```

rendered every new field (`raw graphics zindex source`, `raw graphics double
buffer[_source]`, `raw graphics owned images/placements`, `viewport
calibration tier`) without error, with `terminal_profile = unknown` on this
development machine (`TERM_PROGRAM=vscode`, not one of the seven modeled
profiles — the same honest result Part 1 observed, unchanged by this part).

```
nvim --headless -u NONE -i NONE -c "set runtimepath+=." \
  -c "lua require('md-viewer').setup({ terminal = { profile = 'kitty', kitty_graphics = 'on' }, image = { backend = 'kitty_raw' } })" \
  -c "edit <file>.md" -c "MdViewerOpen" -c "MdViewerDebug" ...
```

confirmed `:MdViewerOpen` honestly refuses to force `kitty_raw` in a headless
session (`"requested backend kitty_raw unavailable: no attached TUI"` — a
hard structural requirement, not a profile-inference question) and that
`:MdViewerDebug`'s snapshot, including the new `backends.kitty_raw` health
fields, renders correctly with no session open. A **separate** run with the
`cells` backend and a real `controller.open()` session (captured instead as
the new `tests/lua/cases/debug.lua`, since it needed to run every time, not
just once by hand) confirmed the new per-session `placement` and
`viewport_calibration_tier` fields also render without error.

---

## Known limitations and unresolved risks (current)

**Update, post-commit:** the operator performed the real acceptance test
described below on real hardware. See "Operator graphical validation" after
this list for the actual results — this bullet is left in place, unedited,
as the honest state of the world *as this part's own commit landed*; treat
the update note as authoritative for current status.

Carried forward from Part 1, still true:

- **No graphical validation was performed for any real terminal, as of this
  part's own commit** — not iTerm2, not Kitty, not WezTerm, not Ghostty, not
  Warp. This development environment has no attached graphical terminal;
  every check in this part was headless (`nvim --headless`, no TUI, no real
  Kitty graphics protocol round-trip). Per policy §4, none of this part's own
  work was claimed as visually validated at commit time.
- The CI matrix's Ubuntu leg is unvalidated.
- The pre-existing `config.setup()` reassign-before-validate quirk is
  unfixed (unrelated to this part; still only cosmetic today).
- `terminal.probe = "safe"` is still unimplemented. This part's calibration
  investigation (see above) is additional, concrete evidence for *why*: the
  one measurement a safe probe could plausibly add — cell pixel size via
  XTWINOPS — turns out not to be readable through any documented Neovim
  mechanism, which removes the strongest reason to implement it. It may still
  be worth removing this config surface in a later part if nothing ever ends
  up branching on it.
- Windows discovery remains implemented and unit-tested but unadvertised.

New in this part:

- **A "measured" cell-pixel calibration tier does not exist and, as far as
  this session could determine, cannot exist against documented Neovim
  0.12.x APIs for a real terminal TUI session.** See "What Part 2 actually
  built" above for the full investigation. If a future Neovim version adds a
  way to read XTWINOPS-style responses (or any other real pixel-geometry
  signal), `coordinates.calibration_tier()` is the single place to add it.

---

## Operator graphical validation (post-commit, real hardware)

The real acceptance test — deleting the four hand-tuned lines from
`~/.config/nvim/lua/plugins/md-viewer.lua` and confirming the preview still
renders — **has now actually been performed by the operator**, superseding
every "not yet tested" caveat above and in Part 2's original closing report:

- **iTerm2: confirmed working.** Preview renders correctly with no hand-tuned
  `render.cell_aspect_ratio`/`estimated_cell_width_px` and no
  `browser.executable_path`.
- **WezTerm: confirmed working.** Same config, no WezTerm-specific
  adjustment needed — `terminal.lua`'s `wezterm` profile inference and the
  `estimated` calibration tier's defaults hold up on real hardware, not just
  in headless unit tests.
- **macOS Terminal.app: correctly falls back to text-only rendering.** This
  is expected, honest behavior, not a failure — Terminal.app does not
  implement the Kitty graphics protocol, `terminal.detect()` has no profile
  for it, and `image.backend = "auto"` degrades to the `cells` backend
  exactly as designed. The operator found this via a real screenshot rather
  than a health-report reading, which surfaced a genuine gap: **the
  degraded preview gave no visible indication it was a fallback** rather
  than a rendering bug. Fixed in a same-day follow-up commit (`0be91a6`, not
  one of the seven part commits — see below): the preview winbar now shows
  `⚠ text-only preview — no Kitty graphics detected (see :MdViewerHealth)`
  whenever `image.backend = "auto"` lands on `cells` (any terminal with no
  Kitty-graphics evidence, not just Terminal.app), while an explicit
  `image.backend = "cells"` stays quiet since that isn't a fallback.
- **Font size:** also reported too small on real iTerm2/WezTerm rendering.
  Same follow-up commit raised the default `render.font_size_px` from an
  implicit 14px to a configurable 16px default (see `config.lua`), with the
  responsive breakpoints now scaling relative to that base.
- **Not tested:** Kitty terminal itself, Ghostty, Warp, and any Linux
  terminal. Still genuinely unvalidated — do not treat WezTerm/iTerm2
  working as evidence for the other three profile-compatible terminals.

**This confirms Parts 1 and 2 achieved their stated goal on at least two of
five modeled Kitty-compatible terminals**, with the third real terminal
tried (Terminal.app) correctly and legibly degrading rather than silently
failing. `v0.2.0` can reasonably be tagged on this branch; the operator has
not yet done so as of this writing.

---

## Decisions that changed assumptions in the original specification (Part 2)

- **Three of the part prompt's five "terminal-specific behaviors to move into
  profile data" (§2.1) turned out to already be uniform, protocol-guaranteed,
  or architecturally generic rather than real per-terminal differences: image
  deletion implicitly removing placements, redraw-after-resize, and
  focusable-float suppression.** Only z-index and the double-buffer
  replacement order got new profile-sourced fields
  (`default_raw_zindex`, `default_double_buffer`) with real resolution logic.
  The other three are documented in "What Part 2 actually built" above as
  generic behavior already covered by existing code (Kitty protocol
  semantics, `kitty_raw.M.move()`'s always-full delete-then-place, and
  `preview.lua`'s occlusion suppression), not turned into profile booleans,
  because no profile in this codebase has a verified reason to differ and
  inventing unverified per-profile differentiation would itself have
  violated policy §4's honesty requirement. If a real terminal is later found
  to need different behavior here, add the field to `terminal.lua` then —
  don't speculate ahead of evidence.
- **The part prompt's assumption that "Neovim can report grid pixel
  dimensions on some UIs" does not hold for terminal-attached Neovim as of
  0.12.4.** This was investigated directly against Neovim's own
  documentation (`TermResponse`'s scope, `nvim_list_uis()`'s return shape)
  rather than assumed either way. The calibration chain therefore has two
  real tiers (`env`, `estimated`), not three. This does not move Part 2's own
  boundary (the part is still complete: the chain is real, tested, and
  honestly reported) and does not invalidate any later part — Part 4's
  coordinate inversion consumes whichever tier produced the viewport, not the
  tier name itself.
- **`tests/lua/cases/backends.lua` lost its raw-Kitty-specific assertions**
  to the new `tests/lua/cases/backend_kitty.lua`, per the part prompt's
  explicit request for a dedicated file. `backends.lua` now only covers
  backend *selection* (`M.select`), which is what its name suggests it
  should have covered all along.

No part boundaries moved. No downstream prompt (`part-3` through `part-7`)
needed edits — Part 4's stated approach (inverting cell → CSS pixel
conversion) is unaffected by which calibration tier supplied the forward
conversion, and nothing else discovered here touches interaction, transport,
provenance, selection, or hardening scope.

---

## What Part 3 actually built

Renderer-side only. **No Lua file was modified**, and nothing user-visible
changed — that is the point of the part. Four Node modules changed, two are new.

### Staleness lanes (`renderer/src/lanes.js`, new)

`main.js` used to hold one `latestByDocument: documentId → requestId` map that
both `render` and `capture` wrote, so any newer request for a document cancelled
any older one. Once Part 4 starts emitting pointer updates at drag frequency
that becomes fatal: the drag stream would starve legitimate renders.

The map is replaced by a per-document record of a `contentEpoch` plus four lane
serials (`content`, `capture`, `interact`, `settle`). Every admitted request is
stamped with a ticket carrying `{ lane, serial, contentEpoch, contentRevision }`,
and staleness is one predicate checked at task start and again after the
expensive work:

```
stale(t) := lanes[t.lane] !== t.serial      // superseded within its lane
         || contentEpoch  !== t.contentEpoch // superseded by newer content
```

Only a `content` admission bumps `contentEpoch`. Every other lane writes its own
serial and nothing else:

```
bump content   -> invalidates content, capture, interact, settle
bump capture   -> invalidates capture only
bump interact  -> invalidates interact only
bump settle    -> invalidates settle only
```

**An interaction therefore has no way to express supersession of a render.** The
content lane's predicate reads `lanes.content` and `contentEpoch`; there is no
code path from an interact admission to either. This is structural, not a
convention — `tests/node/lanes.test.js` fires 200 interactions and asserts the
other three lanes' serial *values* are unchanged, not merely that the tickets
still happen to be valid, and `tests/node/interact.test.js` reproduces it over
the real subprocess with a render and a capture queued behind a 40-point drag
burst.

The module is deliberately pure — no browser, no filesystem, no timers — so the
highest-risk logic in the part is verifiable on any machine regardless of whether
Chromium is installed. Fifteen of the part's tests need no browser at all.

`content`, `capture`, and `settle` keep the historical `STALE_RENDER` code so
existing Lua is untouched; `interact` uses the new `STALE_INTERACTION`. Both now
carry a `detail` object (`lane`, `documentId`, `reason`) through
`protocol.js`, where `reason` is one of `superseded`, `content_changed`,
`revision_mismatch`, `viewport_mismatch`, `overflow`, or `forgotten`. Part 4 can
drop a `superseded` pointer update silently but must re-render on a
`revision_mismatch`.

Head-of-line blocking is handled by the lanes rather than by a second queue.
There is still exactly one serial promise chain, and the existing
`renderQueue.then(task, task)` idiom is preserved verbatim — a second parallel
queue over one shared page would be a real data race (an `interact` evaluating
while a `render` is mid-`setContent`). When a slow render sits ahead of twenty
queued drag updates, all twenty run their staleness check first, nineteen return
in O(1) without touching the page, and only the newest does work. That is the
coalescing.

Two smaller guards: a per-lane overflow cap (64 outstanding) rejects at
admission rather than queueing without bound, and `ALLOWED_LANES` in `main.js`
prevents lane laundering — a `capture` may be promoted to the `settle` lane
(which is how Part 6 will request its settled device-scale frame), but an
`interact` may **not** enter the `content` lane, because that is where the power
to cancel renders lives.

### Document isolation (`renderer/src/browser.js`)

There is one shared page and the prompt forbids a page per document, so
isolation cannot be structural. It is three layers, arranged so a bug in one
fails loudly rather than producing a plausible answer from the wrong document:

1. **`this.active`** — the single authoritative record of which document is
   loaded, mutated by exactly one code path (`loadDocument()`). It is nulled
   *before* `setContent` and repopulated only after geometry has been
   recollected, so there is no window in which a caller can read a half-loaded
   document and believe it. It is also nulled in `ensure()` when the context is
   recreated, in `forgetDocument()`, and in `close()`. Previously `layoutKey` was
   only ever string-compared; which document is on screen was never a readable
   fact.
2. **`ensureDocumentActive()`** — the only door into the DOM for an interaction.
   It confirms `active` already matches, or rehydrates, or throws
   `INTERACT_CACHE_MISS`. It never falls back to whatever happens to be loaded.
   Because callers run it inside the single serial queue, nothing can swap the
   page between this check and the caller's `page.evaluate`. **That co-location
   is the actual guarantee**; the other two layers exist to catch bugs in it.
3. **An in-DOM stamp** — every `setContent` writes an opaque monotonic token
   (`d1`, `d2`, …) onto `<html data-md-viewer-doc>`, and `hitTestInPage` refuses
   to answer if it does not match, *before* querying the DOM at all. It catches a
   `setContent` that silently failed, a context recreation racing in, and any
   future refactor that adds a second queue. The token sits on `<html>`, which
   the sanitizer never processes (it only sees the markdown-derived body
   fragment), so no allowlist change was needed — worth recording, since Part 5's
   prompt warns that unlisted `data-*` attributes vanish.

Rehydration needs the layout inputs, and the `interact` envelope carries no
theme, font size, or padding. `this.documents` holds a **frame record** per
document (layout key, theme, font size, padding, viewport, device scale,
network, browser options, scroll, document height, blocks, token), written on
every successful render and LRU-capped at 64. Without it, rehydration would have
to guess, and a guessed theme is a page that does not match the screenshot the
user is looking at.

`buildDocumentHtml()` is now the single document template used by **both** the
render path and the rehydration path. Two copies of that string is precisely how
document A would get rehydrated into a page that does not match what was
screenshotted.

Per-document interaction state (`interactionState` in `main.js`, keyed by
`documentId`) lives in trusted Node memory rather than on the page, because
`setContent` destroys page state on every document switch. It is dropped
whenever a document's content changes — applying a selection captured against
older content to newer content would be silent corruption in a copy operation —
and evicted alongside the caches. Part 3 only records the last hit; Part 6 fills
in selection and find. Its lifecycle is observable via a new
`interactionDocuments` count on the `health` result and is tested in both
directions.

**Adversarial coverage.** `tests/node/interact.test.js` renders document A
containing `ALPHA-ONLY` and document B containing `BRAVO-ONLY`, leaves B loaded,
then hit-tests document A at a coordinate that in B's layout sits over B's
heading. It asserts the result resolves to A's source line, that `rehydrated` is
true, and — the strongest form — that the string `BRAVO` appears **nowhere** in
the serialized response, not in the text preview, the link, or any diagnostic
field. A separate test corrupts `active.token` after a successful render to
simulate every Node-side check having been fooled, and asserts
`DOCUMENT_MISMATCH` is thrown, that the disproved `active`/`layout` pair is
dropped, and that the next interaction rebuilds and succeeds. Interacting with a
never-rendered document yields `INTERACT_CACHE_MISS`, never a guess.

A viewport that disagrees with the rendered layout is **refused**
(`viewport_mismatch`) rather than silently resized, because resizing would
invalidate the very coordinates the request carries.

### DOM hit-testing (`renderer/src/interact.js`, new)

The precedence rule is the subtle part and is worth stating plainly:
**`elementFromPoint` is authoritative for "is there content here"; the caret APIs
only refine a hit that already landed on content.** Caret APIs snap to the
nearest text node, so consulting them first would turn a click in the
scroll-past-end padding into a confident hit on the last paragraph.

`.markdown-body` carries `padding: 22px 26px var(--md-viewer-bottom-padding)`
(`preview.css:18`), so side padding, top padding, the gaps between blocks, and
the whole scroll-past-end region all resolve to the `article` element — which has
no `data-source-*` attributes of its own. One rule covers all of them, and all of
them honestly report `precision: "none"` rather than a guess.

Caret resolution prefers `document.caretPositionFromPoint`, falls back to
`document.caretRangeFromPoint`, then to element-only. A `strategy` parameter
(`auto` | `caret-position` | `caret-range` | `element-only`) forces each path so
both branches are genuinely exercised rather than whichever one this Chromium
build happens to take; a test asserts all three agree on the same paragraph. A
caret that snaps *outside* the block `elementFromPoint` landed on is discarded
rather than allowed to relocate the answer into a neighbouring block.

Source resolution walks up to the nearest `[data-source-start][data-source-end]`
ancestor. markdown-it maps are 0-based with an exclusive end; Neovim lines are
1-based. That conversion now lives in exactly one place
(`resolveSourcePosition`), because Part 5 inherits it.

**Precision labelling** — a block spanning exactly one source line means we
genuinely know the line, so it reports `line`; a multi-line block reports `block`
with the block's first line; no block reports `none`. `exact` requires inline
provenance and cannot be produced by any code path in this part. Two tests
enforce that: an exhaustive sweep over 40×12 synthetic block spans, and a sweep
over every block the kitchen-sink fixture actually renders.

`activate_at` returns link metadata when the point is over an anchor and falls
back to source semantics otherwise, so Part 4's "an unmodified click on a link
still navigates to source" needs no second round trip. `classifyLink` labels
`fragment` / `http` / `https` / `mailto` / `local_file` / `unsafe`; `file:` is
`local_file` because only Part 4 knows the document root, while protocol-relative
`//host/path` is `unsafe` (it is a network fetch wearing a relative path's
clothes). The renderer never follows a link.

DOM node identity never crosses the process boundary — the hit descriptor
carries `{ nodeType, nodeName }` and a bounded (≤120 char) text preview. Part 6
hit-tests both selection endpoints inside a single `evaluate`, so it never needs
to round-trip a node.

### Atomic interaction results

`captureViewport()` is now shared by `render()` and by interactions. An action
declaring `mutatesVisibleState` always captures; any action may opt in via a
`capture: true` envelope flag. Both produce the semantic result and the PNG from
the **same queued operation**, so Lua never has to issue a follow-up capture.
PNGs go to the same temp dir, are tracked in `this.files`, and are unlinked by
the renderer if the result turns out stale after capture — mirroring the existing
post-render behaviour.

Neither action implemented in this part mutates anything, so the flag is
currently only exercised through `capture: true`. See "Known limitations".

### Markdown cache widened

`renderMarkdown()` now returns `{ html, sourceMap }` and `markdownCache` entries
are `{ key, html, sourceMap }`, with `sourceMap: null`. Part 5 is a fill-in
rather than a refactor of every call site.

---

## Tests run and results (Part 3)

```
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
  -> added 30 packages, 0 vulnerabilities

NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
  -> md-viewer Lua tests: 210 assertions passed (unchanged; this part touches
     no Lua)

npm test --prefix renderer   (node --test ../tests/node/*.test.js)
  -> tests 59, pass 59, fail 0   (24 before this part)

stylua --check lua/ plugin/ tests/lua/
  -> clean (no diff)
```

**A correction to this document's own record:** Part 2's section above reports
195 Lua assertions. The actual count at the branch point for Part 3 is 210 — the
extra 15 come from the two post-Part-2 follow-up commits (`0be91a6`, `8ad0623`),
which this document never recorded. Verified by stashing Part 3's changes and
re-running the suite on the branch point. 210 is the number to compare against
going forward.

The 35 new Node tests split into 15 that need no browser (the whole lane
registry, envelope validation, link classification, source conversion, and the
in-page document guard against a stubbed DOM) and 20 that drive a real Chromium
through a real renderer subprocess over real NDJSON. The browser-backed ones
`t.skip` with a named reason if no Chrome/Chromium/Edge is discoverable, matching
the pattern established in Part 1.

Per policy §5, both `:MdViewerHealth` and `:MdViewerDebug` were invoked directly
in headless sessions. **Neither command's output changed in this part** —
`health.lua` maps renderer fields explicitly rather than passing them through, so
the new `activeDocument`, `cachedDocumentFrames`, `cachedDocuments`,
`laneDocuments`, and `interactionDocuments` fields on the renderer's `health`
result are ignored by it. This was run as a regression check, not as validation
of new surface: `:MdViewerHealth` produced 38 lines with `chromium launch:
succeeded` and a live renderer subprocess, and `:MdViewerDebug` produced 59 lines
with no embedded newlines (the Part 1 crash class).

**No graphical validation was performed and none is applicable.** Nothing
user-visible changes in this part; there is nothing to look at. Part 4 is the
first part that can be validated in a real terminal.

---

## Known limitations and unresolved risks (Part 3)

- **Rapid alternation between two documents costs a full `setContent` plus a
  geometry recollect per switch.** The common case — one preview focused — is
  free, because `active` already matches. The interact result reports
  `rehydrated` and `rehydrateMs` so Part 4 can surface thrash in
  `:MdViewerDebug` rather than hiding it. Opening a second page per document was
  explicitly rejected: it multiplies memory and defeats the persistent-page
  benefit.
- **No action in this part mutates visible DOM state**, so the
  `mutatesVisibleState` branch has no product caller until Part 6. The
  same-queued-operation capture path is exercised through the `capture: true`
  envelope flag, which proves the semantic result and the PNG are produced
  together in one queued task at both `css` and `device` scale. What is *not*
  proven end to end is mutate-then-capture ordering, because there is nothing to
  mutate yet. Part 6 is the first real caller.
- **`interactionState` is currently write-only.** Part 3 records `lastHit`;
  nothing reads it. Its isolation and revision-drop behaviour are tested through
  the `interactionDocuments` health count, but the `selection` and `find` fields
  are Part 6 scaffolding and are untested because they are unpopulated.
- **Rehydration recollects geometry rather than reusing the stored blocks.** The
  layout key pins everything that affects geometry, so these should be identical,
  and a test asserts the rehydrated `documentHeightPx` equals the render's. The
  cost is one extra `evaluate` on an already-expensive switch; the benefit is
  that a divergence becomes visible instead of silent.
- **Blocked images have no geometry at all.** `.md-viewer-image-blocked` is
  `display: none`, so a paragraph containing only a blocked image is zero-height
  and `collectBlockGeometry` filters it out — a click there resolves to the
  article, and honestly reports `none`. This is pre-existing behaviour, not
  introduced here, but it was discovered while writing the image hit-test and is
  worth knowing. The image test therefore renders a real, allowed local PNG
  (generated in the test) rather than pretending the fixture's blocked images
  were a meaningful target.
- Carried forward and unchanged: the CI matrix's Ubuntu leg is still untriggered;
  the `config.setup()` reassign-before-validate quirk is still unfixed;
  `terminal.probe = "safe"` is still unimplemented; Windows discovery remains
  unadvertised; Kitty, Ghostty, Warp, and all Linux terminals remain
  graphically unvalidated.

---

## Decisions that changed assumptions in the original specification (Part 3)

- **A capture no longer cancels a queued render.** This is a real behaviour
  change from Parts 1–2, where both wrote one shared map. The part prompt's rules
  ("a capture must never be cancelled by an interaction") imply an asymmetric
  model, and the operator confirmed the direction: content invalidates downstream
  only. In practice the old symmetry rarely bit, because `renderer.lua` only
  issues a capture when `session.renderer_revision == content_revision`, but the
  race was real. Anything depending on a capture cancelling a render would now
  behave differently; nothing in the tree does.
- **The per-lane `contentRevision` check fires at admission, not in the staleness
  predicate.** The prompt asks that every lane verify `contentRevision`
  independently. Implementing it *both* at admission and inside `isStale()` would
  have made the second check unreachable — `contentEpoch` only ever changes when
  a content admission changes `revision`, so the epoch check subsumes it. Rather
  than ship a redundant branch that can never fire and can never be tested, the
  verification lives at admission where it genuinely rejects a caller working
  from replaced content, before it occupies a queue slot. It is tested for all
  three non-content lanes.
- **`precision: "line"` is reported for single-line blocks**, not a uniform
  `block` for everything. For a block spanning exactly one source line, block and
  line are the same fact, so `line` is both more useful to Part 4 and strictly
  honest. Multi-line blocks report `block` with the block's first line. This was
  an explicit operator decision.
- **markdown-it's map for a nested list item is `[9,11)`, not `[9,10)`** in the
  kitchen-sink fixture — the nested list closes the outer item. Two test
  assertions were written against the wrong assumption and corrected against the
  geometry the renderer actually produces. Noted because Part 5 will be reasoning
  about these maps far more intensively.
- **`this.documents` (frame records) and `markdownCache` are two separate LRUs.**
  They are driven by the same access patterns and both capped at 64, and eviction
  from either cascades to the other, but they can in principle diverge. A
  markdown entry whose frame record is gone yields `INTERACT_CACHE_MISS` with
  reason `no_frame`, which is honest and recoverable, so unifying them was not
  worth the coupling.

No part boundaries moved. **No downstream prompt needed edits** — Parts 4, 5,
and 6 each describe an approach this part's implementation supports as written.
Two contracts they should rely on:

- **Part 4 must send the `scrollY` it is currently displaying**
  (`session.applied_scroll_y`), not the position it wants (`session.scroll_y`).
  The interaction frame is defined by the request: `ensureDocumentActive`
  restores the page to the requested `scrollY` and the result echoes the applied
  value so clamping is detectable. Sending the wrong one would silently map
  clicks onto a frame the user is not looking at.
- **Part 6's actions become additive by flipping `mutatesVisibleState`** in the
  `INTERACT_ACTIONS` registry in `renderer/src/interact.js`. All nine reserved
  action names already validate and reject with `UNSUPPORTED_ACTION` (distinct
  from `UNKNOWN_ACTION`), and `lane: "settle"` is already accepted on `capture`.

---

## Safe stopping point after Part 2 (historical)

The tree is green: all four policy §5 commands pass (195/195 Lua assertions,
24/24 Node tests, stylua clean), and both `:MdViewerHealth` and
`:MdViewerDebug` — the two commands this part changed — have been invoked
directly in headless sessions per policy §5, not just through their
underlying library functions. This part is commit `03f2381` (plus this
follow-up doc-only commit recording that hash, matching Part 1's
`0d62c1f`/`777b4a9` pattern) on `feat/cross-platform-markdown-preview`;
neither has been pushed.

**This is a genuinely shippable `v0.2.0`** in the sense the part prompt
intended (automated portability work complete, generic encoder, real
resolution/reporting for z-index and double-buffering, an honest two-tier
calibration chain), **and unlike the state at the moment this part's own
commit landed, the real acceptance test has now actually been performed** —
see "Operator graphical validation" above. iTerm2 and WezTerm both render
correctly with the four hand-tuned config lines removed; macOS Terminal.app
correctly and now legibly falls back to text-only rendering. A same-day,
out-of-band follow-up commit (`0be91a6` — not one of the seven part commits;
it responds to this real-world feedback, not to a part prompt) raised the
default preview font size and added the fallback-notice UI described above.
`v0.2.0` can reasonably be tagged; it has not been tagged yet.

**First next action for Part 3:** read `prompts/part-3-interaction-transport.md`
fresh (`/clear` first per `prompts/README.md`; that prompt recommends
planning with Opus 5 before implementing with Sonnet 5). Part 3 can rely on
`coordinates.viewport()`'s `tier` field and `kitty_raw.lua`'s
`resolve_zindex()`/`resolve_double_buffer()` pattern (explicit override,
named source string, else profile default) as stable, tested contracts —
neither is expected to change shape again before Part 7.

---

## Safe stopping point after Part 3 (historical)

The tree is green: all four policy §5 commands pass (210/210 Lua assertions,
59/59 Node tests, stylua clean). Part 3 is commit `dbd151f` on
`feat/interaction-transport`, a branch cut from `main` (where Parts 1–2 landed
via PR #1). Neither the branch nor this doc commit has been pushed, and no PR
has been opened.

Part 3 changed **no Lua and nothing user-visible**, so there is nothing to look
at in a terminal and no manual acceptance test to run. The renderer-side
interaction transport is complete and tested: the `interact` method with typed
actions, `STALE_INTERACTION` distinct from `STALE_RENDER`, four independent
staleness lanes, three-layer document isolation, and block/line-honest DOM
hit-testing.

**First next action for Part 4:** read
`prompts/part-4-mouse-and-navigation.md` fresh (`/clear` first per
`prompts/README.md`). Part 4 is the first part whose result a human can see, and
it can rely on these settled contracts:

- The `interact` envelope: `{ documentId, contentRevision, viewportWidthPx,
  viewportHeightPx, scrollY, action, coordinates, modifiers, clickCount,
  captureScale, capture, strategy }`, validated purely in
  `renderer/src/interact.js`.
- Result shapes `{ kind: "source", sourcePosition: { line, byteColumn,
  precision } }` and `{ kind: "link", link: { href, type }, sourcePosition }`,
  where `precision` is `line`, `block`, or `none` — **never `exact`** until
  Part 5.
- Error codes to branch on: `STALE_INTERACTION` (with `detail.reason`),
  `INTERACT_CACHE_MISS`, `DOCUMENT_MISMATCH`, `UNKNOWN_ACTION`,
  `UNSUPPORTED_ACTION`, `INVALID_INTERACTION`, `INVALID_REQUEST`.
- **Send `session.applied_scroll_y`, not `session.scroll_y`** — see the Part 3
  decisions section above for why this one is easy to get wrong and silent when
  wrong.
- `lua/md-viewer/renderer.lua`'s existing result validation requires
  `result.blocks` to be a table; interaction results have no `blocks`, so Part 4
  needs its own response handler rather than reusing `M.request`'s.

---

## What Part 4 actually built

### `lua/md-viewer/interaction.lua` (new) — the gesture engine

All press/drag/release classification, the interact-transport round trip, cursor
movement, and link dispatch live in one new module rather than growing
`mouse.lua` into a second responsibility. `mouse.lua` stays what the part prompt
asked it to remain: the expr-mapping install/detach technique, extended with a
gesture list alongside the existing wheel list.

**Mouse capture is button-scoped, not window-scoped.** A module-level `captured`
variable records which session owns an in-progress press. `mouse.lua`'s
`gesture_session()` resolves press/activate gestures from whichever preview is
currently under the pointer (`state.from_preview_win`), but resolves drag/release
from `interaction.captured_session()` unconditionally. This was not obvious from
the part prompt and was found by reasoning through a concrete failure mode
before writing any dispatch code: if drag/release resolved by window like press
does, a drag that leaves the preview's screen rectangle before the button comes
up would report no session (`state.from_preview_win` finds nothing under the
pointer's new position), the `pressed` flag would never clear, and the *next*
unrelated click would measure its distance against a stale `press_cell` and
misclassify. Routing drag/release through capture instead of window lookup fixes
this the same way real GUI toolkits handle mouse capture, and
`tests/lua/cases/interaction.lua` exercises exactly this scenario (drag reported
under a different `winid` than the one that pressed).

A second, related design point: `install_gesture()` only ever swallows a
drag/release keystroke when `interaction.is_captured(session)` is true for the
resolved session. Resolving drag/release by window (the initially obvious
approach) would have swallowed *any* `<LeftDrag>` that happened to cross a
preview window — including a source-buffer text selection dragged across the
split boundary — even when that preview never captured the press. This is a real
regression class the capture-scoped design avoids by construction, not just by
the specific stuck-flag bug above.

### Coordinate conversion (`lua/md-viewer/coordinates.lua`)

`M.cell_to_css(mouse, placement, viewport)` is pure: 1-based `screenrow`/
`screencol` in, a screen-space `placement` rect (0-based, matching
`M.for_window`'s existing convention) and the CSS-pixel `viewport` that produced
the currently displayed image, nil-or-`{x, y}` out. It reuses `M.for_window`'s
screen-position derivation transitively (via `session.last_placement`, which is
always built from `M.for_window`/`preview.placement`), so winbar, statusline,
global statusline, tabline, and split-separator accounting all come for free —
they were already correct in the rectangle this function receives, and
duplicating that logic here would have been a second place for it to drift.
Exclusion rectangles (`placement.exclusions`, the passive-overlay cutouts Part 2
built) are checked in screen space before the cell→CSS conversion runs, so a
point inside a notification cutout refuses to resolve rather than reporting a
plausible but wrong coordinate.

Cell centring is `(local + 0.5) / count * viewportPx`, exactly as specified — no
guessed pixel constant anywhere in the conversion.

### Link dispatch and the document-root guard (`lua/md-viewer/security.lua`)

`M.is_inside(root, candidate)` mirrors `renderer/src/security.js`'s `isInside()`
byte-for-byte in intent: both sides resolved with `fs_realpath` before the prefix
comparison, so a symlink cannot walk a `local_file` link target outside the
document root and still read as contained. `M.resolve_local_link(href, base_dir,
document_root)` strips a `file://`/`file:` prefix, percent-decodes, joins against
`base_dir` (or treats the href as already-absolute), and refuses anything
`is_inside` rejects. This is the second real security-relevant path validator in
the codebase — `security.js`'s `isInside` was the first — and reuses the same
realpath-containment *approach* while necessarily being separate code, since Lua
cannot call into the renderer's Node module. Both now exist so a future part
touching either has a documented pattern to match rather than inventing a third.

### Fragment links actually work — a renderer-side discovery

The part prompt's dispatch table says a `fragment` link should "scroll within
the controlled Chromium document," and Part 3 already classified `fragment`
hrefs, but nothing in the renderer could resolve *where* a fragment target
actually is: **markdown-it generates no heading `id` attributes today, and
`id` was not in the sanitizer's allowlist for any tag.** Every fragment link in
every document would have resolved to nothing, permanently, regardless of what
Lua-side code this part wrote — this was verified by reading
`renderer/src/markdown.js` directly, not assumed. No later part prompt mentions
heading anchors either (checked `part-5` through `part-7` for "anchor"/"slug"/
"heading id" before deciding this wasn't intentionally deferred).

Two small, additive changes fix this, kept inside `renderer/src/markdown.js`
because they are the same rendering concern the file already owns:

- `headingAnchorPlugin` (markdown-it core-ruler plugin) assigns a GitHub-style
  slug (lowercase, punctuation stripped, spaces to hyphens, numeric-suffix
  dedup for repeats) as each heading's `id`, from the heading's own inline text.
- `id` was added to `allowedAttributes` for `h1`–`h6` specifically (not the
  global `"*"` entry), so raw HTML from other tags cannot inject an `id` via
  the `rawHtml` override — the sanitizer's existing minimal-allowlist posture
  is preserved.

`renderer/src/browser.js` gained `scrollToFragment(href)`: a `page.evaluate()`
call that runs `document.getElementById(id)` and `Element.scrollIntoView()` —
trusted Node-injected code, the same mechanism `hitTestInPage` and
`collectBlockGeometry` already use, not a page script, so
`javaScriptEnabled: false` is untouched and the hidden page still never
navigates (this is a same-page scroll, not a navigation). `interact()` calls it
automatically whenever `activate_at` classifies the hit as a `fragment` link,
and reports `fragmentResolved` plus the resulting `scrollY` on the result — a
miss (no matching id) is reported honestly (`fragmentResolved: false`, scroll
unchanged) rather than silently doing nothing unexplained. Lua's
`interaction.activate_link()` reads `fragmentResolved`/`scrollY` straight off
the already-completed `activate_at` response and calls the existing
`controller.schedule_scroll()` — no second interact round trip, matching the
same "no follow-up request" property Part 3 built for links in general.

This is scope precisely bounded to what Part 4's own dispatch table requires: it
does not touch selection, search, or inline provenance (Part 5/6 territory), and
`renderer/src/interact.js`'s `INTERACT_ACTIONS`/`RESERVED_ACTIONS` registries are
unchanged — `activate_at` still validates and behaves exactly as Part 3 left it
for every non-fragment case.

### Click-to-source, cursor safety, and the sync guard

`interaction.move_source_cursor()` clamps the line to the buffer's line count,
clamps the byte column to the target line's byte length, then walks backward
over UTF-8 continuation bytes (`(byte & 0xC0) == 0x80`) so a click can never
split a multi-byte character. It sets `session.sync_guard = true` before
`nvim_win_set_cursor` and clears it on the next scheduler tick — the exact
technique `sync.update_source_from_scroll()` already uses — rather than adding a
second guard mechanism. `focus_source_on_click = false` calls
`nvim_win_set_cursor` without `nvim_set_current_win`, so the cursor moves in the
(possibly unfocused) source window without stealing focus.

Every click and modifier-click resolves through `activate_at`, never `hit_test`
— Part 3's comment in `interact.js` says this exact simplification is the reason
`activate_at` exists (link when present, source fallback otherwise), and this
part is the first to actually exercise it end to end. `session.last_interaction_kind`/
`last_interaction_precision` are recorded on every resolved click and surfaced in
`debug.lua`'s snapshot (`interaction_last_kind`, `interaction_last_precision`,
`interaction_pointer_pressed`), verified by directly invoking `:MdViewerDebug` in
a headless session per policy §5, not just the underlying function.

### Configuration

`interaction = { enabled, click_to_source, focus_source_on_click, links,
drag_threshold_cells, double_click }` as specified, plus `double_click` (not in
the part prompt's exact list but requested by its own text: "make the binding
configurable now so Part 6 does not have to break anything" — `double_click`
gates whether the `<2-LeftMouse>` mapping installs at all, which is the lever
Part 6's word-select needs). All six fields validate with `assert()`-style
actionable messages matching the existing convention.

`mouse.M.attach()` now installs the wheel mappings and the gesture mappings
independently — `installed_wheel`/`installed_gestures` are two separate flags —
gated on `sync.mouse_scroll` and `interaction.enabled` respectively, so
disabling one doesn't silently disable the other. Interaction is never enabled
for the `cells` backend: `controller.open()` already only calls `mouse.attach()`
for non-cells backends (unchanged from Part 1), and `interaction.locate()`
independently refuses to resolve a point when `session.backend.name == "cells"`,
so the guard holds even if a future caller attaches gestures directly.

---

## Tests run and results (Part 4)

```
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
  -> added 30 packages, 0 vulnerabilities

NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
  -> md-viewer Lua tests: 348 assertions passed (210 at the end of Part 3; the
     net +138 comes from two new files, tests/lua/cases/interaction.lua and
     tests/lua/cases/mouse.lua, plus an expanded tests/lua/cases/coordinates.lua)

npm test --prefix renderer   (node --test ../tests/node/*.test.js)
  -> tests 61, pass 61, fail 0   (59 before this part; +2 from the new fragment-
     scroll tests in tests/node/interact.test.js)

stylua --check lua/ plugin/ tests/lua/
  -> clean (no diff)
```

All four commands were run on this development machine (macOS, Apple Silicon,
Neovim 0.12.4, Node 24, Google Chrome installed at the standard `/Applications`
path).

Per policy §5, `:MdViewerDebug` — the command whose output this part changed —
was invoked directly (not just `debug.snapshot()`) in a headless session with a
real `controller.open()` session, confirming `interaction_last_kind`,
`interaction_last_precision`, and `interaction_pointer_pressed` all render
without error and carry the values set on the session.

**Beyond the policy §5 minimum**, because this part's whole point is a real
mouse gesture reaching a real command, a second headless script exercised the
actual installed keymaps end to end rather than only the library functions
underneath them: it called `require("md-viewer").setup({})`, ran the real
`:MdViewerOpen` command, forced a graphical backend, stubbed
`vim.fn.getmousepos()` and `process.request`, then invoked the *actual Lua
callback* Neovim would run for `<LeftMouse>` and `<LeftRelease>` (available via
`vim.fn.maparg(lhs, mode, false, true).callback`, which exposes a
`vim.keymap.set`-installed function directly — no synthetic terminal input
needed). Result: the press correctly swallows the keystroke and captures the
session on the next scheduler tick, the release correctly swallows its
keystroke, issues one real `interact` request with `action = "activate_at"`,
and the source cursor lands on the expected line with `precision = "line"`
recorded on the session. This is the same class of gap Part 1's post-commit
`:MdViewerHealth` fix taught this project to check for — a library function
passing its unit tests is not the same claim as the actual keystroke path
working — applied proactively here instead of found after the fact.

**No graphical validation was performed in a real terminal.** This development
environment has no attached graphical terminal (`TERM_PROGRAM=vscode`,
consistent with every prior part). The keymap-level check above proves the
dispatch, coordinate conversion, transport round trip, and cursor movement are
wired correctly against a stubbed renderer; it does not prove a real click in a
real Kitty/iTerm2/WezTerm/Ghostty/Warp session lands where a human's eye expects
it to, because no code path in this project can synthesize a real terminal
mouse-report escape sequence. Per policy §4, this is stated as unvalidated, not
implied as tested. See "Operator verification" in
`prompts/part-4-mouse-and-navigation.md` for the manual steps this needs.

---

## Known limitations and unresolved risks (Part 4)

- **No graphical validation in a real terminal**, as above — the highest-value
  open risk of this part, since coordinate conversion is exactly the kind of
  code that can pass every synthetic unit test and still be off by half a cell
  against a real terminal's actual mouse-report geometry.
- **Double-click (`<2-LeftMouse>`) currently performs the same click-to-source
  navigation as a single click.** The part prompt reserves double-click for
  Part 6's word-select and asks only that the binding be configurable now, which
  it is (`interaction.double_click`); this part does not invent interim
  double-click behavior beyond "still useful, not a silent no-op."
  `pointer.click_count` is recorded and available for Part 6 to branch on.
- **Drag state is tracked (`pointer.drag_started`, `pointer.newest_pending_drag_point`)
  but creates no selection**, per the part prompt's explicit scope boundary.
  Part 6 is the first consumer of `newest_pending_drag_point`.
- **A ctrl/cmd-click activates immediately on mouse-down**, not on a matched
  press+release pair. This was a deliberate design choice, not an oversight:
  Neovim only reports the modifier on the press keycode (`<C-LeftMouse>`,
  `<D-LeftMouse>`) — there is no `<C-LeftRelease>` to pair it with — so waiting
  for a release would mean guessing which unmodified `<LeftRelease>` belongs to
  a modified press. Most editors' ctrl/cmd-click-to-open is immediate-on-press
  behavior anyway. Not covered by an automated test beyond the dispatch-table
  unit tests in `tests/lua/cases/interaction.lua`, since it requires no
  press/drag/release state machine to exercise.
- **`renderer/src/markdown.js` now generates heading `id`s unconditionally**,
  which is a real (if narrow) behavior change to every rendered document, not
  only ones with fragment links. It was necessary for the fragment-link feature
  this part's own dispatch table requires to be anything other than permanently
  dead code (see "What Part 4 actually built" above). `tests/node/markdown.test.js`
  and every existing snapshot-style assertion in `tests/node/interact.test.js`
  still pass unchanged, since none of them assert an exact heading tag string.
- Carried forward and unchanged: the CI matrix's Ubuntu leg is still
  untriggered; the `config.setup()` reassign-before-validate quirk is still
  unfixed; `terminal.probe = "safe"` is still unimplemented; Windows discovery
  remains unadvertised; Kitty, Ghostty, Warp, and all Linux terminals remain
  graphically unvalidated for the whole project, not just this part.

---

## Decisions that changed assumptions in the original specification (Part 4)

- **Mouse capture is button-scoped (a module-level `captured` session in
  `interaction.lua`), not resolved per-event by window.** The part prompt does
  not say this explicitly; it was derived from reasoning through the drag-leaves-
  the-window failure mode described above before writing the dispatch code, and
  confirmed by a dedicated regression test. This is the single most
  consequential design decision in this part's implementation and the one most
  likely to matter to Part 6, which will extend the same drag state machine to
  create real selections — Part 6 should keep routing drag/release through
  `interaction.captured_session()`, not through `state.from_preview_win()`.
- **Fragment links required a small, additive renderer change** (heading-id
  generation in `markdown.js`, `scrollToFragment()` in `browser.js`) that the
  part prompt's own "read these files first" list (Lua files only) did not
  anticipate. This was judged in-scope rather than deferred because: (a) it is
  required by this part's own §4.4 dispatch table, not a later part's; (b) it
  does not touch selection, search, or exact provenance — the three things
  explicitly reserved for Parts 5/6; and (c) `renderer/src/interact.js`'s action
  registry was explicitly designed in Part 3 to be additive for exactly this
  kind of narrow extension. If this judgment call should have gone the other
  way (documenting fragment activation as permanently unimplemented instead),
  that is a one-file revert (`browser.js`'s `scrollToFragment` call site) plus
  reverting the two `markdown.js` additions.
- **Clicks always resolve through `activate_at`, never `hit_test`.** Part 3's
  own code comment already named this simplification; this part is the one that
  actually relies on it, confirming the Part 3 design held up against a real
  caller rather than only its own tests.
- **`session.applied_scroll_y` is what's sent in every interact request, not
  `session.scroll_y`**, per the contract Part 3's closing section documented.
  Recorded here because it was easy to get wrong silently (both fields hold a
  plausible scroll position; only one matches the currently displayed image) and
  worth confirming explicitly landed correctly.

No part boundaries moved. No downstream prompt needed edits — Part 5's stated
approach (adding real inline provenance to the same `sourcePosition` shape this
part already consumes) and Part 6's stated approach (extending the drag state
machine and the `<2-LeftMouse>` binding this part already wired) are both
supported as written by what this part actually built.

---

## Two bugs the operator found after Part 5 landed

Both were reported against a real terminal, and both were unmasked by Part 5
rather than introduced by it: until the `modifiers` fix above, no click ever
received a successful response, so neither of these code paths had ever run.
Fixed in a follow-up commit on the same branch.

### 1. Clicking outside the text crashed

```
interaction.lua:102: bad argument #1 to 'floor' (number expected, got userdata)
```

A click on the page padding, or on empty space between blocks, resolves to
precision `none`, and the renderer honestly sends `line: null`. **`vim.json.decode`
maps JSON `null` to `vim.NIL`** — a userdata sentinel that is *truthy* and
compares `~= nil`. So `move_source_cursor`'s guard (`position.line ~= nil`) let
it through and `math.floor` threw on the sentinel.

This is not confined to one field: `if not result.link` and every similar guard
in this codebase reads a null field as *present*. Fixed at the transport, where
the class ends: `protocol.decode` now passes `luanil = { object = true }`, so a
null object value arrives absent. Only `object` — `luanil.array` would leave
holes in arrays like `blocks`, which the scroll sync walks with `ipairs`.
`move_source_cursor` additionally type-checks rather than nil-checks, so the
function that moves a user's cursor cannot be made to crash by a position it
should simply decline to act on.

### 2. Clicking text made the preview scroll itself

Clicking a word moved the source cursor, the resulting `CursorMoved` reached the
source-to-preview sync, and the sync re-anchored the preview on the block
containing that line — which reads as the preview jumping to centre whatever was
just clicked.

`sync_guard` was supposed to prevent exactly this, and could not: **Neovim
dispatches `CursorMoved` when it next returns to its main loop, and
`vim.schedule` callbacks run on that same loop**, so the guard is usually
released before the echo arrives. No amount of rescheduling fixes a race between
two main-loop callbacks.

The fix records the cursor position we set (`sync.suppress_echo`) and drops the
next `CursorMoved` that matches it (`is_echo`). A position is not a race: the
cursor either is where we put it or it is not. The record is consumed on the
first check either way, so a stale record cannot swallow a real move later, and
the position is read *back* from the window rather than taken from the caller
because Neovim's normal-mode clamping can land the cursor short of the requested
column. `update_source_from_scroll` had the same latent flaw — masked there by
the `manual_scroll_until` and block-index checks — and now uses the same
mechanism.

Both fixes have regression tests that were confirmed to **fail against the old
code** before being accepted: `tests/lua/cases/protocol.lua` (null decoding, and
that arrays keep their length), `tests/lua/cases/interaction.lua` (a decoded
precision-`none` position and a raw `vim.NIL` one are both declined, not
crashed), and `tests/lua/cases/sync.lua` (three echo cases, each draining the
scheduler first so it reproduces the losing ordering rather than the convenient
one). A headless end-to-end script also confirmed both against the real renderer:
a click at x=2 (the left page padding) reports `none` with an absent line and
moves nothing, and a click on text resolves exactly, moves the cursor, and leaves
`session.scroll_y` untouched while a genuine cursor move still syncs.

Suite totals after the fixes: **375 Lua assertions** (360 at Part 5's commit),
96 Node tests unchanged, stylua clean.

**Confirmed on real hardware by the operator** (see "Operator confirmation"
below), superseding this section's original "unconfirmed" caveat.


---

## Two more operator findings: the first character of a line, and the scroll again

### 3. The first character of a line could not be clicked

Clicking the left edge of `F` in a `## Features` heading did nothing; only
clicking a character or so to the right moved the cursor.

**A terminal reports which cell was clicked and never where inside it**, so a
click genuinely covers a whole cell — typically wider than a rendered character.
`cell_to_css()` collapsed that cell to its centre, and the centre is exactly the
wrong representative at the edges of the text: the cell holding the first
character of a line also holds the page's left padding, so its centre lands on
the `article`, finds no block, and honestly reports `none` — a click that does
nothing.

This was measured rather than reasoned about. Mapping every cell column across
the heading, at 60 cells over a 600px viewport (10 CSS px per cell):

```
cell col  0 -> css x=  5.0  outside_content  none          <- dead
cell col  1 -> css x= 15.0  outside_content  none          <- dead
cell col  2 -> css x= 25.0  hit              exact col 3   <- first hit is already 'F'
```

Two dead cells at the start of every line, and the first live one already sits
on `F` — so the whole left edge of the text was unaddressable.

The fix passes the cell's own CSS extent along with the point
(`cell_to_css` now returns `cellWidthPx`/`cellHeightPx`, `request_hit` forwards
them) and has `hitTestInPage` probe outward from the centre, **bounded by that
one cell**, taking the nearest content. After the fix:

```
cell col  0 -> css x=  5.0  outside_content  none          <- still none, correctly
cell col  1 -> css x= 15.0  hit  snapped     exact col 3   <- 'F'
cell col  2 -> css x= 25.0  hit              exact col 3
```

Cell 0 spans `[0,10)` and contains no text at any point across its width, so
`none` remains the honest answer there; cell 1 spans `[10,20)` and does overlap
the text, so it resolves. This is **not** the blanket clamping Part 3 refused —
it never reaches beyond the single cell the user clicked, so a click in the
middle of the scroll-past-end padding still finds nothing across the whole cell
and still reports `none`. A test asserts exactly that.

Probing is horizontal only. A cell is about as tall as a rendered line, so
probing vertically could answer from the line above or below — a worse error
than the one being fixed. The hit descriptor carries `cellSnapped` so the
difference between "the pointer was over this" and "the pointer's cell
overlapped this" stays visible in `:MdViewerDebug`.

### 4. The preview still scrolled on click

The previous fix consumed the echo record on its first check. That was not
enough, because **one cursor move produces more than one event**: clicking a
preview line whose source line is off screen moves the cursor, which scrolls the
source window, so `CursorMoved` is followed by `WinScrolled` — and
`controller.lua` routes both into `sync.source_cursor`. The first consumed the
record; the second found it gone and scrolled the preview.

The record now survives being checked and is dropped only once the cursor is
somewhere else. An echoed event also adopts the block the cursor landed in
(`last_source_block`) without scrolling to it, so the *next* keyboard move —
even one inside the block just clicked — does not look like a block change and
scroll the preview after all.

The net behaviour is stronger than "don't scroll when the target is already
visible", which is what was asked for: **a click never scrolls the preview at
all**, and normal cursor-follow syncing resumes the moment the user moves the
cursor themselves.

Both fixes have tests confirmed to fail against the previous code — the cell
test by forcing the probe list back to the centre alone, the echo test by
restoring the consume-on-check version. A headless end-to-end run against a real
Chromium confirms both against `README.md`: the first addressable cell of the
`## Features` heading resolves to `F` with `snapped=true`, and neither the
`CursorMoved` nor the `WinScrolled` that follow a click moves the preview, while
a cursor move the user makes still does.

Suite totals: **382 Lua assertions**, **97 Node tests**, stylua clean.

**Confirmed on real hardware by the operator** — see "Operator confirmation"
immediately below, which supersedes this section's original caveat.

---

## Operator confirmation of the four post-Part-5 fixes

The operator reported all four findings against a real terminal and has
confirmed all four are fixed there:

1. Clicking outside the rendered text no longer throws.
2. Clicking text no longer scrolls or re-renders the preview.
3. The first character of a line is now selectable.
4. The `CursorMoved` + `WinScrolled` pair from a click no longer moves the
   preview.

This is the first **real-terminal** validation of Part 5's click path: a human
clicked, and the cursor landed where they expected. It supersedes the
"unconfirmed" caveats in the two sections above.

**What this does *not* cover.** The operator confirmed the four reported bugs,
not the full "Operator verification" checklist in
`prompts/part-5-source-provenance.md`. Specifically, **the multibyte cases
(`日本語`, `🎉`) remain unconfirmed by eye.** That is still the highest-value
open item in Part 5: those are the cases where a wrong UTF-16→UTF-8 conversion
would put the cursor a few columns off without anything crashing, and no
automated test in this repository can prove where a real click lands on real
hardware. The conversion is covered by `tests/node/utf.test.js` and by
browser-backed provenance tests, so the risk is bounded — but it is not zero,
and it is not the same claim.

Also unchanged: Kitty, Ghostty, Warp, and every Linux terminal remain
graphically unvalidated for the whole project.


---

## Safe stopping point and first next action

The tree is green: all four policy §5 commands pass (348/348 Lua assertions,
61/61 Node tests, stylua clean), and `:MdViewerDebug` plus the actual installed
`<LeftMouse>`/`<LeftRelease>` keymap callbacks have been invoked directly in
headless sessions per policy §5 — not just the library functions underneath
them. Part 4 is commit `e3139e8` on `feat/interaction-transport`, a
branch cut from `main` (where Parts 1–2 landed via PR #1). Neither the branch
nor this doc commit has been pushed, and no PR has been opened.

Part 4 is the first part a human can actually see working, and the automated
verification here is real but structurally bounded: it proves dispatch,
coordinate math, the transport round trip, and cursor movement are wired
correctly against a stubbed renderer and a headless Neovim instance. It does
not and cannot prove a real click in a real graphical terminal lands where a
human's eye expects — see "Known limitations" above and the manual steps in
`prompts/part-4-mouse-and-navigation.md`'s "Operator verification" section.

**First next action for Part 5:** read `prompts/part-5-source-provenance.md`
fresh (`/clear` first per `prompts/README.md`; that part recommends planning and
implementing with Opus 5 throughout). Part 5 can rely on these settled
contracts from Part 4:

- `interaction.move_source_cursor(session, { line, byte_column, precision })`
  is the landing point for exact provenance — it already clamps and validates
  correctly for `line`/`block` precision, and Part 5 only needs to start
  feeding it real (non-zero) `byte_column` values.
- Every click already resolves through `activate_at`, and
  `result.sourcePosition.precision` is asserted `never "exact"` today by both
  `tests/node/interact.test.js` (Part 3) and this part's Lua tests — Part 5
  should either update or add to those assertions once `exact` is real, not
  leave them silently describing stale behavior.
- `interaction.lua`'s pointer state (`pressed`, `press_cell`, `drag_started`,
  `newest_pending_drag_point`, `click_count`) and the button-scoped
  `captured`/`is_captured` capture model are the state machine Part 6 extends;
  Part 5 should not need to touch `interaction.lua`'s gesture handling at all,
  only the source-position precision it consumes.

---

## What Part 5 actually built

Exact source provenance: a click now reports the Markdown **line and UTF-8 byte
column** it came from, wherever markdown-it's own parse state can establish one,
and degrades to `line` / `block` / `none` where it cannot.

Two new renderer modules, four changed, one Lua file changed (two real bug fixes,
both described below — neither was part of the plan).

### The approach, and why this one

markdown-it publishes `token.map` for block tokens and **nothing** for inline
ones. Three approaches were considered:

1. **Instrument markdown-it's inline parser in place** — chosen.
2. A second position-aware pass aligned against the token stream — rejected.
   Re-scanning a line for a token's rendered text collides the moment a block
   contains the same word twice (`apple banana apple`), and collides *silently*.
3. A third-party markdown-it plugin exposing inline positions — none found that
   is both maintained and small enough to audit.

Swapping parsers was forbidden and was not considered.

The instrumentation is three layers, each testable on its own:

**Layer 1 — span capture (parse time).** `renderer/src/provenance.js` wraps every
rule in `md.inline.ruler`. Each token records `[start, end)` **within its own
inline token's `content` string**, taken from the parser's cursor rather than by
searching. Two facts from `rules_inline/state_inline.mjs` and
`parser_inline.mjs` make it work:

- `StateInline.push()` flushes `pending` *before* creating its token, so a text
  run's span is `[pendingStart, state.pos)` — the run being closed and the token
  being opened share one `pos`, which is what keeps the spans from overlapping.
- `pendingStart` is captured on rule entry whenever `state.pending === ""`. The
  `text` rule is tried first on every tokenize iteration, so this fires before
  any character can accumulate — including through `tokenize`'s own
  `state.pending += state.src[state.pos++]` fallback, which appends outside any
  rule and would otherwise be unobservable.
- Tokens a rule pushes directly get `start` at push time and `end` when that rule
  returns true. A token a nested rule already closed keeps its own tighter end.

Silent (validation-mode) rule calls are passed straight through and record
nothing — they move `state.pos` speculatively.

Recorded spans are deliberately allowed to be *wider* than the token's content:
the `newline` rule trims trailing spaces off `pending` before pushing a break,
and `link` moves `pos` onto the label before flushing the text in front of `[`.
Both leave the content as a prefix of the slice, which layer 3 accepts.

**Layer 2 — line alignment (core rule).** An inline token's `content` is
*derived* from its source lines: block rules strip a prefix (indent, `>`, `-`,
`1.`, `#`) and the enclosing `.trim()` strips the ends. `alignLine()` anchors the
derived line against the end of its source line first — the only test that stays
correct when the derived text occurs twice on one line — then falls back to a
**unique** `indexOf` (which is what makes `## Heading ##` work), then gives up.
The search window moves forward only, inside `[map[0], map[1])`, which absorbs
lines that vanished before inline parsing: `alertPlugin` strips a whole `[!NOTE]`
line off a blockquote's content, so its content line 0 belongs to source line
`map[0] + 1`.

**Layer 3 — reconciliation (render time).** The renderer rules compare each
token's *final* content against its recorded source slice and accept one of three
alignments — `startsWith`, `endsWith`, or a unique interior `indexOf` — all of
which guarantee `slice.slice(base, base + rendered.length) === rendered`, so the
offset mapping is a plain identity. Anything else emits **no region at all**.

Doing this at render time rather than at parse time is what makes plugin
mutations self-correcting: `markdown-it-task-lists` slices four characters off a
list item's text long after layer 1 ran, and the `endsWith` branch shifts the
base instead of reporting a column four positions to the left.

### The two markdown-it rules that had to be replaced

`fragments_join` (inline ruler2) and `text_join` (core) both **merge adjacent
text tokens**, which would leave the survivor carrying only the last fragment's
span. Both are replaced with span-aware copies via `Ruler.at()`, which throws
`Parser rule not found` if either name ever moves — so a markdown-it upgrade
fails loudly at construction rather than silently reporting stale columns. A test
also renders a stock parser and the same parser with provenance installed and
asserts the HTML is **identical** once the added attributes and wrappers are
stripped.

`text_join` has one deliberate behavioural difference: it does **not** merge
across an entity or escape. `&amp;` is five source characters rendering as one
and `\*` is two rendering as one; merging either into the surrounding prose would
make the whole merged run's offsets non-linear and the run would have to be
discarded. Keeping them separate costs one extra `<span>` and keeps exact
provenance for the prose *and* for the entity.

### What the DOM carries, and what it does not

Every rendered text run becomes `<span data-md-source-id="sN">`; `code_inline`,
`img`, and every block element get the attribute directly. The id is **opaque**
— a test asserts every id in the markup matches `^s\d+$`. The mapping lives in
`markdownCache` in Node memory, written and evicted with the markup it describes
so the two can never disagree about which render they belong to.

Inline spans do not affect layout or whitespace collapsing, and this was verified
rather than assumed: `collectBlockGeometry()` for `kitchen-sink.md` produces the
**same 30 blocks and the same 1953px document height** before and after.
`data-source-start`/`data-source-end` are untouched.

`data-md-source-id` is allowlisted on `"*"`, alongside the block attributes,
because provenance lands on essentially every tag. A `rawHtml: true` document can
forge one, and the bounded consequence is that it sends its own click somewhere
else *within itself* — the same exposure `data-source-start` already had. Ids are
validated by lookup, so a forged key that does not exist resolves to nothing.

### Source map shape

```js
{ version: 1,
  lines: [...],            // markdown-it-normalized source lines, 0-based
  regions: {
    s7:  { kind: "inline", mapping: "identity", line, startCol16, len16 },
    s8:  { kind: "point",  mapping: "point",    line, startCol16 },
    s12: { kind: "code",   mapping: "lines",    startLine, columns, lengths },
    s3:  { kind: "block",  mapping: "block",    line, endLine },
  } }
```

Lines are **0-based throughout the source map**, on purpose: the single 0→1
conversion stays in `interact.js:resolveSourcePosition()` where Part 3 put it, so
there is exactly one `+ 1` in the whole chain. `byteColumn` is a 0-based byte
offset, matching `nvim_win_set_cursor()`.

Regions store columns, not text; the normalized source lines are stored once per
document and every byte column is computed against them.

### UTF-16 → UTF-8

`renderer/src/utf.js` is separate, pure, and has no markdown-it or DOM
dependency, so a provenance failure can be localised to a layer.
`utf16ToByteOffset()` clamps, snaps a caret that split a surrogate pair **back**
onto the character (snapping forward would skip a character the user clicked
directly on), then sums per-code-point widths. `byteToUtf16Offset()` is the
inverse and exists so the tests can check round-trips rather than spot values;
every case is cross-checked against `Buffer.byteLength`.

### Precision policy

| Situation | Result |
|---|---|
| identity region, caret offset present | `exact`, mapped offset |
| point region (an image) | `exact` at the construct's first character |
| code-block region, caret offset present | `exact`, line and column inside the fence |
| any region, **no** caret offset | `line` at that region's own line |
| no region, block spans one source line | `line` (unchanged from Part 3) |
| no region, block spans several lines | `block` (unchanged) |
| no block | `none` (unchanged) |

The distinction in row 4 caught a real bug during development: `Number(null)` is
`0`, so an element-only hit — which carries no caret — briefly claimed `exact` at
column 0. The offset is now required to be strictly a number.

### Fenced and indented code blocks

Included at the operator's decision. A fence's `token.content` is the source
verbatim apart from the block's own indent, so each rendered line maps straight
back — but only if **every** line matches, which is checked line by line at build
time rather than assumed. `getLines()` re-expands a deeper indent as *spaces*, so
a tab-indented line inside a fence fails the check and the whole block degrades
to `block`, honestly. The in-page offset walk sums text nodes across highlight.js's
syntax spans, so a click lands correctly several nodes in — there is a browser
test that specifically asserts the target text node was preceded by others.

### Table cells

markdown-it gives a table cell's inline token **no map at all** (only the table,
thead, tbody and tr tokens get one — `rules_block/table.mjs`). An inline token
with no map of its own now borrows the innermost enclosing block's. That widens
the search window; it does not weaken the check, because the alignment must still
match a real source line unambiguously — a row with two identical cells degrades
rather than guessing. This was not in the plan; it was found by dumping the
fixture's regions and noticing the table produced none.

---

## Two latent bugs from Part 4, found by Part 5's verification

Both were invisible while every byte column was 0. Both are user-facing. Neither
was found by the automated suites — they were found by running the real thing.

### 1. Every unmodified click was silently refused

`vim.json.encode({})` produces `[]`, not `{}`. `validateEnvelope` rejects an
array for `modifiers` with `INVALID_INTERACTION`, and `interaction.lua`'s
callback does `if err or not result then return end`. So from Part 4 until now,
**every plain left-click sent `modifiers: []`, was refused by the renderer, and
did nothing at all.** Ctrl/Cmd-click worked, because it passes a populated table
that encodes as an object.

Three things hid it: the Lua table looked correct, the Lua tests stub
`process.request` and so never encode anything, and the failure path is a silent
`return`. `interaction.request_hit()` now states all four modifiers explicitly so
the table can only encode as an object, and the test asserts the **encoded wire
form**, not the Lua table.

### 2. `move_source_cursor` read a field name that never arrives

It read `position.byte_column`; the renderer sends `byteColumn`. The cursor
therefore always went to column 0 — which was the correct answer for every
column Part 4 could produce, so nothing failed. It reads `byteColumn` now, with
`byte_column` kept as an alias so Part 4's own tests still pass.

Both bugs are the same lesson this project already learned once with
`:MdViewerHealth` in Part 1: a library function passing its unit tests is not the
same claim as the real path working.

---

## Tests run and results (Part 5)

```
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
  -> added 30 packages, 0 vulnerabilities

NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
  -> md-viewer Lua tests: 360 assertions passed (348 at the end of Part 4)

npm test --prefix renderer   (node --test ../tests/node/*.test.js)
  -> tests 96, pass 96, fail 0   (61 before this part)

stylua --check lua/ plugin/ tests/lua/
  -> clean (no diff)
```

The 35 new Node tests split into 7 for the UTF converter in isolation and 28 for
provenance, of which 27 need no browser at all — they call `renderMarkdown()` and
`resolveRegionPosition()` directly, so a failure names the layer that broke. The
browser-backed one drives real Chromium and `t.skip`s with a named reason if no
executable is discoverable, matching the pattern from Part 1.

Test material is in `tests/fixtures/provenance.md` (new).
**`tests/fixtures/kitchen-sink.md` was deliberately not edited** —
`tests/node/interact.test.js` hardcodes its block line ranges.

Per policy §5, `:MdViewerDebug` was invoked as the actual command in a headless
session and renders `interaction_last_precision = "exact"` across 84 lines with
no embedded newlines (the Part 1 crash class).

**Beyond the policy §5 minimum**, a headless script drove a real click through
the real transport — Lua → NDJSON → Node subprocess → Chromium → back → cursor —
sweeping x across the rendered `Some **bold text** and a [link label](...) here.`
paragraph. The resolved source columns advance monotonically with x (…24, 26, 28,
30, 32, 33, 34, 36) and then **jump from 36 to 59**, correctly stepping over the
`](https://example.com)` that renders as nothing. The source cursor landed on
exactly the reported byte. This is the script that found both Part 4 bugs above;
the plugin's own controller could not be used, because headless auto-selection
lands on the `cells` backend, which never invokes the browser.

---

## Known limitations and unresolved risks (Part 5)

- **No graphical validation was performed.** This environment has no attached
  graphical terminal (`TERM_PROGRAM=vscode`, unchanged from every prior part).
  The end-to-end check above proves the conversion, transport, and cursor
  movement against a real browser; it does **not** prove that a click a human
  makes with a mouse in a real Kitty/iTerm2/WezTerm session lands where their eye
  expects, because no code path here can synthesize a real terminal mouse report.
  Per policy §4 this is stated as unvalidated. The manual steps are in
  `prompts/part-5-source-provenance.md` under "Operator verification" and are the
  highest-value open item in this part.
- **Auto-linkified bare URLs degrade to line/block precision.** markdown-it's
  core `linkify` rule replaces the text token containing the URL with tokens it
  builds itself, which carry no recorded span. Per the operator's decision the
  rule is **not** replaced; the degradation is narrowly scoped (the prose on
  either side of the URL in the same paragraph stays exact) and is covered by a
  dedicated test. `deriveSpan()` in `provenance.js` is the documented, tested
  seam for changing this later: a span-aware linkify replacement calls it to give
  its rewritten tokens real spans. Explicit `[label](url)` links are unaffected
  and exact.
- **Task-list item text has no provenance.** `markdown-it-task-lists` with
  `labelAfter` discards the item's text token and rebuilds the text inside a raw
  `html_inline` `<label>`, so no text token survives to carry a span. Reported as
  `block` honestly. Fixing it would mean forking or replacing the plugin.
- **Multi-line inline code degrades.** markdown-it rewrites the newline in
  `` `a\nb` `` to a space, so the rendered run matches no single source line.
  Rejected rather than approximated; tested.
- **A NUL byte in the source shifts every byte column after it on that line.**
  markdown-it's `normalize` rule replaces `\0` with U+FFFD (1 byte becomes 3) and
  `token.map` indexes the normalized text, so the columns are measured against
  it. Pathological and untested against a real buffer. CRLF is a non-issue —
  `controller.lua` builds the markdown from `nvim_buf_get_lines`, which never
  includes `\r`.
- **The normalized source lines are cached per document**, up to the existing
  LRU of 64. That is roughly one extra copy of each document in the renderer
  process, alongside the HTML already cached there. Regions themselves store
  columns, not text.
- **`__rules__` is a markdown-it internal.** Enumerating the inline rule names
  needs it; there is no public enumeration. Guarded by an explicit named throw if
  the shape ever changes, by `Ruler.at()`'s own "Parser rule not found", and by
  the identical-output test. markdown-it is pinned at 14.3.0.
- Carried forward and unchanged: the CI matrix's Ubuntu leg is still untriggered;
  the `config.setup()` reassign-before-validate quirk is still unfixed;
  `terminal.probe = "safe"` is still unimplemented; Windows discovery remains
  unadvertised; Kitty, Ghostty, Warp, and all Linux terminals remain graphically
  unvalidated for the whole project.

---

## Decisions that changed assumptions in the original specification (Part 5)

- **The parser is instrumented, not reimplemented.** The part prompt's first
  candidate approach ("hook the inline token stream and track `state.pos`") is
  what shipped, but the obvious mechanism — copying `ParserInline.tokenize` so
  the loop can be observed — turned out to be unnecessary. Wrapping the ruler's
  rules gives the same two observation points (`pendingStart` on entry, `end` on
  success) without duplicating any parser logic, because the `text` rule runs
  first on every iteration.
- **Two markdown-it rules are replaced, and that was not anticipated by the
  prompt.** `fragments_join` and `text_join` merge text tokens; without
  span-aware copies every merged run would report its last fragment's position.
  This is the single largest source of upgrade risk in the part and is guarded
  three ways (see above).
- **Fenced-code and table-cell provenance were added.** Fences on the operator's
  explicit decision; table cells because the fixture dump showed markdown-it
  gives cell inline tokens no map, and borrowing the enclosing row's map makes
  them exact for the price of four lines. Neither was named in the prompt.
- **Entities and escapes are kept as separate rendered runs**, a deliberate
  divergence from markdown-it's `text_join`. See above for why.
- **`data-md-source-id` is allowlisted on `"*"`, not per tag.** The plan called
  for a tighter per-tag list, matching Part 4's heading-`id` posture. It was
  written and then reverted: block regions put the attribute on essentially every
  rendered tag, so the "tight" list was the whole allowlist with extra steps and
  the same exposure the existing `data-source-*` entries already have.
- **Part 4's precision assertions were updated, not deleted**, as the prompt
  required. The pure `resolveSourcePosition(block)` sweep stays — block-only
  resolution still cannot be exact, and that is the point. The interaction sweep
  is now the inverse claim: every label is one of the four honest ones, a claimed
  column is inside the line it names, and at least half the fixture's blocks
  resolve exactly.
- **One Lua file changed** (`interaction.lua`), which the prompt predicted would
  not be necessary ("the Lua side should need no change beyond accepting real
  byte columns"). It was necessary for two reasons neither of which is about
  accepting columns — see "Two latent bugs from Part 4" above.

`prompts/part-6-selection-and-search.md` was edited: its "Verified repository
facts" now records the empty-table-encodes-as-array trap (Part 6 adds more
envelope fields and will hit it), that Part 5 has run so search match positions
can be exact, and that `move_source_cursor` reads `byteColumn`. No part boundary
moved. `prompts/part-7-hardening-and-docs.md` needed no edit — its compatibility
matrix already lists "exact source columns" as a row to fill in.

---

## Safe stopping point and first next action

The tree is green: all four policy §5 commands pass (360/360 Lua assertions,
96/96 Node tests, stylua clean), `:MdViewerDebug` has been invoked as a real
command in a headless session, and a real click has been resolved end to end
through the real renderer subprocess and real Chromium.

**The one thing that has not been done is the manual check, and for this part it
matters more than for any other.** A wrong byte column does not crash; it puts
the cursor in the wrong place, in exactly the cases nobody tests by hand. Run
"Operator verification" in `prompts/part-5-source-provenance.md` in a real
graphical terminal before building on top of this — the multibyte cases (`日本語`
and `🎉`) are the ones that matter, because being a few columns off there means
the UTF-16→UTF-8 conversion is wrong.

**First next action for Part 6:** read `prompts/part-6-selection-and-search.md`
fresh (`/clear` first per `prompts/README.md`). Settled contracts it can rely on:

- `result.sourcePosition` is `{ line (1-based), byteColumn (0-based bytes),
  precision }` where precision is `exact`, `line`, `block`, or `none`, and
  `result.hit.sourceId` is the opaque key of the region that was hit.
- `resolveRegionPosition(sourceMap, sourceId, offset)` in
  `renderer/src/provenance.js` is the only resolver; it returns a **0-based**
  line, and the single conversion to Neovim's 1-based lines is in
  `interact.js:resolveSourcePosition()`.
- `hitTestInPage` returns `inline: { sourceId, offset, textLength }`, where
  `offset` is the caret's position within the whole region — summed across text
  nodes, which is what makes highlighted code blocks resolvable.
- Any optional map in an envelope must always carry a key or use
  `vim.empty_dict()`, and its test must assert the encoded wire form.

---

## What Part 6 actually built

The headline feature: dragging over rendered text creates a real Chromium
`Selection`, painted natively by the browser and captured into the same PNG
the user sees; `y` (or `:MdViewerCopy`) copies it to Neovim registers; and
`/`/`n`/`N` (or `:MdViewerFind*`) search the rendered document with match
navigation. All nine of Part 3's reserved actions
(`selection_preview`/`commit`/`clear`/`text`, `word_select`,
`find_set`/`next`/`previous`/`clear`) are now implemented; `RESERVED_ACTIONS`
in `renderer/src/interact.js` is `[]`.

### Renderer: seven new page-evaluate functions, all self-contained

`renderer/src/interact.js` gained `resolveSelectionInPage`,
`readSelectionTextInPage`, `clearSelectionInPage`, `wordSelectInPage`,
`setFindInPage`, `stepFindInPage`, `clearFindInPage` — each a second,
independent `page.evaluate` body alongside `hitTestInPage`, dispatched from
`browser.js`'s new `evaluateAction()`/`buildResult()` pair rather than a
single hardcoded call.

**A real bug found and fixed during this part, worth recording precisely
because it is exactly the trap this part's own "Verified repository facts"
warned about for something else:** the first implementation declared the
~140-line cell-probe/caret-resolution routine (`resolveSelectionPoint`) and
the direction-aware `applySelectionRange` as ordinary top-level functions in
`interact.js`, called from `resolveSelectionInPage` and `wordSelectInPage`.
Every Node-side unit test that stubs `globalThis.document` passed, because
those tests call the exported function directly in the same JS module.
Against a real page, every one of them threw `ReferenceError:
resolveSelectionPoint is not defined` — `page.evaluate(fn, arg)` serializes
only `fn.toString()` and evaluates it standalone inside the page, with no
access to sibling module-scope functions. This is stated as a design
constraint in `hitTestInPage`'s own header comment and was reasoned through
correctly during planning, then violated anyway during implementation because
the two helpers were extracted for tidiness without re-checking that
constraint. The fix (now the actual shape of the code) is to declare
`resolveSelectionPoint`/`applySelectionRange` as *nested* functions inside
each of `resolveSelectionInPage` and `wordSelectInPage` (duplicated between
the two), and `unwrapFindMarksInPage` nested inside both `setFindInPage` and
`clearFindInPage` for the same reason. Only the real, browser-backed tests in
`tests/node/selection.test.js` caught this — the pure/stubbed-DOM tests could
not, structurally, since they never go through Playwright's actual
serialization path. Recorded here as a concrete instance of "a library
function passing its unit tests is not the same claim as the real path
working," the lesson this project has now hit for the fourth time (Parts 1,
4, 5, and this).

**A second real bug, found the same way:** `setFindInPage`/`stepFindInPage`
call `element.scrollIntoView({block:"center"})` to bring the active match into
view, but the result object they returned never reported the page's resulting
`window.scrollY` — `browser.js`'s `interact()` had already computed
`result.scrollY` from `ensureDocumentActive`'s *pre*-mutation applied scroll
position, and nothing overwrote it afterward (unlike `activate_at`'s fragment
scrolling, which already does exactly this via `scrollToFragment`'s return
value). The screenshot itself was correctly scrolled — `captureViewport()`
photographs whatever the page currently shows — so this was invisible in any
test that only checked the PNG; it was caught by
`tests/node/find.test.js`'s "a match far down the document scrolls into view"
test asserting on `result.scrollY` directly. Both find page-evaluate functions
now return `scrollY: window.scrollY`, and `browser.js`'s `interact()`
overwrites `result.scrollY` (and `this.active.scrollY`) with it whenever a raw
result carries one — the same pattern the fragment-scroll code already used,
just not yet generalized to the second caller that needed it.

**A third bug, found by the Node integration suite rather than by hand:**
moving `interactionStateFor(...)` (which creates an entry if none exists)
earlier in `dispatchInteract`'s task — needed so `find_next`/`find_previous`
could read the prior match set before calling `browser.interact()` — meant a
request that ultimately *fails* (a never-rendered document, a stale revision)
now fabricated a fresh, empty interaction-state entry for it anyway, since the
call ran unconditionally before the success/failure was known. The existing
`tests/node/interact.test.js` cross-document-isolation test caught this
immediately (`interactionDocuments` read 2 instead of 1 after an edit that
should have dropped exactly one document's state). Fixed by splitting the
function in two: `peekInteractionState(documentId, contentRevision)` is a
non-mutating read used only to forward `find_next`/`find_previous`'s prior
match set into `cached.findState`, and the original, mutating
`interactionStateFor` moved back to running only after a successful
`browser.interact()` call, exactly where it ran before this part. Only a
successful interact may create or touch interaction state — recorded as an
explicit invariant in a comment at the call site now.

### Renderer: action registry, result shaping, and the `matches` cap

`INTERACT_ACTIONS` (`renderer/src/interact.js`) now has eleven entries. The
nine new ones add `requiresAnchor` (`selection_preview`/`selection_commit`,
validated against a new `anchorCoordinates` envelope field) and
`requiresQuery` (`find_set`, validated against a new, `.trim()`-normalized
`query` field). `selection_text` is the only new action with
`mutatesVisibleState: false` — it re-reads `window.getSelection().toString()`
live rather than trusting any cached state, and `main.js`'s `dispatchInteract`
explicitly excludes it from writing `state.selection` so a copy can never
"commit" a selection that was only ever previewed.

`find_set`'s page-side match list is capped at `MAX_FIND_MATCHES_REPORTED`
(500, alongside the existing `TEXT_PREVIEW_LIMIT`) — DOM highlighting still
marks every match regardless (a correctness requirement), but a document with
thousands of hits for a common word must not serialize thousands of per-match
source positions through Playwright's evaluate channel on every keystroke.
`matchCount` always reports the true total. The resolved (capped) array itself
never reaches Lua: `main.js` reads it once into `state.find.matches` (for
`find_next`/`find_previous` to resolve their active match against) and
`delete`s it from the outward-facing `result` before returning — Lua only ever
sees `matchCount`/`activeIndex`/`activeSourcePosition`.

Search highlighting uses `Text.splitText` plus programmatically created
`<span data-md-viewer-find-mark>` wrappers — never `innerHTML` — inserted
directly into the live page DOM at interact time. This is *after* and
entirely outside `renderer/src/markdown.js`'s one-time `sanitizeHtml()` pass
(confirmed by reading the code: sanitization runs exactly once, at initial
render, cached alongside the source map, never again), so no sanitizer
allowlist change was needed — the same way the existing
`data-md-viewer-doc` token attribute on `<html>` already bypasses it. Query
matching is a lower-cased `String.prototype.indexOf` loop, never
`new RegExp(...)`, so HTML and regex metacharacters in a query are inert by
construction rather than by escaping.

New CSS custom properties `--find-mark-bg`/`--find-mark-active-bg` in both
theme files, consumed by two new rules in `preview.css`
(`[data-md-viewer-find-mark]` / `[...][data-active]`). The real DOM
`Selection` needs no CSS at all — `Selection.setBaseAndExtent()` (preferred;
falls back to a `Node.compareDocumentPosition`-ordered `Range` only on an
engine that lacks it, which the bundled Chromium never does) is what makes
Chromium paint the highlight itself, satisfying the "do not draw your own"
requirement structurally rather than by discipline.

### Reverse dragging and element-boundary normalization

`setBaseAndExtent(anchorNode, anchorOffset, focusNode, focusOffset)` tracks
direction natively, so reverse (right-to-left or bottom-to-top) dragging needed
no special-case logic — `tests/node/selection.test.js`'s backward-selection
test asserts the extracted text is identical regardless of drag direction,
which is the strongest available proof that direction is handled by the
primitive and not accidentally by argument order. When a point resolves to a
block but no caret (padding between inline runs, or space past a short line's
last character, both still inside the block's own box), `resolveSelectionPoint`
picks a text boundary — start or end of the block's rendered text — by
comparing the click x-coordinate to the clicked element's bounding-rect
midpoint, rather than reporting a miss: a selection endpoint must always
resolve to *something*, unlike a hit-test miss. A point genuinely outside every
block (the page's own padding) still honestly misses (`anchor_miss`/
`focus_miss`), matching `hitTestInPage`'s existing "none" semantics for the
same region — verified as two separate tests, not conflated into one.

### Lua: the drag→selection backpressure chain

`lua/md-viewer/interaction.lua`'s `session.pointer` gained `anchor_point` (the
drag's fixed start, set once on the first threshold crossing),
`word_select_fired`, and `pending_settle`. `M.schedule_selection_preview`
mirrors `controller.schedule_scroll`'s exact one-in-flight/one-coalesced-
pending shape (`pointer.selection_request_in_flight`, always sending
`pointer.newest_pending_drag_point`, never a fixed frame rate), debounced by
the new `interaction.drag_debounce_ms` (default 40) via
`debounce.call(session, "selection_debounce_timer", ...)`. Release routes the
final device-scale frame through `M.settle_selection`, which shares the same
`selection_request_in_flight` guard as preview — if a preview is still
in-flight when release fires, the settle request is deferred via
`pointer.pending_settle` and picked up by that preview's own completion
callback rather than racing a second request against it — debounced again by
`interaction.settle_ms` (default 120), mirroring `scroll_settle_ms`'s role in
`schedule_scroll`.

Double-click word selection dispatches from `M.on_press` (not `on_release`):
`<2-LeftMouse>` was already routed there with `click_count = 2` by Part 4, and
a real double-click resolves synchronously on mousedown, matching this.
`pointer.word_select_fired` tells the matching `on_release` not to also
perform a click-to-source navigation. `interaction.word_select = false` (the
gate is independent of `interaction.double_click`, which still controls
whether `<2-LeftMouse>` is mapped at all) falls through to exactly today's
single-click-shaped behavior on release — unchanged, per the part prompt's
explicit "keep it selectable" requirement, and regression-tested.

### Lua: selection/find state is split from pointer/capture state, on purpose

`session.selection_active`, `selection_content_revision`, `find_active`,
`find_query`, `find_match_count`, `find_active_index` are new session fields
(`lua/md-viewer/state.lua`), deliberately **not** part of the button-scoped
`session.pointer` table and **not** touched by the existing `TabLeave`/
`VimSuspend` autocmd (`controller.lua`) that calls `interaction.forget()` to
drop pointer capture. §6.3 requires selection to survive preview focus
changes, which is in direct tension with reusing that autocmd's existing
cleanup call — a new `interaction.forget_selection(session)` is the Lua-side-
only (no renderer request) reset for this state, called from three places:
`controller.close_session`, `controller.M.refresh`'s success path when
`session.selection_content_revision` disagrees with the just-updated
`session.renderer_revision` (dropping a stale-revision selection in the same
tick new content lands, before it is ever displayed), and a new
`process.on_exit` listener registered once in `controller.setup_autocmds()`.

`lua/md-viewer/process.lua` gained `M.on_exit(callback)` — a process-lifetime
listener list, fired from the spawn's existing `on_exit` handler alongside the
pre-existing `deliver_error()` call. `deliver_error` already correctly fails
every outstanding *request* callback on a renderer crash or restart; what was
missing was a hook for *session-level* Lua display state that is not tied to
any specific in-flight request — the renderer's own in-memory
`interactionState` (Node-side) does not survive a process restart at all,
since it is a plain `Map` in the now-dead process, so the Lua-side cached
flags describing it would otherwise go stale silently. `tests/lua/cases/
selection.lua`'s "cleanup on renderer restart" test spawns the real
subprocess (the same pattern `tests/lua/cases/process.lua` already
established for `ping`), registers a listener, calls the real
`process.stop()`, and asserts the listener actually fires.

### Lua: copy, commands, and keymaps

`interaction.copy_selection(session, silent)` always issues a live
`selection_text` request rather than trusting any cached string, writes the
unnamed register unconditionally and `+` only when `vim.fn.has("clipboard") ==
1` — Neovim's own configured clipboard provider decides what actually happens
there; md-viewer never shells out to `pbcopy`/`xclip`/`wl-copy`/`clip.exe`
itself. The notification reports a character count, never the text.
`copy_on_select` (new, default `false`) is read once per successful
`selection_commit`/`word_select` response, not on every drag-preview frame.

Six new commands (`lua/md-viewer/commands.lua`): `:MdViewerCopy`,
`:MdViewerClearSelection`, `:MdViewerFind [query]` (prompts via
`vim.ui.input` — the first use of that API anywhere in this codebase,
confirmed by grep before using it — when called with no argument),
`:MdViewerFindNext`, `:MdViewerFindPrevious`, `:MdViewerFindClear`, each a
thin wrapper in `controller.lua` (`M.copy`/`clear_selection`/`find`/
`find_next`/`find_previous`/`find_clear`) resolving the current session and
delegating into `interaction.lua`. Five new preview-local mappings
(`lua/md-viewer/navigation.lua`): `y`, `/`, `n`, `N` (each gated by its own
`interaction.*` config flag) and `<Esc>` (always installed, so it can fall
through cleanly to normal Neovim `<Esc>` behavior — replayed via
`nvim_feedkeys`+`nvim_replace_termcodes` — regardless of which features are
enabled). `interaction.escape(session)` implements the §6.6 precedence: clear
an active find, else clear the selection, else return `false` for the caller
to fall through.

### Lua: displaying an interact-returned frame

`controller.lua` factors the backend-display logic that used to live inline in
`M.refresh`'s success branch into a shared local `apply_image(session,
image_bytes, capture_scale, png_bytes, capture_ms)`, used both by `M.refresh`
(render/capture path, unchanged call sites) and by a new
`M.display_interact_result(session, result)` (the interact path). Every
mutating selection/find action always captures its own PNG in the same queued
operation it mutated in (`envelope.capture` is forced by `mutatesVisibleState`
— unchanged machinery from Part 3, now exercised by nine real actions instead
of zero); `display_interact_result` is the fetch-and-display half Lua needs
for that PNG, since interact requests bypass `renderer.lua`'s request/response
envelope entirely (`interaction.lua` calls `process.request("interact", ...)`
directly, exactly as `request_hit` already did before this part).
`renderer.lua`'s private `read_bytes` local is now the exported
`M.read_png(path, limit)`, used by both paths.

### Configuration

```lua
interaction = {
  ...,
  selection = true,
  drag_debounce_ms = 40,
  settle_ms = 120,
  copy = true,
  copy_on_select = false,   -- disabled by default, per the part prompt
  word_select = true,
  find = true,
}
```

Validated with the same per-field `assert(type(...) == ..., "md-viewer:
interaction.<name> ...")` pattern every other field already uses.

---

## Tests run and results (Part 6)

```
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
  -> added 30 packages, 0 vulnerabilities

NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
  -> md-viewer Lua tests: 479 assertions passed (382 at the end of Part 5's
     post-commit fixes; +97 from the new tests/lua/cases/selection.lua and the
     expanded config-validation/wire-form sections of tests/lua/cases/interaction.lua)

npm test --prefix renderer   (node --test ../tests/node/*.test.js)
  -> tests 125, pass 125, fail 0   (96 before this part; +29 from the new
     tests/node/selection.test.js and tests/node/find.test.js, net of the two
     interact.test.js tests rewritten for the now-empty RESERVED_ACTIONS)

stylua --check lua/ plugin/ tests/lua/
  -> clean (no diff)
```

All four commands were run on this development machine (macOS, Apple Silicon,
Neovim 0.12.4, Node 24, Google Chrome installed at the standard `/Applications`
path). The browser-backed Node tests in `selection.test.js`/`find.test.js`
drive a real Chromium subprocess through the real renderer, matching the
established `t.skip(...)`-if-no-Chromium pattern from every prior part.

Per policy §5, all six new commands were invoked directly as commands — not
as library functions — in a headless session, following a single combined
script:

1. `:MdViewerOpen` against `tests/fixtures/kitchen-sink.md` (headless
   auto-selection lands on the `cells` backend, as in every prior part).
2. `:MdViewerCopy`, `:MdViewerFindNext`, `:MdViewerFindClear`,
   `:MdViewerClearSelection` invoked immediately, **before any selection or
   search had ever been created** — the state the part prompt explicitly
   calls out as most likely to be under-tested. All four notified cleanly
   (`vim.log.levels.WARN`, "nothing selected" / "no active search") with no
   error, and no register was touched.
3. The session's backend was then swapped to a fake graphical-shaped stub
   (`clear`/`show`/`update`/`move` recording calls only — the same technique
   `tests/lua/cases/mouse.lua` already uses to exercise the non-cells code
   path without an attached TUI) and `controller.refresh()` was called
   directly, driving a **real** render through the real renderer subprocess
   and real Chromium (`session.renderer_revision` became non-nil).
4. `:MdViewerFind Kitchen` against that real render found exactly one match
   (`tests/fixtures/kitchen-sink.md` line 1, `# Kitchen Sink` — confirmed
   present by `grep` before choosing it, rather than assumed) —
   `find_active = true`, `match_count = 1`, `active_index = 0` — a genuine
   Lua → NDJSON → Node subprocess → Chromium → back round trip, not a stub.
5. `:MdViewerFindNext`, `:MdViewerFindPrevious`, and `:MdViewerFindClear`
   all completed without error against that real, active search
   (`find_active` correctly became `false` after the clear).
6. `:MdViewerCopy` against the real renderer (with no DOM selection ever
   made) notified cleanly rather than erroring.
7. `:MdViewerFind` with **no** argument correctly invoked the `vim.ui.input`
   prompt (confirmed via a stubbed `vim.ui.input` that recorded the call and
   simulated cancellation) and did not error. **This is the one part of the
   six commands' surface that could not be exercised end-to-end** — a
   headless session cannot type into the prompt, so only "does not error
   while the prompt's callback never fires" is proven, not the prompt's
   interactive UX itself. Stated honestly as unvalidated for that specific
   path, per policy §4.
8. `:MdViewerClearSelection` against the real renderer completed without
   error.

No crash, no unhandled error, anywhere in this sequence.

**No graphical validation was performed.** This development environment has
no attached graphical terminal (`TERM_PROGRAM=vscode`, unchanged from every
prior part). The headless verification above proves the transport, the
backpressure chain, the six commands, and a real search round trip are wired
correctly; it does not and cannot prove a real drag in a real terminal paints
a moving highlight, that reverse dragging looks correct to a human eye, or
that dragging feels responsive rather than stepwise — see "Operator
verification" in `prompts/part-6-selection-and-search.md`.

---

## Known limitations and unresolved risks (Part 6)

- **No graphical validation was performed for this part's own work.** The
  entire drag-to-select experience — the moving highlight, reverse-drag
  correctness, copy-then-paste, double-click word selection, and search
  responsiveness — is unvalidated in a real terminal, as of this part's own
  commit. This is the single highest-value open item before Part 7.
- **A selection cannot survive its document being swapped out of the single
  shared page.** Discovered while writing `tests/node/selection.test.js`'s
  cross-document-isolation test: rehydrating document A back into the shared
  page after document B took it over is a real `page.setContent()` reload
  (Part 3's architecture; no page-per-document), which destroys any live
  `window.getSelection()` state that referenced A's now-gone DOM nodes. This
  is architecturally honest — A's *old* selection is gone rather than
  resurrected from a stale reference, and B's selection never leaks into A —
  not a bug, but it means §6.3's "selection survives preview focus changes"
  should be read as covering a single session's own Neovim-side focus
  changes (tab leave, window switch), not surviving being displaced by a
  second, independently-interacting preview session sharing the same
  renderer process. A fresh selection on the rehydrated document works
  normally immediately afterward; the test asserts this explicitly.
- **The `Range`-fallback path in `applySelectionRange` is untested against
  real engine behavior.** `Selection.setBaseAndExtent()` has shipped in every
  Chromium version this project could plausibly bundle (since Chrome 27), so
  the fallback branch is realistically unreachable and exists only so a
  future engine swap fails safely instead of throwing outright.
- **`Intl.Segmenter` availability for word-select is assumed, with a regex
  fallback.** `tests/node/selection.test.js`'s word-select test does not hard-
  fail if the bundled Chromium lacks it; nothing in this project's supported
  range should, but it is not independently verified per-platform.
- **The `matches` array a `find_set` response carries internally is capped at
  500** (`MAX_FIND_MATCHES_REPORTED`). DOM highlighting still marks every
  match; a document with more than 500 matches for one query will still
  report the true `matchCount` and step through every match correctly via
  `find_next`/`find_previous` (the DOM `data-md-viewer-find-mark` elements are
  the actual source of truth for stepping), but `activeSourcePosition` for a
  match past the cap resolves to `null` rather than a real position, since
  its descriptor was never resolved on the Node side. Not expected to matter
  in practice — a search returning 500+ hits in one document is not a
  realistic "find the thing I'm looking for" use case — but stated here
  rather than left implicit.
- Carried forward and unchanged: the CI matrix's Ubuntu leg is still
  untriggered; the `config.setup()` reassign-before-validate quirk is still
  unfixed; `terminal.probe = "safe"` is still unimplemented; Windows discovery
  remains unadvertised; Kitty, Ghostty, Warp, and all Linux terminals remain
  graphically unvalidated for the whole project; the multibyte click-precision
  cases (`日本語`, `🎉`) from Part 5 remain unconfirmed by eye on real hardware.

---

## Decisions that changed assumptions in the original specification (Part 6)

- **`selection_preview` and `selection_commit` share one page-side
  implementation** (`resolveSelectionInPage`), differing only in the
  `captureScale` field the envelope already carried before this part. Two
  action *names* still exist because Lua's two call sites — mid-drag versus
  on-release — are genuinely distinct moments (only a commit should be
  treated as "the" selection for `state.selection` purposes), but there was
  no reason to duplicate the DOM/range-resolution logic itself.
- **Point-resolution helpers (`resolveSelectionPoint`, `applySelectionRange`,
  `unwrapFindMarksInPage`) are duplicated as nested functions inside every
  page-evaluate function that needs them, not shared as module-level
  siblings.** Not anticipated by the part prompt's file list, and initially
  implemented wrong (see "What Part 6 actually built" above) before the
  browser-backed test suite caught it. This is the single most consequential
  correction this part made to its own first draft.
- **Renderer-restart cleanup is a new `process.on_exit(callback)` listener
  registry in `process.lua`, not a generation counter threaded through every
  session field.** `deliver_error()` already correctly fails in-flight
  requests; the gap was specifically session-level display state with no
  associated in-flight request, and a listener list is the smaller, more
  direct fix.
- **Selection/find state is a new, separate set of session fields, explicitly
  excluded from the existing `TabLeave`/`VimSuspend` cleanup autocmd.** Not
  stated explicitly in the part prompt, but required by §6.3's own wording —
  reusing `interaction.forget()` (pointer/capture cleanup) for this too would
  have cleared a valid selection on every tab switch, which is exactly what
  that section forbids.
- **A `find_set` response's per-match position array is capped at 500 and
  never crosses the Lua boundary at all** — a constraint the part prompt did
  not name, added after reasoning about what a common-word search against a
  large document would otherwise serialize on every keystroke. `matchCount`
  and DOM-side stepping remain correct past the cap; only a match's exact
  reported source position past index 500 is affected. See "Known
  limitations" above.
- **`interactionStateFor`'s mutating create-if-missing behavior had to be
  split from a new, non-mutating `peekInteractionState`** so that
  `find_next`/`find_previous`'s need to read prior match state before calling
  `browser.interact()` did not also mean a failing interact request
  fabricates interaction state for a document it never successfully touched.
  Not anticipated by the plan; found by the existing Part 3 cross-document-
  isolation test, which is exactly the kind of regression coverage it was
  written to catch even for later parts' changes.

No part boundaries moved. No downstream prompt needed edits — Part 7's stated
approach (regression pass, security review, compatibility matrix,
documentation) is unaffected by anything discovered here; nothing in this
part's implementation invalidates Part 7's own scope as written.

---

## Safe stopping point and first next action

The tree is green: all four policy §5 commands pass (479/479 Lua assertions,
125/125 Node tests, stylua clean), and all six new `:MdViewerCopy`/
`:MdViewerClearSelection`/`:MdViewerFind`/`:MdViewerFindNext`/
`:MdViewerFindPrevious`/`:MdViewerFindClear` commands have been invoked
directly as commands in a headless session per policy §5 — including a real
end-to-end search round trip through the real renderer subprocess and real
Chromium, and the two "no active state" edge cases the part prompt calls out
by name. Part 6 is commit `c06f4bc` on `feat/interaction-transport`, a branch
cut from `main` (where Parts 1–2 landed via PR #1). Neither the branch nor
this doc commit has been pushed, and no PR has been opened.

**The one thing that has not been done is the manual check, and for this part
it is the entire point of the feature.** Nothing in this project's automated
suite — Lua or Node — can synthesize a real terminal mouse-drag sequence or
show a human whether a highlight visibly moves during a drag. Run "Operator
verification" in `prompts/part-6-selection-and-search.md` in a real graphical
terminal before treating drag-to-select as shippable: drag across a paragraph
and confirm a moving (not frozen) highlight, drag upward and confirm no
collapse, press `y` and paste elsewhere, double-click a word, search a
repeated term and cycle `n`/`N`, and confirm dragging feels responsive rather
than stepwise.

**First next action for Part 7:** read `prompts/part-7-hardening-and-docs.md`
fresh (`/clear` first per `prompts/README.md`). Part 7 can rely on these
settled contracts from Part 6:

- `INTERACT_ACTIONS` in `renderer/src/interact.js` has all eleven actions this
  project defines; `RESERVED_ACTIONS` is `[]` and is expected to stay that way
  unless a future part reserves something new.
- `interactionState` entries are `{contentRevision, selection, find, lastHit}`,
  where `selection` is `{text, collapsed, anchorSourcePosition,
  focusSourcePosition}` and `find` is `{query, matchCount, activeIndex,
  activeSourcePosition, matches}` (the last field internal-only; stripped
  before the wire response reaches Lua).
- `interaction.forget_selection(session)` is the single Lua-side reset point
  for selection/find display state; a future part adding any further
  session-level display state tied to the renderer's lifetime should extend
  it rather than invent a second cleanup path.
- `process.on_exit(callback)` exists now for exactly this kind of
  renderer-lifetime hook; a future part needing to react to a renderer
  restart should use it rather than polling `process.status()`.

---

## Post-Part-6 follow-up: click-to-source removed, click-to-deselect added

Commit `4cde042` on `feat/interaction-transport`.

Out-of-band UX change, not one of the seven parts, prompted by early-user
feedback (a click on the preview relocating the source cursor fought the new
drag-to-select gesture from Part 6 — dismissing a highlight by clicking
elsewhere also jumped the editor, which is not how VS Code's own Markdown
preview behaves: drag to select, click anywhere to deselect, no navigation
side effect).

**What changed**, after three explicit operator decisions:

1. **No click gesture moves the source cursor anymore, at all** — this
   includes ctrl/cmd-click's previous fallback (jump to source when the
   point wasn't over a link), not only the plain click. Ctrl/cmd-click still
   activates links; over non-link text it now does nothing.
2. **`interaction.click_to_source` and `interaction.focus_source_on_click`
   are removed outright** — not deprecated or kept-but-ignored. A config
   naming either now fails `config.setup()`'s validation with a message
   naming the removed option, the same way any other unknown/invalid
   `interaction.*` field already does.
3. **Copy stays manual** (`y` / `:MdViewerCopy`), unchanged from Part 6 — no
   auto-copy-on-select. Part 6 already writes to both `"` (unnamed/yank) and
   `+` (system clipboard, gated on `vim.fn.has("clipboard")`) on every
   explicit copy; nothing about copy itself needed to change.

**A plain click now**: with an active selection, clears it (`M.clear_selection`,
issuing a real `selection_clear` interact request); with nothing selected,
does nothing — no interact request at all, not even `activate_at`. Dragging
is completely unaffected (still creates and commits a real Chromium
selection, per Part 6).

### Code removed

`lua/md-viewer/interaction.lua`: `M.move_source_cursor` (the entire
UTF-8-boundary-clamping cursor-placement function) and `M.click` are deleted
in full — both are now unreachable, since their only callers
(`M.on_release`'s plain-click path and `M.activate`'s non-link fallback) were
themselves rewritten to no longer call them. `M.activate` now only ever calls
`record_result` + `M.activate_link` when the hit is a real link; a non-link
ctrl/cmd-click hit does nothing. `M.on_release`'s plain-click branch is
`if session.selection_active then M.clear_selection(session) end` — no
coordinate resolution needed, since VS Code-style deselection doesn't depend
on where the click landed. `sync.suppress_echo`/`sync_guard` are untouched;
`sync.lua`'s own `update_source_from_scroll` (the scroll-follow direction,
unrelated to clicking) still uses them independently.

`lua/md-viewer/config.lua`: `click_to_source`/`focus_source_on_click`
defaults and their two `assert(...)` validation lines are gone.

The renderer (`renderer/src/*.js`) is entirely untouched — `activate_at`'s
result shape is unchanged; ctrl/cmd-click for link detection still needs it,
so no protocol change was needed, only a Lua-side decision about which half
of the answer to act on.

### Tests

`tests/lua/cases/interaction.lua` lost ~190 lines: the "cursor movement"
block (UTF-8 byte-boundary clamping, `focus_source_on_click`) and the
"exact hit round-trips through the click path" block both existed solely to
test `move_source_cursor`/`M.click`, which no longer exist. The renderer-side
UTF-16→UTF-8 conversion this coverage depended on remains fully tested
independently in `tests/node/utf.test.js` — only the now-deleted Lua-side
*consumer* of that data lost coverage, which is the correct, unavoidable
consequence of deleting dead code, not a coverage regression to be concerned
about. The click test itself was rewritten to assert the new behavior (no
request when nothing is selected; `selection_clear` when something is), and
the wire-form modifiers-encoding assertion moved onto the ctrl/cmd-click path
— the only remaining caller of `request_hit`'s `modifiers` field.

Two Part 6 tests needed updating for the same reason, found by simply running
the suite rather than by inspection: `tests/lua/cases/selection.lua`'s
"`word_select = false` falls through to click-to-source" test asserted a
fallback that no longer exists (rewritten to assert no request at all — there
is nothing left to fall through to); a new end-to-end test was added
alongside it, driving a real drag→commit→click→clear sequence rather than
only unit-testing `on_release`'s branch in isolation.

`README.md`'s "Known beta limitations" section had one sentence fixed (it
still said preview text "cannot be selected, searched, copied, or interacted
with", which was already false as of Part 6 and doubly so now) — a targeted,
one-sentence correction, not the full documentation pass
`prompts/part-7-hardening-and-docs.md` explicitly owns.

### Verification

All four policy §5 commands pass (460/460 Lua assertions — down from 479 by
the expected net of deletions/additions above; 125/125 Node tests, unchanged
since the renderer was untouched; stylua clean). Per policy §5's standing
requirement to drive the actual installed command/gesture rather than trust
only the library function underneath it — precisely the class of change that
has bitten this project before (Part 4's silently-refused plain click, found
only by invoking the real `<LeftMouse>`/`<LeftRelease>` keymap callbacks
headlessly) — this change was verified the same way: a real graphical session
via `controller.open()` with a stubbed backend, the actual
`vim.fn.maparg(lhs, mode, false, true).callback` for `<LeftMouse>`,
`<LeftRelease>`, and `<C-LeftMouse>` invoked directly with stubbed
`vim.fn.getmousepos()`/`process.request`. Confirmed: a plain click with
nothing selected sends no interact request and never moves the cursor; a
plain click with an active selection sends `selection_clear` and still never
moves the cursor; ctrl-click over non-link text sends `activate_at` (needed
to determine there's no link) but does not move the cursor; ctrl-click over a
link still calls `vim.ui.open` with the correct URL.

**No graphical validation was performed** — this development environment has
no attached graphical terminal, unchanged from every part before it. The
headless verification proves the dispatch logic is wired correctly; it does
not prove that a real drag-then-click in a real terminal feels right to a
human, which is exactly the kind of thing this change exists to improve.
Operator confirmation on real hardware is the natural next step, the same as
every prior part's own "Operator verification" caveat.

## Post-Part-6 follow-up 2: triple-click paragraph select, sharp interact captures, and three scroll/copy bugs

Commit `8cd2e8a` on `feat/interaction-transport`.

A second out-of-band round of operator feedback, after real use of the
click-to-deselect follow-up above: one missing feature (triple-click) and
three bugs, two of which turned out to share a single root cause once traced.

**1. Triple-click paragraph selection (new feature).** Mirrors word_select's
own double-click path exactly: `lua/md-viewer/mouse.lua`'s `gestures()` now
adds `<3-LeftMouse>` (gated behind `interaction.double_click`, since Vim's own
click-count escalation requires `<2-LeftMouse>` to already be mapped before
`<3-LeftMouse>` will ever fire — it rides the same install gate rather than
inventing a second one); a new `interaction.paragraph_select` config flag
(default `true`) gates the runtime dispatch, matching `word_select`'s own
split between "is the mapping installed" and "does it actually fire". The
renderer side (`renderer/src/interact.js`) adds a `paragraph_select` action
and a `paragraphSelectInPage` page-evaluate function: it resolves the caret's
enclosing block exactly as `wordSelectInPage` does, but instead of expanding
to `Intl.Segmenter` word boundaries, it selects the block's full text (first
through last non-empty text node), via the same `setBaseAndExtent`-based
`applySelectionRange` helper. `renderer/src/browser.js` dispatches it and
routes its result through the existing `buildSelectionResult` — no new result
shape was needed.

**2. Blur during drag-select and right after clearing a highlight.** Every
`interact` request's capture quality was decided by `validateEnvelope`'s
`captureScale: envelope.captureScale === "device" ? "device" : "css"` —
defaulting to the low-res scale scroll's own fast-frame optimization was
built for, unless a caller explicitly opted into `"device"`.
`clear_selection`, `find_set`, `find_next`/`find_previous`, and `find_clear`
never set `captureScale` at all, so they silently inherited scroll's cheap
scale; the drag-preview path made it worse by *explicitly* requesting `"css"`
on every in-flight tick. Fixed by flipping the default (`captureScale:
envelope.captureScale === "css" ? "css" : "device"` — `"css"` is now the
opt-in, not the fallback) and changing the drag-preview call site to request
`"device"` outright. Scroll's own fast/settle mechanism
(`controller.schedule_scroll`) is a fully separate dispatch path that never
goes through `validateEnvelope`, so neither change touches its intentional
low-res-then-settle behavior.

**3. A stray content fragment after copying, and clicking to deselect near
the bottom jumping to the top — the same bug.** `M.copy_selection`,
`M.clear_selection`, `find_set`, `find_next`/`find_previous`, and
`find_clear` all built their `interact` request without a `scrollY` field.
`validateEnvelope` defaulted a missing `scrollY` to `0`, and `interact()`
applied it *unconditionally, before the requested action even ran*, via
`ensureDocumentActive` → `applyScroll` → a real `window.scrollTo(0, top)` on
the shared Chromium page — for every interact call, including read-only ones
like `selection_text` (copy) that never capture a screenshot of their own.
So pressing `y` to copy silently snapped the live page's actual scroll
position to the top as a side effect, even though copy's own result was
never displayed; whatever captured next did so against a corrupted position,
which is what produced the operator-reported artifact (a fragment from the
top of the document appearing where the bottom should have been, right as
the copy notification appeared). `clear_selection`'s identical omission
explained the separately-reported bug directly, since it *does* display its
own capture immediately.

Fixed with two changes: (a) all five omitting call sites in
`lua/md-viewer/interaction.lua` now send `scrollY = session.applied_scroll_y
or 0`, matching the pattern `word_select`/`request_selection`/`request_hit`
already used; (b) defense in depth in `renderer/src/browser.js` — a missing
`scrollY` now resolves to the document's own last known position instead of
`0` (`validateEnvelope` passes `null` through rather than defaulting, and
`ensureDocumentActive` falls back to the cached record's `scrollY`). Getting
(b) actually correct needed a third change beyond the plan's original scope,
found by the new regression tests below failing against real Chromium: the
record's own `scrollY` was only ever updated by `applyScroll`, not by the
separate `scrollIntoView`-driven correction `find_next`/`find_previous` apply
after `applyScroll` already ran — so the fallback could still answer with a
stale pre-`scrollIntoView` position. A new `rememberScrollY()` method keeps
`this.active.scrollY` and the cached record's `scrollY` in sync from every
mechanism that can move the shared page (`applyScroll`, find's
`scrollIntoView`, a fragment jump), not just `applyScroll` alone.

**4. The copy notification's register-summary suffix.** `M.copy_selection`
appended `' (" and +)'`/`' (" only)'` to its success notification — not
malformed, just noise the operator found confusing. Dropped; the message is
now length-only: `"md-viewer: copied N characters"`.

### Tests

Real-Chromium coverage in `tests/node/selection.test.js` and
`tests/node/find.test.js`: a new `paragraph_select` case asserting a triple
click selects a whole paragraph, not one word; regression tests that scroll a
real document, then call `selection_clear`/`find_clear` with no `scrollY`
field at all, asserting the shared page's real scroll position survives
rather than resetting to the top; `captureScale` assertions confirming
`selection_clear`/`find_set`/`find_clear` all now default to `"device"`.
`tests/node/interact.test.js`'s "envelope defaults are conservative" test
was updated for both flipped defaults (`scrollY: null`, `captureScale:
"device"`). Lua coverage in `tests/lua/cases/selection.lua` mirrors
word_select's own test shape for the new triple-click dispatch and its
`paragraph_select = false` disable case, plus `scrollY`/`captureScale`
assertions on every request table that changed.

### Verification

`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix
renderer`, the Lua headless runner, `npm test --prefix renderer`, and
`stylua --check` all pass (474/474 Lua assertions, 128/128 Node tests,
stylua clean). Per policy §5, the underlying Lua functions weren't trusted
alone: a real graphical session via `controller.open()` with a stubbed
backend and `require("md-viewer.navigation").attach`/`require("md-viewer.mouse").attach`
called by hand (`controller.open()` only attaches either when its
auto-selected backend isn't `"cells"`, which a headless environment always
selects), driving the actual installed `<LeftMouse>`, `<2-LeftMouse>`,
`<3-LeftMouse>`, `<LeftRelease>`, and `y` keymap callbacks via
`vim.fn.maparg(lhs, mode, false, true).callback`. Confirmed end to end: a
real triple click issues a `paragraph_select` request carrying the session's
actual `scrollY` and `captureScale: "device"`; a real drag's preview request
also asks for `"device"`, not `"css"`; a real plain click after an active
selection issues `selection_clear` carrying the session's real `scrollY`
(not a hardcoded `0`); and the real `y` keymap's notification reads exactly
`"md-viewer: copied N characters"` with no register summary.

**No graphical validation was performed**, unchanged from every part and
follow-up before it — this environment has no attached terminal. The
headless verification proves the dispatch and capture-quality logic are
wired correctly; it does not prove the rendered result looks sharp or feels
right to a human in a real iTerm2 session. Operator confirmation on real
hardware remains the natural next step.

## Post-Part-6 follow-up 3: the preview "rolled" whenever any notification popped up

Commit `37b18de` on `feat/interaction-transport`.

Operator report, after using the follow-up above on real hardware: pressing
`y` to copy, while a "snacks.nvim"-style floating notification was visible,
made the preview pane redisplay its *own already-shown, unchanged* image
shifted down by about one content row, with the row that had been below the
visible viewport wrapping around to appear at the top. Three diagnostic
questions to the operator ruled out the interact/scroll pipeline entirely:
the shift snapped back to correct the instant the notification closed, it
reproduced for *any* md-viewer notification (not only copy's), and
`laststatus=3` on the operator's system ruled out a `raw_statusline_guard_cells`
window-count interaction that had briefly looked like a candidate. That
combination pointed at the raw-Kitty image *placement* code, not rendering —
a re-display of unchanged bytes, not a wrongly-scrolled new capture.

**Root cause.** `controller.lua`'s `reconcile_placement`, run from a `WinNew`/
`WinClosed` autocmd and from the `ui_poll_ms` backend poll, recomputes
`preview.placement()` on every occlusion-relevant window event and calls
`session.backend.move()` (delete the old Kitty placement, re-crop and
re-place the image) whenever the freshly computed placement differs from
`session.last_placement` in *any* field — including `exclusions`, the
rectangle list `coordinates.passive_overlays` builds for every non-focusable
floating window that geometrically overlaps the preview (used so a click
landing on a notification doesn't resolve into the markdown underneath it).
A notification opening adds one exclusion; closing it removes one — neither
changes the image's actual on-screen row/col/width/height at all, yet the
old code re-cropped and redrew the image anyway. `kitty_raw.lua`'s
`place_regions`/`visible_regions` split the placement into multiple
independently-cropped regions around each exclusion and re-issue them as a
fresh set of Kitty placement IDs; that redundant delete-and-resplit cycle is
what was visible as the shift.

The fix didn't need to touch that crop-splitting logic at all, because it
turned out to be unnecessary for this case in the first place: every
terminal profile in `terminal.lua` sets the raw image's z-index to `-1`
(confirmed by grep, not assumed), meaning the image is *always* composited
strictly beneath normal terminal cell content. A floating window — with a
real background color, as virtually every float has — already visually
occludes the image without any crop at all. The `exclusions` list is only
ever actually consumed for click-resolution (`coordinates.cell_to_css`,
read via `session.last_placement.exclusions` in `interaction.locate`), never
for anything visual.

**Fix.** `reconcile_placement` now decides whether to call `backend.move()`
using a new `same_geometry` check — row/col/width/height only, deliberately
ignoring `exclusions` — instead of the old `coordinates.same` (which also
compared exclusions). `session.last_placement` is still unconditionally
updated to the freshly computed placement either way, so click-resolution
never goes stale; only the unnecessary visual re-crop is skipped. `coordinates.same`
itself is untouched (still exclusion-aware) since nothing else consumes it
after this change removed its one caller. The now-unused `coordinates`
import was removed from `controller.lua`.

### Tests

`tests/lua/cases/controller.lua` gained a direct regression test: with a
stubbed `kitty_raw` backend counting `move()` calls, opening a real
non-focusable floating window over the preview area (mirroring the existing
passive-overlay test just above it) waits for the autocmd-driven reconcile
to add an exclusion to `session.last_placement`, then asserts `move()` was
never called; closing the float is asserted the same way on the way back
down to zero exclusions.

### Verification

Lua headless suite: 479/479 assertions (up from 474 by this one new test).
`npm test --prefix renderer`: 128/128, unchanged — this fix never touches
the renderer. `stylua --check`: clean.

**No graphical validation was performed** — unchanged from every part and
follow-up before it. The regression test proves `backend.move()` is no
longer invoked for a passive float's own exclusion change, which is the
mechanism identified as the cause; it does not independently re-prove the
visual artifact is gone in a real iTerm2 session, since headless tests
cannot observe actual Kitty graphics compositing. Operator confirmation on
real hardware remains the natural next step, same as the reports above that
led to it.

## Post-Part-6 follow-up 4: the preview stayed put, unmoved, when a third-party plugin's own splits took over the screen

Commit `8ead804` on `feat/interaction-transport`.

Operator report, confirming the previous fix worked but surfacing a new,
distinct issue while testing on real hardware: pressing `<leader>gd` to open
`codediff.nvim`'s diff/explorer view left the old preview image sitting on
screen at its old size and position, visibly overlapping the new diff panes,
until closing the diff view again. Traced by reading `codediff.nvim`'s
actual installed source (`~/.local/share/nvim/lazy/codediff.nvim`, found via
the operator's own dotfiles repo) rather than guessing at a third-party
plugin's behavior: its `ui/lib/split.lua` opens each pane with
`vim.api.nvim_open_win(bufnr, false, { split = position, win = -1 })` — a
plain, non-floating split, "relative to editor" so it resizes the *whole*
tabpage's existing layout, including md-viewer's own preview split, as an
immediate side effect of opening.

**Root cause.** `controller.lua`'s `WinNew` autocmd only called
`reconcile_occlusion()` (which computes a fresh placement and, since the
prior follow-up above, calls `backend.move()` when geometry actually
changed) for a *floating* window (`win_config.relative ~= ""`). A plain
split — exactly what `codediff.nvim` opens — was filtered out of this path
entirely. The only other thing that could have caught the resulting
geometry change was the separate `WinResized`/`VimResized` autocmd, or,
failing that, the `ui_poll_timer` background poll (default every 50ms) —
neither is guaranteed to run before the user's own eyes register the stale,
overlapping frame.

**Fix.** `WinNew` now calls `reconcile_occlusion()` unconditionally, for any
new window, floating or not.

### Tests

Verified this genuinely closes the gap, not just plausibly: added a
regression test in `tests/lua/cases/controller.lua` that opens a real,
non-floating split (`split = "left", win = -1`, mirroring `codediff.nvim`'s
own call) sized to shrink the preview window, and asserts `backend.move()`
gets called. Confirmed the test is meaningful the same way Part 4's original
click-dispatch bug was: reverted the fix locally (`git stash`), re-ran the
suite, watched this exact test fail (`backend.move()` never called), then
restored the fix and watched it pass.

### Verification

Lua headless suite: 481/481 assertions (up from 479 by this one new test).
`npm test --prefix renderer`: 128/128, unchanged — this fix never touches
the renderer. `stylua --check`: clean.

**No graphical validation was performed** — unchanged from every part and
follow-up before it. The regression test proves the specific mechanism
identified (a plain split's `WinNew` alone reconciling the preview's
geometry) now works; it does not independently re-prove the visual glitch is
gone in a real `codediff.nvim` session on real hardware, since headless
tests cannot observe actual Kitty graphics compositing or interact with a
real third-party plugin's live window-management timing. Operator
confirmation on real hardware remains the natural next step.

## Post-Part-6 follow-up 5: the preview was never being moved at all — it was stranded on a tabpage nobody could see

Commit `8ec3a31` on `feat/interaction-transport`.

Operator report, after follow-up 4 had already landed and been tested on
real hardware: `<leader>gd` still left the old preview image on screen at
its old size and position, overlapping `codediff.nvim`'s diff panes, for as
long as the diff view stayed open. Two screenshots showed the previous
markdown preview's headings, code block and bullet list at roughly full
scale, *visually interleaved* with the diff text so both were legible at
once.

**Follow-up 4's root cause was wrong, and this is the correction.** That
writeup was built on `codediff.nvim`'s `ui/lib/split.lua`, which does open
plain `{ split = position, win = -1 }` panes. But that is not how the view
is created. `lua/codediff/ui/view/side_by_side.lua`'s `M.create()` — the
function `:CodeDiff` actually reaches, via the `<leader>gd` mapping in the
operator's own `plugins/codediff.lua` — begins with `vim.cmd("tabnew")` and
splits *inside that new tabpage*. The preview split was therefore never
resized, never repositioned, and never overlapped by anything: it was parked
on a tabpage the terminal had stopped displaying, while the image it owned
stayed composited at absolute screen coordinates.

**Root cause.** Nothing in the raw-image display path can detect that. This
was verified headlessly rather than assumed: for a window sitting on a
background tabpage, `nvim_win_is_valid`, `nvim_win_get_position`,
`nvim_win_get_width`/`_get_height` and `vim.fn.screenpos` *all* keep
reporting full, valid, completely unchanged on-screen geometry, exactly as
if it were visible. That is harmless for anything Neovim draws itself, since
a hidden tabpage simply is not composited to the grid — but a raw Kitty
placement is absolute screen coordinates the *terminal* keeps compositing
until explicitly told to stop. Every guard the code had was blind to it:

- `preview.occlusion` → `coordinates.overlapping_floats` →
  `floating_windows` scopes its search to `nvim_win_get_tabpage(ignored_win)`,
  i.e. the preview's *own* tabpage. It never sees the visible tabpage's
  windows at all, so it reported no occlusion.
- `same_geometry` compared equal, correctly — the geometry genuinely had not
  changed.
- `valid(session)` passed, because the window really is still valid.

`TabLeave` did delete the placement. Then four independent paths each
re-showed it, at the hidden tabpage's coordinates, over whatever the visible
tabpage was drawing: the `WinNew` autocmd (which `vim.cmd("tabnew")` fires,
and which follow-up 4 had just made unconditional), `WinResized` →
`reconcile_occlusion`, the 50ms `ui_poll_timer`, and `CompleteDone` →
`refresh_raw_sessions`. All four call `show_cached`, which asks
`update_occlusion` for permission and was told yes. Confirmed each one
individually by deleting the `WinNew` autocmd at runtime and watching the
others resurrect the image regardless — which is exactly why follow-up 4's
change neither fixed the symptom nor visibly altered it. The one path that
was already correct is the `WinEnter`/`BufEnter`/`TabEnter` autocmd, which
carries a hand-written `nvim_win_get_tabpage(...) == nvim_get_current_tabpage()`
guard; that guard existed nowhere else.

This also accounts for every detail of the report that the "stale geometry"
theory did not: the image was at its *old* size and position because the
placement was never wrong, and it reverted the moment the diff view closed
because returning to the preview's tabpage makes the same coordinates
correct again.

**Fix.** A new `coordinates.window_is_displayed(win)` answers the one
question no other window API will, and it is checked in `update_occlusion` —
the single predicate every show/restore/re-place path already funnels
through, so all four resurrection paths close at once. `reconcile_placement`
checks it directly as well, because the `CmdlineEnter`/`CmdlineLeave`
callers re-place unconditionally (`force = true`, follow-up in
`cmdline_placement.lua`) without any occlusion check of their own.

Two supporting changes fall out of it:

- A render that aborts because the image cannot be displayed now sets
  `session.refresh_deferred`, and `show_cached` replays it on restore.
  Without this the fix would trade one bug for another: a debounced render
  landing just after `:CodeDiff` used to complete (onto the wrong tabpage,
  but it did update `session.last_image_bytes`), and would now be silently
  dropped, leaving a permanently stale frame on the way back. The same
  applies to a discarded interact PNG, which never reaches
  `last_image_bytes` at all.
- `TabLeave` now clears through `clear_image` instead of hand-rolling it, so
  the dropped placement goes with the image — `interaction.locate` resolves
  clicks against `session.last_placement`, and there is no longer an image
  on screen for one to land on.

`:MdViewerDebug` reports `tabpage_hidden` and `refresh_deferred`, so "the
preview is blank and nothing looks wrong" has a visible answer next time.

### The z-index contradiction, resolved

Follow-up 3 justified skipping the re-crop with: every profile sets
`raw_zindex = -1`, therefore the image "is *always* composited strictly
beneath normal terminal cell content", therefore a float with a background
color already occludes it. **That reasoning is wrong**, and it contradicted
two things already in this repo — `docs/architecture.md` ("keeps the image
below terminal text while remaining visible above the Neovim backgrounds
painted by iTerm2") and the operator's own `raw_zindex` config comment,
which says the same. In the Kitty graphics protocol a negative `z` above
`INT32_MIN/2` draws the image below text *glyphs* but **above** cell
background colors; only `z < INT32_MIN/2` goes under backgrounds too. So a
blank or background-only cell does not occlude a `z = -1` image.

This bug's own screenshots are direct evidence on real iTerm2 hardware: the
diff panes are a fully painted Neovim screen, and the markdown image showed
through them legibly.

Two consequences, recorded rather than acted on:

- It does **not** weaken this fix. The image had to be deleted, not
  re-cropped or repositioned, and that is what happens now.
- It does mean follow-up 3's skip can let the image bleed through a passive
  notification's blank cells. Follow-up 3's *effect* is still operator-
  confirmed correct (the roll stopped), and its cause — `place_regions`
  re-splitting into a fresh set of placement IDs on every exclusion change —
  is real. Restoring an unconditional `move()` would just bring the roll
  back. The real fix, if the operator confirms bleed-through under
  notifications, is to make the re-crop itself non-rolling (an atomic
  place-then-delete in `kitty_raw.move`, which is currently two separate
  non-atomic `nvim_ui_send` calls). **This needs the operator's eyes before
  anyone changes it** — it is not something headless testing can see.
  `same_geometry`'s comment in `controller.lua` was corrected in place, and
  the stale passive-overlay sentence in `docs/architecture.md` with it.

### Tests

New case, `tests/lua/cases/tabpage_placement.lua`, reproducing the real
mechanism rather than the assumed one: `vim.cmd("tabnew")` followed by an
explorer-style `{ split = "left", win = -1 }` sidebar and a `rightbelow
vsplit` diff pane inside it, exactly mirroring `side_by_side.lua`'s
`M.create()`. It asserts the geometry lie explicitly (the hidden window
still reports its old row/col/width/height), then that no path shows or
re-places the image while the tabpage is hidden, that a forced
`CmdlineEnter` re-place is refused too, and that closing the diff tab
restores the image exactly once, on the right tabpage, at the right
coordinates.

Confirmed meaningful the same way follow-up 4 was, but more carefully:
`git stash`-ing the whole fix only made the test error on the missing
`window_is_displayed` helper, which proves nothing about behavior. So the
helper was left in place and only the two behavioral guards were neutered
(`local hidden = false and ...`). The suite then failed on the assertions
that matter — including `the image is restored on the tabpage that actually
owns the preview / expected: 1, actual: 2`, i.e. the image drawn onto the
diff tab, which is the reported bug reproduced as a test failure. Restoring
the guards turned them green.

### Verification

Lua headless suite: 505/505 assertions (up from 481 by this one new case).
`npm test --prefix renderer`: 128/128, unchanged — this fix never touches
the renderer. `stylua --check`: clean. Baseline measured before any change,
so all three numbers are attributable.

**No graphical validation was performed**, unchanged from every part and
follow-up before it. What is proven headlessly is stronger than in
follow-up 4 — the bug itself was reproduced end to end before the fix (the
image re-shown at tabpage 1's coordinates while tabpage 2 was current) and
the full round trip verified after — but it is still Lua-level state, not
real Kitty compositing in a real iTerm2 session. The z-index conclusion
above rests on the protocol specification plus this bug's own screenshots,
not on a fresh hardware experiment. Operator confirmation remains the
natural next step, and the specific open question to test alongside it is
whether the raw image bleeds through a passive notification's blank cells.

## Post-Part-6 follow-up 6: the Markdown composited straight through every notification's background

Operator report, with two screenshots (`2026-08-06 22:11`/`22:12`): a
snacks.nvim notification rendered over the preview "obstructs part of the
markdown render view", and should be "strictly just the border and the inside
content, without it obstructing anything else". The operator located it
precisely on a follow-up question — the cutoff runs along the preview's winbar,
the tab that shows the source file's name, with the notification sitting at that
same level and "the border or something above the border" occluding it.

**This is the open question follow-up 5 ended on** ("whether the raw image
bleeds through a passive notification's blank cells"), and the operator's own
screenshots answer it: it does.

**Evidence.** Both screenshots contain the same tell, readable straight off the
pixels. A snacks notification is three cell rows tall — border, content, border
— and in both shots the top border row lands on the preview window's winbar row,
where there is no image behind it, while the lower two rows sit over the image.
The notification's background colour appears *only* on the winbar row:

| | winbar row (no image behind) | rows over the image |
| --- | --- | --- |
| error notification | `rgb(57,25,31)` — its own red `NormalFloat` | `rgb(30,30,30)` |
| info notification | `rgb(34,34,34)` — its own `NormalFloat` | `rgb(30,30,30)` |

`rgb(30,30,30)` is the rendered PNG's own background, the colour filling the
preview everywhere outside the notification (`rgb(24,24,24)` is the terminal
background outside the placement rectangle). So on every row where the image is
behind it, the notification loses its background entirely and the Markdown
composites through; only its border characters and its message glyphs survive,
because those are real text. That is the visual the report describes.

**Root cause.** Exactly the hole follow-up 3 left, and that its own corrected
comment already suspected. `coordinates.passive_overlays` computes the
notification's rectangle, `preview.placement` attaches it as an exclusion, and
`kitty_raw.lua`'s `visible_regions`/`subtract` know how to cut it out — but
`reconcile_placement` compared placements with `same_geometry`, which ignores
`exclusions` on purpose, so the cut-out was computed, stored on
`session.last_placement` for click-resolution, and *never sent to the terminal*.
Follow-up 3's reasoning for that skip — "z-index `-1` means the image is always
composited beneath normal terminal cell content, so a float's background already
occludes it" — is wrong, and these screenshots are the hardware evidence. In the
Kitty graphics protocol a negative z above `INT32_MIN/2` draws below text glyphs
but *above* cell background colours, which is precisely why the operator's own
config sets `raw_zindex = -1` with the comment that the image "must remain above
cell backgrounds while staying below text": iTerm2 paints the preview window's
own background, and an image under that would never be visible at all. The same
property that makes the preview work is what makes a notification transparent.

Follow-up 3's *effect* was still real — the roll it removed was real — but its
mechanism was the delete-then-place ordering inside `move()`, not the re-crop
itself. `M.move` deleted the old placement IDs in one `nvim_ui_send` write and
sent the replacements in a second, leaving the terminal with nothing to
composite for the gap in between; any redraw landing in that gap is the blink
that read as a roll.

**Fix.** Two changes, both prescribed verbatim by the corrected `same_geometry`
comment follow-up 5 left behind ("making the re-crop itself non-rolling (atomic
place-then-delete in `kitty_raw.move`), not restoring an unconditional `move()`
here"):

- `kitty_raw.lua`: `place_regions` is split into a pure `placement_sequences`
  (build the commands and their fresh placement IDs, send nothing) and a
  `deletion_sequences` helper. `M.move` now emits the replacement placements and
  the deletion of the ones they supersede as a **single** `nvim_ui_send` write,
  new first. Placement IDs are fresh on every call, so the two sets never
  collide while they briefly overlap, and no redraw can land mid-recrop.
- `controller.lua`: `same_geometry` is gone; `reconcile_placement` compares with
  `coordinates.same` again, which is exclusion-aware, so a passive float
  appearing or disappearing re-crops. `coordinates.same` had been left in place
  by follow-up 3 with no callers; it has one again.

The cut-out is exactly the float's outer box and nothing more, clipped to the
image. Verified against real Neovim geometry with a snacks-shaped float
(editor-relative, bordered, non-focusable, one content line) straddling the
winbar row: preview text area rows 2..28 / cols 40..79, notification box rows
1..3 / cols 46..79, one exclusion of rows 1..3 / cols 46..79, and the backend
paints exactly two regions — rows 2..3 cols 40..45 and rows 4..27 cols 40..79.
Every image cell except the notification's own box, and no image cell inside it.

### Tests

`tests/lua/cases/controller.lua`'s passive-float regression from follow-up 3 is
inverted, since its assertion encoded the bug: opening a non-focusable float now
asserts `move()` *is* called and that the placement handed to the backend
carries exactly one cutout, closing it asserts the same on the way back to zero,
and a new steady-state assertion pins that an unchanged placement still never
re-places (the 50ms poll recomputes constantly and must compare equal). Failure
was confirmed meaningful by restoring the geometry-only comparison and watching
it fail, then restoring the fix.

`tests/lua/cases/backend_kitty.lua` gained the ordering guarantee the anti-roll
argument now rests on: a `move()` is one write, and the new placement command
precedes the `a=d,d=i` deletion within it.

### Verification

Lua headless suite: 510/510 assertions (up from 505 by these cases).
`npm test --prefix renderer`: 128/128, unchanged — this fix never touches the
renderer. `stylua --check`: clean.

**No graphical validation was performed**, unchanged from every part and
follow-up before it — but the diagnosis is the first in this series to rest on
direct hardware evidence rather than inference: the bleed-through is measured off
the operator's screenshots, not deduced from the protocol spec. What is *not*
proven is the other half — that the atomic single-write `move()` keeps the roll
from follow-up 3 from returning now that re-cropping is enabled again. That is
terminal compositing behaviour and headless tests cannot observe it; the ordering
test proves only what bytes go out and in what order. Operator confirmation on
real iTerm2 is the natural next step, and the specific thing to watch is whether
a notification opening and closing over the preview still leaves the image
perfectly still.

**Out of scope, and worth stating plainly:** the notification overlapping the
preview's winbar at all is snacks.nvim's own placement — it positions
notifications at the top-right of the *editor*, which is where md-viewer's winbar
happens to be, and md-viewer cannot move a float another plugin owns. This fix
makes the notification opaque, so it reads as a clean box over the preview
instead of a smear of Markdown; moving it off the winbar row is a
`Snacks.notifier` configuration change on the operator's side.

## Post-Part-6 follow-up 7: the image sits half a cell left of the text grid, so every cut-out is misaligned

Operator report immediately after follow-up 6 landed, with a fresh screenshot and
then a second one after `:ThemeToggle` (chosen so the image's background is
high-contrast grey against a black editor background). Follow-up 6 is confirmed
working — the notification now paints its own background instead of showing the
Markdown through it — but the seam around it is still wrong: "you can clearly see
the odd areas where the snack notification interferes with the Markdown Render
pane."

**Evidence.** Both screenshots give the same measurement, and the high-contrast
one gives it unambiguously. The cell grid is 20px × 44px. Reading the image's
edges against the text grid:

| | image edge | text grid |
| --- | --- | --- |
| preview left edge | x=2 | x=11 |
| cut-out left edge | x=560 | x=571 (notification left) |
| cut-out right edge | x=1762 | x=1771 (notification right) |

A constant ~10px at columns 0, 28 and 88 — not accumulating drift, a fixed origin
offset — and the vertical origin exact (the image's first row starts at y=88, a
row boundary, with the notification's own rectangle starting at y=44). Visible as
a ~10px blank seam down the notification's left side and a ~10px strip of Markdown
painted over its right border cell.

**Root cause, and it is not ours.** md-viewer's cut-out is correct in cells; it
inherits a shift the terminal introduces. iTerm2 applies its horizontal window
margin to text but not to graphics placements, so every raw placement lands that
many pixels left of the grid the text is drawn on. Nothing in the Lua math is
wrong, and nothing about snacks.nvim is involved — a float positioned anywhere
over the preview would show the same seam. Cursor addressing (`\27[{row};{col}H`)
is integral by construction, so this could never have been corrected by moving the
placement.

**Fix.** Two changes, one for the cause and one as a floor under it, because
whether a given terminal implements the protocol keys the first one needs is not
discoverable from Neovim.

- `image.raw_cell_offset_px = { x = 0, y = 0 }` — emitted as the Kitty graphics
  protocol's `X`/`Y` placement keys, the offset in pixels at which the image
  begins inside its first cell. Setting `x` to the measured margin cancels the
  shift outright. Applied in `placement_sequences`, so every cropped region
  carries it, not only the first — each region is positioned by its own cursor
  escape and so has its own first cell. Zero emits no `X`/`Y` at all, so every
  terminal that has not been calibrated receives byte-for-byte what it received
  before.
- `image.raw_overlay_bleed_cells = 1` — `coordinates.passive_overlays` widens each
  overlay rectangle by that many columns on its **trailing edge only**, clipped to
  the placement. Trailing-only because a window margin is never negative: the
  image can be offset toward the origin but never away from it, so it can only
  ever intrude on an overlay's right side, and widening the leading edge would
  double the gap on the other side while fixing nothing. Horizontal-only because
  the vertical origin measured exact and a blank row under every notification
  would be more conspicuous than the overhang it replaced.

With the bleed alone the result is an even ~10px gap either side of the
notification and no Markdown on it; with calibration also honoured the gap closes
entirely. `passive_overlays` grew a `bleed_cells` parameter rather than reading
config directly, keeping `coordinates.lua` the dependency-free geometry module it
has always been — `preview.placement` passes it, exactly as it already passes the
statusline guard. Both values are reported by `:MdViewerHealth`.

### Tests

`tests/lua/cases/coordinates.lua`: the bleed widens the trailing edge by the
requested columns while leaving `col`, `row` and `height` untouched, and is
clipped at the placement's right edge for an overlay that hugs it (which would
otherwise crop image the overlay does not cover).
`tests/lua/cases/backend_kitty.lua`: no `X`/`Y` when the offset is zero, both keys
present when set, and the count of `X=` keys equal to the count of placements so a
multi-region crop cannot be calibrated only on its first region.
`tests/lua/cases/config.lua`: defaults, and rejection of negative values for both.
`tests/lua/cases/controller.lua`'s existing cutout-width assertion now accounts for
the bleed and additionally pins that the leading edge never moves.

Verified end to end with the headless geometry probe from follow-up 6: for an
interior notification at cols 43..76, the cut-out comes back as cols 43..**77**
and the painted regions as cols 40..42 and 78..79 — one column later on the
trailing side, unchanged on the leading side.

### Verification

Lua headless suite: 530/530 assertions (up from 510 by these cases).
`npm test --prefix renderer`: 128/128, unchanged. `stylua --check`: clean.

**No graphical validation was performed**, unchanged from every part and follow-up
before it. The diagnosis is measured off the operator's screenshots rather than
inferred, and the bleed's effect is proven end to end headlessly. Two things are
not proven and need the operator's iTerm2:

1. Whether iTerm2 implements `X`/`Y` at all. If it does not, `raw_cell_offset_px`
   is inert there and the bleed is the whole fix — which is why the bleed defaults
   to on rather than being left for the user to discover.
2. Whether the offset is a constant margin or tracks cell width. 10px is exactly
   half of the 20px cell, so the two are indistinguishable from these screenshots.
   Changing the terminal font size once and re-measuring settles it; if it tracks
   cell width, the setting should be expressed as a fraction rather than pixels.

## What Part 7 actually built

Commit `26e637d`. Full regression, a real security review, complete
lifecycle-cleanup verification, expanded diagnostics, and a full
documentation pass across every doc file — turning six parts plus seven
post-Part-6 follow-ups into a `v0.3.0` release.

### 7.1 Full regression, and a real bug it found

Ran the full automated suite as a baseline (530/530 Lua, 128/128 Node,
stylua clean) before touching anything, then re-verified by hand the
behaviors earlier parts touched but did not own: initial rendering, unsaved
edits, cleanup, and backend fallback, each via a real headless command
sequence (`controller.open()`, a live buffer edit with no `:w`,
`controller.close()`, `backends.select()` in a TUI-less environment), not
just by re-running existing unit tests.

Building a new lifecycle test (`tests/lua/cases/lifecycle.lua`) that opened
two sessions in two different windows surfaced a genuine, real regression:
opening a *second* window with `nvim_open_win`/`:split` transiently
collapsed the two sessions into one. Traced to `controller.lua`'s
`WinEnter`/`BufEnter`/`TabEnter`/`VimResume`/`FocusGained` autocmd, which
reassigns `session.source_win` synchronously off `nvim_get_current_buf()`.
`:split other.md` (and, it turns out, even a bare `nvim_open_win(buf2, ...)`
call) fires `WinEnter` for the new window *while it still shows the window it
split from's buffer* — that is how `:split` works, before the buffer swap
that follows a moment later in the same command. The old code read
`nvim_get_current_buf()` at that transient instant and reassigned
`source_win` to the new window; nothing ever corrected it back, since the
*real* source window (still legitimately showing the source buffer) was
never touched again. Confirmed on real Neovim commands, not just the
`nvim_open_win` reproduction: `:leftabove vsplit /tmp/other.md` while a
preview was open for `/tmp/test1.md` left `session.source_win` pointed at
the new window showing the unrelated file, silently breaking
`WinScrolled`-driven cursor-follow in the window the user was actually still
working in.

**Fix.** The reassignment is now deferred one event-loop tick via
`vim.schedule`, re-reading `nvim_get_current_buf()`/`nvim_get_current_win()`
only once the whole compound command has settled — by which point a
`:split other.md` has already swapped in the new file, so the stale
`WinEnter`'s check (`current_buf == the buffer captured at fire time`) now
correctly fails and skips the reassignment, while a plain `:split` with no
buffer change (a legitimate case where the new window really does now show
the source buffer) still passes it. New regression test in
`tests/lua/cases/controller.lua`, confirmed to fail without the fix
(`git stash` the fix, watch `source_win` come back `1011` instead of the
expected `1000`, restore it).

### 7.2 Security review

Real attacks, not re-assertions of what Parts 3–6 already covered (which
turned out to be substantial: `classifyLink`'s unsafe-scheme rejection,
document-root/symlink containment for both image loading and local-file link
clicks, cross-document interaction isolation, and literal (non-HTML)
handling of search/selection text were all already tested end to end before
Part 7 began). What Part 7 added:

- `tests/node/security-runtime.test.js`: `javaScriptEnabled: false` actually
  stops a `<script>`/`onerror` handler from running, tested by handing
  `browser.js` a `<script>` tag directly — bypassing the sanitizer on
  purpose — to prove the *second*, independent layer holds even if the first
  ever had a bug. A second test attempts `page.goto()` to a real external
  URL (something no code path in `browser.js` ever does — confirmed by a
  companion structural test that greps `browser.js` for any navigating API)
  and confirms the network policy refuses it and the page never displays the
  external site's content.
- `tests/node/no-listening-port.test.js`: spawns the real renderer
  subprocess, forces a full real-Chromium launch, and diffs the system's
  listening-TCP-port list before and after (`lsof -iTCP -sTCP:LISTEN`) —
  asserting "no listening port" against actual OS state rather than against
  the absence of `net.createServer` calls in the source, which would miss a
  dependency (Playwright's own CDP transport, in particular) introducing one
  without any md-viewer code changing at all. Confirmed Playwright's local
  Chromium launch uses pipe transport, not a TCP debug port, on this
  platform.
- `tests/node/markdown.test.js`: arbitrary `data-*` attributes (beyond the
  four provenance keys the allowlist actually grants) and
  `javascript:`/`vbscript:`/`data:`/protocol-relative hrefs are stripped
  even when `rawHtml: true`.
- `tests/lua/cases/interaction.lua`: a symlink inside the document root
  pointing at a real file outside it is rejected for local-file link clicks
  (`security.resolve_local_link`), mirroring the existing Node-side
  `localImageDataUri` symlink test that only ever covered image loading.
- A parallel security-review agent independently read the full branch diff
  (`git diff origin/main...HEAD` plus the working-tree diagnostics changes)
  against the same threat model and found no additional concrete,
  exploitable findings — every high-risk surface it checked (path
  traversal, XSS-equivalent DOM injection, command injection, network-policy
  bypass, and the new `process.lua` error-metadata threading) was either
  read-only, already defended by the existing controls, or explicitly
  defended in the new code itself.

### 7.3 Cleanup and lifecycle

New `tests/lua/cases/lifecycle.lua` covers the paths nothing else exercised
end to end (TabLeave/VimSuspend and tab-hidden placement teardown were
already thoroughly covered by `tests/lua/cases/tabpage_placement.lua` via a
real `:tabnew`/`:tabclose`, which is what actually fires those autocmds):

- A real `BufWipeout` — on both the source buffer and the preview buffer
  independently — releases the session, clears the backend image, and
  restores mouse mappings once it was the last graphical session.
- A real `VimLeavePre` (`close_all`) sweeps *every* open session's image,
  calls each backend's own `clear_all()` as a backstop, restores mouse
  mappings, and stops the renderer subprocess — tested with two concurrent
  sessions, not one, so "every" is actually exercised.
- A `selection_preview` request still in flight when its session closes: the
  late-arriving callback does not error and does not resurrect any
  image/display state on the now-closed session — relying on the same
  pointer-identity check (`session.pointer ~= pointer`) the existing code
  already used for this, now with a regression test proving it holds across
  a real close.

No lifecycle-path *code* changes were needed beyond the `source_win` fix
above — `close_session`'s existing `valid()`/pointer-identity guards already
made every path safe; they were simply untested until now.

### 7.4 Diagnostics

`process.lua`'s `M.request` callback gained an optional third argument,
`meta = { code, detail }`, threading the renderer's machine-readable error
code (`protocol.js`'s `response.code`) through to Lua without changing any
existing two-argument callback's signature. `interaction.lua`'s new
`interact_request` wrapper is the only consumer: it counts every `interact`
request sent per session (`interaction_request_count`) and, by checking
`meta.code == "STALE_INTERACTION"`, separately counts how many lost a race
against a newer request (`interaction_stale_count`) — a real,
machine-readable classification rather than pattern-matching the
human-readable error string, which is what the codebase's one prior
precedent for this (`renderer.lua`'s `"capture cache missing"` string match)
would have required.

`coalesced_drag_events` counts a debounce firing while a prior
`selection_preview` request is still in flight (the point it would have sent
is dropped; whichever `on_drag` call produces the next point is what
actually gets sent once the in-flight one completes) — mirroring
`coalesced_scroll_events`'s existing role for scroll.

`selection_text_length` (never the text) is now recorded everywhere a
selection becomes active (`word_select`, `paragraph_select`, both drag-preview
and settle callbacks) and cleared everywhere one is dropped
(`clear_selection`, `forget_selection`) — wiring up a field
(`pointer.cached_selected_text`) that had existed, unused, since Part 6.

`:MdViewerDebug` now reports: `content_revision`, `selection_active`,
`selection_text_length`, `find_active`/`find_query`/`find_match_count`/
`find_active_index`, `interaction_request_count`, `interaction_stale_count`,
`coalesced_drag_events`, and the global `interaction_enabled` state.
`:MdViewerHealth` now reports `interaction_enabled` and, via the renderer's
existing `health` response (`browser.js`'s `activeDocument`/
`cachedDocumentFrames`, already computed but never surfaced to Lua):
`chromium_active_document`, `chromium_cached_document_frames`,
`chromium_cached_documents`, `chromium_lane_documents`,
`chromium_interaction_documents`. `:checkhealth md-viewer` gained an
`interaction_enabled` ok/warn line and an explicit note that Chromium's
active-document state is not queried by `:checkhealth` (it cannot await the
renderer subprocess) and is only available via `:MdViewerHealth`.

All three commands were invoked directly in a headless session (policy §5) —
not just their underlying `collect()`/`snapshot()` functions — with a real
preview open and synthetic selection/find state injected on the session, and
every new field rendered without error. `checkhealth` in particular was
driven exactly as `:checkhealth md-viewer`, per policy §5's standing
requirement, and confirmed clean (`checkhealth: checks done`, no error).

### 7.5 Manual compatibility matrix

`docs/manual-testing.md` was rewritten from a thin, single-terminal,
Part-1-era checklist (18 rows, all `PENDING`, iTerm2 only) into a repeatable
five-terminal (iTerm2, Kitty, WezTerm, Ghostty, Warp) procedure using the
four honest status labels, covering every scenario §7.5 lists. Every cell
defaults to `Protocol-compatible but unvalidated`, since this development
environment has no graphical terminal at all — no cell was marked
`Supported` on the strength of anything short of an actual human watching a
real screen, per policy §4.

The one nuance recorded explicitly: two real, historical operator
confirmations exist (iTerm2 and WezTerm, both from Part 2, both basic PNG
rendering only, both predating the interaction transport). The document
calls these out as scope-limited and superseded by everything Part 3 onward
added — every interaction feature and every raw-image placement fix (the
roll/blink fix, the notification bleed-through fix, the sub-cell
`raw_cell_offset_px`/`raw_overlay_bleed_cells` calibration) shipped with zero
graphical validation on any terminal, a fact each of the seven post-Part-6
follow-up writeups already stated individually; this document is the first
place it's stated as one honest, consolidated claim about the matrix as a
whole.

The passive-overlay alignment section records the two open questions
follow-up 7 left (does a given terminal implement the Kitty protocol's
`X`/`Y` keys; is the iTerm2 offset a constant margin or does it scale with
cell width) as a per-terminal table with one row filled in (iTerm2,
partially — the constant-vs-scaling question is explicitly unresolved) and
four rows unmeasured. **The pixels-vs-fraction decision `part-7-hardening-
and-docs.md` asked to be made before `v0.3.0` freezes the option was
considered and explicitly deferred, not resolved**: `raw_cell_offset_px`
ships as pixels, unchanged, because the single iTerm2 measurement cannot
distinguish the two theories and there is no second data point available in
this environment to decide with. This is recorded as real, open future work
in both `docs/manual-testing.md` and here, not silently punted.

### 7.6 Documentation

Every file `part-7-hardening-and-docs.md` named was updated. The largest gap
found: `doc/md-viewer.txt`, `docs/troubleshooting.md`, and `docs/security.md`
still described the pre-Part-3 product outright (`doc/md-viewer.txt` said
"Preview text is not selectable", which had been false since Part 6;
`docs/troubleshooting.md` referenced `:MdViewerSpikeStop`, a command that
does not exist — stale even at the time it was written, since the real
command is `:MdViewerClose`). Six parts of shipped interaction surface
(selection, search, copy, link activation, six new commands, an entire
`interaction.*` config block) were not documented in README.md's
configuration block, `doc/md-viewer.txt`, or `docs/architecture.md` at all
before this pass.

- README.md and `docs/architecture.md` now both lead with the exact raster-
  surface/synthetic-interaction distinction `part-7-hardening-and-docs.md`
  §7.6 specifies, verbatim, in a prominent position (README's top
  `[!IMPORTANT]` callout; architecture.md's opening blockquote).
  `docs/architecture.md` gained a full new "Interaction" section (staleness
  lanes, document isolation, hit-testing/precision levels, selection/search,
  link dispatch, Lua-side gesture dispatch) that did not exist at all before
  this pass — Parts 3–6 built all of it without architecture.md ever being
  updated to describe it.
- README.md gained the `interaction.*` config block, all six new commands
  in the usage table, a "Mouse gestures" section, and a "Terminal support"
  section that replaces the old single-terminal "supported environment"
  claim with an honest summary and a pointer to the full matrix.
  `doc/md-viewer.txt` mirrors all of it in Vim help format, gained two new
  TOC sections (`Mouse interaction`, `Terminal support`), and was verified
  with a real `:helptags` run (no errors).
- `SECURITY.md` and `docs/security.md` each gained a section on the
  interaction surface: what it can and cannot do, and why it introduces no
  new attack surface (re-uses the same sanitized document, the same
  document-root/symlink checks, and treats all search/selection text as
  plain text).
- `docs/troubleshooting.md` gained nine new sections mapping every
  post-Part-6 follow-up's symptom to its setting or mechanism (notification
  bleed-through, alignment gap/overhang, roll/blink, stranded-tabpage image,
  interaction not responding, no selection after a drag, wrong click
  position, wrong terminal profile) and fixed the stale
  `:MdViewerSpikeStop` reference.
- `CHANGELOG.md` gained the `[0.3.0]` entry (Added/Changed/Fixed, covering
  Parts 3–7 and every post-Part-6 follow-up). `VERSIONING.md`'s two stale
  "click-to-source" example references were corrected to describe what
  actually shipped. `prompts/part-7-hardening-and-docs.md`'s own §7.5 line
  was corrected the same way, per policy §6.5, since it named a scenario
  ("click-to-source") that no longer exists as a gesture to test.

### 7.7 Final polish

`stylua --check` clean throughout (CI already enforces it since Part 1).
Dead-code sweep of `interaction.lua` (the file most touched across Parts
3–7) found and removed three genuinely unused items, confirmed by grep
across the whole repository including tests: `M.is_captured` (defined,
never called anywhere — `M.captured_session()` is the function actually
used), and two pointer-table fields, `content_revision` and
`interaction_serial`, both set on every press and never read anywhere.
README's terminal claims were written to match `docs/manual-testing.md`
exactly (both describe the same two-terminal historical confirmation, the
same five recognized terminals, and the same tmux/screen/Zellij
non-support). Version bumped to `0.3.0` in `renderer/package.json`,
`renderer/package-lock.json` (via `npm version`, not hand-edited, to keep
the lockfile internally consistent), and `lua/md-viewer/init.lua`'s
`M.version` field.

## Tests run and results (Part 7)

```
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
stylua --check lua/ plugin/ tests/lua/
```

- Lua: **591/591 assertions** (up from a measured 530/530 baseline —
  +61 from `lifecycle.lua` (new), the controller.lua `source_win`
  regression test, the interaction.lua symlink/diagnostics/coalescing
  tests, the process.lua/protocol.lua boundary tests, and the health.lua/
  debug.lua field-rendering assertions).
- Node: **134/134 tests** (up from a measured 128/128 baseline — +6 from
  `security-runtime.test.js` (3), `no-listening-port.test.js` (1), and two
  new `markdown.test.js` sanitization tests).
- `stylua --check lua/ plugin/ tests/lua/`: clean.
- `:checkhealth md-viewer`, `:MdViewerHealth`, and `:MdViewerDebug` each
  invoked directly (not just their library functions) in a real headless
  session per policy §5, with a preview open and synthetic selection/find
  state present; all three completed without error and every new field
  rendered correctly, including through `nvim_buf_set_lines`'s
  embedded-newline rejection that broke `:MdViewerHealth` in Part 1.
- The `controller.lua` `source_win` regression test was confirmed meaningful
  the way this project always confirms a regression test: `git stash` the
  fix, watch the new test fail with the wrong window id, restore the fix,
  watch it pass.

**No graphical validation was performed**, unchanged from every part and
follow-up before it — this development environment has no attached
graphical terminal. Everything in §7.1–§7.4 above is proven by real headless
command execution (real autocmds, real windows/buffers/tabpages, a real
renderer subprocess, real Chromium where the security tests need it) but
none of it is real terminal compositing. `docs/manual-testing.md` records
that honestly rather than papering over it.

## Known limitations and unresolved risks (Part 7)

- **Every scenario in the compatibility matrix remains graphically
  unvalidated**, on every one of the five recognized terminals, as of this
  writing. The two historical Part 1–2 confirmations (iTerm2, WezTerm) cover
  basic PNG rendering only and predate the entire interaction transport and
  every raw-image placement fix.
- **The `raw_cell_offset_px` pixels-vs-fraction question is unresolved**,
  not just unmeasured — it was explicitly considered and deferred for lack
  of a second data point. Shipping `v0.3.0` with the option as pixels is a
  real, if narrow, risk that the API shape needs to change later in a way
  that breaks an operator's configured value, if a second terminal or a
  cross-font-size iTerm2 measurement shows the offset scales with cell
  width rather than being constant.
- **tmux, screen, and Zellij remain entirely unsupported** — detection and
  an honest `:MdViewerHealth` warning only, no passthrough implementation.
  This is unchanged from every prior part and is now explicit policy, not
  an oversight.
- **The `source_win` fix's scope was verified narrowly.** The regression
  test covers the specific compound-command shape that was reported
  (`:split other-file`); it does not exhaustively enumerate every Vim
  command sequence that could produce a similar transient buffer/window
  mismatch (e.g. `:edit`-in-place mid-autocmd, or a session-restore plugin
  replaying window layout). The `vim.schedule` deferral is a general fix
  (it re-reads state after the *whole* command settles, not after a
  specific known-bad shape), so it should generalize, but that has not been
  separately stress-tested.
- **The security review's scope is this branch's diff**, not the codebase's
  full attack surface from first principles. It confirms nothing *newly
  introduced* by Parts 3–7 broke an existing control or added a new gap;
  it does not re-certify Part 1–2's own security work, which was already
  covered in those parts' own reviews.

## Decisions that changed assumptions in the original specification (Part 7)

- **`raw_cell_offset_px` ships as pixels, not a fraction, with the shape
  question recorded as open rather than settled** — §7.5's acceptance
  criterion asked for the question to be "decided before v0.3.0 freezes the
  option." It was considered and explicitly deferred instead of guessed at,
  because guessing wrong would be a worse outcome (a breaking config change
  later) than shipping with the question still open and documented as such.
- **The manual-testing rewrite treats "two historical, scope-limited
  confirmations" as closer to zero than to partial credit.** An earlier
  draft instinct would have been to mark iTerm2 `Supported` for "basic
  rendering" rows and unvalidated for the rest; the final document instead
  states plainly, in prose, that those confirmations predate and do not
  cover any of Part 3 onward's work, so a reader skimming only the table
  cannot walk away over-trusting iTerm2's column.
- **A full regression pass is expected to find and fix real bugs, not only
  re-run existing tests** — the `source_win` bug was found by building new
  test coverage for an unrelated requirement (§7.3's lifecycle table) and
  noticing the fixture itself was behaving unexpectedly. Policy §1's "one
  part per session" boundary was read as compatible with fixing a bug in
  already-shipped code discovered during the regression/hardening pass
  Part 7 exists to perform, as distinct from adding new functionality that
  belongs to a future part.

## Safe stopping point and first next action

The tree is green and complete for everything achievable without a
graphical terminal: 591/591 Lua assertions, 134/134 Node tests, stylua
clean, security review complete (real attacks attempted, not just
re-assertions), every lifecycle path tested end to end, diagnostics
expanded and verified via real command invocation, and documentation
brought current across every file `part-7-hardening-and-docs.md` named.

**The first next action is entirely the operator's, not code.** Work
through `docs/manual-testing.md` in every terminal actually available,
starting with iTerm2 (the terminal with prior, if scope-limited,
confirmation) and prioritizing the two rows every post-Part-6 follow-up
writeup flagged as unconfirmed: passive-overlay opacity (no Markdown
showing through a notification) and placement stability (no roll/blink when
one appears or disappears). Record real results — `Supported`,
`Experimental`, or honestly `Unsupported` — in the matrix, and resolve the
`raw_cell_offset_px` pixels-vs-fraction question the moment a second
terminal or a font-size change on iTerm2 is available to measure against.
Once that operator pass is recorded, `v0.3.0` is ready to tag exactly as it
stands in code today — no further implementation work is expected to be
required first.

---

# Post-Part-7 follow-up — clickable local links and mouse pointer shapes

Reported by the operator while beginning the manual terminal pass, as two
feature requests and one performance complaint. Fixed here in code; the
performance complaint was deliberately not fixed here (see below).

## What was actually wrong with local links

Ctrl-clicking `[docs/manual-testing.md](docs/manual-testing.md)` warned
`refused to open link outside the document root`. That message was
misleading in two independent ways and the underlying behaviour was wrong
in a third.

**The root was too narrow.** `security.document_root` defaulted to the
*document's own directory*. Verified by running the real resolver
headlessly against this repository:

```
href=docs/manual-testing.md   base=<repo root>   -> /…/docs/manual-testing.md
href=docs/manual-testing.md   base=<repo>/docs   -> nil          <-- reported failure
href=manual-testing.md        base=<repo>/docs   -> /…/docs/manual-testing.md
```

So `README.md` at the repository root worked, and any document inside a
subdirectory could reach neither a sibling directory nor the root. A
document in `docs/` linking to `../README.md` was refused every time. The
root is now the enclosing project (`vim.fs.root` with `.git`/`.hg`/`.svn`,
configurable via `security.document_root_markers`), falling back to the
previous behaviour where no marker is found. Containment is untouched:
both the lexical and the symlink-resolved path are still checked.

`renderer.lua` also computed its own root for local *images*
(`cfg.security.document_root or base_dir(...)`), skipping the
normalization the link path applied. Images and links now share one
implementation, which closes a pre-existing divergence rather than one
this change introduced.

**Three different failures wore one message.** `is_inside` calls
`fs_realpath` on both sides and returns false when the target does not
exist, so a link to a file that was simply not there reported a security
refusal. `resolve_local_link` now returns a reason
(`outside_root`/`missing`/`malformed`). The out-of-root case is decided
*lexically*, before the filesystem is consulted — otherwise the two
distinct messages would let a hostile document probe for the existence of
files outside the root by observing which one came back.

**A local link opened in Finder, not Neovim.** `open_local_file` handed
the resolved path to `vim.ui.open`. It now edits the file in the source
window (jump list pushed first, so `<C-o>` returns) and, for Markdown,
retargets the preview onto it via `controller.retarget` — re-keying the
existing session and re-deriving `document_id` rather than closing and
reopening the split. The request-serial bump is what makes that safe:
responses in flight for the old document fail their staleness check. Files
Neovim has no filetype for, and PDFs, still go to the system handler.

## Mouse pointer shapes

> **Superseded.** This feature was removed before `v0.3.0` was tagged; see
> "Operator report: the pointer shape came out, history went in" at the end
> of this document. The section is kept because the reasoning it records --
> what each terminal actually does, and why none of it could be called
> validated -- is what the removal decision rests on.

The preview is a PNG, so no CSS `cursor` rule can reach it; only the
terminal can change the pointer, through `OSC 22`. Two design decisions
carried the feature.

**Hover must not round-trip.** `<MouseMove>` fires on every cell crossing,
so asking Chromium "is this a link?" per event was never viable. It is
also unnecessary: link rectangles belong to the *layout*, not the frame.
`renderer/src/hover.js` collects them once per document load in document
coordinates, on the same path and by the same argument as
`collectBlockGeometry` — scrolling translates them, it does not reflow
them. Per-frame cost is zero bytes and zero work; the only per-frame input
is `scrollY`, already reported. An earlier sketch had the map riding every
capture response, which would have added a `page.evaluate` to the hottest
path to recompute something that cannot change, and would have made a
stale map possible at all.

**Invalidation is a check, not six hooks.** Content, scroll, resize,
occlusion, placement move and retarget could each stale the cell index.
Rather than hooking all six, the index records the frame it was built for
and `hover.matches` rebuilds when that no longer holds, so a missed hook
means "rebuild", never "hand cursor over the wrong thing".

### What the terminals actually do — and what is not known

Researched by reading each terminal's source. **Nothing was launched.**

- **iTerm2 implements OSC 22 but accepts only X11 cursor-font names.**
  Sending `pointer` there falls into its unknown-name branch, which
  *clears* the override — visually identical to no support at all. A
  per-profile name table is therefore load-bearing, not tidiness:
  `hand2`/`xterm`/`left_ptr` go to iTerm2, the CSS names elsewhere.
- **WezTerm does not implement it** (upstream PR still open). Silent
  no-op.
- **Ghostty ignores the empty reset form**, so `pointer.clear()` emits the
  explicit default name *and then* the empty form — two writes, both
  needed, or some terminal is left holding a hand cursor.
- **Ghostty also resets the shape on every mouse-reporting mode change**,
  which enabling `'mousemoveevent'` itself causes. The shape is asserted
  after enabling and the cache is dropped on every toggle.
- **Warp is unknown** (closed source), so `"auto"` sends nothing there.

The query form of OSC 22 is deliberately unused: reading its reply is a
synchronous terminal probe, which `terminal.lua` forbids for the same
reason it never probes for graphics support. Support is inferred from the
profile and reported as inferred.

**None of this is validated.** Every profile keeps
`validation = "protocol-compatible-but-unvalidated"`, and
`docs/manual-testing.md` gained a per-terminal pointer-shape table whose
last column ("Actually looked at") is **No** for all five.

### A cost that is real and was not designed away

`'mousemoveevent'` is global, and Neovim documents that setting it *"can
make pending mappings to be aborted when the mouse is moved"*. It is
enabled only while a graphical preview exists and restored on close, but
while on, a half-typed multi-key mapping can be dropped by mouse movement.
`interaction.pointer_move_events = false` separates the two halves: the
drag I-beam still works (it rides `<LeftDrag>`), the hand cursor cannot.
This is stated in README, the help doc, and troubleshooting rather than
being buried.

Also worth recording: `<MouseMove>` does **not** fire while a button is
held — Neovim reports that as `<LeftDrag>`. The I-beam is therefore driven
from the drag path, not the hover path. The two states cannot race, which
is what makes the requirement implementable at all.

## A pre-existing bug this surfaced

`controller.display_interact_result` never recorded `result.scrollY`, but
`browser.interact()` always reports it and overwrites it with the
post-`scrollIntoView` position for a find step or a fragment link. So
after a search jumped the page, `applied_scroll_y` still held the
pre-search position; the next `interact` sent that stale value and
`ensureDocumentActive` scrolled the page back before hit-testing. A click
after a find resolved against a different position than the image showed.
Fixed here because the hover map reads that field on every mouse move,
which is what made it visible. **Found by code reading; the graphical
symptom was not reproduced.**

## Tests

727 Lua assertions (from 591) and 142 Node tests (from 134), stylua clean.
`:MdViewerHealth`, `:MdViewerDebug`, and `:checkhealth md-viewer` were each
invoked as the real command, not as the library function beneath it.

Worth naming two: `tests/lua/cases/hover.lua` checks the cell index against
a brute-force scan over every cell of a 40x20 grid for 120 generated
rectangles, so the index cannot be subtly wrong; and
`tests/lua/cases/pointer.lua` asserts exact escape bytes *and their
lengths*, that a repeated shape writes nothing, and that iTerm2's profile
sends `hand2` rather than `pointer` — the regression test for the finding
above. The `<MouseMove>` case pins a terminal profile explicitly, because
the CI terminal resolves to `unknown` and would otherwise assert nothing
while appearing to pass.

## Deliberately not done

**Drag-highlight performance.** The operator also reported drag-to-select
as too slow. It is not fixed here: the honest diagnosis is that the
per-frame pipeline captures a *full-viewport screenshot at device scale*
(`interaction.lua` hardcodes `"device"` for preview frames) where the
scroll path already solved the same problem with a `"css"` moving frame
plus one device-scale settle, and there is a 40 ms debounce in front of a
pipeline that already has one-in-flight backpressure. That is a
measurement-first task, not a patch, and bundling it here would have made
this change unreviewable. It is written up as
`prompts/improve_cursor_drag_highlighting.md`, which hands over the full
per-frame trace and a ranked list of suspects while requiring the next
session to measure before changing anything.

**Checkbox and image pointer shapes.** Task-list checkboxes have no click
action, so a hand cursor over one would advertise something the plugin
does not do. Links only, per operator decision.

## Field report: the fix landed, and the first real failure was configuration

The operator reported links still refusing after the above shipped. The
message was the *new* one, which names the root, and that is what made it
findable: the root printed was an Obsidian vault, while the document being
previewed was a sibling repository.

Their Neovim config resolves a vault root by taking `realpath` of
`stdpath('config')` (their `~/.config/nvim` is a symlink into the vault) and
walking three directories up, then pinned it globally:

```lua
security = { document_root = vim.g.obsidian_vault_root }
```

An explicit `document_root` overrides project detection by design, so every
preview -- in any repository -- was confined to the vault, and every link in
this repository's own README was correctly refused. Not a code defect; the
plugin did exactly what it was told.

Two things came out of it worth keeping:

- The old message hid the root, so this was indistinguishable from a plugin
  bug for as long as the configuration had existed. Naming the root in the
  refusal is what reduced it to a two-minute diagnosis, which is the argument
  for the message change independent of the root-widening.
- A configured root that excludes the current document is a *state*, not an
  event, and reporting it one refusal at a time was the actual failure of
  diagnosability. `security.summary` now computes
  `document_root_excludes_current` and `document_root_source`, and
  `:MdViewerHealth` warns on the former with both paths named. The fix for
  their configuration was to drop the pin and use
  `document_root_markers = { ".obsidian", ".git", ".hg", ".svn" }`, which roots
  vault notes at the vault and repository docs at the repository -- i.e. the
  feature this work added, used as intended.

## Operator decision: an unbounded document root, and the guard that made it safe

Asked whether the preview could simply treat the whole machine as the root --
"Neovim can open anything regardless of where you launch it" -- the honest
answer was that it already could (`document_root = "/"` needed no code), but
that the setting was doing two jobs with different consent models:

- **link activation** is user-initiated (you Ctrl-click), and Neovim's own
  `gf`/`gx` have no notion of a project boundary at all;
- **image loading** is document-initiated, happening on render whether or not
  you asked.

The operator chose an unbounded root for both. That is recorded as a
considered choice: the residual image risk is bounded by the existing image
rules (extension and magic bytes must agree, four formats, size cap) and by
`security.network = false`, which together make it an "is this file an image"
oracle rather than an exfiltration path. `:MdViewerHealth` reports the
unbounded root rather than letting it be inferred, and says explicitly if the
network is enabled alongside it.

**The guard that changed the calculus** is independent of the root, and closes
a hole that existed before any of this work: a `local_file` link whose target
Neovim has no filetype for was passed to `vim.ui.open`, and on macOS
`.command`, `.app`, `.terminal`, and `.workflow` are *executed* by the system
handler. The document root never defended against it -- a cloned repository can
ship `setup.command` beside its README and link to it from inside the root --
so widening the root did not create the problem, only enlarge it.
`security.is_system_executable` now refuses those, using two independent
signals because neither is sufficient alone: an extension denylist (bundles are
directories, so no file mode applies to them) and the execute bit (an ordinary
executable may have no telling name).

## A diagnostic that was describing itself

Adding the "configured root excludes the current document" warning surfaced a
pre-existing defect in `health.collect`. Both `:MdViewerHealth` (`M.show`) and
`:checkhealth` create and *enter* their own scratch buffer before collecting,
so `nvim_get_current_buf()` is the report, not any document -- every
document-relative answer in the report, including the document root itself, had
always described the report buffer.

It went unnoticed because the previous root derivation happened to return
something plausible for a nameless buffer. The new warning turned it into a
confident, wrong claim about a file that does not exist, which is how it was
caught.

Worth recording as method: this was **not** caught by `health.collect()` in a
test, which passes a buffer directly and so cannot reproduce it. It was caught
by invoking `:checkhealth md-viewer` as the real command -- exactly the failure
mode policy §5 already requires command-level invocation for, and the second
time that rule has paid for itself. `collect` now resolves a live preview's
source buffer, then a real file, then the buffer the report displaced.

## Operator report: the pointer shape came out, history went in

Three findings from the second field pass, all on an untagged `v0.3.0`.

### The pointer shape was removed, not fixed

The operator's verdict was that it "is not worth it, the terminal and UI seems
a bit too buggy for that". That matches what the source readings already said
and what §4 refused to let the feature claim: three dialects, one terminal that
does not implement `OSC 22` at all, one that resets the shape on every
mouse-reporting mode change (which md-viewer's own `'mousemoveevent'` toggle
causes), and one that is closed source and unknowable. Nothing had ever been
seen on a screen.

Removed rather than defaulted off, because "off by default and unvalidated" is
carrying the maintenance and the global-option cost of a feature nobody is
using. Gone with it: `lua/md-viewer/pointer.lua`, `lua/md-viewer/hover.lua`,
`renderer/src/hover.js`, the `<MouseMove>` mapping, the `'mousemoveevent'`
lifecycle, the per-layout link geometry on the render/capture path,
`localRow`/`localCol` on `cell_to_css`, the per-profile `pointer_support`/
`pointer_shapes` fields, and the three `interaction.*` options. The
`hoverMap`/`hoverRects` wire fields are gone from the renderer protocol; they
were additive and optional, so nothing else had come to depend on them.

The scroll-position bug found alongside it (`display_interact_result` never
recorded `result.scrollY`, so `applied_scroll_y` went stale after a find or a
fragment jump) **stays fixed**. It was pre-existing, the hover map only made it
visible, and it is wrong independently of anything the pointer shape did.

### External links: nothing was broken, everything was silent

The reported symptom was that ctrl-clicking an `https` link did nothing. The
renderer was exonerated by an existing test (`activate_at` returns
`type: "https"` with the href for a real link in a real Chromium), the Lua
dispatch by another (`open_external` is reached and calls `vim.ui.open`), and
`vim.ui.open` itself by running it. What could not be exonerated was the
reporting:

- `vim.ui.open` signals "there is no handler to run" by **returning**
  `nil, <reason>`, not by raising. `pcall` around it therefore never saw a
  thing, and the failure produced no message at all.
- It does not wait, so a handler that starts and *then* fails -- `open: unable
  to find application`, an `xdg-open` with no desktop session -- reports through
  an exit status nothing looked at.
- `M.activate` dropped every hit-test error on the floor, so "the click did not
  resolve" and "there was no link there" were the same non-event.

All three now surface. The exit status is watched without blocking: poll
`kill(pid, 0)` (which asks whether the process exists and sends nothing), and
only once it is gone call `wait`, which then returns immediately. A handler
still running after `interaction.external_open_timeout_ms` is the *successful*
case -- a browser that stayed open -- so the watch simply stops.
`:MdViewerDebug` records the last hand-off and its outcome.

This is honest about what it is: a diagnosis, not a repair. The failure could
not be reproduced here, and the change makes the next occurrence name itself
instead of being invisible. A stale hit-test error is now reported except when
it is a `STALE_INTERACTION`, which is routine and would fire on ordinary fast
clicking.

### Preview history

Following a link retargets the preview, and `preview.pinned` deliberately stops
the preview following an ordinary buffer switch. Those two facts together left
the reader able to reach a document and unable to return to the previous one as
anything but text -- `<C-o>` moved the source window and left the rendered view
where it was.

Each session now carries the documents it has been retargeted through and an
index into that list. `H`/`L` in the preview window and
`:MdViewerBack`/`:MdViewerForward` anywhere walk the index without appending (appending would make "back" oscillate between the last two entries),
and both move the source window as well, for the same reason activating a link
does. A `BufEnter` in the session's source window follows the preview to a
buffer *already in the list*, which is what makes `<C-o>` work on its own
without weakening `pinned` for anything else.

Three details that are decisions rather than details:

1. Entries hold a buffer **and** a path. The buffer makes returning exact and
   cheap; the path is what lets an entry survive `:bwipeout`.
2. Navigating from the middle truncates the forward branch, the same rule a
   browser follows. Interleaving would make "forward" mean nothing.
3. One document can appear at more than one position (a link back to where the
   reader came from puts it there twice), so the `<C-o>` follow searches outward
   from the current index and prefers backwards on a tie -- landing at the far
   end of the list would send the *next* `<C-o>` somewhere the reader has never
   been.

Bounded by `interaction.history_limit` (32), and the bound has its own test:
an unbounded list on a session left open for hours is a slow leak.

The keys are preview-local rather than leader-prefixed because the operator's
first attempt at a global `<leader>m[`/`<leader>m]` pair did not fire at all,
while the commands behind them worked when typed -- a binding collision, which
`H`/`L` cannot have: they are buffer-local to a scratch buffer md-viewer owns
outright, and they shadow "top/bottom of screen", which addresses nothing in a
buffer holding no text. Gated on `interaction.links`, since a link activation
is the only thing that ever puts a second document in the history.

## A link that was unclickable at the default font size

Reported as: ctrl-clicking the one-word `Glow` link at the top of a document
did nothing at iTerm2's default text size, and started working after
`Cmd +` a couple of times.

That is a strange-sounding report, and it was exactly right. `hitTestInPage`
resolved the clicked cell by probing outward from its centre **horizontally
only**, on the stated reasoning that "a cell is about as tall as a rendered
line, so probing vertically could answer from the line above or below". The
first half of that is false on the estimated calibration tier: a cell covers
10x20 CSS px (`estimated_cell_width_px = 10`, `cell_aspect_ratio = 0.5`), a
rendered line is 25 px (`line-height` in `preview.css`), and an inline link's
box is about 18 px for a 16 px font. None of those divide into each other, so
where a link sits relative to the cell-row centres depends on the phase between
two grids that never line up.

Measured against the real document, rendered at 99x56 cells:

```
anchor rect   y 91.59 .. 109.59      (18.0 px tall)
cell rows     centres at ... 70, 90, 110, 130 ...
clickable cells: NONE
```

Row 4's centre lands 1.6 px above the link; row 5's lands 0.4 px below it.
There was no cell in the entire window from which that link could be
activated. At 60x30 cells the same document put the link at y 97.8..118.8,
row 5's centre at 110 landed inside it, and it worked -- the operator's "make
the font bigger" was changing the phase, nothing else.

The fix probes both axes, still bounded by the one cell the user clicked, with
probes ordered nearest-first in *cell fractions* rather than pixels (in pixels,
a cell twice as tall as it is wide makes every vertical probe lose to every
horizontal one, and "nearest" quietly means "nearest horizontally"). Reaching
at most half a cell vertically can only touch a line that same cell already
covers, which is what the original comment was worried about and is the reason
the bound matters more than the probe.

A second change rides with it: within the clicked cell, **a link wins over
prose**. The cell is the resolution limit of the entire input device -- the
terminal cannot report where inside it the pointer was -- so a link anywhere
under the clicked cell is what the reader was pointing at. Prose is the answer
only when the cell holds no link. Still bounded by the one cell: two cells away
is still prose, and that has its own test.

Same geometry after the fix:

```
clickable cells: rows 4-5, cols 3-6   (8 cells)
```

`tests/node/hitbox.test.js` does not sample one alignment. It sweeps `scrollY`
one pixel at a time across a full cell height, which is every phase the two
grids can ever take, and at each one asserts the link is reachable from an
overlapping cell and that the hit box is at least four cells. Reverting the
vertical probe makes it fail, which was checked rather than assumed.

Worth recording as method: the report was reproduced *before* anything was
changed, by driving the real renderer against the operator's own document and
printing which cells resolved the link. Every earlier hypothesis -- the iTerm2
graphics margin, the `max-width: 980px` article cap, a `scale` clamp -- was
wrong, and none of them would have survived contact with those two numbers.

The three `resolveSelectionPoint` copies (drag-select, word select, paragraph
select) still probe horizontally only, deliberately: they resolve through
`caretPositionFromPoint`, which snaps vertically within the line box on its
own, so they never depended on the cell centre landing inside a glyph. Only
the anchor lookup did, because it comes from `elementFromPoint`.

## Safe stopping point

`v0.3.0` remains untagged and the operator's manual terminal pass remains
the only gate. The matrix lost the four pointer-shape rows and the two rows
that existed only to measure `'mousemoveevent'`'s cost, and gained four:
an external link opening (or saying why it did not), a short inline link being
clickable at the terminal's default font size, `:MdViewerBack`, and
`:MdViewerForward`/`<C-o>`. Everything above is headless-verified only; per
§4 none of it may be described as validated on any terminal.

## Post-Part-7 follow-up: drag-highlight responsiveness, stage 1 — measure, then fast frames

Operator report, from real use on iTerm2: dragging to highlight text in the
preview renders too slowly. `prompts/drag_highlight_stage_1_fast_frames.md`
scoped a measurement-first, two-change fix: the capture scale of moving
drag-preview frames, and the debounce sitting ahead of them. Five riskier
suspects (per-frame temp file with a blocking `fs_read`, full PNG re-upload,
per-frame anchor re-resolution, `page.evaluate` re-serialization,
unconditional `applyScroll`) are explicitly out of scope and live in
`prompts/drag_highlight_stage_2_transport.md`, which the operator directed
must not be touched in this session — including the "Measurements from
stage 1" section that prompt normally asks this stage to fill in. That table
is recorded here instead, and stage 2 remains an unfilled placeholder.

### Method

Two throwaway benchmark scripts (not committed), both driving the real
renderer subprocess and real Chromium, no stubbing:

- **Node-side**, modeled on `tests/node/interact.test.js`'s subprocess
  harness: `kitchen-sink.md` + 60 filler paragraphs (5,400 characters, 90
  layout blocks), one `render`, then 20 `selection_preview` requests with
  incrementing coordinates simulating a drag sweep across one line, at
  `captureScale: "device"` and again at `"css"`, reading back each
  response's real `rehydrateMs`/`captureMs`/`totalMs`/`pngBytes`.
- **Lua-side**, modeled on `tests/lua/cases/process.lua`'s real (non-stubbed)
  subprocess usage: a headless `nvim -l` script that seeds the same document
  via a real `render` request over `process.lua`, then calls
  `interaction.request_selection` directly in the same 20-frame sweep,
  timing the Lua-observed round trip with `vim.uv.hrtime()`, plus real
  (non-fabricated) timings for `renderer.read_png`'s blocking `fs_read` and
  `vim.base64.encode` on the returned PNG.
- A third pair of scripts isolated the debounce/pacing question specifically:
  one measuring wall-clock from a single `on_drag` call to its request
  reaching `process.request`, the other simulating a continuous 300ms drag
  (`on_drag` every 15ms, a stubbed ~30ms request latency) and counting how
  many requests actually left Lua under each `drag_debounce_ms` value.

**Honesty gap.** None of this drives a real terminal. The final
`nvim_ui_send` write and whatever the terminal does with those bytes cannot
be measured without one, and this session did not have one attached. Every
number below stops at the boundary of what Lua and the real renderer
subprocess can produce on their own.

### Measurements

Per-frame, `captureScale: "device"` vs `"css"` (averages over 20 frames,
same document, same machine):

```
                 device        css
Node  wallMs      68.40       33.23
Node  rehydrateMs  1.11        1.04
Node  captureMs   64.88       30.07
Node  totalMs     67.95       32.85
Node  pngBytes  86822.9    38397.0

Lua   wall_ms     67.90       32.52   (dispatch + IPC + renderer round trip)
Lua   pngBytes  86823        38397
Lua   fs_read_ms  0.108        0.094  (real, blocking, headless-safe)
Lua   base64_ms   0.060        0.027  (real, pure Lua, headless-safe)
```

The Node- and Lua-observed wall-clock numbers agree closely (68.4 vs 67.9,
33.2 vs 32.5), and `captureMs` accounts for ~95% of `totalMs` in both. The
PNG-read and base64-encode steps are sub-millisecond and did not need
optimizing. **This exonerates `page.evaluate`'s selection-resolve step
(`rehydrateMs`) and the Lua-side PNG handling as suspects for the per-frame
cost — the screenshot itself is the entire story**, and it is ~2.1x more
expensive at device scale, matching the ~2.26x larger PNG.

Debounce/pacing, same machine:

```
first-dispatch latency (single on_drag call):
  drag_debounce_ms=40 (old default): 37.71 ms before the request is sent
  drag_debounce_ms=0  (new default):  0.01 ms

requests actually sent over a continuous 300ms drag (new point every 15ms):
  drag_debounce_ms=40 (old default): 1 request for the whole gesture
  drag_debounce_ms=0  (new default): 11 requests, coalesced_drag_events=19
```

The old default did not merely add 40ms of latency — under input faster than
the debounce interval, the *trailing* debounce (it resets on every call
rather than firing on a schedule) can send exactly one frame for an entire
drag, all the way at the end. This is the case the fix removes: dispatch is
now gated only by the existing one-in-flight/newest-point-only backpressure,
the same shape `controller.schedule_scroll` already used.

### What changed

> **Superseded on both counts — see the round 2 and stage 2 sections below.**
> The capture-scale half of this stage was reverted in `c44e22f`: moving drag
> frames are device scale again, and the cheap capture survives only as an
> opt-in `interaction.fast_drag` defaulting to `false`. The Lua test described
> below as asserting `"css"` asserts `"device"` again. The debounce/pacing half
> described here is unchanged and still stands.

- `lua/md-viewer/interaction.lua`'s `M.schedule_selection_preview`: the
  preview frame now captures at `render.fast_scroll and "css" or "device"`
  (reusing the existing flag rather than inventing `fast_drag`), and dispatch
  fires immediately when `interaction.drag_debounce_ms <= 0`, using
  `debounce.call` only as an opt-in throttle when it is set above `0`.
  Everything else — `M.settle_selection` (always `"device"`, deferred via
  `pointer.pending_settle` when a preview is still in flight), the
  one-in-flight/newest-point-only coalescing, `M.on_drag` — is unchanged.
- `lua/md-viewer/config.lua`: `interaction.drag_debounce_ms` default `40` →
  `0`. The knob is preserved, not removed — the config schema and
  `validate()` are untouched.
- This is a deliberate, narrower reuse of the earlier "post-clear capture
  frames render at full (device) scale" fix (`CHANGELOG.md`'s `[0.3.0]`,
  first `### Fixed`), not a reversion of it. That fix stopped every interact
  capture — including the settled commit — from silently inheriting
  whatever scale a recent scroll had cached. Only the *preview* frame's
  scale changes here; `M.settle_selection`'s commit is still unconditionally
  `"device"`, so what the reader is left looking at after releasing the
  mouse is unchanged.

### Tests

`tests/lua/cases/selection.lua`: the existing preview-frame assertion
(previously asserting `"device"`, the behavior this stage changes) now
asserts `"css"`; added cases for `render.fast_scroll = false` falling back to
`"device"`, `drag_debounce_ms = 0` dispatching and coalescing synchronously
with no timer wait, and a release arriving while a preview is still in
flight deferring correctly via `pointer.pending_settle` (no prior test
exercised that path). All four gates: 721 Lua assertions (from before this
change's own additions), 136 Node tests, stylua clean.

`:MdViewerDebug` was invoked as the real command (not the library function)
against a real headless session with a fake-but-functioning image backend
(only the terminal write itself is faked; render, capture, and interact are
all real) driving an actual press/drag/release. `fast_capture_ms` (26.72),
`fast_png_bytes` (10732), `retina_capture_ms` (49.31), and
`retina_png_bytes` (23772) all populated correctly, confirming the
moving/settled split stays observable through the existing fields as
required.

### Not done here

The five stage-2 suspects are untouched, per scope. `applyScroll` running
unconditionally per interact (suspect 5) is plausible from the numbers above
only as noise inside `rehydrateMs`, which averaged ~1ms either way — not
worth pursuing without a stronger signal. The other four were not measured
at all; they are `page.evaluate`/transport-level and out of this stage's
scope regardless of what the numbers show.

**This cannot be validated.** Whether the drag now *feels* more responsive
is the operator's call, made by dragging in a real terminal. The numbers
above show the two changed mechanisms doing what they were built to do —
capture is materially cheaper, and dispatch no longer waits or starves — but
say nothing about what a real Kitty/iTerm2 draw feels like.

---

## Post-Part-7 follow-up: drag-highlight responsiveness, round 2 — sharp frames

**Commit:** `c44e22f` — "sharp drag frames, and a drag that leaves the window
keeps selecting"

Two operator-reported bugs from a real iTerm2 session, both real:

1. The preview went blurry and emoji looked bloated for the whole of every
   drag. Stage 1's capture-scale change was the cause and was reverted:
   moving drag frames are **device scale** again. The cheap capture survives
   as an opt-in `interaction.fast_drag`, defaulting to `false`, deliberately
   *not* wired to `render.fast_scroll` — nobody reads text mid-scroll, but a
   drag-to-select puts the reader's eye on the exact glyphs being crossed.
2. A drag leaving the preview window stopped extending the selection.
   `interaction.locate_for_drag` now clamps an out-of-window pointer to the
   placement edge, and `resolveSelectionInPage` slides an endpoint that landed
   on no block onto the nearest one. The clamp alone was a no-op: the edge
   column is the page's own 26px side padding, so every request from it came
   back `focus_miss`. `hitTestInPage` still reports an honest `outside_content`
   miss for that padding, so a click in the margin never activates a link.

---

## Post-Part-7 follow-up: drag-highlight responsiveness, stage 2 — make a sharp frame cheap

**Status:** implemented, **not committed**, pending operator validation in a
real terminal.

### What the frame budget is actually made of

Stage 2 began with measurement and no production code, because the previous
round's ranking of suspects turned out not to describe the cost at all.

Decomposing `page.screenshot()` against real Chromium (Chrome 151) showed that
capture time is **not** dominated by rasterization, CDP transfer, or the file
write, and that **area is nearly irrelevant**:

```
990x1020 CSS @ deviceScaleFactor 2 (1980x2040 device px), dense document
  full device-scale PNG (production)      ~82-98 ms
  a 1x1 PIXEL clip                         ~32 ms
  a 990x260 band                           ~32 ms
  full-size JPEG (same pixel count)        ~32 ms
```

A one-pixel screenshot costs the same ~32ms as a full frame. That fixed floor
is `Page.captureScreenshot` waiting for the compositor to commit a fresh
frame, capped at the display refresh rate (~2 x 16.2ms). Everything above the
floor is **PNG encoding**, which is linear in pixel count and content density.

The operator's real session (`:MdViewerDebug`, iTerm2, 99x51 cells) put real
numbers on both halves:

```
viewport 990x1020 px, dsf 2      retina_capture_ms      103.21
retina_png_bytes  471484         retina_image_update_ms   0.783
fast_png_bytes    210423         fast_capture_ms         51.90
```

Encode is therefore ~69% of their frame (103.2 - 32.4) and the floor ~31%.
`fast_capture_ms` confirms the model independently: 51.9 - 32.4 = 19.5ms of
encode for 1.0M px against 70.8ms for 4.04M px, a 3.6x ratio against a 4.0x
area ratio.

### The four previously-suspected costs really are noise

Measured, not assumed:

- `rehydrateMs` (which contains the re-resolved drag anchor, `page.evaluate`
  function re-serialization, and the unconditional `applyScroll`) —
  **0.57-1.25ms** of a 75ms frame.
- Lua-side `fs_read` + `vim.base64.encode` + escape assembly — **0.075ms**
  for an 86KB frame, **0.120ms** for a 151KB one.

All four together are under 1% of the frame. Perfect work on every one of
them would buy roughly 1ms out of 75.

### Terminal transfer is also noise

Never previously timed, and the reason lever A was ranked first. The
operator's `retina_image_update_ms` — `vim.base64.encode` plus `nvim_ui_send`
of a whole 471KB frame — is **0.78ms**. This removes the premise that a
damage-rectangle placement would attack "both dominant costs at once": the
upload is not a cost. (Caveat: this measures `nvim_ui_send` returning, not
iTerm2's own decode and composite, which happens asynchronously and which
nothing in-process can observe.)

### What changed

Two changes, both **pixel-preserving**, neither touching placement, transport,
staleness lanes, or selection semantics:

- `renderer/src/browser.js` launches Chromium with `--disable-frame-rate-limit`.
  This removes the refresh-rate cap on the compositor wait: the floor measured
  32.3ms -> 19.8ms, reproducibly across three runs, with **byte-identical**
  PNG output (same SHA). Idle CPU is unchanged (0.4% of one core with and
  without), which matters because this browser is persistent.
- `captureViewport` now issues `Page.captureScreenshot` over a raw CDP session
  with `optimizeForSpeed: true`, which Playwright does not expose. PNG is
  lossless either way; this only trades compression ratio for encoder time.
  The PNG is ~40% larger, costing ~0.3ms more of a 0.78ms upload.
  `browser.fast_png_encode` (default `true`) turns it off, and any failure
  falls back permanently to `page.screenshot` for the life of the process.

`clip` is in **document** coordinates, so the capture reads the page's live
scroll offset (`visualViewport.pageLeft/pageTop`) rather than trusting
`active.scrollY`. An early version of the benchmark omitted this and silently
screenshotted the top of the document at every scrolled position — the same
shape as the `display_interact_result` `scrollY` bug this repository already
shipped once. There is now a test for it.

`captureEncoder` is reported through to `:MdViewerDebug` as `capture_encoder`,
so a browser that refused the fast path looks refused rather than merely slow.

### Before and after

Same real drag, same document, same machine, three runs each. The envelopes
were produced by a **real drag in a live Neovim** (see below), then replayed
verbatim into the real renderer subprocess:

```
per moving drag frame        BEFORE (c44e22f)      AFTER
  wall (Lua-observed)        79.1 / 73.9 / 74.2    32.1 / 33.5 / 33.7
  captureMs                  75.5 / 70.4 / 70.5    28.0 / 29.2 / 29.9
  pngBytes                          140105               208713
```

**~75.7ms -> ~33.1ms, 2.3x** — roughly 13 to 30 moving frames per second
before terminal transfer.

### Verification

- **A live Neovim driven through the real input layer.** A headless server with
  `--listen`, real windows, real `mouse.attach` mappings, driven by
  `nvim_input_mouse` over `--remote-expr` from a separate process. Its
  `preview.placement()`/`preview.viewport()` pair came out at 99x51 cells ->
  990x1020 px — the operator's real geometry exactly. A press, ten drags and a
  release (one deliberately past the window edge) produced 12 real interact
  envelopes, with `pointer_pressed` false afterwards and no stuck state.
  Attaching a UI to that server is still not possible: `nvim_ui_attach` from an
  `-l` client kills the channel over `--listen` just as it does under `--embed`.
  The image backend is therefore the one part that stays faked.
- **Chained into a real Chromium renderer subprocess.** Those 12 envelopes were
  replayed verbatim; selection text lengths were identical before and after
  (0, 25, 74, 125, 161, 177, 197, 217, 241, 247, 248, 248), and the commit
  frame matched the final preview frame.
- **Pixel verification with an independent decoder.** The tests decode PNGs
  back to raw samples with a decoder that shares no code with the encoder under
  test, rather than comparing file bytes (which necessarily differ).

### One measured, deliberately accepted difference

The CDP capture issues its screenshot marginally earlier in the raster
pipeline than Playwright's path, which does extra round trips first. Against a
fully settled capture of the same state, the production frame differs by a
**constant 10 samples out of 4,039,200 (0.0002%)**, max delta 16/255,
greyscale, in one fixed region — present on every frame regardless of where
the selection is, so it is not selection-related.

It is emphatically not a stale frame: the same frames differ from the
*previous* frame's settled image by 8,000-62,000 samples, three to four orders
of magnitude more. `tests/node/browser.test.js` asserts exactly that ratio, so
a genuinely stale frame fails loudly. It is also not a sharpness change — the
frame is still full device resolution.

### Levers evaluated and rejected

- **A, damage-rectangle capture and partial placement.** Rejected during this
  stage, **and that rejection was wrong — see "Operator validation" below.**
  The reasoning was that upload is 0.78ms so there is no transfer cost to
  attack. That number measures `nvim_ui_send` *returning* — handing bytes to
  Neovim — not the terminal decoding and compositing them, a caveat recorded
  twice in this document and then overridden by the number anyway. Operator
  testing showed the terminal's own decode is the actual bottleneck, and lever
  A is the only evaluated option that addresses it.
- **B, stop screenshotting and composite the highlight terminal-side.**
  Rejected. It would make a moving frame nearly free, but it requires the
  highlight to be drawn by Lua from geometry rather than by the browser that
  owns the selection — which is precisely the way for the picture and
  `selection_text` to disagree. It also depends on unverified Kitty alpha/z
  behaviour on iTerm2 and changes what "the image on screen" means for
  `coordinates.cell_to_css`, `session.last_placement` and every diagnostic.
- **C, JPEG.** Rejected on protocol grounds: the Kitty graphics protocol has no
  JPEG format (`f=100` is PNG; `f=24`/`f=32` are raw RGB/RGBA), so a JPEG
  cannot be carried without transcoding, which costs more than it saves. Its
  lossless cousin — `optimizeForSpeed` — is what shipped instead.
- **`Page.startScreencast`.** Rejected. Push-based frames would remove the wait
  entirely, but measurement showed it silently dropping frames (500ms timeouts
  on some mutations) and its frames carry no request identity, so a superseded
  request could be answered from a newer one's frame.
- **`HeadlessExperimental.beginFrame`.** Unavailable — removed from Chrome 151.
- **Further compositor flags** (`--run-all-compositor-stages-before-draw`,
  `--deterministic-mode`, `--disable-gpu`). Measured, no gain beyond
  `--disable-frame-rate-limit` alone; `--disable-gpu` additionally changed the
  rendered pixels, and combining the first with `--disable-frame-rate-limit`
  hung the capture outright.

### Tests

All four gates: **142 Node tests, 755 Lua assertions, stylua clean**,
`npm ci --ignore-scripts` unchanged. `:MdViewerDebug` was invoked as the real
command in headless Neovim and produced a 63-line buffer.

Four new tests in `tests/node/browser.test.js`, all against real Chromium:
the fast encoder is lossless at both scales and both scroll positions; a drag
frame paints the selection it reports rather than the previous one; a scrolled
capture shows what is on screen rather than the document top; and
`browser.fast_png_encode = false` falls back and is re-read per request.

### This cannot be validated here

Whether the drag *feels* crisp and snappy is the operator's call, made by
dragging in a real terminal. Nothing above was seen in a graphical terminal.
The operator supplied one measurement — the `:MdViewerDebug` numbers quoted
above — and nothing else about this stage has been observed by eye.

### Safe stopping point

The tree is coherent and all gates pass, but **nothing is committed** — the
operator asked to validate in a real terminal first. First next action: drag
in iTerm2 and judge; then `:MdViewerDebug` and compare `retina_capture_ms`
against the 103.21 recorded above, and confirm `capture_encoder` reads
`cdp_fast_png`.

### Operator validation — the result, and what it overturns

Tested in real iTerm2 and WezTerm sessions. **The change did what it was
measured to do and made no perceptible difference to the gesture.**

```
iTerm2, 99x51 cells (990x1020 px, 4.04M device px)
  capture_encoder            cdp_fast_png     (fast path engaged)
  retina_capture_ms          103.21 -> 36.51  (2.8x, as predicted)
  retina_png_bytes           471484 -> 755566 (+60%)
  retina_image_update_ms     0.783 -> 0.790   (unchanged)
  operator verdict           "feels the same"

WezTerm, 87x51 cells (870x1020 px, 3.55M device px)
  retina_capture_ms          29.92
  operator verdict           "feels the same, still laggy while dragging"
```

A ~67ms per-frame saving in the renderer produced no felt change, in two
independent terminals. The renderer was therefore never the limiter.

The discriminating experiment was shrinking the preview to 20x10 cells —
320x320 CSS px, **0.41M device pixels, a 10x reduction, at unchanged
sharpness**:

```
iTerm2, 20x10 cells
  retina_capture_ms          15.98            (only 20ms below full size)
  retina_png_bytes           107864
  retina_image_update_ms     0.128
  operator verdict           "very snappy and smooth"
```

Capture time moved by 20ms while the felt experience changed completely. The
variable that tracks the gesture's responsiveness is **pixel count per frame**,
and the cost lives in the terminal's PNG decode and composite — downstream of
`nvim_ui_send`, and invisible to every measurement obtainable inside Neovim.

**What this means for lever A.** A slow drag — the case where responsiveness
matters, because the reader's eye is on the glyphs being crossed — changes two
or three lines of highlight. That damage band is roughly 990x75 CSS px =
**0.30M device pixels, below the 0.41M frame the operator judged snappy**, at
full size and full sharpness. Lever A is no longer the speculative option it
was ranked as here; it is the only evaluated lever that touches the measured
bottleneck. Its worst case (a fast drag spanning the viewport) degrades to
today's behaviour rather than worse.

**Standing correction to this document's method.** Two measurements in this
stage were correct and led to a wrong conclusion because of what they did not
cover: `retina_image_update_ms` is not terminal cost, and `captureMs` is not
frame cost. Any future claim about drag responsiveness has to be validated by
the operator dragging in a real terminal before it is believed.

#### Follow-up A/B: `browser.fast_png_encode = false` — confounded, but suggestive

The operator flipped the setting off and reported the gesture felt *slightly
faster*, with the renderer measurably **slower** (`retina_capture_ms`
36.51 → 59.44, `capture_encoder` correctly `playwright_png`).

The window was the same (990×1020, 99×51 cells) but the **document was not**:
`document_height_px` 6417 → 11723 and `applied_scroll_y` 990 → 3036, so a
different picture was on screen and `retina_png_bytes` (241595) is not
comparable with the earlier 755566. No conclusion about byte count can be drawn
from this pair.

The inversion itself — slower renderer, better feel — is the part worth
chasing, and points at md-viewer applying **no backpressure against the
terminal**: frames are pushed at it regardless of whether it has drawn the
previous one, so a faster renderer may simply grow a queue. See the open
question in `prompts/drag_highlight_stage_3_damage_band.md`.

**Both were then resolved by a further operator test, and both readings were
withdrawn.** Dragging rapidly for 2-3 seconds and stopping with the button
still held made the highlight **snap into place immediately** — there is no
growing queue, so md-viewer is not outrunning the terminal and pacing is not
the fix. Re-tested, the operator reports the difference between
`fast_png_encode` `true` and `false` is negligible; the earlier "slightly
faster" was noise. Byte count therefore has no demonstrated effect on the
gesture, and **`fast_png_encode` stays defaulted to `true`** — a measured
renderer improvement with no measured downside, and one that will matter again
once damage bands make the capture floor and encode the dominant remaining
cost.

The same session produced the clearest justification yet for a damage band: in
the operator's words, dragging across **two words takes the same time as
dragging a very large distance**. A two-word change currently costs a full
4.04M-pixel frame.

**One tension remains unexplained and is recorded as open in the stage 3
prompt.** Removing 67ms of renderer time per frame was imperceptible, while
shrinking the viewport 10x was dramatic. A pixel-proportional cost therefore
lives downstream of the renderer, is not `retina_image_update_ms`, and is not a
queue. Stage 3 opens by measuring the real in-situ frame period and the
`<LeftDrag>` delivery rate before touching the placement path, because that
measurement can invalidate the damage-band plan far more cheaply than the
placement work can.

---

## Post-Part-7 follow-up: drag-highlight responsiveness, stage 4 — overlay the selection (implemented, NOT committed)

**Status: implemented and headlessly verified; awaiting operator validation in
a real iTerm2. Deliberately not committed — the operator validates first.**
The open tension stage 2 left behind ("a pixel-proportional cost lives
downstream of the renderer") is resolved by construction: a moving drag frame
no longer ships pixels at all.

### What step 1 established (the terminal probe)

The operator ran a throwaway probe script — deliberately not kept in the tree —
in both terminals on 2026-08-07:

- **iTerm2: full pass.** Translucent image alpha-composites over the base;
  crop-of-sheet placements render at natural size; X/Y sub-cell offsets are
  honored — in **device pixels**, while iTerm2 reports cell size via CSI 14t
  in points and never answered CSI 16t (the probe's "which bar matches the
  bracket" check existed for exactly this); z between images works both ways
  (z=-3 fully hidden below the base, later-created wins at equal z); a 40fps
  every-rect-replaced churn ran smooth at avg 333 B/frame; deletion left the
  base intact. iTerm2's known text-vs-graphics margin shift applies to base
  and overlay equally, so highlight-to-page alignment is unaffected.
- **WezTerm: disqualified.** Natural-size outlined bars did not render at
  their positions, an unexplained striped artifact appeared, and the terminal
  application **crashed** on entering the churn check. md-viewer must never
  send this workload to WezTerm.
- **Operator decision:** per-profile gate. `terminal.lua` profiles carry
  `selection_overlay` (true only for iTerm2, with the probe date; WezTerm's
  caveat records the crash); `interaction.selection_overlay = "auto"|"on"|"off"`
  overrides. WezTerm keeps the stage-2 full-frame drag path unchanged. Stage 3
  (damage band) was not implemented and is shelved as the WezTerm candidate.

### The design as built

- **Renderer** (`renderer/src/interact.js`, `browser.js`, new
  `overlay-sheet.js`): `selection_preview` accepts `capture: false` — the same
  queued evaluate that applies the selection and reads its text also measures
  its geometry (`rects`, CSS px, viewport-clipped, capped at 256 with
  `rectsTruncated`), so the picture and the copyable string can never come
  from different requests. Geometry matches the *measured* Chromium paint:
  per-text-node quads for ragged horizontal extents (never an element border
  box), vertical extents expanded to the containing block's line box
  (uniform across mixed-font lines, tiling between lines), one-char-advance
  stubs for blank lines. Results carry `selectionTint`; `overlaySheetPng`
  (a cached solid RGBA PNG) is returned only when the envelope asks.
- **The selection color is now pinned.** `preview*.css` had no `::selection`
  rule; Chromium's defaults measured rgba(97,97,97,.846) dark /
  rgba(189,189,189,.576) light — too opaque for an overlay that sits above
  glyphs. `--selection-bg` pins dark rgba(220,220,220,.3) and light
  rgba(128,128,128,.3), chosen so the composite over the page background is
  bit-identical to the previous look (dark #575757, light #d9d9d9);
  `SELECTION_TINT` in interact.js is the same constant.
- **Lua** (`kitty_raw.lua`, `controller.lua`, `interaction.lua`, `config.lua`,
  `terminal.lua`, `debug.lua`): one tint sheet uploaded per color (~27KB
  base64, once); every rectangle is a crop placement at natural pixel size
  with X/Y sub-cell remainders plus the `raw_cell_offset_px` calibration
  (with cell carry); rect sets are diffed — unchanged rects keep their
  placements, new ones are emitted before superseded ones are deleted, one
  write; exclusions (passive floats) are subtracted in pixel space. The
  iTerm2 profile's base z moved -1 → -2 so the overlay owns -1, both under
  text (the probe ran its base at -2 throughout). `display_selection_overlay`
  refuses any result whose revision or scroll does not match the frame on
  screen; every full frame (settle, scroll, render), placement move,
  occlusion, close, restart, or content change clears the overlay — always
  after the superseding frame is placed. Moving frames fall back to the
  captured path per gesture on any failure (sticky), except a missing sheet,
  which retries exactly once with the sheet attached. The commit frame always
  captures at device scale. `cells`/`nvim_img` backends: no overlay surface,
  path auto-off.

### Measured results

- **Wire cost per moving frame: ~91–500 bytes** of placement escapes (live
  drive, real input layer → real renderer → real Chromium; the terminal
  byte sink was the only fake), **zero pixels**; an unchanged frame diffs to
  **zero bytes**. Before: ~471–755KB PNG ≈ 1MB base64 per frame. Renderer
  round trip for a no-capture preview: ~5.7ms measured (was ~36.5ms with
  capture).
- **Composite equivalence** (tests/node/selection-tint.test.js, dark, dsf 2):
  base + tint at the reported rects vs the browser's own selection_commit
  capture — **0 mismatched samples across 1.73M flat-background samples**;
  edge-band differences 0.83% of all samples (band edges land within ~1 CSS px
  of Chromium's asymmetric half-leading; Chromium additionally paints a
  ~4.8px end-of-line stub the overlay skips); glyph-pixel differences 2.0%
  (the overlay tints glyphs from above during motion; the browser paints
  under them — settle corrects it). Both themes' ::selection paints verified
  bit-exact against `SELECTION_TINT` under Chromium's real compositing model
  (alpha quantized to 77/255, then rounded integer src-over).

### Tests run (all green)

- `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer`
- `NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua` — **827 assertions** (+72)
- `npm test --prefix renderer` — **150/150** (+8: capture opt-out, overlaySheet
  validation, rect passthrough, sheet builder, both tint pins, preview
  semantics/shape guards, composite equivalence)
- `stylua --check lua/ plugin/ tests/lua/` — clean
- Live drive `scripts/stage4-live/drive.lua`: 16/16 checks —
  real `nvim_input_mouse` gestures through the real mappings, envelopes
  recorded and answered by the real renderer, `:MdViewerDebug` and
  `:MdViewerHealth` invoked as the exact user commands (their output gained
  overlay fields).

### Known limitations and unresolved risks

- **The rectangles are too tall.** See "Operator validation, 2026-08-08" below.
  Speed is confirmed; geometry is not.
- The settle frame lands and the overlay placements are deleted in separate
  `nvim_ui_send` writes microseconds apart; a terminal could composite one
  frame of doubled tint at release. Not observed in the probe; operator will
  see it if it exists.
- The overlay skips Chromium's ~4.8px end-of-line continuation stubs; blank
  lines and everything else are reproduced.
- Selected images: the overlay tints the image's border box; unvalidated
  against Chromium's paint for images (no image in the equivalence fixture).
- `interaction.selection_overlay = "on"` exists to force the path for
  validating other terminals; kitty/ghostty remain off pending their own probe
  run.
- RTL text: rect extents come from client quads and should be honest, but no
  RTL fixture was tested.

### Operator validation, 2026-08-08 — speed confirmed, geometry wrong

The operator dragged in real iTerm2. **Speed: confirmed.** Dragging and
highlighting are snappy with essentially instant feedback, and the handoff from
overlay to settle frame reads as instant — the doubled-tint frame listed above
as a theoretical risk was not seen.

**Geometry: wrong.** The overlay rectangles are visibly taller than the
highlight Chromium paints on release. Inside a fenced code block, adjacent
lines' bars touch with no gap at all, where the real selection leaves clear
gaps between lines.

Measured by decoding the operator's two screenshots pixel by pixel (device px
÷ 2 = CSS px):

| Element | Overlay band | Chromium band | The block's CSS `line-height` |
|---|---|---|---|
| `h2` | 30.0 CSS px | 25.0 CSS px | `1.25 × 24px` = 30 |
| `h3` | 25.0 CSS px | 20.5 CSS px | `1.25 × 20px` = 25 |

Band tops agree to within 1 device px and left edges to within 1 CSS px, so
placement is correct — the rect only over-extends downward, and the overlay
band lands on the block's CSS `line-height` **exactly** in both cases.

That is `resolveSelectionInPage`'s `banded` loop in `renderer/src/interact.js`
doing what it says: expanding each text quad to `blockLineHeight(quad.parent)`.
Chromium does not paint the full line box. `pre` is the worst case —
`font-size: .92em` against `line-height: 1.55` leaves ~8 CSS px of leading —
which is why the code-block bars collide. **The Lua path is not at fault**;
`kitty_raw.lua` places what it is handed, which is why the measured band lands
on the CSS value to the pixel.

Fact 2 in that loop's comment ("the paint spans the full LINE BOX") is
therefore wrong for at least headings and `pre`, and
`tests/node/selection-tint.test.js` encoded it as an assertion (`tiled >= 2`,
"consecutive selected lines must tile"), which is why the gate could not catch
this. Correcting the rule and the gate is the next stage's work.

### Two defects found in the tree at commit time

Recorded because both contradict this document's earlier claim that every gate
was green:

1. `tests/node/selection-tint.test.js` did not parse — ~56 lines of a written
   report had been appended to it as raw Markdown after the final `});`.
   `npm test --prefix renderer` globs `../tests/node/*.test.js`, so the Node
   gate was red, not green. Removed before committing.
2. Four production files referenced `scripts/stage4-overlay-probe.mjs`, which
   was never in the tree. The probe was a throwaway; the references now
   describe the 2026-08-07 validation without naming a file. Other terminals
   are qualified instead via `interaction.selection_overlay = "on"`, which
   already bypasses the per-profile gate.

### Stage 5 — the rectangles were sized in the wrong pixels

The stage-4 defect above was diagnosed twice, wrongly the first time. Both
dead ends are recorded because each was a plausible reading of real evidence.

**First hypothesis, killed by measurement.** The overlay bands measured exactly
the block's CSS `line-height` while Chromium's measured ~0.83 of that, so
`interact.js` looked like it was over-expanding text quads to the line box. A
harness driving real Chromium against the real preview CSS says otherwise:

| element | CSS `line-height` | Chromium's painted band |
|---|---|---|
| `h1` | 40.0 | 40.00 |
| `h2` | 30.0 | 30.00 |
| `h3` | 25.0 | 25.00 |
| `li`, `blockquote`, `td` | 25.0 | 25.00 |

Chromium paints the full line box to the hundredth of a pixel. `interact.js` is
correct, the `tiled >= 2` assertion is correct, and the gate passed because
there was nothing renderer-side to catch.

**Second hypothesis, confirmed.** `coordinates.viewport`'s "estimated" tier
guesses a 10×20 CSS px cell (`config.lua`'s `estimated_cell_width_px` and
`cell_aspect_ratio` defaults) and, as its own comment says, "lets the terminal
scale the PNG". Everything else addresses the preview in **cells**, so a wrong
guess is invisible — the image is squeezed into the right cell box either way,
and only sharpness pays. Overlay crops carry no `c`/`r` keys and therefore
display at natural **pixel** size, making them the first thing in the plugin
whose correctness depends on the guess being right.

Measured on the operator's iTerm2: real cell 14×32 physical px against a
guessed 20×40, so a 1980×2040 capture is drawn into 1386×1632. `overlay_apply`
scaled rects by `item.width_px / viewport.widthPx` = 2.0 where the drawn scale
is 1.4 — 1.43× too wide and 1.25× too tall. Measured from the operator's
screenshots: **1.40× and ~1.24×**. Positions were unaffected throughout because
they resolve to cells.

**The fix.** `lua/md-viewer/cellpixels.lua` measures the cell from
`TIOCGWINSZ`'s `ws_xpixel`/`ws_ypixel` via LuaJIT FFI — no escape sequence and
nothing to read back, which is what made this unobtainable before (Neovim owns
terminal input and cannot read a CSI reply). `overlay_apply` now scales against
`placement.width × cell.width`, the box the image is drawn into. Where the cell
cannot be measured the overlay refuses — a precondition `selection_overlay =
"on"` deliberately cannot override, since it is a correctness requirement and
not a capability judgement — and the captured-frame path takes over.

Verified on the operator's terminal: `ioctl` reports `208x55 cells,
2912x1760 px` → 14.00 × 32.00 px per cell, exactly.

**Operator validation, 2026-08-08 (second pass).** "REALLY REALLY CLOSE now and
basically really good." Measured from the operator's during/done screenshot
pair: band height identical (110 px both), width 346 vs 345 px. The geometry is
correct to within one pixel; what remains visible is the tint compositing above
glyphs during a drag versus under them after, plus the end-of-line stubs the
overlay still skips.

### Stale highlight surviving into the next gesture

Reported in the same pass: select a code block, release, then drag out a new
selection elsewhere, and the first highlight stays on screen for the whole
second drag.

The frame under a drag is the browser's own capture, and after a selection
settles that capture has the selection painted into it. Overlay rectangles
composite *over* it, so they can add a highlight and never remove one — a second
gesture inherits the first one's paint.

`apply_image` now records `base_selection_painted` for every frame it places
(true exactly when a DOM selection was live at capture time — `selection_active`
is always updated before the frame is displayed). `overlay_ready` refuses a
painted base and calls `controller.restore_clean_base`, which re-places the
newest cached selection-free capture. That is a local re-upload measured at
~1.4 ms on the operator's terminal, not a renderer round trip, so it can run on
a drag's first frame. It refuses — and the gesture drops to captured frames for
its duration — whenever the cached frame cannot be proven to match what is on
screen: no cache, a different scroll position, or a different content revision.
Interact frames never populate that cache (they are the ones that carry
selection paint), so the only way it could go stale is a render or scroll
capture taken while a selection was live, which is exactly the case the
`selection_active` guard drops.

### Safe stopping point and first next action

Stage 4 is committed. The tree is coherent: the overlay path is live on iTerm2
and confirmed fast by the operator, every other terminal is untouched, and the
settled highlight after release is the browser's own paint in every case — so
the known geometry defect is confined to the moving frames of a drag and
corrects itself the instant the mouse comes up.

The stage-5 fix above is in the working tree, uncommitted, awaiting the
operator's eyes in a real iTerm2 — headless Lua stubs the transport and never
reaches a terminal, so no automated result can speak to this.

First next action, in order:

1. **Operator validates the rectangle geometry.** Drag across a fenced code
   block (adjacent lines must have visible gaps and must not touch), a heading,
   prose, a list, a table, and a line mixing prose with `inline code` (one band,
   not two). Release and watch the transition: the highlight must not change
   size or colour as the settle frame replaces the overlay.
2. **Confirm the overlay is still on**, via `:MdViewerHealth` →
   `cell_pixels`. A terminal or multiplexer that does not fill in
   `ws_xpixel`/`ws_ypixel` now disables the overlay by design; the reason says
   so verbatim.
3. Then commit, and record the hash in `prompts/README.md` row f6.

Two things are deliberately **not** done, and are the natural next stage:

- **The preview is still resampled.** With the "estimated" tier the capture is
  1980×2040 drawn into 1386×1632 — a ~30% downscale on every frame, paid for at
  full render cost. `cellpixels` now knows the exact number that would make it
  1:1; feeding it into `coordinates.viewport` as a "measured" calibration tier
  (the slot its own comment reserves) would make the preview pixel-perfect and
  render text at true size. It is a visible change to how much document fits on
  screen, so it wants the operator's eye and its own commit.
- **End-of-line continuation stubs.** Chromium paints ~4.8 CSS px past the last
  glyph of a soft-broken line; the overlay skips it. The operator asked for
  parity. Deferred so the geometry fix could be validated on its own.
