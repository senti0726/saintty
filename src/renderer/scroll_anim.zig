//! Animation state for an application-driven scroll.
//!
//! When a program scrolls a region of the screen, the terminal model is
//! updated immediately and only the *drawn* position is animated: writes land
//! during the animation (tmux emits the newly exposed row and its status bar
//! in the same burst as the scroll), so the model must stay current and the
//! animation must chase it. See SPEC.md stage 2.
//!
//! This lives in its own file so the easing can be unit tested. It is pure
//! arithmetic over an offset and a clock; nothing here touches the GPU.

const std = @import("std");
const assert = std.debug.assert;

const ScrollAnim = @This();

/// Pixels the animated rows are currently displaced by, decaying to zero.
/// Zero means no animation is running.
offset_px: f32 = 0,

/// Inclusive row range the offset applies to. Rows outside it must not move:
/// tmux keeps its status line outside the scrolling margins precisely so it
/// stays put, and shifting the whole grid would visibly jiggle it.
top: f32 = 0,
bottom: f32 = 0,

/// Inclusive column range the offset applies to. Not every scroll is full
/// width: yazi previews a scrollable buffer in one pane while the file lists
/// beside it stay put, and a tmux vertical split is the same shape. Moving
/// those columns too slides the stationary pane and springs it back.
left: f32 = 0,
right: f32 = 0,

/// The displacement at the most recent push, signed, and how long ago that
/// was. The drawn offset is this curved down to zero over `duration_ms`
/// rather than integrated frame by frame, so the shape of the motion is a
/// property of the curve and not of the frame timing.
start_px: f32 = 0,
elapsed_ms: f32 = 0,

/// A shorter ease for this burst, when rows are arriving faster than the
/// configured duration can retire them; 0 when there is none. See `push`.
pace_ms: f32 = 0,
/// How many intervals `pace_ms` has averaged since the burst began.
pace_samples: u8 = 0,

/// Rate of change of `offset_px`, px per ms. Only the `spring` easing keeps
/// it: it is what makes that motion velocity-continuous. See `advanceSpring`.
vel_px_ms: f32 = 0,

/// The last push found the animation idle, so a spring should set off at
/// once rather than accelerate from standstill. See `advanceSpring`.
from_rest: bool = false,

/// The lag cap the most recent push was given, which a spring stiffens
/// against as the offset approaches it.
limit_px: f32 = 0,

/// The latest input was a key, not the wheel or touchpad. Set by the
/// renderer before each `advance`. A spring held to a burst of key repeats
/// keeps pace with them (`pace_ms`) instead of trailing by V x duration / 3.
/// See `advanceSpring`.
key_paced: bool = false,

/// The held-key glide (see `advanceGlide`): the model's speed under a held
/// key, px per ms, averaged over the frames that brought rows, and the
/// averaged time between those frames.
glide_rate: f32 = 0,
glide_iv_ms: f32 = 0,
/// Rows pushed since the last frame, px, and the time since the last frame
/// that brought any.
glide_pending_px: f32 = 0,
glide_since_ms: f32 = 0,
glide_samples: u8 = 0,
/// Px and ms summed over the first `glide_warm_samples` (their quotient is
/// the rate until the average has enough to go on), then averaged per
/// sample (`glide_alpha`), the rate being their quotient still.
glide_sum_px: f32 = 0,
glide_sum_ms: f32 = 0,
/// The glide's own speed, px per ms, and whether it is driving the offset.
glide_v: f32 = 0,
gliding: bool = false,
/// How long a finished held-key animation has been kept alive, invisibly,
/// waiting for the rows after a stall. See `glide_linger_max_ms`.
glide_linger_ms: f32 = 0,

/// Below this many pixels there is nothing left to see. Holding a sub-pixel
/// offset would keep requesting frames forever for no visible benefit.
pub const min_offset_px: f32 = 0.5;

/// A single scroll larger than this many rows is not smoothed at all.
///
/// Past a few rows this stops being a scroll and becomes a jump: a page move,
/// a tmux full-screen redraw, or a burst of program output. Sliding a whole
/// screen's worth of text past the eye is slower and harder to read than the
/// instant change it replaces, so those snap.
pub const max_animated_rows: isize = 8;

/// The drawn position may never fall further behind the model than this many
/// rows.
///
/// Displacement accumulates while scrolls keep arriving, and during a
/// momentum fling they arrive faster than the ramp retires them. Without a
/// tight cap the offset winds up to whatever the limit allows and the whole
/// block of text is drawn half a screen from where it belongs, leaving the
/// rest of the region empty. Being briefly a row or two behind reads as
/// motion; being half a screen behind reads as lag, because it *is* lag.
pub const max_lag_rows: f32 = 2;

/// How many input intervals a burst of pushes is given to settle. See `push`.
pub const pace_intervals: f32 = 4;

/// How much of each new interval measurement `pace_ms` takes in (an
/// exponential average, ~4 pushes deep). See `push`.
pub const pace_smoothing: f32 = 0.25;

/// How many rows that scrolled OUT of the region the renderer keeps, so it
/// can go on drawing them in the band a lagging offset uncovers. See
/// `shiftGhosts`. This is what makes a lag of more than a row or two
/// possible at all: without them the band is empty -- the rows left the grid
/// the moment the application scrolled -- and a deep lag reads as a hole.
/// More than `ghost_lag_rows`, so the deepest lag still has rows to draw.
pub const max_ghost_rows: usize = 72;

/// With ghost rows to fill the band, how far behind the model the drawn
/// position may fall. A fast wheel spin in nvim arrives as 3-6 row batches
/// 17-67 ms apart at ~3600 px/s, and a spring following that settles about
/// sqrt(2 V cap / omega) behind: ~415 px, inside 24 rows. At 12 rows the
/// spring had to stiffen against the cap and big batches collapsed in a frame.
///
/// 24 was still too few for flicks: once nvim falls behind it delivers 30-42
/// rows in one redraw after a 100-130 ms gap, and everything past the cap
/// landed in one frame ("offset pinned at cap" on every worst moment). At 40,
/// three alternating A/B blocks on the fast harness, smooth% 24 -> 40: fast
/// wheel 90-96 -> 100, touchpad drag ~95 -> 99-100, repeated drags ~85 ->
/// 91-94, wheel flick ~92 -> 96-97, touchpad flick ~95 -> 96. The price is
/// how stale the band may get, and it is drawn from real rows, not a hole.
///
/// 40 -> 48 (2026-09-29): with nvim now keeping up, a fast wheel spin arrives
/// as 36-57 row batches and sat pinned at 40 (on the 4K panel rows are 38 px,
/// so every scroll is twice the pixels). Alternating A/B, 3 blocks: fast
/// wheel 86-88 -> 91-94, repeated touchpad drags 95-96 -> 96-98, flicks
/// unchanged or +1.
pub const ghost_lag_rows: f32 = 48;

/// The largest single application scroll that slides rather than snaps,
/// with ghost rows available. A touchpad flick in nvim delivers up to ~30
/// rows in one redraw once nvim falls behind the input (up to 36 measured);
/// sliding them reads as fast scrolling, snapping them reads as a jump. A
/// half-page jump (`Ctrl-D`, ~29 rows) now slides too, as an Electron editor's
/// Page Down does; a full page still snaps. Up from 40 with `ghost_lag_rows`,
/// for the 42-row batches measured in a wheel flick.
/// 48 -> 64 with the lag cap, for those 57-row batches.
pub const max_ghost_animated_rows: isize = 64;

/// The held-key glide. How much of the input's own travel it keeps in hand
/// (ms of it), how long it takes to close any gap beyond that, how quickly
/// its speed follows, and how much of each new rate sample it takes in. See
/// `advanceGlide`.
pub const glide_lead_ms: f32 = 40;
pub const glide_catch_ms: f32 = 150;
pub const glide_smooth_ms: f32 = 60;
pub const glide_alpha: f32 = 0.15;
/// It takes over once this many frames have brought rows at no faster than
/// one a `glide_min_interval_ms` -- key repeat, not a Ctrl-D burst -- and
/// hands back to the spring when none has come for `glide_release_intervals`
/// of the averaged interval (and at least `glide_release_min_ms`): a release
/// or a stall.
pub const glide_min_samples: u8 = 5;
/// For this many samples the rate is the plain mean since the hold's rows
/// began, then `glide_alpha`'s average. Begun as an average, its first
/// frame-quantised samples (20 px over 33 ms = 0.6 px/ms against a true
/// 0.8) held it low for ~200 ms, and the drawn text fell 2.3 rows behind
/// just after the repeat began.
pub const glide_warm_samples: u8 = 8;
pub const glide_min_interval_ms: f32 = 15;
pub const glide_release_intervals: f32 = 2;
pub const glide_release_min_ms: f32 = 45;
/// A held key whose rows STOP for a moment -- nvim busy 100-130 ms on a big
/// table or a figure line -- hands back to the spring, which lands, and
/// landing ended the animation and threw the glide's averages away. The
/// backlog that came next (4-7 rows at once) then started a stiff paced
/// spring from rest: a freeze and then a leap of up to 3.2 rows in one frame
/// (the user's recording, 2026-10-22). So for this long after landing, under
/// a held key, the animation stays alive at an offset nobody can see, and the
/// backlog resumes the glide, which spreads it over `glide_catch_ms`
/// (modelled: peak 1.5 -> 0.95 rows a frame). A real release just idles
/// invisibly this long.
pub const glide_linger_max_ms: f32 = 300;

/// The stiffness of the `spring` easing, as a multiple of 1/duration. At 6 a
/// single one-row push from rest is inside half a pixel in ~0.6 x duration,
/// and steady scrolling at V px/s trails the model by 2V/omega = V x
/// duration / 3 -- 100 ms at the default-ish 300 ms.
pub const spring_k: f32 = 6;

pub fn active(self: ScrollAnim) bool {
    return self.offset_px != 0;
}

/// Record a scroll of `offset_px` over rows [top, bottom].
///
/// Displacement **accumulates** while an animation is in flight. This is the
/// non-obvious part. If the screen is already drawn a fraction of a row behind
/// the model and the model scrolls again, the display is now behind by the sum
/// of the two: the previous shortfall did not stop being true just because
/// more scrolling happened. Replacing instead of adding pins the display a
/// constant one row behind during continuous scrolling and then snaps at the
/// end, which reads as lag rather than motion.
///
/// A scroll over a *disjoint* region replaces, because the pending offset
/// describes rows that are no longer the ones moving. Overlapping regions
/// still accumulate: tmux jitters its scrolling region by a row as it redraws
/// (1..52 one frame, 2..52 the next), and treating that as a new region threw
/// the pending displacement away, so the content snapped instead of sliding.
///
/// `limit` caps the accumulated displacement, so a burst cannot wind the
/// offset up to something that flashes unrelated content when it unwinds.
///
/// An accumulating push **unions** the region rather than adopting the new
/// one. The invariant is that the region covers everything that contributed
/// to the offset now standing, and it is the invariant whose absence drew the
/// screen tearing.
///
/// Two producers describe the same physical scroll: the application's own
/// scroll events and the repaint detector. They do not agree on its extent,
/// and they alternate frame to frame through a single gesture. Measured on a
/// 55x210 grid with nvim scrolling a wrapped markdown buffer, one C-e burst
/// produced, interleaved:
///
///     scroll event:  rows 0..52, columns 0..209   (nvim's own margins)
///     repaintscroll: rows 0..54, columns 2..207   (what visibly changed)
///     repaintscroll: rows 0..54, columns 5..204
///
/// Adopting the newer region while keeping the accumulated offset meant every
/// row and column dropped from it snapped the whole standing displacement --
/// 15 to 48px, up to a row and a quarter -- to zero in one frame and back on
/// the next. That is a seam along the region's edge, flickering at frame rate:
/// the status line jittering at the bottom, and a ragged strip at each side
/// where the gap the scroll left behind stops being drawn. It reads exactly
/// like a torn frame, which is why it was reported as one.
pub fn push(
    self: *ScrollAnim,
    offset_px: f32,
    top: f32,
    bottom: f32,
    left: f32,
    right: f32,
    limit: f32,
) void {
    // Disjoint in *either* axis is a different region. Columns matter as much
    // as rows: yazi scrolls a preview pane beside a file list that holds
    // still, and carrying a pending offset from one to the other would
    // displace a pane by a distance its own content never travelled.
    const overlaps = self.active() and
        self.top <= bottom and top <= self.bottom and
        self.left <= right and left <= self.right;
    const base: f32 = if (overlaps) self.offset_px else 0;

    // `limit` stops a burst of pushes winding up, not one deliberate move: a
    // single push is displaced by its whole distance (callers already refuse
    // anything over `max_animated_rows`), so yazi's five-row `J` or a tmux
    // batch of rows slides whole instead of snapping all but two rows.
    const cap = @max(@abs(limit), @abs(offset_px));
    const combined = std.math.clamp(base + offset_px, -cap, cap);
    self.offset_px = if (@abs(combined) < min_offset_px) 0 else combined;

    // Restart the curve from wherever we now are. A scroll arriving mid-flight
    // should accelerate away from the current position, not resume a curve
    // aimed at a total that is no longer true.
    // Keep pace with input. Every push restarts the ease from zero, so a
    // held key -- a row every ~33ms of repeat -- keeps restarting a 300ms ramp
    // that has barely begun, the standing offset pins itself at `limit`, and
    // every row beyond it is clipped: drawn as a snap. A longer duration
    // clips more. So while pushes land on a live animation, the time since
    // the last one is the input's interval, and this burst eases over at
    // most `pace_intervals` of them: at 30Hz that is ~130ms, which in steady
    // state stands at ~36px of a 42px cap. A push slower than
    // `duration / pace_intervals` is left at the configured duration, and a
    // push onto an idle animation clears the pace, so an isolated scroll
    // always takes exactly what was configured.
    //
    // The interval is averaged, not taken from the last push alone.
    // `elapsed_ms` only grows a frame at a time, so 40 Hz key repeat on a
    // 60 Hz display measures 17, 33, 17, 33 ms -- and with `key_paced` the
    // spring's stiffness doubled and halved on every key: held j in nvim went
    // fast, fast, slow, slow, slow, slow ten times a second (steps of 7 to
    // 31 px against a mean of 13; smooth% 85, 2026-10-14 under Hyprland).
    // Two pushes inside one frame measure 0, which the average needs too.
    //
    // Except the first interval, when the second is under half of it: held
    // j's first repeat comes 300 ms after the press and every one after it
    // 25 ms apart, and averaged, the 1200 ms that delay seeded took ~12 keys
    // to wash out -- for the first half second of every hold the spring was
    // soft enough to fall 8 rows behind (165 px, the user's "held j lags",
    // 2026-10-14). Only the first: taking every 2x speed-up at once also
    // caught nvim resuming after a 170 ms pause at a table, which went soft
    // then stiff around every one (hold_j_tables smooth% 95 -> 88).
    if (!overlaps) {
        self.pace_ms = 0;
        self.pace_samples = 0;
    } else {
        const measured = self.elapsed_ms * pace_intervals;
        const repeat_delay = self.pace_samples == 1 and measured > 0 and
            2 * measured < self.pace_ms;
        self.pace_ms = if (self.pace_ms > 0 and !repeat_delay)
            self.pace_ms + (measured - self.pace_ms) * pace_smoothing
        else if (measured > 0) measured else 0;
        if (self.pace_ms > 0) self.pace_samples +|= 1;
    }

    self.start_px = self.offset_px;
    self.elapsed_ms = 0;
    self.limit_px = @abs(limit);
    if (!overlaps) {
        self.vel_px_ms = 0;
        self.from_rest = true;
    }
    // A new burst, or the other way: the glide's averages describe some
    // other motion.
    if (!overlaps or (base != 0 and (base > 0) != (offset_px > 0))) {
        self.glide_rate = 0;
        self.glide_iv_ms = 0;
        self.glide_pending_px = 0;
        self.glide_since_ms = 0;
        self.glide_samples = 0;
        self.glide_sum_px = 0;
        self.glide_sum_ms = 0;
        self.gliding = false;
    }
    self.glide_pending_px += @abs(offset_px);
    self.glide_linger_ms = 0;
    if (overlaps) {
        // Union, per the note above. This only ever grows over regions that
        // were actually pushed -- rows and columns something told us really
        // moved -- and it is discarded the moment the offset reaches zero,
        // so it cannot creep outwards across a gesture boundary.
        self.top = @min(self.top, top);
        self.bottom = @max(self.bottom, bottom);
        self.left = @min(self.left, left);
        self.right = @max(self.right, right);
    } else {
        self.top = top;
        self.bottom = bottom;
        self.left = left;
        self.right = right;
    }
}

pub fn stop(self: *ScrollAnim) void {
    self.offset_px = 0;
    self.start_px = 0;
    self.elapsed_ms = 0;
    self.vel_px_ms = 0;
}

/// Would a push over this region add to the running offset (true) or replace
/// it (false)? The renderer needs to know before it pushes: the rows it keeps
/// for drawing the band belong to the running animation's region.
pub fn accumulates(self: ScrollAnim, top: f32, bottom: f32, left: f32, right: f32) bool {
    return self.active() and
        self.top <= bottom and top <= self.bottom and
        self.left <= right and left <= self.right;
}

/// The shape of the motion.
///
/// A linear ramp arrives at full speed and stops dead, which reads as
/// mechanical next to a browser however short it is. Which *curve* reads best
/// is a matter of taste and of how big one step is, so it is a setting rather
/// than a constant.
pub const Easing = enum {
    linear,
    ease_out_cubic,
    ease_out_quint,
    /// cubic-bezier(0.4, 0.0, 0.2, 1.0) -- the curve browsers and Material
    /// interfaces use for moving something into place. Unlike a pure ease-out
    /// it starts gently as well, which reads as the content having weight.
    material,
    /// cubic-bezier(0.25, 0.46, 0.45, 0.94).
    ease_out_quad,
    /// Not a curve: a critically damped spring pulling the drawn position
    /// onto the model. See `advanceSpring`. Every other easing restarts its
    /// curve on every push, and an ease-out is fastest at its start, so
    /// steady input -- a held key, a wheel spinning -- kicks the speed up at
    /// every row and lets it sag until the next: measured 5 to 13 px per
    /// refresh holding j. A spring keeps its velocity across a push, so
    /// steady input settles into steady motion.
    spring,
};

/// Evaluate a cubic Bezier with P0=(0,0), P3=(1,1) at `x`.
///
/// The curve is parameterised by u, not by x, so x must be inverted first.
/// Newton-Raphson converges in a handful of steps here because the curve is
/// monotonic in x for the control points we allow; the bisection fallback
/// keeps a pathological pair from spinning.
fn bezier(x1: f32, y1: f32, x2: f32, y2: f32, x: f32) f32 {
    const curve = struct {
        fn at(a: f32, b: f32, u: f32) f32 {
            const inv = 1.0 - u;
            // 3(1-u)^2 u a + 3(1-u) u^2 b + u^3
            return 3.0 * inv * inv * u * a +
                3.0 * inv * u * u * b +
                u * u * u;
        }
        fn slope(a: f32, b: f32, u: f32) f32 {
            const inv = 1.0 - u;
            return 3.0 * inv * inv * a +
                6.0 * inv * u * (b - a) +
                3.0 * u * u * (1.0 - b);
        }
    };

    var u = x;
    for (0..8) |_| {
        const dx = curve.at(x1, x2, u) - x;
        if (@abs(dx) < 1e-5) return curve.at(y1, y2, u);
        const d = curve.slope(x1, x2, u);
        if (@abs(d) < 1e-6) break;
        u -= dx / d;
    }

    var lo: f32 = 0;
    var hi: f32 = 1;
    u = x;
    for (0..24) |_| {
        const cx = curve.at(x1, x2, u);
        if (@abs(cx - x) < 1e-5) break;
        if (cx > x) hi = u else lo = u;
        u = (lo + hi) / 2.0;
    }
    return curve.at(y1, y2, u);
}

fn easeOut(t: f32, easing: Easing) f32 {
    const inv = 1.0 - t;
    return switch (easing) {
        .linear => t,
        .ease_out_cubic => 1.0 - inv * inv * inv,
        .ease_out_quint => 1.0 - inv * inv * inv * inv * inv,
        .material => bezier(0.4, 0.0, 0.2, 1.0, t),
        .ease_out_quad => bezier(0.25, 0.46, 0.45, 0.94, t),
        // Only reached by callers asking for a curve; the spring itself runs
        // in `advanceSpring`. Its from-rest shape, normalised to end at 1.
        .spring => (1.0 - @exp(-spring_k * t)) / (1.0 - @exp(-spring_k)),
    };
}

