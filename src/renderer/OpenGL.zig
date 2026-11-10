//! Graphics API wrapper for OpenGL.
pub const OpenGL = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const gl = @import("opengl");
const egl = gl.egl;
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(OpenGL);
const Dmabuf = @import("Dmabuf.zig");
pub const Device = @import("opengl/Device.zig");

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

/// Triple-buffering gives the GPU room to pipeline renders without
/// having to wait on the apprt consuming previous frames.
pub const swap_chain_count = 3;

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

/// The shared render device.
device: *const Device,

egl_context: *gl.egl.Context,

/// PARTIAL PRESENT (`gtk-damage-tracking`, `custom-shader-cache`).
///
/// Each frame is drawn into one of `swap_chain_count` targets and exported
/// by blitting the target into its export texture. Two things narrow that:
///
///   `frame_damage`: where this frame differs from the frame before it. It
///   rides on the exported DMABUF so the apprt can hand the toolkit the new
///   texture as an update of the last one, changed only there.
///
///   `slot_damage`: where this frame differs from what this target's export
///   texture last held (the frame drawn into the same slot, a few frames
///   ago). The export blit copies only that, when the export texture is
///   known to hold that frame (`export_current`).
///
/// Both are the whole frame unless the renderer says otherwise
/// (`setFrameDamage`) for the frame being drawn.
frame_damage: Damage = .everything,
slot_damage: Damage = .everything,
/// A drawn frame never reached the apprt: the next one exported differs
/// from what the apprt last saw by more than its own damage.
present_stale: bool = false,
/// Export textures whose contents are the last frame drawn into their
/// target, by GL texture id. Anything else is exported in full.
export_current: [swap_chain_count]gl.c.GLuint = @splat(0),

pub const Damage = Dmabuf.Damage;

pub fn init(
    alloc: Allocator,
    device: *const Device,
    opts: rendererpkg.Options,
) !OpenGL {
    const display = device.display;

    // Bind to OpenGL API explicitly before we create the context,
    // as otherwise it might fallback to OpenGL ES
    try egl.bindApi(egl.c.EGL_OPENGL_API);

    // Create our context. Contexts are surface-scoped because a
    // context can only be current on one thread at a time.
    const context = egl.Context.create(display, device.config, null, &.{
        egl.c.EGL_CONTEXT_MAJOR_VERSION,       MIN_VERSION_MAJOR,
        egl.c.EGL_CONTEXT_MINOR_VERSION,       MIN_VERSION_MINOR,
        egl.c.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.c.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
    }) catch |err| {
        log.warn("failed to create EGL context err={}", .{err});
        return err;
    };
    errdefer context.destroy(display) catch {};

    display.makeCurrent(null, null, context) catch |err| {
        log.warn("failed to make EGL context current err={}", .{err});
        return err;
    };

    // Release current so that the main thread
    // doesn't hold onto the GL context forever.
    defer display.releaseCurrent();

    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .device = device,
        .egl_context = context,
    };
}

pub fn deinit(self: *OpenGL) void {
    self.device.display.releaseCurrent();
    self.egl_context.destroy(self.device.display) catch {};
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
    ).@"fn".attrs.@"callconv";

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

/// Callback called by renderer.Thread when it begins. Called on the render
/// thread. The EGL context was created at `init` time on the main thread;
/// here we (re)bind it to this thread and load the thread-local glad
/// function pointers so all subsequent GL work on this thread is valid.
pub fn threadEnter(self: *OpenGL, surface: *apprt.Surface) !void {
    _ = surface;
    try self.device.display.makeCurrent(null, null, self.egl_context);
    // Load our function pointers for this thread's threadlocal.
    try prepareContext(&gl.egl.getProcAddress);
}

