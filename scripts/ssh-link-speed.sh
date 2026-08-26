#!/bin/sh
# How fast is this SSH link, really?
#
#   sh scripts/ssh-link-speed.sh [--seconds N] [--max-mb N]
#
# Run it from the shell inside the SSH session, with Neovim closed. Prints the
# `render.ssh_link_bytes_per_sec` line to paste into your md-viewer config.
#
# For scale, two links measured with this script and its predecessors:
#
#     AWS SSM tunnel        ~800,000 B/s   the agent paces its output at a
#                                          kilobyte per millisecond and AWS says
#                                          they will not raise it -- see
#                                          docs/local-render-design.md
#     plain SSH, LAN host  ~17,000,000     2026-08-25, 8 MB in 0.47-0.54s
#
# Twenty times apart, so "it is remote" tells you nothing useful and this is
# worth actually running.
#
# This has to be a shell script writing to the terminal, and it cannot be a Lua
# function inside Neovim, because from inside Neovim the answer is not
# observable. `nvim_ui_send` appends to Neovim's own UI queue and returns; the
# TUI drains that queue later. On the SSM link above:
#
#     from inside Neovim   96 payloads, 24 MB, 0.03s, no write ever waited
#     from the shell        8 MB in 11.0s -> 760,267 B/s
#
# So a plugin timing its own writes measures a queue insertion and concludes the
# link runs at ~100 MB/s. That is why md-viewer asks for this number instead of
# inferring one, and why a configured rate is never capped against a heuristic.
#
# Two things make the measurement honest, and an earlier version of this script
# had neither:
#
#   * **Enough data.** The first megabytes go into buffers that are not the
#     link, so a short run reads the buffer. On the SSM link, 2 MB reported
#     1,394,274 B/s where 8 MB reported 763,448 -- the short run was reading a
#     buffer and overstating by 80%. This keeps doubling until the transfer
#     takes --seconds.
#   * **Enough clock.** `date +%s` is whole seconds, so on a fast link a fixed
#     8 MB payload finishes inside one tick and the answer is quantised to the
#     payload size rather than measured -- the LAN figure above takes 0.5s, so
#     a whole-second clock would have reported it as either 8 MB/s or infinity.
#     Sub-second timing is used where the platform has it, and the doubling
#     above is what makes the result sound even where it does not.
set -eu

TARGET_SECONDS=5
MAX_MB=512

while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) TARGET_SECONDS="${2:-5}"; shift 2 ;;
    --max-mb) MAX_MB="${2:-512}"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "usage: sh scripts/ssh-link-speed.sh [--seconds N] [--max-mb N]" >&2; exit 2 ;;
  esac
done

# What is being measured is the terminal link. Redirected to a file or a pipe,
# every number below is the speed of that file or pipe instead -- measured here,
# 1,398,101,333 B/s into a file on a host whose link does nothing like that. A
# plausible wrong answer is worse than no answer, because this one gets pasted
# into a config and believed.
if [ ! -t 1 ]; then
  echo "refusing: stdout is not a terminal, so this would measure the redirection" >&2
  echo "rather than the link. Run it directly in the SSH session." >&2
  exit 2
fi

if [ -z "${SSH_CONNECTION:-}${SSH_TTY:-}" ]; then
  echo "warning: this does not look like an SSH session, so it will measure a local pty" >&2
fi

