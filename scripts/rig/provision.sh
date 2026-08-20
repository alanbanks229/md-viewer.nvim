#!/usr/bin/env bash
# Turn an SSH host into a reproduction rig for the *remote Neovim* mode.
#
# md-viewer has two remote shapes and they exercise different code. In
# `remote-projects/` Neovim runs on your own machine and only file contents
# cross the wire, so `terminal.detect().ssh` is false and the whole
# reuse-sent-pixels path stays off by design. This is the other one: **Neovim
# runs on the far end**, every rendered frame comes back through the SSH pty,
# and the resident-slice machinery is live. That is the shape defects get
# reported in, and until now reproducing one meant a second machine.
#
# What this buys is a single-machine loop. `ssh <host>` from the terminal you
# actually use, open the fixture, scroll. Same transport, same terminal
# detection, same backend as the machine the report came from.
#
# Everything here is idempotent: it reports what is already correct and installs
# only what is missing, so it is safe to re-run after any of it drifts.
#
#   scripts/rig/provision.sh                 # provision the default host
#   scripts/rig/provision.sh some-host       # provision another
#   scripts/rig/provision.sh --check         # report state, change nothing
#   scripts/rig/provision.sh --shape         # throttle egress to a slow link
#   scripts/rig/provision.sh --unshape       # give the link back
#
# ## Why these particular packages
#
# **Neovim from the release tarball, not from apt or snap.** Jammy ships 0.6 and
# md-viewer needs 0.12+; the nvim snap tracks a channel that lags and, per this
# host's own bash history, has already failed to install here once. The tarball
# is a fixed, inspectable version with no confinement and no FUSE dependency.
#
# **Google Chrome, deliberately not the Chromium snap.** A snap is confined, and
# Playwright launches a browser with a profile directory of its own choosing --
# which lands outside the paths the snap is allowed to read. `browser.js` passes
# `executablePath` straight through to `chromium.launch`, so a confined binary
# fails at launch rather than degrading. `renderer/src/browser-discovery.js`
# already looks for `google-chrome-stable` on PATH.
#
# ## The one thing that is load-bearing and silent
#
# Terminal detection has to survive the hop. SSH forwards `TERM` but not
# `TERM_PROGRAM`, so md-viewer identifies iTerm2 and WezTerm through `LC_TERMINAL`,
# which OpenSSH forwards only because sshd accepts `LC_*`. If that variable does
# not arrive, the profile falls back, `resident_pan` is not enabled for it, and
# the rig quietly exercises a *different code path* than the machine you are
# reproducing -- with nothing reporting a fault. The check at the end is there to
# make that impossible to miss, and it can only be answered from the terminal you
# will actually be testing in.
set -euo pipefail

HOST="${MD_VIEWER_RIG_HOST:-ichigo}"
NVIM_VERSION="${MD_VIEWER_RIG_NVIM:-v0.12.4}"
VAULT_REMOTE="${MD_VIEWER_RIG_VAULT:-git@github.com:alanbanks229/obsidian-vault.git}"
# The link `resident.lua`'s wire constants were tuned against -- see
# MAX_WIRE_SAMPLE_BYTES_PER_MS there, and the 0.80 MB/s figure its commentary
# cites. A LAN is not the link defects get reported over, and a timing-sensitive
# one will not reproduce at LAN speed.
SHAPE_RATE="${MD_VIEWER_RIG_RATE:-800kbit}"
SHAPE_DELAY="${MD_VIEWER_RIG_DELAY:-40ms}"

MODE="provision"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --shape) MODE="shape" ;;
    --unshape) MODE="unshape" ;;
    --nvim) NVIM_VERSION="$2"; shift ;;
    -h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) HOST="$1" ;;
  esac
  shift
done

# `-A` rather than relying on the host's ssh_config: the vault is private and is
# cloned with the agent on this machine. The repo's own ssh config sets
# ForwardAgent for the default host, but this script takes any host.
ssh_run() { ssh -A -o ConnectTimeout=10 "$HOST" "bash -s" ; }

say() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# Link shaping. Separate from provisioning because it is a thing you turn on for
# one measurement and off again, not part of the rig's resting state.
# ---------------------------------------------------------------------------
if [ "$MODE" = "shape" ] || [ "$MODE" = "unshape" ]; then
  say "$MODE $HOST"
  ssh -A -o ConnectTimeout=10 "$HOST" \
    "MODE='$MODE' RATE='$SHAPE_RATE' DELAY='$SHAPE_DELAY' bash -s" <<'REMOTE'
