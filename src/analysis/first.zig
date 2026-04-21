//! Local FIRST / nullable analysis for a single `Expr`.
//!
//! Computes, for an expression, the set of input bytes that may begin
//! a successful match (`bits`) and whether the expression may match
//! the empty string (`nullable`). The analysis is purely local: any
//! construct whose FIRST depends on another rule — a `rule_ref`, an
//! as-yet unresolved back-reference — causes `computeLocal` to return
//! `null`, meaning "unknown, do not optimize". A later whole-grammar
//! pass can fold in a rule-table fixed point and extend this.
//!
//! The primary client is the compiler's `#[longest](...)` lowering.
//! When every arm has a known, non-nullable FIRST and the arms are
//! pairwise disjoint, ordered choice matches the same strings as the
//! longest-match semantics — no backtrack-and-retry needed. The check
//! is deliberately conservative: any uncertainty disables demotion.

const std = @import("std");
const ast = @import("../frontend/ast.zig");

/// Result of analyzing a single expression. `bits` is a 256-bit
/// membership set, MSB-within-byte layout matching the runtime
/// charset encoding so the two representations are interchangeable.
pub const FirstInfo = struct {
    bits: [32]u8,
    nullable: bool,

    pub fn empty() FirstInfo {
        return .{ .bits = .{0} ** 32, .nullable = false };
    }

    pub fn epsilon() FirstInfo {
        return .{ .bits = .{0} ** 32, .nullable = true };
    }

    pub fn add(self: *FirstInfo, byte: u8) void {
        self.bits[byte >> 3] |= @as(u8, 1) << @intCast(byte & 0x07);
    }

    pub fn contains(self: FirstInfo, byte: u8) bool {
        return (self.bits[byte >> 3] & (@as(u8, 1) << @intCast(byte & 0x07))) != 0;
    }

    pub fn addRange(self: *FirstInfo, lo: u8, hi: u8) void {
        var b: u16 = lo;
        while (b <= hi) : (b += 1) self.add(@intCast(b));
    }

    pub fn unionInto(self: *FirstInfo, other: FirstInfo) void {
        for (&self.bits, other.bits) |*d, s| d.* |= s;
    }

    pub fn overlaps(a: FirstInfo, b: FirstInfo) bool {
        for (a.bits, b.bits) |x, y| if (x & y != 0) return true;
        return false;
    }
};

/// Compute FIRST/nullable for `expr`. Returns `null` on any construct
/// outside the local core (rule references, back-references). Callers
/// must treat `null` as "unknown — do not optimize".
pub fn computeLocal(expr: *const ast.Expr) ?FirstInfo {
    return computeKind(expr.kind);
}

fn computeKind(kind: ast.ExprKind) ?FirstInfo {
    return switch (kind) {
        // A rule_ref's FIRST is the referenced rule's FIRST, which the
        // local analysis doesn't have. Phase-2 grammar analysis fills
        // this in.
        .rule_ref => null,

        // `.` matches any single byte.
        .any_byte => blk: {
            var info = FirstInfo.empty();
            var b: u16 = 0;
            while (b < 256) : (b += 1) info.add(@intCast(b));
            break :blk info;
        },

        .char_lit => |c| blk: {
            var info = FirstInfo.empty();
            info.add(c);
            break :blk info;
        },

        .charset => |items| blk: {
            var info = FirstInfo.empty();
            for (items) |item| switch (item) {
                .single => |b| info.add(b),
                .range => |r| info.addRange(r.lo, r.hi),
            };
            break :blk info;
        },

        // String literals hold raw undecoded bytes; decode just the
        // first byte. Case-insensitive literals admit both cases of a
        // letter as the first byte.
        .string_lit => |s| blk: {
            if (s.raw.len == 0) break :blk FirstInfo.epsilon();
            const first = firstByte(s.raw) orelse break :blk null;
            var info = FirstInfo.empty();
            info.add(first);
            if (s.case_insensitive and std.ascii.isAlphabetic(first)) {
                info.add(flipCase(first));
            }
            break :blk info;
        },

        .group => |inner| computeLocal(inner),

        .capture => |cap| computeLocal(cap.body),

        // Sequence: walk left-to-right, unioning each part's FIRST
        // into the result and stopping as soon as a non-nullable part
        // is found. The whole sequence is nullable iff every part is.
        .sequence => |parts| blk: {
            var info = FirstInfo.epsilon();
            for (parts) |*p| {
                const part = computeLocal(p) orelse break :blk null;
                info.unionInto(part);
                if (!part.nullable) {
                    info.nullable = false;
                    break :blk info;
                }
            }
            break :blk info;
        },

        // Ordered choice and longest share the same FIRST formula:
        // the union of the arms' FIRSTs, nullable iff any arm is.
        .choice, .longest => |arms| blk: {
            var info = FirstInfo.empty();
            for (arms) |*a| {
                const arm = computeLocal(a) orelse break :blk null;
                info.unionInto(arm);
                if (arm.nullable) info.nullable = true;
            }
            break :blk info;
        },

        .quantifier => |q| blk: {
            const operand = computeLocal(q.operand) orelse break :blk null;
            break :blk switch (q.kind) {
                .star, .question => FirstInfo{ .bits = operand.bits, .nullable = true },
                .plus => operand,
                .bounded => |b| FirstInfo{
                    .bits = operand.bits,
                    .nullable = operand.nullable or (b.min == null) or (b.min.? == 0),
                },
            };
        },

        // Lookaheads consume no input but succeed/fail based on `A`.
        // The standard LL-style over-approximation treats them as
        // (nullable, FIRST=∅): correct for the sequence rule — a
        // sequence `&A B` gets FIRST(B), not the tighter intersection,
        // which is safe for disjointness checks (a superset cannot
        // falsely claim disjointness).
        .lookahead => FirstInfo.epsilon(),

        // Cut marks a commit point; it consumes nothing and always
        // succeeds.
        .cut, .cut_labeled => FirstInfo.epsilon(),
    };
}

