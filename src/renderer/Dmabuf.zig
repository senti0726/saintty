//! A DMABUF frame produced by exporting a GPU texture.
//! This may be used on apprts like GTK that require us to manually
//! export each frame and import them as textures in their UI scene graphs.
//!
//! Note that DMABUFs are independent of the graphics API used:
//! the OpenGL renderer allocates them with GBM, and Vulkan can
//! export them with a KHR external memory implementation. Therefore
//! this struct has to be placed parallel to the renderer
//! implementations.
pub const Dmabuf = @This();
pub const std = @import("std");

/// The maximum number of planes in a DMABUF that we support.
/// This matches the maximum found in apprts such as GTK.
pub const max_planes = 4;

/// Width of the texture in device pixels.
width: u32,

/// Height of the texture in device pixels.
height: u32,

/// DRM fourcc of the pixel format.
/// Ghostty renders RGBA/BGRA8 premultiplied.
fourcc: u32,

/// DRM modifier of the format.
modifier: u64,

/// Whether the data is premultiplied.
/// Ghostty's GL renderers output premultiplied alpha.
premultiplied: bool,

/// Where this frame differs from the frame exported before it
/// (`gtk-damage-tracking`). The apprt may hand its toolkit the frame as an
/// update of the last one, changed only here. Rectangles are in texture
/// rows, i.e. GL coordinates (origin bottom-left), not flipped.
damage: Damage = .everything,

/// The DMABUF planes for a presented frame. The DMABUF owns the fds
/// and must either call `deinit` manually, or pass them to an apprt
/// that consumes them.
planes: Planes,

pub const Planes = struct {
    /// Number of planes. Valid planes are `planes[0..count]`.
    count: u8,

    /// File descriptor for each plane.
    fds: [max_planes]std.posix.fd_t = @splat(-1),

    /// Offset into the DMABUF where each plane starts, in bytes.
    offsets: [max_planes]c_int = @splat(0),

    /// Strides of each plane, in bytes.
    strides: [max_planes]c_int = @splat(0),

    /// Close all valid fds.
    pub fn deinit(self: Planes) void {
        for (self.fds[0..self.count]) |fd| {
            if (fd >= 0) _ = std.posix.system.close(fd);
        }
    }

    /// Validate the current planes. If any plane failed to export
    /// and has an invalid FD, we close all the known valid FDs
    /// and bail.
    pub fn validate(self: Planes) error{BadDmabuf}!void {
        var n_valid: usize = 0;
        while (n_valid < self.count) : (n_valid += 1) {
            if (self.fds[n_valid] < 0) {
                for (self.fds[0..n_valid]) |bad| _ = std.posix.system.close(bad);
                return error.BadDmabuf;
            }
        }
    }
};

pub fn deinit(self: Dmabuf) void {
    self.planes.deinit();
}

/// A set of rectangles (x, y, width, height; GL coordinates, origin
/// bottom-left), or the whole frame.
pub const Damage = struct {
    pub const max_rects = 16;
    pub const everything: Damage = .{ .full = true };
    pub const nothing: Damage = .{ .full = false };

    full: bool,
    n: usize = 0,
    rects: [max_rects][4]u32 = undefined,

    /// Add a rectangle. Past `max_rects` the last one grows to cover the
    /// new one too: a bigger region than needed, never a smaller one.
    pub fn add(self: *Damage, r: [4]u32) void {
        if (self.full or r[2] == 0 or r[3] == 0) return;
        if (self.n == max_rects) {
            const l = &self.rects[max_rects - 1];
            const x0 = @min(l[0], r[0]);
            const y0 = @min(l[1], r[1]);
            const x1 = @max(l[0] + l[2], r[0] + r[2]);
            const y1 = @max(l[1] + l[3], r[1] + r[3]);
            l.* = .{ x0, y0, x1 - x0, y1 - y0 };
            return;
        }
        self.rects[self.n] = r;
        self.n += 1;
    }

    /// Everything either covers.
    pub fn merge(self: *Damage, other: Damage) void {
        if (other.full) {
            self.* = .everything;
            return;
        }
        for (other.slice()) |r| self.add(r);
    }

    pub fn slice(self: *const Damage) []const [4]u32 {
        return self.rects[0..self.n];
    }
};

test "Damage add past max_rects grows the last rect" {
    var d: Damage = .nothing;
    for (0..Damage.max_rects) |i| d.add(.{ @intCast(i * 10), 0, 5, 5 });
    d.add(.{ 500, 100, 10, 10 });
    try std.testing.expect(!d.full);
    try std.testing.expectEqual(Damage.max_rects, d.n);
    const l = d.rects[Damage.max_rects - 1];
    try std.testing.expectEqual([4]u32{ 150, 0, 360, 110 }, l);
    var e: Damage = .nothing;
    e.merge(d);
    try std.testing.expectEqual(d.n, e.n);
    e.merge(.everything);
    try std.testing.expect(e.full);
}
