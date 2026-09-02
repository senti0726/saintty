#!/usr/bin/env python3
"""Drive the scroll input path end to end and check what was drawn.

The other harness (harness.py) drives *applications*, via tmux commands. That
leaves the entire input path untested -- the precision multiplier, momentum,
the rounding that decides when to emit a scroll, the sub-row offset -- which is
where every scrolling bug so far has actually lived.

This feeds recorded touchpad samples through `scroll-input-script`, which
replays them through the same handler a real touchpad reaches, then reads the
trace back and checks the drawn position for the things that get reported by
eye: content jumping backwards, the picture stalling, and rows moving that an
application asked to keep still.

Usage:  python3 tools/scroll-harness/input.py [gesture ...] [--bin=PATH]
"""

import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BINARY = REPO / "zig-out-release" / "bin" / "ghostty"

EMIT = re.compile(
    r"scrollemit yoff=(-?[\d.]+) adj=(-?[\d.]+) poff=(-?[\d.]+) raw=(-?[\d.]+) "
    r"rows=(-?\d+) dir=(-?\d+) pending=(-?[\d.]+) cell=(\d+)"
)
TRACE = re.compile(
    r"scrolltrace t_us=(-?\d+) model_rows=(-?\d+) off_px=(-?[\d.]+) "
    r"inflight=(-?\d+) pending=(-?[\d.]+) top=(-?[\d.]+) bot=(-?[\d.]+) cell_h=(\d+)"
)
EVENT = re.compile(r"scroll event: .*region=(-?\d+)\.\.(-?\d+) rows_total=(\d+)")


def gesture(name: str) -> list[str]:
    """Samples in GTK precision-device pixels, one per 8ms tick."""
    # Wait for the shell to finish printing and for the harness to put tmux
    # into copy-mode. Replaying before the application is ready to scroll
    # measures the startup output instead of the gesture.
    out: list[str] = ["@900"]
    if name == "slow":
        # A steady, deliberate drag -- the case the user calls "very small
        # scroll" and where quantisation is most visible.
        out += [f"{-1.2:.2f}"] * 220
    elif name == "medium":
        out += [f"{-4.0:.2f}"] * 120
    elif name == "flick":
        # A fast flick with a decaying tail, magnitudes taken from a real
        # captured log (yoff 11.7 decaying to 2.7).
        v = 14.0
        while v > 0.4:
            out.append(f"{-v:.2f}")
            v *= 0.94
    elif name == "jitter":
        # Steady movement carrying the small opposite-sign samples a real
        # touchpad reports. This is what produced reverse scrolls.
        for i in range(240):
            out.append(f"{1.1:.2f}" if i % 9 == 3 else f"{-3.0:.2f}")
    elif name == "reverse":
        out += [f"{-3.0:.2f}"] * 90 + ["@25"] + [f"{3.0:.2f}"] * 90
    else:
        raise SystemExit(f"unknown gesture {name}")
    out.append("@120")  # let everything settle inside the trace
    return out


def run(name: str, extra: list[str]) -> list[str]:
    script = REPO / f".scroll-input-{name}.txt"
    script.write_text("\n".join(gesture(name)) + "\n")
    log = REPO / f".scroll-input-{name}.log"
    if log.exists():
        log.unlink()

    cmd = [
        str(BINARY),
        "--gtk-single-instance=false",
        "--scroll-trace=true",
        # Pin the sensitivity. Otherwise the user's own config decides how far
        # a recorded sample scrolls and the test measures their settings
        # rather than the code.
        "--mouse-scroll-multiplier=precision:1,discrete:3",
        f"--scroll-input-script={script}",
        *extra,
        "-e",
        "bash",
        "-lc",
        f"tmux -L inputtest kill-server 2>/dev/null; "
        f"tmux -L inputtest -f {Path(__file__).resolve().parent / 'tmux.conf'} "
        f"new -A -s i 'seq 1 5000; sleep 90'",
    ]
    with log.open("wb") as fh:
        proc = subprocess.Popen(cmd, stdout=fh, stderr=subprocess.STDOUT)
        time.sleep(5)
        # Put tmux in copy-mode so wheel events scroll history, as they would
        # under the user's bindings. This must happen before the replay's
        # lead-in expires.
        subprocess.run(
            ["tmux", "-L", "inputtest", "copy-mode", "-t", "i"],
            capture_output=True,
        )
        time.sleep(22)
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
    subprocess.run(["tmux", "-L", "inputtest", "kill-server"], capture_output=True)
    return log.read_text(errors="replace").splitlines()


