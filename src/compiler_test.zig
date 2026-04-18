const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const object = @import("object.zig");
const compiler_mod = @import("compiler.zig");
const Compiler = compiler_mod.Compiler;
const RuleTable = compiler_mod.RuleTable;

const TestCompileResult = struct {
    chunk: Chunk,
    rules: RuleTable,
    ok: bool,
    alloc: std.mem.Allocator,
    pool: object.ObjPool,
    compiler: Compiler,

    fn deinit(self: *TestCompileResult) void {
        self.chunk.deinit();
        self.rules.deinit(self.alloc);
        self.compiler.deinit();
        self.pool.deinit();
    }
};

fn compileForTest(alloc: std.mem.Allocator, source: []const u8) !TestCompileResult {
    var result: TestCompileResult = .{
        .chunk = Chunk.init(alloc),
        .rules = .{},
        .ok = false,
        .alloc = alloc,
        .pool = object.ObjPool.init(alloc),
        .compiler = Compiler.init(alloc),
    };
    result.ok = result.compiler.compile(source, &result.chunk, &result.rules, &result.pool);
    return result;
}

test "stray token at start flags Expected-an-expression diagnostic" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, ")");
    defer result.deinit();

    try std.testing.expect(!result.ok);
    const errs = result.compiler.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expectEqual(@as(usize, 1), errs[0].line);
    try std.testing.expectEqual(@as(usize, 1), errs[0].column);
    try std.testing.expect(!errs[0].at_eof);
}

test "empty source compiles to just halt" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "");
    defer result.deinit();

    // An empty program is valid: no declarations, main chunk is just OP_HALT.
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(usize, 1), result.chunk.code.items.len);
    try std.testing.expectEqual(
        @intFromEnum(OpCode.op_halt),
        result.chunk.code.items[0],
    );
}

test "renderErrors produces snippet with caret pointing at token" {
    const alloc = std.testing.allocator;
    const src = "   )";
    var result = try compileForTest(alloc, src);
    defer result.deinit();

    try std.testing.expect(!result.ok);

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try result.compiler.renderErrors(src, &aw.writer);

    const expected =
        "error: Expected an expression: a string, a character literal, '.', '[', '(', or a rule name.\n" ++
        " --> line 1, column 4\n" ++
        "   1 |    )\n" ++
        "     |    ^ Expected an expression: a string, a character literal, '.', '[', '(', or a rule name.\n";
    try std.testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "rule declaration populates rule table" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "digit = ['0'-'9'];");
    defer result.deinit();

    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(usize, 1), result.rules.count());
    try std.testing.expect(result.rules.get("digit") != null);
}

test "multiple rule declarations populate rule table" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(
        alloc,
        "digit = ['0'-'9'];\nalpha = ['a'-'z'];",
    );
    defer result.deinit();

    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(usize, 2), result.rules.count());
    try std.testing.expect(result.rules.get("digit") != null);
    try std.testing.expect(result.rules.get("alpha") != null);
}

test "auto-call emits op_call for last rule in main chunk" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "digit = ['0'-'9'];");
    defer result.deinit();

    try std.testing.expect(result.ok);
    // Main chunk should have: OP_CALL <index> OP_HALT
    try std.testing.expect(result.chunk.code.items.len >= 3);
    try std.testing.expectEqual(
        @intFromEnum(OpCode.op_call),
        result.chunk.code.items[0],
    );
}

test "error recovery skips to next rule" {
    const alloc = std.testing.allocator;
    // First rule has a bad body; second rule is valid.
    var result = try compileForTest(
        alloc,
        "bad = );\ndigit = ['0'-'9'];",
    );
    defer result.deinit();

    try std.testing.expect(!result.ok);
    // Despite the error, the second rule should still be in the table.
    try std.testing.expect(result.rules.get("digit") != null);
}

test "repeated rule calls emit the same index operand" {
    const alloc = std.testing.allocator;
    // The rule body contains three calls to "digit" via sequence.
    var result = try compileForTest(
        alloc,
        "digit = ['0'-'9'];\ntriple = digit digit digit;",
    );
    defer result.deinit();

    try std.testing.expect(result.ok);
    // The "triple" rule chunk: three op_call + op_return = 7 bytes.
    const triple = result.rules.getChunkPtr(result.rules.get("triple").?) orelse
        return error.TestUnexpectedResult;
    const code = triple.code.items;
    try std.testing.expectEqual(@as(usize, 7), code.len);
    const call_op = @intFromEnum(OpCode.op_call);
    try std.testing.expectEqual(call_op, code[0]);
    try std.testing.expectEqual(call_op, code[2]);
    try std.testing.expectEqual(call_op, code[4]);
    // All three share the same rule index.
    try std.testing.expectEqual(code[1], code[3]);
    try std.testing.expectEqual(code[1], code[5]);
}

test "scanner error surfaces through compile with correct location" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "\"unterminated");
    defer result.deinit();

    try std.testing.expect(!result.ok);
    const errs = result.compiler.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expectEqualStrings("Unterminated string.", errs[0].message);
    try std.testing.expectEqual(@as(usize, 1), errs[0].column);
}

