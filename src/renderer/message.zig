const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const configpkg = @import("../config.zig");
const font = @import("../font/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");

/// The messages that can be sent to a renderer thread.
pub const Message = union(enum) {
    /// `input_activity` for a key that typed text or deleted it.
    pub const input_typed: i8 = 3;

    /// Purposely crash the renderer. This is used for testing and debugging.
    /// See the "crash" binding action.
    crash,

    /// A change in state in the window focus that this renderer is
    /// rendering within. This is only sent when a change is detected so
    /// the renderer is expected to handle all of these.
    focus: bool,

    /// A change in the view occlusion state. This can be used to determine
    /// if the window is visible or not. A window can be not visible (occluded)
    /// and still have focus.
    visible: bool,

    /// Reset the cursor blink by immediately showing the cursor then
    /// restarting the timer.
    reset_cursor_blink,

    /// A key was pressed that produced input for the program.
    ///
    /// The repaint-scroll detector only trusts a shift it can attribute to
    /// the user, and a keyboard is the other way they scroll: `j`/`k` held
    /// down in vim or in a pager moves the screen exactly as a wheel does,
    /// but reaches none of the scroll plumbing. Without this the detector is
    /// blind to every keyboard-driven scroll.
    ///
    /// The value is 0 for a key. For the wheel or touchpad it is the
    /// direction: +1 when the content should move up (towards later output),
    /// -1 for down. The detector uses it for applications that answer the
    /// wheel by redrawing (Claude Code): a recovered shift has to go the way
    /// the wheel went, and a flick of several notches may move further than a
    /// key ever does. (One message, not a second one beside it: a wheel sends
    /// these at 160 a second.) +2/-2: the same, with the wheel turning
    /// faster than `scroll-animation-wheel-snap`. `input_typed`: a key that
    /// typed text (see `Renderer.noteInputActivity`).
    input_activity: i8,

    /// Change the font grid. This can happen for any number of reasons
    /// including a font size change, family change, etc.
    font_grid: struct {
        grid: *font.SharedGrid,
        set: *font.SharedGridSet,

        // The key for the new grid. If adopting the new grid fails for any
        // reason, the old grid should be kept but the new key should be
        // dereferenced.
        new_key: font.SharedGridSet.Key,

        // After accepting the new grid, the old grid must be dereferenced
        // using the fields below.
        old_key: font.SharedGridSet.Key,
    },

    /// Changes the size. The screen size might change, padding, grid, etc.
    resize: renderer.Size,

    /// The derived configuration to update the renderer with.
    change_config: struct {
        alloc: Allocator,
        thread: *renderer.Thread.DerivedConfig,
        impl: *renderer.Renderer.DerivedConfig,
    },

    /// Matches for the current viewport from the search thread. These happen
    /// async so they may be off for a frame or two from the actually rendered
    /// viewport. The renderer must handle this gracefully.
    search_viewport_matches: SearchMatches,

    /// The selected match from the search thread. May be null to indicate
    /// no match currently.
    search_selected_match: ?SearchMatch,

    /// Activate or deactivate the inspector.
    inspector: bool,

    /// The macOS display ID has changed for the window.
    macos_display_id: u32,

    /// Updates the health of the current presentation state.
    ///
    /// If unhealthy, then somehow the apprt failed to present frames from
    /// the renderer. On GTK, this can be caused by failing to import a DMABUF.
    presentation_health: renderer.Health,

    pub const SearchMatches = struct {
        arena: ArenaAllocator,
        matches: []const terminal.highlight.Flattened,
    };

    pub const SearchMatch = struct {
        arena: ArenaAllocator,
        match: terminal.highlight.Flattened,
    };

    /// Initialize a change_config message.
    pub fn initChangeConfig(alloc: Allocator, config: *const configpkg.Config) !Message {
        const thread_ptr = try alloc.create(renderer.Thread.DerivedConfig);
        errdefer alloc.destroy(thread_ptr);
        const config_ptr = try alloc.create(renderer.Renderer.DerivedConfig);
        errdefer alloc.destroy(config_ptr);

        thread_ptr.* = renderer.Thread.DerivedConfig.init(config);
        config_ptr.* = try renderer.Renderer.DerivedConfig.init(alloc, config);
        errdefer config_ptr.deinit();

        return .{
            .change_config = .{
                .alloc = alloc,
                .thread = thread_ptr,
                .impl = config_ptr,
            },
        };
    }

    pub fn deinit(self: *const Message) void {
        switch (self.*) {
            .change_config => |v| {
                v.impl.deinit();
                v.alloc.destroy(v.impl);
                v.alloc.destroy(v.thread);
            },

            else => {},
        }
    }
};
