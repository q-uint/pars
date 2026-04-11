const std = @import("std");
const chunk = @import("chunk.zig");
const OpCode = chunk.OpCode;
const Chunk = chunk.Chunk;
const printValue = @import("value.zig").printValue;

pub fn disassembleChunk(c: *Chunk, name: []const u8) void {
    std.debug.print("== {s} ==\n", .{name});

    var offset: usize = 0;
    while (offset < c.code.items.len) {
        offset = disassembleInstruction(c, offset);
    }
}

pub fn disassembleInstruction(c: *Chunk, offset: usize) usize {
    std.debug.print("{d:0>4} ", .{offset});

    const line = c.getLine(offset);
    if (offset > 0 and line == c.getLine(offset - 1)) {
        // Same source line as the previous instruction.
        std.debug.print("   | ", .{});
    } else {
        // First instruction on a new source line.
        std.debug.print("{d:>4} ", .{line});
    }

    const instruction = c.code.items[offset];
    const op = std.meta.intToEnum(OpCode, instruction) catch {
        std.debug.print("Unknown opcode {d}\n", .{instruction});
        return offset + 1;
    };

    return switch (op) {
        .op_constant => constantInstruction("OP_CONSTANT", c, offset),
        .op_constant_wide => constantWideInstruction("OP_CONSTANT_WIDE", c, offset),
        .op_halt => simpleInstruction("OP_HALT", offset),
    };
}

fn constantInstruction(name: []const u8, c: *Chunk, offset: usize) usize {
    const constant = c.code.items[offset + 1];
    std.debug.print("{s:<16} {d:>4} '", .{ name, constant });
    printValue(c.constants.items[constant]);
    std.debug.print("'\n", .{});
    return offset + 2;
}

fn constantWideInstruction(name: []const u8, c: *Chunk, offset: usize) usize {
    const constant: usize = @as(usize, c.code.items[offset + 1]) |
        (@as(usize, c.code.items[offset + 2]) << 8) |
        (@as(usize, c.code.items[offset + 3]) << 16);
    std.debug.print("{s:<16} {d:>4} '", .{ name, constant });
    printValue(c.constants.items[constant]);
    std.debug.print("'\n", .{});
    return offset + 4;
}

fn simpleInstruction(name: []const u8, offset: usize) usize {
    std.debug.print("{s}\n", .{name});
    return offset + 1;
}
