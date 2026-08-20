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
capture-scale-from-moving-frame	lua/md-viewer/controller.lua	session.device_image_width_px and session.viewport_width_px)\n      and (session.device_image_width_px	session.image_width_px and session.viewport_width_px)\n      and (session.image_width_px
pointer-table-not-press-pan	lua/md-viewer/controller.lua	  if session.pointer and session.pointer.pressed then return false end	  if session.pointer then return false end
pointer-table-not-press-fill	lua/md-viewer/controller.lua	(session.pointer and session.pointer.pressed) then\n    return plain	session.pointer then\n    return plain
late-capture-overwrites-pan	lua/md-viewer/controller.lua	    if not filling and (session.pan_serial or 0) ~= pan_at then	    if false then
fill-rewinds-the-reader	lua/md-viewer/controller.lua	    if not (newer_scroll_pending or filling) then session.scroll_y = meta.scrollY end	    if not newer_scroll_pending then session.scroll_y = meta.scrollY end
fill-claims-applied-scroll	lua/md-viewer/controller.lua	    if not filling then session.applied_scroll_y = meta.scrollY end	    session.applied_scroll_y = meta.scrollY
region-freed-as-side-effect	lua/md-viewer/controller.lua	        retain_superseded = resident_holds(session.resident, session.image_id),	        retain_superseded = false,
occlusion-frees-instead-of-hides	lua/md-viewer/controller.lua	        local hide = gone.retain and session.backend.hide	        local hide = nil
dead-page-never-rebuilt	renderer/src/browser.js	    if (this.context && this.page && !this.page.isClosed() && this.deviceScaleFactor === scale) return;	    if (this.context && this.deviceScaleFactor === scale) return;
slices-without-row-overlap	lua/md-viewer/resident.lua	  local overlap_img = math.max(1, math.ceil(OVERLAP_ROWS * row_h * scale))	  local overlap_img = 1
decoded-bytes-assumes-four	lua/md-viewer/resident.lua	local BYTES_PER_RESIDENT_PX = 13	local BYTES_PER_RESIDENT_PX = 4
invalidate-only-when-scrolled	lua/md-viewer/controller.lua	    if not filling and session.resident and session.resident.key then	    if false and session.resident and session.resident.key then
invalidate-during-a-fill	lua/md-viewer/controller.lua	    if not filling and session.resident and session.resident.key then	    if session.resident and session.resident.key then
stale-part-list-trusted	lua/md-viewer/controller.lua	  if parts and parts[1] and parts[1].image_id == session.image_id then return parts end	  if parts and #parts > 0 then return parts end
compose-ignores-refused-band	lua/md-viewer/backends/kitty_raw.lua	    if refused > 0 or #ids == 0 then	    if false then
compose-splits-the-write	lua/md-viewer/backends/kitty_raw.lua	  if payload ~= "" then send(payload) end\n\n  local placed = 0	  if addition ~= "" then send(addition) end\n  if removal ~= "" then send(removal) end\n\n  local placed = 0
sheet-sized-by-base-image	lua/md-viewer/backends/kitty_raw.lua	  local width, height = 0, 0\n  if cell and placement and placement.width and placement.height then\n    width = math.ceil(placement.width * cell.width)\n    height = math.ceil(placement.height * cell.height)	  local width, height = item.width_px, item.height_px\n  if cell and placement and placement.width and placement.height then\n    width = math.max(width, math.ceil(placement.width * cell.width))\n    height = math.max(height, math.ceil(placement.height * cell.height))
fill-anchored-on-the-reader	lua/md-viewer/controller.lua	    capture_region = { yPx = slice.doc_y, heightPx = slice.doc_h },	    capture_region = { yPx = session.scroll_y, heightPx = slice.doc_h },
grid-outlives-the-document	lua/md-viewer/resident.lua	  state.grid = nil\n  state.generation = (state.generation or 0) + 1	  state.generation = (state.generation or 0) + 1
slice-shrink-without-regrid	lua/md-viewer/controller.lua	      resident_invalidate(session, resident_key(session))\n      local retry = settle_options(session)	      local retry = settle_options(session)
evicted-slice-not-freed	lua/md-viewer/resident.lua	    state.evictions = state.evictions + 1\n    evicted[#evicted + 1] = gone	    state.evictions = state.evictions + 1
window-keeps-the-farthest	lua/md-viewer/resident.lua	        if distance > worst_distance or (distance == worst_distance and index < worst) then	        if worst == nil or distance < worst_distance then
composite-emits-only-the-top-band	lua/md-viewer/controller.lua	    { image_id = lower.image_id, placement = band_placement(placement, split, rows - split), source = bands.lower },	
seam-without-row-quantisation	lua/md-viewer/resident.lua	  local split = math.ceil((lower.doc_y - scroll_y) / row_h - EPS)	  local split = (lower.doc_y - scroll_y) / row_h
bands-snapped-independently	lua/md-viewer/resident.lua	  local lower_top = round((seam - lower.doc_y) * lower.scale_y)	  local lower_top = round(seam * lower.scale_y) - round(lower.doc_y * lower.scale_y) + 1
reconcile-moves-one-band	lua/md-viewer/controller.lua	    if #screen_parts(session) > 1 then	    if false then
ab-reads-the-region-cache	scripts/resident/ab.lua	  local slices = resident.slice_records(live)	  local slices = live.regions
prefetch-ignores-the-ceiling	lua/md-viewer/controller.lua	  if not resident.has_room(live, resident.slice_cost_px(grid)) then return end	
prefetch-outranks-the-reader	lua/md-viewer/controller.lua	  if not (resident.hold(live, first) and resident.hold(live, last)) then return end	
prefetch-queues-behind-a-drain	lua/md-viewer/controller.lua	  if (live.upload_hold_until or 0) > vim.uv.now() then return end	
prefetch-is-drawn-over-the-reader	lua/md-viewer/controller.lua	      local prefetching = live.fill.prefetch == true	      local prefetching = false
wire-estimate-without-a-ceiling	lua/md-viewer/resident.lua	  if sample > MAX_WIRE_SAMPLE_BYTES_PER_MS then\n    state.wire_samples_discarded = (state.wire_samples_discarded or 0) + 1\n    return\n  end	
inferred-link-rate-outranks-stated	lua/md-viewer/resident.lua	  local configured = positive(configured_bytes_per_sec)\n  if configured then return configured / 1000, "configured" end\n  local estimated = positive(estimated_bytes_per_ms)\n  if estimated then return estimated, "estimated" end	  local estimated = positive(estimated_bytes_per_ms)\n  if estimated then return estimated, "estimated" end\n  local configured = positive(configured_bytes_per_sec)\n  if configured then return configured / 1000, "configured" end
stated-link-rate-never-consulted	lua/md-viewer/controller.lua	  local rate = resident.link_rate(render.ssh_link_bytes_per_sec, live.wire_bytes_per_ms)	  local rate = resident.link_rate(nil, live.wire_bytes_per_ms)
dropped-slices-not-counted	lua/md-viewer/resident.lua	  state.dropped_slices = (state.dropped_slices or 0) + #slices	
undisplayed-fill-not-counted	lua/md-viewer/controller.lua	          live.undisplayed_fills = live.undisplayed_fills + 1	
debug-report-splits-the-preview	lua/md-viewer/debug.lua	    vim.cmd("tabnew")	    vim.cmd("botright new")
health-report-splits-the-preview	lua/md-viewer/health.lua	    vim.cmd("tabnew")	    vim.cmd("botright new")
superseded-fill-counted-as-stale	lua/md-viewer/controller.lua	if filling then filling.superseded_fills = filling.superseded_fills + 1 end	if filling then filling.stale_fills = filling.stale_fills + 1 end
MUTATIONS

caught=0; missed=0; skipped=0
declare -a missed_names=()

# `scripts/resident/ab.lua` is in here because it is the operator's only
# instrument and the plugin never loads it: nothing else compiles that file, so
# a field it reads can be removed from under it with every test still green.
# That is exactly what the grid rewrite did -- scored below as
# `ab-reads-the-region-cache`.
#
# `debug.lua` and `health.lua` are here because a diagnostic that resizes the
# preview destroys what it is diagnosing: both used to open a full-width split,
# which changes the viewport the resident grid is keyed on, so looking at the
# numbers threw away every slice and reported `evictions: 0` while doing it.
restore_all() {
  git checkout -- lua/md-viewer/controller.lua lua/md-viewer/backends/kitty_raw.lua lua/md-viewer/resident.lua lua/md-viewer/debug.lua lua/md-viewer/health.lua renderer/src/browser.js scripts/resident/ab.lua 2>/dev/null || true
}
trap 'restore_all; rm -f "$mutations"' EXIT

if ! git diff --quiet -- lua/md-viewer/controller.lua lua/md-viewer/backends/kitty_raw.lua lua/md-viewer/resident.lua lua/md-viewer/debug.lua lua/md-viewer/health.lua renderer/src/browser.js scripts/resident/ab.lua; then
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