/// Callback called by renderer.Thread when it exits. Called on the render
/// thread; unbinds the context from this thread so it can be destroyed on
/// the main thread.
pub fn threadExit(self: *OpenGL) void {
    self.device.display.releaseCurrent();
    gl.glad.unload();
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

/// Set the GL viewport to cover the given size in device pixels.
///
/// This used to be automatically called by the GtkGLArea upon resizing,
/// but now we need to do this manually.
pub fn setViewport(self: *const OpenGL, width: u32, height: u32) void {
    _ = self;
    gl.viewport(0, 0, @intCast(width), @intCast(height)) catch |err| {
        log.warn("failed to set OpenGL viewport err={}", .{err});
    };
}

/// Actions taken before doing anything in `drawFrame`.
pub fn drawFrameStart(self: *OpenGL) void {
    // Until the renderer says otherwise the frame changes everything.
    self.frame_damage = .everything;
    self.slot_damage = .everything;
}

/// The frame being drawn differs from the frame before it only inside
/// `own`, and from the frame last drawn into the same target only inside
/// `slot` (GL rectangles, origin bottom-left).
pub fn setFrameDamage(self: *OpenGL, own: Damage, slot: Damage) void {
    self.frame_damage = own;
    self.slot_damage = slot;
}

/// A drawn frame was not presented.
pub fn presentSkipped(self: *OpenGL) void {
    self.present_stale = true;
}

fn exportIsCurrent(self: *const OpenGL, id: gl.c.GLuint) bool {
    return id != 0 and std.mem.indexOfScalar(gl.c.GLuint, &self.export_current, id) != null;
}

fn setExportCurrent(self: *OpenGL, id: gl.c.GLuint, current: bool) void {
    if (std.mem.indexOfScalar(gl.c.GLuint, &self.export_current, id)) |i| {
        if (!current) self.export_current[i] = 0;
        return;
    }
    if (!current) return;
    // A free slot, else forget the oldest (GL reuses ids of deleted
    // textures, so stale ids must not pile up).
    const i = std.mem.indexOfScalar(gl.c.GLuint, &self.export_current, 0) orelse 0;
    if (i == 0 and self.export_current[0] != 0) {
        std.mem.copyForwards(gl.c.GLuint, self.export_current[0 .. swap_chain_count - 1], self.export_current[1..]);
        self.export_current[swap_chain_count - 1] = id;
        return;
    }
    self.export_current[i] = id;
}

/// Forget every export texture: targets were rebuilt or released.
pub fn exportsInvalidated(self: *OpenGL) void {
    self.export_current = @splat(0);
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

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const OpenGL, width: usize, height: usize) !Target {
    _ = self;
    return Target.init(.{
        .width = width,
        .height = height,
    });
}

/// Export a rendered target. Caller takes ownership
/// of the frame and is responsible for freeing it.
///
/// This runs on the render thread.
pub fn present(
    self: *OpenGL,
    target: Target,
    presentation_health: rendererpkg.Health,
) !ExportedFrame {
    // Debugging aid: GHOSTTY_FRAME_DUMP=<file> appends every presented frame.
    dumpFrame(target);

    const export_id = target.export_texture.id;

    // We only export DMABUFs when the apprt can present them.
    // Otherwise, use CPU buffers.
    if (presentation_health == .healthy) {
        // Copy only what changed since this export texture was last
        // filled, when it holds exactly that frame.
        const rects: ?[]const [4]u32 = if (!self.slot_damage.full and
            self.exportIsCurrent(export_id)) self.slot_damage.slice() else null;
        if (target.exportDmabuf(self.device.display, self.egl_context, rects)) |dmabuf_| {
            var dmabuf = dmabuf_;
            dmabuf.damage = if (self.present_stale) .everything else self.frame_damage;
            self.present_stale = false;
            self.setExportCurrent(export_id, true);
            return .{ .dmabuf = dmabuf };
        } else |_| {
            log.warn("failed to export DMABUF, falling back to CPU presentation", .{});
        }
    }

    // The export texture was not (fully) written.
    self.setExportCurrent(export_id, false);
    self.present_stale = false;

    return .{ .memory = .{
        .width = @intCast(target.width),
        .height = @intCast(target.height),
        .pixels = try target.readPixelsAlloc(self.alloc),
        .alloc = self.alloc,
    } };
}

/// A finished frame exported for presentation by the apprt.
pub const ExportedFrame = union(enum) {
    dmabuf: Dmabuf,
    memory: Memory,

    /// RGBA8 pixel data with premultiplied alpha, tightly packed
    /// (`width * 4` bytes per row), in CPU memory.
    pub const Memory = struct {
        width: u32,
        height: u32,
        pixels: []u8,
        alloc: Allocator,

        pub fn deinit(self: Memory) void {
            self.alloc.free(self.pixels);
        }
    };

    pub fn deinit(self: ExportedFrame) void {
        switch (self) {
            .dmabuf => |v| v.deinit(),
            .memory => |v| v.deinit(),
        }
    }
};

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
// Per render thread: each surface draws on its own.
threadlocal var frame_dump: FrameDump = .{};

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
    // Copy the stored (sRGB-encoded) values verbatim, as the export does.
    gl.disable(gl.c.GL_FRAMEBUFFER_SRGB) catch {};
    defer gl.enable(gl.c.GL_FRAMEBUFFER_SRGB) catch {};
    ctx.BindFramebuffer.?(gl.c.GL_READ_FRAMEBUFFER, target.framebuffer.id);
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
        .target = .@"2d",
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
        .target = .@"2d",
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
            .target = .rectangle,
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
