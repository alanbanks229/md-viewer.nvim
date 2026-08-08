-- Stage-6 WezTerm qualification config. Not a config anyone should use: every
-- value here exists to make the window's pixel geometry predictable enough
-- that a screenshot can be asserted on.
--
-- Passed with `--config-file`, so it never touches the operator's own config.
-- Deliberately a plain table rather than `wezterm.config_builder()`, because
-- this has to load unchanged on both 20240203-110809-5046fc22 and a current
-- nightly and the builder rejects keys the running build does not know.
local wezterm = require("wezterm")

-- The cell origin has to be the window content origin, or the fiducials and
-- the graphics placements would be measured against different zeroes. Zero
-- padding, no tab bar and no scroll bar is the whole reason for this file.
local config = {
  window_padding = { left = 0, right = 0, top = 0, bottom = 0 },
  enable_tab_bar = false,
  enable_scroll_bar = false,
  use_resize_increments = false,
  adjust_window_size_when_changing_font_size = false,

  -- Pinned so the expectations file can be computed before the window opens.
  initial_cols = 100,
  initial_rows = 30,
  font_size = 13.0,

  -- Flat, opaque, and never animated: anything that changes between the probe
  -- signalling "ready" and the screenshot landing is noise in the assertions.
  colors = { background = "#000000", foreground = "#c0c0c0", cursor_bg = "#000000" },
  window_background_opacity = 1.0,
  text_background_opacity = 1.0,
  cursor_blink_rate = 0,
  default_cursor_style = "SteadyBar",
  animation_fps = 1,
  visual_bell = { fade_in_duration_ms = 0, fade_out_duration_ms = 0 },
  audible_bell = "Disabled",
  check_for_updates = false,
  automatically_reload_config = false,
  -- "Close", not "Hold": a held pane keeps the process alive after the probe
  -- quits and run.sh waits on it forever. Every key here is one both builds
  -- accept -- a key the running build has deprecated pops a Configuration
  -- Error window that covers the terminal and ruins the capture, which is
  -- exactly what `show_update_window` did on the nightly.
  exit_behavior = "Close",
}

-- Pin the window to the top-left of the display. The assertions do not depend
-- on this -- they locate the content origin from the fiducial row -- but it
-- keeps the window wholly on screen and away from the menu bar.
wezterm.on("gui-startup", function(cmd)
  local _, _, window = wezterm.mux.spawn_window(cmd or {})
  window:gui_window():set_position(0, 40)
end)

return config
