# Refactor State

Current phase: Phase D (needs new test infrastructure first) -- in progress

Completed:
- Phase 0, item 1: fixed the health test's `auto_cfg` scope so all intended
  `_diagnose` assertions use the explicit test configuration.
- Phase 0, item 2: restricted local `presented` notifications to injected
  frame transactions, so placement, deletion, and sheet traffic cannot
  confirm pixels that have not resolved.
- Phase 0, item 3: separated overlay-sheet transactions from the injector's
  frame supersession lane and refused selection overlays until their local
  base frame is confirmed.
- Phase 0, item 4: unified the local marker emitter, parser, and decoder on a
  64 KiB full-wire limit and made the Lua emitter refuse oversized markers
  before writing or counting them.
- Phase 0, item 5: corrected SECURITY.md to state that the helper distributes
  its token in the control-socket hello and the plugin subsequently embeds it
  in terminal-stream markers visible to pty observers.
- Phase 0, item 6: re-armed the local-render fallback warning after a
  successful attachment, so a later demotion after recovery is reported.
- Phase 0 complete: all six items landed; `make test` passed with 3,355 Lua
  assertions and 350 Node tests, and StyLua passed.

- Phase A, item 7: deleted confirmed-dead session fields `visual_columns`,
  `obsolete_files`, `selection_render_in_flight`, `selection_render_pending`
  (state.lua), and the empty-bodied `WinLeave` autocmd (controller.lua).
  The plan's fifth sub-item, `debug.log`, was excluded: verification showed
  `md-viewer.debug`'s `M.log` has 6 live callers in `animation.lua` and its
  output is surfaced through `:MdViewerDebug`, asserted by
  `tests/lua/cases/debug.lua` and `tests/lua/cases/interaction.lua:750` — the
  plan's "no callers" premise was wrong for this one, so it was left in place
  per instruction to stop rather than guess on a material contradiction.

- Phase A, item 8: extracted the ten-name timer-teardown list duplicated in
  `release_document` and `deactivate_document` (controller.lua) into a shared
  `SESSION_TIMER_NAMES` constant and `close_session_timers()` helper, called
  from both.

- Phase A, item 9: extracted the identical, unrounded drawn-pixel-box formula
  (`placement.width * cell.width`, `placement.height * cell.height`) shared by
  `kitty_raw.lua`'s `overlay_apply` and `animation_apply` and `animation.lua`'s
  `scales` into `cellpixels.drawn_size(placement, cell)`. Deliberately left
  `kitty_raw.lua`'s `required_sheet_size` and `interaction.lua`'s `sheet_dims`
  unmerged per the plan's caveat: both round the same drawn term differently
  (ceil-before-max vs floor-after-max+margin) as two halves of one
  overlay_needs_sheet/sheet_dims contract, and `sheet_dims`'s cell-based
  branch has no unit test pinning it, so unifying now risks an unverifiable
  1px divergence.
  `scripts/overlay/live/drive.lua` was re-run after this item and still times
  out at "settle after y" — same pre-existing failure noted after Phase 0, not
  a regression from this item.

- Phase A, item 10: moved `apply_image`'s `last_*`/`fast_*`/`retina_*` frame
  telemetry (pure session-field bookkeeping, no `vim.api` calls, feeding only
  `:MdViewerDebug`) verbatim into a new `metrics.lua`, called once from
  `apply_image` as `metrics.record_frame(...)`.
- Phase A complete: all four items (7-10) landed. `make test` passed with
  3,355 Lua assertions and 350 Node tests, and `stylua --check` passed.

- Phase B, item 11: extracted preview history into `history.lua`. Real preview
  sessions now keep the history list, index, and boundary exclusively on the
  pane; the five former pane/session synchronization sites were removed.
  Pane-less tables retain a single-owner fallback for the public low-level API
  and its bounded-history test. Diagnostics now read history through the new
  module. `make test` passed with 3,358 Lua assertions and 350 Node tests, and
  `stylua --check` passed.

- Phase B, item 12 prerequisite: the live overlay failure was reproduced at
  `93df07f`, the commit immediately before item 11, so item 11 is excluded as
  its cause. The driver had retained two stale expectations after production
  behavior changed: leaving preview Visual mode now clears the selection
  immediately after its sharp commit, and the caret is deliberately redrawn as
  the one remaining overlay. The driver now asserts the full current `y`
  lifecycle (commit, copy, clear, caret redraw) and uses embedded RPC so a
  failed child cannot strand it on a dead Unix socket. Two consecutive live
  runs passed, as did `make test` (3,359 Lua assertions and 350 Node tests).

- Phase B, item 12: extracted the frame-on-glass block into `presenter.lua`:
  base PNG application, local surface references, clean-base restoration,
  selection and caret overlays, caret placement, and captured interaction
  results. Controller retains compatibility aliases for its existing
  low-level API and injects the validity/occlusion/teardown orchestration the
  presenter must call. `interaction.lua` now has one top-level presenter
  dependency and no controller require; controller injects its remaining
  retarget/scroll callbacks, removing the module cycle. `make test` passed
  with 3,359 Lua assertions and 350 Node tests, `stylua --check` passed, and
  the mandatory live overlay driver passed against the real renderer and
  Chromium.

