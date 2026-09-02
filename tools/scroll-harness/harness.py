#!/usr/bin/env python3
"""Run a scroll pattern through the real renderer and score how it looks.

Usage:  python3 tools/scroll-harness/harness.py [pattern ...] [--no-anim]

Launches the fork with `--scroll-trace`, runs tools/scroll-harness/emit.py
inside it, then reconstructs where content was drawn on every frame and
reports the things eyes are bad at judging.

Requires a debug build (`zig build`), because the trace rides std.log.debug.
"""

import os
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GHOSTTY = REPO / "zig-out" / "bin" / "ghostty"
BINARY = GHOSTTY
EMIT = Path(__file__).resolve().parent / "emit.py"

TRACE = re.compile(
    r"scrolltrace t_us=(-?\d+) model_rows=(-?\d+) off_px=(-?[\d.]+) "
    r"inflight=-?\d+ pending=-?[\d.]+ "
    r"top=(-?[\d.]+) bot=(-?[\d.]+) cell_h=(\d+)"
)
EVENT = re.compile(
    r"scroll event: rows=(-?\d+) start=-?\d+ region=(-?\d+)\.\.(-?\d+) "
    r"rows_total=\d+ src=(\w+)"
)


class Frame:
    __slots__ = ("t", "rows", "off", "cell_h", "drawn")

    def __init__(self, t, rows, off, cell_h):
        self.t = t / 1000.0  # ms
        self.rows = rows
        self.off = off
        self.cell_h = cell_h
        # Where the content actually sat. The model puts it at
        # -(rows * cell_h); the shader draws it `off` from there.
        self.drawn = -(rows * cell_h) + off


def run(pattern: str, animate: bool, duration_ms: int) -> list[str]:
    log = REPO / f".scroll-trace-{pattern}.log"
    if log.exists():
        log.unlink()
    cmd = [
        str(BINARY),
        "--gtk-single-instance=false",
        "--scroll-trace=true",
        f"--scroll-animation={'true' if animate else 'false'}",
        f"--scroll-animation-duration={duration_ms}",
        "--mouse-scroll-momentum=false",
        "-e",
        sys.executable,
        str(EMIT),
        pattern,
    ]
    with log.open("wb") as fh:
        proc = subprocess.Popen(cmd, stdout=fh, stderr=subprocess.STDOUT)
        # emit.py runs for its pattern plus ~3s of setup and settle.
        time.sleep(24)
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
    return log.read_text(errors="replace").splitlines()


def analyze(lines: list[str], label: str) -> None:
    frames = []
    for ln in lines:
        m = TRACE.search(ln)
        if m:
            frames.append(
                Frame(int(m.group(1)), int(m.group(2)), float(m.group(3)), int(m.group(6)))
            )
    events = [EVENT.search(ln) for ln in lines]
    events = [e for e in events if e]

    print(f"\n=== {label} ===")
    if not frames:
        print("  NO FRAMES TRACED -- is this a debug build with --scroll-trace?")
        return

    regions = {}
    for e in events:
        regions[(int(e.group(2)), int(e.group(3)), e.group(4))] = (
            regions.get((int(e.group(2)), int(e.group(3)), e.group(4)), 0) + 1
        )
    print(f"  frames traced        : {len(frames)}")
    print(f"  scroll events        : {len(events)}")
    for (t, b, src), n in sorted(regions.items(), key=lambda kv: -kv[1])[:6]:
        print(f"      region {t}..{b} {src}: {n}")

    # Trim to the moving part: first to last frame where the model changed.
    moving = [i for i in range(1, len(frames)) if frames[i].rows != frames[i - 1].rows]
    if not moving:
        print("  model never scrolled")
        return
    lo, hi = moving[0] - 1, min(len(frames) - 1, moving[-1] + 90)
    seg = frames[lo:hi]

    deltas = [(seg[i].drawn - seg[i - 1].drawn, seg[i].t - seg[i - 1].t) for i in range(1, len(seg))]
    moved = [d for d, _ in deltas if abs(d) > 0.01]
    if not moved:
        print("  content never moved on screen")
        return

    # A one-directional scroll must never move the other way on screen.
    fwd = sum(1 for d in moved if d > 0)
    rev = sum(1 for d in moved if d < 0)
    minority = min(fwd, rev)
    print(f"  drawn-motion frames  : {len(moved)}  (forward {fwd}, backward {rev})")
    print(f"  REVERSALS            : {minority} frames ({100.0 * minority / len(moved):.1f}%)")

    # Lag: how far the drawn position trails the model.
    lags = [abs(f.off) / f.cell_h for f in seg]
    print(f"  lag behind model     : max {max(lags):.2f} rows, mean {sum(lags) / len(lags):.2f}")

    # Smoothness: per-frame step sizes. Chrome-like scrolling has steps that
    # vary smoothly; a jump of a whole row is a visible tick.
    steps = [abs(d) for d, _ in deltas if abs(d) > 0.01]
    steps.sort()
    cell_h = seg[0].cell_h
    p50 = steps[len(steps) // 2]
    p95 = steps[int(len(steps) * 0.95)]
    print(f"  step size            : p50 {p50:.1f}px ({p50 / cell_h:.2f} rows), "
          f"p95 {p95:.1f}px ({p95 / cell_h:.2f} rows), max {steps[-1]:.1f}px")
    whole = sum(1 for s in steps if s >= cell_h * 0.9)
    print(f"  full-row jumps       : {whole} ({100.0 * whole / len(steps):.1f}% of moving frames)")

    # Stalls: model moved but the screen did not.
    stalls = sum(
        1
        for i in range(1, len(seg))
        if seg[i].rows != seg[i - 1].rows and abs(seg[i].drawn - seg[i - 1].drawn) < 0.01
    )
    print(f"  stalled scroll frames: {stalls}")

    gaps = [dt for _, dt in deltas if dt > 0]
    if gaps:
        gaps.sort()
        print(f"  frame interval       : p50 {gaps[len(gaps) // 2]:.1f}ms, "
              f"p95 {gaps[int(len(gaps) * 0.95)]:.1f}ms")


def main() -> int:
    global BINARY
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    for a in sys.argv[1:]:
        if a.startswith("--bin="):
            BINARY = Path(a.split("=", 1)[1])
    animate = "--no-anim" not in sys.argv
    duration = 80
    for a in sys.argv[1:]:
        if a.startswith("--duration="):
            duration = int(a.split("=", 1)[1])
    patterns = args or ["slow", "medium", "fast"]
    if not BINARY.exists():
        print(f"no binary at {BINARY}; run `zig build`", file=sys.stderr)
        return 1
    for p in patterns:
        lines = run(p, animate, duration)
        analyze(lines, f"{p}  [{BINARY.parent.parent.name}] (animation={'on' if animate else 'off'}, {duration}ms)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
