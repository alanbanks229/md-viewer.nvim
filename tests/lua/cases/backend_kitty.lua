-- The exact stream `golden_session()` below produces on every profile that was
-- validated by hand -- iTerm2, Ghostty and Kitty -- with the image and
-- placement id counters normalized to their order of first appearance. Nothing
-- else in it is run-dependent. Regenerate with MD_VIEWER_DUMP_GOLDEN=1 only
-- after establishing that the change was meant to alter what those three
-- terminals receive; the whole point of pinning it is that the WezTerm
-- sheet-margin work did not.
-- One line per complete operation: an upload, a cursor-framed placement, or a
-- deletion. Read top to bottom it is the whole contract -- upload once, four
-- cropped placements around a passive float, one tint sheet, two overlay crops
-- (the first carrying a sub-cell X/Y remainder), a diffed frame that emits its
-- replacement *before* the deletion it supersedes, a re-crop, then teardown.
--
-- The base's `z=-3` was `z=-2` until the animation layer was reserved between
-- the base and the selection overlay. That is the only difference, it was
-- deliberate, and the overlay's own `z=-1` is unchanged -- which is the point:
-- the highlight did not move, the base made room under it.
local GOLDEN_VALIDATED_STREAM = "<ESC>_Ga=t,f=100,t=d,q=2,i=<0>,m=0;iVBORw0KGgoAAAANSUhEUgAAAGQAAABk<ESC>\\"
  .. "<ESC>[s<ESC>[5;3H<ESC>_Ga=p,q=2,C=1,i=<0>,p=<0>,x=0,y=0,w=100,h=20,c=10,r=2,z=-3;<ESC>\\<ESC>[u"
  .. "<ESC>[s<ESC>[9;3H<ESC>_Ga=p,q=2,C=1,i=<0>,p=<1>,x=0,y=40,w=100,h=60,c=10,r=6,z=-3;<ESC>\\<ESC>[u"
  .. "<ESC>[s<ESC>[7;3H<ESC>_Ga=p,q=2,C=1,i=<0>,p=<2>,x=0,y=20,w=30,h=20,c=3,r=2,z=-3;<ESC>\\<ESC>[u"
  .. "<ESC>[s<ESC>[7;9H<ESC>_Ga=p,q=2,C=1,i=<0>,p=<3>,x=60,y=20,w=40,h=20,c=4,r=2,z=-3;<ESC>\\<ESC>[u"
  .. "<ESC>_Ga=t,f=100,t=d,q=2,i=<1>,m=0;iVBORw0KGgoAAAANSUhEUgAAAGQAAABk<ESC>\\"
  .. "<ESC>[s<ESC>[5;3H<ESC>_Ga=p,q=2,C=1,i=<1>,p=<4>,x=0,y=0,w=20,h=10,z=-1,X=6,Y=7;<ESC>\\<ESC>[u"
  .. "<ESC>[s<ESC>[11;7H<ESC>_Ga=p,q=2,C=1,i=<1>,p=<5>,x=0,y=0,w=33,h=12,z=-1;<ESC>\\<ESC>[u"
  .. "<ESC>[s<ESC>[11;7H<ESC>_Ga=p,q=2,C=1,i=<1>,p=<6>,x=0,y=0,w=33,h=12,z=-1,X=1,Y=0;<ESC>\\<ESC>[u"
  .. "<ESC>_Ga=d,d=i,q=2,i=<1>,p=<5>;<ESC>\\"
  .. "<ESC>[s<ESC>[5;3H<ESC>_Ga=p,q=2,C=1,i=<0>,p=<7>,x=0,y=0,w=100,h=100,c=10,r=10,z=-3;<ESC>\\<ESC>[u"
  .. "<ESC>_Ga=d,d=i,q=2,i=<0>,p=<0>;<ESC>\\"
  .. "<ESC>_Ga=d,d=i,q=2,i=<0>,p=<1>;<ESC>\\"
  .. "<ESC>_Ga=d,d=i,q=2,i=<0>,p=<2>;<ESC>\\"
  .. "<ESC>_Ga=d,d=i,q=2,i=<0>,p=<3>;<ESC>\\"
  .. "<ESC>_Ga=d,d=i,q=2,i=<1>,p=<6>;<ESC>\\"
  .. "<ESC>_Ga=d,d=i,q=2,i=<1>,p=<4>;<ESC>\\"
  .. "<ESC>_Ga=d,d=I,q=2,i=<0>;<ESC>\\"

