#!/usr/bin/env python3
"""Emit the byte stream a scrolling tmux produces, on a scripted cadence.

Runs *inside* the terminal under test. Driving the real touchpad is not
reproducible and driving `tmux send-keys` from outside costs a process spawn
per event (10ms+), which is slower than the fling we are trying to measure.
Writing the escape sequences directly gives exact pacing and removes tmux
from the experiment entirely.

The sequence is the one measured from real tmux (SPEC 3.3): set a scrolling
region that excludes a bottom status row, home the cursor, insert a line.
"""

import shutil
import sys
import time

PATTERNS = {
    # name: (interval_ms, count) -- one row per event, as a wheel notch gives
    "slow": (120.0, 24),
    "medium": (33.0, 45),
    "fast": (10.0, 90),
    "burst": (0.0, 40),
    "reverse": (60.0, 40),  # scrolls up then back down, to catch sign bugs
    # Real tmux does not only scroll the body: it repaints its status line by
    # scrolling a *different*, tiny region. Those repaints interleave with the
    # body scrolls, and any state keyed on "the" scrolling region has to cope.
    "tmuxish": (33.0, 45),
}


def main() -> int:
    name = sys.argv[1] if len(sys.argv) > 1 else "slow"
    interval_ms, count = PATTERNS[name]
    cols, rows = shutil.get_terminal_size((80, 24))
    body = rows - 1  # keep a bottom row out of the region, like tmux's status

    out = sys.stdout
    # Fill the screen so there is something to watch move.
    out.write("\x1b[2J")
    for i in range(rows):
        out.write(f"\x1b[{i + 1};1HROW-{i:03d} " + "#" * max(0, cols - 12))
    # A stand-in for tmux's status line, on the row we exclude.
    out.write(f"\x1b[{rows};1H\x1b[44m STATUS \x1b[0m")
    out.write(f"\x1b[1;{body}r")
    out.flush()
    time.sleep(1.0)

    interval = interval_ms / 1000.0
    line = 0
    for i in range(count):
        down = name == "reverse" and i >= count // 2
        if name == "tmuxish" and i % 3 == 2:
            # Status-line repaint in its own two-row region, then restore.
            out.write(f"\x1b[{rows - 1};{rows}r\x1b[{rows - 1};1H\x1b[1L")
            out.write(f"\x1b[{rows};1H\x1b[44m STATUS {i:03d} \x1b[0m")
            out.write(f"\x1b[1;{body}r")
        out.write("\x1b[1;1H")
        # Insert at top scrolls content down; delete scrolls it up.
        out.write("\x1b[1M" if down else "\x1b[1L")
        out.write(f"\x1b[1;1HNEW-{line:04d} " + "#" * max(0, cols - 12))
        out.flush()
        line += 1
        if interval:
            # Absolute deadlines: sleeping a fixed interval accumulates the
            # cost of the writes and quietly slows the pattern down.
            deadline = time.monotonic() + interval
            while True:
                remain = deadline - time.monotonic()
                if remain <= 0:
                    break
                time.sleep(remain)

    out.write(f"\x1b[r\x1b[{rows};1H")
    out.flush()
    time.sleep(2.0)  # let the animation settle inside the trace
    return 0


if __name__ == "__main__":
    sys.exit(main())
