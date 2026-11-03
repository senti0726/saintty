#!/usr/bin/env python3
"""cuts.py <run-dir> <scenario>: for every nvim WinScrolled, did Ghostty see a scroll?"""
import re, sys
from collections import Counter
d, name = sys.argv[1], sys.argv[2]
nv = [tuple(map(int, l.split())) for l in open(f"{d}/{name}.nvim.log") if l.strip()]
ev = []
for l in open(f"{d}/{name}.ghostty.log"):
    m = re.search(r"scroll event: rows=(-?\d+) .*mono_us=(\d+)", l) or re.search(r"repaintscroll shift=(-?\d+) .*mono_us=(\d+)", l)
    if m: ev.append((int(m[2]), "real" if "event" in l else "rep", abs(int(m[1]))))
cls, bad, prev = Counter(), [], None
for t, top, fill, skip in nv:
    near = [e for e in ev if t - 5000 <= e[0] <= t + 200000]
    c = "cut" if not near else "snap" if any(k == "real" and r > 40 for _, k, r in near) else "ok"
    cls[c] += 1
    if c != "ok": bad.append(f"{prev[0] if prev else '?'}->{top}")
    prev = (top, fill, skip)
print(name, dict(cls), " ".join(bad) if "-v" in sys.argv else "")
