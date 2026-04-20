//! ABNF parser. Produces a typed AST from ABNF source text covering
//! RFC 5234 §4 plus the %s / %i prefix extension from RFC 7405.
//!
//! Source spans are preserved for span-accurate diagnostics after
//! lowering. The lowering pass itself — ABNF AST to pars source text
//! plus a back-map — lives in a companion module.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Byte-offset span into the ABNF source.
pub const Span = struct {
    start: u32,
    len: u32,

    pub fn end(self: Span) u32 {
        return self.start + self.len;
    }
};

pub const Rule = struct {
    /// Rulename as written, hyphens preserved. Lowering mangles them.
    name: []const u8,
    name_span: Span,
    /// True iff the defined-as operator was `=/` (incremental alt).
    incremental: bool,
    body: Alternation,
    span: Span,
};

pub const Alternation = struct {
    arms: []const Concatenation,
    span: Span,
};

pub const Concatenation = struct {
    items: []const Repetition,
    span: Span,
};

pub const Repetition = struct {
    repeat: Repeat,
    element: Element,
    span: Span,
};

pub const Repeat = union(enum) {
    /// No repeat prefix; the element matches exactly once.
    none,
    /// `nA` — exactly n.
    exact: u32,
    /// `n*mA` — between n and m inclusive.
    bounded: struct { min: u32, max: u32 },
    /// `n*A` — at least n.
    at_least: u32,
    /// `*mA` — at most m (0 to m).
    at_most: u32,
    /// `*A` — zero or more.
    unbounded,
};

pub const Element = union(enum) {
    rulename: RuleRef,
    group: *const Alternation,
    option: *const Alternation,
    string_val: StringVal,
    num_val: NumVal,
    prose_val: Span,
};

pub const RuleRef = struct {
    name: []const u8,
    span: Span,
};

pub const StringVal = struct {
    /// Bytes between the surrounding double-quotes (exclusive).
    raw: []const u8,
    /// True iff prefixed with `%s` (RFC 7405 case-sensitive).
    case_sensitive: bool,
    span: Span,
};

pub const NumValKind = enum { single, range, concat };
pub const NumBase = enum { bin, dec, hex };

pub const NumVal = struct {
    kind: NumValKind,
    base: NumBase,
    /// Decoded integer values. For `single`: one entry. For `range`:
    /// two entries (low, high). For `concat`: one or more entries in
    /// source order.
    values: []const u32,
    span: Span,
};

pub const ParseError = struct {
    message: []const u8,
    span: Span,
};

pub const ParseResult = struct {
    rulelist: []const Rule,
    errors: []const ParseError,

    pub fn ok(self: ParseResult) bool {
        return self.errors.len == 0;
    }
};

