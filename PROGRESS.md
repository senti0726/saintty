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
| 2 | Scroll-region animation | 2a done; 2b implemented + hardened; **needs eyes** |
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

## Stage 2b — animation implemented 2026-09-01, needs eyes

`scroll-animation = true` displaces rows inside a scrolled region by the
distance just scrolled and eases them to zero over
`scroll-animation-duration` (default 80ms). Off by default.

Unit tested (`zig build test -Dtest-filter=noteScroll`, 6 tests) for the
detection and delegation logic. **The visual result has not been seen by
anyone.** That is the open item.

### Try it

```
scroll-animation = true
scroll-animation-duration = 80     # try 120 for more obvious, 40 for subtle
```

Scroll in tmux copy-mode or nvim. What to look for, in order:

1. **Does it animate at all** rather than snapping.
2. **Does tmux's status line stay put.** If it jiggles, the region bounds are
   being ignored somewhere.
3. **Is there a band of background at the trailing edge** during the slide.
   This one is *expected* — see below — and the question is whether it is
   noticeable enough to matter.
4. **Does text slide over a stationary background**, which would mean the two
   passes disagree.

### The known artifact

`insertLines` erases the outgoing row, and on the alternate screen (where tmux
lives) there is no scrollback to recover it from. So during the animation the
trailing edge of the region has nothing to draw and shows background — one row
for a one-row scroll. SPEC §4 Feature 2 has the analysis and the fix
(composite the previous frame); this first cut does not implement it.

If it is invisible at 80ms, leave it. If it is ugly, that is the trigger for
the compositing work rather than fiddling with the duration.

---

## Overnight session, 2026-09-01 — hardening while verification was blocked

Visual verification was impossible (no headless display; the GUI harness hangs
for upstream too), so the night went on work that can be *proven* rather than
looked at. Four commits, full suite green throughout
(**3773/3808 pass, 35 skipped, 0 failures**).

**Easing extracted to `src/renderer/scroll_anim.zig`** so it can be tested. It
was buried in a generic renderer struct, unreachable by any test, despite being
pure arithmetic. 12 tests pin what could otherwise only be judged by eye: never
overshoots past zero on a stalled frame, never flips sign, decays
monotonically, symmetric between directions, ignores zero/negative dt, survives
a zero duration.

**Five bugs found by reasoning, none of which look obviously broken:**

1. *The gap rendered as `vec4(0.0)`.* With a transparent background — which
   this machine runs — that is not "nothing", it is **a band of desktop
   wallpaper showing through mid-scroll**. Now clamps to the region's edge row,
   so the gap reads as a blank line in the surrounding background.
2. *Glyphs displaced past the region edge were still drawn*, painting text over
   rows that are deliberately stationary — tmux's status line. Now pushed
   outside the clip volume.
3. *A pending scroll survived a resize or screen switch*, where the recorded
   rows index a grid that no longer exists — it would slide unrelated content
   on entry to and exit from tmux or vim. Both discard it now, with tests.
4. *Displacement replaced instead of accumulating.* If the screen is already
   drawn a fraction of a row behind and the model scrolls again, it is behind
   by the **sum**. Replacing pins the display one row behind for the whole of a
   continuous scroll, then snaps — reads as lag, not motion.
5. *The animation clock was reset on every incoming scroll*, skipping the
   integration frame. During continuous scrolling (a momentum fling generates a
   scroll every frame) the offset would never decay and would wind up to the
   clamp. Now only reset when starting from idle.

4 and 5 interact: accumulation without the clock fix compounds forever. Neither
is visible as a distinct symptom — both just make scrolling feel wrong, which
is exactly why they needed to be reasoned about rather than watched.

**Metal kept compiling.** `generic.zig` publishes `uniforms.scroll_anim` for
every backend, so the Metal `Uniforms` needed the field or macOS stops
building. Mirrored in `shaders.metal` too, byte-compatible. Metal shaders do
not consume it: scroll animation is OpenGL-only.

### Sign convention, re-derived (the most likely remaining bug)

- `insertLines` moves content **down**; the pre-scroll view is one row
  **higher**, so `rows` is negative and the offset is negative.
- `deleteLines` moves content **up**; pre-scroll is one row **lower**, offset
  positive.
- Screen Y increases downward (`origin_upper_left`), so a negative offset draws
  content higher. Consistent.
- The background pass **subtracts** the same offset to find which cell sits
  under a pixel, matching the text pass.

---

## 2026-09-01 — stage 2b VERIFIED working, and the duration bug

First eyeball report was "no artifacts, but the smooth scrolling doesn't
apply -- dropping `--scroll-animation` made no difference", with the GPU at
94% (flag on) vs 80% (flag off).

The GPU delta was the useful clue: it meant `animationWake()` was firing, so
the CPU side was alive and only the pixels were in question.

### Verified, in order, with an automated harness (no eyeballing needed)

