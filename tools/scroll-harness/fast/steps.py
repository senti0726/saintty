#!/usr/bin/env python3
"""Step j (or k) one press at a time through CH2 and flag every press that is
not a clean one-row move.

    python3 tools/scroll-harness/fast/steps.py OUT --from=1555 --to=1580 [--key=j] [--gap=0.35] [--bin=PATH]
        [--shots=12,13] [--shot-at=0.25] [--conf-scroll-animation-duration=4000]

`--shots`: screenshot `--shot-at` seconds into those presses (slow the
animation so it is still moving), saved as NNN.png.

After each press: tmux `capture-pane` text, nvim's view (cursor, topline,
topfill, skipcol) and the Ghostty trace lines it caused. A press is clean
when the new screen is the old one shifted by 0 or 1 rows with only the
entering row new (the cursor row and status lines are ignored). Anything
else -- a shift of 2+, or rows that changed in place (a reflow) -- is listed,
with the rows that differ, so "it jumped" can be told from "it slid 7 rows".
`report.txt` is the summary; `NNN.txt` the screens.
"""

import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run  # noqa: E402

KEYS = {"j": "36", "k": "37"}


def tm(*a):
    return subprocess.run(["tmux", "-L", run.SOCK_NAME, *a], capture_output=True, text=True).stdout


def best_shift(a, b, body):
    """Rows of `b` are rows of `a` moved up by s. Returns (s, mismatched rows).
    Compared past the number column (relative numbers change every row's
    gutter on every move), and scored by the SHARE of overlapping rows that
    differ, so a large shift cannot win by overlapping less."""
    def txt(l):
        return l[5:]
    best = None
    for s in range(-12, 13):
        rows = [r for r in body if r + s in body]
        if len(rows) < len(body) // 2:
            continue
        bad = [r for r in rows if txt(a[r + s]) != txt(b[r])]
        key = (len(bad) / len(rows), abs(s))
        if best is None or key < best[0]:
            best = (key, s, bad)
    return best[1], best[2]


def main():
    out = Path(sys.argv[1])
    if "--analyse" in sys.argv:
        return analyse(out)
    opts = dict(a[2:].split("=", 1) for a in sys.argv[2:] if a.startswith("--") and "=" in a)
    lo, hi = int(opts["from"]), int(opts["to"])
    keyname = opts.get("key", "j")
    gap = float(opts.get("gap", "0.35"))
    binary = opts.get("bin", str(run.REPO / "zig-out-release/bin/ghostty"))
    extra = [a for a in sys.argv[2:] if a.startswith("--conf-")]
    rig = run.Rig(Path(binary), out, extra)
    code = KEYS[keyname]
    screens, views, logs = [], [], []
    try:
        rig.start()
        rig.focus()
        start = lo if keyname == "j" else hi
        rig.reset(start, bottom=keyname == "j")
        time.sleep(2.0)
        env = {**os.environ, **run.YDO}
        shots = {int(x) for x in opts.get("shots", "").split(",") if x}
        for i in range(400):
            g0 = rig.log.stat().st_size
            if i:
                if i in shots:
                    time.sleep(5.0)  # let the slowed animation of earlier presses settle
                subprocess.run(["ydotool", "key", f"{code}:1", f"{code}:0"], env=env, capture_output=True)
                if i in shots:
                    at = float(opts.get("shot-at", "0.25"))
                    time.sleep(at)
                    subprocess.run(["spectacle", "-b", "-n", "-f", "-o", str(out / f"{i:03d}.png")], capture_output=True)
                    time.sleep(max(0.0, gap - at))
                else:
                    time.sleep(gap)
            rig.logf.flush()
            screens.append(tm("capture-pane", "-p", "-e", "-t", "h").split("\n"))
            v = rig.nv('line(".")." ".line("w0")." ".winsaveview().topfill." ".winsaveview().skipcol')
            views.append(v)
            logs.append(run.slice_file(rig.log, g0) if i else "")
            cur = int(v.split()[0]) if v else 0
            if (keyname == "j" and cur >= hi) or (keyname == "k" and cur <= lo):
                break
    finally:
        rig.stop()
    for i, (sc, v, lg) in enumerate(zip(screens, views, logs)):
        (out / f"{i:03d}.txt").write_text(v + "\n" + "\n".join(sc) + "\n---\n" + lg)
    analyse(out)


def load(out):
    frames = []
    for f in sorted(out.glob("[0-9][0-9][0-9].txt")):
        t = f.read_text()
        head, _, log = t.partition("\n---\n")
        lines = head.split("\n")
        frames.append((lines[0], lines[1:], log))
    return frames


def analyse(out):
    strip = re.compile(r"\x1b\[[0-9;:]*m")
    frames = load(out)
    rep = []
    for i in range(1, len(frames)):
        # trailing blanks differ with the width of the virtual text drawn
        # there and are invisible: compare what is visible
        a = [strip.sub("", l).rstrip() for l in frames[i - 1][1]]
        b = [strip.sub("", l).rstrip() for l in frames[i][1]]
        h = min(len(a), len(b)) - 3  # nvim status/cmd + tmux status
        body = set(range(0, h))
        s, bad_t = best_shift(a, b, body)
        ev = re.findall(r"(scroll event: rows=-?\d+|repaintscroll shift=-?\d+)", frames[i][2])
        tag = "ok"
        if abs(s) > 1:
            tag = f"SHIFT {s}"
        if bad_t:
            tag += f" REFLOW rows {bad_t[:12]}{'…' if len(bad_t) > 12 else ''}"
        rep.append(f"{i:03d} {frames[i-1][0]} -> {frames[i][0]}  shift={s} {tag}  ghostty: {', '.join(ev) or '-'}")
    (out / "report.txt").write_text("\n".join(rep) + "\n")
    print("\n".join(r for r in rep if not r.split("  ")[1].endswith(" ok")))
    print(out / "report.txt")


if __name__ == "__main__":
    main()
