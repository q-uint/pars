const std = @import("std");

/// A span into the input: the start position and length of a successful match.
pub const Span = struct {
    start: usize,
    len: usize,
};

/// Runtime value on the VM stack. Represents the result of a match operation.
/// `none` is the falsy value: a match that failed or was never attempted.
pub const Value = union(enum) {
    span: Span,
    none,

pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .none => b == .none,
            .span => |sa| switch (b) {
                .span => |sb| sa.start == sb.start and sa.len == sb.len,
                else => false,
            },
        };
    }
};

pub fn printValue(val: Value) void {
    switch (val) {
        .span => |s| std.debug.print("span({d}, {d})", .{ s.start, s.len }),
        .none => std.debug.print("none", .{}),
    }
}

/// Print a constant pool entry (a byte slice literal).
pub fn printConstant(val: []const u8) void {
    std.debug.print("{s}", .{val});
}
