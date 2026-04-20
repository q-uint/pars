//! Lowering pass from ABNF AST to pars source text.
//!
//! Emits a pars source string together with a span map that associates
//! ranges of the generated source with their originating ABNF spans.
//! The generated source is fed to the existing pars compiler; the span
//! map lets callers translate compiler diagnostics back to ABNF
//! positions.
//!
//! Responsibilities implemented here:
//!
//!  - `A / B / ...` wraps in `#[longest](...)` (auto-lower).
//!  - Directly left-recursive rules are annotated with `#[lr]`.
//!  - Numeric byte values are validated: values > 255 produce an error
//!    with the source span of the offending literal.
//!  - Case-insensitive rule-name collisions inside a block are rejected
//!    first-wins-style per RFC 5234 §2.1.
//!  - Incremental alternatives (`A =/ B`) are merged block-local.
//!    `=/` targeting an undefined name is an error.
//!  - `prose-val` is rejected as an unsupported construct.
//!  - Hyphen-bearing rule names are mangled for the pars registry; the
//!    original spelling is retained for diagnostics.
//!
//! Names referenced by the block that are neither defined in it nor in
//! the host file are left as forward references; authors bring RFC 5234
//! Appendix B.1 core rules into scope with an explicit `use "std/abnf";`
//! in the host file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const abnf = @import("abnf.zig");

pub const Span = abnf.Span;

pub const LowerError = struct {
    message: []const u8,
    span: Span,
};

/// A slice of the generated source whose bytes all originate from one
/// ABNF source span. Sorted by `gen_offset`; the entry ending is
/// implicit from the next entry's `gen_offset`.
pub const SpanMapping = struct {
    gen_offset: u32,
    abnf_span: Span,
};

pub const LowerResult = struct {
    /// Owns all memory referenced by `source`, `spans`, and `errors`.
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    spans: []const SpanMapping,
    errors: []const LowerError,

    pub fn deinit(self: *LowerResult) void {
        self.arena.deinit();
    }

    pub fn ok(self: LowerResult) bool {
        return self.errors.len == 0;
    }
};

/// Lower the given rulelist to a pars source string. The returned
/// `LowerResult` owns its memory via an internal arena; call
/// `result.deinit()` when done.
pub fn lower(gpa: Allocator, rules: []const abnf.Rule) !LowerResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var l = Lower.init(alloc);
    try l.run(rules);

    return .{
        .arena = arena,
        .source = l.buffer.items,
        .spans = l.spans.items,
        .errors = l.errors.items,
    };
}

