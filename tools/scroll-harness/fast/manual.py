#!/usr/bin/env python3
"""Record a REAL mouse's wheel against the harness window, for gestures a
virtual device can't stand in for -- the MX Anywhere 3S's free-spin flick,
whose momentum is the wheel's own and not a curve we chose.

    python3 tools/scroll-harness/fast/manual.py [--bin=PATH] [--out=DIR]
        [--device=/dev/input/eventN] [--secs=45] [--wait=300] [--line=900]

Opens the same window as run.py (fullscreen, user's tmux + nvim on CSAPP
ch. 2), then waits up to --wait for the first wheel report and for --secs records the device's hi-res wheel with CLOCK_MONOTONIC
stamps through `sudo` (event nodes are root:input). Each burst of wheel
separated by 1.5 s of stillness is saved as its own scenario, `flick1`,
`flick2`, ..., in run.py's layout, so analyse.py scores them as is.

The person flicking parks the pointer themselves: Ghostty drops wheel events
until it has seen the pointer move over the window.
"""

import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run  # noqa: E402

# Runs as root: reads the event node, prints "mono_us hires_value" per wheel
# report. EVIOCSCLOCKID switches the node's stamps to CLOCK_MONOTONIC, the
# clock Ghostty's and nvim's logs use.
READER = r"""
import fcntl, struct, sys, time, select
fd = open(sys.argv[1], "rb", buffering=0)
fcntl.ioctl(fd, 0x400445a0, struct.pack("i", 1))  # EVIOCSCLOCKID, MONOTONIC
# Wait up to argv[3] s for the first wheel report, then record argv[2] s.
end = time.monotonic() + float(sys.argv[3])
started = False
fmt = "llHHi"; n = struct.calcsize(fmt)
while time.monotonic() < end:
    if not select.select([fd], [], [], 0.2)[0]:
        continue
    s, us, typ, code, val = struct.unpack(fmt, fd.read(n))
    if typ == 2 and code == 11:  # EV_REL REL_WHEEL_HI_RES
        if not started:
            started, end = True, time.monotonic() + float(sys.argv[2])
        print(s * 1000000 + us, val, flush=True)
"""


def find_device() -> str:
    for p in Path("/sys/class/input").glob("event*"):
        name = (p / "device/name").read_text().strip()
        if "MX Anywhere" in name:
            return f"/dev/input/{p.name}"
    raise SystemExit("no MX Anywhere input device; pass --device=")


def main():
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    binary = Path(opts.get("bin", Path.home() / "tools/ghostty/bin/ghostty"))
    out = Path(opts.get("out", Path.home() / "playground/fast-scroll" / time.strftime("%Y%m%d-%H%M%S-manual")))
    dev = opts.get("device") or find_device()
    secs = float(opts.get("secs", 45))
    wait = float(opts.get("wait", 300))
    line = int(opts.get("line", 900))

    rig = run.Rig(binary, out)
    try:
        rig.start()
        rig.reset(line)
        g0 = rig.log.stat().st_size
        n0 = rig.nvlog.stat().st_size if rig.nvlog.exists() else 0
        subprocess.run(["notify-send", "-u", "critical", "-a", "Claude scroll test", "Flick now",
                        f"Pointer over the text, then free-spin flicks: down, wait for it to stop, up. "
                        f"Repeat a few times. Recording {int(secs)} s from your first flick."])
        print(f"waiting up to {wait:.0f} s for the wheel on {dev}, then {secs:.0f} s", flush=True)
        r = subprocess.run(["sudo", "python3", "-I", "-c", READER, dev, str(secs), str(wait)],
                           capture_output=True, text=True)
        time.sleep(1.0)
        rig.logf.flush()
        subprocess.run(["notify-send", "-a", "Claude scroll test", "Done: stop flicking",
                        "Screen is yours again."])
    finally:
        rig.stop()

    wheel = [tuple(int(x) for x in l.split()) for l in r.stdout.splitlines() if l.strip()]
    if not wheel:
        raise SystemExit(f"no wheel events recorded ({r.stderr.strip()})")
    bursts, cur = [], [wheel[0]]
    for ev in wheel[1:]:
        if ev[0] - cur[-1][0] > 1_500_000:
            bursts.append(cur)
            cur = []
        cur.append(ev)
    bursts.append(cur)

    glog = run.slice_file(rig.log, g0).splitlines(keepends=True)
    nlog = run.slice_file(rig.nvlog, n0).splitlines(keepends=True) if rig.nvlog.exists() else []

    def stamp(line, key):
        i = line.find(key)
        if i < 0:
            return None
        j = i + len(key)
        k = j
        while k < len(line) and line[k].isdigit():
            k += 1
        return int(line[j:k]) if k > j else None

    for i, b in enumerate(bursts, 1):
        t0, t1 = b[0][0] - 200_000, b[-1][0] + 1_500_000
        name = f"flick{i}"
        g = [l for l in glog if (t := stamp(l, "mono_us=")) is not None and t0 <= t <= t1]
        nv = [l for l in nlog if t0 <= int(l.split()[0]) <= t1]
        (out / f"{name}.ghostty.log").write_text("".join(g))
        (out / f"{name}.nvim.log").write_text("".join(nv))
        # run.py's convention: +1/8 per 1/8-notch, positive = content moves
        # down, which is a negative wheel value.
        inp = [f"{t0} start 0.0\n"] + [f"{t} wheel {-v / 120}\n" for t, v in b] + [f"{b[-1][0]} end 0.0\n"]
        (out / f"{name}.input.log").write_text("".join(inp))
        notches = sum(-v for _, v in b) / 120
        dur = (b[-1][0] - b[0][0]) / 1e6
        peak = max_rate(b)
        print(f"{name}: {len(b)} reports, {notches:+.1f} notches over {dur:.2f} s, peak {peak:.0f} notches/s")
    print(out)


def max_rate(b, win_us=100_000):
    best, j, acc = 0.0, 0, 0
    for i, (t, v) in enumerate(b):
        acc += abs(v)
        while b[j][0] < t - win_us:
            acc -= abs(b[j][1])
            j += 1
        best = max(best, acc / 120 / (win_us / 1e6))
    return best


if __name__ == "__main__":
    main()
