#!/usr/bin/env python3
"""Film a held key / a steady wheel FULL-WIDTH and score it per display refresh.

    python3 holdfilm.py OUT [--bin=PATH] [--tests=hold_j@1,wheel_down@1] [--hold=4]
        [--wheel-rate=N] [--reps=1] [--load=PIDFILE] [--nvim-config=DIR] [--tmux=no] [--warm=S] [--conf-KEY=VAL ...]

What the eye calls stutter is uneven motion from one refresh to the next, and a
jump is one refresh that moves much further than its neighbours. lat.py follows
one 64 px strip -- too little text to match reliably (the same setup scored
25-90 % "spread" run to run) -- so this films the whole screen (wf-recorder,
gray, every frame the compositor makes), matches each frame against the
previous one with filmscan's banded signature, and resamples the position on
the display's refresh grid. Per test, over the steady part of the hold:

  rows/refresh      mean distance per refresh (held j at 40/s on 60 Hz = 0.67)
  spread            sd / mean of that distance -- 0 is a perfect glide
  frozen / >1 row   share of refreshes that did not move / moved over a row
  reflows           frames whose bands moved by different amounts
  nvim gaps         nvim's own WinScrolled cadence: p95 and count > 45 ms

`--load=PIDFILE`: a background job's pid (its whole process tree) is paused
(SIGSTOP) for every other run of each test, in ABBA order, and always resumed.
`--nvim-config=DIR`: run nvim with that config directory (plugins stay the
installed ones), for bisecting the config. `--conf-*`: Ghostty overrides as
in run.py (note: they drop scroll-state.conf, so pass the animation too).
PNGs of the worst refreshes go to OUT/png.
"""

import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import devices  # noqa: E402
import filmscan  # noqa: E402
import run  # noqa: E402
import scenarios  # noqa: E402

# Defaults: eDP-1 1920x1200@60. For another output set HOLDFILM_OUTPUT,
# HOLDFILM_SIZE=WxH (the size the film is SCALED to), HOLDFILM_CELL (px per row
# at that size) and HOLDFILM_HZ, e.g. the 4K@120 monitor at scale 2.4:
# HOLDFILM_OUTPUT=HDMI-A-1 HOLDFILM_SIZE=1920x1080 HOLDFILM_CELL=<cell_h/2> HOLDFILM_HZ=120
OUTPUT = os.environ.get("HOLDFILM_OUTPUT", "eDP-1")
W, H = (int(x) for x in os.environ.get("HOLDFILM_SIZE", "1920x1200").split("x"))
CELL = float(os.environ.get("HOLDFILM_CELL", 20))  # px per text row at this display's font size
# full-res crop: tmux bar, nvim status + tmux status, relative-number gutter
TOP, BOTTOM, LEFT = int(CELL * 2), int(CELL * 4), int(CELL * 3.5)
REFRESH = 1 / float(os.environ.get("HOLDFILM_HZ", 60.004))
SCALE = os.environ.get("HOLDFILM_SIZE")  # set => let ffmpeg scale the capture


