const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const InterpretResult = vm_mod.InterpretResult;

fn haltChunk(alloc: std.mem.Allocator) !Chunk {
    var c = Chunk.init(alloc);
    try c.write(@intFromEnum(OpCode.op_halt), 1);
    return c;
}

test "dynamic vm: halt returns ok" {
    const alloc = std.testing.allocator;
    var c = try haltChunk(alloc);
    defer c.deinit();
    var machine = Vm(null).init(alloc);
    defer machine.deinit();
    machine.chunk = &c;
    try std.testing.expectEqual(.ok, machine.run());
}

test "fixed vm: halt returns ok" {
    const alloc = std.testing.allocator;
    var c = try haltChunk(alloc);
    defer c.deinit();
    var machine = Vm(256).init(alloc);
    defer machine.deinit();
    machine.chunk = &c;
    try std.testing.expectEqual(.ok, machine.run());
}

const VmTest = Vm(null);

fn expectMatch(source: []const u8, input: []const u8, expected: InterpretResult) !void {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    try std.testing.expectEqual(expected, machine.match(source, input));
}

test "string literal matches input prefix" {
    try expectMatch("\"GET\"", "GET /", .ok);
}

test "string literal rejects non-matching input" {
    try expectMatch("\"GET\"", "POST /", .no_match);
}

test "string literal rejects input shorter than literal" {
    try expectMatch("\"GET\"", "GE", .no_match);
}

test "sequence of literals matches concatenation" {
    try expectMatch("\"GET\" \" \" \"/\"", "GET /", .ok);
}

test "sequence fails if any primary fails" {
    try expectMatch("\"GET\" \" \" \"/\"", "GET:/", .no_match);
}

test "character literal matches single byte" {
    try expectMatch("'a'", "abc", .ok);
}

test "character literal rejects wrong byte" {
    try expectMatch("'a'", "xbc", .no_match);
}

test "dot matches any single byte" {
    try expectMatch(".", "x", .ok);
}

test "dot fails on empty input" {
    try expectMatch(".", "", .no_match);
}

test "case-insensitive string matches regardless of case" {
    try expectMatch("i\"http\"", "HTTP/1.1", .ok);
    try expectMatch("i\"http\"", "http/1.1", .ok);
    try expectMatch("i\"http\"", "HtTp/1.1", .ok);
}

test "case-insensitive string rejects non-letters that differ" {
    try expectMatch("i\"a-b\"", "a_b", .no_match);
}

test "grouping compiles to the same code as the inner expression" {
    try expectMatch("(\"GET\")", "GET", .ok);
    try expectMatch("(\"GET\" \" \") \"/\"", "GET /", .ok);
}

test "charset matches a single character in range" {
    try expectMatch("['a'-'z']", "m", .ok);
}

test "charset rejects character outside range" {
    try expectMatch("['a'-'z']", "M", .no_match);
}

test "charset matches boundary characters" {
    try expectMatch("['a'-'z']", "a", .ok);
    try expectMatch("['a'-'z']", "z", .ok);
}

test "charset with multiple ranges" {
    try expectMatch("['a'-'z' '0'-'9']", "m", .ok);
    try expectMatch("['a'-'z' '0'-'9']", "5", .ok);
    try expectMatch("['a'-'z' '0'-'9']", "!", .no_match);
}

test "charset with single characters" {
    try expectMatch("['_']", "_", .ok);
    try expectMatch("['_']", "a", .no_match);
}

test "charset mixed ranges and singles" {
    try expectMatch("['a'-'z' '_' '0'-'9']", "_", .ok);
    try expectMatch("['a'-'z' '_' '0'-'9']", "x", .ok);
    try expectMatch("['a'-'z' '_' '0'-'9']", "7", .ok);
    try expectMatch("['a'-'z' '_' '0'-'9']", "!", .no_match);
}

test "charset fails on empty input" {
    try expectMatch("['a'-'z']", "", .no_match);
}

test "charset in sequence" {
    try expectMatch("['a'-'z'] ['0'-'9']", "a1", .ok);
    try expectMatch("['a'-'z'] ['0'-'9']", "1a", .no_match);
}

