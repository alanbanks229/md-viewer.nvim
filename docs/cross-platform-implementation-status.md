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

Parts 1–2 were merged to `main` via PR #1. Part 3 is on the branch
`feat/interaction-transport`, cut from `main`, and has not been pushed.

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

## Safe stopping point and first next action

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