class Film:
    """Every compositor frame of one output, gray, halved, stamped on arrival."""

    def __init__(self, output=OUTPUT):
        self.frames = []
        if os.environ.get("HOLDFILM_NOFILM"):
            # Trace-only runs: at 4K@120 the recorder's own screencopy costs
            # the compositor ~30 % GPU and slows what it films.
            cmd = ["sleep", "infinity"]
            self.rec = subprocess.Popen(cmd, stdout=subprocess.PIPE)
            self.t = threading.Thread(target=lambda: None)
            self.t.start()
            return
        cmd = ["wf-recorder", "-y", "-o", output, "-c", "rawvideo", "-x", "gray", "-m", "rawvideo", "-f", "/dev/stdout"]
        if SCALE:
            cmd[-2:-2] = ["-F", f"scale={W}:{H}:flags=fast_bilinear"]
        self.rec = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        self.t = threading.Thread(target=self._read, daemon=True)
        self.t.start()

    def _read(self):
        n = W * H
        f = self.rec.stdout
        buf = bytearray(n)
        mv = memoryview(buf)
        while True:
            got = 0
            while got < n:
                k = f.readinto(mv[got:])
                if not k:
                    return
                got += k
            t = time.monotonic()
            a = np.frombuffer(buf, np.uint8).reshape(H, W)
            # 2x2 average, not every other pixel: decimation drops a 1 px
            # line (a table's border) whenever the scroll offset puts it on
            # an odd row, which faked "vanishing borders" and torn frames
            q = a[0::2, 0::2].astype(np.uint16)
            q += a[1::2, 0::2]
            q += a[0::2, 1::2]
            q += a[1::2, 1::2]
            self.frames.append((t, (q >> 2).astype(np.uint8)))

    def stop(self):
        self.rec.send_signal(signal.SIGINT)
        try:
            self.rec.wait(5)
        except subprocess.TimeoutExpired:
            self.rec.kill()
        self.t.join(2)


class Load:
    """Pause / resume a background job's whole process tree."""

    def __init__(self, pidfile):
        self.root = int(Path(pidfile).read_text().split()[0]) if pidfile else None
        self.paused = []

    def tree(self):
        out = subprocess.run(["pstree", "-p", str(self.root)], capture_output=True, text=True).stdout
        import re

        return [int(x) for x in re.findall(r"\((\d+)\)", out)]

    def pause(self):
        if self.root and not self.paused:
            self.paused = self.tree()
            for p in self.paused:
                try:
                    os.kill(p, signal.SIGSTOP)
                except ProcessLookupError:
                    pass
            time.sleep(1.0)  # let its CPU work drain off the cores

    def resume(self):
        for p in self.paused:
            try:
                os.kill(p, signal.SIGCONT)
            except ProcessLookupError:
                pass
        self.paused = []


def gesture(name, rec, mouse, hold, rate):
    """Marks key_down/key_up around the steady input, for keys and wheel alike."""
    if name in ("hold_j", "hold_k"):
        code = scenarios.J if name == "hold_j" else 37
        scenarios.key(code, True)
        rec.mark("key_down", 1)
        time.sleep(hold)
        scenarios.key(code, False)
        rec.mark("key_up", 0)
    else:
        direction = 1 if name == "wheel_down" else -1
        rec.mark("key_down", direction)
        scenarios._wheel(mouse, lambda t: rate, hold, direction=direction)
        rec.mark("key_up", 0)


