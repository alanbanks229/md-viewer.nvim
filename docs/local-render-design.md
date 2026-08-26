# Rejected: rendering on the client over a slow link

**This describes code that no longer exists.** It was built on a branch, measured on
the link it was designed for, and removed again before v0.2.0 was tagged — it was never
in a release. The record is kept because the architecture is a plausible idea a reader
will have again, and because the reason it lost is not one anybody would guess from
first principles.

## The problem

md-viewer rasterizes a frame where Neovim runs and sends the pixels to the terminal.
Over a fast local pipe that is free. Over a throttled SSH link it is the whole cost.

The link this was measured on reaches a remote VM through AWS SSM Session Manager
(WebSocket-over-TLS, not TCP/22). It has a flat **0.80 MB/s** ceiling, confirmed from
1 KB to 5 MB with no burst allowance. There is no setting that raises it.

### Where that ceiling comes from

<a id="ssm-ceiling"></a>Re-validated 2026-08-25, because a number this much of the
design rests on should not be believed on one session's say-so. It survives, but the
*explanation* this document used to give for it was wrong, and the wrong one was more
flattering: it blamed the client, `session-manager-plugin`, which paces the other
direction.

**AWS says so directly.** In
[aws/amazon-ssm-agent#664](https://github.com/aws/amazon-ssm-agent/issues/664), "0.6
MB/s speeds on 5 GB/s burstable instance", a reporter measures ~0.6–0.8 MB/s from a
client whose own link runs at 27.5 MB/s, having ruled out instance type (`t3.micro`
through `m7i.8xlarge`, no change) and the far-end service. A maintainer answers:

> It's due to: `agent/session/config/config.go#L50` in combination with a max message
> rate of 1/ms

and closes it with:

> Unfortunately at current time we can't support an increase in scale through our
> service, so this limitation will be kept for now.

That line 50 is `StreamDataPayloadSize = 1024`. One kilobyte per millisecond is
**1.024 MB/s**, and the reporter saw it on *both* `AWS-StartPortForwardingSessionToRemoteHost`
and a plain `aws ssm start-session` — on agent 3.3.3598.0, so it is not an
upgrade-away problem. See also
[#227](https://github.com/aws/amazon-ssm-agent/issues/227) and
[#259](https://github.com/aws/amazon-ssm-agent/issues/259).

**Where the pacing is, in the direction that carries pixels.** Both of the agent's
output paths — VM → terminal, which is where md-viewer's bytes go — do the same thing:

| session | file | loop |
|---|---|---|
| `aws ssm start-session` (plain shell) | `agent/session/shell/shell.go` | reads ≤ `StreamDataPayloadSize` from the pty, then `time.Sleep(time.Millisecond)` — *"Pace the sending to prevent flooding the websocket"* |
| SSH over SSM (`ProxyCommand`) | `agent/session/plugins/port/port_basic.go` | reads ≤ `StreamDataPayloadSize` from the TCP conn, then `time.Sleep(time.Millisecond)` — *"Wait for TCP to process more data"* |

`time.Sleep` overshoots rather than undershoots, so the achievable band is roughly
0.7–1.0 MB/s. The 0.80 MB/s measured here sits inside it at 78% of theoretical, and
matches an unrelated reporter's 0.6–0.8 on unrelated hardware. Three independent lines
agreeing is why the number is trusted, rather than the one measurement.

**Now measured against the channel itself, 2026-08-25.** Everything above is a reading
of the agent's source plus a stranger's numbers — a derivation, and a derivation is a
prediction until something on the actual host agrees with it. It does. On `aide-spock`,
reached by `ProxyCommand aws ssm start-session --document-name AWS-StartSSHSession` and
running with `Compression yes`, 64 MiB of incompressible bytes pushed straight down the
SSH channel three times measured **0.77–0.78 MB/s** — 76% of the 1.024 MB/s the
kilobyte-per-millisecond loop allows, inside the predicted band, and on the same side of
it as the third-party report. Compression was live throughout and could only have
flattered the result; choosing a payload it cannot help is what excluded it.

The same 64 MiB sent as *compressible* bytes on that same session took 6.36 s against
86.23 s — **13.6×** — which is not a footnote but the measurement that explains every
inflated SSM figure this repository has ever recorded, including its own.

The client has the mirror-image loops — `ReadStream` in
`src/sessionmanagerplugin/session/portsession/standardstreamforwarding.go` and
`handleKeyboardInput` in `.../shellsession/shellsession_unix.go`, both 1024-byte reads
followed by a 1 ms sleep — but those pace **keystrokes going up**. The client's
`WriteStream` does `outputStream.Write(payload)` with no chunking and no sleep. The link
is asymmetric, and md-viewer lives in the throttled half.

**This ceiling belongs to SSM, not to "SSH".** An ordinary SSH session goes through none
of it. Measured 2026-08-25 against `ssh ichigo`, a LAN host on plain TCP/22: 64 MB over
the SSH channel in 2.92–3.08 s (**21.8–23.0 MB/s**), and 64 MB of base64'd random bytes
through a pty — the path `scripts/ssh-link-speed.sh` measures — at **14.7 MB/s**. Compare
like with like: **28–30×** on the channel, **14×** through a pty. The pty gap is the
smaller of the two only because SSM's side of it is the one getting a quarter back from
compression, which is point 2 below. Anything in this repo that reasons from 0.80 MB/s is
reasoning about an SSM tunnel specifically, and nothing should read it as "remote" or
"over SSH".

### If you measure an SSM link faster than this

It happens, and it does not mean the arithmetic above is wrong — it means the bytes
being counted are not the bytes the agent pumped. Three ways that happens, in
descending order of how much they inflate:

1. **A compressing hop upstream of the agent.** With `Compression yes` (or `ssh -C`),
   sshd on the VM deflates the stream *before* the SSM agent reads it, so a megabyte of
   repetitive test data reaches the agent as a few kilobytes and clears its 1 KB/ms pump
   instantly. `scripts/ssh-link-speed.sh` used to send `tr '\0' '.'` — the most
   compressible payload constructible — and reported 8.0–10.3 MB/s for this link on that
   basis. Measured directly: **13.6× on 64 MiB**, so an order of magnitude was not
   hyperbole. It now sends base64 over `/dev/urandom`. A figure taken before 2026-08-25
   was measured the old way and should be re-taken.
2. **base64 is itself compressible, so even the fixed script reads ~33% high.** This is
   the one that survives the fix, and it is easy to miss because the payload *looks*
   incompressible — an earlier version of the script's own comment said it was, reasoning
   that PNG is already deflated. That reasoning is about the wrong layer. base64 is 64
   symbols carried in 8-bit bytes: six bits of entropy per byte, so deflate takes it to
   about 75% whatever is inside it. On `aide-spock` that is exactly the gap between the
   channel's 0.774 MB/s and the 1.01–1.07 MB/s the script reports through the pty —
   0.774 ÷ 0.75 = 1.032 — and it is a gap worth keeping rather than correcting, because
   md-viewer's own base64 gets the same quarter back. The script measures the *effective*
   rate, which is what a frame's transit time is actually made of; the channel figure is
   what to argue about the link with. Only the first belongs in
   `render.ssh_link_bytes_per_sec`.
3. **The host is not reached through an SSM data channel at all.** `ssh -G <host> | grep
   -i proxycommand` settles it in one command: no `session-manager-plugin` there means
   none of this section applies to that host.

So the falsifiable form of the claim is narrow and worth stating, and note that it is
about the channel rather than about anything a pty reports: *sustained transfer of
incompressible bytes through an SSM data channel cannot exceed ~1.024 MB/s.* Anything
above that is evidence the traffic is not going through one — but a pty figure above it
is evidence of nothing until the compressor is subtracted, which is why 1.01–1.07 above
refutes nothing.

Latency is not the problem. A tiny Kitty capability query round-trips the same relay in
96 ms, while a 432 KB frame serializes in ~540 ms. Of one settle frame, wire
serialization was ~346 ms — 80% of the total — against ~81 ms of Chromium capture and
~14 ms of terminal receive and decode. The lag scales with bytes and only with bytes.

## What was built

The renderer ran on the machine the *terminal* was on rather than the machine Neovim was
on. A companion process served the ordinary renderer protocol over a `0600` unix socket,
reached by an ordinary `ssh -R` reverse forward; a filter in front of the terminal
replaced a ~56-byte token with the real Kitty upload, byte for byte. Markdown crossed
the link instead of pixels, because markdown is the smallest thing that reproduces the
document — one wheel spin went from 13.8 MB to about 93 KB.

The seam was one function. `backends/kitty_raw.lua` already builds the image upload and
its placement separately, and only the upload is expensive, so placement math, double
buffering, occlusion cut-outs, z-layer resolution and deletion discipline all stayed on
the Neovim host untouched. Neovim kept owning the grid; the client substituted image
*data* in place, at the same position in the same byte stream, so there was never a
fight over cells. That part of the design was right, and a retry should reuse it.

## What it cost

It worked, it kept 13.3 MB of pixels off the link in one measured session, and it made
the preview **slower**:

| | renderer on the VM | renderer on the Mac |
|---|---:|---:|
| capture | 50–62 ms | 15–21 ms |
| link, per frame | ~0 (a pipe) | **~90 ms** |
| frame interval floor | **~56 ms** | ~107 ms |
| delivered | **6.3/s** | 3.0–4.7/s |

A ~96 ms round trip costs more than a 40 ms faster capture saves. Pipelining several
captures should have fixed exactly that — with N in flight the floor becomes
`max(render, RTT/N)` — and it lost worse: 11 frames in 28.9 seconds against 41 in 19.8.
A session-wide "only the newest request may display" gate, predating the lane machinery
and doing the same job one layer up, discarded the extra frames *after* the link had
already carried them.

## Why it was removed

The premise was wrong by the time the code landed. `render.scroll_scale` and
`render.ssh_scroll_settle_ms` — a configuration change with no new process, no new
transport and no new trust boundary — had already taken wire saturation from 79% to 49%.
Transit had stopped being the constraint. The client-render path then removed 16.7
seconds of wire time that was no longer on the critical path, and charged a 92 ms serial
round trip per frame to do it.

Removing it also restores an invariant that had to be narrowed to accommodate it:
**md-viewer opens no listening port**, full stop, rather than "on the machine running
Neovim".

One number went unexplained for a while and is worth recording as settled: a scroll loop
turning over every ~520 ms while transit accounted for only 74 ms of it. The missing
~350 ms was the TUI blocking as it wrote base64 into a pty the far end drained at
0.80 MB/s — still caused by bytes, just not the bytes anyone was counting.

## What to keep from it

**The condition worth revisiting under.** A link with **low round-trip latency but
capped throughput** — a shaped or metered connection rather than a relayed one. There the
bytes are the whole cost and the round trip is not, so the arithmetic that killed this
inverts. Nothing else about the design was wrong; it was pointed at the wrong bottleneck.

**The trap most worth remembering.** Removing the largest thing on a link promotes
whatever was second. Substituting a reference for the PNG still left a 6,542-byte
response, because unchanged block geometry was being returned on every capture; eliding
that too brought it under 2,048. A saving measured only on the thing you removed will
read as a win it is not.

**The better remaining option — since built, and it was the right one.** Keep the whole
document resident in the terminal and pan with crop placements. Shipped in 0.3.0-rc2 and
described in [`architecture.md`](architecture.md); the estimate below of "about 200 bytes"
per scroll turned out to be 196, measured over 40 scrolls of this repository's own README.

The two reservations recorded here were both real and both were answered rather than
dismissed. Terminal memory under placement churn is why WezTerm is excluded outright
(wezterm#7953 duplicates a cell's attachment list on every repeat placement, and panning
is unbounded repeat placements) and why the resident set is bounded by a hard chunk count
as well as by a byte estimate. The "tens of megabytes resident" figure is the one part
still unsettled: the two measurements of terminal memory per resident pixel disagree by
34x, which is why `image.resident_memory_mb` is documented as a heuristic.

**Two alternatives that cannot work.** Writing to the ssh pty slave from a second
process: two processes writing one terminal is not atomic, and a write landing inside an
escape sequence wedges it. Returning data through `TermResponse`: replying to Neovim
means injecting into ssh's *input*, which means owning stdin, which means allocating a
pty, which means a native module that cannot be installed on a machine with no egress.

## References

- [`architecture.md`](architecture.md) — the data flow, and the two live `scroll_scale`
  invariants that constrain any retry
- [`troubleshooting.md`](troubleshooting.md) — the reader-facing symptoms
- [`../SECURITY.md`](../SECURITY.md) — what the defaults enforce