- Phase B, item 13: extracted image visibility and reconciliation into
  `occlusion.lua`: the background-tab/float/UI-suppression decision, complete
  image teardown, active-session iteration, viewport placement reconciliation,
  resident-screen restoration, raw-session recovery, and the UI poll. The old
  `update_occlusion` return value is now explicitly named `must_hide`, making
  clear that it includes transient UI suppression as well as geometric
  occlusion. Added direct coverage for the previously indirect
  `reconcile_resident` path, a forced same-placement redraw, and the extracted
  active-session iterator. `make test` passed with 3,365 Lua assertions and 350
  Node tests, `stylua --check` passed, and the live overlay driver passed.
- Phase B complete: all three items (11-13) landed. `controller.lua` is now
  1,780 lines, down from 2,597 before Phase B. The plan's approximate 1,100-line
  target is not arithmetically reachable from its three specified source
  ranges; no unplanned controller behavior was moved merely to match that
  estimate.

- Phase C, item 14: replaced all 42 `backend.name ==` checks with declared
  capability flags. The plan's parenthetical named five flags; the count the
  code actually needs is six, because its own precise claim -- that the 16
  `kitty_raw` sites are five distinct capabilities -- is right, and
  `is_graphical` covers the other 26. The sixth is `supports_local_markers`
  (the seven local-render sites), alongside `places_raw_images`,
  `accepts_exclusions`, `needs_statusline_guard` and `needs_ui_poll`.
  `preview.placement` now takes the backend table rather than its name, since
  its two adjustments answer to two different flags. `health`'s image-support
  line was converted too: it matched a hardcoded list of backend names, which
  is the same defect one function further out. The fake backend tables in 12
  test cases now build on `backends.capabilities(name)`, and
  `tests/lua/cases/backends.lua` pins the matrix including that every flag is
  declared as a boolean rather than omitted. `make test` passed with 3,426 Lua
  assertions and 350 Node tests, `stylua --check` passed, and the live overlay
  driver passed.

- Phase C, item 15: routed the eleven direct `send()` calls in `kitty_raw.lua`
  through the presenter seam -- every animation call plus the resident
  upload/compose/uncompose trio. `send` now has exactly one caller,
  `direct_present`. Two shapes needed naming to fit the transaction: an upload
  entry may carry an explicit `control`, because the native animation frame
  append transmits under `a=f` rather than the upload contract's `a=t` (the
  default is still the contract the JS port mirrors); and the native begin's
  playback controls ride the transaction's placement half, which is the part of
  a write that is neither upload nor deletion. `uncompose` carries `kill` like
  the `hide` it is the whole-screen form of; the animation frees do not, since
  frame data is not the base image a pending local frame belongs to. Routing is
  not enabling: whether resident mode or animation runs in local mode stays a
  separate decision, and today neither does. `backend_marker.lua` now pins the
  seam with a recording presenter and an empty terminal stream. `make test`
  passed with 3,440 Lua assertions and 350 Node tests, `stylua --check` passed,
  and the live overlay driver passed with an identical 377,622-byte total,
  which with the golden stream tests is the byte-identity proof for the direct
  path. Regenerating `tests/fixtures/local-upload-golden.json` produced the
  same data, so the committed fixture is untouched.

