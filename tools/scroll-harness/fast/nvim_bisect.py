#!/usr/bin/env python3
"""nvim_bisect.py <label> <lua>: pre-scroll CSAPP ch.2 fast, then time 40 x `15j` near the end.

Prints the median/p90 delay from a keypress to nvim's first scroll step, and the
median/p90 gap between steps, with <lua> applied before anything runs.

Both ends are timestamped INSIDE nvim with hrtime: the key by vim.on_key, each
step by WinScrolled. Until 2026-09-28 the key time came from a --remote-expr
issued after --remote-send returned -- two client processes later, ~25 ms in --
and steps before it were dropped, so it measured whichever stretch of the
glide it happened to catch. That read as nvim "flipping between a fast and a
slow mode" per run (SETUP-LOG 2026-09-28)."""
import sys, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import run
label, lua = sys.argv[1], sys.argv[2]
spacing = float(sys.argv[3]) if len(sys.argv) > 3 else 0.15
presses = int(sys.argv[4]) if len(sys.argv) > 4 else 280
rig = run.Rig(run.REPO / "zig-out-release" / "bin" / "ghostty", Path.home() / "playground/fast-scroll/bisect-work")
try:
    rig.start(); time.sleep(4)
    if lua: rig.nv_lua(lua)
    rig.reset(1, bottom=True)
    for i in range(presses):                  # build up state: every region shown once
        run.sh("nvim", "--server", str(rig.sock), "--remote-send", "15j"); time.sleep(spacing)
    if presses == 0:
        time.sleep(280 * spacing)             # the same wall time, idle
    time.sleep(2)
    rig.reset(3000, bottom=True)
    rig.nv_lua("(function() _G.__steps, _G.__keys = {}, {} vim.on_key(function(k) if k == 'j' then table.insert(_G.__keys, math.floor(vim.uv.hrtime() / 1e6)) end end, vim.api.nvim_create_namespace('nvim-bisect')) vim.api.nvim_create_autocmd('WinScrolled', { callback = function() table.insert(_G.__steps, math.floor(vim.uv.hrtime() / 1e6)) end }) return 1 end)()")
    for i in range(40):
        run.sh("nvim", "--server", str(rig.sock), "--remote-send", "15j"); time.sleep(0.7)
    sends = [int(x) for x in rig.nv("join(luaeval('_G.__keys'), ',')").split(",") if x]
    steps = [int(x) for x in rig.nv("join(luaeval('_G.__steps'), ',')").split(",") if x]
    first, gaps = [], []
    for i, s in enumerate(sends):
        nxt = sends[i+1] if i+1 < len(sends) else s + 700
        st = [t for t in steps if s <= t < nxt]
        if st: first.append(st[0] - s); gaps += [b - a for a, b in zip(st, st[1:])]
    first.sort(); gaps.sort()
    q = lambda v, f: v[min(len(v)-1, int(len(v)*f))] if v else -1
    print(f"{label:24} first step median {q(first,.5):4} p90 {q(first,.9):4} ms | step gap median {q(gaps,.5):3} p90 {q(gaps,.9):4} ms", flush=True)
finally:
    rig.stop()
