#!/bin/sh
# Put this working tree on the machine that runs Neovim, and install the
# renderer's locked dependencies there.
#
# For testing an unpushed branch. The normal route is a tag or a branch in the
# lazy.nvim spec, which every machine picks up from the shared config; this is
# for the window before a branch is pushed, or when the working tree has changes
# that are not committed yet.
#
#   scripts/rig/deploy.sh the LAN reference host [remote-path]
#
# Then point lazy.nvim at the deployed copy on that machine only:
#
#   dir = "~/md-viewer.nvim",
#
# and `:Lazy reload md-viewer.nvim`. Re-run this script after every local edit;
# it is rsync, so repeat runs move only what changed.
#
# Neovim 0.12+ and Node.js 22.12+ have to be on the machine running Neovim --
# over SSH that is the remote, not the laptop.
set -eu

HOST="${1:-}"
REMOTE_PATH="${2:-md-viewer.nvim}"

if [ -z "$HOST" ]; then
  echo "usage: scripts/rig/deploy.sh <ssh-host> [remote-path]" >&2
  exit 2
fi

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$REPO_ROOT"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
COMMIT=$(git rev-parse --short HEAD)
DIRTY=""
if [ -n "$(git status --porcelain)" ]; then DIRTY=" +uncommitted changes"; fi

echo "deploying $BRANCH ($COMMIT$DIRTY) -> $HOST:$REMOTE_PATH"

# node_modules is deliberately not copied: it is installed on the far side, so
# the platform's own binaries are the ones that end up there.
rsync -az --delete \
  --exclude 'node_modules' \
  --exclude 'tmp' \
  --exclude '.git' \
  --exclude '.DS_Store' \
  --exclude 'nvim.log' \
  ./ "$HOST:$REMOTE_PATH/"

echo "installing renderer dependencies on $HOST"
# --ignore-scripts and the skip variable keep this from downloading a browser:
# the plugin discovers an installed Chrome/Chromium rather than shipping one.
ssh "$HOST" "cd '$REMOTE_PATH/renderer' \
  && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts >/dev/null 2>&1 \
  && echo '  ok' || { echo '  npm ci FAILED -- run it by hand for the output' >&2; exit 1; }"

echo
echo "deployed. On $HOST, set this in the md-viewer lazy.nvim spec:"
echo
echo "    dir = \"~/$REMOTE_PATH\","
echo
echo "commenting out the version/branch line, then :Lazy reload md-viewer.nvim"
