# Client-side rendering over a slow link: an approach measured and rejected

**This describes code that no longer exists.** It was built, shipped, measured on the link
it was designed for, and removed in v0.2.0. The record is kept because the architecture is
a plausible idea a reader will have again, and because the reason it lost is not one
anybody would guess from first principles.

Everything below is in the past tense, including statements marked **Invariant** — those
were load-bearing while the code existed, and each names a plausible-looking
simplification that reintroduced a real defect.

## Verdict

**What was built.** The renderer ran on the machine the *terminal* was on rather than the
machine Neovim was on. A companion process (`companion.js`) served the ordinary renderer
protocol over a `0600` unix socket; `bin/md-viewer-ssh` wrapped `ssh` with that companion
behind it and a filter (`splice.js`) in front of the terminal; the remote plugin emitted a
~56-byte transmission token in place of each PNG upload and the filter substituted the
real Kitty upload back, byte for byte. Block geometry was elided from responses on the
same path. Later, scroll captures could be pipelined so several were in flight at once.

**What it cost.** It worked. It kept 13.3 MB of pixels off the link in one measured
session — and it made the preview *slower*:

| | renderer on the VM | renderer on the Mac |
|---|---:|---:|
| capture | 50–62 ms | 15–21 ms |
| link, per frame | ~0 (a pipe) | **~90 ms** |
| frame interval floor | **~56 ms** | ~107 ms |
| delivered | **6.3/s** | 3.0–4.7/s |

A ~96 ms round trip costs more than a 40 ms faster capture saves. The operator's verdict
after using it was "about the same", then measurably worse.

**Why it was removed.** The premise was wrong by the time the code landed. Phase 0 —
`render.scroll_scale` / `render.ssh_scroll_scale` and `render.ssh_scroll_settle_ms`, a
config change with no new process, no new transport and no new trust boundary — had
already taken wire saturation from 79% to 49%. Transit had stopped being the constraint.
Phases 1–3 then removed 16.7 seconds of wire time that was no longer on the critical path
and charged a 92 ms serial round trip per frame to do it. The byte case was real, and the
cheaper lever had already won it.

Removing it also restores an invariant that had to be narrowed to accommodate it:
**md-viewer opens no listening port**, full stop, rather than "on the machine running
Neovim".

**The one condition worth revisiting it under.** A link with **low round-trip latency but
capped throughput** — a shaped or metered connection rather than a relayed one. There the
bytes are the whole cost and the round trip is not, so the arithmetic that killed this
inverts. Nothing else about the design was wrong: the seam was clean, the byte equivalence
held, and the failure modes were all one-way. It was pointed at the wrong bottleneck.

## The measurements that decided it

### 2026-08-13, and what it changed

Client rendering shipped and the operator reported scrolling felt **about the same**. The
numbers agreed, and the reason inverted the premise this document had opened with.

| | Phase 0 (render on the VM) | Phases 1–3 (render on the Mac) |
|---|---|---|
| Frame interval floor | ~56 ms | **107 ms** |
| Mean interval, scrolling continuously | ~160 ms | **213 ms** |
| Delivered rate | 6.3/s | **4.7/s** |
| Moving capture | 50–62 ms | **14.9 ms** |
| Pixels crossing the link | all of them | **none** |

`coalesced_scroll_events = 1292` against 101 moving frames confirms the operator was
scrolling continuously, so the mean is pipeline time rather than idle time — the mistake
made once already in this project's history.

At depth 1 the arithmetic closes and the round trip really is the floor: 48 ms out + 20 ms
render + 48 ms back = 116 ms against an observed 107 ms. The Mac was busy 14% of the time.

### Pipelining, which was the fix, and lost worse

With N captures in flight the floor becomes `max(render, RTT/N)`: N=3 predicts ~31 ms.
The prediction was fixed before the run — floor under 40 ms, delivered above 20/s — so a
result that missed could not be reinterpreted as a win. It missed:

| | depth 1 | depth 3 |
|---|---:|---:|
| moving frames | 41 | **11** |
| scrolled for | 19.8 s | 28.9 s |
| interval floor | 107 ms | **198 ms** |
| delivered | 3.0/s | **0.4/s** |

Eleven frames in 28.9 seconds while scrolling 46% longer is the signature of frames being
produced and then thrown away, and that is what happened. `renderer.lua`'s `is_stale`
compared each response against `session.request_serial` — a session-wide "only the newest
request may display" gate that predated the lane machinery and did the same job one layer
up. Three concurrent captures took serials N..N+2, so N and N+1 were discarded **on
arrival, after the link had already carried them**: three times the work for a third of
the frames.

