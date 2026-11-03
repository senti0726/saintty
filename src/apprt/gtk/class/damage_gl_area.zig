const std = @import("std");
const cairo = @import("cairo");
const gdk = @import("gdk");
const gl = @import("opengl");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const Damage = @import("../../../renderer/OpenGL.zig").Damage;

const log = std.log.scoped(.gtk_ghostty_gl_area);

/// A `GtkGLArea` that can tell GTK how little of a frame changed.
///
/// The stock widget renders every frame into a fresh texture, so GTK
/// repaints the widget's whole rectangle and hands the compositor the whole
/// window as damage -- a cursor effect two cells wide costs a full-window
/// blit here and a full-window composite in KWin, 120 times a second.
///
/// In damage mode (`setDamageTracking`) this widget keeps ONE texture for as
/// long as the size holds and renders into it itself: the `render` handler
/// draws only what changed and reports the rectangles (`noteDamage`), and the
/// texture is handed to GTK as an update of the one before, changed in that
/// region only (`gdk_gl_texture_builder_set_update_region`). GTK repaints and
/// submits just those rectangles.
///
/// Outside damage mode it is a plain `GtkGLArea`.
pub const DamageGLArea = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.GLArea;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyGLArea",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// Damage mode was asked for. It also promises that the renderer
        /// has loaded its GL functions on this thread.
        tracking: bool = false,

        /// Our framebuffer and its texture (0 = none), and the texture's size.
        fbo: c_uint = 0,
        tex: c_uint = 0,
        width: c_int = 0,
        height: c_int = 0,

        /// The size last announced with `resize`.
        resize_width: c_int = 0,
        resize_height: c_int = 0,

        /// The texture holds the frame GTK was last given, so the next one
        /// may be described as a change to it.
        persistent: bool = false,
        /// What GTK was last given.
        last: ?*gdk.Texture = null,
        /// What the `render` handler said it changed this frame.
        pending: Damage = .everything,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        self.private().* = .{};
    }

    /// Turn damage mode on or off. Only turn it on once the renderer is
    /// initialized: from then on the next frame uses the GL functions it
    /// loaded.
    pub fn setDamageTracking(self: *Self, v: bool) void {
        const priv = self.private();
        if (priv.tracking == v) return;
        priv.tracking = v;
        priv.persistent = false;
        self.as(gtk.GLArea).queueRender();
    }

    /// For the `render` handler, before it draws: whether the framebuffer
    /// still holds the frame presented before.
    pub fn framePersistent(self: *Self) bool {
        const priv = self.private();
        return priv.tracking and priv.persistent;
    }

    /// For the `render` handler, after it drew: what it changed.
    pub fn noteDamage(self: *Self, d: Damage) void {
        self.private().pending = d;
    }

    fn snapshot(self: *Self, snap: *gtk.Snapshot) callconv(.c) void {
        if (!self.snapshotTracked(snap)) {
            // The stock path, which shares nothing with ours.
            self.private().persistent = false;
            self.dropLast();
            gtk.Widget.virtual_methods.snapshot.call(
                Class.parent,
                self.as(Parent),
                snap,
            );
        }
    }

    /// Draw and snapshot a frame our way. False if it cannot be (nothing
    /// has been drawn or appended then).
    fn snapshotTracked(self: *Self, snap: *gtk.Snapshot) bool {
        const priv = self.private();
        if (!priv.tracking) return false;

        const area = self.as(gtk.GLArea);
        const widget = self.as(gtk.Widget);
        const scale = widget.getScaleFactor();
        const w = widget.getWidth() * scale;
        const h = widget.getHeight() * scale;
        if (w <= 0 or h <= 0) return false;
        if (area.getError() != null) return false;
        const context = area.getContext() orelse return false;
        area.makeCurrent();
        if (area.getError() != null) return false;

        const ctx = &gl.glad.context;
        if (!self.ensureBuffers(w, h)) return false;
        ctx.BindFramebuffer.?(gl.c.GL_FRAMEBUFFER, priv.fbo);

        if (w != priv.resize_width or h != priv.resize_height) {
            priv.resize_width = w;
            priv.resize_height = h;
            gobject.signalEmitByName(self.as(gobject.Object), "resize", w, h);
            // Handlers may bind what they like.
            ctx.BindFramebuffer.?(gl.c.GL_FRAMEBUFFER, priv.fbo);
        }

        // Whoever draws says what it changed; saying nothing is everything.
        priv.pending = .everything;
        var handled: c_int = 0;
        gobject.signalEmitByName(self.as(gobject.Object), "render", context, &handled);
        // GTK draws with another context of the share group: it sees our
        // work once this one has flushed.
        ctx.Flush.?();

        const damage = priv.pending;
        const was_persistent = priv.persistent;
        priv.persistent = true;

        const texture: *gdk.Texture = texture: {
            const update: ?*gdk.Texture = if (was_persistent and !damage.full) priv.last else null;
            // Nothing changed: the same texture again is no damage at all.
            if (update) |last| if (damage.n == 0) break :texture last;

            const builder = gdk.GLTextureBuilder.new();
            defer builder.unref();
            builder.setContext(context);
            builder.setId(priv.tex);
            builder.setWidth(w);
            builder.setHeight(h);
            // What GtkGLArea says of its own GL_RGBA8 texture on desktop GL.
            builder.setFormat(.b8g8r8a8_premultiplied);
            if (update) |last| {
                // The region is in texture rows, which are GL's: no flip.
                var rects: [Damage.max_rects]cairo.RectangleInt = undefined;
                for (damage.slice(), 0..) |r, i| rects[i] = .{
                    .x = @intCast(r[0]),
                    .y = @intCast(r[1]),
                    .width = @intCast(r[2]),
                    .height = @intCast(r[3]),
                };
                const region = cairo.Region.createRectangles(&rects, @intCast(damage.n));
                defer region.destroy();
                builder.setUpdateTexture(last);
                builder.setUpdateRegion(region);
            }
            const new = builder.build(null, null);
            self.dropLast();
            priv.last = new;
            break :texture new;
        };

        // GL's rows run bottom-up and GSK's top-down, so flip (as GtkGLArea
        // does).
        const lw: f32 = @floatFromInt(widget.getWidth());
        const lh: f32 = @floatFromInt(widget.getHeight());
        snap.save();
        snap.translate(&.{ .f_x = 0, .f_y = lh });
        snap.scale(1, -1);
        snap.appendTexture(texture, &.{
            .f_origin = .{ .f_x = 0, .f_y = 0 },
            .f_size = .{ .f_width = lw, .f_height = lh },
        });
        snap.restore();
        return true;
    }

    /// Our framebuffer and a texture of this size. The context is current.
    fn ensureBuffers(self: *Self, w: c_int, h: c_int) bool {
        const priv = self.private();
        const ctx = &gl.glad.context;
        if (priv.tex != 0 and priv.width == w and priv.height == h) return true;

        // A new texture rather than new storage for the old one: GTK may
        // still hold the last frame's.
        self.deleteBuffers();
        ctx.GenTextures.?(1, &priv.tex);
        ctx.BindTexture.?(gl.c.GL_TEXTURE_2D, priv.tex);
        ctx.TexParameteri.?(gl.c.GL_TEXTURE_2D, gl.c.GL_TEXTURE_MIN_FILTER, gl.c.GL_NEAREST);
        ctx.TexParameteri.?(gl.c.GL_TEXTURE_2D, gl.c.GL_TEXTURE_MAG_FILTER, gl.c.GL_NEAREST);
        ctx.TexParameteri.?(gl.c.GL_TEXTURE_2D, gl.c.GL_TEXTURE_WRAP_S, gl.c.GL_CLAMP_TO_EDGE);
        ctx.TexParameteri.?(gl.c.GL_TEXTURE_2D, gl.c.GL_TEXTURE_WRAP_T, gl.c.GL_CLAMP_TO_EDGE);
        ctx.TexImage2D.?(
            gl.c.GL_TEXTURE_2D,
            0,
            gl.c.GL_RGBA8,
            w,
            h,
            0,
            gl.c.GL_BGRA,
            gl.c.GL_UNSIGNED_BYTE,
            null,
        );
        ctx.BindTexture.?(gl.c.GL_TEXTURE_2D, 0);

        ctx.GenFramebuffers.?(1, &priv.fbo);
        ctx.BindFramebuffer.?(gl.c.GL_FRAMEBUFFER, priv.fbo);
        ctx.FramebufferTexture2D.?(
            gl.c.GL_FRAMEBUFFER,
            gl.c.GL_COLOR_ATTACHMENT0,
            gl.c.GL_TEXTURE_2D,
            priv.tex,
            0,
        );
        const status = ctx.CheckFramebufferStatus.?(gl.c.GL_FRAMEBUFFER);
        if (status != gl.c.GL_FRAMEBUFFER_COMPLETE) {
            log.warn("damage framebuffer incomplete status={x}, using the stock path", .{status});
            ctx.BindFramebuffer.?(gl.c.GL_FRAMEBUFFER, 0);
            self.deleteBuffers();
            priv.tracking = false;
            return false;
        }
        priv.width = w;
        priv.height = h;
        priv.persistent = false;
        return true;
    }

    fn deleteBuffers(self: *Self) void {
        const priv = self.private();
        const ctx = &gl.glad.context;
        if (priv.fbo != 0) ctx.DeleteFramebuffers.?(1, &priv.fbo);
        if (priv.tex != 0) ctx.DeleteTextures.?(1, &priv.tex);
        priv.fbo = 0;
        priv.tex = 0;
        priv.width = 0;
        priv.height = 0;
        priv.persistent = false;
    }

    fn dropLast(self: *Self) void {
        const priv = self.private();
        if (priv.last) |t| t.unref();
        priv.last = null;
    }

    fn unrealize(self: *Self) callconv(.c) void {
        const priv = self.private();
        self.dropLast();
        if (priv.tex != 0 or priv.fbo != 0) {
            const area = self.as(gtk.GLArea);
            area.makeCurrent();
            if (area.getError() == null) self.deleteBuffers();
        }
        // Whatever realizes us next starts over, and must turn tracking
        // back on itself.
        priv.* = .{};
        gtk.Widget.virtual_methods.unrealize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
            gtk.Widget.virtual_methods.unrealize.implement(class, &unrealize);
        }

        pub const as = C.Class.as;
    };
};
