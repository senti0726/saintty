#!/usr/bin/env python3
"""Score a fast-scroll run: how smooth was what actually reached the screen?

    python3 tools/scroll-harness/fast/analyse.py <run-dir> [scenario ...] [--plot]

WHAT IS MEASURED. Ghostty's --scroll-trace logs every drawn frame with the
model position (rows scrolled) and the animation offset, so the content's
drawn position is `model_rows * cell_h - off_px`. The display refreshes at a
fixed rate whether or not Ghostty drew, so each drawn frame is one refresh
and a gap of n refreshes between frames is n-1 refreshes of the old picture --
a stall on screen. See `resample`.

WHAT "SMOOTH" MEANS HERE. An Electron app (Obsidian, VS Code) moves content by
a steady amount every refresh while input is steady: the per-refresh step
changes gradually. So every refresh during motion is compared with the local
speed (a +-4 refresh median, ~130 ms at 60 Hz) and flagged when it:

  stall     shows no motion while the local speed is >= 1 px/refresh
  jump      moves more than 2x the local speed + 1/4 row
  reverse   moves against the direction of travel
  jerk      differs from the local speed by more than half of it + 2 px

`smooth%` is the share of motion refreshes with none of these.

WHY IT HAPPENED. For each flagged refresh the report says what the model did
there: how many rows the application delivered in that frame (a big batch is
nvim/tmux coalescing), how long since the previous delivery (a gap is the
application falling behind), and whether the animation offset was pinned at
its cap (excess distance snapped instead of slid).
"""

import re
import statistics
import sys
from pathlib import Path

REFRESH_HZ = 60.0
TICK_US = 1e6 / REFRESH_HZ
# The lag cap the build under test uses (scroll_anim.zig): 2 before ghost rows,
# `ghost_lag_rows` = 12 after. Only feeds the "pinned" column. --lag=N.
MAX_LAG_ROWS = next((int(a.split("=")[1]) for a in sys.argv if a.startswith("--lag=")), 12)
# --nocols scores a new trace the way an old one (no column fields) has to be
# scored, for a fair before/after against a build that did not log them.
IGNORE_COLS = "--nocols" in sys.argv

TRACE = re.compile(r"scrolltrace t_us=-?\d+ model_rows=(-?\d+) off_px=(-?[\d.]+) top=(-?[\d.]+) bot=(-?[\d.]+) cell_h=(\d+) mono_us=(\d+)(?: left=(-?[\d.]+) right=(-?[\d.]+))?")
EVENT = re.compile(r"scroll event: rows=(-?\d+) .*src=(\w+) cell_h=\d+ mono_us=(\d+)")
REPAINT = re.compile(r"repaintscroll shift=(-?\d+) .* mono_us=(\d+)")
SINPUT = re.compile(r"scrollinput mono_us=(\d+) yoff=(-?[\d.]+) precision=(\w+) momentum=(\w+)")
KINPUT = re.compile(r"keyinput mono_us=(\d+) key=(\w+) action=(\w+)")


COLS = re.compile(r"cols=(\d+)\.\.(\d+) of \d+x(\d+)")


def load(run: Path, name: str):
    g = (run / f"{name}.ghostty.log").read_text(errors="replace")
    # The content's model position has to count BOTH producers: nvim's own
    # scroll commands (`scroll event`, which is all `model_rows` counts) and
    # the scrolls the detector recovered from repaints -- holding j in nvim
    # scrolled 33 times with zero scroll events, every one a repaint. Only a
    # detection spanning most of the width moves the text; the number column
    # sliding on its own is not the page moving. Walked in log order, which is
    # the order the renderer did things in, so each frame line sees exactly
    # the model it was drawn from.
    frames, model = [], 0
    cm = re.search(r" of \d+x(\d+)", g)
    cols_total = int(cm[1]) if cm else 210
    for line in g.splitlines():
        m = TRACE.search(line)
        if m:
            off = float(m[2])
            # The offset only displaces the text when the animated columns
            # cover it; a slide of the number column alone leaves the page
            # where the model put it. Older traces carry no columns.
            if m[7] is not None and not IGNORE_COLS and (float(m[8]) - float(m[7]) + 1) < 0.5 * cols_total:
                off = 0.0
            frames.append((int(m[6]), model, off, int(m[5])))
            continue
        m = EVENT.search(line)
        if m:
            model += int(m[1])
            continue
        m = REPAINT.search(line)
        if m and "repair" not in line:
            c = COLS.search(line)
            if c and int(c[2]) - int(c[1]) + 1 >= 0.5 * int(c[3]):
                model += int(m[1])
    events = [(int(m[3]), int(m[1]), m[2]) for m in EVENT.finditer(g)]
    repaints = [(int(m[2]), int(m[1])) for m in REPAINT.finditer(g)]
    sin = [(int(m[1]), float(m[2]), m[3], m[4]) for m in SINPUT.finditer(g)]
    kin = [(int(m[1]), m[2], m[3]) for m in KINPUT.finditer(g)]
    inp = []
    for line in (run / f"{name}.input.log").read_text().splitlines():
        t, k, v = line.split()
        inp.append((int(t), k, float(v)))
    nv = []
    p = run / f"{name}.nvim.log"
    if p.exists():
        for line in p.read_text().splitlines():
            a = line.split()
            if len(a) == 4:
                nv.append(tuple(int(x) for x in a))
    return frames, events, repaints, sin, kin, inp, nv


