# SPEC — Smooth scrolling for Ghostty

Fork goal: make scrolling in this terminal feel smooth — momentum from the
touchpad, and motion that is not quantised to whole text rows.

This file is the **stable** half of the pair. It states what we are building
and why, and it records facts about the upstream code that were *verified by
reading or running it*, not recalled. `PROGRESS.md` is the volatile half: where
we are, what broke, what is next. Read both before touching code.

Upstream base: `ghostty-org/ghostty` @ `e8aa09867` (`1.3.2-dev`), branch
`smooth-scroll`. Every `file:line` below was checked against that commit; if
you have rebased, re-verify them before trusting them.

---

## 1. The problem, stated precisely

A terminal draws a grid of character cells. Nothing in Ghostty 1.3.x renders a
half-row offset, so **one text row is the smallest scroll step that exists**.
`ghostty +show-config --default --docs | grep -i smooth` returns nothing: there
is no such option, and the absence is the answer, not a gap in the search.

So "smooth scrolling" decomposes into three genuinely different features. They
live in different code paths, have different difficulty, and — critically —
**buy different things**. Conflating them is the main way this project goes
wrong.

| # | Feature | What it changes | Where it helps |
|---|---------|-----------------|----------------|
| 1 | **Momentum** | Input layer only. Keep scrolling, with decaying velocity, after the fingers lift. | Everywhere, tmux included |
| 2 | **Scroll-region animation** | Animate the *rendering* of an app-driven scroll. | tmux, nvim, btop — the real win |
| 3 | **Pixel viewport scroll** | Sub-cell offset for Ghostty's own scrollback. | Bare shell **outside** tmux only |

### Why the ordering is 1, 2, 3 and not 1, 3, 2

Feature 3 is what the existing community fork (`parkers0405/ghostty-pixel-scroll`)
implements, and it is the intuitive place to start. **It is also the one that
does nothing for this machine's actual usage**, because this user lives inside
tmux, and inside tmux Ghostty's own viewport never moves (§3.2). Building 3
first would produce a demo that feels great in a bare shell and changes nothing
in real use. Do 1 and 2 first.

---

## 2. Non-goals

- Rewriting the renderer. Every stage must be a bounded diff against upstream.
- Replacing the packaged `/usr/bin/ghostty`. The fork builds to
  `zig-out/bin/ghostty` and is launched explicitly. The daily driver stays on
  the Fedora package until a stage is trusted.
- Upstreaming. Not a goal now; keep the diff clean enough that it stays
  *possible*, but do not let it dictate design.
- Touching tmux/nvim config. That work is **already done and committed** in
  `~/dev/dotfiles` (commit `bfb1056`): tmux wheel bindings are `-N 1` and
  nvim `mousescroll=ver:1`. Those captured all the win available *without* a
  fork. Do not re-litigate them; this fork is about what config cannot reach.

---

## 3. Verified facts about the upstream code

These cost real effort to establish. Do not re-derive them; do re-verify if the
base commit moves.

### 3.1 The input path — `src/Surface.zig`

- `scrollCallback` — **`src/Surface.zig:3456`**. Single entry point for all
  scroll input. Signature `(self, xoff: f64, yoff: f64, scroll_mods)`.
  Sign convention: negative is down/left, and "natural scrolling" inversion is
  the apprt's job, already normalised before this point.
- `ScrollAmount` — **`src/Surface.zig:3439`**. `delta: isize`, plus
  `direction()` and `magnitude() usize`. **This integer is where row
  quantisation happens**, at the input layer, before the renderer ever sees it.
- `mouse.pending_scroll_x` / `pending_scroll_y` — **`src/Surface.zig:243-244`**,
  `f64`. **Important and easy to miss: Ghostty already tracks the sub-cell
  pixel remainder.** Precision deltas accumulate here and only emit a
  `ScrollAmount` once `@abs(poff) >= cell_size`; the remainder is carried.
  Feature 3 therefore does not need new state to *know* the sub-cell offset —
  the information already exists and is simply never rendered.
- Precision vs discrete: `scroll_mods.precision` selects between
  `yoff * multiplier.precision` (pixels) and
  `yoff * cell_size * multiplier.discrete` (wheel ticks normalised to pixels).
  There is a Darwin-only `@max(yoff, 1)` ramp; ignore it, we are Linux.

### 3.2 The three dispatch paths, and which one tmux takes

