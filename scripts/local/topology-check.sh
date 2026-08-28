#!/bin/sh
# K1, the topology experiment: does `ssh -t` behave when its stdout is a pipe
# through the local-render helper -- raw mode, window-size propagation, the
# `~.` escape, and a usable full-screen nvim? The design's whole stdin-
# inherited/stdout-piped seam rests on OpenSSH taking tty control and WINCH
# from stdin, which is a reading of upstream source, not a fact this repo has
# proven -- so this script proves or kills it per host.
#
#   scripts/local/topology-check.sh [ssh-host]     # default: localhost
#
# Needs: tmux locally; key-based (promptless) ssh auth to the host; nvim on
# the host for the full-screen check. Run it once on a LAN/localhost link as
# the gate, and again over the real SSM ProxyCommand host from the work
# laptop -- the second run is the one that settles K1 for the reference
# environment, and this script prints which host it ran against for exactly
# that reason.
#
# Verdicts: RESIZE(rows/cols), ESCAPE(~.), NVIM are pass/fail -- any FAIL is
# a K1 kill for that host. PIXELS is informational: a link that does not
# propagate ws_xpixel/ws_ypixel degrades (the helper's probe supplies cell
# size) and does not kill.

set -u

host=${1:-localhost}
here=$(cd "$(dirname "$0")/../.." && pwd)
session="mdv-topology-$$"
fails=0
notes=""

say() { printf '%s\n' "$*"; }
verdict() { # name pass|fail|info detail
  case $2 in
    fail) fails=$((fails + 1)) ;;
  esac
  notes="${notes}$1: $(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')  $3
"
}

command -v tmux >/dev/null 2>&1 || { say "tmux is required"; exit 2; }

capture() { tmux capture-pane -p -t "$session" 2>/dev/null; }

wait_for() { # pattern timeout-deciseconds
  _i=0
  while [ "$_i" -lt "$2" ]; do
    if capture | grep -q "$1"; then return 0; fi
    sleep 0.2
    _i=$((_i + 1))
  done
  return 1
}

send() { tmux send-keys -t "$session" "$@"; }

cleanup() {
  tmux kill-session -t "$session" 2>/dev/null
}
trap cleanup EXIT INT TERM

# The helper wraps ssh; the wrapper's own exit code is surfaced so the ~.
# check can see the whole chain come down. The trailing sleep keeps the pane
# alive long enough to read that line -- without it, a *successful* escape
# kills the pane, the session, and the evidence in one stroke, and the check
# reports the opposite of what happened (which is exactly how this script's
# first version misreported a passing K1 as a kill verdict).
tmux new-session -d -s "$session" -x 100 -y 30 \
  "sh -c 'node \"$here/renderer/src/local-main.js\" -- ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=yes \"$host\"; echo HELPER-EXIT=\$?; sleep 120'"

say "topology-check against: $host (100x30 tmux pane)"

if ! wait_for "HELPER-EXIT\|\\$\|%\|#\|>" 100; then
  say "no shell prompt appeared within 20s -- is promptless key auth set up for $host?"
  capture | tail -5
  exit 2
fi
if capture | grep -q "HELPER-EXIT"; then
  say "the session died before any check ran:"
  capture | tail -8
  exit 2
fi

# -- TTY: the remote must see a real terminal on stdin.
send -l 'if [ -t 0 ]; then echo TTY-YES; else echo TTY-NO; fi'
send Enter
wait_for "TTY-" 50
if capture | grep -q "TTY-YES"; then
  verdict TTY pass "remote stdin is a tty through the piped-stdout wrapper"
else
  verdict TTY fail "remote stdin is not a tty; ssh did not allocate a pty"
fi

# -- RESIZE: rows/cols must follow the local window through WINCH.
send -l 'stty size'
send Enter
wait_for "30 100" 50 || true
tmux resize-window -t "$session" -x 120 -y 40 2>/dev/null || tmux resize-pane -t "$session" -x 120 -y 40
sleep 1
send -l 'stty size'
send Enter
if wait_for "40 120" 50; then
  verdict RESIZE pass "remote stty size followed the local resize to 40x120"
else
  verdict RESIZE fail "remote stty size did not follow a local resize (got: $(capture | grep -E '^[0-9]+ [0-9]+$' | tail -1))"
fi

# -- PIXELS: informational; needs python3 remotely to read TIOCGWINSZ.
send -l 'python3 -c "import fcntl,struct,termios;r,c,x,y=struct.unpack(chr(72)*4,fcntl.ioctl(1,termios.TIOCGWINSZ,bytes(8)));print(f\"PX rows={r} cols={c} xpixel={x} ypixel={y}\")" 2>/dev/null || echo "PX unavailable"'
send Enter
wait_for "PX " 50 || true
px=$(capture | grep "^PX " | tail -1)
case $px in
  *"xpixel=0"*) verdict PIXELS info "ws_xpixel is 0 over this link; the helper's probe supplies cell size ($px)" ;;
  *xpixel=*) verdict PIXELS info "pixel fields propagate ($px)" ;;
  *) verdict PIXELS info "could not read TIOCGWINSZ remotely (no python3?)" ;;
esac

# -- NVIM: a full-screen application must be usable through the filter path.
# The wait pattern must not match the shell prompt (a home-directory prompt
# contains `~`), or the quit keystrokes race nvim's startup.
send -l 'nvim --clean'
send Enter
if wait_for 'NVIM v' 100; then
  sleep 1
  send Escape
  send -l ':q!'
  send Enter
  sleep 2
  verdict NVIM pass "nvim --clean drew its UI and quit cleanly"
else
  verdict NVIM fail "nvim --clean never drew a recognizable UI"
fi

# -- ESCAPE: `~.` at line start must tear the whole chain down. Sent as
# separate keystrokes with real gaps, the way a human types it.
send Enter
sleep 1
send -l '~'
sleep 0.5
send -l '.'
if wait_for "HELPER-EXIT=" 75; then
  verdict ESCAPE pass "~. disconnected ssh and the helper exited ($(capture | grep -o 'HELPER-EXIT=[0-9]*' | tail -1))"
else
  verdict ESCAPE fail "~. did not bring the session down within 15s"
  say "escape-failure pane tail:"
  capture | grep -v '^$' | tail -6
fi

say ""
say "$notes"
if [ "$fails" -eq 0 ]; then
  say "K1 topology-check: PASS on $host"
  exit 0
fi
say "K1 topology-check: FAIL ($fails) on $host -- the piped-stdout topology does not hold here"
exit 1
