//! Symbol index over a pars source file, built by walking scanner
//! output with a small amount of context tracking. Independent of the
//! compiler so it works on grammars that fail to compile.
//!
//! Three kinds of occurrences are recorded:
//!
//!   * `RuleDef` — an identifier that appears on the left of `=`.
//!     Top-level declarations and where-block sub-rules are both
//!     definitions; `kind` distinguishes them. The `body` range covers
//!     the rule body from just after `=` to the terminating `;` or
//!     `end`, which is what hover renders.
//!
//!   * `Capture` — the name in `<name: expr>`. Detected by the
//!     preceding `<`. A capture's scope for back-reference lookup is
//!     the enclosing rule body, which we approximate as "the most
//!     recently opened rule that has not yet terminated".
//!
//!   * `RuleRef` — any other identifier that is not itself a
//!     definition or capture. `back_ref` is set when the name matches
//!     a capture already in scope, matching the compiler's
//!     op_match_backref behavior.
//!
//!   * `UseDecl` — a top-level `use "..."` import. The `path` is the
//!     module name with surrounding quotes stripped. Tracked so the
//!     LSP can resolve references that a grammar pulls in from the
//!     stdlib.

const std = @import("std");
const pars = @import("pars");

const Allocator = std.mem.Allocator;
const Scanner = pars.scanner.Scanner;
const Token = pars.scanner.Token;
const TokenType = pars.scanner.TokenType;
const stripStringDelimiters = pars.literal.stripStringDelimiters;

/// A span of source bytes plus the 0-based line/column of the first byte.
pub const Span = struct {
    start: usize,
    len: usize,
    line: u32,
    col: u32,
};

/// End position of a span, as 0-based line/column. Computed once so
/// the LSP layer does not need to re-walk the source per occurrence.
pub const End = struct {
    line: u32,
    col: u32,
};

pub const RuleKind = enum { top_level, sub_rule };

pub const RuleDef = struct {
    name: []const u8,
    name_span: Span,
    name_end: End,
    /// Byte range of the rule body (after the `=`, up to but not
    /// including the terminating `;` / `end`). Both ends are 0-based
    /// line/col for LSP consumption.
    body_start: usize,
    body_end: usize,
    body_start_line: u32,
    body_start_col: u32,
    body_end_line: u32,
    body_end_col: u32,
    kind: RuleKind,
};

pub const Capture = struct {
    name: []const u8,
    name_span: Span,
    name_end: End,
    /// Index into `Index.defs` of the rule that owns this capture's
    /// back-reference scope, or null if the capture is lexically
    /// outside any rule (malformed input).
    rule_index: ?u32,
};

pub const RuleRef = struct {
    name: []const u8,
    span: Span,
    end: End,
    /// True when the name resolves to a capture in scope rather than a
    /// top-level rule.
    back_ref: bool,
    /// Rule index of the enclosing rule body, for scope-aware lookup.
    rule_index: ?u32,
};

pub const UseDecl = struct {
    /// Module path as written in the source, with surrounding quotes
    /// stripped. Slices into the original source buffer.
    path: []const u8,
    /// Span of the path string literal (including its quotes).
    span: Span,
};

pub const Index = struct {
    defs: []RuleDef,
    captures: []Capture,
    refs: []RuleRef,
    uses: []UseDecl,

    pub fn deinit(self: *Index, alloc: Allocator) void {
        alloc.free(self.defs);
        alloc.free(self.captures);
        alloc.free(self.refs);
        alloc.free(self.uses);
    }

    /// Find the definition whose name span contains the cursor, or null.
    pub fn defAt(self: *const Index, line: u32, col: u32) ?usize {
        for (self.defs, 0..) |d, idx| {
            if (spanContains(d.name_span, d.name_end, line, col)) return idx;
        }
        return null;
    }

    /// Find the reference whose span contains the cursor, or null.
    pub fn refAt(self: *const Index, line: u32, col: u32) ?usize {
        for (self.refs, 0..) |r, idx| {
            if (spanContains(r.span, r.end, line, col)) return idx;
        }
        return null;
    }

    /// Find the capture whose name span contains the cursor, or null.
    pub fn captureAt(self: *const Index, line: u32, col: u32) ?usize {
        for (self.captures, 0..) |c, idx| {
            if (spanContains(c.name_span, c.name_end, line, col)) return idx;
        }
        return null;
    }

    /// Locate the first definition of the given name, preferring the
    /// caller's enclosing rule scope so that nested sub-rules win over
    /// top-level ones with the same name.
    pub fn findDef(self: *const Index, name: []const u8, prefer_rule: ?u32) ?usize {
        if (prefer_rule) |ri| {
            for (self.defs, 0..) |d, idx| {
                if (d.kind == .sub_rule and
                    idx > ri and // sub-rules appear after their parent
                    std.mem.eql(u8, d.name, name)) return idx;
            }
        }
        for (self.defs, 0..) |d, idx| {
            if (std.mem.eql(u8, d.name, name)) return idx;
        }
        return null;
    }

    /// Locate the first capture with the given name whose scope is the
    /// given rule.
    pub fn findCaptureInRule(self: *const Index, name: []const u8, rule_index: u32) ?usize {
        for (self.captures, 0..) |c, idx| {
            if (c.rule_index) |ri| {
                if (ri == rule_index and std.mem.eql(u8, c.name, name)) return idx;
            }
        }
        return null;
    }
};

