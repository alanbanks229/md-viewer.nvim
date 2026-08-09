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

-- `selection_overlay` is the per-profile gate for the drag-highlight
-- overlay (translucent natural-size Kitty placements composited over the base
-- image): alpha compositing image-over-image, crop placements without c/r,
-- sub-cell X/Y offsets, z ordering between images, 40fps placement churn, and
-- clean deletion. "Implements the Kitty graphics protocol" is not sufficient
-- evidence for any of it -- WezTerm implements it and crashed outright on this
-- workload.
--
-- The flag says whether md-viewer sends that workload. `validation` says how
-- much is actually known, and the two grades are not the same thing:
--   * iTerm2, Ghostty and Kitty were each driven by hand in a real terminal
--     and watched across repeated drags -- the case that matters, since the
--     defect these were enabled after gave one correct highlight and then
--     none.
--   * Kitty was enabled a few hours ahead of that confirmation, on the
--     strength of being the protocol's own reference implementation. That was
--     a decision about what to send, and the `validation` string said
--     "confirmation pending" until someone looked. Never promote a
--     `validation` string on reasoning alone.
-- Anything weaker stays `false` and keeps the full-frame capture path, which
-- is always correct and merely slower.

-- `overlay_encoding` is how a selection rectangle's sub-cell position is
-- expressed. Two values:
--
--   * "sub-cell-offset" (the default, and what every profile but WezTerm uses):
--     the placement carries the Kitty protocol's `X`/`Y` keys, which say how far
--     into its first cell the image starts.
--   * "sheet-margin": no `X`/`Y` keys at all. The tint sheet carries a
--     transparent margin of one cell on each axis, and the crop starts
--     `cell - offset` pixels into it, so the placement's leading pixels come out
--     transparent and the tint begins exactly where the rectangle does.
--
-- The second exists for one measured defect. WezTerm applies `X`/`Y` to *every*
-- cell of a placement rather than only the first, and applies it as an inset:
-- each cell paints `cell - X` pixels wide. A 960px highlight bar at X=3 draws as
-- 60 separate 13px runs with 3px of untinted base between each -- photographed
-- on both 20240203-110809-5046fc22 and 20260805-104032-4b1c3c15, which are
-- identical here. Moving the offset into the image leaves nothing for WezTerm to
-- inset per cell, and it stays one placement per rectangle.
--
-- The default path is untouched, byte for byte, and
-- `tests/lua/cases/backend_kitty.lua` pins that as a golden stream.

