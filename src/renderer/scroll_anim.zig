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
pub fn push(
    self: *ScrollAnim,
    offset_px: f32,
    top: f32,
    bottom: f32,
    limit: f32,
) void {
    const overlaps = self.active() and self.top <= bottom and top <= self.bottom;
    const base: f32 = if (overlaps) self.offset_px else 0;

    const combined = std.math.clamp(base + offset_px, -@abs(limit), @abs(limit));
    self.offset_px = if (@abs(combined) < min_offset_px) 0 else combined;

    // Restart the curve from wherever we now are. A scroll arriving mid-flight
    // should accelerate away from the current position, not resume a curve
    // aimed at a total that is no longer true.
    self.start_px = self.offset_px;
    self.elapsed_ms = 0;
    self.top = top;
    self.bottom = bottom;
}

pub fn stop(self: *ScrollAnim) void {
    self.offset_px = 0;
    self.start_px = 0;
    self.elapsed_ms = 0;
}

/// Cubic ease-out: quick away from the old position, decelerating into the
/// new one.
///
/// A linear ramp arrives at full speed and stops dead, which reads as
/// mechanical next to a browser however short it is. This is the difference a
/// person actually notices, and it matters most for a mouse wheel, where one
/// notch is a large discrete jump rather than a finger's worth of pixels.
fn easeOut(t: f32) f32 {
    const inv = 1.0 - t;
    return 1.0 - inv * inv * inv;
}

/// Advance the animation by `dt_ms`, retiring the displacement over
/// `duration_ms`.
///
/// Eased rather than linear, and computed from elapsed time rather than
/// integrated, so a dropped or long frame lands where it should instead of
/// accumulating error.
pub fn advance(self: *ScrollAnim, dt_ms: f32, duration_ms: f32) void {
    if (!self.active()) return;

    // A stalled or hidden surface can hand us a huge dt. Finishing early is
    // the right failure: the model is already correct, so snapping to it
    // shows the truth rather than a stale intermediate position.
    if (!(dt_ms > 0) or !(duration_ms > 0)) return;

    self.elapsed_ms += dt_ms;
    if (self.elapsed_ms >= duration_ms) {
        self.offset_px = 0;
        return;
    }

    const remaining = self.start_px * (1.0 - easeOut(self.elapsed_ms / duration_ms));
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

    /// Inclusive row range that actually moved.
    ///
    /// Rows an application keeps still -- nvim's status and tab lines, a
    /// prompt box -- hold the same content from frame to frame, so they match
    /// themselves and *not* the shifted picture. Animating the whole grid drags
    /// them along and springs them back, so only the matched span moves.
    top: usize,
    bottom: usize,
};

pub fn detectShift(
    cur: []const u64,
    prev: []const u64,
    min_rows: usize,
    min_ratio: f32,
) ?Shift {
    if (cur.len != prev.len or cur.len == 0) return null;
    const n: isize = @intCast(cur.len);

    var best_shift: isize = 0;
    var best_matches: usize = 0;
    var best_compared: usize = 0;
    var s: isize = -max_animated_rows;
    while (s <= max_animated_rows) : (s += 1) {
        if (s == 0) continue;
        var matches: usize = 0;
        var compared: usize = 0;
        for (0..cur.len) |i| {
            const j = @as(isize, @intCast(i)) + s;
            if (j < 0 or j >= n) continue;
            compared += 1;
            if (cur[i] == prev[@intCast(j)]) matches += 1;
        }
        if (matches > best_matches) {
            best_matches = matches;
            best_compared = compared;
            best_shift = s;
        }
    }

    if (best_shift == 0 or best_compared == 0) return null;
    if (best_matches < min_rows) return null;
    const ratio = @as(f32, @floatFromInt(best_matches)) /
        @as(f32, @floatFromInt(best_compared));
    if (ratio < min_ratio) return null;

    // A screen that did not move matches *itself* best. Without this a static
    // screen of blank or repeating rows finds a spurious shift and animates
    // every frame, inventing motion that never happened.
    var same: usize = 0;
    for (cur, prev) |a, b| {
        if (a == b) same += 1;
    }
    if (same >= best_matches) return null;

    // Trim interface rows off both edges.
    //
    // A row an application pins -- nvim's tab line and status line, a prompt
    // box -- holds the same content across the frame. Scan inward from each
    // edge while that is true and animate what is left. Rows *matching the
    // shift* is the wrong test here: it also excludes rows newly exposed at
    // the trailing edge, which have no previous position but must still move
    // with the block, and leaving them behind tears that edge.
    //
    // Only the outermost unchanged rows are trimmed, so an unchanged row in
    // the middle of the content -- a blank line -- is unaffected.
    var top: usize = 0;
    while (top < cur.len and cur[top] == prev[top]) top += 1;
    if (top == cur.len) return null;
    var bottom: usize = cur.len - 1;
    while (bottom > top and cur[bottom] == prev[bottom]) bottom -= 1;

    return .{ .rows = best_shift, .top = top, .bottom = bottom };
}

