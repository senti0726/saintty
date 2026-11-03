#!/usr/bin/env python3
"""Hitches during held j/k, from a lat.py or realstack.py output dir.

    python3 stalls.py DIR...

smooth% and lat.py's medians average hitches away. Per hold this prints:
  nvim  -- WinScrolled gaps > 45 ms (key repeat is 25 ms): nvim fell behind
  screen-- runs of >= 4 filmed frames (~65 ms) with no motion while the key
           was held, and single frames that jumped >= 3 rows
"""
import glob
import os
import sys

import numpy as np

for d in sys.argv[1:]:
    logs = glob.glob(os.path.join(d, "**/*nvim-scroll.log"), recursive=True)
    nv = np.sort(np.concatenate([[int(l.split()[0]) / 1e6 for l in open(f) if l.strip()] for f in logs]))
    for inp in sorted(glob.glob(os.path.join(d, "*hold_*.input.log"))):
        ev = [l.split() for l in open(inp)]
        kd = next(int(t) / 1e6 for t, k, _ in ev if k == "key_down")
        ku = next(int(t) / 1e6 for t, k, _ in ev if k == "key_up")
        n = nv[(nv > kd + 0.35) & (nv < ku)]  # past the 300 ms repeat delay
        g = np.diff(n) * 1000
        tr = np.loadtxt(inp.replace(".input.log", ".track.txt"))
        tr = tr[(tr[:, 0] > kd + 0.5) & (tr[:, 0] < ku)]
        mv = np.diff(tr[:, 1])
        freezes, run = [], 0
        for x in mv:
            if x == 0:
                run += 1
            else:
                if run >= 4:
                    freezes.append(run)
                run = 0
        jumps = int((np.abs(mv) >= 60).sum())
        print(f"{os.path.basename(inp)[:-10]:28s} nvim gaps>45ms: {len(g[g > 45]):2d} (worst {g.max():4.0f} ms)  "
              f"screen freezes>=4f: {freezes}  3+row jumps: {jumps}")
