---Terminal cell size in *physical* pixels, measured from the operating system
---rather than estimated.
---
---Everything else in md-viewer addresses the preview in **cells**: the image
---is placed over N columns by M rows and the terminal scales it to fit. That
---makes a wrong cell size invisible -- the picture is squeezed or stretched to
---the right box either way, and only sharpness suffers.
---
---The selection overlay is the one exception. Its rectangles are
---crops placed with no `c`/`r` keys, so they display at natural **pixel**
---size, and pixels are only meaningful against the size the base image is
---actually being drawn at. Without the real cell size those rectangles land
---at the capture's scale instead of the screen's, which is exactly the defect
---the operator saw on 2026-08-08: a preview rendered against a guessed
---10x20 cell (the "estimated" tier's defaults) while the terminal's cell was
---7x16, so every highlight rectangle came out 1.41x too wide and 1.24x too
---tall while sitting at the right position.
---
---`TIOCGWINSZ` carries `ws_xpixel`/`ws_ypixel` beside the row and column
---counts Neovim already knows. Terminals that fill them in -- iTerm2, Kitty,
---Ghostty, WezTerm, Alacritty -- give an exact answer with no escape sequence
---and nothing to read back, which matters because Neovim owns terminal input
---and cannot read a CSI reply (see `coordinates.lua`'s `calibration_tier`).
---Terminals that leave them zero, multiplexers that do not propagate them, and
---any Neovim without LuaJIT report nothing, and callers fall back.
local M = {}

-- macOS and the BSDs encode TIOCGWINSZ as _IOR('t', 104, struct winsize):
-- 0x40000000 | (8 << 16) | (116 << 8) | 104. Linux uses a plain number.
local REQUEST = {
  Darwin = 0x40087468,
  FreeBSD = 0x40087468,
  OpenBSD = 0x40087468,
  NetBSD = 0x40087468,
  Linux = 0x5413,
}

-- A cell this far outside the plausible range means the terminal filled the
-- fields with something that is not a pixel count. Generous on purpose: a
-- 4x display with a large font is still inside it.
local MIN_CELL_PX, MAX_CELL_PX = 2, 200

local declared = false
-- Only *permanent* failures are remembered: a platform with no TIOCGWINSZ
-- constant and a Neovim with no LuaJIT ffi will not acquire either mid-session.
-- Everything else is re-read every call. See M.measure.
local unavailable = nil

local function ffi_handle()
  local ok, ffi = pcall(require, "ffi")
  if not ok then return nil end
  if not declared then
    -- Uniquely named so a cdef from another plugin cannot collide with this
    -- one; `ioctl` itself may already be declared, which is harmless -- the
    -- signature any other declaration uses is the same C function.
    pcall(ffi.cdef, "struct md_viewer_winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };")
    pcall(ffi.cdef, "int ioctl(int fd, unsigned long request, ...);")
    declared = true
  end
  local probe = pcall(function() return ffi.new("struct md_viewer_winsize") end)
  if not probe then return nil end
  return ffi
end

---Retained because `VimResized` still calls it and saying so is clearer than a
---silently missing call. There is nothing left to invalidate: `M.measure` reads
---the ioctl every time.
function M.invalidate() end

---One `TIOCGWINSZ` read: returns cols, rows, xpixel, ypixel, or nil when the
---ioctl is refused. Split out and left on the module so a test can substitute
---a terminal whose pixel geometry changes while its grid does not -- which is
---the case that was silently wrong before, and which nothing on a headless
---file descriptor can reproduce.
function M.read_winsize(ffi, request)
  local winsize = ffi.new("struct md_viewer_winsize")
  -- File descriptor 1: Neovim's stdout is the terminal. A headless or piped
  -- Neovim has no pixel geometry to report and lands in the caller's guards.
  local called, rc = pcall(ffi.C.ioctl, 1, request, winsize)
  if not called or rc ~= 0 then return nil end
  return tonumber(winsize.ws_col), tonumber(winsize.ws_row), tonumber(winsize.ws_xpixel), tonumber(winsize.ws_ypixel)
end

---The terminal's cell in physical pixels, or `nil` and a reason.
---
---Returns `{ width, height, cols, rows }` where `width`/`height` may be
---fractional -- a terminal is free to report a pixel size that does not divide
---evenly, and rounding here would reintroduce the error this module exists to
---remove.
---
---**Not cached, deliberately.** It used to be, validated by "the grid still
---matches what was measured", and that check is not sufficient: a terminal can
---change its pixel geometry without changing the grid at all. WezTerm does it
---on every launch -- measured on both 20240203-110809-5046fc22 and
---20260805-104032, it sizes the pty at half scale and corrects it about two
---seconds later, with the row and column counts identical throughout. A
---measurement taken in that window was cached for the rest of the session, and
---every overlay rectangle came out at half scale for it, which is the same
---defect as the rectangles once sized in captured pixels, arriving by a
---different route. A terminal font-size change does the same thing more slowly.
---
---The ioctl costs 0.16 us. The overlay path calls this a handful of times per
---drag frame, so the cache was saving microseconds and risking the one number
---in this plugin that has to be right.
function M.measure()
  if unavailable then return nil, M.reason end

  local sysname = (vim.uv.os_uname() or {}).sysname or ""
  local request = REQUEST[sysname]
  if not request then
    unavailable, M.reason = true, ("no TIOCGWINSZ constant for %s"):format(sysname == "" and "this platform" or sysname)
    return nil, M.reason
  end

  local ffi = ffi_handle()
  if not ffi then
    unavailable, M.reason = true, "LuaJIT ffi is unavailable"
    return nil, M.reason
  end

  local cols, rows, xpixel, ypixel = M.read_winsize(ffi, request)
  if not cols then
    M.reason = "TIOCGWINSZ was refused (no terminal on stdout?)"
    return nil, M.reason
  end

  if cols <= 0 or rows <= 0 or xpixel <= 0 or ypixel <= 0 then
    M.reason = "the terminal reports no pixel geometry (ws_xpixel/ws_ypixel are zero)"
    return nil, M.reason
  end

  local width, height = xpixel / cols, ypixel / rows
  if width < MIN_CELL_PX or width > MAX_CELL_PX or height < MIN_CELL_PX or height > MAX_CELL_PX then
    M.reason = ("implausible cell size %.2fx%.2f px from TIOCGWINSZ"):format(width, height)
    return nil, M.reason
  end

  M.reason = nil
  return { width = width, height = height, cols = cols, rows = rows }
end

---A one-line summary for `:MdViewerHealth` and `:MdViewerDebug`.
function M.describe()
  local cell, reason = M.measure()
  if not cell then return ("unmeasured (%s)"):format(reason) end
  return ("%.2fx%.2f px per cell (%dx%d cells reported by TIOCGWINSZ)"):format(
    cell.width,
    cell.height,
    cell.cols,
    cell.rows
  )
end

return M
