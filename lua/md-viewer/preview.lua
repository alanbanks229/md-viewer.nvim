local config = require("md-viewer.config")
local coordinates = require("md-viewer.coordinates")
local debounce = require("md-viewer.debounce")

local M = {}

local split_commands = {
  right = "rightbelow vsplit",
  left = "leftabove vsplit",
  below = "rightbelow split",
  above = "leftabove split",
}

local loading_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function loading_label(session)
  local index = (session.loading_frame % #loading_frames) + 1
  return loading_frames[index] .. "  Rendering Markdown…"
end

local function update_loading(session)
  if not session.loading or not session.preview_win or not vim.api.nvim_win_is_valid(session.preview_win) then
    return false
  end
  local label = loading_label(session)
  local available = math.max(1, vim.api.nvim_win_get_width(session.preview_win) - 2)
  local width = math.min(available, vim.fn.strdisplaywidth(label))
  if width < vim.fn.strdisplaywidth(label) then label = vim.fn.strcharpart(label, 0, width) end
  if session.loading_buf and vim.api.nvim_buf_is_valid(session.loading_buf) then
    vim.bo[session.loading_buf].modifiable = true
    vim.api.nvim_buf_set_lines(session.loading_buf, 0, -1, false, { label })
    vim.bo[session.loading_buf].modifiable = false
  end
  if session.loading_win and vim.api.nvim_win_is_valid(session.loading_win) then
    local height = vim.api.nvim_win_get_height(session.preview_win)
    pcall(vim.api.nvim_win_set_config, session.loading_win, {
      relative = "win",
      win = session.preview_win,
      row = math.max(0, math.floor((height - 1) / 2)),
      col = math.max(0, math.floor((vim.api.nvim_win_get_width(session.preview_win) - width) / 2)),
      width = width,
      height = 1,
    })
  end
  return true
end

function M.start_loading(session)
  local cfg = config.get().preview
  if
    not cfg.loading
    or session.loading
    or not session.preview_win
    or not vim.api.nvim_win_is_valid(session.preview_win)
  then
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  session.loading = true
  session.loading_buf = buf
  session.loading_frame = 0
  local label = loading_label(session)
  local width =
    math.min(math.max(1, vim.api.nvim_win_get_width(session.preview_win) - 2), vim.fn.strdisplaywidth(label))
  local height = vim.api.nvim_win_get_height(session.preview_win)
  session.loading_win = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = session.preview_win,
    row = math.max(0, math.floor((height - 1) / 2)),
    col = math.max(0, math.floor((vim.api.nvim_win_get_width(session.preview_win) - width) / 2)),
    width = width,
    height = 1,
    style = "minimal",
    focusable = false,
    noautocmd = true,
    zindex = 210,
  })
  vim.api.nvim_set_hl(0, "MdViewerLoading", { link = "Comment", default = true })
  vim.wo[session.loading_win].winhighlight = "Normal:MdViewerLoading"
  vim.wo[session.loading_win].winblend = 0
  update_loading(session)
  local timer = vim.uv.new_timer()
  session.loading_timer = timer
  timer:start(
    cfg.loading_interval_ms,
    cfg.loading_interval_ms,
    vim.schedule_wrap(function()
      if not session.loading then
        debounce.close(session, "loading_timer")
        return
      end
      session.loading_frame = session.loading_frame + 1
      if not update_loading(session) then M.stop_loading(session) end
    end)
  )
end

function M.stop_loading(session)
  if not session then return end
  session.loading = false
  debounce.close(session, "loading_timer")
  if session.loading_win and vim.api.nvim_win_is_valid(session.loading_win) then
    pcall(vim.api.nvim_win_close, session.loading_win, true)
  end
  session.loading_win = nil
  session.loading_buf = nil
end

local function source_title(source_buf)
  local name = vim.api.nvim_buf_get_name(source_buf)
  local filename = name == "" and "[No Name]" or vim.fn.fnamemodify(name, ":t")
  return filename:gsub("%%", "%%%%")
end

---When `image.backend = "auto"` picked the text-cell fallback because no
---graphical backend was available (e.g. macOS Terminal.app, or any terminal
---with no Kitty-graphics evidence), surface that in the preview title instead
---of silently rendering degraded output that looks like a bug. Explicitly
---requesting `image.backend = "cells"` is not a fallback, so it stays quiet.
local function fallback_notice(session)
  if not session.backend or session.backend.name ~= "cells" then return nil end
  if config.get().image.backend ~= "auto" then return nil end
  return "%#WarningMsg#⚠ text-only preview — no Kitty graphics detected (see :MdViewerHealth)%*"
