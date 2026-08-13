local config = require("md-viewer.config")
local terminal = require("md-viewer.terminal")

--- Whether this session may leave the pixels where they were made.
---
--- Client rendering is four things being true at once, and this module exists
--- so that "which four" is written down once. Every one of them is necessary:
---
---  1. **A splicer is in front of the terminal.** `bin/md-viewer-ssh` says so
---     through `LC_MD_VIEWER`. A transmission token with nothing to substitute
---     it is an APC string the terminal discards, so the frame silently never
---     appears -- which is why this is a handshake rather than an assumption.
---  2. **The renderer is the companion, not the child.** A reference names
---     bytes held by whoever rasterized them. The child renderer beside Neovim
---     holds its frames on *this* machine, where a token would be spliced by
---     nobody.
---  3. **The backend is the raw Kitty one.** The token is a Kitty graphics
---     transmission with its payload deferred. `vim.ui.img` and the text-cell
---     fallback are handed pixels by Neovim itself and have nowhere to put a
---     reference.
---  4. **The user has not turned it off.** `client_render.enabled` is
---     "auto" (all of the above), "off", or "on" -- where "on" waives only the
---     handshake, for a terminal-side splicer that cannot forward an
---     environment variable.
---
--- Returns `enabled, reason`. The reason is written for `:MdViewerHealth` and
--- names the specific thing that is missing, because every one of these
--- failures otherwise presents identically: a preview that works, and is slow.
local M = {}

---The address the handshake carried, if it carried one. Read by process.lua
---*below* `client_render.address` and `$MD_VIEWER_CLIENT_ADDR`, because those
---two are decisions made on this host about this host while the handshake is
---whatever the wrapper happened to be told.
function M.announced_address()
  local capability = terminal.detect()
  local announced = capability.client_render
  return announced and announced.address or nil
end

function M.resolve(backend_name)
  local mode = config.get().client_render.enabled
  if mode == "off" then return false, "client_render.enabled=off (explicit override)" end

  local process = require("md-viewer.process")
  local status = process.status()
  if status.transport ~= "socket" then
    -- Distinguished deliberately: "you configured a companion and it was not
    -- there" is a different problem from "you configured nothing", and the
    -- second is not a fault at all.
    if status.companion_refused then return false, ("companion unreachable: %s"):format(status.companion_refused) end
    return false, "no companion renderer (client_render.address / $MD_VIEWER_CLIENT_ADDR is unset)"
  end

  if backend_name ~= nil and backend_name ~= "kitty_raw" then
    return false, ("the %s backend is handed pixels, not transmission commands"):format(backend_name)
  end

  local capability = terminal.detect()
  if capability.client_render then return true, capability.client_render_evidence or "LC_MD_VIEWER v1" end
  if mode == "on" then return true, "client_render.enabled=on (explicit override; no LC_MD_VIEWER handshake)" end
  if capability.client_render_evidence then return false, capability.client_render_evidence end
  return false, "no splicer in front of the terminal ($LC_MD_VIEWER is unset; start the session with md-viewer-ssh)"
end

---The transport to ask the renderer for, for one session's frames.
---
---Deliberately a string rather than a boolean: it is what goes on the wire, and
---`"path"` is what every request has always carried implicitly. A caller that
---forgets this function entirely gets today's behaviour.
function M.frame_transport(backend_name)
  local enabled, reason = M.resolve(backend_name)
  return enabled and "ref" or "path", reason
end

return M
