#!/usr/bin/env python3
"""Replay a ptyrec.py log into pyte and keep the screen at the end of every
synchronized update (?2026l): what a terminal that honours mode 2026 can show.

    syncframes.py LOG COLSxROWS [--from=T --to=T] [--dump=T1,T2]

Flags a frame B between A and C when B is not a plain shift of A, C is not a
plain shift of B, but C IS a plain shift of A: a state shown for one frame and
undone -- what the eye sees as a jump or a tear. Kitty image placeholder cells
(U+10EEEE + row/column diacritics) are rendered as '#'+row-diacritic so a
figure's rows compare like text.
"""
import re, struct, sys
import pyte

PH = "\U0010EEEE"
# tmux's private queries (CSI ? n, CSI > c) trip pyte; nothing here answers them
pyte.Screen.report_device_status = lambda self, *a, **k: None
pyte.Screen.report_device_attributes = lambda self, *a, **k: None


def frames(path, cols, rows, t0=None, t1=None):
    recs = []
    with open(path, "rb") as f:
        while True:
            h = f.read(12)
            if len(h) < 12:
                break
            t, n = struct.unpack("<QI", h)
            recs.append((t / 1e9, f.read(n)))
    scr = pyte.Screen(cols, rows)
    st = pyte.ByteStream(scr)
    strip = re.compile(rb"\x1bP.*?\x1b\\|\x1b_.*?\x1b\\|\x1b\].*?(?:\x07|\x1b\\)", re.S)
    out, buf = [], b""
    for t, b in recs:
        buf += b
        # cut at each sync end; feed the rest later
        while True:
            k = buf.find(b"\x1b[?2026l")
            if k < 0:
                break
            chunk, buf = buf[: k + 8], buf[k + 8 :]
            st.feed(strip.sub(b"", chunk))
            if (t0 is None or t >= t0) and (t1 is None or t <= t1):
                out.append((t, render(scr)))
    return out


def render(scr):
    lines = []
    for y in range(scr.lines):
        row = scr.buffer[y]
        s = []
        for x in range(scr.columns):
            d = row[x].data
            if d.startswith(PH):
                s.append("#" + (chr(0x2460 + (ord(d[1]) % 20)) if len(d) > 1 else "?"))
            else:
                s.append(d or " ")
        lines.append("".join(s).rstrip())
    return lines


def best_shift(a, b, lo, hi, lim=6):
    best = None
    for s in range(-lim, lim + 1):
        rows = [r for r in range(lo, hi) if lo <= r + s < hi]
        bad = [r for r in rows if a[r + s][6:] != b[r][6:]]
        key = (len(bad) / max(len(rows), 1), abs(s))
        if best is None or key < best[0]:
            best = (key, s, bad)
    return best[1], best[2]


def main():
    path, size = sys.argv[1], sys.argv[2]
    cols, rows = (int(v) for v in size.split("x"))
    opts = dict(a[2:].split("=", 1) for a in sys.argv[3:] if a.startswith("--") and "=" in a)
    t0 = float(opts["from"]) if "from" in opts else None
    t1 = float(opts["to"]) if "to" in opts else None
    fr = frames(path, cols, rows, t0, t1)
    print(f"{len(fr)} sync frames")
    lo, hi = 1, rows - 3  # tmux status (top) and nvim's status/cmd lines
    n = 0
    for i in range(1, len(fr) - 1):
        a, b, c = fr[i - 1][1], fr[i][1], fr[i + 1][1]
        s1, bad1 = best_shift(a, b, lo, hi)
        s2, bad2 = best_shift(b, c, lo, hi)
        s3, bad3 = best_shift(a, c, lo, hi)
        if (bad1 or bad2) and len(bad3) < min(len(bad1), len(bad2)) if (bad1 and bad2) else False:
            n += 1
            print(f"t={fr[i][0]:.4f}  A->B shift {s1} reflow rows {bad1[:8]} | B->C shift {s2} rows {bad2[:8]} | A->C shift {s3} rows {bad3[:8]}")
    print(n, "one-frame states undone by the next frame")
    for d in [float(x) for x in opts.get("dump", "").split(",") if x]:
        k = min(range(len(fr)), key=lambda j: abs(fr[j][0] - d))
        for j in (k - 1, k, k + 1):
            print(f"--- frame t={fr[j][0]:.4f}")
            print("\n".join(f"{y:2d}|{l[:150]}" for y, l in enumerate(fr[j][1])))


if __name__ == "__main__":
    main()