A Wayland session is reachable from the agent shell, so this is all
reproducible without a human:

  * Drive scrolls with `tmux -L animtest` on a **dedicated socket**, so the
    user's real sessions are untouched. `tmux -L animtest send-keys -t anim -X
    scroll-up` produces exactly the same IL traffic a touchpad does.
  * Capture with `spectacle -b -n -f -o shot.png`. It works headlessly on
    Plasma 6 Wayland; `import` (ImageMagick/X11) does not.
  * Compare with `magick ... -crop` + `montage`.

1. **Detection**: 10 scroll-ups produced exactly 10
   `rows=-1 region=1..52 source=insert_lines` events. Correct.
2. **Config**: logged `enabled=true cell_h=38` at the scroll site. Reaching
   the renderer.
3. **Easing**: offset published every frame, -76px decaying smoothly over
   ~400 frames. Correct.
4. **std140 layout**: added a permanent `comptime` assertion that
   `@offsetOf(Uniforms, "scroll_anim") == 144`. It holds. This one is worth
   keeping -- a layout drift here fails *silently*, the shader just reads
   neighbouring bytes.
5. **Shader**: forced a constant `.{ -200, 5, 40, 0 }` and screenshotted.
   Rows 5..40 shifted by ~10 rows and the display jumped `ROW-04` -> `ROW-10`.
   The uniform reaches the GPU and the vertex shader honours it.
6. **The animation itself**: with `--scroll-animation-duration=2000`, one
   scroll-up, screenshot immediately and again after settling. Mid-flight
   holds `ROW-12` exactly where settled has `ROW-11`.

**So stage 2b works end to end.** The earlier "it does nothing" reading was
not a plumbing failure.

### The real defect: the decay was exponential, not linear

`advance()` computed `step = (dt_ms / duration_ms) * @abs(self.offset_px)` --
a fraction of the *remaining* offset, which is exponential decay. The doc
comment right above it claimed linear, and the config option is called a
*duration*, but nothing bounded the time: at the documented 80ms default a
one-row scroll actually took ~370ms to settle, and spent most of that creeping
through the last pixel of a row.

That is the "soupy, can't quite see it" character, and it explains the GPU
too: the animation stayed `active()` far longer than it should, holding the
60fps draw-wake loop open.

Fixed by storing `span_px` at push time and retiring a fixed fraction of
*that* per frame, so `duration_ms` means what it says. Two tests added: one
asserts it settles within the configured duration, one asserts equal frames
move equal distance.

### The gap that probably matters most

`Terminal.scrollViewport()` does **not** call `noteScroll()` (verified:
`src/terminal/Terminal.zig:2851`, and the only four `noteScroll` callers are
`scrollUp`/`scrollDown`/`insertLines`/`deleteLines`). Scrollback scrolling in
a plain shell is a renderer-level viewport move that never touches the
terminal model, so **it produces no animation at all**.

Everything verified above is the tmux/alt-screen path. Ordinary
mouse-wheel-through-scrollback -- probably the most common scrolling there is
-- is still unanimated. That is the next real decision, and it is not a small
one: the renderer only builds cells for the viewport rows, so a partial-row
offset needs one row above or below the viewport to be rendered too.

## Harness traps — both cost real time, do not rediscover them

**Ghostty is single-instance.** The packaged `/usr/bin/ghostty` runs as a
daemon (`--gtk-single-instance=true`), and the fork's default is `detect`, so
launching the fork *hands off to the packaged binary* and your code never runs.
Symptom: zero `generic_renderer` log lines and no scroll events, looking exactly
like a regression. Always pass `--gtk-single-instance=false` when testing.

**The `-e` GUI harness is currently broken in this session.** `ghostty -e <cmd>`
no longer exits when the command finishes; it idles until killed, and buffered
log output is lost with it. **The packaged 1.3.1 hangs identically under the
same flags**, so it is environmental, not a fork regression — that control
experiment is the fast way to tell the difference and is worth re-running before
blaming the code.

Consequence: prefer `zig build test` for anything testable headlessly. It is
faster, deterministic, and it caught two real bugs that the GUI harness had
already been mis-reporting.

---

## Next action — for the morning

Everything that can be done without eyes is done. **The open item is looking at
it.**

```
scroll-animation = true
scroll-animation-duration = 120     # exaggerated, easier to judge; 80 is default
```

Scroll in tmux copy-mode. In order of what would be most informative:

1. **Does tmux's status line stay perfectly still?** If it moves at all, region
   bounds are being ignored somewhere and that is the bug to chase first.
2. **Is there a visible band at the trailing edge** during the slide? Expected —
   the outgoing row is erased and unrecoverable on the alternate screen. It
   should now look like a *blank line*, not a hole and definitely not
   wallpaper. If it is ugly, that is the trigger for the compositing work in
   SPEC §4 Feature 2, not for changing the duration.
3. **Does a fast momentum fling look smooth or soupy?** Momentum and animation
   now compose (fling -> mouse reports -> tmux scrolls -> animation), and the
   accumulation fix is what should keep that coherent. This is the interaction
   least likely to be right first time.
4. **Does text ever slide over a stationary background?** That would mean the
   two shader passes disagree.

Then still open, needing a decision rather than a fix:

- Whether to hook `index` (`src/terminal/Terminal.zig`), which would animate
  **all** output scrolling rather than deliberate scrolls. Deliberately not
  done; decide after living with 2b.
- Whether `mouse-scroll-momentum` and `scroll-animation` should default on.
- Whether the trailing-edge artifact justifies compositing the previous frame.

### Known-unknown carried forward

`ecMouseScrollVertical` applies a hardcoded `10.0` multiplier to precision
scrolls (SPEC §3.4b). The momentum path copies it so the two agree, but nobody
has checked *why* it is 10. If fling speed feels wrong *relative to dragging*,
look here first — the decay knob will not fix that.
