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

    const combined = std.math.clamp(base + offset_px, -@abs(limit), @abs(limit));
    self.offset_px = if (@abs(combined) < min_offset_px) 0 else combined;

    // Restart the curve from wherever we now are. A scroll arriving mid-flight
    // should accelerate away from the current position, not resume a curve
    // aimed at a total that is no longer true.
    self.start_px = self.offset_px;
    self.elapsed_ms = 0;
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
    duration_ms: f32,
    easing: Easing,
) void {
    if (!self.active()) return;

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
                if (cur[row + c] == prev[row + c]) continue;
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
    const Verdict = enum { strong, weak, contradict, neutral };
    var left: ?usize = null;
    var right: usize = 0;
    var best_strong: usize = 0;
    var best_is_current = false;
    var seg_strong: usize = 0;
    var seg_first: ?usize = null;
    var seg_last: usize = 0;
    for (0..cols) |c| {
        var changed: usize = 0;
        var moved: usize = 0;
        for (0..rows) |i| {
            const row = i * cols;
            if (cur[row + c] == prev[row + c]) continue;
            changed += 1;
            const j = @as(isize, @intCast(i)) + best_shift;
            if (j < 0 or j >= n) continue;
            if (cur[row + c] == prev[@as(usize, @intCast(j)) * cols + c]) moved += 1;
        }
        const verdict: Verdict = verdict: {
            if (changed == 0) break :verdict .neutral;
            const agrees = @as(f32, @floatFromInt(moved)) >=
                min_ratio * @as(f32, @floatFromInt(changed));
            if (agrees and moved > 0) {
                break :verdict if (moved >= min_rows) .strong else .weak;
            }
            break :verdict if (changed >= min_rows) .contradict else .neutral;
        };
        switch (verdict) {
            // A genuinely independent region: a tmux split, or yazi's file
            // list when its selection moves against the preview's scroll.
            // Everything after this belongs to a different run.
            .contradict => {
                seg_strong = 0;
                seg_first = null;
                best_is_current = false;
            },
            // Bridges, so a gutter or a run of aligned spaces cannot split
            // one scroll into two regions, but never sets a bound.
            .neutral => {},
            .strong, .weak => {
                if (seg_first == null) seg_first = c;
                seg_last = c;
                if (verdict == .strong) seg_strong += 1;
                if (seg_strong > best_strong) {
                    best_strong = seg_strong;
                    best_is_current = true;
                }
                if (best_is_current) {
                    left = seg_first;
                    right = seg_last;
                }
            },
        }
    }
    const l = left orelse return null;

    // The rows that moved, within those columns only. Trailing-edge rows are
    // newly exposed and match nothing, but they still travel with the block,
    // so this asks which rows *changed* rather than which ones matched.
    var top: ?usize = null;
    var bottom: usize = 0;
    for (0..rows) |i| {
        const row = i * cols;
        var any = false;
        for (l..right + 1) |c| {
            if (cur[row + c] != prev[row + c]) {
                any = true;
                break;
            }
        }
        if (!any) continue;
        if (top == null) top = i;
        bottom = i;
    }
    const t = top orelse return null;
    if (bottom - t + 1 < min_rows) return null;

    return .{ .rows = best_shift, .top = t, .bottom = bottom, .left = l, .right = right };
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