set -euo pipefail
iface=$(ip -o -4 route show default | awk '{print $5; exit}')
[ -n "$iface" ] || { echo "no default route to shape" >&2; exit 1; }
# Removing first makes both directions idempotent: shaping twice replaces rather
# than stacking two qdiscs, and unshaping a clean interface is not an error.
sudo tc qdisc del dev "$iface" root 2>/dev/null || true
if [ "$MODE" = "shape" ]; then
  sudo tc qdisc add dev "$iface" root netem rate "$RATE" delay "$DELAY"
  echo "$iface shaped to $RATE with $DELAY delay"
  echo "NOTE: this throttles everything leaving the host, including this ssh session."
else
  echo "$iface unshaped"
fi
tc qdisc show dev "$iface"
REMOTE
  exit 0
fi

# ---------------------------------------------------------------------------
# Provision, or report.
# ---------------------------------------------------------------------------
say "$MODE $HOST"
ssh -A -o ConnectTimeout=10 "$HOST" \
  "MODE='$MODE' NVIM_VERSION='$NVIM_VERSION' VAULT_REMOTE='$VAULT_REMOTE' bash -s" <<'REMOTE'
set -euo pipefail

CHECK_ONLY=false
[ "$MODE" = "check" ] && CHECK_ONLY=true

ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; }
todo() { printf '  \033[33mtodo\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mfail\033[0m  %s\n' "$1"; }
step() { printf '\n\033[1m-- %s\033[0m\n' "$1"; }

# A "would install" in check mode is not a failure, so the two are tracked apart:
# --check has to be able to report an unprovisioned host without looking broken.
MISSING=0
want() { MISSING=$((MISSING + 1)); todo "$1"; $CHECK_ONLY && return 1; return 0; }

# Neovim ---------------------------------------------------------------------
step "Neovim (needs 0.12+)"
have_nvim=$(nvim --version 2>/dev/null | head -1 || true)
nvim_major_minor=$(printf '%s' "$have_nvim" | sed -n 's/^NVIM v\([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
nvim_ok=false
if [ -n "$nvim_major_minor" ]; then
  set -- $nvim_major_minor
  { [ "$1" -gt 0 ] || [ "$2" -ge 12 ]; } && nvim_ok=true
fi
if $nvim_ok; then
  ok "$have_nvim"
elif want "install Neovim $NVIM_VERSION from the release tarball"; then
  arch=$(dpkg --print-architecture)
  case "$arch" in
    amd64) asset="nvim-linux-x86_64" ;;
    arm64) asset="nvim-linux-arm64" ;;
    *) bad "no Neovim tarball for $arch"; exit 1 ;;
  esac
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/nvim.tar.gz" \
    "https://github.com/neovim/neovim/releases/download/$NVIM_VERSION/$asset.tar.gz"
  sudo rm -rf "/opt/$asset"
  sudo tar -C /opt -xzf "$tmp/nvim.tar.gz"
  # Versioned directory, unversioned symlink: re-running with a different
  # --nvim replaces the link rather than leaving two Neovims on PATH.
  sudo ln -sfn "/opt/$asset/bin/nvim" /usr/local/bin/nvim
  rm -rf "$tmp"
  ok "$(nvim --version | head -1)"
fi