pub const Parser = struct {
    source: []const u8,
    pos: u32,
    arena: std.heap.ArenaAllocator,
    errors: std.ArrayList(ParseError),

    pub fn init(gpa: Allocator, source: []const u8) Parser {
        return .{
            .source = source,
            .pos = 0,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .errors = .empty,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    /// Parse the entire source as a rulelist. The returned slice and
    /// every string/slice reachable from it is owned by the parser's
    /// internal arena.
    pub fn parse(self: *Parser) !ParseResult {
        const alloc = self.arena.allocator();
        var rules: std.ArrayList(Rule) = .empty;

        self.skipInterRuleSpace();
        while (!self.isAtEnd()) {
            const rule = self.parseRule() orelse {
                // An unrecoverable error was reported by parseRule or a
                // callee; skip to the next plausible rule start to
                // continue surfacing errors.
                self.recoverToNextLine();
                self.skipInterRuleSpace();
                continue;
            };
            try rules.append(alloc, rule);
            self.skipInterRuleSpace();
        }

        return .{
            .rulelist = try rules.toOwnedSlice(alloc),
            .errors = try self.errors.toOwnedSlice(alloc),
        };
    }

    fn isAtEnd(self: *const Parser) bool {
        return self.pos >= self.source.len;
    }

    fn peek(self: *const Parser) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.pos];
    }

    fn peekAt(self: *const Parser, off: u32) u8 {
        const idx = self.pos + off;
        if (idx >= self.source.len) return 0;
        return self.source[idx];
    }

    fn advance(self: *Parser) u8 {
        const c = self.source[self.pos];
        self.pos += 1;
        return c;
    }

    fn match(self: *Parser, c: u8) bool {
        if (self.peek() != c) return false;
        self.pos += 1;
        return true;
    }

    fn spanFrom(self: *const Parser, start: u32) Span {
        return .{ .start = start, .len = self.pos - start };
    }

    fn reportAt(self: *Parser, span: Span, message: []const u8) void {
        self.errors.append(self.arena.allocator(), .{
            .message = message,
            .span = span,
        }) catch {};
    }

    fn reportHere(self: *Parser, message: []const u8) void {
        const span = Span{ .start = self.pos, .len = if (self.isAtEnd()) 0 else 1 };
        self.reportAt(span, message);
    }

    fn isWsp(c: u8) bool {
        return c == ' ' or c == '\t';
    }

    fn isEolStart(c: u8) bool {
        return c == '\r' or c == '\n';
    }

    fn atEol(self: *const Parser) bool {
        return isEolStart(self.peek());
    }

    /// Consume a single end-of-line sequence (CRLF or bare LF/CR).
    /// Returns true if one was consumed.
    fn consumeEol(self: *Parser) bool {
        if (self.peek() == '\r') {
            self.pos += 1;
            if (self.peek() == '\n') self.pos += 1;
            return true;
        }
        if (self.peek() == '\n') {
            self.pos += 1;
            return true;
        }
        return false;
    }

    /// `;` to end of line, including the line terminator.
    fn consumeComment(self: *Parser) bool {
        if (self.peek() != ';') return false;
        self.pos += 1;
        while (!self.isAtEnd() and !self.atEol()) self.pos += 1;
        _ = self.consumeEol();
        return true;
    }

    /// Consume one `c-wsp` as defined by RFC 5234: either a single WSP
    /// or a c-nl followed by a WSP (continuation). Returns true if one
    /// was consumed.
    ///
    /// The RFC's continuation rule is greedy — any indented next line
    /// technically continues the current rule. In practice, ABNF
    /// authors delimit rules visually by un-indenting new rule names,
    /// and expect an indented `<name> =` line to start a new rule,
    /// not extend the previous one. We enforce that expectation by
    /// peeking past the indent: if the next non-WSP character is a
    /// rule head (identifier followed by `=`), the consumption is
    /// rolled back and the caller is told no continuation occurred.
    fn consumeCwsp(self: *Parser) bool {
        if (isWsp(self.peek())) {
            self.pos += 1;
            return true;
        }
        // Try c-nl + WSP as a continuation.
        const save = self.pos;
        if (self.consumeComment() or self.consumeEol()) {
            if (isWsp(self.peek())) {
                // Look past the indent: if the first non-WSP token
                // looks like a rule definition, treat the newline as a
                // rule boundary, not a continuation.
                var p = self.pos;
                while (p < self.source.len and isWsp(self.source[p])) p += 1;
                if (looksLikeRuleHead(self.source, p)) {
                    self.pos = save;
                    return false;
                }
                self.pos += 1;
                return true;
            }
            // Not a continuation — rewind so the outer caller can treat
            // the newline as a rule terminator.
            self.pos = save;
        }
        return false;
    }

    fn skipCwsp(self: *Parser) void {
        while (self.consumeCwsp()) {}
    }

    /// Space between rules. Unlike `consumeCwsp`, this does not apply
    /// the rule-head rewind heuristic — it is used at the top level
    /// when we are already between rules and just need to skip to the
    /// next potential rule start.
    fn skipInterRuleSpace(self: *Parser) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            if (c == ' ' or c == '\t') {
                self.pos += 1;
                continue;
            }
            if (c == '\r' or c == '\n') {
                _ = self.consumeEol();
                continue;
            }
            if (c == ';') {
                _ = self.consumeComment();
                continue;
            }
            break;
        }
    }

    /// Skip forward to the next line start for error recovery.
    fn recoverToNextLine(self: *Parser) void {
        while (!self.isAtEnd() and !self.atEol()) self.pos += 1;
        _ = self.consumeEol();
    }

    fn parseRule(self: *Parser) ?Rule {
        const start = self.pos;
        const name_ref = self.parseRulename() orelse {
            self.reportHere("Expected a rule name.");
            return null;
        };

        self.skipCwsp();
        const incremental = blk: {
            if (self.peek() == '=' and self.peekAt(1) == '/') {
                self.pos += 2;
                break :blk true;
            }
            if (self.match('=')) break :blk false;
            self.reportHere("Expected '=' or '=/' after rule name.");
            return null;
        };
        self.skipCwsp();

        const body = self.parseAlternation() orelse {
            return null;
        };

        // After the rule body, `c-wsp` may have trailing whitespace
        // before the terminating c-nl. Consume horizontal whitespace so
        // a stray comment on the same line is handled cleanly.
        while (isWsp(self.peek())) self.pos += 1;
        // The rule ends at end-of-line (or EOF). A comment-on-its-own
        // or an actual line break both count; skipInterRuleSpace will
        // consume them after the rule returns.

        return .{
            .name = name_ref.name,
            .name_span = name_ref.span,
            .incremental = incremental,
            .body = body,
            .span = self.spanFrom(start),
        };
    }

    fn parseRulename(self: *Parser) ?RuleRef {
        const start = self.pos;
        if (!isAlpha(self.peek())) return null;
        self.pos += 1;
        while (isAlpha(self.peek()) or isDigit(self.peek()) or self.peek() == '-') self.pos += 1;
        const span = self.spanFrom(start);
        return .{ .name = self.source[span.start..span.end()], .span = span };
    }

    fn parseAlternation(self: *Parser) ?Alternation {
        const alloc = self.arena.allocator();
        const start = self.pos;
        var arms: std.ArrayList(Concatenation) = .empty;

        const first = self.parseConcatenation() orelse return null;
        arms.append(alloc, first) catch return null;

        while (true) {
            const save = self.pos;
            self.skipCwsp();
            if (self.peek() != '/') {
                self.pos = save;
                break;
            }
            self.pos += 1;
            self.skipCwsp();
            const arm = self.parseConcatenation() orelse {
                // `/` with no valid concatenation after it. Report and
                // stop building arms, but return what we have so the
                // enclosing rule can still be assembled.
                self.reportHere("Expected an alternative after '/'.");
                break;
            };
            arms.append(alloc, arm) catch break;
        }

        return .{
            .arms = arms.toOwnedSlice(alloc) catch return null,
            .span = self.spanFrom(start),
        };
    }

    fn parseConcatenation(self: *Parser) ?Concatenation {
        const alloc = self.arena.allocator();
        const start = self.pos;
        var items: std.ArrayList(Repetition) = .empty;

        const first = self.parseRepetition() orelse return null;
        items.append(alloc, first) catch return null;

        while (true) {
            const save = self.pos;
            // A concatenation-continuation requires at least one c-wsp.
            if (!self.consumeCwsp()) break;
            self.skipCwsp();
            // Stop at any token that cannot begin a repetition, so the
            // alternation or parent group can pick up.
            if (self.peekStartsRepetition()) {
                const item = self.parseRepetition() orelse {
                    self.pos = save;
                    break;
                };
                items.append(alloc, item) catch break;
            } else {
                self.pos = save;
                break;
            }
        }

        return .{
            .items = items.toOwnedSlice(alloc) catch return null,
            .span = self.spanFrom(start),
        };
    }

    fn peekStartsRepetition(self: *const Parser) bool {
        const c = self.peek();
        if (isDigit(c) or c == '*') return true;
        return self.peekStartsElement();
    }

    fn peekStartsElement(self: *const Parser) bool {
        const c = self.peek();
        if (isAlpha(c)) return true;
        return switch (c) {
            '(', '[', '"', '%', '<' => true,
            else => false,
        };
    }

    fn parseRepetition(self: *Parser) ?Repetition {
        const start = self.pos;
        const repeat = self.parseRepeat();
        const element = self.parseElement() orelse {
            // If we consumed a repeat prefix but no element follows, the
            // rewind would be cleaner — but we've already errored, so
            // just report and bail.
            if (!std.meta.eql(repeat, Repeat.none)) {
                self.reportHere("Expected an element after repeat prefix.");
            }
            return null;
        };
        return .{
            .repeat = repeat,
            .element = element,
            .span = self.spanFrom(start),
        };
    }

    fn parseRepeat(self: *Parser) Repeat {
        const save = self.pos;
        // Form: DIGIT* '*' DIGIT*  or  DIGIT+
        if (isDigit(self.peek())) {
            const n_start = self.pos;
            while (isDigit(self.peek())) self.pos += 1;
            const n = parseUintSlice(self.source[n_start..self.pos]) orelse {
                // Too large; treat as no-repeat and let later logic
                // surface a diagnostic. Safe because the bytes will be
                // consumed as a bare number, which isn't valid element
                // syntax — parseElement will reject it.
                self.pos = save;
                return .none;
            };
            if (self.match('*')) {
                if (isDigit(self.peek())) {
                    const m_start = self.pos;
                    while (isDigit(self.peek())) self.pos += 1;
                    const m = parseUintSlice(self.source[m_start..self.pos]) orelse {
                        self.pos = save;
                        return .none;
                    };
                    return .{ .bounded = .{ .min = n, .max = m } };
                }
                return .{ .at_least = n };
            }
            return .{ .exact = n };
        }
        if (self.match('*')) {
            if (isDigit(self.peek())) {
                const m_start = self.pos;
                while (isDigit(self.peek())) self.pos += 1;
                const m = parseUintSlice(self.source[m_start..self.pos]) orelse {
                    self.pos = save;
                    return .none;
                };
                return .{ .at_most = m };
            }
            return .unbounded;
        }
        return .none;
    }

    fn parseElement(self: *Parser) ?Element {
        const c = self.peek();
        if (isAlpha(c)) {
            const r = self.parseRulename() orelse return null;
            return .{ .rulename = r };
        }
        switch (c) {
            '(' => return self.parseGroup('(', ')', .group),
            '[' => return self.parseGroup('[', ']', .option),
            '"' => return self.parseStringVal(false, 0),
            '%' => return self.parsePercent(),
            '<' => return self.parseProseVal(),
            else => return null,
        }
    }

    const GroupKind = enum { group, option };

    fn parseGroup(self: *Parser, open: u8, close: u8, kind: GroupKind) ?Element {
        const alloc = self.arena.allocator();
        const start = self.pos;
        std.debug.assert(self.peek() == open);
        self.pos += 1;
        self.skipCwsp();
        const body = self.parseAlternation() orelse {
            self.reportAt(self.spanFrom(start), "Empty group or option.");
            return null;
        };
        self.skipCwsp();
        if (!self.match(close)) {
            self.reportHere(if (kind == .group)
                "Expected ')' to close a group."
            else
                "Expected ']' to close an option.");
            return null;
        }
        const body_ptr = alloc.create(Alternation) catch return null;
        body_ptr.* = body;
        return switch (kind) {
            .group => .{ .group = body_ptr },
            .option => .{ .option = body_ptr },
        };
    }

    fn parseStringVal(self: *Parser, case_sensitive: bool, prefix_len: u32) ?Element {
        const start = self.pos - prefix_len;
        std.debug.assert(self.peek() == '"');
        self.pos += 1;
        const body_start = self.pos;
        while (!self.isAtEnd() and self.peek() != '"') {
            const c = self.peek();
            // RFC 5234: quoted string body is %x20-21 / %x23-7E (printable
            // ASCII excluding the quote). Accept liberally for now and
            // let the lowering decide; reject only obvious control bytes
            // that would confuse diagnostics.
            if (c == '\r' or c == '\n') {
                self.reportHere("String literal may not contain a newline.");
                return null;
            }
            self.pos += 1;
        }
        if (!self.match('"')) {
            self.reportHere("Unterminated string literal.");
            return null;
        }
        const body_end = self.pos - 1;
        return .{ .string_val = .{
            .raw = self.source[body_start..body_end],
            .case_sensitive = case_sensitive,
            .span = self.spanFrom(start),
        } };
    }

    /// `%s"…"`, `%i"…"`, `%b…`, `%d…`, `%x…`. Caller has verified
    /// `peek() == '%'` but not yet advanced.
    fn parsePercent(self: *Parser) ?Element {
        std.debug.assert(self.peek() == '%');
        self.pos += 1;
        const tag = self.peek();
        switch (tag) {
            's', 'i' => {
                self.pos += 1;
                const cs = (tag == 's');
                if (self.peek() != '"') {
                    self.reportHere("Expected '\"' after '%s' or '%i'.");
                    return null;
                }
                return self.parseStringVal(cs, 2);
            },
            'b' => return self.parseNumVal(.bin, isBit, 2),
            'd' => return self.parseNumVal(.dec, isDigit, 10),
            'x' => return self.parseNumVal(.hex, isHexDigit, 16),
            else => {
                self.reportHere("Unknown '%' prefix; expected 's', 'i', 'b', 'd', or 'x'.");
                return null;
            },
        }
    }

    fn parseNumVal(
        self: *Parser,
        base: NumBase,
        comptime isDigitFn: fn (u8) bool,
        comptime radix: u8,
    ) ?Element {
        const alloc = self.arena.allocator();
        const start = self.pos - 1; // include the leading '%'
        std.debug.assert(isAlpha(self.peek()));
        self.pos += 1; // consume the base letter

        const first = self.readDigits(isDigitFn, radix) orelse {
            self.reportHere("Expected digits in numeric value.");
            return null;
        };

        if (self.peek() == '-') {
            self.pos += 1;
            const hi = self.readDigits(isDigitFn, radix) orelse {
                self.reportHere("Expected digits after '-' in numeric range.");
                return null;
            };
            const values = alloc.alloc(u32, 2) catch return null;
            values[0] = first;
            values[1] = hi;
            return .{ .num_val = .{
                .kind = .range,
                .base = base,
                .values = values,
                .span = self.spanFrom(start),
            } };
        }

        if (self.peek() == '.') {
            var list: std.ArrayList(u32) = .empty;
            list.append(alloc, first) catch return null;
            while (self.peek() == '.') {
                self.pos += 1;
                const v = self.readDigits(isDigitFn, radix) orelse {
                    self.reportHere("Expected digits after '.' in numeric concat.");
                    return null;
                };
                list.append(alloc, v) catch return null;
            }
            return .{ .num_val = .{
                .kind = .concat,
                .base = base,
                .values = list.toOwnedSlice(alloc) catch return null,
                .span = self.spanFrom(start),
            } };
        }

        const values = alloc.alloc(u32, 1) catch return null;
        values[0] = first;
        return .{ .num_val = .{
            .kind = .single,
            .base = base,
            .values = values,
            .span = self.spanFrom(start),
        } };
    }

    fn readDigits(self: *Parser, comptime isDigitFn: fn (u8) bool, comptime radix: u8) ?u32 {
        const start = self.pos;
        while (isDigitFn(self.peek())) self.pos += 1;
        if (self.pos == start) return null;
        const slice = self.source[start..self.pos];
        var v: u64 = 0;
        for (slice) |c| {
            const d: u64 = std.fmt.charToDigit(c, radix) catch return null;
            v = v * radix + d;
            if (v > std.math.maxInt(u32)) return null;
        }
        return @intCast(v);
    }

    fn parseProseVal(self: *Parser) ?Element {
        const start = self.pos;
        std.debug.assert(self.peek() == '<');
        self.pos += 1;
        while (!self.isAtEnd() and self.peek() != '>') {
            const c = self.peek();
            if (c == '\r' or c == '\n') {
                self.reportHere("Prose-val may not contain a newline.");
                return null;
            }
            self.pos += 1;
        }
        if (!self.match('>')) {
            self.reportHere("Unterminated prose-val.");
            return null;
        }
        return .{ .prose_val = self.spanFrom(start) };
    }
};

