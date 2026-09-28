#!/usr/bin/env python3
"""press_cuts.py <run-dir> [scenario]: per `15j` press of a count_j sweep, what the user saw.

    all animated / 1-2 rows snapped / 3+ rows snapped / whole move cut / no scroll

A press's scroll steps are the nvim WinScrolled lines between it and the next
press; a step is cut when Ghostty logged no scroll event and no recovered
repaint shift for it. Also prints, per fifth of the sweep, the median delay from
the key to nvim's first step and the median gap between steps (the key mark is
taken after ydotool returns, so it trails the key by a few ms)."""
import re, sys
d = sys.argv[1]
name = sys.argv[2] if len(sys.argv) > 2 else "count_j_sweep"
nv = [int(l.split()[0]) for l in open(f"{d}/{name}.nvim.log") if l.strip()]
ev = []
for l in open(f"{d}/{name}.ghostty.log"):
    m = re.search(r"scroll event: rows=(-?\d+) .*mono_us=(\d+)", l) or re.search(r"repaintscroll shift=(-?\d+) .*mono_us=(\d+)", l)
    if m: ev.append(int(m[2]))
presses = [int(l.split()[0]) for l in open(f"{d}/{name}.input.log") if " key " in l]
b = {"all animated": 0, "1-2 rows snapped": 0, "3+ rows snapped": 0, "whole move cut": 0, "no scroll": 0}
first, gaps, cut_at = [], [], []
for i, p in enumerate(presses):
    end = presses[i + 1] if i + 1 < len(presses) else p + 700000
    steps = [t for t in nv if p <= t < end]
    first.append((steps[0] - p) / 1000 if steps else None)
    gaps.append([(y - x) / 1000 for x, y in zip(steps, steps[1:])])
    if not steps:
        b["no scroll"] += 1; continue
    cut = [not any(t - 5000 <= e <= t + 200000 for e in ev) for t in steps]
    run = best = 0
    for c in cut:
        run = run + 1 if c else 0; best = max(best, run)
    k = "whole move cut" if all(cut) else "3+ rows snapped" if best >= 3 else "1-2 rows snapped" if best else "all animated"
    b[k] += 1
    if k == "whole move cut": cut_at.append(i)
print(d.rstrip("/").split("/")[-1], b)
print("  whole-move cuts at presses:", cut_at)
med = lambda v: (lambda w: round(w[len(w) // 2], 1) if w else -1)(sorted(x for x in v if x is not None))
q = max(1, len(presses) // 5)
for a in range(0, q * 5, q):
    print(f"  presses {a:3}-{a + q - 1:3}: first step {med(first[a:a + q]):6} ms, step gap {med([x for g in gaps[a:a + q] for x in g]):5} ms")
