return function(t)
  local backends = require("md-viewer.backends")
  local backend = assert(backends.select("cells"))
  t.eq("cells", backend.name, "explicit cells")
  local unavailable = select(1, backends.select("nvim_img"))
  t.eq(nil, unavailable, "missing vim.ui.img is actionable")
end