- Phase C, item 16: every session now carries its own configuration snapshot.
  `state.create` takes `config.snapshot()` and re-takes it whenever the
  configuration changes, through the same `invalidate_memoized` hook the
  terminal-capability and link-rate caches already used, so reconfiguring a
  running Neovim still reaches previews that are already open. The 55
  session-scoped `config.get()` reads became `session.config`; the remaining
  ones are the sites where no session is the right question (backend selection,
  terminal capability, health, the global wheel and keymap installers, the
  animation tick's shared FPS floor, `preview.placement`, `open_external`).
  `toggle_line_numbers` now goes through a new validated `config.set_runtime`
  layer, applied over the user's options as each snapshot is taken and cleared
  by `setup`/`reset` exactly as the old in-place write was -- so the toggle
  still reaches previews opened later without editing the reader's table.
  `config.effective(path)` reads one value as a session sees it, which is what
  the toggle needs to know which way to switch. Unused `config` requires were
  dropped from the five modules that no longer have one. `make test` passed
  with 3,464 Lua assertions and 350 Node tests, `stylua --check` passed, and
  the live overlay driver passed.
- Phase C complete: all three items (14-16) landed. `make test` passed with
  3,464 Lua assertions and 350 Node tests, `stylua --check` passed, and
  `scripts/overlay/live/drive.lua` -- mandatory for all of Phase C -- passed
  after each item, with an unchanged 377,622-byte terminal total throughout.

- Phase D, item 17, harness deliverable 1 of 5: `MD_VIEWER_TEST_FILTER` (a Lua
  pattern matched against the case name; narrows the list without reordering
  it, errors when it matches nothing, and labels its summary line so a
  filtered run cannot be read as the suite) and a per-case teardown contract
  in `tests/lua/world.lua` covering windows, tabpages, `state.panes()`, the
  `md-viewer` autocmd group's size and the config singleton. Buffers are
  exempt by design. It found five leaks: a pane stranded by `config.lua` and
  `image.backend = "cells"` left in the global config by `controller.lua`,
  `debug.lua`, `health.lua` and `navigation.lua`. The suite's assertion count
  moved 3,464 -> 3,457 because `debug.lua` asserts once per line of the
  `:MdViewerDebug` report and the report enumerates `state.panes()`; seven of
  those lines described the stranded pane.

- Phase D, item 17, harness deliverable 2 of 5: `tests/lua/cases/autocmds.lua`
  pins the autocmd manifest (21 handlers, identified by callback identity in
  `nvim_get_autocmds` so a five-event registration reads as one handler, with
  each one's events, pattern and purpose), the dispatch order of every event
  with more than one handler, and every event firing against a real session.
  Two counts in the plan were off: there are eight multi-handler events rather
  than six, and only seven are an ordering question -- `OptionSet`'s two have
  disjoint patterns (`background`, `laststatus`) and never both fire. A control
  experiment pins the assumption the ordering half rests on, that
  `nvim_get_autocmds` returns handlers in dispatch order. The firing loop wraps
  `vim.schedule`: without that it reported a green run over eight events whose
  deferred half threw, since Neovim prints such an error and continues.
  Verified by mutation -- deleting the `WinNew` registration fails three
  assertions, and a raising handler fails in either half.

- Phase D, item 17, harness deliverable 3 of 5: the session-shape contract.
  `tests/lua/session_shape.lua` describes all 156 fields the code can put on a
  session in ten categories, including the `screen` (what is painted now) vs
  `target` (what the screen should become) split the plan asked for. The
  runner enforces it across the whole suite: every `state.create` session is
  sampled at every assertion, then both directions are asserted -- nothing
  outside the manifest ever appeared, and everything the manifest marks
  observed did. The completeness direction is skipped under a filter.
  `tests/lua/cases/session_shape.lua` holds the static half and pins the gap
  the constructor cannot show: 18 of its 57 field lines assign `nil`, for
  which Lua stores no key, so it creates 39. Verified by mutation in both
  directions.

- Phase D, item 17, harness deliverable 4 of 5:
  `tests/fixtures/shared-constants.json`, emitted by
  `scripts/dump-shared-constants.js` from the Node modules that own the
  values -- viewport clamps, device-scale band, single-capture ceilings, local
  protocol version and marker bound, and every `REGION_`/`STALE_`/`INTERACT_`
  code. `browser.js` now exports `VIEWPORT_BOUNDS` and
  `DEVICE_SCALE_FACTOR_BOUNDS` at the sites that had the literals, and
  `coordinates.lua` exports the bounds it already declared, so both sides of
  the comparison are the live values rather than copies.
  `tests/node/shared-constants.test.js` fails while the fixture is stale;
  `tests/lua/cases/shared_constants.lua` asserts Lua agrees and that every
  code literal in `lua/` is one the renderer still emits. Verified by mutation
  in both directions. The live overlay driver passed with an unchanged
  377,622-byte total after the `browser.js` change.

Not done, and why:
- The plan gates Phase C items 14-15 on `scripts/manual-checklist.md` on a real
  terminal. That was not run: this session is headless and the checklist needs
  a person looking at pixels. The headless evidence that stands in its place is
  narrower and worth naming -- the golden byte-stream tests, the marker tests,
  and the live overlay driver's byte totals all pin the direct path's output as
  unchanged, but none of them can see whether anything is composited where it
  should be. Run the checklist on a Supported terminal before the next release.

Next:
- Phase D has not begun, and its first step is test infrastructure rather than
  a refactor: the autocmd manifest and driver, a single-case runner, the
  session-shape contract, the generated shared-constants fixture, and
  skip-on-no-browser for the Lua suite. Items 17 and 19 are gated on that
  existing and passing; item 18 is gated on `scripts/resident/drive.lua` on a
  real terminal.

Last verified commit:
- `aae3ae8` (Phase C item 16 landed and verified; Phase C complete).

Notes:
- Follow docs/refactor-plan.md in order.
- Do not start the next major phase without stopping first.
- `scripts/overlay/live/drive.lua` is mandatory for Phase B item 12 and all of
  Phase C. Its former `settle after y` timeout was a pre-existing harness
  defect, reproduced unchanged before item 11 and corrected in the item 12
  prerequisite above; no md-viewer behavior was changed to make it pass.
