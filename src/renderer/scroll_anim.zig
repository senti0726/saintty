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

/// Rate of change of `offset_px`, px per ms. Only the `spring` easing keeps
/// it: it is what makes that motion velocity-continuous. See `advanceSpring`.
vel_px_ms: f32 = 0,

/// The last push found the animation idle, so a spring should set off at
/// once rather than accelerate from standstill. See `advanceSpring`.
from_rest: bool = false,

/// The lag cap the most recent push was given, which a spring stiffens
/// against as the offset approaches it.
limit_px: f32 = 0,

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
    if (!overlaps) {
        self.pace_ms = 0;
    } else if (self.elapsed_ms > 0) {
        self.pace_ms = self.elapsed_ms * pace_intervals;
    }

    self.start_px = self.offset_px;
    self.elapsed_ms = 0;
    self.limit_px = @abs(limit);
    if (!overlaps) {
        self.vel_px_ms = 0;
        self.from_rest = true;
    }
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
    if (!(duration_ms > 0)) {
        self.offset_px = 0;
        self.vel_px_ms = 0;
        return;
    }
    var w = spring_k / duration_ms;
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
            const starts_here = eq(bg_prev[r * cols + c], v) and
                (c == 0 or !eq(bg_prev[r * cols + c - 1], v));
            var pe = c;
            if (starts_here) {
                pe = c + 1;
                while (pe <= right and eq(bg_prev[r * cols + pe], v)) pe += 1;
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
            if (starts_here and !carried and !above and !below and len >= pin_min_cells) {
                @memset(pins[r * cols + c .. r * cols + @max(e, pe)], mark);
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
    return g != blank_glyph and g != glyphOf(prev);
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
pub fn detectShift(
    cur: []const u64,
    prev: []const u64,
    rows: usize,
    cols: usize,
    min_rows: usize,
    min_ratio: f32,
) ?Shift {
    if (rows == 0 or cols == 0) return null;
    if (cur.len != rows * cols or prev.len != cur.len) return null;
    const n: isize = @intCast(rows);

    if (layoutChanged(cur, prev, rows, cols)) return null;

    // The shift explaining the most changed cells.
    var best_shift: isize = 0;
    var best_score: usize = 0;
    var s: isize = -max_animated_rows;
    while (s <= max_animated_rows) : (s += 1) {
        if (s == 0) continue;
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
    const judged = cols <= max_detect_cols;
    if (judged) for (0..cols) |c| {
        verdicts[c] = columnVerdict(Verdict, cur, prev, rows, cols, c, best_shift, min_rows, min_ratio);
        var still: usize = 0;
        for (0..rows) |i_| {
            const k = cur[i_ * cols + c];
            if (k == prev[i_ * cols + c] and glyphOf(k) != blank_glyph) still += 1;
        }
        divider[c] = @as(f32, @floatFromInt(still)) >= divider_ratio * @as(f32, @floatFromInt(rows));
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
                if (testifies(cu[row + c], pr[row + c]) and cu[row + c] == pr[src + c]) return true;
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
                prev[k] = 5;
                cur[k] = 5;
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
    try testing.expectEqual(@as(usize, 29), got.right);
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
    try testing.expectEqual(@as(usize, 44), got.right);
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
