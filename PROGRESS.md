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

## 2026-09-01, later — the two bugs the first working build exposed

With the animation finally visible, two real defects showed up immediately.
Both are fixed and verified by screenshot.

### 1. A fling wound the offset up to half a screen

Reported as: "when I flick up, 4950-5000 goes to 4950-4975 but now located at
the bottom half of the screen, with the upper half empty."

`push()` accumulates displacement, and during a fling scrolls arrive faster
than the ramp retires them. The cap was `cell_h * grid.rows` -- a whole
screen -- so the offset wound up until the block of text was drawn half a
screen from where it belonged. That is not smoothing, it is lag, and it is
what "it got a lot laggier" was describing. The GPU was idle because nothing
was working hard; the picture was just stale.

Two changes:

  * `max_lag_rows = 2`. The drawn position may never fall more than two rows
    behind the model.
  * `max_animated_rows = 8`. A single scroll bigger than this is a page move,
    a tmux full-screen redraw, or an output burst, not a scroll. Those snap,
    and drop any animation in flight. This is what kills the `rows=416` and
    `rows=52` events that were previously being animated as full-screen
    sweeps.

### 2. The trailing gap smeared tmux's blue row into a solid block

Reported as: "the blue box containing the line count dragged down into a whole
blue box."

The overnight session had changed the gap in `cell_bg.f.glsl` from
`return vec4(0.0)` to clamping to the region's edge row, on the reasoning that
transparent would show the desktop through. **That reasoning was wrong**, and
this is worth remembering: the `bg_color` pipeline paints the global
background across the whole surface *before* `cell_bg`, which blends over it.
A transparent fragment in `cell_bg` is therefore exactly what a
default-background cell looks like -- not a hole to the desktop.

Clamping instead replicated the edge row's colors down the entire gap, so when
the edge row was tmux's blue copy-mode status line you got a solid blue block
the height of the scroll. Reverted to returning nothing, with the reasoning
recorded in the shader so it does not get "fixed" again.

### Verified

Sustained fling (300 rapid `scroll-up` sends), screenshot mid-fling: text
fills the region top to bottom, no empty half, no blue block, copy-mode
indicator in its normal place.

### Tuning knobs, if it still feels wrong

Both are constants in `src/renderer/scroll_anim.zig`, not config: `max_lag_rows`
(lower = crisper, less smoothing) and `max_animated_rows`. Use the **default**
`scroll-animation-duration` of 80ms now -- the 250ms used for testing was
deliberately exaggerated and will read as lag on its own.

## 2026-09-01 — the measurement harness, and what it found

Eyeballing had taken this as far as it could go. `tools/scroll-harness/` now
measures scroll feel instead.

### How it works

`emit.py` runs *inside* the terminal under test and writes the byte stream a
scrolling tmux produces, on a scripted cadence. Driving the real touchpad is
not reproducible, and driving `tmux send-keys` from outside costs a process
spawn per event -- slower than the fling being measured. Patterns: `slow`,
`medium`, `fast`, `burst`, `reverse`, `tmuxish` (which interleaves status-line
repaints in their own small region, as real tmux does).

`harness.py` launches the fork with `--scroll-trace`, runs a pattern, then
reconstructs where content sat on every frame as
`-(model_rows * cell_h) + off_px` and reports reversals, lag, per-frame step
size, stalls and frame interval.

    zig build -Doptimize=ReleaseFast --prefix zig-out-release
    python3 tools/scroll-harness/harness.py fast --bin=$PWD/zig-out-release/bin/ghostty

**Measure on a release build.** `--scroll-trace` deliberately logs at `info`
so it survives one.

### What it found immediately

**The animation was halving the frame rate.** Same `fast` pattern, release
build:

| | frame interval p50 | step size p50 |
|---|---|---|
| animation off | 17.9ms (56fps) | 2.00 rows |
| animation on (before) | 33.4ms (30fps) | 3.00 rows |
| animation on (after) | 17.3ms (58fps) | 2.05 rows |

`animationWake()` returned a fixed 8ms draw wake. A scroll animation runs
precisely when the terminal is *also* being updated, so those wakes stacked on
top of the update-driven draws; at 4K on the 780M that overruns the vsync
budget and drops every other frame. The animation was making scrolling
measurably worse than not having it.

Fixed by pacing the wake against `last_draw_ts` -- the time of the last actual
draw, whatever caused it -- so total draw rate is capped near 60fps instead of
two sources competing.

**This was not a debug-build artifact.** That was the first hypothesis and it
was wrong: release and debug both sat at 33ms with the animation on.

### The reversal: a single pending slot

`Terminal.scroll_event` is one slot, and `noteScroll` *replaced* on a region
change. tmux repaints its status line by scrolling a two-row region,
interleaved with body scrolls, so a repaint landing between frames silently
discarded the body scroll waiting there. The body then snapped, and when the
repaint deleted rather than inserted, the text moved *against* the scroll.
That is the "occasionally the words go down".

Two fixes: `noteScroll` ignores scrolling regions under a quarter of the
screen (decorations, not content), and `ScrollAnim.push` now accumulates
across *overlapping* regions rather than only identical ones, because tmux
jitters its region by a row between redraws and that was throwing the pending
displacement away mid-slide.

Note the subtlety that cost a test: for IL/DL, `noteScroll`'s `top` argument
is the *cursor* row, not the region top, so the filter has to measure
`scrolling_region`, not `bottom - top`.

### The ceiling this design has

At the `fast` pattern the content moves ~2 rows per drawn frame, and 81% of
moving frames are still whole-row jumps. That is not the easing failing: the
*input* is 100 rows/sec, so the model genuinely advances ~2 rows per frame at
60fps. No amount of smoothing between model positions fixes it, and Chrome at
an equivalent fling speed is equally unreadable.

What Chrome does differently is upstream of all this: its scroll position is a
continuous value driven by the input device and sampled once per frame, so it
is never behind and never moves in row units. The equivalent here is to make
the renderer own a fractional scroll position, send whole-row scrolls to tmux
only as it crosses row boundaries, and draw the remainder as the offset. That
removes the ~1 row of lag this design structurally cannot (`mean 1.33 rows` on
`fast`) and makes slow scrolling genuinely sub-pixel rather than
sub-pixel-after-the-fact. **Not attempted yet; this is the next decision.**

## 2026-09-01 — clipping, and pixel-perfect scrolling (NEEDS EYES)

### Clipping: two symptoms, one bug

Reported as text drawing over nvim's status bar, and as a row at the bottom
appearing *below* its final position and sliding up to it rather than entering
from the edge.

Both were the same thing. The vertex stage can only drop **whole** rows, so a
row displaced by a fraction of a cell was drawn in full and spilled past the
region. `cell_text.f.glsl` now clips per fragment against the region's pixel
band, which is what makes a row slide in from the boundary.

### Pixel-perfect scrolling: `scroll-pixel-perfect`, default off

This is the redesign, and it is the answer to "you scroll 0.5 line expecting
0.5 line but it jumps a whole one".

`Surface.mouse.pending_scroll_y` already holds the sub-row remainder in
pixels -- Ghostty accumulates it and only acts once it exceeds a cell. It was
simply never drawn. The renderer now draws it.

The non-obvious half is the second term. When the fraction crosses a row,
`pending_scroll_y` resets to ~0 and a scroll event goes to the app -- but the
app is at the far end of a pty and has not moved yet. Drawing only the
fraction would snap the picture back a full row and then jump forward when
tmux catches up. So the offset is

    pending_px + (requested_rows - applied_rows) * cell_h

`requested_rows` is sent by the Surface, `applied_rows` is counted in the
renderer from scroll events, crediting only scrolls that move the way we
asked (a program writing output scrolls the model too, and crediting those
would displace the picture for a gesture that never happened). At the crossing
the outstanding term is exactly the row the fraction gave up, so the content
does not move at all until the model arrives underneath it. **Zero lag by
construction**, unlike the ease-after-the-fact design.

Because the position is already continuous, the catch-up animation is skipped
entirely when this is on -- it would pull content backwards at the very moment
the gesture moved it forwards.

`settleScrollPixel` retires the displacement `settle_idle_ms` after the last
input, handing it to the ordinary ramp so it eases onto the character grid
rather than snapping. This is not optional: a standing fraction holds text
permanently off the grid, and if the app never scrolls at all -- a plain shell
scrolls its *viewport*, which never touches the terminal model, or an app
already at the top of its scrollback -- the outstanding rows would never
unwind and the picture would stay displaced for good.

### Why this one needs a human

**The harness cannot test it.** `emit.py` drives the terminal's byte stream,
which is downstream of everything this feature touches; the whole mechanism
lives in the *input* path, and synthesising touchpad events needs uinput
(root). The sign convention in particular is reasoned, not measured: GTK
reports positive y for scrolling down and `ecMouseScrollVertical` inverts it,
so `pending_scroll_y` is negative scrolling down, and content moving up the
screen is a negative offset -- the two agree, so the terms add. If scrolling
turns out doubled or inverted, that sign is the first thing to check.

Off by default for exactly this reason.

### Still open

Quick flicks in large documents were reported as hanging and then arriving.
Not investigated. The harness measures the render path, and this smells like
the app (nvim) or the pty, so the next step is to find out which before
touching anything.

## 2026-09-01 — pixel-perfect, take two: you can only draw *behind* the app

Take one shipped and was worse than nothing: "hard flick throws off two lines,
soft flick one, flick up throws off from the bottom and down from the top, and
the status bar's words disappear."

### The geometry I got wrong

The offset drew content **ahead** of the terminal model. In the alternate
screen the row that would come into view has not arrived -- tmux has it, we do
not -- so leading by N rows leaves a hole exactly N rows tall, at the bottom
when scrolling up and at the top when scrolling down. Precisely the report.
The new per-fragment clip then did its job and deleted those rows, which is
why it read as text disappearing rather than as a gap.

**The display can only ever trail the app.** Take one's whole "outstanding
rows" term existed to hold the display forward across the moment a fraction
becomes a row, and that is the one thing that cannot be done.

### The upstream bug underneath it

`Surface.scrollCallback` claimed to save the sub-cell remainder:

    const amount = poff / cell_size;                       // f64, unrounded
    self.mouse.pending_scroll_y = poff - (amount * cell_size);

`amount * cell_size` is `poff`, so this is identically zero. The remainder was
discarded on every scroll rather than carried into the next one. So during any
real scrolling `pending_px` was zero and the offset was *purely whole rows*,
which is what turned a design error into deleted lines. Fixed to use the
truncated `delta`; this makes precision scrolling more accurate regardless of
the flag.

### Take two

Round to the **nearest** row instead of truncating, under the flag. Truncating
always leaves the display owing the app a fraction, i.e. leading. Rounding
puts the leftover on either side, bounded to half a row, and the offset is
then just that leftover, clamped to +/- half a cell. Worst case is a half-row
sliver at the trailing edge instead of a missing line, and the display tracks
the finger continuously rather than snapping at row boundaries.

The `requested_rows`/`applied_rows` reconciliation is gone entirely, along
with its assumption that one wheel report always produces exactly one row of
app scrolling -- an assumption nothing enforces.

### Still unverifiable here

Same as before: this lives in the input path and the harness drives the
terminal's byte stream, so it cannot exercise it. Real hands required.

### Untouched

Quick flicks hanging in large nvim documents. Still not investigated.

## 2026-09-01 — take three: rounding *and* the in-flight term

Take two stopped deleting lines but was still line-quantized: "the scroll is
back, and then the previous problem was back: the not really pixel perfect".

Take two removed too much. Dropping the in-flight term left a stutter at every
row boundary: the instant the fraction rounds up, a wheel report goes down the
pty and `pending_scroll_y` flips from +half a cell to -half a cell, but the app
is a round trip away and has not moved, so the offset jumps a whole cell with
nothing underneath it.

The term that bridged that gap was never the problem. Take one was destructive
because it *truncated* -- which always leaves the display owing the app a
fraction, i.e. leading by up to a full row -- compounded by the remainder bug
that pinned `pending_px` at zero. Rounding fixes the direction; the in-flight
term fixes the discontinuity. Together:

| finger | pending | in flight | offset |
|---|---|---|---|
| 0.5 cell, pre-emit | +0.5 | 0 | +0.5 |
| 0.5 cell, post-emit | -0.5 | +1 | +0.5 (continuous) |
| app catches up | -0.5 | 0 | -0.5 |

Peak displacement is half a cell either way, so the lead -- which in the
alternate screen is always a hole, since the incoming row has not arrived --
is at most a half-row sliver.

