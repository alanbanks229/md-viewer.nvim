#!/bin/sh
# How fast is this SSH link, really?
#
#   sh scripts/ssh-link-speed.sh [megabytes]
#
# Run it from the shell inside the SSH session, with Neovim closed. Prints the
# `render.ssh_link_bytes_per_sec` line to paste into your md-viewer config.
#
# This has to be a shell script writing to the terminal, and it cannot be a Lua
# function inside Neovim, because from inside Neovim the answer is not
# observable. `nvim_ui_send` appends to Neovim's own UI queue and returns; the
# TUI drains that queue later. Measured on a link shaped to 0.80 MB/s:
#
#     from inside Neovim   96 payloads, 24 MB, 0.03s, no write ever waited
#     from the shell        8 MB in 11.0s -> 760,267 B/s against a real 800,000
#
# So a plugin timing its own writes measures a queue insertion and concludes the
# link runs at ~100 MB/s. That is why md-viewer asks for this number instead of
# inferring one, and why a configured rate is never capped against a heuristic.
#
# The first megabytes go into buffers that are not the link, so a short run
# reads high. Measured:
#
#     2 MB  ->  1.50s  ->  1,394,274 B/s     (buffers still absorbing)
#     8 MB  -> 10.99s  ->    763,448 B/s     (against a real 800,000)
#
# 8 MB reads ~95% of the true rate and errs low, which is the safe direction:
# erring slow costs a little staleness, erring fast is the failure being
# corrected.
set -eu

MEGABYTES="${1:-8}"
case "$MEGABYTES" in
  *[!0-9]* | "") echo "usage: sh scripts/ssh-link-speed.sh [megabytes]" >&2; exit 2 ;;
esac
[ "$MEGABYTES" -ge 1 ] || { echo "at least 1 MB" >&2; exit 2; }

if [ -z "${SSH_CONNECTION:-}${SSH_TTY:-}" ]; then
  echo "warning: this does not look like an SSH session, so it will measure a local pty" >&2
fi

BYTES=$((MEGABYTES * 1024 * 1024))

# Fill whatever sits between here and the far end before timing anything, so the
# measurement is of the link rather than of a buffer accepting a burst.
printf '\033[2J\033[H' 2>/dev/null || true
dd if=/dev/zero bs=1024 count=1024 2>/dev/null | tr '\0' '.' || true
printf '\033[2J\033[H' 2>/dev/null || true

echo "timing ${MEGABYTES} MB through this terminal, please do not type..."

START=$(date +%s)
dd if=/dev/zero bs=1024 count=$((MEGABYTES * 1024)) 2>/dev/null | tr '\0' '.'
END=$(date +%s)

printf '\033[2J\033[H' 2>/dev/null || true

ELAPSED=$((END - START))
[ "$ELAPSED" -gt 0 ] || ELAPSED=1
RATE=$((BYTES / ELAPSED))

echo
echo "  ${BYTES} bytes in ${ELAPSED}s  ->  ${RATE} bytes/sec"
echo
if [ "$ELAPSED" -lt 5 ]; then
  echo "  Under 5 seconds, so buffers may still be absorbing this and the rate reads"
  echo "  high. Re-run with a larger size:  sh scripts/ssh-link-speed.sh $((MEGABYTES * 4))"
  echo
fi
echo "  Paste into your md-viewer setup:"
echo
echo "      render = { ssh_link_bytes_per_sec = ${RATE} },"
echo