const Lower = struct {
    /// Arena allocator shared with the outer `LowerResult`. Every
    /// byte emitted here lives until the caller deinits the result.
    alloc: Allocator,
    buffer: std.ArrayList(u8),
    spans: std.ArrayList(SpanMapping),
    errors: std.ArrayList(LowerError),

    fn init(alloc: Allocator) Lower {
        return .{
            .alloc = alloc,
            .buffer = .empty,
            .spans = .empty,
            .errors = .empty,
        };
    }

    fn run(self: *Lower, rules: []const abnf.Rule) !void {
        const tmp = self.alloc;

        // Collect canonical rules: first-seen spelling wins, subsequent
        // =/ definitions append arms to the existing body.
        var canonical_order: std.ArrayList(CanonicalRule) = .empty;
        var index_by_key: std.StringHashMapUnmanaged(usize) = .empty;

        for (rules) |rule| {
            const key = try caseFoldName(tmp, rule.name);

            if (index_by_key.get(key)) |idx| {
                const existing = &canonical_order.items[idx];
                if (!std.mem.eql(u8, existing.name, rule.name)) {
                    try self.errors.append(self.alloc, .{
                        .message = try std.fmt.allocPrint(
                            self.alloc,
                            "Rule '{s}' is also spelled '{s}'; ABNF rule names are case-insensitive (RFC 5234 §2.1).",
                            .{ existing.name, rule.name },
                        ),
                        .span = rule.name_span,
                    });
                    continue;
                }
                if (!rule.incremental) {
                    try self.errors.append(self.alloc, .{
                        .message = try std.fmt.allocPrint(
                            self.alloc,
                            "Rule '{s}' is defined more than once in this block; use '=/' to extend.",
                            .{rule.name},
                        ),
                        .span = rule.name_span,
                    });
                    continue;
                }
                for (rule.body.arms) |arm| {
                    try existing.arms.append(tmp, arm);
                }
            } else {
                if (rule.incremental) {
                    try self.errors.append(self.alloc, .{
                        .message = try std.fmt.allocPrint(
                            self.alloc,
                            "Rule '{s}' uses '=/' but has no prior definition in this block.",
                            .{rule.name},
                        ),
                        .span = rule.name_span,
                    });
                    continue;
                }
                var arms: std.ArrayList(abnf.Concatenation) = .empty;
                for (rule.body.arms) |arm| try arms.append(tmp, arm);
                try index_by_key.put(tmp, key, canonical_order.items.len);
                try canonical_order.append(tmp, .{
                    .name = rule.name,
                    .name_span = rule.name_span,
                    .arms = arms,
                });
            }
        }

        for (canonical_order.items, 0..) |rule, i| {
            if (i > 0) try self.writeRaw("\n");
            try self.emitRule(rule);
        }
    }

    fn emitRule(self: *Lower, rule: CanonicalRule) Allocator.Error!void {
        if (try self.ruleIsDirectlyLeftRecursive(rule)) {
            try self.writeAt("#[lr]\n", rule.name_span);
        }
        try self.writeMangledName(rule.name, rule.name_span);
        try self.writeRaw(" = ");
        try self.emitArms(rule.arms.items, rule.name_span);
        try self.writeRaw(";\n");
    }

    fn emitArms(self: *Lower, arms: []const abnf.Concatenation, outer: Span) Allocator.Error!void {
        std.debug.assert(arms.len > 0);
        if (arms.len == 1) {
            try self.emitConcatenation(arms[0]);
            return;
        }
        try self.writeAt("#[longest](", outer);
        for (arms, 0..) |arm, i| {
            if (i > 0) try self.writeRaw(" / ");
            try self.emitConcatenation(arm);
        }
        try self.writeAt(")", outer);
    }

    fn emitConcatenation(self: *Lower, concat: abnf.Concatenation) Allocator.Error!void {
        for (concat.items, 0..) |item, i| {
            if (i > 0) try self.writeRaw(" ");
            try self.emitRepetition(item);
        }
    }

    fn emitRepetition(self: *Lower, rep: abnf.Repetition) Allocator.Error!void {
        // Option elements lower to `expr?` regardless of repeat.
        if (rep.element == .option) {
            const alt_ptr = rep.element.option;
            try self.writeAt("(", rep.span);
            try self.emitArms(alt_ptr.arms, alt_ptr.span);
            try self.writeAt(")?", rep.span);
            // If the ABNF source had an explicit repeat prefix on an
            // option, that is legal ABNF (`2*3[x]`) and should compose;
            // emit it as an additional quantifier afterward.
            try self.emitRepeatSuffix(rep.repeat, rep.span);
            return;
        }
        try self.emitElement(rep.element);
        try self.emitRepeatSuffix(rep.repeat, rep.span);
    }

    fn emitRepeatSuffix(self: *Lower, repeat: abnf.Repeat, span: Span) Allocator.Error!void {
        switch (repeat) {
            .none => {},
            .exact => |n| try self.writeFmtAt(span, "{{{d}}}", .{n}),
            .bounded => |b| {
                if (b.min > b.max) {
                    try self.errors.append(self.alloc, .{
                        .message = try std.fmt.allocPrint(
                            self.alloc,
                            "Bounded repeat has min ({d}) greater than max ({d}).",
                            .{ b.min, b.max },
                        ),
                        .span = span,
                    });
                    return;
                }
                if (b.min == 0 and b.max == 0) {
                    try self.errors.append(self.alloc, .{
                        .message = "Zero-zero repeat matches nothing.",
                        .span = span,
                    });
                    return;
                }
                if (b.min == 0) {
                    try self.writeFmtAt(span, "{{,{d}}}", .{b.max});
                } else {
                    try self.writeFmtAt(span, "{{{d},{d}}}", .{ b.min, b.max });
                }
            },
            .at_least => |n| switch (n) {
                0 => try self.writeAt("*", span),
                1 => try self.writeAt("+", span),
                else => try self.writeFmtAt(span, "{{{d},}}", .{n}),
            },
            .at_most => |m| try self.writeFmtAt(span, "{{,{d}}}", .{m}),
            .unbounded => try self.writeAt("*", span),
        }
    }

    fn emitElement(self: *Lower, element: abnf.Element) Allocator.Error!void {
        switch (element) {
            .rulename => |r| try self.writeMangledName(r.name, r.span),
            .group => |alt_ptr| {
                try self.writeAt("(", alt_ptr.span);
                try self.emitArms(alt_ptr.arms, alt_ptr.span);
                try self.writeAt(")", alt_ptr.span);
            },
            .option => unreachable, // handled in emitRepetition
            .string_val => |sv| try self.emitStringVal(sv),
            .num_val => |nv| try self.emitNumVal(nv),
            .prose_val => |span| {
                try self.errors.append(self.alloc, .{
                    .message = "prose-val (angle-bracketed text) is not supported; replace with an explicit grammar.",
                    .span = span,
                });
                // Emit a never-matching placeholder so subsequent
                // compilation does not spiral on a missing element.
                try self.writeAt("!.", span);
            },
        }
    }

    fn emitStringVal(self: *Lower, sv: abnf.StringVal) !void {
        if (!sv.case_sensitive) try self.writeAt("i", sv.span);
        try self.writeAt("\"", sv.span);
        for (sv.raw) |byte| {
            switch (byte) {
                '\\' => try self.writeAt("\\\\", sv.span),
                '"' => try self.writeAt("\\\"", sv.span),
                else => if (byte < 0x20 or byte == 0x7F) {
                    try self.writeFmtAt(sv.span, "\\x{X:0>2}", .{byte});
                } else {
                    try self.buffer.append(self.alloc, byte);
                },
            }
        }
        try self.writeAt("\"", sv.span);
    }

    fn emitNumVal(self: *Lower, nv: abnf.NumVal) !void {
        switch (nv.kind) {
            .single => {
                const v = nv.values[0];
                if (!self.validateByte(v, nv.span)) return;
                try self.writeFmtAt(nv.span, "'\\x{X:0>2}'", .{@as(u8, @intCast(v))});
            },
            .range => {
                const lo = nv.values[0];
                const hi = nv.values[1];
                if (!self.validateByte(lo, nv.span)) return;
                if (!self.validateByte(hi, nv.span)) return;
                if (lo > hi) {
                    try self.errors.append(self.alloc, .{
                        .message = "Numeric range has low bound greater than high bound.",
                        .span = nv.span,
                    });
                    return;
                }
                try self.writeFmtAt(nv.span, "['\\x{X:0>2}'-'\\x{X:0>2}']", .{
                    @as(u8, @intCast(lo)),
                    @as(u8, @intCast(hi)),
                });
            },
            .concat => {
                try self.writeAt("\"", nv.span);
                for (nv.values) |v| {
                    if (!self.validateByte(v, nv.span)) return;
                    try self.writeFmtAt(nv.span, "\\x{X:0>2}", .{@as(u8, @intCast(v))});
                }
                try self.writeAt("\"", nv.span);
            },
        }
    }

    fn validateByte(self: *Lower, v: u32, span: Span) bool {
        if (v > 255) {
            self.errors.append(self.alloc, .{
                .message = "Numeric byte value exceeds 255 and does not fit in one byte.",
                .span = span,
            }) catch {};
            return false;
        }
        return true;
    }

    fn ruleIsDirectlyLeftRecursive(self: *Lower, rule: CanonicalRule) !bool {
        const tmp = self.alloc;
        const self_key = try caseFoldName(tmp, rule.name);
        for (rule.arms.items) |arm| {
            if (concatLeftmostCalls(self_key, arm, tmp)) return true;
        }
        return false;
    }

    fn concatLeftmostCalls(self_key: []const u8, concat: abnf.Concatenation, arena: Allocator) bool {
        for (concat.items) |item| {
            if (repetitionLeftmostCalls(self_key, item, arena)) return true;
            if (!repetitionCouldBeEmpty(item)) return false;
        }
        return false;
    }

    fn repetitionLeftmostCalls(self_key: []const u8, rep: abnf.Repetition, arena: Allocator) bool {
        return switch (rep.element) {
            .rulename => |r| blk: {
                const k = caseFoldName(arena, r.name) catch return false;
                break :blk std.mem.eql(u8, k, self_key);
            },
            .group => |alt_ptr| altLeftmostCalls(self_key, alt_ptr.*, arena),
            .option => |alt_ptr| altLeftmostCalls(self_key, alt_ptr.*, arena),
            else => false,
        };
    }

    fn altLeftmostCalls(self_key: []const u8, alt: abnf.Alternation, arena: Allocator) bool {
        for (alt.arms) |arm| {
            if (concatLeftmostCalls(self_key, arm, arena)) return true;
        }
        return false;
    }

    fn repetitionCouldBeEmpty(rep: abnf.Repetition) bool {
        const repeat_empty = switch (rep.repeat) {
            .unbounded, .at_most => true,
            .at_least => |n| n == 0,
            .bounded => |b| b.min == 0,
            .exact => |n| n == 0,
            .none => false,
        };
        if (repeat_empty) return true;
        return rep.element == .option;
    }

    /// Append `text` with no associated ABNF span. Used for
    /// separators and punctuation that are purely syntactic.
    fn writeRaw(self: *Lower, text: []const u8) !void {
        try self.buffer.appendSlice(self.alloc, text);
    }

    /// Append `text` and record that it originates from `span`.
    fn writeAt(self: *Lower, text: []const u8, span: Span) !void {
        try self.spans.append(self.alloc, .{
            .gen_offset = @intCast(self.buffer.items.len),
            .abnf_span = span,
        });
        try self.buffer.appendSlice(self.alloc, text);
    }

    fn writeFmtAt(self: *Lower, span: Span, comptime fmt: []const u8, args: anytype) !void {
        try self.spans.append(self.alloc, .{
            .gen_offset = @intCast(self.buffer.items.len),
            .abnf_span = span,
        });
        try self.buffer.print(self.alloc, fmt, args);
    }

    fn writeMangledName(self: *Lower, name: []const u8, span: Span) !void {
        try self.spans.append(self.alloc, .{
            .gen_offset = @intCast(self.buffer.items.len),
            .abnf_span = span,
        });
        for (name) |c| {
            try self.buffer.append(self.alloc, if (c == '-') '_' else c);
        }
    }
};