fn spanContains(span: Span, end: End, line: u32, col: u32) bool {
    if (line < span.line or line > end.line) return false;
    if (line == span.line and col < span.col) return false;
    if (line == end.line and col > end.col) return false;
    return true;
}

const Builder = struct {
    alloc: Allocator,
    source: []const u8,
    tokens: []const Token,
    defs: std.ArrayList(RuleDef),
    captures: std.ArrayList(Capture),
    refs: std.ArrayList(RuleRef),
    uses: std.ArrayList(UseDecl),

    /// Rule-scope stack. Each entry is an index into `defs`; the top
    /// is the most recently opened rule whose body we are currently
    /// inside. Captures and references attribute to the top entry.
    rule_stack: std.ArrayList(u32),

    fn pushRule(self: *Builder, def: RuleDef) !void {
        const idx: u32 = @intCast(self.defs.items.len);
        try self.defs.append(self.alloc, def);
        try self.rule_stack.append(self.alloc, idx);
    }

    fn currentRule(self: *const Builder) ?u32 {
        if (self.rule_stack.items.len == 0) return null;
        return self.rule_stack.items[self.rule_stack.items.len - 1];
    }

    /// Close the currently open rule, recording its body end at the
    /// given terminator token.
    fn closeRule(self: *Builder, terminator: Token) void {
        if (self.rule_stack.items.len == 0) return;
        const idx = self.rule_stack.pop();
        if (idx) |i| {
            const d = &self.defs.items[i];
            d.body_end = terminator.start;
            const end = endOfOffset(self.source, terminator.start);
            d.body_end_line = end.line;
            d.body_end_col = end.col;
        }
    }
};

