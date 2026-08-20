#!/usr/bin/env python3
"""What a resident megapixel actually costs the terminal.

`image.resident_memory_mb` is stated in megabytes and converted to pixels through
one number -- bytes per resident pixel -- about a representation no terminal
documents. Every budget decision this project makes rests on it, and for three
releases it was an assumed four. This is the measurement that replaced the
assumption: 12-13 B/px on iTerm2 3.6.11 / macOS 15, across three runs.

It is not corroborated. The only real session ever sampled held twelve slices,
budgeted at ~342 MB by that conversion, while `ps -o rss=` saw ~10 MB move --
see `rss.sh` and docs/terminal-support.md. Re-running this against real document
slices rather than the synthetic gradients below is the cheap experiment that
would separate "the sampler cannot see it" from "gradients do not generalise".

It is deliberately not `rss.sh`. That samples a real preview on the far end of a
real link for half an hour and answers "does it plateau"; this answers the prior
question -- "what does one megapixel cost, and does it come back" -- in about a
minute, with no SSH, no Neovim and no Chromium in the picture. A whole-document
design needs the second answer before it can pick a ceiling, and the first
answer only once that ceiling is in use.

Run it inside the terminal under test:

    python3 scripts/resident/rss-calibrate.py
    python3 scripts/resident/rss-calibrate.py --spawn      # new iTerm2 window

`--spawn` opens a fresh window and writes the report to `tmp/resident/calibrate/`
so the run does not scribble Kitty escapes over whatever you were doing.

The workload is the resident-slice lifecycle exactly: transmit an image, place
it once, delete the placement but keep the data. A terminal that decodes lazily
would otherwise report nothing at all for images it had never drawn -- which is
the failure mode that makes this measurement worth taking rather than assuming.

Environment: SLICES (default 6), SLICE_W/SLICE_H (a 2-viewport slice at
990x1020 CSS, device scale 2), CEILING_MB (abort, default 3000).
"""
import base64, os, struct, subprocess, sys, time, zlib

ESC = "\x1b"

SLICES = int(os.environ.get("SLICES", "6"))
SLICE_W = int(os.environ.get("SLICE_W", "1980"))  # 990 CSS px at device scale 2
SLICE_H = int(os.environ.get("SLICE_H", "4080"))  # two viewports of 1020 CSS px
CEILING_MB = int(os.environ.get("CEILING_MB", "3000"))
SETTLE = float(os.environ.get("SETTLE_SECONDS", "1.5"))


def gradient_png(width, height, phase):
    """A PNG that cannot be stored as a flat colour.

    Solid fill would let a terminal keep something far smaller than a decoded
    surface and report a cost that says nothing about the real workload. A
    gradient still compresses well -- so the transmission stays quick -- while
    forcing a full decode to W*H*4, which is the quantity under test.
    """
    rows = []
    for y in range(height):
        value = (y * 255 // max(1, height - 1) + phase) % 256
        rows.append(b"\x00" + bytes((value, (value * 3) % 256, 255 - value, 255)) * width)

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(b"".join(rows), 1))
        + chunk(b"IEND", b"")
    )


def transmit(image_id, data):
    b64 = base64.b64encode(data).decode()
    out = []
    for i in range(0, len(b64), 4096):
        piece = b64[i : i + 4096]
        more = 1 if i + 4096 < len(b64) else 0
        control = f"a=t,f=100,t=d,q=2,i={image_id},m={more}" if i == 0 else f"m={more}"
        out.append(f"{ESC}_G{control};{piece}{ESC}\\")
    return "".join(out)


def place(row, col, control):
    return f"{ESC}[s{ESC}[{row};{col}H{ESC}_G{control}{ESC}\\{ESC}[u"


APPS = ("iTerm2", "kitty", "ghostty", "wezterm-gui")


