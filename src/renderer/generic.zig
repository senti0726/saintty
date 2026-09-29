const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");
const xev = global.xev;
const wuffs = @import("wuffs");
const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const inputpkg = @import("../input.zig");
const os = @import("../os/main.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const math = @import("../math.zig");
const Surface = @import("../Surface.zig");
const link = @import("link.zig");
const cellpkg = @import("cell.zig");
const noMinContrast = cellpkg.noMinContrast;
const constraintWidth = cellpkg.constraintWidth;
const isCovering = cellpkg.isCovering;
const rowNeverExtendBg = @import("row.zig").neverExtendBg;
const Overlay = @import("Overlay.zig");
const imagepkg = @import("image.zig");
const ImageState = imagepkg.State;
const shadertoy = @import("shadertoy.zig");
const ScrollAnim = @import("scroll_anim.zig");

/// An inclusive row range that a scroll applies to.
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Terminal = terminal.Terminal;
const Health = renderer.Health;
const compat_file = @import("../lib/compat/file.zig");

const getConstraint = @import("../font/nerd_font_attributes.zig").getConstraint;

const FileType = @import("../file_type.zig").FileType;

const macos = switch (builtin.os.tag) {
    .macos => @import("macos"),
    else => void,
};

const DisplayLink = switch (builtin.os.tag) {
    .macos => *macos.video.DisplayLink,
    else => void,
};

const log = std.log.scoped(.generic_renderer);

/// Create a renderer type with the provided graphics API wrapper.
///
/// The graphics API wrapper must provide the interface outlined below.
/// Specific details for the interfaces are documented on the existing
/// implementations (`Metal` and `OpenGL`).
///
/// Hierarchy of graphics abstractions:
///
/// [ GraphicsAPI ] - Responsible for configuring the runtime surface
///    |     |        and providing render `Target`s that draw to it,
///    |     |        as well as `Frame`s and `Pipeline`s.
///    |     V
///    | [ Target ] - Represents an abstract target for rendering, which
///    |              could be a surface directly but is also used as an
///    |              abstraction for off-screen frame buffers.
///    V
/// [ Frame ] - Represents the context for drawing a given frame,
///    |        provides `RenderPass`es for issuing draw commands
///    |        to, and reports the frame health when complete.
///    V
/// [ RenderPass ] - Represents a render pass in a frame, consisting of
///   :              one or more `Step`s applied to the same target(s),
/// [ Step ] - - - - each describing the input buffers and textures and
///   :              the vertex/fragment functions and geometry to use.
///   :_ _ _ _ _ _ _ _ _ _/
///   v
/// [ Pipeline ] - Describes a vertex and fragment function to be used
///                for a `Step`; the `GraphicsAPI` is responsible for
///                these and they should be constructed and cached
///                ahead of time.
///
/// [ Buffer ] - An abstraction over a GPU buffer.
///
/// [ Texture ] - An abstraction over a GPU texture.
///
pub fn Renderer(comptime GraphicsAPI: type) type {
    return struct {
        const Self = @This();

        pub const API = GraphicsAPI;

        const Target = GraphicsAPI.Target;
        const Buffer = GraphicsAPI.Buffer;
        const Sampler = GraphicsAPI.Sampler;
        const Texture = GraphicsAPI.Texture;
        const RenderPass = GraphicsAPI.RenderPass;

        const shaderpkg = GraphicsAPI.shaders;
        const Shaders = shaderpkg.Shaders;

        /// Allocator that can be used
        alloc: std.mem.Allocator,

        /// This mutex must be held whenever any state used in `drawFrame` is
        /// being modified, and also when it's being accessed in `drawFrame`.
        draw_mutex: std.Io.Mutex = .init,

        /// The configuration we need derived from the main config.
        config: DerivedConfig,

        /// The mailbox for communicating with the window.
        surface_mailbox: apprt.surface.Mailbox,

        /// Current font metrics defining our grid.
        grid_metrics: font.Metrics,

        /// The size of everything.
        size: renderer.Size,

        /// True if the window is focused
        focused: bool,

        /// True if the window is visible.
        visible: bool,

        /// Flag to indicate that our focus state changed for custom
        /// shaders to update their state.
        custom_shader_focused_changed: bool = false,

        /// The most recent scrollbar state. We use this as a cache to
        /// determine if we need to notify the apprt that there was a
        /// scrollbar change.
        scrollbar: terminal.Scrollbar,
        scrollbar_dirty: bool,

        /// Tracks the last bottom-right pin of the screen to detect new output.
        /// When the final line changes (node or y differs), new content was added.
        /// Used for scroll-to-bottom on output feature.
        last_bottom_node: ?usize,
        last_bottom_y: terminal.size.CellCountInt,

        /// The most recent viewport matches so that we can render search
        /// matches in the visible frame. This is provided asynchronously
        /// from the search thread so we have the dirty flag to also note
        /// if we need to rebuild our cells to include search highlights.
        ///
        /// Note that the selections MAY BE INVALID (point to PageList nodes
        /// that do not exist anymore). These must be validated prior to use.
        search_matches: ?renderer.Message.SearchMatches,
        search_selected_match: ?renderer.Message.SearchMatch,
        search_matches_dirty: bool,

        /// The current set of cells to render. This is rebuilt on every frame
        /// but we keep this around so that we don't reallocate. Each set of
        /// cells goes into a separate shader.
        cells: cellpkg.Contents,

        /// Set to true after rebuildCells is called. This can be used
        /// to determine if any possible changes have been made to the
        /// cells for the draw call.
        cells_rebuilt: bool = false,

        /// The current GPU uniform values.
        uniforms: shaderpkg.Uniforms,

        /// In-flight scroll animation, if any. Seeded when the terminal
        /// reports a region scroll and eased to zero over the following
        /// frames. See SPEC.md stage 2.
        scroll_anim: ScrollAnim = .{},

        /// Cumulative rows the terminal model has scrolled, and the clock
        /// base, both only for `scroll-trace`. Together with the per-frame
        /// offset these reconstruct where content was actually drawn.
        scroll_trace_rows: i64 = 0,
        scroll_trace_base: ?std.Io.Timestamp = null,

        /// When a key last produced input for the program.
        ///
        /// Keyboard scrolling -- `j`/`k` held in vim or a pager -- moves the
        /// screen exactly as a wheel does but touches none of the scroll
        /// plumbing, so without this the repaint detector never runs for it.
        input_activity_ts: ?std.Io.Timestamp = null,

        /// When a scroll last arrived inside an open gate: a real scroll
        /// event, or a shift the repaint detector recovered.
        ///
        /// Keeps the gate open for as long as a scroll the user started is
        /// still arriving. See `repaint_chain_ms`.
        scroll_chain_ts: ?std.Io.Timestamp = null,

        /// Row content hashes from the previous frame.
        ///
        /// Some applications move the picture without ever telling us they
        /// scrolled. nvim with `smoothscroll` repaints every row rather than
        /// scrolling the grid when it moves within a wrapped line -- measured
        /// at 9008 bytes of repaint against 1873 for the same movement with
        /// `nosmoothscroll`, which does scroll and emits `CSI M`. Anything on
        /// the primary screen -- a plain shell, Claude Code -- moves our own
        /// scrollback viewport instead, which never reaches `noteScroll`
        /// either. In both cases the content demonstrably moved by whole rows
        /// and there is no event to hook, so we recover the movement by
        /// noticing that this frame's rows are last frame's rows, shifted.
        scroll_row_hashes: std.ArrayList(u64) = .empty,

        /// The cell hashes from just BEFORE the last frame that carried a
        /// scroll event. See "a frame caught mid-redraw" in
        /// `detectRepaintScroll`.
        scroll_pre_event_hashes: std.ArrayList(u64) = .empty,

        /// The previous frame's cell hashes, kept one frame longer than
        /// `scroll_row_hashes` so the pin pass can ask whether a pinned
        /// cell's TEXT stayed too. See `markPinnedText`.
        scroll_hashes_before: std.ArrayList(u64) = .empty,

        /// The scrolling region the application last declared for itself,
        /// while a gesture is in progress.
        ///
        /// The repaint detector has to infer its row range from which rows
        /// *changed*, and nvim's status line changes on every scroll -- it
        /// carries the position percentage and the cursor's line:col. So the
        /// detector sweeps in the very rows the application excluded from its
        /// own scrolling margins, and reported rows 0..54 where nvim's own
        /// events said 0..52. The status line then animated on detector
        /// frames and held still on event frames.
        ///
        /// An application that narrows its region is naming its interface
        /// rows, and that is better information than anything the detector
        /// can recover from pixels. `grid_rows` is kept so a resize
        /// invalidates the region rather than clamping against a stale one.
        scroll_anim_app_region: ?struct {
            top: usize,
            bottom: usize,
            grid_rows: usize,
        } = null,

        /// Glyphs of rows the running scroll carried out of its region, kept
        /// so the band a lagging offset uncovers shows them instead of a
        /// hole. Their grid y is relative to the CURRENT model and lies
        /// outside the region (wrapped u16 above it); the shader draws them
        /// only while the animation is live. See `ScrollAnim.shiftGhosts`.
        scroll_ghost: std.ArrayListUnmanaged(shaderpkg.CellText) = .empty,

        /// The kept rows' backgrounds, as an extended grid. See
        /// `ScrollAnim.shiftGhostBg`; appended after the real background
        /// cells at upload, and read by the background shader for the band.
        scroll_ghost_bg: std.ArrayListUnmanaged(shaderpkg.CellBg) = .empty,
        scroll_ghost_bg_live: bool = false,
        scroll_image_ghosts_stale: bool = false,

        /// Cells pinned as an overlay on the running scroll (see
        /// `ScrollAnim.computePins`), one CellBg per grid cell, byte 0 = 255.
        /// Uploaded after the bg cells (and the ghost backgrounds); the text
        /// and bg shaders leave these cells undisplaced and let nothing
        /// sliding draw over them.
        scroll_pin: std.ArrayListUnmanaged(shaderpkg.CellBg) = .empty,
        scroll_pin_live: bool = false,
        /// The backgrounds as drawn before this frame's rebuild, for pins.
        scroll_bg_prev: std.ArrayListUnmanaged(shaderpkg.CellBg) = .empty,
        /// The last push this frame, for pins: set by `keepScrollGhosts`.
        scroll_frame_push: ?struct { rows: isize, top: usize, bottom: usize, left: usize, right: usize } = null,

        /// The image placements as last drawn, snapshotted before each
        /// kitty update rebuilds them: by the time a scroll is handled the
        /// placements already describe the new model, and the slices that
        /// left are only in here. See `image.State.kitty_ghosts`.
        scroll_prev_images: std.ArrayListUnmanaged(imagepkg.Placement) = .empty,
        scroll_bg_view: std.ArrayListUnmanaged(std.ArrayListUnmanaged(shaderpkg.CellBg)) = .empty,

        /// The row lists plus the ghost list, handed to the GPU upload in one
        /// go. Shallow copies of `cells.fg_rows`; rebuilt every frame.
        scroll_ghost_view: std.ArrayListUnmanaged(std.ArrayListUnmanaged(shaderpkg.CellText)) = .empty,

        /// The application's most recent scroll event: its rows and when.
        /// See `ScrollAnim.isRepair`.
        scroll_anim_last_event: ?struct {
            rows: isize,
            ts: std.Io.Timestamp,
        } = null,

        /// When the last frame was actually drawn, so the scroll animation
        /// can pace itself against every draw rather than adding its own on
        /// top of them.
        last_draw_ts: ?std.Io.Timestamp = null,

        /// When the scroll animation was last advanced.
        scroll_anim_last: ?std.Io.Timestamp = null,

        /// Custom shader uniform values.
        custom_shader_uniforms: shadertoy.Uniforms,

        /// Cursor-effect tracking (this fork), see updateCursorFx. The
        /// cell and mode last seen, the pulse counter last seen, and when
        /// the latest effect-starting event happened, which is what
        /// `custom-shader-animation = cursor` animates after.
        cursor_fx_cell: ?[2]u16 = null,
        cursor_fx_mode: ?struct { style: i32, color: [4]f32 } = null,
        cursor_fx_pulse_seen: u32 = 0,
        cursor_fx_pulse_pending: bool = false,
        cursor_fx_last_event: ?std.Io.Timestamp = null,

        /// Timestamp we rendered out first frame.
        ///
        /// This is used when updating custom shader uniforms.
        first_frame_time: ?std.Io.Timestamp = null,

        /// Timestamp when we rendered out more recent frame.
        ///
        /// This is used when updating custom shader uniforms.
        last_frame_time: ?std.Io.Timestamp = null,

        /// The font structures.
        font_grid: *font.SharedGrid,
        font_shaper: font.Shaper,
        font_shaper_cache: font.ShaperCache,

        /// The images that we may render.
        images: ImageState = .empty,

        /// Background image, if we have one.
        bg_image: ?imagepkg.Image = null,
        /// Set whenever the background image changes, signalling
        /// that the new background image needs to be uploaded to
        /// the GPU.
        ///
        /// This is initialized as true so that we load the image
        /// on renderer initialization, not just on config change.
        bg_image_changed: bool = true,
        /// Background image vertex buffer.
        bg_image_buffer: shaderpkg.BgImage,
        /// This value is used to force-update the swap chain copy
        /// of the background image buffer whenever we change it.
        bg_image_buffer_modified: usize = 0,

        /// Graphics API state.
        api: GraphicsAPI,

        /// The CVDisplayLink used to drive the rendering loop in
        /// sync with the display. This is void on platforms that
        /// don't support a display link.
        display_link: ?DisplayLink = null,

        /// Health of the most recently completed frame.
        health: std.atomic.Value(Health) = .{ .raw = .healthy },

        /// True when we have a graphics context that can create GPU
        /// resources. Creating any GPU resource while this is false is invalid.
        display_realized: bool = true,

        /// Our swap chain (multiple buffering). Null when it has
        /// been released, either because the surface is hidden
        /// (`releaseGpuResources`) or because the display is
        /// unrealized. Rebuilt on the next `drawFrame`.
        swap_chain: ?SwapChain,

        /// This value is used to force-update swap chain targets in the
        /// event of a config change that requires it (such as blending mode).
        target_config_modified: usize = 0,

        /// If something happened that requires us to reinitialize our shaders,
        /// this is set to true so that we can do that whenever possible.
        reinitialize_shaders: bool = false,

        /// Whether or not we have custom shaders.
        has_custom_shaders: bool = false,

        /// Our shader pipelines.
        shaders: Shaders,

        /// The render state we update per loop.
        terminal_state: terminal.RenderState = .empty,

        /// The number of frames since the last terminal state reset.
        /// We reset the terminal state after ~100,000 frames (about 10 to
        /// 15 minutes at 120Hz) to prevent wasted memory buildup from
        /// a large screen.
        terminal_state_frame_count: usize = 0,

        /// Our overlay state, if any.
        overlay: ?Overlay = null,

        /// The base timestamp for the Kitty graphics animation clock.
        /// Animation frame timing is expressed as milliseconds since
        /// this instant. Set on the first frame update that observes
        /// Kitty images.
        kitty_animation_clock: ?std.Io.Timestamp = null,

        /// When the next Kitty animation frame is due, in
        /// milliseconds on the animation clock, from the most recent
        /// frame update. Null when no running animation needs a
        /// wakeup.
        kitty_animation_next_ms: ?u64 = null,

        const HighlightTag = enum(u8) {
            search_match,
            search_match_selected,
        };
        /// Swap chain which maintains multiple copies of the state needed to
        /// render a frame, so that we can start building the next frame while
        /// the previous frame is still being processed on the GPU.
        const SwapChain = struct {
            // The count of buffers we use for double/triple buffering.
            // If this is one then we don't do any double+ buffering at all.
            // This is comptime because there isn't a good reason to change
            // this at runtime and there is a lot of complexity to support it.
            const buf_count = GraphicsAPI.swap_chain_count;

            /// `buf_count` structs that can hold the
            /// data needed by the GPU to draw a frame.
            frames: [buf_count]FrameState,
            /// Index of the most recently used frame state struct.
            frame_index: std.math.IntFittingRange(0, buf_count) = 0,
            /// Semaphore that we wait on to make sure we have an available
            /// frame state struct so we can start working on a new frame.
            frame_sema: std.Io.Semaphore = .{ .permits = buf_count },

            pub fn init(api: GraphicsAPI, custom_shaders: bool) !SwapChain {
                var result: SwapChain = .{ .frames = undefined };

                // Initialize all of our frame state.
                for (&result.frames) |*frame| {
                    frame.* = try FrameState.init(api, custom_shaders);
                }

                return result;
            }

            pub fn deinit(self: *SwapChain) void {
                // Wait for all of our inflight draws to complete
                // so that we can cleanly deinit our GPU state.
                for (0..buf_count) |_| self.frame_sema.waitUncancelable(
                    global.io(),
                );
                for (&self.frames) |*frame| frame.deinit();
            }

            /// Get the next frame state to draw to. This will wait on the
            /// semaphore to ensure that the frame is available. This must
            /// always be paired with a call to releaseFrame.
            pub fn nextFrame(self: *SwapChain) *FrameState {
                self.frame_sema.waitUncancelable(global.io());
                self.frame_index = (self.frame_index + 1) % buf_count;
                return &self.frames[self.frame_index];
            }

            /// This should be called when the frame has completed drawing.
            pub fn releaseFrame(self: *SwapChain) void {
                self.frame_sema.post(global.io());
            }
        };

        /// State we need duplicated for every frame. Any state that could be
        /// in a data race between the GPU and CPU while a frame is being drawn
        /// should be in this struct.
        ///
        /// While a draw is in-process, we "lock" the state (via a semaphore)
        /// and prevent the CPU from updating the state until our graphics API
        /// reports that the frame is complete.
        ///
        /// This is used to implement double/triple buffering.
        const FrameState = struct {
            uniforms: UniformBuffer,
            cells: CellTextBuffer,
            cells_bg: CellBgBuffer,

            grayscale: Texture,
            grayscale_modified: usize = 0,
            color: Texture,
            color_modified: usize = 0,

            target: Target,
            /// See property of same name on Renderer for explanation.
            target_config_modified: usize = 0,

            /// Buffer with the vertex data for our background image.
            ///
            /// TODO: Make this an optional and only create it
            ///       if we actually have a background image.
            bg_image_buffer: BgImageBuffer,
            /// See property of same name on Renderer for explanation.
            bg_image_buffer_modified: usize = 0,

            /// Custom shader state, this is null if we have no custom shaders.
            custom_shader_state: ?CustomShaderState = null,

            const UniformBuffer = Buffer(shaderpkg.Uniforms);
            const CellBgBuffer = Buffer(shaderpkg.CellBg);
            const CellTextBuffer = Buffer(shaderpkg.CellText);
            const BgImageBuffer = Buffer(shaderpkg.BgImage);

            pub fn init(api: GraphicsAPI, custom_shaders: bool) !FrameState {
                // Uniform buffer contains exactly 1 uniform struct. The
                // uniform data will be undefined so this must be set before
                // a frame is drawn.
                var uniforms = try UniformBuffer.init(api.uniformBufferOptions(), 1);
                errdefer uniforms.deinit();

                // Create GPU buffers for our cells.
                //
                // We start them off with a size of 1, which will of course be
                // too small, but they will be resized as needed. This is a bit
                // wasteful but since it's a one-time thing it's not really a
                // huge concern.
                var cells = try CellTextBuffer.init(api.fgBufferOptions(), 1);
                errdefer cells.deinit();
                var cells_bg = try CellBgBuffer.init(api.bgBufferOptions(), 1);
                errdefer cells_bg.deinit();

                // Create a GPU buffer for our background image info.
                var bg_image_buffer = try BgImageBuffer.init(
                    api.bgImageBufferOptions(),
                    1,
                );
                errdefer bg_image_buffer.deinit();

                // Initialize our textures for our font atlas.
                //
                // As with the buffers above, we start these off as small
                // as possible since they'll inevitably be resized anyway.
                const grayscale = try api.initAtlasTexture(&.{
                    .data = undefined,
                    .size = 1,
                    .format = .grayscale,
                });
                errdefer grayscale.deinit();
                const color = try api.initAtlasTexture(&.{
                    .data = undefined,
                    .size = 1,
                    .format = .bgra,
                });
                errdefer color.deinit();

                var custom_shader_state =
                    if (custom_shaders)
                        try CustomShaderState.init(api)
                    else
                        null;
                errdefer if (custom_shader_state) |*state| state.deinit();

                // Initialize the target. Just as with the other resources,
                // start it off as small as we can since it'll be resized.
                const target = try api.initTarget(1, 1);

                return .{
                    .uniforms = uniforms,
                    .cells = cells,
                    .cells_bg = cells_bg,
                    .bg_image_buffer = bg_image_buffer,
                    .grayscale = grayscale,
                    .color = color,
                    .target = target,
                    .custom_shader_state = custom_shader_state,
                };
            }

            pub fn deinit(self: *FrameState) void {
                self.target.deinit();
                self.uniforms.deinit();
                self.cells.deinit();
                self.cells_bg.deinit();
                self.grayscale.deinit();
                self.color.deinit();
                self.bg_image_buffer.deinit();
                if (self.custom_shader_state) |*state| state.deinit();
            }

            pub fn resize(
                self: *FrameState,
                api: GraphicsAPI,
                width: usize,
                height: usize,
            ) !void {
                if (self.custom_shader_state) |*state| {
                    try state.resize(api, width, height);
                }
                const target = try api.initTarget(width, height);
                self.target.deinit();
                self.target = target;
            }
        };

        /// State relevant to our custom shaders if we have any.
        const CustomShaderState = struct {
            /// When we have a custom shader state, we maintain a front
            /// and back texture which we use as a swap chain to render
            /// between when multiple custom shaders are defined.
            front_texture: Texture,
            back_texture: Texture,

            /// Shadertoy uses a sampler for accessing the various channel
            /// textures. In Metal, we need to explicitly create these since
            /// the glslang-to-msl compiler doesn't do it for us (as we
            /// normally would in hand-written MSL). To keep it clean and
            /// consistent, we just force all rendering APIs to provide an
            /// explicit sampler.
            ///
            /// Samplers are immutable and describe sampling properties so
            /// we can share the sampler across front/back textures (although
            /// we only need it for the source texture at a time, we don't
            /// need to "swap" it).
            sampler: Sampler,

            uniforms: UniformBuffer,

            const UniformBuffer = Buffer(shadertoy.Uniforms);

            /// Swap the front and back textures.
            pub fn swap(self: *CustomShaderState) void {
                std.mem.swap(Texture, &self.front_texture, &self.back_texture);
            }

            pub fn init(api: GraphicsAPI) !CustomShaderState {
                // Create a GPU buffer to hold our uniforms.
                var uniforms = try UniformBuffer.init(api.uniformBufferOptions(), 1);
                errdefer uniforms.deinit();

                // Initialize the front and back textures at 1x1 px, this
                // is slightly wasteful but it's only done once so whatever.
                const front_texture = try Texture.init(
                    api.textureOptions(),
                    1,
                    1,
                    null,
                );
                errdefer front_texture.deinit();
                const back_texture = try Texture.init(
                    api.textureOptions(),
                    1,
                    1,
                    null,
                );
                errdefer back_texture.deinit();

                const sampler = try Sampler.init(api.samplerOptions());
                errdefer sampler.deinit();

                return .{
                    .front_texture = front_texture,
                    .back_texture = back_texture,
                    .sampler = sampler,
                    .uniforms = uniforms,
                };
            }

            pub fn deinit(self: *CustomShaderState) void {
                self.front_texture.deinit();
                self.back_texture.deinit();
                self.sampler.deinit();
                self.uniforms.deinit();
            }

            pub fn resize(
                self: *CustomShaderState,
                api: GraphicsAPI,
                width: usize,
                height: usize,
            ) !void {
                const front_texture = try Texture.init(
                    api.textureOptions(),
                    @intCast(width),
                    @intCast(height),
                    null,
                );
                errdefer front_texture.deinit();
                const back_texture = try Texture.init(
                    api.textureOptions(),
                    @intCast(width),
                    @intCast(height),
                    null,
                );
                errdefer back_texture.deinit();

                self.front_texture.deinit();
                self.back_texture.deinit();

                self.front_texture = front_texture;
                self.back_texture = back_texture;
            }
        };

        /// The configuration for this renderer that is derived from the main
        /// configuration. This must be exported so that we don't need to
        /// pass around Config pointers which makes memory management a pain.
        pub const DerivedConfig = struct {
            arena: ArenaAllocator,

            font_thicken: bool,
            font_thicken_strength: u8,
            font_features: std.ArrayListUnmanaged([:0]const u8),
            font_styles: font.CodepointResolver.StyleStatus,
            font_shaping_break: configpkg.FontShapingBreak,
            cursor_color: ?configpkg.Config.TerminalColor,
            cursor_opacity: f64,
            cursor_text: ?configpkg.Config.TerminalColor,
            background: terminal.color.RGB,
            background_opacity: f64,
            background_opacity_cells: bool,
            scroll_animation: bool,
            scroll_animation_duration_ms: u32,
            scroll_animation_reserve_bottom: u8,
            scroll_animation_easing: ScrollAnim.Easing,
            scroll_trace: bool,
            foreground: terminal.color.RGB,
            selection_background: ?configpkg.Config.TerminalColor,
            selection_foreground: ?configpkg.Config.TerminalColor,
            search_background: configpkg.Config.TerminalColor,
            search_foreground: configpkg.Config.TerminalColor,
            search_selected_background: configpkg.Config.TerminalColor,
            search_selected_foreground: configpkg.Config.TerminalColor,
            bold_color: ?terminal.Style.BoldColor,
            faint_opacity: u8,
            min_contrast: f32,
            padding_color: configpkg.WindowPaddingColor,
            custom_shaders: configpkg.RepeatablePath,
            bg_image: ?configpkg.Path,
            bg_image_opacity: f32,
            bg_image_position: configpkg.BackgroundImagePosition,
            bg_image_fit: configpkg.BackgroundImageFit,
            bg_image_repeat: bool,
            links: link.Set,
            vsync: bool,
            colorspace: configpkg.Config.WindowColorspace,
            blending: configpkg.Config.AlphaBlending,
            background_blur: configpkg.Config.BackgroundBlur,
            scroll_to_bottom_on_output: bool,
            custom_shader_animation: configpkg.CustomShaderAnimation,

            pub fn init(
                alloc_gpa: Allocator,
                config: *const configpkg.Config,
            ) !DerivedConfig {
                var arena = ArenaAllocator.init(alloc_gpa);
                errdefer arena.deinit();
                const alloc = arena.allocator();

                // Copy our shaders
                const custom_shaders = try config.@"custom-shader".clone(alloc);

                // Copy our background image
                const bg_image =
                    if (config.@"background-image") |bg|
                        try bg.clone(alloc)
                    else
                        null;

                // Copy our font features
                const font_features = try config.@"font-feature".clone(alloc);

                // Get our font styles
                var font_styles = font.CodepointResolver.StyleStatus.initFill(true);
                font_styles.set(.bold, config.@"font-style-bold" != .false);
                font_styles.set(.italic, config.@"font-style-italic" != .false);
                font_styles.set(.bold_italic, config.@"font-style-bold-italic" != .false);

                // Our link configs
                const links = try link.Set.fromConfig(
                    alloc,
                    config.link.links.items,
                );

                return .{
                    .background_opacity = @max(0, @min(1, config.@"background-opacity")),
                    .background_opacity_cells = config.@"background-opacity-cells",
                    .font_thicken = config.@"font-thicken",
                    .font_thicken_strength = config.@"font-thicken-strength",
                    .font_features = font_features.list,
                    .font_styles = font_styles,
                    .font_shaping_break = config.@"font-shaping-break",

                    .cursor_color = config.@"cursor-color",
                    .cursor_text = config.@"cursor-text",
                    .cursor_opacity = @max(0, @min(1, config.@"cursor-opacity")),

                    .background = config.background.toTerminalRGB(),
                    .foreground = config.foreground.toTerminalRGB(),
                    .bold_color = if (config.@"bold-color") |b| b.toTerminal() else null,
                    .faint_opacity = @intFromFloat(@ceil(config.@"faint-opacity" * 255)),

                    .min_contrast = @floatCast(config.@"minimum-contrast"),

                    .scroll_animation = config.@"scroll-animation",
                    .scroll_animation_duration_ms = config.@"scroll-animation-duration",
                    .scroll_animation_reserve_bottom = config.@"scroll-animation-reserve-bottom",
                    .scroll_animation_easing = switch (config.@"scroll-animation-easing") {
                        .linear => .linear,
                        .@"ease-out-cubic" => .ease_out_cubic,
                        .@"ease-out-quint" => .ease_out_quint,
                        .@"ease-out-quad" => .ease_out_quad,
                        .material => .material,
                        .spring => .spring,
                    },
                    .scroll_trace = config.@"scroll-trace",
                    .padding_color = config.@"window-padding-color",

                    .selection_background = config.@"selection-background",
                    .selection_foreground = config.@"selection-foreground",
                    .search_background = config.@"search-background",
                    .search_foreground = config.@"search-foreground",
                    .search_selected_background = config.@"search-selected-background",
                    .search_selected_foreground = config.@"search-selected-foreground",

                    .custom_shaders = custom_shaders,
                    .bg_image = bg_image,
                    .bg_image_opacity = config.@"background-image-opacity",
                    .bg_image_position = config.@"background-image-position",
                    .bg_image_fit = config.@"background-image-fit",
                    .bg_image_repeat = config.@"background-image-repeat",
                    .links = links,
                    .vsync = config.@"window-vsync",
                    .colorspace = config.@"window-colorspace",
                    .blending = config.@"alpha-blending",
                    .background_blur = config.@"background-blur",
                    .scroll_to_bottom_on_output = config.@"scroll-to-bottom".output,
                    .custom_shader_animation = config.@"custom-shader-animation",
                    .arena = arena,
                };
            }

            pub fn deinit(self: *DerivedConfig) void {
                const alloc = self.arena.allocator();
                self.links.deinit(alloc);
                self.arena.deinit();
            }
        };

        pub fn init(alloc: Allocator, options: renderer.Options) !Self {
            // Initialize our graphics API wrapper, this will prepare the
            // surface provided by the apprt and set up any API-specific
            // GPU resources.
            var api = try GraphicsAPI.init(alloc, options);
            errdefer api.deinit();

            const has_custom_shaders = options.config.custom_shaders.value.items.len > 0;

            // Prepare our swap chain
            var swap_chain = try SwapChain.init(
                api,
                has_custom_shaders,
            );
            errdefer swap_chain.deinit();

            // Create the font shaper.
            var font_shaper = try font.Shaper.init(alloc, .{
                .features = options.config.font_features.items,
            });
            errdefer font_shaper.deinit();

            // Initialize all the data that requires a critical font section.
            const font_critical: struct {
                metrics: font.Metrics,
            } = font_critical: {
                const grid: *font.SharedGrid = options.font_grid;
                grid.lock.lockSharedUncancelable(global.io());
                defer grid.lock.unlockShared(global.io());
                break :font_critical .{
                    .metrics = grid.metrics,
                };
            };

            var result: Self = .{
                .alloc = alloc,
                .config = options.config,
                .surface_mailbox = options.surface_mailbox,
                .grid_metrics = font_critical.metrics,
                .size = options.size,
                .focused = true,
                .visible = true,
                .scrollbar = .zero,
                .scrollbar_dirty = false,
                .last_bottom_node = null,
                .last_bottom_y = 0,
                .search_matches = null,
                .search_selected_match = null,
                .search_matches_dirty = false,

                // Render state
                .cells = .{},
                .uniforms = .{
                    .projection_matrix = undefined,
                    .cell_size = undefined,
                    .grid_size = undefined,
                    .grid_padding = undefined,
                    .scroll_anim = .{ 0, 0, 0, 0 },
                    .scroll_anim_cols = .{ 0, 0, 0, 0 },
                    .screen_size = undefined,
                    .padding_extend = .{},
                    .min_contrast = options.config.min_contrast,
                    .cursor_pos = .{ std.math.maxInt(u16), std.math.maxInt(u16) },
                    .cursor_color = undefined,
                    .bg_color = .{
                        options.config.background.r,
                        options.config.background.g,
                        options.config.background.b,
                        // Note that if we're on macOS with glass effects
                        // we'll disable background opacity but we handle
                        // that in updateFrame.
                        @intFromFloat(@round(options.config.background_opacity * 255.0)),
                    },
                    .bools = .{
                        .cursor_wide = false,
                        .use_display_p3 = options.config.colorspace == .@"display-p3",
                        .use_linear_blending = options.config.blending.isLinear(),
                        .use_linear_correction = options.config.blending == .@"linear-corrected",
                    },
                },
                .custom_shader_uniforms = .{
                    .resolution = .{ 0, 0, 1 },
                    .time = 0,
                    .time_delta = 0,
                    .frame_rate = 60, // not currently updated
                    .frame = 0,
                    .channel_time = @splat(@splat(0)), // not currently updated
                    .channel_resolution = @splat(@splat(0)),
                    .mouse = @splat(0), // not currently updated
                    .date = @splat(0), // not currently updated
                    .sample_rate = 0, // N/A, we don't have any audio
                    .current_cursor = @splat(0),
                    .previous_cursor = @splat(0),
                    .current_cursor_color = @splat(0),
                    .previous_cursor_color = @splat(0),
                    .current_cursor_style = 0,
                    .previous_cursor_style = 0,
                    .cursor_visible = 0,
                    .cursor_change_time = 0,
                    .time_focus = 0,
                    .focus = 1, // assume focused initially
                    .palette = @splat(@splat(0)),
                    .background_color = @splat(0),
                    .foreground_color = @splat(0),
                    .cursor_color = @splat(0),
                    .cursor_text = @splat(0),
                    .selection_background_color = @splat(0),
                    .selection_foreground_color = @splat(0),
                    .cursor_move_from = @splat(0),
                    .cursor_move_to = @splat(0),
                    .time_cursor_move = -1000,
                    .time_cursor_mode = -1000,
                    .time_cursor_pulse = -1000,
                },
                .bg_image_buffer = undefined,

                // Fonts
                .font_grid = options.font_grid,
                .font_shaper = font_shaper,
                .font_shaper_cache = font.ShaperCache.init(),

                // Shaders (initialized below)
                .shaders = undefined,

                // Graphics API stuff
                .api = api,
                .swap_chain = swap_chain,
            };

            try result.initShaders();

            // Ensure our undefined values above are correctly initialized.
            result.updateFontGridUniforms();
            result.updateScreenSizeUniforms();
            result.updateBgImageBuffer();
            try result.prepBackgroundImage();

            return result;
        }

        pub fn deinit(self: *Self) void {
            if (self.overlay) |*overlay| overlay.deinit(self.alloc);
            self.scroll_row_hashes.deinit(self.alloc);
            self.scroll_pre_event_hashes.deinit(self.alloc);
            self.scroll_hashes_before.deinit(self.alloc);
            self.terminal_state.deinit(self.alloc);
            if (self.search_selected_match) |*m| m.arena.deinit();
            if (self.search_matches) |*m| m.arena.deinit();
            if (self.swap_chain) |*sc| sc.deinit();

            if (DisplayLink != void) {
                if (self.display_link) |display_link| {
                    display_link.stop() catch {};
                    display_link.release();
                }
            }

            self.cells.deinit(self.alloc);
            self.scroll_ghost.deinit(self.alloc);
            self.scroll_ghost_bg.deinit(self.alloc);
            self.scroll_prev_images.deinit(self.alloc);
            self.scroll_pin.deinit(self.alloc);
            self.scroll_bg_prev.deinit(self.alloc);
            self.scroll_bg_view.deinit(self.alloc);
            self.scroll_ghost_view.deinit(self.alloc);

            self.font_shaper.deinit();
            self.font_shaper_cache.deinit(self.alloc);

            self.config.deinit();

            self.images.deinit(self.alloc);

            if (self.bg_image) |img| img.deinit(self.alloc);

            self.deinitShaders();

            self.api.deinit();

            self.* = undefined;
        }

        fn deinitShaders(self: *Self) void {
            self.shaders.deinit(self.alloc);
        }

        fn initShaders(self: *Self) !void {
            var arena = ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            // Load our custom shaders
            const custom_shaders: []const [:0]const u8 = shadertoy.loadFromFiles(
                arena_alloc,
                self.config.custom_shaders,
                GraphicsAPI.custom_shader_target,
            ) catch |err| err: {
                log.warn("error loading custom shaders err={}", .{err});
                break :err &.{};
            };

            const has_custom_shaders = custom_shaders.len > 0;

            var shaders = try self.api.initShaders(
                self.alloc,
                custom_shaders,
            );
            errdefer shaders.deinit(self.alloc);

            self.shaders = shaders;
            self.has_custom_shaders = has_custom_shaders;
        }

        /// This is called early right after surface creation.
        pub fn surfaceInit(surface: *apprt.Surface) !void {
            // If our API has to do things here, let it.
            if (@hasDecl(GraphicsAPI, "surfaceInit")) {
                try GraphicsAPI.surfaceInit(surface);
            }
        }

        /// This is called just prior to spinning up the renderer thread for
        /// final main thread setup requirements.
        pub fn finalizeSurfaceInit(self: *Self, surface: *apprt.Surface) !void {
            // If our API has to do things to finalize surface init, let it.
            if (@hasDecl(GraphicsAPI, "finalizeSurfaceInit")) {
                try self.api.finalizeSurfaceInit(surface);
            }
        }

        /// Callback called by renderer.Thread when it begins.
        pub fn threadEnter(self: *const Self, surface: *apprt.Surface) !void {
            // If our API has to do things on thread enter, let it.
            if (@hasDecl(GraphicsAPI, "threadEnter")) {
                try self.api.threadEnter(surface);
            }
        }

        /// Callback called by renderer.Thread when it exits.
        pub fn threadExit(self: *const Self) void {
            // If our API has to do things on thread exit, let it.
            if (@hasDecl(GraphicsAPI, "threadExit")) {
                self.api.threadExit();
            }
        }

        /// Called by renderer.Thread when it starts the main loop.
        pub fn loopEnter(self: *Self, thr: *renderer.Thread) !void {
            // If our API has to do things on loop enter, let it.
            if (@hasDecl(GraphicsAPI, "loopEnter")) {
                self.api.loopEnter();
            }

            // If we don't support a display link we have no work to do.
            if (comptime DisplayLink == void) return;

            self.syncDisplayLink(null, &thr.draw_now);
        }

        /// Called by renderer.Thread when it exits the main loop.
        pub fn loopExit(self: *Self) void {
            // If our API has to do things on loop exit, let it.
            if (@hasDecl(GraphicsAPI, "loopExit")) {
                self.api.loopExit();
            }

            // If we don't support a display link we have no work to do.
            if (comptime DisplayLink == void) return;

            // Stop our display link. If this fails its okay it just means
            // that we either never started it or the view its attached to
            // is gone which is fine.
            const display_link = self.display_link orelse return;
            display_link.stop() catch {};
        }

        /// This is called by the GTK apprt after the surface is
        /// reinitialized due to any of the events mentioned in
        /// the doc comment for `displayUnrealized`.
        pub fn displayRealized(self: *Self) !void {
            // If our API has to do things on realize, let it.
            if (@hasDecl(GraphicsAPI, "displayRealized")) {
                self.api.displayRealized();
            }

            // Lock the draw mutex so that we can
            // safely reinitialize our GPU resources.
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());

            // We assume that the swap chain was deinited in
            // `displayUnrealized`. If not, we have a problem.
            assert(self.swap_chain == null);
            assert(!self.display_realized);

            // We reinitialize our shaders and our swap chain.
            try self.initShaders();
            self.swap_chain = try SwapChain.init(
                self.api,
                self.has_custom_shaders,
            );
            self.display_realized = true;
            self.reinitialize_shaders = false;
            self.target_config_modified = 1;
        }

        /// This is called by the GTK apprt when the surface is being destroyed.
        /// This can happen because the surface is being closed but also when
        /// moving the window between displays or splitting.
        pub fn displayUnrealized(self: *Self) void {
            // If our API has to do things on unrealize, let it.
            if (@hasDecl(GraphicsAPI, "displayUnrealized")) {
                self.api.displayUnrealized();
            }

            // Lock the draw mutex so that we can
            // safely deinitialize our GPU resources.
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());

            // We deinit our swap chain and shaders. Clearing
            // `display_realized` ensures drawFrame doesn't attempt
            // to rebuild the swap chain (we have no GPU context);
            // displayRealized will.
            if (self.swap_chain) |*sc| sc.deinit();
            self.swap_chain = null;
            self.display_realized = false;
            self.shaders.deinit(self.alloc);
        }

        fn displayLinkCallback(
            _: *macos.video.DisplayLink,
            ud: ?*xev.Async,
        ) void {
            const draw_now = ud orelse return;
            draw_now.notify() catch |err| {
                log.err("error notifying draw_now err={}", .{err});
            };
        }

        /// Mark the full screen as dirty so that we redraw everything.
        pub inline fn markDirty(self: *Self) void {
            self.terminal_state.dirty = .full;
        }

        /// Called when we get an updated display ID for our display link.
        pub fn setMacOSDisplayID(
            self: *Self,
            id: u32,
            draw_now: *xev.Async,
        ) !void {
            if (comptime DisplayLink == void) return;
            self.syncDisplayLink(id, draw_now);
        }

        /// The cadence of continuous (draw-only) animation wakes,
        /// i.e. 120fps, and the floor for any animation wake delay.
        pub const draw_interval_ms: u64 = 8;

        /// Rows that must agree before a shift is believed, as a count and as
        /// a fraction of the rows compared.
        ///
        /// Blank and repeating rows match at many offsets at once, so a mostly
        /// empty screen can "match" a shift of any size. Animating that
        /// invents motion that never happened, so a shift has to be carried by
        /// a substantial majority of the screen before it is acted on.
        /// The same gate for the keyboard, kept shorter.
        ///
        /// Key repeat when a key is held runs at roughly 30Hz, so a window
        /// this size stays continuously fresh while `j` is down and closes
        /// promptly once it is released -- which is what keeps the output of
        /// a command you just pressed Enter on from sliding.
        pub const repaint_key_idle_ms: i64 = 150;

        /// How long after the last scroll of a gesture the gate stays open.
        ///
        /// A key can start a scroll that outlasts `repaint_key_idle_ms`: nvim
        /// replays a page jump or a counted `15j` as one-row steps over
        /// 250-450 ms (neoscroll; the user's linewalk.lua), and every step
        /// that crosses a wrapped line (a `skipcol` change) arrives as a
        /// repaint, not a scroll event. With the gate shut after 150 ms those
        /// steps snapped -- a sweep of `15j` through a book chapter lost
        /// about a third of its travel. Each scroll that lands inside the
        /// gate re-arms it for this long, so the chain holds exactly as long
        /// as the scroll keeps coming. It never opens the gate by itself, so
        /// output that follows Enter still does not slide. Long enough for
        /// the slowest step of an eased glide (its last row, ~65 ms).
        pub const repaint_chain_ms: i64 = 100;

        pub const repaint_scroll_min_rows: usize = 6;
        pub const repaint_scroll_min_ratio: f32 = 0.6;

        /// How soon after a scroll event a counter-shift may be the rest of
        /// that event's redraw. See "a frame caught mid-redraw".
        pub const repair_partial_ms: i64 = 60;

        /// A point in the future when the renderer needs to be driven
        /// again to keep animating, and what kind of drive it needs.
        pub const AnimationWake = struct {
            /// Delay in milliseconds until the wake is due.
            delay_ms: u64,
            kind: Kind,

            pub const Kind = enum {
                /// A redraw alone suffices, no updateFrame. Much cheaper
                /// than `update`.
                draw,

                /// Frame data must be updated first: updateFrame, then draw.
                update,
            };
        };

        /// How long after a cursor move, mode change or pulse the
        /// `cursor` animation mode keeps drawing. Longer than any effect
        /// in shaders/cursor-fx.glsl, so the last frame is a clean one.
        const cursor_fx_window_ns: i96 = 1300 * std.time.ns_per_ms;

        fn cursorFxLive(self: *const Self) bool {
            const last = self.cursor_fx_last_event orelse return false;
            const now: std.Io.Timestamp = .now(global.io(), .awake);
            return last.durationTo(now).nanoseconds < cursor_fx_window_ns;
        }

        /// The soonest animation wake this renderer needs, if any:
        /// custom shader animation wants continuous draw-only wakes
        /// at draw_interval_ms while active, and a running Kitty
        /// graphics animation wants an update wake when its next
        /// frame is due. The renderer thread drives its animation
        /// timer off this, re-querying after every wake.
        ///
        /// Must be called on the render thread.
        pub fn animationWake(self: *const Self) ?AnimationWake {
            // Custom shaders animate by redrawing on a fixed cadence,
            // gated by configuration and focus.
            const shader_delay: ?u64 = shader: {
                if (!self.has_custom_shaders) break :shader null;
                break :shader switch (self.config.custom_shader_animation) {
                    .false => null,
                    .always => draw_interval_ms,
                    .true => if (self.focused) draw_interval_ms else null,
                    .cursor => if (self.cursorFxLive()) draw_interval_ms else null,
                };
            };

            // Kitty animations tick during updateFrame; between
            // updates the deadline is absolute on the animation
            // clock, so a stream of draw wakes recomputing this
            // cannot starve it into the future.
            const kitty_delay: ?u64 = kitty: {
                const next = self.kitty_animation_next_ms orelse break :kitty null;
                const base = self.kitty_animation_clock orelse break :kitty null;
                const now: std.Io.Timestamp = .now(global.io(), .awake);
                const now_ms: u64 = @intCast(@divTrunc(
                    base.durationTo(now).nanoseconds,
                    std.time.ns_per_ms,
                ));
                // Never wake faster than the draw interval; an
                // overdue frame is picked up on the next wake.
                break :kitty @max(next -| now_ms, draw_interval_ms);
            };

            // An update wake includes a draw, so it wins ties.
            if (kitty_delay) |k| {
                if (shader_delay == null or k <= shader_delay.?) {
                    return .{ .delay_ms = k, .kind = .update };
                }
            }

            if (shader_delay) |s| return .{ .delay_ms = s, .kind = .draw };

            // A scroll animation needs draw-only wakes until it settles.
            //
            // Pace them against the *last actual draw*, not on a fixed
            // interval. A scroll animation runs precisely when the terminal
            // is also being updated, so a fixed 8ms wake stacks animation
            // draws on top of the update-driven ones. At 4K on an iGPU that
            // overruns the vsync budget and halves the observed frame rate --
            // measured at 33ms/frame with the animation on versus 18ms with
            // it off, which reads as the animation making scrolling *worse*.
            if (self.scroll_anim.active()) {
                const min_interval_ms: u64 = 16;
                const delay: u64 = delay: {
                    const last = self.last_draw_ts orelse break :delay 1;
                    const now: std.Io.Timestamp = .now(global.io(), .awake);
                    const since_ns = last.durationTo(now).nanoseconds;
                    if (since_ns <= 0) break :delay min_interval_ms;
                    const since_ms: u64 = @intCast(@divTrunc(since_ns, std.time.ns_per_ms));
                    break :delay min_interval_ms -| since_ms;
                };
                return .{ .delay_ms = @max(delay, 1), .kind = .draw };
            }

            return null;
        }

        /// Advance any in-flight scroll animation. The easing itself lives in
        /// scroll_anim.zig so it can be unit tested; this only supplies the
        /// clock.
        ///
        /// Must be called on the render thread.
        fn advanceScrollAnim(self: *Self) void {
            if (!self.scroll_anim.active()) return;

            const now: std.Io.Timestamp = .now(global.io(), .awake);
            const last = self.scroll_anim_last orelse {
                // First frame of this animation: no interval to integrate yet.
                self.scroll_anim_last = now;
                return;
            };
            self.scroll_anim_last = now;

            const dt_ms: f32 = @floatFromInt(@divTrunc(
                last.durationTo(now).nanoseconds,
                std.time.ns_per_ms,
            ));
            self.scroll_anim.advance(
                dt_ms,
                @floatFromInt(self.config.scroll_animation_duration_ms),
                self.config.scroll_animation_easing,
            );
            if (!self.scroll_anim.active()) {
                self.scroll_anim_last = null;
                self.clearScrollGhosts();
            }
        }

        /// Keep the rows a push of `rows` over this region is about to carry
        /// out of it. Must run BEFORE the push (to know whether it adds to
        /// the running animation) and before this frame's cells are rebuilt
        /// (`cells.fg_rows` still holds what was last drawn). See
        /// `ScrollAnim.captureGhosts`.
        fn keepScrollGhosts(self: *Self, rows: isize, top: usize, bottom: usize, left: usize, right: usize) void {
            if (!self.scroll_anim.accumulates(
                @floatFromInt(top),
                @floatFromInt(bottom),
                @floatFromInt(left),
                @floatFromInt(right),
            )) self.clearScrollGhosts();
            const nrows = self.cells.size.rows;
            if (nrows == 0 or bottom >= nrows) return;
            ScrollAnim.shiftGhosts(shaderpkg.CellText, &self.scroll_ghost, rows, top, bottom);
            const before = self.scroll_ghost.items.len;
            ScrollAnim.captureGhosts(
                shaderpkg.CellText,
                self.alloc,
                &self.scroll_ghost,
                self.cells.fg_rows[1 .. nrows + 1],
                rows,
                top,
                bottom,
                left,
                right,
            ) catch {
                self.clearScrollGhosts();
                return;
            };
            self.scroll_frame_push = .{ .rows = rows, .top = top, .bottom = bottom, .left = left, .right = right };
            // A pinned cell stays on screen; a kept copy of it would be a
            // second one sliding away (Claude Code's label, once per row).
            // The mask from the last computation, even between animations: the
            // first push of a new scroll captures before this frame's pins
            // exist, and a label that stayed put is still where it was.
            if (self.scroll_pin.items.len == nrows * self.cells.size.columns) {
                const pc = self.cells.size.columns;
                var w: usize = before;
                for (self.scroll_ghost.items[before..]) |g| {
                    const sy = ScrollAnim.ghostY(g.grid_pos[1]) + @as(i32, @intCast(rows));
                    const sx: usize = g.grid_pos[0];
                    if (sy >= 0 and sy < @as(i32, @intCast(nrows)) and sx < pc and
                        self.scroll_pin.items[@as(usize, @intCast(sy)) * pc + sx][1] != 0) continue;
                    self.scroll_ghost.items[w] = g;
                    w += 1;
                }
                self.scroll_ghost.shrinkRetainingCapacity(w);
            }
            if (comptime @hasField(@TypeOf(self.scroll_ghost.items[0].bools), "scroll_ghost")) {
                for (self.scroll_ghost.items[before..]) |*g| g.bools.scroll_ghost = true;
            } else {
                // A backend whose shader cannot draw them: keep none.
                self.clearScrollGhosts();
                return;
            }

            // Their backgrounds, the same way. `cells.bg_cells` still holds
            // what was last drawn, as `fg_rows` does above.
            const cols = self.cells.size.columns;
            const want = ScrollAnim.ghostBgLen(nrows, cols);
            if (self.scroll_ghost_bg.items.len != want) {
                self.scroll_ghost_bg.resize(self.alloc, want) catch {
                    self.clearScrollGhosts();
                    return;
                };
                @memset(self.scroll_ghost_bg.items, .{ 0, 0, 0, 0 });
            } else if (!self.scroll_ghost_bg_live) {
                @memset(self.scroll_ghost_bg.items, .{ 0, 0, 0, 0 });
            }
            ScrollAnim.shiftGhostBg(shaderpkg.CellBg, self.scroll_ghost_bg.items, cols, rows, top, bottom);
            ScrollAnim.captureGhostBg(shaderpkg.CellBg, self.scroll_ghost_bg.items, self.cells.bg_cells, cols, rows, top, bottom, left, right);
            self.scroll_ghost_bg_live = true;
            // Not the background of a pinned cell either (grey stripes of the
            // label's box sliding away in the band).
            if (self.scroll_pin.items.len == nrows * cols and rows != 0 and bottom >= top) {
                const g = ScrollAnim.max_ghost_rows;
                const n_dep: usize = @min(@abs(rows), bottom - top + 1, g);
                const first: usize = if (rows > 0) top else bottom + 1 - n_dep;
                for (first..first + n_dep) |y| {
                    const e = @as(isize, @intCast(y + g)) - rows;
                    if (e < 0 or @as(usize, @intCast(e)) * cols >= self.scroll_ghost_bg.items.len) continue;
                    // Under the label is unknown; carry the colour from its
                    // left (a diff's green stays green, plain text stays bare).
                    const row = self.scroll_ghost_bg.items[@as(usize, @intCast(e)) * cols ..][0..cols];
                    var fill: shaderpkg.CellBg = .{ 0, 0, 0, 0 };
                    for (0..cols) |c| {
                        if (self.scroll_pin.items[y * cols + c][0] != 0) row[c] = fill else fill = row[c];
                    }
                }
            }

            // And the image row slices, from the placements as last drawn.
            // (updateFrame holds `draw_mutex` here.)
            if (self.scroll_image_ghosts_stale) {
                self.images.kitty_ghosts.clearRetainingCapacity();
                self.scroll_image_ghosts_stale = false;
            }
            ScrollAnim.shiftGhostSlices(imagepkg.Placement, &self.images.kitty_ghosts, rows, top, bottom);
            ScrollAnim.captureGhostSlices(
                imagepkg.Placement,
                self.alloc,
                &self.images.kitty_ghosts,
                self.scroll_prev_images.items,
                rows,
                top,
                bottom,
                left,
                right,
            ) catch self.images.kitty_ghosts.clearRetainingCapacity();
        }

        /// Callable with or without `draw_mutex` held (drawFrame holds it
        /// when the animation ends): the image slices live in the image
        /// state drawFrame reads, so they are only marked here and emptied
        /// under the lock by the next `keepScrollGhosts`.
        fn clearScrollGhosts(self: *Self) void {
            self.scroll_pin_live = false;
            self.scroll_ghost.clearRetainingCapacity();
            self.scroll_ghost_bg_live = false;
            self.scroll_image_ghosts_stale = true;
        }

        /// Record that a key produced input, for the repaint detector's gate.
        ///
        /// Called from the render thread's mailbox.
        pub fn noteInputActivity(self: *Self) void {
            self.input_activity_ts = .now(global.io(), .awake);
        }

        /// Recover a scroll that an application performed by repainting.
        ///
        /// `had_event` is true when a real scroll event already described this
        /// frame. The hashes are still refreshed in that case -- the next
        /// frame has to compare against the truth -- but the movement has been
        /// animated already and counting it twice would double the offset.
        ///
        /// Hashes are only kept while a gesture is in progress, so this costs
        /// nothing at rest.
        fn detectRepaintScroll(self: *Self, had_event: bool) void {
            const now: std.Io.Timestamp = .now(global.io(), .awake);
            const sinceMs = struct {
                fn f(now_: std.Io.Timestamp, ts: ?std.Io.Timestamp) i64 {
                    const t = ts orelse return std.math.maxInt(i64);
                    return @intCast(@divTrunc(
                        t.durationTo(now_).nanoseconds,
                        std.time.ns_per_ms,
                    ));
                }
            }.f;

            // Only movement the user drove. Both the wheel and the keyboard
            // mark the same timestamp; the window is short enough that the
            // output of a command you just pressed Enter on does not slide,
            // and key repeat at roughly 30Hz keeps it fresh while a key is
            // held.
            if (sinceMs(now, self.input_activity_ts) > repaint_key_idle_ms and
                sinceMs(now, self.scroll_chain_ts) > repaint_chain_ms)
            {
                self.scroll_chain_ts = null;
                self.scroll_row_hashes.clearRetainingCapacity();
                self.scroll_hashes_before.clearRetainingCapacity();
                // The gesture is over, so the region an application declared
                // during it stops being what the next one will use.
                self.scroll_anim_app_region = null;
                return;
            }

            // A real scroll inside the gate is the gesture still going.
            if (had_event) self.scroll_chain_ts = now;

            const cells_list = self.terminal_state.row_data.items(.cells);
            const n = cells_list.len;
            const cols: usize = self.terminal_state.cols;
            if (n == 0 or cols == 0) return;

            // One hash per *cell*, not per row. A row hash cannot tell a
            // full-width scroll from one confined to a pane, and animating a
            // pane's rows across the whole width drags its neighbours along
            // and springs them back.
            const cur = self.alloc.alloc(u64, n * cols) catch return;
            defer self.alloc.free(cur);
            for (cells_list, 0..) |*cells, i| {
                const raw = cells.items(.raw);
                const graphemes = cells.items(.grapheme);
                const base = i * cols;
                for (0..cols) |c| {
                    // FNV-1a over the cell's bytes. Cheaper than Wyhash per
                    // cell, which is called ~12k times a frame here and is
                    // built for longer inputs.
                    //
                    // Packed with the glyph alone, so the detector can tell a
                    // cell whose text changed from one that was only
                    // repainted -- see `ScrollAnim.cellKey`. A space is as
                    // blank as an empty cell: TUIs pad with styled spaces,
                    // and those match each other at any offset.
                    cur[base + c] = if (c < raw.len) key: {
                        const cell = raw[c];
                        var h: u64 = 0xcbf29ce484222325;
                        for (std.mem.asBytes(&cell)) |b| {
                            h = (h ^ b) *% 0x100000001b3;
                        }
                        // And the combining marks, which live outside the raw
                        // cell. A Kitty image placeholder's row and column ARE
                        // its marks: without them every row of a figure hashed
                        // the same, read as unchanged, and the figure was left
                        // out of the region -- it snapped while text slid.
                        if (cell.content_tag == .codepoint_grapheme and c < graphemes.len) {
                            for (graphemes[c]) |gcp| {
                                h = (h ^ @as(u64, gcp)) *% 0x100000001b3;
                            }
                        }
                        const cp = cell.codepoint();
                        // Kitty image placeholders (U+10EEEE) keep their
                        // glyph: they cannot testify to a shift (see
                        // `ScrollAnim.testifies`) but do say which rows moved.
                        const glyph: u32 = if (!cell.hasText() or cp == ' ')
                            ScrollAnim.blank_glyph
                        else
                            cp;
                        break :key ScrollAnim.cellKey(glyph, @truncate(h ^ (h >> 32)));
                    } else ScrollAnim.cellKey(ScrollAnim.blank_glyph, 0);
                }
            }

            const prev = self.scroll_row_hashes.items;
            defer {
                self.scroll_hashes_before.clearRetainingCapacity();
                self.scroll_hashes_before.appendSlice(self.alloc, prev) catch {};
                self.scroll_row_hashes.clearRetainingCapacity();
                self.scroll_row_hashes.appendSlice(self.alloc, cur) catch {};
            }

            if (had_event) {
                self.scroll_pre_event_hashes.clearRetainingCapacity();
                self.scroll_pre_event_hashes.appendSlice(self.alloc, prev) catch {};
                return;
            }
            if (prev.len != cur.len) return;

            const shift = ScrollAnim.detectShift(
                cur,
                prev,
                n,
                cols,
                repaint_scroll_min_rows,
                repaint_scroll_min_ratio,
            ) orelse return;

            // Hold the detected rows inside the application's own scrolling
            // region. See `scroll_anim_app_region`: what *changed* is not the
            // same question as what *scrolled*, and a status line carrying a
            // position percentage changes on every frame of a scroll without
            // ever moving.
            var top = shift.top;
            var bottom = shift.bottom;
            if (self.scroll_anim_app_region) |r| {
                if (r.grid_rows == n) {
                    top = @max(top, r.top);
                    bottom = @min(bottom, r.bottom);
                    if (bottom < top) return;
                }
            } else if (bottom + 1 == n) {
                // Nothing has declared a region this gesture, so fall back to
                // the same manual reservation the event path applies when an
                // application names none -- otherwise the two producers
                // disagree about the last rows exactly as they did about the
                // status line. Only when the detected range actually reaches
                // the last row: a scroll that ends mid-screen has no
                // interface at its bottom edge to reserve.
                bottom = bottom -| self.config.scroll_animation_reserve_bottom;
                if (bottom < top) return;
            }

            // A FRAME CAUGHT MID-REDRAW. The frame with the event can be drawn
            // between the application's scroll command and its repaint of the
            // rows below it, so the NEXT frame's rows differ from that
            // half-done one -- and can match it a row the other way. nvim at
            // CSAPP ch. 2 line 2808 (a formula at the top of the window): `j`
            // gave `rows=1`, and 1 ms later `shift=-1 rows=7..52 cols=0..162`
            // against it, which slid the left three quarters of the page back
            // down, gutter included, and pinned a dozen runs of text. Against
            // the screen from before the event the same rows moved exactly as
            // the event said, so the event already animates them: drop it.
            if (self.scroll_anim_last_event) |le| {
                const pre = self.scroll_pre_event_hashes.items;
                if (sinceMs(now, le.ts) <= repair_partial_ms and
                    (shift.rows > 0) != (le.rows > 0) and pre.len == cur.len)
                {
                    if (ScrollAnim.detectShift(cur, pre, n, cols, repaint_scroll_min_rows, repaint_scroll_min_ratio)) |whole| {
                        if (whole.rows == le.rows) {
                            if (self.config.scroll_trace) log.info(
                                "repaintscroll partial shift={d} rows={d}..{d} cols={d}..{d} after rows={d} mono_us={d}",
                                .{ shift.rows, shift.top, shift.bottom, shift.left, shift.right, le.rows, @divTrunc(now.nanoseconds, std.time.ns_per_us) },
                            );
                            return;
                        }
                    }
                }
            }

            // The application's own scroll carried screen-fixed columns (the
            // relative line numbers) with it, and this is it rewriting them.
            if (self.scroll_anim_last_event) |le| {
                if (ScrollAnim.isRepair(le.rows, sinceMs(now, le.ts), cols, shift)) {
                    if (self.config.scroll_trace) log.info(
                        "repaintscroll repair shift={d} cols={d}..{d} after rows={d} mono_us={d}",
                        .{ shift.rows, shift.left, shift.right, le.rows, @divTrunc(now.nanoseconds, std.time.ns_per_us) },
                    );
                    return;
                }
            }

            // (A label held on screen -- Claude Code's "Jump to bottom" -- is
            // no longer cut out of the region by rows: its cells are pinned
            // individually after the rebuild, see `ScrollAnim.computePins`.)

            const cell_h: f32 = @floatFromInt(self.size.cell.height);
            const was_idle = !self.scroll_anim.active();
            self.keepScrollGhosts(shift.rows, top, bottom, shift.left, shift.right);
            self.scroll_anim.push(
                @as(f32, @floatFromInt(shift.rows)) * cell_h,
                @floatFromInt(top),
                @floatFromInt(bottom),
                @floatFromInt(shift.left),
                @floatFromInt(shift.right),
                cell_h * ScrollAnim.ghost_lag_rows,
            );
            if (was_idle) self.scroll_anim_last = null;
            self.scroll_chain_ts = now;

            if (self.config.scroll_trace) log.info(
                "repaintscroll shift={d} rows={d}..{d} clamped={d}..{d} cols={d}..{d} of {d}x{d} mono_us={d}",
                .{ shift.rows, shift.top, shift.bottom, top, bottom, shift.left, shift.right, n, cols, @divTrunc(std.Io.Timestamp.now(global.io(), .awake).nanoseconds, std.time.ns_per_us) },
            );
        }

        /// Emit one `scroll-trace` line for this frame.
        ///
        /// `model_rows` is where the terminal thinks the content is;
        /// `off_px` is how far from that it is actually being drawn. The
        /// analyzer reconstructs the drawn position as
        /// `-(model_rows * cell_h) + off_px` and checks that curve for the
        /// things eyes are bad at judging: reversals, stalls, and jumps.
        fn traceScrollFrame(self: *Self) void {
            const now: std.Io.Timestamp = .now(global.io(), .awake);
            const base = self.scroll_trace_base orelse base: {
                self.scroll_trace_base = now;
                break :base now;
            };
            const t_us = @divTrunc(base.durationTo(now).nanoseconds, std.time.ns_per_us);
            log.info(
                "scrolltrace t_us={d} model_rows={d} off_px={d:.3} top={d} bot={d} cell_h={d} mono_us={d} left={d} right={d}",
                .{
                    t_us,
                    self.scroll_trace_rows,
                    self.scroll_anim.offset_px,
                    self.scroll_anim.top,
                    self.scroll_anim.bottom,
                    self.size.cell.height,
                    @divTrunc(now.nanoseconds, std.time.ns_per_us),
                    self.scroll_anim.left,
                    self.scroll_anim.right,
                },
            );
        }

        /// True if our renderer is using vsync. If true, the renderer or apprt
        /// is responsible for triggering draw_now calls to the render thread.
        /// That is the only way to trigger a drawFrame.
        pub fn hasVsync(self: *const Self) bool {
            if (comptime DisplayLink == void) return false;
            const display_link = self.display_link orelse return false;
            return display_link.isRunning();
        }

        /// Callback when the focus changes for the terminal this is rendering.
        ///
        /// Must be called on the render thread.
        pub fn setFocus(self: *Self, focus: bool) !void {
            assert(self.focused != focus);

            self.focused = focus;

            // Flag that we need to update our custom shaders
            self.custom_shader_focused_changed = true;

            self.syncDisplayLink(null, null);
        }

        /// Callback when the window is visible or occluded.
        ///
        /// Must be called on the render thread.
        pub fn setVisible(self: *Self, visible: bool) void {
            self.visible = visible;
            self.syncDisplayLink(null, null);

            // When we're hidden, release our GPU resources if GPU
            // operations are allowed from this thread. Apprts where
            // they aren't (GTK owns the OpenGL context on the app
            // thread) call `releaseGpuResources` at the appropriate
            // time instead.
            if (comptime !apprt.must_draw_from_app_thread) {
                if (!visible) self.releaseGpuResources();
            }
        }

        /// Release the GPU resources we hold while the surface is not
        /// visible. Today this is the swap chain (render targets, font
        /// atlas texture copies, cell buffers, custom shader textures),
        /// which makes up nearly all of a surface's GPU memory usage;
        /// a hidden surface doesn't draw, so it doesn't need it. The
        /// swap chain is rebuilt on the next `drawFrame`.
        ///
        /// This is safe to call in any state; resources that are
        /// already released are skipped.
        ///
        /// For OpenGL this must be called on the app thread with the
        /// GL context current (the same requirement as
        /// `displayUnrealized`). Other APIs may call this from the
        /// render thread; see `apprt.must_draw_from_app_thread`.
        pub fn releaseGpuResources(self: *Self) void {
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());

            if (self.swap_chain) |*sc| {
                // Waits for any in-flight frames to complete, then
                // frees all GPU resources.
                sc.deinit();
                self.swap_chain = null;

                // Let the API drop any references it holds to swap
                // chain resources (e.g. OpenGL's last presented
                // target).
                if (comptime @hasDecl(GraphicsAPI, "gpuResourcesReleased")) {
                    self.api.gpuResourcesReleased();
                }
            }
        }

        /// Create or update the display link and match it to the current
        /// surface state.
        fn syncDisplayLink(
            self: *Self,
            display_id: ?u32,
            draw_now: ?*xev.Async,
        ) void {
            if (comptime DisplayLink == void) return;

            const display_link = self.display_link orelse display_link: {
                if (!self.config.vsync) return;
                const callback = draw_now orelse return;
                const result = macos.video.DisplayLink.createWithActiveCGDisplays() catch |err| {
                    // A locked macOS session can temporarily have no active
                    // displays. Rendering can continue without vsync and a
                    // later display update will retry this method.
                    log.warn("error creating display link; using fallback rendering err={}", .{err});
                    return;
                };
                result.setOutputCallback(
                    xev.Async,
                    &displayLinkCallback,
                    callback,
                ) catch |err| {
                    log.warn("error configuring display link err={}", .{err});
                    result.release();
                    return;
                };

                self.display_link = result;
                log.info("created display link", .{});
                break :display_link result;
            };

            if (display_id) |id| {
                log.info("updating display link display id={}", .{id});
                display_link.setCurrentCGDisplay(id) catch |err| {
                    log.warn("error setting display link display id err={}", .{err});
                };
            }

            const should_run =
                // Non-visible windows never vsync
                self.visible and
                // Only vsync if we have cell changes or animation
                (self.cells_rebuilt or self.animationWake() != null);

            if (should_run) {
                if (!display_link.isRunning()) {
                    display_link.start() catch {};
                }
            } else {
                display_link.stop() catch {};
            }
        }

        /// Set the new font grid.
        ///
        /// Must be called on the render thread.
        pub fn setFontGrid(self: *Self, grid: *font.SharedGrid) void {
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());

            // Update our grid
            self.font_grid = grid;

            // Update all our textures so that they sync on the next frame.
            // We can modify this without a lock because the GPU does not
            // touch this data. A released swap chain is rebuilt with
            // fresh frames that sync all textures on first use.
            if (self.swap_chain) |*sc| for (&sc.frames) |*frame| {
                frame.grayscale_modified = 0;
                frame.color_modified = 0;
            };

            // Get our metrics from the grid. This doesn't require a lock because
            // the metrics are never recalculated.
            const metrics = grid.metrics;
            self.grid_metrics = metrics;

            // Reset our shaper cache. If our font changed (not just the size) then
            // the data in the shaper cache may be invalid and cannot be used, so we
            // always clear the cache just in case.
            const font_shaper_cache = font.ShaperCache.init();
            self.font_shaper_cache.deinit(self.alloc);
            self.font_shaper_cache = font_shaper_cache;

            // Update cell size.
            self.size.cell = .{
                .width = metrics.cell_width,
                .height = metrics.cell_height,
            };

            // Update relevant uniforms
            self.updateFontGridUniforms();

            // Force a full rebuild, because cached rows may still reference
            // an outdated atlas from the old grid and this can cause garbage
            // to be rendered.
            self.markDirty();
        }

        /// Update uniforms that are based on the font grid.
        ///
        /// Caller must hold the draw mutex.
        fn updateFontGridUniforms(self: *Self) void {
            self.uniforms.cell_size = .{
                @floatFromInt(self.grid_metrics.cell_width),
                @floatFromInt(self.grid_metrics.cell_height),
            };
        }

        /// Update the frame data.
        pub fn updateFrame(
            self: *Self,
            state: *renderer.State,
            cursor_blink_visible: bool,
        ) Allocator.Error!void {
            // CoreText shaping accumulates objects for deferred release over
            // the course of a frame. Always flush those objects, including
            // when rebuilding the frame fails due to memory pressure.
            defer self.font_shaper.endFrame();

            // We fully deinit and reset the terminal state every so often
            // so that a particularly large terminal state doesn't cause
            // the renderer to hold on to retained memory.
            //
            // Frame count is ~12 minutes at 120Hz.
            const max_terminal_state_frame_count = 100_000;
            if (self.terminal_state_frame_count >= max_terminal_state_frame_count) {
                self.terminal_state.deinit(self.alloc);
                self.terminal_state = .empty;
                self.terminal_state_frame_count = 0;
            }
            self.terminal_state_frame_count += 1;

            // Create an arena for all our temporary allocations while rebuilding
            var arena = ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            // Data we extract out of the critical area.
            const Critical = struct {
                links: terminal.RenderState.CellSet,
                mouse: renderer.State.Mouse,
                preedit: ?renderer.State.Preedit,
                scrollbar: terminal.Scrollbar,
                overlay_features: []const Overlay.Feature,
                scroll_event: ?terminal.Terminal.ScrollEvent,
            };

            // Hold the draw mutex from here until the rebuilt cells are in
            // place. With GTK, frames are drawn on the app thread while this
            // runs on the renderer thread, and three things below change
            // what a draw would show before the cells catch up: the image
            // placements (kittyUpdate), the scroll offset (push), and the kept
            // band rows. A draw landing in between showed the old grid at the
            // new offset, or new image placements over the old grid -- for one
            // frame everything, or just a figure, sat a scroll's distance off
            // and came back ("the image jumps up a line and back"). The draw
            // thread waits at most one update for this.
            self.draw_mutex.lockUncancelable(global.io());
            var draw_held = true;
            defer if (draw_held) self.draw_mutex.unlock(global.io());

            // Update all our data as tightly as possible within the mutex.
            var critical: Critical = critical: {
                // NOTE: This code needs be updated to 0.16.0 before you
                // un-comment it ;)
                //
                // const start = try std.time.Instant.now();
                // const start_micro = std.time.microTimestamp();
                // defer {
                //     const end = std.time.Instant.now() catch unreachable;
                //     std.log.err("[updateFrame critical time] start={}\tduration={} us", .{ start_micro, end.since(start) / std.time.ns_per_us });
                // }

                state.lockDemand(global.io());
                defer state.unlockDemand(global.io());

                // If we're in a synchronized output state, we pause all rendering.
                if (state.terminal.modes.get(.synchronized_output)) {
                    log.debug("synchronized output started, skipping render", .{});
                    return;
                }

                // Drain any region scroll the terminal recorded since the last
                // frame. Left in place if we bail out above; it coalesces, so a
                // skipped frame costs accuracy of timing, not of position.
                const scroll_event = state.terminal.scroll_event;
                state.terminal.scroll_event = null;

                // If scroll-to-bottom on output is enabled, check if the final line
                // changed by comparing the bottom-right pin. If the node pointer or
                // y offset changed, new content was added to the screen.
                // Update this BEFORE we update our render state so we can
                // draw the new scrolled data immediately.
                if (self.config.scroll_to_bottom_on_output) scroll: {
                    const br = state.terminal.screens.active.pages.getBottomRight(.screen) orelse break :scroll;

                    // If the pin hasn't changed, then don't scroll.
                    if (self.last_bottom_node == @intFromPtr(br.node) and
                        self.last_bottom_y == br.y) break :scroll;

                    // Update tracked pin state for next frame
                    self.last_bottom_node = @intFromPtr(br.node);
                    self.last_bottom_y = br.y;

                    // Scroll
                    state.terminal.scrollViewport(.bottom);
                }

                // Begin the update of our terminal state. Work that
                // doesn't require terminal access (e.g. style
                // denormalization) is deferred to the endUpdate call
                // outside of this critical section, keeping our lock
                // hold time as short as possible.
                try self.terminal_state.beginUpdate(
                    self.alloc,
                    state.terminal,
                );

                // If our terminal state is dirty at all we need to redo
                // the viewport search.
                if (self.terminal_state.dirty != .false) {
                    state.terminal.flags.search_viewport_dirty = true;
                }

                // Get our scrollbar out of the terminal. We synchronize
                // the scrollbar read with frame data updates because this
                // naturally limits the number of calls to this method (it
                // can be expensive) and also makes it so we don't need another
                // cross-thread mailbox message within the IO path.
                const scrollbar = state.terminal.screens.active.pages.scrollbar();

                // Get our preedit state
                const preedit: ?renderer.State.Preedit = preedit: {
                    const p = state.preedit orelse break :preedit null;
                    break :preedit try p.clone(arena_alloc);
                };

                // Advance any running Kitty graphics animations to the
                // frame due now, and remember when the next frame is
                // due (as an absolute deadline, see animationWake) so
                // the renderer thread can schedule a wakeup for it.
                // This must happen before the dirty check below:
                // advancing a frame marks the image state dirty.
                self.kitty_animation_next_ms = next: {
                    // Likely case: we have no kitty images, so do nothing.
                    const storage = &state.terminal.screens.active.kitty_images;
                    if (storage.images.count() == 0) break :next null;

                    const now: std.Io.Timestamp = .now(global.io(), .awake);
                    const base = self.kitty_animation_clock orelse base: {
                        self.kitty_animation_clock = now;
                        break :base now;
                    };
                    const now_ms: u64 = @intCast(@divTrunc(
                        base.durationTo(now).nanoseconds,
                        std.time.ns_per_ms,
                    ));
                    const delay = storage.animationTick(
                        global.io(),
                        now_ms,
                    ) orelse break :next null;
                    break :next now_ms + delay;
                };

                // If we have Kitty graphics data, we enter a SLOW SLOW SLOW path.
                // We only do this if the Kitty image state is dirty meaning only if
                // it changes.
                //
                // If we have any virtual references, we must also rebuild our
                // kitty state on every frame because any cell change can move
                // an image.
                if (self.images.kittyRequiresUpdate(state.terminal)) {
                    // The draw mutex is already held (see above).
                    if (self.config.scroll_animation) {
                        self.scroll_prev_images.clearRetainingCapacity();
                        self.scroll_prev_images.appendSlice(self.alloc, self.images.kitty_placements.items) catch
                            self.scroll_prev_images.clearRetainingCapacity();
                    }
                    self.images.kittyUpdate(
                        self.alloc,
                        state.terminal,
                        .{
                            .width = self.grid_metrics.cell_width,
                            .height = self.grid_metrics.cell_height,
                        },
                    );
                }

                // Get our OSC8 links we're hovering if we have a mouse.
                // This requires terminal state because of URLs.
                const links: terminal.RenderState.CellSet = osc8: {
                    // If our mouse isn't hovering, we have no links.
                    const vp = state.mouse.point orelse break :osc8 .empty;

                    // If the right mods aren't pressed, then we can't match.
                    if (!state.mouse.mods.equal(inputpkg.ctrlOrSuper(.{})))
                        break :osc8 .empty;

                    break :osc8 self.terminal_state.linkCells(
                        arena_alloc,
                        vp,
                    ) catch |err| {
                        log.warn("error searching for OSC8 links err={}", .{err});
                        break :osc8 .empty;
                    };
                };

                const overlay_features: []const Overlay.Feature = overlay: {
                    const insp = state.inspector orelse break :overlay &.{};
                    const renderer_info = insp.rendererInfo();
                    break :overlay renderer_info.overlayFeatures(
                        arena_alloc,
                    ) catch &.{};
                };

                break :critical .{
                    .links = links,
                    .mouse = state.mouse,
                    .preedit = preedit,
                    .scrollbar = scrollbar,
                    .overlay_features = overlay_features,
                    .scroll_event = scroll_event,
                };
            };

            // Stage 2a of SPEC.md is detection only: prove we see the right
            // scrolls, with the right row counts and regions, before anything
            // visual depends on it. `index` is deliberately not yet hooked --
            // it fires on every newline at the bottom of the screen, and we
            // want to know what the deliberate-scroll traffic looks like on
            // its own first.
            if (critical.scroll_event) |ev| scroll: {
                // Promote to info while tracing so the harness works against
                // a release build; debug logs are compiled out of those, and a
                // debug build runs at ~40fps which swamps what we measure.
                if (self.config.scroll_trace) {
                    // Everything that decides whether a sub-row offset is
                    // applied here, so this does not have to be inferred:
                    // the *region* top (not the cursor row `top`), whether it
                    // counted as narrowed, and the offset actually drawn.
                    log.info(
                        "scroll event: rows={d} start={d} region={d}..{d} rows_total={d} src={s} cell_h={d} mono_us={d}",
                        .{
                            ev.rows,
                            ev.top,
                            ev.region_top,
                            ev.bottom,
                            self.size.grid().rows,
                            @tagName(ev.source),
                            self.size.cell.height,
                            @divTrunc(std.Io.Timestamp.now(global.io(), .awake).nanoseconds, std.time.ns_per_us),
                        },
                    );
                } else {
                    log.debug(
                        "scroll event: rows={d} region={d}..{d} source={s} enabled={} cell_h={d}",
                        .{ ev.rows, ev.top, ev.bottom, @tagName(ev.source), self.config.scroll_animation, self.size.cell.height },
                    );
                }

                // Before any filtering: the trace needs the model's true
                // position, including scrolls we deliberately do not animate.
                self.scroll_trace_rows += @intCast(ev.rows);

                // Remember the region so a sub-row displacement arriving
                // between scrolls moves the same rows, and leaves tmux's
                // status line alone.
                // Only remember a region the application has actually
                // narrowed. tmux and nvim set margins precisely so the rows
                // outside them -- a status line, a mode line -- hold still,
                // and that is the only signal we get about which rows are
                // content and which are interface.
                //
                // A region spanning the whole screen carries no such signal.
                // Claude Code, for one, sets no margins and redraws its prompt
                // box in place, so treating full-screen as "everything may
                // move" nudged the box and it sprang back on the next redraw.
                // Without the signal, hold still.
                // Adopt a region between gestures, never during one.
                //
                // Which end an application reserves says nothing useful: a
                // tmux status line sits at the top as readily as the bottom.
                // What matters is that the region stay *put* while a scroll is
                // in progress. Claude Code alternates between `0..54` and
                // `1..54` as it redraws, and re-deciding on each event
                // switched smoothing on and off between frames, snapping the
                // whole screen half a row back and forth. Freezing the choice
                // for the duration of the gesture removes that entirely, and
                // an application with a stable region -- tmux, nvim -- is
                // unaffected because there is nothing to re-decide.
                // `narrowed` says the application named its own interface
                // rows at one end or the other, which is better information
                // than a number in a config file. See the reserve below.
                const grid_rows = self.size.grid().rows;
                const narrowed = ev.region_top > 0 or ev.bottom + 1 < grid_rows;

                if (ev.rows != 0) self.scroll_anim_last_event = .{
                    .rows = @intCast(ev.rows),
                    .ts = .now(global.io(), .awake),
                };

                if (!self.config.scroll_animation) break :scroll;
                if (ev.rows == 0) break :scroll;

                // A jump this large is a page move, a full-screen redraw or a
                // burst of output, not a scroll. Animating it would sweep a
                // screenful of text past the eye more slowly than the instant
                // change it replaces. Drop any animation in flight too: it
                // describes rows that just stopped being where it thought.
                // Ghost rows (see `scroll_ghost`) let a longer scroll than the
                // detector's slide: they fill the band the lag uncovers.
                // A scroll of the region's whole height or more moves every
                // row out: nothing on screen before is on screen after, so it
                // is a clear, not a scroll. tmux uses exactly that to redraw
                // panes on unzoom (`C-a z`): rows=16 over region 2..17, and the
                // whole row of panes slid.
                const region_h: i64 = @as(i64, @intCast(ev.bottom)) - @as(i64, @intCast(ev.region_top)) + 1;
                if (region_h > 0 and @abs(@as(i64, ev.rows)) >= region_h) {
                    self.scroll_anim.stop();
                    self.clearScrollGhosts();
                    break :scroll;
                }
                if (@abs(ev.rows) > ScrollAnim.max_ghost_animated_rows) {
                    self.scroll_anim.stop();
                    self.clearScrollGhosts();
                    break :scroll;
                }

                // Displace by exactly the distance just scrolled, so the first
                // animated frame reproduces the pre-scroll screen, and ease to
                // zero from there. The model is already current -- writes land
                // during the animation and must not be delayed (SPEC stage 2)
                // -- so this only ever moves what is drawn.
                const cell_h: f32 = @floatFromInt(self.size.cell.height);
                const rows: f32 = @floatFromInt(ev.rows);
                const offset = rows * cell_h;

                // Cap how far behind the model the drawn position may fall.
                // Scrolls arrive faster than the ramp retires them during a
                // fling, so without a tight cap the offset winds up until the
                // whole block sits half a screen from where it belongs.
                const limit = cell_h * ScrollAnim.ghost_lag_rows;
                // Accumulate rather than replace, and only reset the clock
                // when starting from idle. Resetting it on every scroll would
                // skip the integration frame each time, so during continuous
                // scrolling the offset would never decay and would simply
                // wind up to the limit.
                // Hold back rows the user has reserved for an interface the
                // application pins but does not exclude from its own scrolling
                // region. Use the region's *margin*, not `ev.top`, which for
                // insert/delete lines is the cursor row.
                // Only when the application tells us *nothing*. A region
                // narrowed at either end is the application naming its own
                // interface rows, and that is better information than a
                // number typed into a config file -- subtracting from it as
                // well steals content rows and freezes them mid-scroll while
                // everything above slides, which is more jarring than the
                // interface wobble the reserve exists to stop.
                //
                // tmux run with `status-position top` is the case that proves
                // it: its region is 1..last, so it *reaches* the bottom row
                // and "does the region touch the bottom" cannot tell it apart
                // from Claude Code. That it narrows at the top can.
                const reserve: usize = if (narrowed)
                    0
                else
                    self.config.scroll_animation_reserve_bottom;
                const bottom = ev.bottom -| reserve;
                if (bottom < ev.region_top) break :scroll;

                // Remember it for the repaint detector, which cannot see a
                // scrolling margin and would otherwise animate the rows this
                // one deliberately leaves out. See `scroll_anim_app_region`.
                self.scroll_anim_app_region = .{
                    .top = ev.region_top,
                    .bottom = bottom,
                    .grid_rows = grid_rows,
                };

                const was_idle = !self.scroll_anim.active();
                self.keepScrollGhosts(
                    @intCast(ev.rows),
                    ev.region_top,
                    bottom,
                    0,
                    self.size.grid().columns -| 1,
                );
                self.scroll_anim.push(
                    offset,
                    @floatFromInt(ev.region_top),
                    @floatFromInt(bottom),
                    // An application that says it scrolled a region means the
                    // whole width of it; only repaint detection can see a
                    // scroll narrower than the screen.
                    0,
                    @floatFromInt(self.size.grid().columns -| 1),
                    limit,
                );
                if (was_idle) self.scroll_anim_last = null;
            }

            // Outside the critical area, complete the update we began
            // within it. This must be done before anything reads the
            // render state (e.g. rebuildCells).
            self.terminal_state.endUpdate();

            // A cursor pulse changes no cell, so nothing else would draw a
            // frame for it: note it here, and animationWake asks for frames.
            if (self.terminal_state.cursor.pulse != self.cursor_fx_pulse_seen) {
                self.cursor_fx_pulse_seen = self.terminal_state.cursor.pulse;
                self.cursor_fx_pulse_pending = true;
                self.cursor_fx_last_event = .now(global.io(), .awake);
            }

            // Now the render state is readable, look for movement no event
            // described. Must come after endUpdate: row_data is not valid
            // until the update it began is completed.
            if (self.config.scroll_animation) {
                self.detectRepaintScroll(critical.scroll_event != null);
            }

            // Outside the critical area we can update our links to contain
            // our regex results.
            self.config.links.renderCellMap(
                arena_alloc,
                &critical.links,
                &self.terminal_state,
                state.mouse.point,
                state.mouse.mods,
            ) catch |err| {
                log.warn("error searching for regex links err={}", .{err});
            };

            // Clear our highlight state and update.
            if (self.search_matches_dirty or self.terminal_state.dirty != .false) {
                self.search_matches_dirty = false;

                // Clear the prior highlights
                const row_data = self.terminal_state.row_data.slice();
                var any_dirty: bool = false;
                for (
                    row_data.items(.highlights),
                    row_data.items(.dirty),
                ) |*highlights, *dirty| {
                    if (highlights.items.len > 0) {
                        highlights.clearRetainingCapacity();
                        dirty.* = true;
                        any_dirty = true;
                    }
                }
                if (any_dirty and self.terminal_state.dirty == .false) {
                    self.terminal_state.dirty = .partial;
                }

                // NOTE: The order below matters. Highlights added earlier
                // will take priority.

                if (self.search_selected_match) |m| {
                    self.terminal_state.updateHighlightsFlattened(
                        self.alloc,
                        @intFromEnum(HighlightTag.search_match_selected),
                        &.{m.match},
                    ) catch |err| {
                        // Not a critical error, we just won't show highlights.
                        log.warn("error updating search selected highlight err={}", .{err});
                    };
                }

                if (self.search_matches) |m| {
                    self.terminal_state.updateHighlightsFlattened(
                        self.alloc,
                        @intFromEnum(HighlightTag.search_match),
                        m.matches,
                    ) catch |err| {
                        // Not a critical error, we just won't show highlights.
                        log.warn("error updating search highlights err={}", .{err});
                    };
                }
            }

            // From this point forward no more errors.
            errdefer comptime unreachable;

            // Reset our dirty state after updating.
            defer self.terminal_state.dirty = .false;

            // Rebuild the overlay image if we have one. We can do this
            // outside of any critical areas.
            self.rebuildOverlay(
                critical.overlay_features,
            ) catch |err| {
                log.warn(
                    "error rebuilding overlay surface err={}",
                    .{err},
                );
            };

            // Still under the draw mutex taken above, for all remaining
            // state updates.
            {
                // Overlay pins compare this frame's backgrounds with the last.
                const pin_push = self.scroll_frame_push;
                self.scroll_frame_push = null;
                if (pin_push != null) {
                    self.scroll_bg_prev.clearRetainingCapacity();
                    self.scroll_bg_prev.appendSlice(self.alloc, self.cells.bg_cells) catch
                        self.scroll_bg_prev.clearRetainingCapacity();
                }

                // Build our GPU cells
                self.rebuildCells(
                    critical.preedit,
                    renderer.cursorStyle(&self.terminal_state, .{
                        .preedit = critical.preedit != null,
                        .focused = self.focused,
                        .blink_visible = cursor_blink_visible,
                    }),
                    &critical.links,
                ) catch |err| {
                    // This means we weren't able to allocate our buffer
                    // to update the cells. In this case, we continue with
                    // our old buffer (frozen contents) and log it.
                    comptime assert(@TypeOf(err) == error{OutOfMemory});
                    log.warn("error rebuilding GPU cells err={}", .{err});
                };

                if (pin_push) |pp| pins: {
                    const n = self.cells.bg_cells.len;
                    if (self.scroll_bg_prev.items.len != n) break :pins;
                    self.scroll_pin.resize(self.alloc, n) catch break :pins;
                    // Over everything the running animation displaces, not just
                    // this push's rows: pushes jitter a row (1..48, then 1..49)
                    // and the union is what the shaders move -- a label on the
                    // row one push left out still slid with the next.
                    const a = self.scroll_anim;
                    const f2u = struct {
                        fn f(v: f32, dflt: usize) usize {
                            return if (v >= 0) @intFromFloat(v) else dflt;
                        }
                    }.f;
                    ScrollAnim.computePins(
                        shaderpkg.CellBg,
                        self.scroll_pin.items,
                        self.scroll_bg_prev.items,
                        self.cells.bg_cells,
                        self.cells.size.columns,
                        pp.rows,
                        if (a.active()) @min(pp.top, f2u(a.top, pp.top)) else pp.top,
                        if (a.active()) @min(@max(pp.bottom, f2u(a.bottom, pp.bottom)), self.cells.size.rows - 1) else pp.bottom,
                        if (a.active()) @min(pp.left, f2u(a.left, pp.left)) else pp.left,
                        if (a.active()) @min(@max(pp.right, f2u(a.right, pp.right)), self.cells.size.columns - 1) else pp.right,
                    );
                    ScrollAnim.markPinnedText(
                        shaderpkg.CellBg,
                        self.scroll_pin.items,
                        self.scroll_row_hashes.items,
                        self.scroll_hashes_before.items,
                        self.cells.size.columns,
                    );
                    self.scroll_pin_live = self.scroll_anim.active();
                    if (self.config.scroll_trace) {
                        const pc = self.cells.size.columns;
                        for (0..self.cells.size.rows) |r| {
                            var first: ?usize = null;
                            var cnt: usize = 0;
                            for (0..pc) |c| if (self.scroll_pin.items[r * pc + c][0] != 0) {
                                if (first == null) first = c;
                                cnt += 1;
                            };
                            if (cnt > 0) log.info("scrollpin row={d} col={d} n={d} text={} shift={d}", .{ r, first.?, cnt, self.scroll_pin.items[r * pc + first.?][1] != 0, pp.rows });
                        }
                    }
                }

                // The scrollbar is only emitted during draws so we also
                // check the scrollbar cache here and update if needed.
                // This is pretty fast.
                if (!self.scrollbar.eql(critical.scrollbar)) {
                    self.scrollbar = critical.scrollbar;
                    self.scrollbar_dirty = true;
                }

                // Update our background color
                self.uniforms.bg_color = .{
                    self.terminal_state.colors.background.r,
                    self.terminal_state.colors.background.g,
                    self.terminal_state.colors.background.b,
                    @intFromFloat(@round(self.config.background_opacity * 255.0)),
                };

                // If we're on macOS and have glass styles, we remove
                // the background opacity because the glass effect handles
                // it.
                if (comptime builtin.os.tag == .macos) switch (self.config.background_blur) {
                    .@"macos-glass-regular",
                    .@"macos-glass-clear",
                    => self.uniforms.bg_color[3] = 0,

                    else => {},
                };

                // Prepare our overlay image for upload (or unload). This
                // has to use our general allocator since it modifies
                // state that survives frames.
                self.images.overlayUpdate(
                    self.alloc,
                    self.overlay,
                ) catch |err| {
                    log.warn("error updating overlay images err={}", .{err});
                };

                // Update custom shader uniforms that depend on terminal state.
                self.updateCustomShaderUniformsFromState();
            }
            self.draw_mutex.unlock(global.io());
            draw_held = false;

            // Start the display link now that the rebuilt frame is ready.
            self.syncDisplayLink(null, null);
        }

        /// Draw the frame to the screen.
        ///
        /// If `sync` is true, this will synchronously block until
        /// the frame is finished drawing and has been presented.
        pub fn drawFrame(
            self: *Self,
            sync: bool,
        ) !void {
            // We hold a the draw mutex to prevent changes to any
            // data we access while we're in the middle of drawing.
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());

            // After the graphics API is complete (so we defer) we want to
            // update our scrollbar state.
            defer if (self.scrollbar_dirty) {
                // Fail instantly if the surface mailbox if full, we'll just
                // get it on the next frame.
                if (self.surface_mailbox.push(.{
                    .scrollbar = self.scrollbar,
                }, .instant) > 0) self.scrollbar_dirty = false;
            };

            // Let our graphics API do any bookkeeping, etc.
            // that it needs to do before / after `drawFrame`.
            self.api.drawFrameStart();
            defer self.api.drawFrameEnd();

            // Retrieve the most up-to-date surface size from the Graphics API
            const surface_size = try self.api.surfaceSize();

            // If either of our surface dimensions is zero
            // then drawing is absurd, so we just return.
            if (surface_size.width == 0 or surface_size.height == 0) return;

            // If we have no graphics context we can't draw. This is
            // only the case while unrealized (GTK); displayRealized
            // rebuilds the swap chain.
            if (!self.display_realized) return;

            // Get our swap chain, rebuilding it if it was released
            // while we were hidden. Rebuilding is deferred to draw
            // time because resource creation must happen somewhere
            // our graphics API allows it (OpenGL requires a current
            // context, which drawFrame guarantees).
            const swap_chain: *SwapChain, const swap_chain_rebuilt: bool =
                if (self.swap_chain) |*sc| .{ sc, false } else rebuild: {
                    self.swap_chain = try SwapChain.init(
                        self.api,
                        self.has_custom_shaders,
                    );
                    break :rebuild .{ &self.swap_chain.?, true };
                };

            const size_changed =
                self.size.screen.width != surface_size.width or
                self.size.screen.height != surface_size.height;

            // Conditions under which we need to draw the frame, otherwise we
            // don't need to since the previous frame should be identical.
            //
            // While any animation is in progress (a pending animation wake)
            // every draw must actually render.
            const needs_redraw =
                size_changed or
                swap_chain_rebuilt or
                self.cells_rebuilt or
                self.animationWake() != null or
                sync;

            if (!needs_redraw) {
                // We still need to present the last target again, because the
                // apprt may be swapping buffers and display an outdated frame
                // if we don't draw something new.
                try self.api.presentLastTarget();

                // Resync the display link because we can probably pause
                // the display link at this point.
                self.syncDisplayLink(null, null);
                return;
            }
            self.cells_rebuilt = false;
            self.last_draw_ts = .now(global.io(), .awake);

            // Wait for a frame to be available.
            const frame = swap_chain.nextFrame();
            errdefer swap_chain.releaseFrame();
            // log.debug("drawing frame index={}", .{swap_chain.frame_index});

            // If we need to reinitialize our shaders, do so.
            if (self.reinitialize_shaders) {
                self.reinitialize_shaders = false;
                self.shaders.deinit(self.alloc);
                try self.initShaders();
            }

            // Our shaders should not be defunct at this point.
            assert(!self.shaders.defunct);

            // If we have custom shaders, make sure we have the
            // custom shader state in our frame state, otherwise
            // if we have a state but don't need it we remove it.
            if (self.has_custom_shaders) {
                if (frame.custom_shader_state == null) {
                    frame.custom_shader_state = try .init(self.api);
                    try frame.custom_shader_state.?.resize(
                        self.api,
                        surface_size.width,
                        surface_size.height,
                    );
                }
            } else if (frame.custom_shader_state) |*state| {
                state.deinit();
                frame.custom_shader_state = null;
            }

            // If our stored size doesn't match the
            // surface size we need to update it.
            if (size_changed) {
                self.size.screen = .{
                    .width = surface_size.width,
                    .height = surface_size.height,
                };
                self.updateScreenSizeUniforms();
            }

            // If this frame's target isn't the correct size, or the target
            // config has changed (such as when the blending mode changes),
            // remove it and replace it with a new one with the right values.
            if (frame.target.width != self.size.screen.width or
                frame.target.height != self.size.screen.height or
                frame.target_config_modified != self.target_config_modified)
            {
                try frame.resize(
                    self.api,
                    self.size.screen.width,
                    self.size.screen.height,
                );
                frame.target_config_modified = self.target_config_modified;
            }

            // Upload images to the GPU as necessary.
            _ = self.images.upload(self.alloc, &self.api);

            // Upload the background image to the GPU as necessary.
            try self.uploadBackgroundImage();

            // Update per-frame custom shader uniforms.
            try self.updateCustomShaderUniformsForFrame();

            // Setup our frame data
            // Advance any scroll animation and publish it to the shaders.
            // Done here, immediately before upload, so the value drawn is the
            // value computed for this frame.
            self.advanceScrollAnim();
            if (self.config.scroll_trace) self.traceScrollFrame();
            const total_off = self.scroll_anim.offset_px;
            const top: f32, const bot: f32 = if (self.scroll_anim.active())
                .{ self.scroll_anim.top, self.scroll_anim.bottom }
            else
                .{ 0, 0 };
            // Whole device pixels. Glyphs are sampled from the atlas with
            // linear filtering, so a fractional offset draws every glyph
            // blended across two pixel rows: soft, doubled strokes and a
            // visibly dimmer screen for as long as anything moves, which
            // read as the screen dimming and brightening on every scroll.
            // A rounded offset moves at most half a pixel off the curve.
            self.uniforms.scroll_anim = .{
                if (@abs(total_off) < ScrollAnim.min_offset_px) 0 else @round(total_off),
                top,
                bot,
                0,
            };
            // Full width unless a repaint-detected scroll narrowed it.
            const cols_f: f32 = @floatFromInt(self.size.grid().columns -| 1);
            self.uniforms.scroll_anim_cols = if (self.scroll_anim.active())
                .{ self.scroll_anim.left, self.scroll_anim.right, 0, 0 }
            else
                .{ 0, cols_f, 0, 0 };

            try frame.uniforms.sync(&.{self.uniforms});
            self.images.kitty_ghosts_live = self.scroll_anim.active() and
                !self.scroll_image_ghosts_stale and self.images.kitty_ghosts.items.len > 0;
            const grid_n: usize = @as(usize, self.cells.size.rows) * self.cells.size.columns;
            const ghost_bg = self.scroll_anim.active() and self.scroll_ghost_bg_live and
                self.scroll_ghost_bg.items.len == ScrollAnim.ghostBgLen(self.cells.size.rows, self.cells.size.columns);
            const pinned = self.scroll_anim.active() and self.scroll_pin_live and
                self.scroll_pin.items.len == grid_n;
            if (ghost_bg or pinned) {
                // The kept rows' backgrounds ride after the grid's own (found
                // through `scroll_anim[3]`), then the pin mask (found through
                // `scroll_anim_cols[3]`, its offset; 0 = none).
                self.scroll_bg_view.clearRetainingCapacity();
                try self.scroll_bg_view.append(self.alloc, .{ .items = self.cells.bg_cells, .capacity = self.cells.bg_cells.len });
                var off = grid_n;
                if (ghost_bg) {
                    try self.scroll_bg_view.append(self.alloc, self.scroll_ghost_bg);
                    off += self.scroll_ghost_bg.items.len;
                    self.uniforms.scroll_anim[3] = @floatFromInt(ScrollAnim.max_ghost_rows);
                }
                if (pinned) {
                    try self.scroll_bg_view.append(self.alloc, self.scroll_pin);
                    self.uniforms.scroll_anim_cols[3] = @floatFromInt(off);
                }
                _ = try frame.cells_bg.syncFromArrayLists(self.scroll_bg_view.items);
                try frame.uniforms.sync(&.{self.uniforms});
            } else try frame.cells_bg.sync(self.cells.bg_cells);
            const fg_count = if (self.scroll_anim.active() and self.scroll_ghost.items.len > 0) ghosted: {
                self.scroll_ghost_view.clearRetainingCapacity();
                try self.scroll_ghost_view.appendSlice(self.alloc, self.cells.fg_rows);
                try self.scroll_ghost_view.append(self.alloc, self.scroll_ghost);
                break :ghosted try frame.cells.syncFromArrayLists(self.scroll_ghost_view.items);
            } else try frame.cells.syncFromArrayLists(self.cells.fg_rows);

            // If our background image buffer has changed, sync it.
            if (frame.bg_image_buffer_modified != self.bg_image_buffer_modified) {
                try frame.bg_image_buffer.sync(&.{self.bg_image_buffer});

                frame.bg_image_buffer_modified = self.bg_image_buffer_modified;
            }

            // If our font atlas changed, sync the texture data
            texture: {
                const modified = self.font_grid.atlas_grayscale.modified.load(.monotonic);
                if (modified <= frame.grayscale_modified) break :texture;
                self.font_grid.lock.lockSharedUncancelable(global.io());
                defer self.font_grid.lock.unlockShared(global.io());
                frame.grayscale_modified = self.font_grid.atlas_grayscale.modified.load(.monotonic);
                try self.syncAtlasTexture(&self.font_grid.atlas_grayscale, &frame.grayscale);
            }
            texture: {
                const modified = self.font_grid.atlas_color.modified.load(.monotonic);
                if (modified <= frame.color_modified) break :texture;
                self.font_grid.lock.lockSharedUncancelable(global.io());
                defer self.font_grid.lock.unlockShared(global.io());
                frame.color_modified = self.font_grid.atlas_color.modified.load(.monotonic);
                try self.syncAtlasTexture(&self.font_grid.atlas_color, &frame.color);
            }

            // Get a frame context from the graphics API.
            var frame_ctx = try self.api.beginFrame(self, &frame.target);
            defer frame_ctx.complete(sync);

            {
                var pass = frame_ctx.renderPass(&.{.{
                    .target = if (frame.custom_shader_state) |state|
                        .{ .texture = state.back_texture }
                    else
                        .{ .target = frame.target },
                    .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                }});
                defer pass.complete();

                // First we draw our background image, if we have one.
                // The bg image shader also draws the main bg color.
                //
                // Otherwise, if we don't have a background image, we
                // draw the background color by itself in its own step.
                //
                // NOTE: We don't use the clear_color for this because that
                //       would require us to do color space conversion on the
                //       CPU-side. In the future when we have utilities for
                //       that we should remove this step and use clear_color.
                if (self.bg_image) |img| switch (img) {
                    .ready => |texture| pass.step(.{
                        .pipeline = self.shaders.pipelines.bg_image,
                        .uniforms = frame.uniforms.buffer,
                        .buffers = &.{frame.bg_image_buffer.buffer},
                        .textures = &.{texture},
                        .draw = .{ .type = .triangle, .vertex_count = 3 },
                    }),
                    else => {},
                } else {
                    pass.step(.{
                        .pipeline = self.shaders.pipelines.bg_color,
                        .uniforms = frame.uniforms.buffer,
                        .buffers = &.{ null, frame.cells_bg.buffer },
                        .draw = .{ .type = .triangle, .vertex_count = 3 },
                    });
                }

                // Then we draw any kitty images that need
                // to be behind text AND cell backgrounds.
                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .kitty_below_bg,
                );

                // Then we draw any opaque cell backgrounds.
                pass.step(.{
                    .pipeline = self.shaders.pipelines.cell_bg,
                    .uniforms = frame.uniforms.buffer,
                    .buffers = &.{ null, frame.cells_bg.buffer },
                    .draw = .{ .type = .triangle, .vertex_count = 3 },
                });

                // Kitty images between cell backgrounds and text.
                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .kitty_below_text,
                );

                // Text.
                pass.step(.{
                    .pipeline = self.shaders.pipelines.cell_text,
                    .uniforms = frame.uniforms.buffer,
                    .buffers = &.{
                        frame.cells.buffer,
                        frame.cells_bg.buffer,
                    },
                    .textures = &.{
                        frame.grayscale,
                        frame.color,
                    },
                    .draw = .{
                        .type = .triangle_strip,
                        .vertex_count = 4,
                        .instance_count = fg_count,
                    },
                });

                // Kitty images in front of text.
                self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .kitty_above_text,
                );

                // Debug overlay. We do this before any custom shader state
                // because our debug overlay is aligned with the grid.
                if (self.overlay != null) self.images.draw(
                    &self.api,
                    self.shaders.pipelines.image,
                    &pass,
                    .overlay,
                );
            }

            // If we have custom shaders, then we render them.
            if (frame.custom_shader_state) |*state| {
                // Sync our uniforms.
                try state.uniforms.sync(&.{self.custom_shader_uniforms});

                for (self.shaders.post_pipelines, 0..) |pipeline, i| {
                    defer state.swap();

                    var pass = frame_ctx.renderPass(&.{.{
                        .target = if (i < self.shaders.post_pipelines.len - 1)
                            .{ .texture = state.front_texture }
                        else
                            .{ .target = frame.target },
                        .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                    }});
                    defer pass.complete();

                    pass.step(.{
                        .pipeline = pipeline,
                        .uniforms = state.uniforms.buffer,
                        .textures = &.{state.back_texture},
                        .samplers = &.{state.sampler},
                        .draw = .{
                            .type = .triangle,
                            .vertex_count = 3,
                        },
                    });
                }
            }
        }

        // Callback from the graphics API when a frame is completed.
        pub fn frameCompleted(
            self: *Self,
            health: Health,
        ) void {
            // If our health value hasn't changed, then we do nothing. We don't
            // do a cmpxchg here because strict atomicity isn't important.
            if (self.health.load(.seq_cst) != health) {
                self.health.store(health, .seq_cst);

                // Our health value changed, so we notify the surface so that it
                // can do something about it.
                _ = self.surface_mailbox.push(.{
                    .renderer_health = health,
                }, .{ .forever = {} });
            }

            // Always release our semaphore. The swap chain is
            // guaranteed to exist here: it is only torn down after
            // waiting for all in-flight frames to complete, and this
            // callback is what signals that completion.
            self.swap_chain.?.releaseFrame();
        }

        /// Call this any time the background image path changes.
        ///
        /// Caller must hold the draw mutex.
        fn prepBackgroundImage(self: *Self) !void {
            // Then we try to load the background image if we have a path.
            if (self.config.bg_image) |p| load_background: {
                const path = switch (p) {
                    .required, .optional => |slice| slice,
                };

                // Open the file
                var file = std.Io.Dir.openFileAbsolute(
                    global.io(),
                    path,
                    .{},
                ) catch |err| {
                    log.warn(
                        "error opening background image file \"{s}\": {}",
                        .{ path, err },
                    );
                    break :load_background;
                };
                defer file.close(global.io());

                // Read it
                const contents = compat_file.readToEndAlloc(
                    file,
                    self.alloc,
                    std.math.maxInt(u32), // Max size of 4 GiB, for now.
                ) catch |err| {
                    log.warn(
                        "error reading background image file \"{s}\": {}",
                        .{ path, err },
                    );
                    break :load_background;
                };
                defer self.alloc.free(contents);

                // Figure out what type it probably is.
                const file_type = switch (FileType.detect(contents)) {
                    .unknown => FileType.guessFromExtension(
                        std.fs.path.extension(path),
                    ),
                    else => |t| t,
                };

                // Decode it if we know how.
                const image_data = switch (file_type) {
                    .png => try wuffs.png.decode(self.alloc, contents),
                    .jpeg => try wuffs.jpeg.decode(self.alloc, contents),
                    .unknown => {
                        log.warn(
                            "Cannot determine file type for background image file \"{s}\"!",
                            .{path},
                        );
                        break :load_background;
                    },
                    else => |f| {
                        log.warn(
                            "Unsupported file type {} for background image file \"{s}\"!",
                            .{ f, path },
                        );
                        break :load_background;
                    },
                };

                const image: imagepkg.Image = .{
                    .pending = .{
                        .width = image_data.width,
                        .height = image_data.height,
                        .pixel_format = .rgba,
                        .data = image_data.data.ptr,
                    },
                };

                // If we have an existing background image, replace it.
                // Otherwise, set this as our background image directly.
                if (self.bg_image) |*img| {
                    img.markForReplace(self.alloc, image);
                } else {
                    self.bg_image = image;
                }
            } else {
                // If we don't have a background image path, mark our
                // background image for unload if we currently have one.
                if (self.bg_image) |*img| img.markForUnload();
            }
        }

        fn uploadBackgroundImage(self: *Self) !void {
            // Make sure our bg image is uploaded if it needs to be.
            if (self.bg_image) |*bg| {
                if (bg.isUnloading()) {
                    bg.deinit(self.alloc);
                    self.bg_image = null;
                    return;
                }
                if (bg.isPending()) try bg.upload(self.alloc, &self.api);
            }
        }

        /// Update the configuration.
        pub fn changeConfig(self: *Self, config: *DerivedConfig) !void {
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());

            // We always redo the font shaper in case font features changed. We
            // could check to see if there was an actual config change but this is
            // easier and rare enough to not cause performance issues.
            {
                var font_shaper = try font.Shaper.init(self.alloc, .{
                    .features = config.font_features.items,
                });
                errdefer font_shaper.deinit();
                self.font_shaper.deinit();
                self.font_shaper = font_shaper;
            }

            // We also need to reset the shaper cache so shaper info
            // from the previous font isn't reused for the new font.
            const font_shaper_cache = font.ShaperCache.init();
            self.font_shaper_cache.deinit(self.alloc);
            self.font_shaper_cache = font_shaper_cache;

            // Set our new minimum contrast
            self.uniforms.min_contrast = config.min_contrast;

            // Set our new color space and blending
            self.uniforms.bools.use_display_p3 = config.colorspace == .@"display-p3";
            self.uniforms.bools.use_linear_blending = config.blending.isLinear();
            self.uniforms.bools.use_linear_correction = config.blending == .@"linear-corrected";

            const bg_image_config_changed =
                self.config.bg_image_fit != config.bg_image_fit or
                self.config.bg_image_position != config.bg_image_position or
                self.config.bg_image_repeat != config.bg_image_repeat or
                self.config.bg_image_opacity != config.bg_image_opacity;

            const bg_image_changed =
                if (self.config.bg_image) |old|
                    if (config.bg_image) |new|
                        !old.equal(new)
                    else
                        true
                else
                    config.bg_image != null;

            const old_blending = self.config.blending;
            const custom_shaders_changed = !self.config.custom_shaders.equal(config.custom_shaders);

            self.config.deinit();
            self.config = config.*;

            // If our background image path changed, prepare the new bg image.
            if (bg_image_changed) try self.prepBackgroundImage();

            // If our background image config changed, update the vertex buffer.
            if (bg_image_config_changed) self.updateBgImageBuffer();

            // Reset our viewport to force a rebuild, in case of a font change.
            self.markDirty();

            const blending_changed = old_blending != config.blending;

            if (blending_changed) {
                // We update our API's blending mode.
                self.api.blending = config.blending;
                // And indicate that we need to reinitialize our shaders.
                self.reinitialize_shaders = true;
                // And indicate that our swap chain targets need to
                // be re-created to account for the new blending mode.
                self.target_config_modified +%= 1;
            }

            if (custom_shaders_changed) {
                self.reinitialize_shaders = true;
            }
        }

        /// Resize the screen.
        pub fn setScreenSize(
            self: *Self,
            size: renderer.Size,
        ) void {
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());

            // We only actually need the padding from this,
            // everything else is derived elsewhere.
            self.size.padding = size.padding;

            self.updateScreenSizeUniforms();

            log.debug("screen size size={}", .{size});
        }

        /// Update uniforms that are based on the screen size.
        ///
        /// Caller must hold the draw mutex.
        fn updateScreenSizeUniforms(self: *Self) void {
            const terminal_size = self.size.terminal();

            // Blank space around the grid.
            const blank: renderer.Padding = self.size.screen.blankPadding(
                self.size.padding,
                .{
                    .columns = self.cells.size.columns,
                    .rows = self.cells.size.rows,
                },
                .{
                    .width = self.grid_metrics.cell_width,
                    .height = self.grid_metrics.cell_height,
                },
            ).add(self.size.padding);

            // Setup our uniforms
            self.uniforms.projection_matrix = math.ortho2d(
                -1 * @as(f32, @floatFromInt(self.size.padding.left)),
                @floatFromInt(terminal_size.width + self.size.padding.right),
                @floatFromInt(terminal_size.height + self.size.padding.bottom),
                -1 * @as(f32, @floatFromInt(self.size.padding.top)),
            );
            self.uniforms.grid_padding = .{
                @floatFromInt(blank.top),
                @floatFromInt(blank.right),
                @floatFromInt(blank.bottom),
                @floatFromInt(blank.left),
            };
            self.uniforms.screen_size = .{
                @floatFromInt(self.size.screen.width),
                @floatFromInt(self.size.screen.height),
            };
        }

        /// Update the background image vertex buffer (CPU-side).
        ///
        /// This should be called if and when configs change that
        /// could affect the background image.
        ///
        /// Caller must hold the draw mutex.
        fn updateBgImageBuffer(self: *Self) void {
            self.bg_image_buffer = .{
                .opacity = self.config.bg_image_opacity,
                .info = .{
                    .position = switch (self.config.bg_image_position) {
                        .@"top-left" => .tl,
                        .@"top-center" => .tc,
                        .@"top-right" => .tr,
                        .@"center-left" => .ml,
                        .@"center-center", .center => .mc,
                        .@"center-right" => .mr,
                        .@"bottom-left" => .bl,
                        .@"bottom-center" => .bc,
                        .@"bottom-right" => .br,
                    },
                    .fit = switch (self.config.bg_image_fit) {
                        .contain => .contain,
                        .cover => .cover,
                        .stretch => .stretch,
                        .none => .none,
                    },
                    .repeat = self.config.bg_image_repeat,
                },
            };
            // Signal that the buffer was modified.
            self.bg_image_buffer_modified +%= 1;
        }

        /// Update custom shader uniforms that depend on terminal state.
        ///
        /// This should be called in `updateFrame` when terminal state changes.
        fn updateCustomShaderUniformsFromState(self: *Self) void {
            // We only need to do this if we have custom shaders.
            if (!self.has_custom_shaders) return;

            // Only update when terminal state is dirty.
            if (self.terminal_state.dirty == .false) return;

            const uniforms: *shadertoy.Uniforms = &self.custom_shader_uniforms;
            const colors: *const terminal.RenderState.Colors = &self.terminal_state.colors;

            // 256-color palette
            for (colors.palette, 0..) |color, i| {
                uniforms.palette[i] = .{
                    @as(f32, @floatFromInt(color.r)) / 255.0,
                    @as(f32, @floatFromInt(color.g)) / 255.0,
                    @as(f32, @floatFromInt(color.b)) / 255.0,
                    1.0,
                };
            }

            // Background color
            uniforms.background_color = .{
                @as(f32, @floatFromInt(colors.background.r)) / 255.0,
                @as(f32, @floatFromInt(colors.background.g)) / 255.0,
                @as(f32, @floatFromInt(colors.background.b)) / 255.0,
                1.0,
            };

            // Foreground color
            uniforms.foreground_color = .{
                @as(f32, @floatFromInt(colors.foreground.r)) / 255.0,
                @as(f32, @floatFromInt(colors.foreground.g)) / 255.0,
                @as(f32, @floatFromInt(colors.foreground.b)) / 255.0,
                1.0,
            };

            // Cursor color
            if (colors.cursor) |cursor_color| {
                uniforms.cursor_color = .{
                    @as(f32, @floatFromInt(cursor_color.r)) / 255.0,
                    @as(f32, @floatFromInt(cursor_color.g)) / 255.0,
                    @as(f32, @floatFromInt(cursor_color.b)) / 255.0,
                    1.0,
                };
            }

            // NOTE: the following could be optimized to follow a change in
            // config for a slight optimization however this is only 12 bytes
            // each being updated and likely isn't a cause for concern

            // Cursor text color
            if (self.config.cursor_text) |cursor_text| {
                uniforms.cursor_text = .{
                    @as(f32, @floatFromInt(cursor_text.color.r)) / 255.0,
                    @as(f32, @floatFromInt(cursor_text.color.g)) / 255.0,
                    @as(f32, @floatFromInt(cursor_text.color.b)) / 255.0,
                    1.0,
                };
            }

            // Selection background color
            if (self.config.selection_background) |selection_bg| {
                uniforms.selection_background_color = .{
                    @as(f32, @floatFromInt(selection_bg.color.r)) / 255.0,
                    @as(f32, @floatFromInt(selection_bg.color.g)) / 255.0,
                    @as(f32, @floatFromInt(selection_bg.color.b)) / 255.0,
                    1.0,
                };
            }

            // Selection foreground color
            if (self.config.selection_foreground) |selection_fg| {
                uniforms.selection_foreground_color = .{
                    @as(f32, @floatFromInt(selection_fg.color.r)) / 255.0,
                    @as(f32, @floatFromInt(selection_fg.color.g)) / 255.0,
                    @as(f32, @floatFromInt(selection_fg.color.b)) / 255.0,
                    1.0,
                };
            }

            // Cursor visibility
            uniforms.cursor_visible = @intFromBool(self.terminal_state.cursor.visible);

            // Cursor style
            const cursor_style: renderer.CursorStyle = .fromTerminal(self.terminal_state.cursor.visual_style);
            uniforms.previous_cursor_style = uniforms.current_cursor_style;
            uniforms.current_cursor_style = @as(i32, @intFromEnum(cursor_style));
        }

        /// This fork's cursor-effect uniforms, from the cursor as drawn this
        /// frame. Unlike iTimeCursorChange, a MOVE is only the cell
        /// changing (a bar/block width change is not one) and a MODE change
        /// is only the style or colour changing, so an effect for one is
        /// never cut short by the other: typing right after `i` keeps the
        /// insert ripple.
        ///
        /// A move while the scroll animation runs is a snap, not a move:
        /// the cursor is riding the text, and a smear there would fly over
        /// every scrolled row. Snapping also ends any smear in flight.
        fn updateCursorFx(
            self: *Self,
            cell_pos: [2]u16,
            rect: [4]f32,
            color: [4]f32,
            now: std.Io.Timestamp,
        ) void {
            const uniforms: *shadertoy.Uniforms = &self.custom_shader_uniforms;
            const style = uniforms.current_cursor_style;

            if (self.cursor_fx_cell) |old| {
                if (old[0] != cell_pos[0] or old[1] != cell_pos[1]) {
                    const riding = self.scroll_anim.active();
                    if (riding) {
                        uniforms.cursor_move_from = rect;
                        uniforms.time_cursor_move = -1000;
                    } else {
                        uniforms.cursor_move_from = uniforms.cursor_move_to;
                        uniforms.time_cursor_move = uniforms.time;
                        self.cursor_fx_last_event = now;
                    }
                    if (self.config.scroll_trace) log.info(
                        "cursorfx move {s} ({},{})->({},{})",
                        .{ if (riding) "snap" else "smear", old[0], old[1], cell_pos[0], cell_pos[1] },
                    );
                }
            } else {
                uniforms.cursor_move_from = rect;
            }
            self.cursor_fx_cell = cell_pos;
            uniforms.cursor_move_to = rect;

            if (self.cursor_fx_mode) |old| {
                if (old.style != style or !std.meta.eql(old.color, color)) {
                    uniforms.time_cursor_mode = uniforms.time;
                    self.cursor_fx_last_event = now;
                }
            }
            self.cursor_fx_mode = .{ .style = style, .color = color };
        }

        /// Update per-frame custom shader uniforms.
        ///
        /// This should be called exactly once per frame, inside `drawFrame`.
        fn updateCustomShaderUniformsForFrame(self: *Self) !void {
            // We only need to do this if we have custom shaders.
            if (!self.has_custom_shaders) return;

            const uniforms: *shadertoy.Uniforms = &self.custom_shader_uniforms;

            const now: std.Io.Timestamp = .now(global.io(), .awake);
            defer self.last_frame_time = now;
            const first_frame_time = self.first_frame_time orelse t: {
                self.first_frame_time = now;
                break :t now;
            };
            const last_frame_time = self.last_frame_time orelse now;

            const since_ns: f32 = @floatFromInt(first_frame_time.durationTo(now).nanoseconds);
            uniforms.time = since_ns / std.time.ns_per_s;

            const delta_ns: f32 = @floatFromInt(last_frame_time.durationTo(now).nanoseconds);
            uniforms.time_delta = delta_ns / std.time.ns_per_s;

            uniforms.frame += 1;

            const screen = self.size.screen;
            const padding = self.size.padding;
            const cell = self.size.cell;

            uniforms.resolution = .{
                @floatFromInt(screen.width),
                @floatFromInt(screen.height),
                1,
            };
            uniforms.channel_resolution[0] = .{
                @floatFromInt(screen.width),
                @floatFromInt(screen.height),
                1,
                0,
            };

            if (self.cells.getCursorGlyph()) |cursor| {
                const cursor_width: f32 = @floatFromInt(cursor.glyph_size[0]);
                const cursor_height: f32 = @floatFromInt(cursor.glyph_size[1]);

                // Left edge of the cell the cursor is in.
                var pixel_x: f32 = @floatFromInt(
                    cursor.grid_pos[0] * cell.width + padding.left,
                );
                // Top edge, relative to the top of the
                // screen, of the cell the cursor is in.
                var pixel_y: f32 = @floatFromInt(
                    cursor.grid_pos[1] * cell.height + padding.top,
                );

                // If +Y is up in our shaders, we need to flip the coordinate
                // so that it's instead the top edge of the cell relative to
                // the *bottom* of the screen.
                if (!GraphicsAPI.custom_shader_y_is_down) {
                    pixel_y = @as(f32, @floatFromInt(screen.height)) - pixel_y;
                }

                // Add the X bearing to get the -X (left) edge of the cursor.
                pixel_x += @floatFromInt(cursor.bearings[0]);

                // How we deal with the Y bearing depends on which direction
                // is "up", since we want our final `pixel_y` value to be the
                // +Y edge of the cursor.
                if (GraphicsAPI.custom_shader_y_is_down) {
                    // As a reminder, the Y bearing is the distance from the
                    // bottom of the cell to the top of the glyph, so to get
                    // the +Y edge we need to add the cell height, subtract
                    // the Y bearing, and add the glyph height to get the +Y
                    // (bottom) edge of the cursor.
                    pixel_y += @floatFromInt(cell.height);
                    pixel_y -= @floatFromInt(cursor.bearings[1]);
                    pixel_y += @floatFromInt(cursor.glyph_size[1]);
                } else {
                    // If the Y direction is reversed though, we instead want
                    // the *top* edge of the cursor, which means we just need
                    // to subtract the cell height and add the Y bearing.
                    pixel_y -= @floatFromInt(cell.height);
                    pixel_y += @floatFromInt(cursor.bearings[1]);
                }

                const new_cursor: [4]f32 = .{
                    pixel_x,
                    pixel_y,
                    cursor_width,
                    cursor_height,
                };
                const cursor_color: [4]f32 = .{
                    @as(f32, @floatFromInt(cursor.color[0])) / 255.0,
                    @as(f32, @floatFromInt(cursor.color[1])) / 255.0,
                    @as(f32, @floatFromInt(cursor.color[2])) / 255.0,
                    @as(f32, @floatFromInt(cursor.color[3])) / 255.0,
                };

                const cursor_changed: bool =
                    !std.meta.eql(new_cursor, uniforms.current_cursor) or
                    !std.meta.eql(cursor_color, uniforms.current_cursor_color);

                if (cursor_changed) {
                    uniforms.previous_cursor = uniforms.current_cursor;
                    uniforms.previous_cursor_color = uniforms.current_cursor_color;
                    uniforms.current_cursor = new_cursor;
                    uniforms.current_cursor_color = cursor_color;
                    uniforms.cursor_change_time = uniforms.time;
                }

                self.updateCursorFx(
                    .{ cursor.grid_pos[0], cursor.grid_pos[1] },
                    new_cursor,
                    cursor_color,
                    now,
                );
            }

            if (self.cursor_fx_pulse_pending) {
                self.cursor_fx_pulse_pending = false;
                uniforms.time_cursor_pulse = uniforms.time;
            }

            // Update focus uniforms
            uniforms.focus = @intFromBool(self.focused);

            // If we need to update the time our focus state changed
            // then update it to our current frame time. This may not be
            // exactly correct since it is frame time, not exact focus
            // time, but focus time on its own isn't exactly correct anyways
            // since it comes async from a message.
            if (self.custom_shader_focused_changed and self.focused) {
                uniforms.time_focus = uniforms.time;
                self.custom_shader_focused_changed = false;
            }
        }

        /// Build the overlay as configured. Returns null if there is no
        /// overlay currently configured.
        fn rebuildOverlay(
            self: *Self,
            features: []const Overlay.Feature,
        ) Overlay.InitError!void {
            const alloc = self.alloc;

            // If we have no features enabled, don't build an overlay.
            // If we had a previous overlay, deallocate it.
            if (features.len == 0) {
                if (self.overlay) |*old| {
                    old.deinit(alloc);
                    self.overlay = null;
                }

                return;
            }

            // If we had a previous overlay, clear it. Otherwise, init.
            const overlay: *Overlay = overlay: {
                if (self.overlay) |*v| existing: {
                    // Verify that our overlay size matches our screen
                    // size as we know it now. If not, deinit and reinit.
                    // Note: these intCasts are always safe because z2d
                    // stores as i32 but we always init with a u32.
                    const width: u32 = @intCast(v.surface.getWidth());
                    const height: u32 = @intCast(v.surface.getHeight());
                    const term_size = self.size.terminal();
                    if (width != term_size.width or
                        height != term_size.height) break :existing;

                    // We also depend on cell size.
                    if (v.cell_size.width != self.size.cell.width or
                        v.cell_size.height != self.size.cell.height) break :existing;

                    // Everything matches, so we can just reset the surface
                    // and redraw.
                    v.reset();
                    break :overlay v;
                }

                // If we reached this point we want to reset our overlay.
                if (self.overlay) |*v| {
                    v.deinit(alloc);
                    self.overlay = null;
                }

                assert(self.overlay == null);
                const new: Overlay = try .init(alloc, self.size);
                self.overlay = new;
                break :overlay &self.overlay.?;
            };
            overlay.applyFeatures(
                alloc,
                &self.terminal_state,
                features,
            );
        }

        const PreeditRange = struct {
            y: terminal.size.CellCountInt,
            x: [2]terminal.size.CellCountInt,
            cp_offset: usize,
        };

        /// Convert the terminal state to GPU cells stored in CPU memory. These
        /// are then synced to the GPU in the next frame. This only updates CPU
        /// memory and doesn't touch the GPU.
        ///
        /// This requires the draw mutex.
        ///
        /// Dirty state on terminal state won't be reset by this.
        fn rebuildCells(
            self: *Self,
            preedit: ?renderer.State.Preedit,
            cursor_style_: ?renderer.CursorStyle,
            links: *const terminal.RenderState.CellSet,
        ) Allocator.Error!void {
            const state: *terminal.RenderState = &self.terminal_state;

            const grid_size_diff =
                self.cells.size.rows != state.rows or
                self.cells.size.columns != state.cols;

            if (grid_size_diff) {
                var new_size = self.cells.size;
                new_size.rows = state.rows;
                new_size.columns = state.cols;
                try self.cells.resize(self.alloc, new_size);
                self.clearScrollGhosts();

                // Update our uniforms accordingly, otherwise
                // our background cells will be out of place.
                self.uniforms.grid_size = .{ new_size.columns, new_size.rows };
            }

            const rebuild = state.dirty == .full or grid_size_diff;
            if (rebuild) {
                // If we are doing a full rebuild, then we clear the entire cell buffer.
                self.cells.reset();

                // We also reset our padding extension depending on the screen type
                switch (self.config.padding_color) {
                    .background => {},

                    // For extension, assume we are extending in all directions.
                    // For "extend" this may be disabled due to heuristics below.
                    .extend, .@"extend-always" => {
                        self.uniforms.padding_extend = .{
                            .up = true,
                            .down = true,
                            .left = true,
                            .right = true,
                        };
                    },
                }
            }

            // From this point on we never fail. We produce some kind of
            // working terminal state, even if incorrect.
            errdefer comptime unreachable;

            // Get our row data from our state
            const row_data = state.row_data.slice();
            const row_raws = row_data.items(.raw);
            const row_cells = row_data.items(.cells);
            const row_dirty = row_data.items(.dirty);
            const row_selection = row_data.items(.selection);
            const row_highlights = row_data.items(.highlights);

            // If our cell contents buffer is shorter than the screen viewport,
            // we render the rows that fit, starting from the bottom. If instead
            // the viewport is shorter than the cell contents buffer, we align
            // the top of the viewport with the top of the contents buffer.
            const row_len: usize = @min(
                state.rows,
                self.cells.size.rows,
            );

            // Determine our x/y range for preedit. We don't want to render anything
            // here because we will render the preedit separately.
            const preedit_range: ?PreeditRange = if (preedit) |preedit_v| preedit: {
                // We base the preedit on the position of the cursor in the
                // viewport. If the cursor isn't visible in the viewport we
                // don't show it.
                const cursor_vp = state.cursor.viewport orelse
                    break :preedit null;

                // If our preedit row isn't dirty then we don't need the
                // preedit range. This also avoids an issue later where we
                // unconditionally add preedit cells when this is set.
                if (!rebuild and !row_dirty[cursor_vp.y]) break :preedit null;

                const range = preedit_v.range(
                    cursor_vp.x,
                    state.cols - 1,
                );
                break :preedit .{
                    .y = @intCast(cursor_vp.y),
                    .x = .{ range.start, range.end },
                    .cp_offset = range.cp_offset,
                };
            } else null;

            for (
                0..,
                row_raws[0..row_len],
                row_cells[0..row_len],
                row_dirty[0..row_len],
                row_selection[0..row_len],
                row_highlights[0..row_len],
            ) |y_usize, row, *cells, *dirty, selection, *highlights| {
                const y: terminal.size.CellCountInt = @intCast(y_usize);

                if (!rebuild) {
                    // Only rebuild if we are doing a full rebuild or this row is dirty.
                    if (!dirty.*) continue;

                    // Clear the cells if the row is dirty
                    self.cells.clear(y);
                }

                // Unmark the dirty state in our render state.
                dirty.* = false;

                self.rebuildRow(
                    y,
                    row,
                    cells,
                    preedit_range,
                    selection,
                    highlights,
                    links,
                ) catch |err| {
                    // This should never happen except under exceptional
                    // scenarios. In this case, we don't want to corrupt
                    // our render state so just clear this row and keep
                    // trying to finish it out.
                    log.warn("error building row y={} err={}", .{ y, err });
                    self.cells.clear(y);
                };
            }

            // Setup our cursor rendering information.
            cursor: {
                // Clear our cursor by default.
                self.cells.setCursor(null, null);
                self.uniforms.cursor_pos = .{
                    std.math.maxInt(u16),
                    std.math.maxInt(u16),
                };

                // If the cursor isn't visible on the viewport, don't show
                // a cursor. Otherwise, get our cursor cell, because we may
                // need it for styling.
                const cursor_vp = state.cursor.viewport orelse break :cursor;
                const cursor_style: terminal.Style = cursor_style: {
                    const cells = state.row_data.items(.cells);
                    const cell = cells[cursor_vp.y].get(cursor_vp.x);
                    break :cursor_style if (cell.raw.hasStyling())
                        cell.style
                    else
                        .{};
                };

                // If we have preedit text, we don't setup a cursor
                if (preedit != null) break :cursor;

                // If there isn't a cursor visual style requested then
                // we don't render a cursor.
                const style = cursor_style_ orelse break :cursor;

                // Determine the cursor color.
                const cursor_color = cursor_color: {
                    // If an explicit cursor color was set by OSC 12, use that.
                    if (state.colors.cursor) |v| break :cursor_color v;

                    // Use our configured color if specified
                    if (self.config.cursor_color) |v| switch (v) {
                        .color => |color| break :cursor_color color.toTerminalRGB(),

                        inline .@"cell-foreground",
                        .@"cell-background",
                        => |_, tag| {
                            const fg_style = cursor_style.fg(.{
                                .default = state.colors.foreground,
                                .palette = &state.colors.palette,
                                .bold = self.config.bold_color,
                            });
                            const bg_style = cursor_style.bg(
                                &state.cursor.cell,
                                &state.colors.palette,
                            ) orelse state.colors.background;

                            break :cursor_color switch (tag) {
                                .color => unreachable,
                                .@"cell-foreground" => if (cursor_style.flags.inverse)
                                    bg_style
                                else
                                    fg_style,
                                .@"cell-background" => if (cursor_style.flags.inverse)
                                    fg_style
                                else
                                    bg_style,
                            };
                        },
                    };

                    break :cursor_color state.colors.foreground;
                };

                self.addCursor(
                    &state.cursor,
                    style,
                    cursor_color,
                );

                // If the cursor is visible then we set our uniforms.
                if (style == .block) {
                    const wide = state.cursor.cell.wide;

                    self.uniforms.cursor_pos = .{
                        // If we are a spacer tail of a wide cell, our cursor needs
                        // to move back one cell. The saturate is to ensure we don't
                        // overflow but this shouldn't happen with well-formed input.
                        switch (wide) {
                            .narrow, .spacer_head, .wide => cursor_vp.x,
                            .spacer_tail => cursor_vp.x -| 1,
                        },
                        @intCast(cursor_vp.y),
                    };

                    self.uniforms.bools.cursor_wide = switch (wide) {
                        .narrow, .spacer_head => false,
                        .wide, .spacer_tail => true,
                    };

                    const uniform_color = if (self.config.cursor_text) |txt| blk: {
                        // If cursor-text is set, then compute the correct color.
                        // Otherwise, use the background color.
                        if (txt == .color) {
                            // Use the color set by cursor-text, if any.
                            break :blk txt.color.toTerminalRGB();
                        }

                        const fg_style = cursor_style.fg(.{
                            .default = state.colors.foreground,
                            .palette = &state.colors.palette,
                            .bold = self.config.bold_color,
                        });
                        const bg_style = cursor_style.bg(
                            &state.cursor.cell,
                            &state.colors.palette,
                        ) orelse state.colors.background;

                        break :blk switch (txt) {
                            // If the cell is reversed, use the opposite cell color instead.
                            .@"cell-foreground" => if (cursor_style.flags.inverse)
                                bg_style
                            else
                                fg_style,
                            .@"cell-background" => if (cursor_style.flags.inverse)
                                fg_style
                            else
                                bg_style,
                            else => unreachable,
                        };
                    } else state.colors.background;

                    self.uniforms.cursor_color = .{
                        uniform_color.r,
                        uniform_color.g,
                        uniform_color.b,
                        255,
                    };
                }
            }

            // Setup our preedit text.
            if (preedit) |preedit_v| preedit: {
                const range = preedit_range orelse break :preedit;
                var x = range.x[0];
                for (preedit_v.codepoints[range.cp_offset..]) |cp| {
                    self.addPreeditCell(
                        cp,
                        .{ .x = x, .y = range.y },
                        state.colors.foreground,
                    ) catch |err| {
                        log.warn("error building preedit cell, will be invalid x={} y={}, err={}", .{
                            x,
                            range.y,
                            err,
                        });
                    };

                    x += if (cp.wide) 2 else 1;
                }
            }

            // Update that our cells rebuilt
            self.cells_rebuilt = true;

            // Log some things
            // log.debug("rebuildCells complete cached_runs={}", .{
            //     self.font_shaper_cache.count(),
            // });
        }

        fn rebuildRow(
            self: *Self,
            y: terminal.size.CellCountInt,
            row: terminal.page.Row,
            cells: *std.MultiArrayList(terminal.RenderState.Cell),
            preedit_range: ?PreeditRange,
            selection: ?[2]terminal.size.CellCountInt,
            highlights: *const std.ArrayList(terminal.RenderState.Highlight),
            links: *const terminal.RenderState.CellSet,
        ) !void {
            const state = &self.terminal_state;

            // If our viewport is wider than our cell contents buffer,
            // we still only process cells up to the width of the buffer.
            const cells_slice = cells.slice();
            const cells_len = @min(cells_slice.len, self.cells.size.columns);
            const cells_raw = cells_slice.items(.raw);
            const cells_style = cells_slice.items(.style);

            // On primary screen, we still apply vertical padding
            // extension under certain conditions we feel are safe.
            //
            // This helps make some scenarios look better while
            // avoiding scenarios we know do NOT look good.
            switch (self.config.padding_color) {
                // These already have the correct values set above.
                .background, .@"extend-always" => {},

                // Apply heuristics for padding extension.
                .extend => if (y == 0) {
                    self.uniforms.padding_extend.up = !rowNeverExtendBg(
                        row,
                        cells_raw,
                        cells_style,
                        &state.colors.palette,
                        state.colors.background,
                    );
                } else if (y == self.cells.size.rows - 1) {
                    self.uniforms.padding_extend.down = !rowNeverExtendBg(
                        row,
                        cells_raw,
                        cells_style,
                        &state.colors.palette,
                        state.colors.background,
                    );
                },
            }

            // Iterator of runs for shaping.
            var run_iter_opts: font.shape.RunOptions = .{
                .grid = self.font_grid,
                .cells = cells_slice,
                .selection = if (selection) |s| s else null,

                // We want to do font shaping as long as the cursor is
                // visible on this viewport.
                .cursor_x = cursor_x: {
                    const vp = state.cursor.viewport orelse break :cursor_x null;
                    if (vp.y != y) break :cursor_x null;
                    break :cursor_x vp.x;
                },
            };
            run_iter_opts.applyBreakConfig(self.config.font_shaping_break);
            var run_iter = self.font_shaper.runIterator(run_iter_opts);
            var shaper_run: ?font.shape.TextRun = try run_iter.next(self.alloc);
            var shaper_cells: ?[]const font.shape.Cell = null;
            var shaper_cells_i: usize = 0;

            for (
                0..,
                cells_raw[0..cells_len],
                cells_style[0..cells_len],
            ) |x, *cell, *managed_style| {
                // If this cell falls within our preedit range then we
                // skip this because preedits are setup separately.
                if (preedit_range) |range| preedit: {
                    // We're not on the preedit line, no actions necessary.
                    if (range.y != y) break :preedit;
                    // We're before the preedit range, no actions necessary.
                    if (x < range.x[0]) break :preedit;
                    // We're in the preedit range, skip this cell.
                    if (x <= range.x[1]) continue;
                    // After exiting the preedit range we need to catch
                    // the run position up because of the missed cells.
                    // In all other cases, no action is necessary.
                    if (x != range.x[1] + 1) break :preedit;

                    // Step the run iterator until we find a run that ends
                    // after the current cell, which will be the soonest run
                    // that might contain glyphs for our cell.
                    while (shaper_run) |run| {
                        if (run.offset + run.cells > x) break;
                        shaper_run = try run_iter.next(self.alloc);
                        shaper_cells = null;
                        shaper_cells_i = 0;
                    }

                    const run = shaper_run orelse break :preedit;

                    // If we haven't shaped this run, do so now.
                    shaper_cells = shaper_cells orelse
                        // Try to read the cells from the shaping cache if we can.
                        self.font_shaper_cache.get(run) orelse
                        cache: {
                            // Otherwise we have to shape them.
                            const new_cells = try self.font_shaper.shape(run);

                            // Try to cache them. If caching fails for any reason we
                            // continue because it is just a performance optimization,
                            // not a correctness issue.
                            self.font_shaper_cache.put(
                                self.alloc,
                                run,
                                new_cells,
                            ) catch |err| {
                                log.warn(
                                    "error caching font shaping results err={}",
                                    .{err},
                                );
                            };

                            // The cells we get from direct shaping are always owned
                            // by the shaper and valid until the next shaping call so
                            // we can safely use them.
                            break :cache new_cells;
                        };

                    // Advance our index until we reach or pass
                    // our current x position in the shaper cells.
                    const shaper_cells_unwrapped = shaper_cells.?;
                    while (run.offset + shaper_cells_unwrapped[shaper_cells_i].x < x) {
                        shaper_cells_i += 1;
                    }
                }

                const wide = cell.wide;
                const style: terminal.Style = if (cell.hasStyling())
                    managed_style.*
                else
                    .{};

                // True if this cell is selected
                const selected: enum {
                    false,
                    selection,
                    search,
                    search_selected,
                } = selected: {
                    // Order below matters for precedence.

                    // Selection should take the highest precedence.
                    const x_compare = if (wide == .spacer_tail)
                        x -| 1
                    else
                        x;
                    if (selection) |sel| {
                        if (x_compare >= sel[0] and
                            x_compare <= sel[1]) break :selected .selection;
                    }

                    // If we're highlighted, then we're selected. In the
                    // future we want to use a different style for this
                    // but this to get started.
                    for (highlights.items) |hl| {
                        if (x_compare >= hl.range[0] and
                            x_compare <= hl.range[1])
                        {
                            const tag: HighlightTag = @enumFromInt(hl.tag);
                            break :selected switch (tag) {
                                .search_match => .search,
                                .search_match_selected => .search_selected,
                            };
                        }
                    }

                    break :selected .false;
                };

                // The `_style` suffixed values are the colors based on
                // the cell style (SGR), before applying any additional
                // configuration, inversions, selections, etc.
                const bg_style = style.bg(
                    cell,
                    &state.colors.palette,
                );
                const fg_style = style.fg(.{
                    .default = state.colors.foreground,
                    .palette = &state.colors.palette,
                    .bold = self.config.bold_color,
                });

                // The final background color for the cell.
                const bg = switch (selected) {
                    // If we have an explicit selection background color
                    // specified in the config, use that.
                    //
                    // If no configuration, then our selection background
                    // is our foreground color.
                    .selection => if (self.config.selection_background) |v| switch (v) {
                        .color => |color| color.toTerminalRGB(),
                        .@"cell-foreground" => if (style.flags.inverse) bg_style else fg_style,
                        .@"cell-background" => if (style.flags.inverse) fg_style else bg_style,
                    } else state.colors.foreground,

                    .search => switch (self.config.search_background) {
                        .color => |color| color.toTerminalRGB(),
                        .@"cell-foreground" => if (style.flags.inverse) bg_style else fg_style,
                        .@"cell-background" => if (style.flags.inverse) fg_style else bg_style,
                    },

                    .search_selected => switch (self.config.search_selected_background) {
                        .color => |color| color.toTerminalRGB(),
                        .@"cell-foreground" => if (style.flags.inverse) bg_style else fg_style,
                        .@"cell-background" => if (style.flags.inverse) fg_style else bg_style,
                    },

                    // Not selected
                    .false => if (style.flags.inverse != isCovering(cell.codepoint()))
                        // Two cases cause us to invert (use the fg color as the bg)
                        // - The "inverse" style flag.
                        // - A "covering" glyph; we use fg for bg in that
                        //   case to help make sure that padding extension
                        //   works correctly.
                        //
                        // If one of these is true (but not the other)
                        // then we use the fg style color for the bg.
                        fg_style
                    else
                        // Otherwise they cancel out.
                        bg_style,
                };

                const fg = fg: {
                    // Our happy-path non-selection background color
                    // is our style or our configured defaults.
                    const final_bg = bg_style orelse state.colors.background;

                    // Whether we need to use the bg color as our fg color:
                    // - Cell is selected, inverted, and set to cell-foreground
                    // - Cell is selected, not inverted, and set to cell-background
                    // - Cell is inverted and not selected
                    break :fg switch (selected) {
                        .selection => if (self.config.selection_foreground) |v| switch (v) {
                            .color => |color| color.toTerminalRGB(),
                            .@"cell-foreground" => if (style.flags.inverse) final_bg else fg_style,
                            .@"cell-background" => if (style.flags.inverse) fg_style else final_bg,
                        } else state.colors.background,

                        .search => switch (self.config.search_foreground) {
                            .color => |color| color.toTerminalRGB(),
                            .@"cell-foreground" => if (style.flags.inverse) final_bg else fg_style,
                            .@"cell-background" => if (style.flags.inverse) fg_style else final_bg,
                        },

                        .search_selected => switch (self.config.search_selected_foreground) {
                            .color => |color| color.toTerminalRGB(),
                            .@"cell-foreground" => if (style.flags.inverse) final_bg else fg_style,
                            .@"cell-background" => if (style.flags.inverse) fg_style else final_bg,
                        },

                        .false => if (style.flags.inverse)
                            final_bg
                        else
                            fg_style,
                    };
                };

                // Foreground alpha for this cell.
                const alpha: u8 = if (style.flags.faint) self.config.faint_opacity else 255;

                // Set the cell's background color.
                {
                    const rgb = bg orelse state.colors.background;

                    // Determine our background alpha. If we have transparency configured
                    // then this is dynamic depending on some situations. This is all
                    // in an attempt to make transparency look the best for various
                    // situations. See inline comments.
                    const bg_alpha: u8 = bg_alpha: {
                        const default: u8 = 255;

                        // Cells that are selected should be fully opaque.
                        if (selected != .false) break :bg_alpha default;

                        // Cells that are reversed should be fully opaque.
                        if (style.flags.inverse) break :bg_alpha default;

                        // If the user requested to have opacity on all cells, apply it.
                        if (self.config.background_opacity_cells and bg_style != null) {
                            var opacity: f64 = @floatFromInt(default);
                            opacity *= self.config.background_opacity;
                            break :bg_alpha @intFromFloat(opacity);
                        }

                        // Cells that have an explicit bg color should be fully opaque.
                        if (bg_style != null) break :bg_alpha default;

                        // Otherwise, we won't draw the bg for this cell,
                        // we'll let the already-drawn background color
                        // show through.
                        break :bg_alpha 0;
                    };

                    self.cells.bgCell(y, x).* = .{
                        rgb.r, rgb.g, rgb.b, bg_alpha,
                    };
                }

                // If the invisible flag is set on this cell then we
                // don't need to render any foreground elements, so
                // we just skip all glyphs with this x coordinate.
                //
                // NOTE: This behavior matches xterm. Some other terminal
                // emulators, e.g. Alacritty, still render text decorations
                // and only make the text itself invisible. The decision
                // has been made here to match xterm's behavior for this.
                if (style.flags.invisible) {
                    continue;
                }

                // Give links a single underline, unless they already have
                // an underline, in which case use a double underline to
                // distinguish them.
                const underline: terminal.Attribute.Underline = underline: {
                    if (links.contains(.{
                        .x = @intCast(x),
                        .y = @intCast(y),
                    })) {
                        break :underline if (style.flags.underline == .single)
                            .double
                        else
                            .single;
                    }
                    break :underline style.flags.underline;
                };

                // We draw underlines first so that they layer underneath text.
                // This improves readability when a colored underline is used
                // which intersects parts of the text (descenders).
                if (underline != .none) self.addUnderline(
                    @intCast(x),
                    @intCast(y),
                    underline,
                    style.underlineColor(&state.colors.palette) orelse fg,
                    alpha,
                ) catch |err| {
                    log.warn(
                        "error adding underline to cell, will be invalid x={} y={}, err={}",
                        .{ x, y, err },
                    );
                };

                if (style.flags.overline) self.addOverline(@intCast(x), @intCast(y), fg, alpha) catch |err| {
                    log.warn(
                        "error adding overline to cell, will be invalid x={} y={}, err={}",
                        .{ x, y, err },
                    );
                };

                // If we're at or past the end of our shaper run then
                // we need to get the next run from the run iterator.
                if (shaper_cells != null and shaper_cells_i >= shaper_cells.?.len) {
                    shaper_run = try run_iter.next(self.alloc);
                    shaper_cells = null;
                    shaper_cells_i = 0;
                }

                if (shaper_run) |run| glyphs: {
                    // If we haven't shaped this run yet, do so.
                    shaper_cells = shaper_cells orelse
                        // Try to read the cells from the shaping cache if we can.
                        self.font_shaper_cache.get(run) orelse
                        cache: {
                            // Otherwise we have to shape them.
                            const new_cells = try self.font_shaper.shape(run);

                            // Try to cache them. If caching fails for any reason we
                            // continue because it is just a performance optimization,
                            // not a correctness issue.
                            self.font_shaper_cache.put(
                                self.alloc,
                                run,
                                new_cells,
                            ) catch |err| {
                                log.warn(
                                    "error caching font shaping results err={}",
                                    .{err},
                                );
                            };

                            // The cells we get from direct shaping are always owned
                            // by the shaper and valid until the next shaping call so
                            // we can safely use them.
                            break :cache new_cells;
                        };

                    const shaped_cells = shaper_cells orelse break :glyphs;

                    // If there are no shaper cells for this run, ignore it.
                    // This can occur for runs of empty cells, and is fine.
                    if (shaped_cells.len == 0) break :glyphs;

                    // If we encounter a shaper cell to the left of the current
                    // cell then we have some problems. This logic relies on x
                    // position monotonically increasing.
                    assert(run.offset + shaped_cells[shaper_cells_i].x >= x);

                    // NOTE: An assumption is made here that a single cell will never
                    // be present in more than one shaper run. If that assumption is
                    // violated, this logic breaks.

                    while (shaper_cells_i < shaped_cells.len and
                        run.offset + shaped_cells[shaper_cells_i].x == x) : ({
                        shaper_cells_i += 1;
                    }) {
                        self.addGlyph(
                            @intCast(x),
                            @intCast(y),
                            state.cols,
                            cells_raw,
                            shaped_cells[shaper_cells_i],
                            shaper_run.?,
                            fg,
                            alpha,
                        ) catch |err| {
                            log.warn(
                                "error adding glyph to cell, will be invalid x={} y={}, err={}",
                                .{ x, y, err },
                            );
                        };
                    }
                }

                // Finally, draw a strikethrough if necessary.
                if (style.flags.strikethrough) self.addStrikethrough(
                    @intCast(x),
                    @intCast(y),
                    fg,
                    alpha,
                ) catch |err| {
                    log.warn(
                        "error adding strikethrough to cell, will be invalid x={} y={}, err={}",
                        .{ x, y, err },
                    );
                };
            }
        }

        /// Add an underline decoration to the specified cell
        fn addUnderline(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            style: terminal.Attribute.Underline,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const sprite: font.Sprite = switch (style) {
                .none => unreachable,
                .single => .underline,
                .double => .underline_double,
                .dotted => .underline_dotted,
                .dashed => .underline_dashed,
                .curly => .underline_curly,
            };

            const render = try self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(sprite),
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            );

            try self.cells.add(self.alloc, .underline, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            });
        }

        /// Add a overline decoration to the specified cell
        fn addOverline(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const render = try self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(font.Sprite.overline),
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            );

            try self.cells.add(self.alloc, .overline, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            });
        }

        /// Add a strikethrough decoration to the specified cell
        fn addStrikethrough(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const render = try self.font_grid.renderGlyph(
                self.alloc,
                font.sprite_index,
                @intFromEnum(font.Sprite.strikethrough),
                .{
                    .cell_width = 1,
                    .grid_metrics = self.grid_metrics,
                },
            );

            try self.cells.add(self.alloc, .strikethrough, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            });
        }

        // Add a glyph to the specified cell.
        fn addGlyph(
            self: *Self,
            x: terminal.size.CellCountInt,
            y: terminal.size.CellCountInt,
            cols: usize,
            cell_raws: []const terminal.page.Cell,
            shaper_cell: font.shape.Cell,
            shaper_run: font.shape.TextRun,
            color: terminal.color.RGB,
            alpha: u8,
        ) !void {
            const cell = cell_raws[x];
            const cp = cell.codepoint();

            // Render
            const render = try self.font_grid.renderGlyph(
                self.alloc,
                shaper_run.font_index,
                shaper_cell.glyph_index,
                .{
                    .grid_metrics = self.grid_metrics,
                    .thicken = self.config.font_thicken,
                    .thicken_strength = self.config.font_thicken_strength,
                    .cell_width = cell.gridWidth(),
                    // If there's no Nerd Font constraint for this codepoint
                    // then, if it's a symbol, we constrain it to fit inside
                    // its cell(s), we don't modify the alignment at all.
                    .constraint = getConstraint(cp) orelse
                        if (cellpkg.isSymbol(cp)) .{
                            .size = .fit,
                        } else .none,
                    .constraint_width = constraintWidth(
                        cell_raws,
                        x,
                        cols,
                    ),
                },
            );

            // If the glyph is 0 width or height, it will be invisible
            // when drawn, so don't bother adding it to the buffer.
            if (render.glyph.width == 0 or render.glyph.height == 0) {
                return;
            }

            try self.cells.add(self.alloc, .text, .{
                .atlas = switch (render.presentation) {
                    .emoji => .color,
                    .text => .grayscale,
                },
                .bools = .{ .no_min_contrast = noMinContrast(cp) },
                .grid_pos = .{ @intCast(x), @intCast(y) },
                .color = .{ color.r, color.g, color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x + shaper_cell.x_offset),
                    @intCast(render.glyph.offset_y + shaper_cell.y_offset),
                },
            });
        }

        fn addCursor(
            self: *Self,
            cursor_state: *const terminal.RenderState.Cursor,
            cursor_style: renderer.CursorStyle,
            cursor_color: terminal.color.RGB,
        ) void {
            const cursor_vp = cursor_state.viewport orelse return;

            // Add the cursor. We render the cursor over the wide character if
            // we're on the wide character tail.
            const wide, const x = cell: {
                // The cursor goes over the screen cursor position.
                if (!cursor_vp.wide_tail) break :cell .{
                    cursor_state.cell.wide == .wide,
                    cursor_vp.x,
                };

                // If we're part of a wide character, we move the cursor back
                // to the actual character.
                break :cell .{ true, cursor_vp.x - 1 };
            };

            const alpha: u8 = if (!self.focused) 255 else alpha: {
                const alpha = 255 * self.config.cursor_opacity;
                break :alpha @intFromFloat(@ceil(alpha));
            };

            const render = switch (cursor_style) {
                .block,
                .block_hollow,
                .bar,
                .underline,
                => render: {
                    const sprite: font.Sprite = switch (cursor_style) {
                        .block => .cursor_rect,
                        .block_hollow => .cursor_hollow_rect,
                        .bar => .cursor_bar,
                        .underline => .cursor_underline,
                        .lock => unreachable,
                    };

                    break :render self.font_grid.renderGlyph(
                        self.alloc,
                        font.sprite_index,
                        @intFromEnum(sprite),
                        .{
                            .cell_width = if (wide) 2 else 1,
                            .grid_metrics = self.grid_metrics,
                        },
                    ) catch |err| {
                        log.warn("error rendering cursor glyph err={}", .{err});
                        return;
                    };
                },

                .lock => self.font_grid.renderCodepoint(
                    self.alloc,
                    0xF023, // lock symbol
                    .regular,
                    .text,
                    .{
                        .cell_width = if (wide) 2 else 1,
                        .grid_metrics = self.grid_metrics,
                    },
                ) catch |err| {
                    log.warn("error rendering cursor glyph err={}", .{err});
                    return;
                } orelse {
                    // This should never happen because we embed nerd
                    // fonts so we just log and return instead of fallback.
                    log.warn("failed to find lock symbol for cursor codepoint=0xF023", .{});
                    return;
                },
            };

            self.cells.setCursor(.{
                .atlas = .grayscale,
                .bools = .{ .is_cursor_glyph = true },
                .grid_pos = .{ x, cursor_vp.y },
                .color = .{ cursor_color.r, cursor_color.g, cursor_color.b, alpha },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            }, cursor_style);
        }

        fn addPreeditCell(
            self: *Self,
            cp: renderer.State.Preedit.Codepoint,
            coord: terminal.Coordinate,
            screen_fg: terminal.color.RGB,
        ) !void {
            // Render the glyph for our preedit text
            const render_ = self.font_grid.renderCodepoint(
                self.alloc,
                @intCast(cp.codepoint),
                .regular,
                .text,
                .{ .grid_metrics = self.grid_metrics },
            ) catch |err| {
                log.warn("error rendering preedit glyph err={}", .{err});
                return;
            };
            const render = render_ orelse {
                log.warn("failed to find font for preedit codepoint={X}", .{cp.codepoint});
                return;
            };

            // Add our text
            try self.cells.add(self.alloc, .text, .{
                .atlas = .grayscale,
                .grid_pos = .{ @intCast(coord.x), @intCast(coord.y) },
                .color = .{ screen_fg.r, screen_fg.g, screen_fg.b, 255 },
                .glyph_pos = .{ render.glyph.atlas_x, render.glyph.atlas_y },
                .glyph_size = .{ render.glyph.width, render.glyph.height },
                .bearings = .{
                    @intCast(render.glyph.offset_x),
                    @intCast(render.glyph.offset_y),
                },
            });

            // Add underline
            try self.addUnderline(@intCast(coord.x), @intCast(coord.y), .single, screen_fg, 255);
            if (cp.wide and coord.x < self.cells.size.columns - 1) {
                try self.addUnderline(@intCast(coord.x + 1), @intCast(coord.y), .single, screen_fg, 255);
            }
        }

        /// Sync the atlas data to the given texture. This copies the bytes
        /// associated with the atlas to the given texture. If the atlas no
        /// longer fits into the texture, the texture will be resized.
        fn syncAtlasTexture(
            self: *const Self,
            atlas: *const font.Atlas,
            texture: *Texture,
        ) !void {
            if (atlas.size > texture.width) {
                // Free our old texture
                texture.*.deinit();

                // Reallocate
                texture.* = try self.api.initAtlasTexture(atlas);
            }

            try texture.replaceRegion(0, 0, atlas.size, atlas.size, atlas.data);
        }
    };
}
