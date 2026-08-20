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

  -- A *remote document* in a *local* Neovim is not an SSH session. The rule
  -- consults the session's transport -- the environment Neovim itself runs
  -- in -- and never the buffer's origin, so a remote-ssh.nvim document gets
  -- the full-quality local path even while its bytes live on another
  -- machine, and an actual remote Neovim keeps its reduced moving frame
  -- whatever its buffers are called. This is the boundary between the two
  -- remote features and must not blur.
  config.reset()
  do
    local state = require("md-viewer.state")
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, "rsync://alan@dev-vm//home/alan/project/mode-b.md")
    local session = state.create(buf, vim.api.nvim_get_current_win())
    session.remote = { ready = true, parsed = { authority = "alan@dev-vm" } }
    stub_ssh(false)
    local remote_doc_scale, remote_doc_source = resolve(config.get().render)
    t.eq(nil, remote_doc_scale, "a remote document on a local Neovim keeps the full-size moving frame")
    t.ok(remote_doc_source:match("local"), "and is answered as a local session")
    t.eq(160, (controller._scroll_settle_delay(config.get().render)), "with the local settle delay")
    stub_ssh(true)
    t.eq(
      0.5,
      (resolve(config.get().render)),
      "an actual SSH session still reduces the moving frame, whatever its buffers are named"
    )
    t.eq(400, (controller._scroll_settle_delay(config.get().render)), "and still waits the SSH settle delay")

    -- Resident panning is gated on the identical rule, and must not blur the
    -- same boundary. It trades terminal memory for wire time, and wire time only
    -- exists where the pixels have to travel -- so a remote document on a local
    -- Neovim gets nothing from it and must not pay for it.
    session.backend = raw_backend
    session.viewport_width_px, session.viewport_height_px = 990, 1020
    stub_ssh(false)
    local local_ok, local_reason = controller._resident_gate(session)
    t.eq(false, local_ok, "a remote document on a local Neovim keeps no resident regions")
    t.ok(local_reason:match("local session"), "and is answered as a local session, not as a remote document")

    stub_ssh(true)
    config.setup({ image = { reuse_sent_pixels = "on" } })
    t.eq(
      true,
      (controller._resident_gate(session)),
      "an actual SSH session may keep them, whatever its buffers are named"
    )

    -- The gate answers with a reason on *success* as well as on failure -- it
    -- says which rule allowed it, not only which one refused. That makes
    -- `fallback_reason = ok and nil or reason` a trap, because `nil` is falsy
    -- and the `or` takes its right branch whatever `ok` was: the success message
    -- becomes a fallback reason and every fill and pan refuses for the rest of
    -- the session. It shipped that way in the A/B harness once and made the
    -- treatment arm silently run on the ordinary path.
    local allowed_ok, allowed_reason = controller._resident_gate(session)
    t.eq(true, allowed_ok, "sanity: the gate allows this session")
    t.ok(allowed_reason ~= nil, "and still answers with a reason, which is what makes the idiom unsafe")

    -- So applying the gate is the controller's job, not a caller's, and the
    -- property that matters is the one that broke: allowed means no fallback.
    local applied_ok = controller.reevaluate_resident(session)
    t.eq(true, applied_ok, "applying the gate to an open session enables it")
    t.eq(true, session.resident.enabled, "recording that on the session")
    t.eq(nil, session.resident.fallback_reason, "and leaving no fallback reason behind when it was allowed")
    t.ok(session.resident.gate_reason ~= nil, "while still reporting why it was allowed")

    config.setup({ image = { reuse_sent_pixels = "off" } })
    local off_ok, off_reason = controller._resident_gate(session)
    t.eq(false, off_ok, "and image.reuse_sent_pixels = off refuses regardless of transport")
    t.ok(off_reason:match("off"), "naming the option that refused")

    -- The other direction: a refusal must leave a reason, or a session that
    -- declined would be indistinguishable from one that was never asked.
    controller.reevaluate_resident(session)
    t.eq(false, session.resident.enabled, "re-applying a refusal disables it")
    t.ok(session.resident.fallback_reason ~= nil, "and says why, on the session")

    config.setup({ image = { reuse_sent_pixels = "on", resident_memory_mb = 0 } })
    local broke_ok, broke_reason = controller._resident_gate(session)
    t.eq(false, broke_ok, "a zero memory ceiling cannot hold a slice")
    t.ok(broke_reason:match("memory"), "and says so")

    -- The key this replaced meant the same bound in a different unit. It is
    -- converted rather than refused: an unknown key accepted in silence would
    -- leave a reader believing a ceiling is in force that is not, but refusing
    -- the whole configuration costs them the preview -- and on the slow remote
    -- link this exists for, "no preview at all" is the worst available way to
    -- learn about a rename.
    local warnings = {}
    local real_notify = vim.notify
    vim.notify = function(message) warnings[#warnings + 1] = message end
    config._forget_budget_px_warning()
    local kept = pcall(config.setup, { image = { reuse_sent_pixels = "on", resident_budget_px = 8000000 } })
    vim.notify = real_notify
    t.eq(true, kept, "a configuration naming the replaced key still loads")
    t.eq(nil, config.get().image.resident_budget_px, "with the old key gone")
    -- 8,000,000 px at the measured 13 bytes each. Deliberately the bound they
    -- *had* rather than the "~32 MB" it was documented as: silently changing how
    -- much a working configuration holds is the one thing a rename must not do.
    t.eq(99, config.get().image.resident_memory_mb, "converted at the measured bytes per resident pixel")
    t.eq(1, #warnings, "and said so exactly once")
    t.ok(tostring(warnings[1]):match("resident_memory_mb"), "naming what replaced it: " .. tostring(warnings[1]))

    -- Zero has to survive the conversion, or a configuration that had turned
    -- resident panning off comes back on.
    config._forget_budget_px_warning()
    vim.notify = function() end
    config.setup({ image = { reuse_sent_pixels = "on", resident_budget_px = 0 } })
    vim.notify = real_notify
    t.eq(0, config.get().image.resident_memory_mb, "a zero budget converts to a zero ceiling, which still disables")
    t.eq(false, (controller._resident_gate(session)), "so the feature stays off rather than switching itself on")
    config.reset()

    -- And the same shape again for the option's own rename, because the reader
    -- is the same one: a preview refused over a renamed key, on the slow remote
    -- link this exists for, is the worst way there is to learn about a rename.
    -- A pure rename, so the conversion is exact rather than a change of units.
    warnings = {}
    vim.notify = function(message) warnings[#warnings + 1] = message end
    config._forget_resident_pan_warning()
    local renamed = pcall(config.setup, { image = { resident_pan = "off" } })
    vim.notify = real_notify
    t.eq(true, renamed, "a configuration naming image.resident_pan still loads")
    t.eq(nil, config.get().image.resident_pan, "with the old key gone")
    t.eq("off", config.get().image.reuse_sent_pixels, "and the value carried across exactly")
    t.eq(1, #warnings, "said exactly once, not once per setup()")
    t.ok(tostring(warnings[1]):match("reuse_sent_pixels"), "naming what replaced it: " .. tostring(warnings[1]))
    t.eq(false, (controller._resident_gate(session)), "so a configuration that had it off keeps it off")
    config.reset()

    -- A value that was never legal stays illegal under the new name, rather
    -- than being quietly replaced by the default: a typo that starts working
    -- and does something else is worse than one that says so.
    config._forget_resident_pan_warning()
    vim.notify = function() end
    local bad_rename = pcall(config.setup, { image = { resident_pan = "yes" } })
    vim.notify = real_notify
    t.eq(false, bad_rename, "an illegal value is still refused after conversion")
    config.reset()

    state.remove(buf)
    vim.api.nvim_buf_delete(buf, { force = true })
  end

  -- ---------------------------------------------------------------------
  -- The settle delay
  -- ---------------------------------------------------------------------

  local settle = controller._scroll_settle_delay

  config.reset()
  stub_ssh(false)
  local local_settle, local_settle_source = settle(config.get().render)
  t.eq(160, local_settle, "a local session settles on the ordinary delay")
  t.ok(local_settle_source:match("scroll_settle_ms"), "the local settle answer names the option")

  stub_ssh(true)
  local ssh_settle, ssh_settle_source = settle(config.get().render)
  t.eq(400, ssh_settle, "an SSH session waits longer before paying for the sharp frame")
  t.ok(ssh_settle_source:match("ssh_scroll_settle_ms"), "the SSH settle answer names the option it came from")

  -- Replacement, not a maximum: an explicit SSH delay is used as written and is
  -- never floored by the local one, so someone who wants the sharp frame sooner
  -- over SSH than locally can have it.
  config.reset()
  config.setup({ render = { scroll_settle_ms = 900, ssh_scroll_settle_ms = 90 } })
  stub_ssh(true)
  t.eq(90, (settle(config.get().render)), "an SSH delay below the local one is honoured, not clamped up")
  stub_ssh(false)
  t.eq(900, (settle(config.get().render)), "and the local delay is untouched by it")

  -- One delay everywhere means setting both, because `setup()` cannot express
  -- an absent key: vim.tbl_deep_extend reads a nil as "keep the default". The
  -- resolver's nil branch is still reachable for a table built by hand, and
  -- must fall back rather than re-defaulting -- asserted directly, since the
  -- supported configuration path cannot produce it.
  config.reset()
  config.setup({ render = { scroll_settle_ms = 90, ssh_scroll_settle_ms = 90 } })
  stub_ssh(true)
  t.eq(90, (settle(config.get().render)), "setting both gives one delay over SSH")
  stub_ssh(false)
  t.eq(90, (settle(config.get().render)), "and the same one locally")
  stub_ssh(true)
  t.eq(160, (settle({ scroll_settle_ms = 160 })), "a hand-built config with no SSH delay falls back to the local one")

  config.reset()
  config.setup({ render = { ssh_scroll_settle_ms = 0 } })
  stub_ssh(true)
  -- 0 is a value, not an omission: it means "settle immediately", and reading it
  -- as absent would silently restore the 400ms default it was set to escape.
  t.eq(0, (settle(config.get().render)), "a zero SSH settle delay is honoured rather than treated as unset")

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
