# Refactor State

Current phase: Phase A

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

Next:
- Begin Phase A with item 7 from docs/refactor-plan.md in the next session.

Last verified commit:
- `1d2453b` (Phase 0 complete; items 1-6 verified).

Notes:
- Follow docs/refactor-plan.md in order.
- Do not start the next major phase without stopping first.
- `scripts/overlay/live/drive.lua` is not a Phase 0 completion gate. The plan
  makes it mandatory for Phase B item 12 and all of Phase C; CONTRIBUTING says
  it is worth running for selection or placement changes.
- The driver was nevertheless run twice after Phase 0 and both attempts timed
  out at `settle after y`. This is a non-blocking Phase 0 observation, but it
  must be resolved or otherwise accounted for before Phase B item 12, where
  the plan makes the driver mandatory.