end

---How much of the document is resident, while any of it is not.
---
---Read straight off the session rather than through `resident_session`, which
---requires this module: a require cycle here would be a load-order failure at
---startup rather than a wrong string.
local function warmup_notice(session)
  local state = session.resident
  if not state or not state.plan then return nil end
  local captured, total = state.captured or 0, state.plan.count or 0
  if total == 0 or captured >= total then return nil end
  if session.resident_waiting then
    return ("%%#WarningMsg#waiting for this page — %d/%d%%*"):format(captured, total)
  end
  return ("%%#Comment#warming %d/%d%%*"):format(captured, total)
end

local function title_text(session)
  local text = "  %#Title#  " .. source_title(session.source_buf) .. "%*"
  -- The one piece of modal state the preview has, and the winbar is the only
  -- place it can be said: Neovim's own mode indicator reports normal mode,
  -- because as far as Neovim is concerned that is what this is.
  if session.visual_active then
    text = text .. "  %#ModeMsg#-- VISUAL" .. (session.visual_linewise and " LINE" or "") .. " --%*"
  end
  local warming = warmup_notice(session)
  if warming then text = text .. "  " .. warming end
  local notice = fallback_notice(session)
  if notice then text = text .. "  " .. notice end
  return text
end

function M.update_title(session)
  if
    not config.get().preview.winbar
    or not session.preview_win
    or not vim.api.nvim_win_is_valid(session.preview_win)
  then
    return
  end
  vim.wo[session.preview_win].winbar = title_text(session)
end

function M.open(position, session)
  local cfg = config.get()
  position = position or cfg.split.position
  vim.cmd(split_commands[position])
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "md-viewer"
  vim.api.nvim_buf_set_name(buf, "md-viewer://preview/" .. buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].spell = false
  -- Window-local, and load-bearing rather than tidy: the surface is exactly as
  -- tall as the placement, so a global 'scrolloff' would fence the caret away
  -- from the top and bottom rows -- the two rows whose whole job is to be
  -- reachable, since reaching them is what scrolls the document. 'sidescrolloff'
  -- is the same argument one axis over, and also keeps 'leftcol' at 0.
  vim.wo[win].scrolloff = 0
  vim.wo[win].sidescrolloff = 0
  -- A Visual highlight that paints nothing. The surface holds blank cells whose
  -- only job is to carry a default background for the image to be composited
  -- through, and an opaque highlight over them is an opaque rectangle over the
  -- preview. The Kitty protocol says a `z = -3` placement still draws above a
  -- non-default cell background -- only `z < INT32_MIN/2` goes beneath one --
  -- but Warp blanks the image anyway, so this does not rely on the terminal
  -- getting that right. Same technique as `MdViewerHiddenCursor` below.
  --
  -- Belt to the `ModeChanged` guard's braces: that guard leaves Visual mode,
  -- but not before one frame has already been drawn in it.
  vim.api.nvim_set_hl(0, "MdViewerInertVisual", { blend = 100, nocombine = true })
  vim.wo[win].winhighlight = "Visual:MdViewerInertVisual,VisualNOS:MdViewerInertVisual"

  if cfg.preview.winbar then vim.wo[win].winbar = title_text(session) end

  if position == "right" or position == "left" then
    vim.api.nvim_win_set_width(win, math.max(cfg.split.min_width, math.floor(vim.o.columns * cfg.split.width)))
  else
    vim.api.nvim_win_set_height(win, math.max(8, math.floor(vim.o.lines * cfg.split.width)))
  end
  return buf, win
end

-- The reader's real `guicursor`, held while the preview is focused and the
-- caret is being drawn as an overlay rectangle instead. Module-local rather
-- than per-session because 'guicursor' is global: two previews cannot disagree
-- about it, and whichever restores last must restore the *original*, not the
-- hidden setting a sibling left behind.
local saved_guicursor = nil

---Hide Neovim's own cursor in favour of the overlay caret.
---
---Only while the overlay caret is actually on screen. Where it cannot be drawn
---(a backend or terminal without overlay support) the terminal's cursor *is*
---the caret -- coarser, but it now sits on the glyph the caret is on rather
---than wherever the reader last left it -- so hiding it there would leave no
---caret at all.
function M.hide_cursor(session)
  if saved_guicursor then return end
  local backend = session and session.backend
  if not (backend and backend.overlay_supported and backend.overlay_supported()) then return end
  saved_guicursor = vim.o.guicursor
  vim.api.nvim_set_hl(0, "MdViewerHiddenCursor", { blend = 100, nocombine = true })
  vim.o.guicursor = "a:MdViewerHiddenCursor"
