const std = @import("std");

/// Element type of a chunk's constant pool: an interned byte sequence used
/// as the target of a literal match (e.g. `"HTTP/"`, `'a'`). Not a match
/// result. Successful matches leave nothing on the value stack; failure
/// unwinds to a backtrack frame. See ADR 006.
pub const Value = []const u8;

pub fn printValue(val: Value) void {
    std.debug.print("{s}", .{val});
}
