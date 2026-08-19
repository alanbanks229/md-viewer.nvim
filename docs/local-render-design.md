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
1 KB to 5 MB with no burst allowance, and traceable to AWS's own client:
`session-manager-plugin` chunks the stream into 1024-byte messages with a deliberate
1 ms sleep per chunk. There is no setting that raises it.

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

**The better remaining option — since built, with bounds.** Keep rendered content resident
in the terminal and pan with crop placements. The protocol support exists and
`placement_sequences` already sends `x,y,w,h` crop keys, so scrolling within resident
content costs a few hundred bytes, and it needs no second machine at all. It is the one
alternative here that removes bytes *without* adding a round trip, so the measurement
above never invalidated it.

What was holding it back was the "whole document" part: tens of megabytes resident in the
terminal, and terminal memory under placement churn is exactly where this project has been
burned before ([`terminal-support.md`](terminal-support.md) on wezterm#7953). What shipped
is **bounded** instead — one region of about two viewports, derived from an explicit pixel
budget rather than from the document's length, so a 5-page README and a 500-page one cost
the same. See [`architecture.md`](architecture.md#resident-regions) and
`:help md-viewer-resident-pan`.

Two things measured during that work are worth carrying forward. A region's PNG scales
close to **linearly** with pixel count rather than as `pixels^0.69` — two viewports came
back at 810 KB, about 1.7× the estimate, which is ~1.35 s of wire here. And Chromium's
`captureBeyondViewport: false` does not fail loudly on a clip taller than the viewport: it
returns a correctly *sized* image whose beyond-the-fold band is only 95.5% right. The flag
is asserted by test rather than assumed from the absence of an exception.

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
