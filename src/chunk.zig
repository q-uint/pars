const std = @import("std");
const Value = @import("value.zig").Value;

pub const OpCode = enum(u8) {
    op_constant, // 2 bytes: opcode + 1-byte index
    // 4 bytes: opcode + 3-byte (24-bit) index. Trades dispatch
    // complexity (two code paths everywhere constants are handled)
    // for compact encoding in the common case.
    op_constant_wide,
    op_return, // 1 byte
};

// Run-length encoded (RLE) line number entry. Each entry covers
// `count` consecutive bytecode bytes, all from the same source `line`.
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

    // Adds a constant and emits the appropriate load instruction.
    // Uses op_constant (2 bytes) when the index fits in a u8,
    // otherwise op_constant_wide (4 bytes) with a 24-bit index.
    pub fn writeConstant(self: *Chunk, val: Value, line: usize) !void {
        const index = try self.addConstant(val);
        if (index <= std.math.maxInt(u8)) {
            try self.write(@intFromEnum(OpCode.op_constant), line);
            try self.write(@intCast(index), line);
        } else {
            try self.write(@intFromEnum(OpCode.op_constant_wide), line);
            try self.write(@intCast(index & 0xff), line);
            try self.write(@intCast((index >> 8) & 0xff), line);
            try self.write(@intCast((index >> 16) & 0xff), line);
        }
    }

    pub fn deinit(self: *Chunk) void {
        self.code.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.constants.deinit(self.allocator);
    }
};

test "getLine resolves offsets across multiple runs" {
    var c = Chunk.init(std.testing.allocator);
    defer c.deinit();

    // 3 bytes on line 1, 2 bytes on line 2, 1 byte on line 3
    try c.write(0, 1);
    try c.write(0, 1);
    try c.write(0, 1);
    try c.write(0, 2);
    try c.write(0, 2);
    try c.write(0, 3);

    try std.testing.expectEqual(1, c.getLine(0));
    try std.testing.expectEqual(1, c.getLine(2));
    try std.testing.expectEqual(2, c.getLine(3));
    try std.testing.expectEqual(2, c.getLine(4));
    try std.testing.expectEqual(3, c.getLine(5));

    // Only 3 runs stored, not 6 entries.
    try std.testing.expectEqual(3, c.lines.items.len);
}

test "writeConstant emits op_constant_wide after 256 constants" {
    var c = Chunk.init(std.testing.allocator);
    defer c.deinit();

    // Fill up the first 256 constant slots.
    for (0..256) |_| {
        try c.writeConstant("x", 1);
    }

    // The 257th should use op_constant_wide.
    const code_len_before = c.code.items.len;
    try c.writeConstant("wide", 2);

    // op_constant_wide is 4 bytes: opcode + 3-byte index.
    try std.testing.expectEqual(code_len_before + 4, c.code.items.len);
    try std.testing.expectEqual(
        @intFromEnum(OpCode.op_constant_wide),
        c.code.items[code_len_before],
    );

    // Index 256 = 0x100: low byte 0x00, middle byte 0x01, high byte 0x00.
    try std.testing.expectEqual(0x00, c.code.items[code_len_before + 1]);
    try std.testing.expectEqual(0x01, c.code.items[code_len_before + 2]);
    try std.testing.expectEqual(0x00, c.code.items[code_len_before + 3]);
}