test "single rule declaration matches via auto-call" {
    try expectMatch("digit = ['0'-'9'];", "5", .ok);
}

test "single rule declaration rejects non-matching input" {
    try expectMatch("digit = ['0'-'9'];", "x", .no_match);
}

test "rule calling another rule" {
    try expectMatch("digit = ['0'-'9'];\ntwo_digits = digit digit;", "42", .ok);
}

test "rule calling another rule fails on short input" {
    try expectMatch("digit = ['0'-'9'];\ntwo_digits = digit digit;", "4", .no_match);
}

test "forward rule reference" {
    try expectMatch("pair = digit digit;\ndigit = ['0'-'9'];", "42", .ok);
}

test "undefined rule produces runtime error" {
    try expectMatch("bogus", "x", .runtime_error);
}

test "rule with sequence body" {
    try expectMatch(
        "http_ver = \"HTTP/\" ['0'-'9'] '.' ['0'-'9'];",
        "HTTP/1.1",
        .ok,
    );
}

test "empty program matches nothing" {
    try expectMatch("", "", .ok);
}

// -- Choice tests --

test "choice picks first matching alternative" {
    try expectMatch("\"GET\" / \"POST\"", "GET /", .ok);
}

test "choice falls back to second alternative" {
    try expectMatch("\"GET\" / \"POST\"", "POST /", .ok);
}

test "choice fails if no alternative matches" {
    try expectMatch("\"GET\" / \"POST\"", "DELETE /", .no_match);
}

test "choice restores position on backtrack" {
    // "GE" matches the first 2 bytes of "GET" but the full literal
    // "GEX" fails, so the parser must backtrack to pos 0 for "GET".
    try expectMatch("\"GEX\" / \"GET\"", "GET", .ok);
}

test "three-way choice" {
    try expectMatch("\"a\" / \"b\" / \"c\"", "a", .ok);
    try expectMatch("\"a\" / \"b\" / \"c\"", "b", .ok);
    try expectMatch("\"a\" / \"b\" / \"c\"", "c", .ok);
    try expectMatch("\"a\" / \"b\" / \"c\"", "d", .no_match);
}

test "choice with sequence: choice binds looser than sequence" {
    // "ab" / "cd" means ("ab") / ("cd"), not "a" ("b" / "c") "d"
    try expectMatch("'a' 'b' / 'c' 'd'", "ab", .ok);
    try expectMatch("'a' 'b' / 'c' 'd'", "cd", .ok);
    try expectMatch("'a' 'b' / 'c' 'd'", "ad", .no_match);
}

test "pipe is synonym for slash" {
    try expectMatch("\"GET\" | \"POST\"", "POST", .ok);
}

test "choice in rules" {
    try expectMatch(
        "method = \"GET\" / \"POST\" / \"PUT\";\nreq = method \" /\";",
        "PUT /",
        .ok,
    );
}

// -- Quantifier tests --

test "star matches zero occurrences" {
    try expectMatch("'a'*", "", .ok);
}

test "star matches multiple occurrences" {
    try expectMatch("'a'*", "aaaa", .ok);
}

test "star stops at non-matching byte" {
    try expectMatch("'a'* 'b'", "aaab", .ok);
}

test "plus requires at least one match" {
    try expectMatch("'a'+", "", .no_match);
}

test "plus matches one occurrence" {
    try expectMatch("'a'+", "a", .ok);
}

test "plus matches many occurrences" {
    try expectMatch("'a'+", "aaaa", .ok);
}

test "plus followed by literal" {
    try expectMatch("['0'-'9']+ '.'", "123.", .ok);
}

test "question matches zero occurrences" {
    try expectMatch("'a'? 'b'", "b", .ok);
}

test "question matches one occurrence" {
    try expectMatch("'a'? 'b'", "ab", .ok);
}

test "quantifier with charset" {
    try expectMatch("['a'-'z']+", "hello", .ok);
    try expectMatch("['a'-'z']+", "HELLO", .no_match);
}

test "quantifier in rule" {
    try expectMatch("digit = ['0'-'9'];\nnumber = digit+;", "42", .ok);
}

