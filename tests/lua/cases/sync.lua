return function(t)
  local sync = require("md-viewer.sync")
  local blocks = {
    { sourceStart = 0, sourceEnd = 3, topPx = 0, bottomPx = 100 },
    { sourceStart = 3, sourceEnd = 6, topPx = 100, bottomPx = 250 },
  }
  t.eq(blocks[2], sync.block_for_line(blocks, 5), "source-map block lookup")
  local nested = {
    { sourceStart = 0, sourceEnd = 10, topPx = 0, bottomPx = 400 },
    { sourceStart = 3, sourceEnd = 5, topPx = 120, bottomPx = 190 },
  }
  t.eq(nested[2], sync.block_for_line(nested, 4), "most specific source-map block wins")
  t.eq(155, sync.block_target(nested[2], 5), "relative line position within block")
  t.eq(0, sync.scroll_for_block(blocks[1], 200, 500), "scroll clamp")
end
