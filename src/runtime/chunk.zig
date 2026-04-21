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
    //
    // op_choice tags its frame as kind=choice so op_cut can recognize
    // it. op_choice_quant and op_choice_lookahead push structurally
    // identical frames but tagged with their respective kinds so that
    // a cut walking the backtrack stack skips past them and commits
    // only to an ordered-choice frame (ADR 008).
    op_choice,
    op_choice_quant,
    op_choice_lookahead,
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
    // Save the current input position into the given capture slot.
    // 2 bytes: opcode + slot index.
    op_capture_begin,
    // Compute a Span from the saved position in the capture slot to
    // the current input position and store it back into the slot.
    // 2 bytes: opcode + slot index.
    op_capture_end,
    // Back-reference: match the exact text previously captured in the
    // given slot. Fails if the input at the current position does not
    // match the captured span byte-for-byte.
    // 2 bytes: opcode + slot index.
    op_match_backref,
    // Pop the top backtrack frame without restoring state, then trigger
    // a failure that unwinds through the next frame down. Used to
    // implement negative lookahead `!A`: when A matches, the outer
    // context must fail rather than accept the match.
    // 1 byte.
    op_fail_twice,
    // Pop the top backtrack frame, restore the saved input position
    // from it, then jump by the signed 16-bit offset. Used to
    // implement positive lookahead `&A`: when A matches, rewind to
    // the position before A and continue past the lookahead.
    // 3 bytes: opcode + signed 16-bit offset.
    op_back_commit,
    // Cut: commit the innermost enclosing ordered-choice frame so that
    // later failures cannot backtrack into another alternative of that
    // choice (ADR 008). Walks the backtrack stack top-down looking for
    // a frame with kind=choice; if found, removes it. A bare cut is a
    // no-op when no such frame is present.
    // 1 byte.
    op_cut,
    // Open a longest-match choice group. Pushes a marker frame that
    // records the starting input position and an empty best-endpoint
    // slot. Each arm is wrapped in an ordinary op_choice so failure
    // routes to the next arm; on success, op_longest_step records the
    // endpoint and rewinds to the start. op_longest_end either advances
    // to the best recorded endpoint or fails if no arm matched.
    // 1 byte.
    op_longest_begin,
    // One arm of a longest-match group succeeded. Peek at the enclosing
    // longest frame (one below the arm's choice frame on the backtrack
    // stack); update its best endpoint if the current position is
    // further along, then restore the input position to the frame's
    // start and pop the arm's choice frame so the next arm may run.
    // 1 byte.
    op_longest_step,
    // Close a longest-match choice group. Pops the longest frame: if
    // any arm matched, advance the input position to the best endpoint
    // recorded; otherwise trigger a match failure.
    // 1 byte.
    op_longest_end,
    // Labelled cut: same as op_cut, and additionally records a label
    // constant on the current call frame. If execution fails with no
    // backtrack frame left, the VM walks the call stack for an active
    // label and raises a runtime error carrying that label's message.
    // Narrow form: 2 bytes (opcode + 1-byte constant index).
    // Wide form:   4 bytes (opcode + 3-byte (24-bit) constant index).
    op_cut_label,
    op_cut_label_wide,
    op_halt, // 1 byte
};

// A source-level location attached to emitted bytecode: the byte
// offset into the source, the length of the span in source bytes, and
// the 1-based source line. Line is stored (not computed from start)
// because the VM surfaces it in runtime error messages without access
// to the original source buffer.
pub const SourceSpan = struct {
    start: usize,
    len: usize,
    line: usize,
};

// Run-length encoded (RLE) source-span entry. Each entry covers
// `count` consecutive bytecode bytes produced from the same source
// span. Bytes emitted for the same token share identical spans and so
// collapse into a single run.
pub const SpanRun = struct {
    span: SourceSpan,
    count: usize,
};

