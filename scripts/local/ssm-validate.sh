#!/bin/sh
# The one-command RC validation for the SSM reference environment.
#
#   sh scripts/local/ssm-validate.sh <ssh-host> [expected-tag]
#
# Run it on the laptop, from the helper checkout, against the host alias the
# operator already sshes with. It runs every leg a machine can run -- version
# agreement on both ends, K1 topology, K2 marker transit, the K4 live
# pipeline with its held-key burst and stage timings, the link measurement,
# the zero-raster invariant -- and writes one Markdown artifact under
# artifacts/ that is the thing to hand back for a verdict. The two checks a
# machine cannot run (how scrolling feels, whether the resting frame
# sharpens) are printed at the end for the human, and they are the only
# manual steps left.
#
# The artifact stays on this machine: artifacts/ is gitignored because a
# validation record names private host aliases and belongs to the operator,
# not to the public repository.
#
# Needs: tmux, promptless key auth to the host, node >= 22.12, a system
# Chrome/Chromium/Edge, and both ends already on the RC under test
# (scripts/local/ssm-rc-update.sh does that part).
set -u

host=${1:-}
[ -n "$host" ] || { echo "usage: ssm-validate.sh <ssh-host> [expected-tag]" >&2; exit 2; }
expected=${2:-}

here=$(cd "$(dirname "$0")/../.." && pwd)
cd "$here"
say() { printf '%s\n' "$*"; }

fails=0
summary=""
check() { # name pass|fail|info detail
  status=$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')
  [ "$2" = fail ] && fails=$((fails + 1))
  summary="${summary}| $1 | $status | $3 |
"
  say "  $1: $status  $3"
}

command -v tmux >/dev/null 2>&1 || { say "tmux is required"; exit 2; }
command -v node >/dev/null 2>&1 || { say "node is required"; exit 2; }

# ---------------------------------------------------------------------------
say "== preflight"

node_version=$(node --version)
helper_version=$(node renderer/src/local-main.js --version 2>/dev/null || echo "unknown")
# `--version` prints "md-viewer-local vX.Y.Z (commit)"; the tag is the vX
# token, and an explicit second argument overrides it.
tag=${expected:-$(printf '%s' "$helper_version" | grep -o 'v[0-9][^ ]*' | head -1)}
[ -n "$tag" ] || tag="unknown"
browser=$(node -e '
  import("./renderer/src/browser-discovery.js").then(({ discoverChromium }) =>
    import("node:fs").then(({ existsSync }) => {
      try { console.log(discoverChromium(process.platform, process.env, existsSync, {}).executable); }
      catch (e) { console.log("NONE: " + e.message); process.exitCode = 1; }
    }));' 2>/dev/null)

check "node >= 22.12" "$(node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.stdout.write(a>22||(a===22&&b>=12)?"pass":"fail")')" "$node_version"
case $browser in NONE*|"") check "system browser" fail "${browser:-discovery failed}" ;; *) check "system browser" pass "$browser" ;; esac
case $helper_version in *"$tag"*) check "helper on $tag" pass "$helper_version" ;; *) check "helper on $tag" fail "$helper_version" ;; esac

# Prefer whichever install actually carries the tag under test: a host can
# hold both a plugin-manager install and a synced checkout (the rig hosts
# do), and validating the wrong one produces confidently wrong answers.
plugin_dir=""
vm_version=""
for candidate in ".local/share/nvim/lazy/md-viewer.nvim" "md-viewer.nvim"; do
  v=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$host" \
    "sed -n 's/.*version = \"\\([^\"]*\\)\".*/\\1/p' $candidate/lua/md-viewer/init.lua 2>/dev/null" | head -1)
  [ -n "$v" ] || continue
  if [ -z "$plugin_dir" ]; then plugin_dir=$candidate; vm_version=$v; fi
  if [ "v$v" = "$tag" ]; then plugin_dir=$candidate; vm_version=$v; break; fi