After computing `x`/`y`, `scrollCallback` branches three ways. **Knowing which
branch is live decides whether a feature helps at all.**

1. **Alt-screen + `mouse_alternate_scroll`** — `src/Surface.zig:3569`. Emits
   cursor-key sequences (`\x1bOA`/`\x1b[A`), one per row of magnitude. Returns.
2. **Mouse reporting active** — `src/Surface.zig:3602`. Emits one
   `mouseReport(.four/.five, .press, ...)` **per row**, then returns *without
   touching the viewport*. **This is the branch tmux uses.**
3. **Otherwise** — `src/Surface.zig:3628`,
   `self.io.terminal.scrollViewport(.{ .delta = y.delta * -1 })`. Ghostty's own
   scrollback. Note the sign flip: delta is negative-down, viewport is
   positive-down.

Consequence, and the single most important fact in this document: **inside tmux
we are in branch 2, and Ghostty's viewport does not move.** tmux runs on the
alternate screen (verified: `smcup=\E[?1049h`, tmux `alternate-screen on`,
`#{alternate_on}` = 1 in a live pane), which has no scrollback by definition.
A pixel offset applied to the viewport has nothing to offset.

### 3.3 What tmux actually emits when it scrolls — measured, not assumed

Ghostty is not the only thing that could animate a scroll. Measured with a
Python `pty` harness driving a real `tmux attach` and capturing the client's
output byte stream, one line of copy-mode scroll produces:

```
ESC[1;23r     DECSTBM — set scroll region to rows 1..23
ESC[1;1H      cursor home
ESC[1L        IL — insert 1 line      <-- the scroll itself
ESC[1;1H LINE-377-...                 <-- only the ONE newly exposed row
ESC[1;24r     restore full region
```

Counts per one-line scroll: `IL` x1, `DECSTBM` x2, **`LINE-n` content redrawn
x1** out of 23 visible rows.

**tmux does not repaint the pane — it issues a standard scroll primitive and
lets the terminal move the other 22 rows.** That is what makes Feature 2
possible. An earlier assumption that tmux repaints was *wrong*, and it would
have killed the project had it not been measured. The harness that proved it is
worth rebuilding if you ever doubt this: see `PROGRESS.md` → Verification.

Historical note, useful for framing: this is essentially DECSCLM (DEC private
mode 4, "smooth scroll"), a VT100 feature xterm still implements. The concept
is not novel; the implementation in a GPU renderer is.

### 3.4 The terminal-side scroll primitives — `src/terminal/Terminal.zig`

The functions that receive what §3.3 measured:

- `insertLines` — **`:2951`**  ← `CSI n L`, what tmux sends
- `deleteLines` — **`:3125`**  ← `CSI n M`
- `scrollUp` — **`:2659`**, `scrollDown` — **`:2619`**  ← `CSI n S` / `T`
- `index` — **`:2316`**  ← `IND` / `ESC D`
- `setTopAndBottomMargin` — **`:2594`**  ← `DECSTBM`, `CSI r`

### 3.4b GTK hands us the fling velocity — we do not have to estimate it

`src/apprt/gtk/ui/1.2/surface.blp` declares the vertical
`EventControllerScroll`, and `scroll-begin` / `scroll-end` are already wired to
`ecMouseScrollVerticalPrecision{Begin,End}` (`src/apprt/gtk/class/surface.zig:3049`,
`:3056`) to track `precision_scroll`.

`GtkEventControllerScrollFlags` has `GTK_EVENT_CONTROLLER_SCROLL_KINETIC`
(`= 1 << 3`, verified in `/usr/include/gtk-4.0/gtk/gtkeventcontrollerscroll.h:66`):
*"Emit ::decelerate after continuous scroll finishes."* Adding `kinetic` to the
controller's flags gives a `decelerate(vel_x, vel_y)` signal carrying the
gesture's exit velocity in px/s, measured by GTK.

**This supersedes an earlier assumption in this document** that Wayland gives no
"fingers lifted" event and that momentum would need gap-detection plus a
home-grown EWMA velocity estimate. It does, via GTK, and using it means the
fling matches the feel of every other app on the desktop instead of being
invented here.

Also note `src/apprt/gtk/class/surface.zig:3074`: precision scrolls are
multiplied by a hardcoded `10.0` in the GTK layer before reaching
`scrollCallback`, on top of `mouse-scroll-multiplier`. Synthesised momentum
events must apply the same factor or they will be 10x too slow.

