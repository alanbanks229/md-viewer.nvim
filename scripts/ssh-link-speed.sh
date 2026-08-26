#!/bin/sh
# How fast is this SSH link, really?
#
#   sh scripts/ssh-link-speed.sh [--seconds N] [--max-mb N] [--samples N]
#                                [--write-cache] [--quiet] [--out FILE]
#
# Run it from the shell inside the SSH session, with Neovim closed. Prints the
# `render.ssh_link_bytes_per_sec` line to paste into your md-viewer config -- or
# with --write-cache, files the answer where md-viewer looks for it by itself
# and there is nothing to paste anywhere. Prefer that: one ~/.config/nvim is
# symlinked to every machine, so a constant correct on one of them is wrong on
# the next, and the two links below are fourteen times apart.
#
# `:MdViewerMeasureLink` runs this script from inside Neovim, which is the same
# measurement without closing anything.
#
# For scale, the two links this script has been run against, measured
# 2026-08-25 with 64 MB of payload each:
#
#     AWS SSM tunnel      ~1,030,000 B/s   with `Compression yes`. The channel
#                                          underneath carries ~774,000: the
#                                          agent paces its output at a kilobyte
#                                          per millisecond and AWS says they
#                                          will not raise it. The difference is
#                                          the compressor, and it is real --
#                                          see the payload note below and
#                                          docs/local-render-design.md
#     plain SSH, LAN host ~14,700,000      no compression, plain TCP/22
#
# Fourteen times apart, so "it is remote" tells you nothing useful and this is
# worth actually running. Neither figure is guessable from the other, which is
# the entire reason this script exists rather than a constant.
#
# This has to be a shell script writing to the terminal, and it cannot be a Lua
# function inside Neovim, because from inside Neovim the answer is not
# observable. `nvim_ui_send` appends to Neovim's own UI queue and returns; the
# TUI drains that queue later. On an SSM link doing well under a megabyte a
# second:
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
SAMPLES=1
QUIET=0
OUT_FILE=
CACHE_FILE=
WRITE_CACHE=0
KEY=
PRINT_KEY=0

usage() {
  cat <<'USAGE'
How fast is this SSH link, really?

  sh scripts/ssh-link-speed.sh [options]

  --seconds N     grow the payload until one transfer takes this long (5)
  --max-mb N      stop growing here even if it never does (512)
  --samples N     repeat the settled transfer N times and keep the lowest (1)
  --quiet         no narration on stdout, which is the terminal being measured
  --out FILE      write the result as key=value lines, for a caller to read
  --write-cache   file the result where md-viewer reads it, instead of printing
                  a config line to paste
  --cache FILE    write the cache record here instead of the derived path
  --key HASH      use this cache key rather than computing one
  --print-key     print this machine's cache key and exit, measuring nothing
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --seconds) TARGET_SECONDS="${2:-5}"; shift 2 ;;
    --max-mb) MAX_MB="${2:-512}"; shift 2 ;;
    --samples) SAMPLES="${2:-1}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --out) OUT_FILE="${2:-}"; shift 2 ;;
    --write-cache) WRITE_CACHE=1; shift ;;
    --cache) CACHE_FILE="${2:-}"; WRITE_CACHE=1; shift 2 ;;
    --key) KEY="${2:-}"; shift 2 ;;
    --print-key) PRINT_KEY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[ "$SAMPLES" -ge 1 ] 2>/dev/null || SAMPLES=1

# Narration, suppressed by --quiet. Anything a reader needs to *act* on goes to
# stderr instead of through here, so it survives --quiet and so a caller reading
# --out can still see it.
say() { [ "$QUIET" = 1 ] || echo "$@"; }

# ---------------------------------------------------------------------------
# The cache key
#
# md-viewer computes this too, in lua/md-viewer/linkrate.lua, and the two must
# agree byte for byte or a measurement taken here is filed where nothing reads
# it. `tests/lua/cases/linkrate.lua` runs `--print-key` against a fabricated
# environment and compares. Hashed because the material holds both ends' IP
# addresses and the key gets printed in diagnostics people paste into issues.
# ---------------------------------------------------------------------------

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then
    # "(stdin)= <hex>" on some builds, "SHA2-256(stdin)= <hex>" on others.
    openssl dgst -sha256 | sed 's/.*= *//'
  else
    return 1
  fi
}