done
if [ -z "$plugin_dir" ]; then
  check "VM plugin found" fail "no md-viewer under ~/.local/share/nvim/lazy or ~/md-viewer.nvim on $host"
  say "cannot continue without the VM plugin"; exit 1
fi
vm_facts=$(ssh -o BatchMode=yes "$host" 'uname -sr; nvim --version | head -1; node --version' 2>/dev/null | tr '\n' ' ')
if [ "v$vm_version" = "$tag" ] || [ "$vm_version" = "$tag" ]; then
  check "VM plugin on $tag" pass "~/$plugin_dir"
else
  check "VM plugin on $tag" fail "VM has '$vm_version' -- run scripts/local/ssm-rc-update.sh $host $tag"
fi

# ---------------------------------------------------------------------------
say "== K1 topology"
k1_out=$(sh scripts/local/topology-check.sh "$host" 2>&1)
k1_code=$?
[ "$k1_code" -eq 0 ] && check "K1 topology" pass "wrapped ssh holds raw mode, resize, ~., nvim" \
  || check "K1 topology" fail "see K1 section of the artifact"

# ---------------------------------------------------------------------------
say "== K2 marker transit (10,000 markers)"
k2_token=$(node -e 'console.log(require("node:crypto").randomBytes(16).toString("hex"))')
k2_session="mdv-k2-$$"
tmux new-session -d -s "$k2_session" -x 120 -y 35 \
  "sh -c 'MD_VIEWER_ECHO_TOKEN=$k2_token node \"$here/renderer/src/local-main.js\" --marker-echo-test -- ssh -o BatchMode=yes \"$host\"; echo HELPER-EXIT=\$?; sleep 90'"
k2_line=""
i=0
while [ "$i" -lt 100 ]; do
  if tmux capture-pane -p -t "$k2_session" 2>/dev/null | grep -q '\$\|%\|#\|>'; then break; fi
  sleep 0.2; i=$((i + 1))
done
tmux send-keys -t "$k2_session" -l "sh ~/$plugin_dir/scripts/local/marker-echo-emit.sh $k2_token 10000; exit"
tmux send-keys -t "$k2_session" Enter
i=0
while [ "$i" -lt 240 ]; do
  k2_line=$(tmux capture-pane -p -t "$k2_session" 2>/dev/null | grep -o 'marker-echo: received=.*' | tail -1)
  [ -n "$k2_line" ] && break
  sleep 1; i=$((i + 1))
done
tmux kill-session -t "$k2_session" 2>/dev/null
if printf '%s' "$k2_line" | grep -q 'received=10000 .*missing=0 out-of-order=0 malformed=0'; then
  check "K2 marker transit" pass "$k2_line"
else
  check "K2 marker transit" fail "${k2_line:-no tally within 4 minutes}"
fi

# ---------------------------------------------------------------------------
say "== K4 live pipeline (attach, render, burst, timings)"
k4_out=$(sh scripts/local/live-pipeline-check.sh "$host" "$plugin_dir" 2>&1)
k4_code=$?
k4_report=$(printf '%s\n' "$k4_out" | grep -v '^evidence:')
k4_evidence=$(printf '%s\n' "$k4_out" | grep '^evidence:' | sed 's/^evidence: //')
[ "$k4_code" -eq 0 ] && check "K4 live pipeline" pass "$(printf '%s\n' "$k4_report" | grep 'presented ack' | head -1 | sed 's/^K4 //')" \
  || check "K4 live pipeline" fail "see K4 section of the artifact"

