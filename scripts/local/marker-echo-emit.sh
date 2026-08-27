#!/bin/sh
# The remote half of the K2 marker-transit check. Run this on the VM inside a
# session wrapped by `local-main.js --marker-echo-test`, handing it the token
# the helper printed at startup:
#
#   sh scripts/local/marker-echo-emit.sh <token> [count]
#
# It emits <count> (default 10000) markers numbered s=1..N straight into the
# pty, interleaved with ordinary text and CSI traffic so the transit test
# exercises marker framing *between* other sequences, not on a quiet line.
# The helper's exit report must then show received=N missing=0
# out-of-order=0 malformed=0 -- anything else on a given link is a K2 kill
# verdict for that link.
#
# This measures transit integrity only. Nothing here renders, and no timing
# printed by this script is a latency measurement.

set -eu

token=${1:?usage: marker-echo-emit.sh <token> [count]}
count=${2:-10000}

case $token in
  *[!0-9a-f]*) echo "token must be lowercase hex (copy it from the helper's 'marker-echo token:' line)" >&2; exit 2 ;;
esac

esc=$(printf '\033')
i=1
while [ "$i" -le "$count" ]; do
  # A marker with empty placement/deletion bodies: structurally complete,
  # semantically inert.
  printf '%s_Mv=1;t=%s;s=%d;d=echo;p=;x=%s\\' "$esc" "$token" "$i" "$esc"
  # Noise between markers: text plus cursor movement, so markers routinely
  # arrive mid-screen rather than at column 0 of an idle terminal.
  if [ $((i % 50)) -eq 0 ]; then
    printf '%s[Kmarker-echo %d/%d\r' "$esc" "$i" "$count"
  fi
  i=$((i + 1))
done
printf '\n%s[Kemitted %d markers (s=1..%d)\n' "$esc" "$count" "$count"
