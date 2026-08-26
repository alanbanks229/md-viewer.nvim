# Validating per-machine link-rate detection (v0.3.0-rc7)

Branch `feat/link-rate-detection`, stacked on `fix/resident-bootstrap` (PR #5,
open). Two commits: `6cfd52b` corrects the compression reasoning in
`scripts/ssh-link-speed.sh` and `docs/local-render-design.md`; `16c7606` is the
feature.

**This file is branch-scoped.** Fold what survives into `docs/development.md`'s
Manual verification section before the branch merges, and delete it.

## What is already proven, and what is not

Proven on the machine this was written on, and green in `make test` (2897 Lua
assertions, 275 node): the resolver's precedence, the cache round trip, every
refusal, the key computed in Lua against the same key computed in POSIX sh, the
`--out` parsing, the winbar arithmetic, and the script end to end over a local
pty — `--samples`, `--out`, `--cache`, `--key`, and the unwritable-cache
degradation.

**Not proven, and the entire reason this file exists: the two numbers.**

| host | expect | acceptance (±10%) |
|---|---|---|
| `aide-spock` (SSM tunnel) | 1,010,000–1,070,000 B/s | 927,000 – 1,133,000 |
| `ichigo` (LAN, plain TCP/22) | ~14,700,000 B/s | 13,230,000 – 16,170,000 |

`:MdViewerMeasureLink` takes three samples and **keeps the lowest**, so expect
the low end of each band rather than the middle. That is deliberate: every way
this measurement goes wrong makes it look faster, and nothing makes it look
slower.

---

## Three things that will silently ruin the run

Check all three before measuring anything. Each produces a plausible wrong
answer rather than an error, which is the failure mode this whole feature exists
to correct.

**1. A number still pinned in the shared vault config.** `configured` outranks
`cached`, so if `obsidian-vault/Neovim/.config/nvim/lua/plugins/md-viewer.lua`
still sets `render.ssh_link_bytes_per_sec`, the health row will read
`configured` on every machine no matter what you measure. Removing that line is
Phase A and is being handled separately; it is a **prerequisite for step 3
only**. Steps 1 and 2 work regardless — `:MdViewerMeasureLink` measures and
caches whatever the tier says.

```vim
:lua =require("md-viewer.config").get().render.ssh_link_bytes_per_sec
```

`"auto"` means Phase A is done. A number means step 3 will not show `cached`,
and that is expected rather than a bug.

**2. `$SSH_TTY` must be set inside Neovim.** It is the only route that works: a
`vim.system` child is detached from the controlling terminal by libuv, so
`/dev/tty` fails outright with ENXIO, and the code refuses to fall back to it.

```vim
:echo $SSH_TTY
```

Expect `/dev/pts/N`. Empty means the command will refuse, and the reason is
worth chasing rather than working around — tmux, a re-attached session, `sudo
-i`, or a Neovim that outlived the SSH session it was started from can all do
it. Say which one it was.

**3. No preview open.** The command refuses while one is, because a resize, a
scroll or a `ColorScheme` during the run is a full capture on the same wire and
would land as a slower link rather than as an error.

---

## Step 0 — get the branch onto the machine that runs Neovim

Neovim runs on the VM, so the plugin has to be there — not on the laptop.

```sh
scripts/rig/deploy.sh aide-spock
```

Then point lazy.nvim at the deployed copy **on that machine only** (`dir =
"~/md-viewer.nvim"`) and `:Lazy reload md-viewer.nvim`. If the branch has been
pushed, a branch pin in the lazy spec is the normal route instead.

Confirm what is actually loaded before trusting anything below:

```vim
:lua =vim.fn.systemlist("git -C " .. vim.fn.fnamemodify(vim.api.nvim_get_runtime_file("lua/md-viewer/linkrate.lua", false)[1], ":h:h:h") .. " log --oneline -1")
```

If `lua/md-viewer/linkrate.lua` is not in the runtime path at all, the deploy did
not land and nothing else in this file will mean anything.

---

## Step 1 — checks that need no measurement

Cheap, fast, and they isolate a broken deploy from a broken measurement.

