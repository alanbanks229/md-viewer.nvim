return function(t)
  local state = require("md-viewer.state")
  local first = state.create(101, 201)
  local second = state.create(102, 202)
  t.eq(first, state.get(101), "first buffer state")
  t.eq(second, state.get(102), "second buffer state")
  state.remove(101)
  state.remove(102)
  t.eq(nil, state.get(101), "buffer state cleanup")

  -- "Is there a screen on this pane" is not "does this session own a frame id".
  -- The resident model draws one or two cropped bands and deliberately owns no
  -- `image_id`, because that field is also what `clear_image` deletes and
  -- `apply_image` updates in place -- neither of which a chunk may ever be.
  t.eq(false, state.screen_up(nil), "no session, no screen")
  t.eq(false, state.screen_up({}), "a session that has drawn nothing has no screen")
  t.eq(true, state.screen_up({ image_id = 7 }), "the viewport model's frame is a screen")
  t.eq(true, state.screen_up({ resident_screen = true }), "and so are resident bands, which have no frame id")
  t.eq(false, state.screen_up({ resident_screen = false }), "bands that are not placed are not a screen")
end