-- `default_raw_zindex` is -2 for every profile that speaks the Kitty graphics
-- protocol, so the selection overlay always has -1 to itself. The two layers
-- must not coincide: the protocol breaks a z-index tie by image id ("the image
-- with the lower id is considered to have the lower z-index"), and md-viewer
-- re-uploads the base image on every full frame, so a base sharing the
-- overlay's layer climbs above it and stays there. -2 and -1 render
-- identically for the base -- both are under text and over the cell background
-- -- so this costs nothing on profiles that never draw an overlay, and it
-- means turning one on later is a one-line change rather than a layer audit.

-- Every caveat carries a `kind`, and the distinction is load-bearing rather
-- than decorative: `warn` means something may actually misbehave and the
-- reader can do something about it, `note` means this is how md-viewer knows
-- what it knows. Only `warn` is reported by `:MdViewerHealth`, concise or
-- verbose. Notes live here, where they explain why the code does what it does;
-- the reader-facing per-terminal status is docs/manual-testing.md. A validation
-- record ("this was photographed working on 2026-08-07") describes this
-- project's testing, not the session in front of the user, and putting it in a
-- diagnostic taught readers to skim past everything else in it.
M.profiles = {
  iterm2 = {
    id = "iterm2",
    label = "iTerm2",
    -- -2 rather than -1 so the selection overlay gets its own layer at -1:
    -- base below highlight, both below Neovim's text (Kitty draws z<0 under
    -- text). The probe ran its base at -2 through every check, so this exact
    -- configuration is what was validated. See the note above M.profiles for
    -- why every Kitty-protocol profile now shares it.
    default_raw_zindex = -2,
    default_double_buffer = true,
    selection_overlay = true,
    placement = { deletion = "by-id", crop = "cropped-placements" },
    validation = "operator-validated (drag-highlight overlay, 2026-08-07)",
    caveats = {
      {
        kind = "note",
        text = "iTerm2 advertises the Kitty graphics protocol, but md-viewer does not run a "
          .. "synchronous response probe (Neovim owns terminal input), so this remains inferred.",
      },
      {
        kind = "note",
        text = "Selection-overlay placements (alpha compositing, sub-cell offsets, placement churn) "
          .. "were validated by the operator in a live iTerm2 session on 2026-08-07.",
      },
    },
  },
  kitty = {
    id = "kitty",
    label = "Kitty",
    default_raw_zindex = -2,
    default_double_buffer = true,
    selection_overlay = true,
    placement = { deletion = "by-id", crop = "cropped-placements" },
    validation = "operator-validated (2026-08-08)",
    caveats = {
      {
        kind = "note",
        text = "Kitty is the reference implementation of the graphics protocol this backend uses: the "
          .. "sub-cell X/Y offsets, natural-size crops and same-z image-id ordering the selection "
          .. "overlay depends on are defined by its own specification.",
      },
      {
        kind = "note",
        text = "Selection-overlay placements were confirmed by the operator on 2026-08-08 across repeated "
          .. "drags -- the case that matters, since the defect this profile was enabled after gave "
          .. "one correct highlight and then none.",
      },
    },
  },
  wezterm = {
    id = "wezterm",
    label = "WezTerm",
    default_raw_zindex = -2,
    default_double_buffer = true,
    -- The only profile that does not express sub-cell position with the
    -- protocol's own X/Y keys. See the note above M.profiles for the measured
    -- reason, and `overlay_placement_sequence` in backends/kitty_raw.lua for
    -- the encoding.
    overlay_encoding = "sheet-margin",
    -- The geometry is solved and photographed; the cost is not. Sustained
    -- placement traffic grows WezTerm's resident memory without bound -- 172 MB
    -- to 786 MB in four seconds with as few as four rectangles being replaced
    -- at 40fps, on both builds, while md-viewer's own live-placement count
    -- stays flat at four. A control that places the base image and then sends
    -- nothing holds steady at 173 MB for the same duration, so it is the
    -- placement churn and not the environment. A drag would exhaust a laptop's
    -- memory in seconds; this measurement cost one, twice.
    --
    -- The cause is upstream and now identified: WezTerm's `assign_image_to_cells`
    -- clones a cell (which already carries its image attachments), adds the new
    -- placement, and writes it back through `Line::set_cell`, which merges the
    -- old cell's attachments in again -- so every repeat placement over an
    -- already-covered cell duplicates the attachment list, and the renderer
    -- emits a quad per attachment. Reported as wezterm/wezterm#7953, with a fix
    -- proposed in wezterm/wezterm#8035.
    --
    -- So the encoding stays (it is correct, and it is what a fixed build would
    -- use) and the flag stays off. WezTerm keeps the full-frame capture path,
    -- which is correct and merely slower. To re-open this once a released build
    -- carries the fix: run scripts/overlay/geometry and scripts/overlay/stress
    -- against it, and flip the flag only if both pass.
    selection_overlay = false,
    placement = { deletion = "by-id", crop = "cropped-placements" },
    validation = "geometry pixel-verified by automated screenshot on 20240203-110809-5046fc22 and "
      .. "20260805-104032-4b1c3c15 (2026-08-08); overlay disabled -- placement churn grows the "
      .. "terminal's memory without bound",
    caveats = {
      {
        kind = "note",
        text = "WezTerm implements the Kitty graphics protocol -- z-indices, crop keys, natural-size "
          .. "placements without c/r, sub-cell X/Y offsets, placement ids and by-id deletion -- "
          .. "and reports pty pixel geometry, so md-viewer can measure its cell.",
      },
      {
        kind = "note",
        text = "WezTerm applies the X/Y sub-cell offset to every cell of a placement instead of only the "
          .. "first as the protocol specifies, and applies it as an inset: each cell paints "
          .. "cell-minus-X pixels wide. A 960px bar at X=3 was photographed as 60 separate 13px "
          .. "runs. md-viewer therefore sends WezTerm no X/Y keys at all and expresses the offset "
          .. "in the tint sheet instead (overlay_encoding = sheet-margin), which was photographed "
          .. "as one solid bar on both builds.",
      },
      {
        kind = "note",
        text = "Both builds behave identically here: 20240203-110809-5046fc22 and 20260805-104032-4b1c3c15 "
          .. "were driven through the same checks and passed the same 36 of 36. There is no version "
          .. "boundary and md-viewer does not look for one.",
      },
      {
        kind = "note",
        text = "Sustained placement traffic grows WezTerm's memory without bound, which is why the overlay "
          .. "is off: 172 MB to 786 MB in four seconds with four rectangles replaced at 40fps, and to "
          .. "6.5 GB with seventy, on both builds. md-viewer's own live-placement count stays flat "
          .. "throughout, and an idle control holds at 173 MB, so it is the churn itself. One earlier "
          .. "run died on 'Failed to allocate 23962752 quads' and an unwrap in draw.rs.",
      },
      {
        kind = "note",
        text = "The growth is an upstream defect, not a cost model: WezTerm's assign_image_to_cells writes "
          .. "a cell that already holds its image attachments back through a merging set_cell, so "
          .. "each repeat placement over an already-covered cell duplicates the attachment list and "
          .. "the renderer emits a quad per attachment. Reported as wezterm/wezterm#7953; a fix is "
          .. "proposed in wezterm/wezterm#8035. Re-qualify with scripts/overlay/ once it ships.",
      },
      {
        kind = "note",
        text = "Upstream issue #6344's divide-by-zero panics are unreachable from md-viewer: the cell must "
          .. "floor to at least one pixel and every crop must be at least one pixel and wholly "
          .. "inside its image before anything is emitted.",
      },
    },
  },
  ghostty = {
    id = "ghostty",
    label = "Ghostty",
    -- -2 for the same reason as iTerm2: the selection overlay needs a layer of
    -- its own at -1. Ghostty is stricter about this than iTerm2 -- it sorts
    -- placements by (z, image id) and rebuilds that list from an unordered map
    -- every frame, so a base sharing the overlay's layer wins on image id the
    -- moment it is re-uploaded, with no creation order to fall back on. See
    -- `resolve_layers` in backends/kitty_raw.lua.
    default_raw_zindex = -2,
    default_double_buffer = true,
    selection_overlay = true,
    placement = { deletion = "by-id", crop = "cropped-placements" },
    validation = "operator-validated (2026-08-08)",
    caveats = {
      {
        kind = "note",
        text = "Ghostty implements the Kitty graphics protocol, including the sub-cell X/Y placement "
          .. "offsets, natural-size crops (no c/r keys) and negative z-indices the selection "
          .. "overlay is built on.",
      },
      {
        kind = "note",
        text = "Ghostty breaks a z-index tie by image id (lower id draws underneath), so the base image "
          .. "and the selection overlay must never share a layer; md-viewer keeps them one apart.",
      },
    },
  },
  warp = {
    id = "warp",
    label = "Warp",
    default_raw_zindex = -2,
    default_double_buffer = true,
    placement = { deletion = "by-id", crop = "cropped-placements" },
    validation = "protocol-compatible-but-unvalidated",
    caveats = {
      {
        kind = "warn",
        text = "Warp's Kitty graphics support has been inconsistent across releases; "
          .. "placement and deletion behavior is unverified.",
      },
    },
  },
  generic_kitty = {
    id = "generic_kitty",
    label = "Kitty-compatible (TERM only)",
    default_raw_zindex = -2,
    default_double_buffer = true,
    placement = { deletion = "by-id", crop = "cropped-placements" },
    validation = "protocol-compatible-but-unvalidated",
    caveats = {
      {
        kind = "warn",
        text = "Only the TERM variable advertises Kitty graphics; no terminal-specific marker was "
          .. "found. This is the weakest signal md-viewer accepts automatically.",
      },
    },
  },
  unknown = {
    id = "unknown",
    label = "Unknown terminal",
    -- Matches every other profile even though this one never reaches the raw
    -- backend, so the "lowered from -1" note in :MdViewerHealth only ever
    -- appears for a deliberate image.raw_zindex override, where it means
    -- something.
    default_raw_zindex = -2,
    default_double_buffer = true,
    placement = { deletion = "unsupported", crop = "unsupported" },
    validation = "not-attempted",
    caveats = {
      { kind = "warn", text = "No evidence of Kitty graphics protocol support was found." },
    },
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
--- Resolution order:
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
    caveats[#caveats + 1] = {
      kind = "warn",
      text = (
        "Running inside %s (%s); md-viewer does not adjust placement for "
        .. "multiplexers and image position may be wrong."
      ):format(mux, mux_evidence),
    }
  end

  return {
    profile_id = profile_id,
    label = profile.label,
    evidence = evidence,
    platform = M.platform(),
    graphics = graphics,
    reason = reason,
    default_raw_zindex = profile.default_raw_zindex,
    -- Only ever true for profiles someone actually looked at, by eye or by
    -- photograph; see the comment above M.profiles.
    selection_overlay = profile.selection_overlay == true,
    overlay_encoding = profile.overlay_encoding or "sub-cell-offset",
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
