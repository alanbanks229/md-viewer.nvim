# Refactor State

Current phase: Phase 0

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

Next:
- Run Phase 0 completion verification, then mark Phase 0 complete and Phase A
  current without starting Phase A.

Last verified commit:
- `9bd9052` (Phase 0, item 5); this commit is Phase 0, item 6.

Notes:
- Follow docs/refactor-plan.md in order.
- Do not start the next major phase without stopping first.