That gate was found and narrowed to match the lane exemption. **The fix was never measured
on a link**, which is exactly the state the first regression shipped in, and is why the
default was returned to 1 rather than raised on the strength of an argument.

Two settings also became mistuned under client rendering, because both traded against wire
bytes that no longer existed: `ssh_scroll_settle_ms = 400` added 240 ms of pure delay
before the picture sharpened, and `ssh_scroll_scale = 0.5` traded sharpness for *render*
time rather than for bytes.

Two details of the design below were changed during implementation, both toward safety:

- The token was `ESC _ MDV1;tx;<ref>;<control> ESC \` — the *control string itself*
  travelled in it, rather than an image id the splicer would have had to reassemble a
  control string from. That kept `chunks()`'s caller the only thing deciding what a
  transmission looked like, and it is what let the same seam carry animation frames
  (`a=f`) unchanged.
- An unknown reference was **forwarded verbatim**, not dropped. Dropping is right if the
  token is ours and the frame was evicted; forwarding is right if it was never ours. Both
  end the same way for a real token — the terminal discards an APC string it does not know
  — so forwarding was strictly better: it could not destroy somebody's output.

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

The cheap one, and the one that shipped and stayed. PNG size against real content follows
`bytes ∝ pixels^0.69`, so halving the capture scale during a scroll cuts roughly 2.6× off
the moving frame while the existing settle frame restores sharpness the moment the wheel
stops. Confirmed on the measured link at **3.01×** — 134,851 → 44,766 bytes, 224 ms of
transit down to 74 ms — with the settle frame byte-identical across both arms, which was
the invariant that mattered. `render.ssh_scroll_settle_ms` then spends that settle frame
less often.

The options and the `device_scale_factor` warning are documented in the README,
`:help md-viewer-ssh` and [`troubleshooting.md`](troubleshooting.md); they are not
repeated here. The two invariants that constrain them are below, and are still live.

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

**This mattered for everything below.** If the missing time were the TUI blocking while it
wrote base64 into a pty the far end drained at 0.80 MB/s, it would still be caused by bytes
— just not by the bytes anyone was counting — and client-side rendering would have fixed it
too. If it were anything else, client-side rendering would buy latency per frame and not
buy smoothness.

The instruction written here at the time was: **do not build the client-render architecture
before that number has been read.** `scripts/scroll-scale/ab.lua` reports the
decomposition, and the discriminating row is **encode + hand to UI** — `nvim_ui_send`
happens inside it, so pty back-pressure lands there rather than in UNACCOUNTED. It was
built anyway, and the answer turned out to be the second one. That is the whole lesson of
this document, and it is cheaper to read than to repeat.

What neither lever removes is the transit ceiling itself. Transit alone caps preview updates
at 13.4/s where it capped them at 4.4/s, and the settle frame still costs half a second
whenever it is taken.

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

| Crosses the link | Pixels over the link | Client-render |
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
client-side rendering replaced one function's output and nothing else. Placement math,
double buffering, occlusion cut-outs, z-layer resolution, deletion discipline and the
golden byte test all stayed on the Neovim host, untouched — and this is the part of the
design that was right, and that a retry should reuse.

**This is why cell ownership was not a problem.** A design where a second process draws
into the terminal has to fight Neovim for the grid: flicker, stale placements, wrong
position after a resize. This one never did. Neovim kept owning the grid; the client
substituted image *data* for a token, in place, at the same position in the same byte
stream. The terminal received the bytes it already received.

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

**Invariant:** the splicer was a passthrough that recognised exactly one token shape. It
never interpreted, rewrote or buffered anything else, and any error put it into permanent
passthrough for the rest of the session. A filter in the path of an interactive SSH session
that gets creative is a corrupted terminal.

### One frame

1. The plugin requested a capture over the socket. **~408 B.**
2. The companion rasterized locally, stored the PNG under a `frameRef` in a bounded cache,
   and replied with metadata, the ref and the PNG's dimensions. **~277 B.**
3. The plugin emitted, through the unchanged `nvim_ui_send` path, a token
   (`ESC _ MDV1;tx;<frameRef>;<control> ESC \`) followed by the ordinary placement
   commands. **~56 B.**
4. The splicer substituted byte-identical `chunks(base64(png), control)`.

The frame was always rendered before the token was emitted, so there was no race. A token
whose ref the companion no longer held was forwarded verbatim: the terminal discards an APC
string it does not recognize, so the frame did not appear and the next render replaced it.
`:MdViewerHealth` warned when that count was non-zero, because nothing else would ever have
said so.

**Invariant:** byte equivalence was proven offline. `kittyChunks` in `splice.js` and
`chunks()` in `kitty_raw.lua` were asserted against the same pinned artifact
(`tests/fixtures/splice-upload.esc`) from both suites, so neither could drift alone. A
second Lua assertion stripped the upload from a byte-carried and a reference-carried frame
and required what remained — every placement, crop, z-index and deletion — to be equal.
None of those files survive the removal; the technique is what is worth keeping.

**Invariant:** unchanged `blocks` were elided from capture responses. Block geometry is
10,477 B for this README and was returned on *every* capture even when the layout was
reused. Sending it per frame would have cost 1.4 MB across one wheel spin and quietly
undone the entire saving. The request named the `blocksRevision` it held — a hash of the
layout key, so exact rather than conservative, and it survived a renderer restart — and a
matching revision returned no `blocks` at all. `renderer.lua` reattached what it held
before any caller saw the result.

Both halves were needed and the measurement said so: a reference alone left a 6,542-byte
response, against under 2,048 with the elision too. **This is the trap most worth
remembering.** Removing the largest thing on a link promotes whatever was second, and a
saving measured only on the thing you removed will read as a win it is not.

### Discovery

The companion exported `LC_MD_VIEWER`. OpenSSH forwards `LC_*` by default — `SendEnv LANG
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
| No companion | No `LC_MD_VIEWER`, no token ever emitted, behaviour unchanged |
| Companion present, socket unreachable | Warned in `:MdViewerHealth`; rendered beside Neovim |
| Companion dies mid-session | Socket closes, one notification, falls back to the local renderer |
| Token reaches a terminal with no splicer | An unknown APC sequence, which conformant terminals ignore |

