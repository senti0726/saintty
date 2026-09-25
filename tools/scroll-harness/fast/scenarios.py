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
    def __init__(self, fn, line=300, settle=2.0, keys=False, doc="", lua=""):
        self.fn, self.line, self.settle, self.keys, self.doc = fn, line, settle, keys, doc
        # Run in the test nvim before the gesture (see the *_native scenarios).
        self.lua = lua

    def run(self, **kw):
        self.fn(**kw)


def key(code, down):
    subprocess.run(["ydotool", "key", f"{code}:{1 if down else 0}"], env=YDO, capture_output=True)


# ---- keyboard ---------------------------------------------------------------
CTRL, D, F = 29, 32, 33


def _chord(rec, code, n, every):
    t0 = time.monotonic()
    for i in range(n):
        sleep_until(t0 + i * every)
        subprocess.run(["ydotool", "key", f"{CTRL}:1", f"{code}:1", f"{code}:0", f"{CTRL}:0"], env=YDO, capture_output=True)
        rec.mark("key", 1)


def ctrl_d(rec, **_):
    """Six half-page jumps, each left to finish before the next."""
    _chord(rec, D, 6, 0.8)


def ctrl_f(rec, **_):
    """Four full-page jumps: past the fork's 40-row slide, so natively a cut."""
    _chord(rec, F, 4, 1.2)


def jumps(rec, **_):
    """G, gg, G, gg a second apart: jumps smear-cursor should draw (+drawlog)."""
    G, SHIFT = 34, 42
    for seq in (["42:1", "34:1", "34:0", "42:0"], ["34:1", "34:0", "34:1", "34:0"]) * 2:
        subprocess.run(["ydotool", "key", *seq], env=YDO, capture_output=True)
        rec.mark("key", 1)
        time.sleep(1.0)


# neoscroll (nvim plugins/motion.lua) off: its keys back to nvim's own.
NATIVE = "(function() for _, k in ipairs({'<C-d>', '<C-f>'}) do pcall(vim.keymap.del, 'n', k) end end)()"

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
    # Run the neoscroll pairs in this order: *_native unmaps it for good.
    "ctrl_d": Scenario(ctrl_d, keys=True),
    "ctrl_f": Scenario(ctrl_f, keys=True),
    "jumps": Scenario(jumps, keys=True),
    "ctrl_d_native": Scenario(ctrl_d, keys=True, lua=NATIVE),
    "ctrl_f_native": Scenario(ctrl_f, keys=True, lua=NATIVE),
}


# Toggles for `run.py <scenario>+<variant>`; each stays in force for the rest of the run.
VARIANTS = {
    "nosmear": "(function() require('smear_cursor').enabled = false end)()",
    # Who draws the smear: <runtime>/drawlog.txt, one caller chain per draw_quad.
    "drawlog": """(function()
  local f = io.open(vim.fn.stdpath('run') .. '/drawlog.txt', 'w')
  local draw = require('smear_cursor.draw')
  local orig = draw.draw_quad
  draw.draw_quad = function(...)
    local chain = {}
    for lvl = 2, 6 do
      local i = debug.getinfo(lvl, 'nl')
      if not i then break end
      chain[#chain + 1] = (i.name or '?') .. ':' .. (i.currentline or 0)
    end
    f:write(table.concat(chain, ' < ') .. '\\n')
    f:flush()
    return orig(...)
  end
end)()""",
    # Every WinScrolled, which floats are visible (and why): <runtime>/floatlog.txt
    "floatlog": """(function()
  local f = io.open(vim.fn.stdpath('run') .. '/floatlog.txt', 'w')
  vim.api.nvim_create_autocmd('WinScrolled', { callback = function()
    local vis = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local c = vim.api.nvim_win_get_config(w)
      if c.relative ~= '' and not c.hide then
        vis[#vis + 1] = w .. ':' .. vim.bo[vim.api.nvim_win_get_buf(w)].filetype .. '@' .. (c.row or '?') .. ',' .. (c.col or '?')
      end
    end
    f:write(math.floor(vim.uv.hrtime() / 1e6) .. ' ' .. table.concat(vis, ' ') .. '\\n')
    f:flush()
  end })
end)()""",
}
