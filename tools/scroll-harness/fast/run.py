#!/usr/bin/env python3
"""Fast-scroll smoothness harness: real devices, real Ghostty, real tmux + nvim.

    python3 tools/scroll-harness/fast/run.py [scenario ...] [--bin=PATH] [--out=DIR]

Launches the fork fullscreen with --scroll-trace, running the user's tmux
config (minus TPM, see below) on a private server, running the user's nvim on
a long markdown file. Each scenario resets nvim to a fixed line, drives one
gesture through virtual uinput devices (devices.py) or ydotool, and saves:

    <out>/<scenario>.ghostty.log   Ghostty's lines for that window of time
    <out>/<scenario>.nvim.log      nvim WinScrolled: mono_us topline topfill skipcol
    <out>/<scenario>.input.log     what was sent: mono_us kind value

analyse.py turns those into a report. All three are on CLOCK_MONOTONIC.

Blast radius, all paid for before:
  * ydotool has no targeting: the window is focused through KWin and a probe
    `j` must be SEEN to move nvim's cursor before any held key is sent.
  * TPM is stripped from the tmux config: tmux-continuum on a second server
    would restore the user's saved sessions into it, or autosave the test
    session over the user's snapshot.
  * reading mode shells out to gt font, which reloads every Ghostty; a
    stub is put first in nvim's PATH.
  * Everything is cleaned up by PID or by the private tmux socket, never by
    `pkill -f`.
"""

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import devices  # noqa: E402
import scenarios  # noqa: E402