/// Advance the animation by `dt_ms`, retiring the displacement over
/// `duration_ms`.
///
/// Eased rather than linear, and computed from elapsed time rather than
/// integrated, so a dropped or long frame lands where it should instead of
/// accumulating error.
pub fn advance(
    self: *ScrollAnim,
    dt_ms: f32,
    duration_cfg_ms: f32,
    easing: Easing,
) void {
    if (!self.active()) return;
    if (easing == .spring) return self.advanceSpring(dt_ms, duration_cfg_ms);
    const duration_ms = if (self.pace_ms > 0) @min(duration_cfg_ms, self.pace_ms) else duration_cfg_ms;

    // A stalled or hidden surface can hand us a huge dt. Finishing early is
    // the right failure: the model is already correct, so snapping to it
    // shows the truth rather than a stale intermediate position.
    if (!(dt_ms > 0)) return;

    // A duration of zero means "do not animate", so land on the model at
    // once. Returning early here instead -- which is what a guard against
    // dividing by zero looks like if you write it without thinking about it
    // -- leaves the displacement standing for good, holding the text off the
    // character grid until some later scroll happens to clear it.
    if (!(duration_ms > 0)) {
        self.offset_px = 0;
        return;
    }

    self.elapsed_ms += dt_ms;
    if (self.elapsed_ms >= duration_ms) {
        self.offset_px = 0;
        return;
    }

    const remaining = self.start_px *
        (1.0 - easeOut(self.elapsed_ms / duration_ms, easing));
    self.offset_px = if (@abs(remaining) < min_offset_px) 0 else remaining;
}

/// Advance the `spring` easing by `dt_ms`.
///
/// Critically damped, integrated exactly rather than stepped, so the motion
/// does not depend on the frame rate:
///
///     x(t) = (x0 + (v0 + w*x0) t) e^(-w t)
///     v(t) = (v0 - w (v0 + w*x0) t) e^(-w t)
///
/// A push moves the model and the offset by the same distance, so the drawn
/// position does not move and -- since the velocity is untouched -- neither
/// does its speed. That is the whole point.
///
/// Two adjustments. A push onto an idle animation sets off at once
/// (v0 = -w*x0, a plain exponential ease-out), or a single keypress would
/// start from standstill and feel late. And the spring stiffens as the offset
/// nears its cap, so a flood of rows pulls it along faster instead of piling
/// up against the cap and being clipped -- which would snap.
fn advanceSpring(self: *ScrollAnim, dt_ms: f32, duration_ms: f32) void {
    if (!(dt_ms > 0)) return;
    // Not part of the motion; it is what `push` measures the input's
    // interval by, for `pace_ms`.
    self.elapsed_ms += dt_ms;
    if (!(duration_ms > 0)) {
        self.offset_px = 0;
        self.vel_px_ms = 0;
        return;
    }
    if (self.advanceGlide(dt_ms)) return;
    var w = spring_k / duration_ms;
    // A held key. At the user's 580 ms and 40 Hz repeat the spring trailed
    // the model by ~7.5 rows, which an application with a screen-fixed
    // cursor shows as a lie: yazi's hover bar holds still while the names
    // under it run 7 files behind, and when the list stops at its end they
    // catch up in half a second -- "skips 4 or 5 files" (2026-10-12). Kept
    // to the input's own pace the lag is 2V x pace / k, ~1.3 rows at 40 Hz.
    // `pace_ms` is only set while pushes land on a live animation, so a
    // single press still takes the configured duration, and the wheel --
    // whose deep lag is deliberate, see `ghost_lag_rows` -- never gets here.
    if (self.key_paced and self.pace_ms > 0) w = @max(w, spring_k / self.pace_ms);
    // Stiffen only past the cap itself. Starting at half of it made one big
    // batch -- nvim catching up 24 rows at once -- read as a flood, and it
    // was retired in about a frame: a snap by another name (measured, 400 px
    // in one refresh).
    if (self.limit_px > 0) {
        const over = @abs(self.offset_px) / self.limit_px;
        if (over > 1) w *= over;
    }
    if (self.from_rest) {
        self.vel_px_ms = -w * self.offset_px;
        self.from_rest = false;
    }
    // A stalled surface can hand us a huge dt; the formula is exact for any
    // dt, and e^(-w dt) simply goes to zero.
    const x0 = self.offset_px;
    const v0 = self.vel_px_ms;
    const e = @exp(-w * dt_ms);
    const b = v0 + w * x0;
    const x = (x0 + b * dt_ms) * e;
    const v = (v0 - w * b * dt_ms) * e;
    if (@abs(x) < min_offset_px and @abs(v) * 16 < min_offset_px) {
        // Landed. Under a held key that was gliding, linger: see
        // `glide_linger_max_ms`. Drawn offsets under half a pixel are
        // drawn as zero, so this is invisible.
        if (self.key_paced and self.glide_samples >= glide_min_samples and
            self.glide_linger_ms < glide_linger_max_ms)
        {
            self.glide_linger_ms += dt_ms;
            self.offset_px = std.math.copysign(min_offset_px * 0.01, x0);
            self.vel_px_ms = 0;
            return;
        }
        self.offset_px = 0;
        self.vel_px_ms = 0;
        return;
    }
    self.offset_px = if (@abs(x) < min_offset_px * 0.01) 0 else x;
    self.vel_px_ms = v;
    // An offset of exactly zero ends the animation (`active`), so a spring
    // passing through zero mid-motion must not land on it.
    if (self.offset_px == 0) self.offset_px = std.math.copysign(min_offset_px * 0.01, v);
}

/// A held key, gliding: move at the input's own averaged speed instead of
/// springing after each row. Returns false, leaving the frame to the spring,
/// until the hold is steady, and again once the rows stop coming.
///
/// Why (2026-10-22). Held j looked like it stuttered and jumped. Filmed per
/// refresh, the text moved 0.4-1.1 rows a refresh around a mean of 0.67
/// (sd 18-24 %; the wheel at the same speed: 5-7 %), and the build before
/// key pacing (2026-10-12) did 9-14 %. Pacing made the spring stiff enough
/// to follow within 1.3 rows -- time constant ~17 ms at 40 Hz -- and a
/// spring that stiff passes nvim's timing straight through: rows land 17 to
/// 35 ms apart, not 25, and a stiff spring speeds up and slows down with
/// every one. A soft spring smooths it but trails V x duration / 3 behind,
/// which is the lag pacing removed. A spring cannot do both: its lag under
/// steady scrolling is what its softness costs.
///
/// So under a steady hold the speed is not a spring's response to each row
/// but the input's own rate, averaged over many (`glide_alpha`), and the
/// offset only steers it: `glide_lead_ms` of travel is kept in hand to
/// absorb a late row, anything beyond it is closed over `glide_catch_ms`,
/// and inside it the glide slows in proportion. The lag stays where pacing
/// put it (~1 row at 40 Hz). Replayed through a Python copy of this file
/// with the nvim timing of 24 filmed holds (~/playground/fast-scroll/
/// glide-sim): sd of rows per refresh, median 15.6 % -> 5.2 % (mean 19.4 ->
/// 9.9; holds where nvim itself stalled 170 ms stay bad either way); median
/// lag 1.05 -> 1.10 rows; landing after the last row 76 -> 73 ms. The rate
/// warms up as a plain mean and is then averaged as distance over time,
/// see `glide_warm_samples`. A single press, a Ctrl-D glide (rows faster than one a
/// `glide_min_interval_ms`) and the wheel never glide; a release or a stall
/// hands the remaining offset back to the spring, velocity and all.
fn advanceGlide(self: *ScrollAnim, dt_ms: f32) bool {
    // One rate sample per frame that brought rows: what they moved over the
    // time since the last frame that did. Rows land on frames, so a single
    // interval reads 17 or 33 ms at 40 Hz on 60 Hz; the average does not.
    if (self.glide_pending_px > 0) {
        if (self.glide_since_ms > 0) {
            const r = self.glide_pending_px / self.glide_since_ms;
            // The first sample may span the repeat delay; the first faster
            // one replaces it rather than averaging with it.
            if (self.glide_samples == 0 or (self.glide_samples < 3 and r > 2 * self.glide_rate)) {
                self.glide_rate = r;
                self.glide_iv_ms = self.glide_since_ms;
                self.glide_sum_px = self.glide_pending_px;
                self.glide_sum_ms = self.glide_since_ms;
            } else if (self.glide_samples < glide_warm_samples) {
                self.glide_sum_px += self.glide_pending_px;
                self.glide_sum_ms += self.glide_since_ms;
                self.glide_rate = self.glide_sum_px / self.glide_sum_ms;
                self.glide_iv_ms += (self.glide_since_ms - self.glide_iv_ms) * glide_alpha;
                if (self.glide_samples + 1 == glide_warm_samples) {
                    // From here they are averages per sample, see below.
                    const n: f32 = @floatFromInt(glide_warm_samples);
                    self.glide_sum_px /= n;
                    self.glide_sum_ms /= n;
                }
            } else {
                // Distance and time averaged apart, then divided: averaging
                // each frame's own rate weights a 17 ms sample (1.2 px/ms
                // at 40 Hz) like a 33 ms one (0.6), and read 0.9 for a true
                // 0.8 -- the glide ran ahead of the rows and kept braking.
                self.glide_sum_px += (self.glide_pending_px - self.glide_sum_px) * glide_alpha;
                self.glide_sum_ms += (self.glide_since_ms - self.glide_sum_ms) * glide_alpha;
                self.glide_rate = self.glide_sum_px / self.glide_sum_ms;
                self.glide_iv_ms = self.glide_sum_ms;
            }
            self.glide_samples +|= 1;
        }
        self.glide_pending_px = 0;
        self.glide_since_ms = 0;
    }
    self.glide_since_ms += dt_ms;

    const steady = self.key_paced and
        self.glide_samples >= glide_min_samples and
        self.pace_ms >= pace_intervals * glide_min_interval_ms;
    const released = self.glide_since_ms >
        @max(glide_release_intervals * self.glide_iv_ms, glide_release_min_ms);
    if (!steady or released) {
        self.gliding = false;
        return false;
    }
    if (!self.gliding) {
        self.gliding = true;
        self.glide_v = @abs(self.vel_px_ms);
    }

    const g = @abs(self.offset_px);
    const sign: f32 = if (self.offset_px > 0) 1 else -1;
    const lead = @max(self.glide_rate * glide_lead_ms, 1.0);
    const target = if (g >= lead)
        self.glide_rate + (g - lead) / glide_catch_ms
    else
        self.glide_rate * g / lead;
    self.glide_v += (target - self.glide_v) * (1.0 - @exp(-dt_ms / glide_smooth_ms));
    var g2 = g - self.glide_v * dt_ms;
    // Caught up with the model: wait there for the next row rather than
    // end the animation, which would throw the averages away.
    if (g2 < min_offset_px) {
        g2 = min_offset_px;
        self.glide_v = 0;
    }
    self.offset_px = sign * g2;
    self.vel_px_ms = -sign * self.glide_v;
    return true;
}

/// Decode a ghost row's grid y: rows above the region are stored as wrapped
/// u16 (a grid position has no sign), so 65535 is the row just above row 0.
pub fn ghostY(y: u16) i32 {
    return @as(i16, @bitCast(y));
}

pub fn ghostYEncode(y: i32) u16 {
    return @bitCast(@as(i16, @intCast(y)));
}

/// Move the kept rows along with a scroll of `rows` (content up by `rows`)
/// and drop the ones that are no longer needed: back inside [top, bottom],
/// where the application has drawn the real thing, or further than
/// `max_ghost_rows` beyond either edge, where no offset will ever reach.
/// `T` is any glyph type with a `grid_pos: [2]u16`.
pub fn shiftGhosts(comptime T: type, ghosts: *std.ArrayListUnmanaged(T), rows: isize, top: usize, bottom: usize) void {
    const t: i32 = @intCast(top);
    const b: i32 = @intCast(bottom);
    const far: i32 = @intCast(max_ghost_rows);
    var w: usize = 0;
    for (ghosts.items) |g| {
        const y = ghostY(g.grid_pos[1]) - @as(i32, @intCast(rows));
        if (y >= t and y <= b) continue;
        if (y < t - far or y > b + far) continue;
        var h = g;
        h.grid_pos[1] = ghostYEncode(y);
        ghosts.items[w] = h;
        w += 1;
    }
    ghosts.shrinkRetainingCapacity(w);
}

/// Keep the rows a scroll of `rows` is about to carry out of [top, bottom],
/// from `row_lists` (one glyph list per grid row, as last drawn), placed where
/// they now are relative to the model: above the region for content moving
/// up, below it for content moving down. Only glyphs in [left, right]: the
/// shader displaces nothing outside those columns, so a glyph kept from
/// beyond them would be drawn, undisplaced, on top of whatever is there.
pub fn captureGhosts(
    comptime T: type,
    alloc: std.mem.Allocator,
    ghosts: *std.ArrayListUnmanaged(T),
    row_lists: []const std.ArrayListUnmanaged(T),
    rows: isize,
    top: usize,
    bottom: usize,
    left: usize,
    right: usize,
) std.mem.Allocator.Error!void {
    if (rows == 0 or bottom < top or bottom >= row_lists.len) return;
    const n: usize = @min(@abs(rows), bottom - top + 1, max_ghost_rows);
    // Departing rows, nearest the edge last so the closest ones survive the
    // `max_ghost_rows` bound.
    const first: usize = if (rows > 0) top else bottom + 1 - n;
    for (first..first + n) |y| {
        const ny: i32 = @as(i32, @intCast(y)) - @as(i32, @intCast(rows));
        for (row_lists[y].items) |g| {
            if (g.grid_pos[0] < left or g.grid_pos[0] > right) continue;
            var h = g;
            h.grid_pos[1] = ghostYEncode(ny);
            try ghosts.append(alloc, h);
        }
    }
}

/// `shiftGhosts` for image row slices: anything with an `x: i32, y: i32`
/// grid position (`image.Placement`). A slice back inside [top, bottom] is
/// the model's again; one beyond `max_ghost_rows` can never be reached.
pub fn shiftGhostSlices(comptime T: type, ghosts: *std.ArrayListUnmanaged(T), rows: isize, top: usize, bottom: usize) void {
    const t: i32 = @intCast(top);
    const b: i32 = @intCast(bottom);
    const far: i32 = @intCast(max_ghost_rows);
    var w: usize = 0;
    for (ghosts.items) |g| {
        const y = g.y - @as(i32, @intCast(rows));
        if (y >= t and y <= b) continue;
        if (y < t - far or y > b + far) continue;
        var h = g;
        h.y = y;
        ghosts.items[w] = h;
        w += 1;
    }
    ghosts.shrinkRetainingCapacity(w);
}

/// `captureGhosts` for image row slices: of `drawn` (the placements as last
/// drawn), keep the one-row slices on the rows a scroll of `rows` carries out
/// of [top, bottom], starting in [left, right], placed where they now are.
/// Only unicode-placeholder slices qualify (z == -1, one row each); a
/// classic placement spans rows and is not the grid's to move.
pub fn captureGhostSlices(
    comptime T: type,
    alloc: std.mem.Allocator,
    ghosts: *std.ArrayListUnmanaged(T),
    drawn: []const T,
    rows: isize,
    top: usize,
    bottom: usize,
    left: usize,
    right: usize,
) std.mem.Allocator.Error!void {
    if (rows == 0 or bottom < top) return;
    const n: usize = @min(@abs(rows), bottom - top + 1, max_ghost_rows);
    const first: i32 = @intCast(if (rows > 0) top else bottom + 1 - n);
    const last: i32 = first + @as(i32, @intCast(n)) - 1;
    for (drawn) |p| {
        if (p.z != -1) continue;
        if (p.y < first or p.y > last) continue;
        if (p.x < @as(i32, @intCast(left)) or p.x > @as(i32, @intCast(right))) continue;
        var h = p;
        h.y = p.y - @as(i32, @intCast(rows));
        try ghosts.append(alloc, h);
    }
}

/// Forget the kept copies of a row found PINNED (see `trimPinnedRows`):
/// the glyphs in `row` (as last drawn) that some kept glyph duplicates in the
/// same column, same glyph and colour. Before the row was recognised, the
/// label on it slid with the region and was kept once per row scrolled; the
/// rest of what was kept is real content and stays -- dropping all of it
/// left the band behind the lag blank.
pub fn dropGhostCopies(comptime T: type, ghosts: *std.ArrayListUnmanaged(T), row: []const T) void {
    var w: usize = 0;
    outer: for (ghosts.items) |g| {
        for (row) |r| {
            if (r.grid_pos[0] == g.grid_pos[0] and
                std.mem.eql(u32, &r.glyph_pos, &g.glyph_pos) and
                std.mem.eql(u8, &r.color, &g.color)) continue :outer;
        }
        ghosts.items[w] = g;
        w += 1;
    }
    ghosts.shrinkRetainingCapacity(w);
}

/// The same for kept backgrounds: cells equal to the pinned row's own
/// non-transparent background in that column.
pub fn dropGhostBgCopies(comptime T: type, ext: []T, row_bg: []const T) void {
    const cols = row_bg.len;
    if (cols == 0 or ext.len % cols != 0) return;
    const zero = std.mem.zeroes(T);
    var e: usize = 0;
    while (e < ext.len) : (e += cols) {
        for (0..cols) |c| {
            if (std.meta.eql(row_bg[c], zero)) continue;
            if (std.meta.eql(ext[e + c], row_bg[c])) ext[e + c] = zero;
        }
    }
}

/// A run of this many cells pins (see `computePins`).
pub const pin_min_cells: usize = 4;

/// Mark the cells that are an OVERLAY on a scroll: a coloured background
/// that stayed where it was on screen while the content under it moved.
/// yazi's selection bar when the list scrolls under a cursor that stays on
/// its row; Claude Code's "Jump to bottom" box on top of the transcript; an
/// editor's cursor line riding the window's edge. Displacing them slid the
/// bar away from the line number and caps drawn beside it, or dragged the
/// label along with the text -- and pinning the whole row instead (the
/// earlier fix for the label) froze the text beside it too.
///
/// A cell pins when its background is not the default, is the same as the
/// frame before at the same place, and is NOT what the shift carried there.
/// Runs of `pin_min_cells` only: an inline-code highlight coinciding with
/// the one above it is a few cells, a bar or a label is a run. `pins` gets
/// 255 in byte 0 for a pinned cell, 0 otherwise, over the whole grid.
pub fn computePins(
    comptime T: type,
    pins: []T,
    bg_prev: []const T,
    bg_now: []const T,
    cols: usize,
    shift: isize,
    top: usize,
    bottom: usize,
    left: usize,
    right: usize,
) void {
    const zero = std.mem.zeroes(T);
    @memset(pins, zero);
    if (cols == 0 or bg_now.len != bg_prev.len or pins.len != bg_now.len) return;
    const rows = bg_now.len / cols;
    if (bottom >= rows or right >= cols or top > bottom or left > right) return;
    var mark = zero;
    mark[0] = 255;
    const eq = std.meta.eql;
    for (top..bottom + 1) |r| {
        const src = @as(isize, @intCast(r)) + shift;
        const src_row: ?usize = if (src < 0 or src >= @as(isize, @intCast(rows))) null else @intCast(src);
        // Where the last pinned run on this row ended: a coloured run that
        // starts right there belongs to the same overlay. yazi's hovered
        // row is the bar over the name AND a second shade over a symlink's
        // `-> target`; only the first was held, so the target's highlight
        // slid off the bar and left the name's black box behind.
        var pinned_end: ?usize = null;
        var c = left;
        while (c <= right) {
            const v = bg_now[r * cols + c];
            if (eq(v, zero)) {
                c += 1;
                continue;
            }
            // A run of one colour in this frame: [c, e).
            var e = c + 1;
            while (e <= right and eq(bg_now[r * cols + e], v)) e += 1;
            // The previous frame's run of that colour starting at the SAME
            // column: [c, pe). yazi's bar is as wide as the hovered name, so
            // its right end moves; its left end and colour do not.
            //
            // The colour itself may change: yazi's bar takes the hovered
            // file's colour (orange on one folder, purple on the next), and
            // asking for the same colour let the bar slide off with the list
            // on every such step -- its caps on one row, the bar on another.
            // Any coloured run that started at this column counts, except on
            // a row the scroll is bringing IN: there, a heading arriving
            // where another heading stood is content, not an overlay.
            const pv = bg_prev[r * cols + c];
            const arriving = if (shift > 0)
                r + @as(usize, @intCast(shift)) > bottom
            else
                r < top + @as(usize, @intCast(-shift));
            // And only where the text that scrolled into this row was BARE
            // before: a table whose cells are coloured at the same column
            // row after row (nvim) is one colour replacing another too, and
            // pinning those held table rows still on a fast wheel scroll.
            const src_bare = if (src_row) |sr| eq(bg_prev[sr * cols + c], zero) else false;
            const starts_here = !eq(pv, zero) and (eq(pv, v) or (!arriving and src_bare)) and
                (c == 0 or !eq(bg_prev[r * cols + c - 1], pv));
            var pe = c;
            if (starts_here) {
                pe = c + 1;
                while (pe <= right and eq(bg_prev[r * cols + pe], pv)) pe += 1;
            }
            // ...and not simply what the shift carried there.
            const carried = if (src_row) |sr| eq(bg_prev[sr * cols + c], v) and
                (c == 0 or !eq(bg_prev[sr * cols + c - 1], v)) else false;
            // One row tall: the rows above and below do not carry the same
            // colour at the run's start. The first and last rows of a tall
            // coloured block (Claude Code's green diff, a code block) are
            // also "the same here, not what the shift carried" -- and
            // pinning them froze a band of the block while the rest slid.
            const above = r > 0 and eq(bg_now[(r - 1) * cols + c], v);
            const below = r + 1 < rows and eq(bg_now[(r + 1) * cols + c], v);
            const len = @max(e, pe) - c;
            // Any later coloured run on a row that holds an overlay is part
            // of it, touching or not: the shade over the target starts a
            // cell after the name, and left unpinned it slid in from the row
            // below -- a piece of the bar on the wrong row.
            const joins = pinned_end != null;
            if ((starts_here or joins) and !carried and !above and !below and (joins or len >= pin_min_cells)) {
                @memset(pins[r * cols + c .. r * cols + @max(e, pe)], mark);
                pinned_end = @max(e, pe);
            }
            c = e;
        }
    }
}