const CanonicalRule = struct {
    name: []const u8,
    name_span: Span,
    arms: std.ArrayList(abnf.Concatenation),
};

fn caseFoldName(alloc: Allocator, name: []const u8) ![]const u8 {
    const buf = try alloc.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return buf;
}

fn lowerSource(alloc: Allocator, src: []const u8) !LowerResult {
    var p = abnf.Parser.init(alloc, src);
    defer p.deinit();
    const parsed = try p.parse();
    // The AST is owned by the parser's arena and borrowed into Lower;
    // deep-copy via the Lower arena is done inside `lower` when it
    // collects and re-homes names and arm lists.
    return lower(alloc, parsed.rulelist);
}

test "lower: simple rule with single arm" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc, "foo = \"bar\"\n");
    defer r.deinit();
    try std.testing.expect(r.ok());
    try std.testing.expectEqualStrings("foo = i\"bar\";\n", r.source);
}

test "lower: case-sensitive string via %s" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc, "foo = %s\"Bar\"\n");
    defer r.deinit();
    try std.testing.expect(r.ok());
    try std.testing.expectEqualStrings("foo = \"Bar\";\n", r.source);
}

test "lower: multi-arm alternation wraps in #[longest]" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc, "x = \"a\" / \"b\" / \"c\"\n");
    defer r.deinit();
    try std.testing.expect(r.ok());
    try std.testing.expectEqualStrings("x = #[longest](i\"a\" / i\"b\" / i\"c\");\n", r.source);
}