pub const Chunk = struct {
    code: std.ArrayList(u8),
    // Run-length encoded source-span info. Instead of one entry per
    // bytecode byte, consecutive bytes from the same source span share
    // a single SpanRun. getLine()/getSpan() walk the runs to resolve a
    // bytecode offset -- acceptable because they only run on errors or
    // on demand from the disassembler.
    spans: std.ArrayList(SpanRun),
    constants: std.ArrayList(Value),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Chunk {
        return .{
            .code = .empty,
            .spans = .empty,
            .constants = .empty,
            .allocator = allocator,
        };
    }

    pub fn write(self: *Chunk, byte: u8, span: SourceSpan) !void {
        try self.code.append(self.allocator, byte);
        if (self.spans.items.len > 0 and
            std.meta.eql(self.spans.items[self.spans.items.len - 1].span, span))
        {
            // Same span as previous byte, extend the current run.
            self.spans.items[self.spans.items.len - 1].count += 1;
        } else {
            // New source span, start a new run.
            try self.spans.append(self.allocator, .{ .span = span, .count = 1 });
        }
    }

    pub fn getSpan(self: *const Chunk, offset: usize) SourceSpan {
        var remaining = offset;
        for (self.spans.items) |run| {
            if (remaining < run.count) return run.span;
            remaining -= run.count;
        }
        unreachable;
    }

    pub fn getLine(self: *const Chunk, offset: usize) usize {
        return self.getSpan(offset).line;
    }

    pub fn addConstant(self: *Chunk, val: Value) !usize {
        // Deduplicate: reuse an existing slot when the value is already
        // present. Linear scan is fine for typical constant pool sizes.
        for (self.constants.items, 0..) |existing, i| {
            if (existing.eql(val)) return i;
        }
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
        span: SourceSpan,
    ) !void {
        const index = try self.addConstant(val);
        if (index <= std.math.maxInt(u8)) {
            try self.write(@intFromEnum(op_narrow), span);
            try self.write(@intCast(index), span);
        } else {
            try self.write(@intFromEnum(op_wide), span);
            try self.write(@intCast(index & 0xff), span);
            try self.write(@intCast((index >> 8) & 0xff), span);
            try self.write(@intCast((index >> 16) & 0xff), span);
        }
    }

    // Insert `count` zero bytes at `offset`, shifting existing code
    // to the right. The span-info run covering `offset` is extended
    // so that the new bytes inherit the same source span.
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
        // Extend the span-info run that covers the insertion point.
        var pos: usize = 0;
        for (self.spans.items) |*run| {
            if (pos + run.count > offset) {
                run.count += count;
                return;
            }
            pos += run.count;
        }
        if (self.spans.items.len > 0) {
            self.spans.items[self.spans.items.len - 1].count += count;
        }
    }

    // Replace the byte range [start, end) with `new_bytes`, attributing
    // every new byte to `new_span`. Bytes after `end` keep their original
    // per-byte spans (re-registered one at a time; chunk.write coalesces
    // adjacent equal spans back into a single RLE run). Used by the
    // post-pass peephole to splice one merged instruction in place of a
    // run of adjacent literals. Caller is responsible for adjusting any
    // relative jump offsets that straddle the merged region before
    // calling — otherwise their targets shift out from under them.
    pub fn replaceRange(
        self: *Chunk,
        start: usize,
        end: usize,
        new_bytes: []const u8,
        new_span: SourceSpan,
    ) !void {
        std.debug.assert(start <= end);
        std.debug.assert(end <= self.code.items.len);

        const tail_len = self.code.items.len - end;
        const tail_bytes = try self.allocator.alloc(u8, tail_len);
        defer self.allocator.free(tail_bytes);
        @memcpy(tail_bytes, self.code.items[end..]);

        const tail_spans = try self.allocator.alloc(SourceSpan, tail_len);
        defer self.allocator.free(tail_spans);
        for (0..tail_len) |i| tail_spans[i] = self.getSpan(end + i);

        self.truncate(start);
        for (new_bytes) |b| try self.write(b, new_span);
        for (tail_bytes, tail_spans) |b, s| try self.write(b, s);
    }

    // Shrink the chunk to `new_len` bytes, adjusting the RLE span runs
    // so their total count still matches the code length. Runs entirely
    // past the cut are dropped; the run straddling the cut is trimmed.
    // Constants are left untouched — they dedupe on the next addConstant
    // and unused entries cost a few bytes of pool. Used by the emit-time
    // peephole to discard a just-emitted region and replace it with a
    // smaller one.
    pub fn truncate(self: *Chunk, new_len: usize) void {
        std.debug.assert(new_len <= self.code.items.len);
        self.code.items.len = new_len;
        var pos: usize = 0;
        var i: usize = 0;
        while (i < self.spans.items.len) : (i += 1) {
            const run = self.spans.items[i];
            if (pos + run.count <= new_len) {
                pos += run.count;
                continue;
            }
            if (pos >= new_len) break;
            self.spans.items[i].count = new_len - pos;
            pos = new_len;
            i += 1;
            break;
        }
        self.spans.items.len = i;
    }

    pub fn deinit(self: *Chunk) void {
        self.code.deinit(self.allocator);
        self.spans.deinit(self.allocator);
        self.constants.deinit(self.allocator);
    }
};

fn testSpan(start: usize, len: usize, line: usize) SourceSpan {
    return .{ .start = start, .len = len, .line = line };
}

test "getLine resolves offsets across multiple runs" {
    var c = Chunk.init(std.testing.allocator);
    defer c.deinit();

    // 3 bytes from span A (line 1), 2 from span B (line 2), 1 from C (line 3).
    const a = testSpan(0, 3, 1);
    const b = testSpan(10, 4, 2);
    const d = testSpan(20, 2, 3);
    try c.write(0, a);
    try c.write(0, a);
    try c.write(0, a);
    try c.write(0, b);
    try c.write(0, b);
    try c.write(0, d);

    try std.testing.expectEqual(1, c.getLine(0));
    try std.testing.expectEqual(1, c.getLine(2));
    try std.testing.expectEqual(2, c.getLine(3));
    try std.testing.expectEqual(2, c.getLine(4));
    try std.testing.expectEqual(3, c.getLine(5));

    try std.testing.expectEqual(a, c.getSpan(0));
    try std.testing.expectEqual(b, c.getSpan(4));
    try std.testing.expectEqual(d, c.getSpan(5));

    // Only 3 runs stored, not 6 entries.
    try std.testing.expectEqual(3, c.spans.items.len);
}