`scrollPixelOffset` clamps hard to +/- half a cell. That clamp is a safety net,
not arithmetic: the in-flight term assumes one wheel report yields one row of
app scrolling, which nothing enforces (an app may scroll three, or refuse at
the top of its buffer). When that slips the term drifts, and the clamp stops
drift from ever becoming a deleted line again.

## The nvim flick-hang, root-caused (not yet fixed)

"Quick flicks are laggy, sometimes it hangs for a while and then only arrives
at the scroll target position."

Not the renderer, which is why the harness never saw it:

1. `Surface.scrollCallback` sends **one wheel report per row**:
   `for (0..@abs(y.delta)) |_| { ... mouseReport(...) }` (src/Surface.zig:3624).
   With the hardcoded 10x precision multiplier plus momentum, a hard flick
   makes a lot of them.
2. nvim is configured `mousescroll=ver:1` (our own dotfiles change), so every
   report is a separate redraw of a large document.
3. The app cannot keep up, the pty backs up, the writer thread stalls.
4. The termio mailbox is **64 slots** (src/termio/mailbox.zig:15). When full,
   `send` unlocks the renderer mutex and does a **`.forever` blocking push**
   (src/termio/mailbox.zig:95) -- on the **GTK main thread**.

So the UI thread blocks until nvim drains a queue the flick overfilled. Fix
direction: stop amplifying. Cap reports per gesture, or drop them when the
queue is backing up, rather than blocking the main thread. Deliberately not
attempted yet.

## Note on nvim smooth-scroll plugins

Worth knowing before chasing one: neoscroll.nvim, vim-smoothie and
mini.animate ease the *timing* of a jump by issuing a sequence of small
scrolls. They cannot produce sub-line movement -- nvim draws into a character
grid like everything else in a terminal. Sub-line positioning can only come
from the terminal, which is what `scroll-pixel-perfect` is. They compose:
a plugin smooths the timing, this smooths the position. A plugin would also
*increase* the report traffic behind the flick-hang above.

## 2026-09-02 — the snap is now optional, and the flick-hang is fixed

Take three landed well: "this has to be the fastest one yet, not a single lag
I caught." Sub-row motion during a gesture works. Three things remained.

### The autocorrect on release (`scroll-pixel-perfect-snap`)

"It autocorrects to the original or the next/previous line depending on the
scroll direction." That is `settleScrollPixel` doing what it was written to
do: 120ms after input stops it eases the offset to zero, landing on the app's
current row -- the original line if the gesture moved less than half a row,
the next if more.

It exists because a terminal has no content for a partially visible row, so a
fractional rest leaves a blank sliver up to half a line tall at one edge.
`scroll-pixel-perfect-snap=false` keeps the gesture's true resting position
and accepts the sliver. Cheap experiment before committing to the compositing
work in SPEC section 4 Feature 2, which is the only way to have both.

Note the split in `settleScrollPixel`: the **in-flight term is retired
either way**. It describes rows still travelling down the pty and once the
gesture is over there are none, so leaving it would let a miscount pin the
offset permanently. Only the *fraction* is kept when snapping is off.

### Fast scrolling looks per-line, and always will

Not the GPU -- frames measured 17ms through hard flicks. At fling speed the
content genuinely advances two or more rows per drawn frame while the offset
is bounded to half a row, so there is no sub-row detail left to show. This is
an information limit, not a throughput one, and no tuning improves it.

### The flick-hang: one message instead of hundreds

Root cause was one mailbox message *per wheel report*
(`for (0..@abs(y.delta)) |_| mouseReport(...)`) against a 64-slot termio
mailbox. A big flick overran it, and `Mailbox.send` then falls back to a
**blocking** push (src/termio/mailbox.zig:95) on the GTK main thread: the
window froze until the app drained a queue the flick had overfilled, then
jumped to the end position.

Fixed by encoding the report once and queueing all repeats as a single
message. `mouseEncode` splits encoding from queueing, `queueRepeatedWrite`
packs the repeats into one `write_small` or `write_alloc`. Every report is
kept, so the scroll travels exactly as far as asked -- it just costs one queue
slot instead of hundreds. The alternate-scroll cursor-key path had the same
flaw and got the same treatment.

### nvim smooth-scroll plugins

neoscroll.nvim, vim-smoothie and mini.animate ease the *timing* of a jump by
issuing a sequence of small scrolls. They cannot produce sub-line movement --
nvim draws into a character grid like every terminal program. Sub-line
positioning can only come from the terminal. They compose with this, but a
plugin also multiplies the report traffic behind the flick-hang above.

## 2026-09-02 — the three things that actually stood between this and "Chrome"

Feedback: still not pixel perfect even scrolling as slowly as possible; Claude
Code's prompt box and hint text move when they should not; and text jumps up
then straight back down as it approaches the next line.

Three separate causes, all now fixed.

### 1. The touchpad was being amplified 10x before we ever saw it

`ecMouseScrollVertical` multiplied precision scrolls by a hardcoded 10. A few
pixels of finger movement was therefore already a whole row, and the position
was quantised long before anything downstream could draw it smoothly -- which
is exactly why scrolling as slowly as possible still jumped a line.

This was flagged as a known-unknown in the very first SPEC ("why 10?") and
turned out to be the single biggest obstacle to pixel-perfectness. Under
`scroll-pixel-perfect` the multiplier is now 1, so content tracks the finger
the way a browser does; `mouse-scroll-multiplier` tunes it to taste.

### 2. The in-flight term was being applied to synchronous scrolls

`scroll_requested_rows` was counted for *every* scroll. It only makes sense for
scrolls that go to the application over the pty and come back as a model change
milliseconds later; the renderer holds the picture still across that gap.
Viewport scrolling happens synchronously in-process, so counting those held the
picture still for a gap that never existed -- the text jumping and immediately
returning. Now counted only on the mouse-reporting path.

### 3. The offset moved rows the application parks outside its margins

Two bugs in one. `ScrollEvent.top` is where the scroll *started*, which for
insert/delete lines is the cursor row, not the margin -- so it was never the
right bound for deciding which rows may move. `ScrollEvent.region_top` now
carries the true top margin.

And with no known region at all the code fell back to the whole grid, which
shifts everything an application deliberately pins outside it: tmux's status
line, nvim's bars, Claude Code's prompt box and its hint line. An application
that redraws rather than scrolls never reports a region, so it now gets **no
smoothing** instead of a wobbling interface.

### Measurement note

Harness runs during this session read 30ms/frame rather than the usual 17ms.
That was not a regression: `realesrgan-ncnn` was running at ~79% CPU and it is
a *GPU* upscaler, competing for the 780M. Check `ps` before trusting a frame
interval from this harness.

## 2026-09-02 — the clip was erasing every interface outside the region

Confirmed by A/B: Claude Code's prompt box misbehaved only with pixel-perfect
on, so it was ours. Narrowing the remembered region did not help, and hunting
for why found the actual bug.

`cell_text.f.glsl` clipped **every** fragment falling outside the scrolling
region's pixel band:

    if (scroll_anim.x != 0.0) {
        ... if (outside band) discard;
    }

Not just displaced rows -- *all* of them. So for as long as any offset was
live, every glyph an application parks outside its margins was discarded:
tmux's status line, nvim's bars, Claude Code's prompt box. They vanished and
reappeared on every scrolled frame.

The tell was in the reports and I missed it twice: "the status **bar's word**
disappears". The bar stayed and the words went, because backgrounds come from
`cell_bg.f.glsl`, which correctly touches only rows inside the region. Only the
text pass had the bug. Reported later as the prompt box "scrolling down a line
and directly back up" -- it was flickering out, not moving.

Fixed by carrying a `flat float scroll_clip` from the vertex stage, set only on
rows the vertex stage actually displaced, and clipping only those.

### Verification, given no display

The session's display appeared to be asleep -- the window never reached
`info(opengl): loaded OpenGL`, so nothing rendered and the harness traced no
frames. GLSL compiles at *runtime*, so `zig build` proves nothing about it.