### 3.5 Renderer and timing anchors

- `projection_matrix` — **`src/renderer/generic.zig:2160`** (`math.ortho2d`)
- `grid_padding` — **`src/renderer/generic.zig:2166`**. Plausible carrier for a
  sub-cell Y offset without touching per-cell geometry; unproven, treat as a
  lead not a plan.
- **A frame-clock timer pattern already exists in-tree**:
  `gtk.Widget.addTickCallback` / `removeTickCallback` with a `gdk.FrameClock`,
  used at **`src/apprt/gtk/class/imgui_widget.zig:244`** (removal at `:258`).
  Copy this rather than inventing a timer. Both animation features need a
  per-frame tick and this is the sanctioned way to get one.
- The GTK surface widget is `src/apprt/gtk/class/surface.zig` (~4466 lines).

---

## 4. The features

### Feature 1 — Momentum  *(start here)*

**Goal.** After a touchpad flick ends, continue scrolling with exponentially
decaying velocity until it falls below a threshold.

**Why first.** It is input-layer only — no renderer changes, no new rendering
invariants, no risk of visual corruption. And it is the only one of the three
that helps in *every* dispatch path of §3.2, because it works by synthesising
additional scroll events, which each branch then handles by its own existing
logic. Cheapest real win.

**Design.**
- New state on `Surface`, beside the existing `mouse.pending_scroll_*`:
  current velocity (px/s), last-event timestamp, tick-callback id.
- Velocity comes from GTK's `decelerate` signal (§3.4b) — no estimation, no
  gap-detection. Enable it with the `kinetic` controller flag.
- On that signal, start a frame-clock tick (§3.5). Each frame: decay velocity
  by a time-constant, convert elapsed velocity into a pixel delta, feed it
  through the *same* accumulator path as a real precision event so all three
  dispatch branches keep working unchanged. Stop below threshold.
- Any new real scroll event, or a keypress, cancels the fling immediately.

**Acceptance.** A flick in a tmux pane keeps scrolling and eases to a stop.
Scrolling still tracks the finger 1:1 during contact. `mouse-scroll-multiplier`
still behaves. No runaway scroll when the surface loses focus or closes.

**Threading — settled.** Frame-clock ticks run on the GTK main thread, exactly
like the input events in `ecMouseScrollVertical`. Calling `scrollCallback` from
a tick is therefore no different from calling it from a real scroll event, and
momentum needs no locking of its own. The remaining hazard is lifetime, not
concurrency: the tick dereferences `core_surface` every frame, so it must be
removed in `dispose()` (mirroring `imgui_widget.zig:258`).

**Config.** `mouse-scroll-momentum = true|false` (default false while
experimental) and a decay constant. Follow upstream config conventions in
`src/config/Config.zig`.

---

### Feature 2 — Scroll-region animation  *(the real prize)*

**Goal.** When the application scrolls a region (§3.3/§3.4), animate the
transition over a few frames instead of snapping.

**The one hazard that will bite you.** Look again at the measured byte stream
in §3.3: immediately after `ESC[1L`, tmux writes the newly exposed row *and*
the status bar, in the same burst. Writes land **during** the animation window.
Therefore:

> **Apply the scroll to the grid model instantly; animate only the pixel offset
> used at draw time.** Fast-forward or snap if another scroll arrives mid-flight.

Animating the model instead will corrupt the screen. This is how Neovide does
it, and it is the difference between this working and producing tearing
garbage.

**The problem neither obvious approach solves: the outgoing row is gone.**

Verified by reading `insertLines` (`src/terminal/Terminal.zig:2951`): it
operates within `scrolling_region.top/bottom` and the row scrolled out of the
region is erased/reused immediately. After the call the old content does not
exist anywhere.

That matters because animating a scroll means showing, for a few frames, the
arrangement *before* the scroll. Concretely, scrolling up one row and animating
the new model downward by `cell_height` leaves the top row of the region with
nothing to draw — a one-row gap for the duration of the animation, N rows for
an N-row scroll. On the primary screen the missing row is in scrollback and
could be fetched, but **tmux runs on the alternate screen, which has no
scrollback**, so for the case we actually care about it is genuinely gone.

Any working implementation must therefore preserve the outgoing rows somehow.
Two candidates:

