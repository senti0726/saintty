#!/usr/bin/env python3
"""Sit between a terminal and a program and log everything the program writes.

    ptyrec.py LOG -- CMD ARGS...

Records are (CLOCK_MONOTONIC ns: u64, length: u32, bytes), so the stream can be
replayed into an emulator and cut at each synchronized-output end (?2026l) to
see what the program meant each frame to be, and lined up against a film of
the screen (same clock as time.monotonic()). Input is passed through raw and
the window size follows the terminal's.
"""
import fcntl, os, pty, select, signal, struct, sys, termios, time, tty

log_path, cmd = sys.argv[1], sys.argv[sys.argv.index("--") + 1 :]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)


def winsize(*_):
    try:
        ws = fcntl.ioctl(0, termios.TIOCGWINSZ, b"\0" * 8)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, ws)
        os.kill(pid, signal.SIGWINCH)
    except OSError:
        pass


winsize()
signal.signal(signal.SIGWINCH, winsize)
old = termios.tcgetattr(0)
tty.setraw(0)
log = open(log_path, "wb", buffering=0)
try:
    while True:
        try:
            r, _, _ = select.select([0, fd], [], [])
        except InterruptedError:
            continue
        if fd in r:
            try:
                b = os.read(fd, 1 << 16)
            except OSError:
                break
            if not b:
                break
            log.write(struct.pack("<QI", time.monotonic_ns(), len(b)) + b)
            os.write(1, b)
        if 0 in r:
            b = os.read(0, 1 << 16)
            if not b:
                break
            os.write(fd, b)
finally:
    termios.tcsetattr(0, termios.TCSADRAIN, old)
    os.waitpid(pid, 0)
