return function(t)
  local renderer = require("md-viewer.renderer")
  t.eq(true, renderer.is_stale({ closed = false, request_serial = 3 }, 2), "stale response rejection")
  t.eq(false, renderer.is_stale({ closed = false, request_serial = 3 }, 3), "latest response acceptance")
end
