# Over SSH

md-viewer works over SSH with one thing to set up and one thing to know.

**Node.js and Chrome go on the remote host, not on your laptop.** The renderer
runs wherever Neovim runs and produces a PNG; Neovim writes that to your terminal
as escape sequences. A browser on the local machine is never consulted.

## Make your terminal identifiable

This is the one step that needs doing, because SSH does not forward
`TERM_PROGRAM`. Run `echo $LC_TERMINAL` on the remote host — **if it prints, skip
this section.**

iTerm2 and WezTerm export `LC_TERMINAL`, which can travel, but only if both ends
allow it. In `~/.ssh/config` on your machine:

```yaml
# ~/.ssh/config

Host *
  HostName
  User
  # ...
  SendEnv LC_TERMINAL LC_TERMINAL_VERSION # <-- Add this
```

Make sure your remote `/etc/ssh/sshd_config` accepts these variables e.g. `AcceptEnv LANG LC_*`, check if your distribution already ships this.

Kitty, Ghostty and Warp export no forwardable identity at all, so name the profile on the remote host instead:

```sh
export MD_VIEWER_TERMINAL_PROFILE=kitty
```

`:MdViewerDebug` reports the profile it detected and the evidence that produced
it. If the preview falls back to text,
[troubleshooting.md](troubleshooting.md#the-preview-falls-back-to-text-over-ssh)
walks it through.
## If it works but feels slow

Every refresh ships a full-page PNG down the connection, so on a throttled link
the picture arrives late. md-viewer already does two things about that on any SSH
session, neither of which needs configuring:

- `render.ssh_scroll_scale = 0.5` captures the moving frame of a scroll at half
  size — 2.6x to 3x fewer bytes — and restores full sharpness the moment
  scrolling stops.
- `render.ssh_scroll_settle_ms = 400` waits longer before spending that sharp
  capture, so a scroll still in motion does not pay for a frame nobody sees.

Do **not** reach for `render.device_scale_factor = 1` here. It is a calibration
divisor rather than a size knob: lowering it doubles the CSS viewport, grows the
frame, and collapses the moving and settle captures into one.

### Measure the link

```vim
:MdViewerMeasureLink
```

Run it once per machine, from an SSH session, with no preview open. It caches
the answer under `stdpath("state")` for that machine, which
`render.ssh_link_bytes_per_sec = "auto"` then reads. One `~/.config/nvim`
reaches hosts that measure fourteen times apart, so a constant written into a
shared config is wrong somewhere by construction — `:help md-viewer-ssh` has the
precedence rules.

### Local rendering

Below roughly 1 MB/s, shrinking the frame stops helping, because the problem is
no longer the size of the picture but that there is a picture at all.
`render.location = "local"` inverts the topology instead: a helper on the
machine your terminal runs on wraps the ssh session and runs the renderer beside
the terminal. The remote keeps Markdown parsing and the whole security pipeline
and nothing heavier.

```
remote ──▶ terminal   control socket (ssh -R):  prepared html, asset bytes once
                      terminal stream:          frame markers, ~0.3–1 KB each
terminal ──▶ remote   control socket:           geometry, blocks, notifications
```

No raster bytes cross in either direction, and no frame waits for a round trip:
the marker that presents a frame is emitted in the same tick as the render
request, and a scroll emits a marker and nothing else.

**Setup.** On the machine your terminal runs on:

```sh
node <md-viewer>/renderer/src/local-main.js -- ssh <host>
```

and in the remote Neovim's opts, `render = { location = "local" }`. Because one
config usually reaches machines that are not all behind a helper, and because
there is no autodetection, gate it on a variable of your own:

```lua
render = { location = vim.env.MD_VIEWER_LOCAL and "local" or "current" }
```

then `MD_VIEWER_LOCAL=1 nvim` in the sessions you launch through the helper.
`:help md-viewer-local` is the full reference.

**Requirements and limits.** Both ends must run the same md-viewer version — the
handshake refuses a mismatch and names the older side. Without a helper you get
one warning per preview open and remote rendering exactly as before, never a
silent failure. In local mode resident mode demotes and `render.animate` is
structurally off. The path is protocol-compatible but unvalidated on every
terminal; see [terminal-support.md](terminal-support.md).

The trust boundary — unix socket, pairing token, push-only content-addressed
assets — is in [SECURITY.md](../SECURITY.md); the moving parts are in
[architecture.md](architecture.md#render-location).

### Whole-document resident mode

The other answer, and independent of the first. The document is captured once as
a handful of chunks held in the terminal's image memory, and scrolling becomes a
placement command: 196 bytes per scroll against the ~80 KB a per-scroll capture
sends. It costs a long warm-up and a document's worth of terminal image memory,
so it only pays where the per-scroll capture is what you are waiting on.

`image.resident = "auto"` opts in, and needs `:MdViewerMeasureLink` to have been
run once on that machine: `"auto"` turns the mode on only where the measured link
is under `image.resident_below_bytes_per_sec` (4 MB/s), and an unmeasured link
stays on the per-scroll path. `:help md-viewer-resident` has the bounds.

## Where the AWS SSM ceiling comes from

<a id="ssm-ceiling"></a>AWS Session Manager (WebSocket-over-TLS, not TCP/22) has
a flat ceiling near **0.80 MB/s**, confirmed from 1 KB to 5 MB with no burst
allowance. No setting raises it, and it is the reason local rendering exists.

**AWS says so directly.** In
[aws/amazon-ssm-agent#664](https://github.com/aws/amazon-ssm-agent/issues/664),
a reporter measures ~0.6–0.8 MB/s from a client whose own link runs at
27.5 MB/s, having ruled out instance type (`t3.micro` through `m7i.8xlarge`) and
the far-end service. A maintainer answers:

> It's due to: `agent/session/config/config.go#L50` in combination with a max
> message rate of 1/ms

and closes it with:

> Unfortunately at current time we can't support an increase in scale through
> our service, so this limitation will be kept for now.

Line 50 is `StreamDataPayloadSize = 1024`. One kilobyte per millisecond is
**1.024 MB/s**. See also
[#227](https://github.com/aws/amazon-ssm-agent/issues/227) and
[#259](https://github.com/aws/amazon-ssm-agent/issues/259).

**The pacing is in the direction that carries pixels.** Both of the agent's
output paths — VM to terminal, which is where md-viewer's bytes go — do the
same thing:

| Session | File | Loop |
|---|---|---|
| `aws ssm start-session` (plain shell) | `agent/session/shell/shell.go` | reads ≤ `StreamDataPayloadSize` from the pty, then `time.Sleep(time.Millisecond)` — *"Pace the sending to prevent flooding the websocket"* |
| SSH over SSM (`ProxyCommand`) | `agent/session/plugins/port/port_basic.go` | reads ≤ `StreamDataPayloadSize` from the TCP conn, then `time.Sleep(time.Millisecond)` — *"Wait for TCP to process more data"* |

`time.Sleep` overshoots rather than undershoots, so the achievable band is
roughly 0.7–1.0 MB/s.

**Measured against the channel itself** (SSM reference host, 2026-08-25, reached
by `ProxyCommand aws ssm start-session --document-name AWS-StartSSHSession` with
`Compression yes` live): 64 MiB of incompressible bytes pushed straight down the
SSH channel, three times, measured **0.77–0.78 MB/s** — 76% of what the
kilobyte-per-millisecond loop allows, inside the predicted band. Compression was
running throughout and could only have flattered the result; choosing a payload
it cannot help is what excluded it.

The client has mirror-image loops, but those pace **keystrokes going up**. The
link is asymmetric and md-viewer lives in the throttled half.

### If you measure an SSM link faster than that

It happens, and it does not mean the arithmetic is wrong — it means the bytes
being counted are not the bytes the agent pumped. Three causes, in descending
order of how much they inflate:

1. **A compressing hop upstream of the agent.** With `Compression yes` (or
   `ssh -C`), sshd deflates the stream *before* the agent reads it, so
   repetitive test data clears the 1 KB/ms pump instantly. Measured directly:
   **13.6x on 64 MiB**. This is why `scripts/ssh-link-speed.sh` sends base64
   over `/dev/urandom` rather than something compressible.
2. **base64 is itself compressible, so even a correct measurement reads ~33%
   high.** It looks incompressible because PNG is already deflated, but that is
   the wrong layer: base64 is 64 symbols carried in 8-bit bytes — six bits of
   entropy per byte — so deflate takes it to about 75% whatever is inside it.
   0.774 ÷ 0.75 = 1.032, which is exactly the gap between the channel figure and
   the 1.01–1.07 MB/s the same host reports through a pty. **Keep the gap rather
   than correcting it**: md-viewer's own base64 gets the same quarter back, so
   the pty figure is the one that predicts a frame's transit time and the one
   that belongs in `render.ssh_link_bytes_per_sec`.
3. **The host is not reached through an SSM data channel at all.**
   `ssh -G <host> | grep -i proxycommand` settles it in one command: no
   `session-manager-plugin` there means none of this applies.

The falsifiable claim is narrow, and it is about the channel rather than
anything a pty reports: *sustained transfer of incompressible bytes through an
SSM data channel cannot exceed ~1.024 MB/s.*
