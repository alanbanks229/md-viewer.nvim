return function(t)
  local backends = require("md-viewer.backends")
  local backend = assert(backends.select("cells"))
  t.eq("cells", backend.name, "explicit cells")
  local unavailable = select(1, backends.select("nvim_img"))
  t.eq(nil, unavailable, "missing vim.ui.img is actionable")

  local raw_backend = require("md-viewer.backends.kitty_raw")
  local original_ui_send = vim.api.nvim_ui_send
  local graphics_sequences = {}
  vim.api.nvim_ui_send = function(value) graphics_sequences[#graphics_sequences + 1] = value end
  local fake_png = "\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\0\100\0\0\0\100"
  local raw_id = raw_backend.show(fake_png, {
    row = 0,
    col = 0,
    width = 10,
    height = 10,
    exclusions = { { row = 2, col = 2, width = 4, height = 4 } },
  })
  local graphics_output = table.concat(graphics_sequences)
  t.ok(graphics_output:find("a=t,f=100", 1, true), "raw image uploads independently of placements")
  local _, cropped_placements = graphics_output:gsub("\27_Ga=p", "")
  t.eq(4, cropped_placements, "one passive overlay cuts the preview into four placements")
  graphics_sequences = {}
  raw_backend.move(raw_id, { row = 0, col = 0, width = 10, height = 10, exclusions = {} })
  graphics_output = table.concat(graphics_sequences)
  t.ok(graphics_output:find("a=d,d=i", 1, true), "moving deletes only owned placement IDs")
  local _, restored_placements = graphics_output:gsub("\27_Ga=p", "")
  t.eq(1, restored_placements, "removing the overlay restores one full placement")
  raw_backend.clear(raw_id)
  vim.api.nvim_ui_send = original_ui_send
end
