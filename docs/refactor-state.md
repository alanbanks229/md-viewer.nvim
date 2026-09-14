# Refactor State

Current phase: Phase B

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

Next:
- Continue Phase B with item 12 from docs/refactor-plan.md in this session.
- Phase B item 12 (`presenter.lua`) requires `scripts/overlay/live/drive.lua`
  passing first (see Notes) — resolve or account for the "settle after y"
  timeout before attempting item 12.

Last verified commit:
- `75f31b0` (Phase B item 11 landed and verified).

Notes:
- Follow docs/refactor-plan.md in order.
- Do not start the next major phase without stopping first.
- `scripts/overlay/live/drive.lua` was not a Phase A completion gate (only
  Phase B item 12 and all of Phase C require it; CONTRIBUTING recommends it
  for any selection/placement change). It was nevertheless run after Phase 0
  and again after Phase A item 9 (an overlay-geometry change) — both of the
  latter two runs, and the two runs after Phase 0, all timed out identically
  at `settle after y`. Four consecutive identical timeouts across unrelated
  commits is stronger evidence this is pre-existing and environmental (e.g.
  this machine/session) rather than caused by any change in Phase 0 or A, but
  it is still unresolved and **must** be fixed or otherwise accounted for
  before attempting Phase B item 12, where the plan makes the driver
  mandatory.
