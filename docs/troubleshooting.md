# Troubleshooting

Run `:MdViewerHealth` first — it names the backend, why it was chosen, and any
warnings. `:MdViewerDebug` is the full diagnostic and is what to attach to a bug
report; every field name quoted below is printed there.

## Quick answers

| Symptom | What to do |
|---|---|
| Preview is styled text, not an image | `auto` found no graphics backend. `:MdViewerHealth`'s `Reason` says which. If your terminal does speak the Kitty protocol but was not recognised, set `terminal.profile`. Over SSH, see [below](#the-preview-falls-back-to-text-over-ssh). |
| An explicit backend reports unavailable | Intentional — explicit `nvim_img`/`kitty_raw` never fall back silently. Read `Reason`. |
| Renderer exits, or Playwright is missing | From `renderer/`: `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts`. Do not run `playwright install`. Set `browser.executable_path` if Chrome discovery missed. |
| Wrong terminal profile detected | `:MdViewerDebug`'s `identified by` says why. Override with `terminal.profile`, or `$MD_VIEWER_TERMINAL_PROFILE` when one config is shared across machines. |
| Caret or selection is a huge grey block | You forced `interaction.selection_overlay = "on"` on a terminal that cannot do it (`overlay` says `forced`). Remove it. |
| Preview blinks blank while dragging the mouse | Expected. The mouse never selects text; an unmapped drag hits Neovim's own blockwise-Visual default and md-viewer clears it within a tick. If the image blanks with the mode still `NORMAL`, set `image.double_buffer = true`. |
| Mouse wheel does not scroll the preview | Needs `sync.mouse_scroll = true`, Neovim mouse support on, and the pointer inside the preview window. |
| Clicking, selecting, finding or copying does nothing | Needs `interaction enabled: yes` and the matching `interaction.*` flag. Unavailable on the `cells` backend — there is no page to hit-test. |
| `v`/`V` does not extend a selection | Needs `interaction.visual` **and** `interaction.selection`, focus in the preview window, and one frame already rendered. |
| A click lands on the wrong character | `viewport calibration` is probably `estimated` — see [the next section](#text-is-twice-the-size-it-should-be-or-the-image-is-stretched-or-soft). |
| Mouse pointer never changes shape | It never will. Terminal support for `OSC 22` was too inconsistent to keep. |
| An image shows a placeholder | The placeholder names the reason. Dashed border = refused by policy (non-public address, not https, outside `security.document_root`, or SVG). Solid = fetch attempted and failed. A slow image fills in on its own. |
| An animated image is not moving | Animation is off by default: set `render.animate = true`. With it on, `:MdViewerDebug`'s `animation` line says why it is still off. A finished non-looping GIF holds its last frame, as a browser does. |
| Image overlaps other UI, or survives closing | `occluded` should be `true` under a focusable float; `ui_polling: true` covers `noautocmd` windows. Close with `:MdViewerToggle` — never global image deletion, it damages other plugins. |
| Notification shows Markdown through its background | `passive_cutouts` should be nonzero while it is visible, and `raw_zindex` negative (`layer stack` prints all three). |
| Scrolling feels slow | Compare `fast_capture_ms` / `fast_png_bytes` after a scroll. Lower `render.scroll_scale`. Do **not** lower `render.device_scale_factor` — it grows the frame rather than shrinking it. |

## Text is twice the size it should be, or the image is stretched or soft

The preview is a photograph of a web page, sized to fit your terminal's character
cells. If md-viewer gets the size of one cell wrong, the terminal stretches or
shrinks the photo to fit, and the text comes out too big, too small, or blurry.
This is never a font setting — `render.font_size_px` is honoured exactly.

Try these in order:

1. **On a non-retina (1x) display, set `render.device_scale_factor = 1`.** The
   default of `2` assumes a retina screen; on a 1x screen everything comes out
   about double. It also stops the renderer capturing four times the pixels it
   needs.
2. **Get out of tmux or screen.** Neither passes the terminal's pixel size
   through, so md-viewer has to guess. `:MdViewerDebug`'s `viewport calibration`
   reads `estimated` when it is guessing, `measured` when it is not.
3. **Tell it the cell size yourself.** In `:MdViewerDebug`, `measured cell` is
   what the terminal reported. Divide both numbers by your
   `device_scale_factor` and export the result:

   ```sh
   # a 2x display reporting a 14x32 cell
   export MD_VIEWER_CELL_WIDTH_PX=7
   export MD_VIEWER_CELL_HEIGHT_PX=16
   ```

   `viewport calibration` then reads `env`. This is the fix for a very small
   font on a HiDPI display, where the real cell falls outside the range
   md-viewer treats as plausible.

Warp is a known special case: it reports its cell in logical points rather than
device pixels, so the scale is applied twice. md-viewer detects that one.

## The preview falls back to text over SSH

This is terminal identification, not the renderer — if `chromium launch:
succeeded`, the renderer is fine. The signature in `:MdViewerDebug`:

```
ssh session:              yes (SSH_CONNECTION)
terminal profile:         unknown (Unknown terminal)
selected backend:         cells
```

SSH does not forward `TERM_PROGRAM`, and Neovim will not emit graphics at a
terminal it cannot identify. Two fixes:

1. **iTerm2 and WezTerm** export `LC_TERMINAL`, which SSH can carry once both
   ends allow it. Run `echo $LC_TERMINAL` on the remote host; if it prints,
   this is not your problem. If it is empty,
   [ssh.md](ssh.md#make-your-terminal-identifiable) has the `SendEnv` /
   `AcceptEnv` configuration.
2. **Kitty, Ghostty and Warp** export nothing forwardable. Name the profile on
   the remote host: `export MD_VIEWER_TERMINAL_PROFILE=kitty`. Prefer this to
   `terminal.profile` when one `~/.config/nvim` reaches several hosts.

Two things that do not help: `browser.executable_path` (it names a binary on the
machine running Neovim, not yours), and forcing `image.backend = "kitty_raw"`
(selection still calls `detect()`, so it turns the fallback into a hard error
without changing the outcome).

A preview that renders but feels *sluggish* is bandwidth, not detection — see
[ssh.md](ssh.md#if-it-works-but-feels-slow).

## Remote images never load, and the network needs a proxy

`$HTTP_PROXY` and `$HTTPS_PROXY` are deliberately not consulted, so where a
proxy is the only route out, every `https` image fails to its placeholder.
Nothing is misconfigured and no setting changes it: the fetcher validates the
resolved address and then pins the connection to it, which is what stops a
hostname answering with a public address for the check and a private one for the
fetch. A proxy makes that pin impossible.

It costs the pictures and nothing else — local images and links never touch the
network, and the render never waits on a fetch.

## A link to another document refuses to open

The message says which of three things happened:

- **"link target does not exist"** — a typo, or a file not written yet.
- **"refused to open link outside the document root"** — the root defaults to the
  nearest ancestor holding `.git`, `.hg` or `.svn`, or the document's own
  directory when there is none. Set `security.document_root`, or add a marker to
  `security.document_root_markers`. If links work in one project but not
  another, check for a `security.document_root` set once globally — that pins
  every preview to one directory. `:MdViewerDebug`'s `document root` names the
  resolved root and where it came from.
- **Refused as an executable** — md-viewer never hands the OS a link it would
  *run*. `:help md-viewer-security` lists what counts.

On macOS, Ctrl-click and Cmd-click are often claimed by the terminal before
Neovim sees them. If `interaction_request_count` does not move when you click,
that is what happened. For an external link that reaches Neovim and still does
nothing, `:MdViewerDebug`'s `last_external_open` records the hand-off —
`"none"`, `no handler: ...`, an exit code, or `spawned` (the success case for a
browser that stays open).

## A gap or overhang appears beside a notification

The cut-out is exact in cells, but some terminals (iTerm2 confirmed) apply their
window margin to text and not to graphics, shifting the image a fraction of a
cell. `image.raw_overlay_bleed_cells` (default `1`) absorbs the gap.

To cancel it outright on a terminal implementing the protocol's `X`/`Y`
placement keys: screenshot a notification over the preview, compare the x
coordinate of the image's edge with the notification's edge, and set
`image.raw_cell_offset_px.x` to the difference (10 for a 20px cell on iTerm2's
defaults). The gap then closes completely and bleed can drop to `0`.
`:MdViewerDebug` reports both as `cell offset / bleed`.

## Local rendering (`render.location = "local"`)

Experimental, off by default; see [ssh.md](ssh.md#local-rendering).

**"local rendering unavailable" on open.** The helper has to wrap the ssh session
*before* Neovim starts inside it:

```sh
node <md-viewer>/renderer/src/local-main.js -- ssh <host>
```

The warning's parenthetical is the scan's verdict per socket: "no helper socket
found" (no `ssh -R` forward landed), "mode ... is looser than 0600" (permission
check failed), or "hello refused (PROTOCOL_MISMATCH: ...)" (the two checkouts
are different versions — pin both to the same tag). `$MD_VIEWER_LOCAL_SOCKET`
pins the path when the scan picks wrong.

**"pairing probe unanswered".** The socket answered but the helper never saw the
probe, usually because a second helper session to the same host was found first.
Close the stale session, or point `$MD_VIEWER_LOCAL_SOCKET` at the right socket.
A multiplexer between ssh and the terminal also eats the probe.

**Is it actually rendering locally?** `:MdViewerHealth`'s `Location` row answers
in words. In the counters, read `parser.remoteMdvGraphicsCommands` — it counts
only md-viewer's own graphics, and zero while attached is the invariant. Its
sibling `parser.remoteGraphicsCommands` counts every program in the session and
proves nothing on its own.

**Demoted mid-session ("rendering on this host instead").** The control socket
died; frames render remotely from then on, correct but paying the link. The
reason is in `:MdViewerHealth` and `local_render.reason`. Re-attach by reopening
the preview from a fresh helper-launched session.

## Resident mode is configured, but `render_path` says `viewport`

`:MdViewerDebug`'s `render_path_reason` names the one condition that failed:

| `render_path_reason` | What to do |
|---|---|
| `link speed unknown …` | Run `:MdViewerMeasureLink` once on this machine. `"auto"` never measures on its own. |
| `link measures … at or above the … cutoff` | Working as intended — this link is fast enough that resident mode buys nothing. Set `image.resident = "on"` if you want it anyway. |
| any terminal reason (`wezterm#7953`, …) | Your terminal refuses resident placements. See [terminal-support.md](terminal-support.md). |
| `local render owns scrolling` | Local rendering is attached and already scrolls without sending pixels. The two are exclusive by design. |

If it reports `image.resident = off` when you set otherwise, `setup()` never
received what you thought — check for a second `setup()` call or a plugin-manager
`opts` table.

**A resident preview jumps to the wrong position, or shows torn content.**
iTerm2 3.6.11 applies the re-crop unreliably over a slow link, so its profile
sets `resident_pan = false` and uses the viewport model instead. If a preview
that should be on the viewport model is warming chunks, check `terminal.profile`
and `$MD_VIEWER_TERMINAL_PROFILE` for an override.

---

Reporting a graphical bug: `:MdViewerDebug` output, the exact terminal and
Neovim versions, statusline/winbar configuration, and a minimal reproduction
confirmed outside any multiplexer. [terminal-support.md](terminal-support.md)
has the per-terminal status.
