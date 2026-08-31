# PROGRESS — smooth-scroll fork

Volatile half of the pair. `SPEC.md` says what and why and holds the verified
facts about upstream; this file says **where we are**. Update it at the end of
every working session, before context is lost.

**If you are an agent picking this up cold: read `SPEC.md` first, then §"State"
below, then §"How to work on this".** Do not re-derive the facts in SPEC §3 —
they were expensive. Do re-verify them if `git merge-base` has moved.

---

## State

**Base:** `ghostty-org/ghostty` @ `e8aa09867` (`1.3.2-dev`), branch `smooth-scroll`
**Last updated:** 2026-08-31

| Stage | Feature | Status |
|-------|---------|--------|
| 0 | Toolchain + unmodified build | **DONE, verified** |
| 1 | Momentum | **WORKS** — verified by hand; tuning open |
| 2 | Scroll-region animation | **2a detection DONE + verified**; 2b animation not started |
| 3 | Pixel viewport scroll | not started |

Commits on this branch: `ff0b00271` (docs), `d312bef5a` (stage 1).

### Stage 0 — done 2026-08-31

Unmodified Ghostty main builds and runs from source on this machine.

```
$ ~/dev/ghostty/zig-out/bin/ghostty --version
Ghostty 1.3.2-main-+e8aa09867
  Zig version : 0.16.0
  build mode  : .ReleaseFast
$ /usr/bin/ghostty --version
Ghostty 1.3.1-4.fc44          # packaged, untouched; rpm -V clean
```

Verified by running the binary, not by the presence of a file.

---

## How to work on this

### Build

```bash
cd ~/dev/ghostty
zig build                          # Debug — fast, use while developing
zig build -Doptimize=ReleaseFast   # slow, for actually using it
```

Zig 0.16.0 from Fedora (`dnf`), matching `minimum_zig_version` in
`build.zig.zon`. Deps are cached in `~/.cache/zig` (~210 MB) so the first build
is the slow one. Run long builds in the background and report progress.

### Run without risking your session

```bash
~/dev/ghostty/zig-out/bin/ghostty      # opens a NEW window
```

Launch it *from* a working terminal. If a change crashes on startup you still
have a terminal to fix it from. Do not point the desktop entry at the fork.

### System dependencies (already installed, recorded for a rebuild)

```bash
sudo dnf install -y blueprint-compiler gtk4-devel gtk4-layer-shell-devel \
                    libadwaita-devel oniguruma-devel zlib-ng-devel
```

**Do not use `sudo dnf builddep ghostty`.** It resolves deps for Fedora's
*packaged* 1.3.1, which is built with Zig 0.15.2 via the `zig015` COPR package.
`zig015` installs to `/usr/lib/zig/` and `/usr/bin/zig` — the same paths as
`zig` 0.16.0 — so RPM aborts the whole 41-package transaction with file
conflicts. We build **main**, which wants 0.16.0, so `zig015` is not needed at
all. The six packages above are that builddep list minus `zig015`, and they
were sufficient: the unmodified build needed nothing further.

### Verification

**Scrolling is a GUI behaviour. Compiling proves nothing.** Actually scroll.

For anything involving what an application emits (Feature 2 especially),
measure rather than assume — that is how SPEC §3.3 was established and how an
earlier wrong assumption was caught. The harness: allocate a pty with Python's
`pty` module, run `tmux attach` inside it, drive scrolls from outside with
`tmux send-keys -X -N 1 scroll-up`, and capture the master fd. Classify the
captured bytes by regex for `IL`/`DL`/`SU`/`SD`/`IND`/`DECSTBM` versus count of
printable glyphs redrawn. Note `script(1)` is **not installed** on this machine
— that path is a dead end, use Python.

To see whether the fork changed feel, compare side by side against
`/usr/bin/ghostty`, which is upstream 1.3.1 and stays installed for exactly
this reason.

---

## Session log

Newest last. Record what was learned and what was ruled out, not just what was
done.

### 2026-08-31 — stage 0, and the specs

- Established that config, not the terminal, was the original culprit: this
  machine has only a touchpad (a *precision* device), which Ghostty already
  tracks 1:1 (`mouse-scroll-multiplier = precision:1`), while tmux was
  multiplying every event by 5 and nvim by 3. Fixed downstream and committed
  to `~/dev/dotfiles` as `bfb1056`. **That is out of scope here** and should
  not be redone — this fork is for what config cannot reach.
- Surveyed the alternatives before forking: no GTK "kinetic scrolling" knob is
  reachable (Ghostty has zero scroll-animation options in its full config
  schema, and GTK's `kinetic-scrolling` is a scrolled-window/touch property
  that does not reach a GPU-rendered grid). The community fork
  `parkers0405/ghostty-pixel-scroll` implements Feature 3 only — real, but
  scoped to a case this user is never in, and bundled into a personal mega-fork
  carrying collaborative cursors and a Neovim GUI mode.
