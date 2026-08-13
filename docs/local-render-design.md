# Client-side rendering over a slow link

How md-viewer can render on the machine your *terminal* runs on rather than the machine
Neovim runs on, why that is worth doing, and what it may not break. Statements marked
**Invariant** are load-bearing: each has a plausible-looking simplification that
reintroduces a real defect.

This is a design record. It describes the architecture and the evidence behind it; the
shipped behaviour is documented in [`../README.md`](../README.md),
`:help md-viewer-client-render` and [`troubleshooting.md`](troubleshooting.md).

## Status

| Phase | State |
|---|---|
| 0 — `render.scroll_scale`, SSH-gated | **Shipped and validated on the real link.** Moving frame 134,851 → 47,469 B; delivered rate 3.8/s → 6.3/s; wire saturation 79% → 49% |
| 1 — transport seam (`service.js`, `companion.js`, socket transport) | **Shipped.** One machine only: responses still returned a path |
| 2 — transmission tokens, splicer, `blocks` elision | **Shipped.** `frames.js`, `splice.js`, the `transmit()` seam, `frameTransport: "ref"`, `blocksRevision` |
| 3 — `bin/md-viewer-ssh`, `LC_MD_VIEWER`, diagnostics | **Shipped.** End-to-end on one machine; not yet run across a real link |
| 4 — parity: overlay sheet, animation frames, local images by reference | **Not built.** See "What is still missing" below |

Two details of the design below were changed during implementation, both toward
safety, and the text has been corrected in place:

- The token is `ESC _ MDV1;tx;<ref>;<control> ESC \` — the *control string itself* travels
  in it, rather than an image id the splicer would have to reassemble a control string
  from. That keeps `chunks()`'s caller the only thing that decides what a transmission
  looks like, and it is what lets the same seam carry animation frames (`a=f`) unchanged.
- An unknown reference is **forwarded verbatim**, not dropped. Dropping is right if the
  token is ours and the frame was evicted; forwarding is right if it was never ours. Both
  end the same way for a real token — the terminal discards an APC string it does not know
  — so forwarding is strictly better: it cannot destroy somebody's output.

### What is still missing

- **Local images.** `resolveLocalImage` reads the renderer host's filesystem, which under
  client rendering is the wrong machine. The image renders as its failure placeholder.
  Phase 4's asset channel is the fix, and it is the one substantially new subsystem left.
- **Animated images.** `animation.lua` reads frame PNGs from paths on the renderer host,
  so animations stay on their still frame. The `transmit()` seam already accepts a
  reference for them; what is missing is `frames[].width/height` in the renderer's
  `animation` response and a reference in place of each path.
- **The overlay sheet** still round-trips: the renderer returns it base64 in the response
  and Lua sends it back as an upload. It is a solid-colour PNG of a few kilobytes,
  uploaded once per session, so this is a correctness-neutral inefficiency rather than a
  gap. It goes through the same seam whenever the response grows a reference.

## The problem

md-viewer rasterizes a frame where Neovim runs and sends the pixels to the terminal. Over
a fast local pipe that is free. Over a throttled SSH link it is the whole cost.

The link measured for this work reaches a remote VM through AWS SSM Session Manager
(WebSocket-over-TLS, not TCP/22). It has a flat **0.80 MB/s** ceiling, confirmed from 1 KB
to 5 MB with no burst allowance, and traceable to AWS's own client: `session-manager-plugin`
chunks the stream into 1024-byte messages with a deliberate 1 ms sleep per chunk
(`StreamDataPayloadSize = 1024`). There is no setting that raises it.

Latency is not the problem. A tiny Kitty capability query round-trips the same relay in
96 ms, while a 432 KB frame serializes in ~540 ms. The lag is **throughput-bound**, so it
scales with bytes and only with bytes.

Measured on that link, per stage of one settle frame:

| Stage | Time | Share |
|---|---:|---:|
| Chromium capture | ~81 ms | 15% |
| Lua → pty | ~2 ms | <1% |
| **Wire serialization** | **~346 ms** | **80%** |
| Terminal receive + base64 + PNG decode | ~14 ms | 3% |
| Terminal GPU composite | ~16 ms | 4% |

**No configuration fixes this, and two obvious settings make it worse.**
`render.device_scale_factor` is a *calibration divisor*, not a density knob: lowering it to
`1` stops dividing the terminal cell down, so the CSS viewport doubles and the frame grows
from 80 KB to 224 KB. It also collapses the fast/settle distinction, because the fast frame
is defined as a CSS-scale capture against a device-scale one — at `dsf=1` they are the same
capture. `render.fast_scroll = false` makes every frame a full device capture. Both were
A/B'd live and both felt equal or worse. The defaults are already the fastest configuration
available, which is why the remedy is a code change rather than advice.

## The two levers

### 1. Send fewer pixels (`render.scroll_scale`)

PNG size against real content follows `bytes ∝ pixels^0.69`, so halving the capture scale
during a scroll cuts roughly 2.6× off the moving frame while the existing settle frame
restores sharpness the moment the wheel stops. This needs no new process, no new transport
and no new trust boundary; it is on by default over SSH and off everywhere else.

Confirmed on the measured link, operator-driven through `scripts/scroll-scale/ab.lua`,
2026-08-12, Rocky Linux 8.10 VM reached from iTerm2 over AWS SSM:

| | baseline 1.0× | treatment 0.5× |
|---|---:|---:|
| `fast_png_bytes` | 134,851 | 44,766 |
| transit at 0.80 MB/s | 224 ms | 74 ms |
| `retina_png_bytes` | 304,666 | 304,666 |
| `capture_encoder` | `cdp_fast_png` | `cdp_fast_png` |

**3.01×**, against 2.58× measured on a macOS development machine at a narrower pane. The
exponent is not a constant: this content came out at `pixels^0.795` where the original
investigation and the development machine both sat near `^0.69`. Fonts, Chromium build and
layout all move it, so treat 2.6× as the conservative figure and anything above it as
content-dependent luck. The settle frame is byte-identical across the two phases, which is
the invariant that mattered.

The settle frame is untouched by this, deliberately, and it is still 304,666 bytes —
**508 ms** of transit. What can be done cheaply is spending it less often:
`render.ssh_scroll_settle_ms` raises the idle time before that capture from 160 ms to
400 ms on an SSH session, above the 50–150 ms gaps between wheel notches and below the
pauses between reading and scrolling again, so it is paid for a reader who has actually
stopped rather than one mid-flick. The cost is that sharpness arrives about 240 ms later
when they do stop, which is only worth it when the frame itself takes half a second.

### An unresolved contradiction, recorded rather than smoothed over

Operator-driven, 2026-08-12, second run: the byte reduction landed exactly as designed —
average moving frame 100,116 → 27,810 bytes (**3.6×**), total traffic 5.03 MB → 2.16 MB —
and **the frame rate did not move**: 35 frames in 20 s became 34 in 20 s. Wire utilisation
was 42% and then 18% of the 0.80 MB/s ceiling, so the link was never saturated in either
arm.

That is not consistent with transit being the constraint on the scroll loop. The per-frame
arithmetic at the top of this document still holds — a frame's transit really is several
times its capture — but a loop turning over every ~520 ms is not a loop bounded by 74 ms
of transit. Something else accounts for roughly 350 ms per frame:

| | |
|---|---|
| Full renderer + Lua path, measured with no network at all (request → capture → PNG read → base64) | **32 ms**, ~31 fps |
| Observed frame interval over the link | ~520 ms |
| Of which transit | 74 ms |

**This matters for everything below.** If the missing time is the TUI blocking while it
writes base64 into a pty the far end drains at 0.80 MB/s, it is still caused by bytes, just
not by the bytes anyone was counting — and client-side rendering removes essentially all of
them from that pty, so it would fix this too. If it is anything else — VM scheduling,
Neovim's redraw cycle, the input path — then client-side rendering buys latency per frame
and does not buy smoothness, and the case for building it is much weaker than the byte
table suggests.

`scripts/scroll-scale/ab.lua` now reports the decomposition, and the discriminating row is
**encode + hand to UI**: `nvim_ui_send` happens inside it, so pty back-pressure lands there
rather than in UNACCOUNTED. **Do not build the client-render architecture before that number
has been read.** The byte case for it is sound and the smoothness case is currently
unproven.

What neither lever removes is the transit ceiling itself. Transit alone caps preview updates
at 13.4/s where it capped them at 4.4/s, and the settle frame still costs half a second
whenever it is taken. Those numbers exist only because pixels cross the link at all — but as
of this run they are not the numbers a reader is waiting on.

**Invariant:** only the *moving* frame is scaled. The settle capture stays at full
`device_scale_factor`, or an idle preview would sit at reduced sharpness indefinitely —
which is the one state a reader actually looks at.

**Invariant:** placement geometry keys off cells and the CSS viewport, never the capture
scale. A frame captured at 0.5× is placed into exactly the same cell rectangle as a frame
captured at 1×; the terminal scales it. A test asserts the placement bytes are identical
across scales.

### 2. Send no pixels at all (client-side rendering)

The bigger lever. Ship the markdown *source* over the link and rasterize on the machine the
terminal runs on, where the pixels never touch the throttled hop. Scrolling stops being a
transfer and becomes a local operation.

Measured on this repository's own README (14,429 bytes, 360×774 CSS viewport, `dsf=2`):

| Crosses the link | Today | Client-render |
|---|---:|---:|
| Document open | 303,148 B (base64 PNG) | ~26,014 B (request + response) |
| One scroll frame | 101,215 B (base64 PNG) | ~685 B |
| One wheel spin (136 coalesced frames) | 13.8 MB → ~17 s of wire | ~93 KB → ~0.12 s |

Note what is *not* shipped: the rendered HTML is 45,630 B and its source map 58,305 B,
because provenance instrumentation wraps every text run in a `data-md-source-id` span. Both
are produced and consumed on the rendering side. **Markdown is the smallest thing that
reproduces the document**, so markdown is what crosses.

## The seam

The Kitty graphics protocol separates transmitting an image from placing it, and
`backends/kitty_raw.lua` already builds the two separately:

```lua
-- build_show()
local upload   = chunks(encoded, ("a=t,f=100,t=d,q=2,i=%d"):format(id))  -- 80-324 KB
local sequence = placement_sequences(item, placement)                    -- ~60 B each
return id, upload .. sequence
```

Only `chunks(...)` is expensive, and `send()` is a single choke point (`nvim_ui_send`). So
client-side rendering replaces one function's output and nothing else. Placement math,
double buffering, occlusion cut-outs, z-layer resolution, deletion discipline and the golden
byte test all stay on the Neovim host, untouched.

**This is why cell ownership is not a problem here.** A design where a second process draws
into the terminal has to fight Neovim for the grid: flicker, stale placements, wrong
position after a resize. This design never does. Neovim keeps owning the grid; the client
substitutes image *data* for a token, in place, at the same position in the same byte
stream. The terminal receives the bytes it receives today.

## Architecture

```
client machine                                 Neovim host
──────────────────────────────────────         ─────────────────────────
terminal
  └ shell
     └ md-viewer-ssh  (companion)
          ├─ ssh   stdin = INHERITED tty ─────► sshd ─► nvim ─► md-viewer
          │        stdout = pipe ◄──────────────────────────────────┘
          │          └ splicer: passes bytes through untouched,
          │            replaces MDV tokens with real `a=t` uploads
          ├─ unix socket (0600) ◄── ssh -R ──── plugin dials the forwarded port
          │          └ the ordinary renderer dispatch
          └─ the browser already installed on this machine