test "detectShift: finds a clean shift and gets its sign right" {
    // prev rows 0..19; cur is prev scrolled up by 3, so cur[i] == prev[i+3].
    var prev: [20]u64 = undefined;
    for (&prev, 0..) |*v, i| v.* = 1000 + i;
    var cur: [20]u64 = undefined;
    for (&cur, 0..) |*v, i| v.* = 1000 + i + 3;
    try testing.expectEqual(@as(isize, 3), detectShift(&cur, &prev, 6, 0.6).?.rows);
}

test "detectShift: reports the other direction as negative" {
    var prev: [20]u64 = undefined;
    for (&prev, 0..) |*v, i| v.* = 1000 + i;
    var cur: [20]u64 = undefined;
    for (&cur, 0..) |*v, i| v.* = 1000 + i - 2;
    try testing.expectEqual(@as(isize, -2), detectShift(&cur, &prev, 6, 0.6).?.rows);
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

    const got = detectShift(&cur, &prev, 6, 0.6).?;
    try testing.expectEqual(@as(isize, 3), got.rows);
    try testing.expectEqual(@as(usize, 1), got.top);
    try testing.expectEqual(@as(usize, 17), got.bottom);
}

test "detectShift: a still screen is not a scroll" {
    // The failure this guards: a static screen finding a shift and animating
    // every frame forever.
    var rows: [20]u64 = undefined;
    for (&rows, 0..) |*v, i| v.* = 1000 + i;
    try testing.expect(detectShift(&rows, &rows, 6, 0.6) == null);
}

test "detectShift: a blank screen matches every shift and must be refused" {
    // Every row equal means every offset scores a perfect match. Believing one
    // would slide an empty screen sideways for no reason.
    const blank: [20]u64 = @splat(0);
    try testing.expect(detectShift(&blank, &blank, 6, 0.6) == null);
}

test "detectShift: repeating content does not invent a scroll" {
    // Alternating rows match at every even offset, and match themselves just
    // as well, so `same` has to veto it.
    var rows: [20]u64 = undefined;
    for (&rows, 0..) |*v, i| v.* = if (i % 2 == 0) 7 else 9;
    try testing.expect(detectShift(&rows, &rows, 6, 0.6) == null);
}

test "detectShift: an unrelated screen is not a scroll" {
    // A full repaint with different content -- switching buffers, say -- has
    // nothing in common and must not be animated.
    var prev: [20]u64 = undefined;
    for (&prev, 0..) |*v, i| v.* = 1000 + i;
    var cur: [20]u64 = undefined;
    for (&cur, 0..) |*v, i| v.* = 50_000 + i * 7;
    try testing.expect(detectShift(&cur, &prev, 6, 0.6) == null);
}

test "detectShift: too few matching rows is refused" {
    // Only three rows line up: below the confidence floor, so no animation.
    var prev: [20]u64 = undefined;
    for (&prev, 0..) |*v, i| v.* = 1000 + i;
    var cur: [20]u64 = undefined;
    for (&cur, 0..) |*v, i| v.* = if (i < 3) 1000 + i + 3 else 90_000 + i;
    try testing.expect(detectShift(&cur, &prev, 6, 0.6) == null);
}

test "detectShift: a shift larger than we animate is not reported" {
    var prev: [40]u64 = undefined;
    for (&prev, 0..) |*v, i| v.* = 1000 + i;
    var cur: [40]u64 = undefined;
    // Past max_animated_rows: a page jump, which snaps rather than slides.
    for (&cur, 0..) |*v, i| v.* = 1000 + i + max_animated_rows + 5;
    try testing.expect(detectShift(&cur, &prev, 6, 0.6) == null);
}

test "detectShift: mismatched lengths are refused rather than compared" {
    const a: [10]u64 = @splat(1);
    const b: [12]u64 = @splat(1);
    try testing.expect(detectShift(&a, &b, 6, 0.6) == null);
}

test "ScrollAnim: settles within the configured duration, not long after" {
    // The whole point of a *duration*: a one-row scroll at 60fps must be done
    // in the time asked for. Decaying a fraction of the remaining offset
    // instead stretches an 80ms setting into hundreds of milliseconds of
    // sub-pixel creep, which reads as smear rather than motion.
    var a: ScrollAnim = .{};
    a.push(-38, 1, 52, 10_000);
    var elapsed: f32 = 0;
    while (a.active() and elapsed < 1000) : (elapsed += 16) a.advance(16, 80);
    try testing.expect(!a.active());
    try testing.expect(elapsed <= 96);
}

