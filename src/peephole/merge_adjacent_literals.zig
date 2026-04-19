const std = @import("std");
const chunk_mod = @import("../chunk.zig");
const object = @import("../object.zig");
const value_mod = @import("../value.zig");

const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const SourceSpan = chunk_mod.SourceSpan;
const Value = value_mod.Value;

/// Fold runs of adjacent mergeable literal instructions in `chunk` into
/// a single op_match_string each. Runs by design never cross a jump
/// target (other than the run's first byte) and never include an
/// op_match_string_i, so fusing them never changes matching semantics.
///
/// Example, `"HTTP" "/" "1.1"`:
///
///   before                                after
///   OP_MATCH_STRING  'HTTP'               OP_MATCH_STRING  'HTTP/1.1'
///   OP_MATCH_CHAR    '/'
///   OP_MATCH_STRING  '1.1'
///
/// Three dispatched ops become one; the constant pool gains one
/// entry (old ones stay, dedup picks them up elsewhere). Jump offsets
/// that straddled any of the merged regions are adjusted to account
/// for the shrinkage before the bytes are spliced out.
///
/// Intended to run as a post-pass after a chunk is fully compiled,
/// so every jump the chunk will ever contain is already emitted and
/// discoverable by a forward scan.
pub fn mergeAdjacentLiterals(chunk: *Chunk, pool: *object.ObjPool) !void {
    // Repeat until no run can be extended. One pass does almost all
    // the work; a second can catch freshly-exposed adjacencies when a
    // merge brings two non-adjacent literals together (which does not
    // actually happen today — merges only shrink, never rearrange —
    // but the loop makes the pass idempotent by construction).
    while (try mergeOnce(chunk, pool)) {}
}

fn mergeOnce(chunk: *Chunk, pool: *object.ObjPool) !bool {
    var jump_targets = std.AutoHashMap(usize, void).init(pool.allocator);
    defer jump_targets.deinit();
    try collectJumpTargets(chunk, &jump_targets);

    var scan: usize = 0;
    while (scan < chunk.code.items.len) {
        const op_byte = chunk.code.items[scan];
        const op = std.enums.fromInt(OpCode, op_byte) orelse return false;
        const size = instructionSize(op);
        if (!isMergeableLiteral(op) or scan + size > chunk.code.items.len) {
            scan += size;
            continue;
        }

        // Extend the run as long as the next instruction is also a
        // mergeable literal and no jump target lands on its start.
        var run_end = scan + size;
        var count: usize = 1;
        while (run_end < chunk.code.items.len) {
            if (jump_targets.contains(run_end)) break;
            const next_op = std.enums.fromInt(OpCode, chunk.code.items[run_end]) orelse break;
            if (!isMergeableLiteral(next_op)) break;
            const next_size = instructionSize(next_op);
            if (run_end + next_size > chunk.code.items.len) break;
            run_end += next_size;
            count += 1;
        }

        if (count >= 2) {
            try mergeRun(chunk, pool, scan, run_end);
            return true;
        }
        scan = run_end;
    }
    return false;
}

fn mergeRun(chunk: *Chunk, pool: *object.ObjPool, run_start: usize, run_end: usize) !void {
    // Concatenate the payloads of every literal in the run. Char
    // literals contribute their inline byte; string literals pull from
    // the constant pool.
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(pool.allocator);
    var p = run_start;
    while (p < run_end) {
        const op = std.enums.fromInt(OpCode, chunk.code.items[p]) orelse unreachable;
        const payload = literalPayload(chunk, p, op);
        try combined.appendSlice(pool.allocator, payload);
        p += instructionSize(op);
    }

    const lit = try pool.copyLiteral(combined.items);
    const idx = try chunk.addConstant(.{ .obj = lit.asObj() });

    var replacement: [4]u8 = undefined;
    var replacement_len: usize = undefined;
    if (idx <= std.math.maxInt(u8)) {
        replacement[0] = @intFromEnum(OpCode.op_match_string);
        replacement[1] = @intCast(idx);
        replacement_len = 2;
    } else {
        replacement[0] = @intFromEnum(OpCode.op_match_string_wide);
        replacement[1] = @intCast(idx & 0xff);
        replacement[2] = @intCast((idx >> 8) & 0xff);
        replacement[3] = @intCast((idx >> 16) & 0xff);
        replacement_len = 4;
    }

    // Pathological: if the replacement is larger than the run, skip.
    // (In practice two 2-byte literals + a wide replacement = 4, same
    // size; three or more always shrink.)
    if (replacement_len >= run_end - run_start) return;
    const shrink: usize = (run_end - run_start) - replacement_len;

    // Rewrite jump offsets that straddle the merged region BEFORE the
    // splice, while every source and target is still in pre-shrink
    // coordinates.
    adjustStraddlingJumps(chunk, run_start, run_end, shrink);

    const span = chunk.getSpan(run_start);
    try chunk.replaceRange(run_start, run_end, replacement[0..replacement_len], span);
}

