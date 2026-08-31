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

/// Begin an animation displaced by `offset_px`, covering rows [top, bottom].
///
/// A scroll arriving mid-animation supersedes it rather than queueing: the
/// animation can only ever chase the latest position, so there is nothing to
/// be gained by remembering where it used to be going.
pub fn start(self: *ScrollAnim, offset_px: f32, top: f32, bottom: f32) void {
    self.* = .{
        .offset_px = if (@abs(offset_px) < min_offset_px) 0 else offset_px,
        .top = top,
        .bottom = bottom,
    };
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
    a.start(0.1, 0, 10);
    try testing.expect(!a.active());
}

test "ScrollAnim: advancing a full duration finishes it" {
    var a: ScrollAnim = .{};
    a.start(-20, 0, 10);
    try testing.expect(a.active());
    a.advance(80, 80);
    try testing.expect(!a.active());
    try testing.expectEqual(@as(f32, 0), a.offset_px);
}

test "ScrollAnim: a longer-than-duration frame does not overshoot past zero" {
    var a: ScrollAnim = .{};
    a.start(-20, 0, 10);
    // A stalled surface: the offset must land exactly on zero, never cross it
    // and animate back from the other side.
    a.advance(5000, 80);
    try testing.expectEqual(@as(f32, 0), a.offset_px);
}

test "ScrollAnim: decays monotonically toward zero without changing sign" {
    var a: ScrollAnim = .{};
    a.start(-20, 0, 10);
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
    up.start(30, 0, 10);
    down.start(-30, 0, 10);
    for (0..3) |_| {
        up.advance(16, 80);
        down.advance(16, 80);
    }
    try testing.expectApproxEqAbs(up.offset_px, -down.offset_px, 0.001);
}

test "ScrollAnim: a new scroll supersedes one in flight" {
    var a: ScrollAnim = .{};
    a.start(-20, 0, 10);
    a.advance(16, 80);
    a.start(40, 2, 8);
    try testing.expectEqual(@as(f32, 40), a.offset_px);
    try testing.expectEqual(@as(f32, 2), a.top);
    try testing.expectEqual(@as(f32, 8), a.bottom);
}

test "ScrollAnim: zero or negative dt is ignored rather than reversing" {
    var a: ScrollAnim = .{};
    a.start(-20, 0, 10);
    const before = a.offset_px;
    a.advance(0, 80);
    a.advance(-5, 80);
    try testing.expectEqual(before, a.offset_px);
}

test "ScrollAnim: a zero duration does not divide by zero" {
    var a: ScrollAnim = .{};
    a.start(-20, 0, 10);
    a.advance(16, 0);
    try testing.expect(a.offset_px == -20);
}
