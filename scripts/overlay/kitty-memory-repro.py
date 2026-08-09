#!/usr/bin/env python3
"""Minimal reproduction: a Kitty placement that lands on cells already covered
by another placement costs WezTerm tens of megabytes, and the memory is never
returned.

Run it inside the terminal under test:

    python3 kitty-memory-repro.py            # overlay on top of the base image
    python3 kitty-memory-repro.py --clear    # identical, but aimed at bare rows

The only difference between the two modes is *where* the second placement is
put. Everything else -- the images, the number of placements, the rate, the
deletes -- is identical.

Observed on macOS 15, WezTerm 20240203-110809-5046fc22 and 20260805-104032:

    overlapping the base image   ~30-50 MB per frame, unbounded
    aimed at bare rows           ~1 MB per frame, plateaus

kitty 0.43 and Ghostty 1.2 hold flat in both modes.

Nothing is retained by WezTerm's own Kitty bookkeeping: with
WEZTERM_LOG=wezterm_term::terminalstate::kitty=trace the counters stay at
2 images / <=16 placements / constant used_memory for the whole run.
"""
import base64, os, subprocess, sys, time, zlib, struct

ESC = "\x1b"
# Escapes go to the terminal, commentary goes to stderr. Keeping them apart lets
# the run be logged to a file without redirecting the protocol into it too.
TTY = open("/dev/tty", "w")
def emit(text):
    TTY.write(text)
    TTY.flush()
def log(text):
    print(text, file=sys.stderr, flush=True)
FRAMES = int(os.environ.get("FRAMES", "40"))
CEILING_MB = int(os.environ.get("CEILING_MB", "1200"))
CLEAR_OF_BASE = "--clear" in sys.argv


def png(width, height, rgba):
    """A flat RGBA PNG, so the repro needs no image files."""
    raw = b"".join(b"\x00" + bytes(rgba) * width for _ in range(height))
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 1))
            + chunk(b"IEND", b""))


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
    """Position, place without moving the cursor, restore."""
    return f"{ESC}[s{ESC}[{row};{col}H{ESC}_G{control}{ESC}\\{ESC}[u"


def terminal_pid():
    rows = subprocess.run(["ps", "-axo", "pid=,ppid=,comm="], capture_output=True, text=True).stdout
    tree = {}
    for line in rows.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3:
            tree[int(parts[0])] = (int(parts[1]), parts[2])
    pid = os.getpid()
    for _ in range(12):
        if pid not in tree:
            break
        ppid, comm = tree[pid]
        if any(name in comm for name in ("wezterm-gui", "kitty", "ghostty", "iTerm2")):
            return pid
        pid = ppid
    return None


def rss_mb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout
    return int(out.strip()) / 1024 if out.strip() else float("nan")


cols, rows = os.get_terminal_size(TTY.fileno())
pid = terminal_pid()
if pid is None:
    sys.exit("could not find the terminal process")

# Two images, transmitted once. Neither is ever retransmitted.
BASE_ID, OVER_ID = 0x4A01, 0x5A01
BASE_ROWS = max(4, rows // 2)
width, height = (cols - 2) * 8, BASE_ROWS * 16
emit(f"{ESC}[2J{ESC}[H")
emit(transmit(BASE_ID, png(width, height, (64, 64, 64, 255))))
emit(transmit(OVER_ID, png(width, height, (220, 220, 220, 77))))
time.sleep(1.0)

# The base frame: one image scaled across the top half of the screen.
emit(place(2, 2, f"a=p,q=2,C=1,i={BASE_ID},p=1,c={cols - 2},r={BASE_ROWS},z=-2"))
time.sleep(1.0)

start = rss_mb(pid)
overlay_row = 2 if not CLEAR_OF_BASE else BASE_ROWS + 3
mode = "OVER the base image" if not CLEAR_OF_BASE else "clear of the base image"
log(f"terminal pid {pid}, {cols}x{rows}, overlay {mode}, start {start:.0f} MB")

placement_id = 100
live = []
for frame in range(FRAMES):
    payload = ""
    # One placement per frame, cropped out of the already-transmitted overlay
    # image, then the previous one deleted. Ids are fresh each frame; using a
    # single stable placement id instead makes no measurable difference.
    placement_id += 1
    payload += place(
        overlay_row, 2,
        f"a=p,q=2,C=1,i={OVER_ID},p={placement_id},"
        f"x=0,y={frame % 7},w={width},h={height // 3},z=-1",
    )
    for old in live:
        payload += f"{ESC}_Ga=d,d=i,q=2,i={OVER_ID},p={old}{ESC}\\"
    live = [placement_id]
    emit(payload)

    now = rss_mb(pid)
    log(f"frame {frame:3d}   {now:7.0f} MB   (+{now - start:.0f})")
    if now > CEILING_MB:
        log(f"stopping: {now:.0f} MB is over the {CEILING_MB} MB ceiling")
        break
    time.sleep(0.025)

# Optionally hold the final frame on screen, so a screenshot can be taken of it.
# If cells accumulated one translucent ImageCell per frame, the band would
# composite repeatedly and drift towards opaque; a single composite is flat.
HOLD = int(os.environ.get("HOLD_SECONDS", "0"))
if HOLD:
    log(f"holding the final frame for {HOLD}s")
    time.sleep(HOLD)

# Give everything back and see what comes down.
emit(f"{ESC}_Ga=d,d=A,q=2{ESC}\\")
time.sleep(2)
log(f"after deleting every placement and image: {rss_mb(pid):.0f} MB")
emit(f"{ESC}[2J{ESC}[H")
time.sleep(3)
log(f"after clearing the screen:                {rss_mb(pid):.0f} MB   (started at {start:.0f})")
