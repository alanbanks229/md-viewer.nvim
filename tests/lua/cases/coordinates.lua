return function(t)
  local config = require("md-viewer.config")
  local coords = require("md-viewer.coordinates")
  local cfg = config.get()
  local viewport = coords.viewport({ width = 80, height = 30 }, cfg.render)
  t.ok(viewport.widthPx <= cfg.render.max_width_px, "bounded viewport width")
  t.ok(viewport.heightPx <= cfg.render.max_height_px, "bounded viewport height")
  t.eq(false, viewport.calibrated, "uncalibrated viewport is labeled")
  t.ok(
    coords.same({ row = 1, col = 2, width = 3, height = 4 }, { row = 1, col = 2, width = 3, height = 4 }),
    "coordinate equality"
  )
  t.eq(
    false,
    coords.same(
      { row = 1, col = 2, width = 3, height = 4, exclusions = { { row = 1, col = 2, width = 1, height = 1 } } },
      { row = 1, col = 2, width = 3, height = 4 }
    ),
    "placement equality includes overlay cutouts"
  )
end
