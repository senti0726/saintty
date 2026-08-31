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

/// Below this many pixels there is nothing left to see. Holding a sub-pixel
/// offset would keep requesting frames forever for no visible benefit.
pub const min_offset_px: f32 = 0.5;

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
/// A scroll over a *different* region replaces, because the pending offset
/// describes rows that are no longer the ones moving.
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
    const base: f32 = if (self.active() and self.top == top and self.bottom == bottom)
        self.offset_px
    else
        0;

    const combined = std.math.clamp(base + offset_px, -@abs(limit), @abs(limit));
    self.offset_px = if (@abs(combined) < min_offset_px) 0 else combined;
    self.top = top;
    self.bottom = bottom;
}

pub fn stop(self: *ScrollAnim) void {
    self.offset_px = 0;
}

/// Advance the animation by `dt_ms`, retiring the displacement over
/// `duration_ms`.
///
/// Linear rather than exponential: a scroll has a definite end, and an
/// exponential tail leaves a fraction of a row hanging around looking like a
/// misaligned grid rather than motion. The rate is proportional to how far
/// this particular scroll had to travel, so a large jump does not crawl.
pub fn advance(self: *ScrollAnim, dt_ms: f32, duration_ms: f32) void {
    if (!self.active()) return;

    // A stalled or hidden surface can hand us a huge dt. Finishing early is
    // the right failure: the model is already correct, so snapping to it
    // shows the truth rather than a stale intermediate position.
    if (!(dt_ms > 0) or !(duration_ms > 0)) return;
    if (dt_ms >= duration_ms) {
        self.offset_px = 0;
        return;
    }

    const step = (dt_ms / duration_ms) * @abs(self.offset_px);
    if (@abs(self.offset_px) <= step) {
        self.offset_px = 0;
        return;
    }

    self.offset_px -= std.math.sign(self.offset_px) * step;
    if (@abs(self.offset_px) < min_offset_px) self.offset_px = 0;
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

test "ScrollAnim: a scroll over a different region replaces" {
    var a: ScrollAnim = .{};
    a.push(-20, 0, 10, 10_000);
    a.advance(16, 80);
    a.push(40, 2, 8, 10_000);
    try testing.expectEqual(@as(f32, 40), a.offset_px);
    try testing.expectEqual(@as(f32, 2), a.top);
    try testing.expectEqual(@as(f32, 8), a.bottom);
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