def terminal_pid():
    """The terminal *application*, which is what holds decoded image data.

    The ancestry walk on its own is not enough on iTerm2 3.5 and later: a session
    runs under `iTermServer-<version>`, which lives in a directory literally named
    `iTerm2`, so a substring match lands on a 6 MB helper and reports that a
    hundred megapixels cost nothing. Match the executable's basename exactly, and
    when the walk only finds a helper, resolve the app by name the way
    `scripts/resident/rss.sh` does -- iTermServer is re-parented away from the GUI,
    so there is nothing further up the tree to find.
    """
    rows = subprocess.run(["ps", "-axo", "pid=,ppid=,comm="], capture_output=True, text=True).stdout
    tree, by_name = {}, {}
    for line in rows.splitlines():
        parts = line.split(None, 2)
        if len(parts) != 3:
            continue
        pid, ppid, comm = int(parts[0]), int(parts[1]), parts[2]
        tree[pid] = (ppid, comm)
        by_name.setdefault(os.path.basename(comm), []).append(pid)

    pid, helper = os.getpid(), False
    for _ in range(12):
        if pid not in tree:
            break
        ppid, comm = tree[pid]
        name = os.path.basename(comm)
        if name in APPS:
            return pid, name
        if name.startswith("iTermServer"):
            helper = True
        pid = ppid

    if helper or "iTerm" in os.environ.get("TERM_PROGRAM", ""):
        # Largest resident size wins: the sandboxed XPC workers share the name
        # prefix but not the image cache.
        candidates = by_name.get("iTerm2", [])
        if candidates:
            return max(candidates, key=rss_mb), "iTerm2"
    return None, None


def query_placement(tty, image_id, placement_id, timeout=2.0):
    """Place `image_id` with responses enabled and report what the terminal said.

    `q=0` is the Kitty protocol's "answer me": `OK` when the image is still held,
    `ENOENT` when it has been forgotten. Returns the raw status, or "no answer"
    for a terminal that does not reply -- which is not the same as OK and must
    not be reported as one.
    """
    import select, termios, tty as ttymod

    try:
        fd = os.open("/dev/tty", os.O_RDWR)
    except OSError:
        return "unavailable (no readable tty)"
    saved = termios.tcgetattr(fd)
    try:
        ttymod.setraw(fd)
        request = f"{ESC}[s{ESC}[1;1H{ESC}_Ga=p,q=0,C=1,i={image_id},p={placement_id},c=1,r=1,z=-3{ESC}\\{ESC}[u"
        os.write(fd, request.encode())
        deadline, buffer = time.time() + timeout, b""
        while time.time() < deadline:
            ready, _, _ = select.select([fd], [], [], deadline - time.time())
            if not ready:
                break
            buffer += os.read(fd, 4096)
            if b"\x1b\\" in buffer:
                break
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        os.close(fd)

    if not buffer:
        return "no answer (this terminal does not reply to q=0)"
    text = buffer.decode("latin-1")
    if ";" in text:
        return text.split(";", 1)[1].split("\x1b")[0].strip() or "empty"
    return repr(text[:60])


def rss_mb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout
    return int(out.strip()) / 1024 if out.strip() else float("nan")


def spawn():
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    out = os.path.join(repo, "tmp", "resident", "calibrate")
    os.makedirs(out, exist_ok=True)
    report, done = os.path.join(out, "report.txt"), os.path.join(out, "done")
    for path in (report, done):
        if os.path.exists(path):
            os.remove(path)
    runner = os.path.join(out, "run.command")
    with open(runner, "w") as handle:
        handle.write(
            "#!/bin/bash\n"
            f"cd {repo!r}\n"
            f"SLICES={SLICES} SLICE_W={SLICE_W} SLICE_H={SLICE_H} CEILING_MB={CEILING_MB} "
            f"python3 scripts/resident/rss-calibrate.py 2>{report!r}\n"
            f"touch {done!r}\n"
            "exit\n"
        )
    os.chmod(runner, 0o755)
    subprocess.run(["open", "-a", "iTerm", runner], check=True)
    print(f"launched a new iTerm2 window; report -> {report}", file=sys.stderr)
    for _ in range(600):
        if os.path.exists(done):
            break
        time.sleep(0.5)
    if os.path.exists(report):
        sys.stdout.write(open(report).read())
    else:
        print("no report was written", file=sys.stderr)
        return 1
    return 0


