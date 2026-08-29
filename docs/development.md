# Development

## Repository layout

- `lua/md-viewer/`: configuration, sessions, lifecycle, synchronization,
  placement, health checks, and renderer-process control
- `lua/md-viewer/backends/`: `vim.ui.img`, raw Kitty protocol, and text-cell
  display backends
- `plugin/md-viewer.lua`: runtime entry point and default highlights
- `renderer/src/`: persistent Node.js renderer, Markdown pipeline, browser
  lifecycle, protocol, source maps, and security policy. `service.js` is what a
  request *means*; `main.js` is the stdin/stdout entrypoint that decides where
  requests arrive from
- `renderer/assets/`: bundled preview themes and syntax colors
- `tests/lua/`, `tests/node/`: headless suites
- `tests/fixtures/`: Markdown documents both suites and the manual checklist use
- `scripts/`: harnesses needing a real browser, a real terminal window, or a
  real remote host — `overlay/`, `resident/`, `animation/`, `scroll-scale/`,
  `remote-images/`, `rig/`, `local/`, and `ssh-link-speed.sh`. None of it runs
  in CI; see [../scripts/README.md](../scripts/README.md)
- `doc/md-viewer.txt`: `:help md-viewer`
- `docs/`: architecture, terminal support, troubleshooting, development, the
  and slow links

## Bootstrap

```sh
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
```

Both the environment variable and `--ignore-scripts` are security measures, not
conveniences: they prevent Playwright or dependency lifecycle scripts from
downloading a browser or running install-time code. This command may contact the
configured npm registry; runtime rendering does not.

## Automated tests

```sh
make test            # both suites
stylua --check lua/ plugin/ tests/lua/
```

`make test` is the two suites; `stylua` is a third check with no `make` target.
CI runs all three on macOS and Ubuntu for every push and pull request, with
Neovim pinned to `v0.12.4` and stylua to `v2.5.2` (`.github/workflows/ci.yml`) —
match those locally or expect spurious diffs. The Lua suite needs Neovim 0.12+
for the same reason the plugin does. The browser suites require an existing
Chrome or Chromium installation; no test downloads a Playwright-managed browser.

To run less than everything:

```sh
make test-lua                                   # the Lua suite alone
make test-node                                  # the Node suite alone
node --test tests/node/hitbox.test.js           # one Node case
```

**There is no single-case runner for the Lua suite.** `tests/lua/run.lua` globs
`tests/lua/cases/*.lua` and runs all of them, with no filter argument and no
environment variable — run the suite.

The headless suites prove the request/response plumbing, staleness handling,
sanitization, hit-test geometry, source provenance, selection and search
semantics, placement encoding, and capability resolution. **They cannot see a
pixel.** Nothing automated can tell you whether the image is composited where it
should be, whether a highlight is visible, whether anything flickers or rolls,
whether a real click lands on the thing under the pointer, or how a terminal
behaves when the plugin exits.

Three harnesses under `scripts/overlay/` cover part of that gap — an end-to-end
vim-motion selection regression against a real browser, a pixel-asserting
geometry rig, and an overlay stress rig. [../scripts/README.md](../scripts/README.md)
says what each proves and when to run it. The selection regression needs no display:

```sh
nvim --headless -u NONE -i NONE -l scripts/overlay/live/drive.lua
```

## Manual verification

Required before tagging any release, and for any change touching placement,
interaction, or the overlay. Do not start against a red tree — every failure you
find by hand must be attributable to the terminal, not to a known-broken build.

**Setup.** Open `tests/fixtures/kitchen-sink.md`, or
`tests/fixtures/provenance-comprehensive.md` for multibyte and emoji cases, with
`image.backend = "kitty_raw"` set **explicitly**, outside tmux/screen/Zellij.
Record the terminal name and version, OS, `TERM`/`TERM_PROGRAM`, Neovim version,
and whether HiDPI scaling is active. A result with no environment recorded is not
usable evidence. Sanity-check at least one terminal from the `Supported` set in
[terminal-support.md](terminal-support.md), plus whichever others you have.

Attach a screenshot for anything visual. For alignment and bleed-through a
screenshot is the *only* acceptable evidence — the protocol specification will
not tell you.