def resample(frames, t_from, t_to):
    """Drawn position at every display refresh between t_from and t_to (us).

    Each drawn frame is one refresh: the renderer is vsync-paced, and its
    frames land within a millisecond or so of the refresh either side, so
    sampling on a fixed 60 Hz grid instead reads that jitter as a refresh with
    no new frame followed by one with two -- a stall and a jump that never
    reached the screen (measured: every "stall" on a steady wheel spin, with
    no frame interval over 18.2 ms). A gap of n refreshes between frames IS a
    stall on screen: the old picture stayed up for n-1 of them."""
    sel = [f for f in frames if t_from <= f[0] <= t_to]
    out = []
    for i, cur in enumerate(sel):
        t, rows, off, ch = cur
        p = rows * ch - off
        if i:
            n = max(1, round((t - sel[i - 1][0]) / TICK_US))
            prev = out[-1][1]
            for k in range(1, n):
                out.append((sel[i - 1][0] + k * TICK_US, prev, sel[i - 1]))
        out.append((t, p, cur))
    return out


def analyse(run: Path, name: str, plot=False):
    frames, events, repaints, sin, kin, inp, nv = load(run, name)
    if not frames:
        return {"name": name, "error": "no frames traced"}
    frames.sort()
    cell_h = frames[-1][3]
    sent = [e for e in inp if e[1] not in ("start", "end")]
    t_in0 = sent[0][0] if sent else inp[0][0]
    t_in1 = sent[-1][0] if sent else inp[-1][0]

    # Motion span: first to last change of drawn position.
    pos = [(t, r * ch - o) for t, r, o, ch in frames]
    moving = [pos[i][0] for i in range(1, len(pos)) if abs(pos[i][1] - pos[i - 1][1]) > 0.01]
    if not moving:
        return {"name": name, "error": "nothing moved", "inputs": len(sent), "ghostty_inputs": len(sin) + len(kin)}
    t_m0, t_m1 = moving[0], moving[-1]
    ticks = resample(frames, t_m0 - TICK_US, t_m1 + TICK_US)
    steps = [(ticks[i][0], ticks[i][1] - ticks[i - 1][1], ticks[i][2]) for i in range(1, len(ticks))]
    direction = 1 if ticks[-1][1] >= ticks[0][1] else -1

    # Model deliveries (frames where model_rows changed): size and spacing.
    deliveries = []
    for i in range(1, len(frames)):
        d = frames[i][1] - frames[i - 1][1]
        if d:
            deliveries.append((frames[i][0], d))

    flags = []
    vals = [s for _, s, _ in steps]
    for i, (t, s, fr) in enumerate(steps):
        win = vals[max(0, i - 4): i + 5]
        ref = statistics.median(win)
        kinds = []
        if abs(ref) >= 1 and abs(s) < 0.05:
            kinds.append("stall")
        if abs(s) > 2 * abs(ref) + cell_h / 4:
            kinds.append("jump")
        if s * direction < -1:
            kinds.append("reverse")
        if not kinds and abs(s - ref) > 0.5 * abs(ref) + 2:
            kinds.append("jerk")
        if kinds:
            # what the model did in the frame that produced this tick
            j = max(k for k in range(len(deliveries) + 1) if k == 0 or deliveries[k - 1][0] <= t) if deliveries else 0
            last = deliveries[j - 1] if j else None
            gap = (t - deliveries[j - 2][0]) / 1000 if j >= 2 else None
            pinned = abs(fr[2]) >= MAX_LAG_ROWS * cell_h - 0.5
            flags.append((t, kinds, s, ref, last[1] if last else 0, gap, pinned))

    n = len(steps)
    kinds_count = {}
    for f in flags:
        for k in f[1]:
            kinds_count[k] = kinds_count.get(k, 0) + 1
    speeds = [abs(v) for v in vals]
    batch = [abs(d) for _, d in deliveries]
    gaps = [(deliveries[i][0] - deliveries[i - 1][0]) / 1000 for i in range(1, len(deliveries))]
    drawn = [frames[i][0] - frames[i - 1][0] for i in range(1, len(frames)) if t_m0 <= frames[i][0] <= t_m1]

    res = {
        "name": name,
        "inputs": len(sent),
        "ghostty_inputs": len(sin) + len(kin),
        "input_span_ms": (t_in1 - t_in0) / 1000,
        "motion_ms": (t_m1 - t_m0) / 1000,
        "latency_ms": (t_m0 - t_in0) / 1000,
        "tail_ms": (t_m1 - t_in1) / 1000,
        "rows": abs(frames[-1][1] - frames[0][1]),
        "refreshes": n,
        "smooth_pct": 100 * (1 - len(flags) / n) if n else 0,
        "kinds": kinds_count,
        "peak_px_per_refresh": max(speeds) if speeds else 0,
        "median_px_per_refresh": statistics.median(speeds) if speeds else 0,
        "batch_rows": (statistics.median(batch), max(batch)) if batch else (0, 0),
        "delivery_gap_ms": (statistics.median(gaps), max(gaps)) if gaps else (0, 0),
        "drawn_frame_ms": (statistics.median(drawn) / 1000, max(drawn) / 1000) if drawn else (0, 0),
        "pinned_refreshes": sum(1 for _, _, fr in steps if abs(fr[2]) >= MAX_LAG_ROWS * cell_h - 0.5),
        "nvim_scrolls": len(nv),
        "repaint_detections": len(repaints),
        "event_sources": sorted({src for _, _, src in events}),
        "worst": sorted(flags, key=lambda f: -abs(f[2] - f[3]))[:6],
        "t0": t_m0,
        "cell_h": cell_h,
    }
    if plot:
        _plot(run, name, ticks, deliveries, sent, flags, t_m0)
    return res