test "combined: choice and quantifiers" {
    try expectMatch(
        "alpha = ['a'-'z' 'A'-'Z'];\n" ++
            "digit = ['0'-'9'];\n" ++
            "ident = alpha (alpha / digit)*;",
        "foo123",
        .ok,
    );
}

test "combined: optional and sequence" {
    try expectMatch(
        "digit = ['0'-'9'];\n" ++
            "sign = '+' / '-';\n" ++
            "integer = sign? digit+;",
        "-42",
        .ok,
    );
}

test "combined: optional sign with unsigned" {
    try expectMatch(
        "digit = ['0'-'9'];\n" ++
            "sign = '+' / '-';\n" ++
            "integer = sign? digit+;",
        "42",
        .ok,
    );
}

test "left-recursive rule produces left-recursion error" {
    try expectMatch(
        "expr = expr \"+\" expr / ['0'-'9'];",
        "1+2",
        .runtime_error,
    );
}

test "mutual right-recursion through a dispatch rule is not flagged" {
    // A dispatches to B; B consumes a byte before calling A again.
    // No position is ever revisited by the same rule, so this must
    // parse cleanly rather than tripping left-recursion detection.
    try expectMatch(
        "A = B; B = 'x' A / 'y';",
        "xxy",
        .ok,
    );
}

test "where clause: sub-rule used in body" {
    try expectMatch(
        "x = y where y = \"y\" end;",
        "y",
        .ok,
    );
}

test "where clause: trailing semicolon on last sub-rule is optional" {
    try expectMatch(
        "x = y where y = \"y\"; end;",
        "y",
        .ok,
    );
}

test "where clause: multiple sub-rules" {
    try expectMatch(
        "kv = k \":\" v where k = ['a'-'z']+; v = ['0'-'9']+ end;",
        "abc:123",
        .ok,
    );
}

test "where clause: sub-rule references another sub-rule" {
    try expectMatch(
        "pair = a a where a = ['a'-'z'] end;",
        "xy",
        .ok,
    );
}

test "where clause: no semicolon after end is valid" {
    try expectMatch(
        "x = y where y = \"y\" end",
        "y",
        .ok,
    );
}

test "where clause: body not matched when sub-rule fails" {
    try expectMatch(
        "x = y where y = \"y\" end;",
        "z",
        .no_match,
    );
}

test "where clause: prior plain rule does not leak into scan" {
    // The pre-scan for where-bindings must stop at the current rule's
    // terminating ';'. Otherwise a trailing rule's where-block is
    // registered as locals of the preceding rule and surfaces as a
    // spurious "unused where-binding" error.
    try expectMatch(
        "a = \"a\"; x = y where y = \"y\" end;",
        "y",
        .ok,
    );
}

test "rules persist across REPL iterations" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();

    // First iteration: define a rule.
    const r1 = machine.match("digit = ['0'-'9'];", "5");
    try std.testing.expectEqual(.ok, r1);

    // Second iteration: call the rule by name.
    const r2 = machine.match("digit", "7");
    try std.testing.expectEqual(.ok, r2);

    // Third iteration: rule still available.
    const r3 = machine.match("digit digit", "42");
    try std.testing.expectEqual(.ok, r3);
}

test "capture records matched span" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match("<k: ['a'-'z']+>", "hello123");
    try std.testing.expectEqual(.ok, result);
    try std.testing.expectEqual(@as(usize, 0), machine.captures[0].start);
    try std.testing.expectEqual(@as(usize, 5), machine.captures[0].len);
}

test "captures in sequence get distinct slots" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match(
        "<k: ['a'-'z']+> \":\" <v: ['0'-'9']+>",
        "abc:123",
    );
    try std.testing.expectEqual(.ok, result);
    try std.testing.expectEqual(@as(usize, 0), machine.captures[0].start);
    try std.testing.expectEqual(@as(usize, 3), machine.captures[0].len);
    try std.testing.expectEqual(@as(usize, 4), machine.captures[1].start);
    try std.testing.expectEqual(@as(usize, 3), machine.captures[1].len);
}

test "capture wraps choice inside brackets" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const r1 = machine.match("<s: \"http\" / \"ftp\"> \"://\"", "http://");
    try std.testing.expectEqual(.ok, r1);
    try std.testing.expectEqual(@as(usize, 0), machine.captures[0].start);
    try std.testing.expectEqual(@as(usize, 4), machine.captures[0].len);
}