Control experiment instead: preprocess the `#include` by hand and compile both
the modified and the **unmodified** shaders with `glslc --target-env=opengl`.
Both produce exactly one identical diagnostic ("SPIR-V requires location for
user input/output", the interface block, same line number). It is a SPIR-V
requirement that does not apply to Ghostty's direct-GLSL path, and the change
introduces no new diagnostics. Useful trick to remember: `glslc` is installed
and the original file is the control that separates a real error from a
target-environment artifact.

## 2026-09-02 — the reverse-scroll oscillation

Report, scrolling steadily in one direction: "down, down, down, up one line and
directly back down one line, down, down, repeat."

A **full line** is the tell. The sub-row offset is clamped to half a cell and
can never move a whole line, so the application really was scrolling backwards
for one step -- meaning we sent it a wheel event in the wrong direction.

Cause, self-inflicted by take two. Rounding to nearest leaves the remainder
sitting *exactly* on the half-row threshold immediately after a scroll is
emitted -- the precise point where the next rounding tips over. A touchpad
always reports a little jitter of the opposite sign, so one stray sample
rounded backwards and emitted a reverse scroll, which the next sample undid.
Truncation had hidden this behind a full-row deadband; rounding removed the
deadband without replacing it.

Fixed with hysteresis: reversing takes a whole row of accumulated offset rather
than half of one. Turning around still needs only half a row of genuine
movement, because the remainder is already half a row past.

Very likely the same bug as the nvim complaint ("jumps a lot more now", "jump
up when scrolling down"): one spurious reverse notch there scrolls a whole
*logical* line, which with wrapped text is several rows.

### The clip fix verified, and a display trap

The previous commit could not be render-tested because the screen had gone to
sleep -- the window never reached `info(opengl): loaded OpenGL` and the harness
traced nothing. Worth recognising: **no OpenGL line in the log means nothing
rendered, not that the code is broken.** Once the display was awake, a capture
during an active offset shows the word "STATUS" -- which sits outside the
scrolling region -- rendering normally. Before the fix it was discarded.

### Two repo hygiene notes

`zig-out-release/` had been committed by a `git add -A` (722 files, including a
33MB binary). Untracked and added to `.gitignore`.

And do not `pkill -f` a pattern that also matches the shell running it: the
agent shell matched `emit.py slow` and killed itself mid-command twice, losing
the commit both times.

## 2026-09-02 — the Claude Code glitch, found by measurement

Four consecutive fixes changed nothing the user could see, because all four
were reasoned from descriptions. Logging the decision directly found it in one
capture.

### What the log showed

    region=0..54  rows_total=55  ->  pixoff=0.00
    region=1..54  rows_total=55  ->  pixoff=-16.28

Claude Code **alternates** its scrolling region between `0..54` and `1..54` as
it redraws. The rule at the time trusted a region that had been narrowed at
either end, so `1..54` enabled smoothing and `0..54` disabled it -- switching
on and off between frames, snapping the whole screen half a row back and forth.
That is the "goes down one line and directly back up" that survived four fixes.

### The rule that was wrong

Reserving rows at the *top* says nothing about where an interface lives. The
rows that must not move are the ones pinned *below* the content: tmux's status
line, nvim's mode line, a prompt box. The test is now `ev.bottom + 1 <
grid_rows` alone. Claude Code never satisfies it, so it gets no smoothing and
holds still; tmux and nvim both reserve at the bottom and are unaffected.

### Two lessons worth keeping

**The log printed the wrong field for six rounds.** `ScrollEvent.top` is the
cursor row for insert/delete lines, not the margin, and the margin is what the
decision uses. Reading `top` as the region led to a confident and wrong
conclusion that smoothing was inactive in Claude Code -- which a user A/B then
flatly contradicted. Log the value the branch actually tests, not a neighbour
of it.

**An A/B with one variable beats any amount of reasoning.** Running the *old*
code at the *new* speed (`mouse-scroll-multiplier = precision:0.1`, no
pixel-perfect) isolated speed from smoothing in a single test and proved the
fault was ours, after several rounds of arguing from symptoms.

Also: the harness's event regex has to track the log format. Changing the
scroll-event line silently made `scroll events: 0` in every report.

## 2026-09-02 — "reserved at the bottom" was wrong too; freeze the region instead

The bottom-margin rule from an hour earlier killed smoothing in tmux outright.
Measured with the tmux harness:

    region=1..54  rows_total=55  src=insert_lines  pixoff=0.00

tmux reserves the row at the **top**, because this user runs
`status-position top`. A rule keyed on the bottom margin rejected every tmux
scroll. Which end an application reserves says nothing useful.

The real difference between tmux and Claude Code was never which end, it was
**stability**: tmux holds one region, Claude Code alternates `0..54` /
`1..54` as it redraws, and re-deciding per event toggled smoothing between
frames.

So: adopt a region *between* gestures, never during one. Freezing the choice
for the duration of a scroll removes the toggling regardless of what the
application does with its margins, and an application with a stable region is
unaffected because there is nothing to re-decide.

### Harness limitation worth remembering

`tools/scroll-harness` drives scrolls through `tmux send-keys -X scroll-up`,
which is command-driven, not mouse-driven. `scroll_pending_px` is only set by
real pointer input, so **`pixoff` is always 0.00 in harness runs** and the
harness cannot measure pixel-perfect behaviour at all. It still measures the
region decision, frame pacing and the animation path. Anything touching the
input path continues to need a human.

## 2026-09-02 — an input-path harness, and what it proved

After ten rounds of the user testing by hand, the missing tool was obvious:
`tools/scroll-harness/harness.py` drives *applications* through tmux commands,
so the entire input path -- multiplier, momentum, rounding, sub-row offset --
had never been under test, and that is where every bug had lived.

### `scroll-input-script` and `tools/scroll-harness/input.py`

Synthesising touchpad events at the OS level needs uinput and root. Feeding
recorded samples in at the GTK handler costs nothing and exercises everything
that actually breaks. `scroll-input-script` replays one signed pixel delta per
8ms tick through the same handler a real touchpad reaches; `input.py` generates
gestures (slow drag, jitter, flick, reversal), runs them against a
self-contained tmux, and checks the drawn position for reversals, stalls and
whole-row jumping.

It found three real defects in its first hour, none of which needed a human:

**1. The renderer was never woken.** `scrollCallback` pushed the sub-row
position into the renderer mailbox but never called `queueRender`, so the
message sat there until something else happened to wake the thread. The offset
was read frames late or not at all -- it stayed put while the model stepped a
row at a time, which is precisely the whole-row jumping the feature exists to
remove. One line.

**2. Deciding the region only between gestures smoothed nothing.** The previous
fix froze the region for the duration of a gesture, but a gesture that began
before any region was known froze on *nothing*. Now decided once, on the first
scroll of the gesture, and held: `scroll_region_locked`.

**3. The harness itself was wrong twice**, which is worth recording because
both mistakes are easy to repeat: the replay began before tmux was in
copy-mode, so it measured startup output rather than the gesture; and it
inherited the user's `mouse-scroll-multiplier`, so it measured their settings
rather than the code. It now pins the multiplier and ships its own `tmux.conf`.

### What it then proved about the remaining jumping

    req=1 applied=0     <- one scroll in flight
    req=2 applied=1     <- still one in flight
    req=3 applied=2     <- always one in flight

The offset saturates at its half-row clamp and **freezes for ~12 frames
(~200ms)** -- the time tmux takes to actually perform the scroll. That is
longer than the finger takes to cross one row, so a scroll is *always* in
flight, the offset is permanently clamped, and the only motion left is the
model's whole-row steps.

This is not a tuning problem. While a scroll is outstanding the display has to
*lead* the model, and in the alternate screen a lead is a hole exactly as tall
as the lead. Clamping the lead to half a row is what freezes it. The options
are an application that answers within a frame -- not something we control --
or keeping the previous frame so a full row of lead can be drawn without a
hole. The second is SPEC section 4 Feature 2, and it is now the only thing left
between this and the goal.

### A trap in the trace itself

`traceScrollFrame` logs `top`/`bot` from `scroll_anim`, not the region actually
published to the shader. Reading `top=0 bot=0` as "no region" cost an hour.

## 2026-09-02 — measured: tmux answers in 0.3ms, the 200ms was ours

The freezing was blamed on tmux being slow. Measuring it directly, outside
Ghostty, with a pty harness sending SGR wheel events:

    tmux wheel->output latency: n=12 min=0.3ms median=0.3ms max=0.5ms

So the ~200ms was entirely inside Ghostty, and therefore fixable. **Measure the
other end before concluding something external is slow.**

### What was actually stuck

`inflight=1` permanently. The compensation for "a scroll we asked for that the
application has not performed yet" was never retired, so the offset sat on its
half-row clamp for the whole gesture and only whole-row model steps showed.

The cause is an ordering race, and it defeated two designs in a row. tmux
answers a wheel event in 0.3ms -- **faster than our own cross-thread message
announcing that we asked for it**. So the model's scroll can be seen *before*
the request. A pair of counters guarded by `asked > 0` skipped the credit and
stayed one apart for ever; a flag retired on the matching event was cleared
before the request that set it, then set again and never cleared.

Now: count both sides, take the difference, and clamp it towards zero from the
far side, so seeing the scroll first reads as "nothing in flight" rather than
as a scroll the other way. A deadline (`scroll_outstanding_ms`) expires the
compensation as well, so an application that ignores the wheel makes the
picture lag instead of freezing.

### Result, from the input harness

| | before | after |
|---|---|---|
| frames where the picture moved | 25 | 107 |
| median step | 36.6px (0.96 rows) | 4.8px (0.13 rows) |
| full-row jumps | 56% | 13% |

Genuine sub-row motion for the first time.

### Still failing

One full-row jump and one reversal per emitted scroll remain, at the moment the
remainder wraps: the display steps back a row before the compensation covers
it. Reproducible in `input.py`, so it can be chased without a human. `jitter`
is worst (28% reversals) and is the closest gesture to real use.

## 2026-09-03 — the wrap skip narrowed, and where it now sits

User's description finally matches the harness exactly: "smooth until the lower
half of the line, then it directly skips to the next line." That is the
full-row jump `input.py` reports at every remainder wrap, so it can be chased
without a human from here on.

### Fixed: an event with no identity clearing the wrong compensation

`scroll_outstanding` was cleared whenever *any* scroll arrived in a matching
direction. Scroll events carry no identity, so a scroll belonging to an earlier
request cleared the compensation for the request just made, and the picture
stepped back a whole row exactly at the wrap. The counters already say what is
outstanding; the flag is now only a direction and is never cleared by an event.

Full-row jumps: slow 13% -> 11%, jitter 26% -> 14%, flick 27% -> 17%.

### Tried and reverted: removing the expiry deadline

The deadline drops the compensation in one frame, and a fresh request re-arms
it, so when an application is slow the offset swings a whole row back and
forth. Removing it looked obviously right and was badly wrong: with the
compensation permanently clamped on, the picture stops moving altogether --
**102 moving frames down to 6**. Restored, with the measurement recorded in the
code so it is not "cleaned up" again.

### Where it stands, measured

| gesture | median step | full-row jumps | reversals |
|---|---|---|---|
| slow | 0.13 rows | 11% | 20% |
| jitter | 0.34 rows | 14% | 48% |
| flick | 0.26 rows | 17% | 33% |

Against the 0.96 rows/step and 56% jumps of a few commits ago this is a large
improvement, and sub-row motion is real. It is not finished: the reversals are
genuine and large (jitter: median 15px backward, p90 32px -- not sub-pixel
noise, verified), and they come from the expiry/re-arm cycle above.

### The next thing to try

The compensation is binary -- fully on or fully off -- and both edges are one
frame wide. It should ramp instead: fade in over the frame after a request and
out over a few frames if the application does not answer. That removes both the
expiry snap and the re-arm snap without reintroducing the freeze, since it is
never clamped on indefinitely.

### Not yet done, requested

Extend `input.py` to open a long nvim document and resume a Claude Code
session, scroll one notch at a time, and record where a fixed interface element
(nvim's mode line, the prompt box) sits after each notch. The user's report is
that the box lands somewhere different each time, which such a test would pin
down exactly.

## 2026-09-03 — ease out only what nothing cancels

The compensation for "a scroll asked for but not yet performed" was binary,
switching on and off in one frame, and both edges showed. The fix is not to
ramp all of it: **two of the three transitions must stay instant, because each
exactly cancels something happening in the same frame.**

  * **Arming** cancels the remainder wrapping by a whole row when a scroll is
    emitted.
  * **Disarming because the application caught up** cancels the row of content
    it just moved.
  * **Disarming because the request went unanswered** cancels nothing. That is
    the only one free to take its time, and it is the one that was swinging the
    picture a row back and forth on a slow application.

`advanceScrollFlight` follows the counters exactly while a request is live and
eases the residual to zero over `scroll_flight_ramp_ms` once it expires.

### Measured

Backward steps on the `slow` gesture, which is the one the user describes:

| | before | after |
|---|---|---|
| median backward step | 15.4px | 1.9px |
| p90 | 32px | 2.2px |
| steps over 5px | 47 of 53 | 0 |
| median forward step | 4.8px | 2.2px (0.06 rows) |

### The harness was failing on invisible noise

Its reversal test counted any backward movement over 0.01px, so a 2px wobble at
60fps -- which no one can see -- failed the run, while genuine row-sized jumps
were reported with the same weight. It now counts only reversals above a tenth
of a row and prints the magnitude distribution, so the number means something.
Current: slow 3.2%, jitter 7.8%, flick 4.0% visible reversals.

### Still open

`jitter` keeps five visible reversals of 11-13px per run. It is the gesture
closest to a real finger, so it is the one to chase next. And `flick` is 40%
whole-row steps, which is expected rather than a defect: at fling speed the
content genuinely advances a row per frame and there is no sub-row detail left.

### Next, in order

1. nvim, where one logical line occupies several rows and a notch scrolls all
   of them. Present in unmodified Ghostty too, so it needs a new mechanism
   rather than a fix.
2. Claude Code's prompt box. The user's suggestion is to mask it. Worth
   measuring first with the notch-at-a-time test they proposed: scroll one
   notch, record where the box sits, repeat.
3. Keeping all of this rebaseable onto upstream.

## 2026-09-03 — measuring honestly: the animation path is currently better

The user reported the ramp fixed nothing and had added rapid up-and-down
movement. That was right, and two of my measurements had been wrong.

### Why the measurements lied

**1. The harness did not notice when the application never scrolled.** In the
run that produced the "fixed" numbers, `model_rows` never changed for the whole
gesture: tmux was not scrolling at all, so every request expired unanswered and
the compensation armed and faded repeatedly. That looks like a rendering bug and
was reported as a good result. `input.py` now fails such runs as `INVALID`.

**2. Frame rate changes the score.** The good run was taken while
`realesrgan-ncnn` was using 79% CPU. Fewer frames drawn means fewer chances to
observe a reversal, so load *improves* the numbers. Check `ps` before comparing
two runs.

Both mistakes flattered the result. Rerun under a quiet machine with a
responsive application, the same binary and gesture score 15% whole-row jumps,
not the 11% claimed.

### Where the two approaches actually stand

Same machine, same gesture, minutes apart:

| | animation (`scroll-animation`) | pixel-perfect |
|---|---|---|
| visible reversals | 0 | 5 (4.9%) |
| whole-row jumps | 0 | 15 (15%) |
| median step | 0.20 rows | 0.06 rows |
| frame interval | 16.7ms | 17ms |

Pixel-perfect takes finer steps, and that is real. But it still skips a whole
row at 15% of moving frames -- the "smooth until half way down the line, then a
skip" the user keeps reporting -- and it oscillates whenever an application does
not answer a wheel notch promptly, because the compensation has nothing to
cancel against.

**The animation path cannot oscillate**, because it never depends on an
application answering: it renders the transition between two model states it
already has. That is why it scores clean.

### The conclusion this points to

Pixel-perfect scrolling asks an application to move in sub-row steps it has no
way to make, then papers over the round trip. Every remaining defect traces to
that. Unless the terminal can render content the application has not sent -- it
cannot, in the alternate screen -- the honest ceiling is: animate the transition
between the states the application does give us, and drive the *progress* of
that animation from the finger rather than from a timer.

That keeps everything the finger-driven work bought (position tracks the
gesture, no fixed duration) and drops the part that cannot work (asking for
positions between two application states). It is a smaller change than it
sounds: the animation machinery is already written and measures clean.

### Harness fixes this round

  * gesture magnitudes scale with `1/multiplier`, so a run scrolls the same
    distance at any sensitivity -- at `precision:0.1` the old gestures emitted
    one scroll and the harness called it smooth
  * `--mult=` to reproduce a user's sensitivity
  * reversals judged against a tenth of a row, with the magnitude distribution
    printed
  * `INVALID` when the application never scrolled
  * `harness.py`'s trace pattern, which the new trace format had silently
    broken into reporting zero frames

## 2026-09-03 — ease-out, which is what a browser is doing

User, on the animation path: "much better really... but it's lacking a little
compared to Chrome. Is there some sort of curve in Chrome's mouse scroll?"

Correct diagnosis. The ramp was deliberately *linear* -- constant speed, chosen
earlier to kill an exponential tail that never arrived. Linear motion leaves at
full speed and stops dead, which reads as mechanical however short it is. A
browser eases out: most of the travel immediately, decelerating into place.

`advance` now computes position from elapsed time along a cubic ease-out rather
than integrating a fixed step. Two consequences worth having:

  * **Feel.** Step sizes on the same gesture went from a flat 7.6-8.1px to
    7.3px median with a 22.8px maximum -- early frames travel far, late frames
    barely move.
  * **Less lag, not more.** Mean lag behind the model fell from 0.40 rows to
    0.29, because most of the distance is covered in the first third.

Computing from elapsed time also makes a dropped frame land where it should
instead of leaving the animation behind, which the old integrating form could
not do. There is a test for that.

Default duration 80ms -> 120ms. A linear ramp had to be short or it felt like
lag; an eased one spends its tail decelerating, so a longer curve reads as
smoother rather than slower, and it is closer to what a browser uses.

Still 0 reversals and 0 whole-row jumps.

## 2026-09-03 — Claude Code's prompt box, made reproducible then held still

The user's own proposal -- scroll one notch, record where the box sits, repeat
-- turned into `tools/scroll-harness/pinned_box.py` and the `notch` gesture.

### Reproducing it without Claude Code

Running the real thing is not reproducible (it wants a session and a network,
and renders differently every time), and it exits immediately under a bare pty.
The stand-in reproduces the two behaviours that were actually measured from it:

  * it scrolls its history with a region running to the **last row**, so it
    never reserves the rows its box sits on
  * it redraws the box afterwards, alternating the region's top margin between
    1 and 2 exactly as Claude Code alternated `0..54` and `1..54`

Two traps in writing it, both worth remembering for any future fake TUI:

  * `sys.stdin.buffer.read()` on a non-blocking fd returns `None` even with
    bytes waiting. Use `os.read`.
  * without `tty.setraw`, the line discipline holds input until a newline, so
    mouse reports never arrive at all.

With those fixed the test fails on exactly the user's complaint:

    FAIL: pinned interface moved on 178 frames (region reaches row 57, up to 40.0px)

### Why it cannot be fixed automatically

tmux and nvim both reserve the rows they pin an interface on, which is why
their bars hold still without any help. Claude Code does not, so the terminal
is told the box is ordinary content.

Nothing distinguishes the two from outside. **After a scroll every row in the
region is dirty, whether it moved or was rewritten**, so per-row dirty tracking
-- the obvious candidate -- cannot separate them. Telling them apart needs the
pre-scroll contents to compare against, which is the same machinery as
compositing.

### `scroll-animation-reserve-bottom`

A manual reservation for applications that will not make one. `2` covers a
prompt box and its hint line. Measured: box moves on 169 frames with `0`, holds
still with `2`, and 0 reversals either way.

Also switched the animation's region to `ev.region_top` rather than `ev.top`,
which for insert/delete lines is the *cursor* row and was never the right bound
for which rows may move. tmux path unchanged and still clean: 0 reversals, 0
whole-row jumps, 0.23 rows/step, mean lag 0.29 rows.

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

## 2026-09-03 — Upstream exposure, measured

The question was whether this fork can keep tracking upstream. Answer: yes,
and the risk is much lower than the diffstat suggests.

**Measured on 96 upstream commits (three days' worth).** All 36 commits
rebased with zero conflicts; the result builds and `zig build test
-Dtest-filter=scroll` passes.

**Why it is not fragile.** Of ~5,100 changed lines, only **18 are upstream
lines replaced**. Everything else is added alongside. Git only fights over
lines both sides edited, so an additive patch survives churn that a rewrite
would not.

The 18 sit in:

| Where | What | Upstream churn |
|---|---|---|
| `src/Surface.zig` — `scrollCallback`, `mouseReport` | genuinely rewritten | ~17 commits/yr (~1.4/mo) |
| `src/apprt/gtk/class/surface.zig` | the `10.0` precision multiplier | rare |
| `src/renderer/*`, `src/terminal/Terminal.zig` | one-line hooks at function ends | low |

Expect a small conflict in `Surface.zig` roughly monthly. Rebase in small
batches; a month of upstream is a five-minute conflict, a year of it is not.

### The trap that actually bit

The first real rebase attempt died at commit 16/36, not on upstream code:

```
error: The following untracked working tree files would be overwritten by merge:
    zig-out-release/bin/ghostty
    ... 722 files
```

`2be4d9e9f` had accidentally committed `zig-out-release/` (722 files, 33MB via
`git add -A`); a later commit deleted them again, so **HEAD looked clean and
the problem was invisible** — but replaying that commit still tries to write
722 files that exist on disk untracked, and aborts. It would have blocked
every future rebase.

Note the trial rebase in a scratch worktree did **not** catch this, because a
fresh worktree has no build output on disk. A rebase rehearsal must run
somewhere with the same untracked files as the real tree, or it is testing a
different question.

Stripped with:

```
git branch -f smooth-scroll-backup smooth-scroll   # first
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --index-filter \
  'git rm -r --cached --ignore-unmatch -q zig-out-release' \
  --prune-empty main..smooth-scroll
```

Verified by tree hash: `b5d95d382…` before and after, all 36 commits kept, no
commit anywhere on the branch touching build output. `zig-out-release/` was
already in `.gitignore`, so it cannot come back by accident.

### Silent-failure watch list

A conflict is loud and therefore fine. These would rebase cleanly and stop
working quietly:

- **Uniform layout.** Already guarded — the `comptime` check in
  `src/renderer/opengl/shaders.zig` asserts `scroll_anim` is at byte 144, so a
  new uniform inserted ahead of it is a build error naming the real offset,
  not a dead animation. GLSL compiles at *runtime*, so this guard is the only
  thing standing between an upstream uniform change and a silent no-op.
- **`noteScroll` hooks.** If upstream adds a new way to scroll the grid, our
  hooks are not on it and that path silently stops animating. No error. This
  is the standing argument for running `tools/scroll-harness/input.py` after
  every rebase.

### Routine

```
cd ~/dev/ghostty && git fetch origin main && git rebase origin/main \
  && zig build && zig build test -Dtest-filter=scroll \
  && python3 tools/scroll-harness/input.py
```

## 2026-09-03 — Why nvim and Claude Code never animated

Both had the same cause, and it is not one `noteScroll` can ever see: **the
content moved but no scroll operation was sent.**

### Measured, not guessed

nvim under a pty, same file, same movement (3x Ctrl-E), counting what nvim
actually writes to the terminal:

| nvim setting | scroll ops | bytes |
|---|---|---|
| `smoothscroll` | **0** | 9008 |
| `nosmoothscroll` | 3x `CSI M` + `DECSTBM` | 1873 |

With `smoothscroll` on, nvim does not scroll the grid when moving within a
wrapped line -- it repaints every row, five times the traffic. There is no
scroll operation to hook. With it off nvim scrolls properly and the animation
works, but a wrapped line then moves in one jump, which is the complaint
`smoothscroll` was turned on to fix. The two were mutually exclusive.

Claude Code is the same shape for a different reason: it runs on the *primary*
screen, so scrolling it moves our own scrollback viewport via `scrollViewport`,
which has no hook at all. `noteScroll` is called from exactly four places --
`scroll_up`, `scroll_down`, `insert_lines`, `delete_lines` -- all
alternate-screen operations. The gap was already described in a comment on
`settleScrollPixel` ("a plain shell, which scrolls its viewport without
touching the terminal model") and treated only as a hazard, never as something
to animate.

### The fix: stop asking the application

`ScrollAnim.detectShift` hashes each row and finds the whole-row offset that
maps this frame onto the last one. If row *i* now holds what row *i+3* held,
the screen scrolled by 3 -- however the application drew it.

An earlier note in this file said comparing frames was too expensive. That was
wrong, and the reason is worth recording: it was reasoning about comparing
*cells*. At 60 rows, testing shifts of +/-8 is ~960 comparisons of one u64 each,
against the ~9KB of text nvim just made us parse anyway. Hashes are kept only
while a gesture is in flight, so it costs nothing at rest.

Guards, each with a test:

- **Gate on recent input** (`repaint_scroll_idle_ms`). Without it every
  screenful of program output would slide instead of appear.
- **`same >= best_matches` veto.** Blank and repeating rows match at every
  offset at once, so a still screen would otherwise find a shift and animate
  forever.
- **Confidence floor** (rows *and* ratio) so a full repaint with unrelated
  content is not read as a scroll.
- **`had_event`**, so a real scroll event is not counted twice.

### Verification status -- read this before trusting it

`detectShift` is unit tested (9 tests, negative-control checked: the suite does
fail when the expected value is wrong). **The integration is not verified end
to end.** `tools/scroll-harness/input.py` cannot currently drive an
application: the replay runs and reaches `setScrollPixel` (`pending=36.00`,
`inflight=1` in the trace) but the terminal never scrolls (`model_rows=0`), so
every end-to-end number it printed today was measuring startup output, not the
gesture. Fixing that is the next job, and nothing here should be called working
until it passes.

Traps banked while chasing this:

- `scrollemit` only logs on the pixel-perfect path, so `scrollemit: 0` on the
  animation path is expected and is *not* evidence the replay failed.
- `@n` in a replay script waits n *frames* of 8ms, not n milliseconds.
- `input.py`'s `MULT` had no module-level default; every gesture died with a
  bare `NameError` unless `--mult=` was passed.
- nvim launched with `--clean` ignores wheel events unless `set mouse=a`.

## 2026-09-03 (later) — Keyboard scrolling, easing, and the pixel-perfect removal

### Keyboard-driven scrolls were invisible

Holding `j`/`k` in vim, and paging through `bat`, did not animate. Same cause
for both: the repaint detector's gate only accepted a *mouse* scroll, and the
keyboard reaches none of the scroll plumbing. A new `input_activity` renderer
message marks a keypress that produced pty input, and after the pixel-perfect
removal the wheel sends the same message, so there is now one activity
timestamp rather than two.

The window is 150ms. Key repeat runs at roughly 30Hz so it stays continuously
fresh while a key is held, and it closes promptly on release -- which is what
keeps the output of a command you just pressed Enter on from sliding past
instead of appearing.

### Easing is a setting

`scroll-animation-easing`: `ease-out-cubic` (default, unchanged behaviour),
`ease-out-quint`, `ease-out-quad`, `material`, `linear`. The last three go
through a real cubic-bezier solver (Newton with a bisection fallback), so
`material` is genuinely `cubic-bezier(0.4, 0, 0.2, 1)` -- the curve browsers
use to move something into place, which eases *in* as well as out and reads as
the content having weight.

Tested: every curve starts at 0, ends at 1, never moves backwards, the
ease-outs lead a linear ramp at the halfway point, and the solver reproduces
the identity bezier `cubic-bezier(0.25, 0.25, 0.75, 0.75)`.

### Pixel-perfect is gone

Removed `scroll-pixel-perfect` and `scroll-pixel-perfect-snap` and everything
they owned: `setScrollPixel`, `advanceScrollFlight`, `settleScrollPixel`,
`scrollPixelOffset`, the `scroll_pixel` renderer message, the in-flight
compensation counters, the frozen scrolling region, and the reversal hysteresis
in `Surface.scrollCallback`. The gtk precision multiplier is back to upstream's
plain `10.0`.

The coupling worth knowing about, because it would have failed *silently*: the
repaint detector's gate read `scroll_input_ts`, which only `setScrollPixel`
set. Deleting that path with the gate untouched would have left mouse-driven
detection dead with everything still compiling and every test passing. The
wheel now sends `input_activity` directly.

Kept, because they are independent fixes and still correct:

- the rounded-delta remainder fix in `scrollCallback` (upstream discards the
  sub-cell remainder on every scroll)
- `queueRepeatedWrite` / `mouseReportRepeat`, which coalesce a flick's mouse
  reports into one mailbox message instead of overrunning the 64-slot termio
  queue and freezing the GTK thread

`narrowed` survives the removal: it is what decides whether
`scroll-animation-reserve-bottom` applies.

### Still not verified end to end

`tools/scroll-harness/input.py` still cannot drive an application. Its defaults
no longer pass the deleted flags, but the underlying fault is unfixed: the
replay reaches `scrollCallback` and rows are emitted (`pending` cycling,
`inflight` set before the counters were removed) yet the application never
scrolls. Everything in this section was verified by unit tests, the full suite
(291 scroll tests, 3837 overall), and the compiler -- not by watching a screen.

## 2026-09-05 — a scroll is not always full width

Reported in yazi: with a scrollable nvim buffer in the preview pane, scrolling
it slid the file lists in the left and middle panes too, which then snapped
back. A regression from the repaint detector.

### Reproduced before changing anything

The detector hashed one value per **row**, so it had no way to express a scroll
confined to some columns. Modelling yazi offline -- three panes, only the right
one moving, chrome on the first and last row:

```
FIRES: shift=3 span=1..56 (of 58 rows)
```

It found the preview's shift correctly and then animated those rows across the
whole width, dragging the stationary panes and springing them back when the
animation ended.

Two things were wrong at once, and the first hid the second:

1. The span came from *changed* rows, so it stretched over every row the
   preview touched.
2. Blank and static cells match at every offset, so the left pane's empty
   region helped confirm a shift it had no part in.

### The fix

One hash per **cell** instead of per row, and `detectShift` now returns a column
range as well as a row range. A column qualifies only if the cells that
**changed** in it are the ones the shift explains -- so a stationary pane, whose
cells did not change, contributes to neither the numerator nor the denominator
and simply drops out. The longest contiguous run of qualifying columns is the
moved region.

Counting only changed cells is the part worth remembering: the previous ratio
counted every compared row, and an unchanged row matches at *any* shift, so a
mostly-still screen could confirm an arbitrary one.

On the GPU, `scroll_anim_cols` carries the range and `cell_text.v.glsl` /
`cell_bg.f.glsl` gate on `grid_pos.x` as well as `.y`. The std140 offset guard
now covers both vec4s (144 and 160).

This also fixes tmux vertical splits, which have exactly the same shape and
would have been just as wrong.

Cost: ~12k cell hashes per frame (FNV-1a, cheaper than Wyhash at this size) and
~200k u64 comparisons for the shift search, and only while a gesture is in
flight.

### Verification

`detectShift` has 11 tests including the yazi case (asserting the region stops
at the pane boundary) and a full-width scroll (asserting it is *not* narrowed).
Negative-controlled: asserting the wrong column reports `expected 0, found 40`.
Full suite 3839 tests.

GLSL is compiled at runtime, so `zig build` says nothing about it. Checked with
`glslc` after inlining `common.glsl` by hand, against the pristine file as a
control: `cell_bg.f.glsl` compiles clean, and `cell_text.v.glsl` fails
*identically to the control* at line 189/190 -- an interface block that SPIR-V
wants a location qualifier on, pre-existing and not reachable through Ghostty's
own runtime path. Compiling a shader here without that control would have
looked like a real failure.

## 2026-09-23 — two "shakes", two causes: nvim really reflows, and yazi's preview never scrolled

### First: the binary was not HEAD

`~/tools/ghostty` was built 2026-09-08 03:13 from ~286 uncommitted lines (the
region union of 09-07 and the four-way column verdict of 09-08), not from
`978f79386` as its version string says. Committed unchanged as `07440d5ac` and
`5f8669dd1` before anything else, so history matches the binary that was
reported on. Both filtered test runs passed first (91/91, 97/97).

### Symptom A — nvim jerks when the cursor crosses a rendered line

Driven live (`ydotool`, 400ms apart, fixture `$$` block at lines 7-9, a 33-line
file on a 59-row screen so nothing can scroll the viewport):

    j 6->7   scroll event: rows=6 region=6..56 src=delete_lines
    j 7->8   repaintscroll shift=-1 rows=6..58 ... ; shift=-6 rows=6..57 cols=0..102
    j 8->9   repaintscroll shift=-1 rows=13..58; shift=1 rows=13..57
    j 9->10  repaintscroll shift=1 rows=13..37 cols=0..102
    (k back: shift=7, then scroll event rows=-6 insert_lines)

and nvim's own answer to "which screen row is buffer line 11 on":

    cursor 6 -> row 15,  7 -> 9,  8 -> 16,  9 -> 16,  10 -> 15

**Net −6 / +7 / −1 rows, exactly what the log reported.** The detector is not
misreading a height change as a scroll: the text below the block really moves,
and the first move is not the detector at all — it is nvim's own `DL`/`IL`,
which the scroll-event path animates with no input gate. The 150ms keyboard
window is not what lets it in.

Cause, in `markdown.lua`: a display block conceals its source rows with one
`conceal_lines` mark PER ROW, each anti-concealing independently. On the
opening `$$` the rendering (virt_lines anchored to that row) is hidden but
the other source rows stay concealed: 6 rows shorter. One row in, the
rendering is back and a source row is revealed: 1 taller. The table wrapper
already moved to one mark with `end_row` for this reason (SETUP-LOG
2026-09-14); display maths did not. Not fixed here — see "Open".

Mitigation, measured (two alternating pairs, `--config-default-files=false`):

| duration | visibly moving | more than a row off |
|---|---|---|
| 300 | 250–262 ms | 67–95 ms |
| 120 | 100–101 ms | 34 ms |

Peak is clamped at `max_lag_rows` either way, so the jump's size is unchanged.

**Trap:** `--scroll-animation-duration=120` on the command line did NOTHING
the first time — both runs came out identical. `config` includes
`scroll-state.conf` via `config-file`, and an include is loaded after CLI
flags, so it wins. Measure with `--config-default-files=false`.

### Symptom B — yazi's preview tears along a column boundary

`yazi ~/playground`, j/k down the middle column. **Nothing ever scrolls
there** — every entry fits on screen; each key only moves the selection and
replaces the preview. Yet, on the installed binary, 25 detections in 40 keys:

    repaintscroll shift=8 rows=2..58 cols=85..101 of 59x103   (pane is 52..101)
    repaintscroll shift=5 rows=2..58 cols=67..101
    repaintscroll shift=1 rows=2..58 cols=14..101             (list AND preview)

The hypothesis that the run stops partway through the pane is right about the
shape and wrong about the cause: these are not scrolls at all. Reproduced
offline on `tmux capture-pane -e` frames of the same size (effective SGR
state, not SGR history — the first parse got that wrong and invented
disagreements) with a Python port of `detectShift`, which reproduces the live
verdicts. Three kinds of cell were voting without carrying evidence:

1. **Blanks.** Ten entries -> five: the padding yazi paints to the pane edge
   in each entry's colour lines up with padding five rows away (`S11/8`) while
   the name columns contradict outright (`X12/5`). The region is exactly the
   empty tail of every line.
2. **Restyled cells.** The relative-number gutter (yazi's relative-motions,
   like nvim's) genuinely shifts a row per key and anchored a run. The
   selection bar then restyled `csapp-md-backup2` in place, whose shared
   prefix equals the row above in the bar's colour: weak `2/2` columns out to
   col 34, the head of each name sliding and its tail not.
3. **A lone coincidence, far away.** Real list scroll in `/usr/bin`: one hex
   digit of the preview's BuildID agreed with the digit below it, and the
   09-08 weak-column rule let that one cell widen the region from 49 to 76
   across 26 neutral columns and the pane border.

Tried and rejected: letting a cell that STAYED PUT vote against the shift.
Right in principle, but on a real scroll the low-information columns (an icon
identical on every row) have only edge artifacts left to vote with — pane
border rows, the fixed selection bar, the row entering at the bottom compared
against the border — and it narrowed `/usr/bin` from 20..49 to 24..42. A
narrowed real scroll is the 09-08 tear.

### The fix (`26e099f78`)

- Cells are keyed `cellKey(glyph, rest)`: glyph in the low 32 bits (a space
  counts as blank), FNV of the whole cell folded into the high 32. Synthetic
  test hashes below 2^32 mean what they did before.
- A cell **testifies** only if its glyph changed, to a non-blank glyph — in
  the shift score and the column verdict both. A testifying cell still has to
  match in full.
- Weak columns gather into clusters across at most `weak_bridge_cols = 2`
  neutral columns, and only a cluster with a strong column sets a bound.
  Measured: the widest legitimate bridge on real prose was 1 (a word gap);
  every false one was 22-34. Strong columns still bridge any gap (HEAD's rule).

### Verification

- `zig build test -Dtest-filter=detectShift`: 94/94. Three new tests fail on
  the old code with the modelled values (a shift where there is none;
  `expected 29, found 56`; `expected 1, found 19`) and pass after. Each rule
  was broken on its own and its test, and only its test (plus the one that
  shares it), failed. All 11 old tests pass, the four negative controls
  included.
- Offline, captured frames: nvim C-e/C-y keep `cols 0..101`; the genuinely
  scrolling `/usr/bin` list goes from `20..76`/`20..72` on two frames to
  `20..49` on all ten; the yazi selection moves stay within `14..18`.
- **Live**, same 29x103 window, same 40 keys, `tools/scroll-harness/drive-yazi.sh`:

  | build | detections | touching the preview | shift > 1 |
  |---|---|---|---|
  | before | 25 | 17 | 8 |
  | after | 40 | **0** | **0** |

  The four keys where the list really scrolled at 29 rows came out
  `±1 cols=18..49`, the whole list body. nvim C-e/C-y live: all 8 through
  nvim's own full-width scroll events, detector correctly idle.
- No shader changed, so no `glslc` check was needed this round.
- Installed build is `cmp`-identical to the one verified.

### The harness

`drive-yazi.sh` added: real keys, a probe confirmed by `ya sub hover` before
any burst, per-key log slices, PID-only cleanup. It closes the gap for yazi
only; `input.py` still cannot drive an application and that is still undiagnosed.

### Open

- **Symptom A's actual fix is in `markdown.lua`**, and it is a trade-off:
  one mark spanning the block (so it anti-conceals as a unit — one move in,
  one out, instead of −6/+7/−1), or `conceal = false` (never reflows, but the
  LaTeX source is never visible, even in insert mode given `render_modes`).
- **The relative-number gutter rolls a row on every j/k** in nvim and yazi
  (cols 0..3 / 14..18). A real shift of real glyphs; left alone.
- **`scroll_anim_app_region` outlives its gesture.** It is only cleared when
  `detectRepaintScroll` runs while idle, and that needs an `updateFrame`, so
  after one `scroll event` it kept clamping gutter detections to rows 6..36
  for eleven keypresses 400ms apart. Minor; not either symptom.

## 2026-09-23 (later) — held keys, and the gutter's neighbours

Reported against `26e099f78`, all measured before changing anything:

- **"1000ms feels the same as 300."** The setting works (single `C-e`: 84ms
  at 120, 733ms after a live reload to 1000, 726ms fresh). What made it feel
  the same: with a key HELD, every push restarts the ease from zero, the
  offset pins at the `max_lag_rows` cap and each row beyond it is clipped to a
  snap. Longer durations clip more — at 1000ms the old build moved 1.8px a
  frame and jumped a whole row 13 times in 2s. Fix: while pushes land on a
  live animation the burst eases over at most `pace_intervals` (4) input
  intervals; slower input or a fresh gesture keeps the configured duration.
  Test: 220px clipped -> 0. Live, nvim in tmux: median 6.2px/frame at both 300
  and 1000.
  Also: an edit of `scroll-animation-duration` in `config` is overridden by
  the `scroll-state.conf` include; `gt scroll` is the way to set it.
- **nvim, `j` held at the bottom, "just jumps".** Not the fork (the previous
  binary is identical). The remaining whole-row steps are rows arriving
  several at a time — tmux coalescing (+3, +5 rows, over the 2-row cap) and
  nvim falling behind on a heavy markdown chapter and catching up in one
  +28-row redraw (over `max_animated_rows`, so a jump by design).
- **yazi's relative numbers dragged their surroundings.** Rows: the range was
  every row that *changed* in the region's columns, reaching the status bar
  (it names the hovered file) and swallowing the bottom border in between —
  the border's `─` slid with the numbers. Now the rows that *moved*, plus
  `|shift|` arriving rows. Columns: the selection's rounded cap and
  open-folder icon genuinely move with the cursor one blank column from the
  numbers; `weak_bridge_cols` 2 -> 0 (strong columns still bridge anything).
  On captured prose and real list scrolls, no region changed except that a
  real yazi list scroll no longer includes border + status bar.
- **yazi, `j` held through the wrap, "whole screen shaking".** Not reproduced
  as such. Held through two wraps in `~/playground` and through an 80-entry
  list in tmux: no large detections either build. The one screen-wide
  difference found is the old build drawing rows 2..58 (border and status
  bar) on every key, now 2..28. Left for the user to re-test.

Commit `e94751925`. 96/96 detectShift, 99/99 ScrollAnim; installed build
`cmp`-identical to the one measured.

## 2026-09-23 (evening) — a deliberate multi-row scroll slides whole

yazi gained `J`/`K` (5 rows). `max_lag_rows` capped every push at 2 rows, so
each `J` snapped 3 rows and slid 2 — the cap was written for bursts, not for
one deliberate move. `push` now caps at `max(limit, |this push|)`. Measured
live (yazi in tmux, 80 entries, 28 keys): first-frame displacement 40px ->
100px on every key. `ScrollAnim` 100/100, `detectShift` 96/96. The same change
lets tmux's 3-5 row batches of nvim scrolling slide instead of snapping.

## 2026-09-24 — smooth at speed: a real-device harness, ghost rows, a spring

User: slow input feels fine, fast doesn't (held j, fast touchpad, an MX
Anywhere 3S wheel in free-spin) -- wants Obsidian/VS Code smoothness.

### The harness (`tools/scroll-harness/fast/`, commit `ec0bfd584`)

Real input the whole way: **uinput devices** (`devices.py`: a hi-res wheel
sending 1/8 notches, a clickpad shaped like the ASCP1209) go through
libinput -> KWin -> GTK -> Ghostty exactly like hardware; ydotool for keys.
`/dev/uinput` is ACL-writable by the user, no root. `run.py` runs a fullscreen
fork window -> the user's tmux (TPM stripped) -> the user's nvim on CSAPP
ch. 2; `analyse.py` scores the drawn position per display refresh; `visual.py`
screenshots a 4 s animation mid-flight. Results default to
`~/playground/fast-scroll/`; the 2026-09-24 baseline and final runs are kept
there.

Traps, each cost a run:
- **The display must be on.** DPMS off = no frame callbacks = Ghostty never
  realises its surface and never spawns `-e`. Looks like a hang.
  `kscreen-doctor --dpms on`.
- **A window under a pointer that never moved gets no wheel at all** (Ghostty
  reports at the last known position). `park_pointer` moves it and proves the
  position with nvim's `getmousepos()`.
- `$TMUX` inherited from the agent's own tmux makes the inner tmux refuse to
  nest; a unix socket path over 108 bytes makes nvim silently not listen.
- tmux-continuum on a second server would restore/overwrite the user's
  sessions -- TPM is stripped from the harness's tmux.conf.
- Sampling: resample per DRAWN FRAME, not on a fixed 60 Hz grid -- frames sit
  within ±1 ms of the grid and the jitter manufactured stall+double pairs.
- Scoring position: count repaint-detected scrolls (held j produced zero
  scroll events, all repaints) and ignore offsets on narrow animated columns.
- **Trace clock**: `.awake` IS CLOCK_MONOTONIC -- device send to Ghostty
  receipt measured 0.3 ms apart, so all three logs share one clock.

### What was wrong, and the fixes (`d279e888d`)

1. **The number column cancelled the scroll.** nvim scrolls with DL/IL (full
   width, gutter included), then repaints the screen-fixed relative numbers;
   when that repaint lands in the next frame the detector reads a narrow
   shift (-N, and once +8) and `push` adds it to the ONE shared offset: the
   page snapped (30-40% of fast-wheel frames had no slide) or lurched back
   160 px. `ScrollAnim.isRepair`: under half the event's width, within 250 ms
   of an app scroll -> the app's repaint, ignored. Either sign.
2. **The lag cap made batches snap.** nvim delivers 3-6 rows every 17-67 ms at
   ~3600 px/s on a fast spin, and 24-36 at once when it falls behind a flick;
   a 2-row cap can't smooth that, and >8 rows snapped. Lagging further needs
   the rows that already left the grid -> **ghost rows**: before the frame's
   cells are rebuilt, `keepScrollGhosts` copies the departing rows' glyphs
   (`captureGhosts`, columns clipped to the push), keeps them relative to the
   model (`shiftGhosts`), and the shader draws them (SCROLL_GHOST flag, u16 y
   read as signed, no bg/cursor lookup, clipped to the region, gone when the
   animation ends). Cap 24 rows; app scrolls up to 40 rows slide (Ctrl-D now
   slides; a full page still snaps). Band bg is the global bg.
3. **Ease-out restarted per push surges and sags.** Measured 5-13 px/refresh
   holding j. New `spring` easing (now the DEFAULT): critically damped,
   integrated exactly, velocity kept across pushes, exponential kick from
   rest, stiffens only past the cap (stiffening from half the cap retired a
   24-row batch in one frame = a snap).

smooth% (no stall/jump/jerk/reversal), baseline -> final (two runs):

| scenario | before | after |
|---|---|---|
| wheel slow / fast / flick | 84 / 53 / 56 | 100 / 100 / 96 |
| touchpad slow / fast / flick / repeated | 96 / 57 / 74 / 48 | 99.6 / 94-100 / 93-96 / 90 |
| held j / tapped j | (baseline run invalid) | 100 / 100 |

Tests: `isRepair` 4 (one flipped when the rule widened to both signs),
`spring` 4 incl. an ease-out control that must stay unsteady, `ghosts` 3;
each negative-controlled by breaking it. ScrollAnim 100/100, detectShift
96/96. `cell_text.v.glsl` via glslc: same single SPIR-V diagnostic as the
pristine file; a deliberately broken copy adds its error. Visual: mid-flight
screenshots both directions show continuous text through the band.

### Ruled out

- **Forcing nvim to redraw at least every 10 ms while scrolling**
  (WinScrolled -> `:redraw`). It did even out deliveries (47 -> 92 on repeated
  touchpad) but made everything worse, slow wheel 100 -> 78-89, held j 100
  -> 77: each step drawn in two pieces stalls the picture. Reverted.

### Open

- Flicks still batch in nvim (it postpones redraw while input is queued): the
  last ~5-10% on flick scenarios is that, not the terminal.
- A ghost row carries whatever the old frame had, e.g. nvim's `@@@`
  last-line marker, for the length of a slide.
- Metal shaders were never given the scroll animation; ghosts are Linux-only
  like the rest (`@hasField` guards the flag).
- Measured on the 60 Hz laptop panel only; the AW2725Q was not connected.

## 2026-09-25 — Claude Code's bullets and pinned label; flicks trail 40 rows

Reported from a live Claude Code session: the "Jump to bottom (ctrl+End) ↓"
label appeared four times up the screen while scrolling, and the white/green
bullets did not glide with their text. Plus the open items from 09-24.

Reproduced with `tools/scroll-harness/fast/claude_code.py` (Claude Code
resumed on a throwaway transcript copy, animation slowed to 4 s, shots
mid-slide). Claude Code's fullscreen view scrolls by **repainting**, so both
are the repaint detector (`b6f51072c`):

1. **Bullets**: trace said `cols=2..209` on every detection. The bullets are
   column 0, column 1 is always blank, and three bullets per screen are
   never `min_rows` of evidence -- a weak cluster, and weak clusters had to
   touch strong ones (`weak_bridge_cols = 0`, for yazi's selection glyphs).
   New `edge_bridge_cols = 2`: weak evidence STARTING AT COLUMN 0 may bridge
   inward. yazi's case is the mirror (strong gutter, weak glyph to its right)
   and its test still passes.
2. **Label**: it sits on the region's last row, which also carries transcript
   that moved, so the row slid -- and each push kept that row as a ghost,
   one label per row scrolled. New `trimPinnedRows`: an edge row with a run
   of 8+ non-blank cells unchanged in place and NOT what the shift brought
   leaves the region; an active animation holding it shrinks and drops its
   ghosts. Same for a sticky header on the first row.
3. **Flicks**: every worst moment was "offset pinned at cap" -- nvim sends
   30-42 rows per redraw after a 100-130 ms gap once it falls behind, and
   the 24-row cap snapped the excess. `ghost_lag_rows` 40, `max_ghost_rows`
   56, `max_ghost_animated_rows` 48. Alternating A/B, 3 blocks each:

| scenario | lag 24 | lag 40 |
|---|---|---|
| wheel fast | 89.7 / 96.0 / 92.1 | 100 / 100 / 100 |
| wheel flick | 92.1 / 93.1 / 91.7 | 95.6 / 97.1 / 97.5 |
| touchpad fast | 96.0 / 94.6 / 95.5 | 99.4 / 100 / 99.4 |
| touchpad flick | 94.4 / 93.6 / 96.4 | 96.2 / 95.8 / 95.8 |
| touchpad repeated | 84.5 / 85.8 / 84.8 | 91.3 / 91.4 / 93.5 |

Full suite on the final build, two runs (with the user's new neoscroll +
smear-cursor): wheel slow/fast/flick 100 / 100 / 94-95, touchpad
slow/fast/flick/repeated 100 / 98 / 98 / 91-93, held and tapped j 100,
neoscroll C-d 99-100, C-f 100. Mid-slide shots at ~36 rows of lag: the band
is continuous (old relative numbers, raw markdown as nvim sent it).

Also: nvim's `@@@` last-line marker is blanked (`fillchars lastline: `,
dotfiles), since the ghost band carried it mid-screen; and the harness now
wakes a sleeping screen and puts it back (`8deea0372`).

### Harness trap

A screen put to sleep by powerdevil's "Turn Off Screen" goes dark a moment
AFTER the call returns, and a wake sent right after it is ignored. Back-to-
back runs therefore failed alternately ("nvim never came up"), and the
failing half was whichever build ran second -- an A/B that looked like one
build could not start. `run.py` now waits for the off to land and verifies
the wake.

### Open

- Touchpad flicks and repeated drags still pin at 40 rows at the user's
  600 ms duration: the spring's steady lag is V x 0.2 s, 1600 px at a flick's
  8000 px/s. More cap is more staleness; the remaining 4-9% is that.
- Once, a mid-slide shot showed the bottom third black under a figure; not
  reproduced in three further tries.
- Metal shaders still lack the animation. 60 Hz panel only.

## 2026-09-27 — the repaint gate follows a scroll the user started

The user's `15j` in CSAPP ch. 2 sometimes landed in one frame. A `15j` sweep
of the chapter (`count_j_sweep`): 96 of 299 scrolls reached the renderer with
no scroll at all. 60 of the 67 that changed nvim's `skipcol` (the view starting
part-way into a wrapped line) were full repaints; nvim does not use a terminal
scroll across a skipcol change. The fix on the nvim side (dotfiles
`config/linewalk.lua`) replays a counted `j`/`k` as one-row `<C-e>` steps
over ~250-450 ms, like neoscroll does a page, so each step is a shift the
detector can recover.

That exposed the gate: `repaint_key_idle_ms` shut detection 150 ms after the
key, so every repainted step after that snapped. New `scroll_chain_ts`: a real
scroll event or a recovered shift that lands INSIDE an open gate re-arms it for
`repaint_chain_ms` (100 ms, longer than the eased tail's slowest step, ~65 ms).
It never opens the gate on its own, so output after Enter still does not slide.

Result, per `15j` press over the whole chapter (whole move cut / all animated):
69 / 166 before, 29 / 117 with the nvim glide on the old build, 13 / 137 with
this build plus the nvim-side cache warm-up for render-markdown's maths (it
blocked 150-300 ms converting formulas on first sight). Suite on this build:
wheel 100 / 100 / 94.6, touchpad 100 / 98.1 / 98.9 / 91.6, held and tapped
`j` 100, `C-d` 100, `C-f` 99.3. `scroll` tests 322/322.

Harness: `count_j`, `count_j_sweep` (line 1 to the end), `count_j_short`,
`count_j_tail`, and `+nosmear` / `+smearon` / `+normd` / `+floatlog` /
`+drawlog` / `+spawnlog` variants. `cuts.py <run> <scenario>` says, per nvim
scroll, whether the renderer saw it; `nvim_bisect.py <label> <lua> [spacing] [presses]` (renamed 09-28: `bisect.py` shadowed the stdlib module and broke analyse.py)
times late `15j` presses after a long run, with one thing switched off.

### Open

- The last ~13 whole-move cuts are all past line 3000 of the sweep and come
  from nvim itself slowing (first step 130-240 ms after the key). Not a leak
  (autocmds, active timers, extmarks flat over 120 glides) and not any one of
  smear-cursor / render-markdown / obsidian's status footer: the same run lands
  in a fast mode (4 ms / 11 ms per step) or a slow one (~31 / ~36 ms) whichever
  of them is switched off. Something outside the nvim config flips it.

## 2026-09-28 — crisp text in motion, coloured band, image edges, the tear, yazi's gutter

Reported by eye: the screen "dims and brightens" on every scroll (zoomed
screenshot: every glyph doubled/soft mid-slide); the first rows on a hard flick
lose inline-code highlights; a tear at CSAPP 2 line 1273 (right half of the
text a scroll behind the left); an image's edge row vanishes instead of sliding
out; yazi at the bottom of a folder detaches the line number from its row.

1. **Fractional offsets.** The offset reached the shaders in fractional
   pixels and glyphs are sampled with linear filtering, so everything in
   motion was drawn blended across two pixel rows. Rounded to whole pixels at
   upload (at most half a pixel off the curve).
2. **Band backgrounds.** Ghost rows kept glyphs only. Their backgrounds now
   ride after the grid's own in the bg buffer, as an extended grid
   (`max_ghost_rows` above and below; `ScrollAnim.shiftGhostBg` /
   `captureGhostBg`), found by cell_bg.f through `scroll_anim.w`. Most of the
   raw-looking top rows were NOT this, though: render-markdown's anti-conceal
   un-renders the cursor's lines, and a scroll drags the cursor along the top
   edge -- that is the nvim side's to fix (dotfiles, same day).
3. **The tear** was the detector splitting one pane at text that re-wrapped
   mid-scroll (`cols=0..145`, also 0..196, 5..170; 15 of ~70 detections around
   line 1273). A contradicting column now splits the region only across a
   DIVIDER column -- unchanged and non-blank on 60% of rows (tmux/yazi/nvim
   separators, or a pane holding still); inside one pane the minority that
   disagrees counts as weak evidence of the same scroll.
4. **yazi's gutter.** At the bottom of a folder the list stops and the cursor
   walks, relabelling every relative number: `shift=-1 cols=27..28` on each
   `j`, which slid the numbers a row out of step with the selection bar. No
   region narrower than `min_region_cols` (6) is a scroll. Also, Kitty image
   placeholder cells no longer testify: two previews lined up 8 rows apart
   and slid (`shift=-8 cols=105..208`).
5. **Image edges.** Unicode-placeholder images are one-row slices; a slice
   leaving the region now becomes a ghost like a text row
   (`image.State.kitty_ghosts`, captured from a snapshot of the placements as
   last drawn, because kittyUpdate runs before the scroll is handled), flagged
   in the new `Image.flags` attribute, and every displaced slice is clipped to
   the region in image.f (an image's last row no longer draws over the status
   line mid-slide). The ghost list is only marked stale from
   `clearScrollGhosts` -- drawFrame calls that with `draw_mutex` held.
6. **Claude Code's band went blank** for a moment when its label was first
   recognised as pinned (all ghosts were dropped). Now only the label's
   copies are (`dropGhostCopies`, `dropGhostBgCopies`).

Tried and dropped: a speed-adaptive spring (stiffen so a flick's steady lag
stays under 70% of the cap). Alternating A/B, 3 blocks: within noise
(wheel flick +1, everything else +/-2). Flicks already score 95-98.

Tests: tear + divider control, bullets, pinned rows, ghost bg (+ control),
ghost slices (+ control), label copies; the yazi gutter tests now expect no
region. `scroll`, `ghost`, `detectShift` filters all pass. glslc: cell_bg.f
clean and a broken copy errors; image.v/f report only the SPIR-V "location"
diagnostic the pristine files also raise.

Also: `bisect.py` renamed `nvim_bisect.py` -- it shadowed the stdlib module,
and analyse.py died importing `statistics`.

## 2026-09-28 — the "fast/slow nvim mode" was matchparen, and is already gone

Closes the 2026-09-27 Open item. Not a mode and not this renderer: nvim's
matchparen asks `vim.treesitter.get_captures_at_pos` about every bracket in
view on each cursor move, and stock nvim answers by walking every parse tree
of the buffer. CSAPP ch. 2 grows from a few hundred trees to ~5000 as it is
read, so each glide step cost more the deeper the sweep got. The dotfiles'
round-3 `ts-highlight-index.lua` indexes that call, which already removed it.

Proof, embedded nvim with a UI and no terminal, 285 `15j` 0.7 s apart, first
step per fifth of the sweep / presses over 100 ms:
current 27 → 40 ms, 14/285; stock lookup restored 35 → 259 ms, 155/285;
stock lookup + `:NoMatchParen` 24 → 27 ms, 7/285.
Real-device `count_j_sweep` (press_cuts.py): whole-move cuts 13 → 0 / 0 / 1
(09-28 final-a, final-b, and today on battery), all-animated 137 → 251 / 254 / 211.

Not the terminal: a 5 ms /proc sampler over nvim server + TUI, tmux and
Ghostty never caught nvim in `pipe_write`. Power is a constant factor (first
step ~6 ms on AC, ~12 ms on battery `quiet`), not growth and not cuts.

Why it looked like a per-run flip: `nvim_bisect.py` took the key time from a
`--remote-expr` sent after `--remote-send` returned (two client processes,
~25 ms late) and dropped every step before it, so it measured whichever part
of the glide it caught. It now timestamps key and steps inside nvim.

Tools: `press_cuts.py <run> [scenario]` -- per-press verdicts (all animated /
snapped / whole move cut), which presses cut, and first-step / step-gap per
fifth of the sweep.

## 2026-09-29 — torn frames, overlays that stay, tmux unzoom, figures on repaint scrolls; the 4K panel

1. **Torn frames (`67b9ee211`).** With GTK, drawFrame runs on the app thread
   while updateFrame runs on the renderer thread. kittyUpdate, the scroll push
   and ghost capture ran outside `draw_mutex`, so a draw could land between
   them and rebuildCells: the old grid at the new offset, or new image
   placements over the old grid. For one frame everything, or just a figure,
   sat a scroll off and came back ("the image jumps a line and back").
   updateFrame now holds the lock from the critical section to the end of the
   rebuild. A/B against the previous build: no regression (wheel fast 88-89
   vs 82-85).
2. **Overlays stay put (`3ed73620e`).** `computePins` finds a one-row coloured
   run that starts at the same column as the previous frame and is not what
   the shift carried there: yazi's selection bar (as wide as the hovered name,
   so only its left end is stable), Claude Code's "Jump to bottom" box, a
   riding cursor line. Those cells are undisplaced, and sliding text passes
   under them. The mask is appended to the bg buffer at offset
   `scroll_anim_cols.w`, and read by cell_bg.f, cell_text.v and cell_text.f.
   Its copies never enter the band: glyphs are filtered, and the bg under them
   is filled from the left. This replaces cutting the label's whole row out,
   which the user saw as the rest of that line freezing.
   Rules paid for on screen:
   - a tall block's edge rows are not pinned (holes in the green diff);
   - pins are computed over the animation's union, not the push;
   - the mask persists between animations for capture filtering;
   - the slid copy of a pinned bg draws nothing.
3. **tmux unzoom.** tmux redraws a row of panes with a SCROLL of the
   region's whole height (rows=16 over 2..17). That is a clear, so it is no
   longer animated: 134 animated frames per 3 zoom cycles → 0
   (`tmux_zoom.py`). `layoutChanged` also refuses repaint detection when a
   full-height vertical border appears or vanishes.
4. **Claude Code tears.** Ragged line tails past a quiet column were left
   out (`cols=0..132`). Weak evidence anywhere in the run's pane now joins it.
5. **Figures on repaint scrolls (`1bf5add11`).** A placeholder's row/column
   are combining marks, which the cell hash ignored, so every figure row
   hashed alike, read as unchanged, and snapped while the text slid (`j`
   above a half-visible figure: rows 1..44 of 52 → 1..52). Graphemes are
   hashed now. Placeholders still never testify, but they mark moved rows.
6. **Lag cap 48 rows, slides up to 64.** nvim got faster (another session
   turned off obsidian.nvim's 10 s vault-wide rg) and delivers 36-57 row
   batches. A/B, 3 blocks: wheel fast 86-88 → 91-94, touchpad repeat
   95-96 → 96-98.

The 4K AW2725Q is now connected: cells are 38 px, so each row of scroll is
twice the pixels of the laptop panel.

Harness: `yazi.py` (`--pre=N` j presses to reach the list-scrolls-under-cursor
case), `tmux_zoom.py`, and new scenarios `hold_j_{figs,maths,tables}`,
`hold_k{,_maths,_tables}`, `wheel_fast_up`, `tp_fast_up`, `tp_slow_up`
(Scenario `top=True` starts a key scenario with the cursor on the top row).

## 2026-09-29 (round 5) — held-j jumps, yazi icons/bar/short lists, the gutter

The user's report after round 4, tested on the 4K panel. New tool:
`steps.py` presses j/k one at a time and diffs `capture-pane` text, flagging
any press that moved more than one row or reflowed. smooth% could not see
these: they slid smoothly, just too far. The nvim causes were fixed in
dotfiles (raw cursor line off in normal mode, linewalk stale w_botline,
snacks figures placed only on screen); every press in 1555-1580,
1800-1880, 2650-2690 and 2795-2825 is now one row, at 0.35 s and 0.12 s.

Renderer (`scroll_anim.zig`, `generic.zig`, text shaders):
1. **Identical-icon columns ride.** A column the same down every row (a
   folder of one file type in yazi) is unchanged AND what the shift would put
   there; it counted as a divider, so icons stood while names slid. Only a
   column drawn as a rule (`isVerticalRule`) divides now; others join the
   scroll they touch (across ≤2 blank columns).
2. **Short lists do not shake.** `min_region_cols` is checked on the run's
   own evidence before pane-wide weak widening: yazi's relabelled numbers
   (2 cols) plus scraps from the cursor's rows grew to `cols=28..103` on every
   `j`. Test uses the real captured frames (`src/renderer/testdata/`); a
   synthetic version passed even without the fix.
3. **The gutter moves the same way every step.** A run starting within 5
   columns of the left edge, with no drawn border before it, starts at 0.
   Relative numbers mostly keep their value per row, so the gutter read as a
   still divider on some frames and not others: the left edge wandered 0/2/5
   while events always moved the full width.
4. **A frame caught mid-redraw.** A counter-shift within 60 ms of an event,
   which the pre-event frame explains as exactly the event, is dropped
   (`shift=-1 cols=0..162` 1 ms after `rows=1` at CSAPP 2808).
5. **Pins hold text only when the text stayed** (mask byte 1,
   `markPinnedText`): Claude Code's label and sticky header yes; yazi's bar
   no — its name froze while the number and size on the same row slid.

Suite unchanged within noise (hold_* 100, tp 98-100, ctrl_d/f 100, wheel
fast 87-95). `tmux_zoom.py` now counts mid-slide frames (0), not event
lines. The Claude Code "empty line" was Claude Code's own spacer row above
the prompt box (present in tmux's grid) — not ours.

## 2026-09-29 (round 6) — overlays: no black box, no stacked labels, no tear

User report: a black box beside Claude Code's "Jump to bottom" label and
yazi's bar on fast scrolls (it hid text on plain rows), several labels
stacked when the label sits on a grey row, and a tear through Claude Code's
green diff rows.

1. **What slides out from under a pinned overlay.** The slid copy of a
   pinned cell drew nothing (the box). Now: its background is the nearest
   unpinned colour to its left on the same row of the CURRENT frame
   (`fillUnderlay`, every frame; the push-time colour was stale when Claude
   Code finished a redraw a frame later -- a red box on a green row), and
   its text is the previous frame's row the shift carried there, kept as
   underlay ghosts (`CellText.bools.scroll_underlay`), captured over the
   whole scrolling row, drawn only where their own cell is pinned now and
   never over a pinned cell, and only when the new row's visible glyphs
   match that old row (a half-redrawn row gets none). A colour-only pin's
   own glyphs (yazi's hovered name) draw only over the bar.
2. **Labels found by text.** `pinStillText`: a run of >= 8 glyphs unchanged
   in place and different from what the shift carried there is an overlay,
   whatever its colour (the label on Claude Code's grey prompt rows was one
   colour run with the row, so never pinned, and every kept row carried a
   copy). On a row that already has a bar, any such glyph (yazi's end caps,
   the cursor's number). Only if the rest of the row changed: a row the app
   has not redrawn yet also "stays put".
3. **Bars keep their tail.** A coloured run starting where a pinned run ends
   is the same overlay (yazi's second shade over a symlink target).
4. **A scroll covers its whole pane.** Blank columns out to the dividers
   move with it: backgrounds scroll too (Claude Code's green diff to column
   200, text to 130: the tear).

Suite subset unchanged (hold_* 97-100, tp 100, wheel fast 89-95, ctrl_d 100).
Harness: `sweep.py` (hidden nvim, whole-chapter held-j or wheel sweep,
flags multi-row steps and reflows) -- it found the figures arriving late.

## 2026-09-29 (round 7) — the figure tear, readable bars

From the user's OBS recordings (frame-exact):

1. **A figure torn in two while scrolling up onto it** (CSAPP 291: its first
   row drawn twice, a later one lost, for one frame). nvim scrolls only the
   rows BELOW a figure hung above its top line (`IL` in a region starting
   there: `region=5..52`, `6..52`, ...) and repaints the figure's rows one row
   lower; the event animated its region only, so part of the figure slid and
   part did not. Ruled out first by replaying nvim's own output (396 frames)
   and tmux's output to the terminal (506 frames) through pyte: no frame had
   a duplicated image row -- it was ours. `extendEventRows`: rows beside the
   event whose content is last frame's shifted by the same amount join the
   animation and the gesture's app region; rows arriving at the edge join
   only inside rows some event of the gesture covered (the status line, row
   53, changes every step) or if they hold a figure. Also checked on the
   frames after the event within 60 ms (nvim often repaints those rows a
   frame later), against the pre-event hashes.
2. **yazi's hovered name unreadable while j is held**: the list is always
   part-way into a slide, and a name in its normal light colour on the light
   bar vanished. Text over a light colour-only pin is drawn in the terminal
   background colour (cell_text.f `recolor`).
3. **Bar-coloured block sliding off the bar**: `fillUnderlay` skips cells of
   the pin's own colour (yazi's icon cell is bar-coloured, unpinned).
4. **Stale pins when the bar moves without a scroll**: pins are recomputed on
   every frame of a running animation (last push's direction), text pins
   carried over on frames that did not scroll.

Suite subset: hold_* 100, tp 100, ctrl_d 100, wheel fast 92-95; tmux zoom 0.

## 2026-09-30 (round 8) — frames, not guesses

1. **GHOSTTY_FRAME_DUMP** (OpenGL.zig `dumpFrame`): every presented frame,
   shrunk to a third on the GPU, appended to a file (16-byte header +
   RGBA). `frames.py DUMP --check` measures per frame how far the text and
   each figure moved and flags disagreements and figures that VANISH;
   `--png` exports frames. Screen recorders were not usable (OBS's PipeWire
   capture opens a picker dialog on every start — it popped up on the user's
   screen while they worked; killed). The read-back slows drawing, so smooth%
   under a dump is not representative (64-73 vs 94-100 clean); use it for
   what is drawn, not when. Gate GUI runs on the user being idle: tmux
   `#{client_activity}` (KDE's idle query is unsupported here).
2. **Regression from round 7: overlays on frames without a push.** The
   per-frame pin recompute pinned every coloured run that "stayed put" on a
   frame where nothing moved: inline code, code-block labels, `󰦪 text` held
   still while the prose slid (317 pins in a held-j run; 0 after), and the
   text check held every overlay's text. Frames without a push now keep last
   frame's pins minus cells whose colour or text changed.
3. **An event that undersells** (generic.zig `applyPendingScroll`). tmux
   merges an application's updates, so one frame held a `rows=2` scroll
   event AND a repaint that moved the content ~10 rows (one wheel notch:
   nvim 2343 -> 2350 skipcol 752 in 8 steps / 26 ms); the event animated 2
   and 8 snapped — with a figure on screen, the figure jumped. The event is
   now animated after the frame is read, by the distance `detectShiftUpTo`
   (up to 24 rows, same direction, >= 80% of the width) finds, when that is
   further than the event said. Logged as `scroll event undersold`.
4. Harness: pointer parking nudges until mid-screen (the display went to
   scale 2.25 / 120 Hz / HDR and the fixed moves landed on the status line).

Clean suite at 120 Hz / 2.25: hold_* 99.6-99.7, tp_fast 99.5, tp_fast_up 96.5,
wheel_fast 94.2, wheel_fast_up 93.3, ctrl_d 98.3.

The remaining figure jumps were nvim's (snacks.image closing and re-placing
figures; dotfiles SETUP-LOG 2026-09-30).

## 2026-10-02 — shader cache: redo only the rows that changed

### Why

Measured on the desktop (`~/playground/desktop-power`, SETUP-LOG 2026-10-02):
one 12 fps text spinner in a corner cost 22-34% of the GPU with the `slab` glow
and 10-13% with no glow, because every frame ran the terminal image and all
three custom shaders over the whole 4K window. Six working Claude panes took
Ghostty to 30-44% and +5..15 W of a 45 W package budget.

### What

`custom-shader-cache = true` (OpenGL only; `drawFrameCached` in
`renderer/generic.zig`). Three layers, each kept from the last frame:

    cache[0]        the terminal image
    cache[1..n-1]   the output of each static shader (the glow passes)
    frame.target    the output of the LAST shader (cursor-fx, the animated one)

Every pass draws exactly what the uncached path draws, clipped by `glScissor`
to horizontal strips: the rows `rebuildCells` rebuilt, the cursor's old and new
row, each widened by `custom-shader-cache-margin` px (default 48; it must
cover the widest blur, 18 px for slab, plus glyph overhang). The last shader
runs over the whole window while `custom-shader-animation` says an effect is
live, once more after it ends, and whenever a shadertoy uniform other than the
clock changed; otherwise over the strips only.

`takeCacheDamage` answers "full" whenever it cannot name rows: a full rebuild,
resize, config or shader reload, font atlas change, any uniform change other
than the cursor's, a scroll animation (and the frame after it), Kitty images,
the overlay, a background image, hovered links.

The contract this puts on shaders: all but the last must be static, local
filters of the terminal image. A glow preset that read `iTime` or the cursor
would go stale.

### Verified

`custom-shader-cache-debug = verify` draws every frame a second time the
uncached way and compares the two targets byte for byte. It needs a
TRANSPARENT window to mean anything - the glow passes only write alpha, so on
`background-opacity = 1` every margin "passes" (that cost one false green).

    margin 0   44 mismatches on text appearing on an empty screen (the check can fail)
    margin 48  0 mismatches in 298 frames: spinner, seq scroll, typing, split,
               pane switch, nvim (j, 20j, C-d/C-u, visual, insert, search),
               btop, zoom, clear   (~/playground/desktop-power/gh/drive.sh)

Release build, test window's own GPU time (fdinfo), cache off -> on, two runs each:

    idle      0.7% -> 0.15%
    spinner   5.0% -> 0.9%
    typing    6.9% -> 2.5%     (every keystroke is a cursor move, so the last
                                shader runs full-window for 1.3 s; that is now the cost)
    output    4.8% -> 4.0%     (scrolling output is a scroll animation = full)

### Not done

- Scroll animations and typing still pay the last shader over the whole
  window. Bounding cursor-fx to the box its effect can reach is the next step.
- Metal: untouched; the path is compiled out there.

## 2026-10-02 (later) — shader cache: the cursor effect only costs the box it can reach

Stats from the real window showed where the cost had moved: `chain none 63 /
final full 66` in 2.4 s. With nothing changing on screen, every cursor event
kept the LAST shader (cursor-fx) running over the whole window at the draw rate
for 1.3 s - and Claude Code moves the cursor constantly.

`custom-shader-cache-fx-reach = <cell heights>` (0 = off, the old behaviour;
only with `custom-shader-animation = cursor`). While an effect is live the last
shader runs over `cacheFxBox`: the cursor, both ends of its last move and the
rect of every mode change / pulse of the last 2 s, grown by the reach - plus
the box the previous frame drew in (to move or erase the effect), plus the
damaged strips. The cursor's own uniforms no longer force a full pass in this
mode; any other uniform change still does.

Reach for cursor-fx.glsl, from its constants: railgun particles travel at most
|v0|*2/|(-DAMP, CURL)| = 30.5cw*2/7.43 = 8.2 cell widths (4.1 cell heights)
from a start point up to one cell off the path, the ripple reaches 3.5 cell
heights, the boom 3. 5 passes; **7** is what the config uses.

Verified (`debug = verify`, transparent window, drive.sh + jumps.sh):

    reach 0.5   363 mismatches of 713 frames (the check can fail)
    reach 7     0 of 1280 frames of long jumps and mode flips (jumps.sh)
    reach 5/7   1 of ~860 per drive.sh run, about every other run: 2 px, one
                frame. NOT the cache: the pixel is outside everything redrawn
                that frame, and the frames before and after it pass with the
                same cached pixel, so it is the uncached reference render that
                has a one-frame hole (clear colour showing through). The
                mismatch log now prints the column range, the box, the cursor
                uniforms and the last 12 frames' damage for exactly this.

Release build, typing at 10 keys/s, test window's own GPU time, alternating
runs with the desktop in use (so noisy): cache off 50%; reach 0: 21, 38, 38,
41, 21%; reach 7: 10, 18, 9, 5, 16%. The last shader's share of the window per
frame went 1.000 -> 0.097.

## 2026-10-03 — damage tracking: a small change is a small frame for GTK and KWin too

### Why

Typing with the cursor effects on: Ghostty 21-33% of the GPU and KWin up to
38% (transparent window), though `final_share` said the last shader touched 4%
of the window. `WAYLAND_DEBUG=1` showed why: every frame was committed with
`damage_buffer(0, 0, INT_MAX, INT_MAX)`. `GtkGLArea` renders each frame into a
fresh texture, so our present blit copied the whole target, GSK re-drew the
whole widget, and KWin recomposited the whole window - 120 times a second for
the 1.3 s after every cursor event.

### What

`gtk-damage-tracking = true` (GTK, OpenGL; default off).

- `apprt/gtk/class/damage_gl_area.zig`: `GhosttyGLArea`, a `GtkGLArea`
  subclass that overrides `snapshot`. In damage mode it owns ONE texture + FBO
  for as long as the size holds, binds it, emits `resize`/`render` itself, and
  hands GTK a `GdkGLTexture` built with `set_update_texture(previous)` +
  `set_update_region(rects)`. GSK's node diff then repaints only that region
  and `eglSwapBuffersWithDamage` passes it on. Nothing changed = the same
  texture object again = no damage at all. Anything it cannot do (no context,
  FBO incomplete, tracking off) goes to the parent's stock snapshot.
- `renderer/OpenGL.zig`: `present_persistent` (set by the apprt per draw),
  `frame_damage` (set by the renderer, reset to "everything" in
  `drawFrameStart`), `presented` (taken by the apprt). `present` blits only the
  damage rectangles when the framebuffer kept the last frame;
  `presentLastTarget` is then a no-op. A frame that was drawn but not presented
  marks the framebuffer stale and the next present is whole.
- `renderer/generic.zig`: `drawFrameCached` reports `final_rects` (the strips
  plus the fx boxes) unless the final pass was full. So only frames through
  `custom-shader-cache` are narrowed; the uncached path stays whole-window.
- Tracking is only switched on once the core surface exists: the widget uses
  the renderer's glad context, which is `undefined` (not null) before that.
- The update region is in texture rows = GL rows, so GL scissor rects go in
  unflipped; the flip is the snapshot transform, as in GtkGLArea.

### Verified

- Protocol: typing now commits `damage_buffer(867, 0, 470, 386)`-sized boxes
  and one-line strips; full damage only on full frames.
- `custom-shader-cache-debug = verify` now also reads back the framebuffer
  after every present and compares it with the target (`present MISMATCH`,
  `present-verify checked=`): 0 over drive2.sh and jumps2.sh; with
  `GHOSTTY_PRESENT_BREAK=1` (drops the first rect) 158 - the check can fail.
- On screen (`~/playground/desktop-power/gh/e2e.sh`): after a run of jumps and
  mode flips, a screenshot is pixel-identical to one taken after a forced full
  frame (SIGUSR2), twice.
- GPU, own fdinfo, 12 s, alternating pairs, old `1974d867c` -> this:

      typing, solid            ghostty 32.4 -> 5.6 %   kwin  3.6 -> 0.5 %
      i/Esc flips, solid       ghostty 36.7 -> 10.7 %  kwin  3.6 -> 2.2 %
      typing, transparent+slab ghostty 32.8 -> 5.5 %   kwin 38.1 -> 3.0 %

### Traps

- A game on screen (YARG) holds the display at 120 fps and KWin at ~12%:
  KWin deltas measured beside it mean nothing. Check `vblank/s` at idle first.
- `pkill -f '[e]2e.sh'` inside a command line that also runs `./e2e.sh` kills
  the caller.
- A bare `wait` in a driver script waits for the Ghostty under test as well.

### Not done

- Frames outside the shader cache (no custom shader, scroll animations, Kitty
  images) are still whole-window.
- The shader cache's own verify still shows the 2 px one-frame hole, including
  on full frames, where neither cache nor damage tracking does anything.