```vim
:lua =require("md-viewer.linkrate").key()
:lua =require("md-viewer.linkrate").cache_path()
:lua =require("md-viewer.linkrate").describe()
```

Expect a 16-character hex key, a path under `stdpath("state")` ending
`/md-viewer/link-rate/<key>.json`, and `unknown -- :MdViewerMeasureLink measures
it, ...`.

Then `:MdViewerHealth`. The Rendering section should carry a `Link rate:` row
reading unknown, and **the Warnings section must not mention the link at all** —
unknown is not a fault, and a warning here would fire on every machine that has
never measured.

### The key-parity check, which is the one I am least sure of

Run this in a **login shell on the same host**, not through Neovim:

```sh
sh ~/md-viewer.nvim/scripts/ssh-link-speed.sh --print-key
```

It should print the same 16 characters `linkrate.key()` did. The test suite pins
this against a fabricated environment, so the algorithm agrees; what it cannot
pin is whether the *environment* agrees — `TERM` in particular can differ
between Neovim's inherited environment and a fresh login shell.

**If they differ, that is a real finding but a narrow one.** It only breaks the
`sh ssh-link-speed.sh --write-cache` route, which would then file its
measurement where nothing reads it. `:MdViewerMeasureLink` computes the key in
Lua and is unaffected. Report both keys and `echo "$TERM"` from each side.

---

## Step 2 — measure aide-spock

```vim
:MdViewerMeasureLink
```

Expected sequence: a notification (`measuring this link. The screen will flood
and then clear; please do not type.`), roughly **30 seconds** of garbage on
screen, a clear, and a second notification with the number and the spread.

Thirty seconds is the estimate, not a measurement: at ~1 MB/s the script's
doubling ramp settles at 8 MB on the first try (8 s ≥ the 5 s target), so it is
three transfers of ~8 s plus a prefill. Much longer than a minute means
something is wrong; the hard timeout is five minutes.

Record verbatim:

- the full second notification, including the spread
- `:MdViewerHealth`'s `Link rate:` row
- `:lua =require("md-viewer.linkrate").describe()`
- the record itself: `:lua =vim.fn.readfile(require("md-viewer.linkrate").cache_path())`

The health row should now read `cached`, with `measured just now`, a spread, and
the key — **unless the vault still pins a number**, in which case it reads
`configured` and that is the expected consequence of Phase A being outstanding.

### What the number means

Both figures below are *effective* rates: base64 as md-viewer sends it, with
whatever the compressor gives back already included. The channel underneath
aide-spock is ~774,000 B/s, and 774,000 ÷ 0.75 = 1,032,000 is why the effective
figure is what it is. A result near **1.03 MB/s does not beat the SSM ceiling**;
subtract the quarter and it is 0.77.

- **Well above 1.15 MB/s** — either this host is not reached through an SSM data
  channel (`ssh -G aide-spock | grep -i proxycommand` settles it), or something
  is compressing more than base64's inherent 25%. Both are findings.
- **Well below 0.9 MB/s** — plausible on a loaded link; take a second
  measurement before concluding anything. If the two disagree by more than 2×,
  health will say so on its own.
- **Any stderr caveat in the notification** — the script writes anything
  actionable to stderr and it is surfaced with the result. The one that matters
  says the host generated the payload barely faster than the link carried it,
  which makes the answer a floor rather than a rate. At ~1 MB/s against a CPU
  doing hundreds of MB/s this should not fire; if it does, report it, because it
  means the measurement was CPU-bound and the number is not the link's.

---

## Step 3 — measure ichigo

Same command, same checks. Two differences worth expecting rather than
diagnosing:

- The ramp settles at **128 MB**, not the 64 MB that produced the 14.7 MB/s
  figure this is being checked against, because 64 MB takes 4.35 s and the
  target is 5. So expect **~45 seconds** and a figure at or slightly under 14.7.
- The `--max-mb` note may appear on stderr, saying the terminal rather than the
  network may be what is being measured. On a LAN host that is true and is the
  script being honest, not a fault.

Two different keys will now exist under `link-rate/`, one per host, which is the
whole point. `ls` the directory on each and confirm each machine has only its
own.

---