raster=$(printf '%s' "$k4_evidence" | node -e '
  let s=""; process.stdin.on("data",c=>s+=c); process.stdin.on("end",()=>{
    try {
      const e = JSON.parse(s);
      const p = e.extra.helper?.parser ?? {};
      const fallbacks = e.markers?.direct_bytes_fallbacks;
      console.log(`remoteRasterBytes=${p.remoteRasterBytes} remoteMdvRasterBytes=${p.remoteMdvRasterBytes} directByteFallbacks=${fallbacks}`);
      process.exitCode = (p.remoteRasterBytes === 0 && fallbacks === 0) ? 0 : 1;
    } catch { console.log("evidence unreadable"); process.exitCode = 1; }
  });' 2>/dev/null)
[ $? -eq 0 ] && check "zero raster over the link" pass "$raster" || check "zero raster over the link" fail "$raster"

# ---------------------------------------------------------------------------
say "== link measurement (one sample; the screen noise stays in the pipe)"
link_line=""
if ssh -tt -o BatchMode=yes "$host" "sh ~/$plugin_dir/scripts/ssh-link-speed.sh --quiet --samples 1 --out /tmp/mdv-validate-link.txt" >/dev/null 2>&1; then
  link_line=$(ssh -o BatchMode=yes "$host" "grep bytes_per_sec /tmp/mdv-validate-link.txt; rm -f /tmp/mdv-validate-link.txt" 2>/dev/null | head -1)
fi
[ -n "$link_line" ] && check "link measured" info "$link_line" || check "link measured" info "measurement did not run (not fatal)"

status_out=$(node renderer/src/local-main.js --status 2>&1)

# ---------------------------------------------------------------------------
verdict="PASS"; [ "$fails" -gt 0 ] && verdict="FAIL ($fails)"
stamp=$(date +%Y-%m-%d)
mkdir -p artifacts
artifact="artifacts/ssm-validation-$tag-$stamp.md"
n=2
while [ -e "$artifact" ]; do artifact="artifacts/ssm-validation-$tag-$stamp-$n.md"; n=$((n + 1)); done

{
  echo "# SSM validation -- $tag -- $stamp"
  echo
  echo "Automated verdict: **$verdict**"
  echo
  echo "| leg | result | detail |"
  echo "| --- | --- | --- |"
  printf '%s' "$summary"
  echo
  echo "## Environment"
  echo
  echo '```'
  echo "host alias:        $host"
  echo "laptop:            $(uname -sr), terminal ${TERM_PROGRAM:-${LC_TERMINAL:-$TERM}} ${TERM_PROGRAM_VERSION:-}"
  echo "laptop node:       $node_version"
  echo "helper:            $helper_version"
  echo "browser:           $browser"
  echo "VM:                $vm_facts"
  echo "VM plugin:         $vm_version at ~/$plugin_dir"
  echo '```'
  echo
  echo "## K1 topology"
  echo
  echo '```'
  printf '%s\n' "$k1_out"
  echo '```'
  echo
  echo "## K2 marker transit"
  echo
  echo '```'
  printf '%s\n' "${k2_line:-no tally}"
  echo '```'
  echo
  echo "## K4 live pipeline and timings"
  echo
  echo '```'
  printf '%s\n' "$k4_report"
  echo '```'
  echo
  echo "## Helper --status at validation time"
  echo
  echo '```'
  printf '%s\n' "$status_out"
  echo '```'
  echo
  echo "## Raw K4 evidence"
  echo
  echo '```json'
  printf '%s\n' "$k4_evidence"
  echo '```'
  echo
  echo "## Human feel check (fill in)"
  echo
  echo "1. Hold \`j\` in a preview for several seconds:  smooth / slightly laggy but acceptable / unacceptably laggy"
  echo "2. Stop moving. Did the frame sharpen back to full quality within ~half a second?  yes / no"
  echo
  echo "Notes:"
} > "$artifact"

say ""
say "AUTOMATED VALIDATION: $verdict"
say ""
say "Human check (the only manual part):"
say "  1. In your own terminal: node $here/renderer/src/local-main.js -- ssh $host"
say "     then on the VM open a markdown file with the preview on, and hold j for a few seconds."
say "     Judge: smooth / slightly laggy but acceptable / unacceptably laggy."
say "  2. Stop moving. Confirm the frame sharpens back to full quality."
say "  Write both answers into the artifact's last section."
say ""
say "RESULT FILE:"
say "  $here/$artifact"
[ "$fails" -eq 0 ] && exit 0 || exit 1