Every one of these was one-way, and none of them ever fired in anger. The architecture's
failure was not that it broke; it is that it worked and did not help.

## What this does to the security posture

The project's standing claim is that the renderer opens no port and speaks to nothing over
the network. This design narrowed it — precisely, and in writing, but narrowed it — which
is the second reason removing the code was worth doing. The narrowing was:

- **On the machine running Neovim, nothing changed.** The plugin only ever *dialled out*.
  The listening socket on that side was created by `sshd` because the user asked for a
  reverse forward, not by md-viewer. `renderer/src/main.js` was unmodified and still opened
  nothing, which is why `tests/node/no-listening-port.test.js` kept passing as written.
- **On the client machine** an opt-in companion, started by hand, listened on a **unix
  domain socket** with mode `0600` — never a TCP port.
- **Remote image fetching moved to the client**, so the SSRF blocklist protected the
  client's private network instead of the Neovim host's. The logic was unchanged: https
  only, resolve then validate then pin the address, every redirect hop re-checked, no
  allowlist. That is a real change of *which network is being defended*, and it needed a
  section in `SECURITY.md` to say so.
- **Local image reads did not move, so they failed.** Reading a file needs the renderer
  beside it, and there was nothing on the other side of the document-root check to reach.
  No containment rule was weakened; a local image rendered as the placeholder the existing
  rules already specify. `:MdViewerHealth` noted it, because "why is this image broken only
  over SSH" is otherwise unanswerable.
- **`bin/md-viewer-ssh` read the session's output stream**, since filtering it is what it
  was for. It had no network access of its own, forwarded everything it did not recognize,
  and wrote its log (splicer events and counters, never session output) mode `0600`.

Each of those was defensible on its own and none of them was a defect. Together they are
five paragraphs of qualification on a one-line claim, which is the cost the feature was
charging even when it worked.

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
remains the best option for an SSH user who wants more than `render.scroll_scale` gives
them, and it is the one alternative here that the 2026-08-13 measurement did not
invalidate — it removes bytes *without* adding a round trip.

## References

- [`architecture.md`](architecture.md) — the data flow this extended
- [`troubleshooting.md`](troubleshooting.md) — the reader-facing symptoms
- [`terminal-support.md`](terminal-support.md) — the evidence ladder any per-terminal claim uses
- [`../SECURITY.md`](../SECURITY.md) — what the defaults enforce
