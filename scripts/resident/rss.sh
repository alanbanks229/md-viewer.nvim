#!/usr/bin/env bash
# Sustained-memory sampler for resident regions.
#
# The one measurement that has to exist before `image.resident_budget_px` is
# raised. Budgeting is done in pixels because a terminal holding a compressed
# PNG does not consume `png_bytes`, it consumes a decoded surface -- and 4 bytes
# per pixel is an assumption about a representation no terminal documents. This
# is what checks it.
#
# Three questions, and all three need the same run:
#
#   1. How much resident size does the terminal take per resident megapixel?
#   2. Does it come back when the region is evicted (`a=d,d=I`)?
#   3. Does it plateau over half an hour, or creep?
#
# A run that only answers 1 is worthless: a terminal that grows 30 MB per region
# and never gives any of it back is exactly the failure this exists to catch,
# and it looks identical to a healthy one for the first sixty seconds.
#
# Unlike scripts/overlay/stress/run.sh this does NOT launch the terminal -- it
# attaches to the one you are already working in, because the workload is you
# scrolling a real preview on the far end of a real link. It therefore never
# kills the process it samples: over the ceiling it says so and stops, and
# closing the preview is yours to do.
#
#   ./scripts/resident/rss.sh [label] [seconds] [pid]
#
# Defaults: label `resident`, 1800 seconds (30 minutes), and the frontmost
# iTerm2 process. Override the ceiling with MD_VIEWER_RESIDENT_RSS_CEILING_KB.
set -euo pipefail

label="${1:-resident}"
seconds="${2:-1800}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# iTerm2 runs a helper process per session; the one that holds decoded image
# data is the main app, which is the lowest-PID iTerm2 with a non-trivial
# resident size. Passing a pid explicitly overrides all of this.
pid="${3:-}"
if [ -z "$pid" ]; then
  pid="$(pgrep -x "iTerm2" | head -1 || true)"
fi
[ -n "$pid" ] || { echo "no iTerm2 process found; pass a pid explicitly" >&2; exit 2; }
kill -0 "$pid" 2>/dev/null || { echo "pid $pid is not running" >&2; exit 2; }

ceiling_kb="${MD_VIEWER_RESIDENT_RSS_CEILING_KB:-8000000}"
out="$repo/tmp/resident/$label"
rm -rf "$out"; mkdir -p "$out"

baseline="$(ps -o rss= -p "$pid" | tr -d ' ')"
cat <<EOF
sampling pid $pid ($(ps -o comm= -p "$pid" | sed 's|.*/||')) for ${seconds}s
baseline rss: $((baseline / 1024)) MB
ceiling:      $((ceiling_kb / 1024)) MB
out:          $out

Now, in the preview on the far end:
  1. Let one region fill, then scroll inside it for a few minutes.
  2. Cross a boundary so the first region is evicted, and repeat.
  3. Keep going until this exits. Then CLOSE the preview and watch the last
     samples: resident size returning to near baseline is question 2.
EOF

echo "seconds,rss_kb,cpu_pct" >"$out/rss.csv"
elapsed=0
peak="$baseline"
while [ "$elapsed" -lt "$seconds" ]; do
  kill -0 "$pid" 2>/dev/null || { echo "sampled process exited at ${elapsed}s" >&2; break; }
  rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  cpu="$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  [ -n "$rss" ] || break
  echo "$elapsed,$rss,${cpu:-0}" >>"$out/rss.csv"
  [ "$rss" -gt "$peak" ] 2>/dev/null && peak="$rss"
  # Reported, never enforced by signal. This is the terminal the operator is
  # working in; taking it down to protect it would lose the session and the
  # measurement together.
  if [ "$rss" -gt "$ceiling_kb" ] 2>/dev/null; then
    echo "CEILING EXCEEDED at ${elapsed}s: $((rss / 1024)) MB > $((ceiling_kb / 1024)) MB" \
      | tee "$out/exceeded.txt" >&2
    echo "Close the preview now. Do not raise image.resident_budget_px." >&2
    break
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

final="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo 0)"
samples="$(($(wc -l <"$out/rss.csv") - 1))"

# Creep is measured as the difference between the middle and final thirds rather
# than as a total delta, because a run that fills its regions in the first two
# minutes and then holds steady has a large delta and no problem at all. What
# matters is whether it is still climbing when it stops.
mid_avg="$(awk -F, -v n="$samples" 'NR>1 && NR-1 > n/3 && NR-1 <= 2*n/3 {s+=$2; c++} END {if (c) printf "%d", s/c; else print 0}' "$out/rss.csv")"
end_avg="$(awk -F, -v n="$samples" 'NR>1 && NR-1 > 2*n/3 {s+=$2; c++} END {if (c) printf "%d", s/c; else print 0}' "$out/rss.csv")"

cat <<EOF

--- $label: $samples samples over ${elapsed}s ---
baseline      $((baseline / 1024)) MB
peak          $((peak / 1024)) MB
final         $((final / 1024)) MB
growth        $(((peak - baseline) / 1024)) MB above baseline at peak
middle third  $((mid_avg / 1024)) MB average
final third   $((end_avg / 1024)) MB average
csv           $out/rss.csv

Read it against :MdViewerDebug's resident block from the same run --
\`decoded_mb_estimate\` is the 4-bytes-per-pixel guess this measurement exists to
check, and \`evictions\` says how many times the terminal was asked to give
memory back.

A budget may be raised only if BOTH hold: the final third is not materially
above the middle third (it plateaued), and resident size returns to near
baseline after the preview closes (eviction genuinely frees). Take the largest
budget where both hold and halve it.
EOF
