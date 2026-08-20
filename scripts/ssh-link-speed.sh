#!/usr/bin/env sh
# How fast is this SSH link, really?
#
#   scripts/ssh-link-speed.sh
#
# Run it **in the SSH session, from the shell, with Neovim closed**. Prints one
# number and the configuration line to put it in. Once per link, not per session.
#
# ## Why this is a shell script and not a `:runtime` one
#
# Over SSH every rendered frame is bytes down a pty, and md-viewer pauses after a
# large upload so the frames produced during it do not queue behind it at
# positions the reader has already left. That pause is a timer over a link rate,
# and md-viewer cannot measure one from inside Neovim. The first version of this
# tried, by timing `nvim_ui_send` and pushing until the writes started to block.
# They never block. Measured on a host shaped to 6400 kbit/s (0.80 MB/s):
#
#     96 payloads, 24 MB, 0.03s, and no write ever had to wait
#
# 24 megabytes accepted in thirty milliseconds on a link that can carry 0.8 per
# second. `nvim_ui_send` hands the bytes to Neovim's own UI queue and returns;
# the TUI drains that queue onto the pty later, on its own time. So a Lua caller
# sees no back-pressure at all, and every "throughput sample" md-viewer has ever
# taken measured the speed of a queue insertion. That is why a real session
# reported 101,169 B/ms -- about 101 MB/s -- for an SSM tunnel, and computed a
# 2 ms pause from it.
#
# A shell writing to its controlling terminal has no such queue in the way. The
# same host, same shaping, from the shell:
#
#     2 MB  ->  1.50s  ->  1,394,274 B/s     (buffers still absorbing)
#     8 MB  -> 10.99s  ->    763,448 B/s     (against a real 800,000)
#
# Within 5%, and low rather than high, which is the safe direction: erring slow
# costs staleness, erring fast costs the backlog this whole mechanism exists to
# prevent. The first megabytes are absorbed by pty, sshd and TCP buffers, which
# is why this fills them before it starts timing anything.
#
# ## What it does to your terminal
#
# Writes spaces to it -- several megabytes of them -- then clears the screen.
# Nothing is left behind and no escape sequence is interpreted, but the screen
# will be busy for as long as the measurement takes, which on a slow link is
# most of a minute.
set -eu

# Buffers first, then the measurement. 4 MB is comfortably more than a pty plus
# an sshd plus a TCP window, so by the time the timed run starts there is nowhere
# left for it to be absorbed -- which is the entire difference between this and
# the number md-viewer arrives at on its own.
FILL_MB="${MD_VIEWER_FILL_MB:-4}"
MEASURE_MB="${MD_VIEWER_MEASURE_MB:-8}"

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

[ -t 1 ] || die "No terminal on stdout. Run this from the shell in your SSH session, not through a pipe."

if [ -z "${SSH_CONNECTION:-}${SSH_TTY:-}" ]; then
  cat <<'EOF'
Not an SSH session, so there is no link to measure.

This matters only when Neovim itself runs on the far end of an SSH connection
and rendered frames have to travel back to your terminal. A local preview writes
to a terminal on the same machine, and md-viewer does not pause for one --
render.ssh_link_bytes_per_sec is ignored there.
EOF
  exit 0
fi

command -v dd >/dev/null 2>&1 || die "dd not found"
command -v tr >/dev/null 2>&1 || die "tr not found"
command -v awk >/dev/null 2>&1 || die "awk not found"

# Nanoseconds where the platform has them. `date +%s.%N` prints a literal "%N" on
# platforms without it, which would silently turn the arithmetic below into
# nonsense rather than failing -- so it is tested rather than assumed.
now() { date +%s.%N; }
case "$(now)" in
  *N*) die "This shell's date(1) has no sub-second resolution; run it on the remote host, which is where the link is." ;;
esac

blast() { dd if=/dev/zero bs=1048576 count="$1" 2>/dev/null | tr '\0' ' '; }

printf 'md-viewer: measuring this link. The screen will be busy for a minute.\n'
printf 'Filling buffers with %s MB...\n' "$FILL_MB"
blast "$FILL_MB" > /dev/tty

printf '\033[2J\033[H'
start="$(now)"
blast "$MEASURE_MB" > /dev/tty
finish="$(now)"
printf '\033[2J\033[H'

awk -v mb="$MEASURE_MB" -v start="$start" -v finish="$finish" '
BEGIN {
  seconds = finish - start
  if (seconds <= 0) {
    print "The timed run took no measurable time, so this link could not be filled."
    print ""
    print "Leave render.ssh_link_bytes_per_sec unset: it sizes a pause that keeps a large"
    print "upload from burying the frames behind it, and on a link this fast there is"
    print "nothing to keep apart."
    exit 0
  }
  bytes = mb * 1048576
  rate = bytes / seconds
  printf "md-viewer: link speed\n\n"
  printf "  %d bytes/sec  (%.2f MB/s)\n\n", rate, rate / 1048576
  printf "Put this in your md-viewer configuration:\n\n"
  printf "    render = { ssh_link_bytes_per_sec = %d },\n\n", rate
  # As a %s argument, not as a literal: awk reads a leading "--" in a printf
  # format as the decrement operator and refuses the whole program.
  printf "%s\n\n", "-- How this was measured ---------------------------------------------"
  printf "  buffers filled first, then %d MB timed over %.2fs\n", mb, seconds
  printf "  measured from the shell, writing to the terminal directly\n\n"
  printf "That last line is the whole point. md-viewer cannot take this measurement\n"
  printf "itself: nvim_ui_send queues into Neovim and returns, so from inside Lua a\n"
  printf "slow link and a fast one look identical -- 24 MB was accepted in 0.03s on a\n"
  printf "link doing 0.8 MB/s. Every rate md-viewer infers on its own is the speed of\n"
  printf "that queue, which is why :MdViewerHealth asks you to run this instead.\n"
}
'