/// Build a symbol index over `source`. The returned slices are owned
/// by the caller and freed via `Index.deinit`.
pub fn buildIndex(alloc: Allocator, source: []const u8) !Index {
    // Collect tokens first so we can use one-token lookahead without
    // restarting the scanner. Grammar files are tiny in practice.
    var toks: std.ArrayList(Token) = .empty;
    defer toks.deinit(alloc);
    {
        var scanner = Scanner.init(source);
        while (true) {
            const t = scanner.scanToken();
            try toks.append(alloc, t);
            if (t.type == .eof) break;
        }
    }

    var b: Builder = .{
        .alloc = alloc,
        .source = source,
        .tokens = toks.items,
        .defs = .empty,
        .captures = .empty,
        .refs = .empty,
        .uses = .empty,
        .rule_stack = .empty,
    };
    defer b.rule_stack.deinit(alloc);
    errdefer {
        b.defs.deinit(alloc);
        b.captures.deinit(alloc);
        b.refs.deinit(alloc);
        b.uses.deinit(alloc);
    }

    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var expect_capture_name: bool = false;

    var i: usize = 0;
    while (i < b.tokens.len) : (i += 1) {
        const t = b.tokens[i];
        switch (t.type) {
            .eof => break,
            .left_paren => paren_depth += 1,
            .right_paren => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            .left_bracket => bracket_depth += 1,
            .right_bracket => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            .left_angle => expect_capture_name = true,
            .kw_use => {
                // `use "path";` — only valid at the top level. The next
                // token is the module path string. We record the path
                // (with quotes stripped) and its span, then let the
                // surrounding loop continue; the string token itself
                // has no other meaning to the index.
                if (b.rule_stack.items.len != 0) continue;
                if (i + 1 >= b.tokens.len) continue;
                const str_tok = b.tokens[i + 1];
                if (str_tok.type != .string) continue;
                // Strip the surrounding `"..."`. Triple-quoted strings
                // are legal syntactically but meaningless here; we
                // still handle them to avoid slicing into a delimiter.
                const inner = stripStringDelimiters(str_tok.lexeme, 0);
                const span: Span = .{
                    .start = str_tok.start,
                    .len = str_tok.len,
                    .line = @intCast(str_tok.line - 1),
                    .col = @intCast(str_tok.column - 1),
                };
                try b.uses.append(b.alloc, .{ .path = inner, .span = span });
                i += 1; // consume the string token
            },
            .semicolon => {
                // A `;` at the outermost paren/bracket level that is
                // also directly inside a rule body terminates that rule.
                // A `;` inside a where sub-rule terminates the sub-rule.
                if (paren_depth == 0 and bracket_depth == 0) {
                    b.closeRule(t);
                }
            },
            .kw_end => {
                // `end` closes the where block and the enclosing rule
                // (the outer rule), so pop two entries if present. If
                // there is only one open rule (malformed — a bare
                // `end`), just pop it.
                if (b.rule_stack.items.len > 0) {
                    b.closeRule(t);
                }
                if (b.rule_stack.items.len > 0) {
                    b.closeRule(t);
                }
            },
            .identifier => {
                if (expect_capture_name) {
                    // `<` immediately preceded this identifier → capture name.
                    expect_capture_name = false;
                    const span: Span = .{
                        .start = t.start,
                        .len = t.len,
                        .line = @intCast(t.line - 1),
                        .col = @intCast(t.column - 1),
                    };
                    const end = endOfSpan(b.source, span);
                    try b.captures.append(b.alloc, .{
                        .name = t.lexeme,
                        .name_span = span,
                        .name_end = end,
                        .rule_index = b.currentRule(),
                    });
                    continue;
                }

                if (bracket_depth > 0) continue; // paranoia; not valid pars

                // Distinguish definition from reference by peeking at
                // the next token. The scanner already skipped any
                // whitespace or comments between them.
                const next_ty: ?TokenType = if (i + 1 < b.tokens.len) b.tokens[i + 1].type else null;
                if (next_ty == .equal) {
                    const name_span: Span = .{
                        .start = t.start,
                        .len = t.len,
                        .line = @intCast(t.line - 1),
                        .col = @intCast(t.column - 1),
                    };
                    const name_end = endOfSpan(b.source, name_span);

                    // Body starts right after `=` + whitespace. We use
                    // the token *after* `=` as the body start, which
                    // skips leading whitespace naturally.
                    const eq_tok = b.tokens[i + 1];
                    const body_first_tok_idx = i + 2;
                    const body_start: usize = if (body_first_tok_idx < b.tokens.len)
                        b.tokens[body_first_tok_idx].start
                    else
                        eq_tok.start + eq_tok.len;
                    const body_start_pos = endOfOffset(b.source, body_start);

                    const kind: RuleKind = if (b.rule_stack.items.len > 0) .sub_rule else .top_level;

                    try b.pushRule(.{
                        .name = t.lexeme,
                        .name_span = name_span,
                        .name_end = name_end,
                        .body_start = body_start,
                        .body_end = body_start,
                        .body_start_line = body_start_pos.line,
                        .body_start_col = body_start_pos.col,
                        .body_end_line = body_start_pos.line,
                        .body_end_col = body_start_pos.col,
                        .kind = kind,
                    });
                    // Consume the `=` so we don't revisit it.
                    i += 1;
                    continue;
                }

                // Plain reference. Mark back_ref if the name matches a
                // capture in the current rule scope.
                const rule_idx = b.currentRule();
                const span: Span = .{
                    .start = t.start,
                    .len = t.len,
                    .line = @intCast(t.line - 1),
                    .col = @intCast(t.column - 1),
                };
                const end = endOfSpan(b.source, span);
                var is_back_ref = false;
                if (rule_idx) |ri| {
                    for (b.captures.items) |c| {
                        if (c.rule_index) |c_ri| {
                            if (c_ri == ri and std.mem.eql(u8, c.name, t.lexeme)) {
                                is_back_ref = true;
                                break;
                            }
                        }
                    }
                }
                try b.refs.append(b.alloc, .{
                    .name = t.lexeme,
                    .span = span,
                    .end = end,
                    .back_ref = is_back_ref,
                    .rule_index = rule_idx,
                });
            },
            else => {},
        }
    }

    // Any rules still open at EOF (malformed input) get their body_end
    // clamped to the source length so hover still renders something.
    while (b.rule_stack.items.len > 0) {
        const idx = b.rule_stack.pop().?;
        const d = &b.defs.items[idx];
        d.body_end = b.source.len;
        const end = endOfOffset(b.source, b.source.len);
        d.body_end_line = end.line;
        d.body_end_col = end.col;
    }

    return .{
        .defs = try b.defs.toOwnedSlice(alloc),
        .captures = try b.captures.toOwnedSlice(alloc),
        .refs = try b.refs.toOwnedSlice(alloc),
        .uses = try b.uses.toOwnedSlice(alloc),
    };
}

