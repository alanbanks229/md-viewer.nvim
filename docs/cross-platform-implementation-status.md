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
| 4 | Mouse layer, click-to-source, safe links | `e3139e8` |
| 5 | Exact source provenance — inline mapping, byte-accurate columns | `1db9cfe` |

Parts 1–2 were merged to `main` via PR #1. Parts 3–5 are on the branch
`feat/interaction-transport`, cut from `main`, and have not been pushed.

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
