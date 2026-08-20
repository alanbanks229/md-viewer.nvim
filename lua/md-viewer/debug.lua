local state = require("md-viewer.state")
local process = require("md-viewer.process")
local config = require("md-viewer.config")
local resident = require("md-viewer.resident")

local M = { events = {} }

function M.log(event, data)
  M.events[#M.events + 1] = { time = os.date("!%Y-%m-%dT%H:%M:%SZ"), event = event, data = data }
  if #M.events > 200 then table.remove(M.events, 1) end
end

---The backend's own process-wide byte total, when it keeps one.
---
---Only the raw Kitty backend does. The others answer nil rather than zero,
---because "this backend does not measure its output" and "this backend wrote
---nothing" are different facts and a report that conflated them would invite
---exactly the wrong conclusion from a quiet session.
local function backend_ui_bytes(session)
  local backend = session.backend
  if not (backend and backend.ui_bytes_total) then return nil end
  return backend.ui_bytes_total()
end

---What the terminal is holding on this session's behalf, and whether it is
---earning its keep.
---
---`hits` against `misses` is the whole question: a hit is a scroll that cost
---placement bytes instead of a frame. `slices_resident` against `grid_slices`
---says how much of the document the terminal is holding, and `resident_px`
---beside `memory_px` says how close the ceiling is to binding.
---
---`decoded_mb_budgeted` is the same quantity in the unit the ceiling is stated
---in, and it is named for what it is. It converts `resident_px` at
---`resident.BYTES_PER_RESIDENT_PX`, which was measured on synthetic gradients
---(`scripts/resident/rss-calibrate.py`) and is contradicted by the only real
---session anyone has sampled: twelve slices reported ~342 MB here while
---`scripts/resident/rss.sh` saw iTerm2's resident size move ~10 MB. Something is
---34x wrong -- either the sampler cannot see decoded slices, or the conversion
---does not generalise to a document that is mostly flat background -- so this
---says what the plugin is *spending against its own ceiling*, not what the
---terminal is holding, and `decoded_basis` says so on the line below rather than
---leaving a reader to find this comment.
---
---`evictions` is the number the rebuild was for. Under the bounded region it
---climbed with every boundary crossing; under a grid a document inside the
---ceiling should never evict at all, so a non-zero count on an ordinary document
---is the signal that something is wrong rather than a statistic.
local function resident_report(session)
  local live = session.resident
  if not live then return nil end
  local slices = resident.slice_records(live)
  local decoded = 0
  for _, region in ipairs(slices) do
    decoded = decoded + resident.decoded_bytes(region)
  end
  local grid = live.grid
  -- Asked here rather than read off the session, so the block answers about the
  -- configuration there is now rather than about the one the last hold happened
  -- to be computed under.
  local link_rate, link_source = resident.link_rate(
    config.get().render.ssh_link_bytes_per_sec,
    live.wire_bytes_per_ms,
    live.wire_samples,
    live.wire_samples_discarded
  )
  local slices_that_fit, whole_document = resident.slices_that_fit(grid, live.memory_px)
  return {
    enabled = live.enabled,
    -- Non-nil means this session gave up and is on the ordinary capture path
    -- for good; the string says why.
    fallback_reason = live.fallback_reason,
    -- The grid, and which generation of it. Two is the resting value on a
    -- healthy session before a single slice exists -- one bump when the preview
    -- opens and the gate is evaluated, one when the first scroll finds no key
    -- to compare against -- so this is a *change* counter, not a fault counter.
    -- It used to be documented as meaning the renderer had refused a slice,
    -- which it reads as from generation 2 onwards on every session ever opened.
    -- `slice_shrinks` is the field that actually answers that.
    --
    -- What it does say: every bump past those two threw away whatever was held,
    -- and `dropped_slices` says how much.
    grid_generation = live.generation,
    grid_slices = grid and grid.count,
    grid_slice_h = grid and grid.slice_h,
    grid_overlap = grid and grid.overlap,
    grid_refusal = live.grid_refusal,
    slices_resident = #slices,
    resident_px = live.resident_px,
    memory_px = live.memory_px,
    -- Whether this document fits `image.resident_memory_mb`, and how much of it
    -- does. Reported rather than enforced: a document larger than the memory
    -- allowed for it is an ordinary situation, not an error and not a refusal.
    -- What is not ordinary is having to infer it from `evictions` climbing, so
    -- it is said here directly -- along with what it costs, which is an upload
    -- every time the reader crosses the window.
    slices_that_fit = slices_that_fit,
    document_fits = whole_document,
    decoded_mb_budgeted = decoded > 0 and (decoded / 1048576) or 0,
    decoded_basis = ("%d B/px assumed, uncorroborated by a real session"):format(resident.BYTES_PER_RESIDENT_PX),
    hits = live.hits,
    misses = live.misses,
    pans = live.pans,
    unplaced_places = live.unplaced_places,
    fills = live.fills,
    -- Every way a fill can fail to become a resident slice, kept apart because
    -- they mean different things and cost different amounts. `superseded` and
    -- `abandoned` cost nothing at all -- the capture never left the renderer --
    -- while `undisplayed` has already crossed the wire. `stale` is the one that
    -- means something is invalidating the grid faster than it can be filled.
    --
    -- Together with `slices_resident`, `evictions` and `dropped_slices` these
    -- account for `fills` exactly:
    --
    --   fills == slices_resident + stale + abandoned + undisplayed
    --                            + evictions + dropped_slices
    --
    -- asserted in `tests/lua/cases/resident_e2e.lua` across a whole-document
    -- walk. `superseded_fills` is outside the identity on purpose: it counts
    -- captures that never reached the point `fills` is incremented at.
    stale_fills = live.stale_fills,
    abandoned_fills = live.abandoned_fills,
    superseded_fills = live.superseded_fills,
    undisplayed_fills = live.undisplayed_fills,
    evictions = live.evictions,
    -- Slices given back all at once, and how many times. **Not evictions.** A
    -- resize, a colorscheme change, an edit or `:MdViewerRefresh` invalidates
    -- the grid, which is correct -- the document reflows, so the held pixels
    -- stop describing it -- but every slice dropped that way was captured and
    -- paid for at full price. This was the missing quarter of a real session's
    -- traffic, and the only trace of it was `fills` exceeding `slices_resident`.
    dropped_slices = live.dropped_slices,
    drains = live.drains,
    prefetches = live.prefetches,
    -- Pans declined so a browser-painted highlight would not be erased. Not a
    -- failure: it is the feature correctly getting out of the way.
    blocked_by_find = live.blocked_by_find,
    blocked_by_selection = live.blocked_by_selection,
    upload_bytes = live.upload_bytes,
    placement_bytes = live.placement_bytes,
    fill_in_flight = live.fill.in_flight,
    -- The wire, which is the resource the cache is really trading against. A
    -- region and the moving frames it replaces share one `nvim_ui_send` queue
    -- and one pty, so a hit ratio alone can look excellent while the link is
    -- still saturated. `frames_suppressed_by_hold` is the count of moving frames
    -- this session declined to queue behind a draining region -- the anti-
    -- backlog measure -- and `link_bytes_per_ms` is the rate the hold in front
    -- of it was computed from.
    --
    -- `link_rate_source` is reported beside the number because the two readings
    -- are not the same kind of fact. `configured` is
    -- `render.ssh_link_bytes_per_sec`, which the operator stated. `estimated` is
    -- inferred from writes that blocked, and a write blocking is back-pressure
    -- rather than arrival -- it runs fast and it is a fallback. `unknown` means
    -- there was no sample to work from at all.
    --
    -- `unobservable` is the reading that matters on a real tunnel, and it means
    -- this session had samples and threw most of them out: SSH took each payload
    -- into its buffer and the write returned before anything crossed, so what
    -- survived measures buffer room rather than a link. A session reporting it
    -- has no inference worth holding the wire on, and
    -- `render.ssh_link_bytes_per_sec` is the only thing that will give the hold a
    -- real number -- `scripts/ssh-link-speed.lua` measures one. This used to
    -- print an estimate of 101,169 B/ms for a link doing 800 and call it
    -- measured, and the hold computed from it was 2 ms.
    link_bytes_per_ms = link_rate,
    link_rate_source = link_source,
    wire_samples = live.wire_samples,
    -- Samples thrown out for implying a link faster than one can be. Outnumbering
    -- `wire_samples` is what makes `link_rate_source` `unobservable`: the two
    -- populations are the same phenomenon, and differ only in whether the number
    -- they produced happened to land under the ceiling.
    wire_samples_discarded = live.wire_samples_discarded,
    upload_hold_ms = live.upload_hold_ms,
    frames_suppressed_by_hold = live.frames_suppressed_by_hold,
    superseded_by_pan = live.superseded_by_pan,
    -- Scroll positions spanning two slices, drawn as two bands in one write --
    -- and those that had to fall back to a captured frame because only one of
    -- the two was held. The second climbing while the first does not means fills
    -- are not keeping up with the reader, not that the composite is wrong.
    straddles = live.straddles,
    straddle_misses = live.straddle_misses,
    -- Below 1 means the renderer refused to capture a slice at the full height
    -- and the whole grid was regenerated with shorter ones.
    slice_scale = live.slice_scale,
    slice_shrinks = live.slice_shrinks,
    fill_png_bytes = live.fill_png_bytes,
    fill_capture_ms = live.fill_capture_ms,
    desired_scroll_y = live.desired_scroll_y,
    gate_reason = live.gate_reason,
  }
end

function M.snapshot()
  local sessions = {}
  for buf, session in pairs(state.all()) do
    sessions[tostring(buf)] = {
      source_win = session.source_win,
      preview_buf = session.preview_buf,
      preview_win = session.preview_win,
      backend = session.backend and session.backend.name,
      image_id = session.image_id,
      requested = session.request_serial,
      applied = session.applied_serial,
      scroll_y = session.scroll_y,
      document_height_px = session.document_height_px,
      applied_scroll_y = session.applied_scroll_y,
      -- The caret, and the two numbers its position is derived from. A caret
      -- rect is viewport-relative at the scroll it was measured against, and
      -- every later position is that rect less the drift since. So a caret in
      -- the wrong place is one of three things, and only these fields tell them
      -- apart: a stale rect, a `caret_scroll_y` that no longer matches the
      -- measurement, or an `applied_scroll_y` that disagrees with the pixels on
      -- screen. Panning changes the third with no round trip, which is why it
      -- became worth reporting.
      caret_scroll_y = session.caret_scroll_y,
      caret_rect = session.caret_rect and ("%.1f,%.1f %.1fx%.1f"):format(
        session.caret_rect.x,
        session.caret_rect.y,
        session.caret_rect.width,
        session.caret_rect.height
      ),
      caret_drift_px = session.caret_rect and ((session.applied_scroll_y or 0) - (session.caret_scroll_y or 0)) or nil,
      caret_index = session.caret_index,
      pan_serial = session.pan_serial,
      layout_reused = session.last_layout_reused,
      markdown_reused = session.last_markdown_reused,
      capture_scale = session.last_capture_scale,
      -- The fraction of its natural size the moving frame is captured at, and
      -- why. Both nil on a local session, which is the case where nothing is
      -- reduced. Reported beside `capture_encoder` on purpose: the Playwright
      -- fallback path cannot express a sub-1x scale, so a session asking for
      -- 0.5 whose frames are not shrinking is answered by those two rows
      -- together and by neither alone.
      scroll_scale = session.scroll_scale,
      scroll_scale_source = session.scroll_scale_source,
      -- How long scrolling must be idle before the expensive settle capture is
      -- taken. Reported beside the scale because the two are the whole of what
      -- an SSH session does differently, and a reader chasing scroll cost needs
      -- to see both: the scale decides what a moving frame costs, this decides
      -- how often the sharp one is paid for at all.
      scroll_settle_ms = session.scroll_settle_ms,
      scroll_settle_source = session.scroll_settle_source,
      capture_encoder = session.last_capture_encoder,
      png_bytes = session.last_png_bytes,
      layout_ms = session.last_layout_ms,
      capture_ms = session.last_capture_ms,
      image_update_ms = session.last_image_update_ms,
      fast_png_bytes = session.fast_png_bytes,
      fast_capture_ms = session.fast_capture_ms,
      fast_image_update_ms = session.fast_image_update_ms,
      -- How many frames of each kind were actually captured and transmitted,
      -- and their total bytes. `coalesced_scroll_events` below counts the
      -- opposite -- scroll events dropped before capture -- so these are the
      -- only fields that answer "how much went down the wire".
      fast_frame_count = session.fast_frame_count or 0,
      fast_bytes_total = session.fast_bytes_total or 0,
      -- The fastest and the average this loop turned over. Compare the minimum
      -- against fast_capture_ms + fast_image_update_ms + the frame's transit to
      -- see what the per-frame cost is actually made of; a minimum far above
      -- their sum means the constraint is somewhere none of them measure.
      fast_interval_min_ms = session.fast_interval_min_ms,
      fast_interval_mean_ms = session.fast_interval_count
          and session.fast_interval_count > 0
          and (session.fast_interval_sum_ms / session.fast_interval_count)
        or nil,
      retina_png_bytes = session.retina_png_bytes,
      retina_capture_ms = session.retina_capture_ms,
      retina_image_update_ms = session.retina_image_update_ms,
      retina_frame_count = session.retina_frame_count or 0,
      retina_bytes_total = session.retina_bytes_total or 0,
      coalesced_scroll_events = session.coalesced_scroll_events or 0,
      -- Everything this session has actually written to the terminal, and what
      -- the last write cost. The `*_bytes_total` fields above count PNGs only;
      -- these count the placements, deletions and overlay rectangles that ride
      -- the same pty. Over SSH they are one wire, so a change that claims to
      -- have removed traffic has to be judged here -- removing the largest
      -- payload promotes whatever was second, and PNG counters cannot see that.
      --
      -- `raw_ui_bytes_total` is the whole backend's, across every session plus
      -- the shared tint-sheet and animation-frame caches, so it is always the
      -- larger number; a big gap between them is work no session owns.
      ui_bytes_total = session.ui_bytes_total or 0,
      last_ui_bytes = session.last_ui_bytes,
      raw_ui_bytes_total = backend_ui_bytes(session),
      viewport_width_px = session.viewport_width_px,
      -- What the terminal is holding, measured from the PNG header rather than
      -- derived from the requested scale: the Playwright fallback cannot express
      -- a sub-1x factor, so a frame that asked for 0.5 and came back at 1.0
      -- shows the disagreement here and nowhere else.
      image_width_px = session.image_width_px,
      image_height_px = session.image_height_px,
      resident = resident_report(session),
      -- How many animated images the last render *measured*, beside how many
      -- became assets. Without the first number a document whose geometry pass
      -- timed out reads exactly like a document with no animated images in it
      -- at all -- which is how that failure stayed invisible for so long. A
      -- count here with `animation_count = 0` means the rects never arrived;
      -- `incomplete` means the renderer is still trying to measure them.
      animation_geometry_count = session.animation_geometry and #session.animation_geometry or 0,
      animation_geometry_incomplete = session.animation_geometry_incomplete or false,
      remote_images_pending = session.remote_images_pending or false,
      animation_count = session.animation_assets and vim.tbl_count(session.animation_assets) or 0,
      animation_strategy = session.animation_strategy,
      animation_assets = (function()
        if not session.animation_assets then return nil end
        local lines = {}
        for id, asset in pairs(session.animation_assets) do
          lines[#lines + 1] = ("%s %s %dx%d %s%s"):format(
            id,
            asset.strategy,
            asset.target_w,
            asset.target_h,
            asset.refused and ("refused: " .. asset.refused)
              or (asset.frames and (asset.strategy == "native" and (asset.native_ready and "playing" or "uploading") or (#asset.frames .. " frames")))
              or "materializing",
            asset.decode_ms and (" (decoded in " .. asset.decode_ms .. "ms)") or ""
          )
        end
        table.sort(lines)
        return lines
      end)(),
      animation_ticks = session.animation_ticks,
      animation_last_bytes = session.animation_last_bytes,
      animation_last_error = session.animation_last_error,
      animation_suppressed_reason = session.animation_suppressed_reason,
      viewport_height_px = session.viewport_height_render_px,
      viewport_calibration_tier = session.viewport_calibration_tier,
      -- The cell this render was sized against, so the tier above can be
      -- checked rather than trusted: `viewport_width_px` should be
      -- `preview_width_cells` times this. nil on the estimated tier, where no
      -- exact cell exists and the aspect ratio stands in for one.
      viewport_cell_css_px = session.viewport_cell_css_width_px and require("md-viewer.coordinates").describe_cell(
        session.viewport_cell_css_width_px,
        session.viewport_cell_css_height_px,
        session.viewport_cell_detail
      ),
      preview_width_cells = session.preview_width_cells,
      preview_height_cells = session.preview_height_cells,
      occluded = session.occluded,
      occluding_windows = session.occluding_windows,
      -- Why an otherwise healthy session is showing nothing: the preview
      -- window is parked on a tabpage the terminal is not displaying.
      tabpage_hidden = session.tabpage_hidden or false,
      refresh_deferred = session.refresh_deferred or false,
      ui_suppressed = session.ui_suppressed,
      ui_polling = session.ui_poll_timer ~= nil,
      placement = session.last_placement,
      passive_cutouts = session.last_placement and #(session.last_placement.exclusions or {}) or 0,
      loading = session.loading,
      render_failed = session.render_failed,
      -- Current content revision this session's cached frame/interaction state
      -- is pinned to (renderer.lua's "changedtick:render_epoch" string) -- what
      -- a stale-interaction error is measured against.
      content_revision = session.renderer_revision,
      interaction_last_kind = session.last_interaction_kind,
      interaction_last_precision = session.last_interaction_precision,
      interaction_pointer_pressed = session.pointer ~= nil and session.pointer.pressed or false,
      -- Where this preview sits in the documents it has followed links
      -- through. Counts and an index only: no paths, which the winbar already
      -- shows for the one that matters.
      history_length = session.history and #session.history or 0,
      history_index = session.history_index or 0,
      -- The remote-document session, when this is one: where the document
      -- lives, whether the root walk has answered, and what the fetch
      -- pipeline has done so far. `failed` carries the root walk's error, the
      -- one fact that explains a session whose images are all placeholders.
      remote_document = session.remote and {
        authority = session.remote.parsed and session.remote.parsed.authority,
        scheme = session.remote.parsed and session.remote.parsed.scheme,
        ready = session.remote.ready or false,
        failed = session.remote.failed,
        root = session.remote.root,
        base_dir = session.remote.base_dir,
        mirror_root = session.remote.mirror_root,
        assets_fetched = session.remote.assets and session.remote.assets.fetched or 0,
        assets_refused = session.remote.assets and session.remote.assets.refused or 0,
        assets_failed = session.remote.assets and session.remote.assets.failed or 0,
      } or nil,
      selection_active = session.selection_active,
      -- Length only -- see interaction.lua's copy_selection comment. Never
      -- surface the selected text itself in diagnostics.
      selection_text_length = session.selection_text_length,
      find_active = session.find_active,
      find_query = session.find_query,
      find_match_count = session.find_match_count,
      find_active_index = session.find_active_index,
      interaction_request_count = session.interaction_request_count or 0,
      interaction_stale_count = session.interaction_stale_count or 0,
      coalesced_drag_events = session.coalesced_drag_events or 0,
      -- Drag overlay: whether rectangles are on screen right now, and
      -- what the last overlay frame cost. `overlay_last_bytes` is the byte
      -- count actually written to the terminal for that frame -- the number
      -- that replaced ~1MB of base64 PNG per moving frame.
      overlay_active = session.overlay_set ~= nil,
      overlay_rect_count = session.overlay_rect_count or 0,
      overlay_frames = session.overlay_frames or 0,
      overlay_last_bytes = session.overlay_last_bytes,
      overlay_last_ms = session.overlay_last_ms,
      overlay_last_error = session.overlay_last_error,
    }
  end
  -- `renderer`, `backends` and `terminal` used to be dumped here as well.
  -- They are the machine's capabilities, not this preview's behaviour, and
  -- health.environment_lines() now renders exactly the same data above the
  -- snapshot -- reporting a fact twice in one buffer only invites the reader
  -- to wonder which copy is stale.
  return {
    sessions = sessions,
    -- The last link md-viewer handed to the operating system, and what came
    -- back. This is the difference between "the click never reached the
    -- plugin" and "the plugin ran the handler and the OS declined".
    last_external_open = require("md-viewer.interaction").last_external or "none",
    events = M.events,
  }
end

---The one complete diagnostic artifact: what this machine can do, followed by
---what the running previews are actually doing with it.
---
---Both halves are needed to explain almost any real report, and while they
---lived in two separate commands every bug report arrived with one of them.
---Round-trips to the renderer for the same reason `:MdViewerHealth` does: the
---Chromium path and launch result are only trustworthy when the subprocess
---itself answers for them.
function M.show()
  local health = require("md-viewer.health")
  process.request("health", { browser = config.get().browser }, function(result, err)
    local lines = { "md-viewer.nvim debug", ("="):rep(20) }
    vim.list_extend(lines, health.environment_lines(health.collect(result, err)))
    -- The renderer has always computed and sent these counters; nothing read
    -- them, so decode failures, refusals and frame-store evictions were
    -- invisible on this side while being one field away the whole time.
    if type(result) == "table" and type(result.animationStore) == "table" then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "-- Renderer animation store --"
      vim.list_extend(lines, vim.split(vim.inspect(result.animationStore), "\n", { plain = true }))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "-- Sessions & Events --"
    vim.list_extend(lines, vim.split(vim.inspect(M.snapshot()), "\n", { plain = true }))

    -- A tab, not the `botright new` this used to be, because a full-width split
    -- takes rows from the preview and that is not a free thing to do. The
    -- viewport is part of the resident key -- the document reflows at a
    -- different height -- so shrinking the pane invalidates every slice the
    -- terminal is holding, and closing the split again invalidates them a
    -- second time. On a slow link that is the whole document, re-uploaded,
    -- because someone looked at the numbers. It cost a real session six slices
    -- and ~2.5 MB, reported as `evictions: 0`, in a run whose own protocol says
    -- to check this command while walking. A new tab leaves every window in the
    -- current tab exactly where it was.
    vim.cmd("tabnew")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, "md-viewer://debug")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "md-viewer-debug"
  end)
end

return M
