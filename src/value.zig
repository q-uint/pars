const std = @import("std");
const object = @import("object.zig");
const Obj = object.Obj;

/// A span into the input: the start position and length of a successful match.
pub const Span = struct {
    start: usize,
    len: usize,
};

/// Runtime value on the VM stack. Represents the result of a match operation.
/// `none` is the falsy value: a match that failed or was never attempted.
/// `obj` holds a pointer to a heap-allocated object (literal, charset, etc.).
pub const Value = union(enum) {
    span: Span,
    obj: *Obj,
    none,

    pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .none => b == .none,
            .span => |sa| switch (b) {
                .span => |sb| sa.start == sb.start and sa.len == sb.len,
                else => false,
            },
            .obj => |oa| switch (b) {
                .obj => |ob| object.objEql(oa, ob),
                else => false,
            },
        };
    }

    pub fn isObj(self: Value) bool {
        return self == .obj;
    }

    pub fn asObj(self: Value) *Obj {
        return self.obj;
    }
};

pub fn printValue(val: Value) void {
    switch (val) {
        .span => |s| std.debug.print("span({d}, {d})", .{ s.start, s.len }),
        .obj => |o| object.printObject(o),
        .none => std.debug.print("none", .{}),
    }
}