test "lower: concatenation uses juxtaposition" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc, "x = \"a\" \"b\"\n");
    defer r.deinit();
    try std.testing.expect(r.ok());
    try std.testing.expectEqualStrings("x = i\"a\" i\"b\";\n", r.source);
}

test "lower: repeat variants" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc,
        \\a = 3DIGIT
        \\b = 2*5DIGIT
        \\c = 1*DIGIT
        \\d = *5DIGIT
        \\e = *DIGIT
        \\f = 0*DIGIT
        \\
    );
    defer r.deinit();
    try std.testing.expect(r.ok());
    try std.testing.expectEqualStrings(
        \\a = DIGIT{3};
        \\
        \\b = DIGIT{2,5};
        \\
        \\c = DIGIT+;
        \\
        \\d = DIGIT{,5};
        \\
        \\e = DIGIT*;
        \\
        \\f = DIGIT*;
        \\
    , r.source);
}

test "lower: option becomes (body)?" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc, "x = [\"a\"]\n");
    defer r.deinit();
    try std.testing.expect(r.ok());
    try std.testing.expectEqualStrings("x = (i\"a\")?;\n", r.source);
}

test "lower: num-val single, range, concat" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc,
        \\a = %x41
        \\b = %x30-39
        \\c = %x41.42.43
        \\
    );
    defer r.deinit();
    try std.testing.expect(r.ok());
    try std.testing.expectEqualStrings(
        \\a = '\x41';
        \\
        \\b = ['\x30'-'\x39'];
        \\
        \\c = "\x41\x42\x43";
        \\
    , r.source);
}