### Rendering and sync

| Check | How | Expect |
|---|---|---|
| Image renders | `:MdViewerToggle` | A rendered page filling the split, correctly sized and positioned, with no hand-tuned `render.*` config |
| Live preview | Edit without `:w` | Follows within the debounce interval |
| Cursor follow | Move through the source | The preview scrolls to match |
| Scrolling | `j`/`k`, `Ctrl-d`/`u`, `Ctrl-f`/`b`, `gg`/`G`, wheel over the preview | Smooth, no flicker, no stray image. The wheel does nothing when the pointer is outside the preview |
| Resize and font size | Resize the window, then change the terminal's font size | Re-renders at the new geometry and stays aligned |
| Scroll scale, locally | Wheel-scroll, then `:MdViewerDebug` | `scroll_scale = nil`, source `local session`. Nothing about a local preview may change: this is the byte-identical path |
| Scroll scale, over SSH | The same from an SSH session | `scroll_scale = 0.5`, source naming `ssh_scroll_scale`, and `fast_png_bytes` 2.6x to 3x below what the same pane reports locally |
| Settle sharpness | Scroll hard over SSH, then stop and look | The moving frame may be visibly soft; the frame that lands after `render.ssh_scroll_settle_ms` (400 ms, against 160 locally) is sharp. A preview that stays soft at rest is the failure this option can cause |

### The preview caret

| Check | How | Expect |
|---|---|---|
| Shaped like the glyph | Caret on an `# H1`, then on body text | A block the size of the character it is on — visibly larger on the heading, not a fixed cell |
| Never on nothing | Click right of a short heading; click in the left margin | Snaps onto the nearest real character; never hovers over blank space |
| Neovim's cursor is hidden | Focus the preview, then leave it | Only the block caret while focused; the ordinary cursor returns everywhere else, including after `:q`, a tab switch, and `:qa` |
| Only one caret after refocusing | Focus the preview, switch to another app, switch back, press nothing | Still only the block caret — Neovim's own must not be sitting beside it |
| Backward motion never sticks | `$` on a heading, then hold `h` to its first letter | Every press moves one glyph. It must not stop on a glyph and refuse to leave; `l` back across the same heading visits the same glyphs, skipping none |
| `l` stops at the end of a line | Hold `l` along a rendered line, including one mid-paragraph | Stops at that line's last glyph; does not slide onto the line below. `h` likewise stops at the first |
| `w` does not skip a word | Caret on a heading's last word, then `w` | Lands on the **first** word of the next block. Same at the end of a list item |
| Column is held | Caret on the first letter of an `# H1`, then `j` | Lands on the *first* letter of the line below |
| Round trip | `j` to the bottom, then `k` back to the top | Returns to the character it started on |
| Line ends | `0`, `$`, then `j` after `$` | After `$`, `j` keeps following line ends down |
| Counts and scroll | `10l`, `3j`; hold `j` past the bottom; `<C-d>`, `<C-f>` | Counts apply; the view scrolls to keep the caret visible |
| Caret stays put under `<C-e>` | `<C-e>` until the caret leaves the view | The view moves, the caret does not; it stops being drawn off screen and returns when scrolled back |
| Document ends | `gg`, `G`, `30G` | `30G` does the same as `G` — the count is ignored, not reinterpreted |
| Click agreement | Click somewhere, then press `l` | Continues from where you clicked |
| Non-overlay terminal | The same on WezTerm | Falls back to the terminal's cursor: a fixed cell, but on the right character. Neovim's cursor is *not* hidden there |

### Selection, search, and links

