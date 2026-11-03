#!/usr/bin/env python3
"""Replay a ptyrec.py log into pyte and check each synchronized update.

    ptyreplay.py LOG [--cols=N --rows=N] [--around=T1,T2,...]

Prints, per ?2026 block: when it ended, its size, and whether the screen at
its end has a non-blank row equal to the row below it that the previous
block's end did not have (a half-done repaint would show one). Also counts
bytes written OUTSIDE any block -- the terminal may draw those at any moment.
"""
import re, struct, sys
import pyte

path = sys.argv[1]
opts = dict(a[2:].split("=", 1) for a in sys.argv[2:] if a.startswith("--") and "=" in a)
recs = []
with open(path, "rb") as f:
    while True:
        h = f.read(12)
        if len(h) < 12:
            break
        t, n = struct.unpack("<QI", h)
        recs.append((t / 1e9, f.read(n)))
data = b"".join(b for _, b in recs)
# time of each byte offset (start of its record)
offs, acc = [], 0
for t, b in recs:
    offs.append((acc, t))
    acc += len(b)
def time_at(o):
    lo, hi = 0, len(offs) - 1
    while lo < hi:
        m = (lo + hi + 1) // 2
        if offs[m][0] <= o:
            lo = m
        else:
            hi = m - 1
    return offs[lo][1]

if "cols" in opts:
    cols, rows = int(opts["cols"]), int(opts["rows"])
else:
    cup = [(int(r), int(c)) for r, c in re.findall(rb"\x1b\[(\d+);(\d+)H", data)]
    rows, cols = max(r for r, _ in cup), max(c for _, c in cup)
# APC (kitty graphics) and OSC confuse pyte: drop them, keep their length out
clean = re.compile(rb"\x1b_.*?\x1b\\|\x1b\].*?(?:\x07|\x1b\\)", re.S)
scr = pyte.Screen(cols, rows)
st = pyte.ByteStream(scr)
marks = [(m.start(), m.group(1)) for m in re.finditer(rb"\x1b\[\?2026([hl])", data)]
print(f"{len(data)} bytes, {cols}x{rows}, {sum(1 for _, k in marks if k == b'h')} sync blocks")

def dups(lines):
    out = set()
    for i in range(len(lines) - 1):
        a = lines[i].rstrip()
        if len(a.strip()) > 20 and a == lines[i + 1].rstrip():
            out.add((i, a.strip()[:50]))
    return out

pos, insync, outside, prev_d, blocks = 0, False, 0, set(), []
for o, kind in marks + [(len(data), b"end")]:
    chunk = data[pos:o]
    if not insync and chunk.strip():
        outside += len(chunk)
    st.feed(clean.sub(b"", chunk))
    pos = o + (len(b"\x1b[?2026h") if kind != b"end" else 0)
    if kind == b"h":
        insync = True
        start = o
    elif kind == b"l":
        insync = False
        d = dups(scr.display)
        new = d - prev_d
        blocks.append((time_at(o), o - start, new))
        prev_d = d
print(f"bytes outside sync blocks: {outside}")
around = [float(x) for x in opts.get("around", "").split(",") if x]
bad = [b for b in blocks if b[2]]
print(f"blocks ending with a NEW duplicated row: {len(bad)}")
for t, n, new in bad[:30]:
    print(f"  t={t:.4f} block {n} B  {sorted(new)[:3]}")
for a in around:
    near = [b for b in blocks if a - 0.06 <= b[0] <= a + 0.01]
    print(f"film tear at {a:.4f}: blocks in the 60 ms before:", [(round(t - a, 4), n, bool(new)) for t, n, new in near])