return function(t)
  local config = require("md-viewer.config")
  local raw_backend = require("md-viewer.backends.kitty_raw")
  local cellpixels = require("md-viewer.cellpixels")

  -- A headless Neovim has no terminal on stdout, so the real TIOCGWINSZ
  -- measurement is unavailable here by construction. Stand in for it: 10x10 px
  -- against the 10x10-cell placement below makes the drawn box exactly the
  -- 100x100 fake capture, which is the degenerate case where the pre-2026-08-08
  -- capture-relative arithmetic and the drawn-relative arithmetic agree. The
  -- case where they *disagree* is asserted separately further down.
  local real_measure = cellpixels.measure
  local function stub_cell(width, height, cols, rows)
    cellpixels.measure = function()
      if not width then return nil, "stubbed unavailable" end
      return { width = width, height = height, cols = cols or 10, rows = rows or 10 }
    end
  end
  stub_cell(10, 10)

  local original_ui_send = vim.api.nvim_ui_send
  local sequences
  vim.api.nvim_ui_send = function(value) sequences[#sequences + 1] = value end
  local function output() return table.concat(sequences) end
  local function reset_sequences() sequences = {} end

  local function fake_png(extra_bytes)
    local header = "\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\0\100\0\0\0\100"
    if not extra_bytes then return header end
    return header .. string.rep("\0", extra_bytes)
  end

  local placement = { row = 0, col = 0, width = 10, height = 10 }
  -- 200x200: large enough to cover a drawn box plus a one-cell margin.
  local big_sheet = "\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\0\200\0\0\0\200"

  -- Z-index: explicit override, in every sign, always wins over the profile
  -- default and is the literal value encoded into the placement command.
  for _, value in ipairs({ -5, 0, 5 }) do
    config.reset()
    config.setup({ image = { raw_zindex = value }, terminal = { profile = "kitty" } })
    local health = raw_backend.health()
    t.eq(value, health.zindex, ("explicit raw_zindex=%d is the effective value"):format(value))
    t.ok(health.zindex_source:match("explicit override"), "explicit override is named as the source")
    reset_sequences()
    local id = raw_backend.show(fake_png(), placement)
    t.eq(tostring(value), output():match("z=(%-?%d+)"), "encoded placement z= matches the explicit override")
    raw_backend.clear(id)
  end

  -- Z-index: with no explicit override, each profile's own default supplies
  -- the value and names itself as the source.
  config.reset()
  config.setup({ terminal = { profile = "kitty" } })
  local kitty_health = raw_backend.health()
  t.eq(-3, kitty_health.zindex, "profile default zindex for kitty")
  t.ok(kitty_health.zindex_source:match("profile default"), "profile default is named as the source")
  t.ok(kitty_health.zindex_source:match("kitty"), "source names the active profile")
  -- The profile default declares the whole stack's base directly, so nothing
  -- was moved and nothing may claim to have been: a "lowered" note on an
  -- untouched configuration teaches readers to skim past the one that matters.
  t.eq(nil, kitty_health.zindex_source:match("lowered"), "an untouched default reports no move")

  -- Base, animation frames and the selection overlay are derived together and
  -- no two may ever coincide: the Kitty protocol breaks a z-index tie by image
  -- id, so a base sharing another layer overtakes it the first time it is
  -- re-uploaded (the 2026-08-08 Ghostty defect -- one instant highlight, then
  -- none). Asserting all three from one health call is the check; two equal
  -- numbers anywhere in the stack is the bug.
  for _, profile in ipairs({ "iterm2", "kitty", "ghostty", "wezterm", "warp", "generic_kitty" }) do
    config.reset()
    config.setup({ terminal = { profile = profile } })
    local layered = raw_backend.health()
    t.eq(-3, layered.zindex, ("%s draws its base at -3"):format(profile))
    t.eq(-2, layered.animation_zindex, ("%s leaves -2 to animation frames"):format(profile))
    t.eq(-1, layered.overlay_zindex, ("%s leaves -1 to the selection overlay"):format(profile))
  end

  -- An explicit value only moves when the stack above it would reach 0, where
  -- the protocol draws over Neovim's text instead of under it. Then the whole
  -- stack slides down just far enough for its top to land on -1, and the health
  -- report says so rather than silently disagreeing with the configured value.
  for _, configured in ipairs({ -1, -2 }) do
    config.reset()
    config.setup({ terminal = { profile = "ghostty" }, image = { raw_zindex = configured } })
    local pinned = raw_backend.health()
    t.eq(-3, pinned.zindex, ("an explicit raw_zindex=%d is lowered to -3"):format(configured))
    t.eq(-2, pinned.animation_zindex, "so animation frames still get their own layer")
    t.eq(-1, pinned.overlay_zindex, "and so does the overlay")
    t.ok(pinned.zindex_source:match("lowered from %-?%d"), "and the health report explains the move")
  end

  -- A stack that already clears the text is left alone entirely.
  config.reset()
  config.setup({ terminal = { profile = "ghostty" }, image = { raw_zindex = -3 } })
  local exact = raw_backend.health()
  t.eq(-3, exact.zindex, "a base with room for the whole stack keeps the layer it asked for")
  t.eq(nil, exact.zindex_source:match("lowered"), "and nothing is reported as moved")

  -- Every explicit value above the text keeps its layer and takes the others
  -- with it. A base deliberately put above the text is the only place a
  -- highlight over that base can be seen from.
  config.reset()
  config.setup({ terminal = { profile = "ghostty" }, image = { raw_zindex = 5 } })
  local above = raw_backend.health()
  t.eq(5, above.zindex, "a base above the text keeps the layer it asked for")
  t.eq(6, above.animation_zindex, "and animation frames follow it up")
  t.eq(7, above.overlay_zindex, "and so does the overlay, rather than hiding under it")

  -- With the overlay disabled outright there is one fewer layer to make room
  -- for -- but the animation layer is reserved whether or not anything is
  -- animating, so an explicit -1 still has to give way by exactly one.
  config.reset()
  config.setup({
    terminal = { profile = "ghostty" },
    image = { raw_zindex = -1 },
    interaction = {
      selection_overlay = "off",
    },
  })
  local unlayered = raw_backend.health()
  t.eq(-2, unlayered.zindex, "selection_overlay=off still leaves the animation layer its own")
  t.eq(-1, unlayered.animation_zindex, "which is the layer an explicit -1 was asking for")
  t.eq(nil, unlayered.overlay_zindex, "and reports no overlay layer at all")

  -- ...and with the overlay off, a base that already has room above it does not
  -- move at all, which is what keeps an explicit raw_zindex meaningful.
  config.reset()
  config.setup({
    terminal = { profile = "ghostty" },
    image = { raw_zindex = -2 },
    interaction = { selection_overlay = "off" },
  })
  local unlayered_roomy = raw_backend.health()
  t.eq(-2, unlayered_roomy.zindex, "selection_overlay=off leaves an explicit -2 exactly where it was put")
  t.eq(-1, unlayered_roomy.animation_zindex, "with the animation layer above it")

  -- An explicit override still beats a different profile's default.
  config.reset()
  config.setup({ terminal = { profile = "wezterm" }, image = { raw_zindex = 9 } })
  local overridden_health = raw_backend.health()
  t.eq(9, overridden_health.zindex, "explicit override wins over a non-default profile")
  t.ok(overridden_health.zindex_source:match("explicit override"), "override source names itself, not the profile")

  -- Animation frames: the same natural-size crop placement the overlay uses,
  -- on the layer between the base and the selection tint. What this pins is
  -- the shape of one tick -- upload once, then place-before-delete -- and the
  -- three keys that must never appear: `c` and `r` (which would quantize the
  -- frame's position to whole cells) and any z other than the animation layer.
  config.reset()
  config.setup({ terminal = { profile = "kitty" }, render = { animate = true } })
  stub_cell(10, 20)
  reset_sequences()

  local frame_a = raw_backend.animation_upload("frame-a", fake_png())
  local anim_placement = { row = 4, col = 2, width = 20, height = 10, exclusions = {} }
  -- x = 25 drawn px is cell 2 remainder 5; y = 33 is cell 1 remainder 13.
  local anim_set = raw_backend.animation_apply(
    nil,
    { { image_id = frame_a, x = 25, y = 33, width = 100, height = 50 } },
    anim_placement
  )
  t.ok(anim_set ~= nil, "a frame at a sub-cell offset places")
  local first_tick = output()
  t.ok(first_tick:match("a=p[^;]*,z=%-2"), "frames are placed on the animation layer, not the base or overlay one")
  t.eq(nil, first_tick:match("a=p[^;]*,c=%d"), "no c key: cell scaling would quantize the frame's position")
  t.eq(nil, first_tick:match("a=p[^;]*,r=%d"), "no r key, for the same reason")
  t.ok(first_tick:match("X=5,Y=13"), "the sub-cell remainder is carried in X/Y")
  t.ok(first_tick:match("\27%[6;5H"), "and the cell part positions the cursor (row 4+1, col 2+2, one-based)")
  t.ok(first_tick:match("x=0,y=0,w=100,h=50"), "the crop is the whole frame, which Node already sized to the box")

  reset_sequences()
  local frame_b = raw_backend.animation_upload("frame-b", fake_png())
  raw_backend.animation_apply(
    anim_set,
    { { image_id = frame_b, x = 25, y = 33, width = 100, height = 50 } },
    anim_placement
  )
  local second_tick = output()
  local placed_at = second_tick:find("a=p", 1, true)
  local deleted_at = second_tick:find("a=d,d=i", 1, true)
  t.ok(placed_at and deleted_at, "a later tick both places and deletes")
  t.ok(placed_at < deleted_at, "the new frame is emitted before the one it supersedes, or the image blinks")

  -- An unchanged rectangle with an unchanged image is not re-placed: that is
  -- what makes a paused animation cost nothing.
  reset_sequences()
  raw_backend.animation_apply(
    anim_set,
    { { image_id = frame_b, x = 25, y = 33, width = 100, height = 50 } },
    anim_placement
  )
  t.eq("", output(), "re-applying the identical frame emits nothing at all")

  -- The same frame bytes are uploaded once per session, however often the loop
  -- comes round: a tick must cost placement bytes, not an image.
  reset_sequences()
  t.eq(frame_a, raw_backend.animation_upload("frame-a", fake_png()), "an uploaded frame keeps its id")
  t.eq("", output(), "and is not re-transmitted")

  -- A refused apply must leave the set exactly as it was. The old diff moved
  -- matched entries out of `set.placements` as it walked, so a refusal partway
  -- stranded them: live in the terminal, tracked by nothing, never deleted.
  -- A frame narrower than one pixel forces the refusal -- its clipped piece
  -- rounds up to the 1px placement minimum, which cannot crop from a 0.4px
  -- source -- and the valid item ahead of it is the one that must survive.
  reset_sequences()
  local refused_set, refusal = raw_backend.animation_apply(anim_set, {
    { image_id = frame_b, x = 25, y = 33, width = 100, height = 50 },
    { image_id = frame_a, x = 0, y = 0, width = 0.4, height = 50 },
  }, anim_placement)
  t.eq(nil, refused_set, "a frame that cannot be expressed refuses the whole apply")
  t.ok(refusal:find("crop", 1, true), "and says why")
  t.eq("", output(), "a refused apply sends nothing at all")

  -- A frame whose drawn origin lands exactly halfway between two pixels. The
  -- piece's origin rounds up while its width does not, so the crop derived from
  -- the two used to end one pixel past the frame and refuse -- and since a
  -- refusal abandons the entire diff, one such frame left every animation in
  -- the document sitting on its still frame. Whether any frame lands on a half
  -- pixel is arithmetic on the drawn scale, which is why this reproduced at one
  -- preview width and disappeared at the next.
  reset_sequences()
  local half_set = raw_backend.animation_apply(
    nil,
    { { image_id = frame_a, x = 25.5, y = 33.5, width = 100, height = 50 } },
    anim_placement
  )
  local half_tick = output()
  t.ok(half_set ~= nil, "a frame sitting on a half pixel places instead of refusing")
  t.ok(half_tick:match("x=0,y=0,w=100,h=50"), "and crops the whole frame rather than one pixel past it")
  raw_backend.animation_clear(half_set)

  reset_sequences()
  raw_backend.animation_clear(anim_set)
  t.ok(
    output():find("a=d,d=i", 1, true) ~= nil,
    "the placement the refused apply walked over is still tracked, so clear deletes it"
  )

  -- Native animation: the terminal owns playback. The wire contract is the
  -- protocol's animation extension -- root frame as a plain transmission, the
  -- root's gap set by control action (a=t carries no gap of its own), loading
  -- mode while frames stream, per-frame a=f with the gap as z, then s=3 with
  -- the loop count. Everything below is q=2 like the rest of this backend:
  -- Neovim owns terminal input, so no response could ever be read.

  -- The gate first. A kitty profile grants "frames" until the hardware run
  -- promotes it, so native must refuse -- and say it is the mode, not the
  -- terminal, that refused.
  local native_ok, native_reason = raw_backend.animation_native_supported()
  t.eq(false, native_ok, "the kitty profile does not grant native until someone watched it")
  t.ok(native_reason:find("frames", 1, true), "and the refusal names the mode that stands instead")
  t.eq(true, (raw_backend.animation_supported()), "while client-driven frames remain granted")

  config.reset()
  config.setup({ terminal = { profile = "kitty", animation = "native" }, render = { animate = true } })
  stub_cell(10, 20)
  local overridden_ok, overridden_evidence = raw_backend.animation_native_supported()
  t.eq(true, overridden_ok, "terminal.animation=native opens the gate")
  t.ok(overridden_evidence:find("explicit override", 1, true), "and the evidence says who opened it")

  config.reset()
  config.setup({ terminal = { profile = "wezterm" }, render = { animate = true } })
  stub_cell(10, 20)
  local wez_ok, wez_reason = raw_backend.animation_native_supported()
  t.eq(false, wez_ok, "wezterm refuses native along with everything else")
  t.ok(wez_reason:find("7953", 1, true), "for its own measured reason, not generic caution")

  config.reset()
  config.setup({ terminal = { profile = "kitty", animation = "native" }, render = { animate = true } })
  stub_cell(10, 20)

  -- The upload sequence, exactly.
  reset_sequences()
  local native_key = "sha-abc:100x50"
  local native_id, native_existing = raw_backend.animation_native_begin(native_key, fake_png(), 70)
  t.ok(native_id ~= nil and native_existing == false, "a fresh key begins an upload")
  local begin_out = output()
  local root_at = begin_out:find("a=t,f=100,t=d,q=2,i=" .. native_id, 1, true)
  local gap_at = begin_out:find("a=a,q=2,i=" .. native_id .. ",r=1,z=70", 1, true)
  local loading_at = begin_out:find("a=a,q=2,i=" .. native_id .. ",s=2", 1, true)
  t.ok(root_at, "the root frame is a plain transmission")
  t.ok(gap_at and root_at < gap_at, "the root gap follows it, set through the control action")
  t.ok(loading_at and gap_at < loading_at, "and playback starts in loading mode, ready to show frames as they land")

  reset_sequences()
  t.eq(true, (raw_backend.animation_native_frame(native_key, fake_png(), 200)))
  t.eq(1, #sequences, "one frame is one send -- interleaving another graphics command between chunks corrupts it")
  t.ok(output():find("a=f,f=100,t=d,q=2,i=" .. native_id .. ",z=200", 1, true), "frame data carries its gap as z")

  reset_sequences()
  raw_backend.animation_native_frame(native_key, fake_png(), 0)
  t.eq(nil, output():match("z=%d"), "a zero gap omits the z key entirely -- the protocol ignores z=0")

  reset_sequences()
  t.eq(true, (raw_backend.animation_native_finish(native_key, "infinite")))
  t.ok(output():find("a=a,q=2,i=" .. native_id .. ",s=3,v=1", 1, true), "infinite runs looping with v=1")

  -- A finished key is terminal-resident content: a re-begin hands back the
  -- same id and transmits nothing, whichever session (or renderer process)
  -- asks.
  reset_sequences()
  local reused_id, reused_existing = raw_backend.animation_native_begin(native_key, fake_png(), 70)
  t.eq(native_id, reused_id, "a complete upload is reused by key")
  t.eq(true, reused_existing, "and says so")
  t.eq("", output(), "with nothing re-transmitted")
  t.eq(
    nil,
    (raw_backend.animation_native_frame(native_key, fake_png(), 10)),
    "a finished animation accepts no more frames"
  )

  -- Placement rides the exact machinery the frame-swap path uses -- one item
  -- whose image id happens to be an animated image. Multiple placements of an
  -- animated image animate in sync per the protocol, so nothing else is needed.
  reset_sequences()
  local native_set = raw_backend.animation_apply(
    nil,
    { { image_id = native_id, x = 25, y = 33, width = 100, height = 50 } },
    anim_placement
  )
  t.ok(native_set ~= nil, "a native animation places through the shared clip/exclusion pipeline")
  t.ok(output():find("a=p", 1, true) and output():match("z=%-2"), "on the animation layer like any frame")
  raw_backend.animation_clear(native_set)

  -- Freeing releases the terminal's copy of the data (uppercase delete), and
  -- the key becomes fresh: the next begin uploads anew under a new id.
  reset_sequences()
  t.eq(1, raw_backend.animation_free({ native_key }))
  t.ok(output():find("a=d,d=I,q=2,i=" .. native_id, 1, true), "free deletes image data, not only placements")
  reset_sequences()
  local fresh_id, fresh_existing = raw_backend.animation_native_begin(native_key, fake_png(), 70)
  t.ok(fresh_id ~= native_id and fresh_existing == false, "a freed key uploads again under a new id")

  -- Finite loop counts: repetitionCount 0 is "play once". The protocol's
  -- "loop v-1 times" is ambiguous about plays versus repeats; the mapping errs
  -- toward one extra play and scripts/animation pins the hardware truth.
  reset_sequences()
  raw_backend.animation_native_finish(native_key, 0)
  t.ok(output():find("s=3,v=2", 1, true), "repetitionCount 0 maps to v=2")
  raw_backend.animation_free({ native_key })

  -- An upload abandoned mid-flight must not be appended to: a re-begin frees
  -- the half and starts over.
  reset_sequences()
  local half_id = raw_backend.animation_native_begin("half-done", fake_png(), 10)
  local replacement_id, replacement_existing = raw_backend.animation_native_begin("half-done", fake_png(), 10)
  t.ok(replacement_id ~= half_id, "an incomplete upload is not resumed")
  t.eq(false, replacement_existing, "it is restarted")
  t.ok(output():find("a=d,d=I,q=2,i=" .. half_id, 1, true), "and the abandoned half is freed first")
  raw_backend.animation_free({ "half-done" })

  t.eq(nil, (raw_backend.animation_native_frame("never-began", fake_png(), 10)), "a frame for an unknown key refuses")
  t.eq(nil, (raw_backend.animation_native_finish("never-began", "infinite")), "as does a finish")

  config.reset()
  config.setup({ terminal = { profile = "kitty" }, render = { animate = true } })
  stub_cell(10, 20)
  -- Put the shared 10x10 stub back: everything after this point was written
  -- against it, and a 10x20 cell silently changes what those placements encode.
  stub_cell(10, 10)

  -- Double buffering: profile default is true (place-then-delete). An
  -- explicit false flips the order to delete-then-place.
  config.reset()
  config.setup({ terminal = { profile = "kitty" } })
  local db_health = raw_backend.health()
  t.eq(true, db_health.double_buffer, "profile default double_buffer is true")
  t.ok(db_health.double_buffer_source:match("profile default"), "double_buffer source names the profile default")

  reset_sequences()
  local first_id = raw_backend.show(fake_png(), placement)
  reset_sequences()
  local second_id = raw_backend.update(first_id, fake_png(), placement)
  local double_buffered_output = output()
  local shows_first = double_buffered_output:find("a=t,f=100", 1, true)
  local deletes_first = double_buffered_output:find("d=I", 1, true)
  t.ok(shows_first ~= nil and deletes_first ~= nil, "both the new upload and the old deletion are present")
  t.ok(shows_first < deletes_first, "double_buffer=true shows the new image before deleting the old one")
  -- And all of it in one write, like M.move, overlay_apply and animation_apply.
  -- This used to be three -- upload, placement, deletion -- and the terminal is
  -- free to composite between them. The state it composites in the middle has
  -- the old image deleted and the new one not yet placed, which is a blank
  -- preview. Harmless once; this path runs on every frame of a drag.
  t.eq(1, #sequences, "a replacement frame is one write: upload, placement and deletion cannot be split")
  raw_backend.clear(second_id)

  config.reset()
  config.setup({ image = { double_buffer = false } })
  local forced_health = raw_backend.health()
  t.eq(false, forced_health.double_buffer, "explicit double_buffer=false overrides the profile default")
  t.ok(forced_health.double_buffer_source:match("explicit override"), "explicit override is named as the source")
  reset_sequences()
  local third_id = raw_backend.show(fake_png(), placement)
  reset_sequences()
  local fourth_id = raw_backend.update(third_id, fake_png(), placement)
  local single_buffered_output = output()
  local deletes_second = single_buffered_output:find("d=I", 1, true)
  local shows_second = single_buffered_output:find("a=t,f=100", 1, true)
  t.ok(deletes_second ~= nil and shows_second ~= nil, "both the old deletion and the new upload are present")
  t.ok(deletes_second < shows_second, "double_buffer=false deletes the old image before showing the new one")
  t.eq(1, #sequences, "the delete-then-place order is one write too -- only the order differs")
  raw_backend.clear(fourth_id)
  config.reset()

  -- Sub-cell calibration: the Kitty X/Y placement keys cancel the origin
  -- offset a terminal introduces by applying its window margin to text but not
  -- to graphics. Absent by default, so a terminal that does not implement them
  -- receives exactly the bytes it did before this existed.
  config.reset()
  config.setup({ terminal = { profile = "iterm2" } })
  reset_sequences()
  local plain_offset_id = raw_backend.show(fake_png(), placement)
  t.eq(nil, output():match("X=%d+"), "no X/Y is emitted when the offset is zero")
  raw_backend.clear(plain_offset_id)
  config.reset()
  config.setup({ terminal = { profile = "iterm2" }, image = { raw_cell_offset_px = { x = 10, y = 3 } } })
  reset_sequences()
  local offset_id = raw_backend.show(fake_png(), {
    row = 0,
    col = 0,
    width = 10,
    height = 10,
    exclusions = { { row = 2, col = 2, width = 4, height = 4 } },
  })
  local offset_output = output()
  t.eq("10", offset_output:match("X=(%d+)"), "a configured x offset reaches the placement command")
  t.eq("3", offset_output:match("Y=(%d+)"), "a configured y offset reaches the placement command")
  local _, offset_placements = offset_output:gsub("\27_Ga=p", "")
  local _, offset_keys = offset_output:gsub("X=%d+", "")
  t.eq(offset_placements, offset_keys, "every cropped region carries the offset, not only the first")
  raw_backend.clear(offset_id)
  config.reset()

  -- Placement lifecycle: upload-once, cropped placements, targeted
  -- deletion, and crop recomputation when exclusions change.
  reset_sequences()
  local raw_id = raw_backend.show(fake_png(), {
    row = 0,
    col = 0,
    width = 10,
    height = 10,
    exclusions = { { row = 2, col = 2, width = 4, height = 4 } },
  })
  local placed_output = output()
  t.ok(placed_output:find("a=t,f=100", 1, true), "raw image uploads independently of placements")
  local _, cropped_placements = placed_output:gsub("\27_Ga=p", "")
  t.eq(4, cropped_placements, "one passive overlay cuts the preview into four placements")

  reset_sequences()
  raw_backend.move(raw_id, { row = 0, col = 0, width = 10, height = 10, exclusions = {} })
  local moved_output = output()
  t.ok(moved_output:find("a=d,d=i", 1, true), "moving deletes only owned placement IDs")
  t.eq(false, moved_output:find("a=t,f=100", 1, true) ~= nil, "moving never re-uploads the already-owned image")
  local _, restored_placements = moved_output:gsub("\27_Ga=p", "")
  t.eq(1, restored_placements, "removing the overlay restores one full placement")

  -- Regression: a re-crop must never leave the terminal with nothing to
  -- composite, or the image visibly blinks and rolls for as long as the float
  -- that triggered it stays open. The replacement placement has to be written
  -- before the deletion it supersedes, and both in the same write.
  t.eq(1, #sequences, "a move is a single write, so no redraw can land mid-recrop")
  t.ok(
    moved_output:find("\27_Ga=p", 1, true) < moved_output:find("a=d,d=i", 1, true),
    "the new placement is sent before the placement it replaces is deleted"
  )
  raw_backend.clear(raw_id)

  -- Base64 chunking at the 4096-byte boundary: an upload whose encoded form
  -- lands exactly on two full chunks, and one that spills one chunk's worth
  -- of bytes into a third, tiny final chunk.
  reset_sequences()
  local exact_id = raw_backend.show(fake_png(6144 - 24), placement) -- base64(6144 bytes) == 8192 chars
  local exact_output = output()
  local _, exact_more_zero = exact_output:gsub("q=2,m=0", "")
  local _, exact_more_one = exact_output:gsub(",m=1", "")
  t.eq(1, exact_more_zero, "an exactly-two-chunk upload ends with a single terminating m=0 chunk")
  t.eq(1, exact_more_one, "an exactly-two-chunk upload has exactly one continuation chunk before it")
  raw_backend.clear(exact_id)

  reset_sequences()
  local remainder_id = raw_backend.show(fake_png(6147 - 24), placement) -- base64(6147 bytes) == 8196 chars
  local remainder_output = output()
  local _, remainder_more_zero = remainder_output:gsub("q=2,m=0", "")
  local _, remainder_more_one = remainder_output:gsub(",m=1", "")
  t.eq(1, remainder_more_zero, "a spillover upload still ends with a single terminating m=0 chunk")
  t.eq(2, remainder_more_one, "a spillover upload sends two full chunks before its tiny remainder")
  raw_backend.clear(remainder_id)

  -- Invalid PNGs are rejected outright rather than uploaded blind.
  local invalid_ok = pcall(raw_backend.show, "not a png", placement)
  t.eq(false, invalid_ok, "an invalid PNG payload is rejected")

  -- ---------------------------------------------------------------------
  -- Selection overlay.
  -- ---------------------------------------------------------------------
  local tint = { r = 220, g = 220, b = 220, a = 0.3 }

  -- Gating: profile flag under "auto", explicit on/off overrides.
  config.reset()
  config.setup({ terminal = { profile = "warp" } })
  local warp_supported, warp_reason = raw_backend.overlay_supported()
  t.eq(false, warp_supported, "an unvalidated profile refuses overlay placements")
  t.ok(warp_reason:match("not validated"), "the refusal names the profile gate")
  config.reset()
  config.setup({ terminal = { profile = "warp" }, interaction = { selection_overlay = "on" } })
  t.eq(true, (raw_backend.overlay_supported()), "selection_overlay=on forces the overlay past the profile")
  config.reset()
  config.setup({ terminal = { profile = "iterm2" }, interaction = { selection_overlay = "off" } })
  t.eq(false, (raw_backend.overlay_supported()), "selection_overlay=off wins over a validated profile")
  config.reset()
  config.setup({ terminal = { profile = "iterm2" } })
  t.eq(true, (raw_backend.overlay_supported()), "the iterm2 profile default enables the overlay")

  -- Sheet lifecycle: an apply without the sheet says need_sheet and sends
  -- nothing; supplying it uploads once and places crops.
  reset_sequences()
  local overlay_base = raw_backend.show(fake_png(), placement) -- 100x100 px over 10x10 cells
  t.eq(true, raw_backend.overlay_needs_sheet(overlay_base), "no tint sheet is uploaded yet")
  reset_sequences()
  local viewport = { widthPx = 100, heightPx = 100 }
  local rect = { x = 5.5, y = 7.25, width = 20, height = 10 }
  local no_sheet_set, no_sheet_reason =
    raw_backend.overlay_apply(nil, overlay_base, { rect }, viewport, tint, nil, placement)
  t.eq(nil, no_sheet_set, "without the sheet the apply refuses")
  t.eq("need_sheet", no_sheet_reason, "and reports the caller-actionable reason")
  t.eq(0, #sequences, "a refused apply must not write anything to the terminal")

  local set_id, stats = raw_backend.overlay_apply(nil, overlay_base, { rect }, viewport, tint, fake_png(), placement)
  t.ok(set_id ~= nil, "supplying the sheet makes the apply succeed: " .. tostring(stats))
  local overlay_output = output()
  t.ok(overlay_output:find("a=t,f=100", 1, true) ~= nil, "the tint sheet uploads as a direct PNG transmission")
  t.ok(overlay_output:find("x=0,y=0,w=20,h=10", 1, true) ~= nil, "the rect places as a crop of the sheet")
  t.eq(nil, overlay_output:match(",c=%d"), "overlay placements never use cell scaling (c/r)")
  t.eq("-1", overlay_output:match("w=20,h=10,z=(%-?%d+)"), "the overlay sits one layer above the -2 base, under text")
  t.ok(overlay_output:find(",X=6,Y=7", 1, true) ~= nil, "sub-cell offsets carry the rect's pixel remainder")
  t.eq(false, raw_backend.overlay_needs_sheet(overlay_base), "the sheet cache is warm after one upload")
  t.eq(1, stats.placed, "one rectangle placed")

  -- Diffing: an identical rect set writes nothing; a changed set emits the
  -- replacement before the deletion it supersedes, in one write.
  reset_sequences()
  local same_set, same_stats = raw_backend.overlay_apply(set_id, overlay_base, { rect }, viewport, tint, nil, placement)
  t.eq(set_id, same_set, "an unchanged rect set keeps its set id")
  t.eq(0, #sequences, "an unchanged rect set writes nothing at all")
  t.eq(1, same_stats.kept, "the placement is kept, not replaced")
  reset_sequences()
  local moved_set = raw_backend.overlay_apply(
    set_id,
    overlay_base,
    { { x = 30, y = 7.25, width = 20, height = 10 } },
    viewport,
    tint,
    nil,
    placement
  )
  t.eq(set_id, moved_set, "a changed rect set still keeps its set id")
  t.eq(1, #sequences, "a changed rect set is a single write")
  local moved_overlay = output()
  t.ok(
    moved_overlay:find("\27_Ga=p", 1, true) < moved_overlay:find("a=d,d=i", 1, true),
    "the new rectangle is emitted before the placement it supersedes is deleted"
  )

  -- Exclusions: a passive float's cut-out splits the rectangle, so the
  -- overlay never paints across a notification.
  local excluded_placement = {
    row = 0,
    col = 0,
    width = 10,
    height = 10,
    exclusions = { { row = 0, col = 3, width = 2, height = 2 } },
  }
  reset_sequences()
  raw_backend.overlay_apply(
    set_id,
    overlay_base,
    { { x = 0, y = 0, width = 100, height = 10 } },
    viewport,
    tint,
    nil,
    excluded_placement
  )
  local cut_output = output()
  local _, cut_placements = cut_output:gsub("\27_Ga=p", "")
  t.eq(2, cut_placements, "a rect crossing a passive-float cut-out splits into two placements")

  -- Calibration carry: the configured raw_cell_offset_px shifts the overlay
  -- exactly as it shifts the base, carrying into the next cell when the sum
  -- exceeds the cell.
  config.reset()
  config.setup({ terminal = { profile = "iterm2" }, image = { raw_cell_offset_px = { x = 8, y = 0 } } })
  reset_sequences()
  raw_backend.overlay_apply(set_id, overlay_base, { rect }, viewport, tint, nil, placement)
  local carry_output = output()
  t.ok(carry_output:find("\27%[1;2H") ~= nil, "an offset past the cell edge advances the cursor cell")
  t.ok(carry_output:find(",X=4,Y=7", 1, true) ~= nil, "and keeps the remainder as the sub-cell offset")
  config.reset()
  config.setup({ terminal = { profile = "iterm2" } })

  -- ---------------------------------------------------------------------
  -- The WezTerm encoding: no X/Y keys, the offset cropped out of the sheet's
  -- transparent margin instead.
  --
  -- WezTerm applies X/Y to every cell of a placement rather than the first,
  -- and applies it as an inset, so each cell paints cell-minus-X pixels wide.
  -- A 960px bar at X=3 was photographed as 60 separate 13px runs on both
  -- 20240203-110809-5046fc22 and 20260805-104032-4b1c3c15. Moving the offset
  -- into the image leaves nothing to inset, and it is still one placement per
  -- rectangle -- the splitting alternatives cost up to nine.
  -- ---------------------------------------------------------------------
  config.reset()
  config.setup({ terminal = { profile = "iterm2" } })
  stub_cell(10, 10)
  t.eq(nil, raw_backend.overlay_margin(), "profiles on the default encoding ask for no margin")
  config.reset()
  config.setup({ terminal = { profile = "wezterm" } })
  t.eq(false, (raw_backend.overlay_supported()), "wezterm refuses the overlay: the churn cost, not the geometry")
  config.reset()
  config.setup({ terminal = { profile = "wezterm" }, interaction = { selection_overlay = "on" } })
  local wez_margin = raw_backend.overlay_margin()
  t.eq(10, wez_margin.x, "the wezterm margin is one whole cell wide")
  t.eq(10, wez_margin.y, "and one whole cell tall")
  stub_cell(7.6, 16.4)
  t.eq(7, raw_backend.overlay_margin().x, "a fractional cell floors: the margin must be a whole pixel count")
  t.eq(16, raw_backend.overlay_margin().y, "in both axes")
  stub_cell(10, 10)

  raw_backend.clear_all()
  reset_sequences()
  local wez_base = raw_backend.show(fake_png(), placement) -- 100x100 px over 10x10 cells
  -- The sheet has to cover the margin as well as the drawn box, so the 100x100
  -- sheet every other profile accepts here is refused.
  t.eq(true, raw_backend.overlay_needs_sheet(wez_base, tint, placement), "wezterm needs a sheet of its own")
  local small_ok, small_why = raw_backend.overlay_apply(nil, wez_base, { rect }, viewport, tint, fake_png(), placement)
  t.eq(nil, small_ok, "a sheet with no room for the margin is refused")
  t.ok(small_why:match("must cover"), "and says what it failed to cover: " .. tostring(small_why))

  reset_sequences()
  local wez_set = raw_backend.overlay_apply(nil, wez_base, { rect }, viewport, tint, big_sheet, placement)
  t.ok(wez_set ~= nil, "a sheet that covers the margin is accepted")
  local wez_output = output()
  -- The same rect the golden session places at X=6,Y=7 on every other profile.
  -- Here: cursor to the same cell, no X/Y at all, and the crop starts
  -- (cell - offset) into the margin and is (offset + size) long.
  t.eq(nil, wez_output:match("X=%d+"), "no sub-cell X key is sent to wezterm")
  t.eq(nil, wez_output:match("Y=%d+"), "and no Y key either -- that is the whole point")
  t.ok(
    wez_output:find("x=4,y=3,w=26,h=17", 1, true) ~= nil,
    "the offset moves into the crop: x=cell-6, y=cell-7, w=6+20, h=7+10 -- " .. wez_output:gsub("%c", "."):sub(1, 300)
  )
  t.ok(wez_output:find("\27[1;1H", 1, true) ~= nil, "and the placement still sits at the rectangle's own cell")

  -- A rectangle already on a cell boundary still crops the full margin away,
  -- so the first tinted pixel is the first pixel of the cell.
  reset_sequences()
  raw_backend.overlay_apply(
    wez_set,
    wez_base,
    { { x = 20, y = 30, width = 15, height = 12 } },
    viewport,
    tint,
    nil,
    placement
  )
  t.ok(
    output():find("x=10,y=10,w=15,h=12", 1, true) ~= nil,
    "a cell-aligned rect crops past the whole margin: " .. output():gsub("%c", "."):sub(1, 200)
  )

  -- The two encodings are not interchangeable, and neither are their sheets:
  -- cropping a marginless sheet with margin arithmetic would shift every
  -- rectangle by up to a cell.
  local wez_sheet_id = tonumber(wez_output:match("a=p,q=2,C=1,i=(%d+),p=%d+,x=%d+,y=%d+,w=%d+,h=%d+,z="))
  config.reset()
  config.setup({ terminal = { profile = "iterm2" } })
  t.eq(
    true,
    raw_backend.overlay_needs_sheet(wez_base, tint, placement),
    "the margined sheet cannot serve a profile that crops from zero"
  )
  reset_sequences()
  raw_backend.overlay_apply(nil, wez_base, { rect }, viewport, tint, big_sheet, placement)
  local plain_sheet_id = tonumber(output():match("a=t,f=100,t=d,q=2,i=(%d+)"))
  t.ok(plain_sheet_id ~= nil and plain_sheet_id ~= wez_sheet_id, "so a second sheet is uploaded for the other encoding")
  t.ok(output():find(",X=6,Y=7", 1, true) ~= nil, "and that profile still gets the sub-cell keys it was validated with")
  raw_backend.clear_all()
  config.reset()
  config.setup({ terminal = { profile = "iterm2" } })
  stub_cell(10, 10)
  reset_sequences()
  overlay_base = raw_backend.show(fake_png(), placement)
  set_id = raw_backend.overlay_apply(nil, overlay_base, { rect }, viewport, tint, fake_png(), placement)

  -- Deletion: clearing the set removes every placement; clear_all also frees
  -- the sheet.
  local healthy = raw_backend.health()
  t.eq(1, healthy.overlay_sets, "one overlay set is live")
  t.ok(healthy.overlay_placements >= 1, "with at least one placement")
  t.eq(1, healthy.overlay_sheets, "one tint sheet is cached")
  reset_sequences()
  t.eq(true, raw_backend.overlay_clear(set_id), "clearing an owned set succeeds")
  t.ok(output():find("a=d,d=i", 1, true) ~= nil, "clearing deletes the placements")
  t.eq(0, raw_backend.health().overlay_sets, "no sets remain after clear")
  t.eq(1, raw_backend.health().overlay_sheets, "the sheet survives for the next gesture")
  raw_backend.clear(overlay_base)
  reset_sequences()
  raw_backend.clear_all()
  t.ok(output():find("a=d,d=I", 1, true) ~= nil, "clear_all frees the sheet image")
  t.eq(0, raw_backend.health().overlay_sheets, "no sheets survive clear_all")

  -- ---------------------------------------------------------------------
  -- The tint sheet outranks every base image by id, for as long as the
  -- session lasts.
  --
  -- This is the 2026-08-08 Ghostty defect. The two layers are kept apart by
  -- resolve_layers above, but the protocol's own tie-break is by image id --
  -- "the image with the lower id is considered to have the lower z-index" --
  -- and sheets used to be allocated from the same counter as base frames. The
  -- sheet therefore outranked the base for exactly one drag, and the first
  -- settle capture after it took the lead back permanently: one instant
  -- highlight per session, then the overlay drawn underneath every later one,
  -- with every placement still reported as accepted.
  -- ---------------------------------------------------------------------
  config.reset()
  config.setup({ terminal = { profile = "ghostty" } })
  reset_sequences()
  local id_base = raw_backend.show(fake_png(), placement)
  raw_backend.overlay_apply(nil, id_base, { rect }, viewport, tint, fake_png(), placement)
  -- The base carries c/r, the overlay crop does not, so "h=<n>,z=" is the
  -- shape only an overlay placement has.
  local sheet_id = tonumber(output():match("a=p,q=2,C=1,i=(%d+),p=%d+,x=0,y=0,w=%d+,h=%d+,z="))
  t.ok(sheet_id ~= nil, "the overlay placement names the sheet it crops")
  t.ok(sheet_id > id_base, "the sheet starts above the base image it composites over")
  local rolling, highest_base = id_base, id_base
  for _ = 1, 50 do
    rolling = raw_backend.update(rolling, fake_png(), placement)
    highest_base = math.max(highest_base, rolling)
  end
  t.ok(sheet_id > highest_base, "and stays above it however many full frames are re-uploaded")
  raw_backend.clear(rolling)
  raw_backend.clear_all()
  config.reset()

  -- ---------------------------------------------------------------------
  -- Rectangles are sized in the pixels the base image is DRAWN at, not the
  -- pixels it was CAPTURED at.
  --
  -- This is the 2026-08-08 defect. The base is placed with c/r, so the
  -- terminal scales it to fill placement.width x placement.height cells;
  -- overlay crops carry no c/r and display at natural pixel size. When the
  -- render viewport mis-estimated the cell -- 10x20 CSS px guessed against a
  -- real 7x16 -- the capture is drawn smaller than it was taken, and a
  -- rectangle sized against the capture comes out too big while still sitting
  -- at the right place. Every number below differs from the capture-relative
  -- answer, which is the point.
  -- ---------------------------------------------------------------------
  config.reset()
  config.setup({ terminal = { profile = "iterm2" } })
  stub_cell(7, 16) -- real cell; the 100x100 capture over 10x10 cells implies 10x10
  reset_sequences()
  local drawn_base = raw_backend.show(fake_png(), placement) -- 100x100 px over 10x10 cells
  -- Drawn box is 10*7 x 10*16 = 70x160. The sheet must cover the taller of the
  -- two boxes (160 > 100), so a sheet sized only to the capture is refused.
  t.eq(
    true,
    raw_backend.overlay_needs_sheet(drawn_base, nil, placement),
    "a sheet must cover the drawn box, not just the capture"
  )
  local small_sheet_set, small_sheet_reason = raw_backend.overlay_apply(
    nil,
    drawn_base,
    { { x = 0, y = 0, width = 10, height = 10 } },
    {
      widthPx = 100,
      heightPx = 100,
    },
    tint,
    fake_png(),
    placement
  )
  t.eq(nil, small_sheet_set, "a sheet smaller than the drawn box is refused")
  t.ok(small_sheet_reason:match("must cover"), "and says what it failed to cover: " .. tostring(small_sheet_reason))

  -- 200x200 sheet covers both boxes. A rect at CSS (10,10) sized 20x25 in a
  -- 100x100 viewport scales by 70/100 and 160/100:
  --   x: 10*0.7 = 7        w: round(30*0.7) - 7 = 21 - 7 = 14
  --   y: 10*1.6 = 16       h: round(35*1.6) - 16 = 56 - 16 = 40
  -- The capture-relative arithmetic would have said 20x25 at (10,10).
  reset_sequences()
  local drawn_set = raw_backend.overlay_apply(
    nil,
    drawn_base,
    { { x = 10, y = 10, width = 20, height = 25 } },
    { widthPx = 100, heightPx = 100 },
    tint,
    big_sheet,
    placement
  )
  t.ok(drawn_set ~= nil, "the apply succeeds once the sheet covers the drawn box")
  local drawn_output = output()
  t.ok(
    drawn_output:find("x=0,y=0,w=14,h=40", 1, true) ~= nil,
    "the crop is sized in drawn pixels, not captured pixels: " .. drawn_output:gsub("%c", "."):sub(1, 400)
  )
  -- Position stays exact either way, because cells are: x=7 is cell 1 + 0 px
  -- (cell is 7 wide), y=16 is cell 1 + 0 px (cell is 16 tall).
  t.eq(nil, drawn_output:match(",X=%d"), "a rect landing on a cell boundary needs no sub-cell offset")
  raw_backend.clear_all()

  -- ---------------------------------------------------------------------
  -- Upstream WezTerm issue #6344: no placement may divide by zero.
  --
  -- `assign_image_to_cells` (term/src/terminalstate/image.rs) has two integer
  -- divisions, one on each branch, and md-viewer's two kinds of placement
  -- reach one each:
  --
  --   * without c/r -- every overlay rectangle -- it divides by
  --     `cell_pixel_width` / `cell_pixel_height`, which is the pty's pixel
  --     geometry over the grid;
  --   * with c/r -- every base frame -- it divides by
  --     `draw_width = min(w, image_width - x)`.
  --
  -- On 20240203-110809-5046fc22, before upstream added its own guards, either
  -- zero is a Rust panic that takes the whole application down. These
  -- assertions are what makes that unreachable from md-viewer's side, so the
  -- February 2024 stable can stay a support target.
  -- ---------------------------------------------------------------------

  -- The two preconditions, asserted directly. Nothing the arithmetic above can
  -- produce violates either -- that is the point of them -- so driving them
  -- through the public API alone proves nothing about whether they work.
  local precondition = raw_backend._preconditions
  t.eq(true, precondition.cell_is_placeable({ width = 1, height = 1 }), "a 1x1 px cell is placeable")
  t.eq(true, precondition.cell_is_placeable({ width = 7.6, height = 16.4 }), "a fractional cell floors to placeable")
  t.eq(false, precondition.cell_is_placeable({ width = 0.9, height = 16 }), "a cell under 1px wide is not placeable")
  t.eq(false, precondition.cell_is_placeable({ width = 16, height = 0 }), "a zero-height cell is not placeable")
  t.eq(false, precondition.cell_is_placeable(nil), "an absent cell is not placeable")

  t.eq(20, (precondition.crop_within(100, 100, 0, 0, 20, 10)), "an interior crop passes through unchanged")
  t.eq(100, (precondition.crop_within(100, 100, 0, 0, 100, 100)), "a crop filling the image exactly is allowed")
  t.eq(1, (precondition.crop_within(100, 100, 99, 99, 1, 1)), "a single pixel at the far corner is allowed")
  t.eq(nil, precondition.crop_within(100, 100, 0, 0, 101, 10), "a crop wider than the image is refused, not clamped")
  t.eq(nil, precondition.crop_within(100, 100, 0, 0, 10, 101), "a crop taller than the image is refused")
  t.eq(nil, precondition.crop_within(100, 100, 95, 0, 10, 10), "a crop running off the right edge is refused")
  t.eq(nil, precondition.crop_within(100, 100, 100, 0, 1, 1), "a crop starting at the right edge is refused")
  t.eq(nil, precondition.crop_within(100, 100, 0, 0, 0, 10), "a zero-width crop is refused (#6344's own title case)")
  t.eq(nil, precondition.crop_within(100, 100, 0, 0, 10, 0), "a zero-height crop is refused")
  t.eq(nil, precondition.crop_within(0, 0, 0, 0, 1, 1), "nothing can be cropped out of a zero-sized image")
  t.eq(nil, precondition.crop_within(100, 100, -1, 0, 10, 10), "a negative origin is refused")

  -- A PNG header may declare 0x0, and `0` is truthy in Lua -- so a zero
  -- dimension used to sail past every `if not width` check in this file and
  -- produce a c/r placement cropping a region out of an image with no pixels
  -- in it, which is `draw_width == 0`: the WezTerm panic itself.
  local zero_png = "\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\0\0\0\0\0\0"
  t.eq(false, pcall(raw_backend.show, zero_png, placement), "a PNG declaring 0x0 is rejected outright")

  ---Every `a=p` placement in an output blob, as its numeric keys.
  local function placements_in(text)
    local found = {}
    for control in text:gmatch("\27_G(a=p[^;]*);") do
      local keys = {}
      for key, value in control:gmatch("([%a])=(%-?%d+)") do
        keys[key] = tonumber(value)
      end
      found[#found + 1] = keys
    end
    return found
  end

  ---Assert #6344's preconditions against every placement in `text`, given the
  ---pixel dimensions of each image id it may reference.
  local function assert_placeable(text, dims, label)
    local found = placements_in(text)
    t.ok(#found > 0, ("%s emitted at least one placement to check"):format(label))
    for index, keys in ipairs(found) do
      local image = dims[keys.i]
      local where = ("%s placement %d (i=%s)"):format(label, index, tostring(keys.i))
      t.ok(image ~= nil, where .. " names a known image")
      if image then
        t.ok((keys.w or 0) >= 1 and (keys.h or 0) >= 1, where .. " has a non-zero crop size")
        t.ok(
          (keys.x or 0) >= 0 and (keys.x or 0) + keys.w <= image.width,
          ("%s crops inside the image horizontally (x=%d w=%d, image %d wide)"):format(
            where,
            keys.x or 0,
            keys.w or 0,
            image.width
          )
        )
        t.ok(
          (keys.y or 0) >= 0 and (keys.y or 0) + keys.h <= image.height,
          ("%s crops inside the image vertically (y=%d h=%d, image %d tall)"):format(
            where,
            keys.y or 0,
            keys.h or 0,
            image.height
          )
        )
      end
      if keys.c or keys.r then t.ok((keys.c or 0) >= 1 and (keys.r or 0) >= 1, where .. " spans at least one cell") end
    end
    return #found
  end

  config.reset()
  config.setup({ terminal = { profile = "iterm2" } })
  stub_cell(7, 16) -- a cell the 100x100-over-10x10 capture does NOT imply
  reset_sequences()
  local guard_base = raw_backend.show(fake_png(), {
    row = 0,
    col = 0,
    width = 10,
    height = 10,
    exclusions = { { row = 3, col = 3, width = 3, height = 3 } },
  })
  local guard_sheet_png = "\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\0\200\0\0\0\200"
  local guard_dims = { [guard_base] = { width = 100, height = 100 } }
  raw_backend.overlay_apply(
    nil,
    guard_base,
    { { x = 0, y = 0, width = 100, height = 100 } },
    { widthPx = 100, heightPx = 100 },
    tint,
    guard_sheet_png,
    { row = 0, col = 0, width = 10, height = 10 }
  )
  -- The sheet's own id, taken from the placement that crops it: "no c/r" is the
  -- shape only an overlay placement has, so this cannot pick up the base upload.
  local guard_sheet_id = tonumber(output():match("a=p,q=2,C=1,i=(%d+),p=%d+,x=0,y=0,w=%d+,h=%d+,z="))
  guard_dims[guard_sheet_id] = { width = 200, height = 200 }
  -- Rectangles that run off every edge of the drawn box, at the maximum
  -- sub-cell offset, plus one that covers it entirely.
  raw_backend.overlay_apply(
    nil,
    guard_base,
    {
      { x = -50, y = -50, width = 200, height = 200 },
      { x = 99, y = 99, width = 100, height = 100 },
      { x = 6, y = 15, width = 1, height = 1 },
      { x = 0, y = 0, width = 1000, height = 1000 },
    },
    { widthPx = 100, heightPx = 100 },
    tint,
    nil,
    { row = 0, col = 0, width = 10, height = 10, exclusions = { { row = 2, col = 2, width = 2, height = 2 } } }
  )
  raw_backend.move(guard_base, { row = 0, col = 0, width = 10, height = 10, exclusions = {} })
  assert_placeable(output(), guard_dims, "#6344 sweep")

  -- Degenerate geometry never reaches the wire at all. `w=0`/`h=0` is the
  -- literal trigger named in the upstream issue title ("zero-height kitty
  -- graphic"); NaN is worse, because it compares false against everything and
  -- would slip past an ordinary `x1 > x0` guard.
  local nan = 0 / 0
  for _, bad in ipairs({
    { label = "zero width", rect = { x = 10, y = 10, width = 0, height = 20 } },
    { label = "zero height", rect = { x = 10, y = 10, width = 20, height = 0 } },
    { label = "negative width", rect = { x = 10, y = 10, width = -20, height = 20 } },
    { label = "NaN x", rect = { x = nan, y = 10, width = 20, height = 20 } },
    { label = "NaN width", rect = { x = 10, y = 10, width = nan, height = 20 } },
    { label = "infinite height", rect = { x = 10, y = 10, width = 20, height = math.huge } },
    { label = "sub-pixel sliver", rect = { x = 10.1, y = 10.1, width = 0.2, height = 0.2 } },
  }) do
    reset_sequences()
    raw_backend.overlay_apply(
      nil,
      guard_base,
      { bad.rect },
      { widthPx = 100, heightPx = 100 },
      tint,
      nil,
      { row = 0, col = 0, width = 10, height = 10 }
    )
    t.eq(0, #placements_in(output()), ("a %s rect emits no placement at all"):format(bad.label))
  end

  -- A cell that floors to zero pixels is the divisor on the no-c/r branch, so
  -- it is refused for the same reason an unmeasurable cell is -- and "on"
  -- cannot force it, because this is a safety precondition and not a
  -- capability judgement.
  stub_cell(0.5, 0.5)
  local floor_ok, floor_reason = raw_backend.overlay_supported()
  t.eq(false, floor_ok, "a cell that floors to zero pixels disables the overlay")
  t.ok(floor_reason:match("floors to 0x0"), "and the refusal names the floored cell: " .. tostring(floor_reason))
  config.reset()
  config.setup({ terminal = { profile = "iterm2" }, interaction = { selection_overlay = "on" } })
  t.eq(false, (raw_backend.overlay_supported()), "selection_overlay=on cannot force a cell that floors to zero")
  stub_cell(1, 1)
  t.eq(true, (raw_backend.overlay_supported()), "a cell that floors to exactly one pixel is placeable")
  stub_cell(10, 10)
  raw_backend.clear_all()

  -- Deletions come out in a defined order. They are independent of each other
  -- -- distinct placement ids, one write -- so no terminal can tell the orders
  -- apart, but `pairs` over a hash table has no defined order and was seen to
  -- reorder between two builds that differed nowhere near it. That makes the
  -- emitted stream unassertable, which is why this is pinned: the three rects
  -- below are emitted in an order their sorted rect keys deliberately reverse.
  config.reset()
  config.setup({ terminal = { profile = "iterm2" } })
  stub_cell(10, 10)
  raw_backend.clear_all()
  reset_sequences()
  local ordered_base = raw_backend.show(fake_png(), placement)
  local ordered_set = raw_backend.overlay_apply(nil, ordered_base, {
    { x = 90, y = 0, width = 10, height = 10 },
    { x = 10, y = 0, width = 10, height = 10 },
    { x = 50, y = 0, width = 10, height = 10 },
  }, viewport, tint, fake_png(), placement)
  local emitted = {}
  for pid in output():gmatch("a=p,q=2,C=1,i=%d+,p=(%d+),x=0,y=0,w=%d+,h=%d+,z=") do
    emitted[#emitted + 1] = pid
  end
  t.eq(3, #emitted, "three overlay rectangles were placed")
  reset_sequences()
  raw_backend.overlay_clear(ordered_set)
  local deleted = {}
  for pid in output():gmatch("a=d,d=i,q=2,i=%d+,p=(%d+)") do
    deleted[#deleted + 1] = pid
  end
  -- Emitted x=90, x=10, x=50 -> keys "90:...", "10:...", "50:...", which sort
  -- to 10, 50, 90: the second, third and first placements, in that order.
  t.eq(
    table.concat({ emitted[2], emitted[3], emitted[1] }, ","),
    table.concat(deleted, ","),
    "deletions are emitted in rect-key order, not hash order"
  )
  raw_backend.clear_all()

  -- ---------------------------------------------------------------------
  -- Byte identity for the three operator-validated terminals.
  --
  -- The #6344 guards above must not change one byte of what iTerm2, Ghostty
  -- and Kitty receive -- they were each validated by hand against the exact
  -- output of this path. A representative session is pinned below with only
  -- the two id counters normalized to their order of first appearance; those
  -- advance across the whole test file and are the only run-dependent part of
  -- the stream. Anything else -- key order, crop arithmetic, cursor framing,
  -- base64 chunking, the place-before-delete ordering -- fails this on all
  -- three profiles at once.
  -- ---------------------------------------------------------------------
  local function normalize_ids(text)
    local seen, counts = {}, {}
    local function tag(prefix, value)
      local key = prefix .. value
      if not seen[key] then
        seen[key] = ("%s<%d>"):format(prefix, counts[prefix] or 0)
        counts[prefix] = (counts[prefix] or 0) + 1
      end
      return seen[key]
    end
    text = text:gsub("(i=)(%d+)", function(prefix, value) return tag(prefix, value) end)
    text = text:gsub("(p=)(%d+)", function(prefix, value) return tag(prefix, value) end)
    return (text:gsub("\27", "<ESC>"))
  end

  ---One fixed session, byte for byte: an upload cropped around a passive
  ---float, a first overlay frame that has to upload the sheet, a second that
  ---diffs against it, a re-crop, then teardown.
  local function golden_session()
    reset_sequences()
    local golden_placement = {
      row = 4,
      col = 2,
      width = 10,
      height = 10,
      exclusions = { { row = 6, col = 5, width = 3, height = 2 } },
    }
    local base = raw_backend.show(fake_png(), golden_placement)
    local set = raw_backend.overlay_apply(
      nil,
      base,
      { { x = 5.5, y = 7.25, width = 20, height = 10 }, { x = 40, y = 60, width = 33, height = 12 } },
      { widthPx = 100, heightPx = 100 },
      tint,
      fake_png(),
      golden_placement
    )
    raw_backend.overlay_apply(
      set,
      base,
      { { x = 5.5, y = 7.25, width = 20, height = 10 }, { x = 41, y = 60, width = 33, height = 12 } },
      { widthPx = 100, heightPx = 100 },
      tint,
      nil,
      golden_placement
    )
    raw_backend.move(base, { row = 4, col = 2, width = 10, height = 10, exclusions = {} })
    raw_backend.overlay_clear(set)
    raw_backend.clear(base)
    local text = normalize_ids(output())
    raw_backend.clear_all()
    return text
  end

  local golden = {}
  for _, profile in ipairs({ "iterm2", "ghostty", "kitty" }) do
    config.reset()
    config.setup({ terminal = { profile = profile } })
    stub_cell(10, 10)
    golden[profile] = golden_session()
  end
  t.eq(golden.iterm2, golden.ghostty, "iTerm2 and Ghostty receive identical bytes")
  t.eq(golden.iterm2, golden.kitty, "iTerm2 and Kitty receive identical bytes")
  if os.getenv("MD_VIEWER_DUMP_GOLDEN") then io.write("GOLDEN>>>" .. golden.iterm2 .. "<<<GOLDEN\n") end
  t.eq(GOLDEN_VALIDATED_STREAM, golden.iterm2, "the validated terminals' byte stream is unchanged")

  -- Without a measured cell there is no way to know what a pixel is worth on
  -- screen, so the overlay refuses -- and "on" cannot override a correctness
  -- precondition the way it overrides a capability judgement.
  config.reset()
  config.setup({ terminal = { profile = "iterm2" } })
  stub_cell(nil)
  config.reset()
  config.setup({ terminal = { profile = "iterm2" } })
  local blind_ok, blind_reason = raw_backend.overlay_supported()
  t.eq(false, blind_ok, "an unmeasurable cell disables the overlay on a validated profile")
  t.ok(blind_reason:match("pixel cell size is unknown"), "and says why: " .. tostring(blind_reason))
  config.reset()
  config.setup({ terminal = { profile = "iterm2" }, interaction = { selection_overlay = "on" } })
  t.eq(false, (raw_backend.overlay_supported()), "selection_overlay=on cannot force it without a measured cell")
  t.ok(raw_backend.health().cell_pixels:match("unmeasured"), "health reports the cell as unmeasured")

  cellpixels.measure = real_measure
  vim.api.nvim_ui_send = original_ui_send
  config.reset()
end