/// The backgrounds of the kept rows, as an EXTENDED grid: `max_ghost_rows`
/// rows above row 0, the grid's own rows, and `max_ghost_rows` below, so
/// grid row y is `ext` row `y + max_ghost_rows`. Only rows outside the
/// region are ever set; the renderer appends this after the real
/// background cells and the background shader reads it for the band.
///
/// Without it the band drew kept text on the global background: inline
/// code, a highlighted line, a table header, lost their colour for the
/// length of a slide -- "the first 4-8 lines look like a filter
/// unhighlights them", on every hard flick.
/// Which pinned runs hold their TEXT still as well as their colour: byte 1 of
/// the mask. A pin is an overlay the scroll passes under, and there are two
/// kinds. Claude Code's "Jump to bottom" label is text that never moved, and
/// must stay whole while the transcript slides under it. yazi's selection bar
/// is only a COLOUR that stays: the names in it are the list, and the next
/// name arrives there with every step. Holding that text too froze the
/// hovered name while the number to its left and the size to its right slid
/// on -- the row came apart ("starship" detached from "45" and "1").
///
/// A run's text is held when most of its glyphs are the same as last frame.
/// `now`/`before` are the detector's cell hashes; without them (the gate was
/// closed) every pinned run holds its text, as before this existed.
/// Pin TEXT that stayed put while the scroll says something else should be
/// there -- an overlay whose colour cannot find it. Claude Code's "Jump to
/// bottom" box on a row of the same grey (its sticky prompt rows) is one run
/// of one colour with the row, so `computePins` never saw it: the label slid
/// with the text, and every kept row carried a copy -- a stack of labels.
///
/// A cell qualifies when its full key (glyph and style) is the same as last
/// frame AND differs from what the shift carried there, so identical lines
/// moving past each other never do. A run is those cells with gaps of at most
/// one blank (words), holding at least `pin_text_min` glyphs: relative line
/// numbers also stay put, but are never that long.
pub const pin_text_min: usize = 8;

pub fn pinStillText(
    comptime T: type,
    pins: []T,
    now: []const u64,
    before: []const u64,
    cols: usize,
    shift: isize,
    top: usize,
    bottom: usize,
    left: usize,
    right: usize,
) void {
    if (cols == 0 or now.len != pins.len or before.len != pins.len) return;
    const rows = pins.len / cols;
    if (bottom >= rows or right >= cols or top > bottom or left > right) return;
    for (top..bottom + 1) |r| {
        const src = @as(isize, @intCast(r)) + shift;
        if (src < 0 or src >= @as(isize, @intCast(rows))) continue;
        const sr: usize = @intCast(src);
        // On a row that already holds a coloured overlay, any glyph that
        // stayed put belongs to it: yazi draws its bar's round end caps as
        // characters in the bar's colour on no background, and the cursor's
        // line number beside it; they slid off the held bar. Not glyphs
        // INSIDE the bar -- its text is the list's (see markPinnedText).
        var bar_row = false;
        for (left..right + 1) |x| if (pins[r * cols + x][0] != 0) {
            bar_row = true;
            break;
        };
        // And the row must have MOVED around the run -- its other text
        // changed. A row the application has not redrawn yet this frame
        // also "stayed put", all of it (yazi's last row, once).
        var others: usize = 0;
        var changed: usize = 0;
        for (left..right + 1) |x| {
            const k = r * cols + x;
            if (glyphOf(now[k]) == blank_glyph) continue;
            others += 1;
            if (now[k] != before[k]) changed += 1;
        }
        // (Beside a held bar one changed glyph is enough: "video-use" to
        // "Videos" keeps most of its letters, and the caps slid off.)
        if (if (bar_row) changed == 0 else changed * 2 < others) continue;
        const min_run: usize = if (bar_row) 1 else pin_text_min;
        var run_start: ?usize = null;
        var run_end: usize = 0; // one past the last still glyph
        var glyphs: usize = 0;
        var c = left;
        while (c <= right + 1) : (c += 1) {
            const k = r * cols + c;
            // A bar's cap is drawn in the bar's colour, which changes with
            // the hovered file: for symbol glyphs (private use and up, where
            // the caps live) on a bar's row the same GLYPH is enough.
            const cap = c <= right and bar_row and glyphOf(now[k]) >= 0xE000 and
                glyphOf(now[k]) == glyphOf(before[k]) and
                glyphOf(now[k]) != glyphOf(before[sr * cols + c]);
            const still = c <= right and glyphOf(now[k]) != blank_glyph and
                ((now[k] == before[k] and now[k] != before[sr * cols + c]) or cap) and
                !(bar_row and pins[k][0] != 0 and pins[k][1] == 0);
            if (still) {
                if (run_start == null) run_start = c;
                run_end = c + 1;
                glyphs += 1;
                continue;
            }
            // A single blank inside a run continues it.
            if (run_start != null and c <= right and c == run_end and
                glyphOf(now[k]) == blank_glyph and now[k] == before[k]) continue;
            if (run_start) |st| {
                if (glyphs >= min_run) {
                    for (st..run_end) |x| {
                        pins[r * cols + x][0] = 255;
                        pins[r * cols + x][1] = 255;
                    }
                }
            }
            run_start = null;
            glyphs = 0;
        }
    }
}

test "pins: a label the same colour as its row is found by its text" {
    const T = [4]u8;
    const cols = 30;
    const rows = 3;
    var pins: [rows * cols]T = @splat(.{ 0, 0, 0, 0 });
    var now: [rows * cols]u64 = undefined;
    var before: [rows * cols]u64 = undefined;
    // Content moves up a row (shift 1); row 1 carries a label at 10..23.
    for (0..rows) |i| for (0..cols) |c| {
        before[i * cols + c] = cellKey(@intCast(1000 + i * cols + c), 0);
        now[i * cols + c] = cellKey(@intCast(1000 + (i + 1) * cols + c), 0);
    };
    const label = "Jump to bottom";
    for (label, 0..) |ch, j| {
        const k = cellKey(if (ch == ' ') blank_glyph else ch, 9);
        before[1 * cols + 10 + j] = k;
        now[1 * cols + 10 + j] = k;
    }
    pinStillText(T, &pins, &now, &before, cols, 1, 0, 1, 0, cols - 1);
    try std.testing.expectEqual(@as(u8, 255), pins[1 * cols + 10][0]);
    try std.testing.expectEqual(@as(u8, 255), pins[1 * cols + 23][0]);
    try std.testing.expectEqual(@as(u8, 0), pins[1 * cols + 9][0]);
    // Control: row 0 moved (now == what the shift carried), nothing pinned.
    for (0..cols) |c| try std.testing.expectEqual(@as(u8, 0), pins[c][0]);
}

test "pins: a held bar's end caps are held with it, the names inside are not" {
    const T = [4]u8;
    const cols = 20;
    const rows = 3;
    var pins: [rows * cols]T = @splat(.{ 0, 0, 0, 0 });
    var now: [rows * cols]u64 = undefined;
    var before: [rows * cols]u64 = undefined;
    for (0..rows) |i| for (0..cols) |c| {
        before[i * cols + c] = cellKey(@intCast(1000 + i * cols + c), 0);
        now[i * cols + c] = cellKey(@intCast(1000 + (i + 1) * cols + c), 0);
    };
    // Row 1: the bar's colour held at 5..14 (computePins found it); a cap
    // glyph at 4 and 15 that never moves; the name inside is new, except
    // that its first glyph happens to equal last frame's.
    for (5..15) |c| pins[1 * cols + c][0] = 255;
    for ([_]usize{ 4, 15 }) |c| {
        before[1 * cols + c] = cellKey(0xE0B6, 7);
        now[1 * cols + c] = cellKey(0xE0B6, 7);
    }
    before[1 * cols + 5] = cellKey('.', 8);
    now[1 * cols + 5] = cellKey('.', 8);
    // The right cap also changed colour with the bar (style 7 to 6).
    now[1 * cols + 15] = cellKey(0xE0B6, 6);
    pinStillText(T, &pins, &now, &before, cols, 1, 0, 1, 0, cols - 1);
    try std.testing.expectEqual(@as(u8, 255), pins[1 * cols + 4][1]);
    try std.testing.expectEqual(@as(u8, 255), pins[1 * cols + 15][1]);
    try std.testing.expectEqual(@as(u8, 0), pins[1 * cols + 5][1]);
    // Control: row 0 has no bar, so a lone still glyph there is not held.
    before[0 * cols + 3] = cellKey('x', 1);
    now[0 * cols + 3] = cellKey('x', 1);
    pinStillText(T, &pins, &now, &before, cols, 1, 0, 1, 0, cols - 1);
    try std.testing.expectEqual(@as(u8, 0), pins[0 * cols + 3][0]);
}

pub fn markPinnedText(comptime T: type, pins: []T, now: []const u64, before: []const u64, cols: usize) void {
    const have = now.len == pins.len and before.len == pins.len and cols > 0;
    var i: usize = 0;
    while (i < pins.len) {
        if (pins[i][0] == 0) {
            i += 1;
            continue;
        }
        var e = i;
        while (e < pins.len and pins[e][0] != 0 and (e == i or e % cols != 0)) e += 1;
        var glyphs: usize = 0;
        var same: usize = 0;
        if (have) for (i..e) |k| {
            const g = glyphOf(now[k]);
            if (g == blank_glyph) continue;
            glyphs += 1;
            if (g == glyphOf(before[k])) same += 1;
        };
        const hold = !have or (glyphs > 0 and same * 5 >= glyphs * 4);
        // Only ever sets: cells `pinStillText` held individually (a bar's
        // end caps) stay held inside a run whose text moves.
        if (hold) for (i..e) |k| {
            pins[k][1] = 255;
        };
        i = e;
    }
}

test "pins: a label's text is held, a bar's changing names are not" {
    const T = [4]u8;
    const cols = 10;
    var pins: [2 * cols]T = @splat(.{ 0, 0, 0, 0 });
    var now: [2 * cols]u64 = undefined;
    var before: [2 * cols]u64 = undefined;
    for (0..2 * cols) |k| {
        now[k] = cellKey(@intCast(100 + k), 0);
        before[k] = now[k];
    }
    // Row 0: a label, same text as last frame. Row 1: a bar over a new name.
    for (2..8) |c| {
        pins[c][0] = 255;
        pins[cols + c][0] = 255;
        before[cols + c] = cellKey(@intCast(900 + c), 0);
    }
    markPinnedText(T, &pins, &now, &before, cols);
    try std.testing.expectEqual(@as(u8, 255), pins[2][1]);
    try std.testing.expectEqual(@as(u8, 0), pins[cols + 2][1]);
    // Control: without the detector's hashes every pin holds its text.
    markPinnedText(T, &pins, &.{}, &.{}, cols);
    try std.testing.expectEqual(@as(u8, 255), pins[cols + 2][1]);
}

/// The background under each pinned cell, for its slid copy: the nearest
/// unpinned colour to its LEFT on the same row of the current frame (a
/// diff's green stays green, plain text stays bare), refreshed every frame.
/// Taking the colour the last push carried there instead was stale whenever
/// the application finished its redraw a frame later -- Claude Code: a red
/// box on a green row. Unpinned cells are left alone.
pub fn fillUnderlay(comptime T: type, under: []T, pins: []const T, bg_now: []const T, cols: usize) void {
    if (cols == 0 or under.len != pins.len or bg_now.len != pins.len) return;
    const nrows = pins.len / cols;
    const eq = std.meta.eql;
    for (0..nrows) |y| {
        for (0..cols) |c| {
            const k = y * cols + c;
            if (pins[k][0] == 0) continue;
            // Nearest unpinned cell to the left whose colour is NOT the pin's
            // own: yazi paints the icon cell in the bar's colour without it
            // being pinned, and filling from there slid a bar-coloured block
            // off the bar.
            var fill = std.mem.zeroes(T);
            var x = c;
            while (x > 0) {
                x -= 1;
                const j = y * cols + x;
                if (pins[j][0] != 0 or eq(bg_now[j], bg_now[k])) continue;
                fill = bg_now[j];
                break;
            }
            under[k] = fill;
        }
    }
}

test "underlay: a pinned cell's slid copy takes its row's colour from the left" {
    const T = [4]u8;
    const cols = 4;
    var pins: [2 * cols]T = @splat(.{ 0, 0, 0, 0 });
    var now: [2 * cols]T = undefined;
    var under: [2 * cols]T = @splat(.{ 0, 0, 0, 0 });
    for (0..2 * cols) |k| now[k] = .{ @intCast(k), 0, 0, 255 };
    pins[1 * cols + 2][0] = 255;
    pins[1 * cols + 3][0] = 255;
    pins[0][0] = 255; // at the left edge: nothing to its left
    fillUnderlay(T, &under, &pins, &now, cols);
    try std.testing.expectEqual(now[1 * cols + 1], under[1 * cols + 2]);
    try std.testing.expectEqual(now[1 * cols + 1], under[1 * cols + 3]);
    try std.testing.expectEqual(T{ 0, 0, 0, 0 }, under[0]);
}

pub fn ghostBgLen(rows: usize, cols: usize) usize {
    return (rows + 2 * max_ghost_rows) * cols;
}

/// Move the kept backgrounds with a scroll of `rows`, exactly as
/// `shiftGhosts` moves the glyphs, and forget any that are back inside
/// [top, bottom].
pub fn shiftGhostBg(comptime T: type, ext: []T, cols: usize, rows: isize, top: usize, bottom: usize) void {
    if (cols == 0 or ext.len % cols != 0) return;
    const n: isize = @intCast(ext.len / cols);
    const zero = std.mem.zeroes(T);
    if (rows != 0) {
        // new[e] = old[e + rows]: ascending when reading ahead, else descending.
        var i: isize = 0;
        while (i < n) : (i += 1) {
            const e = if (rows > 0) i else n - 1 - i;
            const src = e + rows;
            const dst_row = ext[@as(usize, @intCast(e)) * cols ..][0..cols];
            if (src < 0 or src >= n) {
                @memset(dst_row, zero);
            } else {
                @memcpy(dst_row, ext[@as(usize, @intCast(src)) * cols ..][0..cols]);
            }
        }
    }
    const g: usize = max_ghost_rows;
    const first = top + g;
    const last = @min(bottom + g, @as(usize, @intCast(n)) - 1);
    if (first <= last) @memset(ext[first * cols .. (last + 1) * cols], zero);
}

/// Keep the backgrounds of the rows a scroll of `rows` carries out of
/// [top, bottom] (the same rows `captureGhosts` keeps), from `bg`, the grid's
/// background cells as last drawn. Only columns [left, right].
pub fn captureGhostBg(
    comptime T: type,
    ext: []T,
    bg: []const T,
    cols: usize,
    rows: isize,
    top: usize,
    bottom: usize,
    left: usize,
    right: usize,
) void {
    if (rows == 0 or cols == 0 or bottom < top or bg.len % cols != 0) return;
    const grid_rows = bg.len / cols;
    if (bottom >= grid_rows or ext.len != ghostBgLen(grid_rows, cols) or right >= cols) return;
    const n: usize = @min(@abs(rows), bottom - top + 1, max_ghost_rows);
    const first: usize = if (rows > 0) top else bottom + 1 - n;
    for (first..first + n) |y| {
        const e = @as(isize, @intCast(y + max_ghost_rows)) - rows;
        if (e < 0 or e >= @as(isize, @intCast(ext.len / cols))) continue;
        const dst = ext[@as(usize, @intCast(e)) * cols ..][0..cols];
        @memset(dst, std.mem.zeroes(T));
        @memcpy(dst[left .. right + 1], bg[y * cols + left .. y * cols + right + 1]);
    }
}

/// The detector's key for one cell: the glyph in the low half, a hash of
/// everything else drawn -- style, colour, width -- in the high half.
///
/// Two cells with equal keys look identical. The low half alone answers a
/// different question, "did the *text* here change?", which is the one that
/// decides whether a cell can testify to a scroll at all: a blank looks like
/// every other blank, and a highlight moving over text that stays put is not
/// that text moving. See `detectShift`. Packing both into one word keeps the
/// detector's input a single array, and keeps any hash below 2^32 -- every
/// synthetic frame in the tests -- meaning exactly what it did before.
pub fn cellKey(glyph: u32, rest: u32) u64 {
    return (@as(u64, rest) << 32) | glyph;
}

/// The glyph half of a `cellKey`.
pub fn glyphOf(key: u64) u32 {
    return @truncate(key);
}

/// The glyph of a cell that draws no text, whatever colour it is painted.
pub const blank_glyph: u32 = 0;

/// Find the whole-row shift that best maps `cur` onto `prev`, or null.
///
/// `cur[i] == prev[i + shift]` means row i now holds what row i+shift held,
/// which is content moving *up* by `shift` -- the same sense as
/// `ScrollEvent.rows`, so a caller needs no negation.
///
/// This exists because some applications move the picture without ever saying
/// they scrolled: nvim repaints rather than scrolls when moving within a
/// wrapped line, and anything on the primary screen moves the scrollback
/// viewport instead. Hashing rows and looking for the offset recovers the
/// movement from what was drawn.
pub const Shift = struct {
    /// Rows the content moved up by; negative means down.
    rows: isize,

    /// Inclusive row range that moved.
    top: usize,
    bottom: usize,

    /// Inclusive *column* range that moved.
    ///
    /// Not every scroll is full width. yazi previews an nvim buffer in its
    /// right-hand pane while the file lists either side stay put, and a tmux
    /// vertical split is the same shape. Animating the whole row width there
    /// slides the stationary panes and springs them back, which is worse than
    /// not animating at all.
    left: usize,
    right: usize,
};

/// How long after an application's own scroll a detected counter-shift is
/// still read as its repair rather than a scroll. Generous: tmux can split
/// nvim's redraw across several of its own writes and frames.
pub const repair_window_ms: i64 = 250;

/// Is a repaint-detected `shift` just the application putting back rows that
/// its own scroll carried away?
///
/// An application that scrolls with a real scroll command (nvim's `DL`/`IL`,
/// delivered as a `ScrollEvent`) moves every column of the region, including
/// ones that are fixed to the SCREEN rather than to the text -- relative line
/// numbers, a cursor-line number, a sign or fold column. It rewrites those a
/// moment later, and when that rewrite lands in the next frame the detector
/// sees those few columns move by the scroll's distance the other way. Pushing
/// that is catastrophic: the animation keeps one offset for the region, so
/// the -N cancels the +N and the whole page snaps instead of sliding.
/// Measured on nvim with `relativenumber`: every 3-row wheel step read as
/// `shift=-3 cols=2..3` straight after `rows=3`, and 30-40% of frames on a
/// fast wheel spin had no slide at all.
///
/// A repair is: within `repair_window_ms` of the last event, and covering
/// less than half the event's width -- in EITHER direction. The first version
/// only caught the opposite sign; a fast wheel spin then produced
/// `shift=8 cols=2..2` (the number column, same direction) mid-scroll, which
/// pushed 160 px onto the whole page and lurched it backwards. While the
/// application is scrolling with scroll commands, a narrow strip moving is
/// always it repainting columns fixed to the screen. A full-width shift is
/// still a scroll -- the user changed direction, or the app repainted rather
/// than scrolled.
pub fn isRepair(
    last_event_rows: isize,
    since_event_ms: i64,
    event_cols: usize,
    shift: Shift,
) bool {
    if (last_event_rows == 0 or shift.rows == 0) return false;
    if (since_event_ms < 0 or since_event_ms > repair_window_ms) return false;
    const width = shift.right - shift.left + 1;
    return width * 2 < event_cols;
}

/// How many neutral columns a thinly-attested column may sit from the
/// cluster it widens: none, it has to touch it. See `detectShift`.
const weak_bridge_cols: usize = 0;

/// The exception: thin evidence starting at the screen's LEFT EDGE may sit
/// this many neutral columns from the strong cluster it widens. Claude Code
/// draws its message bullets in column 0 and the text from column 2, with
/// column 1 always blank; three bullets on screen are never `min_rows` of
/// evidence, so the bullets stood still while their text slid past them.
/// Nothing lies beyond the edge for such a column to have come from, which
/// is what separates it from yazi's selection glyphs a blank column to the
/// RIGHT of the relative numbers (see the test of that name).
const edge_bridge_cols: usize = 2;

/// No region narrower than this is a scroll. The strip that shifts alone is
/// a relative-number gutter being RELABELLED as the cursor moves over a list
/// that holds still: yazi at the bottom of a folder, where the list stops
/// scrolling and the cursor walks down. Measured `cols=27..28` on every `j`
/// there, which slid the numbers a row out of step with the selection bar
/// beside them ("58" and its icon detached from the rest of the row). A pane
/// that really scrolls is wider than any gutter.
const min_region_cols: usize = 6;