REPO = HERE.parents[2]
FILE = Path.home() / "notes/obsidian-cpp/Study Resources/booksInMarkdown/CSAPP/Chapter 2 Representing and Manipulating Information.md"
TITLE = "scroll-harness-fast"
SOCK_NAME = "smoothharness"
CLASS = "com.claude.scrollharness"
# Hyprland or KWin: the window is placed, focused and the screen woken through
# whichever compositor is running.
HYPR = bool(os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"))
YDO = {"YDOTOOL_SOCKET": "/run/ydotoold/socket"}


def sh(*a, **kw):
    return subprocess.run(a, capture_output=True, text=True, **kw)


class Rig:
    def __init__(self, binary: Path, out: Path, extra=()):
        self.bin, self.out, self.extra = binary, out, list(extra)
        out.mkdir(parents=True, exist_ok=True)
        self.work = out / "work"
        self.work.mkdir(exist_ok=True)
        # A unix socket path must fit in 108 bytes; the scratch dirs this runs
        # in are longer than that, and nvim then silently never listens.
        self.sock = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / f"{SOCK_NAME}-nvim.sock"
        self.log = out / "ghostty.full.log"
        self.nvlog = self.work / "nvim-scroll.log"
        self.proc = None

    # ---- setup -------------------------------------------------------------
    def _tmux_conf(self) -> Path:
        src = (Path.home() / ".config/tmux/tmux.conf").read_text().splitlines()
        keep = [l for l in src if "tpm/tpm" not in l and "@continuum" not in l and "@resurrect" not in l]
        p = self.work / "tmux.conf"
        p.write_text("\n".join(keep) + "\n")
        return p

    def _stub(self) -> Path:
        d = self.work / "stub"
        d.mkdir(exist_ok=True)
        f = d / "gt"
        f.write_text('#!/bin/sh\necho "stub $*"\n')
        f.chmod(0o755)
        return d

    def _ghostty_conf(self, overrides: list[str]) -> Path:
        """The user's Ghostty config with `scroll-state.conf` left out and
        `overrides` appended. A flag on the command line loses to that
        include (includes load after flags), so a setting it carries --
        `scroll-animation-duration` -- cannot be changed any other way without
        touching the user's live file."""
        d = Path.home() / ".config/ghostty"
        out = []
        for line in (d / "config").read_text().splitlines():
            k = line.split("=", 1)
            if len(k) == 2 and k[0].strip() == "config-file":
                name = k[1].strip()
                if "scroll-state.conf" in name:
                    continue
                opt = name.startswith("?")
                name = name.lstrip("?")
                line = f"config-file = {'?' if opt else ''}{d / name}"
            out.append(line)
        out += overrides
        p = self.work / "ghostty.conf"
        p.write_text("\n".join(out) + "\n")
        return p

    def _hypr_dpms(self) -> bool:
        import json
        mons = json.loads(sh("hyprctl", "monitors", "-j").stdout or "[]")
        return all(m.get("dpmsStatus", True) for m in mons)

    def wake_screen(self):
        if HYPR:
            # hypridle honours systemd idle inhibitors.
            self.inhibit = subprocess.Popen(
                ["systemd-inhibit", "--what=idle", "--who=scroll-harness", "--why=test run", "sleep", "7200"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
            )
            self.woke = not self._hypr_dpms()
            if self.woke:
                print("screen was asleep: waking it for the run")
                sh("hyprctl", "dispatch", 'hl.dsp.dpms({ action = "on" })')
                time.sleep(2)
            return
        self._wake_screen_kde()

    def _wake_screen_kde(self):
        """A screen that has gone to sleep stops Ghostty drawing at all (no
        frame callbacks), and every run then fails as "nvim never came up".
        Wake it, and remember to put it back: stop() does, via powerdevil's
        own "Turn Off Screen" action -- `kscreen-doctor --dpms off` was
        measured not to take."""
        # Hold the screen on for the whole run: the user's power profile turns
        # it off after 15 minutes idle, and virtual-device input does not
        # always count as activity -- a long suite went dark part-way.
        self.inhibit = subprocess.Popen(
            ["kde-inhibit", "--power", "--screenSaver", "sleep", "7200"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
        )
        state = sh("kscreen-doctor", "--dpms", "show", timeout=10).stdout
        self.woke = ": off" in state
        if self.woke:
            print("screen was asleep: waking it for the run")
            # Right after powerdevil turned it off (the previous run's
            # stop()), a wake is ignored for a moment: measured, every run
            # started straight after another failed as "nvim never came up".
            for _ in range(20):
                sh("kscreen-doctor", "--dpms", "on", timeout=10)
                time.sleep(1)
                if ": on" in sh("kscreen-doctor", "--dpms", "show", timeout=10).stdout:
                    break
            else:
                raise SystemExit("could not wake the screen")
            time.sleep(1)

    def sleep_screen(self):
        inh = getattr(self, "inhibit", None)
        if inh and inh.poll() is None:
            os.killpg(inh.pid, signal.SIGTERM)
        if getattr(self, "woke", False) and HYPR:
            sh("hyprctl", "dispatch", 'hl.dsp.dpms({ action = "off" })')
            print("screen put back to sleep")
            return
        if getattr(self, "woke", False):
            time.sleep(1)  # the devices closing counts as activity
            sh("qdbus-qt6", "org.kde.kglobalaccel", "/component/org_kde_powerdevil",
               "org.kde.kglobalaccel.Component.invokeShortcut", "Turn Off Screen")
            # The action lands a moment later. Returning before it does let
            # the NEXT run see the screen on, start, and then go dark under
            # it -- measured, every second run of a back-to-back pair.
            for _ in range(20):
                time.sleep(0.5)
                if ": off" in sh("kscreen-doctor", "--dpms", "show", timeout=10).stdout:
                    print("screen put back to sleep")
                    break
            else:
                print("screen did not go back to sleep; it will on the idle timeout")

    def start(self):
        self.wake_screen()
        if HYPR:
            import json
            self.prev_ws = json.loads(sh("hyprctl", "activeworkspace", "-j").stdout)["id"]
            # Its own workspace, fullscreen, so the user's windows are left
            # where they are and come back with one focus on stop().
            cls = CLASS.replace(".", "\\\\.")
            sh("hyprctl", "eval", f'hl.window_rule({{ name = "scroll-harness", match = {{ class = "^{cls}$" }}, workspace = "9", fullscreen = true }})')
        if self.sock.exists():
            self.sock.unlink()
        sh("tmux", "-L", SOCK_NAME, "kill-server")
        conf, stub = self._tmux_conf(), self._stub()
        inner = f"env PATH={stub}:{os.environ['PATH']} nvim --listen {self.sock} '{FILE}'"
        cmd = [
            str(self.bin), "--gtk-single-instance=false", "--scroll-trace=true",
            f"--title={TITLE}", f"--class={CLASS}",
            *self.ghostty_flags(),
            "-e", "tmux", "-L", SOCK_NAME, "-f", str(conf), "new-session", "-A", "-s", "h", inner,
        ]
        self.logf = open(self.log, "w")
        # This harness is usually driven from inside the user's tmux; a
        # tmux started with $TMUX set refuses to nest and exits at once.
        env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}
        self.proc = subprocess.Popen(cmd, stdout=self.logf, stderr=subprocess.STDOUT, start_new_session=True, env=env)
        for _ in range(60):
            time.sleep(0.25)
            if self.sock.exists() and self.nv("1") == "1":
                break
        else:
            raise SystemExit("nvim never came up")
        if HYPR:
            self.focus()
        else:
            self.kwin(f"""
var w = workspace.windowList();
for (var i = 0; i < w.length; i++)
  if (String(w[i].caption).indexOf("{TITLE}") >= 0) {{ workspace.activeWindow = w[i]; w[i].fullScreen = true; }}
""")
        time.sleep(1.5)
        hook = self.work / "hook.lua"
        hook.write_text(
            f"""
local f = assert(io.open("{self.nvlog}", "a"))
vim.api.nvim_create_autocmd("WinScrolled", {{ callback = function()
  local v = vim.fn.winsaveview()
  f:write(string.format("%d %d %d %d\\n", math.floor(vim.uv.hrtime() / 1000), v.topline, v.topfill, v.skipcol))
  f:flush()
end }})
return 1
"""
        )
        if self.nv(f"luaeval('dofile(\"{hook}\")')") != "1":
            raise SystemExit("could not install the nvim scroll hook")

    def ghostty_flags(self):
        # --conf-KEY=VALUE: goes into a private copy of the user's config (see
        # _ghostty_conf), for keys the scroll-state.conf include would win.
        conf = [a[len("--conf-"):].replace("=", " = ", 1) for a in self.extra if a.startswith("--conf-")]
        flags = [a for a in self.extra if not a.startswith("--conf-")]
        if conf:
            flags = ["--config-default-files=false", f"--config-file={self._ghostty_conf(conf)}"] + flags
        return flags

    def kwin(self, js: str):
        if HYPR:
            return
        f = self.work / "kwin.js"
        f.write_text(js)
        sh("qdbus-qt6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.unloadScript", "harness")
        sh("qdbus-qt6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.loadScript", str(f), "harness")
        sh("qdbus-qt6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.start")

    def focus(self):
        if HYPR:
            cls = CLASS.replace(".", "\\\\.")
            sh("hyprctl", "dispatch", f'hl.dsp.focus({{ window = "class:^{cls}$" }})')
            time.sleep(0.4)
            return
        self.kwin(f"""
var w = workspace.windowList();
for (var i = 0; i < w.length; i++)
  if (String(w[i].caption).indexOf("{TITLE}") >= 0) workspace.activeWindow = w[i];
""")
        time.sleep(0.4)

    # ---- nvim --------------------------------------------------------------
    def nv(self, expr: str) -> str:
        return sh("nvim", "--server", str(self.sock), "--remote-expr", expr, timeout=10).stdout.strip()

    def nv_lua(self, code: str) -> str:
        return self.nv("luaeval('" + code.replace("\\", "\\\\").replace("'", "''") + "')")

    def reset(self, line: int, bottom=False):
        """Top of the window at `line`; cursor on the top row, or on the
        bottom row for key scenarios (so j scrolls from the first press)."""
        # zb, not zt+L: `L` stops `scrolloff` rows short and, with wrapped
        # lines, lands the cursor mid-screen -- measured, holding j then spent
        # 2.7 s walking the cursor down before anything scrolled.
        sh("nvim", "--server", str(self.sock), "--remote-send", f"<Esc>:{line}<CR>" + ("zb" if bottom else "zt"))
        time.sleep(1.2)

    def view(self) -> str:
        return self.nv('join(values(winsaveview()), ",")')

    def probe_keys(self) -> bool:
        """Is a key we send going to reach THIS nvim? Moves the cursor once."""
        self.focus()
        before = self.view()
        sh("ydotool", "key", "36:1", "36:0", env={**os.environ, **YDO})
        time.sleep(0.5)
        return self.view() != before

    def park_pointer(self, mouse, tries=3):
        """Retry: right after the screen wakes the first attempt sometimes
        lands nowhere (getmousepos stays at row 1, col 1)."""
        for i in range(tries):
            try:
                return self._park_pointer(mouse)
            except SystemExit as e:
                if i == tries - 1:
                    raise
                print(f"{e}; retrying")
                time.sleep(1.0)

    def _park_pointer(self, mouse):
        """Put the pointer over the middle of the text and prove it is there.

        Ghostty reports a wheel event at the last pointer position it saw, and
        drops it if it never saw one -- a window that appears under a pointer
        that has not moved gets NO wheel input at all (measured: 24 events,
        zero scroll). Also keeps it off tmux's status line, where the wheel
        switches windows instead of scrolling."""
        for _ in range(40):  # into the top-left corner; the screen edge clamps
            mouse.move(-200, -200)
            time.sleep(0.005)
        for _ in range(60):  # then slowly out, so acceleration stays small
            mouse.move(12, 4)
            time.sleep(0.01)
        time.sleep(0.3)
        import ast
        lines = int(self.nv("&lines") or 0)
        row, pos = -1, ""
        # One wheel notch each way; nvim records where it happened. How far
        # the moves above land depends on the display scale (2 -> 2.25 put
        # the pointer on the status line), so nudge until it is mid-screen.
        for _attempt in range(8):
            for d in (1, -1):
                for _ in range(8):
                    mouse.tick(d)
                    time.sleep(0.004)
                time.sleep(0.3)
            pos = self.nv('string(getmousepos())')
            try:
                row = ast.literal_eval(pos)["screenrow"]
            except Exception:
                row = -1
            if 3 <= row <= lines - 4:
                break
            dy = -6 if row > lines // 2 or row < 0 else 6
            for _ in range(30):
                mouse.move(0, dy)
                time.sleep(0.01)
            time.sleep(0.2)
        if not (3 <= row <= lines - 4):
            raise SystemExit(f"pointer not over the text (getmousepos={pos}, lines={lines})")
        print(f"pointer parked at screen row {row}/{lines}")

    # ---- teardown ----------------------------------------------------------
    def stop(self):
        sh("tmux", "-L", SOCK_NAME, "kill-server")
        if self.proc and self.proc.poll() is None:
            os.killpg(self.proc.pid, signal.SIGTERM)
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
        if HYPR:
            if getattr(self, "prev_ws", None) is not None:
                sh("hyprctl", "dispatch", f"hl.dsp.focus({{ workspace = {self.prev_ws} }})")
        else:
            sh("qdbus-qt6", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.unloadScript", "harness")
        self.sleep_screen()


def slice_file(path: Path, start: int) -> str:
    with open(path, errors="replace") as f:
        f.seek(start)
        return f.read()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    binary = Path(opts.get("bin", REPO / "zig-out-release" / "bin" / "ghostty"))
    out = Path(opts.get("out", Path.home() / "playground" / "fast-scroll" / time.strftime("%Y%m%d-%H%M%S")))
    names = args or list(scenarios.ALL)

    # Any other --scroll-*=... is passed to Ghostty, e.g. --scroll-animation-easing=spring.
    # (A flag only wins where no config-file include sets the same key.)
    extra = [a for a in sys.argv[1:] if a.startswith("--scroll-") or a.startswith("--conf-")]
    rig = Rig(binary, out, extra)
    (out / "flags.txt").write_text(" ".join(extra) + "\n")
    rec = devices.Recorder()
    mouse = pad = None
    try:
        rig.start()
        mouse, pad = devices.Mouse(rec), devices.Touchpad(rec)
        time.sleep(1.0)  # let libinput/KWin adopt the new devices
        rig.park_pointer(mouse)
        for name in names:
            # `<scenario>+<variant>`: the same gesture after scenarios.VARIANTS[variant].
            base, _, variant = name.partition("+")
            sc = scenarios.ALL[base]
            if sc.lua:
                rig.nv_lua(sc.lua)
            if variant:
                rig.nv_lua(scenarios.VARIANTS[variant])
            rig.reset(sc.line)
            if sc.keys and not rig.probe_keys():
                print(f"{name}: PROBE FAILED -- keys are not reaching the test nvim; skipped")
                continue
            if sc.keys:
                rig.reset(sc.line, bottom=not sc.top)
                rig.focus()
            g0, n0 = rig.log.stat().st_size, (rig.nvlog.stat().st_size if rig.nvlog.exists() else 0)
            rec.events.clear()
            rec.mark("start")
            sc.run(mouse=mouse, pad=pad, rec=rec)
            rec.mark("end")
            time.sleep(sc.settle)
            rig.logf.flush()
            (out / f"{name}.ghostty.log").write_text(slice_file(rig.log, g0))
            (out / f"{name}.nvim.log").write_text(slice_file(rig.nvlog, n0) if rig.nvlog.exists() else "")
            (out / f"{name}.input.log").write_text("".join(f"{t} {k} {v}\n" for t, k, v in rec.events))
            print(f"{name}: recorded ({len(rec.events)} input events)")
    finally:
        for d in (mouse, pad):
            if d:
                d.close()
        rig.stop()
    print(out)


if __name__ == "__main__":
    main()
