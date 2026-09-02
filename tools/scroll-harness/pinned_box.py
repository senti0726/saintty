#!/usr/bin/env python3
"""An application that pins an interface to the bottom, like Claude Code.

Reproduces what Claude Code was measured doing: it scrolls its history in
response to the wheel, and separately redraws a box it keeps pinned above the
last line, using its own scrolling regions -- which it alternates between the
full screen and one row short of it.

The point of the stand-in is that the box's rows are known exactly, so a test
can assert the box never moves. Running the real thing is not reproducible: it
needs a session, a network, and it renders differently every time.
"""

import os
import shutil
import sys
import termios
import time
import tty

BOX_ROWS = 2  # the pinned interface occupies the last two rows


def main() -> int:
    cols, rows = shutil.get_terminal_size((80, 24))
    body = rows - BOX_ROWS
    out = sys.stdout

    out.write("\x1b[2J")
    for i in range(1, body + 1):
        out.write(f"\x1b[{i};1HHIST-{i:03d} " + "#" * max(0, cols - 14))
    draw_box(out, rows, cols, 0)
    # Ask for mouse reporting, as a full-screen interface does.
    out.write("\x1b[?1000h\x1b[?1006h")
    out.flush()

    # Raw mode, as any full-screen application does. Without it the line
    # discipline holds input until a newline and the escape sequences for
    # mouse reports never arrive.
    saved = termios.tcgetattr(sys.stdin.fileno())
    tty.setraw(sys.stdin.fileno())
    os.set_blocking(sys.stdin.fileno(), False)
    n = 0
    end = time.time() + 40
    while time.time() < end:
        try:
            # os.read, not sys.stdin.buffer.read: a buffered reader on a
            # non-blocking fd returns None even when bytes are waiting.
            data = os.read(sys.stdin.fileno(), 4096)
        except BlockingIOError:
            data = None
        except OSError:
            break
        if data:
            # Any wheel report scrolls the history by one row.
            for _ in range(data.count(b"M")):
                n += 1
                # Scroll the history. The region runs to the *last* row, as
                # Claude Code's was measured doing -- it does not reserve the
                # rows it pins its box on, which is the whole difficulty.
                out.write(f"\x1b[1;{rows}r\x1b[1;1H\x1b[1L")
                out.write(f"\x1b[1;1HNEW-{n:04d} " + "#" * max(0, cols - 14))
                # Redraw the pinned box, alternating the region the way Claude
                # Code does: sometimes the whole screen, sometimes one short.
                # Alternate the top margin between 1 and 2, exactly as Claude
                # Code was observed alternating 0..54 and 1..54.
                out.write(f"\x1b[{1 if n % 2 else 2};{rows}r")
                draw_box(out, rows, cols, n)
                out.write("\x1b[r")
            out.flush()
        time.sleep(0.004)

    out.write("\x1b[r\x1b[?1000l\x1b[?1006l")
    out.flush()
    termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, saved)
    return 0


def draw_box(out, rows: int, cols: int, n: int) -> None:
    """Draw the pinned interface on the last BOX_ROWS rows."""
    # One column short of the width: writing the full width on the last row
    # wraps the cursor and scrolls the screen, which would be the harness
    # generating scroll events rather than the gesture.
    w = max(0, cols - 1)
    top = rows - BOX_ROWS + 1
    out.write(f"\x1b[{top};1H\x1b[44m" + f" PROMPT BOX {n:04d} ".ljust(w) + "\x1b[0m")
    out.write(f"\x1b[{rows};1H\x1b[44m" + " bypass permissions ".ljust(w) + "\x1b[0m")


if __name__ == "__main__":
    sys.exit(main())