- **Corrected a wrong call made mid-investigation:** the claim that tmux
  repaints the pane, making animation impossible, was wrong. Measurement (SPEC
  §3.3) shows a clean `DECSTBM` + `CSI 1 L` with a single row redrawn. Feature
  2 is viable *because* that assumption was tested instead of trusted.
- Toolchain: hit the `zig015` file-conflict wall via `builddep`; diagnosed and
  routed around it (see above). Nothing was installed by the failed
  transaction — RPM aborts atomically.
- Stage 0 built clean and verified running.
- Wrote `SPEC.md` + this file, on branch `smooth-scroll`.

---

## Stage 1 — works, tuning open

Verified by hand on the touchpad 2026-08-31: `decelerate` fires, the fling
runs. Two rounds of feedback so far.

**Round 1 → round 2.** Momentum was too weak, and flicks did not stack. The
stacking failure was a design bug: `ecMouseScrollVertical` called
`momentumStop()`, zeroing velocity the moment fingers came back down, so the
follow-up flick started from nothing. Now a real scroll *pauses* the fling and
keeps its velocity; `decelerate` adds the new gesture's velocity to the
residual, after decaying it by the length of the gesture. Strength: decay
constant 0.18s → 0.45s, stop threshold 12 → 8 px/s.

### Tuning without rebuilding

`mouse-scroll-momentum-decay` (seconds, default 0.45) is the "how far does a
flick carry" knob. A fling runs roughly 4-5x this before stopping.

```
mouse-scroll-momentum = true
mouse-scroll-momentum-decay = 0.7      # glides further
```

Ghostty reloads config without a restart, so iterate on feel there rather than
in the source. Only touch the code constants if the *shape* is wrong rather
than the duration — `momentum_max_velocity` (30000 px/s, the stacking ceiling)
and `momentum_min_velocity` (8 px/s, the stop threshold).

### Reading the debug log

```
scroll momentum: vel_y=<N> residual=<N> combined=<N> px/s tau=<N>s
```

`residual` non-zero on a second flick is stacking working. If `combined`
saturates at 30000 repeatedly, the ceiling is being hit and could be raised.

## Stage 2a — scroll detection, done and verified 2026-08-31

`Terminal.scroll_event` records region scrolls; the renderer drains it in the
`updateFrame` critical section and logs. **No visual change yet.**

Verified twice. Synthetic sequences with known answers:

```
CSI 1;23r, cursor row 5, then IL 2 / DL 3 / SU 4 / SD 2
-> rows=-2 region=4..22 insert_lines
   rows=3  region=4..22 delete_lines
   rows=4  region=0..22 scroll_up
   rows=-2 region=0..22 insert_lines
```

And against real tmux copy-mode: three scroll-ups give `rows=-1
region=0..51 insert_lines` each, matching the `CSI 1 L` measured in SPEC §3.3.
A 5-row scroll-down at the buffer end correctly reported `rows=3` — the
clamped count, not the requested one.

### Two things testing caught that guesswork had wrong

1. **`scrollDown` delegates to `insertLines`.** Hooking both double-counted:
   `SD 2` reported 4. Only `insertLines` is hooked now; it is the choke point
   for SD and RI alike. `scrollUp` has its own implementation and stays
   distinguishable. This is why `ScrollEvent.Source` has no `scroll_down`.
2. **`insertLines`/`deleteLines` scroll from the cursor row**, not the region
   top, so the span is `[cursor, bottom margin]`. Recording
   `scrolling_region.top` would have been wrong for every IL/DL.

### Deliberately not done

`index` (`src/terminal/Terminal.zig:2316`) is **not** hooked. It fires on every
newline at the bottom of the screen, so hooking it animates all terminal
output, not deliberate scrolling. Decide that separately, after watching what
the deliberate-scroll traffic looks like on its own.

### Seeing it

Run the fork and watch stderr; events log at debug level as

```
scroll event: rows=<N> region=<top>..<bottom> source=<which>
```

---

## Next action

1. Live with the current feel; adjust `mouse-scroll-momentum-decay` in config.
   Only revisit code if the *character* is wrong, not the distance.
2. Once settled: consider flipping `mouse-scroll-momentum` to default true,
   and decide whether the debug log stays.
3. **Stage 2b: the animation itself.** SPEC §4 Feature 2 now carries the full
   design analysis — read it before writing code, especially the outgoing-row
   problem and the recommendation to composite the previous frame rather than
   stash rows. Attach continuous frames to `animationWake()`
   (`src/renderer/generic.zig:1039`); do not invent a timer. And the standing
   hazard: **animate the pixel offset used at draw time, never the grid
   model.**

### Known-unknown carried forward

`ecMouseScrollVertical` applies a hardcoded `10.0` multiplier to precision
scrolls (SPEC §3.4b). The momentum path copies it so the two agree, but nobody
has checked *why* it is 10, or whether it interacts badly with a
`mouse-scroll-multiplier` far from 1. If fling speed feels wrong *relative to
dragging*, look here first — that is the one symptom the decay knob will not fix.