fn collectJumpTargets(chunk: *Chunk, out: *std.AutoHashMap(usize, void)) !void {
    var offset: usize = 0;
    while (offset < chunk.code.items.len) {
        const op = std.enums.fromInt(OpCode, chunk.code.items[offset]) orelse return;
        const size = instructionSize(op);
        if (isJumpInstruction(op) and offset + 3 <= chunk.code.items.len) {
            const t = jumpTarget(chunk, offset) orelse {
                offset += size;
                continue;
            };
            try out.put(t, {});
        }
        offset += size;
    }
}

fn adjustStraddlingJumps(chunk: *Chunk, run_start: usize, run_end: usize, shrink: usize) void {
    var offset: usize = 0;
    while (offset < chunk.code.items.len) {
        const op = std.enums.fromInt(OpCode, chunk.code.items[offset]) orelse return;
        const size = instructionSize(op);
        if (isJumpInstruction(op) and offset + 3 <= chunk.code.items.len) {
            const source = offset;
            const target = jumpTarget(chunk, offset) orelse {
                offset += size;
                continue;
            };
            var delta: isize = 0;
            if (source < run_start and target >= run_end) {
                delta = -@as(isize, @intCast(shrink));
            } else if (source >= run_end and target <= run_start) {
                delta = @as(isize, @intCast(shrink));
            }
            if (delta != 0) {
                const lo = chunk.code.items[offset + 1];
                const hi = chunk.code.items[offset + 2];
                const old: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
                const new_jump: i16 = @intCast(@as(isize, old) + delta);
                const bits: u16 = @bitCast(new_jump);
                chunk.code.items[offset + 1] = @intCast(bits & 0xff);
                chunk.code.items[offset + 2] = @intCast(bits >> 8);
            }
        }
        offset += size;
    }
}

fn jumpTarget(chunk: *Chunk, offset: usize) ?usize {
    const lo = chunk.code.items[offset + 1];
    const hi = chunk.code.items[offset + 2];
    const j: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
    const t = @as(isize, @intCast(offset + 3)) + j;
    if (t < 0 or t > @as(isize, @intCast(chunk.code.items.len))) return null;
    return @intCast(t);
}

fn literalPayload(chunk: *Chunk, offset: usize, op: OpCode) []const u8 {
    return switch (op) {
        .op_match_char => chunk.code.items[offset + 1 ..][0..1],
        .op_match_string => chunk.constants.items[chunk.code.items[offset + 1]].obj.asLiteral().chars(),
        .op_match_string_wide => blk: {
            const idx: usize = @as(usize, chunk.code.items[offset + 1]) |
                (@as(usize, chunk.code.items[offset + 2]) << 8) |
                (@as(usize, chunk.code.items[offset + 3]) << 16);
            break :blk chunk.constants.items[idx].obj.asLiteral().chars();
        },
        else => unreachable,
    };
}

fn isMergeableLiteral(op: OpCode) bool {
    return switch (op) {
        .op_match_char, .op_match_string, .op_match_string_wide => true,
        else => false,
    };
}

fn isJumpInstruction(op: OpCode) bool {
    return switch (op) {
        .op_choice,
        .op_choice_quant,
        .op_choice_lookahead,
        .op_commit,
        .op_back_commit,
        => true,
        else => false,
    };
}

fn instructionSize(op: OpCode) usize {
    return switch (op) {
        .op_match_any,
        .op_return,
        .op_fail,
        .op_fail_twice,
        .op_cut,
        .op_longest_begin,
        .op_longest_step,
        .op_longest_end,
        .op_halt,
        => 1,
        .op_match_char,
        .op_match_string,
        .op_match_string_i,
        .op_match_charset,
        .op_call,
        .op_capture_begin,
        .op_capture_end,
        .op_match_backref,
        .op_cut_label,
        => 2,
        .op_choice,
        .op_choice_quant,
        .op_choice_lookahead,
        .op_commit,
        .op_back_commit,
        => 3,
        .op_match_string_wide,
        .op_match_string_i_wide,
        .op_match_charset_wide,
        .op_call_wide,
        .op_cut_label_wide,
        => 4,
    };
}

test "fuses three char literals into one match_string" {
    const alloc = std.testing.allocator;
    var pool = object.ObjPool.init(alloc);
    defer pool.deinit();
    var chunk = Chunk.init(alloc);
    defer chunk.deinit();

    const span: SourceSpan = .{ .start = 0, .len = 1, .line = 1 };
    try chunk.write(@intFromEnum(OpCode.op_match_char), span);
    try chunk.write('a', span);
    try chunk.write(@intFromEnum(OpCode.op_match_char), span);
    try chunk.write('b', span);
    try chunk.write(@intFromEnum(OpCode.op_match_char), span);
    try chunk.write('c', span);
    try chunk.write(@intFromEnum(OpCode.op_return), span);

    try mergeAdjacentLiterals(&chunk, &pool);

    try std.testing.expectEqual(@as(usize, 3), chunk.code.items.len);
    try std.testing.expectEqual(
        @intFromEnum(OpCode.op_match_string),
        chunk.code.items[0],
    );
    const lit = chunk.constants.items[chunk.code.items[1]].obj.asLiteral();
    try std.testing.expectEqualStrings("abc", lit.chars());
    try std.testing.expectEqual(
        @intFromEnum(OpCode.op_return),
        chunk.code.items[2],
    );
}

