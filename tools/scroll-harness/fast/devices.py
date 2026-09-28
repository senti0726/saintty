"""Virtual input devices that go through the whole real input path.

A uinput device is picked up by udev -> libinput -> KWin -> the focused/hovered
Wayland client exactly like hardware, so everything between the finger and the
terminal (libinput's touchpad scroll, acceleration, the compositor, GTK's
scroll/kinetic handling, Ghostty's multiplier and momentum) is exercised. That
is the point: `tmux send-keys` never reaches Ghostty at all, and ydotool's
device has no working wheel here (EV_ABS-less keyboard-class device).

/dev/uinput is writable by the desktop user on this machine (ACL), so no root.

Every emitted event is recorded as (CLOCK_MONOTONIC us, kind, value) so the
analyser can line input up against Ghostty's `mono_us` trace fields.
"""

import time

from evdev import AbsInfo, UInput
from evdev import ecodes as e

now_us = lambda: time.monotonic_ns() // 1000


def sleep_until(t_s: float) -> None:
    """Sleep to an absolute monotonic deadline, busy-waiting the last ms.

    time.sleep alone overshoots by 50-100 us per call, which at 1 kHz wheel
    rates is a 10% rate error -- enough to fake a stutter."""
    while True:
        left = t_s - time.monotonic()
        if left <= 0:
            return
        if left > 0.002:
            time.sleep(left - 0.0015)


class Recorder:
    def __init__(self):
        self.events = []  # (mono_us, kind, value)

    def mark(self, kind, value=0.0):
        self.events.append((now_us(), kind, value))


class Mouse:
    """A wheel mouse with a high-resolution wheel, like the MX Anywhere 3S.

    Logitech hi-res wheels report REL_WHEEL_HI_RES in 1/8 notches (15 of the
    kernel's 120 units per notch) and REL_WHEEL once per whole notch; libinput
    uses the hi-res stream when it is present."""

    HIRES_STEP = 15  # 120 / 8

    def __init__(self, rec: Recorder):
        self.rec = rec
        self.ui = UInput(
            {
                e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE],
                e.EV_REL: [e.REL_X, e.REL_Y, e.REL_WHEEL, e.REL_WHEEL_HI_RES],
            },
            name="scroll-harness mouse",
            vendor=0x046D,
            product=0xB034,
        )
        self.acc = 0

    def close(self):
        self.ui.close()

    def move(self, dx, dy):
        self.ui.write(e.EV_REL, e.REL_X, dx)
        self.ui.write(e.EV_REL, e.REL_Y, dy)
        self.ui.syn()

    def tick(self, direction: int):
        """One 1/8-notch hi-res step. direction +1 = content moves down (the
        wheel rolled towards you), which is a negative wheel value."""
        v = -direction * self.HIRES_STEP
        self.ui.write(e.EV_REL, e.REL_WHEEL_HI_RES, v)
        self.acc += v
        if abs(self.acc) >= 120:
            self.ui.write(e.EV_REL, e.REL_WHEEL, -direction)
            self.acc -= -direction * 120
        self.ui.syn()
        self.rec.mark("wheel", direction / 8)

    def notches(self, schedule, direction=1):
        """schedule: iterable of absolute monotonic times (s), one 1/8 step each.
        direction -1 scrolls back up."""
        for t in schedule:
            sleep_until(t)
            self.tick(direction)


