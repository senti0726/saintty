#!/usr/bin/env python3
"""Read a GHOSTTY_FRAME_DUMP file (every frame Ghostty presented, at a third
of the resolution; see OpenGL.zig `dumpFrame`) and look for figures that do
not move with the text.

    python3 tools/scroll-harness/fast/frames.py DUMP [--png=OUTDIR] [--from=N --to=M]
    python3 tools/scroll-harness/fast/frames.py DUMP --check

`--png` writes frames as PNG (all, or --from/--to by index). `--check`
measures, per consecutive pair of frames:

  * how far the TEXT moved: the vertical shift that best lines up the row
    brightness profiles of the text columns outside any figure;
  * how far each FIGURE moved: the shift that best lines up the figure's own
    rows (a figure is a block of light, low-saturation pixels);

and lists pairs where a figure moved by a different amount than the text
(a jump), or where the figure matches its previous self at no shift at all
(torn: rows duplicated or lost). Shifts are in dump pixels (x3 for the screen).
"""
import struct
import sys
from pathlib import Path

import numpy as np


def frames(path):
    with open(path, "rb") as f:
        while True:
            head = f.read(16)
            if len(head) < 16:
                return
            us, w, h = struct.unpack("<QII", head)
            data = f.read(w * h * 4)
            if len(data) < w * h * 4:
                return
            img = np.frombuffer(data, np.uint8).reshape(h, w, 4)[::-1, :, :3]
            yield us, img


def figure_mask(img):
    # Figures here are light (a grey or white page) on the black theme; text
    # is thin strokes. Rows/columns that are mostly light belong to a figure.
    g = img.astype(np.int16)
    light = (g.min(axis=2) > 150) & ((g.max(axis=2) - g.min(axis=2)) < 60)
    return light


def max_run(row):
    # Longest run of True in a boolean row.
    if not row.any():
        return 0
    d = np.diff(np.concatenate(([0], row.astype(np.int8), [0])))
    starts, ends = np.nonzero(d == 1)[0], np.nonzero(d == -1)[0]
    return int((ends - starts).max())


def figure_boxes(light):
    h, w = light.shape
    # A figure row has a long unbroken run of light pixels; light TEXT never
    # does (glyph strokes are a few pixels wide), which counted every line of
    # prose as a figure.
    rows = np.array([max_run(light[y]) >= 50 for y in range(h)])
    boxes = []
    y = 0
    while y < h:
        if rows[y]:
            y0 = y
            while y < h and rows[y]:
                y += 1
            if y - y0 >= 6:
                cols = light[y0:y].sum(axis=0) > (y - y0) * 0.5
                xs = np.nonzero(cols)[0]
                if len(xs):
                    boxes.append((y0, y, int(xs[0]), int(xs[-1]) + 1))
        y += 1
    return boxes


def best_shift(a, b, maxs=160):
    """Shift s (rows) minimising mean |a[y] - b[y+s]| over the overlap."""
    best = (1e9, 0)
    n = len(a)
    for s in range(-maxs, maxs + 1):
        lo, hi = max(0, -s), min(n, n - s)
        if hi - lo < n // 3:
            continue
        d = np.abs(a[lo:hi] - b[lo + s:hi + s]).mean()
        if d < best[0]:
            best = (d, s)
    return best[1], best[0]


def check(path):
    prev = None
    n = 0
    flagged = 0
    vanished = 0
    for i, (us, img) in enumerate(frames(path)):
        n += 1
        g = img.mean(axis=2)
        light = figure_mask(img)
        boxes = figure_boxes(light)
        # Text profile: columns left of every figure and outside them.
        mask_cols = np.ones(g.shape[1], bool)
        for (y0, y1, x0, x1) in boxes:
            mask_cols[x0:x1] = False
        text_prof = g[:, mask_cols].mean(axis=1) if mask_cols.any() else g.mean(axis=1)
        if prev is not None:
            pus, pg, pprof, pboxes = prev
            ts, terr = best_shift(pprof, text_prof)
            for (y0, y1, x0, x1) in boxes:
                # The figure's own rows now vs the same columns last frame.
                cur = g[y0:y1, x0:x1].mean(axis=1)
                col = pg[:, x0:x1].mean(axis=1)
                bs, berr = 1e9, 0
                for s in range(-160, 161):
                    a0, a1 = y0 + s, y1 + s
                    if a0 < 0 or a1 > len(col):
                        continue
                    d = np.abs(col[a0:a1] - cur).mean()
                    if d < bs:
                        bs, berr = d, s
                # berr is measured the other way round from ts (the figure's
                # current rows against last frame's), so agreement is -ts.
                at_edge = y0 < 20 or y1 > g.shape[0] - 20
                if abs(berr + ts) > 1 or (bs > 12 and not at_edge):
                    flagged += 1
                    print(f"frame {i} (+{(us - pus) / 1000:.1f} ms): text moved {-ts:+d}px, "
                          f"figure y{y0}..{y1} moved {berr:+d}px (err {bs:.1f})")
            # A figure that VANISHES: fully inside the screen last frame (not
            # touching an edge), and nothing figure-like where the text shift
            # would have taken it now. nvim closing and re-placing a figure
            # (its rows collapse, then come back) looks exactly like this.
            H = g.shape[0]
            for (y0, y1, x0, x1) in pboxes:
                if y0 < 20 or y1 > H - 20 or y1 - y0 < 20:
                    continue
                ny0, ny1 = y0 + ts, y1 + ts
                if not any(b[0] < ny1 and ny0 < b[1] and b[2] < x1 and x0 < b[3] for b in boxes):
                    vanished += 1
                    print(f"frame {i}: FIGURE VANISHED (was y{y0}..{y1}, text moved {ts:+d}px)")
        prev = (us, g, text_prof, boxes)
    print(f"{n} frames, {flagged} figure/text disagreements, {vanished} figures vanished")


def main():
    path = sys.argv[1]
    opts = dict(a[2:].split("=", 1) for a in sys.argv[2:] if a.startswith("--") and "=" in a)
    if "--check" in sys.argv:
        return check(path)
    out = Path(opts.get("png", "frames"))
    out.mkdir(parents=True, exist_ok=True)
    lo, hi = int(opts.get("from", 0)), int(opts.get("to", 10 ** 9))
    from PIL import Image
    for i, (us, img) in enumerate(frames(path)):
        if lo <= i <= hi:
            Image.fromarray(np.ascontiguousarray(img)).save(out / f"{i:05d}.png")
    print(out)


if __name__ == "__main__":
    main()
