-- `render.scroll_scale`: how much of its natural size the moving frame of a
-- scroll is captured at.
--
-- Two things are worth proving here and neither needs a terminal. The first is
-- the resolution rule, because it is the only place the plugin lets a session's
-- *transport* change what it renders, and getting it wrong in the local
-- direction would silently degrade every user who has no bandwidth problem. The
-- second is that placement geometry does not move when the capture shrinks --
-- the invariant the whole optimization rests on, since a frame captured at half
-- size is still drawn into exactly the same cells.
return function(t)
  local config = require("md-viewer.config")
  local controller = require("md-viewer.controller")
  local terminal = require("md-viewer.terminal")
  local raw_backend = require("md-viewer.backends.kitty_raw")

  config.reset()

  -- ---------------------------------------------------------------------
  -- The resolution rule
  -- ---------------------------------------------------------------------

  local real_detect = terminal.detect
  local function stub_ssh(over_ssh)
    terminal.detect = function()
      local capability = real_detect()
      return vim.tbl_extend("force", vim.deepcopy(capability), { ssh = over_ssh })
    end
  end

  local resolve = controller._scroll_capture_scale

  stub_ssh(false)
  local local_scale, local_source = resolve(config.get().render)
  -- nil, not 1: the request then carries no factor field at all, so a local
  -- session's bytes are byte-for-byte what they were before this option
  -- existed. That is the whole of the backward-compatibility claim.
  t.eq(nil, local_scale, "a local session captures the moving frame at full size")
  t.ok(local_source:match("local"), "the local answer says it came from the session, not a setting")

  stub_ssh(true)
  local ssh_scale, ssh_source = resolve(config.get().render)
  t.eq(0.5, ssh_scale, "an SSH session falls back to render.ssh_scroll_scale")
  t.ok(ssh_source:match("ssh_scroll_scale"), "the SSH answer names the option it came from")

  -- An explicit value is an assertion about this user's link, so it wins in
  -- both directions -- including asking for a reduced frame on a local session,
  -- which is how someone on a slow local terminal gets the same relief.
  config.reset()
  config.setup({ render = { scroll_scale = 0.75 } })
  stub_ssh(false)
  t.eq(0.75, (resolve(config.get().render)), "an explicit scroll scale applies without SSH")
  stub_ssh(true)
  t.eq(0.75, (resolve(config.get().render)), "an explicit scroll scale overrides the SSH default")
  t.ok(
    select(2, resolve(config.get().render)):match("explicit override"),
    "an explicit scroll scale says so rather than crediting the session"
  )

  -- With no separate moving frame there is only the frame a reader looks at,
  -- and reducing that would leave the preview permanently soft. The refusal
  -- lives in the resolver rather than at each caller so there is one place to
  -- read it.
  config.reset()
  config.setup({ render = { fast_scroll = false, scroll_scale = 0.5 } })
  stub_ssh(true)
  local no_fast_scale, no_fast_source = resolve(config.get().render)
  t.eq(nil, no_fast_scale, "with fast_scroll off there is no moving frame to reduce")
  t.ok(no_fast_source:match("fast_scroll"), "the refusal names the option that caused it")

  terminal.detect = real_detect
  config.reset()

  -- ---------------------------------------------------------------------
  -- Placement geometry is independent of capture scale
  -- ---------------------------------------------------------------------

  local original_ui_send = vim.api.nvim_ui_send
  local sequences = {}
  vim.api.nvim_ui_send = function(value) sequences[#sequences + 1] = value end

  local function png(width, height)
    local function be32(value)
      return string.char(
        math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256,
        value % 256
      )
    end
    return "\137PNG\r\n\26\n\0\0\0\13IHDR" .. be32(width) .. be32(height) .. "\0\0\0\0\0\0"
  end

  -- The same rectangle both times: a capture scale change must not reach it.
  local placement = { row = 4, col = 2, width = 10, height = 10 }

  ---Cursor cell and cell-count keys of every placement in a stream, with the
  ---image, placement id and crop pixels left out. Those three are *expected* to
  ---differ between two differently sized captures -- ids are per-call and the
  ---crop is expressed in the image's own pixels -- so comparing the whole
  ---command would only prove that two runs are two runs.
  local function cell_geometry(stream)
    local out = {}
    for row, col, cols, rows in stream:gmatch("\27%[s\27%[(%d+);(%d+)H\27_Ga=p[^;]-,c=(%d+),r=(%d+),") do
      out[#out + 1] = ("cursor=%s;%s cells=%sx%s"):format(row, col, cols, rows)
    end
    return out
  end

  ---The crop rectangle of every placement, to prove each still covers its whole
  ---image rather than a scaled-down corner of it.
  local function crops(stream)
    local out = {}
    for x, y, w, h in stream:gmatch("\27_Ga=p[^;]-,x=(%d+),y=(%d+),w=(%d+),h=(%d+),") do
      out[#out + 1] = ("%s,%s %sx%s"):format(x, y, w, h)
    end
    return out
  end

  sequences = {}
  raw_backend.show(png(200, 200), placement)
  local full_stream = table.concat(sequences)

  sequences = {}
  raw_backend.show(png(100, 100), placement)
  local half_stream = table.concat(sequences)

  t.eq(
    cell_geometry(full_stream),
    cell_geometry(half_stream),
    "halving the capture leaves the cursor position and cell count identical"
  )
  t.eq({ "0,0 200x200" }, crops(full_stream), "a full-size capture is placed whole")
  t.eq({ "0,0 100x100" }, crops(half_stream), "a half-size capture is also placed whole, at its own pixels")

  -- And the cheap half: a reduced frame must still be a single upload followed
  -- by placements, in that order. The saving is entirely in the upload, so an
  -- accidental extra one would give it all back.
  local _, upload_count = half_stream:gsub("\27_Ga=t,", "")
  t.eq(1, upload_count, "a reduced frame still uploads exactly once")

  raw_backend.clear_all()
  vim.api.nvim_ui_send = original_ui_send
  sequences = {}
  config.reset()
end
