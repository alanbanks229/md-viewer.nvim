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
    if caveat:match("tmux") then mentions_tmux = true end
  end
  t.ok(mentions_tmux, "multiplexer presence is warned about in caveats")

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
end