| Check | How | Expect |
|---|---|---|
| No drag mapping | Click and drag across a paragraph | Nothing highlights. Neovim may briefly show `V-BLOCK`/`-- VISUAL --` (its own unmapped-drag fallback) and recover on its own within a tick — see docs/troubleshooting.md |
| Click-to-deselect | Click once with a selection active | The highlight clears. The **source cursor does not move** — under any gesture |
| Click places the caret | Click on a word | The caret snaps to the nearest real character there |
| Copy | `y` or `:MdViewerCopy` | Unnamed register, and the system clipboard where available. Nothing is copied automatically |
| Search | `/` or `:MdViewerFind`, then `n`/`N`, then `/` dismissed with Escape | Matches highlight, stepping wraps, dismissing the empty prompt removes them |
| Visual mode | `v`, `3j`, `y`; then `V`, `j`; then `v`, `3j`, `o`, `k` | The highlight follows; the winbar shows `-- VISUAL --` / `-- VISUAL LINE --`; `o` swaps ends; `y` copies and leaves |
| Multi-paragraph | `v`, motions across a block boundary | The selection spans both |
| Word / block | `v`/`V` plus `w`/`b`/`e`, `{`/`}` | Extends by word, then by block, matching the motion's own semantics |
| Past the viewport | `v`, then `G` | Scrolls and keeps extending to the end of the document |
| Escape precedence | `v`, motion, `<Esc>`, `<Esc>` | First leaves visual mode keeping the highlight; second clears it |
| Multibyte columns | Ctrl/Cmd-click `café`, `日本語`, an emoji in `provenance-comprehensive.md` | `:MdViewerDebug` reports an exact byte column landing inside the line it names |
| External link | Ctrl/Cmd-click an `http(s)` link | Opens in the system browser, or says why it did not |
| Local Markdown link | Ctrl/Cmd-click a relative `.md` link | Opens or reuses a preview tab; the editable source window and focus stay unchanged |
| Repo-relative link | Follow `../README.md` from a subdirectory | Resolves; not refused as outside the document root |
| Missing target | Ctrl/Cmd-click a link to a nonexistent file | Reports *does not exist* — not *outside the document root* |
| Small target | Ctrl/Cmd-click a one-word link at the start of a line, at the default font size | Activates. This is the case that used to be unreachable at some cell alignments |
| Tabs and history | Follow links, use `[b`/`]b`, then `H`/`L`, close a tab, and go back to it | Tabs affect only the preview; history is independent and recreates the closed document |

### Selection-highlight overlay

Only where `selection_overlay` resolves on — confirm with `:MdViewerDebug`'s
`overlay` row under `-- Raw Graphics (kitty_raw) --`, which reads `on, layer …`
or `off -- <reason>`.

| Check | How | Expect |
|---|---|---|
| Instant highlight | `v`, then extend with a motion | Appears as you move, without the page visibly re-rendering |
| Three gestures in a row | `v`, extend, `y`; repeat twice more, each starting elsewhere | Every gesture behaves like the first. A terminal can draw the overlay correctly once and then silently draw it *underneath* the preview, with every placement still reporting success — one correct gesture proves nothing |
| No stale highlight | Select, `y`, start a new selection elsewhere | The first highlight is gone for the whole second gesture |
| Settled frame | `y`, or `<Esc>` to leave visual mode | The highlight becomes the browser's own paint, without visibly shifting or changing colour |

### Placement, occlusion, and lifecycle

| Check | How | Expect |
|---|---|---|
| Notification opacity | Trigger a notification over the preview | Its background stays opaque; no Markdown shows through |
| No roll or blink | Let that notification appear and disappear | The image does not jump, roll, or blink |
| Splits | Open the preview `right`, `left`, `above`, `below` | Correct placement in each |
| Chrome | With a winbar, a statusline, and `laststatus=3` | None overlaps the image |
| Float | Open a focusable float over the preview, then close it | It occludes; closing restores |
| Tabpage | `:tabnew`, switch away and back | No stranded image over the other tabpage |
| Suspend | `Ctrl-z`, then `fg` | The image comes back intact |
| Repeated open/close | Open and close several times | No stray placements accumulate |
| Teardown | `:qa` | No image left on the terminal, and no Node or Chromium process still running |

## For maintainers

Everything below this line needs hardware, a terminal, or a remote host that a
contributor is not expected to have. A pull request is not held to it; a
release is.

## Qualifying a terminal

Status labels and their evidence bar are defined in
[terminal-support.md](terminal-support.md). Never promote one on the strength of
an environment variable matching, protocol compatibility, or a headless test
passing — three graphical defects this project has shipped and fixed were
invisible to every headless test that existed at the time.

**Before enabling `selection_overlay` for a profile**, run the geometry and
stress harnesses against that terminal and enable it only if both pass:

```sh
scripts/overlay/geometry/run.sh /path/to/Terminal.app
scripts/overlay/stress/run.sh   /path/to/Terminal.app
```

This is also the gate for re-enabling WezTerm's overlay once its upstream fix
ships in a *released* build. It is not a version check.

### Sub-cell calibration

iTerm2 applies its window margin to text but not to graphics placements, landing
the raw image a fraction of a cell toward the origin;
`image.raw_cell_offset_px` and `image.raw_overlay_bleed_cells` exist because of
that one measurement. Whether any other terminal shares the quirk is **unknown**
and cannot be inferred from the protocol specification. Two questions per
terminal:

1. **Does it implement the `X`/`Y` placement keys at all?** Set
   `image.raw_cell_offset_px = { x = 10 }`, open a notification over the preview,
   and look. If the image shifts, it does — record the offset that closes the
   gap. If nothing changes, record `X`/`Y` as unimplemented there and rely on
   `raw_overlay_bleed_cells` alone.
2. **Is the offset a fixed window margin, or does it scale with cell width?**
   Change the terminal's font size once and re-measure.

The measurement is a screenshot, not a calculation: compare the x coordinate of
the image's edge against the x coordinate of the notification's edge.

| Terminal | Implements `X`/`Y`? | Measured offset | Constant or scales? |
|---|---|---|---|
| iTerm2 | Yes | ~10px of a 20px cell horizontally; vertical measured exact | Undetermined — one measurement only |
| WezTerm | Yes, but inset per cell rather than on the first cell only | None needed; content and graphics origins coincide | n/a |
| Kitty, Ghostty, Warp | Unmeasured | — | — |

