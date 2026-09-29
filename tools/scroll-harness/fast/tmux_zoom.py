#!/usr/bin/env python3
"""tmux zoom/unzoom over 8 panes (2 rows x 4), counting what the renderer
animated. A layout change is not a scroll: nothing should slide.

    python3 tools/scroll-harness/fast/tmux_zoom.py OUT [--bin=PATH]
"""
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run  # noqa: E402

SOCK, TITLE = "zoomtest", "scroll-harness-zoom"
YDO = {**os.environ, "YDOTOOL_SOCKET": "/run/ydotoold/socket"}
FILE = Path.home() / "dev/dotfiles/SETUP-LOG.md"


def tm(*a):
    return subprocess.run(["tmux", "-L", SOCK, *a], capture_output=True, text=True).stdout


def key(*codes):
    subprocess.run(["ydotool", "key", *codes], env=YDO, capture_output=True)


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    opts = dict(a[2:].split("=", 1) for a in sys.argv[2:] if a.startswith("--") and "=" in a)
    binary = opts.get("bin", str(run.REPO / "zig-out-release/bin/ghostty"))
    rig = run.Rig(Path(binary), out, [])
    conf = rig._tmux_conf()
    rig.wake_screen()
    tm("kill-server")
    env = {k: v for k, v in os.environ.items() if not k.startswith("TMUX")}
    pane = f"less +{400} '{FILE}'"
    cmd = [binary, "--gtk-single-instance=false", "--scroll-trace=true", f"--title={TITLE}",
           "-e", "tmux", "-L", SOCK, "-f", str(conf), "new-session", "-A", "-s", "h", pane]
    logf = open(out / "ghostty.full.log", "w")
    proc = subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT, start_new_session=True, env=env)
    try:
        time.sleep(3)
        rig.kwin(f"""var w = workspace.windowList();
for (var i = 0; i < w.length; i++) if (String(w[i].caption).indexOf("{TITLE}") >= 0) {{ workspace.activeWindow = w[i]; w[i].fullScreen = true; }}""")
        time.sleep(2)
        for i in range(7):
            tm("split-window", "-t", "h", f"less +{400 + 60 * (i + 1)} '{FILE}'")
            tm("select-layout", "-t", "h", "tiled")
        time.sleep(2)
        tm("select-pane", "-t", "h.1")
        time.sleep(1)
        g0 = (out / "ghostty.full.log").stat().st_size
        for _ in range(3):
            key("29:1", "30:1", "30:0", "29:0", "44:1", "44:0")  # C-a z: zoom
            time.sleep(1.5)
            key("29:1", "30:1", "30:0", "29:0", "44:1", "44:0")  # C-a z: unzoom
            time.sleep(1.5)
        logf.flush()
        log = run.slice_file(out / "ghostty.full.log", g0)
        (out / "zoom.log").write_text(log)
        # Frames drawn off their model position. Not "scroll event" lines:
        # tmux's unzoom IS a scroll event (the whole region), logged before
        # the renderer declines to animate it.
        n = sum(1 for l in log.splitlines() if "scrolltrace" in l and "off_px=0.000" not in l)
        print(f"frames drawn mid-slide during 3 zoom/unzoom cycles: {n}")
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


if __name__ == "__main__":
    main()
