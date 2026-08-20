#!/usr/bin/env bash
# Sustained-memory sampler for resident regions.
#
# The one measurement that has to exist before `image.resident_memory_mb` is
# raised. Budgeting is done in pixels because a terminal holding a compressed
# PNG does not consume `png_bytes`, it consumes a decoded surface -- and what
# that surface costs is a property of the terminal rather than of the image.
# `scripts/resident/rss-calibrate.py` has since measured it at 12-13 bytes per
# pixel on iTerm2, against the 4 this project assumed for its first three
# releases; that answers questions 1 and 2 below in a minute, on a synthetic
# workload. This is the sustained run, and it is still the only thing that can
# answer 3.
#
# Three questions, and only the third now needs half an hour:
#
#   1. How much resident size does the terminal take per resident megapixel?
#   2. Does it come back when the region is evicted (`a=d,d=I`)?
#   3. Does it plateau over half an hour, or creep?
#
# RESULT, 2026-08-19, iTerm2 on macOS, real session over the SSM tunnel:
# **it plateaus.** RSS rose ~10 MB above baseline across the run, with transient
# peaks on resize that relaxed afterwards. No creep, no leak. Question 3 is
# answered and `image.resident_memory_mb` is no longer waiting on it.
#
# The same run disqualified question 1's answer, which is the more interesting
# result. `:MdViewerDebug` reported twelve slices resident -- ~342 MB at the
# 12-13 B/px this script's companion measured -- while this sampler saw ~10 MB
# move. 34x apart, and they cannot both be describing the terminal's memory.
# Either `ps -o rss=` cannot see where iTerm2 keeps decoded slices, in which
# case this script answers "does it creep" and can never answer "what does it
# cost"; or 13 B/px does not generalise, because rss-calibrate.py transmits
# synthetic gradients chosen to be incompressible while a document slice is
# mostly flat background and text. Re-running rss-calibrate.py against a real
# document's slices would separate the two, and is the next thing worth doing
# here.
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
  1. Let the slice under you fill, then scroll inside it for a few minutes.
  2. Walk the whole document, letting each slice fill as you reach it. Crossing
     a boundary is NOT an eviction any more -- a slice is uploaded once and
     kept -- so what this is measuring is the terminal holding all of them at
     once, which is the case the old bounded region never reached.
  3. Walk back through the same slices. \`evictions\` in :MdViewerDebug should
     still be 0; if it is not, the document is over image.resident_memory_mb and
     the window is sliding, which is a different measurement.
  4. Keep going until this exits. Then CLOSE the preview and watch the last
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
    echo "Close the preview now. Do not raise image.resident_memory_mb." >&2
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
\`decoded_mb_budgeted\` converts \`resident_px\` at an assumed ~13 bytes per
resident pixel. A large gap between the two is the thing this run exists to
find, and the 2026-08-19 run found one it has not explained: 342 MB budgeted
against ~10 MB sampled. Read them as two different quantities until
rss-calibrate.py has been re-run against real document slices. \`evictions\` says how many
times the terminal was asked to give memory back; on a document inside
\`image.resident_memory_mb\` it should be zero, because a grid of slices is
uploaded once and kept.

The ceiling may be raised only if BOTH hold: the final third is not materially
above the middle third (it plateaued), and resident size returns to near
baseline after the preview closes (eviction genuinely frees). Take the largest
ceiling where both hold and halve it.
EOF
