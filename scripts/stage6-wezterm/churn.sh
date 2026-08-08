#!/usr/bin/env bash
# Stage-6 churn run: prompt check 4. Drives churn.lua in a real terminal window
# and samples the terminal process's own CPU while it happens, because "the
# rectangles keep up" and "the machine is on fire" are both possible at once.
#
#   ./churn.sh <path-to-WezTerm.app> [label] [seconds]
set -euo pipefail

app="${1:?usage: churn.sh <path-to-WezTerm.app> [label] [seconds]}"
gui="$app/Contents/MacOS/wezterm-gui"
cli="$app/Contents/MacOS/wezterm"
[ -x "$gui" ] || { echo "no wezterm-gui at $gui" >&2; exit 2; }

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build="$("$cli" --version | awk '{print $2}')"
label="${2:-churn-$build}"
seconds="${3:-30}"
out="$repo/tmp/stage6/$label"
rm -rf "$out"; mkdir -p "$out"
echo "build: $build   workloads: 3 x ${seconds}s   out: $out"

MD_VIEWER_REPO="$repo" \
MD_VIEWER_STAGE6_OUT="$out" \
MD_VIEWER_STAGE6_BUILD="$build" \
MD_VIEWER_STAGE6_SECONDS="$seconds" \
MD_VIEWER_STAGE6_PROFILE="${MD_VIEWER_STAGE6_PROFILE:-wezterm}" \
MD_VIEWER_STAGE6_WORKLOAD="${MD_VIEWER_STAGE6_WORKLOAD:-}" \
MD_VIEWER_STAGE6_RECTS="${MD_VIEWER_STAGE6_RECTS:-70}" \
"$gui" --config-file "$repo/scripts/stage6-wezterm/wezterm.lua" \
  start --always-new-process -- \
  nvim -u NONE -i NONE --cmd "set runtimepath+=$repo" \
    -c "luafile $repo/scripts/stage6-wezterm/churn.lua" \
  >"$out/wezterm.log" 2>&1 &
wez_pid=$!
trap 'kill "$wez_pid" 2>/dev/null || true' EXIT

waited=0
while [ ! -e "$out/churn.ready" ]; do
  if [ -e "$out/error.txt" ]; then echo "probe failed: $(cat "$out/error.txt")" >&2; exit 1; fi
  if ! kill -0 "$wez_pid" 2>/dev/null; then echo "terminal exited early; see $out/wezterm.log" >&2; exit 1; fi
  sleep 0.25; waited=$((waited + 1))
  if [ "$waited" -gt 120 ]; then echo "timed out waiting for the probe" >&2; exit 1; fi
done
open -a "$app"

# The GUI process is the one doing the cell mutations; sample it, not nvim.
#
# The resident-size ceiling is not paranoia. An earlier version of this script
# measured a full-frame-capture baseline by re-uploading a viewport-sized PNG
# at 40fps; WezTerm caches decoded image data per image id against a prune
# budget that could not keep up, grew to 15 GB, and took the machine's
# application memory with it. Nothing here is worth someone's laptop, so the
# run aborts long before that.
rss_ceiling_kb="${MD_VIEWER_STAGE6_RSS_CEILING_KB:-2000000}"
: >"$out/cpu.txt"
(
  while kill -0 "$wez_pid" 2>/dev/null; do
    ps -o %cpu= -p "$wez_pid" 2>/dev/null | tr -d ' ' >>"$out/cpu.txt" || true
    ps -o rss= -p "$wez_pid" 2>/dev/null | tr -d ' ' >>"$out/rss.txt" || true
    rss="$(ps -o rss= -p "$wez_pid" 2>/dev/null | tr -d ' ')"
    if [ -n "$rss" ] && [ "$rss" -gt "$rss_ceiling_kb" ] 2>/dev/null; then
      echo "ABORT: terminal resident size ${rss}KB exceeded the ${rss_ceiling_kb}KB ceiling" \
        | tee "$out/aborted.txt" >&2
      kill "$wez_pid" 2>/dev/null || true
      exit 1
    fi
    sleep 1
  done
) &
sampler=$!

wait "$wez_pid" 2>/dev/null || true
kill "$sampler" 2>/dev/null || true
trap - EXIT

if [ ! -s "$out/churn.json" ]; then
  echo "no churn.json produced; see $out/wezterm.log and $out/error.txt" >&2
  exit 1
fi
node "$repo/scripts/stage6-wezterm/churn-report.mjs" "$out"