fn isAlpha(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

/// Heuristic: does `source[start..]` look like the start of a new rule
/// declaration (`rulename [WSP] =`)? Used to disambiguate whether an
/// indented next line is a concatenation-continuation of the previous
/// rule body or the start of a new rule.
fn looksLikeRuleHead(source: []const u8, start: usize) bool {
    var p = start;
    if (p >= source.len or !isAlpha(source[p])) return false;
    while (p < source.len and (isAlpha(source[p]) or isDigit(source[p]) or source[p] == '-')) p += 1;
    while (p < source.len and (source[p] == ' ' or source[p] == '\t')) p += 1;
    if (p >= source.len) return false;
    return source[p] == '=';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'A' and c <= 'F') or (c >= 'a' and c <= 'f');
}

fn isBit(c: u8) bool {
    return c == '0' or c == '1';
}

fn parseUintSlice(slice: []const u8) ?u32 {
    return std.fmt.parseInt(u32, slice, 10) catch null;
}

test "parse: empty source yields empty rulelist" {
    var p = Parser.init(std.testing.allocator, "");
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expectEqual(@as(usize, 0), r.rulelist.len);
    try std.testing.expectEqual(@as(usize, 0), r.errors.len);
}

test "parse: single simple rule" {
    var p = Parser.init(std.testing.allocator, "foo = \"bar\"\n");
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(r.ok());
    try std.testing.expectEqual(@as(usize, 1), r.rulelist.len);
    try std.testing.expectEqualStrings("foo", r.rulelist[0].name);
    try std.testing.expect(!r.rulelist[0].incremental);
    try std.testing.expectEqual(@as(usize, 1), r.rulelist[0].body.arms.len);
}