test "use std/abnf populates DIGIT in rule table" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "use \"std/abnf\";");
    defer result.deinit();
    try std.testing.expect(result.ok);
    try std.testing.expect(result.rules.get("DIGIT") != null);
    try std.testing.expect(result.rules.get("ALPHA") != null);
}

test "use unknown module is a compile error" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "use \"std/bogus\";");
    defer result.deinit();
    try std.testing.expect(!result.ok);
}

test "char literal escape \\n compiles successfully" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "'\\n'");
    defer result.deinit();
    try std.testing.expect(result.ok);
    // Main chunk: OP_MATCH_CHAR 0x0A OP_HALT
    try std.testing.expectEqual(@as(usize, 3), result.chunk.code.items.len);
    try std.testing.expectEqual(@intFromEnum(OpCode.op_match_char), result.chunk.code.items[0]);
    try std.testing.expectEqual(@as(u8, '\n'), result.chunk.code.items[1]);
}

test "char literal escape \\r compiles successfully" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "'\\r'");
    defer result.deinit();
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(u8, '\r'), result.chunk.code.items[1]);
}

test "char literal escape \\t compiles successfully" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "'\\t'");
    defer result.deinit();
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(u8, '\t'), result.chunk.code.items[1]);
}

test "char literal hex escape \\x41 compiles to 0x41" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "'\\x41'");
    defer result.deinit();
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(u8, 0x41), result.chunk.code.items[1]);
}

test "char literal hex escape \\x00 compiles to 0x00" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "'\\x00'");
    defer result.deinit();
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(u8, 0x00), result.chunk.code.items[1]);
}

test "charset with hex escaped range compiles successfully" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "['\\x00'-'\\x1F']");
    defer result.deinit();
    try std.testing.expect(result.ok);
}

test "char literal unknown escape is a compile error" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "'\\z'");
    defer result.deinit();
    try std.testing.expect(!result.ok);
}

test "char literal hex escape with bad digit is a compile error" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "'\\xZZ'");
    defer result.deinit();
    try std.testing.expect(!result.ok);
}

test "unused where-binding is reported" {
    const alloc = std.testing.allocator;
    const src =
        "foo = \"x\"\n" ++
        "  where\n" ++
        "    a = \"y\"\n" ++
        "  end\n";
    var result = try compileForTest(alloc, src);
    defer result.deinit();

    try std.testing.expect(!result.ok);
    const errs = result.compiler.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expectEqualStrings(
        "Unused where-binding 'a'.",
        errs[0].message,
    );
    try std.testing.expectEqual(@as(usize, 3), errs[0].line);
    try std.testing.expectEqual(@as(usize, 5), errs[0].column);
}

test "used where-binding is not reported" {
    const alloc = std.testing.allocator;
    const src =
        "foo = a\n" ++
        "  where\n" ++
        "    a = \"y\"\n" ++
        "  end\n";
    var result = try compileForTest(alloc, src);
    defer result.deinit();

    try std.testing.expect(result.ok);
}

test "where-binding only referenced by a typo is flagged as unused" {
    const alloc = std.testing.allocator;
    // 'k' is bound but the body references 'kk', so 'k' goes unused.
    // 'kk' falls through to the global rule table and is fine at
    // compile time, exactly like any other forward-declared rule.
    const src =
        "foo = kk\n" ++
        "  where\n" ++
        "    k = \"x\"\n" ++
        "  end\n";
    var result = try compileForTest(alloc, src);
    defer result.deinit();

    try std.testing.expect(!result.ok);
    const errs = result.compiler.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expectEqualStrings(
        "Unused where-binding 'k'.",
        errs[0].message,
    );
}

test "multiple unused where-bindings are all reported" {
    const alloc = std.testing.allocator;
    const src =
        "foo = \"x\"\n" ++
        "  where\n" ++
        "    a = \"y\";\n" ++
        "    b = \"z\"\n" ++
        "  end\n";
    var result = try compileForTest(alloc, src);
    defer result.deinit();

    try std.testing.expect(!result.ok);
    const errs = result.compiler.getErrors();
    try std.testing.expectEqual(@as(usize, 2), errs.len);
}