test "ScrollAnim: eases out, so early frames move further than late ones" {
    // The property a person notices: leave the old position quickly, arrive at
    // the new one gently. A linear ramp arrives at full speed and stops dead.
    var a: ScrollAnim = .{};
    a.push(-100, 0, 10, 10_000);
    const start = a.offset_px;
    a.advance(10, 100);
    const first = @abs(a.offset_px - start);
    const before = a.offset_px;
    a.advance(10, 100);
    const second = @abs(a.offset_px - before);
    try testing.expect(first > second);
}

test "ScrollAnim: position comes from elapsed time, not accumulated frames" {
    // One long frame must land where several short ones would, so a dropped
    // frame does not leave the animation behind.
    var a: ScrollAnim = .{};
    var b: ScrollAnim = .{};
    a.push(-100, 0, 10, 10_000);
    b.push(-100, 0, 10, 10_000);
    a.advance(30, 100);
    b.advance(10, 100);
    b.advance(10, 100);
    b.advance(10, 100);
    try testing.expectApproxEqAbs(a.offset_px, b.offset_px, 0.001);
}

const testing = std.testing;

test "ScrollAnim: starts inactive" {
    const a: ScrollAnim = .{};
    try testing.expect(!a.active());
}

test "ScrollAnim: start below the visible threshold is a no-op" {
    var a: ScrollAnim = .{};
    a.push(0.1, 0, 10, 10_000);
    try testing.expect(!a.active());
}

test "ScrollAnim: advancing a full duration finishes it" {
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 10_000);
    try testing.expect(a.active());
    a.advance(80, 80);
    try testing.expect(!a.active());
    try testing.expectEqual(@as(f32, 0), a.offset_px);
}

test "ScrollAnim: a longer-than-duration frame does not overshoot past zero" {
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 10_000);
    // A stalled surface: the offset must land exactly on zero, never cross it
    // and animate back from the other side.
    a.advance(5000, 80);
    try testing.expectEqual(@as(f32, 0), a.offset_px);
}

test "ScrollAnim: decays monotonically toward zero without changing sign" {
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 10_000);
    var prev = a.offset_px;
    var i: usize = 0;
    while (i < 200 and a.active()) : (i += 1) {
        a.advance(16, 80);
        try testing.expect(a.offset_px <= 0); // never flips sign
        try testing.expect(@abs(a.offset_px) <= @abs(prev)); // never grows
        prev = a.offset_px;
    }
    try testing.expect(!a.active());
}

test "ScrollAnim: positive and negative decay symmetrically" {
    var up: ScrollAnim = .{};
    var down: ScrollAnim = .{};
    up.push(30, 0, 10, 10_000);
    down.push(-30, 0, 10, 10_000);
    for (0..3) |_| {
        up.advance(16, 80);
        down.advance(16, 80);
    }
    try testing.expectApproxEqAbs(up.offset_px, -down.offset_px, 0.001);
}

test "ScrollAnim: a scroll over a disjoint region replaces" {
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 10_000);
    a.advance(16, 80);
    a.push(40, 20, 30, 10_000);
    try testing.expectEqual(@as(f32, 40), a.offset_px);
    try testing.expectEqual(@as(f32, 20), a.top);
    try testing.expectEqual(@as(f32, 30), a.bottom);
}

test "ScrollAnim: a one-row region jitter keeps the pending displacement" {
    // tmux moves its scrolling region by a row between redraws. Treating that
    // as a different region discarded the offset mid-slide, and the content
    // snapped to the model instead of arriving there.
    var a: ScrollAnim = .{};
    a.push(-20, 1, 52, 10_000);
    a.push(-20, 2, 52, 10_000);
    try testing.expectEqual(@as(f32, -40), a.offset_px);
    try testing.expectEqual(@as(f32, 2), a.top);
}

test "ScrollAnim: successive scrolls over the same region accumulate" {
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 10_000);
    // Still behind by 20px when the model scrolls another 20: the display is
    // now behind by 40, not by 20.
    a.push(-20, 0, 10, 10_000);
    try testing.expectEqual(@as(f32, -40), a.offset_px);
}

test "ScrollAnim: opposing scrolls net out rather than compounding" {
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 10_000);
    a.push(20, 0, 10, 10_000);
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
        a.push(-cell_h, 1, 52, limit);
        a.advance(16, 80);
    }
    try testing.expect(@abs(a.offset_px) <= limit);
}

test "ScrollAnim: accumulation is capped by the limit" {
    var a: ScrollAnim = .{};
    for (0..100) |_| a.push(-20, 0, 10, 50);
    try testing.expectEqual(@as(f32, -50), a.offset_px);
}

test "ScrollAnim: zero or negative dt is ignored rather than reversing" {
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 10_000);
    const before = a.offset_px;
    a.advance(0, 80);
    a.advance(-5, 80);
    try testing.expectEqual(before, a.offset_px);
}

test "ScrollAnim: a zero duration does not divide by zero" {
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 10_000);
    a.advance(16, 0);
    try testing.expect(a.offset_px == -20);
}