test "parse: hyphenated rule name is preserved verbatim" {
    var p = Parser.init(std.testing.allocator, "hier-part = \"x\"\n");
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(r.ok());
    try std.testing.expectEqualStrings("hier-part", r.rulelist[0].name);
}

test "parse: incremental alternative with =/" {
    var p = Parser.init(std.testing.allocator,
        \\foo = "a"
        \\foo =/ "b"
        \\
    );
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(r.ok());
    try std.testing.expectEqual(@as(usize, 2), r.rulelist.len);
    try std.testing.expect(!r.rulelist[0].incremental);
    try std.testing.expect(r.rulelist[1].incremental);
}

test "parse: alternation has multiple arms" {
    var p = Parser.init(std.testing.allocator, "x = \"a\" / \"b\" / \"c\"\n");
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(r.ok());
    try std.testing.expectEqual(@as(usize, 3), r.rulelist[0].body.arms.len);
}

test "parse: concatenation collects multiple elements" {
    var p = Parser.init(std.testing.allocator, "x = \"a\" \"b\" \"c\"\n");
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(r.ok());
    const arm = r.rulelist[0].body.arms[0];
    try std.testing.expectEqual(@as(usize, 3), arm.items.len);
}

test "parse: repeat variants" {
    var p = Parser.init(std.testing.allocator,
        \\a = 3DIGIT
        \\b = 2*5DIGIT
        \\c = 1*DIGIT
        \\d = *5DIGIT
        \\e = *DIGIT
        \\
    );
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(r.ok());
    try std.testing.expectEqual(Repeat{ .exact = 3 }, r.rulelist[0].body.arms[0].items[0].repeat);
    try std.testing.expectEqual(Repeat{ .bounded = .{ .min = 2, .max = 5 } }, r.rulelist[1].body.arms[0].items[0].repeat);
    try std.testing.expectEqual(Repeat{ .at_least = 1 }, r.rulelist[2].body.arms[0].items[0].repeat);
    try std.testing.expectEqual(Repeat{ .at_most = 5 }, r.rulelist[3].body.arms[0].items[0].repeat);
    try std.testing.expectEqual(Repeat.unbounded, r.rulelist[4].body.arms[0].items[0].repeat);
}

