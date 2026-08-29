#!/bin/sh
# The live pipeline check: everything the local-render unit rigs fake, real.
# A helper-wrapped ssh session in a tmux pane, a real nvim on the remote with
# `render.location = "local"`, the real sshd socket forward, and the helper's
# real browser beside the terminal. scripts/local/e2e-init.lua runs on the
# remote and writes evidence JSON; this script fetches and judges it:
# attached, rendered over the socket, first frame *presented* (injected into
# this terminal's byte stream), one scroll resolved by marker alone, zero
# direct-byte fallbacks.
#
#   scripts/local/live-pipeline-check.sh <ssh-host> [remote-checkout-dir]
#
# Needs: tmux locally; promptless key auth; the same md-viewer commit checked
# out at <remote-checkout-dir> on the host with renderer deps installed
# (npm ci); a system Chrome/Chromium beside this script. tmux never renders
# the injected graphics -- what this proves is the byte pipeline, not glass;
# glass is the operator-driven iTerm2 run in docs/ssh.md.

set -u

host=${1:-}
remote_repo=${2:-md-viewer.nvim}
if [ -z "$host" ]; then
  echo "usage: scripts/local/live-pipeline-check.sh <ssh-host> [remote-checkout-dir]" >&2
  exit 2
fi
here=$(cd "$(dirname "$0")/../.." && pwd)
session="mdv-live-$$"

say() { printf '%s\n' "$*"; }
command -v tmux >/dev/null 2>&1 || {
  say "tmux is required"
  exit 2
}

capture() { tmux capture-pane -p -t "$session" 2>/dev/null; }
send() { tmux send-keys -t "$session" "$@"; }
cleanup() { tmux kill-session -t "$session" 2>/dev/null; }
trap cleanup EXIT INT TERM

wait_for() { # pattern timeout-deciseconds
  _i=0
  while [ "$_i" -lt "$2" ]; do
    if capture | grep -q "$1"; then return 0; fi
    sleep 0.2
    _i=$((_i + 1))
  done
  return 1
}

ssh_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=yes"

tmux new-session -d -s "$session" -x 120 -y 35 \
  "sh -c 'node \"$here/renderer/src/local-main.js\" -- ssh $ssh_opts \"$host\"; echo HELPER-EXIT=\$?; sleep 180'"

say "live-pipeline-check against: $host (remote checkout: ~/$remote_repo)"

if ! wait_for "\\$\|%\|#\|>" 100; then
  say "no shell prompt within 20s -- is promptless key auth set up for $host?"
  capture | tail -5
  exit 2
fi
if capture | grep -q "HELPER-EXIT"; then
  say "the session died before nvim ran:"
  capture | tail -8
  exit 2
fi

send -l "rm -f ~/mdv-e2e.json; nvim -n -u ~/$remote_repo/scripts/local/e2e-init.lua ~/$remote_repo/tests/fixtures/kitchen-sink.md"
send Enter

# The init file quits nvim after writing the evidence (or after its own 90s
# deadline). Poll for the file over a separate ssh connection rather than
# scraping the pane: the pane is full-screen nvim.
i=0
while [ "$i" -lt 150 ]; do
  if ssh $ssh_opts "$host" test -f "mdv-e2e.json" 2>/dev/null; then break; fi
  sleep 1
  i=$((i + 1))
done
if [ "$i" -ge 90 ]; then
  say "no evidence file appeared within 90s; pane tail:"
  capture | tail -10
  exit 1
fi

evidence=$(ssh $ssh_opts "$host" cat "mdv-e2e.json")
send -l "exit"
send Enter

printf '%s' "$evidence" | node -e '
  let input = "";
  process.stdin.on("data", (c) => (input += c));
  process.stdin.on("end", () => {
    const e = JSON.parse(input);
    const s = e.sessions[0] ?? {};
    const checks = [
      ["attached", e.status.phase === "attached", e.status.phase + (e.status.reason ? " (" + e.status.reason + ")" : "")],
      ["render over socket", (s.document_height_px ?? 0) > 0, "documentHeightPx=" + s.document_height_px],
      ["viewport path (no resident)", s.render_path === "viewport", String(s.render_path)],
      ["frame markers emitted", (s.local_marker_frames ?? 0) >= 2, "frames=" + s.local_marker_frames],
      ["frames presented (injected)", (s.local_presented_count ?? 0) >= 2, "presented=" + s.local_presented_count],
      ["scroll applied by marker", (s.applied_scroll_y ?? 0) > 0, "appliedScrollY=" + s.applied_scroll_y],
      ["zero direct-byte fallbacks", (e.markers.direct_bytes_fallbacks ?? 1) === 0, "fallbacks=" + e.markers.direct_bytes_fallbacks],
      ["K4 burst ran", (e.extra.burst_steps ?? 0) >= 30, "burstSteps=" + e.extra.burst_steps],
      ["did not time out", !e.extra.timed_out, "timedOut=" + Boolean(e.extra.timed_out)],
    ];
    let fails = 0;
    for (const [name, ok, detail] of checks) {
      if (!ok) fails += 1;
      console.log(`${name}: ${ok ? "PASS" : "FAIL"}  ${detail}`);
    }
    // The K4 numbers, formatted for the before/after table a latency change
    // must quote. Informational, not pass/fail: what "good" means is the
    // change under test.
    const fmt = (r) => (r ? `p50=${r.p50Ms ?? r.p50_ms}ms p95=${r.p95Ms ?? r.p95_ms}ms max=${r.maxMs ?? r.max_ms}ms n=${r.count}` : "no samples");
    const presented = e.status.presented;
    const injector = e.extra.helper?.injector;
    const replica = e.extra.replica;
    console.log("");
    console.log("K4 marker emit -> presented ack (remote clock): " + fmt(presented && { ...presented, p50Ms: presented.p50_ms, p95Ms: presented.p95_ms, maxMs: presented.max_ms }));
    console.log("K4 frame time-to-inject (helper clock):        " + fmt(injector?.timing?.frameTimeToInject));
    console.log("capture queue wait:                            " + fmt(replica?.timing?.captureQueueWait));
    console.log("capture duration:                              " + fmt(replica?.timing?.captureDuration));
    if (replica) {
      console.log(
        `captures: requested=${replica.capturesRequested ?? "-"} started=${replica.captures} ` +
          `completed=${replica.capturesCompleted ?? "-"} supersededBeforeStart=${replica.capturesSupersededBeforeStart ?? "-"} ` +
          `discarded=${replica.capturesDiscarded ?? "-"} served=${replica.surfacesServed}`
      );
    }
    if (injector) {
      console.log(`injector: accepted=${injector.accepted} superseded=${injector.superseded} injected=${injector.injectedTransactions}`);
    }
    const scale = e.sessions[0] ?? {};
    console.log(`moving scale: ${scale.scroll_scale ?? "none (device only)"} (${scale.scroll_scale_source ?? "-"}), settle ${scale.scroll_settle_ms ?? "-"}ms`);
    console.log("");
    console.log("evidence: " + JSON.stringify(e));
    process.exit(fails === 0 ? 0 : 1);
  });
'
result=$?

if [ "$result" -eq 0 ]; then
  say ""
  say "live-pipeline-check: PASS on $host"
  exit 0
fi
say ""
say "live-pipeline-check: FAIL on $host"
exit 1