link_key_material() {
  # SSH_CONNECTION is "<client ip> <client port> <server ip> <server port>", and
  # is deliberately split on whitespace here. Client IP alone would not do: an
  # SSM tunnel is a loopback forward, so both ends read 127.0.0.1.
  # shellcheck disable=SC2086
  set -- ${SSH_CONNECTION:-}
  _term=${TERM_PROGRAM:-}
  [ -n "$_term" ] || _term=${LC_TERMINAL:-}
  [ -n "$_term" ] || _term=${TERM:-}
  printf 'md-viewer-link-rate-1\nhost=%s\nclient=%s\nserver=%s\nterm=%s' \
    "$(uname -n 2>/dev/null || echo '')" "${1:-}" "${3:-}" "$_term"
}

link_key() { link_key_material | sha256_hex | cut -c1-16; }

# Where `vim.fn.stdpath("state")` lands on every platform md-viewer runs on.
default_cache_path() {
  printf '%s/%s/md-viewer/link-rate/%s.json' \
    "${XDG_STATE_HOME:-$HOME/.local/state}" "${NVIM_APPNAME:-nvim}" "$1"
}

if [ "$PRINT_KEY" = 1 ]; then
  if ! link_key; then
    echo "no sha256 tool found (sha256sum, shasum or openssl)" >&2
    exit 2
  fi
  exit 0
fi

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

# What gets sent, and why it is not a stream of one repeated byte -- and what
# this script therefore measures, which is not the channel.
#
# An earlier version sent `tr '\0' '.'`, which is the most compressible payload
# it is possible to construct. Any compressing hop between here and the terminal
# -- `ssh -C`, `Compression yes` in a config, a websocket negotiating
# permessage-deflate -- then carries almost nothing while this script believes it
# sent the full amount, and reports a rate the link cannot actually do. On the
# SSM link, the same 64 MB took 6.36s compressible against 86.23s incompressible:
# a factor of 13.6, which is the whole of the 8-10 MB/s that script used to
# report for a link doing well under one.
#
# So the payload is base64 over /dev/urandom, because that is what md-viewer
# actually pushes: base64-encoded PNG. **It is not incompressible, and an earlier
# version of this comment claimed it was.** base64 is 64 symbols carried in
# 8-bit bytes -- six bits of entropy per byte -- so deflate takes it to about 75%
# whatever is inside, PNG or noise or Shakespeare. The compressor is not defeated
# here; it is merely held to the one quarter it can always get.
#
# That is the right payload anyway, and the number it produces is the useful one,
# as long as you know which number it is: this measures the **effective** rate,
# md-viewer's bytes as md-viewer sends them, with whatever a compressing hop
# gives back already included. It is not the channel's own capacity, and on a
# compressing link the two differ by exactly that quarter. Measured on an AWS SSM
# tunnel with `Compression yes`, 2026-08-25:
#
#     raw channel, incompressible, 64 MiB x3     774,000 B/s   the channel
#     this script, base64, through the pty     1,010,000-      what md-viewer
#                                              1,070,000 B/s   experiences
#
# and 774,000 / 0.75 = 1,032,000, which is the measured band. Configure md-viewer
# with the effective figure -- it is the one that predicts how long a frame takes
# -- and reach for the channel figure only when arguing about the link itself.
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

say "timing this terminal (clock: $CLOCK, target ${TARGET_SECONDS}s), please do not type..."

report_run() {
  say "  $(($1 / 1024 / 1024)) MB in $(($2 / 1000)).$(printf '%03d' $(($2 % 1000)))s -> $3 bytes/sec"
}

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

  report_run "$BYTES" "$ELAPSED_MS" "$RATE"

  if [ $((ELAPSED_MS / 1000)) -ge "$TARGET_SECONDS" ]; then break; fi
  if [ $((MEGABYTES * 2)) -gt "$MAX_MB" ]; then
    echo "note: stopped at ${MAX_MB} MB without reaching ${TARGET_SECONDS}s. This link is fast" >&2
    echo "enough that the terminal, not the network, may be what is being measured." >&2
    break
  fi
  MEGABYTES=$((MEGABYTES * 2))
done

# Repeatability, once the ramp has settled on a payload the link takes real time
# to carry. The settled run above is the first sample rather than a warm-up to be
# discarded -- it is the same transfer at the same size, and discarding it would
# cost a slow link a whole minute to learn nothing.
#
# The lowest sample wins, not the mean. Every way this measurement can go wrong
# makes it look faster than the link is -- a buffer accepting a burst, a
# compressor, a run too short for the clock -- and there is no mechanism that
# makes it look slower. Averaging a real figure with an inflated one produces an
# inflated one; taking the minimum discards exactly the samples that are wrong.
SAMPLE_LIST="$RATE"
SAMPLE_MIN=$RATE
SAMPLE_INDEX=1
while [ "$SAMPLE_INDEX" -lt "$SAMPLES" ]; do
  SAMPLE_INDEX=$((SAMPLE_INDEX + 1))
  START=$(now_ms)
  payload "$MEGABYTES"
  END=$(now_ms)
  clear_screen
  SAMPLE_MS=$((END - START))
  [ "$SAMPLE_MS" -gt 0 ] || SAMPLE_MS=1
  SAMPLE_RATE=$((BYTES * 1000 / SAMPLE_MS))
  SAMPLE_LIST="$SAMPLE_LIST $SAMPLE_RATE"
  if [ "$SAMPLE_RATE" -lt "$SAMPLE_MIN" ]; then SAMPLE_MIN=$SAMPLE_RATE; fi
  report_run "$BYTES" "$SAMPLE_MS" "$SAMPLE_RATE"
