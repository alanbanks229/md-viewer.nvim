return function(t)
  local caret = require("md-viewer.caret")
  local config = require("md-viewer.config")
  local coords = require("md-viewer.coordinates")
  local interaction = require("md-viewer.interaction")
  local navigation = require("md-viewer.navigation")
  local preview = require("md-viewer.preview")
  local process = require("md-viewer.process")

  config.reset()
  require("md-viewer").setup({ image = { backend = "cells" } })
  local controller = require("md-viewer.controller")

  local entry_win = vim.api.nvim_get_current_win()
  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# One", "", "body", "", "more" })
  local session = assert(controller.open("right"))

  -- The caret exists only on a graphical backend: `cells` writes real document
  -- text into the preview buffer, and a caret over that would be addressing
  -- text rather than an image.
  session.backend = { name = "kitty_raw" }
  preview.reset_surface(session)
  session.renderer_revision = "1:0"
  session.viewport_width_px = 800
  session.viewport_height_render_px = 600
  session.viewport_height_px = 600
  session.document_height_px = 10000
  session.scroll_y = 0
  session.applied_scroll_y = 0
  session.last_placement = preview.placement(session.preview_win, "kitty_raw")

  local original_schedule_scroll = controller.schedule_scroll
  controller.schedule_scroll = function() end

  ---Stand in for the renderer. Records what was asked and answers with a glyph
  ---box, which is the shape `caret_move` really returns -- a *rectangle*, not a
  ---point, because the caret is drawn the size of the character it sits on.
  local requests = {}
  local reply = { x = 100, y = 200, width = 9, height = 18 }
  local original_request = process.request
  process.request = function(_, params, callback)
    -- Encode every request the way the real transport does. A stub that only
    -- records the table proves nothing about whether it can be sent: `$` once
    -- parked the sticky column at `math.huge`, which every assertion here was
    -- happy with and which `protocol.encode` refuses outright -- surfacing as a
    -- traceback in the reader's face on the next `j`.
    local encodable = pcall(require("md-viewer.protocol").encode, params)
    t.ok(encodable, "interact request is JSON-encodable: " .. tostring(params.action))
    requests[#requests + 1] = params
    if callback then
      callback({
        kind = "caret",
        ok = true,
        index = reply.index,
        rect = { x = reply.x, y = reply.y, width = reply.width, height = reply.height },
        selectionTint = { r = 230, g = 230, b = 230, a = 0.62 },
      }, nil)
    end
  end

  local function feed(keys) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false) end

  -- ---------------------------------------------------------------------
  -- The caret is a glyph box, not a cell. This is the correction the first
  -- attempt needed: a fixed-size terminal cursor could sit in the page margin
  -- or in the blank space beside a short heading, addressing nothing and drawn
  -- at a size with no relationship to the text under it.
  -- ---------------------------------------------------------------------
  do
    caret.forget(session)
    t.eq(nil, caret.rect(session), "there is no caret before one has been placed")
    t.eq(nil, caret.point(session), "and so no point to resolve from")

    caret.set_rect(session, { x = 40, y = 60, width = 19, height = 38 }, 0)
    local rect = caret.rect(session)
    t.eq(40, rect.x, "the caret keeps the box it was given")
    t.eq(38, rect.height, "including the glyph's own height -- an h1 is taller than body text")
    local point = caret.point(session)
    t.eq(40 + 19 / 2, point.x, "and resolves from the middle of that glyph")
    t.eq(60 + 38 / 2, point.y, "and resolves from the middle of that glyph")
  end

  -- ---------------------------------------------------------------------
  -- Scrolling re-places the caret locally. The box is stored against the
  -- scroll it was measured at, so an ordinary scroll costs no round trip --
  -- and a caret scrolled off screen is simply not drawn.
  -- ---------------------------------------------------------------------
  do
    caret.set_rect(session, { x = 40, y = 300, width = 9, height = 18 }, 0)
    session.applied_scroll_y = 100
    t.eq(200, caret.rect(session).y, "a scroll moves the caret's box against it, with no request")
    session.applied_scroll_y = 400
    t.eq(nil, caret.rect(session), "a caret scrolled above the viewport is not drawn")
    session.applied_scroll_y = -400
    t.eq(nil, caret.rect(session), "nor one scrolled below it")
    session.applied_scroll_y = 0
    t.eq(300, caret.rect(session).y, "and it comes back when it scrolls back into view")
  end

  -- ---------------------------------------------------------------------
  -- With no caret yet, a motion starts from the top-left of the image, which
  -- the renderer's "none" granularity snaps onto the first real character.
  -- ---------------------------------------------------------------------
  do
    caret.forget(session)
    local origin = caret.origin(session)
    t.ok(origin ~= nil, "a motion can still start before the caret has been placed")
    local expected = coords.cell_to_css(
      { screenrow = session.last_placement.row + 1, screencol = session.last_placement.col + 1 },
      session.last_placement,
      { widthPx = 800, heightPx = 600 }
    )
    t.eq(expected.x, origin.x, "from the first cell of the image")
    t.eq(expected.y, origin.y, "from the first cell of the image")
  end

  -- ---------------------------------------------------------------------
  -- Motions are renderer round trips, and the mappings say what they mean.
  -- ---------------------------------------------------------------------
  do
    navigation.attach(session, controller.navigate)
    vim.api.nvim_set_current_win(session.preview_win)

    local function last_request(keys)
      requests = {}
      feed(keys)
      return requests[#requests]
    end

    local motions = {
      { "l", "character", "forward", 1 },
      { "h", "character", "backward", 1 },
      { "j", "line", "forward", 1 },
      { "k", "line", "backward", 1 },
      { "3j", "line", "forward", 3 },
      { "10l", "character", "forward", 10 },
      { "w", "word", "forward", 1 },
      { "b", "word", "backward", 1 },
      { "e", "word_end", "forward", 1 },
      { "}", "block", "forward", 1 },
      { "{", "block", "backward", 1 },
      { "gg", "document", "backward", 1 },
      { "G", "document", "forward", 1 },
    }
    for _, motion in ipairs(motions) do
      local keys, granularity, direction, count = motion[1], motion[2], motion[3], motion[4]
      local request = last_request(keys)
      t.eq("caret_move", request and request.action, keys .. " asks the renderer to move the caret")
      t.eq(granularity, request and request.granularity, keys .. " granularity")
      t.eq(direction, request and request.direction, keys .. " direction")
      t.eq(count, request and request.count, keys .. " count")
    end

    -- Half- and full-page motions are line motions with a count, which is what
    -- Vim does with them -- so the caret leads the scroll instead of being left
    -- behind by it.
    local half = last_request("<C-d>")
    t.eq("line", half.granularity, "<C-d> is a line motion")
    t.eq("forward", half.direction, "downward")
    t.ok(half.count > 1, "by a viewport's worth of lines, not one")
    local page = last_request("<C-f>")
    t.ok(page.count > half.count, "and a full page is more than half a page")

    -- The renderer's answer becomes the caret.
    reply = { x = 321, y = 123, width = 11, height = 28 }
    feed("w")
    local rect = caret.rect(session)
    t.eq(321, rect.x, "the caret lands where the renderer put it")
    t.eq(28, rect.height, "with that glyph's height")

    for _, motion in ipairs({ { "0", "backward" }, { "$", "forward" } }) do
      local request = last_request(motion[1])
      t.eq("lineboundary", request.granularity, motion[1] .. " is a line-boundary motion")
      t.eq(motion[2], request.direction, motion[1] .. " direction")
    end
  end

  -- ---------------------------------------------------------------------
  -- A motion carries *which character* the caret is on, not just where its box
  -- was drawn.
  --
  -- Asking the renderer to find the caret again from its own glyph centre does
  -- not work, and this is the fix for it: a point resolves to the nearest
  -- boundary *between* two characters, and a glyph's middle is equidistant from
  -- the boundaries either side of it. On the glyphs where that tie broke
  -- rightward the renderer decided the caret was one character further on than
  -- it was drawn -- so `h` stepped back onto the glyph it started on and the
  -- caret never moved again, and `l` skipped one.
  -- ---------------------------------------------------------------------
  do
    local function last_request(keys)
      requests = {}
      feed(keys)
      return requests[#requests]
    end
    local function last_after(fn)
      requests = {}
      fn()
      return requests[#requests]
    end

    reply = { x = 321, y = 123, width = 11, height = 28, index = 57 }
    feed("l")
    t.eq(57, caret.index(session), "the caret remembers which character the renderer put it on")
    t.eq(57, last_request("l").caretIndex, "and the next motion resumes from it rather than from a point")
    t.eq(57, last_request("j").caretIndex, "every motion does, not only the character ones")

    -- "none" is the snap-only granularity -- "put the caret on the character
    -- nearest this point" -- which is how a caret is first placed and how a
    -- click re-places it. An index would defeat exactly that.
    local snap = last_after(function() interaction.caret_motion(session, "none", "forward", 1) end)
    t.eq("none", snap.granularity, "a snap is a motion with no granularity")
    t.eq(nil, snap.caretIndex, "and resolves its point, never the index it came from")

    -- A click likewise: it has a point, and the point is the whole answer.
    local clicked = last_after(function() interaction.caret_from_click(session, { x = 120, y = 240 }) end)
    t.eq(120, clicked.coordinates.x, "a click resolves where the reader pressed")
    t.eq(nil, clicked.caretIndex, "not wherever the caret happened to be")

    -- Re-rendering renumbers the renderer's character space, so an index taken
    -- from the document before it names a different character, or none at all.
    feed("l")
    t.eq(57, caret.index(session), "the index is live again after a motion")
    session.renderer_revision = "2:0"
    t.eq(nil, caret.index(session), "a re-render invalidates it")
    t.eq(nil, last_request("l").caretIndex, "so the next motion falls back to its point")

    session.renderer_revision = "1:0"
    reply = { x = 321, y = 123, width = 11, height = 28 }
    feed("l")
    t.eq(nil, caret.index(session), "and an answer with no index leaves none behind")

    -- Zero is the document's first character, not "no index". Cheap to assert
    -- and worth asserting: the same shape written in JavaScript, or behind a
    -- `type()` check, silently drops it.
    reply = { x = 26, y = 10, width = 11, height = 28, index = 0 }
    feed("h")
    t.eq(0, caret.index(session), "the first character of the document is a real position")
    t.eq(0, last_request("h").caretIndex, "and is sent as one")
  end

  -- ---------------------------------------------------------------------
  -- The sticky column, Vim's `curswant`.
  --
  -- Without it every `j` re-derives its target from wherever the previous one
  -- landed, so a run down a document drifts sideways and the matching run of
  -- `k` cannot retrace it -- which is exactly what "j to the bottom, k back to
  -- the top, and the caret has moved along the line" was.
  -- ---------------------------------------------------------------------
  do
    local function last_request(keys)
      requests = {}
      feed(keys)
      return requests[#requests]
    end

    caret.forget(session)
    caret.set_rect(session, { x = 42, y = 24, width = 19, height = 38 }, session.applied_scroll_y)

    -- The first `j` of a run seeds the column from the caret's own left edge --
    -- its edge, not its centre, which is what stops a big heading glyph landing
    -- one character right of where it should on the smaller line below.
    reply = { x = 44, y = 91, width = 8, height = 18 }
    local first = last_request("j")
    t.eq(42, first.desiredX, "a line motion aims at the caret's left edge")

    -- Every later step of the run aims at the *same* column, even though the
    -- caret has meanwhile landed somewhere slightly different.
    reply = { x = 47, y = 109, width = 8, height = 18 }
    local second = last_request("j")
    t.eq(42, second.desiredX, "and later steps keep aiming at it, not at where they landed")
    local back = last_request("k")
    t.eq(42, back.desiredX, "including on the way back up")

    -- Any motion that is not a line motion re-seeds the column.
    reply = { x = 300, y = 109, width = 8, height = 18 }
    feed("w")
    t.eq(300, session.caret_desired_x, "a word motion re-seeds the column where it lands")
    local after_word = last_request("j")
    t.eq(300, after_word.desiredX, "so the next j aims from there")

    -- `$` parks the column past every line's end, so a following `j` keeps
    -- landing on line ends -- the same thing Vim does with it.
    reply = { x = 700, y = 109, width = 8, height = 18 }
    feed("$")
    t.eq(
      session.viewport_width_px,
      session.caret_desired_x,
      "$ parks the column past the end of every line -- at the viewport's width, which JSON can carry"
    )
    local after_dollar = last_request("j")
    t.eq(session.viewport_width_px, after_dollar.desiredX, "so j keeps following the line ends down")

    caret.forget(session)
    t.eq(nil, session.caret_desired_x, "forgetting the caret forgets its column too")
  end

  -- ---------------------------------------------------------------------
  -- Neovim's own cursor shadows the caret: not what the reader sees, but it
  -- keeps the preview window's cursor somewhere meaningful for the terminals
  -- that cannot draw the overlay and are left showing the real one.
  -- ---------------------------------------------------------------------
  do
    local rows, columns = preview.surface_size(session)
    caret.set_rect(session, { x = 0, y = 0, width = 9, height = 18 }, session.applied_scroll_y)
    local cursor = vim.api.nvim_win_get_cursor(session.preview_win)
    t.eq(1, cursor[1], "a caret at the top-left of the image shadows to the first row")
    t.eq(0, cursor[2], "and the first column")

    caret.set_rect(session, { x = 799, y = 599, width = 1, height = 1 }, session.applied_scroll_y)
    cursor = vim.api.nvim_win_get_cursor(session.preview_win)
    t.eq(rows, cursor[1], "a caret at the far corner shadows to the last row")
    t.eq(columns - 1, cursor[2], "and the last column")
  end

  -- ---------------------------------------------------------------------
  -- Entering the preview places a caret, and Neovim's own cursor is hidden
  -- exactly while the block is drawn. Both of these were reported broken: the
  -- Vim cursor showed at the top left on entry (no caret had been placed, so
  -- nothing had hidden it), and after one motion *both* were visible at once
  -- (the hide was gated on a window event that ran before the caret existed).
  -- ---------------------------------------------------------------------
  do
    local overlay_rects = nil
    session.backend = {
      name = "kitty_raw",
      overlay_supported = function() return true end,
      overlay_apply = function(_, _, rects)
        overlay_rects = rects
        return 42, { rects = #rects }
      end,
      overlay_clear = function() end,
      clear = function() return true end,
    }
    session.image_id = 7
    local original_guicursor = vim.o.guicursor
    preview.restore_cursor()
    caret.forget(session)
    session.caret_overlay_set = nil

    -- Unfocused: nothing to see, so nothing is spent finding it.
    vim.api.nvim_set_current_win(entry_win)
    caret.forget(session)
    requests = {}
    controller.place_caret(session)
    t.eq(0, #requests, "an unfocused preview does not go looking for a caret")
    t.eq(nil, session.caret_rect, "and does not get one")

    -- Focused: entering the window is itself what places the caret, with no
    -- motion pressed. This is the reported bug -- the Vim cursor sat at the top
    -- left on entry because nothing had placed a caret to hide it.
    reply = { x = 42, y = 24, width = 19, height = 38 }
    requests = {}
    vim.api.nvim_set_current_win(session.preview_win)
    t.eq(1, #requests, "entering the preview places a caret")
    t.eq("caret_move", requests[1].action, "by asking the renderer for a real character")
    t.eq("none", requests[1].granularity, "snapping rather than moving")
    t.ok(session.caret_rect ~= nil, "and the caret exists from then on")
    t.ok(overlay_rects ~= nil, "the caret is drawn as an overlay rectangle")
    t.eq(19, overlay_rects[1].width, "shaped like the glyph it sits on")
    t.eq(38, overlay_rects[1].height, "shaped like the glyph it sits on")
    t.ok(
      vim.o.guicursor:find("MdViewerHiddenCursor", 1, true) ~= nil,
      "and Neovim's own cursor is hidden, so the two are never both up"
    )

    -- Leaving the terminal gives the cursor back, and returning to it has to
    -- take it away again. Reported: coming back to the window left Neovim's own
    -- cursor sitting beside the block until some later motion happened to
    -- redraw it. `FocusLost` restores without any window changing, so nothing
    -- fires `WinEnter` on the way back and nothing hid it again.
    vim.api.nvim_exec_autocmds("FocusLost", { modeline = false })
    t.eq(original_guicursor, vim.o.guicursor, "leaving the terminal gives Neovim's cursor back")
    vim.api.nvim_exec_autocmds("FocusGained", { modeline = false })
    t.ok(
      vim.o.guicursor:find("MdViewerHiddenCursor", 1, true) ~= nil,
      "and returning hides it again, rather than leaving both up until the next motion"
    )

    -- Scrolled out of view, there is no block to see -- so the real cursor has
    -- to come back rather than leave the reader with no caret at all.
    session.applied_scroll_y = 5000
    t.eq(false, controller.display_caret_overlay(session), "a caret scrolled off screen is not drawn")
    t.eq(original_guicursor, vim.o.guicursor, "and Neovim's cursor is given back")
    session.applied_scroll_y = 0

    -- A backend that cannot draw the overlay never hides the cursor either:
    -- there the terminal's own cursor *is* the caret.
    preview.restore_cursor()
    session.backend = { name = "kitty_raw", clear = function() return true end }
    controller.place_caret(session)
    t.eq(original_guicursor, vim.o.guicursor, "a backend without the overlay keeps the real cursor visible")

    session.backend = {
      name = "kitty_raw",
      overlay_supported = function() return true end,
      overlay_apply = function() return 42, { rects = 1 } end,
      overlay_clear = function() end,
      clear = function() return true end,
    }
  end

  -- ---------------------------------------------------------------------
  -- Visual mode anchors on the caret's glyph and extends with any motion.
  -- ---------------------------------------------------------------------
  do
    caret.set_rect(session, { x = 100, y = 100, width = 10, height = 20 }, session.applied_scroll_y)
    requests = {}
    feed("v")
    t.eq(true, interaction.visual_active(session), "v enters preview visual mode")
    local anchored = nil
    for _, request in ipairs(requests) do
      if request.action == "selection_preview" then anchored = request end
    end
    t.ok(anchored ~= nil, "and sends a selection anchored at the caret")
    t.eq(105, anchored.anchorCoordinates.x, "anchored at the middle of the caret's glyph")
    t.eq(110, anchored.anchorCoordinates.y, "anchored at the middle of the caret's glyph")

    reply = { x = 400, y = 300, width = 10, height = 20 }
    requests = {}
    feed("3j")
    local extended = nil
    for _, request in ipairs(requests) do
      if request.action == "selection_preview" then extended = request end
    end
    t.ok(extended ~= nil, "a motion in visual mode extends the selection")
    t.eq(105, extended.anchorCoordinates.x, "the anchor stays where v put it")
    t.eq(405, extended.coordinates.x, "and the focus follows the caret's new glyph")

    feed("<Esc>")
    t.eq(false, interaction.visual_active(session), "Esc leaves visual mode")
  end

  process.request = original_request
  controller.schedule_scroll = original_schedule_scroll
  controller.close()
  t.eq(nil, session.caret_rect, "closing a preview forgets its caret")
  if vim.api.nvim_win_is_valid(entry_win) then vim.api.nvim_set_current_win(entry_win) end
  if vim.api.nvim_buf_is_valid(source) then vim.api.nvim_buf_delete(source, { force = true }) end
  config.reset()
end
