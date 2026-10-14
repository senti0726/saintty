#!/usr/bin/env python3
"""Film held j/k (and a wheel spin) over most of the text and find frames where
the text CHANGED rather than moved -- the "blink" -- plus how far the screen
trails nvim in each direction.

    python3 tools/scroll-harness/fast/blink.py [--bin=PATH] [--out=DIR] [--arms=0,600]
        [--lines=1500,560,1210,2520]

Each filmed frame is matched to the one before by the best whole-pixel
vertical shift; what is left after that shift (`resid`, mean |diff| over the
overlap) is ~0 for a pure scroll and jumps when cells are redrawn
differently. The worst frames are saved as PNGs (before | after | diff) so the
change can be looked at, and the spacing of the spikes says whether it is
periodic. `gt scroll` switches the animation like the user's slider does, and
puts the old value back at the end.
"""

import json
import subprocess
import sys
import threading
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import devices  # noqa: E402
import run  # noqa: E402
import scenarios  # noqa: E402

GT = Path.home() / ".local/bin/gt"
X, W, Y, H = 0, 1000, 60, 960  # text rows 3..50 of the left half
if any(a == "--narrow" for a in sys.argv):  # long gestures: ~200 KB a frame
    W = 200


class Film:
    def __init__(self):
        self.frames = []
        cmd = ["wf-recorder", "-y", "-g", f"{X},{Y} {W}x{H}", "-c", "rawvideo", "-x", "gray",
               "-m", "rawvideo", "-f", "/dev/stdout"]
        self.p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.t = threading.Thread(target=self._read, daemon=True)
        self.t.start()

    def _read(self):
        n = W * H
        while True:
            b = self.p.stdout.read(n)
            if len(b) < n:
                return
            self.frames.append((time.monotonic(), np.frombuffer(b, np.uint8).reshape(H, W)))

    def stop(self):
        self.p.send_signal(2)
        try:
            self.p.wait(5)
        except subprocess.TimeoutExpired:
            self.p.kill()
        self.t.join(2)


def best_shift(a, b, lim=200):
    pa, pb = a.mean(axis=1), b.mean(axis=1)
    best, bs = None, 0
    for s in range(-lim, lim + 1):
        x, y = (pa[s:], pb[: H - s]) if s >= 0 else (pa[: H + s], pb[-s:])
        if len(x) < H // 3:
            continue
        e = float(np.mean(np.abs(x - y)))
        if best is None or e < best:
            best, bs = e, s
    return bs


def resid(a, b, s):
    x, y = (a[s:], b[: H - s]) if s >= 0 else (a[: H + s], b[-s:])
    d = np.abs(x.astype(np.int16) - y.astype(np.int16))
    return float(d.mean()), d


def save_png(path, a, b, s):
    _, d = resid(a, b, s)
    x = a[s:] if s >= 0 else a[: H + s]
    y = b[: H - s] if s >= 0 else b[-s:]
    img = np.concatenate([x, y, np.clip(d * 4, 0, 255).astype(np.uint8)], axis=1)
    h, w = img.shape
    with open(path, "wb") as f:  # PGM, then converted
        f.write(f"P5 {w} {h} 255\n".encode() + img.tobytes())
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(path), str(path.with_suffix(".png"))])
    path.unlink()


