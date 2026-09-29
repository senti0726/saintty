#!/usr/bin/env python3
"""yazi in $HOME in the test Ghostty (through tmux): walk down with j, trace
the detector, and screenshot mid-slide.

    python3 tools/scroll-harness/fast/yazi.py OUT [--bin=PATH] [--pre=N] \\
        [--dir=PATH] [--presses=12] [--key=j|k] [--gap=0.7] [--shots=3,8,11] \\
        [--conf-scroll-animation-duration=4000]

`--dir` starts yazi there (default $HOME). `summary.txt` lists, per press,
every scroll the renderer animated (event or recovered repaint, with its
rows/cols) and every overlay pin it held.

`--pre=N` j presses first (0.12 s apart) to reach where the list starts to
scroll under a cursor that stays on its row -- the case where the selection
bar detached from its line number (2026-09-28). Then 12 more j, 0.7 s apart,
with shots 0.2 s into presses 3, 8 and 11 (slow the animation to see them),
and `capture-pane` text after each. `keys.log` is the Ghostty log for the 12.
"""

import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run  # noqa: E402

SOCK, TITLE = "yazitest", "scroll-harness-yazi"
YDO = {**os.environ, "YDOTOOL_SOCKET": "/run/ydotoold/socket"}


def tm(*a):
    return subprocess.run(["tmux", "-L", SOCK, *a], capture_output=True, text=True).stdout


def shot(p):
    subprocess.run(["spectacle", "-b", "-n", "-f", "-o", str(p)], capture_output=True)


def key(*codes):
    subprocess.run(["ydotool", "key", *codes], env=YDO, capture_output=True)


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    opts = dict(a[2:].split("=", 1) for a in sys.argv[2:] if a.startswith("--") and "=" in a)
    binary = opts.get("bin", str(run.REPO / "zig-out-release/bin/ghostty"))
    extra = [a for a in sys.argv[2:] if a.startswith("--conf-")]
    rig = run.Rig(Path(binary), out, extra)
    conf = rig._tmux_conf()
    rig.wake_screen()
    tm("kill-server")
    env = {k: v for k, v in os.environ.items() if not k.startswith("TMUX")}
    cmd = [binary, "--gtk-single-instance=false", "--scroll-trace=true", f"--title={TITLE}", *rig.ghostty_flags(),
           "-e", "tmux", "-L", SOCK, "-f", str(conf), "new-session", "-A", "-s", "h", "-c", opts.get("dir", str(Path.home())), "yazi"]
    logf = open(out / "ghostty.full.log", "w")
    proc = subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT, start_new_session=True, env=env)
    try:
        time.sleep(4)
        rig.kwin(f"""var w = workspace.windowList();
for (var i = 0; i < w.length; i++) if (String(w[i].caption).indexOf("{TITLE}") >= 0) {{ workspace.activeWindow = w[i]; w[i].fullScreen = true; }}""")
        time.sleep(3)
        for _ in range(int(opts.get("pre", "44"))):
            key("36:1", "36:0")
            time.sleep(0.12)
        time.sleep(5)
        g0 = (out / "ghostty.full.log").stat().st_size
        code = {"j": "36", "k": "37"}[opts.get("key", "j")]
        shots = {int(x) for x in opts.get("shots", "3,8,11").split(",") if x}
        summary = []
        for n in range(int(opts.get("presses", "12"))):
            logf.flush()
            a = (out / "ghostty.full.log").stat().st_size
            key(f"{code}:1", f"{code}:0")
            at = float(opts.get("shot-at", "0.2"))
            gap = float(opts.get("gap", "0.7"))
            if n in shots:
                time.sleep(at)
                shot(out / f"j{n}.png")
                time.sleep(4.5 if extra else max(0.0, gap - at))
            else:
                time.sleep(gap)
            (out / f"j{n}.txt").write_text(tm("capture-pane", "-p", "-t", "h"))
            logf.flush()
            seg = run.slice_file(out / "ghostty.full.log", a)
            hits = [l.split("): ", 1)[-1] for l in seg.splitlines() if "scroll event" in l or "repaintscroll" in l or "scrollpin" in l]
            summary.append(f"press {n}: " + (" | ".join(hits) or "-"))
        logf.flush()
        (out / "keys.log").write_text(run.slice_file(out / "ghostty.full.log", g0))
        (out / "summary.txt").write_text("\n".join(summary) + "\n")
        print("\n".join(summary))
    finally:
        tm("kill-server")
        if proc.poll() is None:
            os.killpg(proc.pid, 15)
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, 9)
        subprocess.run(["qdbus-qt6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.unloadScript", "harness"],
                       capture_output=True)
        rig.sleep_screen()
    print(out)


if __name__ == "__main__":
    main()