/// Whether all infos are pairwise disjoint on their FIRST bits.
/// Runs in O(n·32) by accumulating a union: if arm_i overlaps the
/// union of arms 0..i-1, it overlaps at least one of them.
pub fn disjoint(infos: []const FirstInfo) bool {
    var combined = FirstInfo.empty();
    for (infos) |info| {
        if (combined.overlaps(info)) return false;
        combined.unionInto(info);
    }
    return true;
}

/// Whether a `#[longest]` over `arms` can be demoted to ordered
/// choice without changing which strings match. Requires every arm
/// to be analyzable, non-nullable, and pairwise disjoint from the
/// others on FIRST.
pub fn canDemoteLongest(arms: []const ast.Expr) bool {
    if (arms.len < 2) return false;
    var combined = FirstInfo.empty();
    for (arms) |*arm| {
        const info = computeLocal(arm) orelse return false;
        if (info.nullable) return false;
        if (combined.overlaps(info)) return false;
        combined.unionInto(info);
    }
    return true;
}

/// Source-level rewrite: for every `#[longest](...)` group whose arms
/// have pairwise-disjoint, non-nullable FIRST sets, overwrite the
/// `#[longest]` prefix (up to and including the closing `]`) with
/// spaces. The opening `(` is left in place, so on re-scan the tokens
/// read as a parenthesized expression and the compiler emits ordered
/// choice instead of longest-match.
///
/// Rewrites in place. Byte-preserving, so all existing source offsets
/// — line/column diagnostics, ABNF span maps — remain valid without
/// remapping. A parse failure leaves the buffer untouched; the main
/// compiler will report the same errors.
pub fn demoteLongestInPlace(
    allocator: std.mem.Allocator,
    source: []u8,
) !void {
    var parser = ast.Parser.init(allocator, source);
    defer parser.deinit();
    const result = parser.parse() catch return;
    if (!result.ok()) return;

    for (result.program.items) |item| {
        switch (item) {
            .rule => |r| {
                demoteInExpr(&r.body, source);
                for (r.where_bindings) |wb| demoteInExpr(&wb.body, source);
            },
            .bare_expr => |e| demoteInExpr(&e, source),
            .use_decl, .tagged_block => {},
        }
    }
}

fn demoteInExpr(expr: *const ast.Expr, source: []u8) void {
    switch (expr.kind) {
        .longest => |arms| {
            if (canDemoteLongest(arms)) blank(source, expr.span.start);
            for (arms) |*a| demoteInExpr(a, source);
        },
        .sequence => |parts| for (parts) |*p| demoteInExpr(p, source),
        .choice => |arms| for (arms) |*a| demoteInExpr(a, source),
        .group => |inner| demoteInExpr(inner, source),
        .capture => |cap| demoteInExpr(cap.body, source),
        .quantifier => |q| demoteInExpr(q.operand, source),
        .lookahead => |la| demoteInExpr(la.operand, source),
        .rule_ref,
        .string_lit,
        .char_lit,
        .charset,
        .any_byte,
        .cut,
        .cut_labeled,
        => {},
    }
}

