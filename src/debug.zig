const std = @import("std");
const chunk = @import("chunk.zig");
const OpCode = chunk.OpCode;
const Chunk = chunk.Chunk;
const value_mod = @import("value.zig");
const printValue = value_mod.printValue;

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
        .op_match_char => byteInstruction("OP_MATCH_CHAR", c, offset),
        .op_match_any => simpleInstruction("OP_MATCH_ANY", offset),
        .op_match_string => constantInstruction("OP_MATCH_STRING", c, offset),
        .op_match_string_wide => constantWideInstruction("OP_MATCH_STRING_WIDE", c, offset),
        .op_match_string_i => constantInstruction("OP_MATCH_STRING_I", c, offset),
        .op_match_string_i_wide => constantWideInstruction("OP_MATCH_STRING_I_WIDE", c, offset),
        .op_match_charset => constantInstruction("OP_MATCH_CHARSET", c, offset),
        .op_match_charset_wide => constantWideInstruction("OP_MATCH_CHARSET_WIDE", c, offset),
        .op_call => indexInstruction("OP_CALL", c, offset),
        .op_call_wide => indexWideInstruction("OP_CALL_WIDE", c, offset),
        .op_return => simpleInstruction("OP_RETURN", offset),
        .op_choice => jumpInstruction("OP_CHOICE", c, offset),
        .op_commit => jumpInstruction("OP_COMMIT", c, offset),
        .op_fail => simpleInstruction("OP_FAIL", offset),
        .op_capture_begin => indexInstruction("OP_CAPTURE_BEGIN", c, offset),
        .op_capture_end => indexInstruction("OP_CAPTURE_END", c, offset),
        .op_match_backref => indexInstruction("OP_MATCH_BACKREF", c, offset),
        .op_halt => simpleInstruction("OP_HALT", offset),
    };
}

fn byteInstruction(name: []const u8, c: *Chunk, offset: usize) usize {
    const byte = c.code.items[offset + 1];
    std.debug.print("{s:<22} '{c}'\n", .{ name, byte });
    return offset + 2;
}

fn constantInstruction(name: []const u8, c: *Chunk, offset: usize) usize {
    const constant = c.code.items[offset + 1];
    std.debug.print("{s:<22} {d:>4} '", .{ name, constant });
    printValue(c.constants.items[constant]);
    std.debug.print("'\n", .{});
    return offset + 2;
}

fn constantWideInstruction(name: []const u8, c: *Chunk, offset: usize) usize {
    const constant: usize = @as(usize, c.code.items[offset + 1]) |
        (@as(usize, c.code.items[offset + 2]) << 8) |
        (@as(usize, c.code.items[offset + 3]) << 16);
    std.debug.print("{s:<22} {d:>4} '", .{ name, constant });
    printValue(c.constants.items[constant]);
    std.debug.print("'\n", .{});
    return offset + 4;
}

fn indexInstruction(name: []const u8, c: *Chunk, offset: usize) usize {
    const index = c.code.items[offset + 1];
    std.debug.print("{s:<22} {d}\n", .{ name, index });
    return offset + 2;
}

fn indexWideInstruction(name: []const u8, c: *Chunk, offset: usize) usize {
    const index: u32 = @as(u32, c.code.items[offset + 1]) |
        (@as(u32, c.code.items[offset + 2]) << 8) |
        (@as(u32, c.code.items[offset + 3]) << 16);
    std.debug.print("{s:<22} {d}\n", .{ name, index });
    return offset + 4;
}

fn jumpInstruction(name: []const u8, c: *Chunk, offset: usize) usize {
    const lo = c.code.items[offset + 1];
    const hi = c.code.items[offset + 2];
    const jump: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
    const target: isize = @as(isize, @intCast(offset)) + 3 + jump;
    std.debug.print("{s:<22} {d} -> {d}\n", .{ name, jump, target });
    return offset + 3;
}

fn simpleInstruction(name: []const u8, offset: usize) usize {
    std.debug.print("{s}\n", .{name});
    return offset + 1;
}