# Milliseconds since the epoch, from whichever of these the platform has.
# GNU date supports %N; BSD/macOS date does not and returns a literal N.
if [ "$(date +%N 2>/dev/null)" != "N" ] && [ -n "$(date +%N 2>/dev/null)" ]; then
  # `date +%N` is zero-padded to nine digits, and POSIX shell arithmetic reads a
  # leading zero as octal -- so 088953509 is a syntax error rather than a number.
  now_ms() {
    _s=$(date +%s)
    _n=$(date +%N)
    _n=${_n#"${_n%%[!0]*}"}
    echo $((_s * 1000 + ${_n:-0} / 1000000))
  }
  CLOCK="date +%N"
elif command -v python3 >/dev/null 2>&1; then
  now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
  CLOCK="python3"
elif command -v perl >/dev/null 2>&1; then
  now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
  CLOCK="perl"
else
  now_ms() { echo $(( $(date +%s) * 1000 )); }
  CLOCK="whole seconds only"
fi

clear_screen() { printf '\033[2J\033[H' 2>/dev/null || true; }

# What gets sent, and why it is not a stream of one repeated byte.
#
# An earlier version sent `tr '\0' '.'`, which is the most compressible payload
# it is possible to construct. Any compressing hop between here and the terminal
# -- `ssh -C`, `Compression yes` in a config, a websocket negotiating
# permessage-deflate -- then carries almost nothing while this script believes it
# sent the full amount, and reports a rate the link cannot actually do.
#
# That matters because of what md-viewer sends: base64-encoded PNG. PNG is
# already deflated, so base64 of it is incompressible, and a rate measured on
# compressible bytes does not predict it at all. This measures what the plugin
# actually pushes -- base64 over random bytes -- so a compressing hop is included
# honestly rather than flattering the result.
payload() { dd if=/dev/urandom bs=1024 count=$(( $1 * 768 )) 2>/dev/null | base64; }

# base64 of urandom is ~4/3 of its input, so ask for 768 KB of entropy per
# megabyte wanted and check what actually came out rather than assuming.
measure_payload_bytes() { payload "$1" | wc -c | tr -d ' '; }

# Can this host even generate the payload faster than the link carries it? If
# not, the number below is the CPU's and not the link's. Timed to /dev/null,
# where there is no link at all.
GEN_START=$(now_ms)
payload 8 > /dev/null
GEN_END=$(now_ms)
GEN_MS=$((GEN_END - GEN_START))
[ "$GEN_MS" -gt 0 ] || GEN_MS=1

# Fill whatever sits between here and the far end before timing anything, so the
# measurement is of the link rather than of a buffer accepting a burst.
clear_screen
payload 1 || true
clear_screen

echo "timing this terminal (clock: $CLOCK, target ${TARGET_SECONDS}s), please do not type..."

MEGABYTES=8
RATE=0
ELAPSED_MS=0
while :; do
  BYTES=$(measure_payload_bytes "$MEGABYTES")
  START=$(now_ms)
  payload "$MEGABYTES"
  END=$(now_ms)
  clear_screen

  ELAPSED_MS=$((END - START))
  [ "$ELAPSED_MS" -gt 0 ] || ELAPSED_MS=1
  RATE=$((BYTES * 1000 / ELAPSED_MS))

  echo "  $((BYTES / 1024 / 1024)) MB in $((ELAPSED_MS / 1000)).$(printf '%03d' $((ELAPSED_MS % 1000)))s -> ${RATE} bytes/sec"

  if [ $((ELAPSED_MS / 1000)) -ge "$TARGET_SECONDS" ]; then break; fi
  if [ $((MEGABYTES * 2)) -gt "$MAX_MB" ]; then
    echo
    echo "  Stopping at ${MAX_MB} MB without reaching ${TARGET_SECONDS}s. This link is fast"
    echo "  enough that the terminal, not the network, may be what is being measured."
    break
  fi
  MEGABYTES=$((MEGABYTES * 2))
done

# Generating 8 MB took GEN_MS with no link involved at all. If that is an
# appreciable fraction of what the same payload took through the terminal, then
# some of what was just measured is this host making bytes rather than the link
# carrying them, and the answer is a floor rather than a rate.
GEN_RATE=$(( 8 * 1024 * 1024 * 1000 / GEN_MS ))
echo
echo "  payload generation alone: ${GEN_RATE} bytes/sec (no link involved)"
if [ "$RATE" -gt 0 ] && [ "$GEN_RATE" -lt $((RATE * 4)) ]; then
  echo
  echo "  WARNING: this host only generates the payload $((GEN_RATE / RATE))x faster than the"
  echo "  rate just measured, so some of that number is CPU rather than link. Treat it"
  echo "  as a lower bound, and prefer the smallest figure any run has produced."
fi

echo
echo "  Paste into your md-viewer setup:"
echo
echo "      render = { ssh_link_bytes_per_sec = ${RATE} },"
echo
echo "  md-viewer uses this for warm-up progress and to bound queued bytes."
echo "  Erring low costs a little staleness; erring high is the failure it corrects."
echo