test "parse: group and option" {
    var p = Parser.init(std.testing.allocator, "x = (\"a\" / \"b\") [\"c\"]\n");
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(r.ok());
    const items = r.rulelist[0].body.arms[0].items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expect(items[0].element == .group);
    try std.testing.expect(items[1].element == .option);
}

test "parse: num-val single, range, concat" {
    var p = Parser.init(std.testing.allocator,
        \\a = %x41
        \\b = %x30-39
        \\c = %x41.42.43
        \\
    );
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(r.ok());
    const a = r.rulelist[0].body.arms[0].items[0].element.num_val;
    try std.testing.expectEqual(NumValKind.single, a.kind);
    try std.testing.expectEqual(@as(u32, 0x41), a.values[0]);
    const b = r.rulelist[1].body.arms[0].items[0].element.num_val;
    try std.testing.expectEqual(NumValKind.range, b.kind);
    try std.testing.expectEqual(@as(u32, 0x30), b.values[0]);
    try std.testing.expectEqual(@as(u32, 0x39), b.values[1]);
    const c = r.rulelist[2].body.arms[0].items[0].element.num_val;
    try std.testing.expectEqual(NumValKind.concat, c.kind);
    try std.testing.expectEqual(@as(usize, 3), c.values.len);
}

test "parse: decimal and binary num-val" {
    var p = Parser.init(std.testing.allocator,
        \\a = %d65
        \\b = %b1000001
        \\
    );
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(r.ok());
    try std.testing.expectEqual(@as(u32, 65), r.rulelist[0].body.arms[0].items[0].element.num_val.values[0]);
    try std.testing.expectEqual(@as(u32, 0b1000001), r.rulelist[1].body.arms[0].items[0].element.num_val.values[0]);
}

