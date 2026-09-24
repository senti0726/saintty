"""The gestures. Each is a slow baseline or a fast case the user reported.

Every scenario starts nvim at a fixed line (so runs are comparable) and scrolls
DOWN through CSAPP chapter 2: prose, wrapped lines, tables, figures, maths.
"""

import math
import os
import subprocess
import time

from devices import sleep_until

YDO = {**os.environ, "YDOTOOL_SOCKET": "/run/ydotoold/socket"}
J = 36  # KEY_J


class Scenario:
    def __init__(self, fn, line=300, settle=2.0, keys=False, doc=""):
        self.fn, self.line, self.settle, self.keys, self.doc = fn, line, settle, keys, doc

    def run(self, **kw):
        self.fn(**kw)


def key(code, down):
    subprocess.run(["ydotool", "key", f"{code}:{1 if down else 0}"], env=YDO, capture_output=True)


# ---- keyboard ---------------------------------------------------------------
def j_spam(rec, **_):
    """Tapping j about 8 times a second -- the 'slow is fine' baseline."""
    t0 = time.monotonic()
    for i in range(24):
        sleep_until(t0 + i * 0.125)
        key(J, True)
        rec.mark("key", 1)
        time.sleep(0.03)
        key(J, False)


def hold_j(rec, **_):
    """Hold j for 4 s; the compositor's key repeat does the rest."""
    key(J, True)
    rec.mark("key_down", 1)
    time.sleep(4.0)
    key(J, False)
    rec.mark("key_up", 0)


# ---- wheel (MX Anywhere 3S-like, 1/8-notch hi-res steps) -------------------
def _wheel(mouse, rate_of_t, duration):
    """rate_of_t(t) in notches/s; integrates to 1/8-notch step times."""
    times, t, acc, dt = [], 0.0, 0.0, 0.0005
    start = time.monotonic() + 0.05
    while t < duration:
        acc += rate_of_t(t) * 8 * dt
        while acc >= 1:
            times.append(start + t)
            acc -= 1
        t += dt
    mouse.notches(times)


def wheel_slow(mouse, **_):
    """4 notches/s ratcheting for 3 s -- baseline."""
    _wheel(mouse, lambda t: 4, 3.0)


def wheel_fast(mouse, **_):
    """20 notches/s ratcheting for 2 s -- a quick deliberate spin."""
    _wheel(mouse, lambda t: 20, 2.0)


def wheel_flick(mouse, **_):
    """Free-spin flick: 80 notches/s decaying (time constant 0.7 s) over 3 s."""
    _wheel(mouse, lambda t: 80 * math.exp(-t / 0.7), 3.0)


# ---- touchpad (two-finger) -------------------------------------------------
def tp_slow(pad, **_):
    """Reading drag: 15 mm/s for 3 s."""
    pad.stroke(lambda t: 15 * t, 3.0)


def tp_fast(pad, **_):
    """Fast drag: 60 mm in 0.4 s, fingers stay down to the end then lift."""
    pad.stroke(lambda t: 150 * t, 0.4)


def tp_flick(pad, **_):
    """Flick: 50 mm in 0.12 s (eased), lift while moving -> momentum."""
    pad.stroke(lambda t: 50 * (t / 0.12) ** 0.8, 0.12)


def tp_repeat(pad, **_):
    """Three quick drags in a row, like paging through with the touchpad."""
    for _ in range(3):
        pad.stroke(lambda t: 55 * min(1, t / 0.25) ** 0.7, 0.25)
        time.sleep(0.15)


ALL = {
    "j_spam": Scenario(j_spam, keys=True),
    "hold_j": Scenario(hold_j, keys=True, settle=2.5),
    "wheel_slow": Scenario(wheel_slow),
    "wheel_fast": Scenario(wheel_fast),
    "wheel_flick": Scenario(wheel_flick, settle=3.0),
    "tp_slow": Scenario(tp_slow),
    "tp_fast": Scenario(tp_fast, settle=3.0),
    "tp_flick": Scenario(tp_flick, settle=4.0),
    "tp_repeat": Scenario(tp_repeat, settle=3.0),
}