/// A row counts as having moved with a shift (for `rides`) when this many of
/// its cells did. One is enough: a pane holding still changes no glyph, so
/// it testifies to nothing, and near-identical names (`file-07.txt`,
/// `file-08.txt`) change only a digit or two per row.
const moved_row_cells: usize = 1;

/// The tallest screen whose moved rows are tracked for `rides`; taller ones
/// fall back to judging the whole screen.
const max_detect_rows_judged: usize = 512;

/// A scroll starting this close to the left edge takes the edge with it: the
/// strip is a line-number gutter. See `detectShift`.
const gutter_cols: usize = 5;

fn isVerticalRule(key: u64) bool {
    const g = glyphOf(key);
    return g == 0x2502 or g == 0x2503 or g == 0x2551 or g == '|' or
        (g >= 0x2500 and g <= 0x257F and (g == 0x251C or g == 0x2524 or g == 0x253C));
}

/// A pane border that appears or disappears is a LAYOUT change, not a scroll.
/// tmux's zoom (`C-a z`) out of one of eight Claude Code panes redrew the
/// whole row of panes, and each pane's text, shifted by the new geometry,
/// matched itself a few rows off: every pane in that row slid. A column that
/// is a vertical rule on at least half the rows in one frame and on under a
/// tenth in the other is a border coming or going. A table's `│` scrolling
/// in by a row moves that count by one, never across both thresholds.
pub fn layoutChanged(cur: []const u64, prev: []const u64, rows: usize, cols: usize) bool {
    if (rows < 4) return false;
    for (0..cols) |c| {
        var a: usize = 0;
        var b: usize = 0;
        for (0..rows) |i| {
            if (isVerticalRule(cur[i * cols + c])) a += 1;
            if (isVerticalRule(prev[i * cols + c])) b += 1;
        }
        const hi = rows / 2;
        const lo = rows / 10;
        if ((a >= hi and b <= lo) or (b >= hi and a <= lo)) return true;
    }
    return false;
}

/// The widest grid `detectShift` classifies with dividers; wider falls back
/// to splitting at every contradiction, as before.
const max_detect_cols: usize = 1024;

/// A column unchanged and non-blank on this share of rows divides panes.
const divider_ratio: f32 = 0.6;

fn columnVerdict(
    comptime V: type,
    cur: []const u64,
    prev: []const u64,
    rows: usize,
    cols: usize,
    c: usize,
    shift: isize,
    min_rows: usize,
    min_ratio: f32,
) V {
    const n: isize = @intCast(rows);
    var changed: usize = 0;
    var moved: usize = 0;
    for (0..rows) |i| {
        const row = i * cols;
        if (!testifies(cur[row + c], prev[row + c])) continue;
        changed += 1;
        const j = @as(isize, @intCast(i)) + shift;
        if (j < 0 or j >= n) continue;
        if (cur[row + c] == prev[@as(usize, @intCast(j)) * cols + c]) moved += 1;
    }
    if (changed == 0) return .neutral;
    const agrees = @as(f32, @floatFromInt(moved)) >= min_ratio * @as(f32, @floatFromInt(changed));
    if (agrees and moved > 0) return if (moved >= min_rows) .strong else .weak;
    return if (changed >= min_rows) .contradict else .neutral;
}

/// Whether a cell can be evidence about a scroll: its text changed, to some
/// text. See `detectShift`.
fn testifies(cur: u64, prev: u64) bool {
    const g = glyphOf(cur);
    return g != blank_glyph and g != placeholder_glyph and g != glyphOf(prev);
}

/// Kitty's unicode image placeholder. Its row is an index into an image, so
/// two different pictures line up at any offset -- yazi's previews of two
/// folders matched eight rows apart and slid as a scroll (`shift=-8`). It
/// never decides WHETHER something scrolled. But once a shift is found, a
/// row of an image that moved with it is a row that moved: leaving image
/// rows out of the row range snapped a figure while the text above it slid
/// (nvim, `j` above a half-visible figure: `rows=1..44` of 52).
pub const placeholder_glyph: u32 = 0x10EEEE;

fn movedWith(cur: u64, prev: u64, src: u64) bool {
    const g = glyphOf(cur);
    if (g == placeholder_glyph) return cur != prev and cur == src;
    return testifies(cur, prev) and cur == src;
}

/// Find the whole-row shift that best maps `cur` onto `prev`, or null.
///
/// `cur` and `prev` are `rows * cols` hashes in row-major order -- one per
/// cell, so a scroll confined to some columns can be told apart from one that
/// moves the whole screen.
///
/// `cur[i][c] == prev[i + shift][c]` means the cell at row i now holds what row
/// i+shift held, which is content moving *up* by `shift` -- the same sense as
/// `ScrollEvent.rows`, so a caller needs no negation.
///
/// Only cells that actually **changed** are counted, in the numerator and the
/// denominator both. A blank or static cell matches at every offset at once,
/// so counting those lets a mostly-still screen "confirm" any shift at all.
///
/// And "changed" means the **glyph** changed, to something that is not blank
/// (see `cellKey`). Two kinds of change carry no information about where
/// anything went, and both were measured producing scrolls that never
/// happened:
///
///   - A cell that became blank, or a blank that changed colour. A blank
///     equals every other blank in its colour, so it "confirms" whichever
///     shift lines the blanks up. yazi replacing a ten-entry preview listing
///     with a five-entry one read as `shift=5` across the padding at the end
///     of every line, while the names themselves disagreed.
///   - A cell restyled in place. A selection bar or cursor line moving over
///     text that stays put restyles two rows, and where neighbouring rows
///     share text -- `csapp-md-backup2` under `csapp-md-backup` -- the
///     restyled row equals the row above it in its new colour.
///
/// A cell that *does* testify still has to match in full, glyph and style.
/// The furthest shift `detectShiftUpTo` looks for when checking what a frame
/// with a scroll event really did (see generic.zig "an event that
/// undersells"). A plain repaint is still held to `max_animated_rows`.
pub const max_detect_rows: isize = 24;

/// And for a repaint the wheel caused: a flick of several notches in Claude
/// Code (16 rows a notch here) is most of a screen in one frame.
pub const max_wheel_rows: isize = 48;

pub fn detectShift(
    cur: []const u64,
    prev: []const u64,
    rows: usize,
    cols: usize,
    min_rows: usize,
    min_ratio: f32,
) ?Shift {
    return detectShiftUpTo(cur, prev, rows, cols, min_rows, min_ratio, max_animated_rows);
}

pub fn detectShiftUpTo(
    cur: []const u64,
    prev: []const u64,
    rows: usize,
    cols: usize,
    min_rows: usize,
    min_ratio: f32,
    max_rows: isize,
) ?Shift {
    return detectShiftDir(cur, prev, rows, cols, min_rows, min_ratio, max_rows, 0);
}

/// `dir` restricts the search to one direction: +1 only shifts > 0 (content
/// moving up), -1 only shifts < 0, 0 both. The caller knows the direction
/// when the wheel caused the repaint; a transcript of bullets and blank lines
/// can match better the other way, and animating that slid the text
/// backwards before it landed.
pub fn detectShiftDir(
    cur: []const u64,
    prev: []const u64,
    rows: usize,
    cols: usize,
    min_rows: usize,
    min_ratio: f32,
    max_rows: isize,
    dir: i8,
) ?Shift {
    if (rows == 0 or cols == 0) return null;
    if (cur.len != rows * cols or prev.len != cur.len) return null;
    const n: isize = @intCast(rows);

    if (layoutChanged(cur, prev, rows, cols)) return null;

    // The shift explaining the most changed cells.
    var best_shift: isize = 0;
    var best_score: usize = 0;
    var s: isize = -max_rows;
    while (s <= max_rows) : (s += 1) {
        if (s == 0) continue;
        if ((dir > 0 and s < 0) or (dir < 0 and s > 0)) continue;
        var score: usize = 0;
        for (0..rows) |i| {
            const j = @as(isize, @intCast(i)) + s;
            if (j < 0 or j >= n) continue;
            const row = i * cols;
            const src = @as(usize, @intCast(j)) * cols;
            for (0..cols) |c| {
                if (!testifies(cur[row + c], prev[row + c])) continue;
                if (cur[row + c] == prev[src + c]) score += 1;
            }
        }
        if (score > best_score) {
            best_score = score;
            best_shift = s;
        }
    }
    if (best_shift == 0 or best_score == 0) return null;

    // Which columns that shift actually explains. A column of a stationary
    // pane changes little and matches the shift not at all, so it drops out
    // here rather than being dragged along.
    //
    // The classification is FOUR-WAY, and every one of the distinctions was
    // paid for by a seam on screen. A column can confirm the shift *well*, it
    // can confirm it on the little evidence it has, it can positively
    // disagree, or it can carry no evidence whatsoever -- and those last two
    // are not the same thing, nor are the first two.
    //
    // What separates "no evidence" from "a little evidence" is whether the
    // column CHANGED AT ALL, and that is the whole trick:
    //
    //   - A column with nothing changed says nothing about this frame, and
    //     must not extend the region. This is yazi's file list beside a
    //     scrolling preview, or a tmux pane holding still: displacing it
    //     would slide a pane whose content never moved and spring it back.
    //
    //   - A column where everything that changed moved with the shift belongs
    //     to the scroll, however few cells that was. This is the ragged right
    //     end of wrapped prose, and the first columns of a list whose rows are
    //     mostly indented past them. Requiring `min_rows` changed cells before
    //     a column could confirm excluded exactly these, so a line's head was
    //     displaced while its tail was not: the Claude Code session list drew
    //     "Laptop crash recovery and disp" on one row and "lay resolution" on
    //     the row above it. Reported as tearing, and it was, drawn by us.
    //
    // So `min_rows` still gates DISAGREEMENT -- breaking a run is a strong
    // claim and needs evidence -- but it no longer gates agreement. A run's
    // score is still its count of well-attested columns, so a thinly-attested
    // edge can widen a region but never invent one.
    //
    // And a thin edge can only widen a region it TOUCHES. Weak columns gather
    // into clusters with the columns directly beside them
    // (`weak_bridge_cols`), and only a cluster holding at least one strong
    // column may set a bound. The weak columns that sat further out were
    // coincidences -- one hex digit of a BuildID in yazi's preview, 26
    // columns away across a pane border, slid the preview's left half with
    // the file list -- or the selection's own glyphs: yazi's rounded cap and
    // open-folder icon follow the cursor one blank column from the relative
    // numbers, and slid the left end of the selection bar with them. On the
    // captured prose, nvim and yazi scrolls, allowing no gap at all changed
    // no region: the gaps inside real text are between STRONG columns, and
    // strong columns still bridge any gap, so a gutter between two blocks of
    // scrolling text does not split them.
    const Verdict = enum { strong, weak, contradict, neutral };
    var left: ?usize = null;
    var right: usize = 0;
    var best_strong: usize = 0;
    var best_is_current = false;
    // The segment since the last contradiction: its strong-column count, and
    // the extent of its clusters that hold strong evidence.
    var seg_strong: usize = 0;
    var seg_first: ?usize = null;
    var seg_last: usize = 0;
    // The cluster being built.
    var cl_first: ?usize = null;
    var cl_last: usize = 0;
    var cl_strong: usize = 0;
    // Pass 1: every column's verdict, and which columns are DIVIDERS --
    // unchanged and non-blank down most of the screen: tmux's `│`, yazi's
    // borders, an nvim split's separator, or a whole pane holding still.
    var verdicts: [max_detect_cols]Verdict = undefined;
    var divider: [max_detect_cols]bool = undefined;
    // Columns that look the same whichever way you read them: unchanged, and
    // ALSO what the shift would have put there -- the same glyph down every
    // row. yazi draws one icon per row, and a folder of files of one type
    // (all `.md`, all folders) is a column of identical icons. That column
    // counted as a divider (unchanged, non-blank), so the scroll stopped at
    // it and the icons stood still while their names slid past them. A pane
    // border is the same shape, so it stays a divider only if it is DRAWN as
    // one (`isVerticalRule`); anything else rides with the scroll it sits in.
    var rides: [max_detect_cols]bool = undefined;
    // Still columns DRAWN as a border (`isVerticalRule`), as opposed to text
    // that merely held still -- see the gutter rule below.
    var ruled: [max_detect_cols]bool = undefined;
    const judged = cols <= max_detect_cols;
    // Whether a column rides is judged on the rows that MOVED only. Counted
    // down the whole screen, the rows around a list that does not fill it --
    // yazi's header and status bar, a tmux popup's border, and the pane
    // behind the popup -- are still cells that match no shift, and they sank
    // an icon column under the 0.8 below: in a `<p> e` popup (35 rows, list
    // 22) the folder icons and the `folder-` prefix every name shared read
    // 19 of 27 (0.70), counted as dividers, and the scroll began at the first
    // digit -- names slid while their icons stood still (2026-11-04). Bare
    // yazi passed only just, so it failed now and then. A row moved when at
    // least `moved_row_cells` of its cells moved with the shift.
    var moved: [max_detect_rows_judged]bool = undefined;
    var n_moved: usize = 0;
    const rows_judged = rows <= max_detect_rows_judged;
    if (judged and rows_judged) for (0..rows) |i_| {
        moved[i_] = false;
        const j_ = @as(isize, @intCast(i_)) + best_shift;
        if (j_ < 0 or j_ >= n) continue;
        const src = @as(usize, @intCast(j_)) * cols;
        var hits: usize = 0;
        for (0..cols) |c| {
            if (movedWith(cur[i_ * cols + c], prev[i_ * cols + c], prev[src + c])) hits += 1;
        }
        moved[i_] = hits >= moved_row_cells;
        if (moved[i_]) n_moved += 1;
    };
    if (judged) for (0..cols) |c| {
        verdicts[c] = columnVerdict(Verdict, cur, prev, rows, cols, c, best_shift, min_rows, min_ratio);
        var still: usize = 0;
        var same: usize = 0;
        var rules: usize = 0;
        var still_m: usize = 0;
        var same_m: usize = 0;
        var rules_m: usize = 0;
        for (0..rows) |i_| {
            const k = cur[i_ * cols + c];
            if (k == prev[i_ * cols + c] and glyphOf(k) != blank_glyph) {
                const in_moved = rows_judged and moved[i_];
                still += 1;
                if (in_moved) still_m += 1;
                if (isVerticalRule(k)) {
                    rules += 1;
                    if (in_moved) rules_m += 1;
                }
                const j_ = @as(isize, @intCast(i_)) + best_shift;
                if (j_ >= 0 and j_ < n and prev[@as(usize, @intCast(j_)) * cols + c] == k) {
                    same += 1;
                    if (in_moved) same_m += 1;
                }
            }
        }
        const is_still = @as(f32, @floatFromInt(still)) >= divider_ratio * @as(f32, @floatFromInt(rows));
        // On the moved rows: still down most of them, not drawn as a border,
        // and what the shift would have put there.
        const rides_moved = n_moved >= min_rows and
            @as(f32, @floatFromInt(still_m)) >= divider_ratio * @as(f32, @floatFromInt(n_moved)) and
            rules_m * 2 < still_m and
            @as(f32, @floatFromInt(same_m)) >= 0.8 * @as(f32, @floatFromInt(still_m));
        rides[c] = rides_moved or (is_still and rules * 2 < still and
            @as(f32, @floatFromInt(same)) >= 0.8 * @as(f32, @floatFromInt(still)));
        divider[c] = is_still and !rides[c];
        ruled[c] = is_still and rules * 2 >= still;
    };
    // Pass 2: a contradiction only splits the region across a DIVIDER. Within
    // one pane, columns that disagree with the shift are its own text having
    // changed as well as moved -- a paragraph re-wrapping as render-markdown
    // conceals a formula, which is the TEAR at CSAPP 2's line 1273: measured
    // `cols=0..145` (and 0..196, 5..170) while the prose was one window wide,
    // so the left of every row slid and the right did not. A pane that mostly
    // disagrees stays a genuinely separate region.
    if (judged) {
        var a: usize = 0;
        while (a < cols) {
            var b = a;
            while (b < cols and !divider[b]) b += 1;
            var strong: usize = 0;
            var against: usize = 0;
            for (a..b) |c| switch (verdicts[c]) {
                .strong => strong += 1,
                .contradict => against += 1,
                else => {},
            };
            if (against <= strong) for (a..b) |c| {
                // Weak: part of the scroll where it touches it, never a bound on its own.
                if (verdicts[c] == .contradict) verdicts[c] = .weak;
            };
            a = b + 1;
        }
    }
    for (0..cols) |c| {
        const verdict: Verdict = if (judged) verdicts[c] else columnVerdict(Verdict, cur, prev, rows, cols, c, best_shift, min_rows, min_ratio);
        switch (verdict) {
            // A genuinely independent region: a tmux split, or yazi's file
            // list when its selection moves against the preview's scroll.
            // Everything after this belongs to a different run.
            .contradict => {
                seg_strong = 0;
                seg_first = null;
                cl_first = null;
                best_is_current = false;
            },
            // Bridges, so a gutter or a run of aligned spaces cannot split
            // one scroll into two regions, but never sets a bound.
            .neutral => {},
            .strong, .weak => {
                const joins = if (cl_first) |f| joins: {
                    const gap = c - cl_last - 1;
                    if (gap <= weak_bridge_cols) break :joins true;
                    // Thin evidence at the left edge, reaching inwards.
                    break :joins f == 0 and cl_strong == 0 and gap <= edge_bridge_cols;
                } else false;
                if (!joins) {
                    cl_first = c;
                    cl_strong = 0;
                }
                cl_last = c;
                if (verdict == .strong) {
                    cl_strong += 1;
                    seg_strong += 1;
                }
                if (cl_strong > 0) {
                    if (seg_first == null) seg_first = cl_first;
                    seg_last = cl_last;
                }
                if (seg_strong > best_strong) {
                    best_strong = seg_strong;
                    best_is_current = true;
                }
                if (best_is_current) {
                    if (seg_first) |f| {
                        left = f;
                        right = seg_last;
                    }
                }
            },
        }
    }
    var l = left orelse return null;

    // The width test belongs HERE, on the run's own evidence, before thin
    // evidence elsewhere in the pane widens it. yazi in a folder too short to
    // scroll: `j` relabels the relative numbers (a 2-column strip that really
    // does read as a row shift), and the two rows the cursor left and entered
    // change too -- scraps of which agree with any shift. Pane-wide inclusion
    // grew the strip to the whole pane (`cols=28..103`), and every `j` slid
    // the list a row and back: the list "shook" on each press.
    if (right - l + 1 < @min(min_region_cols, cols)) return null;

    // Within the pane that holds the run -- the columns between the dividers
    // around it -- thin evidence anywhere belongs to the same scroll. The
    // ragged right ends of long lines are weak columns, and a column with
    // nothing changed between them and the text cut them off: in Claude Code
    // `cols=0..132` (also 0..95, 0..158) while lines ran on to column 200,
    // so their tails stood still while their heads slid -- a tear. What the
    // touching rule guards against, a coincidence across a pane border, has
    // a divider in between and stays out.
    if (judged) {
        var pa = l;
        while (pa > 0 and !divider[pa - 1]) pa -= 1;
        var pb = right;
        while (pb + 1 < cols and !divider[pb + 1]) pb += 1;
        for (pa..pb + 1) |c| switch (verdicts[c]) {
            .strong, .weak => {
                if (c < l) l = c;
                if (c > right) right = c;
            },
            else => {},
        };
        // And the pane's blank columns with it, out to its dividers. A
        // column with no text says nothing either way, but its BACKGROUND
        // moves with the rows: Claude Code's green diff runs to column 200
        // while its text stops at 130, and the scroll stopped with the text
        // -- the green right-hand block stood still while the left slid, a
        // tear through every coloured row (2026-09-29, round 6).
        if (pa < l) l = pa;
        if (pb > right) right = pb;
        // A run that starts within `gutter_cols` of the screen's left edge,
        // with no divider before it, starts AT the edge. That strip is a
        // line-number gutter: nvim's relative numbers are relabelled on
        // every step, so what they testify changes from frame to frame, and
        // the detected left edge wandered between columns 0, 2 and 5 on
        // consecutive `j` presses (CSAPP ch. 2, 2800-2820). A real scroll
        // event always moves the full width, gutter included, so on the
        // steps that arrived as repaints the numbers held still and on the
        // rest they slid: the gutter hopped. Now both kinds move it.
        //
        // Only a DRAWN border stops it. Relative numbers mostly keep their
        // value on each screen row, so the gutter itself reads as a still,
        // non-blank column -- a divider -- on frames where few lines wrap,
        // and not on frames where many do. That is the wandering edge.
        if (l <= gutter_cols) {
            var clear = true;
            for (0..l) |c| if (ruled[c]) {
                clear = false;
            };
            if (clear) l = 0;
        }
        // A column that rides (see `rides`) goes with the scroll it touches,
        // across up to `edge_bridge_cols` quiet columns (yazi puts a space
        // between the icon and the name). Only a region wide enough on its
        // own evidence (`min_region_cols`): names sharing a long prefix are
        // riding columns too, and must not widen a relabelled gutter into a
        // "scroll" (see "a selection bar moving is not the list scrolling").
        if (right - l + 1 < @min(min_region_cols, cols)) return null;
        outer: while (true) {
            var g: usize = 1;
            while (g <= edge_bridge_cols + 1 and l >= g) : (g += 1) {
                const c = l - g;
                if (rides[c]) {
                    l = c;
                    continue :outer;
                }
                if (verdicts[c] != .neutral or divider[c]) break;
            }
            break;
        }
        outer: while (true) {
            var g: usize = 1;
            while (g <= edge_bridge_cols + 1 and right + g < cols) : (g += 1) {
                const c = right + g;
                if (rides[c]) {
                    right = c;
                    continue :outer;
                }
                if (verdicts[c] != .neutral or divider[c]) break;
            }
            break;
        }
    }

    // The rows that MOVED, within those columns only -- not every row that
    // changed there. yazi's status bar changes on every key (it names the
    // hovered file), and taking every changed row stretched the region down
    // to it, swallowing the pane's bottom border on the way: the border's
    // `─` slid with the relative numbers above it.
    //
    // The rows entering on the side the content arrives from are the one
    // exception. They are newly exposed and match nothing, but they travel
    // with the block, and leaving them out would snap the newest line into
    // place while everything above it slides. So the moved span is extended
    // by up to `|shift|` rows on that side, as long as those rows changed.
    const moved_row = struct {
        fn f(cu: []const u64, pr: []const u64, i: usize, s_: isize, n_: isize, cols_: usize, l_: usize, r_: usize) bool {
            const j = @as(isize, @intCast(i)) + s_;
            if (j < 0 or j >= n_) return false;
            const row = i * cols_;
            const src = @as(usize, @intCast(j)) * cols_;
            for (l_..r_ + 1) |c| {
                if (movedWith(cu[row + c], pr[row + c], pr[src + c])) return true;
            }
            return false;
        }
    }.f;
    const changed_row = struct {
        fn f(cu: []const u64, pr: []const u64, i: usize, cols_: usize, l_: usize, r_: usize) bool {
            const row = i * cols_;
            for (l_..r_ + 1) |c| if (cu[row + c] != pr[row + c]) return true;
            return false;
        }
    }.f;
    var top: ?usize = null;
    var bottom: usize = 0;
    for (0..rows) |i| {
        if (!moved_row(cur, prev, i, best_shift, n, cols, l, right)) continue;
        if (top == null) top = i;
        bottom = i;
    }
    var t = top orelse return null;
    var k: usize = 0;
    while (k < @abs(best_shift)) : (k += 1) {
        if (best_shift > 0) {
            if (bottom + 1 >= rows or !changed_row(cur, prev, bottom + 1, cols, l, right)) break;
            bottom += 1;
        } else {
            if (t == 0 or !changed_row(cur, prev, t - 1, cols, l, right)) break;
            t -= 1;
        }
    }
    if (bottom - t + 1 < min_rows) return null;
    if (right - l + 1 < @min(min_region_cols, cols)) return null;

    return .{ .rows = best_shift, .top = t, .bottom = bottom, .left = l, .right = right };
}