test "skips across a jump target inside the run" {
    const alloc = std.testing.allocator;
    var pool = object.ObjPool.init(alloc);
    defer pool.deinit();
    var chunk = Chunk.init(alloc);
    defer chunk.deinit();

    const span: SourceSpan = .{ .start = 0, .len = 1, .line = 1 };
    // Layout:
    //   0: OP_CHOICE      5 -> 8     ; jump target = 8
    //   3: OP_MATCH_CHAR  'a'        ; [3, 5)
    //   5: OP_COMMIT      0 -> 8     ; [5, 8)  (offset 0)
    //   8: OP_MATCH_CHAR  'b'        ; <-- jump target
    //  10: OP_MATCH_CHAR  'c'
    // Merging 'a' with 'b' or 'b' with 'c' would be invalid if any jump
    // landed at 8. The pass should merge 'b' and 'c' together since 8
    // is the first literal of the run, not the second.
    try chunk.write(@intFromEnum(OpCode.op_choice), span);
    try chunk.write(5, span);
    try chunk.write(0, span);
    try chunk.write(@intFromEnum(OpCode.op_match_char), span);
    try chunk.write('a', span);
    try chunk.write(@intFromEnum(OpCode.op_commit), span);
    try chunk.write(0, span);
    try chunk.write(0, span);
    try chunk.write(@intFromEnum(OpCode.op_match_char), span);
    try chunk.write('b', span);
    try chunk.write(@intFromEnum(OpCode.op_match_char), span);
    try chunk.write('c', span);

    try mergeAdjacentLiterals(&chunk, &pool);

    // After merge: 'b' and 'c' became one op_match_string "bc" at
    // offset 8; 'a' stayed alone. Total length shrinks by 2.
    try std.testing.expectEqual(@as(usize, 10), chunk.code.items.len);
    try std.testing.expectEqual(
        @intFromEnum(OpCode.op_match_string),
        chunk.code.items[8],
    );
    const lit = chunk.constants.items[chunk.code.items[9]].obj.asLiteral();
    try std.testing.expectEqualStrings("bc", lit.chars());
}

test "adjusts forward jump offsets that straddle a merge" {
    const alloc = std.testing.allocator;
    var pool = object.ObjPool.init(alloc);
    defer pool.deinit();
    var chunk = Chunk.init(alloc);
    defer chunk.deinit();

    const span: SourceSpan = .{ .start = 0, .len = 1, .line = 1 };
    // Layout:
    //   0: OP_CHOICE      11 -> 14    ; jumps over the literal run
    //   3: OP_MATCH_CHAR  'a'
    //   5: OP_MATCH_CHAR  'b'
    //   7: OP_MATCH_CHAR  'c'
    //   9: OP_MATCH_CHAR  'd'
    //  11: OP_COMMIT      0  -> 14
    //  14: OP_RETURN
    try chunk.write(@intFromEnum(OpCode.op_choice), span);
    try chunk.write(11, span);
    try chunk.write(0, span);
    try chunk.write(@intFromEnum(OpCode.op_match_char), span);
    try chunk.write('a', span);
    try chunk.write(@intFromEnum(OpCode.op_match_char), span);
    try chunk.write('b', span);
    try chunk.write(@intFromEnum(OpCode.op_match_char), span);
    try chunk.write('c', span);
    try chunk.write(@intFromEnum(OpCode.op_match_char), span);
    try chunk.write('d', span);
    try chunk.write(@intFromEnum(OpCode.op_commit), span);
    try chunk.write(0, span);
    try chunk.write(0, span);
    try chunk.write(@intFromEnum(OpCode.op_return), span);

    try mergeAdjacentLiterals(&chunk, &pool);

    // Merged: 4 chars (8 bytes) → 1 string (2 bytes), shrink = 6.
    // OP_CHOICE's target was 14 → must become 8 (14 - 6).
    // OP_COMMIT's target was 14, source 11 → after shrink source 5,
    // target 8, offset = 8 - (5 + 3) = 0. Already 0, no change, but
    // the relative form still reads correctly.
    const lo = chunk.code.items[1];
    const hi = chunk.code.items[2];
    const choice_jump: i16 = @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
    const choice_target: isize = 3 + choice_jump;
    try std.testing.expectEqual(@as(isize, 8), choice_target);
}