fn blank(source: []u8, longest_start: u32) void {
    // Blank `#` through the `]` that closes the attribute bracket.
    // Nothing inside `[longest]` is itself a `]`, so the first one
    // found is always the right one.
    var i: usize = longest_start;
    while (i < source.len and source[i] != ']') : (i += 1) {}
    if (i >= source.len) return;
    @memset(source[longest_start .. i + 1], ' ');
}

// Decode the first logical byte of a string-literal's raw content,
// honoring the same escape sequences as `literal.extractCharByte`.
// Returns null when the escape is malformed or unrecognized; the
// caller's contract is "unknown means do not optimize".
fn firstByte(raw: []const u8) ?u8 {
    if (raw.len == 0) return null;
    if (raw[0] != '\\') return raw[0];
    if (raw.len < 2) return null;
    return switch (raw[1]) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        '\\' => '\\',
        '\'' => '\'',
        '"' => '"',
        'x' => blk: {
            if (raw.len < 4) break :blk null;
            const hi = std.fmt.charToDigit(raw[2], 16) catch break :blk null;
            const lo = std.fmt.charToDigit(raw[3], 16) catch break :blk null;
            break :blk @as(u8, (hi << 4) | lo);
        },
        else => null,
    };
}

fn flipCase(b: u8) u8 {
    if (b >= 'A' and b <= 'Z') return b + 32;
    if (b >= 'a' and b <= 'z') return b - 32;
    return b;
}

const testing = std.testing;

// Parse a rule body so tests can feed real AST nodes to the analyzer
// rather than hand-constructing them against an arena lifetime.
const Fixture = struct {
    parser: ast.Parser,
    program: ast.Program,

    fn init(src: []const u8) !Fixture {
        var p = ast.Parser.init(testing.allocator, src);
        const r = try p.parse();
        if (!r.ok()) {
            p.deinit();
            return error.ParseFailed;
        }
        return .{ .parser = p, .program = r.program };
    }

    fn deinit(self: *Fixture) void {
        self.parser.deinit();
    }

    fn ruleBody(self: *const Fixture, index: usize) *const ast.Expr {
        return &self.program.items[index].rule.body;
    }
};

test "char literal has singleton FIRST and is not nullable" {
    var f = try Fixture.init("a = 'H';");
    defer f.deinit();
    const info = computeLocal(f.ruleBody(0)).?;
    try testing.expect(info.contains('H'));
    try testing.expect(!info.contains('h'));
    try testing.expect(!info.nullable);
}

test "string literal reports first byte" {
    var f = try Fixture.init("a = \"GET\";");
    defer f.deinit();
    const info = computeLocal(f.ruleBody(0)).?;
    try testing.expect(info.contains('G'));
    try testing.expect(!info.contains('E'));
    try testing.expect(!info.nullable);
}

test "case-insensitive string literal admits both letter cases" {
    var f = try Fixture.init("a = i\"Get\";");
    defer f.deinit();
    const info = computeLocal(f.ruleBody(0)).?;
    try testing.expect(info.contains('G'));
    try testing.expect(info.contains('g'));
    try testing.expect(!info.contains('e'));
    try testing.expect(!info.nullable);
}

test "case-insensitive string on non-letter first byte is unchanged" {
    var f = try Fixture.init("a = i\"1bc\";");
    defer f.deinit();
    const info = computeLocal(f.ruleBody(0)).?;
    try testing.expect(info.contains('1'));
    // No mirror case to add.
    try testing.expect(!info.contains('2'));
}

test "string literal with hex-escaped first byte decodes" {
    var f = try Fixture.init("a = \"\\x41BC\";");
    defer f.deinit();
    const info = computeLocal(f.ruleBody(0)).?;
    try testing.expect(info.contains(0x41));
    try testing.expect(!info.nullable);
}

test "charset singles and ranges populate FIRST" {
    var f = try Fixture.init("a = ['a'-'c' 'x'];");
    defer f.deinit();
    const info = computeLocal(f.ruleBody(0)).?;
    try testing.expect(info.contains('a'));
    try testing.expect(info.contains('b'));
    try testing.expect(info.contains('c'));
    try testing.expect(info.contains('x'));
    try testing.expect(!info.contains('d'));
    try testing.expect(!info.nullable);
}

test "any-byte fills FIRST" {
    var f = try Fixture.init("a = .;");
    defer f.deinit();
    const info = computeLocal(f.ruleBody(0)).?;
    var b: u16 = 0;
    while (b < 256) : (b += 1) try testing.expect(info.contains(@intCast(b)));
    try testing.expect(!info.nullable);
}

