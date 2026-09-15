# Refactor State

Current phase: Phase D is COMPLETE -- every migration phase in
docs/refactor-plan.md section 6 has landed. The next major phase is the plan's
section 7 deliverables (see Next); do not start it without reading that section
first.

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

- Phase D, item 17, harness deliverable 5 of 5: skip-on-no-browser for the Lua
  suite. `tests/lua/browser.lua` asks the renderer's own discovery module --
  the same question the Node suite asks -- after two cheaper checks (no node,
  renderer dependencies not installed) that are also reasons the round-trip
  cannot happen. `debug.lua` and `health.lua` skip their renderer round-trips
  instead of waiting 30 seconds each and failing about the machine.
  `MD_VIEWER_TEST_NO_BROWSER=1` forces that path; under it the suite runs 3,419
  assertions and two named skips in 7 seconds instead of 3,868 in 67.
  `t.skip` takes a session-shape sample, because a skip is where a case stops.
- Phase D, item 17: all five harness deliverables landed. `make test` passes
  with 3,868 Lua assertions and 352 Node tests, `stylua --check` passes, and
  `scripts/overlay/live/drive.lua` passed with an unchanged 377,622-byte total
  after the one production change in the set (naming `browser.js`'s clamps).
  Next in item 17: `lanes.lua`.

- Phase D, item 17 (lanes): `lanes.lua` is the Lua half of
  `renderer/src/lanes.js` -- a content admission invalidates every lane through
  an epoch (any render re-lays out the page), each other lane invalidates only
  itself. Four lanes, not the renderer's four: `interact` does not pass through
  here, and the plugin has one the renderer does not distinguish, the resident
  chunk, which is the one whose loss was measurable. `request_serial` stays as
  the monotonic request count and as the serial each lane stores;
  `:MdViewerDebug` now also reports the per-lane serials. The controller's two
  "void everything" bumps became `lanes.invalidate`.
  One consequence needed naming: the two sides' supersession rules are not a
  superset of each other (the renderer keeps one `capture` lane for what this
  side splits three ways), so a renderer `STALE_RENDER` now reaches the caller
  as staleness rather than as a failure -- the shared serial used to hide that
  case by staling everything, and without it a routine supersession would have
  surfaced to the reader as an error notification. The wire is unchanged: no
  lane is sent. `make test` passed with 3,918 Lua assertions and 352 Node
  tests, `stylua --check` passed, and the live overlay driver passed with an
  unchanged 377,622-byte total.
- Phase D, item 17 complete: the five harness deliverables and `lanes.lua`.

- Phase D, item 18: extracted the resident loop into `resident_controller.lua`
  -- `pump_resident`, `holding_position`, `draw_resident`, `begin_resident`, 239
  lines of `controller.lua`. It is the third and outermost of the resident
  layers: `resident.lua` is the arithmetic, `resident_session.lua` is the
  per-session state machine, and this is what spends the renderer and the wire
  on that plan. The host seam is three functions (`valid`, `markdown`,
  `refresh`), so the new module reaches presenter, occlusion, preview, renderer,
  linkrate and resident_session directly and never requires controller.
  Controller keeps the three names as aliases, the same pattern `history.lua`
  and `presenter.lua` already use, so `occlusion`'s host, `:MdViewerDebug` and
  `tests/lua/cases/resident_bootstrap.lua` call exactly what they called before
  -- which is what makes the before/after gate runs comparable at all.
  The moved body is verbatim apart from four rebinds forced by the move
  (`M.refresh` -> the injected `refresh` x3, and an inline
  `require("md-viewer.linkrate")` that is now a top-level require),
  `M.clear_caret_overlay`/`M.place_caret` -> `presenter.*`, and comment
  references re-qualified for their new file. Two locals orphaned in controller
  (`linkrate`, `clear_selection_overlay`) were dropped.
  `make test` passed with 3,918 Lua assertions and 352 Node tests -- unchanged,
  as expected for a path the suite cannot reach -- and `stylua --check` passed.
  The gate is what matters: `scripts/resident/drive.lua` passed 12/12 both
  plain and with `--slow-chunks=2000`, before and after the move, with
  identical numbers each time (21/21 chunks, 22 images on the wire, 40 scrolls
  costing 0 renderer requests and 0 uploads, 58 placements in 40 writes, 196
  bytes per write, the preview following the reader to chunk 9). The live
  overlay driver was run too, though Phase D does not require it, and passed
  with the unchanged 377,622-byte total.

- Phase D, item 19: extracted the autocmd group into `autocmds.lua` -- the
  augroup and its 21 handlers, 368 lines and 39 registrations. It is the layer
  above controller that `commands.lua` already models: it requires controller
  and controller never requires it back, so the arrow the target architecture
  draws (wiring -> orchestration) is now real in both directions rather than
  only on paper.
  `setup_autocmds` also held two things that are not autocmds -- the renderer
  process's exit hook and local rendering's four helper events. Those stayed in
  controller as `M.setup_listeners()`, because what they do is session
  bookkeeping rather than wiring, and `init.lua` now calls both. The plan's
  diagram puts only "commands / autocmds" in the top layer, which is what
  settled that split.
  Five controller names became public for the layer above (`valid`,
  `show_cached`, `close_session`, `schedule_source_scroll`, and a
  `history_follow_buffer` wrapper so no caller has to assemble `history_host`).
  That is the whole of what the handlers needed that was not already public;
  the bodies are otherwise verbatim, `M.x` -> `controller.x`.
  Verification, because this is the move the plan calls the most dangerous:
  `tests/lua/cases/autocmds.lua` passes (123 assertions -- the manifest, the
  seven ordering questions, every event fired against a real session), and the
  plugin was loaded in a real Neovim both TTY-attached (1 UI) and headless,
  sourced through `plugin/md-viewer.lua` on the runtimepath, where the
  `md-viewer` group comes up with 39 registrations across 21 handlers, the
  user commands install, a preview opens, and dispatched events do not raise.
  `make test` 3,918 Lua assertions and 352 Node tests, `stylua --check` clean,
  the live overlay driver unchanged at 377,622 bytes, and
  `scripts/resident/drive.lua` 12/12 both ways.
- Phase D complete: all three items (17-19) landed. `controller.lua` is now
  1,215 lines, down from 1,796 at the start of the phase and 2,597 before
  Phase B. Phase-wide verification on the committed tree: `make test` 3,918 Lua
  assertions and 352 Node tests with 0 skips, `stylua --check` clean,
  `scripts/resident/drive.lua` 12/12 plain and with `--slow-chunks=2000` (item
  18's gate), and the live overlay driver at the unchanged 377,622-byte total.
  Every migration phase in the plan's section 6 has now landed.

Not done, and why:
- The plan gates Phase C items 14-15 on `scripts/manual-checklist.md` on a real
  terminal. That was not run: this session is headless and the checklist needs
  a person looking at pixels. The headless evidence that stands in its place is
  narrower and worth naming -- the golden byte-stream tests, the marker tests,
  and the live overlay driver's byte totals all pin the direct path's output as
  unchanged, but none of them can see whether anything is composited where it
  should be. Run the checklist on a Supported terminal before the next release.
  This one is real and still outstanding -- do not confuse it with the
  correction below, which is a different script.

Corrections:
- 2026-09-14: item 18 was recorded here as blocked on a real
  terminal. It is not, and never was. `scripts/resident/drive.lua` runs
  headless -- its own header and `scripts/README.md` both say it needs "no
  display and no graphics terminal -- only Node and a Chrome/Chromium",
  because it spawns a child Neovim with a *faked* Kitty-capable terminal and
  records the byte stream instead of drawing it. The claim came from
  `docs/refactor-plan.md`, which has been corrected at both places it appeared.
  The gate was then run on this machine, headless, and passed twice:

    nvim --headless -u NONE -i NONE -l scripts/resident/drive.lua
      12/12 checks passed -- 21/21 chunks resident, each uploaded once;
      40 scrolls over an 11,762px document costing 0 renderer requests,
      0 image uploads, 58 placements in 40 writes, 196 bytes per write.

    ... same, with --slow-chunks=2000 (the warm-up path, which is what the
    knob exists for)
      12/12 checks passed -- 0 of 24 warm-up samples showed pixels nobody
      could vouch for.

  What the gate genuinely means still stands: `pump_resident` and its siblings
  are unreachable on every validated host, so `make test` proves nothing about
  this extraction. The driver is the oracle. Run it plain and with
  `--slow-chunks=2000` both before and after the move, and require 12/12 each
  time.

Next:
- The migration is done. What remains is docs/refactor-plan.md section 7,
  "Deliverables", which is the next major phase and has not been started:
    1. `docs/architecture.md` -- still the original 153 lines. The plan asks
       for a rewrite into the full contributor-facing document: the four
       rendering models, the state map, the counter/lane story, both diagrams.
       Everything it has to describe now exists and is named, which was not
       true when the plan was written.
    2. A published artifact -- the same content as a browsable page with
       rendered diagrams.
  Read section 7 before starting; it is a writing phase, not a code phase, and
  nothing in it should change behavior.
- Still outstanding from Phase C, and unrelated to the above:
  `scripts/manual-checklist.md` on a real terminal, before the next release.
  See "Not done, and why".

Last verified commit:
- `116b50b` (Phase D item 19 landed, and with it the whole phase:
  `autocmds.lua`). Verified on that tree: `make test` 3,918 Lua assertions and
  352 Node tests, `stylua --check` clean, `scripts/resident/drive.lua` 12/12
  plain and with `--slow-chunks=2000`, the live overlay driver unchanged at
  377,622 bytes, and a real-Neovim load (TTY-attached and headless) showing the
  `md-viewer` group at 39 registrations across 21 handlers.

Notes:
- Follow docs/refactor-plan.md in order.
- The Lua suite now has a single-case runner (`MD_VIEWER_TEST_FILTER`, a Lua
  pattern over case names), a per-case teardown contract
  (`tests/lua/world.lua`), a session-shape contract enforced across the whole
  run (`tests/lua/session_shape.lua`), and skips its browser round-trips when
  no browser is present (`MD_VIEWER_TEST_NO_BROWSER=1` forces that path).
  A filtered run says so in its summary line and skips the shape contract's
  completeness half, which only a whole run can assert.
- Do not start the next major phase without stopping first.
- `scripts/overlay/live/drive.lua` is mandatory for Phase B item 12 and all of
  Phase C. Its former `settle after y` timeout was a pre-existing harness
  defect, reproduced unchanged before item 11 and corrected in the item 12
  prerequisite above; no md-viewer behavior was changed to make it pass.
- `scripts/resident/drive.lua` is mandatory for Phase D item 18 and runs
  headless. Run it both ways -- plain, and `--slow-chunks=2000` for the warm-up
  path -- and require 12/12 from each. Both harnesses under `scripts/` state
  their own requirements in their headers and in `scripts/README.md`; where the
  plan and a script disagree about what a harness needs, the script is right.
  That disagreement has already cost one session.
- The module layout the migration produced, top to bottom:
  `commands.lua` / `autocmds.lua` (event wiring; both require controller and
  neither is ever required back) -> `controller.lua` -> the peer feature
  modules (`history`, `occlusion`, `resident_controller`, `lanes`, `metrics`)
  -> `presenter.lua` -> `state` / `config` / `backends` / `renderer`. Four
  modules take an injected host rather than requiring controller
  (`presenter`, `interaction`, `occlusion`, `resident_controller`); that is
  what keeps the graph acyclic, so adding a `require("md-viewer.controller")`
  to any of them puts the cycle back.
