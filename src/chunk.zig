const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;

pub const OpCode = enum(u8) {
    // Match a single byte from the input against an inline byte operand.
    // 2 bytes: opcode + byte.
    op_match_char,
    // Match any single byte. 1 byte.
    op_match_any,
    // Match a literal byte sequence held in the constant pool.
    // Narrow form: 2 bytes (opcode + 1-byte index).
    // Wide form:   4 bytes (opcode + 3-byte (24-bit) index).
    op_match_string,
    op_match_string_wide,
    // Case-insensitive variant of op_match_string. Compares ASCII letters
    // without regard to case; other bytes compare exactly.
    op_match_string_i,
    op_match_string_i_wide,
    // Match a single byte against a charset (256-bit bitvector) in the
    // constant pool. Succeeds and advances by one byte when the byte at
    // the current position is a member of the set.
    op_match_charset,
    op_match_charset_wide,
    // Call a named rule. The operand is a constant-pool index holding
    // the rule name (an ObjLiteral). At runtime the VM looks up the
    // name in its rule table and transfers control to the rule's chunk.
    op_call,
    op_call_wide,
    // Return from a rule body, restoring the caller's chunk and ip.
    op_return,
    // Push a backtrack frame saving the current input position and
    // the given forward jump target. If a match instruction fails
    // while this frame is on the stack, the VM restores the saved
    // position and jumps to the target (the start of the alternative).
    // 3 bytes: opcode + signed 16-bit offset.
    op_choice,
    // Pop the top backtrack frame (the preceding alternative succeeded)
    // and jump by the signed 16-bit offset. Used both for forward jumps
    // (past the alternative in ordered choice) and backward jumps
    // (looping in quantifiers).
    // 3 bytes: opcode + signed 16-bit offset.
    op_commit,
    // Explicitly trigger a match failure. If a backtrack frame exists,
    // restore state and continue; otherwise propagate .no_match.
    // 1 byte.
    op_fail,
    op_halt, // 1 byte
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

    // Emits a constant-pool load for the given op pair. Uses the narrow
    // form (1-byte index) when the index fits in a u8, otherwise the
    // wide form (24-bit index). Both forms share a single constant pool.
    pub fn emitOpConstant(
        self: *Chunk,
        op_narrow: OpCode,
        op_wide: OpCode,
        val: Value,
        line: usize,
    ) !void {
        const index = try self.addConstant(val);
        if (index <= std.math.maxInt(u8)) {
            try self.write(@intFromEnum(op_narrow), line);
            try self.write(@intCast(index), line);
        } else {
            try self.write(@intFromEnum(op_wide), line);
            try self.write(@intCast(index & 0xff), line);
            try self.write(@intCast((index >> 8) & 0xff), line);
            try self.write(@intCast((index >> 16) & 0xff), line);
        }
    }

    // Insert `count` zero bytes at `offset`, shifting existing code
    // to the right. The line-info run covering `offset` is extended
    // so that the new bytes inherit the same source line.
    pub fn insertBytesAt(self: *Chunk, offset: usize, count: usize) !void {
        const old_len = self.code.items.len;
        // Grow code array by `count` bytes.
        for (0..count) |_| try self.code.append(self.allocator, 0);
        // Shift existing bytes to the right.
        std.mem.copyBackwards(
            u8,
            self.code.items[offset + count .. old_len + count],
            self.code.items[offset..old_len],
        );
        // Zero the inserted gap.
        @memset(self.code.items[offset..][0..count], 0);
        // Extend the line-info run that covers the insertion point.
        var pos: usize = 0;
        for (self.lines.items) |*run| {
            if (pos + run.count > offset) {
                run.count += count;
                return;
            }
            pos += run.count;
        }
        if (self.lines.items.len > 0) {
            self.lines.items[self.lines.items.len - 1].count += count;
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

test "emitOpConstant switches to wide form after 256 constants" {
    const object = @import("object.zig");
    const alloc = std.testing.allocator;
    object.init(alloc);
    defer object.freeObjects();

    var c = Chunk.init(alloc);
    defer c.deinit();

    // Fill up the first 256 constant slots.
    for (0..256) |_| {
        const lit = try object.copyLiteral("x");
        try c.emitOpConstant(.op_match_string, .op_match_string_wide, .{ .obj = lit.asObj() }, 1);
    }

    // The 257th should use the wide form.
    const code_len_before = c.code.items.len;
    const lit = try object.copyLiteral("wide");
    try c.emitOpConstant(.op_match_string, .op_match_string_wide, .{ .obj = lit.asObj() }, 2);

    // Wide form is 4 bytes: opcode + 3-byte index.
    try std.testing.expectEqual(code_len_before + 4, c.code.items.len);
    try std.testing.expectEqual(
        @intFromEnum(OpCode.op_match_string_wide),
        c.code.items[code_len_before],
    );

    // Index 256 = 0x100: low byte 0x00, middle byte 0x01, high byte 0x00.
    try std.testing.expectEqual(0x00, c.code.items[code_len_before + 1]);
    try std.testing.expectEqual(0x01, c.code.items[code_len_before + 2]);
    try std.testing.expectEqual(0x00, c.code.items[code_len_before + 3]);
}
