-- Capability flags, not `backend.name ==`.
--
-- Every backend declares the same six booleans, and a caller asks for the
-- capability it needs rather than for the backend that happens to have it
-- today. `name` stays what it always was -- the label `image.backend` accepts
-- and diagnostics print -- and nothing branches on it.
--
--   * `is_graphical` -- the preview is pixels. False only for `cells`, whose
--     preview is styled text in the buffer: scrolling, the caret, selection,
--     interaction, rendered line numbers and the wheel all have no image to
--     act on there, and every one of them asks this.
--   * `places_raw_images` -- the backend writes the graphics escapes itself, so
--     the plugin owns what is on the glass: it moves and crops the placement by
--     hand, and it may lay animation frames and overlay sheets beside the base.
--     Where Neovim owns the image instead, it reflows the placement itself and
--     offers no sub-cell position to draw either of those at.
--   * `accepts_exclusions` -- a placement may carry cut-out rectangles for the
--     floats that overlap it.
--   * `needs_statusline_guard` -- the bottom placement row must be handed back,
--     because these pixels come from the terminal rather than from Neovim and
--     would otherwise paint over the statusline.
--   * `needs_ui_poll` -- terminal-owned UI (the completion popup, the command
--     line) paints over pixels Neovim does not know about, so placements are
--     suppressed on those events and re-asserted by polling.
--   * `supports_local_markers` -- the backend presents through a seam, so
--     `localrender` can install `kitty_marker` in it and send a reference over
--     the wire instead of a frame.
--
-- The last five are true for exactly one backend today, and are still five
-- flags: each names a different reason a site used to ask "is this kitty_raw?",
-- and a site wanting one of them rarely wants the others.
local FLAGS = {
  "is_graphical",
  "places_raw_images",
  "accepts_exclusions",
  "needs_statusline_guard",
  "needs_ui_poll",
  "supports_local_markers",
}

local config = require("md-viewer.config")

local modules = {
  nvim_img = require("md-viewer.backends.nvim_img"),
  kitty_raw = require("md-viewer.backends.kitty_raw"),
  cells = require("md-viewer.backends.cells"),
}

local M = {}

function M.select(requested)
  requested = requested or config.get().image.backend
  if requested ~= "auto" then
    local backend = modules[requested]
    local ok, reason = backend.detect()
    if not ok then return nil, ("requested backend %s unavailable: %s"):format(requested, reason) end
    return backend, reason
  end
  local ok, reason = modules.nvim_img.detect()
  if ok then return modules.nvim_img, "verified: " .. reason end
  local raw_ok, raw_reason = modules.kitty_raw.detect()
  if raw_ok then return modules.kitty_raw, raw_reason end
  return modules.cells, ("nvim_img unavailable (%s); %s; using cells"):format(reason, raw_reason)
end

function M.health()
  local selected, reason = M.select()
  return {
    selected = selected and selected.name or nil,
    decision = reason,
    nvim_img = modules.nvim_img.health(),
    kitty_raw = modules.kitty_raw.health(),
    cells = modules.cells.health(),
  }
end

---The flags a backend declares, without its implementation.
---
---They live on the backend modules themselves -- `backends.get("cells").is_graphical`
---is this same field -- so this exists for callers that want the declaration
---and nothing else: diagnostics, and tests standing in for a backend.
function M.capabilities(name)
  local backend = modules[name]
  if not backend then return nil end
  local out = { name = backend.name }
  for _, flag in ipairs(FLAGS) do
    out[flag] = backend[flag] == true
  end
  return out
end

function M.get(name) return modules[name] end

return M