test "duplicate where-binding reports prior declaration location" {
    const alloc = std.testing.allocator;
    const src =
        "foo = a\n" ++
        "  where\n" ++
        "    a = \"x\";\n" ++
        "    a = \"y\"\n" ++
        "  end\n";
    var result = try compileForTest(alloc, src);
    defer result.deinit();

    try std.testing.expect(!result.ok);
    const errs = result.compiler.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errs.len);

    const e = errs[0];
    try std.testing.expectEqual(@as(usize, 4), e.line);
    try std.testing.expectEqual(@as(usize, 5), e.column);
    try std.testing.expectEqualStrings(
        "Duplicate where-binding 'a'. Previous declaration at line 3, column 5.",
        e.message,
    );

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try result.compiler.renderErrors(src, &aw.writer);
    const expected =
        "error: Duplicate where-binding 'a'. Previous declaration at line 3, column 5.\n" ++
        " --> line 4, column 5\n" ++
        "   4 |     a = \"y\"\n" ++
        "     |     ^ Duplicate where-binding 'a'. Previous declaration at line 3, column 5.\n";
    try std.testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "capture emits capture-begin and capture-end opcodes" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "<k: \"x\">");
    defer result.deinit();

    try std.testing.expect(result.ok);
    const code = result.chunk.code.items;
    // op_capture_begin 0, op_match_string X, op_capture_end 0, op_halt
    try std.testing.expectEqual(@intFromEnum(OpCode.op_capture_begin), code[0]);
    try std.testing.expectEqual(@as(u8, 0), code[1]);
    const halt_pos = code.len - 1;
    try std.testing.expectEqual(@intFromEnum(OpCode.op_halt), code[halt_pos]);
    try std.testing.expectEqual(@intFromEnum(OpCode.op_capture_end), code[halt_pos - 2]);
    try std.testing.expectEqual(@as(u8, 0), code[halt_pos - 1]);
}

test "multiple captures get distinct slots" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "<a: \"x\"> <b: \"y\">");
    defer result.deinit();

    try std.testing.expect(result.ok);
    const code = result.chunk.code.items;
    // First capture uses slot 0.
    try std.testing.expectEqual(@intFromEnum(OpCode.op_capture_begin), code[0]);
    try std.testing.expectEqual(@as(u8, 0), code[1]);
    // Find second capture_begin; its slot should be 1.
    var found_second = false;
    for (code[2..], 2..) |byte, i| {
        if (byte == @intFromEnum(OpCode.op_capture_begin) and i > 1) {
            try std.testing.expectEqual(@as(u8, 1), code[i + 1]);
            found_second = true;
            break;
        }
    }
    try std.testing.expect(found_second);
}

test "unreferenced capture is not flagged as unused" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "foo = <k: \"x\">;");
    defer result.deinit();

    try std.testing.expect(result.ok);
}

test "back-reference emits op_match_backref" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "<k: \"x\"> k");
    defer result.deinit();

    try std.testing.expect(result.ok);
    const code = result.chunk.code.items;
    // Find op_match_backref after the capture_end.
    var found = false;
    for (code) |byte| {
        if (byte == @intFromEnum(OpCode.op_match_backref)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "capture allows choice inside brackets" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "<s: \"http\" / \"ftp\">");
    defer result.deinit();

    try std.testing.expect(result.ok);
}

test "negative lookahead emits choice, operand, fail_twice" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "!\"x\"");
    defer result.deinit();

    try std.testing.expect(result.ok);
    const code = result.chunk.code.items;
    try std.testing.expectEqual(@intFromEnum(OpCode.op_choice_lookahead), code[0]);
    try std.testing.expectEqual(@intFromEnum(OpCode.op_match_string), code[3]);
    try std.testing.expectEqual(@intFromEnum(OpCode.op_fail_twice), code[5]);
    try std.testing.expectEqual(@intFromEnum(OpCode.op_halt), code[6]);
}

test "positive lookahead emits choice, operand, back_commit, fail" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "&\"x\"");
    defer result.deinit();

    try std.testing.expect(result.ok);
    const code = result.chunk.code.items;
    try std.testing.expectEqual(@intFromEnum(OpCode.op_choice_lookahead), code[0]);
    try std.testing.expectEqual(@intFromEnum(OpCode.op_match_string), code[3]);
    try std.testing.expectEqual(@intFromEnum(OpCode.op_back_commit), code[5]);
    try std.testing.expectEqual(@intFromEnum(OpCode.op_fail), code[8]);
    try std.testing.expectEqual(@intFromEnum(OpCode.op_halt), code[9]);
}

test "lookahead binds looser than quantifier: !A* parses as !(A*)" {
    // If `*` is inside the lookahead's operand, the emitted bytecode
    // contains the quantifier loop between the choice and the fail_twice,
    // not after it.
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "!\"x\"*");
    defer result.deinit();

    try std.testing.expect(result.ok);
    const code = result.chunk.code.items;
    // Outer lookahead choice, then the star's own choice/commit pair
    // wrapping the match, then fail_twice, then halt.
    try std.testing.expectEqual(@intFromEnum(OpCode.op_choice_lookahead), code[0]);
    // Scan for fail_twice; everything before it (after the outer choice's
    // 3-byte header) belongs to the operand.
    var fail_twice_at: ?usize = null;
    for (code, 0..) |byte, i| {
        if (byte == @intFromEnum(OpCode.op_fail_twice)) {
            fail_twice_at = i;
            break;
        }
    }
    try std.testing.expect(fail_twice_at != null);
    // The quantifier must have been compiled inside the operand: a
    // quantifier choice appears between the outer one and fail_twice.
    var inner_choice_found = false;
    var i: usize = 3;
    while (i < fail_twice_at.?) : (i += 1) {
        if (code[i] == @intFromEnum(OpCode.op_choice_quant)) {
            inner_choice_found = true;
            break;
        }
    }
    try std.testing.expect(inner_choice_found);
}
