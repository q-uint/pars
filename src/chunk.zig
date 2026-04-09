const std = @import("std");
const Value = @import("value.zig").Value;

pub const OpCode = enum(u8) {
    op_constant,
    op_return,
};

// Run-length encoded line number entry. Each entry covers `count`
// consecutive bytecode bytes, all from the same source `line`.
pub const LineRun = struct {
    line: usize,
    count: usize,
};

pub const Chunk = struct {
    code: std.ArrayList(u8),
    // Run-length encoded line info. Instead of one entry per bytecode
    // byte, consecutive bytes from the same source line share a single
    // LineRun. getLine() walks the runs to resolve a bytecode offset
    // to a source line -- acceptable because it only runs on errors.
    lines: std.ArrayList(LineRun),
    constants: std.ArrayList(Value),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Chunk {
        return .{
            .code = .empty,
            .lines = .empty,
            .constants = .empty,
            .allocator = allocator,
        };
    }

    pub fn write(self: *Chunk, byte: u8, line: usize) !void {
        try self.code.append(self.allocator, byte);
        if (self.lines.items.len > 0 and
            self.lines.items[self.lines.items.len - 1].line == line)
        {
            // Same line as previous byte, extend the current run.
            self.lines.items[self.lines.items.len - 1].count += 1;
        } else {
            // New source line, start a new run.
            try self.lines.append(self.allocator, .{ .line = line, .count = 1 });
        }
    }

    pub fn getLine(self: *const Chunk, offset: usize) usize {
        var remaining = offset;
        for (self.lines.items) |run| {
            if (remaining < run.count) return run.line;
            remaining -= run.count;
        }
        unreachable;
    }

    pub fn addConstant(self: *Chunk, val: Value) !usize {
        try self.constants.append(self.allocator, val);
        return self.constants.items.len - 1;
    }

    pub fn deinit(self: *Chunk) void {
        self.code.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.constants.deinit(self.allocator);
    }
};