test "emitOpConstant switches to wide form after 256 constants" {
    const object = @import("object.zig");
    const alloc = std.testing.allocator;
    var pool = object.ObjPool.init(alloc);
    defer pool.deinit();

    var c = Chunk.init(alloc);
    defer c.deinit();

    // Fill up the first 256 constant slots with distinct values.
    // Use span values with unique start positions so deduplication
    // does not collapse them.
    const s1 = testSpan(0, 0, 1);
    for (0..256) |i| {
        try c.emitOpConstant(.op_match_string, .op_match_string_wide, .{ .span = .{ .start = i, .len = 0 } }, s1);
    }

    // The 257th should use the wide form.
    const code_len_before = c.code.items.len;
    const lit = try pool.copyLiteral("wide");
    try c.emitOpConstant(.op_match_string, .op_match_string_wide, .{ .obj = lit.asObj() }, testSpan(0, 0, 2));

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

test "replaceRange splices in a shorter region and preserves tail spans" {
    var c = Chunk.init(std.testing.allocator);
    defer c.deinit();

    const a = testSpan(0, 3, 1);
    const b = testSpan(10, 4, 2);
    const d = testSpan(20, 2, 3);
    // [0..3) from span A, [3..6) from span B, [6..8) from span D.
    for (0..3) |_| try c.write(0xAA, a);
    for (0..3) |_| try c.write(0xBB, b);
    for (0..2) |_| try c.write(0xDD, d);

    // Replace [0..6) with two bytes under span A. Tail [6..8) must
    // keep span D and move to [2..4).
    const new_bytes: [2]u8 = .{ 0xEE, 0xEE };
    try c.replaceRange(0, 6, &new_bytes, a);

    try std.testing.expectEqual(@as(usize, 4), c.code.items.len);
    try std.testing.expectEqual(@as(u8, 0xEE), c.code.items[0]);
    try std.testing.expectEqual(@as(u8, 0xEE), c.code.items[1]);
    try std.testing.expectEqual(@as(u8, 0xDD), c.code.items[2]);
    try std.testing.expectEqual(@as(u8, 0xDD), c.code.items[3]);
    try std.testing.expectEqual(a, c.getSpan(0));
    try std.testing.expectEqual(a, c.getSpan(1));
    try std.testing.expectEqual(d, c.getSpan(2));
    try std.testing.expectEqual(d, c.getSpan(3));
}

test "truncate drops and trims RLE span runs" {
    var c = Chunk.init(std.testing.allocator);
    defer c.deinit();

    const a = testSpan(0, 3, 1);
    const b = testSpan(10, 4, 2);
    const d = testSpan(20, 2, 3);
    // Layout: 3 bytes span A, 4 bytes span B, 1 byte span D  (8 bytes total).
    try c.write(0, a);
    try c.write(0, a);
    try c.write(0, a);
    try c.write(0, b);
    try c.write(0, b);
    try c.write(0, b);
    try c.write(0, b);
    try c.write(0, d);
    try std.testing.expectEqual(@as(usize, 8), c.code.items.len);
    try std.testing.expectEqual(@as(usize, 3), c.spans.items.len);

    // Truncate mid-run: keep 5 bytes = span A (3) + 2 of span B.
    c.truncate(5);
    try std.testing.expectEqual(@as(usize, 5), c.code.items.len);
    try std.testing.expectEqual(@as(usize, 2), c.spans.items.len);
    try std.testing.expectEqual(@as(usize, 3), c.spans.items[0].count);
    try std.testing.expectEqual(@as(usize, 2), c.spans.items[1].count);

    // Truncate to zero drops all runs.
    c.truncate(0);
    try std.testing.expectEqual(@as(usize, 0), c.code.items.len);
    try std.testing.expectEqual(@as(usize, 0), c.spans.items.len);
}

test "addConstant deduplicates identical values" {
    const object = @import("object.zig");
    const alloc = std.testing.allocator;
    var pool = object.ObjPool.init(alloc);
    defer pool.deinit();

    var c = Chunk.init(alloc);
    defer c.deinit();

    const lit = try pool.copyLiteral("digit");
    const idx0 = try c.addConstant(.{ .obj = lit.asObj() });
    const idx1 = try c.addConstant(.{ .obj = lit.asObj() });
    const idx2 = try c.addConstant(.{ .obj = lit.asObj() });

    try std.testing.expectEqual(idx0, idx1);
    try std.testing.expectEqual(idx0, idx2);
    try std.testing.expectEqual(@as(usize, 1), c.constants.items.len);
}
