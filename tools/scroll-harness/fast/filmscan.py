#!/usr/bin/env python3
"""Find what the eye calls "stutter" and "jumps" in a filmed scroll.

    python3 filmscan.py FRAMES.gray PTS.txt WxH [--top=PX] [--bottom=PX] [--left=PX] [--row=PX] [--from=S] [--to=S] [--png=DIR]
    (or import scan() and feed it frames)

smooth% scores evenness from Ghostty's own log and lat.py follows ONE strip, so
neither sees a frame where part of the screen moves differently from the rest
(a reflow: a table, callout or figure changing height mid-scroll) or where the
text changes in place. Each frame is reduced to a signature -- per row, the
mean of 8 column chunks -- and matched against the previous frame:

  shift   how far the whole text area moved up (px of THIS film's scale)
  bands   the same, separately for 6 horizontal bands; a band that disagrees
          with the rest by > 2 px is a REFLOW (or a torn frame)
  resid   after aligning, the share of signature cells that still differ:
          content that changed in place (a blink, a row redrawn raw)

Flags, judged against the median step of the surrounding 0.5 s:
  JUMP    shift > 1.8 x median and > median + 1 text row
  STALL   no movement while the neighbourhood moves (median >= 3 px)
  REFLOW  bands disagree
  CHANGE  resid high with no reflow
"""
import sys
from pathlib import Path

import numpy as np

CHUNKS = 8
BANDS = 6


def signature(frame):
    h, w = frame.shape
    c = w // CHUNKS
    return frame[:, : c * CHUNKS].reshape(h, CHUNKS, c).mean(axis=2)


def match(prev, cur, y0, y1, lim):
    """s such that cur[y0:y1] ~ prev[y0+s:y1+s]; (s, err, second-best err)."""
    errs = {}
    for s in range(-lim, lim + 1):
        a0, a1 = y0 + s, y1 + s
        lo, hi = max(a0, 0), min(a1, len(prev))
        if hi - lo < (y1 - y0) * 0.6:
            continue
        x = prev[lo:hi]
        y = cur[lo - s : hi - s]
        errs[s] = float(np.abs(x - y).mean())
    s = min(errs, key=errs.get)
    rest = sorted(e for k, e in errs.items() if abs(k - s) > 3)
    return s, errs[s], rest[0] if rest else errs[s]


def scan(sigs, pts, row_px, lim=80):
    """sigs: list of (H, CHUNKS) arrays. Returns one dict per frame pair."""
    out = []
    h = sigs[0].shape[0]
    edges = np.linspace(0, h, BANDS + 1).astype(int)
    for i in range(1, len(sigs)):
        p, c = sigs[i - 1], sigs[i]
        s, err, _ = match(p, c, 0, h, lim)
        bands = []
        for b in range(BANDS):
            y0, y1 = edges[b], edges[b + 1]
            tex = float(c[y0:y1].std())
            if tex < 3:  # blank band: nothing to match on
                bands.append(None)
                continue
            bs, be, b2 = match(p, c, y0, y1, lim)
            # ambiguous (repetitive text): take the global shift if it fits as well
            if b2 - be < 0.5:
                bands.append(None)
                continue
            bands.append(bs)
        # residual after the global shift
        lo, hi = max(s, 0), min(h, h + s)
        x, y = p[lo:hi], c[lo - s : hi - s]
        resid = float((np.abs(x - y) > 6).mean())
        out.append({"t": pts[i], "shift": s, "err": err, "bands": bands, "resid": resid})
    # flags
    sh = np.array([o["shift"] for o in out], float)
    t = np.array([o["t"] for o in out])
    for i, o in enumerate(out):
        w = (t > o["t"] - 0.25) & (t < o["t"] + 0.25)
        med = float(np.median(np.abs(sh[w])))
        o["med"] = med
        flags = []
        a = abs(o["shift"])
        if a > 1.8 * med and a > med + row_px:
            flags.append("JUMP")
        if a == 0 and med >= 3:
            flags.append("STALL")
        bs = [b for b in o["bands"] if b is not None]
        if len(bs) >= 2 and (max(bs) - min(bs) > 2 or any(abs(b - o["shift"]) > 2 for b in bs)):
            flags.append("REFLOW")
        elif o["resid"] > 0.04:
            flags.append("CHANGE")
        o["flags"] = flags
    return out


def load_raw(path, w, h, t0=None, t1=None, pts=None, top=0, bottom=0, left=0):
    a = np.memmap(path, np.uint8, "r").reshape(-1, h, w)
    sel = range(len(a)) if pts is None else [i for i, x in enumerate(pts[: len(a)]) if (t0 is None or x >= t0) and (t1 is None or x <= t1)]
    sigs = [signature(a[i, top : h - bottom, left:].astype(np.float32)) for i in sel]
    return a, list(sel), sigs


def save_png(a, i, j, path, top, bottom):
    from PIL import Image

    h = a.shape[1]
    x = np.concatenate([a[i, top : h - bottom], np.full((a.shape[1] - top - bottom, 6), 255, np.uint8), a[j, top : h - bottom]], axis=1)
    Image.fromarray(x).save(path)


def main():
    path, ptsf, size = sys.argv[1], sys.argv[2], sys.argv[3]
    w, h = (int(v) for v in size.split("x"))
    opts = dict(a[2:].split("=", 1) for a in sys.argv[4:] if a.startswith("--") and "=" in a)
    top, bottom, left = int(opts.get("top", 0)), int(opts.get("bottom", 0)), int(opts.get("left", 0))
    pts = [float(x) for x in open(ptsf) if x.strip()]
    t0 = float(opts["from"]) if "from" in opts else None
    t1 = float(opts["to"]) if "to" in opts else None
    row_px = float(opts.get("row", 10))
    a, sel, sigs = load_raw(path, w, h, t0, t1, pts, top, bottom, left)
    res = scan(sigs, [pts[i] for i in sel], row_px)
    moving = [o for o in res if o["med"] >= 3]
    print(f"{len(res)} frame pairs, {len(moving)} while scrolling")
    counts = {}
    for o in res:
        for f in o["flags"]:
            counts[f] = counts.get(f, 0) + 1
    print("flags:", counts)
    png = Path(opts["png"]) if "png" in opts else None
    if png:
        png.mkdir(parents=True, exist_ok=True)
    for k, o in enumerate(res):
        if o["flags"]:
            print(f"t={o['t']:7.3f} shift={o['shift']:4d} med={o['med']:4.1f} bands={o['bands']} resid={o['resid']:.3f} {' '.join(o['flags'])}")
            if png:
                save_png(a, sel[k], sel[k + 1], png / f"{o['t']:08.3f}-{'-'.join(o['flags'])}.png", top, bottom)


if __name__ == "__main__":
    main()


def dup_rows(frame, row_px, tex_min=20.0, diff_max=2.5):
    """y positions where a text row (row_px high) equals the row right below
    it: a repaint caught half done shows the row it just wrote twice."""
    f = frame.astype(np.float32)
    h = f.shape[0]
    out = []
    y = 0
    while y + 2 * row_px <= h:
        a, b = f[y : y + row_px], f[y + row_px : y + 2 * row_px]
        if a.std() > tex_min and np.abs(a - b).mean() < diff_max:
            out.append(y)
            y += row_px
        else:
            y += 1
    return out