class Touchpad:
    """A clickpad shaped like this laptop's (ASCP1209, 149 x 97 mm)."""

    W_MM, H_MM, RES = 149, 97, 12  # units per mm

    def __init__(self, rec: Recorder):
        self.rec = rec
        xmax, ymax = self.W_MM * self.RES, self.H_MM * self.RES
        self.xmax, self.ymax = xmax, ymax
        absx = AbsInfo(0, 0, xmax, 0, 0, self.RES)
        absy = AbsInfo(0, 0, ymax, 0, 0, self.RES)
        self.ui = UInput(
            {
                e.EV_KEY: [e.BTN_LEFT, e.BTN_TOUCH, e.BTN_TOOL_FINGER, e.BTN_TOOL_DOUBLETAP, e.BTN_TOOL_TRIPLETAP],
                e.EV_ABS: [
                    (e.ABS_X, absx),
                    (e.ABS_Y, absy),
                    (e.ABS_MT_SLOT, AbsInfo(0, 0, 4, 0, 0, 0)),
                    (e.ABS_MT_POSITION_X, absx),
                    (e.ABS_MT_POSITION_Y, absy),
                    (e.ABS_MT_TRACKING_ID, AbsInfo(0, 0, 65535, 0, 0, 0)),
                ],
                e.EV_MSC: [e.MSC_TIMESTAMP],
            },
            name="scroll-harness touchpad",
            vendor=0x093A,
            product=0x3024,
            input_props=[e.INPUT_PROP_POINTER, e.INPUT_PROP_BUTTONPAD],
        )
        self.tid = 100
        self.t0 = time.monotonic()

    def close(self):
        self.ui.close()

    def _frame(self, fingers):
        """fingers: list of (x, y) in device units, or [] to lift all."""
        w = self.ui.write
        for slot in range(2):
            w(e.EV_ABS, e.ABS_MT_SLOT, slot)
            if slot < len(fingers):
                x, y = fingers[slot]
                w(e.EV_ABS, e.ABS_MT_POSITION_X, int(x))
                w(e.EV_ABS, e.ABS_MT_POSITION_Y, int(y))
        if fingers:
            w(e.EV_ABS, e.ABS_X, int(fingers[0][0]))
            w(e.EV_ABS, e.ABS_Y, int(fingers[0][1]))
        w(e.EV_MSC, e.MSC_TIMESTAMP, int((time.monotonic() - self.t0) * 1e6) & 0x7FFFFFFF)
        self.ui.syn()

    def down(self, y):
        w = self.ui.write
        cx = self.xmax / 2
        for slot, x in enumerate((cx - 180, cx + 180)):
            w(e.EV_ABS, e.ABS_MT_SLOT, slot)
            self.tid += 1
            w(e.EV_ABS, e.ABS_MT_TRACKING_ID, self.tid)
        w(e.EV_KEY, e.BTN_TOUCH, 1)
        w(e.EV_KEY, e.BTN_TOOL_DOUBLETAP, 1)
        self._frame([(cx - 180, y), (cx + 180, y)])

    def move(self, y):
        cx = self.xmax / 2
        self._frame([(cx - 180, y), (cx + 180, y)])

    def up(self):
        w = self.ui.write
        for slot in range(2):
            w(e.EV_ABS, e.ABS_MT_SLOT, slot)
            w(e.EV_ABS, e.ABS_MT_TRACKING_ID, -1)
        w(e.EV_KEY, e.BTN_TOUCH, 0)
        w(e.EV_KEY, e.BTN_TOOL_DOUBLETAP, 0)
        self._frame([])

    def stroke(self, y_of_t, duration_s, hz=125, sign=1):
        """Two fingers down, follow y_of_t(t) mm for duration_s, lift.

        Real touchpads report at 100-140 Hz; this one at `hz`. `sign` flips
        which way the fingers travel (natural scrolling decides which way
        that scrolls the content; the analyser checks the result)."""
        y0 = self.ymax * (0.8 if sign > 0 else 0.2)
        start = time.monotonic()
        self.down(y0)
        self.rec.mark("finger_down", 0)
        n = int(duration_s * hz)
        prev = 0.0
        for i in range(1, n + 1):
            t = i / hz
            sleep_until(start + t)
            mm = y_of_t(t)
            self.move(y0 - sign * mm * self.RES)
            self.rec.mark("finger", mm - prev)
            prev = mm
        sleep_until(start + (n + 1) / hz)
        self.up()
        self.rec.mark("finger_up", 0)
