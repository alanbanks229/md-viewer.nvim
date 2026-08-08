#!/usr/bin/env bash
# Run one case of repro.mjs in a freshly launched terminal window and wait for
# it to finish.
#
#   ./run.sh <case> <terminal> [label]
#
# <terminal> is "stable" | "nightly" | "kitty" | "ghostty" | a path to a .app.
#
# The probe enforces its own RSS ceiling; this enforces a second one from
# outside, because a probe that wedges cannot stop the terminal it wedged. Both
# exist because this measurement has already cost one machine its memory.
set -euo pipefail

case_id="${1:?usage: run.sh <case> <terminal> [label]}"
terminal="${2:?usage: run.sh <case> <terminal> [label]}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

case "$terminal" in
  stable)  app="/Applications/WezTerm.app" ;;
  nightly) app="$repo/tmp/stage6/WezTerm-macos-20260805-104032-4b1c3c15/WezTerm.app" ;;
  kitty)   app="/Applications/kitty.app" ;;
  ghostty) app="/Applications/Ghostty.app" ;;
  *)       app="$terminal" ;;
esac

label="${3:-$terminal-$case_id}"
out="$repo/tmp/wezterm-memory/$label"
rm -rf "$out"; mkdir -p "$out"

# The command is a generated script rather than an argv, so the probe's
# environment survives terminals that re-exec through a login shell or hand the
# request to an already-running instance.
launcher="$out/launch.sh"
cat >"$launcher" <<EOF
#!/bin/sh
export CASE="$case_id"
export OUT="$out"
export ITERS="${ITERS:-1200}"
export FPS="${FPS:-40}"
export RECTS="${RECTS:-4}"
export MOVING="${MOVING:-${RECTS:-4}}"
export CEILING_KB="${CEILING_KB:-1200000}"
export IDLE_MS="${IDLE_MS:-6000}"
export VMMAP="${VMMAP:-1}"
export VMMAP_AT_KB="${VMMAP_AT_KB:-}"
export SAMPLE_SECONDS="${SAMPLE_SECONDS:-0}"
export BASE="${BASE:-1}"
${BASE_W:+export BASE_W="$BASE_W"}
export BASE_CROP="${BASE_CROP:-1}"
export BASE_ROWS="${BASE_ROWS:-}"
export OVERLAY_ROW_SHIFT="${OVERLAY_ROW_SHIFT:-}"
export MALLOC_HISTORY="${MALLOC_HISTORY:-}"
${BASE_H:+export BASE_H="$BASE_H"}
export REPEATS="${REPEATS:-1}"
export SAMPLE_EVERY="${SAMPLE_EVERY:-20}"
${SHEET_W:+export SHEET_W="$SHEET_W"}
${SHEET_H:+export SHEET_H="$SHEET_H"}
exec "$(command -v node)" "$repo/scripts/wezterm-memory/repro.mjs"
EOF
chmod +x "$launcher"

case "$(basename "$app")" in
  WezTerm.app)
    build="$("$app/Contents/MacOS/wezterm" --version | awk '{print $2}')"
    # WEZ_CONFIG is a space-separated list of key=value overrides, so a run can
    # turn one of WezTerm's own knobs and be compared against the same workload
    # with it left alone.
    extra=()
    for kv in ${WEZ_CONFIG:-}; do extra+=(--config "$kv"); done
    echo "${WEZ_CONFIG:-（defaults）}" >"$out/wez-config.txt"
    "$app/Contents/MacOS/wezterm-gui" --config-file "$repo/scripts/stage6-wezterm/wezterm.lua" \
      "${extra[@]+"${extra[@]}"}" \
      start --always-new-process -- "$launcher" >"$out/terminal.log" 2>&1 &
    ;;
  kitty.app)
    build="$("$app/Contents/MacOS/kitty" --version | awk '{print $2}')"
    "$app/Contents/MacOS/kitty" --config NONE -o enable_audio_bell=no \
      -o initial_window_width=100c -o initial_window_height=30c \
      --instance-group "mdv-probe-$$" "$launcher" >"$out/terminal.log" 2>&1 &
    ;;
  Ghostty.app)
    build="$("$app/Contents/MacOS/ghostty" --version | head -1 | awk '{print $2}')"
    "$app/Contents/MacOS/ghostty" --window-width=100 --window-height=30 \
      -e "$launcher" >"$out/terminal.log" 2>&1 &
    ;;
  *)
    echo "unsupported terminal bundle: $app" >&2; exit 2 ;;
esac
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
echo "$terminal ($build) case $case_id -> $out"

# Raise the window. This is not cosmetic: an occluded window is not composited,
# so AppKit never calls draw_rect and the terminal renders nothing. Two runs of
# the same configuration disagreed by 47 MB/frame until this was pinned, because
# one of them happened to open behind another window.
if [ "${RAISE:-1}" = "1" ]; then
  ( sleep 2; open -a "$app" 2>/dev/null || true ) &
fi

ceiling="${CEILING_KB:-1200000}"
( # outer watchdog
  while kill -0 "$pid" 2>/dev/null; do
    rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [ -n "$rss" ]; then
      echo "$rss" >>"$out/outer-rss.txt"
      if [ "$rss" -gt "$((ceiling + 300000))" ] 2>/dev/null; then
        echo "WATCHDOG: ${rss}KB > ceiling, killing the terminal" | tee "$out/watchdog.txt" >&2
        kill -9 "$pid" 2>/dev/null || true
        exit 1
      fi
    fi
    sleep 1
  done
) &
watchdog=$!

waited=0
while kill -0 "$pid" 2>/dev/null; do
  sleep 1; waited=$((waited + 1))
  if [ "$waited" -gt "${TIMEOUT:-600}" ]; then
    echo "timed out; killing" >&2; kill -9 "$pid" 2>/dev/null || true; break
  fi
done
kill "$watchdog" 2>/dev/null || true
trap - EXIT

echo "$build" >"$out/build.txt"
[ -s "$out/result.json" ] || { echo "no result.json; see $out/terminal.log" >&2; exit 1; }
node "$repo/scripts/wezterm-memory/report.mjs" "$out"