test "parse: case-sensitive and case-insensitive string prefixes" {
    var p = Parser.init(std.testing.allocator,
        \\a = %s"Foo"
        \\b = %i"Foo"
        \\c = "Foo"
        \\
    );
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(r.ok());
    const a = r.rulelist[0].body.arms[0].items[0].element.string_val;
    try std.testing.expect(a.case_sensitive);
    try std.testing.expectEqualStrings("Foo", a.raw);
    const b = r.rulelist[1].body.arms[0].items[0].element.string_val;
    try std.testing.expect(!b.case_sensitive);
    const c = r.rulelist[2].body.arms[0].items[0].element.string_val;
    try std.testing.expect(!c.case_sensitive);
}

test "parse: prose-val is accepted for later rejection" {
    var p = Parser.init(std.testing.allocator, "x = <free text>\n");
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(r.ok());
    try std.testing.expect(r.rulelist[0].body.arms[0].items[0].element == .prose_val);
}

test "parse: comments are stripped" {
    var p = Parser.init(std.testing.allocator,
        \\; leading comment
        \\x = "a" ; trailing comment
        \\; between rules
        \\y = "b"
        \\
    );
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(r.ok());
    try std.testing.expectEqual(@as(usize, 2), r.rulelist.len);
}

test "parse: multi-line alternation with indented continuation" {
    var p = Parser.init(std.testing.allocator, "hier-part = \"//\" authority\n" ++
        "          / path-absolute\n" ++
        "          / path-rootless\n");
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(r.ok());
    try std.testing.expectEqual(@as(usize, 3), r.rulelist[0].body.arms.len);
}