/// A run of this many unmoved, non-blank cells on a region's edge row pins
/// that row. See `trimPinnedRows`.
pub const pinned_min_cells: usize = 8;

/// Shrink a detected region past edge rows holding something PINNED to the
/// screen: text redrawn in the same place while everything around it moved.
///
/// Claude Code draws "Jump to bottom (ctrl+End) ↓" on the last row of its
/// scrolling area, and a sticky copy of the current prompt on the first, on
/// top of the transcript. Both rows also carry transcript text that did move,
/// so they are rows of the scroll by every other test -- and displacing them
/// slid the label along with the text, while the band behind a lagging
/// offset filled with a fresh copy of it for every row scrolled: four labels
/// stacked up the screen. Left out of the region, the row holds still, which
/// is the label's intent; its bit of transcript arrives unanimated, the same
/// as a status line's would.
///
/// A cell is pinned when it is unchanged in place and does NOT equal what the
/// shift would have brought there. Unmoved blanks match at every offset and
/// neither count nor break a run; anything else that moved or changed does
/// break it. A run of `pinned_min_cells` non-blank pinned cells pins the row:
/// prose coincides with the line above it a letter at a time, never eight in
/// a row. Only edge rows, and only inward: a label in mid-region is drawn
/// over content that must still slide, which one region cannot express.
pub fn trimPinnedRows(
    cur: []const u64,
    prev: []const u64,
    rows: usize,
    cols: usize,
    shift: isize,
    top: usize,
    bottom: usize,
    left: usize,
    right: usize,
) struct { top: usize, bottom: usize } {
    const pinned = struct {
        fn row(cu: []const u64, pr: []const u64, n: usize, cs: usize, s: isize, i: usize, l: usize, r: usize) bool {
            const j = @as(isize, @intCast(i)) + s;
            const src: ?usize = if (j < 0 or j >= @as(isize, @intCast(n))) null else @intCast(j);
            var run: usize = 0;
            for (l..r + 1) |c| {
                const k = cu[i * cs + c];
                const moved_in: ?u64 = if (src) |sr| pr[sr * cs + c] else null;
                if (k == pr[i * cs + c] and (moved_in == null or moved_in.? != k)) {
                    if (glyphOf(k) != blank_glyph) {
                        run += 1;
                        if (run >= pinned_min_cells) return true;
                    }
                } else if (k == pr[i * cs + c] and glyphOf(k) == blank_glyph) {
                    // an unmoved blank: bridges
                } else run = 0;
            }
            return false;
        }
    }.row;
    if (cur.len != rows * cols or prev.len != cur.len or right >= cols or bottom >= rows)
        return .{ .top = top, .bottom = bottom };
    var t = top;
    var b = bottom;
    while (t < b and pinned(cur, prev, rows, cols, shift, b, left, right)) b -= 1;
    while (t < b and pinned(cur, prev, rows, cols, shift, t, left, right)) t += 1;
    return .{ .top = t, .bottom = b };
}

test "Easing: every curve starts at 0 and ends at 1" {
    // A curve that does not reach 1 leaves the animation permanently short of
    // the model, which pins the text off the character grid.
    for (std.enums.values(Easing)) |e| {
        try testing.expectApproxEqAbs(@as(f32, 0), easeOut(0, e), 0.002);
        try testing.expectApproxEqAbs(@as(f32, 1), easeOut(1, e), 0.002);
    }
}

test "Easing: every curve advances monotonically" {
    // Any dip backwards is content visibly moving against the scroll.
    for (std.enums.values(Easing)) |e| {
        var prev: f32 = -1;
        var i: usize = 0;
        while (i <= 100) : (i += 1) {
            const v = easeOut(@as(f32, @floatFromInt(i)) / 100.0, e);
            try testing.expect(v >= prev - 0.001);
            prev = v;
        }
    }
}

test "Easing: the eased curves lead a linear ramp at the halfway point" {
    // The property that makes them read as motion rather than a slide: most
    // of the travel is done early. `material` is deliberately exempt -- it
    // eases in as well, which is the whole point of offering it.
    for ([_]Easing{ .ease_out_cubic, .ease_out_quint, .ease_out_quad }) |e| {
        try testing.expect(easeOut(0.5, e) > 0.5);
    }
}

test "Easing: bezier matches its closed form on a known curve" {
    // cubic-bezier(0.25, 0.25, 0.75, 0.75) is the identity; if the solver is
    // wrong this is where it shows.
    var i: usize = 0;
    while (i <= 10) : (i += 1) {
        const x = @as(f32, @floatFromInt(i)) / 10.0;
        try testing.expectApproxEqAbs(x, bezier(0.25, 0.25, 0.75, 0.75, x), 0.002);
    }
}

test "detectShift: finds a clean shift and gets its sign right" {
    // prev rows 0..19; cur is prev scrolled up by 3, so cur[i] == prev[i+3].
    var prev: [20]u64 = undefined;
    for (&prev, 0..) |*v, i| v.* = 1000 + i;
    var cur: [20]u64 = undefined;
    for (&cur, 0..) |*v, i| v.* = 1000 + i + 3;
    try testing.expectEqual(@as(isize, 3), detectShift(&cur, &prev, cur.len, 1, 6, 0.6).?.rows);
}

test "detectShift: reports the other direction as negative" {
    var prev: [20]u64 = undefined;
    for (&prev, 0..) |*v, i| v.* = 1000 + i;
    var cur: [20]u64 = undefined;
    for (&cur, 0..) |*v, i| v.* = 1000 + i - 2;
    try testing.expectEqual(@as(isize, -2), detectShift(&cur, &prev, cur.len, 1, 6, 0.6).?.rows);
}

test "detectShift: interface rows held at top and bottom are excluded" {
    // The bug this guards, reported by eye: nvim's tab line and status line
    // rode along with the scroll and sprang back, because the whole grid was
    // animated. They keep their content across the frame, so they match
    // themselves and not the shifted picture -- which is exactly the signal
    // that they are not part of the scroll.
    var prev: [20]u64 = undefined;
    var cur: [20]u64 = undefined;
    for (0..20) |i| {
        prev[i] = 1000 + i;
        cur[i] = 1000 + i + 3;
    }
    // Row 0 a tab line, rows 18-19 a status line and command line: unchanged.
    for ([_]usize{ 0, 18, 19 }) |i| {
        prev[i] = 500 + i;
        cur[i] = 500 + i;
    }

    const got = detectShift(&cur, &prev, cur.len, 1, 6, 0.6).?;
    try testing.expectEqual(@as(isize, 3), got.rows);
    try testing.expectEqual(@as(usize, 1), got.top);
    try testing.expectEqual(@as(usize, 17), got.bottom);
}

test "detectShift: a pane scrolling does not drag the panes beside it" {
    // Reported by eye in yazi: the right pane previews a scrollable nvim
    // buffer, and scrolling it slid the file lists in the left and middle
    // panes too, which then snapped back. The row-only detector found the
    // shift and animated those rows across the *full width*.
    //
    // Columns 0..39 are the two file lists, 40..79 the preview. Rows 0 and 23
    // are chrome. Only the preview scrolls.
    const rows = 24;
    const cols = 80;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    for (0..rows) |i| {
        for (0..cols) |c| {
            const k = i * cols + c;
            if (i == 0 or i == rows - 1) { // chrome: identical both frames
                prev[k] = 7_000_000 + k;
                cur[k] = 7_000_000 + k;
            } else if (c < 40) { // file lists: unchanged, and unique per row
                prev[k] = 1_000_000 + k;
                cur[k] = 1_000_000 + k;
            } else { // preview: scrolled up by 3
                prev[k] = 2_000_000 + (i * cols) + c;
                cur[k] = 2_000_000 + ((i + 3) * cols) + c;
            }
        }
    }

    const got = detectShift(&cur, &prev, rows, cols, 6, 0.6).?;
    try testing.expectEqual(@as(isize, 3), got.rows);
    // The preview only. Anything reaching column 39 would move a file list.
    try testing.expectEqual(@as(usize, 40), got.left);
    try testing.expectEqual(@as(usize, cols - 1), got.right);
}

test "detectShift: a full-width scroll still reports the whole width" {
    // The other half of the pane case: an ordinary scroll must not be narrowed.
    const rows = 24;
    const cols = 80;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    for (0..rows) |i| {
        for (0..cols) |c| {
            const k = i * cols + c;
            prev[k] = 3_000_000 + (i * cols) + c;
            cur[k] = 3_000_000 + ((i + 2) * cols) + c;
        }
    }
    const got = detectShift(&cur, &prev, rows, cols, 6, 0.6).?;
    try testing.expectEqual(@as(isize, 2), got.rows);
    try testing.expectEqual(@as(usize, 0), got.left);
    try testing.expectEqual(@as(usize, cols - 1), got.right);
}

test "detectShift: a sparse column does not split the region in two" {
    // The screen tearing this guards, seen scrolling a CSAPP chapter in nvim.
    //
    // Columns 38..41 are a gutter that only changes on every eighth row --
    // three changed cells over the whole height, which is under `min_rows` and
    // so cannot confirm the shift. When "cannot confirm" ended the run, the
    // region stopped at column 37: the left of the screen animated, the right
    // stood still, and the seam between them looked like display tearing.
    // Nothing about this frame is a split; it is one scroll all the way across.
    const rows = 24;
    const cols = 80;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    for (0..rows) |i| {
        for (0..cols) |c| {
            const k = i * cols + c;
            if (c >= 38 and c <= 41 and i % 8 != 0) {
                prev[k] = 5_000_000 + c;
                cur[k] = 5_000_000 + c;
            } else {
                prev[k] = 4_000_000 + (i * cols) + c;
                cur[k] = 4_000_000 + ((i + 2) * cols) + c;
            }
        }
    }
    const got = detectShift(&cur, &prev, rows, cols, 6, 0.6).?;
    try testing.expectEqual(@as(isize, 2), got.rows);
    try testing.expectEqual(@as(usize, 0), got.left);
    try testing.expectEqual(@as(usize, cols - 1), got.right);
}

test "detectShift: a thinly-attested edge column still belongs to the scroll" {
    // The seam this guards, photographed in Claude Code's session list: a
    // line's head displaced by the animation while its tail was not, so the
    // screen read "Laptop crash recovery and disp" with "lay resolution"
    // sitting on the row above it. The same at the left margin, where
    // "Resume session" broke into "Re" and "sume session" a row apart.
    //
    // Columns 0..1 are the left margin and 60..79 the ragged right ends of
    // wrapped lines: content on two rows out of 24, both moving with the
    // shift. Four changed cells is under `min_rows`, so requiring `min_rows`
    // agreements before a column could confirm left them outside the region
    // even though they are plainly part of the scroll.
    //
    // Contrast the yazi test above, where the stationary pane's columns are
    // *unchanged*. That is the distinction: nothing changed says nothing,
    // while a little that all agrees is still agreement.
    const rows = 24;
    const cols = 80;
    // Non-blank only on these source rows, so a sparse column has four
    // changed cells across the frame: two arriving, two leaving.
    const sparse_content = struct {
        fn at(k: usize) bool {
            return k == 4 or k == 20;
        }
    };
    const blank: u64 = 999;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    for (0..rows) |i| {
        for (0..cols) |c| {
            const k = i * cols + c;
            const sparse = c < 2 or c >= 60;
            if (!sparse) { // body text: every row changes and moves
                prev[k] = 6_000_000 + (i * cols) + c;
                cur[k] = 6_000_000 + ((i + 2) * cols) + c;
                continue;
            }
            prev[k] = if (sparse_content.at(i)) 6_000_000 + (i * cols) + c else blank;
            cur[k] = if (sparse_content.at(i + 2)) 6_000_000 + ((i + 2) * cols) + c else blank;
        }
    }

    const got = detectShift(&cur, &prev, rows, cols, 6, 0.6).?;
    try testing.expectEqual(@as(isize, 2), got.rows);
    try testing.expectEqual(@as(usize, 0), got.left);
    try testing.expectEqual(@as(usize, cols - 1), got.right);
}

test "detectShift: blank padding cannot testify to a shift" {
    // yazi's preview pane, measured: moving the selection from a directory
    // with ten entries to one with five replaced the listing, and the detector
    // reported `shift=5 cols=65..101` -- the right half of a 51-column pane.
    // That is the torn line: each preview row's tail displaced by five rows
    // and easing back, its head standing still.
    //
    // Every cell that "agreed" was a blank. yazi pads each entry to the pane
    // edge in the entry's colour, so a directory's padding five rows down
    // equals a directory's padding here, and a plain blank equals every other
    // plain blank. The text itself -- the only part that could say where
    // anything went -- disagreed with the shift outright.
    //
    // A blank cannot say where it came from. It must not vote.
    const rows = 24;
    const cols = 40;
    const plain = cellKey(blank_glyph, 0);
    const file_pad = cellKey(blank_glyph, 11); // padding in a file's colour
    const dir_pad = cellKey(blank_glyph, 22); // and in a directory's
    var prev: [rows * cols]u64 = @splat(plain);
    var cur: [rows * cols]u64 = @splat(plain);
    for (2..12) |i| {
        for (0..cols) |c| {
            prev[i * cols + c] = if (c < 10)
                cellKey(@intCast(1000 + i * cols + c), 7) // this listing's names
            else if (i < 7) file_pad else dir_pad;
        }
    }
    for (2..7) |i| {
        for (0..cols) |c| {
            cur[i * cols + c] = if (c < 10)
                cellKey(@intCast(90_000 + i * cols + c), 7) // a different listing
            else
                dir_pad;
        }
    }
    try testing.expect(detectShift(&cur, &prev, rows, cols, 6, 0.6) == null);
}

test "detectShift: a lone coincidence across a pane border cannot widen the region" {
    // yazi's file list genuinely scrolling one row, with the preview beside it
    // showing `file(1)` output for each binary. Consecutive binaries describe
    // themselves almost identically, so the preview barely changes -- except a
    // BuildID hash, one of whose hex digits happened to equal the digit a row
    // below it. Measured: `cols=20..76` where the list is 20..49.
    //
    // One agreeing cell made that column "weak", and the rule that lets a
    // weak column widen a run (a ragged line end, a left margin) let it do so
    // across 26 columns of border and unchanged preview. The preview's left
    // half then slid with the list and its right half did not.
    //
    // Measured on real prose, a weak column is never more than one neutral
    // column from the text it continues -- a word gap. Across a pane border it
    // is always a coincidence.
    const rows = 24;
    const cols = 60;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    for (0..rows) |i| {
        for (0..cols) |c| {
            const k = i * cols + c;
            if (c < 30) { // the list: every row moves up one
                prev[k] = 7_000_000 + i * cols + c;
                cur[k] = 7_000_000 + (i + 1) * cols + c;
            } else if (c == 31) { // the border
                prev[k] = cellKey(0x2502, 5);
                cur[k] = cellKey(0x2502, 5);
            } else if (c < 33) { // padding
                prev[k] = cellKey(blank_glyph, 0);
                cur[k] = cellKey(blank_glyph, 0);
            } else { // the preview: identical from one binary to the next
                prev[k] = 8_000_000 + i * cols + c;
                cur[k] = prev[k];
            }
        }
    }
    // ...but for one digit of a hash, which equals the one below it.
    cur[6 * cols + 56] = prev[7 * cols + 56];

    const got = detectShift(&cur, &prev, rows, cols, 6, 0.6).?;
    try testing.expectEqual(@as(isize, 1), got.rows);
    try testing.expectEqual(@as(usize, 0), got.left);
    // The list and its blank padding (col 30), never past the border.
    try testing.expectEqual(@as(usize, 30), got.right);
}

test "detectShift: a selection bar moving is not the list scrolling" {
    // yazi's middle column, `j` with nothing scrolling: the relative line
    // numbers in the gutter really do shift a row, and that anchored a run.
    // The bar then moved from `csapp-md-backup2` to `csapp-md-backup3` -- the
    // same text restyled in place, whose shared prefix equals the row above
    // in the bar's new colour. Measured `cols=15..34`: the gutter and the
    // first twenty columns of every name slid a row, the rest of each name
    // did not.
    //
    // A cell whose glyph is unchanged has not moved, whatever colour it is
    // now. Restyling is an overlay moving over text that stayed put.
    const rows = 24;
    const cols = 40;
    const bar: u32 = 99;
    const sel_old = 9;
    const sel_new = 10;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    for (0..rows) |i| {
        for (0..cols) |c| {
            const k = i * cols + c;
            if (c < 2) {
                // Relative numbers: |i - cursor|, which shifts with the cursor.
                const d_old: u32 = @intCast(if (i > sel_old) i - sel_old else sel_old - i);
                const d_new: u32 = @intCast(if (i > sel_new) i - sel_new else sel_new - i);
                prev[k] = cellKey(500 + d_old * 2 + @as(u32, @intCast(c)), 0);
                cur[k] = cellKey(500 + d_new * 2 + @as(u32, @intCast(c)), 0);
                continue;
            }
            // Names that share a long prefix with their neighbours: the glyph
            // depends on the column, not the row, until the last few columns.
            const glyph: u32 = if (c < 20) @intCast(3000 + c) else @intCast(4000 + i * cols + c);
            prev[k] = cellKey(glyph, if (i == sel_old) bar else 0);
            cur[k] = cellKey(glyph, if (i == sel_new) bar else 0);
        }
    }
    // Not the names -- and since 2026-09-28 not the gutter either: numbers
    // relabelled under a cursor are not a scroll (`min_region_cols`).
    try testing.expectEqual(@as(?Shift, null), detectShift(&cur, &prev, rows, cols, 6, 0.6));
}

