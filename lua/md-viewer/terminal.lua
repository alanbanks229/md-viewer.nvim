-- Terminal capability model.
--
-- Neovim owns terminal input, so this module never performs a synchronous
-- protocol probe: doing so would race (and potentially steal) user
-- keystrokes. Every conclusion reached from environment variables or a
-- profile match is reported as "inferred", never "verified". "verified" is
-- reserved for capabilities Neovim itself confirms (vim.ui.img), which this
-- module does not decide — see md-viewer.backends.nvim_img and
-- md-viewer.backends.init for that half of the resolution order.
local M = {}

local function default_env() return vim.fn.environ() end

--- Static, terminal-specific metadata. Evidence, platform, and multiplexer
--- state are runtime facts and are attached by M.capability(), not stored
--- here.
-- `default_double_buffer` is the profile's default answer to "should
-- placement replacement show the new image before deleting the old one
-- (place-then-delete, avoids a blank frame) or the reverse?". Every profile
-- below implements the same Kitty graphics protocol with the same placement
-- semantics, so this is uniformly `true` today; it is still sourced from the
-- profile (not hardcoded in the encoder) so a future profile with a real,
-- verified reason to differ has somewhere to say so. `image.double_buffer`
-- in user config always overrides it.

M.profiles = {
  iterm2 = {
    id = "iterm2",
    label = "iTerm2",
    default_raw_zindex = -1,
    default_double_buffer = true,
    placement = { deletion = "by-id", crop = "cropped-placements" },
    validation = "protocol-compatible-but-unvalidated",
    caveats = {
      "iTerm2 advertises the Kitty graphics protocol, but md-viewer does not run a "
        .. "synchronous response probe (Neovim owns terminal input), so this remains inferred.",
    },
  },
  kitty = {
    id = "kitty",
    label = "Kitty",
    default_raw_zindex = -1,
    default_double_buffer = true,
    placement = { deletion = "by-id", crop = "cropped-placements" },
    validation = "protocol-compatible-but-unvalidated",
    caveats = {
      "Kitty is the reference implementation of the graphics protocol this backend uses.",
    },
  },
  wezterm = {
    id = "wezterm",
    label = "WezTerm",
    default_raw_zindex = -1,
    default_double_buffer = true,
    placement = { deletion = "by-id", crop = "cropped-placements" },
    validation = "protocol-compatible-but-unvalidated",
    caveats = {
      "WezTerm implements the Kitty graphics protocol.",
    },
  },
  ghostty = {
    id = "ghostty",
    label = "Ghostty",
    default_raw_zindex = -1,
    default_double_buffer = true,
    placement = { deletion = "by-id", crop = "cropped-placements" },
    validation = "protocol-compatible-but-unvalidated",
    caveats = {
      "Ghostty implements the Kitty graphics protocol.",
    },
  },
  warp = {
    id = "warp",
    label = "Warp",
    default_raw_zindex = -1,
    default_double_buffer = true,
    placement = { deletion = "by-id", crop = "cropped-placements" },
    validation = "protocol-compatible-but-unvalidated",
    caveats = {
      "Warp's Kitty graphics support has been inconsistent across releases; "
        .. "placement and deletion behavior is unverified.",
    },
  },
  generic_kitty = {
    id = "generic_kitty",
    label = "Kitty-compatible (TERM only)",
    default_raw_zindex = -1,
    default_double_buffer = true,
    placement = { deletion = "by-id", crop = "cropped-placements" },
    validation = "protocol-compatible-but-unvalidated",
    caveats = {
      "Only the TERM variable advertises Kitty graphics; no terminal-specific marker was "
        .. "found. This is the weakest signal md-viewer accepts automatically.",
    },
  },
  unknown = {
    id = "unknown",
    label = "Unknown terminal",
    default_raw_zindex = -1,
    default_double_buffer = true,
    placement = { deletion = "unsupported", crop = "unsupported" },
    validation = "not-attempted",
    caveats = { "No evidence of Kitty graphics protocol support was found." },
  },
}

--- Identify which multiplexer, if any, wraps this session.
--- Returns the multiplexer id and the matched evidence string (or nil).
function M.multiplexer(env)
  env = env or default_env()
  if env.TMUX and env.TMUX ~= "" then return "tmux", "TMUX=" .. env.TMUX end
  if env.ZELLIJ and env.ZELLIJ ~= "" then return "zellij", "ZELLIJ=" .. env.ZELLIJ end
  if env.STY and env.STY ~= "" then return "screen", "STY=" .. env.STY end
  return "none", nil
end

--- Report the host platform: "macos", "linux", "windows", or the raw
--- lower-cased sysname if unrecognized.
function M.platform()
  local uname = vim.uv.os_uname()
  local sysname = uname and uname.sysname or ""
  if sysname == "Darwin" then return "macos" end
  if sysname == "Linux" then return "linux" end
  if sysname:match("^Windows") or sysname:match("^MINGW") or sysname:match("^MSYS") then return "windows" end
  return sysname ~= "" and sysname:lower() or "unknown"
