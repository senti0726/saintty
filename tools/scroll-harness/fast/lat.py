#!/usr/bin/env python3
"""What the user SEES when a key scrolls: films a strip of the real screen and
times it against the keys, at several `gt scroll` durations in one window.

    python3 tools/scroll-harness/fast/lat.py [--bin=PATH] [--out=DIR] [--arms=600,120,0]

analyse.py scores how evenly the text moves, from Ghostty's own frame log.
That says nothing about how LATE it moves, nor whether what Ghostty drew is
what reached the screen. This films it instead: wf-recorder on a 64 px strip
of the harness window (damage-driven, so a frame arrives when the compositor
composites), each frame's vertical offset found by matching its brightness
profile against the previous frame's.

Each arm is applied the way the user's control-centre slider applies it --
`gt scroll <ms>`, which rewrites scroll-state.conf and SIGUSR2s every Ghostty
-- so it also tests that the toggle reaches a running window. The value that
was set before is put back at the end.
"""

import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run  # noqa: E402
import scenarios  # noqa: E402
from scenarios import key, sleep_until  # noqa: E402

GT = Path.home() / ".local/bin/gt"
J, K = 36, 37
X, W, Y, H = 260, 64, 60, 840  # strip: text rows 3..44, clear of status lines


def taps(rec, **_):
    """Six single j presses 1.2 s apart: how long one row takes to land."""
    t0 = time.monotonic()
    for i in range(6):
        sleep_until(t0 + i * 1.2)
        key(J, True)
        rec.mark("key", 1)
        time.sleep(0.04)
        key(J, False)


TESTS = [
    ("taps", taps, False),
    ("hold_j", scenarios.hold_j, False),
    ("hold_k", scenarios.hold_k, True),
    ("ctrl_d", scenarios.ctrl_d, False),
]
# per-press tests: timed like taps, each press its own window
PER_PRESS = {"taps": 1.2, "ctrl_d": 0.8}