# Node -----------------------------------------------------------------------
step "Node.js (needs 22.12+)"
node_version=$(node --version 2>/dev/null || true)
node_ok=false
if [ -n "$node_version" ]; then
  major=${node_version#v}; major=${major%%.*}
  minor=${node_version#v*.}; minor=${minor%%.*}
  { [ "$major" -gt 22 ] || { [ "$major" -eq 22 ] && [ "$minor" -ge 12 ]; }; } && node_ok=true
fi
if $node_ok; then
  ok "node $node_version, npm $(npm --version 2>/dev/null || echo '?')"
elif want "install Node 22.x from NodeSource"; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null
  sudo apt-get install -y nodejs >/dev/null
  ok "node $(node --version), npm $(npm --version)"
fi

# Browser --------------------------------------------------------------------
step "Chrome (Playwright drives this, not a snap)"
chrome=$(command -v google-chrome-stable || command -v google-chrome || true)
if [ -n "$chrome" ]; then
  ok "$chrome -- $("$chrome" --version 2>/dev/null || echo 'version unavailable')"
elif want "install google-chrome-stable from Google's apt repo"; then
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | sudo gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
    | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y google-chrome-stable >/dev/null
  ok "$(command -v google-chrome-stable) -- $(google-chrome-stable --version)"
fi

# The vault's Neovim config --------------------------------------------------
step "Neovim config (the vault, symlinked exactly as on the Mac)"
vault="$HOME/obsidian-vault"
if [ -d "$vault/.git" ]; then
  ok "vault at $vault ($(git -C "$vault" rev-parse --short HEAD))"
elif want "clone the vault (uses your forwarded ssh agent)"; then
  git clone --quiet "$VAULT_REMOTE" "$vault"
  ok "vault at $vault ($(git -C "$vault" rev-parse --short HEAD))"
fi
link_target="$vault/Neovim/.config/nvim"
if [ "$(readlink -f "$HOME/.config/nvim" 2>/dev/null)" = "$(readlink -f "$link_target" 2>/dev/null)" ] \
  && [ -n "$(readlink "$HOME/.config/nvim" 2>/dev/null)" ]; then
  ok "~/.config/nvim -> $link_target"
elif [ -e "$HOME/.config/nvim" ] && [ ! -L "$HOME/.config/nvim" ]; then
  # Never clobber a real config directory. Someone put it there on purpose and
  # this script has no way to know it was not wanted.
  bad "~/.config/nvim exists and is not a symlink -- move it aside by hand"
elif want "symlink ~/.config/nvim at the vault's config"; then
  mkdir -p "$HOME/.config"
  ln -sfn "$link_target" "$HOME/.config/nvim"
  ok "~/.config/nvim -> $link_target"
fi

# The fixture ----------------------------------------------------------------
#
# Generated rather than committed so every repro starts from byte-identical
# content: "scroll to the end and watch the caret" is only a shared observation
# if the document is the same one. Several viewports of mixed content, because a
# caret has to land on real glyphs and a document of one heading has nowhere for
# it to go.
step "Scroll fixture"
fixture="$HOME/mdv-rig/scroll-test.md"
if [ -f "$fixture" ]; then
  ok "$fixture ($(wc -l < "$fixture") lines)"
elif want "generate $fixture"; then
  mkdir -p "$(dirname "$fixture")"
  {
    echo "# Scroll fixture"
    echo
    echo "Generated by \`scripts/rig/provision.sh\`. Several viewports of mixed"
    echo "content, so a caret always has a real glyph to land on."
    echo
    for section in $(seq 1 24); do
      echo "## Section $section"
      echo
      echo "Ordinary paragraph text for section $section, long enough to wrap at any"
      echo "reasonable preview width and give the caret somewhere to travel across."
      echo
      echo "- first item in section $section"
      echo "- second item, with \`inline code\` in it"
      echo "- third item"
      echo
      echo '```lua'
      echo "local section = $section"
      echo "return section * 2"
      echo '```'
      echo
      echo "> A blockquote closing section $section."
      echo
    done
  } > "$fixture"
  ok "$fixture ($(wc -l < "$fixture") lines)"
fi

# Terminal detection ---------------------------------------------------------
step "Terminal detection across the hop"
if grep -qiE '^[[:space:]]*AcceptEnv.*LC_\*' /etc/ssh/sshd_config; then
  ok "sshd accepts LC_* (so LC_TERMINAL can arrive)"
else
  bad "sshd does not accept LC_* -- add 'AcceptEnv LANG LC_*' to /etc/ssh/sshd_config"
fi
if [ -n "${LC_TERMINAL:-}" ]; then
  ok "LC_TERMINAL=$LC_TERMINAL arrived on this connection"
else
  # Not a failure of the host. This script is usually run from a scripted shell,
  # which is not the terminal that will do the testing.
  todo "LC_TERMINAL is unset on *this* connection -- run 'echo \$LC_TERMINAL' from
        the iTerm2/WezTerm window you will test in. Empty there means md-viewer
        will misidentify the terminal and reusing sent pixels will stay off."
fi

step "Summary"
if [ "$MISSING" -eq 0 ]; then
  ok "rig is ready"
elif $CHECK_ONLY; then
  todo "$MISSING item(s) not provisioned -- re-run without --check to install"
else
  ok "provisioned $MISSING item(s)"
fi
REMOTE

say "Next"
cat <<EOF
  ssh $HOST                       # from the terminal you are reproducing in
  nvim ~/mdv-rig/scroll-test.md
  :Lazy sync                      # first run also builds the renderer's deps
  <leader>mp                      # open the preview
  <leader>md                      # :MdViewerDebug, if something looks wrong

  scripts/rig/provision.sh $HOST --shape     # then again over a slow link
  scripts/rig/provision.sh $HOST --unshape
EOF