def _plot(run, name, ticks, deliveries, sent, flags, t0):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig, (a1, a2) = plt.subplots(2, 1, figsize=(11, 6), sharex=True)
    xs = [(t - t0) / 1000 for t, _, _ in ticks]
    a1.plot(xs, [p for _, p, _ in ticks], lw=1, label="drawn position (px)")
    a1.plot([(t - t0) / 1000 for t, _ in deliveries], [0] * len(deliveries), "|", ms=6, label="app delivered rows")
    a1.legend(loc="upper left")
    st = [ticks[i][1] - ticks[i - 1][1] for i in range(1, len(ticks))]
    a2.plot(xs[1:], st, lw=1, label="px per refresh")
    a2.plot([(f[0] - t0) / 1000 for f in flags], [f[2] for f in flags], "rx", ms=4, label="flagged")
    a2.plot([(t - t0) / 1000 for t, _, _ in sent], [0] * len(sent), "k|", ms=4, label="input sent")
    a2.set_xlabel("ms from first motion")
    a2.legend(loc="upper left")
    fig.suptitle(name)
    fig.tight_layout()
    fig.savefig(run / f"{name}.png", dpi=90)
    plt.close(fig)


def report(results):
    out = []
    hdr = f"{'scenario':12} {'smooth%':>7} {'stall':>5} {'jump':>4} {'jerk':>4} {'rev':>3}  {'rows':>4} {'lat ms':>6} {'tail ms':>7} {'px/ref med/peak':>15} {'batch med/max':>13} {'gap ms med/max':>14} {'pinned':>6}"
    out.append(hdr)
    for r in results:
        if "error" in r:
            out.append(f"{r['name']:12} ERROR: {r['error']}  (sent {r.get('inputs')}, ghostty saw {r.get('ghostty_inputs')})")
            continue
        k = r["kinds"]
        out.append(
            f"{r['name']:12} {r['smooth_pct']:7.1f} {k.get('stall', 0):5} {k.get('jump', 0):4} {k.get('jerk', 0):4} {k.get('reverse', 0):3}  "
            f"{r['rows']:4} {r['latency_ms']:6.0f} {r['tail_ms']:7.0f} "
            f"{r['median_px_per_refresh']:6.1f}/{r['peak_px_per_refresh']:6.1f}  "
            f"{r['batch_rows'][0]:5.0f}/{r['batch_rows'][1]:<5.0f}  {r['delivery_gap_ms'][0]:6.0f}/{r['delivery_gap_ms'][1]:<6.0f} {r['pinned_refreshes']:6}"
        )
    out.append("")
    for r in results:
        if "error" in r or not r["worst"]:
            continue
        out.append(f"{r['name']}: worst moments (t from first motion; batch = rows the app delivered in that frame)")
        for t, kinds, s, ref, batch, gap, pinned in r["worst"]:
            g = f"{gap:.0f}ms after previous delivery" if gap is not None else ""
            out.append(
                f"   {(t - r['t0']) / 1000:7.0f}ms {'+'.join(kinds):13} step {s:6.1f}px vs local {ref:5.1f}px  batch {batch:+d} rows  {g}{'  offset pinned at cap' if pinned else ''}"
            )
    return "\n".join(out)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    run = Path(args[0])
    names = args[1:] or sorted(p.name[: -len(".input.log")] for p in run.glob("*.input.log"))
    results = [analyse(run, n, plot="--plot" in sys.argv) for n in names]
    text = report(results)
    print(text)
    (run / "report.txt").write_text(text + "\n")


if __name__ == "__main__":
    main()
