const std = @import("std");
const chunk = @import("chunk.zig");
const OpCode = chunk.OpCode;
const Chunk = chunk.Chunk;
const object = @import("object.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
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
    const op = std.enums.fromInt(OpCode, instruction) orelse {
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
        .op_choice_quant => jumpInstruction("OP_CHOICE_QUANT", c, offset),
        .op_choice_lookahead => jumpInstruction("OP_CHOICE_LOOKAHEAD", c, offset),
        .op_commit => jumpInstruction("OP_COMMIT", c, offset),
        .op_fail => simpleInstruction("OP_FAIL", offset),
        .op_capture_begin => indexInstruction("OP_CAPTURE_BEGIN", c, offset),
        .op_capture_end => indexInstruction("OP_CAPTURE_END", c, offset),
        .op_match_backref => indexInstruction("OP_MATCH_BACKREF", c, offset),
        .op_fail_twice => simpleInstruction("OP_FAIL_TWICE", offset),
        .op_back_commit => jumpInstruction("OP_BACK_COMMIT", c, offset),
        .op_cut => simpleInstruction("OP_CUT", offset),
        .op_cut_label => constantInstruction("OP_CUT_LABEL", c, offset),
        .op_cut_label_wide => constantWideInstruction("OP_CUT_LABEL_WIDE", c, offset),
        .op_longest_begin => simpleInstruction("OP_LONGEST_BEGIN", offset),
        .op_longest_step => simpleInstruction("OP_LONGEST_STEP", offset),
        .op_longest_end => simpleInstruction("OP_LONGEST_END", offset),
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

// Metadata describing a single decoded instruction. Produced by
// decodeInstruction() and consumed by the JSON disassembler. `detail`
// is the same human-readable operand string the text disassembler
// prints; `size` is the total instruction width in bytes.
const DecodedInstruction = struct {
    op: OpCode,
    name: []const u8,
    size: usize,
    detail: []const u8,
};

// Decode the instruction at `offset` into its name, width, and a
// human-readable operand string. The `detail` slice is written into
// `buf` so the caller owns the backing storage.
pub fn decodeInstruction(c: *const Chunk, offset: usize, buf: []u8) !DecodedInstruction {
    const byte = c.code.items[offset];
    const op = std.enums.fromInt(OpCode, byte) orelse {
        const s = try std.fmt.bufPrint(buf, "unknown opcode {d}", .{byte});
        return .{ .op = .op_halt, .name = "OP_UNKNOWN", .size = 1, .detail = s };
    };

    return switch (op) {
        .op_match_char => .{
            .op = op,
            .name = "OP_MATCH_CHAR",
            .size = 2,
            .detail = try std.fmt.bufPrint(buf, "'{c}'", .{c.code.items[offset + 1]}),
        },
        .op_match_any => .{ .op = op, .name = "OP_MATCH_ANY", .size = 1, .detail = "" },
        .op_match_string => try decodeConstant("OP_MATCH_STRING", c, offset, 2, buf),
        .op_match_string_wide => try decodeConstant("OP_MATCH_STRING_WIDE", c, offset, 4, buf),
        .op_match_string_i => try decodeConstant("OP_MATCH_STRING_I", c, offset, 2, buf),
        .op_match_string_i_wide => try decodeConstant("OP_MATCH_STRING_I_WIDE", c, offset, 4, buf),
        .op_match_charset => try decodeConstant("OP_MATCH_CHARSET", c, offset, 2, buf),
        .op_match_charset_wide => try decodeConstant("OP_MATCH_CHARSET_WIDE", c, offset, 4, buf),
        .op_call => try decodeIndex("OP_CALL", c, offset, 2, buf),
        .op_call_wide => try decodeIndex("OP_CALL_WIDE", c, offset, 4, buf),
        .op_return => .{ .op = op, .name = "OP_RETURN", .size = 1, .detail = "" },
        .op_choice => try decodeJump("OP_CHOICE", c, offset, buf),
        .op_choice_quant => try decodeJump("OP_CHOICE_QUANT", c, offset, buf),
        .op_choice_lookahead => try decodeJump("OP_CHOICE_LOOKAHEAD", c, offset, buf),
        .op_commit => try decodeJump("OP_COMMIT", c, offset, buf),
        .op_fail => .{ .op = op, .name = "OP_FAIL", .size = 1, .detail = "" },
        .op_capture_begin => try decodeIndex("OP_CAPTURE_BEGIN", c, offset, 2, buf),
        .op_capture_end => try decodeIndex("OP_CAPTURE_END", c, offset, 2, buf),
        .op_match_backref => try decodeIndex("OP_MATCH_BACKREF", c, offset, 2, buf),
        .op_fail_twice => .{ .op = op, .name = "OP_FAIL_TWICE", .size = 1, .detail = "" },
        .op_back_commit => try decodeJump("OP_BACK_COMMIT", c, offset, buf),
        .op_cut => .{ .op = op, .name = "OP_CUT", .size = 1, .detail = "" },
        .op_cut_label => try decodeConstant("OP_CUT_LABEL", c, offset, 2, buf),
        .op_cut_label_wide => try decodeConstant("OP_CUT_LABEL_WIDE", c, offset, 4, buf),
        .op_longest_begin => .{ .op = op, .name = "OP_LONGEST_BEGIN", .size = 1, .detail = "" },
        .op_longest_step => .{ .op = op, .name = "OP_LONGEST_STEP", .size = 1, .detail = "" },
        .op_longest_end => .{ .op = op, .name = "OP_LONGEST_END", .size = 1, .detail = "" },
        .op_halt => .{ .op = op, .name = "OP_HALT", .size = 1, .detail = "" },
    };
}

fn decodeConstant(name: []const u8, c: *const Chunk, offset: usize, size: usize, buf: []u8) !DecodedInstruction {
    const index = if (size == 2)
        @as(usize, c.code.items[offset + 1])
    else
        @as(usize, c.code.items[offset + 1]) |
            (@as(usize, c.code.items[offset + 2]) << 8) |
            (@as(usize, c.code.items[offset + 3]) << 16);
    // Fill the buffer with "{index} '{value}'" mimicking the text form.
    var fbs = std.Io.Writer.fixed(buf);
    try fbs.print("{d} '", .{index});
    try writeValue(&fbs, c.constants.items[index]);
    try fbs.writeAll("'");
    return .{
        .op = std.enums.fromInt(OpCode, c.code.items[offset]).?,
        .name = name,
        .size = size,
        .detail = fbs.buffered(),
    };
}

fn decodeIndex(name: []const u8, c: *const Chunk, offset: usize, size: usize, buf: []u8) !DecodedInstruction {
    const index: u32 = if (size == 2)
        c.code.items[offset + 1]
    else
        @as(u32, c.code.items[offset + 1]) |
            (@as(u32, c.code.items[offset + 2]) << 8) |
            (@as(u32, c.code.items[offset + 3]) << 16);
    const s = try std.fmt.bufPrint(buf, "{d}", .{index});
    return .{
        .op = std.enums.fromInt(OpCode, c.code.items[offset]).?,
        .name = name,
        .size = size,
        .detail = s,
    };
}

fn decodeJump(name: []const u8, c: *const Chunk, offset: usize, buf: []u8) !DecodedInstruction {
    const lo = c.code.items[offset + 1];
    const hi = c.code.items[offset + 2];
    const jump: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
    const target: isize = @as(isize, @intCast(offset)) + 3 + jump;
    const s = try std.fmt.bufPrint(buf, "{d} -> {d}", .{ jump, target });
    return .{
        .op = std.enums.fromInt(OpCode, c.code.items[offset]).?,
        .name = name,
        .size = 3,
        .detail = s,
    };
}

// Write a value's readable representation (the same form printValue()
// prints to stderr) to the given writer.
fn writeValue(w: *std.Io.Writer, val: Value) !void {
    switch (val) {
        .span => |s| try w.print("span({d}, {d})", .{ s.start, s.len }),
        .obj => |o| switch (o.obj_type) {
            .literal => try w.writeAll(o.asLiteral().chars()),
            .charset => try writeCharsetRanges(w, o.asCharset()),
        },
        .none => try w.writeAll("none"),
    }
}

// Render a charset bitvector as a pars-style character class
// (`[a-zA-Z0-9_]`). Contiguous runs of set bits collapse into a single
// range; single bits are emitted as one character. Non-printable bytes
// use `\xNN` escapes.
fn writeCharsetRanges(w: *std.Io.Writer, cs: *object.ObjCharset) !void {
    try w.writeAll("[");
    var byte: u16 = 0;
    while (byte < 256) {
        if (!cs.contains(@intCast(byte))) {
            byte += 1;
            continue;
        }
        const run_start: u8 = @intCast(byte);
        while (byte < 256 and cs.contains(@intCast(byte))) byte += 1;
        const run_end: u8 = @intCast(byte - 1);
        try writeCharsetByte(w, run_start);
        if (run_end != run_start) {
            if (run_end > run_start + 1) try w.writeAll("-");
            try writeCharsetByte(w, run_end);
        }
    }
    try w.writeAll("]");
}

fn writeCharsetByte(w: *std.Io.Writer, byte: u8) !void {
    if (byte >= 0x20 and byte < 0x7f and byte != '\\' and byte != ']' and byte != '-') {
        try w.print("{c}", .{byte});
    } else {
        try w.print("\\x{x:0>2}", .{byte});
    }
}

// Serialize the chunk disassembly into the given stringifier as a JSON
// object with `constants` (the pool) and `instructions` (decoded ops
// with source spans). Takes a `*std.json.Stringify` rather than a raw
// writer so callers can embed the disassembly inside a larger JSON
// document (e.g. an LSP response envelope) without double-encoding.
pub fn writeChunkJson(c: *const Chunk, s: *std.json.Stringify, alloc: std.mem.Allocator) !void {
    try s.beginObject();

    try s.objectField("constants");
    try s.beginArray();
    for (c.constants.items, 0..) |val, i| {
        try s.beginObject();
        try s.objectField("index");
        try s.write(i);
        try s.objectField("kind");
        try s.write(valueKind(val));
        try s.objectField("display");
        var aw = std.Io.Writer.Allocating.init(alloc);
        defer aw.deinit();
        try writeValue(&aw.writer, val);
        try s.write(aw.writer.buffered());
        try s.endObject();
    }
    try s.endArray();

    try s.objectField("instructions");
    try s.beginArray();
    var offset: usize = 0;
    var detail_buf: [256]u8 = undefined;
    while (offset < c.code.items.len) {
        const dec = try decodeInstruction(c, offset, &detail_buf);
        const span = c.getSpan(offset);
        try s.beginObject();
        try s.objectField("offset");
        try s.write(offset);
        try s.objectField("size");
        try s.write(dec.size);
        try s.objectField("op");
        try s.write(dec.name);
        try s.objectField("detail");
        try s.write(dec.detail);
        try s.objectField("span");
        try s.beginObject();
        try s.objectField("start");
        try s.write(span.start);
        try s.objectField("len");
        try s.write(span.len);
        try s.objectField("line");
        try s.write(span.line);
        try s.endObject();
        try s.endObject();
        offset += dec.size;
    }
    try s.endArray();

    try s.endObject();
}

fn valueKind(val: Value) []const u8 {
    return switch (val) {
        .span => "span",
        .obj => |o| switch (o.obj_type) {
            .literal => "literal",
            .charset => "charset",
        },
        .none => "none",
    };
}

test "writeChunkJson emits instructions, constants, and spans" {
    const alloc = std.testing.allocator;
    var pool = object.ObjPool.init(alloc);
    defer pool.deinit();

    var c = Chunk.init(alloc);
    defer c.deinit();

    const s1: chunk.SourceSpan = .{ .start = 0, .len = 3, .line = 1 };
    const s2: chunk.SourceSpan = .{ .start = 4, .len = 5, .line = 1 };

    // OP_MATCH_ANY (1 byte) with span s1.
    try c.write(@intFromEnum(OpCode.op_match_any), s1);
    // OP_MATCH_STRING narrow (2 bytes) pointing at literal "http", span s2.
    const lit = try pool.copyLiteral("http");
    try c.emitOpConstant(.op_match_string, .op_match_string_wide, .{ .obj = lit.asObj() }, s2);
    // OP_HALT (1 byte) sharing span s2.
    try c.write(@intFromEnum(OpCode.op_halt), s2);

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try writeChunkJson(&c, &s, alloc);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, aw.writer.buffered(), .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    const constants = root.get("constants").?.array;
    try std.testing.expectEqual(@as(usize, 1), constants.items.len);
    try std.testing.expectEqualStrings("literal", constants.items[0].object.get("kind").?.string);
    try std.testing.expectEqualStrings("http", constants.items[0].object.get("display").?.string);

    const instructions = root.get("instructions").?.array;
    try std.testing.expectEqual(@as(usize, 3), instructions.items.len);

    try std.testing.expectEqualStrings("OP_MATCH_ANY", instructions.items[0].object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 0), instructions.items[0].object.get("offset").?.integer);
    try std.testing.expectEqual(@as(i64, 0), instructions.items[0].object.get("span").?.object.get("start").?.integer);

    try std.testing.expectEqualStrings("OP_MATCH_STRING", instructions.items[1].object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 1), instructions.items[1].object.get("offset").?.integer);
    try std.testing.expectEqual(@as(i64, 2), instructions.items[1].object.get("size").?.integer);
    try std.testing.expectEqual(@as(i64, 4), instructions.items[1].object.get("span").?.object.get("start").?.integer);

    try std.testing.expectEqualStrings("OP_HALT", instructions.items[2].object.get("op").?.string);
    try std.testing.expectEqual(@as(i64, 3), instructions.items[2].object.get("offset").?.integer);
}

test "writeCharsetRanges collapses runs of set bits" {
    const alloc = std.testing.allocator;
    var pool = object.ObjPool.init(alloc);
    defer pool.deinit();

    var bits: [32]u8 = .{0} ** 32;
    // Set 'a'..'z' and '0'..'9'.
    for ('a'..'z' + 1) |b| bits[b >> 3] |= @as(u8, 1) << @intCast(b & 0x07);
    for ('0'..'9' + 1) |b| bits[b >> 3] |= @as(u8, 1) << @intCast(b & 0x07);

    const cs = try pool.createCharset(bits);
    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try writeCharsetRanges(&aw.writer, cs);

    try std.testing.expectEqualStrings("[0-9a-z]", aw.writer.buffered());
}