end

---Give the reader their cursor back. Called from every path that can take focus
---away from a preview, and from session teardown -- a plugin that leaves the
---cursor invisible has broken the editor, so this errs heavily toward running
---more often than strictly needed.
function M.restore_cursor()
  if not saved_guicursor then return end
  vim.o.guicursor = saved_guicursor
  saved_guicursor = nil
end

function M.placement(win, backend_name)
  local value = coordinates.for_window(win)
  if backend_name == "kitty_raw" and value.statusline then
    local guard = math.max(0, math.floor(config.get().image.raw_statusline_guard_cells or 1))
    guard = math.min(guard, math.max(0, value.height - 1))
    value.height = value.height - guard
    value.statusline_guard_cells = guard
  end
  if backend_name == "kitty_raw" then
    value.exclusions = coordinates.passive_overlays(value, win, config.get().image.raw_overlay_bleed_cells)
  end
  return value
end

function M.viewport(win, backend_name) return coordinates.viewport(M.placement(win, backend_name), config.get().render) end

function M.occlusion(win)
  local overlaps = coordinates.overlapping_floats(M.placement(win), win)
  return #overlaps > 0, overlaps
end

---How many blank cells the preview surface must offer, as `rows, columns`:
---exactly the placement the image is drawn into, so every cell a caret can
---reach is a cell `coordinates.cell_to_css` can resolve.
---
---Not the window's own height. `M.placement` hands the raw Kitty backend a
---statusline guard row back, and `cell_to_css` refuses any row at or past
---`placement.height` -- a caret parked on that row would resolve to nothing,
---and resolve to nothing *silently*, since a nil point is how "not addressable
---content" is spelled everywhere downstream.
function M.surface_size(session)
  if not (session.preview_win and vim.api.nvim_win_is_valid(session.preview_win)) then return nil end
  local backend_name = session.backend and session.backend.name
  if backend_name == "cells" then return nil end
  local placement = M.placement(session.preview_win, backend_name)
  return math.max(1, placement.height), math.max(1, placement.width)
end

---Hold the preview buffer at the shape a caret needs: one line per placement
---row, each as wide as the placement.
---
---Spaces rather than empty lines plus `virtualedit = "all"`. Virtual space lets
---the cursor push one column past the window's width, which scrolls the window
---horizontally -- and a horizontally scrolled window is one `screenpos()`
---reports as not visible, which is exactly the placement corruption
---`coordinates.for_window` documents. Real characters buy the same free
---horizontal movement with none of that: a W-wide line exactly fills a W-wide
---window, so `leftcol` stays 0. Measured both ways on 0.12.4.
---
---Re-asserted before every frame, because a frame is also the moment the
---geometry may have changed -- but it preserves the caret while doing so.
---`nvim_buf_set_lines` clamps the cursor to line 1 when it shrinks the buffer,
---and this runs on every render, scroll, selection-preview frame, find step
---and cached restore; a caret that jumped home on each of those would not be
---a caret.
function M.reset_surface(session)
  if not (session.preview_buf and vim.api.nvim_buf_is_valid(session.preview_buf)) then return end
  if session.backend and session.backend.name == "cells" then return end
  local rows, columns = M.surface_size(session)
  if not rows then return end
  local blank = string.rep(" ", columns)
  local lines = vim.api.nvim_buf_get_lines(session.preview_buf, 0, -1, false)
  -- Every line is identical by construction and the buffer is nomodifiable, so
  -- the first one settles the width for all of them.
  if #lines == rows and lines[1] == blank then return end
  local win = session.preview_win
  local cursor = nil
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == session.preview_buf then
    cursor = vim.api.nvim_win_get_cursor(win)
  end
  local replacement = {}
  for index = 1, rows do
    replacement[index] = blank
  end
  vim.bo[session.preview_buf].modifiable = true
  vim.bo[session.preview_buf].readonly = false
  vim.api.nvim_buf_set_lines(session.preview_buf, 0, -1, false, replacement)
  vim.bo[session.preview_buf].modifiable = false
  vim.bo[session.preview_buf].readonly = true
  if cursor then
    pcall(vim.api.nvim_win_set_cursor, win, {
      math.max(1, math.min(rows, cursor[1])),
      math.max(0, math.min(columns - 1, cursor[2])),
    })
  end
end

return M