def analyse(out, tag, frames, events, nv):
    pts, pos = [], 0
    for (t0, a), (t1, b) in zip(frames, frames[1:]):
        s = best_shift(a, b)
        r, _ = resid(a, b, s)
        pos += s
        pts.append((t1, s, r, pos))
    (out / f"{tag}.film.txt").write_text("".join(f"{t:.4f} {s} {r:.3f} {p}\n" for t, s, r, p in pts))
    rs = np.array([p[2] for p in pts]) if pts else np.zeros(1)
    floor = float(np.median(rs))
    spikes = [(i, p) for i, p in enumerate(pts) if p[2] > max(4 * floor, floor + 1.0)]
    times = [p[0] for _, p in spikes]
    gaps = np.diff(times) * 1000 if len(times) > 1 else np.array([])
    for i, p in sorted(spikes, key=lambda x: -x[1][2])[:4]:
        save_png(out / f"{tag}.spike{i:04d}.pgm", frames[i][1], frames[i + 1][1], p[1])
    keys = [t / 1e6 for t, k, _ in events if k in ("key_down", "start")]
    ends = [t / 1e6 for t, k, _ in events if k in ("key_up", "end")]
    moving = [p for p, q in zip(pts, [(0, 0, 0, 0)] + pts) if p[3] != q[3]]
    res = {
        "frames": len(pts),
        "rows": pos / 20,
        "resid_median": floor,
        "spikes": len(spikes),
        "spike_gap_ms_median": float(np.median(gaps)) if len(gaps) else None,
        "spike_gaps_ms": [round(g) for g in gaps[:20]],
        "move_gap_ms_max": float(np.max(np.diff([p[0] for p in moving])) * 1000) if len(moving) > 1 else None,
        "rows_per_move_max": max((abs(p[1]) // 20 for p in moving), default=0),
        "stop_after_release_ms": (moving[-1][0] - ends[-1]) * 1000 if moving and ends else None,
    }
    nvt = [t / 1e6 for t in nv]
    if nvt and ends:
        res["nvim_last_after_release_ms"] = (nvt[-1] - ends[-1]) * 1000
        res["nvim_rows"] = len(nvt)
        # screen behind nvim, in rows, while it runs
        trail = []
        for t, _, _, p in pts:
            if keys and keys[0] + 0.8 < t < ends[-1]:
                trail.append(sum(1 for x in nvt if x <= t) - abs(p) / 20)
        if trail:
            res["trail_rows_median"] = float(np.median(trail))
            res["trail_rows_max"] = float(np.max(trail))
    return res


def main():
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    binary = Path(opts.get("bin", Path.home() / "tools/ghostty/bin/ghostty"))
    out = Path(opts.get("out", Path.home() / "playground/fast-scroll" / time.strftime("%Y%m%d-%H%M%S-blink")))
    arms = [int(x) for x in opts.get("arms", "0,600").split(",")]
    # `own`: each scenario's own start line (the mx_* replays need theirs).
    lines = [None if x == "own" else int(x) for x in opts.get("lines", "1500,560,1210,2520").split(",")]
    tests = opts.get("tests", "hold_j,hold_k,wheel_fast_up").split(",")
    before = json.loads(subprocess.run([GT, "scroll", "--json"], capture_output=True, text=True).stdout)["value"]

    rig = run.Rig(binary, out)
    rec = devices.Recorder()
    mouse = pad = None
    report = {}
    try:
        rig.start()
        mouse, pad = devices.Mouse(rec), devices.Touchpad(rec)
        time.sleep(1.0)
        rig.park_pointer(mouse)
        for arm in arms:
            subprocess.run([GT, "scroll", str(arm)], capture_output=True)
            time.sleep(1.0)
            for line in lines:
                for name in tests:
                    sc = scenarios.ALL[name]
                    start = sc.line if line is None else line + (150 if sc.top else 0)  # k / up: room above
                    if sc.keys:
                        rig.reset(start, bottom=not sc.top)
                        if not rig.probe_keys():
                            print(f"{arm} {line} {name}: PROBE FAILED", flush=True)
                            continue
                    rig.reset(start, bottom=sc.keys and not sc.top)
                    rig.focus()
                    n0 = rig.nvlog.stat().st_size if rig.nvlog.exists() else 0
                    film = Film()
                    time.sleep(0.5)
                    rec.events.clear()
                    rec.mark("start")
                    sc.run(mouse=mouse, pad=pad, rec=rec)
                    rec.mark("end")
                    time.sleep(min(max(sc.settle, 1.5), 6.0))
                    film.stop()
                    nv = [int(l.split()[0]) for l in run.slice_file(rig.nvlog, n0).splitlines() if l.strip()]
                    tag = f"{arm}-{line}-{name}"
                    r = analyse(out, tag, film.frames, rec.events, nv)
                    film.frames.clear()
                    report[tag] = r
                    print(f"{tag}: {json.dumps(r)}", flush=True)
    finally:
        for d in (mouse, pad):
            if d:
                d.close()
        subprocess.run([GT, "scroll", str(before)], capture_output=True)
        rig.stop()
    (out / "report.json").write_text(json.dumps(report, indent=1))
    print(out)


if __name__ == "__main__":
    main()
