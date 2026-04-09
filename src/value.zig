const std = @import("std");

pub const Value = []const u8;

pub fn printValue(val: Value) void {
    std.debug.print("{s}", .{val});
}