end

local function warp_evidence(env)
  local found = {}
  for key, value in pairs(env) do
    if type(key) == "string" and key:match("^WARP_") then found[#found + 1] = key .. "=" .. tostring(value) end
  end
  table.sort(found)
  return found
end

--- Infer a terminal profile id purely from environment evidence. Returns the
--- profile id and the list of evidence strings that produced it.
function M.match_profile(env)
  env = env or default_env()
  if env.TERM_PROGRAM == "iTerm.app" then
    local evidence = { "TERM_PROGRAM=iTerm.app" }
    if env.TERM_PROGRAM_VERSION and env.TERM_PROGRAM_VERSION ~= "" then
      evidence[#evidence + 1] = "TERM_PROGRAM_VERSION=" .. env.TERM_PROGRAM_VERSION
    end
    return "iterm2", evidence
  end
  if env.KITTY_WINDOW_ID and env.KITTY_WINDOW_ID ~= "" then
    return "kitty", { "KITTY_WINDOW_ID=" .. env.KITTY_WINDOW_ID }
  end
  if env.WEZTERM_EXECUTABLE and env.WEZTERM_EXECUTABLE ~= "" then
    return "wezterm", { "WEZTERM_EXECUTABLE=" .. env.WEZTERM_EXECUTABLE }
  end
  if env.GHOSTTY_RESOURCES_DIR and env.GHOSTTY_RESOURCES_DIR ~= "" then
    return "ghostty", { "GHOSTTY_RESOURCES_DIR=" .. env.GHOSTTY_RESOURCES_DIR }
  end
  local warp = warp_evidence(env)
  if env.TERM_PROGRAM == "WarpTerminal" or #warp > 0 then
    local evidence = {}
    if env.TERM_PROGRAM == "WarpTerminal" then evidence[#evidence + 1] = "TERM_PROGRAM=WarpTerminal" end
    vim.list_extend(evidence, warp)
    return "warp", evidence
  end
  if env.TERM and env.TERM:match("kitty") then return "generic_kitty", { "TERM=" .. env.TERM } end
  return "unknown", {}
end

--- Resolve full terminal capability from configuration plus environment
--- evidence. `cfg` is the `terminal` config section (profile, kitty_graphics,
--- probe); `env` is injectable for tests and defaults to the real process
--- environment.
---
--- Resolution order (see prompts/part-1-foundations.md 1.2):
--- 1. explicit `cfg.kitty_graphics` pins graphics availability outright.
--- 2. (handled by callers) verified vim.ui.img support.
--- 3. a safe asynchronous probe — unimplemented; `cfg.probe` stays "off".
--- 4. conservative profile inference from environment evidence.
--- 5. text-cell fallback (graphics = "unavailable").
function M.capability(cfg, env)
  cfg = cfg or {}
  env = env or default_env()

  local profile_id, evidence
  if cfg.profile and cfg.profile ~= "auto" then
    profile_id = cfg.profile
    evidence = { ("terminal.profile=%s (explicit override)"):format(cfg.profile) }
  else
    profile_id, evidence = M.match_profile(env)
  end

  local profile = M.profiles[profile_id]
  if not profile then
    profile_id, profile = "unknown", M.profiles.unknown
    evidence = { ("terminal.profile=%q is not a known profile; defaulted to unknown"):format(tostring(profile_id)) }
  end

  local graphics, reason
  if cfg.kitty_graphics == "on" then
    graphics = "explicit"
    reason = "terminal.kitty_graphics=on (explicit override)"
  elseif cfg.kitty_graphics == "off" then
    graphics = "unavailable"
    reason = "terminal.kitty_graphics=off (explicit override)"
  elseif profile_id == "unknown" then
    graphics = "unavailable"
    reason = "no terminal graphics evidence found; defaulting to text-cell fallback"
  else
    graphics = "inferred"
    reason = "inferred from " .. (evidence[1] or profile_id)
  end

  local mux, mux_evidence = M.multiplexer(env)
  local caveats = vim.deepcopy(profile.caveats or {})
  if mux ~= "none" then
    caveats[#caveats + 1] = (
      "Running inside %s (%s); md-viewer does not adjust placement for "
      .. "multiplexers and image position may be wrong."
    ):format(mux, mux_evidence)
  end

  return {
    profile_id = profile_id,
    label = profile.label,
    evidence = evidence,
    platform = M.platform(),
    graphics = graphics,
    reason = reason,
    default_raw_zindex = profile.default_raw_zindex,
    placement = profile.placement,
    multiplexer = mux,
    multiplexer_evidence = mux_evidence,
    validation = profile.validation,
    caveats = caveats,
  }
end

--- Convenience entry point used by backend selection and diagnostics: reads
--- live configuration and the real process environment.
function M.detect()
  local config = require("md-viewer.config")
  return M.capability(config.get().terminal)
end

return M