test "detectShift: a status line below the region does not stretch it" {
    // yazi's relative-number gutter sliding a row, with the pane's bottom
    // border and then the status bar beneath it. The status bar shows the
    // hovered file's name, so it changes on every key -- and the row range
    // used to be every row that CHANGED within the region's columns, which
    // reached down to the status bar and swallowed the border in between.
    // The border's `─` then slid with the numbers: the stray line the report
    // describes above and below the gutter.
    //
    // The rows are the ones that MOVED, plus the rows entering on the side
    // the content arrives from, which are new and cannot match anything.
    const rows = 24;
    const cols = 20;
    var prev: [rows * cols]u64 = @splat(cellKey(blank_glyph, 0));
    var cur: [rows * cols]u64 = @splat(cellKey(blank_glyph, 0));
    for (0..cols) |c| {
        prev[0 * cols + c] = cellKey('-', 1); // top border
        cur[0 * cols + c] = cellKey('-', 1);
        prev[21 * cols + c] = cellKey('-', 1); // bottom border
        cur[21 * cols + c] = cellKey('-', 1);
        prev[23 * cols + c] = cellKey(@intCast(700 + c), 2); // status: old name
        cur[23 * cols + c] = cellKey(@intCast(900 + c), 2); // status: new name
    }
    for (1..21) |i| for (0..10) |c| {
        // Distinct per row, moving down one: the list (ten columns wide, so
        // it is a region at all -- see `min_region_cols`).
        prev[i * cols + c] = cellKey(@intCast(100 + i * cols + c), 0);
        cur[i * cols + c] = cellKey(@intCast(100 + (i - 1) * cols + c), 0);
    };
    const got = detectShift(&cur, &prev, rows, cols, 6, 0.6).?;
    try testing.expectEqual(@as(isize, -1), got.rows);
    try testing.expectEqual(@as(usize, 1), got.top);
    try testing.expectEqual(@as(usize, 20), got.bottom);
}

test "detectShift: the selection's own glyphs beside a gutter do not slide with it" {
    // yazi draws the selected row with a rounded cap and an open-folder
    // icon, both of which move with the cursor -- genuinely one row, the same
    // shift as the relative numbers beside them, but a column of blank away.
    // Allowed to bridge that blank, they slid the left end of the selection
    // bar with the numbers ("9  " moving as one). A thinly-attested column
    // must touch the evidence it widens; strong columns still bridge gaps.
    const rows = 24;
    const cols = 12;
    var prev: [rows * cols]u64 = @splat(cellKey(blank_glyph, 0));
    var cur: [rows * cols]u64 = @splat(cellKey(blank_glyph, 0));
    for (0..rows) |i| {
        prev[i * cols + 0] = cellKey(@intCast(100 + i), 0); // gutter digit
        cur[i * cols + 0] = cellKey(@intCast(100 + i - 1 + 0), 0);
        prev[i * cols + 3] = cellKey('d', 0); // closed-folder icon on every row
        cur[i * cols + 3] = cellKey('d', 0);
    }
    // Selection moves from row 9 to row 10: cap in column 2, open icon in 3.
    prev[9 * cols + 2] = cellKey('(', 5);
    cur[10 * cols + 2] = cellKey('(', 5);
    prev[9 * cols + 3] = cellKey('D', 5);
    cur[10 * cols + 3] = cellKey('D', 5);
    // Neither the glyphs nor, since `min_region_cols`, the lone gutter.
    try testing.expectEqual(@as(?Shift, null), detectShift(&cur, &prev, rows, cols, 6, 0.6));
}

/// One window of prose scrolled up a row, whose right third also changed on
/// most rows (re-wrapped), with an optional divider column at 40.
fn rewrapFrames(comptime rows: usize, comptime cols: usize, with_divider: bool, prev: *[rows * cols]u64, cur: *[rows * cols]u64) void {
    for (0..rows) |i| for (0..cols) |c| {
        const k = i * cols + c;
        if (with_divider and c == 40) {
            prev[k] = cellKey('|', 1);
            cur[k] = cellKey('|', 1);
        } else if (c < 40) {
            prev[k] = cellKey(@intCast(10_000 + i * cols + c), 0);
            cur[k] = cellKey(@intCast(10_000 + (i + 1) * cols + c), 0);
        } else {
            prev[k] = cellKey(@intCast(50_000 + i * cols + c), 0);
            cur[k] = cellKey(@intCast(90_000 + i * cols + c), 0); // matches nothing
        }
    };
}

test "detectShift: text re-wrapping inside one pane does not tear it" {
    const rows = 30;
    const cols = 60;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    rewrapFrames(rows, cols, false, &prev, &cur);
    const got = detectShift(&cur, &prev, rows, cols, 6, 0.6).?;
    try testing.expectEqual(@as(isize, 1), got.rows);
    try testing.expectEqual(@as(usize, 0), got.left);
    try testing.expectEqual(@as(usize, cols - 1), got.right);
}

test "detectShift: control -- the same disagreement behind a divider is a separate pane" {
    const rows = 30;
    const cols = 60;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    rewrapFrames(rows, cols, true, &prev, &cur);
    const got = detectShift(&cur, &prev, rows, cols, 6, 0.6).?;
    try testing.expectEqual(@as(usize, 0), got.left);
    try testing.expectEqual(@as(usize, 39), got.right);
}

test "detectShift: long lines' tails past a quiet column still slide" {
    // Text in columns 0..29 on every row; tails in 35..44 on two rows only;
    // column 30..34 never changes. Scrolled up one row.
    const rows = 30;
    const cols = 50;
    var prev: [rows * cols]u64 = @splat(cellKey(blank_glyph, 0));
    var cur: [rows * cols]u64 = @splat(cellKey(blank_glyph, 0));
    for (0..rows + 1) |k| for (0..cols) |c| {
        const body = c < 30;
        const tail = c >= 35 and c < 45 and (k == 7 or k == 19);
        if (!body and !tail) continue;
        const key = cellKey(@intCast(1000 + k * cols + c), 0);
        if (k < rows) prev[k * cols + c] = key;
        if (k >= 1) cur[(k - 1) * cols + c] = key;
    };
    const got = detectShift(&cur, &prev, rows, cols, 6, 0.6).?;
    try testing.expectEqual(@as(usize, 0), got.left);
    // Tails included -- and, since the pane's blank columns move with it
    // (backgrounds), out to the screen edge.
    try testing.expectEqual(@as(usize, cols - 1), got.right);
}

test "detectShift: image rows that moved with the text are in the region" {
    // Text on rows 0..19, an image (placeholder cells, row index in the
    // hash) on rows 20..27; everything scrolled up one row.
    const rows = 28;
    const cols = 30;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    for (0..rows + 1) |k| for (0..cols) |c| {
        const key = if (k >= 20) cellKey(placeholder_glyph, @intCast(k * 64 + c)) else cellKey(@intCast(1000 + k * cols + c), 0);
        if (k < rows) prev[k * cols + c] = key;
        if (k >= 1) cur[(k - 1) * cols + c] = key;
    };
    const got = detectShift(&cur, &prev, rows, cols, 6, 0.6).?;
    try testing.expectEqual(@as(isize, 1), got.rows);
    try testing.expectEqual(@as(usize, rows - 1), got.bottom);
}

test "detectShift: two unrelated images lining up is not a scroll" {
    const rows = 20;
    const cols = 20;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    // The same placeholder cells, eight rows apart: yazi's two previews.
    for (0..rows) |i| for (0..cols) |c| {
        prev[i * cols + c] = cellKey(placeholder_glyph, @intCast(i * 64 + c));
        cur[i * cols + c] = cellKey(placeholder_glyph, @intCast(((i + 8) % 64) * 64 + c));
    };
    try testing.expectEqual(@as(?Shift, null), detectShift(&cur, &prev, rows, cols, 6, 0.6));
}

test "detectShift: bullets at the left edge slide with their text" {
    // Claude Code: a bullet in column 0 on three rows, column 1 always blank,
    // prose from column 2. The bullets moved with the text and stood still.
    const rows = 24;
    const cols = 40;
    var prev: [rows * cols]u64 = @splat(cellKey(blank_glyph, 0));
    var cur: [rows * cols]u64 = @splat(cellKey(blank_glyph, 0));
    for (0..rows + 1) |k| { // content line k is on row k (prev), k-1 (cur)
        for (2..cols) |c| {
            const key = cellKey(@intCast(1000 + k * cols + c), 0);
            if (k < rows) prev[k * cols + c] = key;
            if (k >= 1) cur[(k - 1) * cols + c] = key;
        }
        if (k == 5 or k == 11 or k == 17) {
            if (k < rows) prev[k * cols] = cellKey('*', 7);
            if (k >= 1) cur[(k - 1) * cols] = cellKey('*', 7);
        }
    }
    const got = detectShift(&cur, &prev, rows, cols, 6, 0.6).?;
    try testing.expectEqual(@as(isize, 1), got.rows);
    try testing.expectEqual(@as(usize, 0), got.left);
    try testing.expectEqual(@as(usize, cols - 1), got.right);
}

/// A transcript scrolling up one row under a label pinned to `pin_row`.
fn pinnedFrames(comptime rows: usize, comptime cols: usize, pin_row: ?usize, prev: *[rows * cols]u64, cur: *[rows * cols]u64) void {
    for (0..rows + 1) |k| {
        for (0..cols) |c| {
            const key = cellKey(@intCast(1000 + k * cols + c), 0);
            if (k < rows) prev[k * cols + c] = key;
            if (k >= 1) cur[(k - 1) * cols + c] = key;
        }
    }
    const label = "Jump to bottom";
    if (pin_row) |r| for (label, 0..) |ch, i| {
        const key = if (ch == ' ') cellKey(blank_glyph, 9) else cellKey(ch, 9);
        prev[r * cols + 20 + i] = key;
        cur[r * cols + 20 + i] = key;
    };
}

test "trimPinnedRows: a label held on the bottom row leaves the region" {
    const rows = 20;
    const cols = 60;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    pinnedFrames(rows, cols, 18, &prev, &cur);
    const got = trimPinnedRows(&cur, &prev, rows, cols, 1, 1, 18, 0, cols - 1);
    try testing.expectEqual(@as(usize, 1), got.top);
    try testing.expectEqual(@as(usize, 17), got.bottom);
}

test "trimPinnedRows: a sticky header on the top row leaves the region" {
    const rows = 20;
    const cols = 60;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    pinnedFrames(rows, cols, 1, &prev, &cur);
    const got = trimPinnedRows(&cur, &prev, rows, cols, 1, 1, 18, 0, cols - 1);
    try testing.expectEqual(@as(usize, 2), got.top);
    try testing.expectEqual(@as(usize, 18), got.bottom);
}

test "trimPinnedRows: control -- the same scroll with no label keeps every row" {
    const rows = 20;
    const cols = 60;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    pinnedFrames(rows, cols, null, &prev, &cur);
    const got = trimPinnedRows(&cur, &prev, rows, cols, 1, 1, 18, 0, cols - 1);
    try testing.expectEqual(@as(usize, 1), got.top);
    try testing.expectEqual(@as(usize, 18), got.bottom);
}

test "trimPinnedRows: repeating rows that moved are not pinned" {
    // A table's rule lines, two rows apart, scrolled by two: every rule cell
    // is unchanged in place, but it is also exactly what the shift brought.
    const rows = 20;
    const cols = 30;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    for (0..rows + 2) |k| {
        for (0..cols) |c| {
            const key = if (k % 2 == 0) cellKey('-', 3) else cellKey(@intCast(1000 + k * cols + c), 0);
            if (k < rows) prev[k * cols + c] = key;
            if (k >= 2) cur[(k - 2) * cols + c] = key;
        }
    }
    const got = trimPinnedRows(&cur, &prev, rows, cols, 2, 0, rows - 1, 0, cols - 1);
    try testing.expectEqual(@as(usize, 0), got.top);
    try testing.expectEqual(@as(usize, rows - 1), got.bottom);
}

test "detectShift: a pane border appearing is a layout change, not a scroll" {
    // Zoomed pane (full width) -> unzoomed: a border at column 20 appears and
    // the text on its left happens to match its old self a row up.
    const rows = 24;
    const cols = 40;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    for (0..rows) |i| for (0..cols) |c| {
        prev[i * cols + c] = cellKey(@intCast(1000 + i * cols + c), 0);
        cur[i * cols + c] = if (c == 20) cellKey(0x2502, 3) else cellKey(@intCast(1000 + (i + 1) * cols + c), 0);
    };
    try testing.expectEqual(@as(?Shift, null), detectShift(&cur, &prev, rows, cols, 6, 0.6));
    // Control: the same frames with the border already present in both.
    for (0..rows) |i| prev[i * cols + 20] = cellKey(0x2502, 3);
    try testing.expect(detectShift(&cur, &prev, rows, cols, 6, 0.6) != null);
}

fn iconListKey(comptime cols: usize, icon: u32, i: usize, row: usize, col: usize) u64 {
    // The list sits right of yazi's parent-directory pane, behind its border.
    if (col < 10) return if (col == 9) cellKey(0x2502, 3) else cellKey(blank_glyph, 0);
    const c = col - 10;
    return switch (c) {
        0, 1 => cellKey(@intCast('0' + (i % 10)), 1),
        2, 4 => cellKey(blank_glyph, 0),
        3 => cellKey(icon, 5),
        else => cellKey(@intCast(5000 + row * cols + c), 2),
    };
}

fn iconListFrames(comptime rows: usize, comptime cols: usize, icon: u32, prev: *[rows * cols]u64, cur: *[rows * cols]u64) void {
    // yazi: relative numbers (cols 0-1, fixed to the screen), a blank, one
    // icon per row (col 3), a blank, the name (cols 5..). The list scrolls
    // up by one row; the numbers do not move.
    for (0..rows) |i| for (0..cols) |c| {
        prev[i * cols + c] = iconListKey(cols, icon, i, i, c);
        cur[i * cols + c] = iconListKey(cols, icon, i, i + 1, c);
    };
}

fn gutterFrames(comptime rows: usize, comptime cols: usize, border: bool, prev: *[rows * cols]u64, cur: *[rows * cols]u64) void {
    // nvim: relative numbers in cols 0-3 (relabelled every step: the same
    // number stays on each screen row), a blank, then prose moving up a row.
    for (0..rows) |i| for (0..cols) |c| {
        const k = i * cols + c;
        if (border and c == 2) {
            prev[k] = cellKey(0x2502, 3);
            cur[k] = prev[k];
        } else if (c < 4) {
            prev[k] = cellKey(@intCast(600 + (i % 7) * 4 + c), 1);
            cur[k] = prev[k];
        } else if (c == 4) {
            prev[k] = cellKey(blank_glyph, 0);
            cur[k] = prev[k];
        } else {
            prev[k] = cellKey(@intCast(9000 + i * cols + c), 2);
            cur[k] = cellKey(@intCast(9000 + (i + 1) * cols + c), 2);
        }
    };
}

test "detectShift: a scroll beside a line-number gutter takes the gutter" {
    const rows = 20;
    const cols = 40;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    gutterFrames(rows, cols, false, &prev, &cur);
    const s = detectShift(&cur, &prev, rows, cols, 6, 0.6).?;
    try testing.expectEqual(@as(usize, 0), s.left);
    // Control: a pane border in that strip keeps the scroll on its side.
    gutterFrames(rows, cols, true, &prev, &cur);
    const b = detectShift(&cur, &prev, rows, cols, 6, 0.6).?;
    try testing.expect(b.left > 2);
}

test "detectShift: a column of identical icons slides with its names" {
    const rows = 20;
    const cols = 40;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    iconListFrames(rows, cols, 0xF48A, &prev, &cur);
    const s = detectShift(&cur, &prev, rows, cols, 6, 0.6).?;
    try testing.expectEqual(@as(isize, 1), s.rows);
    try testing.expectEqual(@as(usize, 12), s.left); // icon (13) and the blank before it
    try testing.expectEqual(@as(usize, cols - 1), s.right);
}

test "detectShift: control -- a drawn border in that column still divides" {
    const rows = 20;
    const cols = 40;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    iconListFrames(rows, cols, 0x2502, &prev, &cur);
    const s = detectShift(&cur, &prev, rows, cols, 6, 0.6).?;
    try testing.expectEqual(@as(usize, 14), s.left); // past the border (13)
}

test "detectShift: a still screen is not a scroll" {
    // The failure this guards: a static screen finding a shift and animating
    // every frame forever.
    var rows: [20]u64 = undefined;
    for (&rows, 0..) |*v, i| v.* = 1000 + i;
    try testing.expect(detectShift(&rows, &rows, rows.len, 1, 6, 0.6) == null);
}

test "detectShift: a blank screen matches every shift and must be refused" {
    // Every row equal means every offset scores a perfect match. Believing one
    // would slide an empty screen sideways for no reason.
    const blank: [20]u64 = @splat(0);
    try testing.expect(detectShift(&blank, &blank, blank.len, 1, 6, 0.6) == null);
}

test "detectShift: repeating content does not invent a scroll" {
    // Alternating rows match at every even offset, and match themselves just
    // as well, so `same` has to veto it.
    var rows: [20]u64 = undefined;
    for (&rows, 0..) |*v, i| v.* = if (i % 2 == 0) 7 else 9;
    try testing.expect(detectShift(&rows, &rows, rows.len, 1, 6, 0.6) == null);
}

test "detectShift: an unrelated screen is not a scroll" {
    // A full repaint with different content -- switching buffers, say -- has
    // nothing in common and must not be animated.
    var prev: [20]u64 = undefined;
    for (&prev, 0..) |*v, i| v.* = 1000 + i;
    var cur: [20]u64 = undefined;
    for (&cur, 0..) |*v, i| v.* = 50_000 + i * 7;
    try testing.expect(detectShift(&cur, &prev, cur.len, 1, 6, 0.6) == null);
}

test "detectShift: too few matching rows is refused" {
    // Only three rows line up: below the confidence floor, so no animation.
    var prev: [20]u64 = undefined;
    for (&prev, 0..) |*v, i| v.* = 1000 + i;
    var cur: [20]u64 = undefined;
    for (&cur, 0..) |*v, i| v.* = if (i < 3) 1000 + i + 3 else 90_000 + i;
    try testing.expect(detectShift(&cur, &prev, cur.len, 1, 6, 0.6) == null);
}

test "detectShift: with the wheel's direction, a shift the other way is not found" {
    // Rows of two alternating kinds: moving up 3 looks the same as down 1.
    const rows = 12;
    const cols = 12;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    for (0..rows) |i| for (0..cols) |c| {
        prev[i * cols + c] = cellKey(@intCast(100 + (i % 4) * 16 + c), 0);
        cur[i * cols + c] = cellKey(@intCast(100 + ((i + 3) % 4) * 16 + c), 0);
    };
    const any = detectShiftDir(&cur, &prev, rows, cols, 6, 0.6, 8, 0).?;
    try testing.expectEqual(@as(isize, -1), any.rows);
    const up = detectShiftDir(&cur, &prev, rows, cols, 6, 0.6, 8, 1).?;
    try testing.expectEqual(@as(isize, 3), up.rows);
}

test "detectShift: a shift larger than we animate is not reported" {
    var prev: [40]u64 = undefined;
    for (&prev, 0..) |*v, i| v.* = 1000 + i;
    var cur: [40]u64 = undefined;
    // Past max_animated_rows: a page jump, which snaps rather than slides.
    for (&cur, 0..) |*v, i| v.* = 1000 + i + max_animated_rows + 5;
    try testing.expect(detectShift(&cur, &prev, cur.len, 1, 6, 0.6) == null);
}

test "detectShift: mismatched lengths are refused rather than compared" {
    const a: [10]u64 = @splat(1);
    const b: [12]u64 = @splat(1);
    try testing.expect(detectShift(&a, &b, a.len, 1, 6, 0.6) == null);
}

test "ScrollAnim: settles within the configured duration, not long after" {
    // The whole point of a *duration*: a one-row scroll at 60fps must be done
    // in the time asked for. Decaying a fraction of the remaining offset
    // instead stretches an 80ms setting into hundreds of milliseconds of
    // sub-pixel creep, which reads as smear rather than motion.
    var a: ScrollAnim = .{};
    a.push(-38, 1, 52, 0, 0, 10_000);
    var elapsed: f32 = 0;
    while (a.active() and elapsed < 1000) : (elapsed += 16) a.advance(16, 80, .ease_out_cubic);
    try testing.expect(!a.active());
    try testing.expect(elapsed <= 96);
}

test "ScrollAnim: eases out, so early frames move further than late ones" {
    // The property a person notices: leave the old position quickly, arrive at
    // the new one gently. A linear ramp arrives at full speed and stops dead.
    var a: ScrollAnim = .{};
    a.push(-100, 0, 10, 0, 0, 10_000);
    const start = a.offset_px;
    a.advance(10, 100, .ease_out_cubic);
    const first = @abs(a.offset_px - start);
    const before = a.offset_px;
    a.advance(10, 100, .ease_out_cubic);
    const second = @abs(a.offset_px - before);
    try testing.expect(first > second);
}

test "ScrollAnim: position comes from elapsed time, not accumulated frames" {
    // One long frame must land where several short ones would, so a dropped
    // frame does not leave the animation behind.
    var a: ScrollAnim = .{};
    var b: ScrollAnim = .{};
    a.push(-100, 0, 10, 0, 0, 10_000);
    b.push(-100, 0, 10, 0, 0, 10_000);
    a.advance(30, 100, .ease_out_cubic);
    b.advance(10, 100, .ease_out_cubic);
    b.advance(10, 100, .ease_out_cubic);
    b.advance(10, 100, .ease_out_cubic);
    try testing.expectApproxEqAbs(a.offset_px, b.offset_px, 0.001);
}

const testing = std.testing;