fn endOfSpan(source: []const u8, span: Span) End {
    return endOfOffset(source, span.start + span.len);
}

fn endOfOffset(source: []const u8, offset: usize) End {
    const stop = @min(source.len, offset);
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < stop) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .col = @intCast(stop - line_start) };
}

test "buildIndex: top-level rule" {
    const alloc = std.testing.allocator;
    var idx = try buildIndex(alloc, "foo = bar;");
    defer idx.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), idx.defs.len);
    try std.testing.expectEqualStrings("foo", idx.defs[0].name);
    try std.testing.expectEqual(RuleKind.top_level, idx.defs[0].kind);
    try std.testing.expectEqual(@as(u32, 0), idx.defs[0].name_span.line);
    try std.testing.expectEqual(@as(u32, 0), idx.defs[0].name_span.col);

    try std.testing.expectEqual(@as(usize, 1), idx.refs.len);
    try std.testing.expectEqualStrings("bar", idx.refs[0].name);
    try std.testing.expect(!idx.refs[0].back_ref);
}

test "buildIndex: sub-rule in where block" {
    const alloc = std.testing.allocator;
    const src =
        \\outer = sub
        \\  where
        \\    sub = 'x'
        \\  end
    ;
    var idx = try buildIndex(alloc, src);
    defer idx.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), idx.defs.len);
    try std.testing.expectEqualStrings("outer", idx.defs[0].name);
    try std.testing.expectEqual(RuleKind.top_level, idx.defs[0].kind);
    try std.testing.expectEqualStrings("sub", idx.defs[1].name);
    try std.testing.expectEqual(RuleKind.sub_rule, idx.defs[1].kind);
}

test "buildIndex: capture and back-reference" {
    const alloc = std.testing.allocator;
    var idx = try buildIndex(alloc, "r = <q: 'a'> q;");
    defer idx.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), idx.captures.len);
    try std.testing.expectEqualStrings("q", idx.captures[0].name);

    // The trailing `q` should be flagged as a back-reference.
    try std.testing.expectEqual(@as(usize, 1), idx.refs.len);
    try std.testing.expectEqualStrings("q", idx.refs[0].name);
    try std.testing.expect(idx.refs[0].back_ref);
}

test "buildIndex: capture not shadowing ref in another rule" {
    const alloc = std.testing.allocator;
    const src =
        \\a = <q: 'a'> q;
        \\b = q;
    ;
    var idx = try buildIndex(alloc, src);
    defer idx.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), idx.refs.len);
    // First q is a back-ref in rule a.
    try std.testing.expect(idx.refs[0].back_ref);
    // Second q is a plain reference in rule b (no capture in scope).
    try std.testing.expect(!idx.refs[1].back_ref);
}

test "buildIndex: malformed input does not crash" {
    const alloc = std.testing.allocator;
    var idx = try buildIndex(alloc, "rule = ");
    defer idx.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), idx.defs.len);
    try std.testing.expectEqualStrings("rule", idx.defs[0].name);
}

test "buildIndex: body span covers whole rule body" {
    const alloc = std.testing.allocator;
    const src = "foo = bar baz;";
    var idx = try buildIndex(alloc, src);
    defer idx.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), idx.defs.len);
    const d = idx.defs[0];
    try std.testing.expectEqualStrings("bar baz", src[d.body_start..d.body_end]);
}

test "buildIndex: use declaration is recorded" {
    const alloc = std.testing.allocator;
    const src =
        \\use "std/abnf";
        \\foo = DIGIT;
    ;
    var idx = try buildIndex(alloc, src);
    defer idx.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), idx.uses.len);
    try std.testing.expectEqualStrings("std/abnf", idx.uses[0].path);
}

test "Index.findDef prefers sub-rule in same scope" {
    const alloc = std.testing.allocator;
    const src =
        \\foo = sub
        \\  where
        \\    sub = 'x'
        \\  end
        \\sub = 'y';
    ;
    var idx = try buildIndex(alloc, src);
    defer idx.deinit(alloc);

    // Calling from inside rule 0, the sub-rule (idx 1) should win.
    const hit = idx.findDef("sub", 0).?;
    try std.testing.expectEqual(@as(usize, 1), hit);
    try std.testing.expectEqual(RuleKind.sub_rule, idx.defs[hit].kind);
}
