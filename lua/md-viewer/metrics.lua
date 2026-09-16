---Per-frame capture/placement telemetry, recorded at the one place every
---full frame passes through (`controller.lua`'s `apply_image`). Surfaced by
---`:MdViewerDebug` (see `debug.lua`); nothing else reads it, and nothing
---here touches `vim.api` -- nothing has to run in a real Neovim to be right.
local M = {}

---The `*_png_bytes` fields recorded below are the *last* frame of each kind;
---the counters are every one of them. Both are needed and neither implies
---the other: the size says what a frame costs, the count says how many were
---actually paid for. Without the count the only available stand-in was
---`coalesced_scroll_events`, which counts the opposite thing -- events
---superseded *before* capture, so frames that were never produced and never
---transmitted -- and reading it as frames sent overstates the traffic badly.
function M.record_frame(session, image_update_ms, png_bytes, capture_ms, capture_scale, capture_encoder)
  session.last_image_update_ms = image_update_ms
  if png_bytes then session.last_png_bytes = png_bytes end
  if capture_ms then session.last_capture_ms = capture_ms end
  if capture_scale then session.last_capture_scale = capture_scale end
  -- Which of the renderer's two screenshot paths produced this frame. The fast
  -- one falls back silently and permanently on its first failure, so without
  -- this a browser that refused it would just look inexplicably slow.
  if capture_encoder then session.last_capture_encoder = capture_encoder end
  if capture_scale == "css" then
    session.fast_png_bytes = session.last_png_bytes
    session.fast_capture_ms = session.last_capture_ms
    session.fast_image_update_ms = session.last_image_update_ms
    session.fast_frame_count = (session.fast_frame_count or 0) + 1
    session.fast_bytes_total = (session.fast_bytes_total or 0) + (session.last_png_bytes or 0)
    -- Interval between consecutive moving frames, which is the only honest
    -- measure of how fast this pipeline can actually turn. Frames divided by
    -- wall-clock is not: a scroll driven by hand has pauses in it, and they
    -- land in the denominator as though the pipeline had been busy. The
    -- *minimum* is the floor -- the fastest this loop went when it was
    -- genuinely saturated -- and it is what a per-frame cost has to be compared
    -- against to say whether transit is the constraint or something else is.
    local now = vim.uv.hrtime()
    if session.fast_last_ns then
      local interval = (now - session.fast_last_ns) / 1e6
      session.fast_interval_min_ms = math.min(session.fast_interval_min_ms or interval, interval)
      session.fast_interval_sum_ms = (session.fast_interval_sum_ms or 0) + interval
      session.fast_interval_count = (session.fast_interval_count or 0) + 1
    end
    session.fast_last_ns = now
  elseif capture_scale == "device" then
    session.retina_png_bytes = session.last_png_bytes
    session.retina_capture_ms = session.last_capture_ms
    session.retina_image_update_ms = session.last_image_update_ms
    session.retina_frame_count = (session.retina_frame_count or 0) + 1
    session.retina_bytes_total = (session.retina_bytes_total or 0) + (session.last_png_bytes or 0)
  end
end

return M