test "ScrollAnim: starts inactive" {
    const a: ScrollAnim = .{};
    try testing.expect(!a.active());
}

test "ScrollAnim: start below the visible threshold is a no-op" {
    var a: ScrollAnim = .{};
    a.push(0.1, 0, 10, 0, 0, 10_000);
    try testing.expect(!a.active());
}

test "ScrollAnim: advancing a full duration finishes it" {
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 0, 0, 10_000);
    try testing.expect(a.active());
    a.advance(80, 80, .ease_out_cubic);
    try testing.expect(!a.active());
    try testing.expectEqual(@as(f32, 0), a.offset_px);
}

test "ScrollAnim: a longer-than-duration frame does not overshoot past zero" {
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 0, 0, 10_000);
    // A stalled surface: the offset must land exactly on zero, never cross it
    // and animate back from the other side.
    a.advance(5000, 80, .ease_out_cubic);
    try testing.expectEqual(@as(f32, 0), a.offset_px);
}

test "ScrollAnim: decays monotonically toward zero without changing sign" {
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 0, 0, 10_000);
    var prev = a.offset_px;
    var i: usize = 0;
    while (i < 200 and a.active()) : (i += 1) {
        a.advance(16, 80, .ease_out_cubic);
        try testing.expect(a.offset_px <= 0); // never flips sign
        try testing.expect(@abs(a.offset_px) <= @abs(prev)); // never grows
        prev = a.offset_px;
    }
    try testing.expect(!a.active());
}

test "ScrollAnim: positive and negative decay symmetrically" {
    var up: ScrollAnim = .{};
    var down: ScrollAnim = .{};
    up.push(30, 0, 10, 0, 0, 10_000);
    down.push(-30, 0, 10, 0, 0, 10_000);
    for (0..3) |_| {
        up.advance(16, 80, .ease_out_cubic);
        down.advance(16, 80, .ease_out_cubic);
    }
    try testing.expectApproxEqAbs(up.offset_px, -down.offset_px, 0.001);
}

test "ScrollAnim: a scroll over a disjoint region replaces" {
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 0, 0, 10_000);
    a.advance(16, 80, .ease_out_cubic);
    a.push(40, 20, 30, 0, 0, 10_000);
    try testing.expectEqual(@as(f32, 40), a.offset_px);
    try testing.expectEqual(@as(f32, 20), a.top);
    try testing.expectEqual(@as(f32, 30), a.bottom);
}

test "ScrollAnim: a one-row region jitter keeps the pending displacement" {
    // tmux moves its scrolling region by a row between redraws. Treating that
    // as a different region discarded the offset mid-slide, and the content
    // snapped to the model instead of arriving there.
    var a: ScrollAnim = .{};
    a.push(-20, 1, 52, 0, 0, 10_000);
    a.push(-20, 2, 52, 0, 0, 10_000);
    try testing.expectEqual(@as(f32, -40), a.offset_px);
    // Row 1 keeps the region: it earned 20px of the 40px now standing, and
    // dropping it would snap that row back on this frame and forward on the
    // next. This assertion used to read `2`; see the union in `push`.
    try testing.expectEqual(@as(f32, 1), a.top);
}

test "ScrollAnim: the two scroll producers disagreeing must not tear the region" {
    // The measured case, from a real C-e scroll of a wrapped markdown buffer
    // on a 55x210 grid: nvim's own scroll events report rows 0..52 full
    // width, the repaint detector reports rows 0..54 of columns 2..207, and
    // they interleave through one gesture.
    //
    // The offset is shared, so the region must cover both. Adopting only the
    // newest left columns 0..1 and 208..209 snapping between displaced and
    // stationary at frame rate, which is the seam reported as tearing.
    const cell_h: f32 = 38;
    var a: ScrollAnim = .{};
    a.push(cell_h, 0, 52, 0, 209, cell_h * max_lag_rows);
    a.push(cell_h, 0, 54, 2, 207, cell_h * max_lag_rows);
    try testing.expectEqual(@as(f32, 0), a.left);
    try testing.expectEqual(@as(f32, 209), a.right);
    try testing.expectEqual(@as(f32, 0), a.top);
    try testing.expectEqual(@as(f32, 54), a.bottom);

    // And the detector's narrower opinion arriving first is the same fact.
    var b: ScrollAnim = .{};
    b.push(cell_h, 0, 54, 5, 204, cell_h * max_lag_rows);
    b.push(cell_h, 0, 52, 0, 209, cell_h * max_lag_rows);
    try testing.expectEqual(@as(f32, 0), b.left);
    try testing.expectEqual(@as(f32, 209), b.right);
}

test "ScrollAnim: a scroll in disjoint columns replaces rather than merging" {
    // yazi scrolls its preview pane while the file list beside it holds
    // still. If the user then scrolls the list within the same animation, the
    // pending offset belongs to the preview and must not be handed to the
    // list -- and the union must not swallow the gap between them, which
    // would slide both panes together.
    var a: ScrollAnim = .{};
    a.push(-20, 0, 40, 60, 200, 10_000);
    a.advance(16, 80, .ease_out_cubic);
    a.push(40, 0, 40, 0, 40, 10_000);
    try testing.expectEqual(@as(f32, 40), a.offset_px);
    try testing.expectEqual(@as(f32, 0), a.left);
    try testing.expectEqual(@as(f32, 40), a.right);
}

test "ScrollAnim: the union is discarded once the offset reaches zero" {
    // Growth is bounded by one gesture. Without this the region would creep
    // outwards across unrelated scrolls until it covered the whole screen.
    var a: ScrollAnim = .{};
    a.push(20, 0, 52, 0, 209, 10_000);
    a.push(20, 0, 54, 2, 207, 10_000);
    try testing.expectEqual(@as(f32, 54), a.bottom);
    a.advance(1000, 80, .ease_out_cubic);
    try testing.expect(!a.active());
    a.push(20, 0, 52, 0, 209, 10_000);
    try testing.expectEqual(@as(f32, 52), a.bottom);
}

test "ScrollAnim: one deliberate multi-row scroll is animated whole" {
    // yazi's `J` moves the list five rows in one go, and tmux hands nvim's
    // scrolling over in batches of three to five rows. `max_lag_rows` exists
    // to stop a BURST of pushes winding the offset up -- but it also cut a
    // single five-row push down to two rows, snapping the other three before
    // the slide began. A single push is displaced by its whole distance, up
    // to `max_animated_rows`; only accumulation beyond it is capped.
    const cell_h: f32 = 21;
    var a: ScrollAnim = .{};
    a.push(5 * cell_h, 0, 52, 0, 209, cell_h * max_lag_rows);
    try testing.expectEqual(@as(f32, 5 * cell_h), a.offset_px);

    // Landing on a standing offset still cannot exceed the larger of the two.
    a.push(5 * cell_h, 0, 52, 0, 209, cell_h * max_lag_rows);
    try testing.expectEqual(@as(f32, 5 * cell_h), a.offset_px);
}

test "ScrollAnim: a held key keeps up instead of snapping against the cap" {
    // Holding `j` at the bottom of an nvim window: one row every ~33ms of key
    // repeat, with the configured 300ms ease restarting from zero on every
    // row. Measured live, the standing offset pinned itself at the
    // `max_lag_rows` cap and each new row was CLIPPED -- the part over the cap
    // drawn as a snap -- so held scrolling alternated sliding and jumping. A
    // longer duration retires rows more slowly and so clips more, which is
    // why 1000ms "felt the same" as 300: most of every row was a jump.
    //
    // No row may be clipped once the animation is keeping pace with input.
    const cell_h: f32 = 21;
    const limit = cell_h * max_lag_rows;
    var a: ScrollAnim = .{};
    var clipped: f32 = 0;
    var t: usize = 0;
    while (t < 60) : (t += 1) {
        // 60Hz frames, a row every other frame: ~30Hz key repeat.
        if (t % 2 == 0) {
            const before = a.offset_px;
            a.push(cell_h, 0, 52, 0, 209, limit);
            if (t >= 8) clipped += (before + cell_h) - a.offset_px;
        }
        a.advance(16.7, 300, .ease_out_cubic);
    }
    try testing.expectApproxEqAbs(@as(f32, 0), clipped, 0.01);
}

test "ScrollAnim: a scroll after a pause still takes the configured duration" {
    // Pacing to input must not leak into an isolated scroll: two rows 250ms
    // apart are two separate gestures as far as the eye is concerned.
    var a: ScrollAnim = .{};
    a.push(21, 0, 52, 0, 209, 42);
    a.advance(250, 300, .ease_out_cubic);
    a.push(21, 0, 52, 0, 209, 42);
    a.advance(200, 300, .ease_out_cubic);
    try testing.expect(a.active());
    a.advance(120, 300, .ease_out_cubic);
    try testing.expect(!a.active());
}

test "ScrollAnim: successive scrolls over the same region accumulate" {
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 0, 0, 10_000);
    // Still behind by 20px when the model scrolls another 20: the display is
    // now behind by 40, not by 20.
    a.push(-20, 0, 10, 0, 0, 10_000);
    try testing.expectEqual(@as(f32, -40), a.offset_px);
}

test "ScrollAnim: opposing scrolls net out rather than compounding" {
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 0, 0, 10_000);
    a.push(20, 0, 10, 0, 0, 10_000);
    try testing.expect(!a.active());
}

test "ScrollAnim: a fling cannot wind the offset past a couple of rows" {
    // The failure this guards: scrolls arrive faster than the ramp retires
    // them, the offset winds up, and the whole block of text is drawn half a
    // screen from where it belongs with the rest of the region empty.
    const cell_h: f32 = 38;
    var a: ScrollAnim = .{};
    const limit = cell_h * max_lag_rows;
    for (0..200) |_| {
        a.push(-cell_h, 1, 52, 0, 0, limit);
        a.advance(16, 80, .ease_out_cubic);
    }
    try testing.expect(@abs(a.offset_px) <= limit);
}

test "ScrollAnim: accumulation is capped by the limit" {
    var a: ScrollAnim = .{};
    for (0..100) |_| a.push(-20, 0, 10, 0, 0, 50);
    try testing.expectEqual(@as(f32, -50), a.offset_px);
}

test "ScrollAnim: zero or negative dt is ignored rather than reversing" {
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 0, 0, 10_000);
    const before = a.offset_px;
    a.advance(0, 80, .ease_out_cubic);
    a.advance(-5, 80, .ease_out_cubic);
    try testing.expectEqual(before, a.offset_px);
}

test "ScrollAnim: a zero duration snaps rather than freezing" {
    // Reachable the moment the duration is a setting someone can type into.
    // The obvious divide-by-zero guard returns early, which pins the text a
    // row off the grid indefinitely -- a worse failure than not animating.
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 0, 0, 10_000);
    a.advance(16, 0, .ease_out_cubic);
    try testing.expectEqual(@as(f32, 0), a.offset_px);
    try testing.expect(!a.active());
}

fn testShift(rows: isize, left: usize, right: usize) Shift {
    return .{ .rows = rows, .top = 1, .bottom = 56, .left = left, .right = right };
}

test "isRepair: the number column put back after a scroll is not a scroll" {
    // nvim scrolled 3 rows over 210 columns; the gutter reads as -3.
    try std.testing.expect(isRepair(3, 16, 210, testShift(-3, 2, 3)));
    try std.testing.expect(isRepair(-1, 40, 210, testShift(1, 0, 3)));
}

test "isRepair: a full-width reversal is the user changing direction" {
    try std.testing.expect(!isRepair(3, 16, 210, testShift(-2, 0, 209)));
    try std.testing.expect(!isRepair(3, 16, 210, testShift(-2, 4, 207)));
}

test "isRepair: the number column alone moving WITH the scroll is a repaint too" {
    // Measured mid-spin: shift=8 over column 2 only, same sign as the scroll.
    try std.testing.expect(isRepair(3, 16, 210, testShift(8, 2, 2)));
    // But a full-width shift the same way is the app repainting a scroll.
    try std.testing.expect(!isRepair(3, 16, 210, testShift(3, 0, 209)));
}

test "isRepair: long after the scroll, a narrow shift is its own movement" {
    try std.testing.expect(!isRepair(3, repair_window_ms + 1, 210, testShift(-1, 2, 3)));
    try std.testing.expect(!isRepair(0, 0, 210, testShift(-1, 2, 3)));
}

/// Drive `push`/`advance` like the renderer does: a push of `push_px` every
/// `interval_ms`, frames every 1000/60 ms, and return the smallest and
/// largest per-frame movement of the DRAWN position between `from_ms` and
/// `to_ms` -- what the eye sees as steady or not.
fn steadiness(easing: Easing, push_px: f32, interval_ms: f32, from_ms: f32, to_ms: f32) [2]f32 {
    var a: ScrollAnim = .{};
    const dt: f32 = 1000.0 / 60.0;
    var model: f32 = 0;
    var next_push: f32 = 0;
    var t: f32 = 0;
    var prev_drawn: ?f32 = null;
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = 0;
    while (t < to_ms) : (t += dt) {
        while (next_push <= t) : (next_push += interval_ms) {
            a.push(push_px, 0, 50, 0, 200, ghost_lag_rows * 20);
            model += push_px;
        }
        a.advance(dt, 300, easing);
        const drawn = model - a.offset_px;
        if (prev_drawn) |p| if (t >= from_ms) {
            lo = @min(lo, drawn - p);
            hi = @max(hi, drawn - p);
        };
        prev_drawn = drawn;
    }
    return .{ lo, hi };
}

test "spring: a held key scrolls at a steady speed" {
    // A row every 40 ms -- key repeat at 25 Hz -- is 8.3 px per frame on
    // average. The spring holds within about a pixel of that.
    const r = steadiness(.spring, 20, 40, 400, 1300);
    try std.testing.expect(r[1] - r[0] < 2.0);
    try std.testing.expect(r[0] > 6.0);
}

test "spring: control -- an ease-out restarted per row surges and sags" {
    // The same input through ease-out-cubic: every push restarts the curve
    // at its fastest, so the speed saws between ~5.5 and ~12 px per frame.
    // Measured live holding j: 5 to 13. If this stops failing to be steady,
    // the test above is no longer telling the two apart.
    const r = steadiness(.ease_out_cubic, 20, 40, 400, 1300);
    try std.testing.expect(r[1] - r[0] > 4.0);
}

test "spring: a single push sets off at once and settles" {
    var a: ScrollAnim = .{};
    a.push(20, 0, 50, 0, 200, 240);
    a.advance(1000.0 / 60.0, 300, .spring);
    // Moving on the first frame: no standstill start for a lone keypress.
    try std.testing.expect(a.offset_px < 20 - 5);
    var t: f32 = 1000.0 / 60.0;
    while (a.active() and t < 1000) : (t += 1000.0 / 60.0) a.advance(1000.0 / 60.0, 300, .spring);
    try std.testing.expect(!a.active());
    try std.testing.expect(t <= 300);
}

test "spring: a flood stiffens instead of piling against the cap" {
    // Three rows every frame (a touchpad flick nvim can barely keep up
    // with): the spring must never be clipped by the cap.
    var a: ScrollAnim = .{};
    const limit: f32 = ghost_lag_rows * 20;
    var worst: f32 = 0;
    for (0..60) |_| {
        a.push(60, 0, 50, 0, 200, limit);
        a.advance(1000.0 / 60.0, 300, .spring);
        worst = @max(worst, @abs(a.offset_px));
    }
    try std.testing.expect(worst < limit);
}

/// Hold a key: a 20 px row every `interval_ms` for 1.5 s at the user's
/// 580 ms duration, and return the deepest lag (px) over the last half.
fn heldLag(key_paced: bool, interval_ms: f32) f32 {
    var a: ScrollAnim = .{};
    const dt: f32 = 1000.0 / 60.0;
    var next_push: f32 = 0;
    var t: f32 = 0;
    var worst: f32 = 0;
    while (t < 1500) : (t += dt) {
        while (next_push <= t) : (next_push += interval_ms)
            a.push(20, 0, 50, 0, 200, ghost_lag_rows * 20);
        a.key_paced = key_paced;
        a.advance(dt, 580, .spring);
        if (t >= 750) worst = @max(worst, @abs(a.offset_px));
    }
    return worst;
}

test "spring: a held key keeps pace instead of trailing rows behind" {
    // 40 Hz repeat. Unpaced the spring trails by ~7.7 rows (V x 580 / 3),
    // which yazi showed as its hover bar sitting on the wrong file.
    try std.testing.expect(heldLag(false, 25) > 6 * 20);
    try std.testing.expect(heldLag(true, 25) < 2 * 20);
}

test "spring: key pacing keeps a held key steady" {
    var a: ScrollAnim = .{};
    const dt: f32 = 1000.0 / 60.0;
    var model: f32 = 0;
    var next_push: f32 = 0;
    var t: f32 = 0;
    var prev: ?f32 = null;
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = 0;
    while (t < 1500) : (t += dt) {
        while (next_push <= t) : (next_push += 25) {
            a.push(20, 0, 50, 0, 200, ghost_lag_rows * 20);
            model += 20;
        }
        a.key_paced = true;
        a.advance(dt, 580, .spring);
        const drawn = model - a.offset_px;
        if (prev) |p| if (t >= 500) {
            lo = @min(lo, drawn - p);
            hi = @max(hi, drawn - p);
        };
        prev = drawn;
    }
    // 13.3 px a frame on average; 40 Hz input against 60 Hz frames lands
    // one or two rows per frame, and the spring must smooth that out.
    try std.testing.expect(lo > 6.0);
    try std.testing.expect(hi < 22.0);
}

test "spring: held key pace does not beat against the frame rate" {
    // Pushes land between frames, as real ones do: 40 Hz against 60 Hz is
    // one frame, two frames, one, two... apart. Taking each interval as
    // the pace swung the spring's stiffness 2x per key (steps 7..31 px).
    var a: ScrollAnim = .{};
    const dt: f32 = 1000.0 / 60.0;
    var model: f32 = 0;
    var next_push: f32 = 5;
    var t: f32 = 0;
    var prev: ?f32 = null;
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = 0;
    while (t < 2000) : (t += dt) {
        while (next_push <= t) : (next_push += 25) {
            a.push(20, 0, 50, 0, 200, ghost_lag_rows * 20);
            model += 20;
        }
        a.key_paced = true;
        a.advance(dt, 580, .spring);
        const drawn = model - a.offset_px;
        if (prev) |p| if (t >= 800) {
            lo = @min(lo, drawn - p);
            hi = @max(hi, drawn - p);
        };
        prev = drawn;
    }
    try std.testing.expect(lo > 10.0);
    try std.testing.expect(hi < 17.0);
    // ...and still keeps pace, for yazi's sake.
    try std.testing.expect(heldLag(true, 25) < 2 * 20);
}

test "spring: a hold keeps pace from its first repeat" {
    // Press, the 300 ms repeat delay, then 40 Hz repeat. The delay must not
    // linger in the pace: from half a second in, the drawn text may trail
    // the model by no more than the steady held-key lag. Measured as the
    // mean, plus a looser bound on the peak: the glide keeps
    // `glide_lead_ms` of travel in hand, so the frame a row lands on reads
    // a row more than the mean (the spring's peaks were ~1.4 rows, the
    // glide's ~2.2; the mean ~1 row either way). Unpaced it was 8 rows.
    var a: ScrollAnim = .{};
    a.key_paced = true;
    const dt: f32 = 1000.0 / 60.0;
    var model: f32 = 0;
    var next_push: f32 = 0;
    var t: f32 = 0;
    var worst: f32 = 0;
    var sum: f32 = 0;
    var n: f32 = 0;
    while (t < 1500) : (t += dt) {
        while (next_push <= t) {
            a.push(20, 0, 50, 0, 200, ghost_lag_rows * 20);
            model += 20;
            next_push += if (next_push == 0) 300 else 25;
        }
        a.advance(dt, 600, .spring);
        if (t >= 450) {
            worst = @max(worst, @abs(a.offset_px));
            sum += @abs(a.offset_px);
            n += 1;
        }
    }
    try std.testing.expect(sum / n < 1.5 * 20);
    try std.testing.expect(worst < 2.5 * 20);
}

test "spring: a single keypress is not paced" {
    var a: ScrollAnim = .{};
    a.key_paced = true;
    a.push(20, 0, 50, 0, 200, 240);
    try std.testing.expect(a.pace_ms == 0);
}

