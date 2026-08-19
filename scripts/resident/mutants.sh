#!/usr/bin/env bash
# Does the suite actually catch the defects this feature has already shipped?
#
# A regression test only earns the name if it fails when the defect is present,
# and the only way to know is to put the defect back. Every mutation below is a
# real bug that reached a real session -- reintroduced verbatim, one at a time,
# with the suite run against each.
#
# CAUGHT means the suite failed, which is the result wanted. MISSED means the
# defect can be reintroduced with every test still green, and is a gap in
# coverage rather than a passing grade.
#
# Runs the Lua suite only. The Node suite covers the renderer in isolation and
# none of these mutations are expressible there.
#
#   ./scripts/resident/mutants.sh [name-filter]
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"
filter="${1:-}"

# name | file | search | replace
#
# Tab-separated so the patterns may contain anything but a tab. Each must be a
# unique substring of the file, or the mutation is skipped rather than applied
# somewhere unintended -- a mutation that lands in the wrong place would report
# a coverage result about code nobody was asking about.
#
# Written to a file rather than captured in `$(...)`: bash cannot parse a
# heredoc containing unbalanced parentheses inside a command substitution, and
# several of these patterns are fragments of Lua expressions.
mutations="$(mktemp)"
trap 'rm -f "$mutations"' EXIT
cat >"$mutations" <<'MUTATIONS'
caret-shadow-on-pan	lua/md-viewer/controller.lua	  caret.shadow_cursor(session)\n  animation.repaint(session)	  animation.repaint(session)
capture-scale-from-moving-frame	lua/md-viewer/controller.lua	session.device_image_width_px and session.viewport_width_px)\n        and (session.device_image_width_px	session.image_width_px and session.viewport_width_px)\n        and (session.image_width_px
pointer-table-not-press-pan	lua/md-viewer/controller.lua	  if session.pointer and session.pointer.pressed then return false end	  if session.pointer then return false end
pointer-table-not-press-fill	lua/md-viewer/controller.lua	(session.pointer and session.pointer.pressed) then\n    return plain	session.pointer then\n    return plain
byte-cap-fights-budget	lua/md-viewer/controller.lua	local REGION_PNG_CAP_FRAMES = 6	local REGION_PNG_CAP_FRAMES = 3
late-capture-overwrites-pan	lua/md-viewer/controller.lua	    if not filling and (session.pan_serial or 0) ~= pan_at then	    if false then
fill-rewinds-the-reader	lua/md-viewer/controller.lua	    if not (newer_scroll_pending or filling) then session.scroll_y = meta.scrollY end	    if not newer_scroll_pending then session.scroll_y = meta.scrollY end
fill-claims-applied-scroll	lua/md-viewer/controller.lua	    if not filling then session.applied_scroll_y = meta.scrollY end	    session.applied_scroll_y = meta.scrollY
region-freed-as-side-effect	lua/md-viewer/controller.lua	        retain_superseded = resident_holds(session.resident, session.image_id),	        retain_superseded = false,
occlusion-frees-instead-of-hides	lua/md-viewer/controller.lua	    local hide = resident_holds(session.resident, session.image_id) and session.backend.hide	    local hide = nil
dead-page-never-rebuilt	renderer/src/browser.js	    if (this.context && this.page && !this.page.isClosed() && this.deviceScaleFactor === scale) return;	    if (this.context && this.deviceScaleFactor === scale) return;
sheet-sized-by-base-image	lua/md-viewer/backends/kitty_raw.lua	  local width, height = 0, 0\n  if cell and placement and placement.width and placement.height then\n    width = math.ceil(placement.width * cell.width)\n    height = math.ceil(placement.height * cell.height)	  local width, height = item.width_px, item.height_px\n  if cell and placement and placement.width and placement.height then\n    width = math.max(width, math.ceil(placement.width * cell.width))\n    height = math.max(height, math.ceil(placement.height * cell.height))
MUTATIONS

caught=0; missed=0; skipped=0
declare -a missed_names=()

restore_all() {
  git checkout -- lua/md-viewer/controller.lua lua/md-viewer/backends/kitty_raw.lua renderer/src/browser.js 2>/dev/null || true
}
trap 'restore_all; rm -f "$mutations"' EXIT

if ! git diff --quiet -- lua/md-viewer/controller.lua lua/md-viewer/backends/kitty_raw.lua renderer/src/browser.js; then
  echo "refusing to run: the files this mutates have uncommitted changes" >&2
  echo "commit or stash them first -- restoring would throw them away" >&2
  exit 2
fi

printf '%-34s %s\n' "MUTATION" "RESULT"
printf '%-34s %s\n' "--------" "------"

while IFS=$'\t' read -r name file search replace; do
  [ -n "$name" ] || continue
  [ -z "$filter" ] || [[ "$name" == *"$filter"* ]] || continue

  if ! python3 - "$file" "$search" "$replace" <<'PY'
import sys
path, search, replace = sys.argv[1], sys.argv[2].replace("\\n", "\n"), sys.argv[3].replace("\\n", "\n")
body = open(path).read()
if body.count(search) != 1:
    sys.exit(3)
open(path, "w").write(body.replace(search, replace, 1))
PY
  then
    printf '%-34s %s\n' "$name" "SKIPPED (pattern not unique)"
    skipped=$((skipped + 1))
    restore_all
    continue
  fi

  # Whichever suite covers the mutated file. A renderer defect is invisible to
  # the Lua suite by construction -- it cannot crash a Chromium page -- so
  # scoring one against it would report a coverage gap that is really a
  # misdirected question.
  if [ "$file" = "renderer/src/browser.js" ]; then
    suite=(node --test tests/node/region-capture.test.js)
  else
    suite=(env NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua)
  fi

  if "${suite[@]}" >/dev/null 2>&1; then
    printf '%-34s %s\n' "$name" "MISSED  <-- suite stayed green"
    missed=$((missed + 1))
    missed_names+=("$name")
  else
    printf '%-34s %s\n' "$name" "caught"
    caught=$((caught + 1))
  fi
  restore_all
done <"$mutations"

echo
echo "$caught caught, $missed missed, $skipped skipped"
if [ "$missed" -gt 0 ]; then
  echo
  echo "Uncovered. Each of these is a defect that reached a real session and can be"
  echo "reintroduced today without a single test noticing:"
  for name in "${missed_names[@]}"; do echo "  - $name"; done
  exit 1
fi