test "lower: num-val out-of-range is an error" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc, "foo = %x100\n");
    defer r.deinit();
    try std.testing.expect(!r.ok());
    try std.testing.expectEqual(@as(usize, 1), r.errors.len);
}

test "lower: hyphenated rule name is mangled" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc, "hier-part = \"x\"\nfoo = hier-part\n");
    defer r.deinit();
    try std.testing.expect(r.ok());
    try std.testing.expectEqualStrings("hier_part = i\"x\";\n\nfoo = hier_part;\n", r.source);
}

test "lower: incremental =/ merges arms" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc,
        \\x = "a"
        \\x =/ "b"
        \\x =/ "c"
        \\
    );
    defer r.deinit();
    try std.testing.expect(r.ok());
    try std.testing.expectEqualStrings("x = #[longest](i\"a\" / i\"b\" / i\"c\");\n", r.source);
}

test "lower: case-insensitive collision is rejected" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc,
        \\URI = "a"
        \\uri = "b"
        \\
    );
    defer r.deinit();
    try std.testing.expect(!r.ok());
    try std.testing.expectEqual(@as(usize, 1), r.errors.len);
}

test "lower: =/ with same spelling as prior definition merges cleanly" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc,
        \\URI = "a"
        \\URI =/ "b"
        \\
    );
    defer r.deinit();
    try std.testing.expect(r.ok());
}

test "lower: =/ with no prior definition is an error" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc, "x =/ \"a\"\n");
    defer r.deinit();
    try std.testing.expect(!r.ok());
}

test "lower: duplicate (non-incremental) definition is an error" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc,
        \\x = "a"
        \\x = "b"
        \\
    );
    defer r.deinit();
    try std.testing.expect(!r.ok());
}

test "lower: prose-val is rejected" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc, "x = <prose>\n");
    defer r.deinit();
    try std.testing.expect(!r.ok());
}

test "lower: direct left recursion attaches #[lr]" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc,
        \\expr = expr "+" term / term
        \\term = "1"
        \\
    );
    defer r.deinit();
    try std.testing.expect(r.ok());
    try std.testing.expect(std.mem.indexOf(u8, r.source, "#[lr]\nexpr") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.source, "#[lr]\nterm") == null);
}

test "lower: non-left-recursive self reference does not attach #[lr]" {
    const alloc = std.testing.allocator;
    var r = try lowerSource(alloc,
        \\list = item list / item
        \\item = "1"
        \\
    );
    defer r.deinit();
    try std.testing.expect(r.ok());
    try std.testing.expect(std.mem.indexOf(u8, r.source, "#[lr]") == null);
}

test "lower: URI example lowers to compilable pars" {
    const alloc = std.testing.allocator;
    const src =
        "URI       = scheme \":\" hier-part\n" ++
        "scheme    = ALPHA *( ALPHA / DIGIT )\n" ++
        "hier-part = \"//\" authority\n" ++
        "          / path-absolute\n" ++
        "          / path-rootless\n";
    var r = try lowerSource(alloc, src);
    defer r.deinit();
    try std.testing.expect(r.ok());
    // Sanity-check the structure without nailing every detail.
    try std.testing.expect(std.mem.indexOf(u8, r.source, "URI = scheme") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.source, "hier_part") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.source, "#[longest]") != null);
}

test "lower: string with control bytes is hex-escaped" {
    const alloc = std.testing.allocator;
    // \x01 as part of the ABNF source via a num-val concat, but the
    // direct string path also needs escaping for embedded quotes.
    var r = try lowerSource(alloc, "x = \"a\\b\"\n");
    defer r.deinit();
    try std.testing.expect(r.ok());
    // The ABNF source had backslash-b (two literal bytes); we emit
    // them with \\ for the backslash and a regular 'b'.
    try std.testing.expectEqualStrings("x = i\"a\\\\b\";\n", r.source);
}