test "parse: URI example from the proposal" {
    const src =
        "URI         = scheme \":\" hier-part [ \"?\" query ] [ \"#\" fragment ]\n" ++
        "scheme      = ALPHA *( ALPHA / DIGIT / \"+\" / \"-\" / \".\" )\n" ++
        "hier-part   = \"//\" authority path-abempty\n" ++
        "            / path-absolute\n" ++
        "            / path-rootless\n" ++
        "            / path-empty\n";
    var p = Parser.init(std.testing.allocator, src);
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(r.ok());
    try std.testing.expectEqual(@as(usize, 3), r.rulelist.len);
    try std.testing.expectEqualStrings("URI", r.rulelist[0].name);
    try std.testing.expectEqualStrings("scheme", r.rulelist[1].name);
    try std.testing.expectEqualStrings("hier-part", r.rulelist[2].name);
    try std.testing.expectEqual(@as(usize, 4), r.rulelist[2].body.arms.len);
}

test "parse: error on missing equal" {
    var p = Parser.init(std.testing.allocator, "foo \"bar\"\n");
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(!r.ok());
    try std.testing.expect(r.errors.len >= 1);
}

test "parse: error on unterminated string" {
    var p = Parser.init(std.testing.allocator, "foo = \"oops\n");
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(!r.ok());
}

test "parse: error on unknown % prefix" {
    var p = Parser.init(std.testing.allocator, "foo = %q123\n");
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(!r.ok());
}

test "parse: accepts both CRLF and LF line endings" {
    var p = Parser.init(std.testing.allocator, "a = \"x\"\r\nb = \"y\"\n");
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(r.ok());
    try std.testing.expectEqual(@as(usize, 2), r.rulelist.len);
}

test "parse: span of a rule covers its full extent" {
    const src = "foo = \"bar\"\n";
    var p = Parser.init(std.testing.allocator, src);
    defer p.deinit();
    const r = try p.parse();
    try std.testing.expect(r.ok());
    const rule = r.rulelist[0];
    try std.testing.expectEqual(@as(u32, 0), rule.span.start);
    // Span should cover "foo = \"bar\"" (11 bytes) — we stop before
    // the newline terminator.
    try std.testing.expectEqual(@as(u32, 11), rule.span.len);
}
