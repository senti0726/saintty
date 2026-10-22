#!/usr/bin/env python3
"""lat.py, but through the user's REAL stack instead of a fresh harness one.

    python3 tools/scroll-harness/fast/realstack.py [--arms=real-tmux,real-bare] [--tests=taps,hold_j,hold_k,ctrl_d]

run.py always starts a NEW Ghostty process with a stripped tmux, so it cannot
see anything that builds up in a long-lived Ghostty (hours of surfaces, swap,
shader caches) or comes from the user's own tmux server (status jobs, hooks,
plugins). Arms:
  real-tmux  window in the running Ghostty (+new-window) -> user's tmux server
             (a throwaway session) -> nvim
  real-bare  window in the running Ghostty -> nvim, no tmux
Same file, lines, strip and metrics as lat.py, so numbers compare directly.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import lat  # noqa: E402
import run  # noqa: E402
import scenarios  # noqa: E402
import devices  # noqa: E402

TITLE = "realstack-lagtest"
SESSION = "realstack-lagtest"
SOCK = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "realstack-nvim.sock"
GHOSTTY = Path.home() / "tools/ghostty/bin/ghostty"
TESTS = {name: (fn, top) for name, fn, top in lat.TESTS}


def sh(*a, **kw):
    return subprocess.run(a, capture_output=True, text=True, **kw)


class RealRig(run.Rig):
    """Only the bits of Rig that touch nvim/focus, pointed at a window inside
    the user's running Ghostty."""

    def __init__(self, arm, out):
        self.arm, self.work = arm, out
        out.mkdir(parents=True, exist_ok=True)
        self.sock = SOCK
        self.nvlog = out / f"{arm}-nvim-scroll.log"

    def start(self):
        self.prev_ws = json.loads(sh("hyprctl", "activeworkspace", "-j").stdout)["id"]
        sh("hyprctl", "eval", f'hl.window_rule({{ name = "realstack", match = {{ title = "^{TITLE}$" }}, workspace = "9", fullscreen = true }})')
        if SOCK.exists():
            SOCK.unlink()
        nvim = f"nvim --listen {SOCK} '{run.FILE}'"
        if self.arm == "real-tmux":
            sh("tmux", "kill-session", "-t", SESSION)
            sh("tmux", "new-session", "-d", "-s", SESSION, nvim)
            inner = ["tmux", "attach", "-t", SESSION]
        else:
            inner = ["sh", "-c", nvim]
        env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}
        # +new-window hands the window to the RUNNING instance over D-Bus.
        r = sh(str(GHOSTTY), "+new-window", f"--title={TITLE}", "-e", *inner, env=env)
        if r.returncode:
            raise SystemExit(f"+new-window failed: {r.stderr}")
        for _ in range(60):
            time.sleep(0.25)
            if SOCK.exists() and self.nv("1") == "1":
                break
        else:
            raise SystemExit("nvim never came up")
        pid = self.window()["pid"]
        print(f"{self.arm}: window pid {pid}", flush=True)
        self.focus()
        time.sleep(1.5)
        hook = self.work / "hook.lua"
        hook.write_text(f"""
local f = assert(io.open("{self.nvlog}", "a"))
vim.api.nvim_create_autocmd("WinScrolled", {{ callback = function()
  f:write(string.format("%d\\n", math.floor(vim.uv.hrtime() / 1000)))
  f:flush()
end }})
return 1
""")
        if self.nv(f"luaeval('dofile(\"{hook}\")')") != "1":
            raise SystemExit("could not install the nvim scroll hook")

    def window(self):
        for c in json.loads(sh("hyprctl", "clients", "-j").stdout):
            if c["title"] == TITLE:
                return c
        raise SystemExit("test window not found")

    def focus(self):
        sh("hyprctl", "dispatch", f'hl.dsp.focus({{ window = "title:^{TITLE}$" }})')
        time.sleep(0.4)

    def stop(self):
        try:
            self.nv("execute('qa!')")
        except Exception:
            pass
        time.sleep(0.5)
        sh("tmux", "kill-session", "-t", SESSION)
        sh("hyprctl", "dispatch", f"hl.dsp.focus({{ workspace = {self.prev_ws} }})")


def main():
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    out = Path(opts.get("out", Path.home() / "playground/fast-scroll" / time.strftime("%Y%m%d-%H%M%S-real")))
    arms = opts.get("arms", "real-tmux,real-bare").split(",")
    tests = opts.get("tests", "taps,hold_j,hold_k,ctrl_d").split(",")
    wake = run.Rig.__new__(run.Rig)  # only for wake_screen/sleep_screen
    wake.extra = []
    wake.wake_screen()
    rec = devices.Recorder()
    report = {}
    try:
        for arm in arms:
            rig = RealRig(arm, out)
            rig.start()
            try:
                for name in tests:
                    fn, top = TESTS[name]
                    rig.reset(1500 if not top else 1700, bottom=not top)
                    if not rig.probe_keys():
                        print(f"{arm} {name}: PROBE FAILED", flush=True)
                        continue
                    rig.reset(1500 if not top else 1700, bottom=not top)
                    rig.focus()
                    n0 = rig.nvlog.stat().st_size if rig.nvlog.exists() else 0
                    film = lat.Film()
                    time.sleep(0.6)
                    rec.events.clear()
                    rec.mark("start")
                    fn(rec=rec)
                    rec.mark("end")
                    time.sleep(1.5)
                    film.stop()
                    nv = [int(l.split()[0]) for l in run.slice_file(rig.nvlog, n0).splitlines() if l.strip()]
                    tr = lat.track(film.frames)
                    r = lat.summarise(name, tr, rec.events, nv)
                    report[f"{arm}:{name}"] = r
                    (out / f"{arm}-{name}.track.txt").write_text("".join(f"{t:.4f} {p}\n" for t, p in tr))
                    (out / f"{arm}-{name}.input.log").write_text("".join(f"{t} {k} {v}\n" for t, k, v in rec.events))
                    print(f"{arm} {name}: {json.dumps(r)}", flush=True)
            finally:
                rig.stop()
    finally:
        wake.sleep_screen()
    (out / "report.json").write_text(json.dumps(report, indent=1))
    print(out)


if __name__ == "__main__":
    main()
