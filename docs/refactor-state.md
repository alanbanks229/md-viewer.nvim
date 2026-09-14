# Refactor State

Current phase: Phase 0

Completed:
- Phase 0, item 1: fixed the health test's `auto_cfg` scope so all intended
  `_diagnose` assertions use the explicit test configuration.
- Phase 0, item 2: restricted local `presented` notifications to injected
  frame transactions, so placement, deletion, and sheet traffic cannot
  confirm pixels that have not resolved.

Next:
- Continue Phase 0 with item 3 (overlay-sheet uploads must not evict a pending
  frame).

Last verified commit:
- `07447fc` (Phase 0, item 1); this commit is Phase 0, item 2.

Notes:
- Follow docs/refactor-plan.md in order.
- Do not start the next major phase without stopping first.
