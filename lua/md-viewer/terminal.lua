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

-- `selection_overlay` is the per-profile gate for the selection-highlight
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
--     and watched across repeated selection extensions -- the case that
--     matters, since the defect these were enabled after gave one correct
--     highlight and then none.
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

-- `default_raw_zindex` is -3 for every profile that speaks the Kitty graphics
-- protocol, so animation frames always have -2 to themselves and the selection
-- overlay -1. The layers must not coincide: the protocol breaks a z-index tie
-- by image id ("the image with the lower id is considered to have the lower
-- z-index"), and md-viewer re-uploads the base image on every full frame, so a
-- base sharing an upper layer climbs above it and stays there. -3, -2 and -1
-- render identically for the base -- all are under text and over the cell
-- background -- so this costs nothing on profiles that never animate or draw
-- an overlay, and it means the default stack needs no "lowered from" slide in
-- `resolve_layers`: what the profile declares is what is emitted.

-- Every caveat carries a `kind`, and the distinction is load-bearing rather
-- than decorative: `warn` means something may actually misbehave and the
-- reader can do something about it, `note` means this is how md-viewer knows
-- what it knows. Only `warn` is surfaced to a reader -- in `:MdViewerHealth`'s
-- warnings list and `:MdViewerDebug`'s terminal caveats -- and `note` never is.
-- Notes live here, where they explain why the code does what it does;
-- the reader-facing per-terminal status is docs/terminal-support.md. A validation
-- record ("this was photographed working on 2026-08-07") describes this
-- project's testing, not the session in front of the user, and putting it in a
-- diagnostic taught readers to skim past everything else in it.
M.profiles = {
  iterm2 = {
    id = "iterm2",
    label = "iTerm2",
    -- -3 rather than -1 so animation frames get their own layer at -2 and the
    -- selection overlay its own at -1: base below frames below highlight, all
    -- below Neovim's text (Kitty draws z<0 under text). The overlay probe ran
    -- its base two layers under the overlay through every check, so that
    -- relative stack is what was validated. See the note above M.profiles for
    -- why every Kitty-protocol profile shares it.
    default_raw_zindex = -3,
    default_double_buffer = true,
    selection_overlay = true,
    -- Animation is a *mode*, not a flag, because two different workloads hide
    -- behind the word. "frames" is client-driven: one placement swap per
    -- frame, the same operation as an overlay crop, so the profiles validated
    -- for the overlay are the profiles validated for it. "native" hands the
    -- Kitty protocol's own animation extension (a=f frame data, a=a playback)
    -- to the terminal and walks away -- a different protocol surface that
    -- being good at placements says nothing about. Like every capability
    -- here, a mode is only ever promoted after someone watched it; until
    -- then `terminal.animation = "native"` exists precisely so someone can.
    animation = {
      mode = "frames",
      evidence = "client-driven frame placements ride the operator-validated overlay machinery; "
        .. "the terminal-driven animation extension is unverified here",
    },
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
    default_raw_zindex = -3,
    default_double_buffer = true,
    selection_overlay = true,
    -- "frames" even though Kitty is the animation extension's own reference
    -- implementation: the mode table's rule is that nothing is promoted on
    -- reasoning, and the native path has not yet been watched on real
    -- hardware. scripts/animation/ is the qualification run; flip this to
    -- "native" (evidence and all) once it passes there, and users can flip it
    -- early for themselves with `terminal.animation = "native"`.
    animation = {
      mode = "frames",
      evidence = "client-driven frame placements validated by the operator (2026-08-08); native "
        .. "playback is protocol-documented for Kitty but pending the scripts/animation run",
    },
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
    default_raw_zindex = -3,
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
    -- placement churn and not the environment. Holding a selection extension
    -- (repeated `j`/`l` under `v`/`V`) at speed would exhaust a laptop's
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
    -- Off for the same upstream defect, and more firmly. #7953 duplicates a
    -- cell's attachment list on every repeat placement over it -- that is per
    -- placement, not per second, so a slower tick does not make it safe, only
    -- slower. A held selection extension ends; a preview stays open. Re-qualify
    -- with scripts/overlay/geometry and scripts/overlay/stress before flipping
    -- it.
    animation = {
      mode = "off",
      evidence = "not validated for animation: wezterm/wezterm#7953 grows the terminal's memory on "
        .. "every repeat placement over a covered cell",
    },
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
    -- -3 for the same reason as iTerm2: animation frames and the selection
    -- overlay each need a layer of their own. Ghostty is stricter about this
    -- than iTerm2 -- it sorts
    -- placements by (z, image id) and rebuilds that list from an unordered map
    -- every frame, so a base sharing the overlay's layer wins on image id the
    -- moment it is re-uploaded, with no creation order to fall back on. See
    -- `resolve_layers` in backends/kitty_raw.lua.
    default_raw_zindex = -3,
    default_double_buffer = true,
    selection_overlay = true,
    -- "frames": client-driven placement swaps ride the same machinery the
    -- overlay validated. Ghostty's support for the protocol's *animation
    -- extension* (a=f/a=a) is unverified here -- `terminal.animation =
    -- "native"` plus the scripts/animation run is how that changes.
    animation = {
      mode = "frames",
      evidence = "client-driven frame placements validated by the operator (2026-08-08); the "
        .. "terminal-driven animation extension is unverified here",
    },
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
    default_raw_zindex = -3,
    default_double_buffer = true,
    placement = { deletion = "by-id", crop = "cropped-placements" },
    -- Explicit rather than absent, which reads the same to `M.capability` but
    -- records something absence cannot: the overlay was *tried* here, under
    -- `interaction.selection_overlay = "on"`, and it failed. See the caveat
    -- below. WezTerm's `selection_overlay = false` is spelled out for the same
    -- reason.
    selection_overlay = false,
    -- Experimental, not Supported: launched and watched, with three defects
    -- found. Animation stays off on the table's own default, having never been
    -- watched here.
    validation = "operator-driven (2026-08-11, macOS); experimental -- image rendering watched, "
      .. "three defects found, overlay qualified and failed, animation never watched",
    caveats = {
      -- A note, not a warning: it explains why the overlay is off rather than
      -- asking the reader to do anything, and the warning list is only for
      -- things they can act on.
      {
        kind = "note",
        text = "Warp ignores Kitty placement ids (warpdotdev/Warp#7789): re-placing the same image id "
          .. "and placement id does not replace the previous placement, so an image can only be "
          .. "replaced by deleting it first. The selection-highlight overlay is off there for that reason.",
      },
      {
        kind = "warn",
        text = "A Neovim Visual selection painted over the preview can blank the image in Warp. The "
          .. "protocol puts only z < INT32_MIN/2 beneath a non-default cell background, and this "
          .. "backend places at -3, so a highlight should composite over the image rather than "
          .. "replace it. md-viewer keeps Neovim out of its own visual mode over the surface instead "
          .. "of relying on that; image.raw_zindex = 1 is the fallback if one still gets through.",
      },
      {
        kind = "note",
        text = "Preview text rendered about twice its configured size here until the cell-unit "
          .. "heuristic landed: Warp's reported pixel geometry did not survive being divided by "
          .. "render.device_scale_factor. See coordinates.cell_metrics and `cell unit` in health.",
      },
      {
        kind = "note",
        text = "The drag-highlight overlay was qualified here on 2026-08-11 with "
          .. "interaction.selection_overlay=on, and failed. An overlay rectangle is a crop taken "
          .. "out of a viewport-sized tint sheet, placed with no c/r keys so it draws at natural "
          .. "pixel size; Warp drew each one far larger than the crop asked for, anchored at the "
          .. "placement cell and running to the edge of the split. Photographed twice: a one-glyph "
          .. "caret block covered most of the preview. Sizing a sheet per rectangle instead would "
          .. "mean an upload per rectangle per frame, which is the cost the overlay exists to "
          .. "avoid, so this is off rather than re-encoded the way WezTerm's offset was.",
      },
    },
  },
  generic_kitty = {
    id = "generic_kitty",
    label = "Kitty-compatible (TERM only)",
    default_raw_zindex = -3,
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
    -- backend, so the "lowered from" note in :MdViewerDebug's `base layer`
    -- row only ever appears for a deliberate image.raw_zindex override,
    -- where it means something.
    default_raw_zindex = -3,
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

--- Report whether this Neovim is running on the far side of an SSH connection.
--- Returns a boolean and the matched evidence string (or nil).
---
--- The evidence names the variable but never its value. SSH_CONNECTION and
--- SSH_CLIENT hold the client's IP address and both ends' ports, and this
--- feeds :MdViewerDebug, whose whole purpose is to be pasted into a public
--- issue. Which variable was set is the entire diagnostic value here; the
--- addresses in it are not.
function M.ssh(env)
  env = env or default_env()
  for _, key in ipairs({ "SSH_CONNECTION", "SSH_TTY", "SSH_CLIENT" }) do
    local value = env[key]
    if value and value ~= "" then return true, key end
  end
  return false, nil
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

-- iTerm2 and WezTerm both export LC_TERMINAL (and LC_TERMINAL_VERSION) for one
-- reason: OpenSSH forwards LC_* by default -- `SendEnv LANG LC_*` ships in the
-- stock client config, `AcceptEnv LANG LC_*` in the stock sshd config -- while
-- nothing forwards TERM_PROGRAM. Over SSH it is the only terminal evidence that
-- survives the hop, and without reading it a remote Neovim identifies no
-- terminal at all and drops to the text-cell fallback on a session whose
-- terminal supports graphics perfectly well.
--
-- It is weaker than the native variables above in one specific way, so it is
-- checked after all of them. LC_TERMINAL is exported, which means it is
-- *inherited* by whatever the terminal launches: a VS Code window started from
-- iTerm2 reports TERM_PROGRAM=vscode alongside a stale LC_TERMINAL=iTerm2, and
-- VS Code's terminal speaks no graphics protocol. Believing LC_TERMINAL there
-- would turn on Kitty graphics against a terminal that has none. So it is only
-- trusted when nothing else has claimed the session -- TERM_PROGRAM absent or
-- empty, which is exactly the SSH case and never the nested-terminal one.
-- A terminal that sets both agrees with itself and has already matched above.
local LC_TERMINAL_PROFILES = { iTerm2 = "iterm2", WezTerm = "wezterm" }

local function lc_terminal_profile(env)
  local name = env.LC_TERMINAL
  if not name or name == "" then return nil end
  if env.TERM_PROGRAM and env.TERM_PROGRAM ~= "" then return nil end
  local profile_id = LC_TERMINAL_PROFILES[name]
  if not profile_id then return nil end
  local evidence = { "LC_TERMINAL=" .. name }
  if env.LC_TERMINAL_VERSION and env.LC_TERMINAL_VERSION ~= "" then
    evidence[#evidence + 1] = "LC_TERMINAL_VERSION=" .. env.LC_TERMINAL_VERSION
  end
  return profile_id, evidence
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
  local lc_profile, lc_evidence = lc_terminal_profile(env)
  if lc_profile then return lc_profile, lc_evidence end
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
---
--- The profile itself resolves `terminal.profile` > `$MD_VIEWER_TERMINAL_PROFILE`
--- > inference. The environment override exists for the case config cannot
--- serve: one `~/.config/nvim` copied to many remote hosts, reached from
--- whichever terminal is in front of you that day. A profile hardcoded in that
--- shared config is wrong the moment the terminal changes, whereas an
--- environment variable travels with the session. Same reasoning, and the same
--- precedence, as MD_VIEWER_CELL_WIDTH_PX in md-viewer.cellpixels.
function M.capability(cfg, env)
  cfg = cfg or {}
  env = env or default_env()

  -- A misspelled override is reported rather than silently ignored: it is set
  -- on the far end of an SSH connection, where "nothing happened" is the
  -- hardest possible symptom to chase.
  local env_profile, rejected_env_profile = env.MD_VIEWER_TERMINAL_PROFILE, nil
  if env_profile == "" then env_profile = nil end
  if env_profile and not M.profiles[env_profile] then
    env_profile, rejected_env_profile = nil, env_profile
  end

  local profile_id, evidence
  if cfg.profile and cfg.profile ~= "auto" then
    profile_id = cfg.profile
    evidence = { ("terminal.profile=%s (explicit override)"):format(cfg.profile) }
  elseif env_profile then
    profile_id = env_profile
    evidence = { ("MD_VIEWER_TERMINAL_PROFILE=%s (environment override)"):format(env_profile) }
  else
    profile_id, evidence = M.match_profile(env)
  end

  local profile = M.profiles[profile_id]
  if not profile then
    local requested = profile_id
    profile_id, profile = "unknown", M.profiles.unknown
    evidence = { ("terminal.profile=%q is not a known profile; defaulted to unknown"):format(tostring(requested)) }
  end

  if rejected_env_profile then
    evidence[#evidence + 1] = ("MD_VIEWER_TERMINAL_PROFILE=%q is not a known profile; ignored"):format(
      rejected_env_profile
    )
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

  -- Animation resolves to `{ mode, evidence }` unconditionally. Profiles that
  -- say nothing are off -- the conservative default for warp, generic_kitty
  -- and unknown -- and an explicit `terminal.animation` override replaces the
  -- profile's answer wholesale, evidence included, because the override IS the
  -- evidence: the user asserting a mode for a terminal this table does not
  -- (yet) trust is exactly how a new terminal gets qualified.
  local animation = profile.animation
  if type(animation) ~= "table" or type(animation.mode) ~= "string" then
    animation = {
      mode = "off",
      evidence = ("profile %s is not validated for animation frame placements"):format(profile_id),
    }
  end
  if cfg.animation == "native" or cfg.animation == "frames" or cfg.animation == "off" then
    animation = {
      mode = cfg.animation,
      evidence = ("terminal.animation=%s (explicit override)"):format(cfg.animation),
    }
  end

  local mux, mux_evidence = M.multiplexer(env)
  local ssh, ssh_evidence = M.ssh(env)
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

  -- An unidentified terminal is ordinary and self-explanatory locally; over
  -- SSH it is a specific, fixable defect with a non-obvious cause, and the
  -- diagnostic that says only "unknown" sends the reader after the wrong
  -- thing entirely -- usually the renderer, which is running fine.
  if ssh and profile_id == "unknown" then
    caveats[#caveats + 1] = {
      kind = "warn",
      text = (
        "Running over SSH (%s) with no terminal evidence: SSH does not forward "
        .. "TERM_PROGRAM, so the terminal could not be identified and the preview "
        .. "falls back to text. iTerm2 and WezTerm are recognized through LC_TERMINAL "
        .. "when this host's sshd accepts it (AcceptEnv LANG LC_*); for any other "
        .. "terminal set MD_VIEWER_TERMINAL_PROFILE or terminal.profile on this host."
      ):format(ssh_evidence),
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
    default_double_buffer = profile.default_double_buffer,
    -- Only ever true for profiles someone actually looked at, by eye or by
    -- photograph; see the comment above M.profiles.
    selection_overlay = profile.selection_overlay == true,
    animation = animation,
    overlay_encoding = profile.overlay_encoding or "sub-cell-offset",
    placement = profile.placement,
    multiplexer = mux,
    multiplexer_evidence = mux_evidence,
    ssh = ssh,
    ssh_evidence = ssh_evidence,
    validation = profile.validation,
    caveats = caveats,
  }
end

-- Capability resolution snapshots the whole process environment
-- (vim.fn.environ()), reads uname, and deep-copies profile caveats. Callers
-- reach M.detect() on every placement and, while animating, several times per
-- tick -- through zindex resolution and animation gating -- so an unmemoized
-- walk is thousands of environment snapshots per minute. The environment
-- cannot change under a running Neovim; the config half can, and
-- config.setup()/reset() invalidate this cache when it does.
local detected = nil

--- Convenience entry point used by backend selection and diagnostics: reads
--- live configuration and the real process environment, memoized until the
--- configuration changes.
function M.detect()
  if detected then return detected end
  local config = require("md-viewer.config")
  detected = M.capability(config.get().terminal)
  return detected
end

--- Effective double-buffer policy and where it came from: an explicit
--- `image.double_buffer` always wins; otherwise the active terminal profile's
--- default; otherwise `true`.
---
--- This lives here rather than in a backend because the profile table it reads
--- lives here, and because *every* backend that replaces an image needs the
--- same answer. It used to exist only in `backends/kitty_raw.lua`, and
--- `backends/nvim_img.lua` grew its own copy that read `image.double_buffer`
--- directly -- which reads `nil` (the default, meaning "ask the profile") as
--- false and so chose delete-then-create, blanking the preview for one frame on
--- every render. `backends/init.lua` prefers `nvim_img` on any Neovim 0.12 with
--- `vim.ui.img`, so that defect was live on every terminal, not just the ones
--- without a profile default. One resolver, one answer.
---
--- Returns `enabled, source`.
function M.double_buffer()
  local explicit = require("md-viewer.config").get().image.double_buffer
  if explicit ~= nil then return explicit, "explicit override (image.double_buffer)" end
  local capability = M.detect()
  local default = capability.default_double_buffer
  if default == nil then default = true end
  return default, ("profile default (%s)"):format(capability.profile_id)
end

--- Drop the memoized capability snapshot. Called by config.setup()/reset();
--- tests that stub the environment go through M.capability directly, which is
--- never cached.
function M.invalidate() detected = nil end

return M
