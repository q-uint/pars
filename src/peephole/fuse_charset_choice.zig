const std = @import("std");
const chunk_mod = @import("../chunk.zig");
const object = @import("../object.zig");
const value_mod = @import("../value.zig");

const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const SourceSpan = chunk_mod.SourceSpan;
const Value = value_mod.Value;

/// Try to collapse the choice `A / B` currently sitting in the chunk
/// into a single op_match_charset when both arms are single-byte
/// matchers. Layout expected on entry:
///
///   [left_start      ] op_choice <offset>   (3 bytes)
///   [left_start+3    ] A's emitted bytes
///   [commit_offset   ] op_commit <offset>   (3 bytes)
///   [commit_offset+3 ] B's emitted bytes
///   [end             ]
///
/// Example, `BIT = "0" / "1"`:
///
///   before                          after
///   OP_CHOICE      5 -> 8           OP_MATCH_CHARSET  [01]
///   OP_MATCH_CHAR  '0'              OP_RETURN
///   OP_COMMIT      2 -> 10
///   OP_MATCH_CHAR  '1'
///   OP_RETURN
///
/// Five instructions (and the backtrack frame pushed by OP_CHOICE)
/// become one charset lookup. Fusion composes across left-associative
/// chains: `'+' / '*' / '/'` fuses pairwise into `[*+/]`.
///
/// Returns true when the fusion fired so the caller knows the chunk
/// has been rewritten.
pub fn fuseCharsetChoice(
    chunk: *Chunk,
    pool: *object.ObjPool,
    left_start: usize,
    commit_offset: usize,
    span: SourceSpan,
) !bool {
    const code = chunk.code.items;
    if (commit_offset + 3 > code.len) return false;
    const left_bytes = code[left_start + 3 .. commit_offset];
    const right_bytes = code[commit_offset + 3 .. code.len];

    const constants = chunk.constants.items;
    const left_set = extractByteSet(left_bytes, constants) orelse return false;
    const right_set = extractByteSet(right_bytes, constants) orelse return false;

    var union_bits: [32]u8 = undefined;
    for (&union_bits, left_set, right_set) |*dst, l, r| dst.* = l | r;

    const cs = try pool.createCharset(union_bits);
    chunk.truncate(left_start);
    try chunk.emitOpConstant(
        .op_match_charset,
        .op_match_charset_wide,
        .{ .obj = cs.asObj() },
        span,
    );
    return true;
}

/// Return the 256-bit membership set if `bytes` is exactly one
/// byte-matcher instruction (op_match_char or op_match_charset, narrow
/// or wide), otherwise null. Any extra instructions, captures, calls,
/// or control flow disqualify the region.
fn extractByteSet(bytes: []const u8, constants: []const Value) ?[32]u8 {
    if (bytes.len == 0) return null;
    const op = std.enums.fromInt(OpCode, bytes[0]) orelse return null;
    switch (op) {
        .op_match_char => {
            if (bytes.len != 2) return null;
            var bits: [32]u8 = .{0} ** 32;
            const b = bytes[1];
            bits[b >> 3] |= @as(u8, 1) << @intCast(b & 0x07);
            return bits;
        },
        .op_match_charset => {
            if (bytes.len != 2) return null;
            return charsetBits(constants[bytes[1]]);
        },
        .op_match_charset_wide => {
            if (bytes.len != 4) return null;
            const idx: usize = @as(usize, bytes[1]) |
                (@as(usize, bytes[2]) << 8) |
                (@as(usize, bytes[3]) << 16);
            return charsetBits(constants[idx]);
        },
        else => return null,
    }
}

fn charsetBits(val: Value) ?[32]u8 {
    return switch (val) {
        .obj => |o| switch (o.obj_type) {
            .charset => o.asCharset().bits,
            else => null,
        },
        else => null,
    };
}

test "fuses char / char into charset" {
    const alloc = std.testing.allocator;
    var pool = object.ObjPool.init(alloc);
    defer pool.deinit();
    var chunk = Chunk.init(alloc);
    defer chunk.deinit();

    const span: SourceSpan = .{ .start = 0, .len = 1, .line = 1 };
    // Layout: op_choice off=5, op_match_char '0', op_commit off=2, op_match_char '1'.
    try chunk.write(@intFromEnum(OpCode.op_choice), span);
    try chunk.write(5, span);
    try chunk.write(0, span);
    try chunk.write(@intFromEnum(OpCode.op_match_char), span);
    try chunk.write('0', span);
    try chunk.write(@intFromEnum(OpCode.op_commit), span);
    try chunk.write(2, span);
    try chunk.write(0, span);
    try chunk.write(@intFromEnum(OpCode.op_match_char), span);
    try chunk.write('1', span);

    const fired = try fuseCharsetChoice(&chunk, &pool, 0, 5, span);
    try std.testing.expect(fired);
    try std.testing.expectEqual(@as(usize, 2), chunk.code.items.len);
    try std.testing.expectEqual(
        @intFromEnum(OpCode.op_match_charset),
        chunk.code.items[0],
    );
    const cs = chunk.constants.items[chunk.code.items[1]].obj.asCharset();
    try std.testing.expect(cs.contains('0'));
    try std.testing.expect(cs.contains('1'));
    try std.testing.expect(!cs.contains('2'));
}

test "leaves choice alone when an arm has extra bytes" {
    const alloc = std.testing.allocator;
    var pool = object.ObjPool.init(alloc);
    defer pool.deinit();
    var chunk = Chunk.init(alloc);
    defer chunk.deinit();

    const span: SourceSpan = .{ .start = 0, .len = 1, .line = 1 };
    // Left arm is two match_chars — not a single byte-matcher.
    try chunk.write(@intFromEnum(OpCode.op_choice), span);
    try chunk.write(7, span);
    try chunk.write(0, span);
    try chunk.write(@intFromEnum(OpCode.op_match_char), span);
    try chunk.write('a', span);
    try chunk.write(@intFromEnum(OpCode.op_match_char), span);
    try chunk.write('b', span);
    try chunk.write(@intFromEnum(OpCode.op_commit), span);
    try chunk.write(2, span);
    try chunk.write(0, span);
    try chunk.write(@intFromEnum(OpCode.op_match_char), span);
    try chunk.write('c', span);

    const len_before = chunk.code.items.len;
    const fired = try fuseCharsetChoice(&chunk, &pool, 0, 7, span);
    try std.testing.expect(!fired);
    try std.testing.expectEqual(len_before, chunk.code.items.len);
}