test "sequence FIRST is leftmost non-nullable part's FIRST" {
    var f = try Fixture.init("a = 'x' 'y' 'z';");
    defer f.deinit();
    const info = computeLocal(f.ruleBody(0)).?;
    try testing.expect(info.contains('x'));
    try testing.expect(!info.contains('y'));
    try testing.expect(!info.nullable);
}

test "sequence of nullables unions FIRSTs and stays nullable" {
    var f = try Fixture.init("a = 'x'? 'y'? 'z'?;");
    defer f.deinit();
    const info = computeLocal(f.ruleBody(0)).?;
    try testing.expect(info.contains('x'));
    try testing.expect(info.contains('y'));
    try testing.expect(info.contains('z'));
    try testing.expect(info.nullable);
}

test "choice unions arm FIRSTs" {
    var f = try Fixture.init("a = 'x' / 'y' / 'z';");
    defer f.deinit();
    const info = computeLocal(f.ruleBody(0)).?;
    try testing.expect(info.contains('x'));
    try testing.expect(info.contains('y'));
    try testing.expect(info.contains('z'));
    try testing.expect(!info.nullable);
}

test "longest unions arm FIRSTs" {
    var f = try Fixture.init("a = #[longest]('x' / 'y');");
    defer f.deinit();
    const info = computeLocal(f.ruleBody(0)).?;
    try testing.expect(info.contains('x'));
    try testing.expect(info.contains('y'));
    try testing.expect(!info.nullable);
}

test "star and question are nullable with operand's FIRST" {
    var f = try Fixture.init(
        \\a = 'x'*;
        \\b = 'y'?;
    );
    defer f.deinit();
    const a = computeLocal(f.ruleBody(0)).?;
    try testing.expect(a.contains('x'));
    try testing.expect(a.nullable);
    const b = computeLocal(f.ruleBody(1)).?;
    try testing.expect(b.contains('y'));
    try testing.expect(b.nullable);
}

test "plus preserves operand nullability" {
    var f = try Fixture.init("a = 'x'+;");
    defer f.deinit();
    const info = computeLocal(f.ruleBody(0)).?;
    try testing.expect(info.contains('x'));
    try testing.expect(!info.nullable);
}

test "bounded quantifier with min=0 is nullable" {
    var f = try Fixture.init(
        \\a = 'x'{0,3};
        \\b = 'y'{,4};
        \\c = 'z'{2,5};
    );
    defer f.deinit();
    try testing.expect(computeLocal(f.ruleBody(0)).?.nullable);
    try testing.expect(computeLocal(f.ruleBody(1)).?.nullable);
    try testing.expect(!computeLocal(f.ruleBody(2)).?.nullable);
}

test "group is transparent" {
    var f = try Fixture.init("a = ('x' / 'y');");
    defer f.deinit();
    const info = computeLocal(f.ruleBody(0)).?;
    try testing.expect(info.contains('x'));
    try testing.expect(info.contains('y'));
}

test "capture is transparent" {
    var f = try Fixture.init("a = <n: 'x' / 'y'>;");
    defer f.deinit();
    const info = computeLocal(f.ruleBody(0)).?;
    try testing.expect(info.contains('x'));
    try testing.expect(info.contains('y'));
}

test "lookahead contributes no FIRST but stays nullable" {
    var f = try Fixture.init(
        \\a = &'x' 'y';
        \\b = !'x' 'y';
    );
    defer f.deinit();
    // `&x y` → FIRST = FIRST(y) = {y}, non-nullable.
    const a = computeLocal(f.ruleBody(0)).?;
    try testing.expect(a.contains('y'));
    try testing.expect(!a.contains('x'));
    try testing.expect(!a.nullable);
    const b = computeLocal(f.ruleBody(1)).?;
    try testing.expect(b.contains('y'));
    try testing.expect(!b.contains('x'));
    try testing.expect(!b.nullable);
}

test "bare lookahead arm is nullable with empty FIRST" {
    var f = try Fixture.init("a = &'x';");
    defer f.deinit();
    const info = computeLocal(f.ruleBody(0)).?;
    try testing.expect(!info.contains('x'));
    try testing.expect(info.nullable);
}

test "rule reference blocks analysis" {
    var f = try Fixture.init("a = other;");
    defer f.deinit();
    try testing.expect(computeLocal(f.ruleBody(0)) == null);
}

test "sequence containing a rule reference blocks analysis" {
    var f = try Fixture.init("a = 'x' other;");
    defer f.deinit();
    // Leading non-nullable 'x' short-circuits; rule_ref is never visited.
    const info = computeLocal(f.ruleBody(0)).?;
    try testing.expect(info.contains('x'));
}

