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

    if (offset > 0 and c.lines.items[offset] == c.lines.items[offset - 1]) {
        std.debug.print("   | ", .{});
    } else {
        std.debug.print("{d:>4} ", .{c.lines.items[offset]});
    }

    const instruction = c.code.items[offset];
    const op = std.meta.intToEnum(OpCode, instruction) catch {
        std.debug.print("Unknown opcode {d}\n", .{instruction});
        return offset + 1;
    };

    return switch (op) {
        .op_constant => constantInstruction("OP_CONSTANT", c, offset),
        .op_return => simpleInstruction("OP_RETURN", offset),
    };
}

fn constantInstruction(name: []const u8, c: *Chunk, offset: usize) usize {
    const constant = c.code.items[offset + 1];
    std.debug.print("{s:<16} {d:>4} '", .{ name, constant });
    printValue(c.constants.items[constant]);
    std.debug.print("'\n", .{});
    return offset + 2;
}

fn simpleInstruction(name: []const u8, offset: usize) usize {
    std.debug.print("{s}\n", .{name});
    return offset + 1;
}
