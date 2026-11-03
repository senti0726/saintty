//! Graphics API wrapper for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const gl = @import("opengl");
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(OpenGL);

pub const GraphicsAPI = OpenGL;
pub const Target = @import("opengl/Target.zig");
pub const Frame = @import("opengl/Frame.zig");
pub const RenderPass = @import("opengl/RenderPass.zig");
pub const Pipeline = @import("opengl/Pipeline.zig");
const bufferpkg = @import("opengl/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("opengl/Sampler.zig");
pub const Texture = @import("opengl/Texture.zig");
pub const shaders = @import("opengl/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .glsl;
// The fragCoord for OpenGL shaders is +Y = up.
pub const custom_shader_y_is_down = false;

/// Because OpenGL's frame completion is always
/// sync, we have no need for multi-buffering.
pub const swap_chain_count = 1;

/// `custom-shader-cache` needs scissored render passes and textures that
/// persist between frames (a swap chain of one).
pub const custom_shader_cache_supported = true;

const log = std.log.scoped(.opengl);

/// We require at least OpenGL 4.3
pub const MIN_VERSION_MAJOR = 4;
pub const MIN_VERSION_MINOR = 3;

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The most recently presented target, in case we need to present it again.
last_target: ?Target = null,

/// PARTIAL PRESENT (`gtk-damage-tracking`). Normally the apprt hands us a
/// framebuffer whose contents are undefined, so `present` copies the whole
/// target into it and the apprt shows (and the compositor repaints) the whole
/// window, however little of it changed.
///
/// An apprt whose framebuffer still holds the frame presented before sets
/// `present_persistent` for the draw. `present` then copies only
/// `frame_damage` -- the rectangles the renderer says differ from the last
/// frame -- and records what it wrote in `presented`, which the apprt takes
/// afterwards to tell the toolkit how little there is to repaint.
present_persistent: bool = false,
/// What the frame being drawn changes in its target. The renderer narrows it
/// (`setFrameDamage`); anything that does not is the whole frame.
frame_damage: Damage = .everything,
/// What `present` has written since the apprt last took it.
presented: Damage = .nothing,
/// A frame was drawn but not presented (GL error): the framebuffer is behind
/// the target by more than the next frame's damage.
present_stale: bool = false,
/// `custom-shader-cache-debug = verify`: after every present, read back the
/// framebuffer and the target and compare them. Partial presents that leave
/// the framebuffer different from the target are counted and logged.
present_verify: bool = false,
present_verify_stats: struct { checked: u64 = 0, partial: u64 = 0, mismatched: u64 = 0 } = .{},

/// A set of rectangles (x, y, width, height; GL coordinates, origin
/// bottom-left), or the whole frame.
pub const Damage = struct {
    pub const max_rects = 12;
    pub const everything: Damage = .{ .full = true };
    pub const nothing: Damage = .{ .full = false };

    full: bool,
    n: usize = 0,
    rects: [max_rects][4]u32 = undefined,

    pub fn add(self: *Damage, r: [4]u32) void {
        if (self.full or r[2] == 0 or r[3] == 0) return;
        if (self.n == max_rects) {
            self.* = .everything;
            return;
        }
        self.rects[self.n] = r;
        self.n += 1;
    }

    pub fn slice(self: *const Damage) []const [4]u32 {
        return self.rects[0..self.n];
    }
};

/// NOTE: This is an error{}!OpenGL instead of just OpenGL for parity with
///       Metal, since it needs to be fallible so does this, even though it
///       can't actually fail.
pub fn init(alloc: Allocator, opts: rendererpkg.Options) error{}!OpenGL {
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
    };
}

pub fn deinit(self: *OpenGL) void {
    self.* = undefined;
}

/// 32-bit windows cross-compilation breaks with `.c` for some reason, so...
const gl_debug_proc_callconv =
    @typeInfo(
        @typeInfo(
            @typeInfo(
                gl.c.GLDEBUGPROC,
            ).optional.child,
        ).pointer.child,
    ).@"fn".calling_convention;

fn glDebugMessageCallback(
    src: gl.c.GLenum,
    typ: gl.c.GLenum,
    id: gl.c.GLuint,
    severity: gl.c.GLenum,
    len: gl.c.GLsizei,
    msg: [*c]const gl.c.GLchar,
    user_param: ?*const anyopaque,
) callconv(gl_debug_proc_callconv) void {
    _ = user_param;

    const src_str: []const u8 = switch (src) {
        gl.c.GL_DEBUG_SOURCE_API => "OpenGL API",
        gl.c.GL_DEBUG_SOURCE_WINDOW_SYSTEM => "Window System",
        gl.c.GL_DEBUG_SOURCE_SHADER_COMPILER => "Shader Compiler",
        gl.c.GL_DEBUG_SOURCE_THIRD_PARTY => "Third Party",
        gl.c.GL_DEBUG_SOURCE_APPLICATION => "User",
        gl.c.GL_DEBUG_SOURCE_OTHER => "Other",
        else => "Unknown",
    };

    const typ_str: []const u8 = switch (typ) {
        gl.c.GL_DEBUG_TYPE_ERROR => "Error",
        gl.c.GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR => "Deprecated Behavior",
        gl.c.GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR => "Undefined Behavior",
        gl.c.GL_DEBUG_TYPE_PORTABILITY => "Portability Issue",
        gl.c.GL_DEBUG_TYPE_PERFORMANCE => "Performance Issue",
        gl.c.GL_DEBUG_TYPE_MARKER => "Marker",
        gl.c.GL_DEBUG_TYPE_PUSH_GROUP => "Group Push",
        gl.c.GL_DEBUG_TYPE_POP_GROUP => "Group Pop",
        gl.c.GL_DEBUG_TYPE_OTHER => "Other",
        else => "Unknown",
    };

    const msg_str = msg[0..@intCast(len)];

    (switch (severity) {
        gl.c.GL_DEBUG_SEVERITY_HIGH => log.err(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_MEDIUM => log.warn(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_LOW => log.info(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_NOTIFICATION => log.debug(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        else => log.warn(
            "UNKNOWN SEVERITY [{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
    });
}

/// Prepares the provided GL context, loading it with glad.
fn prepareContext(getProcAddress: anytype) !void {
    const version = try gl.glad.load(getProcAddress);
    const major = gl.glad.versionMajor(@intCast(version));
    const minor = gl.glad.versionMinor(@intCast(version));
    errdefer gl.glad.unload();
    log.info("loaded OpenGL {}.{}", .{ major, minor });

    // Need to check version before trying to enable it
    if (major < MIN_VERSION_MAJOR or
        (major == MIN_VERSION_MAJOR and minor < MIN_VERSION_MINOR))
    {
        log.warn(
            "OpenGL version is too old. Ghostty requires OpenGL {d}.{d}",
            .{ MIN_VERSION_MAJOR, MIN_VERSION_MINOR },
        );
        return error.OpenGLOutdated;
    }

    // Enable debug output for the context.
    try gl.enable(gl.c.GL_DEBUG_OUTPUT);

    // Register our debug message callback with the OpenGL context.
    gl.glad.context.DebugMessageCallback.?(glDebugMessageCallback, null);

    // Enable SRGB framebuffer for linear blending support.
    try gl.enable(gl.c.GL_FRAMEBUFFER_SRGB);
}

/// This is called early right after surface creation.
pub fn surfaceInit(surface: *apprt.Surface) !void {
    _ = surface;

    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        // GTK uses global OpenGL context so we load from null.
        apprt.gtk,
        => try prepareContext(null),

        apprt.embedded => {
            // TODO(mitchellh): this does nothing today to allow libghostty
            // to compile for OpenGL targets but libghostty is strictly
            // broken for rendering on this platforms.
        },
    }

    // These are very noisy so this is commented, but easy to uncomment
    // whenever we need to check the OpenGL extension list
    // if (builtin.mode == .Debug) {
    //     var ext_iter = try gl.ext.iterator();
    //     while (try ext_iter.next()) |ext| {
    //         log.debug("OpenGL extension available name={s}", .{ext});
    //     }
    // }
}

/// This is called just prior to spinning up the renderer
/// thread for final main thread setup requirements.
pub fn finalizeSurfaceInit(self: *const OpenGL, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;
}

/// Callback called by renderer.Thread when it begins.
pub fn threadEnter(self: *const OpenGL, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;

    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.gtk => {
            // GTK doesn't support threaded OpenGL operations as far as I can
            // tell, so we use the renderer thread to setup all the state
            // but then do the actual draws and texture syncs and all that
            // on the main thread. As such, we don't do anything here.
        },

        apprt.embedded => {
            // TODO(mitchellh): this does nothing today to allow libghostty
            // to compile for OpenGL targets but libghostty is strictly
            // broken for rendering on this platforms.
        },
    }
}

/// Callback called by renderer.Thread when it exits.
pub fn threadExit(self: *const OpenGL) void {
    _ = self;

    switch (apprt.runtime) {
        else => @compileError("unsupported app runtime for OpenGL"),

        apprt.gtk => {
            // We don't need to do any unloading for GTK because we may
            // be sharing the global bindings with other windows.
        },

        apprt.embedded => {
            // TODO: see threadEnter
        },
    }
}

pub fn displayRealized(self: *const OpenGL) void {
    _ = self;

    switch (apprt.runtime) {
        apprt.gtk => prepareContext(null) catch |err| {
            log.warn(
                "Error preparing GL context in displayRealized, err={}",
                .{err},
            );
        },

        else => @compileError("only GTK should be calling displayRealized"),
    }
}

/// Actions taken before doing anything in `drawFrame`.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameStart(self: *OpenGL) void {
    // Until the renderer says otherwise the frame changes everything.
    self.frame_damage = .everything;
}

/// The frame being drawn differs from the one before only inside `rects`
/// (GL scissor rectangles). Only meaningful when every frame since the last
/// full one went through here or was whole.
pub fn setFrameDamage(self: *OpenGL, rects: []const ?[4]u32) void {
    var d: Damage = .nothing;
    for (rects) |r| d.add(r orelse {
        self.frame_damage = .everything;
        return;
    });
    self.frame_damage = d;
}

/// What has been presented since the last call, for the apprt.
pub fn takePresented(self: *OpenGL) Damage {
    defer self.presented = .nothing;
    return self.presented;
}

/// A drawn frame was not presented.
pub fn presentSkipped(self: *OpenGL) void {
    self.present_stale = true;
}

/// Actions taken after `drawFrame` is done.
///
/// Right now there's nothing we need to do for OpenGL.
pub fn drawFrameEnd(self: *OpenGL) void {
    _ = self;
}

pub fn initShaders(
    self: *const OpenGL,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = alloc;
    return try shaders.Shaders.init(
        self.alloc,
        custom_shaders,
    );
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const OpenGL) !struct { width: u32, height: u32 } {
    _ = self;
    var viewport: [4]gl.c.GLint = undefined;
    gl.glad.context.GetIntegerv.?(gl.c.GL_VIEWPORT, &viewport);
    return .{
        .width = @intCast(viewport[2]),
        .height = @intCast(viewport[3]),
    };
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const OpenGL, width: usize, height: usize) !Target {
    return Target.init(.{
        .internal_format = if (self.blending.isLinear()) .srgba else .rgba,
        .width = width,
        .height = height,
    });
}

/// Present the provided target.
pub fn present(self: *OpenGL, target: Target) !void {
    // In order to present a target we blit it to the default framebuffer.

    // We disable GL_FRAMEBUFFER_SRGB while doing this blit, otherwise the
    // values may be linearized as they're copied, but even though the draw
    // framebuffer has a linear internal format, the values in it should be
    // sRGB, not linear!
    try gl.disable(gl.c.GL_FRAMEBUFFER_SRGB);
    defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch |err| {
        log.err("Error re-enabling GL_FRAMEBUFFER_SRGB, err={}", .{err});
    };

    // Bind the target for reading.
    const fbobind = try target.framebuffer.bind(.read);
    defer fbobind.unbind();

    // Blit: the rectangles that changed if the framebuffer still holds the
    // last frame, everything otherwise.
    const partial = self.present_persistent and !self.present_stale and
        !self.frame_damage.full and self.last_target != null and
        self.last_target.?.framebuffer.id == target.framebuffer.id;
    if (partial) {
        // GHOSTTY_PRESENT_BREAK=1 drops the first rectangle of every partial
        // present, to show that `present_verify` can fail.
        const skip: usize = if (self.present_verify and
            std.c.getenv("GHOSTTY_PRESENT_BREAK") != null) 1 else 0;
        for (self.frame_damage.slice(), 0..) |r, i| {
            if (i < skip) continue;
            const x0: gl.c.GLint = @intCast(@min(r[0], target.width));
            const y0: gl.c.GLint = @intCast(@min(r[1], target.height));
            const x1: gl.c.GLint = @intCast(@min(r[0] + r[2], target.width));
            const y1: gl.c.GLint = @intCast(@min(r[1] + r[3], target.height));
            if (x1 <= x0 or y1 <= y0) continue;
            gl.glad.context.BlitFramebuffer.?(
                x0,
                y0,
                x1,
                y1,
                x0,
                y0,
                x1,
                y1,
                gl.c.GL_COLOR_BUFFER_BIT,
                gl.c.GL_NEAREST,
            );
            self.presented.add(.{
                @intCast(x0),
                @intCast(y0),
                @intCast(x1 - x0),
                @intCast(y1 - y0),
            });
        }
    } else {
        gl.glad.context.BlitFramebuffer.?(
            0,
            0,
            @intCast(target.width),
            @intCast(target.height),
            0,
            0,
            @intCast(target.width),
            @intCast(target.height),
            gl.c.GL_COLOR_BUFFER_BIT,
            gl.c.GL_NEAREST,
        );
        self.presented = .everything;
        self.present_stale = false;
    }
    if (self.present_verify) self.verifyPresent(target, partial);

    // Debugging aid: GHOSTTY_FRAME_DUMP=<file> appends every presented frame.
    dumpFrame(target);

    // Keep track of this target in case we need to repeat it.
    self.last_target = target;
}

/// FRAME DUMP (debugging aid). With `GHOSTTY_FRAME_DUMP=<file>` in the
/// environment, every presented frame is shrunk to a third on the GPU and
/// appended to that file: a 16-byte header (u64 monotonic microseconds, u32
/// width, u32 height) then RGBA rows, bottom row first. Screen recorders
/// cannot be scripted here (OBS's PipeWire capture asks with a dialog every
/// time) and sample at their own rate; this is exactly what Ghostty drew, one
/// entry per frame, which is what visual scroll bugs needed (a figure torn for
/// one frame). `tools/scroll-harness/fast/frames.py` unpacks it. Off unless
/// set; the read-back stalls the GPU, so timing under it is not representative.
const FrameDump = struct {
    tried: bool = false,
    fd: c_int = -1,
    fbo: gl.c.GLuint = 0,
    rbo: gl.c.GLuint = 0,
    w: i32 = 0,
    h: i32 = 0,
    buf: []u8 = &.{},
    // Two pixel-pack buffers: this frame's read-back goes into one while the
    // other (last frame's) is mapped and written out, so the GPU never has
    // to finish a frame before the next is drawn. A synchronous read-back
    // cost enough to change the animation it was recording (smooth% 94 ->
    // 64 on a fast wheel spin).
    pbo: [2]gl.c.GLuint = .{ 0, 0 },
    pbo_us: [2]u64 = .{ 0, 0 },
    pbo_full: [2]bool = .{ false, false },
    next: usize = 0,
};
var frame_dump: FrameDump = .{};

fn dumpFrame(target: Target) void {
    const d = &frame_dump;
    if (!d.tried) {
        d.tried = true;
        const path = std.c.getenv("GHOSTTY_FRAME_DUMP") orelse return;
        d.fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (d.fd < 0) log.warn("frame dump: cannot open {s}", .{path});
    }
    if (d.fd < 0) return;
    const ctx = gl.glad.context;
    const w: i32 = @intCast(@max(1, target.width / 3));
    const h: i32 = @intCast(@max(1, target.height / 3));
    var prev_draw: gl.c.GLint = 0;
    var prev_read: gl.c.GLint = 0;
    ctx.GetIntegerv.?(gl.c.GL_DRAW_FRAMEBUFFER_BINDING, &prev_draw);
    ctx.GetIntegerv.?(gl.c.GL_READ_FRAMEBUFFER_BINDING, &prev_read);
    defer {
        ctx.BindFramebuffer.?(gl.c.GL_DRAW_FRAMEBUFFER, @intCast(prev_draw));
        ctx.BindFramebuffer.?(gl.c.GL_READ_FRAMEBUFFER, @intCast(prev_read));
    }
    if (d.fbo == 0) {
        ctx.GenFramebuffers.?(1, &d.fbo);
        ctx.GenRenderbuffers.?(1, &d.rbo);
        ctx.GenBuffers.?(2, &d.pbo);
    }
    if (d.w != w or d.h != h) {
        ctx.BindRenderbuffer.?(gl.c.GL_RENDERBUFFER, d.rbo);
        ctx.RenderbufferStorage.?(gl.c.GL_RENDERBUFFER, gl.c.GL_RGBA8, w, h);
        ctx.BindFramebuffer.?(gl.c.GL_DRAW_FRAMEBUFFER, d.fbo);
        ctx.FramebufferRenderbuffer.?(gl.c.GL_DRAW_FRAMEBUFFER, gl.c.GL_COLOR_ATTACHMENT0, gl.c.GL_RENDERBUFFER, d.rbo);
        if (d.buf.len > 0) std.heap.page_allocator.free(d.buf);
        d.buf = std.heap.page_allocator.alloc(u8, 16) catch {
            d.buf = &.{};
            return;
        };
        for (d.pbo) |pbo| {
            ctx.BindBuffer.?(gl.c.GL_PIXEL_PACK_BUFFER, pbo);
            ctx.BufferData.?(gl.c.GL_PIXEL_PACK_BUFFER, @intCast(w * h * 4), null, gl.c.GL_STREAM_READ);
        }
        ctx.BindBuffer.?(gl.c.GL_PIXEL_PACK_BUFFER, 0);
        d.pbo_full = .{ false, false };
        d.w = w;
        d.h = h;
    }
    if (d.buf.len == 0) return;
    // The target is bound for reading (see `present`).
    ctx.BindFramebuffer.?(gl.c.GL_DRAW_FRAMEBUFFER, d.fbo);
    ctx.BlitFramebuffer.?(0, 0, @intCast(target.width), @intCast(target.height), 0, 0, w, h, gl.c.GL_COLOR_BUFFER_BIT, gl.c.GL_LINEAR);
    ctx.BindFramebuffer.?(gl.c.GL_READ_FRAMEBUFFER, d.fbo);
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const us: u64 = @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
    // Start this frame's read-back into one buffer (returns at once)...
    const i = d.next;
    ctx.BindBuffer.?(gl.c.GL_PIXEL_PACK_BUFFER, d.pbo[i]);
    ctx.ReadPixels.?(0, 0, w, h, gl.c.GL_RGBA, gl.c.GL_UNSIGNED_BYTE, null);
    d.pbo_us[i] = us;
    d.pbo_full[i] = true;
    // ...and write out the other, filled a frame ago and long since done.
    const o = 1 - i;
    if (d.pbo_full[o]) {
        ctx.BindBuffer.?(gl.c.GL_PIXEL_PACK_BUFFER, d.pbo[o]);
        const ptr = ctx.MapBuffer.?(gl.c.GL_PIXEL_PACK_BUFFER, gl.c.GL_READ_ONLY);
        if (ptr) |p| {
            std.mem.writeInt(u64, d.buf[0..8], d.pbo_us[o], .little);
            std.mem.writeInt(u32, d.buf[8..12], @intCast(w), .little);
            std.mem.writeInt(u32, d.buf[12..16], @intCast(h), .little);
            _ = std.c.write(d.fd, d.buf.ptr, 16);
            _ = std.c.write(d.fd, @ptrCast(p), @intCast(w * h * 4));
            _ = ctx.UnmapBuffer.?(gl.c.GL_PIXEL_PACK_BUFFER);
        }
        d.pbo_full[o] = false;
    }
    ctx.BindBuffer.?(gl.c.GL_PIXEL_PACK_BUFFER, 0);
    d.next = o;
}

/// Read a target back as RGBA8, for `custom-shader-cache-debug = verify`.
/// `buf` must hold width * height * 4 bytes.
pub fn readTarget(self: *OpenGL, target: Target, buf: []u8) !void {
    _ = self;
    const fbobind = try target.framebuffer.bind(.read);
    defer fbobind.unbind();
    gl.glad.context.ReadPixels.?(
        0,
        0,
        @intCast(target.width),
        @intCast(target.height),
        gl.c.GL_RGBA,
        gl.c.GL_UNSIGNED_BYTE,
        buf.ptr,
    );
}

/// `present_verify`: the framebuffer just presented into must equal the
/// target, pixel for pixel. The target is still bound for reading.
fn verifyPresent(self: *OpenGL, target: Target, partial: bool) void {
    const alloc = std.heap.c_allocator;
    const bytes = target.width * target.height * 4;
    const want = alloc.alloc(u8, bytes * 2) catch return;
    defer alloc.free(want);
    const got = want[bytes..];
    const ctx = &gl.glad.context;
    const w: gl.c.GLsizei = @intCast(target.width);
    const h: gl.c.GLsizei = @intCast(target.height);
    ctx.ReadPixels.?(0, 0, w, h, gl.c.GL_RGBA, gl.c.GL_UNSIGNED_BYTE, want.ptr);
    var draw: gl.c.GLint = 0;
    var read: gl.c.GLint = 0;
    ctx.GetIntegerv.?(gl.c.GL_DRAW_FRAMEBUFFER_BINDING, &draw);
    ctx.GetIntegerv.?(gl.c.GL_READ_FRAMEBUFFER_BINDING, &read);
    ctx.BindFramebuffer.?(gl.c.GL_READ_FRAMEBUFFER, @intCast(draw));
    ctx.ReadPixels.?(0, 0, w, h, gl.c.GL_RGBA, gl.c.GL_UNSIGNED_BYTE, got.ptr);
    ctx.BindFramebuffer.?(gl.c.GL_READ_FRAMEBUFFER, @intCast(read));

    const st = &self.present_verify_stats;
    st.checked += 1;
    if (partial) st.partial += 1;
    if (!std.mem.eql(u8, want[0..bytes], got)) {
        st.mismatched += 1;
        var px: u64 = 0;
        var i: usize = 0;
        while (i < bytes) : (i += 4) {
            if (!std.mem.eql(u8, want[i..][0..4], got[i..][0..4])) px += 1;
        }
        log.warn("present MISMATCH px={} partial={} rects={}", .{ px, partial, self.frame_damage.n });
    }
    if (st.checked % 200 == 0) log.info(
        "present-verify checked={} partial={} mismatched={}",
        .{ st.checked, st.partial, st.mismatched },
    );
}

/// Present the last presented target again.
pub fn presentLastTarget(self: *OpenGL) !void {
    // A framebuffer that kept the last frame already shows it.
    if (self.present_persistent and !self.present_stale and
        self.last_target != null) return;
    self.frame_damage = .everything;
    if (self.last_target) |target| try self.present(target);
}

/// Called when the renderer released its GPU resources; the last
/// presented target is deinited with them so we must drop our copy.
pub fn gpuResourcesReleased(self: *OpenGL) void {
    self.last_target = null;
}

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: OpenGL) bufferpkg.Options {
    _ = self;
    return .{
        .target = .array,
        .usage = .dynamic_draw,
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: OpenGL) Texture.Options {
    _ = self;
    return .{
        .format = .rgba,
        .internal_format = .srgba,
        .target = .@"2D",
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Returns the options to use when constructing samplers.
pub inline fn samplerOptions(self: OpenGL) Sampler.Options {
    _ = self;
    return .{
        .min_filter = .linear,
        .mag_filter = .linear,
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(self: ImageTextureFormat) gl.Texture.Format {
        return switch (self) {
            .gray => .red,
            .rgba => .rgba,
            .bgra => .bgra,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: OpenGL,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    _ = self;
    return .{
        .format = format.toPixelFormat(),
        .internal_format = if (srgb) .srgba else .rgba,
        .target = .@"2D",
        // TODO: Generate mipmaps for image textures and use
        //       linear_mipmap_linear filtering so that they
        //       look good even when scaled way down.
        .min_filter = .linear,
        .mag_filter = .linear,
        // TODO: Separate out background image options, use
        //       repeating coordinate modes so we don't have
        //       to do the modulus in the shader.
        .wrap_s = .clamp_to_edge,
        .wrap_t = .clamp_to_edge,
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const OpenGL,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    _ = self;
    const format: gl.Texture.Format, const internal_format: gl.Texture.InternalFormat =
        switch (atlas.format) {
            .grayscale => .{ .red, .red },
            .bgra => .{ .bgra, .srgba },
            else => @panic("unsupported atlas format for OpenGL texture"),
        };

    return try Texture.init(
        .{
            .format = format,
            .internal_format = internal_format,
            .target = .Rectangle,
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *const OpenGL,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target is presented via the provided renderer's API when completed.
    target: *Target,
) !Frame {
    _ = self;
    return try Frame.begin(.{}, renderer, target);
}