done
RATE=$SAMPLE_MIN

# Generating 8 MB took GEN_MS with no link involved at all. If that is an
# appreciable fraction of what the same payload took through the terminal, then
# some of what was just measured is this host making bytes rather than the link
# carrying them, and the answer is a floor rather than a rate.
GEN_RATE=$(( 8 * 1024 * 1024 * 1000 / GEN_MS ))
say
say "  payload generation alone: ${GEN_RATE} bytes/sec (no link involved)"
if [ "$RATE" -gt 0 ] && [ "$GEN_RATE" -lt $((RATE * 4)) ]; then
  echo "warning: this host only generates the payload $((GEN_RATE / RATE))x faster than the rate" >&2
  echo "just measured, so some of that number is CPU rather than link. Treat it as a lower" >&2
  echo "bound, and prefer the smallest figure any run has produced." >&2
fi

if [ -n "$OUT_FILE" ]; then
  {
    echo "version=1"
    echo "bytes_per_sec=$RATE"
    echo "samples=$SAMPLE_LIST"
    echo "payload_bytes=$BYTES"
    echo "elapsed_ms=$ELAPSED_MS"
    echo "generation_bytes_per_sec=$GEN_RATE"
    echo "clock=$CLOCK"
  } > "$OUT_FILE"
fi

if [ "$WRITE_CACHE" = 1 ]; then
  if [ -z "$KEY" ]; then
    if ! KEY=$(link_key); then
      echo "cannot cache: no sha256 tool found (sha256sum, shasum or openssl). Paste the" >&2
      echo "line below into your md-viewer config instead, or run :MdViewerMeasureLink." >&2
      KEY=
    fi
  fi
  if [ -n "$KEY" ]; then
    [ -n "$CACHE_FILE" ] || CACHE_FILE=$(default_cache_path "$KEY")
    CACHE_DIR=$(dirname "$CACHE_FILE")
    # Whole record through a temporary file, so a reader never sees half of one.
    # One `if` over the whole chain rather than `&&` at statement level: `set -e`
    # would take a failed write as a reason to abandon the run, after the answer
    # has already been measured and possibly already written to --out.
    if mkdir -p "$CACHE_DIR" 2>/dev/null &&
      printf '{"version":1,"key":"%s","bytes_per_sec":%s,"samples":[%s],"measured_at":%s,"payload_bytes":%s,"source":"ssh-link-speed.sh"}\n' \
        "$KEY" "$RATE" "$(echo "$SAMPLE_LIST" | tr ' ' ',')" "$(date +%s)" "$BYTES" > "$CACHE_FILE.$$" 2>/dev/null &&
      mv -f "$CACHE_FILE.$$" "$CACHE_FILE" 2>/dev/null; then
      say
      say "  Cached for this machine as $KEY. md-viewer reads it on its own while"
      say "  render.ssh_link_bytes_per_sec is \"auto\", which is the default -- there is"
      say "  nothing to paste."
      say
      exit 0
    fi
    rm -f "$CACHE_FILE.$$" 2>/dev/null || true
    echo "cannot cache: could not write $CACHE_FILE" >&2
    # Only where a config line is actually about to be printed. Under --quiet the
    # caller is reading --out and has the answer already.
    [ "$QUIET" = 1 ] || echo "The config line below carries the same answer, to paste by hand." >&2
  fi
fi

say
say "  Paste into your md-viewer setup:"
say
say "      render = { ssh_link_bytes_per_sec = ${RATE} },"
say
say "  -- or re-run with --write-cache and paste nothing. A number set in config"
say "  wins over a cached one everywhere, which is the problem when that config is"
say "  one file symlinked to several machines."
say
say "  md-viewer uses this to estimate how long a resident warm-up will take. It"
say "  bounds nothing: a configured rate is never capped against a heuristic, and"
say "  no rate is ever inferred from one. Erring low costs a pessimistic estimate;"
say "  erring high is the failure this measurement exists to correct."
say
