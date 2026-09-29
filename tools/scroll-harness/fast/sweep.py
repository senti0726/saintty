#!/usr/bin/env python3
"""Hold-j sweep through CH2 in a HIDDEN nvim (detached tmux at the 4K size,
210x55 -- no Ghostty, no screen): press j every --gap seconds, capture the
pane after each press, and flag every press that moved more than one row or
changed rows in place. Uses the user's live nvim config.

    python3 tools/scroll-harness/fast/sweep.py OUT [--from=1] [--to=END] [--gap=0.12] [--key=j]
        [--wheel=down|up] [--burst=1]

`--wheel`: instead of a key, `--burst` wheel events per step through
nvim_input_mouse (the user's mousescroll and scroll.lua apply). A wheel step
may move several rows, so only reflows are flagged, and shifts past 12.
"""
import os, re, subprocess, sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import run, steps  # noqa: E402

S = "sweep"
SOCK = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "sweep-nvim.sock"


def tm(*a):
    return subprocess.run(["tmux", "-L", S, *a], capture_output=True, text=True).stdout


def nv(expr):
    return subprocess.run(["nvim", "--server", str(SOCK), "--remote-expr", expr], capture_output=True, text=True).stdout.strip()


def send(keys):
    subprocess.run(["nvim", "--server", str(SOCK), "--remote-send", keys], capture_output=True)


def main():
    out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
    opts = dict(a[2:].split("=", 1) for a in sys.argv[2:] if a.startswith("--") and "=" in a)
    lo, gap, key = int(opts.get("from", "1")), float(opts.get("gap", "0.12")), opts.get("key", "j")
    wheel = opts.get("wheel")
    if wheel == "up":
        key = "k"
    stub = out / "stub"; stub.mkdir(exist_ok=True)
    (stub / "ghostty-font").write_text("#!/bin/sh\necho stub\n"); (stub / "ghostty-font").chmod(0o755)
    tm("kill-server")
    if SOCK.exists():
        SOCK.unlink()
    env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}
    env["SNACKS_GHOSTTY"] = "true"
    subprocess.run(["tmux", "-L", S, "-f", "/dev/null", "new-session", "-d", "-x", "210", "-y", "55", "-s", "h",
                    f"env PATH={stub}:{os.environ['PATH']} nvim --listen {SOCK} '{run.FILE}'"], env=env)
    for _ in range(60):
        time.sleep(0.25)
        if SOCK.exists() and nv("1") == "1":
            break
    time.sleep(2)
    hi = int(opts.get("to", nv('line("$")')))
    send(f"<Esc>:{lo}<CR>" + ("zb" if key == "j" else "zt"))
    time.sleep(1.5)
    strip = re.compile(r"\x1b\[[0-9;:]*m")
    prev, pv = None, None
    bad = []
    log = open(out / "report.txt", "w")
    n = 0
    try:
        while True:
            if wheel:
                for _ in range(int(opts.get("burst", "1"))):
                    nv(f"luaeval('vim.api.nvim_input_mouse(\"wheel\", \"{wheel}\", \"\", 0, 25, 100)')")
            else:
                send(key)
            time.sleep(gap)
            scr = [strip.sub("", l).rstrip() for l in tm("capture-pane", "-p", "-t", "h").split("\n")]
            v = nv('line(".")." ".line("w0")." ".winsaveview().topfill." ".winsaveview().skipcol')
            if prev is not None:
                h = min(len(prev), len(scr)) - 3
                body = set(range(0, h))
                s, rows = steps.best_shift(prev, scr, body)
                # the cursor's own rows at the bottom change on every press
                rows = [r for r in rows if r < h - 3]
                if (abs(s) > 1 and not wheel) or rows or abs(s) >= 12:
                    line = f"{n:05d} {pv} -> {v} shift={s} reflow={rows[:10]}"
                    bad.append(line); log.write(line + "\n"); log.flush()
                    (out / f"{n:05d}-a.txt").write_text("\n".join(prev))
                    (out / f"{n:05d}-b.txt").write_text("\n".join(scr))
            prev, pv = scr, v
            n += 1
            cur = int(v.split()[0]) if v else 0
            top = int(v.split()[1]) if v else 0
            if (key == "j" and (cur >= hi or (wheel and top >= hi - 40))) or (key == "k" and (cur <= 1 or top <= 1)) or n > 20000:
                break
    finally:
        tm("kill-server")
    print(f"{n} presses, {len(bad)} flagged")
    print("\n".join(bad[:60]))


if __name__ == "__main__":
    main()