test "capture inside rule declaration" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match(
        "kv = <k: ['a'-'z']+> \"=\" <v: ['0'-'9']+>;",
        "abc=42",
    );
    try std.testing.expectEqual(.ok, result);
    try std.testing.expectEqual(@as(usize, 0), machine.captures[0].start);
    try std.testing.expectEqual(@as(usize, 3), machine.captures[0].len);
    try std.testing.expectEqual(@as(usize, 4), machine.captures[1].start);
    try std.testing.expectEqual(@as(usize, 2), machine.captures[1].len);
}

test "back-reference matches same text" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match("<w: ['a'-'z']+> \"-\" w", "abc-abc");
    try std.testing.expectEqual(.ok, result);
}

test "back-reference rejects different text" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match("<w: ['a'-'z']+> \"-\" w", "abc-xyz");
    try std.testing.expectEqual(.no_match, result);
}

test "capture survives backtracking in choice" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match(
        "(<k: \"ab\"> \"X\") / \"abc\"",
        "abc",
    );
    try std.testing.expectEqual(.ok, result);
}

test "negative lookahead passes when operand does not match" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match("!\"no\" ['a'-'z']+", "yes");
    try std.testing.expectEqual(.ok, result);
}

test "negative lookahead fails when operand matches" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match("!\"no\" ['a'-'z']+", "nope");
    try std.testing.expectEqual(.no_match, result);
}

test "negative lookahead does not consume input" {
    // If `!'a'` consumed input, the subsequent `'b'` would see the
    // second byte 'b' at position 1 instead of position 0 on a
    // non-matching case, or miss the 'b' on a matching case.
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const ok = machine.match("!\"a\" \"b\"", "b");
    try std.testing.expectEqual(.ok, ok);
}

test "keyword exclusion pattern with nested negative lookaheads" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();

    const source =
        "word = !keyword ident" ++
        "  where" ++
        "    keyword    = (\"if\" / \"else\") !ident_char;" ++
        "    ident      = ident_char+;" ++
        "    ident_char = ['a'-'z']" ++
        "  end";

    // Reserved keywords are rejected.
    try std.testing.expectEqual(.no_match, machine.match(source, "if"));
    try std.testing.expectEqual(.no_match, machine.match(source, "else"));
    // Identifiers that happen to start with a keyword still match,
    // because the trailing `!ident_char` rules them out as keywords.
    try std.testing.expectEqual(.ok, machine.match(source, "ifx"));
    try std.testing.expectEqual(.ok, machine.match(source, "elsewhere"));
    // Plain non-keyword identifiers match.
    try std.testing.expectEqual(.ok, machine.match(source, "hello"));
}

test "positive lookahead passes when operand matches, without consuming" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    // &"a" asserts 'a' at position 0, then 'a' consumes it.
    const result = machine.match("&\"a\" \"a\" \"b\"", "ab");
    try std.testing.expectEqual(.ok, result);
}

test "positive lookahead fails when operand does not match" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match("&\"a\" \"b\"", "b");
    try std.testing.expectEqual(.no_match, result);
}

test "bare cut prevents fallback to later alternative" {
    // Without cut, the first alt matches "A", "C" fails, backtrack tries
    // the second alt "A!" and succeeds. With cut, after "A" matches the
    // / frame is committed, so "C" failing cannot fall back to "A!".
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    try std.testing.expectEqual(.ok, machine.match("(\"A\" \"C\") / \"A!\"", "A!"));
    try std.testing.expectEqual(.no_match, machine.match("(\"A\" ^ \"C\") / \"A!\"", "A!"));
}

test "bare cut lets the matching first alternative succeed" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match("(\"A\" ^ \"C\") / \"D\"", "AC");
    try std.testing.expectEqual(.ok, result);
}

test "bare cut in second alternative is harmless when no / frame remains" {
    // After A fails and the / frame is popped, the cut in the second
    // alternative has no frame to commit. The match then depends only
    // on whether "B" and "C" succeed.
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    try std.testing.expectEqual(.ok, machine.match("\"A\" / \"B\" ^ \"C\"", "BC"));
    try std.testing.expectEqual(.no_match, machine.match("\"A\" / \"B\" ^ \"C\"", "BX"));
}