def analyse(frames, events, nv_us, name, png_dir=None, tag=""):
    kd = next(t for t, k, _ in events if k == "key_down") / 1e6
    ku = next(t for t, k, _ in events if k == "key_up") / 1e6
    lo, hi = kd + 1.0, ku - 0.15
    sel = [(t, f) for t, f in frames if lo <= t <= hi]
    res = {"film_frames": len(sel)}
    # nvim's own cadence over the same window
    nv = np.array([x / 1e6 for x in nv_us if lo <= x / 1e6 <= hi])
    if len(nv) > 2:
        g = np.diff(nv) * 1000
        res["nvim_steps_per_s"] = round(len(nv) / (nv[-1] - nv[0]), 1)
        res["nvim_gap_p50_p95_max"] = [round(float(np.median(g)), 1), round(float(np.percentile(g, 95)), 1), round(float(g.max()), 1)]
        res["nvim_gaps_over_45ms"] = int((g > 45).sum())
    if len(sel) < 20:
        return res
    t = np.array([x for x, _ in sel])
    crop = lambda f: f[TOP // 2 : (H - BOTTOM) // 2, LEFT // 2 :].astype(np.float32)  # noqa: E731
    sigs = [filmscan.signature(crop(f)) for _, f in sel]
    scan = filmscan.scan(sigs, list(t), CELL / 2, lim=100)
    sh = np.array([abs(o["shift"]) for o in scan], float)
    # position on the refresh grid: a refresh with no new frame did not move
    pos = np.concatenate([[0], np.cumsum(sh)])
    grid = np.arange(t[0], t[-1], REFRESH)
    idx = np.searchsorted(t, grid + REFRESH / 2, side="right") - 1
    step = np.diff(pos[idx]) * 2 / CELL  # rows per refresh
    dt = np.diff(t) / REFRESH
    res.update(
        rows_per_refresh=round(float(step.mean()), 3),
        spread_pct=round(float(step.std() / step.mean() * 100), 1) if step.mean() else None,
        frozen_pct=round(float((step == 0).mean() * 100), 1),
        over_1row_pct=round(float((step > 1.0).mean() * 100), 1),
        over_2row=int((step > 2.0).sum()),
        max_step_rows=round(float(step.max()), 2),
        reflows=sum(1 for o in scan if "REFLOW" in o["flags"]),
        film_skipped_refreshes=int(np.clip(np.round(dt) - 1, 0, None).sum()),
    )
    # torn frames: a duplicated row that neither neighbour frame has
    dups = [len(filmscan.dup_rows(crop(f), int(CELL // 2))) for _, f in sel]
    res["tears"] = sum(1 for i in range(1, len(dups) - 1) if dups[i] > max(dups[i - 1], dups[i + 1]))
    res["_tear_idx"] = [i for i in range(1, len(dups) - 1) if dups[i] > max(dups[i - 1], dups[i + 1])]
    res["tear_times"] = [round(float(t[i]), 4) for i in res["_tear_idx"]]
    res["key_down_at"] = round(kd, 4)
    # Lag: nvim's rows (one WinScrolled per held-key row) against the
    # film's, both counted from key_down, and how long the screen kept moving
    # after nvim's last row. The same count for every arm, so comparable even
    # where a redraw covered two keys.
    all_t = np.array([x for x, _ in frames])
    k0 = [i for i, (x, _) in enumerate(frames) if x >= kd]
    if k0 and len(nv_us) > 2:
        fs = frames[k0[0]:]
        ft = np.array([x for x, _ in fs])
        fsig = [filmscan.signature(crop(f)) for _, f in fs]
        fsh = [0] + [abs(filmscan.match(fsig[i - 1], fsig[i], 0, fsig[i].shape[0], 100)[0]) for i in range(1, len(fsig))]
        frows = np.cumsum(fsh) * 2 / CELL
        nvt = np.array([x / 1e6 for x in nv_us if x / 1e6 >= kd])
        nrows = np.searchsorted(nvt, ft, side="right")
        m = (ft >= lo) & (ft <= hi)
        if m.any():
            res["lag_rows_median"] = round(float(np.median(nrows[m] - frows[m])), 2)
        moving = ft[1:][np.array(fsh[1:]) > 0]
        if len(nvt) and len(moving):
            res["moves_after_last_row_ms"] = round(float((moving[-1] - nvt[-1]) * 1000), 1)
    res["_step"] = step.tolist()
    if png_dir is not None:
        png_dir.mkdir(parents=True, exist_ok=True)
        for i in res["_tear_idx"][:3]:
            filmscan.save_png(np.stack([sel[i - 1][1], sel[i][1]]), 0, 1, png_dir / f"{tag}{name}-{t[i] - kd:06.3f}s-TEAR.png", TOP // 2, BOTTOM // 2)
        worst = sorted(range(len(scan)), key=lambda i: -(abs(scan[i]["shift"]) + (100 if "REFLOW" in scan[i]["flags"] else 0)))[:4]
        for i in worst:
            filmscan.save_png(np.stack([sel[i][1], sel[i + 1][1]]), 0, 1, png_dir / f"{tag}{name}-{t[i + 1] - kd:06.3f}s-shift{scan[i]['shift']}{'-REFLOW' if 'REFLOW' in scan[i]['flags'] else ''}.png", TOP // 2, BOTTOM // 2)
    return res


class HoldRig(run.Rig):
    """run.Rig, optionally with nvim on another config directory."""

    def __init__(self, binary, out, extra=(), nvim_config=None, tmux=True):
        super().__init__(binary, out, extra)
        self.nvim_config = nvim_config
        self.use_tmux = tmux
        if os.environ.get("HOLDFILM_PTYREC"):
            # log what the terminal receives -- nvim's bytes, or with tmux
            # tmux's -- see ptyrec.py
            self.exec_prefix = ["python3", str(HERE / "ptyrec.py"), os.environ["HOLDFILM_PTYREC"], "--"]

    def start(self):
        if self.nvim_config:
            xdg = self.work / "xdg"
            xdg.mkdir(exist_ok=True)
            link = xdg / "nvim"
            if link.is_symlink() or link.exists():
                link.unlink()
            link.symlink_to(Path(self.nvim_config).resolve())
            self.nvim_env = f"XDG_CONFIG_HOME={xdg} "
        super().start()


def main():
    out = Path(sys.argv[1])
    opts = dict(a[2:].split("=", 1) for a in sys.argv[2:] if a.startswith("--") and "=" in a and not a.startswith("--conf-"))
    extra = [a for a in sys.argv[2:] if a.startswith("--conf-")]
    binary = Path(opts.get("bin", Path.home() / "tools/ghostty/bin/ghostty"))
    tests = [(x.split("@")[0], int(x.split("@")[1]) if "@" in x else 1) for x in opts.get("tests", "hold_j@1,wheel_down@1").split(",")]
    hold, rate, reps = float(opts.get("hold", 4)), float(opts.get("wheel-rate", 40)), int(opts.get("reps", 1))
    load = Load(opts.get("load"))
    rig = HoldRig(binary, out, extra, opts.get("nvim-config"), tmux=opts.get("tmux", "yes") != "no")
    rec = devices.Recorder()
    mouse = None
    report = []
    try:
        rig.start()
        # A fresh nvim blocks 150-250 ms on each formula its latex warm-up
        # has not reached yet; let it finish before anything is timed.
        time.sleep(float(opts.get("warm", 0)))
        if any(n.startswith("wheel") for n, _ in tests):
            mouse = devices.Mouse(rec)
            time.sleep(0.5)
            rig.park_pointer(mouse)
        for rep in range(reps):
            arms = ["load", "quiet"] if load.root else ["-"]
            if rep % 2:
                arms.reverse()
            for arm in arms:
                for name, line in tests:
                    up = name in ("hold_k", "wheel_up")
                    if arm == "quiet":
                        load.pause()
                    try:
                        rig.reset(line, bottom=not up)
                        if name.startswith("hold") and not rig.probe_keys():
                            print(f"{name}: PROBE FAILED", flush=True)
                            continue
                        rig.reset(line, bottom=not up)
                        rig.focus()
                        n0 = rig.nvlog.stat().st_size if rig.nvlog.exists() else 0
                        film = Film()
                        time.sleep(0.8)
                        rec.events.clear()
                        gesture(name, rec, mouse, hold, rate)
                        time.sleep(1.0)
                        film.stop()
                    finally:
                        load.resume()
                    nv = [int(l.split()[0]) for l in run.slice_file(rig.nvlog, n0).splitlines() if l.strip()]
                    r = analyse(film.frames, rec.events, nv, name, out / "png", f"r{rep}-{arm}-")
                    r.update(test=f"{name}@{line}", arm=arm, rep=rep)
                    step = r.pop("_step", None)
                    r.pop("_tear_idx", None)
                    report.append(r)
                    if step is not None:
                        (out / f"r{rep}-{arm}-{name}@{line}.steps.txt").write_text("\n".join(f"{x:.3f}" for x in step))
                    print(json.dumps(r), flush=True)
                    del film
    finally:
        load.resume()
        if mouse:
            mouse.close()
        rig.stop()
    (out / "report.json").write_text(json.dumps(report, indent=1))


if __name__ == "__main__":
    main()
