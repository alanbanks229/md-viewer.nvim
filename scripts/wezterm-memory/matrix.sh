#!/usr/bin/env bash
# Run a set of probe configurations back to back against one terminal and print
# the growth rate of each, so the cases can be compared rather than admired one
# at a time.
#
#   ./matrix.sh <terminal> [tag]
#
# Every row uses the same frame count, rect count and ceiling; only the variable
# under test changes. Rows are separated by a full terminal restart so no run
# inherits another's heap.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
terminal="${1:?usage: matrix.sh <terminal> [tag]}"
tag="${2:-matrix}"

ITERS="${ITERS:-40}"
RECTS="${RECTS:-4}"
CEILING_KB="${CEILING_KB:-500000}"
IDLE_MS="${IDLE_MS:-4000}"

# label            case  base  moving
rows=(
  "ref-base-B        B     1     $RECTS"
  "nobase-B          B     0     $RECTS"
  "base-A            A     1     $RECTS"
  "base-E            E     1     $RECTS"
  "base-B-static     B     1     0"
  "base-B2-nodelete  B2    1     $RECTS"
)

for row in "${rows[@]}"; do
  set -- $row
  label="$1"; case_id="$2"; base="$3"; moving="$4"
  CASE_LABEL="$tag-$terminal-$label"
  BASE="$base" MOVING="$moving" RECTS="$RECTS" ITERS="$ITERS" SAMPLE_EVERY=1 \
    CEILING_KB="$CEILING_KB" IDLE_MS="$IDLE_MS" TIMEOUT=200 \
    "$here/run.sh" "$case_id" "$terminal" "$CASE_LABEL" >/dev/null 2>&1
  node "$here/growth.mjs" "$(dirname "$here")/../tmp/wezterm-memory/$CASE_LABEL" "$label"
done
