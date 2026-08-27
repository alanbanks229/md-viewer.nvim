#!/bin/sh
# Move both ends of a local-render deployment to one release tag.
#
#   sh scripts/local/ssm-rc-update.sh <ssh-host> <tag> [--no-remote]
#
# Run it on the laptop, from inside the helper checkout it should update.
# It checks that checkout out at <tag>, reinstalls the renderer's locked
# dependencies, and then -- unless --no-remote -- runs the plugin manager's
# headless update on the VM and verifies the installed plugin reports the
# same tag. Both ends on one tag is the invariant the socket hello enforces
# at attach time; this script is how an operator gets there in one command
# instead of a page of remembered steps.
#
# What it deliberately does NOT do:
#   * touch your Neovim configuration. The VM's config must already pin
#     `version = "<tag>"` (however that config is synced to the VM); if it
#     still pins the old tag, the remote verification below fails and names
#     exactly that.
#   * run with uncommitted changes in this checkout. A development tree is
#     not an operator deployment; commit or stash first, or use a dedicated
#     clone (~/md-viewer-local in docs/aws-ssm.md).
#   * store or forward any credential. The ssh alias's own config does the
#     authenticating.
set -eu

usage() { echo "usage: ssm-rc-update.sh <ssh-host> <tag> [--no-remote]" >&2; exit 2; }

host=${1:-}; tag=${2:-}
[ -n "$host" ] && [ -n "$tag" ] || usage
remote=1
[ "${3:-}" = "--no-remote" ] && remote=0

here=$(cd "$(dirname "$0")/../.." && pwd)
cd "$here"

say() { printf '%s\n' "$*"; }
fail() { printf 'ssm-rc-update: %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || fail "git is required"
command -v node >/dev/null 2>&1 || fail "node is required"

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  fail "this checkout has uncommitted changes; commit/stash them, or update a dedicated clone instead"
fi

say "== laptop helper: $here -> $tag"
git fetch --tags origin
git -c advice.detachedHead=false checkout "$tag"
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer >/dev/null
helper_version=$(node renderer/src/local-main.js --version)
say "helper --version: $helper_version"
short_tag=${tag#v}
case $helper_version in
  *"v$short_tag "*|*"v$short_tag") : ;;
  *) fail "helper reports '$helper_version', not $tag -- the checkout and the version metadata disagree" ;;
esac

if [ "$remote" = 0 ]; then
  say "== remote: skipped (--no-remote)"
  say "done. Remember the VM plugin must be on $tag before validating."
  exit 0
fi

say "== VM plugin on $host: headless update"
# `Lazy! update <plugin>` waits for completion headlessly and touches only
# this plugin. The version actually installed is read back from the plugin
# tree afterwards -- the update having run is not the same as the pin having
# moved.
ssh -o BatchMode=yes "$host" 'nvim --headless "+Lazy! update md-viewer.nvim" +qa' >/dev/null 2>&1 \
  || say "note: headless ':Lazy update' did not run cleanly; verifying what is installed anyway"

plugin_dir=""
for candidate in ".local/share/nvim/lazy/md-viewer.nvim" "md-viewer.nvim"; do
  if ssh -o BatchMode=yes "$host" test -f "$candidate/lua/md-viewer/init.lua" 2>/dev/null; then
    plugin_dir=$candidate
    break
  fi
done
[ -n "$plugin_dir" ] || fail "no md-viewer plugin found on $host (looked in ~/.local/share/nvim/lazy and ~/md-viewer.nvim)"

installed=$(ssh -o BatchMode=yes "$host" "sed -n 's/.*version = \"\\([^\"]*\\)\".*/\\1/p' $plugin_dir/lua/md-viewer/init.lua" | head -1)
say "VM plugin version: ${installed:-unknown} (~/$plugin_dir)"
if [ "v$installed" != "$tag" ] && [ "$installed" != "$tag" ]; then
  fail "the VM still runs '$installed', wanted $tag. Its Neovim config pins the version -- update the pin (and sync the config to the VM) first, then re-run this script."
fi

say ""
say "done: laptop helper and VM plugin are both on $tag."
say "next: sh scripts/local/ssm-validate.sh $host $tag"
