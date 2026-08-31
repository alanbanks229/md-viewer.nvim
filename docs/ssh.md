# Over SSH

md-viewer works over SSH with one thing to set up and one thing to know.

**Node.js and Chrome go on the remote host, not on the machine your terminal is
on.** The renderer runs wherever Neovim runs and produces a PNG; Neovim writes
that to your terminal as escape sequences. Nothing on the terminal side is
involved beyond drawing it.

The one exception is [local rendering](#local-rendering) below — an experimental,
off-by-default mode that deliberately moves the browser to the terminal side
because on a slow enough link the picture is the whole cost. It changes which
machine draws, not what is drawn.

## Make your terminal identifiable

This is the one step that needs doing, because SSH does not forward
`TERM_PROGRAM`. Run `echo $LC_TERMINAL` on the remote host — **if it prints, skip
this section.**

iTerm2 and WezTerm export `LC_TERMINAL`, which SSH can carry — but only when
both ends are configured to let it. In `~/.ssh/config` on your machine:

```
# ~/.ssh/config
Host *
  SendEnv LC_TERMINAL LC_TERMINAL_VERSION
```

Upstream OpenSSH sends nothing by default;
distributions usually add `SendEnv LANG LC_*`, and a `Host *` block of your own
overrides that. On the server, `/etc/ssh/sshd_config` needs `AcceptEnv LANG LC_*`
and an `sshd` reload — nearly every distribution ships this already, but it is
an administrator's change where it does not. `ssh -G <host> | grep sendenv`
shows what your client actually sends.

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

**Requirements and limits.** Run the same tag on both ends where you can, but
the handshake compares the control-socket *protocol* version, not the tag:
`renderer/src/local/version.js` treats two independently-updated checkouts as
the steady state, so ordinary skew is accepted and only an incompatible protocol
is refused. The refusal cannot tell which side is older — update both checkouts
to the same tag. Without a helper you get one warning per preview open and
remote rendering exactly as before, never a silent failure. In local mode
resident mode demotes and `render.animate` is structurally off. The path is
protocol-compatible but unvalidated on every terminal; see
[terminal-support.md](terminal-support.md).

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

The cause is upstream and acknowledged: the agent sends stream data in 1 KB
payloads at a maximum of one message per millisecond — 1.024 MB/s by
arithmetic — and
[aws/amazon-ssm-agent#664](https://github.com/aws/amazon-ssm-agent/issues/664)
confirms both the mechanism and that it is staying. The pacing sits in the
direction that carries md-viewer's pixels; keystrokes going up are unaffected.
Measured against the channel itself (an SSM-tunneled host, 2026-08-25): 64 MiB
of incompressible bytes, three runs, **0.77–0.78 MB/s** — inside the band the
arithmetic predicts.

### If you measure an SSM link faster than that

The bytes being counted are probably not the bytes the agent pumped:

1. **A compressing hop upstream of the agent** (`Compression yes`, `ssh -C`)
   deflates the stream before the agent reads it — measured inflating a figure
   13.6x on compressible test data, which is why `scripts/ssh-link-speed.sh`
   sends base64 of `/dev/urandom`.
2. **base64 itself deflates by ~25%**, so even a correct raw-channel figure
   reads high. Keep the gap rather than correcting it: md-viewer's own
   transfers are base64 too, so the pty figure is the one that predicts a
   frame's transit time and the one that belongs in
   `render.ssh_link_bytes_per_sec`.
3. **The host may not be reached through SSM at all.**
   `ssh -G <host> | grep -i proxycommand` settles it in one command: no
   `session-manager-plugin` there means none of this applies.