def main():
    if "--spawn" in sys.argv:
        return spawn()

    try:
        tty = open("/dev/tty", "w")
    except OSError as error:
        print(f"no controlling terminal ({error}); run this in a terminal, or pass --spawn", file=sys.stderr)
        return 2

    def emit(text):
        tty.write(text)
        tty.flush()

    def log(text):
        print(text, file=sys.stderr, flush=True)

    pid, comm = terminal_pid()
    if pid is None:
        print("could not find a terminal application in this process's ancestry", file=sys.stderr)
        return 2

    megapixels = SLICE_W * SLICE_H / 1e6
    emit(f"{ESC}[2J{ESC}[H")
    time.sleep(SETTLE)
    baseline = rss_mb(pid)
    log(f"terminal {comm} pid {pid}, baseline {baseline:.0f} MB")
    log(f"{SLICES} slices of {SLICE_W}x{SLICE_H} = {megapixels:.2f} Mpx each")
    log("")
    log(f"{'slices':>7} {'Mpx':>9} {'RSS MB':>9} {'delta':>9} {'B/px':>8}")

    samples = []
    stopped = None
    for index in range(SLICES):
        image_id = 0x4D000000 + index
        emit(transmit(image_id, gradient_png(SLICE_W, SLICE_H, index * 37)))
        # Place it once, then take the placement down and leave the data
        # resident -- the lifecycle a resident slice actually has. A terminal
        # that only decodes on first draw is measured honestly this way and
        # invisible otherwise.
        emit(place(1, 1, f"a=p,q=2,C=1,i={image_id},p={index + 1},c=20,r=10,z=-3"))
        time.sleep(0.4)
        emit(f"{ESC}_Ga=d,d=i,q=2,i={image_id},p={index + 1}{ESC}\\")
        time.sleep(SETTLE)

        now = rss_mb(pid)
        total_px = (index + 1) * SLICE_W * SLICE_H
        delta = now - baseline
        per_px = delta * 1024 * 1024 / total_px
        samples.append((index + 1, total_px, delta, per_px))
        log(f"{index + 1:>7} {total_px / 1e6:>9.2f} {now:>9.0f} {delta:>+9.0f} {per_px:>8.2f}")
        if now > CEILING_MB:
            stopped = now
            log(f"stopping: {now:.0f} MB is over the {CEILING_MB} MB ceiling")
            break

    # Is the FIRST slice still there after all the others arrived?
    #
    # The whole design rests on "uploaded once and kept": if the terminal
    # evicts on its own the reader gets a blank band from a placement that
    # reported nothing wrong. Asked with q=0 so the terminal answers -- OK if it
    # still holds the image, ENOENT if it does not. A terminal that answers
    # nothing at all leaves the question open, which is worth saying out loud
    # rather than reading as a pass.
    survived = query_placement(tty, 0x4D000000, 900)

    emit(f"{ESC}_Ga=d,d=A,q=2{ESC}\\")
    time.sleep(3)
    freed = rss_mb(pid)
    emit(f"{ESC}[2J{ESC}[H")
    time.sleep(3)
    cleared = rss_mb(pid)

    # Resident size not falling is not the same as memory not being freed: an
    # allocator is free to keep the pages, and macOS is free to leave them
    # resident until something else wants them. Reloading the same workload
    # separates the two -- if the second pass grows by as much as the first, the
    # first pass's pages were genuinely not reusable.
    reloaded = None
    if not stopped:
        for index in range(len(samples)):
            image_id = 0x4E000000 + index
            emit(transmit(image_id, gradient_png(SLICE_W, SLICE_H, index * 37 + 11)))
            emit(place(1, 1, f"a=p,q=2,C=1,i={image_id},p={index + 1},c=20,r=10,z=-3"))
            time.sleep(0.4)
            emit(f"{ESC}_Ga=d,d=i,q=2,i={image_id},p={index + 1}{ESC}\\")
            time.sleep(SETTLE)
        reloaded = rss_mb(pid)
        emit(f"{ESC}_Ga=d,d=A,q=2{ESC}\\")
        time.sleep(2)
        emit(f"{ESC}[2J{ESC}[H")

    log("")
    log(f"after deleting every image (a=d,d=A): {freed:>7.0f} MB (+{freed - baseline:.0f} over baseline)")
    log(f"after clearing the screen:            {cleared:>7.0f} MB (+{cleared - baseline:.0f} over baseline)")
    if reloaded is not None:
        growth = reloaded - cleared
        log(f"after loading the same workload again:{reloaded:>7.0f} MB (+{growth:.0f} over the cleared figure)")
        log(
            "  -> the first pass's pages were "
            + ("reused, so the terminal did give them back" if growth < samples[-1][2] * 0.5 else "NOT reused")
        )
    log(f"first slice still held after all {len(samples)} arrived: {survived}")
    log("")

    if not samples:
        log("VERDICT: no samples taken")
        return 1

    # The marginal cost, not the average: the first slice carries whatever the
    # terminal allocates once to be in the image business at all, and charging
    # that to every megapixel overstates a large document badly.
    if len(samples) > 1:
        first, last = samples[0], samples[-1]
        marginal = (last[2] - first[2]) * 1024 * 1024 / (last[1] - first[1])
    else:
        marginal = samples[0][3]
    # "Did it come back" cannot be answered by watching resident size fall.
    # An allocator is free to keep the pages and macOS is free to leave them
    # resident until something wants them, so a healthy terminal and a leaking
    # one look identical here. The reload does answer it: pages the terminal
    # genuinely released are pages the second pass does not have to be given
    # again. Reading the drop instead reported a leak on a terminal that had
    # freed everything.
    reused = None
    if reloaded is not None and samples[-1][2] > 0:
        reused = 1.0 - max(0.0, reloaded - cleared) / samples[-1][2]

    log(f"marginal cost:  {marginal:.2f} bytes per resident pixel (assumed: 4.00)")
    if reused is None:
        log("reuse:          not measured")
    else:
        log(f"reuse:          {reused * 100:.0f}% of the first pass's pages served the second")
    log("")

    if stopped is not None:
        log("VERDICT: INCONCLUSIVE -- the run hit its ceiling before finishing.")
        return 1
    # Below this the run measured scheduling noise rather than an image cache,
    # and every ratio derived from it is noise over noise. Saying so beats
    # reporting "0% returned" about growth that never happened.
    if samples[-1][2] < 32:
        log(f"VERDICT: INCONCLUSIVE -- only {samples[-1][2]:.0f} MB of growth across")
        log(f"         {samples[-1][1] / 1e6:.1f} Mpx. Raise SLICES or SLICE_W/SLICE_H.")
        return 1
    if not survived.startswith("OK"):
        log(f"VERDICT: DO NOT KEEP SLICES RESIDENT. The first slice reported '{survived}'")
        log(f"         after {len(samples)} arrived, so the terminal drops images on its own")
        log("         and a placement would draw a band of nothing.")
        return 1
    if reused is not None and reused < 0.80:
        log(f"VERDICT: DO NOT RAISE THE CEILING. Only {reused * 100:.0f}% of the first pass's pages")
        log("         served the second, so resident slices accumulate for the session.")
        return 1
    per_mb_px = 1024 * 1024 / marginal
    log(f"VERDICT: budget at {marginal:.1f} bytes per resident pixel, not 4.")
    log(f"         One MB holds {per_mb_px / 1e6:.3f} Mpx, i.e. {per_mb_px / SLICE_W:.0f} device rows at {SLICE_W} px wide.")
    for ceiling in (256, 512, 1024):
        mpx = ceiling * per_mb_px / 1e6
        log(
            f"         {ceiling:>5} MB -> {mpx:6.1f} Mpx -> {mpx * 1e6 / SLICE_W:7.0f} device rows"
            f" -> {mpx * 1e6 / SLICE_W / 2:7.0f} CSS px at device scale 2"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
