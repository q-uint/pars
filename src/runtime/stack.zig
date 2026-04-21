const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;

/// Fixed-size stack backed by an array. Fast and cache-friendly, but
/// will panic on overflow if the program exceeds the limit.
pub fn FixedStack(comptime size: comptime_int) type {
    return struct {
        const Self = @This();

        buf: [size]Value,
        top: usize,

        pub fn init(_: std.mem.Allocator) Self {
            return .{ .buf = undefined, .top = 0 };
        }

        pub fn push(self: *Self, val: Value) !void {
            if (self.top >= size) return error.StackOverflow;
            self.buf[self.top] = val;
            self.top += 1;
        }

        pub fn pop(self: *Self) Value {
            self.top -= 1;
            return self.buf[self.top];
        }

        pub fn slice(self: *Self) []const Value {
            return self.buf[0..self.top];
        }

        pub fn deinit(_: *Self) void {}
    };
}

/// Dynamic stack backed by an ArrayList. Grows as needed so it never
/// overflows, at the cost of heap allocation and possible realloc on
/// push. Cache locality may be worse than a fixed array since the
/// backing memory is heap-allocated and can move on resize.
pub const DynamicStack = struct {
    items: std.ArrayList(Value),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DynamicStack {
        return .{ .items = .empty, .allocator = allocator };
    }

    pub fn push(self: *DynamicStack, val: Value) !void {
        try self.items.append(self.allocator, val);
    }

    pub fn pop(self: *DynamicStack) Value {
        return self.items.pop().?;
    }

    pub fn slice(self: *DynamicStack) []const Value {
        return self.items.items;
    }

    pub fn deinit(self: *DynamicStack) void {
        self.items.deinit(self.allocator);
    }
};