Warp was driven by hand on 2026-08-11 (see
[terminal-support.md](terminal-support.md#warp)), but the sub-cell offset was
not among what was measured, so it stays `Unmeasured` here.

**Open question.** `raw_cell_offset_px` ships as pixels because iTerm2 measured
at exactly half a cell, which cannot distinguish a constant-10px theory from a
half-a-cell theory, and there is no second data point. If a second terminal — or
iTerm2 across two font sizes — shows the offset scaling with cell width, the
option is the wrong shape and should express a fraction of a cell instead.
**Settle this before adding another terminal's calibration numbers: changing the
option's shape afterwards is a breaking config change.**

## Measuring the link rate over a fast connection

`:MdViewerMeasureLink`'s cache key includes terminal identity
(`terminal_id()` in `lua/md-viewer/linkrate.lua`) because on a fast link the
terminal emulator, not the network, dominates the measured throughput.
Measured on the LAN reference host (2026-08-26), same script, same day, three drains of the
identical link:

| drain | rate |
|---|---|
| iTerm2 rendering it | 14,700,000 B/s |
| `:MdViewerMeasureLink`, headless Neovim, `/dev/null` | 23,970,342 B/s |
| `ssh-link-speed.sh` by hand, `/dev/null` | 25,938,722 B/s |

Compression was off for this host, so none of that spread is a compressor —
it's the terminal. On a link this fast, roughly 40% of the wall clock is the
emulator, which is why the same host reached from two different terminals can
measure two different rates, and why the cache key has to include which
terminal is asking.

**Open:** the LAN reference host's own link rate under a real iTerm2 drain has never been
measured — only the `/dev/null`-drain figures above exist. An agent has no
terminal emulator to drain into. Run `:MdViewerMeasureLink` from inside a real
iTerm2 session on the LAN reference host and record the result here.

## The local-render helper

`renderer/src/local-main.js` is the optional per-session process behind
`render.location = "local"` — same package, zero extra dependencies. Run it in
place of plain ssh, on the machine the terminal is on:

```sh
node renderer/src/local-main.js -- ssh <host>     # the session wrapper
node renderer/src/local-main.js --version         # what a bug report should quote
node renderer/src/local-main.js --status          # counters from every helper socket
node renderer/src/local-main.js --marker-echo-test -- ssh <host>   # K2 transit rig
```

Its tests are part of the ordinary node suite (`local-*.test.js`: stream
parser + passthrough fuzz, injector rules, socket hello/pairing, replica
renders, no-TCP, orphan-exit). The pieces that need real hardware have rigs
under `scripts/local/`: `topology-check.sh` proves the wrapped-ssh topology
(raw mode, resize, `~.`) against a real host, and `marker-echo-emit.sh` is
the remote half of the echo test. Two hard-won facts to preserve when
touching it: the helper must never read `process.stdin` (the tty probe opens
its own `/dev/tty` — see the header in `renderer/src/local/tty-probe.js` for the measured
failure), and remote forward paths must be absolute and short
(`sshd` refuses relative streamlocal binds; `sun_path` caps at ~104 bytes).

## Releasing

The project follows [Semantic Versioning](https://semver.org/). While the major
version is `0`, a breaking change is allowed in a MINOR bump; that carve-out ends
at `1.0.0`.

1. Run all three automated suites from a clean checkout.
2. Work through [Manual verification](#manual-verification) on at least one
   `Supported` terminal.
3. Bump the version in `lua/md-viewer/init.lua` (`M.version`) and
   `renderer/package.json`, then regenerate the lockfile — never hand-edit it:

   ```sh
   npm install --package-lock-only --prefix renderer
   ```

4. Add the `CHANGELOG.md` section and its link reference at the bottom of the
   file. Keep it release notes, not a postmortem: one bullet per user-visible
   change, at most one sentence of cause where that is what makes the fix
   legible. Benchmarks, root-cause analysis and terminal internals belong in
   [architecture.md](architecture.md) if they are durable invariants, in
   [terminal-support.md](terminal-support.md) if they are current limitations,
   and in Git history otherwise.
5. Confirm no browser binary, `node_modules`, log, screenshot, generated PNG, or
   local profile is tracked. Run `git diff --check`. Review dependency licenses
   and advisories.
6. Confirm the README's install snippets pin the version being tagged — both
   the lazy.nvim `version` and the `vim.pack` `version`.
7. Tag the tested commit with an **annotated** tag, then publish the release
   from the matching changelog section. The section is extracted verbatim, so a
   malformed heading or a missing link reference breaks the release notes:

   ```sh
   git tag -a v0.2.0 -m "v0.2.0: <summary>"
   git push origin v0.2.0
   awk '/^## \[0\.2\.0\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md > /tmp/notes.md
   gh release create v0.2.0 --title "v0.2.0" --notes-file /tmp/notes.md
   ```

## Design constraints

Preserve these unless a proposal explicitly revisits them. Each is stated with
its mechanism in [SECURITY.md](../SECURITY.md) or
[architecture.md](architecture.md):

- the plugin and renderer open no listening port; renderer transport is
  child-process stdin/stdout, and the one listener anywhere — the optional
  local-render helper's unix socket, operator-launched on the operator's own
  machine — is never TCP (a test pins that) and never gains a path-request
  channel: assets are push-only
- browser networking blocked unconditionally; remote images fetched only by the
  Node process, only from public destinations, on every redirect hop
- Playwright uses an existing browser and manages no downloads
- raw image cleanup targets only plugin-owned image and placement IDs
- local file access canonicalized and confined to a document root
- the graphical preview stays a read-only raster surface

## Code with no live caller right now

Some paths are correct, tested, and reachable in principle, but nothing on any
host this plugin currently runs on exercises them -- e.g. the resident-mode
warm-up traffic reductions in `resident_session.lua` and `controller.lua`,
dormant because no combination of a measured link and a terminal profile in
active use selects the resident render path today. That is a fact about
today's deployed hosts, not about the code, and it can flip the moment a host
or a terminal's `resident_pan` setting changes.

Mark this with a `KEEP_IN_MIND:` comment at the dormant site, stating exactly
what would need to be true for it to run again and how to exercise it
deliberately (a stub, a script, an env var) without waiting for a real host to
change. A grep for `KEEP_IN_MIND` should always find every such site.

Do not delete code just because it currently has no live caller -- that is
what the comment is for. If a path should be removed outright rather than left
dormant (the feature it serves is being dropped, not just currently
unexercised), that is a product decision -- open an issue rather than deleting
it in a pull request. Once a real host exercises the path again, delete the
comment along with it: it has done its job.
