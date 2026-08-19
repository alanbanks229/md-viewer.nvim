return function(t)
  local terminal = require("md-viewer.terminal")
  local config = require("md-viewer.config")

  -- Profile detection per terminal from synthetic environments.
  local iterm2_id, iterm2_evidence = terminal.match_profile({ TERM_PROGRAM = "iTerm.app" })
  t.eq("iterm2", iterm2_id, "iTerm2 detected from TERM_PROGRAM")
  t.ok(iterm2_evidence[1] == "TERM_PROGRAM=iTerm.app", "iTerm2 evidence names the matched variable")

  local kitty_id = terminal.match_profile({ KITTY_WINDOW_ID = "3" })
  t.eq("kitty", kitty_id, "Kitty detected from KITTY_WINDOW_ID")

  local wezterm_id = terminal.match_profile({ WEZTERM_EXECUTABLE = "/usr/bin/wezterm" })
  t.eq("wezterm", wezterm_id, "WezTerm detected from WEZTERM_EXECUTABLE")

  local ghostty_id = terminal.match_profile({ GHOSTTY_RESOURCES_DIR = "/opt/ghostty" })
  t.eq("ghostty", ghostty_id, "Ghostty detected from GHOSTTY_RESOURCES_DIR")

  local warp_id = terminal.match_profile({ TERM_PROGRAM = "WarpTerminal" })
  t.eq("warp", warp_id, "Warp detected from TERM_PROGRAM")

  local warp_env_id = terminal.match_profile({ WARP_IS_LOCAL_SHELL_SESSION = "1" })
  t.eq("warp", warp_env_id, "Warp detected from a WARP_-prefixed variable alone")

  local generic_id = terminal.match_profile({ TERM = "xterm-kitty" })
  t.eq("generic_kitty", generic_id, "TERM-only Kitty advertisement falls back to generic_kitty")

  local unknown_id, unknown_evidence = terminal.match_profile({})
  t.eq("unknown", unknown_id, "no evidence yields the unknown profile")
  t.eq(0, #unknown_evidence, "unknown profile carries no evidence")

  -- Explicit profile override beats environment inference entirely.
  local overridden = terminal.capability({ profile = "wezterm" }, { TERM_PROGRAM = "iTerm.app" })
  t.eq("wezterm", overridden.profile_id, "explicit terminal.profile overrides environment evidence")

  -- terminal.kitty_graphics = "on"/"off" overrides inference.
  local forced_on = terminal.capability({ kitty_graphics = "on" }, {})
  t.eq("explicit", forced_on.graphics, "kitty_graphics=on forces graphics available even on unknown terminals")

  local forced_off = terminal.capability({ kitty_graphics = "off" }, { TERM_PROGRAM = "iTerm.app" })
  t.eq("unavailable", forced_off.graphics, "kitty_graphics=off forces graphics unavailable despite strong evidence")

  -- Resolution-order precedence: explicit kitty_graphics beats profile inference,
  -- and an explicit profile still respects an explicit kitty_graphics override.
  local pinned = terminal.capability({ profile = "kitty", kitty_graphics = "off" }, {})
  t.eq("kitty", pinned.profile_id, "explicit profile is honored")
  t.eq("unavailable", pinned.graphics, "explicit kitty_graphics still overrides an explicit profile match")

  -- Unknown terminal never infers graphics.
  local plain = terminal.capability({}, { TERM = "xterm-256color" })
  t.eq("unknown", plain.profile_id, "plain xterm has no known evidence")
  t.eq("unavailable", plain.graphics, "unknown terminal never infers graphics availability")

  -- Multiplexer detection.
  t.eq("tmux", (terminal.multiplexer({ TMUX = "/tmp/tmux-501/default,1234,0" })), "tmux detected")
  t.eq("zellij", (terminal.multiplexer({ ZELLIJ = "0" })), "zellij detected")
  t.eq("screen", (terminal.multiplexer({ STY = "1000.pts-0.host" })), "screen detected")
  t.eq("none", (terminal.multiplexer({})), "no multiplexer by default")
  local muxed = terminal.capability({}, { TERM_PROGRAM = "iTerm.app", TMUX = "/tmp/tmux-501/default,1234,0" })
  t.eq("tmux", muxed.multiplexer, "capability report includes multiplexer state")
  local mentions_tmux = false
  for _, caveat in ipairs(muxed.caveats) do
    -- Specifically kind "warn": a multiplexer can actually misplace the image,
    -- which is the distinction that keeps it out of the notes pile and in the
    -- concise health report where someone will read it.
    if caveat.kind == "warn" and caveat.text:match("tmux") then mentions_tmux = true end
  end
  t.ok(mentions_tmux, "multiplexer presence is warned about in caveats")

  -- LC_TERMINAL is the only terminal evidence that survives SSH: OpenSSH
  -- forwards LC_* by default and forwards TERM_PROGRAM never, so without this
  -- branch every remote session identifies no terminal and drops to `cells`.
  local lc_id, lc_evidence = terminal.match_profile({ LC_TERMINAL = "iTerm2" })
  t.eq("iterm2", lc_id, "iTerm2 detected from LC_TERMINAL when TERM_PROGRAM did not survive SSH")
  t.eq("LC_TERMINAL=iTerm2", lc_evidence[1], "LC_TERMINAL evidence names the matched variable")

  local lc_versioned = select(2, terminal.match_profile({ LC_TERMINAL = "iTerm2", LC_TERMINAL_VERSION = "3.6.11" }))
  t.eq(2, #lc_versioned, "a forwarded version is recorded as evidence alongside the name")
  t.eq("LC_TERMINAL_VERSION=3.6.11", lc_versioned[2], "and names the version variable it came from")

  t.eq("wezterm", (terminal.match_profile({ LC_TERMINAL = "WezTerm" })), "WezTerm also identifies itself over SSH")

  -- The gate. LC_TERMINAL is exported, so it is inherited by whatever the
  -- terminal launches: a VS Code window started from iTerm2 really does report
  -- TERM_PROGRAM=vscode beside a stale LC_TERMINAL=iTerm2, and VS Code's
  -- terminal speaks no graphics protocol. Trusting the stale value there would
  -- enable Kitty graphics against a terminal that has none -- a visibly broken
  -- preview, which is strictly worse than the text fallback.
  local nested = terminal.match_profile({ TERM_PROGRAM = "vscode", LC_TERMINAL = "iTerm2" })
  t.eq("unknown", nested, "an inherited LC_TERMINAL is not believed once another terminal claims the session")

  t.eq(
    "kitty",
    (terminal.match_profile({ KITTY_WINDOW_ID = "3", LC_TERMINAL = "iTerm2" })),
    "native evidence outranks a forwarded LC_TERMINAL"
  )
  t.eq(
    "iterm2",
    (terminal.match_profile({ TERM = "xterm-kitty", LC_TERMINAL = "iTerm2" })),
    "but LC_TERMINAL is more specific than a bare TERM advertisement"
  )
  t.eq("unknown", (terminal.match_profile({ LC_TERMINAL = "Terminal.app" })), "an unrecognized LC_TERMINAL is ignored")

  -- SSH detection. The evidence deliberately names the variable and not its
  -- value: SSH_CONNECTION and SSH_CLIENT carry the client's IP address, and
  -- this feeds :MdViewerDebug, which exists to be pasted into public issues.
  for _, key in ipairs({ "SSH_CONNECTION", "SSH_TTY", "SSH_CLIENT" }) do
    local present, evidence = terminal.ssh({ [key] = "10.0.0.4 51000 10.0.0.9 22" })
    t.eq(true, present, ("%s marks the session as remote"):format(key))
    t.eq(key, evidence, ("%s evidence names the variable without its value"):format(key))
  end
  local local_session, local_evidence = terminal.ssh({})
  t.eq(false, local_session, "no SSH variables means a local session")
  t.eq(nil, local_evidence, "and no evidence to report")

  -- An unidentified terminal is ordinary locally and a specific, fixable defect
  -- over SSH, so only the remote case earns a warning -- and it has to name the
  -- fixes, because the debug dump otherwise points at the renderer, which is
  -- working fine.
  local remote_env = { SSH_CONNECTION = "10.0.0.4 51000 10.0.0.9 22", TERM = "xterm-256color" }
  local remote_blind = terminal.capability({}, remote_env)
  t.eq(true, remote_blind.ssh, "capability report includes SSH state")
  t.eq("SSH_CONNECTION", remote_blind.ssh_evidence, "and the variable that established it")
  local ssh_warning
  for _, caveat in ipairs(remote_blind.caveats) do
    if caveat.kind == "warn" and caveat.text:match("SSH") then ssh_warning = caveat.text end
  end
  t.ok(ssh_warning, "an unidentified terminal over SSH is warned about")
  t.ok(ssh_warning:match("LC_TERMINAL"), "the warning names the variable that would have identified it")
  t.ok(ssh_warning:match("MD_VIEWER_TERMINAL_PROFILE"), "and the environment override that fixes it")
  t.ok(ssh_warning:match("terminal%.profile"), "and the config override that also fixes it")

  local function warns_about_ssh(capability)
    for _, caveat in ipairs(capability.caveats) do
      if caveat.kind == "warn" and caveat.text:match("SSH") then return true end
    end
    return false
  end

  local remote_known = terminal.capability({}, { SSH_TTY = "/dev/pts/3", LC_TERMINAL = "iTerm2" })
  t.eq("iterm2", remote_known.profile_id, "a forwarded LC_TERMINAL identifies the terminal over SSH")
  t.eq("inferred", remote_known.graphics, "which is enough to infer graphics and leave the cells fallback")
  t.eq(false, warns_about_ssh(remote_known), "an identified SSH session is not warned about")

  local local_blind = terminal.capability({}, { TERM = "xterm-256color" })
  t.eq(false, local_blind.ssh, "a local session is reported as such")
  t.eq(false, warns_about_ssh(local_blind), "and an unidentified local terminal gets no SSH advice")

  -- MD_VIEWER_TERMINAL_PROFILE exists for one `~/.config/nvim` copied across
  -- many hosts: a profile hardcoded in that shared config is wrong the moment
  -- the terminal in front of you changes, but an environment variable travels
  -- with the session.
  local env_override = terminal.capability({}, { MD_VIEWER_TERMINAL_PROFILE = "kitty" })
  t.eq("kitty", env_override.profile_id, "MD_VIEWER_TERMINAL_PROFILE selects a profile")
  t.eq("inferred", env_override.graphics, "and that is enough to leave the cells fallback")
  t.ok(env_override.evidence[1]:match("MD_VIEWER_TERMINAL_PROFILE"), "the evidence names the override")

  local both = terminal.capability({ profile = "ghostty" }, { MD_VIEWER_TERMINAL_PROFILE = "kitty" })
  t.eq("ghostty", both.profile_id, "an explicit terminal.profile still outranks the environment override")

  local beats_inference = terminal.capability(
    { profile = "auto" },
    { MD_VIEWER_TERMINAL_PROFILE = "kitty", TERM_PROGRAM = "iTerm.app" }
  )
  t.eq("kitty", beats_inference.profile_id, "but the environment override outranks inference")

  -- A typo falls through to inference rather than erroring or pinning
  -- "unknown", and says so: it is set on the far side of an SSH connection,
  -- where a silently ignored variable is the hardest symptom to chase.
  local typo = terminal.capability({}, { MD_VIEWER_TERMINAL_PROFILE = "iterm", TERM_PROGRAM = "iTerm.app" })
  t.eq("iterm2", typo.profile_id, "an unknown MD_VIEWER_TERMINAL_PROFILE value falls through to inference")
  local reported = false
  for _, entry in ipairs(typo.evidence) do
    if entry:match("MD_VIEWER_TERMINAL_PROFILE") and entry:match("ignored") then reported = true end
  end
  t.ok(reported, "and the rejected value is reported rather than silently dropped")

  local empty = terminal.capability({}, { MD_VIEWER_TERMINAL_PROFILE = "", TERM_PROGRAM = "iTerm.app" })
  t.eq("iterm2", empty.profile_id, "an empty MD_VIEWER_TERMINAL_PROFILE is absent, not invalid")
  t.eq(1, #empty.evidence, "and is not reported as a rejected value")

  -- Every static profile caveat is classified, and the classification is not
  -- vacuous: the terminals md-viewer has actually validated carry no warnings
  -- at all, so a warning in the concise report always means something.
  for id, profile in pairs(terminal.profiles) do
    for _, caveat in ipairs(profile.caveats or {}) do
      t.ok(caveat.kind == "warn" or caveat.kind == "note", ("%s: every caveat declares a kind"):format(id))
      t.ok(type(caveat.text) == "string" and #caveat.text > 0, ("%s: every caveat carries text"):format(id))
    end
  end
  for _, id in ipairs({ "iterm2", "kitty", "ghostty", "wezterm" }) do
    for _, caveat in ipairs(terminal.profiles[id].caveats) do
      t.eq("note", caveat.kind, ("%s: a validated profile states provenance, it does not warn"):format(id))
    end
  end
  for _, id in ipairs({ "warp", "generic_kitty", "unknown" }) do
    local has_warning = false
    for _, caveat in ipairs(terminal.profiles[id].caveats) do
      if caveat.kind == "warn" then has_warning = true end
    end
    t.ok(has_warning, ("%s: an unvalidated profile warns"):format(id))
  end

  -- Capability confidence is never "verified" from environment variables alone,
  -- across every profile this module can produce.
  local samples = {
    { {}, { TERM_PROGRAM = "iTerm.app" } },
    { {}, { KITTY_WINDOW_ID = "1" } },
    { {}, { WEZTERM_EXECUTABLE = "/x" } },
    { {}, { GHOSTTY_RESOURCES_DIR = "/x" } },
    { {}, { TERM_PROGRAM = "WarpTerminal" } },
    { {}, { TERM = "xterm-kitty" } },
    { {}, {} },
    { { kitty_graphics = "on" }, {} },
    { { kitty_graphics = "off" }, { TERM_PROGRAM = "iTerm.app" } },
    { { profile = "kitty" }, {} },
  }
  local saw_verified = false
  for _, sample in ipairs(samples) do
    local capability = terminal.capability(sample[1], sample[2])
    if capability.graphics == "verified" then saw_verified = true end
  end
  t.eq(false, saw_verified, "no environment-only capability report ever claims verified")

  -- `selection_overlay` is the per-profile gate for the drag-highlight overlay,
  -- true only where someone actually looked -- by eye for iTerm2, Ghostty and
  -- Kitty, by photograph for WezTerm.
  --
  -- `overlay_encoding` is how a rectangle's sub-cell position is expressed.
  -- Only WezTerm differs, and only because it insets every cell of a placement
  -- by the X/Y offset rather than the first cell alone.
  local overlay_by_profile = {
    iterm2 = { overlay = true, encoding = "sub-cell-offset" },
    ghostty = { overlay = true, encoding = "sub-cell-offset" },
    kitty = { overlay = true, encoding = "sub-cell-offset" },
    wezterm = { overlay = false, encoding = "sheet-margin" },
    warp = { overlay = false, encoding = "sub-cell-offset" },
    generic_kitty = { overlay = false, encoding = "sub-cell-offset" },
    unknown = { overlay = false, encoding = "sub-cell-offset" },
  }
  for profile, want in pairs(overlay_by_profile) do
    local capability = terminal.capability({ profile = profile }, {})
    t.eq(want.overlay, capability.selection_overlay, ("selection_overlay for the %s profile"):format(profile))
    t.eq(want.encoding, capability.overlay_encoding, ("overlay_encoding for the %s profile"):format(profile))
    -- Every Kitty-protocol profile draws its base at -3 so animation frames
    -- always have -2 to themselves and the overlay -1. The layers must not
    -- coincide: the protocol breaks a z-index tie by image id, and md-viewer
    -- re-uploads the base on every full frame, so a shared layer lets the base
    -- climb above the highlight and stay there.
    t.eq(-3, capability.default_raw_zindex, ("%s leaves the frame and overlay layers free"):format(profile))
  end

  -- `resident_pan` is its own gate and deliberately not a synonym for the
  -- overlay's, even though both are placements over a base image. An overlay
  -- rectangle is placed at natural pixel size and so needs a measured cell; a
  -- resident crop scales by cells and needs none. What it needs instead is that
  -- the terminal hold a *large* image across sustained placement churn -- which
  -- is why Kitty and Ghostty, both cleared for the overlay, are not cleared for
  -- this until someone has watched their memory over a long session.
  local resident_by_profile = {
    iterm2 = true,
    ghostty = false,
    kitty = false,
    wezterm = false,
    warp = false,
    generic_kitty = false,
    unknown = false,
  }
  for profile, want in pairs(resident_by_profile) do
    local capability = terminal.capability({ profile = profile }, {})
    t.eq(want, capability.resident_pan, ("resident_pan for the %s profile"):format(profile))
  end
  t.ok(
    terminal.capability({ profile = "kitty" }, {}).selection_overlay,
    "sanity: kitty passes the overlay gate, so the two gates are genuinely independent"
  )

  -- The flag and the evidence are different grades, and neither may stand in
  -- for the other. WezTerm's geometry was photographed and is correct; its cost
  -- is not, so the encoding ships and the flag does not. The validation string
  -- has to carry both halves rather than rounding to "unsupported".
  local wez = terminal.capability({ profile = "wezterm" }, {})
  t.eq(false, wez.selection_overlay, "wezterm does not send the overlay workload")
  t.eq("sheet-margin", wez.overlay_encoding, "but it keeps the encoding that was proven correct")
  t.ok(wez.validation:match("pixel%-verified"), "the wezterm validation string records what was checked")
  t.ok(wez.validation:match("20240203%-110809"), "and names the old stable build it was checked on")
  t.ok(wez.validation:match("20260805%-104032"), "and the current build too")
  t.ok(wez.validation:match("memory without bound"), "and names the reason the flag is off")
  t.eq(nil, wez.validation:match("operator%-validated"), "it never claims an operator validated it")
  for _, seen in ipairs({ "iterm2", "ghostty", "kitty" }) do
    local capability = terminal.capability({ profile = seen }, {})
    t.ok(
      capability.validation:match("operator%-validated"),
      ("%s keeps the stronger grade someone actually earned"):format(seen)
    )
  end

  -- `terminal` config validation rejects bad values with actionable errors.
  config.reset()
  local bad_profile_ok, bad_profile_err = pcall(config.setup, { terminal = { profile = "not-a-profile" } })
  t.eq(false, bad_profile_ok, "invalid terminal.profile is rejected")
  t.ok(tostring(bad_profile_err):match("terminal%.profile"), "invalid profile error names the offending option")

  config.reset()
  local bad_graphics_ok, bad_graphics_err = pcall(config.setup, { terminal = { kitty_graphics = "maybe" } })
  t.eq(false, bad_graphics_ok, "invalid terminal.kitty_graphics is rejected")
  t.ok(tostring(bad_graphics_err):match("terminal%.kitty_graphics"), "invalid kitty_graphics error names the option")

  config.reset()
  local bad_probe_ok, bad_probe_err = pcall(config.setup, { terminal = { probe = "aggressive" } })
  t.eq(false, bad_probe_ok, "invalid terminal.probe is rejected")
  t.ok(tostring(bad_probe_err):match("terminal%.probe"), "invalid probe error names the option")

  config.reset()

  -- Wiring: an unknown terminal (no vim.ui.img, no graphics evidence) falls
  -- back to the cells backend through the real selection path.
  config.setup({ terminal = { profile = "unknown" } })
  local backends = require("md-viewer.backends")
  local selected = assert(backends.select("auto"))
  t.eq("cells", selected.name, "unknown terminal falls back to cells through auto selection")
  config.reset()

  -- detect() memoizes its snapshot -- it walks the whole environment and is
  -- reached on every placement and animation gate -- and a config change is
  -- the one event that must drop it.
  config.setup({ terminal = { profile = "kitty" } })
  local first = terminal.detect()
  t.ok(first == terminal.detect(), "repeated detect() returns the same snapshot, not a re-walk")
  config.setup({ terminal = { profile = "ghostty" } })
  local second = terminal.detect()
  t.eq("ghostty", second.profile_id, "config.setup invalidates the snapshot so the new profile is seen")
  config.reset()
  -- After reset the profile is "auto" and detection reads the real process
  -- environment, whose contents this test cannot assume -- so assert only that
  -- the snapshot was dropped, by identity.
  t.ok(terminal.detect() ~= second, "config.reset drops the snapshot as well")
  config.reset()

  -- Double-buffer policy resolves here, not in a backend, because the profile
  -- table it reads lives here and because every backend that replaces an image
  -- needs the same answer. kitty_raw had this logic and nvim_img grew a second,
  -- subtly different copy that read `image.double_buffer` directly -- and that
  -- option's default is nil, meaning "ask the profile", which reads as false.
  config.setup({ terminal = { profile = "warp" } })
  local enabled, source = terminal.double_buffer()
  t.eq(true, enabled, "an unset image.double_buffer takes the profile default, not `nil` as false")
  t.ok(source:match("profile default %(warp%)"), "the source names the profile it came from")

  config.setup({ terminal = { profile = "warp" }, image = { double_buffer = false } })
  local overridden, override_source = terminal.double_buffer()
  t.eq(false, overridden, "an explicit false outranks the profile default")
  t.ok(override_source:match("explicit override"), "and is named as an override rather than a default")

  -- A profile that says nothing still gets create-then-delete: the blank
  -- interval is the thing worth avoiding, and it costs one extra live image id.
  config.setup({ terminal = { profile = "unknown" }, image = { double_buffer = nil } })
  t.eq(true, (terminal.double_buffer()), "a profile with no stated default still avoids the blank interval")
  config.reset()
end
