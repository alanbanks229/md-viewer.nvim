#!/usr/bin/env bash
# Stage-6 WezTerm geometry run. Launches one WezTerm window with a pinned
# config, lets probe.lua draw through md-viewer's real placement path, and
# screenshots the display at each phase.
#
#   ./run.sh <path-to-WezTerm.app> [label]
#
# macOS requires Screen Recording permission for whichever process calls
# `screencapture` -- that is the terminal this script runs in, not WezTerm.
# Without it the captures come back as desktop wallpaper with no windows, which
# assert.mjs reports as "no fiducial row found" rather than silently passing.
set -euo pipefail

app="${1:?usage: run.sh <path-to-WezTerm.app> [label]}"
gui="$app/Contents/MacOS/wezterm-gui"
cli="$app/Contents/MacOS/wezterm"
[ -x "$gui" ] || { echo "no wezterm-gui at $gui" >&2; exit 2; }

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
build="$("$cli" --version | awk '{print $2}')"
label="${2:-$build}"
out="$repo/tmp/stage6/$label"

rm -rf "$out"; mkdir -p "$out"
echo "build:  $build"
echo "app:    $app"
echo "out:    $out"

# --always-new-process so this never attaches to a WezTerm the operator has
# open with their own config; -n on nvim's side is not enough on its own.
MD_VIEWER_REPO="$repo" \
MD_VIEWER_STAGE6_OUT="$out" \
MD_VIEWER_STAGE6_BUILD="$build" \
"$gui" --config-file "$repo/scripts/stage6-wezterm/wezterm.lua" \
  start --always-new-process -- \
  nvim -u NONE -i NONE --cmd "set runtimepath+=$repo" \
    -c "luafile $repo/scripts/stage6-wezterm/probe.lua" \
  >"$out/wezterm.log" 2>&1 &
wez_pid=$!

cleanup() { kill "$wez_pid" 2>/dev/null || true; }
trap cleanup EXIT

# A `while` loop's exit status is that of the last command in its body, not
# zero -- so under `set -e` the final failing bounds check used to take the
# whole script down the moment the file appeared. Hence the explicit return.
wait_for() {
  local file="$1" limit="${2:-60}" waited=0
  while [ ! -e "$file" ]; do
    if [ -e "$out/error.txt" ]; then echo "probe failed: $(cat "$out/error.txt")" >&2; exit 1; fi
    if ! kill -0 "$wez_pid" 2>/dev/null; then echo "wezterm exited early; see $out/wezterm.log" >&2; exit 1; fi
    if [ "$waited" -gt $((limit * 4)) ]; then echo "timed out waiting for $file" >&2; exit 1; fi
    sleep 0.25
    waited=$((waited + 1))
  done
  return 0
}

for phase in 1 2 3; do
  echo "waiting for phase $phase..."
  wait_for "$out/phase-$phase.ready"
  # A window launched from a background process opens *behind* whatever the
  # operator was using, and `screencapture` photographs the display, not the
  # window -- so an unraised window is simply absent from the capture, which
  # assert.mjs then reports as a missing fiducial row. `open -a` raises it
  # without needing Accessibility permission.
  open -a "$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
  # A beat for the compositor: the ready marker means the escapes were queued,
  # not that the GPU has presented them.
  sleep 0.8
  if ! screencapture -x -o -t png "$out/phase-$phase.png"; then
    echo "screencapture failed for phase $phase (exit $?)" >&2
    exit 1
  fi
  touch "$out/phase-$phase.done"
  echo "captured phase $phase -> $(cd "$out" && ls -l "phase-$phase.png" | awk '{print $5}') bytes"
done

wait "$wez_pid" 2>/dev/null || true
trap - EXIT
echo
node "$repo/scripts/stage6-wezterm/assert.mjs" "$out"