test "labelled cut raises runtime error on subsequent failure" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const source = "foo = \"if\" ^\"expected condition\" \"X\";";
    try std.testing.expectEqual(.runtime_error, machine.match(source, "if!"));
    try std.testing.expectEqual(.ok, machine.match(source, "ifX"));
}

test "labelled cut both prunes backtracking and carries the label" {
    // Baseline: without the cut, "X" failing backtracks to the second
    // alternative "A", which matches the 'A' byte and the match succeeds.
    // With the labelled cut, that fallback is pruned and the failure is
    // raised with the label instead — proving the label form also commits
    // the enclosing choice, not just records a message.
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    try std.testing.expectEqual(
        .ok,
        machine.match("foo = (\"A\" \"X\") / \"A\";", "AY"),
    );
    try std.testing.expectEqual(
        .runtime_error,
        machine.match("foo = (\"A\" ^\"need X\" \"X\") / \"A\";", "AY"),
    );
}

test "innermost labelled cut wins when failure propagates" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    // outer is declared last so it is auto-called as the entry point.
    const source =
        "inner = \"i\" ^\"inner label\" \"x\";" ++
        "outer = \"o\" ^\"outer label\" inner;";
    // Both cuts fire; failure inside inner is labelled with the inner
    // label because it is the innermost active rule.
    try std.testing.expectEqual(.runtime_error, machine.match(source, "oiZ"));
}

test "cut scope does not escape the current rule" {
    // If a cut in `inner` wrongly committed `entry`'s / frame, the
    // backtrack to the second alt on "A" failing would be suppressed
    // and the match would fail. The correct scoping keeps the outer /
    // available so "XY" (the second alt) matches.
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const source =
        "inner = \"X\" ^ \"Y\";" ++
        "entry = (inner \"A\") / \"XY\";";
    try std.testing.expectEqual(.ok, machine.match(source, "XY"));
}

test "cut inside negative lookahead is a compile error" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match("!(\"X\" ^ \"Y\")", "Z");
    try std.testing.expectEqual(.compile_error, result);
}

test "cut inside positive lookahead is a compile error" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match("&(\"X\" ^ \"Y\") \"X\"", "XY");
    try std.testing.expectEqual(.compile_error, result);
}

test "cut inside quantifier commits the inner choice" {
    // The cut sits in the first alternative of the inner choice. Once
    // "X" matches, the / frame is committed and the "Xb" fallback
    // becomes unreachable. Without the cut, input "Xb" would match via
    // the fallback; with the cut, "a" failing propagates and the whole
    // + fails on its first iteration.
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    try std.testing.expectEqual(.ok, machine.match("(\"X\" \"a\" / \"Xb\")+", "Xb"));
    try std.testing.expectEqual(.no_match, machine.match("(\"X\" ^ \"a\" / \"Xb\")+", "Xb"));
}

test "cut inside quantifier walks past the quant frame to commit an outer choice" {
    // The inner * body has no / of its own, so the cut must walk past
    // the quantifier's backtrack frame to reach the outer / frame. The
    // star iterates once (matching "x"), fails on "y", and unwinds to
    // the quant frame — the outer / survives on the stack because it
    // was merely tagged committed, not popped. After the star exits,
    // matching "Z" fails at pos 0 and propagates.
    //
    // Without the cut, that same failure backtracks into the outer /'s
    // second alternative ("x") and matches. With the cut, the outer /
    // is committed, so the second alt is unreachable and the match
    // fails. The two outcomes isolate the quant-skipping branch of
    // cutInnermostChoice: if a cut mistakenly committed the quant
    // frame, the star would never exit cleanly; if it failed to walk
    // past the quant to find the outer /, the baseline and cut cases
    // would be indistinguishable.
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    try std.testing.expectEqual(
        .ok,
        machine.match("(\"x\" \"y\")* \"Z\" / \"x\"", "x"),
    );
    try std.testing.expectEqual(
        .no_match,
        machine.match("(\"x\" ^ \"y\")* \"Z\" / \"x\"", "x"),
    );
}