## Step 4 — the shell route (optional, but it is half the feature)

From a shell on aide-spock, with Neovim closed:

```sh
sh ~/md-viewer.nvim/scripts/ssh-link-speed.sh --write-cache
```

It should print the measurement, then say it cached the answer under this
machine's key with nothing to paste. Re-open Neovim and confirm
`:lua =require("md-viewer.linkrate").describe()` reports it with
`source` `ssh-link-speed.sh` in the record. This is the route the key-parity
check in step 1 is guarding.

---

## Step 5 — the ETA (optional, and the only thing the number does)

The rate feeds exactly one runtime consumer: the resident warm-up's estimate.
Resident mode is experimental and off by default, so this needs opting in.

```lua
require("md-viewer").setup({ image = { resident = "auto" } })
```

Open a long document over SSH and watch the winbar. With a measured link it
should read `warming 3/12 ~14s` rather than `warming 3/12`; the estimate appears
only after the first chunk lands, because it extrapolates from the bytes that
document has actually produced rather than from its pixel count.

Sanity, not precision: does the estimate fall as chunks arrive, and is it in the
right order of magnitude against the wall clock? A wildly wrong ETA on a
correctly measured link would mean the 4/3 base64 factor or the per-chunk
average is wrong, which nothing on a fast machine can catch.

---

## Refusals, and what each one means

| message | means |
|---|---|
| `this is not an SSH session, so there is no link to measure` | none of `SSH_CONNECTION`, `SSH_TTY`, `SSH_CLIENT` is set |
| `close the preview first (:MdViewerToggle)` | a preview window is open; its captures would be measured as the link |
| `no terminal device: SSH_TTY is unset and this platform has no /proc/self/fd/1 to resolve` | see prerequisite 2 |
| `refusing /dev/tty: a vim.system child has no controlling terminal` | `SSH_TTY` literally names `/dev/tty`; measured to fail, so it is refused rather than attempted |
| `SSH_TTY is not a terminal device (...)` | the path is stale or is not a character device |
| `refusing: stdout is not a terminal ...` | from the script itself: the redirect landed on something that is not a pty. Report the whole stderr — this one would mean the `sh -c 'exec >"$device"'` wrapper is wrong on this host's `/bin/sh` |
| `a measurement is already running` | a previous run has not finished; wait it out |

---

## Where I think this could be wrong

Stated so you argue with it rather than work around it.

1. **`SSH_TTY` on aide-spock.** The spike that settled the route ran on
   `ichigo`. aide-spock arrives as an ordinary sshd session with a
   `ProxyCommand` in front, so sshd should set `SSH_TTY` identically — but that
   is reasoning, not a measurement, and it is the load-bearing assumption of the
   whole command.
2. **The `sh -c 'device=$1; shift; exec >"$device" || exit 3; exec sh "$@"'`
   wrapper** against the VM's `/bin/sh` (dash on Ubuntu). Tested on macOS
   `/bin/sh` only.
3. **The TUI is attached**, unlike `ssh-link-speed.sh`'s own instruction to
   close Neovim. `lazyredraw` is set and a preview is refused, but a redraw
   during the run still costs wire time that is counted against the link. If
   `:MdViewerMeasureLink` reads consistently *lower* than the same script run by
   hand from a shell, that is the cause and it is worth quantifying — run both
   on aide-spock and compare.
4. **`--samples 3` is a guess at the right number.** Spread was ~7% on
   aide-spock and 2.2× on one earlier link. If three samples on aide-spock come
   back inside 2%, two would have done and the command could be 8 seconds
   shorter.
5. **The 30 s / 45 s estimates** are arithmetic from the ramp, not observations.
6. **`sha256sum` on the VM** — assumed present (coreutils). `--print-key` in
   step 1 falls back to `shasum` then `openssl`, and refuses with a clear message
   if none is there.

## What to report back

The two numbers and their spreads, verbatim; the health rows; whether the key
parity check agreed; anything on stderr; and which of the six items above turned
out to be wrong. If a number lands outside its band, the raw
`sh scripts/ssh-link-speed.sh` output from the same host in the same session is
what settles whether the command or the link is the difference.
