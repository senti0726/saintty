#!/usr/bin/env python3
"""How long the application keeps scrolling after the wheel stops.

    python3 tools/scroll-harness/fast/overrun.py <run-dir> [scenario ...]

overrun = last nvim WinScrolled - last wheel report sent; also the rows
travelled after the wheel stopped, and the Ghostty scrollinput count against
reports sent (a shortfall is input lost before Ghostty)."""
import re
import sys
from pathlib import Path

run = Path(sys.argv[1])
names = sys.argv[2:] or sorted(p.name[: -len(".input.log")] for p in run.glob("*.input.log"))
print(f"{'scenario':14} {'overrun ms':>10} {'rows after':>10} {'rows total':>10} {'nvim upd':>8} {'ghostty in':>10} {'sent':>5}")
for n in names:
    inp = [l.split() for l in (run / f"{n}.input.log").read_text().splitlines()]
    w = [int(a[0]) for a in inp if a[1] == "wheel"]
    if not w:
        continue
    nv = [tuple(int(x) for x in l.split()) for l in (run / f"{n}.nvim.log").read_text().splitlines() if l.strip()]
    g = (run / f"{n}.ghostty.log").read_text()
    si = len(re.findall(r"scrollinput", g))
    if not nv:
        print(f"{n:14} no nvim scrolls")
        continue
    after = [x for x in nv if x[0] > w[-1]]
    top_at_stop = next((x[1] for x in reversed(nv) if x[0] <= w[-1]), nv[0][1])
    print(f"{n:14} {(nv[-1][0] - w[-1]) / 1000:10.0f} {abs(nv[-1][1] - top_at_stop):10d} {abs(nv[-1][1] - nv[0][1]):10d} {len(nv):8d} {si:10d} {len(w):5d}")