test "glide: a held key whose rows land unevenly still moves evenly" {
    // nvim's rows under 40 Hz repeat land 17-35 ms apart, not 25. The
    // stiff paced spring followed every one (rows per frame 9-19 px, sd
    // ~20 %, in a model of this file); the glide moves at their average.
    const seq = [_]f32{ 25, 33, 18, 29, 21, 35, 24, 17, 30, 27 };
    var a: ScrollAnim = .{};
    const dt: f32 = 1000.0 / 60.0;
    var model: f32 = 0;
    var next_push: f32 = 5;
    var i: usize = 0;
    var t: f32 = 0;
    var prev: ?f32 = null;
    var lo: f32 = std.math.inf(f32);
    var hi: f32 = 0;
    var sum: f32 = 0;
    var sum2: f32 = 0;
    var n: f32 = 0;
    var worst: f32 = 0;
    while (t < 2000) : (t += dt) {
        while (next_push <= t) {
            a.push(20, 0, 50, 0, 200, ghost_lag_rows * 20);
            model += 20;
            next_push += seq[i % seq.len];
            i += 1;
        }
        a.key_paced = true;
        a.advance(dt, 580, .spring);
        const drawn = model - a.offset_px;
        if (prev) |p| if (t >= 800) {
            const s = drawn - p;
            lo = @min(lo, s);
            hi = @max(hi, s);
            sum += s;
            sum2 += s * s;
            n += 1;
            worst = @max(worst, @abs(a.offset_px));
        };
        prev = drawn;
    }
    try std.testing.expect(a.gliding);
    const mean = sum / n;
    const sd = @sqrt(@max(sum2 / n - mean * mean, 0));
    try std.testing.expect(sd / mean < 0.10);
    try std.testing.expect(lo > 10.0);
    try std.testing.expect(hi < 16.5);
    // ...and no more lag than pacing gave.
    try std.testing.expect(worst < 2 * 20);
}

test "glide: rows queued behind a stall resume the glide" {
    // 40 Hz rows, nvim stalls 130 ms, then delivers the 5 rows it owed at
    // once and carries on. Without the linger the glide had landed and been
    // forgotten, and the backlog leapt in on a stiff spring.
    var a: ScrollAnim = .{};
    const dt: f32 = 1000.0 / 60.0;
    var model: f32 = 0;
    var t: f32 = 0;
    var next: f32 = 0;
    var prev: ?f32 = null;
    var worst_after: f32 = 0;
    var backlog_sent = false;
    while (t < 3000) : (t += dt) {
        if (t < 1500) {
            while (next <= t) : (next += 25) {
                a.push(20, 0, 50, 0, 200, ghost_lag_rows * 20);
                model += 20;
            }
        } else if (t >= 1630 and !backlog_sent) {
            for (0..5) |_| {
                a.push(20, 0, 50, 0, 200, ghost_lag_rows * 20);
                model += 20;
            }
            backlog_sent = true;
            next = t + 25;
        } else if (backlog_sent) {
            while (next <= t) : (next += 25) {
                a.push(20, 0, 50, 0, 200, ghost_lag_rows * 20);
                model += 20;
            }
        }
        a.key_paced = true;
        a.advance(dt, 580, .spring);
        const drawn = model - a.offset_px;
        if (prev) |p| if (t >= 1630 and t < 2100) {
            worst_after = @max(worst_after, drawn - p);
        };
        prev = drawn;
    }
    // A row a frame at most, against 30 px with the glide forgotten.
    try std.testing.expect(worst_after < 22);
}

test "glide: a Ctrl-D burst is left to the spring" {
    // nvim's own half-page glide: a row every 6 ms, several a frame.
    var a: ScrollAnim = .{};
    const dt: f32 = 1000.0 / 60.0;
    var next_push: f32 = 0;
    var t: f32 = 0;
    var pushed: usize = 0;
    while (t < 600) : (t += dt) {
        while (next_push <= t and pushed < 29) : (next_push += 6) {
            a.push(20, 0, 50, 0, 200, ghost_lag_rows * 20);
            pushed += 1;
        }
        a.key_paced = true;
        a.advance(dt, 580, .spring);
        try std.testing.expect(!a.gliding);
    }
}

test "glide: letting go lands without stopping dead or going back" {
    var a: ScrollAnim = .{};
    const dt: f32 = 1000.0 / 60.0;
    var model: f32 = 0;
    var next_push: f32 = 5;
    var t: f32 = 0;
    var prev: ?f32 = null;
    var was_gliding = false;
    var landed_at: ?f32 = null;
    var last_step: f32 = 0;
    while (t < 2000) : (t += dt) {
        while (next_push <= t and next_push < 1000) : (next_push += 25) {
            a.push(20, 0, 50, 0, 200, ghost_lag_rows * 20);
            model += 20;
        }
        a.key_paced = true;
        a.advance(dt, 580, .spring);
        if (a.gliding) was_gliding = true;
        const drawn = model - a.offset_px;
        if (prev) |p| {
            const s = drawn - p;
            try std.testing.expect(s >= -0.01);
            // the last frames before it lands step down, not off a cliff
            if (t > 1000 and s > 0.01) {
                if (last_step > 0) try std.testing.expect(s < last_step * 1.05 or s < 2);
                last_step = s;
            }
        }
        prev = drawn;
        // Landed = nothing left to see; under a held key it then lingers
        // invisibly (`glide_linger_max_ms`).
        if (landed_at == null and @abs(a.offset_px) < min_offset_px) landed_at = t;
    }
    try std.testing.expect(was_gliding);
    try std.testing.expect(landed_at != null and landed_at.? < 1000 + 300);
}

const TestGlyph = struct { grid_pos: [2]u16, id: u32 = 0 };

test "ghost slices: an image row leaving the top is kept above it" {
    const S = struct { x: i32, y: i32, z: i32 };
    var ghosts: std.ArrayListUnmanaged(S) = .empty;
    defer ghosts.deinit(testing.allocator);
    // Image rows at grid rows 1..4, one classic placement at row 1 (z 5).
    const drawn = [_]S{
        .{ .x = 3, .y = 1, .z = -1 }, .{ .x = 3, .y = 2, .z = -1 },
        .{ .x = 3, .y = 3, .z = -1 }, .{ .x = 3, .y = 4, .z = -1 },
        .{ .x = 3, .y = 1, .z = 5 },
    };
    // Content up by 2 over rows 1..10: rows 1 and 2 leave.
    shiftGhostSlices(S, &ghosts, 2, 1, 10);
    try captureGhostSlices(S, testing.allocator, &ghosts, &drawn, 2, 1, 10, 0, 20);
    try testing.expectEqual(@as(usize, 2), ghosts.items.len);
    try testing.expectEqual(@as(i32, -1), ghosts.items[0].y);
    try testing.expectEqual(@as(i32, 0), ghosts.items[1].y);
    // Back down by 2: both are the model's again.
    shiftGhostSlices(S, &ghosts, -2, 1, 10);
    try testing.expectEqual(@as(usize, 0), ghosts.items.len);
}

test "ghost slices: control -- a slice outside the region's columns is not kept" {
    const S = struct { x: i32, y: i32, z: i32 };
    var ghosts: std.ArrayListUnmanaged(S) = .empty;
    defer ghosts.deinit(testing.allocator);
    const drawn = [_]S{.{ .x = 30, .y = 1, .z = -1 }};
    try captureGhostSlices(S, testing.allocator, &ghosts, &drawn, 2, 1, 10, 0, 20);
    try testing.expectEqual(@as(usize, 0), ghosts.items.len);
}

test "ghosts: copies of a pinned label are dropped, the rest kept" {
    const G = struct { grid_pos: [2]u16, glyph_pos: [2]u32, color: [4]u8 };
    var ghosts: std.ArrayListUnmanaged(G) = .empty;
    defer ghosts.deinit(testing.allocator);
    const label = [_]G{
        .{ .grid_pos = .{ 5, 20 }, .glyph_pos = .{ 1, 1 }, .color = .{ 9, 9, 9, 255 } },
        .{ .grid_pos = .{ 6, 20 }, .glyph_pos = .{ 2, 1 }, .color = .{ 9, 9, 9, 255 } },
    };
    try ghosts.appendSlice(testing.allocator, &.{
        .{ .grid_pos = .{ 5, 22 }, .glyph_pos = .{ 1, 1 }, .color = .{ 9, 9, 9, 255 } }, // copy
        .{ .grid_pos = .{ 6, 23 }, .glyph_pos = .{ 2, 1 }, .color = .{ 9, 9, 9, 255 } }, // copy
        .{ .grid_pos = .{ 5, 24 }, .glyph_pos = .{ 7, 1 }, .color = .{ 9, 9, 9, 255 } }, // text
        .{ .grid_pos = .{ 9, 22 }, .glyph_pos = .{ 1, 1 }, .color = .{ 9, 9, 9, 255 } }, // same glyph, other column
    });
    dropGhostCopies(G, &ghosts, &label);
    try testing.expectEqual(@as(usize, 2), ghosts.items.len);
    try testing.expectEqual(@as(u32, 7), ghosts.items[0].glyph_pos[0]);
    try testing.expectEqual(@as(u16, 9), ghosts.items[1].grid_pos[0]);
}

test "pins: the edge rows of a tall coloured block are not pinned" {
    const rows = 12;
    const cols = 20;
    var prev = [_][4]u8{.{ 0, 0, 0, 0 }} ** (rows * cols);
    var now = prev;
    // A green block over rows 3..8 moves down 2 (content down, shift -2).
    for (3..9) |r| for (2..18) |c| {
        prev[r * cols + c] = .{ 0, 99, 0, 255 };
    };
    for (5..11) |r| for (2..18) |c| {
        now[r * cols + c] = .{ 0, 99, 0, 255 };
    };
    var pins = [_][4]u8{.{ 0, 0, 0, 0 }} ** (rows * cols);
    computePins([4]u8, &pins, &prev, &now, cols, -2, 0, rows - 1, 0, cols - 1);
    for (pins) |v| try testing.expectEqual(@as(u8, 0), v[0]);
}

test "pins: a bar as wide as the hovered name keeps its left end" {
    const rows = 6;
    const cols = 30;
    var prev = [_][4]u8{.{ 0, 0, 0, 0 }} ** (rows * cols);
    var now = prev;
    for (3..8) |c| prev[4 * cols + c] = .{ 9, 9, 9, 255 }; // "tools"
    for (3..12) |c| now[4 * cols + c] = .{ 9, 9, 9, 255 }; // "video-use"
    var pins = [_][4]u8{.{ 0, 0, 0, 0 }} ** (rows * cols);
    computePins([4]u8, &pins, &prev, &now, cols, 1, 0, rows - 1, 0, cols - 1);
    for (0..cols) |c| try testing.expectEqual(@as(u8, if (c >= 3 and c < 12) 255 else 0), pins[4 * cols + c][0]);
}

test "pins: a bar that changes colour with the file under it is still held" {
    const T = [4]u8;
    const cols = 16;
    const rows = 6;
    const blue: T = .{ 10, 20, 200, 255 };
    const orange: T = .{ 250, 150, 20, 255 };
    var prev: [rows * cols]T = @splat(.{ 0, 0, 0, 0 });
    var now: [rows * cols]T = @splat(.{ 0, 0, 0, 0 });
    var pins: [rows * cols]T = undefined;
    // The bar sits on row 2 in both frames, blue then orange, a little wider.
    for (3..9) |c| prev[2 * cols + c] = blue;
    for (3..11) |c| now[2 * cols + c] = orange;
    computePins(T, &pins, &prev, &now, cols, 1, 0, rows - 1, 0, cols - 1);
    try std.testing.expectEqual(@as(u8, 255), pins[2 * cols + 3][0]);
    try std.testing.expectEqual(@as(u8, 255), pins[2 * cols + 10][0]);
    // Control: the row that scrolled in was coloured there already (a table
    // with a coloured cell in that column on every row): content, not a bar.
    for (3..9) |c| prev[3 * cols + c] = .{ 9, 9, 9, 255 };
    computePins(T, &pins, &prev, &now, cols, 1, 0, rows - 1, 0, cols - 1);
    try std.testing.expectEqual(@as(u8, 0), pins[2 * cols + 3][0]);
    // Control: the same pair on the row the scroll brings in (the last one)
    // is new content -- a heading arriving where a heading stood.
    @memset(&prev, .{ 0, 0, 0, 0 });
    @memset(&now, .{ 0, 0, 0, 0 });
    for (3..9) |c| prev[(rows - 1) * cols + c] = blue;
    for (3..11) |c| now[(rows - 1) * cols + c] = orange;
    computePins(T, &pins, &prev, &now, cols, 1, 0, rows - 1, 0, cols - 1);
    try std.testing.expectEqual(@as(u8, 0), pins[(rows - 1) * cols + 3][0]);
}

test "pins: a selection bar that stays while the list scrolls under it" {
    const rows = 10;
    const cols = 30;
    var prev = [_][4]u8{.{ 0, 0, 0, 0 }} ** (rows * cols);
    var now = prev;
    // Bar on row 6, columns 2..21, in both frames; an inline-code highlight
    // of 3 cells on row 2 that coincides; a code block of rows 3..4 that
    // scrolled up one (so rows 2..3 now) -- moved, not pinned.
    for (2..22) |c| {
        prev[6 * cols + c] = .{ 9, 9, 9, 255 };
        now[6 * cols + c] = .{ 9, 9, 9, 255 };
    }
    for (5..8) |c| {
        prev[2 * cols + c] = .{ 5, 5, 5, 255 };
        now[2 * cols + c] = .{ 5, 5, 5, 255 };
    }
    for (0..cols) |c| {
        prev[3 * cols + c] = .{ 7, 7, 7, 255 };
        prev[4 * cols + c] = .{ 7, 7, 7, 255 };
        now[2 * cols + c] = if (c >= 5 and c < 8) .{ 5, 5, 5, 255 } else .{ 7, 7, 7, 255 };
        now[3 * cols + c] = .{ 7, 7, 7, 255 };
    }
    var pins = [_][4]u8{.{ 0, 0, 0, 0 }} ** (rows * cols);
    computePins([4]u8, &pins, &prev, &now, cols, 1, 0, rows - 1, 0, cols - 1);
    for (0..rows) |r| for (0..cols) |c| {
        const want: u8 = if (r == 6 and c >= 2 and c < 22) 255 else 0;
        try testing.expectEqual(want, pins[r * cols + c][0]);
    };
}

test "ghost bg: a row leaving the top keeps its colours above the region" {
    const rows = 6;
    const cols = 4;
    var bg: [rows * cols]u32 = undefined;
    for (&bg, 0..) |*v, i| v.* = @intCast(100 + i);
    var ext = [_]u32{0} ** ghostBgLen(rows, cols);
    // Content up by 2 over rows 1..4, columns 1..2: rows 1 and 2 leave.
    shiftGhostBg(u32, &ext, cols, 2, 1, 4);
    captureGhostBg(u32, &ext, &bg, cols, 2, 1, 4, 1, 2);
    const g = max_ghost_rows;
    // Grid row 1 is now at y = -1, row 2 at y = 0 (above region top 1).
    try testing.expectEqualSlices(u32, &.{ 0, 105, 106, 0 }, ext[(g - 1) * cols ..][0..cols]);
    try testing.expectEqualSlices(u32, &.{ 0, 109, 110, 0 }, ext[(g + 0) * cols ..][0..cols]);
    // A second push by 1 carries them up one more and drops nothing yet.
    shiftGhostBg(u32, &ext, cols, 1, 1, 4);
    try testing.expectEqualSlices(u32, &.{ 0, 105, 106, 0 }, ext[(g - 2) * cols ..][0..cols]);
    // Scrolling back down by 3 brings row 2's colours back inside: forgotten.
    shiftGhostBg(u32, &ext, cols, -3, 1, 4);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0, 0 }, ext[(g + 1) * cols ..][0..cols]);
}

test "ghost bg: control -- without a capture the band has no colour" {
    const rows = 6;
    const cols = 4;
    var ext = [_]u32{0} ** ghostBgLen(rows, cols);
    shiftGhostBg(u32, &ext, cols, 2, 1, 4);
    for (ext) |v| try testing.expectEqual(@as(u32, 0), v);
}

test "ghosts: rows leaving the top are kept above it, in their columns only" {
    const alloc = std.testing.allocator;
    var rows: [6]std.ArrayListUnmanaged(TestGlyph) = @splat(.empty);
    defer for (&rows) |*r| r.deinit(alloc);
    for (&rows, 0..) |*r, y| {
        try r.append(alloc, .{ .grid_pos = .{ 0, @intCast(y) }, .id = @intCast(y * 10) });
        try r.append(alloc, .{ .grid_pos = .{ 5, @intCast(y) }, .id = @intCast(y * 10 + 1) });
    }
    var ghosts: std.ArrayListUnmanaged(TestGlyph) = .empty;
    defer ghosts.deinit(alloc);
    // Region rows 1..4, columns 2..9, content up by 2: rows 1 and 2 leave.
    try captureGhosts(TestGlyph, alloc, &ghosts, &rows, 2, 1, 4, 2, 9);
    try std.testing.expectEqual(@as(usize, 2), ghosts.items.len);
    try std.testing.expectEqual(@as(i32, -1), ghostY(ghosts.items[0].grid_pos[1]));
    try std.testing.expectEqual(@as(u32, 11), ghosts.items[0].id);
    try std.testing.expectEqual(@as(i32, 0), ghostY(ghosts.items[1].grid_pos[1]));
    try std.testing.expectEqual(@as(u32, 21), ghosts.items[1].id);
}

test "ghosts: moving the other way drops kept rows the model has again" {
    const alloc = std.testing.allocator;
    var ghosts: std.ArrayListUnmanaged(TestGlyph) = .empty;
    defer ghosts.deinit(alloc);
    try ghosts.append(alloc, .{ .grid_pos = .{ 3, ghostYEncode(0) } });
    try ghosts.append(alloc, .{ .grid_pos = .{ 3, ghostYEncode(-3) } });
    // Region 1..40; content moves DOWN 2: y 0 -> 2 (inside, dropped),
    // -3 -> -1 (still above, kept).
    shiftGhosts(TestGlyph, &ghosts, -2, 1, 40);
    try std.testing.expectEqual(@as(usize, 1), ghosts.items.len);
    try std.testing.expectEqual(@as(i32, -1), ghostY(ghosts.items[0].grid_pos[1]));
}

test "ghosts: rows beyond any possible lag are let go" {
    const alloc = std.testing.allocator;
    var ghosts: std.ArrayListUnmanaged(TestGlyph) = .empty;
    defer ghosts.deinit(alloc);
    try ghosts.append(alloc, .{ .grid_pos = .{ 3, ghostYEncode(-1) } });
    shiftGhosts(TestGlyph, &ghosts, @intCast(max_ghost_rows + 1), 1, 40);
    try std.testing.expectEqual(@as(usize, 0), ghosts.items.len);
}

/// A captured screen (`tmux capture-pane -p`) as detector keys: glyph only.
fn captureKeys(comptime rows: usize, comptime cols: usize, data: []const u8, out: *[rows * cols]u64) !void {
    @memset(out, cellKey(blank_glyph, 0));
    var it = std.mem.splitScalar(u8, data, '\n');
    var r: usize = 0;
    while (it.next()) |line| : (r += 1) {
        if (r >= rows) break;
        var view = try std.unicode.Utf8View.init(line);
        var cps = view.iterator();
        var c: usize = 0;
        while (cps.nextCodepoint()) |cp| : (c += 1) {
            if (c >= cols) break;
            out[r * cols + c] = if (cp == ' ') cellKey(blank_glyph, 0) else cellKey(cp, 0);
        }
    }
}

test "detectShift: the cursor walking a list too short to scroll is not a scroll" {
    // yazi, `j` in a 16-entry folder (captured 2026-09-29, 210x55): nothing
    // scrolls, but the relative numbers relabel -- a 2-column strip that does
    // read as `shift=-1` -- and the rows the cursor left and entered changed
    // too. Pane-wide widening made that `cols=28..103`, and the list slid a
    // row and back on every press.
    const rows = 55;
    const cols = 210;
    var prev: [rows * cols]u64 = undefined;
    var cur: [rows * cols]u64 = undefined;
    try captureKeys(rows, cols, @embedFile("testdata/yazi-short-list-0.txt"), &prev);
    try captureKeys(rows, cols, @embedFile("testdata/yazi-short-list-1.txt"), &cur);
    try testing.expectEqual(@as(?Shift, null), detectShift(&cur, &prev, rows, cols, 6, 0.6));
}



test "detectShift: an icon column in a popup rides with the names" {
    // yazi in a tmux popup (`<p> e`, 35x139, list rows 6..27), one `j` that
    // scrolls, cell keys dumped by GHOSTTY_HASH_DUMP (2026-11-04). The folder
    // icons (col 34) and the `folder-` prefix every name shares (36..42) are
    // identical down the list; judged over the whole screen -- popup border,
    // the pane behind it, yazi's own bars -- they read as dividers and the
    // region began at the first digit, `cols=43..68`: the names slid and
    // their icons stood still. Judged on the moved rows they ride.
    const data = @embedFile("testdata/yazi-popup-icons.dump");
    const rows = std.mem.readInt(u32, data[0..4], .little);
    const cols = std.mem.readInt(u32, data[4..8], .little);
    const sz = rows * cols * 8;
    const prev = try testing.allocator.alloc(u64, rows * cols);
    defer testing.allocator.free(prev);
    const cur = try testing.allocator.alloc(u64, rows * cols);
    defer testing.allocator.free(cur);
    @memcpy(std.mem.sliceAsBytes(prev), data[8..][0..sz]);
    @memcpy(std.mem.sliceAsBytes(cur), data[8 + sz ..][0..sz]);
    const s_ = detectShift(cur, prev, rows, cols, 6, 0.6) orelse return error.NoShift;
    try testing.expectEqual(@as(isize, 1), s_.rows);
    try testing.expectEqual(@as(usize, 32), s_.left); // after the gutter, icon included
    try testing.expectEqual(@as(usize, 68), s_.right);
}
