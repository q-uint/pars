//! FIRST / nullable analysis for a single `Expr`.
//!
//! Computes, for an expression, the set of input bytes that may begin
//! a successful match (`bits`) and whether the expression may match
//! the empty string (`nullable`). `computeLocal` is purely local: any
//! construct whose FIRST depends on another rule -- a `rule_ref`, an
//! as-yet unresolved back-reference -- returns `null`, meaning
//! "unknown, do not optimize". `computeWithResolver` lifts that
//! restriction by delegating `rule_ref` resolution to a `Resolver`;
//! the whole-grammar pass in `grammar.zig` supplies one backed by a
//! fixed-point rule table.
//!
//! The primary client is the `#[longest](...)` demotion in
//! `grammar.zig`. When every arm has a known, non-nullable FIRST
//! and the arms are pairwise disjoint, ordered choice matches the
//! same strings as the longest-match semantics -- no
//! backtrack-and-retry needed. The check is deliberately
//! conservative: any uncertainty disables demotion.
//!
//! Contract note. Both `computeLocal` and `computeWithResolver`
//! poison all-or-nothing: if any subexpression is unresolvable they
//! return `null`, discarding the FIRST of sibling arms or prior
//! sequence parts that were computable. This matches the demotion
//! client's "any uncertainty => don't optimize" requirement. Callers
//! wanting best-effort FIRST (e.g. a diagnostic listing the known
//! starting bytes of a partially-unresolved rule) need a different
//! entry point; don't reuse these functions with a relaxed
//! interpretation of `null`.
//!
//! Lookahead caveat. `&A` is reported as (FIRST=empty, nullable=true).
//! Safe for sequence prefixes and for consumers that gate on
//! `nullable` (as `canDemoteLongest` does). A consumer that reads
//! FIRST without that gate would classify `&A` as disjoint from A,
//! which is wrong -- true FIRST(&A) is FIRST(A).

const std = @import("std");
const ast = @import("../frontend/ast.zig");

/// Result of analyzing a single expression. `bits` is a 256-bit
/// membership set, LSB-within-byte layout matching the runtime
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

/// Opaque adapter supplying FIRST/nullable for rule references during
/// analysis. Passing `null` for the resolver preserves the
/// purely-local semantics: any `rule_ref` becomes `null` ("unknown,
/// do not optimize"). A whole-grammar driver (see `grammar.zig`)
/// supplies a resolver backed by its fixed-point rule table.
pub const Resolver = struct {
    ctx: *const anyopaque,
    lookupFn: *const fn (ctx: *const anyopaque, name: []const u8) ?FirstInfo,

    pub fn lookup(self: Resolver, name: []const u8) ?FirstInfo {
        return self.lookupFn(self.ctx, name);
    }
};

/// Compute FIRST/nullable for `expr`. Returns `null` on any construct
/// outside the local core (rule references, back-references). Callers
/// must treat `null` as "unknown -- do not optimize".
pub fn computeLocal(expr: *const ast.Expr) ?FirstInfo {
    return computeWithResolver(expr, null);
}

/// Same as `computeLocal`, but consults `resolver` on `rule_ref`
/// nodes. Passing `null` reproduces the local-only behavior.
pub fn computeWithResolver(expr: *const ast.Expr, resolver: ?Resolver) ?FirstInfo {
    return computeKind(expr.kind, resolver);
}