class Film:
    """Raw gray frames from wf-recorder, stamped on arrival. No container:
    nut through ffmpeg buffered the damage-driven trickle and never flushed."""

    def __init__(self):
        self.frames = []  # (pts_s, arrival_mono_s, profile)
        rec = ["wf-recorder", "-y", "-g", f"{X},{Y} {W}x{H}", "-c", "rawvideo", "-x", "gray",
               "-m", "rawvideo", "-f", "/dev/stdout"]
        self.rec = subprocess.Popen(rec, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.t = threading.Thread(target=self._read, daemon=True)
        self.t.start()

    def _read(self):
        n = W * H
        f = self.rec.stdout
        while True:
            b = f.read(n)
            if len(b) < n:
                return
            a = np.frombuffer(b, np.uint8).reshape(H, W).astype(np.float32)
            self.frames.append((time.monotonic(), a.mean(axis=1)))

    def stop(self):
        self.rec.send_signal(2)
        try:
            self.rec.wait(5)
        except subprocess.TimeoutExpired:
            self.rec.kill()
        self.t.join(2)


def shift(a, b, lim=120):
    """Pixels the content moved UP from profile a to profile b (b[y] ~ a[y+s])."""
    best, bs = None, 0
    for s in range(-lim, lim + 1):
        if s >= 0:
            x, y = a[s:], b[: H - s]
        else:
            x, y = a[: H + s], b[-s:]
        if len(x) < H // 3:
            continue
        e = float(np.mean(np.abs(x - y)))
        if best is None or e < best:
            best, bs = e, s
    return bs, best


def track(frames):
    """[(t, cumulative px moved up)] -- one point per filmed frame."""
    out, pos = [], 0
    for (t0, a), (t1, b) in zip(frames, frames[1:]):
        s, _ = shift(a, b)
        pos += s
        out.append((t1, pos))
    return out


def summarise(name, tr, events, nv, cell=20):
    rows = lambda px: px / cell  # noqa: E731
    keys = [t / 1e6 for t, k, _ in events if k in ("key", "key_down")]
    ups = [t / 1e6 for t, k, _ in events if k == "key_up"]
    moving = [(t, p) for (t, p), (_, q) in zip(tr, [(0, 0)] + tr) if p != q]
    res = {"filmed_frames": len(tr), "moved_rows": rows(tr[-1][1]) if tr else 0}
    if not moving:
        return res
    if name in PER_PRESS:
        lat, land = [], []
        for i, k in enumerate(keys):
            nxt = keys[i + 1] if i + 1 < len(keys) else k + PER_PRESS[name]
            mv = [t for t, _ in moving if k <= t < nxt]
            if mv:
                lat.append((mv[0] - k) * 1000)
                land.append((mv[-1] - k) * 1000)
        res["first_visible_ms"] = lat
        res["last_visible_ms"] = land
    else:
        t_up = ups[0] if ups else keys[-1]
        res["start_ms"] = (moving[0][0] - keys[0]) * 1000
        res["stop_after_release_ms"] = (moving[-1][0] - t_up) * 1000
        # nvim's WinScrolled vs the filmed position: how many rows the screen
        # trails nvim by, sampled at each filmed frame during the hold.
        nvt = [t / 1e6 for t in nv]
        trail = []
        for t, p in tr:
            if not (keys[0] + 1.0 < t < t_up):
                continue
            n = sum(1 for x in nvt if x <= t)
            trail.append(n - abs(rows(p)))
        if trail:
            res["trail_rows_median"] = float(np.median(trail))
            # rows/s nvim scrolls, to turn the trail into a delay
            span = [x for x in nvt if keys[0] + 1.0 < x < t_up]
            rate = (len(span) - 1) / (span[-1] - span[0]) if len(span) > 2 else 0
            res["nvim_rows_per_s"] = rate
            res["trail_ms"] = float(np.median(trail)) / rate * 1000 if rate else None
        gaps = np.diff([t for t, _ in tr if keys[0] + 1.0 < t < t_up]) * 1000
        if len(gaps):
            res["film_gap_ms_med_p95_max"] = [float(np.median(gaps)), float(np.percentile(gaps, 95)), float(gaps.max())]
    return res


def main():
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    binary = Path(opts.get("bin", Path.home() / "tools/ghostty/bin/ghostty"))
    out = Path(opts.get("out", Path.home() / "playground/fast-scroll" / time.strftime("%Y%m%d-%H%M%S-lat")))
    arms = [int(x) for x in opts.get("arms", "600,120,0,600").split(",")]
    only = opts.get("tests")
    tests = [t for t in TESTS if not only or t[0] in only.split(",")]
    before = subprocess.run([GT, "scroll", "--json"], capture_output=True, text=True)
    before = json.loads(before.stdout)["value"]

    rig = run.Rig(binary, out)
    rec = scenarios_rec = None
    import devices
    rec = devices.Recorder()
    report = {}
    try:
        rig.start()
        for arm in arms:
            mark = rig.log.stat().st_size
            subprocess.run([GT, "scroll", str(arm)], capture_output=True)
            time.sleep(1.0)
            rig.logf.flush()
            reloaded = "reloading configuration" in run.slice_file(rig.log, mark)
            for name, fn, top in tests:
                rig.reset(1500 if not top else 1700, bottom=not top)
                if not rig.probe_keys():
                    print(f"{arm} {name}: PROBE FAILED")
                    continue
                rig.reset(1500 if not top else 1700, bottom=not top)
                rig.focus()
                n0 = rig.nvlog.stat().st_size if rig.nvlog.exists() else 0
                film = Film()
                time.sleep(0.6)
                rec.events.clear()
                rec.mark("start")
                fn(rec=rec)
                rec.mark("end")
                time.sleep(1.5)
                film.stop()
                nv = [int(l.split()[0]) for l in run.slice_file(rig.nvlog, n0).splitlines() if l.strip()]
                tr = track(film.frames)
                r = summarise(name, tr, rec.events, nv)
                r["reloaded"] = reloaded
                report[f"{arm}:{name}"] = r
                (out / f"{arm}-{name}.track.txt").write_text("".join(f"{t:.4f} {p}\n" for t, p in tr))
                (out / f"{arm}-{name}.input.log").write_text("".join(f"{t} {k} {v}\n" for t, k, v in rec.events))
                print(f"{arm} ms {name}: {json.dumps(r)}", flush=True)
    finally:
        subprocess.run([GT, "scroll", str(before)], capture_output=True)
        rig.stop()
    (out / "report.json").write_text(json.dumps(report, indent=1))
    print(out)


if __name__ == "__main__":
    main()