def analyze(lines: list[str], label: str) -> bool:
    emits = [EMIT.search(l) for l in lines]
    emits = [m for m in emits if m]
    frames = [TRACE.search(l) for l in lines]
    frames = [m for m in frames if m]
    events = [EVENT.search(l) for l in lines]
    events = [m for m in events if m]

    print(f"\n=== {label} ===")
    if not emits:
        print("  NO SCROLL INPUT REPLAYED -- is scroll-input-script wired up?")
        return False
    print(f"  samples delivered   : {len(emits)}")

    rows = [int(m.group(5)) for m in emits]
    fwd = sum(1 for r in rows if r > 0)
    rev = sum(1 for r in rows if r < 0)
    print(f"  scrolls emitted     : {fwd + rev}  (forward {fwd}, backward {rev})")

    regions = {}
    for m in events:
        regions[(int(m.group(1)), int(m.group(2)))] = (
            regions.get((int(m.group(1)), int(m.group(2))), 0) + 1
        )
    if regions:
        print(f"  regions seen        : {dict(list(regions.items())[:4])}")

    ok = True
    if fwd and rev:
        print(f"  FAIL: {min(fwd, rev)} scrolls emitted against the gesture")
        ok = False

    if not frames:
        print("  no frames traced")
        return ok

    cell = int(frames[0].group(8))
    # The replay has a lead-in; ignore everything before the first emitted
    # scroll so startup output is not mistaken for the gesture.
    first_us = None
    for l in lines:
        m = EMIT.search(l)
        if m and int(m.group(5)) != 0:
            break
    for i, l in enumerate(lines):
        if EMIT.search(l):
            t = TRACE.search(lines[max(0, i - 1)])
            first_us = int(t.group(1)) if t else None
            break
    sel = [
        m for m in frames
        if first_us is None or int(m.group(1)) >= first_us
    ]
    if len(sel) > 10:
        frames = sel
    pos = [
        -(int(m.group(2)) * cell) + float(m.group(3))
        for m in frames
    ]
    deltas = [b - a for a, b in zip(pos, pos[1:])]
    moved = [d for d in deltas if abs(d) > 0.01]
    if moved:
        f = sum(1 for d in moved if d > 0)
        r = sum(1 for d in moved if d < 0)
        back = min(f, r)
        print(f"  drawn motion frames : {len(moved)} (forward {f}, backward {r})")
        pct = 100.0 * back / len(moved)
        print(f"  drawn REVERSALS     : {back} ({pct:.1f}%)")
        if pct > 2.0:
            print("  FAIL: the picture moves against the gesture")
            ok = False
        steps = sorted(abs(d) for d in moved)
        p50 = steps[len(steps) // 2]
        print(f"  step p50            : {p50:.1f}px ({p50 / cell:.2f} rows)")
        whole = sum(1 for s in steps if s >= cell * 0.9)
        print(f"  full-row jumps      : {whole} ({100.0 * whole / len(steps):.0f}%)")
    return ok


def main() -> int:
    global BINARY
    names = [a for a in sys.argv[1:] if not a.startswith("--")]
    extra = []
    for a in sys.argv[1:]:
        if a.startswith("--bin="):
            BINARY = Path(a.split("=", 1)[1])
        elif a.startswith("--"):
            extra.append(a)
    if not extra:
        extra = ["--scroll-pixel-perfect=true", "--scroll-pixel-perfect-snap=false"]
    if not BINARY.exists():
        print(f"no binary at {BINARY}", file=sys.stderr)
        return 1
    allok = True
    for n in names or ["slow", "jitter", "flick"]:
        allok &= analyze(run(n, extra), f"{n}  {' '.join(extra)}")
    print("\nRESULT:", "ok" if allok else "FAILURES")
    return 0 if allok else 1


if __name__ == "__main__":
    sys.exit(main())