```

**Why stdin stays inherited.** `ssh` reads the window size with `ioctl(TIOCGWINSZ)` on
*stdin*. Give it a pipe and resize breaks permanently. Inheriting stdin leaves raw mode,
`^C`, `^Z`, resize and exit status entirely ssh's business, and needs no pty — therefore no
native module, therefore nothing to download on a machine that may have no egress. Only
stdout is filtered.

**Invariant:** the splicer is a passthrough that recognises exactly one token shape. It
never interprets, rewrites or buffers anything else, and any error puts it into permanent
passthrough for the rest of the session. A filter in the path of an interactive SSH session
that gets creative is a corrupted terminal.

### One frame

1. The plugin requests a capture over the socket. **~408 B.**
2. The companion rasterizes locally, stores the PNG under a `frameRef` in a bounded cache,
   and replies with metadata, the ref and the PNG's dimensions. **~277 B.**
3. The plugin emits, through the unchanged `nvim_ui_send` path, a token
   (`ESC _ MDV1;tx;<frameRef>;<control> ESC \`) followed by today's placement commands.
   **~56 B.**
4. The splicer substitutes byte-identical `chunks(base64(png), control)`.

The control string travels *in* the token rather than being reconstructed from an image id,
so `transmit()`'s caller remains the only thing that decides what a transmission looks like
— which is what lets the same seam carry an `a=f` animation frame with its own gap key
without the splicer learning anything new.

The frame is always rendered before the token is emitted, so there is no race. A token whose
ref the companion no longer holds is forwarded verbatim: the terminal discards an APC string
it does not recognize, so the frame does not appear and the next render replaces it.
`:MdViewerHealth` warns when that count is non-zero, because nothing else would ever say so.

**Invariant:** byte equivalence is proven offline. `kittyChunks` in `splice.js` and
`chunks()` in `kitty_raw.lua` are asserted against the same pinned artifact
(`tests/fixtures/splice-upload.esc`) from `tests/node/splice.test.js` and
`tests/lua/cases/client_render.lua`, so neither can drift alone. A second Lua assertion
strips the upload from both a byte-carried and a reference-carried frame and requires what
remains — every placement, crop, z-index and deletion — to be equal.

**Invariant:** unchanged `blocks` are elided from capture responses. Block geometry is
10,477 B for this README and is returned on *every* capture even when the layout was reused.
Sending it per frame would cost 1.4 MB across one wheel spin and quietly undo the entire
saving. The request names the `blocksRevision` it holds — a hash of the layout key, so it is
exact rather than conservative and survives a renderer restart — and a matching revision
returns no `blocks` at all. `renderer.lua` reattaches what it holds before any caller sees
the result, so nothing downstream knows this happens.

Both halves are needed and the measurement says so: a reference alone left a 6,542-byte
response, against under 2,048 with the elision too. `tests/node/client-frames.test.js`
asserts that number rather than the reasoning.

### Discovery

The companion exports `LC_MD_VIEWER`. OpenSSH forwards `LC_*` by default — `SendEnv LANG
LC_*` in the stock client config, `AcceptEnv LANG LC_*` in the stock sshd config — which is
the same mechanism that already carries `LC_TERMINAL`, and the reason a remote Neovim can
identify iTerm2 at all. The address to dial comes from `client_render.address` or
`$MD_VIEWER_CLIENT_ADDR` on the Neovim host, following the precedent set by
`MD_VIEWER_TERMINAL_PROFILE`: an environment variable travels with the session, while a
value in a config file shared across many hosts is wrong the moment the session changes.

The reverse forward itself is ordinary SSH and is not md-viewer's to manage. `ssh -R
[bind_address:]port:local_socket` forwards a loopback TCP port on the Neovim host to a unix
socket on the client, which composes with whatever `-R` habit already exists.

### Failure and fallback

| Situation | Behaviour |
|---|---|
| No companion | No `LC_MD_VIEWER`, no token is ever emitted, behaviour is exactly as today |
| Companion present, socket unreachable | Warned in `:MdViewerHealth`; renders locally as today |
| Companion dies mid-session | Socket closes, one notification, falls back to the local renderer |
| Token reaches a terminal with no splicer | An unknown APC sequence, which conformant terminals ignore |

## What this does to the security posture

The project's standing claim was that the renderer opens no port and speaks to nothing over
the network. That claim is narrowed, not dropped, and the narrowing is precise:

- **On the machine running Neovim, nothing changes.** The plugin only ever *dials out*. The
  listening socket on that side is created by `sshd` because the user asked for a reverse
  forward, not by md-viewer. `renderer/src/main.js` is unmodified and still opens nothing,
  which is why `tests/node/no-listening-port.test.js` continues to pass as written.
- **On the client machine** an opt-in companion, started by hand, listens on a **unix domain
  socket** with mode `0600` — never a TCP port.
- **Remote image fetching moves to the client**, so the SSRF blocklist now protects the
  client's private network instead of the Neovim host's. The logic is unchanged: https only,
  resolve then validate then pin the address, every redirect hop re-checked, no allowlist.
  This is a real change of which network is being defended and is called out in
  [`../SECURITY.md`](../SECURITY.md).
- **Local image reads do not move, so they fail.** Reading a file needs the renderer beside
  it, and until Phase 4's asset channel exists there is nothing on the other side of the
  document-root check to reach. No containment rule was weakened; a local image simply
  renders as the placeholder the existing rules already specify. `:MdViewerHealth` notes
  this whenever client rendering is on, because "why is this image broken only over SSH"
  is otherwise unanswerable.
- **`bin/md-viewer-ssh` reads the session's output stream**, since filtering it is what it
  is for. It has no network access of its own, forwards everything it does not recognize,
  and writes its log (splicer events and counters, never session output) mode `0600`.

## Alternatives considered

**A dedicated terminal pane owned by the companion.** Sidesteps the grid question by not
sharing a grid, but gives up the preview window inside Neovim — its winbar, caret,
navigation keys, occlusion handling and mouse routing — and needs terminal automation to
create and size the pane. More work for a worse result.

**Writing to the ssh pty slave from a second process.** Two processes writing one terminal
is not atomic; a write landing inside an escape sequence wedges the terminal.

**Returning data through `TermResponse` instead of a socket.** Attractive, because it would
need no forward at all. It cannot work: replying to Neovim means injecting into ssh's
*input*, which means owning stdin, which means allocating a pty, which means a native module
that cannot be installed without network egress. `TIOCSTI` is restricted on current systems.

**Keeping the whole document resident in the terminal and panning with crop placements.**
Genuinely viable — the protocol support already exists and `placement_sequences` already
sends `x,y,w,h` crop keys — and it needs no second machine at all. Scrolling within resident
content costs about 200 bytes. It was not chosen because it requires tens of megabytes of
image data resident in the terminal, and terminal memory under placement churn is exactly
where this project has been burned before (see `terminal-support.md` on wezterm#7953). It
remains the best option for an SSH user who will never run a companion.

## References

- [`architecture.md`](architecture.md) — the data flow this extends
- [`troubleshooting.md`](troubleshooting.md) — the reader-facing symptoms
- [`terminal-support.md`](terminal-support.md) — the evidence ladder any per-terminal claim uses
- [`../SECURITY.md`](../SECURITY.md) — what the defaults enforce
