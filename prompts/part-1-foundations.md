---
part: 1
title: Foundations — capability layer, browser discovery, CI, test harness
status: not-started
model: Sonnet 5
depends_on: none
commit: ""
---

# Part 1 of 7 — Foundations

> Read `prompts/00-policy.md` first. It defines the invariants, verification
> commands, and the closing checklist that this part must follow.

## Objective

Replace terminal detection guesswork with a real capability model, make Chromium
discovery work off macOS, and put a cross-platform test signal in CI. Nothing
user-visible changes except that detection becomes correct and honest.

This part unblocks everything else. Get it right rather than fast.

---

## Verified repository facts

These were confirmed by direct inspection. Trust them; do not spend tokens
rediscovering them. Verify only if something contradicts what you see.

**Terminal detection is currently a dead end.** `lua/md-viewer/backends/kitty_raw.lua`
`M.detect()` returns `false` on *every* path — even when the terminal is iTerm2
or Kitty, its last line returns
`false, "Kitty graphics advertised but active response probe not confirmed"`.
This is deliberate: Neovim owns terminal input, so a synchronous protocol probe
would steal user keystrokes, and the author refused to fake success.

The consequence is that `lua/md-viewer/backends/init.lua` `M.select("auto")`
**never** selects `kitty_raw` — it falls through to `cells`. The raw backend is
reachable only by explicit `image.backend = "kitty_raw"`, and only through this
fragile escape hatch in `init.lua`:

```lua
if requested == "kitty_raw" and reason and reason:match("active response probe") then
  return backend, reason
end
```

Matching on an error string is the thing you are replacing.

**Chromium discovery is macOS-only.** `renderer/src/browser.js` has a
three-entry hardcoded list:

```js
const knownChromium = [
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
];
```

`resolveExecutable()` honours `options.executable_path` first, then scans that
list with `fs.existsSync`, then returns `null`.

**Existing config surface** lives in `lua/md-viewer/config.lua` as
`M.defaults` with sections `split`, `preview`, `render`, `browser`, `image`,
`sync`, `security`. Validation is a `validate(cfg)` function of `assert()` calls.
There is no `terminal` section yet.

**Test layout.**
- Lua: `tests/lua/run.lua` is a single **285-line linear script** — not a test
  framework. `tests/lua/harness.lua` provides only `t.eq`, `t.ok`, `t.finish`.
  Run via `nvim --headless -u NONE -i NONE -l tests/lua/run.lua`.
- Node: five files in `tests/node/*.test.js` using `node --test`. Invoked as
  `npm test --prefix renderer` → `node --test ../tests/node/*.test.js`.

**CI** (`.github/workflows/ci.yml`) runs on `macos-latest` only, with no lint
step, despite `stylua.toml` existing at the repo root.

---

## Read these files first

```text
lua/md-viewer/backends/kitty_raw.lua
lua/md-viewer/backends/init.lua
lua/md-viewer/backends/nvim_img.lua
lua/md-viewer/config.lua
lua/md-viewer/health.lua
lua/md-viewer/debug.lua
renderer/src/browser.js
tests/lua/run.lua
tests/lua/harness.lua
tests/node/browser.test.js
.github/workflows/ci.yml
```

Do not read `renderer/node_modules/`.

---

## Implement

### 1.1 Test harness restructure (do this first)

`tests/lua/run.lua` will roughly triple in size across this project. A single
linear script will not survive that.

Split it into `tests/lua/cases/*.lua`, each returning a function that takes the
harness table. `run.lua` becomes a loader that discovers and runs them in a
stable, sorted order and calls `t.finish()` once.

- Preserve every existing assertion. The pass count must not drop.
- Add `t.near(expected, actual, tolerance, label)` to the harness — geometry
  work in Part 2 needs float comparison.
- Keep the harness dependency-free. Do not add a test framework.

Migrate the existing assertions into cases split by subject (config, backends,
coordinates, controller, navigation, process). Do this as the first change so
everything afterwards lands in the new structure.

### 1.2 Terminal capability module

Create `lua/md-viewer/terminal.lua`.

Expose profiles for: `iterm2`, `kitty`, `wezterm`, `ghostty`, `warp`,
`generic_kitty`, `unknown`.

Each profile reports at minimum:

```lua
{
  id = "wezterm",
  evidence = { "TERM_PROGRAM=WezTerm" },  -- what was actually observed
  platform = "linux",                      -- macOS / linux / windows
  graphics = "inferred",                   -- explicit | verified | inferred | unavailable
  default_raw_zindex = -1,
  placement = { ... },                     -- placement / deletion / crop assumptions
  multiplexer = "none",                    -- tmux | screen | zellij | none
  validation = "protocol-compatible-but-unvalidated",
  caveats = { "..." },
}
```

Detection evidence should draw on `TERM_PROGRAM`, `TERM`, `KITTY_WINDOW_ID`,
`WEZTERM_EXECUTABLE`, `GHOSTTY_RESOURCES_DIR`, `WARP_*`, `TERM_PROGRAM_VERSION`,
and `TMUX` / `STY` / `ZELLIJ`. Record *which* variable matched — health output
must be able to explain itself.

**Capability resolution order**, strictly:

1. Explicit user configuration (`terminal.kitty_graphics = "on" | "off"`).
2. Verified `vim.ui.img` support.
3. A safe asynchronous graphics probe — **only if** you can implement one that
   provably cannot consume or corrupt normal Neovim input. If you cannot, leave
   the probe unimplemented and default `terminal.probe = "off"`. Do not ship a
   probe you are not confident in.