- **(a) Stash rows.** The scroll primitives copy outgoing rows into a small
  ring in shared state; the renderer draws them in the gap. Bounded and
  explicit, but touches core terminal code on the hot path and needs its own
  lifetime rules.
- **(b) Composite the previous frame.** Keep the last frame's texture and,
  during the animation, draw it shifted by the offset with the current frame
  shifted by `offset - N*cell_height`, scissored to the region. The old rows
  come for free because the old frame contains them, and it is region-agnostic
  apart from the scissor. The renderer already has offscreen render targets for
  the custom-shader path (`frame.custom_shader_state`,
  `src/renderer/generic.zig:1707`), so the machinery exists — though today it is
  only allocated when custom shaders are enabled.

**(b) is the recommendation.** It solves the gap without putting per-row
copying in the terminal's hot path, and it degrades to "no animation" cleanly.

**Where the pieces attach.**

- Per-row offset in the vertex shader is easy: `cell_text.v.glsl:50` computes
  `cell_pos = cell_size * vec2(grid_pos)`, so a conditional Y offset for rows
  inside the margins is a small change. Note the background is a separate pass
  (`cell_bg.f.glsl`) and must be offset consistently or text will slide over a
  stationary background.
- Continuous frames already have a sanctioned mechanism: `animationWake()`
  (`src/renderer/generic.zig:1039`) returns the soonest wake the renderer needs
  and is what drives custom-shader animation at `draw_interval_ms`. A running
  scroll animation is another source of `.draw` wakes; do not invent a timer.
- Backends: only OpenGL matters here, but `generic.zig` is shared with Metal.
  Keep changes in the generic layer where possible.

**Sequencing.** Detection first, animation second. The scroll primitives fire
far more often than one might guess — `index` (`:2316`) runs on *every* newline
at the bottom of the screen, so animating it naively would animate all terminal
output, not just deliberate scrolling. Log what fires and how often before
attaching anything visual to it. That is why Stage 2a below is detection only.

**Design sketch (unproven).** A per-surface `scroll_anim` holding pixel offset,
target, and start time. Terminal scroll primitives (§3.4) signal the renderer
that a region scrolled by N rows; renderer initialises offset to `N *
cell_height` and eases it to 0. Region-aware: only rows inside the DECSTBM
margins shift, so a full-screen offset is wrong when a status bar sits outside
the region — the measured stream sets margins to rows 1..23 of 24 precisely
because tmux's status line must not move.

**Acceptance.** Scrolling a long file in tmux copy-mode or nvim eases rather
than snaps; no tearing, no stale rows, no corruption when output arrives
mid-animation; disabling the feature restores exact upstream behaviour.

**Risks.** Highest of the three. Latency/correctness tradeoff: animating means
*delaying* the display of content. Keep the duration short (~60-100 ms) and
make it configurable. Interaction with damage tracking and with the custom
shader pipeline (this user runs `custom-shader = text-glow.glsl`) is unknown —
the shader post-processes a finished frame, so it *should* be transparent, but
verify rather than assume.

---

### Feature 3 — Pixel viewport scroll  *(last, and know what it buys)*

**Goal.** Sub-cell offset when scrolling Ghostty's own scrollback (branch 3).

**Scope, honestly.** Helps only at a bare shell with tmux not running. For this
user that is close to never. Do it for completeness or because it is
satisfying, not because it fixes the original complaint.

**Design.** The remainder in `mouse.pending_scroll_y` (§3.1) is *already* the
sub-cell offset — surface it to the renderer instead of discarding it. Render
one extra row above the viewport and translate the grid by the offset;
`grid_padding` (§3.5) is a candidate carrier.

**Risks.** Mouse hit-testing, selection, and cursor position all assume integer
rows. Every one of those must account for the offset or they will drift by up
to one row.

---

## 5. Working agreements

- **Verify, don't declare.** A stage is done when it has been *run*, not when
  it compiles. Ghostty is a GUI app: build success proves nothing about
  behaviour.
- **Never break the daily driver.** `/usr/bin/ghostty` stays packaged and
  untouched (`rpm -V ghostty` clean). Launch the fork explicitly from a working
  terminal so a crash-on-startup is survivable.
- **One feature per commit**, each independently revertible.
- Each feature ships behind a config option defaulting to off until trusted.
- Record *why* and what was ruled out, not just what was done — matching the
  house style of `~/dev/dotfiles/SETUP-LOG.md`.
