const std = @import("std");

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

const log = std.log.scoped(.osc_rxvt_extension);

/// Parse OSC 777
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };
    // ensure that we are sentinel terminated
    cap.writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    // `cursor-pulse` takes no arguments, so it may have no `;` at all.
    // data ends in the NUL written above.
    if (std.mem.eql(u8, std.mem.sliceTo(data, ';'), "cursor-pulse\x00") or
        std.mem.startsWith(u8, data, "cursor-pulse;"))
    {
        parser.command = .cursor_pulse;
        return &parser.command;
    }
    if (std.mem.eql(u8, std.mem.sliceTo(data, ';'), "cursor-boom\x00") or
        std.mem.startsWith(u8, data, "cursor-boom;"))
    {
        // Optional `;power;col;row`; anything unparsable is just left out.
        var boom: Command.CursorBoom = .{};
        var it = std.mem.splitScalar(u8, data[0 .. data.len - 1], ';');
        _ = it.next();
        if (it.next()) |s| boom.power = std.fmt.parseInt(u8, s, 10) catch 1;
        const col = if (it.next()) |s| std.fmt.parseInt(u16, s, 10) catch null else null;
        const row = if (it.next()) |s| std.fmt.parseInt(u16, s, 10) catch null else null;
        if (col != null and row != null) {
            boom.col = col;
            boom.row = row;
        }
        parser.command = .{ .cursor_boom = boom };
        return &parser.command;
    }
    const k = std.mem.indexOfScalar(u8, data, ';') orelse {
        parser.state = .invalid;
        return null;
    };
    const ext = data[0..k];
    if (!std.mem.eql(u8, ext, "notify")) {
        log.warn("unknown rxvt extension: {s}", .{ext});
        parser.state = .invalid;
        return null;
    }
    const t = std.mem.indexOfScalarPos(u8, data, k + 1, ';') orelse {
        log.warn("rxvt notify extension is missing the title", .{});
        parser.state = .invalid;
        return null;
    };
    data[t] = 0;
    const title = data[k + 1 .. t :0];
    const body = data[t + 1 .. data.len - 1 :0];
    parser.command = .{
        .show_desktop_notification = .{
            .title = title,
            .body = body,
        },
    };
    return &parser.command;
}

test "OSC: OSC 777 show desktop notification with title" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "777;notify;Title;Body";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings(cmd.show_desktop_notification.title, "Title");
    try testing.expectEqualStrings(cmd.show_desktop_notification.body, "Body");
}

test "OSC: OSC 777 cursor pulse" {
    const testing = std.testing;

    for ([_][]const u8{ "777;cursor-pulse", "777;cursor-pulse;" }) |input| {
        var p: Parser = .init(null);
        for (input) |ch| p.next(ch);
        const cmd = p.end('\x07').?.*;
        try testing.expect(cmd == .cursor_pulse);
    }
}

test "OSC: OSC 777 cursor boom" {
    const testing = std.testing;

    const Case = struct { in: []const u8, power: u8, col: ?u16, row: ?u16 };
    for ([_]Case{
        .{ .in = "777;cursor-boom", .power = 1, .col = null, .row = null },
        .{ .in = "777;cursor-boom;2", .power = 2, .col = null, .row = null },
        .{ .in = "777;cursor-boom;2;10;5", .power = 2, .col = 10, .row = 5 },
        .{ .in = "777;cursor-boom;x;10", .power = 1, .col = null, .row = null },
    }) |c| {
        var p: Parser = .init(null);
        for (c.in) |ch| p.next(ch);
        const cmd = p.end('\x07').?.*;
        try testing.expect(cmd == .cursor_boom);
        try testing.expectEqual(c.power, cmd.cursor_boom.power);
        try testing.expectEqual(c.col, cmd.cursor_boom.col);
        try testing.expectEqual(c.row, cmd.cursor_boom.row);
    }
}