4. Conservative terminal-profile inference.
5. Text-cell fallback.

A profile match yields `graphics = "inferred"`. It must **never** yield
`"verified"`.

### 1.3 Wire capability into backend selection

Rewrite `backends.select()` to consult `terminal.lua` instead of string-matching
error messages. Delete the `reason:match("active response probe")` hatch.

Behaviour change: `image.backend = "auto"` may now select `kitty_raw` on the
strength of *inferred* capability. That is the point of this part — the plugin
should work out of the box on a Kitty-compatible terminal. Report the confidence
level in health output so the user knows it was inferred, not verified.

Preserve the ability to force any backend explicitly, including forcing `cells`.

### 1.4 Configuration

Add a `terminal` section to `config.lua` defaults:

```lua
terminal = {
  profile = "auto",         -- or an explicit profile id
  kitty_graphics = "auto",  -- "auto" | "on" | "off"
  probe = "off",            -- "off" | "safe"; see 1.2 step 3
}
```

Validate profile ids and enum values with actionable error messages, matching
the existing `assert()` style in `validate()`.

### 1.5 Cross-platform Chromium discovery

Extract discovery from `browser.js` into `renderer/src/browser-discovery.js` so
it is unit-testable without launching anything.

Contract: given a platform, an environment object, and a file-existence
predicate, return the chosen executable path and the reason it was chosen.
Injecting those three makes every branch testable on any OS.

- **Explicit `executable_path` always wins.** If it is set and does not exist,
  throw the existing actionable error.
- **macOS** — the three current paths, plus Homebrew locations
  (`/opt/homebrew/bin`, `/usr/local/bin`) and `~/Applications` equivalents.
- **Linux** — search `PATH` for `google-chrome`, `google-chrome-stable`,
  `chromium`, `chromium-browser`, `microsoft-edge`, `microsoft-edge-stable`;
  then `/usr/bin`, `/usr/local/bin`, `/snap/bin`, and Flatpak locations.
- **Windows (best-effort)** — search `PATH` honouring `PATHEXT`, then
  `PROGRAMFILES`, `PROGRAMFILES(X86)`, and `LOCALAPPDATA` Chrome/Edge
  directories. Use `path.win32` semantics. Implement it and test it with mocks,
  but **do not advertise Windows as supported.**

Never invoke `playwright install`. Never download a browser. Return an actionable
error naming what was searched, and surface the selected executable in health
output.

### 1.6 CI matrix

Update `.github/workflows/ci.yml`:

- Run the job on both `macos-latest` and `ubuntu-latest`. Cross-platform code
  with single-platform CI is a claim, not a fact.
- Add a `stylua --check` step. `stylua.toml` already exists and is unused.
- Keep `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` and `npm ci --ignore-scripts`.
- If a test needs a real Chromium and Linux runners lack one, skip that test
  explicitly by name rather than weakening it. Note the skip in the status
  document.

### 1.7 Diagnostics

Extend `:MdViewerHealth`, `:MdViewerDebug`, and `:checkhealth md-viewer` to
report: detected profile, the evidence that produced it, capability confidence
(explicit / verified / inferred / unavailable), selected backend and why,
effective z-index, platform, multiplexer status, discovered browser executable,
and validation status.

The user must be able to read health output and understand exactly how the
plugin reached its conclusion.

---

## Do not do in this part

- Do not rewrite the image placement backend — that is Part 2.
- Do not touch geometry or coordinate conversion — that is Part 2.
- Do not add mouse interaction, the `interact` protocol, or DOM work.
- Do not add a Sixel backend. Keep the backend interface extensible and leave it.
- Do not claim tmux support. Detect multiplexers, warn, and stop there.

---

## Tests to add

**Lua** (`tests/lua/cases/terminal.lua`):
profile detection per terminal from synthetic environments; explicit profile
override; `kitty_graphics = "on" | "off"` overriding inference; unknown terminal
falls back to `cells`; resolution-order precedence; multiplexer detection;
capability confidence is never `verified` from environment variables alone;
`terminal` config validation rejects bad values.

**Node** (`tests/node/browser-discovery.test.js`):
each platform's search order with a mocked filesystem and environment; explicit
path wins; explicit missing path throws; `PATH` and `PATHEXT` handling on
Windows; not-found produces an actionable error listing what was searched.

**Regression:** every pre-existing assertion still passes after the harness
restructure.

---

## Acceptance criteria

- [ ] `tests/lua/cases/` exists; `run.lua` is a loader; no assertions were lost.
- [ ] `lua/md-viewer/terminal.lua` exposes all seven profiles.
- [ ] Capability states distinguish explicit, verified, inferred, and unavailable.
- [ ] No code path reports `verified` on environment-variable evidence alone.
- [ ] The `reason:match("active response probe")` hatch is gone.
- [ ] `image.backend = "auto"` can select `kitty_raw` from inferred capability.
- [ ] `renderer/src/browser-discovery.js` is pure and unit-testable.
- [ ] Discovery covers macOS, Linux, and Windows; Windows is not advertised.
- [ ] No `playwright install`; no browser download.
- [ ] CI runs on macOS and Ubuntu and includes `stylua --check`.
- [ ] Health output explains its detection evidence and confidence.
- [ ] All Lua and Node tests pass.
- [ ] `docs/cross-platform-implementation-status.md` created per policy §6.

---

## Commit

```text
feat(md-viewer): cross-platform preview part 1/7 - capability and browser foundation
```

Then follow `prompts/00-policy.md` §6 (closing) and §7 (reporting).
