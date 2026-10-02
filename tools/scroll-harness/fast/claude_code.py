#!/usr/bin/env python3
"""Claude Code (fullscreen renderer) in the test Ghostty: scroll it, trace it, screenshot mid-slide.

    python3 tools/scroll-harness/fast/claude_code.py OUT --session=UUID \
        [--conf-scroll-animation-duration=4000] [--bin=PATH] [--mode=shots|trace]

Claude Code's fullscreen view scrolls by REPAINTING (no scroll commands), so
it exercises the repaint detector: the bullets in column 0 and the pinned
"Jump to bottom (ctrl+End)" label on the last transcript row. `shots` takes a
picture ~0.25 s into each burst (slow the animation to 4 s so it is still
moving) and another once settled, plus `tmux capture-pane` text.

--session must be a THROWAWAY copy of a finished transcript, never a live one:

    cd ~/.claude/projects/-home-liangjunchen && N=$(uuidgen) &&
      cp <old>.jsonl $N.jsonl && sed -i "s/<old>/$N/g" $N.jsonl

`claude --resume` of it makes no API call as long as nothing is typed.
Delete the copy afterwards.
"""
import os, subprocess, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import devices, run  # noqa

SOCK = "smoothharness-cc"
TITLE = "scroll-harness-cc"


def tmux(*a):
    return subprocess.run(["tmux", "-L", SOCK, *a], capture_output=True, text=True).stdout


def shot(p):
    subprocess.run(["spectacle", "-b", "-n", "-f", "-o", str(p)], capture_output=True)


def main():
    out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
    opts = dict(a[2:].split("=", 1) for a in sys.argv[2:] if a.startswith("--") and "=" in a)
    extra = [a for a in sys.argv[2:] if a.startswith("--conf-")]
    binary = Path(opts.get("bin", run.REPO / "zig-out-release/bin/ghostty"))
    mode = opts.get("mode", "shots")
    session = opts["session"]
    rig = run.Rig(binary, out, extra)
    conf = rig._tmux_conf()
    rig.wake_screen()
    tmux("kill-server")
    env = {k: v for k, v in os.environ.items() if not k.startswith(("TMUX", "CLAUDE"))}
    cmd = [str(binary), "--gtk-single-instance=false", "--scroll-trace=true", f"--title={TITLE}", *rig.ghostty_flags(),
           "-e", "tmux", "-L", SOCK, "-f", str(conf), "new-session", "-A", "-s", "h", "-c", str(Path.home()),
           f"claude --resume {session}"]
    logf = open(out / "ghostty.full.log", "w")
    proc = subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT, start_new_session=True, env=env, cwd=Path.home())
    rec = devices.Recorder()
    mouse = None
    try:
        time.sleep(4)
        rig.kwin(f"""
var w = workspace.windowList();
for (var i = 0; i < w.length; i++)
  if (String(w[i].caption).indexOf("{TITLE}") >= 0) {{ workspace.activeWindow = w[i]; w[i].fullScreen = true; }}
""")
        time.sleep(6)
        mouse = devices.Mouse(rec)
        time.sleep(1)
        for _ in range(40):
            mouse.move(-200, -200); time.sleep(0.005)
        for _ in range(60):
            mouse.move(12, 8); time.sleep(0.01)
        time.sleep(0.5)
        (out / "0-pane.txt").write_text(tmux("capture-pane", "-p", "-t", "h"))
        shot(out / "0-still.png")
        # scroll up (towards older output) a few notches, then shots mid-slide
        g0 = (out / "ghostty.full.log").stat().st_size
        if mode == "shots":
            for name, d, n in (("1-up", -1, 3), ("2-up", -1, 3), ("3-down", 1, 3)):
                for _ in range(n * 8):
                    mouse.tick(d); time.sleep(0.004)
                time.sleep(0.25)
                shot(out / f"{name}.png")
                time.sleep(float(opts.get("wait", "4.5")))
                (out / f"{name}-pane.txt").write_text(tmux("capture-pane", "-p", "-t", "h"))
                shot(out / f"{name}-after.png")
        elif mode == "notches":
            # An ordinary wheel mouse: whole notches, one at a time, at the
            # pace of a hand (--gap seconds apart). Each should SLIDE; the
            # analysis is `notches.txt`: per notch, the scroll the renderer
            # animated (or none: it snapped).
            gap = float(opts.get("gap", "0.4"))
            k = 0
            for d in (-1, 1):
                for _ in range(int(opts.get("count", "10"))):
                    # --burst=N: N notches --burst-gap apart, as a hand
                    # flicks the wheel, then the pause.
                    for b in range(int(opts.get("burst", "1"))):
                        if b: time.sleep(float(opts.get("burst-gap", "0.03")))
                        mouse.notch(d)
                    time.sleep(gap)
                    k += 1
                    (out / f"n{k:02d}-pane.txt").write_text(tmux("capture-pane", "-p", "-t", "h"))
                time.sleep(1.0)
        else:
            for name, d in (("up", -1), ("down", 1)):
                times = [time.monotonic() + 0.05 + i / 160 for i in range(8 * 12)]  # 20 notches/s
                for t in times:
                    devices.sleep_until(t); mouse.tick(d)
                time.sleep(1.5)
        logf.flush()
        (out / "scroll.ghostty.log").write_text(run.slice_file(out / "ghostty.full.log", g0))
    finally:
        if mouse:
            mouse.close()
        tmux("kill-server")
        if proc.poll() is None:
            os.killpg(proc.pid, 15)
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, 9)
        subprocess.run(["qdbus-qt6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.unloadScript", "harness"], capture_output=True)
        rig.sleep_screen()
    print(out)


main()
