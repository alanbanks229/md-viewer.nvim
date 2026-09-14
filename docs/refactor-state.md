# Refactor State

Current phase: Phase B complete (stopped before Phase C)

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

Next:
- Stop before Phase C as required. The next planned work is Phase C item 14
  (backend capability flags), but it has not begun.

Last verified commit:
- `4fe45c6` (Phase B item 13 landed and verified).

Notes:
- Follow docs/refactor-plan.md in order.
- Do not start the next major phase without stopping first.
- `scripts/overlay/live/drive.lua` is mandatory for Phase B item 12 and all of
  Phase C. Its former `settle after y` timeout was a pre-existing harness
  defect, reproduced unchanged before item 11 and corrected in the item 12
  prerequisite above; no md-viewer behavior was changed to make it pass.