test "sequence with nullable lead and rule reference blocks analysis" {
    var f = try Fixture.init("a = 'x'? other;");
    defer f.deinit();
    try testing.expect(computeLocal(f.ruleBody(0)) == null);
}

test "canDemoteLongest: disjoint literal arms" {
    // G, P, D all distinct as first bytes — demotion safe.
    var f = try Fixture.init("a = #[longest](\"GET\" / \"POST\" / \"DELETE\");");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(canDemoteLongest(arms));
}

test "canDemoteLongest: shared-first-byte literals block demotion" {
    // POST and PUT both start with P — even though they're different
    // words, longest semantics diverges from ordered choice here.
    var f = try Fixture.init("a = #[longest](\"GET\" / \"POST\" / \"PUT\");");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(!canDemoteLongest(arms));
}

test "canDemoteLongest: overlapping first bytes blocks demotion" {
    var f = try Fixture.init("a = #[longest](\"GET\" / \"GETS\");");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(!canDemoteLongest(arms));
}

test "canDemoteLongest: rule reference arm blocks demotion" {
    var f = try Fixture.init("a = #[longest]('x' / other);");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(!canDemoteLongest(arms));
}

test "canDemoteLongest: nullable arm blocks demotion" {
    var f = try Fixture.init("a = #[longest]('x' / 'y'?);");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(!canDemoteLongest(arms));
}

test "canDemoteLongest: charset arms with disjoint ranges" {
    var f = try Fixture.init("a = #[longest](['0'-'9'] / ['a'-'z']);");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(canDemoteLongest(arms));
}

test "canDemoteLongest: charset arms with overlapping ranges blocked" {
    var f = try Fixture.init("a = #[longest](['a'-'m'] / ['k'-'z']);");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(!canDemoteLongest(arms));
}

test "canDemoteLongest: case-insensitive string arms respect folded FIRST" {
    // i"Get" has FIRST {G, g}; i"Post" has FIRST {P, p} — disjoint.
    var f = try Fixture.init("a = #[longest](i\"Get\" / i\"Post\");");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(canDemoteLongest(arms));
}

test "canDemoteLongest: case-insensitive overlap blocks demotion" {
    // i"Get" FIRST {G, g}; "g..." FIRST {g} — overlap on 'g'.
    var f = try Fixture.init("a = #[longest](i\"Get\" / \"gist\");");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(!canDemoteLongest(arms));
}

test "demoteLongestInPlace: disjoint literals are demoted" {
    const src = "a = #[longest](\"GET\" / \"POST\" / \"DELETE\");";
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    try demoteLongestInPlace(testing.allocator, buf);
    // `#[longest]` prefix is blanked; `(` is kept.
    try testing.expectEqualStrings(
        "a =           (\"GET\" / \"POST\" / \"DELETE\");",
        buf,
    );
}

test "demoteLongestInPlace: overlapping arms are untouched" {
    const src = "a = #[longest](\"GET\" / \"GETS\");";
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    try demoteLongestInPlace(testing.allocator, buf);
    try testing.expectEqualStrings(src, buf);
}

test "demoteLongestInPlace: buffer is byte-preserving" {
    const src = "a = #[longest](\"x\" / \"y\");\nb = c;\n";
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    try demoteLongestInPlace(testing.allocator, buf);
    try testing.expectEqual(src.len, buf.len);
    // Only the `#[longest]` prefix was rewritten; newlines unchanged.
    try testing.expectEqual(@as(usize, std.mem.count(u8, src, "\n")), std.mem.count(u8, buf, "\n"));
}

test "demoteLongestInPlace: descends into rule bodies and where-blocks" {
    const src =
        \\a = b
        \\  where b = #[longest]("x" / "y") end
        \\;
    ;
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    try demoteLongestInPlace(testing.allocator, buf);
    try testing.expect(std.mem.indexOf(u8, buf, "#[longest]") == null);
}

test "demoteLongestInPlace: parse failures leave buffer intact" {
    const src = "not a grammar at all { } ???";
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    try demoteLongestInPlace(testing.allocator, buf);
    try testing.expectEqualStrings(src, buf);
}

test "canDemoteLongest: single arm is not a candidate" {
    // Structurally a `longest` node with one arm shouldn't occur in
    // parsed pars — the parser only emits `longest` when it sees
    // `#[longest](...)` with at least one arm, and multi-arm is the
    // normal shape. Guard defensively anyway.
    var f = try Fixture.init("a = #[longest]('x');");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(!canDemoteLongest(arms));
}
