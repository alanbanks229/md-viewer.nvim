local config = require("md-viewer.config")
local coordinates = require("md-viewer.coordinates")
local debounce = require("md-viewer.debounce")
local linkrate = require("md-viewer.linkrate")
local resident = require("md-viewer.resident")
local state = require("md-viewer.state")

local M = {}

local click_actions = {}
local next_click_id = 0

local function click_id(pane, action)
  next_click_id = next_click_id + 1
  click_actions[next_click_id] = action
  pane.winbar_click_ids = pane.winbar_click_ids or {}
  pane.winbar_click_ids[#pane.winbar_click_ids + 1] = next_click_id
  return next_click_id
end

function M.clear_clicks(pane)
  for _, id in ipairs(pane and pane.winbar_click_ids or {}) do
    click_actions[id] = nil
  end
  if pane then pane.winbar_click_ids = nil end
end

_G.MdViewerWinbarClick = function(minwid, _, button)
  local action = click_actions[tonumber(minwid)]
  if not action then return end
  local controller = require("md-viewer.controller")
  if button == "m" or action.close then
    controller.tab_close(action.session)
  elseif button == "l" then
    controller.activate_document(action.session)
  end
end

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

local function escaped(value) return tostring(value):gsub("%%", "%%%%") end

local function path_parts(path)
  local parts = {}
  for part in path:gmatch("[^/\\]+") do
    parts[#parts + 1] = part
  end
  return parts
end

---Shortest path suffixes that distinguish every document in a pane. Untitled
---buffers fall back to their buffer number, which is stable for the session.
local function tab_labels(pane)
  local parts, labels = {}, {}
  for index, document in ipairs(pane.documents) do
    local path = vim.api.nvim_buf_get_name(document.source_buf)
    parts[index] = path ~= "" and path_parts(vim.fs.normalize(path)) or { "[No Name " .. document.source_buf .. "]" }
  end
  for index, own in ipairs(parts) do
    local depth = 1
    while depth < #own do
      local suffix = table.concat(own, "/", math.max(1, #own - depth + 1))
      local unique = true
      for other, candidate in ipairs(parts) do
        if other ~= index then
          local theirs = table.concat(candidate, "/", math.max(1, #candidate - depth + 1))
          if suffix == theirs then
            unique = false
            break
          end
        end
      end
      if unique then break end
      depth = depth + 1
    end
    labels[index] = table.concat(own, "/", math.max(1, #own - depth + 1))
  end
  return labels
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

---How much longer a warm-up has to run, or "" when nothing here can say.
---
---Estimated from the chunks this document has already produced rather than from
---the plan's geometry: PNG bytes against real content are not predictable from a
---pixel count -- the same 4 Mpx chunk is 396 KB of prose and rather less of a
---page of headings -- so the document's own captured chunks are the best
---available sample of its own remaining ones. What crosses the wire is base64,
---hence the 4/3.
---
---Silent unless every input is real: one chunk actually captured, bytes actually
---counted, and a link rate that came from a measurement rather than a guess. An
---ETA is a promise, and there is no honest one to make from an inferred rate --
---see md-viewer.linkrate for where the rate is allowed to come from.
local function warmup_eta(warming)
  local captured, total = warming.captured or 0, warming.plan.count or 0
  local bytes = tonumber(warming.bytes) or 0
  if captured < 1 or bytes <= 0 or total <= captured then return "" end
  -- Resolved here and passed in, never resolved inside `link_rate`: that
  -- function takes one parameter on purpose, and the parameter means "a rate
  -- somebody observed".
  local bytes_per_sec = linkrate.resolve()
  local bytes_per_ms = resident.link_rate(bytes_per_sec)
  if not bytes_per_ms then return "" end
  local seconds = ((bytes / captured) * (total - captured) * 4 / 3) / bytes_per_ms / 1000
  if seconds < 1 then return "" end
  if seconds < 90 then return (" ~%ds"):format(math.ceil(seconds)) end
  return (" ~%dm"):format(math.ceil(seconds / 60))
end

---How much of the document is resident, while any of it is not.
---
---Read straight off the session rather than through `resident_session`, which
---requires this module: a require cycle here would be a load-order failure at
---startup rather than a wrong string. `md-viewer.resident` and
---`md-viewer.linkrate` above are safe to require -- both are leaves.
local function warmup_notice(session)
  local state = session.resident
  if not state or not state.plan then return nil end
  local captured, total = state.captured or 0, state.plan.count or 0
  if total == 0 or captured >= total then return nil end
  if session.resident_waiting then
    return ("%%#WarningMsg#waiting for this page — %d/%d%%*"):format(captured, total)
  end
  return ("%%#Comment#warming %d/%d%s%%*"):format(captured, total, warmup_eta(state))
end

local function title_text(session)
  local pane = session.pane
  local text = ""
  if pane and #pane.documents > 0 then
    M.clear_clicks(pane)
    local labels = tab_labels(pane)
    for index, document in ipairs(pane.documents) do
      local active = document == pane.active
      local tab_action = click_id(pane, { session = document })
      local close_action = click_id(pane, { session = document, close = true })
      text = text
        .. (active and "%#MdViewerTabActive#" or "%#MdViewerTabInactive#")
        .. ("%%%d@v:lua.MdViewerWinbarClick@"):format(tab_action)
        .. " "
        .. escaped(labels[index])
        .. " %T"
        .. ("%%%d@v:lua.MdViewerWinbarClick@"):format(close_action)
        .. "×%T%* "
    end
  else
    text = "  %#Title#  " .. source_title(session.source_buf) .. "%*"
  end
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
  local active = session.pane and session.pane.active or session
  vim.api.nvim_set_hl(0, "MdViewerTabActive", { link = "TabLineSel", default = true })
  vim.api.nvim_set_hl(0, "MdViewerTabInactive", { link = "TabLine", default = true })
  vim.wo[session.preview_win].winbar = title_text(active)
end

local line_number_ns = vim.api.nvim_create_namespace("md-viewer_line_numbers")

local function line_center(line) return (line.topPx + line.bottomPx) / 2 end

---The rendered visual line nearest document-coordinate `y`. Geometry is
---ordered, so two neighbours around the binary-search insertion point are the
---only candidates whose centres can win.
local function nearest_line_index(lines, y)
  if not (lines and lines[1]) then return nil end
  local low, high = 1, #lines
  while low <= high do
    local middle = math.floor((low + high) / 2)
    if line_center(lines[middle]) < y then
      low = middle + 1
    else
      high = middle - 1
    end
  end
  local after = math.max(1, math.min(#lines, low))
  local before = math.max(1, after - 1)
  if math.abs(line_center(lines[before]) - y) <= math.abs(line_center(lines[after]) - y) then return before end
  return after
end

local function caret_line_index(session)
  local rect = session.caret_rect
  if not rect then return nil end
  local y = (session.caret_scroll_y or 0) + rect.y + rect.height / 2
  return nearest_line_index(session.latest_lines, y)
end

local function viewport_line_index(session)
  local height = session.viewport_height_render_px or session.viewport_height_px or 0
  return nearest_line_index(session.latest_lines, (session.applied_scroll_y or 0) + height / 2)
end

local function progress_text(session)
  local document_height = session.document_height_px or 0
  local viewport_height = session.viewport_height_px or 0
  if document_height <= viewport_height then return "All" end

  local lines = session.latest_lines or {}
  local total = #lines
  local basis = session.progress_basis == "caret" and "caret" or "viewport"
  local index = basis == "caret" and caret_line_index(session) or viewport_line_index(session)
  if total > 0 and index then
    if basis == "caret" then
      if index == 1 then return "Top" end
      if index == total then return "Bot" end
    else
      local maximum = math.max(0, document_height - viewport_height)
      local scroll = session.applied_scroll_y or 0
      if scroll <= 0 then return "Top" end
      if scroll >= maximum - 0.5 then return "Bot" end
    end
    return string.format("%d%%", math.max(1, math.min(99, math.floor((index / total) * 100))))
  end

  -- Before the first render has delivered visual-line geometry, retain an
  -- honest pixel fallback rather than exposing the viewport-sized shadow
  -- buffer's native percentage.
  local y
  if basis == "caret" and session.caret_rect then
    y = (session.caret_scroll_y or 0) + session.caret_rect.y + session.caret_rect.height / 2
  else
    y = (session.applied_scroll_y or 0) + viewport_height / 2
  end
  if y <= 0 then return "Top" end
  if y >= document_height - 1 then return "Bot" end
  return string.format("%d%%", math.max(1, math.min(99, math.floor((y / document_height) * 100))))
end

---A raw, human-readable progress label for statusline integrations. nil means
---the current buffer is not a graphical md-viewer preview and the caller should
---fall back to its ordinary component.
function M.statusline_progress(buf)
  local session = state.from_preview(buf or vim.api.nvim_get_current_buf())
  if not session or not session.backend or session.backend.name == "cells" then return nil end
  return progress_text(session)
end

---Publish progress without taking ownership of 'statusline'. The last label is
---cached so a run of motions within one percentage does not churn a global
---statusline renderer such as Lualine.
function M.update_progress(session)
  if not session or not session.backend or session.backend.name == "cells" then return end
  local text = progress_text(session)
  if text == session.last_progress_text then return end
  session.last_progress_text = text
  vim.api.nvim_exec_autocmds("User", {
    pattern = "MdViewerProgressChanged",
    modeline = false,
    data = { buf = session.preview_buf, win = session.preview_win, progress = text },
  })
end

function M.set_progress_basis(session, basis)
  assert(basis == "caret" or basis == "viewport", "progress basis must be caret or viewport")
  session.progress_basis = basis
  M.update_progress(session)
end

---Draw absolute or caret-relative rendered visual-line numbers. The browser's
---line boxes vary in height, so their vertical centres go through the same
---CSS-pixel-to-terminal-cell conversion as the caret. Using top edges was the
---one-row-up bias visible on headings and other tall lines.
function M.update_line_numbers(session)
  if not (session.preview_buf and vim.api.nvim_buf_is_valid(session.preview_buf)) then return end
  vim.api.nvim_buf_clear_namespace(session.preview_buf, line_number_ns, 0, -1)
  local mode = config.get().preview.line_numbers
  if session.backend and session.backend.name == "cells" then
    if session.preview_win and vim.api.nvim_win_is_valid(session.preview_win) then
      vim.wo[session.preview_win].number = mode ~= "off"
      vim.wo[session.preview_win].relativenumber = mode == "relative"
    end
    return
  end
  if mode == "off" then return end
  vim.api.nvim_set_hl(0, "MdViewerLineNumber", { link = "LineNr", default = true })
  vim.api.nvim_set_hl(0, "MdViewerCurrentLineNumber", { link = "CursorLineNr", default = true })
  local placement = session.last_placement
  if not placement and session.preview_win and vim.api.nvim_win_is_valid(session.preview_win) then
    placement = M.placement(session.preview_win, session.backend and session.backend.name)
  end
  if not placement or placement.height <= 0 then return end
  local viewport_height = session.viewport_height_render_px or 0
  if viewport_height <= 0 then return end
  local scroll_y = session.applied_scroll_y or 0
  local current = mode == "relative" and caret_line_index(session) or nil
  local by_row = {}
  for index, line in ipairs(session.latest_lines or {}) do
    if line.bottomPx > scroll_y and line.topPx < scroll_y + viewport_height then
      local relative_y = line_center(line) - scroll_y
      local row = coordinates.css_to_cell(
        { x = 0, y = relative_y },
        placement,
        { widthPx = session.viewport_width_px or 1, heightPx = viewport_height }
      )
      if row then
        local row_center = ((row - 0.5) / placement.height) * viewport_height
        local distance = math.abs(relative_y - row_center)
        if not by_row[row] or distance < by_row[row].distance then
          local value = index
          if current and index ~= current then value = math.abs(index - current) end
          by_row[row] = {
            distance = distance,
            value = value,
            highlight = current == index and "MdViewerCurrentLineNumber" or "MdViewerLineNumber",
          }
        end
      end
    end
  end
  for row, number in pairs(by_row) do
    pcall(vim.api.nvim_buf_set_extmark, session.preview_buf, line_number_ns, row - 1, 0, {
      virt_text = { { tostring(number.value), number.highlight } },
      virt_text_pos = "overlay",
    })
  end
end

local window_options = {
  "number",
  "relativenumber",
  "signcolumn",
  "foldcolumn",
  "wrap",
  "cursorline",
  "spell",
  "scrolloff",
  "sidescrolloff",
  "winhighlight",
  "winbar",
  "winfixbuf",
}

local function snapshot_window(win)
  local snapshot = {
    buf = vim.api.nvim_win_get_buf(win),
    view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
    width = vim.api.nvim_win_get_width(win),
    height = vim.api.nvim_win_get_height(win),
    options = {},
  }
  for _, name in ipairs(window_options) do
    local ok, value = pcall(vim.api.nvim_get_option_value, name, { win = win })
    if ok then snapshot.options[name] = value end
  end
  return snapshot
end

function M.create_buffer(session)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "md-viewer"
  local pane_id = session.pane and session.pane.id or 0
  vim.api.nvim_buf_set_name(buf, ("md-viewer://preview/%d/%d"):format(pane_id, buf))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  session.preview_buf = buf
  return buf
end

local function configure_window(win, session)
  local cfg = config.get()
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

  if cfg.preview.winbar then
    vim.api.nvim_set_hl(0, "MdViewerTabActive", { link = "TabLineSel", default = true })
    vim.api.nvim_set_hl(0, "MdViewerTabInactive", { link = "TabLine", default = true })
    vim.wo[win].winbar = title_text(session)
  end
  if session.backend and session.backend.name == "cells" then
    vim.wo[win].number = cfg.preview.line_numbers ~= "off"
    vim.wo[win].relativenumber = cfg.preview.line_numbers == "relative"
  end
end

function M.open(position, session, adopt_win)
  local cfg = config.get()
  position = position or cfg.split.position
  local buf = session.preview_buf or M.create_buffer(session)
  local win
  if adopt_win then
    win = adopt_win
    session.pane.owned = false
    session.pane.original = snapshot_window(win)
    vim.wo[win].winfixbuf = false
    vim.api.nvim_win_set_buf(win, buf)
  else
    -- The destination buffer exists before the split: no observable frame can
    -- show a second copy of the source and be mistaken for another source pane.
    win = vim.api.nvim_open_win(buf, true, { split = position, win = -1 })
  end
  session.preview_win = win
  session.pane.preview_win = win
  configure_window(win, session)
  vim.wo[win].winfixbuf = true

  if not adopt_win and (position == "right" or position == "left") then
    vim.api.nvim_win_set_width(win, math.max(cfg.split.min_width, math.floor(vim.o.columns * cfg.split.width)))
  elseif not adopt_win then
    vim.api.nvim_win_set_height(win, math.max(8, math.floor(vim.o.lines * cfg.split.width)))
  end
  return buf, win
end

function M.show_document(session)
  local pane, win = session.pane, session.pane and session.pane.preview_win
  if not (win and vim.api.nvim_win_is_valid(win)) then return false end
  vim.wo[win].winfixbuf = false
  local ok = pcall(vim.api.nvim_win_set_buf, win, session.preview_buf)
  if ok then
    session.preview_win = win
    configure_window(win, session)
  end
  vim.wo[win].winfixbuf = true
  return ok
end

function M.restore_adopted(pane)
  local win, original = pane and pane.preview_win, pane and pane.original
  if not (original and win and vim.api.nvim_win_is_valid(win)) then return false end
  vim.wo[win].winfixbuf = false
  if vim.api.nvim_buf_is_valid(original.buf) then pcall(vim.api.nvim_win_set_buf, win, original.buf) end
  for name, value in pairs(original.options) do
    pcall(vim.api.nvim_set_option_value, name, value, { win = win })
  end
  pcall(vim.api.nvim_win_set_width, win, original.width)
  pcall(vim.api.nvim_win_set_height, win, original.height)
  pcall(vim.api.nvim_win_call, win, function() vim.fn.winrestview(original.view) end)
  return true
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
