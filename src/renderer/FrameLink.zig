//! Vsync for apprts that composite our frames on their own frame clock
//! (GTK). The macOS equivalent is DisplayLink.zig.
//!
//! Without it the render thread draws the moment anything changes, so on a
//! 60 Hz display it may draw two or three frames per refresh at arbitrary
//! times and the compositor shows whichever finished last. A scroll
//! animation sampled at those arbitrary times moves unevenly from one
//! refresh to the next (smooth% 99 -> 79 for a held j, 2026-11-10).
//!
//! With the link enabled the render thread never draws on its own. It
//! marks a frame as `wanted` (and wakes the apprt if the link was idle);
//! the apprt's frame clock tick then calls `tick`, which asks the render
//! thread to draw and returns at once. The finished frame is pushed to the
//! apprt as usual and shown on the next refresh. A tick with nothing wanted
//! stops the apprt's ticking, so an idle terminal costs nothing.
//!
//! `tick` must not wait for the draw. Blocking the GTK main thread in the
//! tick (up to 10 ms, to show the frame in the same refresh) made GTK's
//! frame clock tick irregularly -- 67 ticks/s on a 60 Hz display, some 2-4
//! ms apart -- and smooth% stayed ~90. Without the wait it ticks at exactly
//! the refresh rate and a held j measures 100% (2026-11-11).
const FrameLink = @This();

const std = @import("std");
const global = @import("../global.zig");
const xev = global.xev;

/// Draws are paced by the apprt's ticks. Set by the render thread on loop
/// enter, cleared on loop exit.
enabled: std.atomic.Value(bool) = .init(false),

/// A frame is pending: the next tick draws it.
wanted: std.atomic.Value(bool) = .init(false),

/// When the frame drawn for the latest tick will be on screen, in ns on
/// CLOCK_MONOTONIC (zig's `.awake` on Linux, GLib's monotonic time). 0
/// until the first tick. Animations sample this rather than the time the
/// draw happens to start: draws start late by a varying amount (the
/// render thread may still be busy with terminal output), but the frames
/// are shown exactly one refresh apart, so this is the time they are seen.
present_ns: std.atomic.Value(u64) = .init(0),

/// The render thread's draw_now, set on loop enter.
draw_now: ?*xev.Async = null,

/// Render thread: a frame should be drawn on the next tick. Returns true if
/// the link was idle, so the caller must wake the apprt to start ticking.
pub fn want(self: *FrameLink) bool {
    return !self.wanted.swap(true, .acq_rel);
}

/// Render thread: a draw finished. `more` keeps the ticks coming (an
/// animation is running).
pub fn frameDone(self: *FrameLink, more: bool) void {
    if (more) self.wanted.store(true, .release);
}

/// The time animations should be sampled at for the frame being drawn,
/// or null when the link is not pacing draws.
pub fn animTime(self: *const FrameLink) ?std.Io.Timestamp {
    if (!self.enabled.load(.acquire)) return null;
    const ns = self.present_ns.load(.acquire);
    if (ns == 0) return null;
    return .{ .nanoseconds = ns };
}

/// Apprt main thread, once per frame clock tick. Returns false when nothing
/// is wanted: the apprt stops ticking until the next wake. Otherwise asks
/// the render thread for a draw, to be shown at `present_ns` (the frame
/// clock's prediction for the next refresh), and returns without waiting.
pub fn tick(self: *FrameLink, present_ns: u64) bool {
    if (!self.enabled.load(.acquire)) return false;
    if (!self.wanted.swap(false, .acq_rel)) return false;
    const draw_now = self.draw_now orelse return false;
    self.present_ns.store(present_ns, .release);
    draw_now.notify() catch {};
    return true;
}
