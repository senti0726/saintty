#!/usr/bin/env python3
"""Look at a scroll mid-flight: are the ghost rows drawn where they belong?

    python3 tools/scroll-harness/fast/visual.py [--out=DIR] [--notches=N] [--bin=PATH]

The numbers from analyse.py say where the content WAS drawn, not what it
looked like. Ghost rows (rows kept after they scrolled out of the region, to
fill the band a lagging offset uncovers) are new drawing, and only a picture
can show they land in the right place. Screen recording cannot be driven from
a script here (spectacle's recorder needs its GUI to stop), so the animation
is slowed to 4 s instead and ordinary screenshots catch it part-way.

Takes: a still before, one ~0.3 s into a burst down, one into a burst up.
The trace offset at each shot is printed, so a picture of "no band" can be
told apart from a picture taken after the animation already finished.
"""

import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import devices  # noqa: E402
import run  # noqa: E402


def shot(path: Path):
    subprocess.run(["spectacle", "-b", "-n", "-f", "-o", str(path)], capture_output=True)


def last_offset(log: Path) -> str:
    lines = [l for l in log.read_text(errors="replace").splitlines() if "scrolltrace" in l]
    return re.sub(r".*(model_rows=\S+ off_px=\S+).*", r"\1", lines[-1]) if lines else "?"


def main():
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    out = Path(opts.get("out", Path.home() / "playground" / "fast-scroll" / ("visual-" + time.strftime("%H%M%S"))))
    notches = int(opts.get("notches", "3"))
    rig = run.Rig(
        Path(opts.get("bin", run.REPO / "zig-out-release" / "bin" / "ghostty")),
        out,
        ["--conf-scroll-animation-duration=4000", "--conf-scroll-animation-easing=spring"],
    )
    rec = devices.Recorder()
    mouse = None
    try:
        rig.start()
        mouse = devices.Mouse(rec)
        time.sleep(1.0)
        rig.park_pointer(mouse)
        rig.reset(300)
        time.sleep(4.5)  # let the parking scroll's 4 s animation finish
        shot(out / "0-still.png")
        for name, d in (("1-down", 1), ("2-up", -1)):
            for _ in range(notches * 8):
                mouse.tick(d)
                time.sleep(0.004)
            time.sleep(0.15)
            print(f"{name}: at shot {last_offset(rig.log)}")
            shot(out / f"{name}.png")
            print(f"{name}: after shot {last_offset(rig.log)}")
            time.sleep(4.5)
            shot(out / f"{name}-settled.png")  # the same view at rest, to compare
    finally:
        if mouse:
            mouse.close()
        rig.stop()
    print(out)


if __name__ == "__main__":
    main()
