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

const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Terminal = terminal.Terminal;
const Health = renderer.Health;
const compat_file = @import("../lib/compat/file.zig");

const getConstraint = @import("../font/nerd_font_attributes.zig").getConstraint;

const FileType = @import("../file_type.zig").FileType;

const macos = switch (builtin.target.os.tag) {
    .macos => @import("macos"),
    else => void,
};

/// The display link used to pace drawing to the display's refresh
/// rate. Only macOS has one. Everywhere else this is void and the
/// display link code paths compile away.
const DisplayLink = switch (builtin.target.os.tag) {
    .macos => @import("DisplayLink.zig"),
    else => void,
};

/// Vsync where the apprt composites exported frames on its own frame clock
/// (GTK): draws wait for the apprt's tick. See FrameLink.zig.
const FrameLink = @import("FrameLink.zig");

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
/// [ ExportedFrame ] - A finished frame ready to be consumed by the apprt
///                     in case that the frame needs to be composited with
///                     UI elements by the graphical toolkit manually.
///
pub fn Renderer(comptime GraphicsAPI: type) type {
    return struct {
        const Self = @This();

        pub const API = GraphicsAPI;

        pub const ExportedFrame = if (@hasDecl(GraphicsAPI, "ExportedFrame")) GraphicsAPI.ExportedFrame else void;

        /// Whether +Y is down in the coordinate space of exported
        /// frames. Apprts use this to orient frames when presenting.
        pub const custom_shader_y_is_down = GraphicsAPI.custom_shader_y_is_down;

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

        /// The latest exported frame ready to be consumed by an apprt
        /// who needs to manually composite the frame with UI elements.
        /// Previously exported frames are released when a new frame is
        /// exported and pushed onto the queue.
        ///
        /// Unused if the renderer does not need to export frames to
        /// present its rendered frame.
        latest_frame: LatestFrame = .{},

        /// Paces draws to the apprt's frame clock when frames are
        /// exported and there is no DisplayLink. See FrameLink.zig.
        frame_link: FrameLink = .{},

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

        /// `custom-shader-cache`: what changed since the last frame drawn.
        /// See `drawFrame` and SPEC.md "Shader cache". `full` means "no idea,
        /// redo everything" and is the answer whenever in doubt.
        cache_damage_full: bool = true,
        /// Rows rebuilt since the last frame drawn, indexed by row.
        cache_damage_rows: std.ArrayListUnmanaged(bool) = .empty,
        /// Hovered links are drawn by rebuilding their rows, but leaving a
        /// link does not mark its row dirty.
        cache_had_links: bool = false,
        /// What the last drawn frame was drawn from, to spot changes that no
        /// dirty row announces.
        cache_last_uniforms: ?shaderpkg.Uniforms = null,
        cache_last_cursor: ?shaderpkg.CellText = null,
        cache_last_post_uniforms: ?shadertoy.Uniforms = null,
        /// The whole-screen state that forces a full redraw was present in
        /// the last frame (so this one must be full too, to clean up).
        cache_last_volatile: bool = true,
        /// The target holds the last shader's output for a frame in which no
        /// animation was live, drawn over the whole window.
        cache_final_settled: bool = false,
        /// Where the last shader drew a cursor effect in the last frame, as
        /// a GL scissor. The next frame has to redraw it: with the effect a
        /// little further on, or without it once the effect is over.
        cache_fx_box: ?[4]u32 = null,
        /// Every frame drawn gets the next sequence number (`drawFrame`).
        cache_seq: u64 = 0,
        /// What each of the last few frames changed, by sequence number:
        /// a swap-chain slot drawn at seq s is brought up to date by
        /// redoing everything changed since s (see `drawFrameCached`).
        cache_log: [cache_log_len]CacheLogEntry = @splat(.{}),
        /// The last few frames, for the verify log: what each one redid.
        cache_history: [12]CacheFrameNote = @splat(.{}),
        cache_history_i: usize = 0,
        cache_note_volatile: [2]bool = .{ false, false },
        cache_stats: CacheStats = .{},
        cache_verify_buf: std.ArrayListUnmanaged(u8) = .empty,
        /// Set to true after the Kitty image placements are rebuilt. Like
        /// `cells_rebuilt`, this means the next frame must be drawn. This
        /// matters when the images change but no cell does, for example
        /// when a program places an image.
        images_rebuilt: bool = false,

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

        /// The last key TYPED text (or deleted it), as opposed to moving.
        /// With an insert (bar) cursor such a key is text entry, and nothing
        /// it redraws is a scroll. See `detectRepaintScroll`.
        input_typed: bool = false,

        /// The wheel's last movement and its direction (+1 = content up).
        /// See `noteWheelActivity`.
        wheel_ts: ?std.Io.Timestamp = null,
        wheel_dir: i8 = 0,
        /// The last wheel movement past `scroll-animation-wheel-snap`.
        wheel_fast_ts: ?std.Io.Timestamp = null,

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
        /// Per cell, what the last push carried in UNDER a pinned overlay:
        /// its background, uploaded after the mask for the slid copy of a
        /// pinned cell to draw (cell_bg.f). Its text goes into
        /// `scroll_ghost` as underlay glyphs. See `keepScrollGhosts`.
        scroll_pin_under: std.ArrayListUnmanaged(shaderpkg.CellBg) = .empty,
        scroll_pin_live: bool = false,
        /// The backgrounds as drawn before this frame's rebuild, for pins.
        scroll_bg_prev: std.ArrayListUnmanaged(shaderpkg.CellBg) = .empty,
        /// The last push this frame, for pins: set by `keepScrollGhosts`.
        scroll_frame_push: ?struct { rows: isize, top: usize, bottom: usize, left: usize, right: usize } = null,
        /// The last push, kept: pins are recomputed on every frame of a
        /// running animation, not only on frames that pushed (see the
        /// rebuild block).
        scroll_last_push: ?struct { rows: isize, top: usize, bottom: usize, left: usize, right: usize } = null,

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
            /// The rows it animated (region top .. bottom after the reserve).
            top: usize = 0,
            bottom: usize = 0,
        } = null,

        /// Every row any scroll event of this gesture covered: the only rows
        /// `extendEventRows` may take as "arriving" content. A changed row
        /// just outside an event can be the app's own status line (nvim's,
        /// row 53: its position readout changes on every step).
        scroll_event_span: ?struct { top: usize, bottom: usize } = null,

        /// This frame's scroll event, animated once the frame has been read.
        /// See `applyPendingScroll`.
        scroll_pending: ?struct { rows: isize, top: usize, bottom: usize, left: usize, right: usize, limit: f32 } = null,
        /// Set by `detectRepaintScroll` on an event frame: how far the
        /// content really moved, when that is further than the event said.
        scroll_event_total: ?isize = null,

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
        /// OSC 777;cursor-boom (this fork): the last count seen, and the
        /// boom waiting for the next frame's uniforms.
        cursor_fx_boom_seen: u32 = 0,
        cursor_fx_boom_pending: ?terminal.osc.Command.CursorBoom = null,
        /// OSC 777;cursor-target (this fork), copied at updateFrame: the
        /// cell effects treat as the cursor while none is drawn, and the
        /// target's sequence number. `used` is the sequence number when a
        /// cursor was last drawn: a target only counts if it was sent after
        /// that, so it lasts exactly one hidden-cursor spell (yazi, a menu)
        /// and a blink or a later hidden spell never jumps back to it.
        cursor_fx_target: ?[2]u16 = null,
        cursor_fx_target_seq: u32 = 0,
        cursor_fx_target_used: u32 = 0,
        cursor_fx_last_event: ?std.Io.Timestamp = null,
        /// The cursor's style and colour at the last updateFrame, to see a
        /// mode change there (see updateFrame) and not only at draw time.
        cursor_fx_style_seen: ?terminal.CursorStyle = null,
        cursor_fx_color_seen: ?terminal.color.RGB = null,
        /// Next slot of the uniforms' cursor effect event ring.
        cursor_fx_next: usize = 0,

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

        /// The display link that paces drawing to the display's refresh
        /// rate. It is created lazily on the render thread the first
        /// time `syncDisplayLink` runs, and stays null if vsync is
        /// disabled or creation failed. This is void on platforms
        /// without a display link.
        ///
        /// The link is only ever started and stopped on the main thread.
        /// See `renderer/DisplayLink.zig` for why that matters.
        display_link: if (DisplayLink != void) ?*DisplayLink else void =
            if (DisplayLink != void) null else {},

        /// Health of the most recently completed frame.
        health: std.atomic.Value(Health) = .{ .raw = .healthy },

        /// Health of how well the apprt can present our frames.
        ///
        /// This is separate from `health` because a renderer
        /// can produce healthy frames that the apprt can't present.
        presentation_health: std.atomic.Value(Health) = .{ .raw = .healthy },

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
        const CacheStats = struct {
            since: ?std.Io.Timestamp = null,
            frames: u32 = 0,
            cells_none: u32 = 0,
            cells_part: u32 = 0,
            cells_full: u32 = 0,
            final_none: u32 = 0,
            final_part: u32 = 0,
            final_full: u32 = 0,
            /// Sum over frames of the share of the window the static chain redid.
            share: f64 = 0,
            /// The same for the last shader.
            final_share: f64 = 0,
            verified: u32 = 0,
            mismatched: u32 = 0,
        };

        const CacheFrameNote = struct {
            full: bool = false,
            bands: u8 = 0,
            first_top: u32 = 0,
            last_bottom: u32 = 0,
            volatile_now: bool = false,
            volatile_before: bool = false,
            scroll_off: f32 = 0,
            live: bool = false,
            final_full: bool = false,
            final_n: u8 = 0,
            uniforms_same: bool = false,
        };

        /// One horizontal strip of the window, in pixels from the top.
        const CacheBand = struct { top: u32, bottom: u32 };
        const cache_max_bands = 8;
        const CacheDamage = struct {
            full: bool = false,
            n: usize = 0,
            bands: [cache_max_bands]CacheBand = undefined,

            fn none(self: CacheDamage) bool {
                return !self.full and self.n == 0;
            }

            /// Add a strip; past `cache_max_bands` the last one grows to
            /// cover it (more to redo, never less).
            fn add(self: *CacheDamage, b: CacheBand) void {
                if (self.full or b.bottom <= b.top) return;
                if (self.n == cache_max_bands) {
                    const l = &self.bands[cache_max_bands - 1];
                    l.top = @min(l.top, b.top);
                    l.bottom = @max(l.bottom, b.bottom);
                    return;
                }
                self.bands[self.n] = b;
                self.n += 1;
            }

            fn merge(self: *CacheDamage, other: CacheDamage) void {
                if (other.full) {
                    self.* = .{ .full = true };
                    return;
                }
                for (other.bands[0..other.n]) |b| self.add(b);
            }
        };

        /// What one frame changed: the strips of the terminal image (and of
        /// the static shaders' output) and the rectangles of the last
        /// shader's output. `seq` 0 is no frame.
        const CacheLogEntry = struct {
            seq: u64 = 0,
            bands: CacheDamage = .{ .full = true },
            final: if (@hasDecl(GraphicsAPI, "Damage")) GraphicsAPI.Damage else void =
                if (@hasDecl(GraphicsAPI, "Damage")) .everything else {},
        };
        /// Enough for any slot of the swap chain, plus slack for frames
        /// drawn while a slot was busy.
        const cache_log_len = 8;
        /// Room for a frame's own rectangles (its strips and two effect
        /// boxes) and for a slot's union of several frames' (the API's
        /// `Damage` merges past its own limit).
        const final_rects_len = @max(
            cache_max_bands + 2,
            if (@hasDecl(GraphicsAPI, "Damage")) GraphicsAPI.Damage.max_rects else 0,
        );

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

            /// `custom-shader-cache`: the frame (`cache_seq`) whose image
            /// this slot's cache layers and target hold. 0: nothing usable.
            cache_seq: u64 = 0,

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
                self.cache_seq = 0;
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

            /// `custom-shader-cache`: `cache[0]` holds the terminal image and
            /// `cache[i]` the output of shader `i - 1`, for every shader but
            /// the last. Unlike front/back these are never swapped, so each
            /// keeps its contents from frame to frame and a pass can redo a
            /// strip of it. `verify` is the same chain drawn in full, for
            /// `custom-shader-cache-debug = verify`.
            cache: [max_cache]?Texture = @splat(null),
            verify: [max_cache]?Texture = @splat(null),
            verify_target: ?Target = null,
            cache_width: usize = 0,
            cache_height: usize = 0,

            /// More shaders than this and the cache is simply not used.
            const max_cache = 8;

            const UniformBuffer = Buffer(shadertoy.Uniforms);

            fn freeCache(self: *CustomShaderState) void {
                for (&self.cache) |*t| if (t.*) |tex| {
                    tex.deinit();
                    t.* = null;
                };
                for (&self.verify) |*t| if (t.*) |tex| {
                    tex.deinit();
                    t.* = null;
                };
                if (self.verify_target) |*t| {
                    t.deinit();
                    self.verify_target = null;
                }
                self.cache_width = 0;
                self.cache_height = 0;
            }

            /// Make `n` cache textures of this size exist. Returns true if
            /// any had to be created, in which case they hold nothing yet.
            fn ensureCache(
                self: *CustomShaderState,
                api: GraphicsAPI,
                n: usize,
                width: usize,
                height: usize,
                with_verify: bool,
            ) !bool {
                var have: usize = 0;
                for (self.cache) |t| {
                    if (t != null) have += 1;
                }
                const verify_ok = !with_verify or
                    (self.verify_target != null and self.verify[n - 1] != null);
                if (have == n and verify_ok and
                    self.cache_width == width and self.cache_height == height) return false;
                self.freeCache();
                errdefer self.freeCache();
                for (0..n) |i| {
                    self.cache[i] = try Texture.init(api.textureOptions(), @intCast(width), @intCast(height), null);
                    if (with_verify) self.verify[i] = try Texture.init(api.textureOptions(), @intCast(width), @intCast(height), null);
                }
                if (with_verify) self.verify_target = try api.initTarget(width, height);
                self.cache_width = width;
                self.cache_height = height;
                return true;
            }

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
                self.freeCache();
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
            font_features: std.ArrayList([:0]const u8),
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
            custom_shader_cache: bool,
            custom_shader_cache_margin: u32,
            custom_shader_cache_fx_reach: f32,
            custom_shader_cache_debug: configpkg.Config.CustomShaderCacheDebug,
            gtk_damage_tracking: bool,

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
                    .custom_shader_cache = config.@"custom-shader-cache",
                    .custom_shader_cache_margin = config.@"custom-shader-cache-margin",
                    .custom_shader_cache_fx_reach = config.@"custom-shader-cache-fx-reach",
                    .custom_shader_cache_debug = config.@"custom-shader-cache-debug",
                    .gtk_damage_tracking = config.@"gtk-damage-tracking",
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
            // surface provided by the apprt and set up any API- and surface-
            // specific GPU resources.
            var api = try GraphicsAPI.init(
                alloc,
                options.device,
                options,
            );
            errdefer api.deinit();

            const has_custom_shaders = options.config.custom_shaders.value.items.len > 0;

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
                    .cursor_fx_event = @splat(.{ -1000, 0, 0, 0 }),
                    .cursor_fx_event_color = @splat(@splat(0)),
                    .cursor_fx_event_rect = @splat(@splat(0)),
                },
                .bg_image_buffer = undefined,

                // Fonts
                .font_grid = options.font_grid,
                .font_shaper = font_shaper,
                .font_shaper_cache = font.ShaperCache.init(),

                // Graphics API stuff
                .api = api,
                .swap_chain = null,
                .has_custom_shaders = has_custom_shaders,
                .reinitialize_shaders = true,
                // Shaders are initialized lazily on the render thread.
                .shaders = .uninit,
            };

            // Ensure our undefined values above are correctly initialized.
            result.updateFontGridUniforms();
            result.updateScreenSizeUniforms();
            result.updateBgImageBuffer();
            try result.prepBackgroundImage();

            return result;
        }

        pub fn deinit(self: *Self) void {
            // This only deinitializes and frees CPU-side state
            // and does not free GPU resources like the swap chain and
            // shaders. Those are freed with `releaseGpuResources`.

            if (self.overlay) |*overlay| overlay.deinit(self.alloc);
            self.scroll_row_hashes.deinit(self.alloc);
            self.scroll_pre_event_hashes.deinit(self.alloc);
            self.scroll_hashes_before.deinit(self.alloc);
            self.terminal_state.deinit(self.alloc);
            if (self.search_selected_match) |*m| m.arena.deinit();
            if (self.search_matches) |*m| m.arena.deinit();

            self.latest_frame.deinit(global.io());

            // Stop and release the display link. Surfaces are destroyed
            // on the main thread, where `close` stops the link before
            // returning. After this the display link callback is never
            // invoked again, so `renderer.Thread` can free the `draw_now`
            // handle the callback points at.
            if (DisplayLink != void) {
                if (self.display_link) |display_link| {
                    display_link.close();
                    self.display_link = null;
                }
            }

            self.cells.deinit(self.alloc);
            self.scroll_ghost.deinit(self.alloc);
            self.scroll_ghost_bg.deinit(self.alloc);
            self.scroll_prev_images.deinit(self.alloc);
            self.scroll_pin.deinit(self.alloc);
            self.cache_damage_rows.deinit(self.alloc);
            self.cache_verify_buf.deinit(self.alloc);
            self.scroll_pin_under.deinit(self.alloc);
            self.scroll_bg_prev.deinit(self.alloc);
            self.scroll_bg_view.deinit(self.alloc);
            self.scroll_ghost_view.deinit(self.alloc);

            self.font_shaper.deinit();
            self.font_shaper_cache.deinit(self.alloc);

            self.config.deinit();
            self.api.deinit();

            self.* = undefined;
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

        /// Callback called by renderer.Thread when it begins.
        pub fn threadEnter(self: *Self, surface: *apprt.Surface) !void {
            // If our API has to do things on thread enter, let it.
            if (@hasDecl(GraphicsAPI, "threadEnter")) {
                try self.api.threadEnter(surface);
            }
        }

        /// Callback called by renderer.Thread when it exits. Called on the
        /// render thread. Releases all GPU resources before the API tears down
        /// its context, since after this the GL context will be gone.
        pub fn threadExit(self: *Self) void {
            {
                self.draw_mutex.lockUncancelable(global.io());
                defer self.draw_mutex.unlock(global.io());

                // Release swap chain and shaders. Shaders are only freed
                // while unrealized and not every apprt unrealizes before
                // destroying a surface (macOS never does), so mark it
                // unrealized. This also stops any later draw.
                self.display_realized = false;
                self.releaseGpuResources();

                // We don't release images in `releaseGpuResources`
                // since it can be called whenever the terminal is
                // occluded or unrealized, and we don't want to
                // reupload images every time that happens.
                self.images.deinit(self.alloc);
                self.images = .empty;

                if (self.bg_image) |img| {
                    img.deinit(self.alloc);
                    self.bg_image = null;
                }
            }

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

            if (comptime DisplayLink == void and ExportedFrame != void) {
                self.frame_link.draw_now = &thr.draw_now;
                self.frame_link.enabled.store(self.config.vsync, .release);
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

            // Stop pacing: later ticks see the link disabled and stop.
            if (comptime DisplayLink == void and ExportedFrame != void) {
                self.frame_link.enabled.store(false, .release);
            }

            // If we don't support a display link we have no work to do.
            if (comptime DisplayLink == void) return;

            // Ask the display link to stop. The stop itself happens on
            // the main thread shortly after. `deinit` later stops the
            // link for certain before anything the display link callback
            // references is freed.
            const display_link = self.display_link orelse return;
            display_link.setRunning(false);
        }

        /// This is called by the GTK apprt after the surface is
        /// reinitialized (e.g. after the widget is re-realized following
        /// a display change or reparenting).
        pub fn displayRealized(self: *Self) !void {
            // If our API has to do things on realize, let it.
            if (@hasDecl(GraphicsAPI, "displayRealized")) {
                self.api.displayRealized();
            }

            // Lock the draw mutex so that we can safely update state.
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());

            // Mark the display as realized. The render thread will lazily
            // rebuild the swap chain and shaders on the next `drawFrame`,
            // which is the right place for GL resource creation (it
            // guarantees a current context on the render thread).
            self.display_realized = true;
            self.reinitialize_shaders = true;
            self.target_config_modified = 1;
        }

        /// This is called when the surface is being unrealized.
        /// This can happen because the surface is being closed but
        /// also when moving the window between displays or splitting.
        ///
        /// This runs on the main thread and only updates CPU-side state
        /// here; resource cleanup happens on the render thread via
        /// `releaseGpuResources`.
        pub fn displayUnrealized(self: *Self) void {
            // Lock the draw mutex so that we can safely update state.
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());

            // Clearing `display_realized` ensures drawFrame doesn't attempt
            // to rebuild the swap chain or make any graphics API calls.
            // The actual GPU resource release is done by the render thread.
            self.display_realized = false;
        }

        /// A thread-safe, single-slot "latest wins" queue. The render thread
        /// calls `push` with the latest frame; the apprt calls `take` in its
        /// snapshot handler to grab the most recent frame. Old frames are
        /// dropped and released. For a terminal this is correct — we never
        /// want to queue up frames behind a slow compositor.
        const LatestFrame = struct {
            const Self = @This();
            mutex: std.Io.Mutex = .init,
            latest: ?ExportedFrame = null,

            pub fn push(self: *LatestFrame, io: std.Io, value: ExportedFrame) void {
                if (comptime ExportedFrame == void) return;

                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                var new = value;
                if (self.latest) |*old| {
                    // The apprt never saw `old`: what `new` changes is
                    // relative to the frame before it, so add its change.
                    carryDamage(old.*, &new);
                    old.deinit();
                }
                self.latest = new;
            }

            fn carryDamage(old: ExportedFrame, new: *ExportedFrame) void {
                if (comptime !@hasField(ExportedFrame, "dmabuf")) return;
                switch (new.*) {
                    .dmabuf => |*d| switch (old) {
                        .dmabuf => |o| d.damage.merge(o.damage),
                        else => d.damage = .everything,
                    },
                    else => {},
                }
            }

            pub fn take(self: *LatestFrame, io: std.Io) ?ExportedFrame {
                if (comptime ExportedFrame == void) return null;

                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                const result = self.latest orelse return null;
                self.latest = null;
                return result;
            }

            pub fn deinit(self: *LatestFrame, io: std.Io) void {
                if (comptime ExportedFrame == void) return;

                self.mutex.lockUncancelable(io);
                defer self.mutex.unlock(io);
                if (self.latest) |*v| v.deinit();
                self.latest = null;
            }
        };

        /// Push the latest completed frame, replacing if one previously
        /// existed. Called on the render thread.
        ///
        /// Has no effect for renderers that do not export frames
        /// (i.e. `ExportedFrame == void`).
        pub fn pushFrame(self: *Self, frame: ExportedFrame) void {
            return self.latest_frame.push(global.io(), frame);
        }

        /// Take the latest completed frame for the apprt to composite.
        /// Returns null if no frame is available. The caller takes
        /// ownership of the returned frame. Called on the main thread.
        ///
        /// Has no effect for renderers that do not export frames
        /// (i.e. `ExportedFrame == void`).
        pub fn takeFrame(self: *Self) ?ExportedFrame {
            return self.latest_frame.take(global.io());
        }

        /// The display link output callback. CoreVideo invokes this on
        /// its own thread once per display refresh while the link is
        /// running. All it does is wake the render thread, which then
        /// draws a frame.
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

        /// Called when the window moves to a different display, with
        /// the CGDirectDisplayID of the new one. The display link is
        /// bound to that display so that it follows its refresh rate.
        ///
        /// Must be called on the render thread.
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

        /// How long after a key the repaint detector's gate stays open.
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

        /// The longest the chain may hold the gate open after the last key
        /// or wheel movement, however steadily scrolls keep arriving.
        ///
        /// Without a bound the chain never closed on its own. Enter opens the
        /// gate like any key, and command output that starts inside it and
        /// keeps scrolling a few rows a frame -- `make`, `tail -f`, a test
        /// run -- re-armed it every frame, so the whole run slid as if the
        /// user were scrolling it. Long enough for the slowest glide a key
        /// starts (neoscroll's 450 ms, see above); a held key or a spinning
        /// wheel keeps refreshing the input time, so it never cuts a real
        /// gesture short.
        pub const repaint_chain_max_ms: i64 = 600;

        /// Rows that must agree before a shift is believed, as a count and as
        /// a fraction of the rows compared.
        ///
        /// Blank and repeating rows match at many offsets at once, so a mostly
        /// empty screen can "match" a shift of any size. Animating that
        /// invents motion that never happened, so a shift has to be carried by
        /// a substantial majority of the screen before it is acted on.
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

            // Under the GTK frame link, the refresh this frame is shown on
            // (see FrameLink.present_ns), not when the draw started.
            const now: std.Io.Timestamp = self.frame_link.animTime() orelse
                .now(global.io(), .awake);
            const last = self.scroll_anim_last orelse {
                // First frame of this animation: no interval to integrate yet.
                self.scroll_anim_last = now;
                return;
            };
            self.scroll_anim_last = now;

            // Exact, not truncated to whole milliseconds: `last` moves to
            // `now` every frame, so a truncated remainder was lost for good
            // -- 6.94 ms frames at 144 Hz integrated as 6, and every
            // animation ran ~14% longer than configured.
            const dt_ms: f32 = @as(f32, @floatFromInt(last.durationTo(now).nanoseconds)) /
                @as(f32, @floatFromInt(std.time.ns_per_ms));
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
        fn keepScrollGhosts(self: *Self, rows: isize, top: usize, bottom: usize, left: usize, right: usize, hashes: ?[2][]const u64) void {
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

            // What this push slides UNDER a pinned overlay: model row y now
            // holds what row y + rows held, and where y is pinned the overlay
            // hides it -- but the frame about to be replaced still shows it
            // whole. Keep those glyphs, as underlay ghosts at row y that the
            // shader never draws over the overlay (the colour is
            // `fillUnderlay`'s, every frame). The next push drops them
            // (shiftGhosts: back inside the region), by which time the model
            // draws that text itself, clear of the overlay. The mask is the
            // last one computed, as for the filter above. `same_row` says,
            // per row, whether the new frame's row y really is the old row
            // y + rows where it is visible (repaint path: the hashes); a row
            // an application has not finished redrawing gets no underlay
            // rather than the wrong one.
            if (self.scroll_pin.items.len == nrows * cols) under: {
                const nr: isize = @intCast(nrows);
                for (0..nrows) |y| {
                    const pin_row = self.scroll_pin.items[y * cols ..][0..cols];
                    var any = false;
                    for (pin_row) |m| if (m[0] != 0) {
                        any = true;
                        break;
                    };
                    if (!any) continue;
                    const src = @as(isize, @intCast(y)) + rows;
                    if (src < 0 or src >= nr) continue;
                    if (hashes) |h| {
                        // Where the new row y is visible, is it the old row
                        // `src`? (cur = h[0], prev = h[1].)
                        if (h[0].len != nrows * cols or h[1].len != nrows * cols) continue;
                        const su: usize = @intCast(src);
                        var seen: usize = 0;
                        var same: usize = 0;
                        // Only the scrolling columns: yazi relabels its line
                        // numbers every step, which failed every row.
                        for (left..@min(right + 1, cols)) |c| {
                            if (pin_row[c][0] != 0) continue;
                            const k = h[0][y * cols + c];
                            if (ScrollAnim.glyphOf(k) == ScrollAnim.blank_glyph) continue;
                            seen += 1;
                            // Glyphs, not styles: the row that just became
                            // the hovered one is restyled (yazi's size column).
                            if (ScrollAnim.glyphOf(k) == ScrollAnim.glyphOf(h[1][su * cols + c])) same += 1;
                        }
                        if (same * 5 < seen * 4) continue;
                    }
                    // The whole row within the scroll, not just the cells
                    // pinned now: the next mask can be wider (yazi's bar
                    // grows to cover a symlink's target), and the shader
                    // draws an underlay glyph only where its own cell is
                    // pinned in the CURRENT mask.
                    for (self.cells.fg_rows[@as(usize, @intCast(src)) + 1].items) |g| {
                        const x: usize = g.grid_pos[0];
                        if (x >= cols or x < left or x > right) continue;
                        var h = g;
                        h.grid_pos[1] = ScrollAnim.ghostYEncode(@intCast(y));
                        h.bools.scroll_ghost = true;
                        h.bools.scroll_underlay = true;
                        self.scroll_ghost.append(self.alloc, h) catch break :under;
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
        pub fn noteInputActivity(self: *Self, typed: bool) void {
            // drawFrame reads `key_paced` on the app thread (GTK).
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());
            self.input_activity_ts = .now(global.io(), .awake);
            self.input_typed = typed;
            // A wheel movement arrives as this AND `noteWheelActivity`,
            // which clears it again.
            self.scroll_anim.key_paced = true;
        }

        /// Record a wheel or touchpad scroll and its direction.
        ///
        /// Claude Code answers the wheel by redrawing, four rows a notch. A
        /// hand flicks several notches at once, and two things went wrong
        /// (8 scrolls in 10 "jump directly", 2026-10-02): the redraws merge
        /// into one frame that moved 12 or 16 rows, past what a recovered
        /// shift was allowed to be, so it was dropped and the screen snapped;
        /// and a transcript full of bullets and blank lines sometimes matched
        /// better the WRONG way (wheel up read as `shift=6`), which slid the
        /// text backwards before it landed. While the wheel is the cause, the
        /// detector looks as far as `max_wheel_rows` and only the wheel's way.
        ///
        /// Called from the render thread's mailbox.
        pub fn noteWheelActivity(self: *Self, dir: i8, fast: bool) void {
            // drawFrame reads these on the app thread (GTK): `wheel_ts` for
            // the cursor effects and `key_paced` for the spring.
            self.draw_mutex.lockUncancelable(global.io());
            defer self.draw_mutex.unlock(global.io());
            self.wheel_ts = .now(global.io(), .awake);
            if (fast) self.wheel_fast_ts = self.wheel_ts;
            self.wheel_dir = dir;
            self.scroll_anim.key_paced = false;
        }

        /// The wheel is spinning too fast to animate (`scroll-animation-wheel-snap`):
        /// a scroll arriving now is drawn as a plain jump. Holds for a short
        /// while after the last fast movement, which is how long the
        /// application takes to answer it.
        fn wheelSnapping(self: *const Self, now: std.Io.Timestamp) bool {
            const t = self.wheel_fast_ts orelse return false;
            return t.durationTo(now).nanoseconds <= 80 * std.time.ns_per_ms;
        }

        /// How long after a wheel movement a repaint is taken to be its doing.
        pub const wheel_repaint_ms: i64 = 300;

        /// Animate this frame's scroll event (stashed by the event handling in
        /// `updateFrame`), by the distance the frame shows when that is
        /// further than the event said (`scroll_event_total`).
        fn applyPendingScroll(self: *Self) void {
            const p = self.scroll_pending orelse return;
            self.scroll_pending = null;
            const rows = self.scroll_event_total orelse p.rows;
            self.scroll_event_total = null;
            if (rows != p.rows) {
                self.scroll_trace_rows += rows - p.rows;
                if (self.scroll_anim_last_event) |*le| le.rows = rows;
                if (self.config.scroll_trace) log.info(
                    "scroll event undersold rows={d} -> {d} region={d}..{d}",
                    .{ p.rows, rows, p.top, p.bottom },
                );
            }
            const cell_h: f32 = @floatFromInt(self.size.cell.height);
            const was_idle = !self.scroll_anim.active();
            self.keepScrollGhosts(rows, p.top, p.bottom, p.left, p.right, null);
            self.scroll_anim.push(
                @as(f32, @floatFromInt(rows)) * cell_h,
                @floatFromInt(p.top),
                @floatFromInt(p.bottom),
                @floatFromInt(p.left),
                @floatFromInt(p.right),
                p.limit,
            );
            if (self.wheelSnapping(.now(global.io(), .awake))) self.scroll_anim.stop();
            if (was_idle) self.scroll_anim_last = null;
            // Rows beside the event that moved with it (needs the push done).
            const n = self.terminal_state.row_data.items(.cells).len;
            const cols: usize = self.terminal_state.cols;
            const cur = self.scroll_row_hashes.items;
            const prev = self.scroll_hashes_before.items;
            if (n > 0 and cur.len == n * cols and prev.len == cur.len)
                self.extendEventRows(cur, prev, n, cols);
        }

        /// An application's scroll may leave out rows that moved with it,
        /// repainting them instead. nvim scrolling up onto a figure hung above
        /// its top line (virtual lines, `topfill`) scrolls only the rows BELOW
        /// the figure -- `IL` in a region starting there, `region=5..52`, then
        /// 6..52, 7..52 -- and repaints the figure's rows, one row lower. The
        /// event animated only its region, so the figure's lower rows slid and
        /// its upper rows did not: the picture tore, its first row drawn twice
        /// and a later one lost (recorded with OBS at CSAPP ch. 2 line 291).
        /// Rows next to the event's region whose content IS last frame's
        /// shifted by the same amount join the animation, and the region the
        /// rest of the gesture is held to. Rows arriving at the edge the
        /// content comes from (new, so matching nothing) come along, as in
        /// `detectShift`.
        fn extendEventRows(self: *Self, cur: []const u64, prev: []const u64, n: usize, cols: usize) void {
            const le = self.scroll_anim_last_event orelse return;
            if (le.rows == 0 or !self.scroll_anim.active()) return;
            if (le.bottom >= n or le.top > le.bottom) return;
            const rowMoved = struct {
                fn f(cu: []const u64, pr: []const u64, r: usize, rows: isize, n_: usize, cols_: usize) bool {
                    const src = @as(isize, @intCast(r)) + rows;
                    if (src < 0 or src >= @as(isize, @intCast(n_))) return false;
                    const a = cu[r * cols_ ..][0..cols_];
                    const b = pr[@as(usize, @intCast(src)) * cols_ ..][0..cols_];
                    return std.mem.eql(u64, a, b) and !std.mem.eql(u64, a, pr[r * cols_ ..][0..cols_]);
                }
            }.f;
            const rowChanged = struct {
                fn f(cu: []const u64, pr: []const u64, r: usize, cols_: usize) bool {
                    return !std.mem.eql(u64, cu[r * cols_ ..][0..cols_], pr[r * cols_ ..][0..cols_]);
                }
            }.f;
            var lo = le.top;
            while (lo > 0 and rowMoved(cur, prev, lo - 1, le.rows, n, cols)) lo -= 1;
            var hi = le.bottom;
            while (hi + 1 < n and rowMoved(cur, prev, hi + 1, le.rows, n, cols)) hi += 1;
            // The rows arriving from the edge: above for content moving down.
            // Only into rows some event of this gesture scrolled -- never the
            // status line (see `scroll_event_span`).
            // A row holding part of a figure is content wherever it is.
            const sp = self.scroll_event_span orelse return;
            const hasImage = struct {
                fn f(cu: []const u64, r: usize, cols_: usize) bool {
                    for (cu[r * cols_ ..][0..cols_]) |key| {
                        if (ScrollAnim.glyphOf(key) == ScrollAnim.placeholder_glyph) return true;
                    }
                    return false;
                }
            }.f;
            var k: usize = 0;
            while (k < @abs(le.rows)) : (k += 1) {
                if (le.rows < 0 and lo > 0 and rowChanged(cur, prev, lo - 1, cols) and
                    (lo > sp.top or hasImage(cur, lo - 1, cols))) lo -= 1;
                if (le.rows > 0 and hi + 1 < n and rowChanged(cur, prev, hi + 1, cols) and
                    (hi < sp.bottom or hasImage(cur, hi + 1, cols))) hi += 1;
            }
            if (lo == le.top and hi == le.bottom) return;
            self.scroll_anim.top = @min(self.scroll_anim.top, @as(f32, @floatFromInt(lo)));
            self.scroll_anim.bottom = @max(self.scroll_anim.bottom, @as(f32, @floatFromInt(hi)));
            if (self.scroll_anim_app_region) |*r| {
                r.top = @min(r.top, lo);
                r.bottom = @max(r.bottom, hi);
            }
            if (self.config.scroll_trace) log.info(
                "scroll event widened rows={d} {d}..{d} -> {d}..{d}",
                .{ le.rows, le.top, le.bottom, lo, hi },
            );
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
            // Typing is not scrolling. With an insert cursor, a typed key's
            // redraw is the text being edited: nvim's completion menu
            // re-sorting moved its entries a row, and the region grew
            // across the still text beside it and over the status line,
            // which slid up and back and was drawn twice (tear.mkv
            // 3:02, 2026-10-29). Normal-mode `j` has a block cursor, and
            // the wheel and app-declared scrolls never come through here.
            const typing = self.input_typed and
                sinceMs(now, self.wheel_ts) > repaint_key_idle_ms and
                self.terminal_state.cursor.visual_style == .bar;
            // The chain only extends a gesture the user is still close to:
            // see `repaint_chain_max_ms`.
            const key_idle = sinceMs(now, self.input_activity_ts);
            const chain_over = sinceMs(now, self.scroll_chain_ts) > repaint_chain_ms or
                key_idle > repaint_chain_max_ms;
            if (typing or (key_idle > repaint_key_idle_ms and chain_over)) {
                self.scroll_chain_ts = null;
                self.scroll_row_hashes.clearRetainingCapacity();
                self.scroll_hashes_before.clearRetainingCapacity();
                // The gesture is over, so the region an application declared
                // during it stops being what the next one will use.
                self.scroll_anim_app_region = null;
                self.scroll_event_span = null;
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
                // AN EVENT THAT UNDERSELLS. tmux merges an application's
                // updates, so one frame can hold a scroll command AND a
                // repaint that moved the content further: a wheel notch in
                // nvim went 2343 -> 2350 (skipcol 752), about ten rows in 8
                // steps over 26 ms, and arrived as `rows=2` plus a repaint.
                // The event animated 2 and the other 8 rows snapped -- with a
                // figure on screen, the figure jumped (captured frame by frame
                // with GHOSTTY_FRAME_DUMP). The frame is compared with the one
                // before it; if the content moved further the same way, the
                // pending event is animated by that distance instead.
                if (self.scroll_pending) |pend| if (prev.len == cur.len) {
                    if (ScrollAnim.detectShiftUpTo(cur, prev, n, cols, repaint_scroll_min_rows, repaint_scroll_min_ratio, ScrollAnim.max_detect_rows)) |whole| {
                        // The same direction, further, and across (nearly)
                        // the event's whole width: a tmux pane beside it
                        // moving on its own must not stretch this one.
                        const wide = (whole.right - whole.left + 1) * 5 >= (pend.right - pend.left + 1) * 4;
                        if (wide and (whole.rows > 0) == (pend.rows > 0) and @abs(whole.rows) > @abs(pend.rows))
                            self.scroll_event_total = whole.rows;
                    }
                };
                return;
            }
            if (prev.len != cur.len) return;

            // The rows an event left out are often repainted a frame AFTER it
            // (nvim's figure rows, see `extendEventRows`): check again against
            // the screen from before the event, while that event is recent.
            if (self.scroll_anim_last_event) |le| {
                const pre = self.scroll_pre_event_hashes.items;
                if (sinceMs(now, le.ts) <= repair_partial_ms and pre.len == cur.len)
                    self.extendEventRows(cur, pre, n, cols);
            }

            // Only for an application that answers the wheel by redrawing
            // alone. nvim sends scroll commands for the wheel; recovering
            // its large repaints as well took fast wheel scrolling there
            // from 94% smooth to 86%.
            const by_wheel = self.wheel_dir != 0 and sinceMs(now, self.wheel_ts) <= wheel_repaint_ms and
                (self.scroll_anim_last_event == null or sinceMs(now, self.scroll_anim_last_event.?.ts) > 1000);
            const shift = ScrollAnim.detectShiftDir(
                cur,
                prev,
                n,
                cols,
                repaint_scroll_min_rows,
                repaint_scroll_min_ratio,
                if (by_wheel) ScrollAnim.max_wheel_rows else ScrollAnim.max_animated_rows,
                if (by_wheel) self.wheel_dir else 0,
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
            self.keepScrollGhosts(shift.rows, top, bottom, shift.left, shift.right, .{ cur, prev });
            self.scroll_anim.push(
                @as(f32, @floatFromInt(shift.rows)) * cell_h,
                @floatFromInt(top),
                @floatFromInt(bottom),
                @floatFromInt(shift.left),
                @floatFromInt(shift.right),
                cell_h * ScrollAnim.ghost_lag_rows,
            );
            if (self.wheelSnapping(now)) self.scroll_anim.stop();
            if (was_idle) self.scroll_anim_last = null;
            self.scroll_chain_ts = now;

            // Debugging aid: GHOSTTY_HASH_DUMP=<file> appends the two cell-key
            // grids of every detected repaint scroll (u32 rows, u32 cols, prev, cur),
            // for replaying `detectShift` offline.
            if (std.c.getenv("GHOSTTY_HASH_DUMP")) |dp| {
                const fd = std.c.open(dp, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c_uint, 0o644));
                if (fd >= 0) {
                    defer _ = std.c.close(fd);
                    const hdr = [2]u32{ @intCast(n), @intCast(cols) };
                    const pb = std.mem.sliceAsBytes(prev);
                    const cb = std.mem.sliceAsBytes(cur);
                    _ = std.c.write(fd, std.mem.asBytes(&hdr), 8);
                    _ = std.c.write(fd, pb.ptr, pb.len);
                    _ = std.c.write(fd, cb.ptr, cb.len);
                }
            }
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

        /// The render thread wants a frame but `hasVsync` says it must not
        /// draw on its own: mark it wanted for the next frame-link tick,
        /// and wake the apprt if it had stopped ticking.
        ///
        /// Must be called on the render thread.
        pub fn requestFrame(self: *Self) void {
            if (comptime DisplayLink != void or ExportedFrame == void) return;
            if (self.frame_link.want()) {
                _ = self.surface_mailbox.push(.redraw, .{ .forever = {} });
            }
        }

        /// Returns true if the display link is running, meaning frames
        /// are paced by display refresh. In that case the render thread
        /// must only draw when the display link wakes it through
        /// `draw_now`, and not on its own.
        ///
        /// This reflects the link's actual state. Right after
        /// `syncDisplayLink` asks the link to start, this is still false
        /// until the main thread starts it, and the render thread draws
        /// immediately in the meantime.
        pub fn hasVsync(self: *const Self) bool {
            if (comptime DisplayLink == void) {
                if (comptime ExportedFrame == void) return false;
                return self.frame_link.enabled.load(.acquire);
            }
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

        /// Called when the apprt reports a change in how well
        /// frames can be presented.
        pub fn setPresentationHealth(self: *Self, health: Health) void {
            self.presentation_health.store(health, .seq_cst);
        }

        /// Returns how well frames can be presented.
        pub fn presentationHealth(self: *Self) Health {
            return self.presentation_health.load(.seq_cst);
        }

        /// Callback when the window is visible or occluded.
        ///
        /// Must be called on the render thread.
        pub fn setVisible(self: *Self, visible: bool) void {
            self.visible = visible;
            self.syncDisplayLink(null, null);

            // When we're hidden, release our GPU resources.
            if (!visible) {
                self.draw_mutex.lockUncancelable(global.io());
                defer self.draw_mutex.unlock(global.io());
                self.releaseGpuResources();
            }
        }

        /// Release the GPU resources we hold while the surface is not
        /// visible. Today this is the swap chain (render targets, font
        /// atlas texture copies, cell buffers, custom shader textures),
        /// which makes up nearly all of a surface's GPU memory usage.
        /// The swap chain is rebuilt on the next `drawFrame`.
        ///
        /// Note that images are NOT released here since we don't want
        /// to reupload images every time the terminal is brought back
        /// from being occluded or unrealized.
        ///
        /// Caller must lock the draw mutex before calling this function.
        /// Resources that are already released are skipped.
        pub fn releaseGpuResources(self: *Self) void {
            if (self.swap_chain) |*sc| {
                // Waits for any in-flight frames to complete, then
                // frees all GPU resources.
                sc.deinit();
                self.swap_chain = null;
            }

            // Release the shaders as well if we're unrealized.
            if (!self.display_realized) {
                self.shaders.deinit(self.alloc);
            }
        }

        /// Create the display link if needed, then ask it to match the
        /// current surface state: bound to `display_id` if one is given,
        /// and running only while the surface is visible and has
        /// something to draw (rebuilt cells or a running animation).
        ///
        /// `draw_now` is required the first time this is called, since
        /// creating the link needs the handle its callback will notify.
        /// Later calls can pass null.
        ///
        /// Must be called on the render thread. This never blocks. The
        /// display link applies the requested state on the main thread
        /// shortly after, because starting and stopping a CVDisplayLink
        /// anywhere else can deadlock against CoreVideo's own display
        /// reconfiguration handling. See `renderer/DisplayLink.zig`
        /// for the full explanation.
        fn syncDisplayLink(
            self: *Self,
            display_id: ?u32,
            draw_now: ?*xev.Async,
        ) void {
            if (comptime DisplayLink == void) return;

            const display_link = self.display_link orelse display_link: {
                if (!self.config.vsync) return;
                const callback = draw_now orelse return;
                const result = DisplayLink.create(
                    self.alloc,
                    xev.Async,
                    &displayLinkCallback,
                    callback,
                ) catch |err| {
                    // A locked macOS session can temporarily have no active
                    // displays. Rendering continues without vsync and the
                    // next call to this function tries again.
                    log.warn("error creating display link; using fallback rendering err={}", .{err});
                    return;
                };

                self.display_link = result;
                log.info("created display link", .{});
                break :display_link result;
            };

            if (display_id) |id| display_link.setDisplay(id);

            const should_run =
                // Non-visible windows never vsync
                self.visible and
                // Only vsync if we have cell or image changes or animation
                (self.cells_rebuilt or
                    self.images_rebuilt or
                    self.animationWake() != null);

            display_link.setRunning(should_run);
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
            // and came back ("the image jumps up a line and back").
            //
            // It is taken at the first of those, never before: not before
            // `lockDemand`. Waiting for the terminal while holding it made
            // the GTK app thread wait out the IO thread too -- under heavy
            // output (`cat` of a big file) every draw stalled for the length
            // of the terminal wait, scroll animation on or off. The lock
            // order terminal -> draw is the one upstream already uses for
            // kittyUpdate, and drawFrame never takes the terminal lock.
            var draw_held = false;
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
                //
                // Its rows are rows of the ACTIVE area. With the viewport
                // scrolled back into history those are not the rows on
                // screen -- what is drawn did not move at all -- so the event
                // is dropped, as the terminal already drops it on a resize or
                // a screen switch.
                const scroll_event = if (state.terminal.screens.active.pages.viewport == .active)
                    state.terminal.scroll_event
                else
                    null;
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

                // Advance any running Kitty graphics animations to the
                // frame due now, and remember when the next frame is
                // due (as an absolute deadline, see animationWake) so
                // the renderer thread can schedule a wakeup for it.
                //
                // This runs before the render state update. Advancing
                // a frame gives the image a new generation, so the
                // update then reports placements with the new frame,
                // and the frame is uploaded and drawn right away.
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

                // Rebuild our Kitty image placements when the placements
                // or the images changed. The render state update above
                // has already positioned every placement, so this is
                // cheap. Most frames that only change text skip it.
                if (self.images.kittyRequiresUpdate(
                    state.terminal,
                    &self.terminal_state,
                )) {
                    // Held from here to the rebuild (see above).
                    if (!draw_held) {
                        self.draw_mutex.lockUncancelable(global.io());
                        draw_held = true;
                    }
                    if (self.config.scroll_animation) {
                        self.scroll_prev_images.clearRetainingCapacity();
                        self.scroll_prev_images.appendSlice(self.alloc, self.images.kitty_placements.items) catch
                            self.scroll_prev_images.clearRetainingCapacity();
                    }
                    self.images.kittyUpdate(
                        self.alloc,
                        state.terminal,
                        &self.terminal_state,
                    );
                    self.images_rebuilt = true;
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

            // The terminal is released; from here the scroll state drawFrame
            // reads changes, so hold the draw mutex to the rebuild (see above).
            if (!draw_held) {
                self.draw_mutex.lockUncancelable(global.io());
                draw_held = true;
            }

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
                        "scroll event: rows={d} start={d} region={d}..{d} rows_total={d} src={s} cell_h={d} mono_us={d} cols={d}..{d}",
                        .{
                            ev.rows,
                            ev.top,
                            ev.region_top,
                            ev.bottom,
                            self.size.grid().rows,
                            @tagName(ev.source),
                            self.size.cell.height,
                            @divTrunc(std.Io.Timestamp.now(global.io(), .awake).nanoseconds, std.time.ns_per_us),
                            ev.left,
                            ev.right,
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

                // `applyPendingScroll` displaces by exactly the distance just
                // scrolled, so the first animated frame reproduces the
                // pre-scroll screen, and eases to
                // zero from there. The model is already current -- writes land
                // during the animation and must not be delayed (SPEC stage 2)
                // -- so this only ever moves what is drawn.
                const cell_h: f32 = @floatFromInt(self.size.cell.height);

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
                if (self.scroll_anim_last_event) |*le| {
                    le.top = ev.region_top;
                    le.bottom = bottom;
                }
                self.scroll_event_span = if (self.scroll_event_span) |sp| .{
                    .top = @min(sp.top, ev.region_top),
                    .bottom = @max(sp.bottom, bottom),
                } else .{ .top = ev.region_top, .bottom = bottom };

                // Remember it for the repaint detector, which cannot see a
                // scrolling margin and would otherwise animate the rows this
                // one deliberately leaves out. See `scroll_anim_app_region`.
                self.scroll_anim_app_region = .{
                    .top = ev.region_top,
                    .bottom = bottom,
                    .grid_rows = grid_rows,
                };

                // Applied after the frame is read (`applyPendingScroll`),
                // not here: the frame may show the content moved FURTHER than
                // this event says -- see "an event that undersells".
                //
                // Across the columns the scroll moved: the whole width, or
                // only between the left and right margins (DECSLRM) when the
                // application set them -- tmux scrolls a pane beside another
                // that way, and the pane next to it must hold still.
                const last_col = self.size.grid().columns -| 1;
                const right = @min(ev.right, last_col);
                self.scroll_pending = .{
                    .rows = @intCast(ev.rows),
                    .top = ev.region_top,
                    .bottom = bottom,
                    .left = @min(ev.left, right),
                    .right = right,
                    .limit = limit,
                };
                // (see applyPendingScroll)
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
            if (self.terminal_state.cursor.boom != self.cursor_fx_boom_seen) {
                self.cursor_fx_boom_seen = self.terminal_state.cursor.boom;
                self.cursor_fx_boom_pending = self.terminal_state.cursor.boom_last;
                self.cursor_fx_last_event = .now(global.io(), .awake);
            }
            if (self.terminal_state.cursor.fx_target_seq != self.cursor_fx_target_seq) {
                self.cursor_fx_target_seq = self.terminal_state.cursor.fx_target_seq;
                self.cursor_fx_target = self.terminal_state.cursor.fx_target;
                // Like a pulse it changes no cell: ask for frames, so the
                // smear to it plays.
                self.cursor_fx_last_event = .now(global.io(), .awake);
            }

            // A mode change (cursor style or colour, e.g. nvim i / Esc / v)
            // is only recorded when the frame is DRAWN (updateCursorFx), and
            // on GTK that happens later, on the app thread -- after this
            // thread has already asked animationWake whether to keep
            // drawing. From idle the answer was no, so the effect got the
            // one or two frames something else drew and never visibly
            // played ("the effects sometimes don't play", tbd-5: they did
            // play when another effect was still running). Note it here, as
            // for a pulse, so the animation timer is armed for it.
            {
                const style = self.terminal_state.cursor.visual_style;
                const color = self.terminal_state.colors.cursor;
                const seen = self.cursor_fx_style_seen != null;
                if (seen and (self.cursor_fx_style_seen.? != style or
                    !std.meta.eql(self.cursor_fx_color_seen, color)))
                {
                    self.cursor_fx_last_event = .now(global.io(), .awake);
                }
                self.cursor_fx_style_seen = style;
                self.cursor_fx_color_seen = color;
            }

            // Now the render state is readable, look for movement no event
            // described. Must come after endUpdate: row_data is not valid
            // until the update it began is completed.
            if (self.config.scroll_animation) {
                self.detectRepaintScroll(critical.scroll_event != null);
            }
            self.applyPendingScroll();

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
                        @backingInt(HighlightTag.search_match_selected),
                        &.{m.match},
                    ) catch |err| {
                        // Not a critical error, we just won't show highlights.
                        log.warn("error updating search selected highlight err={}", .{err});
                    };
                }

                if (self.search_matches) |m| {
                    self.terminal_state.updateHighlightsFlattened(
                        self.alloc,
                        @backingInt(HighlightTag.search_match),
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
                // On every frame of a running animation, not only on frames
                // that pushed: an application can move its overlay between
                // scrolls (yazi's bar moving down a list that stopped), and a
                // mask left from the last push held the old row still and
                // left the new one sliding -- a bar half on one row, its caps
                // on another. Frames without a push use the last push's
                // direction for "carried".
                const pushed = self.scroll_frame_push != null;
                if (self.scroll_frame_push) |fp| self.scroll_last_push = .{ .rows = fp.rows, .top = fp.top, .bottom = fp.bottom, .left = fp.left, .right = fp.right };
                const pin_push = if (self.scroll_frame_push) |fp| fp else if (self.scroll_anim.active() and self.scroll_pin_live) if (self.scroll_last_push) |lp| @TypeOf(self.scroll_frame_push.?){ .rows = lp.rows, .top = lp.top, .bottom = lp.bottom, .left = lp.left, .right = lp.right } else null else null;
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
                    const lo_r = if (a.active()) @min(pp.top, f2u(a.top, pp.top)) else pp.top;
                    const hi_r = if (a.active()) @min(@max(pp.bottom, f2u(a.bottom, pp.bottom)), self.cells.size.rows - 1) else pp.bottom;
                    const lo_c = if (a.active()) @min(pp.left, f2u(a.left, pp.left)) else pp.left;
                    const hi_c = if (a.active()) @min(@max(pp.right, f2u(a.right, pp.right)), self.cells.size.columns - 1) else pp.right;
                    if (!pushed) {
                        // A FRAME THAT DID NOT SCROLL finds no new overlays:
                        // with nothing moving, every coloured run "stayed
                        // where it was" and "was not carried there" -- inline
                        // code, a code block's language label, all pinned
                        // and held still while the text around them slid,
                        // and the text check held every overlay's text (the
                        // round-7 per-frame recompute did exactly that). It
                        // keeps last frame's pins instead, dropping cells
                        // whose colour or text changed since (yazi's bar
                        // leaving a row without a scroll).
                        const now_h = self.scroll_row_hashes.items;
                        const bef_h = self.scroll_hashes_before.items;
                        const have_h = now_h.len == n and bef_h.len == n;
                        const eq = std.meta.eql;
                        for (0..n) |k| {
                            const m = &self.scroll_pin.items[k];
                            if (m[0] == 0) continue;
                            if (!eq(self.cells.bg_cells[k], self.scroll_bg_prev.items[k])) {
                                m.* = .{ 0, 0, 0, 0 };
                            } else if (m[1] != 0 and have_h and now_h[k] != bef_h[k]) {
                                m[1] = 0;
                            }
                        }
                    } else {
                        ScrollAnim.computePins(
                            shaderpkg.CellBg,
                            self.scroll_pin.items,
                            self.scroll_bg_prev.items,
                            self.cells.bg_cells,
                            self.cells.size.columns,
                            pp.rows,
                            lo_r,
                            hi_r,
                            lo_c,
                            hi_c,
                        );
                        ScrollAnim.pinStillText(
                            shaderpkg.CellBg,
                            self.scroll_pin.items,
                            self.scroll_row_hashes.items,
                            self.scroll_hashes_before.items,
                            self.cells.size.columns,
                            pp.rows,
                            lo_r,
                            hi_r,
                            lo_c,
                            hi_c,
                        );
                        ScrollAnim.markPinnedText(
                            shaderpkg.CellBg,
                            self.scroll_pin.items,
                            self.scroll_row_hashes.items,
                            self.scroll_hashes_before.items,
                            self.cells.size.columns,
                        );
                    }
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
                            if (cnt > 0) {
                                // The pinned run's text now and last frame,
                                // and which cells hold their text (T).
                                var nb: [48]u8 = @splat(' ');
                                var bb: [48]u8 = @splat(' ');
                                var tb: [48]u8 = @splat(' ');
                                const nh = self.scroll_row_hashes.items;
                                const bh = self.scroll_hashes_before.items;
                                if (nh.len == n and bh.len == n) for (0..@min(48, pc - first.?)) |j| {
                                    const k = r * pc + first.? + j;
                                    const g1 = ScrollAnim.glyphOf(nh[k]);
                                    const g2 = ScrollAnim.glyphOf(bh[k]);
                                    nb[j] = if (g1 == 0) ' ' else if (g1 < 127 and g1 > 32) @intCast(g1) else '#';
                                    bb[j] = if (g2 == 0) ' ' else if (g2 < 127 and g2 > 32) @intCast(g2) else '#';
                                    const m = self.scroll_pin.items[k];
                                    tb[j] = if (m[0] == 0) '.' else if (m[1] != 0) 'T' else 'c';
                                };
                                log.info("scrollpin row={d} col={d} n={d} text={} shift={d} pushed={} now=[{s}] before=[{s}] mask=[{s}]", .{ r, first.?, cnt, self.scroll_pin.items[r * pc + first.?][1] != 0, pp.rows, pushed, nb, bb, tb });
                            }
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
                if (comptime builtin.target.os.tag == .macos) switch (self.config.background_blur) {
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
            // Keep the frame-link ticks coming while anything animates.
            defer if (comptime DisplayLink == void and ExportedFrame != void) {
                if (self.frame_link.enabled.load(.acquire))
                    // A sync draw runs on the main thread: animation state
                    // is the render thread's, and its next draw decides.
                    self.frame_link.frameDone(!sync and self.animationWake() != null);
            };

            // Everything that touches draw state happens under the draw
            // mutex. The display link is synced after the mutex is
            // released. It doesn't need the lock, and this keeps the
            // critical section to just drawing.
            const sync_display_link = locked: {
                self.draw_mutex.lockUncancelable(global.io());
                defer self.draw_mutex.unlock(global.io());
                break :locked try self.drawFrameLocked(sync);
            };

            if (sync_display_link) self.syncDisplayLink(null, null);
        }

        /// The body of `drawFrame`. Must be called with `draw_mutex` held.
        ///
        /// Returns true if the display link should be resynced once the
        /// draw mutex is released. This is only ever true on the no-redraw
        /// path, which a sync draw never takes. Sync draws come from the
        /// main thread, so this keeps `syncDisplayLink` on the render
        /// thread as its contract requires.
        fn drawFrameLocked(
            self: *Self,
            sync: bool,
        ) !bool {
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
            if (surface_size.width == 0 or surface_size.height == 0) return false;

            // If we have no graphics context we can't draw. This is
            // only the case while unrealized (GTK) or after the render
            // thread exits; displayRealized rebuilds the swap chain.
            if (!self.display_realized) return false;

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
                self.images_rebuilt or
                self.animationWake() != null or
                sync;

            if (!needs_redraw) {
                // Ask our caller to resync the display link once the draw
                // mutex is released, because we can probably pause the
                // display link at this point.
                return true;
            }
            self.cells_rebuilt = false;
            self.last_draw_ts = .now(global.io(), .awake);
            self.images_rebuilt = false;

            // Wait for a frame to be available.
            const frame = swap_chain.nextFrame();
            errdefer swap_chain.releaseFrame();
            self.cache_seq += 1;
            // log.debug("drawing frame index={}", .{swap_chain.frame_index});

            // If we need to reinitialize our shaders, do so.
            if (self.reinitialize_shaders) {
                self.reinitialize_shaders = false;
                self.shaders.deinit(self.alloc);
                try self.initShaders();
                self.cache_damage_full = true;
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
                self.cache_damage_full = true;
            }
            if (size_changed or swap_chain_rebuilt) self.cache_damage_full = true;

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
                try self.scroll_bg_view.append(self.alloc, .{ .items = self.cells.bg_cells, .capacity = self.cells.bg_cells.len, .pointer_stability = .{} });
                var off = grid_n;
                if (ghost_bg) {
                    try self.scroll_bg_view.append(self.alloc, self.scroll_ghost_bg);
                    off += self.scroll_ghost_bg.items.len;
                    self.uniforms.scroll_anim[3] = @floatFromInt(ScrollAnim.max_ghost_rows);
                }
                if (pinned) {
                    try self.scroll_bg_view.append(self.alloc, self.scroll_pin);
                    self.uniforms.scroll_anim_cols[3] = @floatFromInt(off);
                    // The underlay grid directly after the mask: the shader
                    // reads it at mask index + grid size, so it must be there.
                    if (self.scroll_pin_under.items.len != grid_n) {
                        try self.scroll_pin_under.resize(self.alloc, grid_n);
                        @memset(self.scroll_pin_under.items, .{ 0, 0, 0, 0 });
                    }
                    ScrollAnim.fillUnderlay(shaderpkg.CellBg, self.scroll_pin_under.items, self.scroll_pin.items, self.cells.bg_cells, self.cells.size.columns);
                    try self.scroll_bg_view.append(self.alloc, self.scroll_pin_under);
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
                self.cache_damage_full = true;
            }

            // If our font atlas changed, sync the texture data
            texture: {
                const modified = self.font_grid.atlas_grayscale.modified.load(.monotonic);
                if (modified <= frame.grayscale_modified) break :texture;
                self.cache_damage_full = true;
                self.font_grid.lock.lockSharedUncancelable(global.io());
                defer self.font_grid.lock.unlockShared(global.io());
                frame.grayscale_modified = self.font_grid.atlas_grayscale.modified.load(.monotonic);
                try self.syncAtlasTexture(&self.font_grid.atlas_grayscale, &frame.grayscale);
            }
            texture: {
                const modified = self.font_grid.atlas_color.modified.load(.monotonic);
                if (modified <= frame.color_modified) break :texture;
                self.cache_damage_full = true;
                self.font_grid.lock.lockSharedUncancelable(global.io());
                defer self.font_grid.lock.unlockShared(global.io());
                frame.color_modified = self.font_grid.atlas_color.modified.load(.monotonic);
                try self.syncAtlasTexture(&self.font_grid.atlas_color, &frame.color);
            }

            // Get a frame context from the graphics API.
            var frame_ctx = try self.api.beginFrame(self, &frame.target);
            defer frame_ctx.complete(sync);

            // custom-shader-cache: the cached path replaces everything below.
            if (comptime @hasDecl(GraphicsAPI, "custom_shader_cache_supported")) cached: {
                const state = if (frame.custom_shader_state) |*st| st else break :cached;
                const n = self.shaders.post_pipelines.len;
                if (!self.config.custom_shader_cache or n == 0 or
                    n > CustomShaderState.max_cache)
                {
                    // Leaving the cached path: nothing it tracked is valid
                    // when it is next entered.
                    self.cache_damage_full = true;
                    self.cache_final_settled = false;
                    break :cached;
                }
                try self.drawFrameCached(frame, state, &frame_ctx, fg_count);
                return false;
            }

            // Drawn without the cache: this slot's cache layers are stale,
            // and no slot can catch up across this frame by redoing strips.
            frame.cache_seq = 0;
            self.cache_log[self.cache_seq % cache_log_len] = .{ .seq = self.cache_seq };

            {
                var pass = frame_ctx.renderPass(&.{.{
                    .target = if (frame.custom_shader_state) |state|
                        .{ .texture = state.back_texture }
                    else
                        .{ .target = frame.target },
                    .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                }});
                defer pass.complete();
                self.drawCellSteps(&pass, frame, fg_count);
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

            return false;
        }

        /// The terminal image: backgrounds, images, text. Everything a frame
        /// draws before any custom shader runs.
        fn drawCellSteps(
            self: *Self,
            pass: *RenderPass,
            frame: *FrameState,
            fg_count: usize,
        ) void {
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
                pass,
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
                pass,
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
                pass,
                .kitty_above_text,
            );

            // Debug overlay. We do this before any custom shader state
            // because our debug overlay is aligned with the grid.
            if (self.overlay != null) self.images.draw(
                &self.api,
                self.shaders.pipelines.image,
                pass,
                .overlay,
            );
        }

        /// What part of the terminal image differs from the last frame
        /// drawn, and consume the record of it. Anything this cannot name
        /// as a set of rows is `full`.
        fn takeCacheDamage(self: *Self) CacheDamage {
            const rows = self.cache_damage_rows.items;
            defer {
                @memset(rows, false);
                self.cache_damage_full = false;
                self.cache_last_uniforms = self.uniforms;
                self.cache_last_cursor = self.cells.getCursorGlyph();
            }

            // State that redraws the whole window, or that no dirty row
            // announces. It forces `full` on the frame after it ends as well:
            // that frame is what paints over what it left behind.
            const volatile_now = self.scroll_anim.active() or
                self.images.kitty_placements.items.len > 0 or
                // Stale slices are never drawn (see `clearScrollGhosts`) and
                // can sit here long after the animation that kept them.
                (!self.scroll_image_ghosts_stale and self.images.kitty_ghosts.items.len > 0) or
                self.overlay != null or
                self.bg_image != null;
            const volatile_before = self.cache_last_volatile;
            self.cache_last_volatile = volatile_now;
            self.cache_note_volatile = .{ volatile_now, volatile_before };
            if (self.cache_damage_full or volatile_now or volatile_before) return .{ .full = true };

            // The uniforms move the whole image (padding, colours, the
            // scroll offset), except the cursor's: those recolour the text
            // under a block cursor, on the cursor's own row.
            const last_u = self.cache_last_uniforms orelse return .{ .full = true };
            var cursor_rows: [4]?usize = @splat(null);
            {
                var cmp = self.uniforms;
                cmp.cursor_pos = last_u.cursor_pos;
                cmp.cursor_color = last_u.cursor_color;
                cmp.bools.cursor_wide = last_u.bools.cursor_wide;
                if (!std.meta.eql(cmp, last_u)) return .{ .full = true };
                if (!std.meta.eql(self.uniforms, last_u)) {
                    cursor_rows[0] = last_u.cursor_pos[1];
                    cursor_rows[1] = self.uniforms.cursor_pos[1];
                }
            }
            {
                const now_c = self.cells.getCursorGlyph();
                if (!std.meta.eql(now_c, self.cache_last_cursor)) {
                    if (self.cache_last_cursor) |c| cursor_rows[2] = c.grid_pos[1];
                    if (now_c) |c| cursor_rows[3] = c.grid_pos[1];
                }
            }
            // An off-grid row (the uniform's "no cursor" value) is no row.
            for (cursor_rows) |r| if (r) |y| {
                if (y < rows.len) rows[y] = true;
            };

            // Rows to strips. Rows closer than two margins share a strip,
            // because their strips would overlap anyway.
            const cell_h: u32 = self.size.cell.height;
            const pad_top: u32 = self.size.padding.top;
            const screen_h: u32 = self.size.screen.height;
            const margin: u32 = self.config.custom_shader_cache_margin;
            if (cell_h == 0) return .{ .full = true };
            const gap: usize = (2 * margin) / cell_h + 1;

            var d: CacheDamage = .{};
            var y: usize = 0;
            while (y < rows.len) {
                if (!rows[y]) {
                    y += 1;
                    continue;
                }
                var last = y;
                var z = y + 1;
                while (z < rows.len and z - last <= gap) : (z += 1) {
                    if (rows[z]) last = z;
                }
                const top: u32 = if (y == 0) 0 else (pad_top + @as(u32, @intCast(y)) * cell_h) -| margin;
                const bottom: u32 = if (last + 1 >= rows.len)
                    screen_h
                else
                    @min(screen_h, pad_top + @as(u32, @intCast(last + 1)) * cell_h + margin);
                if (d.n == cache_max_bands) {
                    // Too many strips: one strip from the first to the last.
                    d.bands[0].bottom = bottom;
                    d.n = 1;
                    var w = last + 1;
                    while (w < rows.len) : (w += 1) if (rows[w]) {
                        d.bands[0].bottom = if (w + 1 >= rows.len)
                            screen_h
                        else
                            @min(screen_h, pad_top + @as(u32, @intCast(w + 1)) * cell_h + margin);
                    };
                    break;
                }
                d.bands[d.n] = .{ .top = @min(top, screen_h), .bottom = bottom };
                d.n += 1;
                y = last + 1;
            }
            // Nearly everything: the bookkeeping buys nothing.
            var px: u64 = 0;
            for (d.bands[0..d.n]) |b| px += b.bottom - b.top;
            if (px * 10 >= @as(u64, screen_h) * 9) return .{ .full = true };
            return d;
        }

        /// The box a live cursor effect can draw in, as a GL scissor: the
        /// cursor as it is, the ends of its last move, and where it was at
        /// each recent mode change or pulse, grown by the configured reach.
        /// Shader coordinates here are GL's (+y up, a rect is left, top, w, h).
        fn cacheFxBox(self: *const Self, width: u32, height: u32) [4]u32 {
            const u = &self.custom_shader_uniforms;
            const w_f: f32 = @floatFromInt(width);
            const h_f: f32 = @floatFromInt(height);
            var x0: f32 = w_f;
            var y0: f32 = h_f;
            var x1: f32 = 0;
            var y1: f32 = 0;
            const Acc = struct {
                fn add(r: [4]f32, ax0: *f32, ay0: *f32, ax1: *f32, ay1: *f32) void {
                    if (r[2] <= 0 and r[3] <= 0) return; // never set
                    ax0.* = @min(ax0.*, r[0]);
                    ax1.* = @max(ax1.*, r[0] + r[2]);
                    ay1.* = @max(ay1.*, r[1]);
                    ay0.* = @min(ay0.*, r[1] - r[3]);
                }
            };
            // Longer than any effect lasts; the live window is 1.3 s.
            const recent: f32 = 2.0;
            Acc.add(u.current_cursor, &x0, &y0, &x1, &y1);
            if (u.time - u.time_cursor_move < recent) {
                Acc.add(u.cursor_move_from, &x0, &y0, &x1, &y1);
                Acc.add(u.cursor_move_to, &x0, &y0, &x1, &y1);
            }
            for (u.cursor_fx_event, u.cursor_fx_event_rect) |ev, rect| {
                if (u.time - ev[0] < recent) Acc.add(rect, &x0, &y0, &x1, &y1);
            }
            if (x1 <= x0 or y1 <= y0) return .{ 0, 0, width, height };
            const reach = self.config.custom_shader_cache_fx_reach *
                @as(f32, @floatFromInt(self.size.cell.height));
            x0 = std.math.clamp(@floor(x0 - reach), 0, w_f);
            y0 = std.math.clamp(@floor(y0 - reach), 0, h_f);
            x1 = std.math.clamp(@ceil(x1 + reach), 0, w_f);
            y1 = std.math.clamp(@ceil(y1 + reach), 0, h_f);
            if (x1 <= x0 or y1 <= y0) return .{ 0, 0, width, height };
            return .{
                @intFromFloat(x0),
                @intFromFloat(y0),
                @intFromFloat(x1 - x0),
                @intFromFloat(y1 - y0),
            };
        }

        /// `custom-shader-cache`: draw a frame by redoing only what changed.
        ///
        /// Three layers, each kept from the last frame:
        ///
        ///   cache[0]        the terminal image
        ///   cache[1..n-1]   the output of each static shader
        ///   frame.target    the output of the last (animated) shader
        ///
        /// Every pass draws exactly what the uncached path draws, clipped to
        /// the strips of the window that changed. That is correct as long as
        /// nothing outside the strips would have come out different, which is
        /// what `takeCacheDamage` and the margin are for.
        fn drawFrameCached(
            self: *Self,
            frame: *FrameState,
            state: *CustomShaderState,
            frame_ctx: anytype,
            fg_count: usize,
        ) !void {
            const pipelines = self.shaders.post_pipelines;
            const n = pipelines.len;
            const width: u32 = self.size.screen.width;
            const height: u32 = self.size.screen.height;
            const debug = self.config.custom_shader_cache_debug;

            // This slot's layers hold the frame drawn into it at
            // `frame.cache_seq`: nothing usable if they were just made.
            const slot_seq = frame.cache_seq;
            frame.cache_seq = 0; // until this frame is drawn
            const slot_fresh = try state.ensureCache(self.api, n, width, height, debug == .verify) or
                slot_seq == 0 or self.cache_seq - slot_seq >= cache_log_len;

            // What this frame changes, from the frame before it.
            const damage = self.takeCacheDamage();
            try state.uniforms.sync(&.{self.custom_shader_uniforms});

            // What this slot has to redo: that, and what every frame drawn
            // since this slot's own last frame changed.
            var slot_bands: CacheDamage = if (slot_fresh) .{ .full = true } else damage;
            var missed: [cache_log_len]*const CacheLogEntry = undefined;
            var missed_n: usize = 0;
            if (!slot_fresh) {
                var seq = slot_seq + 1;
                while (seq < self.cache_seq) : (seq += 1) {
                    const e = &self.cache_log[seq % cache_log_len];
                    if (e.seq != seq) {
                        slot_bands = .{ .full = true };
                        break;
                    }
                    slot_bands.merge(e.bands);
                    missed[missed_n] = e;
                    missed_n += 1;
                }
            }

            // A strip as a GL scissor: origin bottom-left, and the image is
            // upright (row 0 at the top of the window is the highest y).
            const Scissor = struct {
                fn of(b: CacheBand, w: u32, h: u32) [4]u32 {
                    return .{ 0, h - b.bottom, w, b.bottom - b.top };
                }
            };
            const whole: [1]CacheBand = .{.{ .top = 0, .bottom = height }};
            const bands: []const CacheBand = if (slot_bands.full) &whole else slot_bands.bands[0..slot_bands.n];

            // 1. The terminal image and the static shaders, over the strips.
            for (bands) |b| {
                const scissor: ?[4]u32 = if (slot_bands.full) null else Scissor.of(b, width, height);
                {
                    var pass = frame_ctx.renderPass(&.{.{
                        .target = .{ .texture = state.cache[0].? },
                        .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                        .scissor = scissor,
                    }});
                    defer pass.complete();
                    self.drawCellSteps(&pass, frame, fg_count);
                }
                for (pipelines[0 .. n - 1], 0..) |pipeline, i| {
                    var pass = frame_ctx.renderPass(&.{.{
                        .target = .{ .texture = state.cache[i + 1].? },
                        .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                        .scissor = scissor,
                    }});
                    defer pass.complete();
                    pass.step(.{
                        .pipeline = pipeline,
                        .uniforms = state.uniforms.buffer,
                        .textures = &.{state.cache[i].?},
                        .samplers = &.{state.sampler},
                        .draw = .{ .type = .triangle, .vertex_count = 3 },
                    });
                }
            }

            // 2. The last shader.
            //
            // Without a reach (or outside `cursor` animation): over the whole
            // window while it animates and for one frame after it stops.
            //
            // With `custom-shader-cache-fx-reach` in `cursor` animation: over
            // a box around the cursor's recent events instead, plus the box
            // the last frame drew in, plus the strips. A cursor effect then
            // costs a few cells per frame, not the window.
            //
            // Either way the whole window whenever a uniform the shader can
            // see changed that is not the clock or the cursor's.
            const boxed = self.config.custom_shader_animation == .cursor and
                self.config.custom_shader_cache_fx_reach > 0;
            const live = switch (self.config.custom_shader_animation) {
                .cursor => self.cursorFxLive(),
                .false => false,
                .true, .always => true,
            };
            const uniforms_same = same: {
                const last = self.cache_last_post_uniforms orelse break :same false;
                var cmp = self.custom_shader_uniforms;
                cmp.time = last.time;
                cmp.time_delta = last.time_delta;
                cmp.frame = last.frame;
                cmp.frame_rate = last.frame_rate;
                cmp.date = last.date;
                if (boxed) {
                    // The cursor's own uniforms only matter inside the box.
                    cmp.current_cursor = last.current_cursor;
                    cmp.previous_cursor = last.previous_cursor;
                    cmp.current_cursor_color = last.current_cursor_color;
                    cmp.previous_cursor_color = last.previous_cursor_color;
                    cmp.current_cursor_style = last.current_cursor_style;
                    cmp.previous_cursor_style = last.previous_cursor_style;
                    cmp.cursor_visible = last.cursor_visible;
                    cmp.cursor_change_time = last.cursor_change_time;
                    cmp.cursor_move_from = last.cursor_move_from;
                    cmp.cursor_move_to = last.cursor_move_to;
                    cmp.time_cursor_move = last.time_cursor_move;
                    cmp.time_cursor_mode = last.time_cursor_mode;
                    cmp.time_cursor_pulse = last.time_cursor_pulse;
                    cmp.cursor_fx_event = last.cursor_fx_event;
                    cmp.cursor_fx_event_color = last.cursor_fx_event_color;
                    cmp.cursor_fx_event_rect = last.cursor_fx_event_rect;
                }
                break :same std.meta.eql(cmp, last);
            };
            self.cache_last_post_uniforms = self.custom_shader_uniforms;

            const box_now: ?[4]u32 = if (boxed and live) self.cacheFxBox(width, height) else null;
            const box_prev = self.cache_fx_box;
            const final_full = !self.cache_final_settled or !uniforms_same or damage.full or
                (live and !boxed);

            var final_rects: [final_rects_len]?[4]u32 = @splat(null);
            var final_n: usize = 0;
            if (final_full) {
                final_n = 1; // one pass, no scissor
            } else {
                for (damage.bands[0..damage.n]) |b| {
                    final_rects[final_n] = Scissor.of(b, width, height);
                    final_n += 1;
                }
                if (box_now) |r| {
                    final_rects[final_n] = r;
                    final_n += 1;
                }
                if (box_prev) |r| if (box_now == null or !std.meta.eql(r, box_now.?)) {
                    final_rects[final_n] = r;
                    final_n += 1;
                };
            }
            // This frame's own change, as the API's damage, and what the
            // slot has to redo of the last shader's output: that plus every
            // missed frame's own change.
            const Damage = if (comptime @hasDecl(GraphicsAPI, "Damage")) GraphicsAPI.Damage else void;
            const has_damage = comptime Damage != void;
            var own_final: Damage = if (has_damage) .nothing else {};
            var slot_final: Damage = if (has_damage) .nothing else {};
            if (comptime has_damage) {
                if (final_full) {
                    own_final = .everything;
                } else for (final_rects[0..final_n]) |r| own_final.add(r.?);
                slot_final = if (slot_fresh or slot_bands.full) .everything else own_final;
                for (missed[0..missed_n]) |e| slot_final.merge(e.final);
                if (!slot_final.full) {
                    final_n = 0;
                    for (slot_final.slice()) |r| {
                        final_rects[final_n] = r;
                        final_n += 1;
                    }
                } else {
                    final_rects[0] = null;
                    final_n = 1;
                }
            } else if (slot_fresh or missed_n > 0 or slot_bands.full) {
                final_rects[0] = null;
                final_n = 1;
            }

            for (final_rects[0..final_n]) |scissor| {
                var pass = frame_ctx.renderPass(&.{.{
                    .target = .{ .target = frame.target },
                    .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                    .scissor = scissor,
                }});
                defer pass.complete();
                pass.step(.{
                    .pipeline = pipelines[n - 1],
                    .uniforms = state.uniforms.buffer,
                    .textures = &.{state.cache[n - 1].?},
                    .samplers = &.{state.sampler},
                    .draw = .{ .type = .triangle, .vertex_count = 3 },
                });
            }
            // The frame differs from the last one inside `own_final` and
            // nowhere else, which is all the apprt needs to show it as an
            // update (`gtk-damage-tracking`); the export copies `slot_final`.
            if (comptime has_damage) self.api.setFrameDamage(
                if (self.config.gtk_damage_tracking) own_final else .everything,
                slot_final,
            );
            frame.cache_seq = self.cache_seq;
            self.cache_log[self.cache_seq % cache_log_len] = .{
                .seq = self.cache_seq,
                .bands = damage,
                .final = own_final,
            };
            if (boxed) {
                // After any frame the target is right everywhere except
                // (possibly) inside the box an effect was just drawn in.
                self.cache_final_settled = true;
                self.cache_fx_box = box_now;
            } else {
                if (final_full) self.cache_final_settled = !live;
                self.cache_fx_box = null;
            }

            if (debug == .off) return;

            self.cache_history[self.cache_history_i % self.cache_history.len] = .{
                .full = damage.full,
                .bands = @intCast(damage.n),
                .first_top = if (damage.n > 0) damage.bands[0].top else 0,
                .last_bottom = if (damage.n > 0) damage.bands[damage.n - 1].bottom else 0,
                .volatile_now = self.cache_note_volatile[0],
                .volatile_before = self.cache_note_volatile[1],
                .scroll_off = self.uniforms.scroll_anim[0],
                .live = live,
                .final_full = final_full,
                .final_n = @intCast(final_n),
                .uniforms_same = uniforms_same,
            };
            self.cache_history_i += 1;

            // Stats, and the uncached frame to compare against.
            const st = &self.cache_stats;
            st.frames += 1;
            if (damage.full) st.cells_full += 1 else if (damage.n > 0) st.cells_part += 1 else st.cells_none += 1;
            if (final_full) st.final_full += 1 else if (final_n > 0) st.final_part += 1 else st.final_none += 1;
            if (final_full) {
                st.final_share += 1;
            } else {
                var fpx: u64 = 0;
                for (final_rects[0..final_n]) |r| fpx += @as(u64, r.?[2]) * r.?[3];
                st.final_share += @min(1.0, @as(f64, @floatFromInt(fpx)) /
                    @as(f64, @floatFromInt(@max(@as(u64, width) * height, 1))));
            }
            {
                var px: u64 = 0;
                for (bands) |b| px += b.bottom - b.top;
                st.share += @as(f64, @floatFromInt(px)) / @as(f64, @floatFromInt(@max(height, 1)));
            }

            if (debug == .verify) verify: {
                {
                    var pass = frame_ctx.renderPass(&.{.{
                        .target = .{ .texture = state.verify[0].? },
                        .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                    }});
                    defer pass.complete();
                    self.drawCellSteps(&pass, frame, fg_count);
                }
                for (pipelines, 0..) |pipeline, i| {
                    var pass = frame_ctx.renderPass(&.{.{
                        .target = if (i < n - 1)
                            .{ .texture = state.verify[i + 1].? }
                        else
                            .{ .target = state.verify_target.? },
                        .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                    }});
                    defer pass.complete();
                    pass.step(.{
                        .pipeline = pipeline,
                        .uniforms = state.uniforms.buffer,
                        .textures = &.{state.verify[i].?},
                        .samplers = &.{state.sampler},
                        .draw = .{ .type = .triangle, .vertex_count = 3 },
                    });
                }
                const bytes: usize = @as(usize, width) * height * 4;
                self.cache_verify_buf.resize(self.alloc, bytes * 2) catch break :verify;
                const got = self.cache_verify_buf.items[0..bytes];
                const want = self.cache_verify_buf.items[bytes..];
                self.api.readTarget(frame.target, got) catch break :verify;
                self.api.readTarget(state.verify_target.?, want) catch break :verify;
                st.verified += 1;
                if (std.mem.eql(u8, got, want)) break :verify;
                st.mismatched += 1;
                // Which rows of the window differ (readback is bottom-up).
                var first: ?u32 = null;
                var last_row: u32 = 0;
                var diff_px: u64 = 0;
                var max_delta: u32 = 0;
                const stride: usize = @as(usize, width) * 4;
                for (0..height) |gy| {
                    const a = got[gy * stride ..][0..stride];
                    const b = want[gy * stride ..][0..stride];
                    if (std.mem.eql(u8, a, b)) continue;
                    const from_top: u32 = height - 1 - @as(u32, @intCast(gy));
                    if (first == null or from_top < first.?) first = from_top;
                    last_row = @max(last_row, from_top);
                    var x: usize = 0;
                    while (x < stride) : (x += 4) {
                        var differs = false;
                        for (0..4) |c| {
                            const dlt = @abs(@as(i32, a[x + c]) - @as(i32, b[x + c]));
                            if (dlt > 0) differs = true;
                            max_delta = @max(max_delta, dlt);
                        }
                        if (differs) diff_px += 1;
                    }
                }
                log.warn(
                    "shader-cache MISMATCH px={} max_delta={} rows_px={}..{} (cell rows {}..{}) damage full={} bands={} final_full={} live={}",
                    .{
                        diff_px,                                                                      max_delta,
                        first orelse 0,                                                               last_row,
                        ((first orelse 0) -| self.size.padding.top) / @max(self.size.cell.height, 1), (last_row -| self.size.padding.top) / @max(self.size.cell.height, 1),
                        damage.full,                                                                  damage.n,
                        final_full,                                                                   live,
                    },
                );
                for (damage.bands[0..damage.n]) |b| log.warn("  band px {}..{}", .{ b.top, b.bottom });
                {
                    // Where across, and what the last shader was given.
                    var min_x: usize = width;
                    var max_x: usize = 0;
                    for (0..height) |gy| {
                        const ra = got[gy * stride ..][0..stride];
                        const rb = want[gy * stride ..][0..stride];
                        if (std.mem.eql(u8, ra, rb)) continue;
                        var x: usize = 0;
                        while (x < stride) : (x += 4) {
                            if (!std.mem.eql(u8, ra[x..][0..4], rb[x..][0..4])) {
                                min_x = @min(min_x, x / 4);
                                max_x = @max(max_x, x / 4);
                            }
                        }
                    }
                    for (0..self.cache_history.len) |back| {
                        if (back >= self.cache_history_i) break;
                        const h = self.cache_history[(self.cache_history_i - 1 - back) % self.cache_history.len];
                        log.warn("  frame -{}: full={} bands={} px {}..{} vol={}/{} scroll_off={d:.1} live={} final_full={} final_n={} uni_same={}", .{
                            back,           h.full,            h.bands,      h.first_top, h.last_bottom,
                            h.volatile_now, h.volatile_before, h.scroll_off, h.live,      h.final_full,
                            h.final_n,      h.uniforms_same,
                        });
                    }
                    if (max_x >= min_x and first != null) {
                        const gy: usize = height - 1 - first.?;
                        const o = gy * stride + min_x * 4;
                        log.warn("  first px got={any} want={any} cursor_uniform={any} cursor_glyph_row={any}", .{
                            got[o..][0..4].*,         want[o..][0..4].*,
                            self.uniforms.cursor_pos, if (self.cells.getCursorGlyph()) |c| c.grid_pos else null,
                        });
                    }
                    const u = &self.custom_shader_uniforms;
                    log.warn("  cols_px {}..{} box_now={any} box_prev={any} t={d:.3} move_t={d:.3} cur={any} from={any} to={any}", .{
                        min_x,            max_x,              box_now,          box_prev,
                        u.time,           u.time_cursor_move, u.current_cursor, u.cursor_move_from,
                        u.cursor_move_to,
                    });
                }
            }

            const now: std.Io.Timestamp = .now(global.io(), .awake);
            const since = st.since orelse {
                st.since = now;
                return;
            };
            const ms = @divTrunc(since.durationTo(now).nanoseconds, std.time.ns_per_ms);
            if (ms < 2000) return;
            log.info(
                "shader-cache {}ms frames={} chain none/part/full={}/{}/{} final none/part/full={}/{}/{} mean_share={d:.3} final_share={d:.3} verified={} mismatched={}",
                .{
                    ms,                                            st.frames,
                    st.cells_none,                                 st.cells_part,
                    st.cells_full,                                 st.final_none,
                    st.final_part,                                 st.final_full,
                    st.share / @as(f64, @floatFromInt(st.frames)), st.final_share / @as(f64, @floatFromInt(st.frames)),
                    st.verified,                                   st.mismatched,
                },
            );
            st.* = .{ .since = now };
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

            // A frame that went wrong leaves its slot holding who knows what.
            if (health != .healthy) if (self.swap_chain) |*sc| {
                sc.frames[sc.frame_index].cache_seq = 0;
            };

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

            // custom-shader-cache: anything may look different now.
            self.cache_damage_full = true;
            self.cache_final_settled = false;
            self.cache_fx_box = null;

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

            self.size = size;
            self.updateScreenSizeUniforms();

            // Some graphics APIs need to manually update their viewport,
            // like OpenGL. Do so here.
            if (@hasDecl(GraphicsAPI, "setViewport")) {
                self.api.setViewport(self.size.screen.width, self.size.screen.height);
            }

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
            self.uniforms.projection_matrix = @bitCast(math.ortho2d(
                -1 * @as(f32, @floatFromInt(self.size.padding.left)),
                @floatFromInt(terminal_size.width + self.size.padding.right),
                @floatFromInt(terminal_size.height + self.size.padding.bottom),
                -1 * @as(f32, @floatFromInt(self.size.padding.top)),
            ));
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
            uniforms.current_cursor_style = @as(i32, @backingInt(cursor_style));
        }

        /// Record a mode change (kind 0), pulse (kind 1) or boom (kind 2,
        /// `arg` = its power) in the uniforms' event ring, overwriting the
        /// oldest, so effects stack.
        fn pushCursorFxEvent(
            self: *Self,
            kind: f32,
            arg: f32,
            style: i32,
            color: [4]f32,
            rect: [4]f32,
        ) void {
            const uniforms: *shadertoy.Uniforms = &self.custom_shader_uniforms;
            const i = self.cursor_fx_next;
            uniforms.cursor_fx_event[i] = .{ uniforms.time, @floatFromInt(style), kind, arg };
            uniforms.cursor_fx_event_color[i] = color;
            uniforms.cursor_fx_event_rect[i] = rect;
            self.cursor_fx_next = (i + 1) % shadertoy.cursor_fx_events;
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
                    // Or the wheel is turning: between an application's
                    // scroll batches the animation can be idle, and with
                    // `scroll-animation-wheel-snap` it never runs at all, so
                    // a flick smeared the cursor all over the screen
                    // (2026-10-14).
                    const wheel_recent = if (self.wheel_ts) |t|
                        t.durationTo(now).nanoseconds <= wheel_repaint_ms * std.time.ns_per_ms
                    else
                        false;
                    const riding = self.scroll_anim.active() or wheel_recent;
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
                    self.pushCursorFxEvent(0, 0, style, color, rect);
                    if (self.config.scroll_trace) log.info(
                        "cursorfx mode style {}->{} color {d:.3}->{d:.3} t={d:.3}",
                        .{ old.style, style, old.color[0], color[0], uniforms.time },
                    );
                }
            }
            self.cursor_fx_mode = .{ .style = style, .color = color };
        }

        /// A cell as a cell-sized rect in the cursor uniforms' convention
        /// (left, +Y edge, w, h): where booms and cursor-targets play.
        fn cellFxRect(self: *const Self, col: u16, row: u16) [4]f32 {
            const cell = self.size.cell;
            const padding = self.size.padding;
            const x: f32 = @floatFromInt(@as(u32, col) * cell.width + padding.left);
            var y: f32 = @floatFromInt(@as(u32, row) * cell.height + padding.top);
            if (GraphicsAPI.custom_shader_y_is_down) {
                y += @floatFromInt(cell.height);
            } else {
                y = @as(f32, @floatFromInt(self.size.screen.height)) - y;
            }
            return .{ x, y, @floatFromInt(cell.width), @floatFromInt(cell.height) };
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
                // A drawn cursor retires every target sent so far.
                self.cursor_fx_target_used = self.cursor_fx_target_seq;
            } else if (self.cursor_fx_target) |cell_pos| {
                // No cursor drawn (an app hid it): effects go to the target
                // the app's tmux side reported, as a cell-sized block in
                // the cursor's rect convention, so the smear flies there
                // and pulses / booms without a cell play there.
                if (self.cursor_fx_target_seq != self.cursor_fx_target_used) {
                    const rect = self.cellFxRect(cell_pos[0], cell_pos[1]);
                    self.updateCursorFx(cell_pos, rect, uniforms.current_cursor_color, now);
                }
            }

            if (self.cursor_fx_pulse_pending) {
                self.cursor_fx_pulse_pending = false;
                uniforms.time_cursor_pulse = uniforms.time;
                self.pushCursorFxEvent(
                    1,
                    0,
                    uniforms.current_cursor_style,
                    uniforms.current_cursor_color,
                    uniforms.cursor_move_to,
                );
            }

            if (self.cursor_fx_boom_pending) |boom| {
                self.cursor_fx_boom_pending = null;
                // At the named cell, as a cell-sized rect in the same
                // convention as the cursor's (left, +Y edge, w, h); else at
                // the cursor.
                // cursor_move_to is the cursor, or the cursor-target
                // while the cursor is hidden.
                const rect: [4]f32 = if (boom.col != null and boom.row != null)
                    self.cellFxRect(boom.col.?, boom.row.?)
                else
                    uniforms.cursor_move_to;
                self.pushCursorFxEvent(
                    2,
                    @floatFromInt(@max(boom.power, 1)),
                    uniforms.current_cursor_style,
                    uniforms.current_cursor_color,
                    rect,
                );
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

            // custom-shader-cache: note what is about to change.
            if (self.cache_damage_rows.items.len != state.rows) {
                try self.cache_damage_rows.resize(self.alloc, state.rows);
                @memset(self.cache_damage_rows.items, false);
                self.cache_damage_full = true;
            }
            if (rebuild) self.cache_damage_full = true;
            {
                const has_links = links.count() > 0;
                if (has_links or self.cache_had_links) self.cache_damage_full = true;
                self.cache_had_links = has_links;
            }

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
                self.cache_damage_rows.items[y] = true;

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
                            const tag: HighlightTag = @fromBackingInt(hl.tag);
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
                @backingInt(sprite),
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
                @backingInt(font.Sprite.overline),
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
                @backingInt(font.Sprite.strikethrough),
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
                        @backingInt(sprite),
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
                .{
                    .grid_metrics = self.grid_metrics,
                    .thicken = self.config.font_thicken,
                    .thicken_strength = self.config.font_thicken_strength,
                },
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
