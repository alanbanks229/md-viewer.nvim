# Cross-Platform Implementation Status

This document is the handoff record for `prompts/`. It is created by Part 1 and
updated by every subsequent part. It records what is actually true of the
repository right now, not what was planned.

---

## Completed parts

| # | Part | Commit |
|---|------|--------|
| 1 | Foundations — capability layer, browser discovery, CI, test harness | `c638674` |

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

---

## Tests run and results

```
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
  -> added 30 packages, 0 vulnerabilities

NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
  -> md-viewer Lua tests: 124 assertions passed

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

## Known limitations and unresolved risks

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

## Decisions that changed assumptions in the original specification

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

## Safe stopping point and first next action

The tree is green: all four policy §5 commands pass, nothing is known to be
broken, and every change is committed as a single reviewable unit (see commit
hash at the top of this document once recorded).

**First next action for Part 2:** read `prompts/part-2-portable-rendering.md`
fresh (do not carry this session's context forward — `/clear` first per
`prompts/README.md`). Part 2 should consume `terminal.lua`'s capability
report (in particular `profile.placement`, `default_raw_zindex`, and
`multiplexer`) when de-iTerm2-ing the Kitty backend's placement and geometry
assumptions, rather than re-deriving terminal identity itself.