fn computeKind(kind: ast.ExprKind, resolver: ?Resolver) ?FirstInfo {
    return switch (kind) {
        // A rule_ref's FIRST is the referenced rule's FIRST. Without a
        // resolver the local analysis can't supply one; with a
        // resolver we delegate. The resolver also returns null for
        // unknown or unanalyzable names, so this branch's null
        // contract is unchanged.
        .rule_ref => |name| if (resolver) |r| r.lookup(name) else null,

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

        // Single-quoted string literals store their escape-bearing source
        // verbatim, so we decode the first byte the same way the compiler
        // does at emit time. Triple-quoted strings are raw: the first
        // byte of `raw` is already the first byte the runtime matches.
        // Case-insensitive literals admit both cases of a letter as the
        // first byte.
        .string_lit => |s| blk: {
            if (s.raw.len == 0) break :blk FirstInfo.epsilon();
            const first = if (s.triple_quoted)
                s.raw[0]
            else
                firstByte(s.raw) orelse break :blk null;
            var info = FirstInfo.empty();
            info.add(first);
            if (s.case_insensitive and std.ascii.isAlphabetic(first)) {
                info.add(flipCase(first));
            }
            break :blk info;
        },

        .group => |inner| computeWithResolver(inner, resolver),

        .capture => |cap| computeWithResolver(cap.body, resolver),

        // Sequence: walk left-to-right, unioning each part's FIRST
        // into the result and stopping as soon as a non-nullable part
        // is found. The whole sequence is nullable iff every part is.
        .sequence => |parts| blk: {
            var info = FirstInfo.epsilon();
            for (parts) |*p| {
                const part = computeWithResolver(p, resolver) orelse break :blk null;
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
                const arm = computeWithResolver(a, resolver) orelse break :blk null;
                info.unionInto(arm);
                if (arm.nullable) info.nullable = true;
            }
            break :blk info;
        },

        .quantifier => |q| blk: {
            const operand = computeWithResolver(q.operand, resolver) orelse break :blk null;
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
        // (nullable, FIRST=empty): correct for the sequence rule -- a
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
/// Runs in O(n*32) by accumulating a union: if arm_i overlaps the
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
/// others on FIRST. Passing `null` for `resolver` keeps the
/// local-only behavior (rule references block demotion); a
/// whole-grammar resolver lifts that restriction for arms whose
/// references resolve through the rule table.
pub fn canDemoteLongest(arms: []const ast.Expr, resolver: ?Resolver) bool {
    if (arms.len < 2) return false;
    var combined = FirstInfo.empty();
    for (arms) |*arm| {
        const info = computeWithResolver(arm, resolver) orelse return false;
        // TODO: this check can be fooled by a capture back-reference
        // whose name shadows a non-nullable top-level rule. See the
        // TODO on `ast.ExprKind.rule_ref`. Latent today because
        // captures don't appear in ABNF-lowered source, the only
        // input `demoteLongestInPlace` runs on.
        if (info.nullable) return false;
        if (combined.overlaps(info)) return false;
        combined.unionInto(info);
    }
    return true;
}

// Decode the first logical byte of a single-quoted string literal's
// raw content, matching the escape table in `literal.decodeStringBody`.
// Returns null when the escape is malformed or unrecognized; the
// caller's contract is "unknown means do not optimize". Triple-quoted
// strings are raw and must not be passed here.
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
    // `&x y` -> FIRST = FIRST(y) = {y}, non-nullable.
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
    // G, P, D all distinct as first bytes -- demotion safe.
    var f = try Fixture.init("a = #[longest](\"GET\" / \"POST\" / \"DELETE\");");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(canDemoteLongest(arms, null));
}

test "canDemoteLongest: shared-first-byte literals block demotion" {
    // POST and PUT both start with P -- even though they're different
    // words, longest semantics diverges from ordered choice here.
    var f = try Fixture.init("a = #[longest](\"GET\" / \"POST\" / \"PUT\");");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(!canDemoteLongest(arms, null));
}

test "canDemoteLongest: overlapping first bytes blocks demotion" {
    var f = try Fixture.init("a = #[longest](\"GET\" / \"GETS\");");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(!canDemoteLongest(arms, null));
}

test "canDemoteLongest: rule reference arm blocks demotion" {
    var f = try Fixture.init("a = #[longest]('x' / other);");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(!canDemoteLongest(arms, null));
}

test "canDemoteLongest: nullable arm blocks demotion" {
    var f = try Fixture.init("a = #[longest]('x' / 'y'?);");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(!canDemoteLongest(arms, null));
}

test "canDemoteLongest: charset arms with disjoint ranges" {
    var f = try Fixture.init("a = #[longest](['0'-'9'] / ['a'-'z']);");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(canDemoteLongest(arms, null));
}

test "canDemoteLongest: charset arms with overlapping ranges blocked" {
    var f = try Fixture.init("a = #[longest](['a'-'m'] / ['k'-'z']);");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(!canDemoteLongest(arms, null));
}

test "canDemoteLongest: case-insensitive string arms respect folded FIRST" {
    // i"Get" has FIRST {G, g}; i"Post" has FIRST {P, p} -- disjoint.
    var f = try Fixture.init("a = #[longest](i\"Get\" / i\"Post\");");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(canDemoteLongest(arms, null));
}

test "canDemoteLongest: case-insensitive overlap blocks demotion" {
    // i"Get" FIRST {G, g}; "g..." FIRST {g} -- overlap on 'g'.
    var f = try Fixture.init("a = #[longest](i\"Get\" / \"gist\");");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(!canDemoteLongest(arms, null));
}

test "canDemoteLongest: single arm is not a candidate" {
    // Structurally a `longest` node with one arm shouldn't occur in
    // parsed pars -- the parser only emits `longest` when it sees
    // `#[longest](...)` with at least one arm, and multi-arm is the
    // normal shape. Guard defensively anyway.
    var f = try Fixture.init("a = #[longest]('x');");
    defer f.deinit();
    const arms = f.ruleBody(0).kind.longest;
    try testing.expect(!canDemoteLongest(arms, null));
}
