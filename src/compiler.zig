const std = @import("std");
const scanner = @import("scanner.zig");

pub fn compile(source: []const u8) void {
    scanner.init(source);

    var line: isize = -1;
    while (true) {
        const token = scanner.scanToken();
        const token_line: isize = @intCast(token.line);
        if (token_line != line) {
            std.debug.print("{d:>4} ", .{token.line});
            line = token_line;
        } else {
            std.debug.print("   | ", .{});
        }
        std.debug.print("{d:>2} '{s}'\n", .{ @intFromEnum(token.type), token.lexeme });
        if (token.type == .eof) break;
    }
}
