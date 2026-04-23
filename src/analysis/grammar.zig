//! Whole-grammar FIRST / nullable analysis.
//!
//! Computes, for every rule (and every `where`-scoped sub-rule) in a
//! program, the set of input bytes that may begin a successful match
//! and whether the rule may match the empty string. Extends
//! `first.zig`'s local analysis via a monotone fixed point over the
//! rule table: each iteration recomputes every entry using the
//! current table as the resolver for `rule_ref` subterms. Bits can
//! only be added, `nullable` only flips false -> true, so the lattice
//! is finite and convergence is guaranteed.
//!
//! Unanalyzable rules (bodies that contain malformed escapes, or
//! that transitively call a rule whose entry is itself unanalyzable)
//! have `known=false`. A `rule_ref` to a `known=false` rule poisons
//! the containing computation the same way the local analyzer's
//! `null` return does.
//!
//! Scopes. A `rule_ref` inside a rule body resolves in order:
//!   1. The enclosing rule's `where` bindings, if any.
//!   2. The top-level rule table.
//! Unresolved names contribute `null` ("unknown, do not optimize").
//!
//! `#[lr]` handling. Directly (and indirectly) left-recursive rules
//! get the Warth seed trick: while computing the body of an `#[lr]`
//! rule R, a `rule_ref` to R itself returns bottom (empty FIRST, not
//! nullable). Recursive arms then contribute nothing; seed arms drive
//! FIRST(R). The fixed point handles indirect cycles naturally --
//! once FIRST(R) stabilizes from seed arms, any rule that transits
//! through R converges too.
//!
//! Deliberately out of scope:
//!   - `use "..."` imports are not pre-expanded; unresolved names
//!     resolve to `known=false`. A follow-up can merge imported
//!     module tables before running the fixed point.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("../frontend/ast.zig");
const first = @import("first.zig");
const FirstInfo = first.FirstInfo;

/// A single rule's analyzed FIRST/nullable plus a `known` bit. An
/// unknown entry models the same "do not optimize" contract as a
/// `null` return from the local analyzer.
pub const Entry = struct {
    first: FirstInfo,
    known: bool,

    pub fn unknown() Entry {
        return .{ .first = FirstInfo.empty(), .known = false };
    }

    pub fn bottom() Entry {
        return .{ .first = FirstInfo.empty(), .known = true };
    }
};

/// Map of binding-name -> Entry for a single `where` block.
pub const WhereScope = std.StringHashMapUnmanaged(Entry);

/// Rule name -> Entry for top-level rules, plus a per-rule map of
/// `where`-scoped bindings. Owned by an arena so key slices outlive
/// the AST the analyzer consumed. Free via `deinit`.
pub const RuleFirstTable = struct {
    arena: std.heap.ArenaAllocator,
    rules: std.StringHashMapUnmanaged(Entry),
    /// Keyed by the enclosing rule's name. Absent for rules that have
    /// no `where` block.
    where_scopes: std.StringHashMapUnmanaged(WhereScope),

    pub fn deinit(self: *RuleFirstTable) void {
        self.arena.deinit();
    }

    /// Look up a top-level rule. Returns null for unknown names or
    /// `known=false` entries -- the same null contract the local
    /// analyzer's `rule_ref` branch uses.
    pub fn lookup(self: *const RuleFirstTable, name: []const u8) ?FirstInfo {
        const entry = self.rules.get(name) orelse return null;
        if (!entry.known) return null;
        return entry.first;
    }

    /// Look up a binding in `rule`'s `where` scope. Returns null when
    /// the rule has no such binding or the binding is `known=false`.
    pub fn lookupWhere(
        self: *const RuleFirstTable,
        rule: []const u8,
        name: []const u8,
    ) ?FirstInfo {
        const scope = self.where_scopes.getPtr(rule) orelse return null;
        const entry = scope.get(name) orelse return null;
        if (!entry.known) return null;
        return entry.first;
    }

    /// A resolver that consults only the top-level table. Callers
    /// that need `where`-scope shadowing should build a
    /// `ScopedResolver` instead.
    pub fn resolver(self: *const RuleFirstTable) first.Resolver {
        return .{
            .ctx = @ptrCast(self),
            .lookupFn = lookupAdapter,
        };
    }

    fn lookupAdapter(ctx: *const anyopaque, name: []const u8) ?FirstInfo {
        const self: *const RuleFirstTable = @ptrCast(@alignCast(ctx));
        return self.lookup(name);
    }
};

/// Resolver carrying lexical scope for a single in-progress
/// computation. Fields are mutable so the fixed-point driver can
/// reuse one `first.Resolver` handle across rules.
pub const ScopedResolver = struct {
    table: *const RuleFirstTable,
    /// Rule whose `where`-scope should be consulted before the
    /// top-level table. Null means top-level only.
    rule_name: ?[]const u8 = null,
    /// When set, a `rule_ref` whose name equals this value returns
    /// bottom (empty FIRST, not nullable). Used while computing the
    /// body of an `#[lr]` rule: the Warth seed trick. Must be cleared
    /// when computing anything else (including the rule's own
    /// `where` bindings).
    self_lr: ?[]const u8 = null,
    /// When true, a `self_lr` hit returns `null` (unknown) instead of
    /// bottom. The whole-grammar fixed point needs bottom as a
    /// monotone seed: empty bits can only grow, so the lattice
    /// converges. `canDemoteLongest` needs unknown: an empty FIRST
    /// means "overlaps nothing," so a longest arm that recurses back
    /// into the enclosing LR rule would otherwise be silently
    /// classified disjoint and demoted even when the recursive arm
    /// could out-consume the seed on overlapping input.
    disjointness_mode: bool = false,

    pub fn resolver(self: *const ScopedResolver) first.Resolver {
        return .{
            .ctx = @ptrCast(self),
            .lookupFn = lookupAdapter,
        };
    }

    fn lookupAdapter(ctx: *const anyopaque, name: []const u8) ?FirstInfo {
        const self: *const ScopedResolver = @ptrCast(@alignCast(ctx));
        if (self.self_lr) |s| if (std.mem.eql(u8, s, name)) {
            // Disjointness consumers must set `disjointness_mode` --
            // see the field doc above. Empty FIRST is a fixed-point
            // seed, not a runtime-empty FIRST.
            if (self.disjointness_mode) return null;
            return FirstInfo.empty();
        };
        if (self.rule_name) |rn| {
            if (self.table.where_scopes.getPtr(rn)) |scope| {
                if (scope.get(name)) |e| {
                    if (!e.known) return null;
                    return e.first;
                }
            }
        }
        return self.table.lookup(name);
    }
};

/// Run whole-grammar FIRST analysis over `program`. The returned
/// table owns its storage via an arena; call `deinit` to free. Names
/// are duped into the arena so the table is safe to keep after the
/// AST parser is destroyed.
pub fn analyze(gpa: Allocator, program: ast.Program) !RuleFirstTable {
    var table: RuleFirstTable = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .rules = .empty,
        .where_scopes = .empty,
    };
    errdefer table.arena.deinit();

    const alloc = table.arena.allocator();

    // Duplicate rule names (which the main compiler rejects as a
    // diagnostic) are filtered once up-front. Every subsequent loop
    // iterates the canonical set, so "first rule with a given name
    // wins" holds uniformly across seed, fixed point, and downstream
    // walks -- no phantom where-scope bindings, no body clobber.
    const canonical = try collectCanonicalRules(alloc, program.items);

    // Seed: every rule and every where-binding starts at bottom.
    // `#[lr]` rules are seeded the same way; recursion is handled at
    // lookup time via ScopedResolver.self_lr, not via special
    // seeding.
    for (canonical) |r| {
        const owned_name = try alloc.dupe(u8, r.name);
        try table.rules.put(alloc, owned_name, Entry.bottom());

        if (r.where_bindings.len == 0) continue;
        try table.where_scopes.put(alloc, owned_name, .empty);
        const scope = table.where_scopes.getPtr(owned_name).?;
        for (r.where_bindings) |wb| {
            const wb_name = try alloc.dupe(u8, wb.name);
            const wb_gop = try scope.getOrPut(alloc, wb_name);
            if (!wb_gop.found_existing) wb_gop.value_ptr.* = Entry.bottom();
        }
    }

    // Fixed point. A single ScopedResolver is mutated between rules
    // and between body-vs-where passes; the backing `first.Resolver`
    // handle stays stable across iterations.
    var scoped: ScopedResolver = .{ .table = &table };
    const rsv = scoped.resolver();

    // Scratch set for deduping where-binding names per rule per
    // iteration (see note in the where-binding branch below). Held
    // outside the loop so we recycle capacity.
    var seen_binding: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_binding.deinit(gpa);

    while (true) {
        var changed = false;
        for (canonical) |r| {
            // Rule body: scope to this rule; bind self_lr when `#[lr]`.
            scoped.rule_name = r.name;
            scoped.self_lr = if (r.attrs.lr) r.name else null;
            if (try reanalyze(alloc, &table.rules, r.name, &r.body, rsv)) {
                changed = true;
            }

            // Where bindings share the rule's where-scope. No self_lr:
            // where bindings don't carry attributes today. Duplicate
            // binding names (accepted by the parser, rejected later as
            // a compiler diagnostic) are first-wins here: analyzing
            // both would overwrite the same scope key with differing
            // FIRSTs and the fixed point would oscillate.
            scoped.self_lr = null;
            if (r.where_bindings.len > 0) {
                const scope = table.where_scopes.getPtr(r.name).?;
                seen_binding.clearRetainingCapacity();
                for (r.where_bindings) |wb| {
                    const gop = try seen_binding.getOrPut(gpa, wb.name);
                    if (gop.found_existing) continue;
                    if (try reanalyze(alloc, scope, wb.name, &wb.body, rsv)) {
                        changed = true;
                    }
                }
            }
        }
        if (!changed) break;
    }

    return table;
}

/// Collect pointers to the first-declared rule per name. Subsequent
/// rules with a duplicate name are excluded entirely: the main
/// compiler will report the duplicate as a diagnostic, and keeping
/// them in analyzer loops would cross-pollute the first rule's
/// scope with the duplicate's bindings and body.
fn collectCanonicalRules(
    alloc: Allocator,
    items: []const ast.TopLevel,
) ![]*const ast.Rule {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(alloc);
    var out: std.ArrayListUnmanaged(*const ast.Rule) = .empty;
    for (items) |*item| {
        if (item.* != .rule) continue;
        const gop = try seen.getOrPut(alloc, item.rule.name);
        if (gop.found_existing) continue;
        try out.append(alloc, &item.rule);
    }
    return out.toOwnedSlice(alloc);
}

// Recompute one entry. Returns true when the entry changed. Skips
// recomputation when the current entry is already `known=false`
// (unknown is the lattice top; once there, stay there).
fn reanalyze(
    alloc: Allocator,
    map: *std.StringHashMapUnmanaged(Entry),
    key: []const u8,
    body: *const ast.Expr,
    rsv: first.Resolver,
) !bool {
    const cur = map.get(key).?;
    if (!cur.known) return false;

    const computed = first.computeWithResolver(body, rsv);
    const new_entry: Entry = if (computed) |info|
        .{ .first = info, .known = true }
    else
        Entry.unknown();

    if (entriesEqual(cur, new_entry)) return false;
    try map.put(alloc, key, new_entry);
    return true;
}

fn entriesEqual(a: Entry, b: Entry) bool {
    if (a.known != b.known) return false;
    if (!a.known) return true;
    if (a.first.nullable != b.first.nullable) return false;
    return std.mem.eql(u8, &a.first.bits, &b.first.bits);
}

/// Source-level rewrite: for every `#[longest](...)` group whose
/// arms have pairwise-disjoint, non-nullable FIRST sets, overwrite
/// the `#[longest]` prefix (up to and including the closing `]`)
/// with spaces. The opening `(` is left in place, so on re-scan the
/// tokens read as a parenthesized expression and the compiler emits
/// ordered choice instead of longest-match.
///
/// Rewrites in place. Byte-preserving, so all existing source
/// offsets -- line/column diagnostics, ABNF span maps -- remain
/// valid without remapping. A parse failure leaves the buffer
/// untouched; the main compiler reports the same errors. An
/// analysis failure also leaves the buffer untouched.
///
/// Invariant: the AST's name and literal slices point into `source`,
/// and `blank` overwrites those bytes in place. Anyone extending
/// this function to read AST string fields between blanks (e.g. to
/// log which rule got demoted) will see spaces where identifiers
/// used to be.
pub fn demoteLongestInPlace(allocator: Allocator, source: []u8) !void {
    var parser = ast.Parser.init(allocator, source);
    defer parser.deinit();
    const result = parser.parse() catch return;
    if (!result.ok()) return;

    var table = analyze(allocator, result.program) catch return;
    defer table.deinit();

    // One scoped resolver, mutated per rule so the same `Resolver`
    // handle drives every walk. `disjointness_mode` makes a self-LR
    // lookup return unknown instead of bottom, so a recursive arm
    // cannot be silently classified as disjoint.
    var scoped: ScopedResolver = .{ .table = &table, .disjointness_mode = true };
    const rsv = scoped.resolver();

    const canonical = collectCanonicalRules(allocator, result.program.items) catch return;
    defer allocator.free(canonical);

    for (canonical) |r| {
        scoped.rule_name = r.name;
        scoped.self_lr = if (r.attrs.lr) r.name else null;
        demoteInExpr(&r.body, source, rsv);

        // Where bindings share the rule's scope but not the
        // `#[lr]` self-ref trick -- bindings don't carry
        // attributes.
        scoped.self_lr = null;
        for (r.where_bindings) |wb| demoteInExpr(&wb.body, source, rsv);
    }

    for (result.program.items) |item| {
        if (item != .bare_expr) continue;
        scoped.rule_name = null;
        scoped.self_lr = null;
        demoteInExpr(&item.bare_expr, source, rsv);
    }
}

fn demoteInExpr(expr: *const ast.Expr, source: []u8, rsv: first.Resolver) void {
    switch (expr.kind) {
        .longest => |arms| {
            if (first.canDemoteLongest(arms, rsv)) blank(source, expr.span.start);
            for (arms) |*a| demoteInExpr(a, source, rsv);
        },
        .sequence => |parts| for (parts) |*p| demoteInExpr(p, source, rsv),
        .choice => |arms| for (arms) |*a| demoteInExpr(a, source, rsv),
        .group => |inner| demoteInExpr(inner, source, rsv),
        .capture => |cap| demoteInExpr(cap.body, source, rsv),
        .quantifier => |q| demoteInExpr(q.operand, source, rsv),
        .lookahead => |la| demoteInExpr(la.operand, source, rsv),
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

const testing = std.testing;

// Parse a grammar into an AST, analyze it, and return both. Tests
// keep the parser alive because the AST's arena owns rule-body
// pointers the analyzer reads from. The returned table, in contrast,
// owns its keys -- so it outlives the parser if needed.
const Fixture = struct {
    parser: ast.Parser,
    program: ast.Program,
    table: RuleFirstTable,

    fn init(src: []const u8) !Fixture {
        var p = ast.Parser.init(testing.allocator, src);
        const r = try p.parse();
        if (!r.ok()) {
            p.deinit();
            return error.ParseFailed;
        }
        const tbl = try analyze(testing.allocator, r.program);
        return .{ .parser = p, .program = r.program, .table = tbl };
    }

    fn deinit(self: *Fixture) void {
        self.table.deinit();
        self.parser.deinit();
    }
};

test "single literal rule: FIRST and nullable" {
    var f = try Fixture.init("greet = \"hi\";");
    defer f.deinit();
    const e = f.table.rules.get("greet").?;
    try testing.expect(e.known);
    try testing.expect(e.first.contains('h'));
    try testing.expect(!e.first.contains('i'));
    try testing.expect(!e.first.nullable);
}

test "cross-rule reference: caller inherits callee's FIRST" {
    var f = try Fixture.init(
        \\a = "hi";
        \\b = a;
    );
    defer f.deinit();
    const b = f.table.rules.get("b").?;
    try testing.expect(b.known);
    try testing.expect(b.first.contains('h'));
    try testing.expect(!b.first.nullable);
}

test "choice of rule references unions FIRSTs" {
    var f = try Fixture.init(
        \\alpha = ['a'-'z'];
        \\digit = ['0'-'9'];
        \\tok = alpha / digit;
    );
    defer f.deinit();
    const tok = f.table.rules.get("tok").?;
    try testing.expect(tok.known);
    try testing.expect(tok.first.contains('a'));
    try testing.expect(tok.first.contains('m'));
    try testing.expect(tok.first.contains('5'));
    try testing.expect(!tok.first.contains('0' - 1));
    try testing.expect(!tok.first.nullable);
}

test "nullable propagates through rule reference" {
    var f = try Fixture.init(
        \\maybe_x = 'x'?;
        \\ref = maybe_x 'y';
    );
    defer f.deinit();
    const ref = f.table.rules.get("ref").?;
    try testing.expect(ref.known);
    try testing.expect(ref.first.contains('x'));
    try testing.expect(ref.first.contains('y'));
    try testing.expect(!ref.first.nullable);
}

test "mutual recursion converges" {
    // a = 'x' b?; b = 'y' a?;
    // FIRST(a) = {x}, FIRST(b) = {y}, neither nullable.
    var f = try Fixture.init(
        \\a = 'x' b?;
        \\b = 'y' a?;
    );
    defer f.deinit();
    const a = f.table.rules.get("a").?;
    const b = f.table.rules.get("b").?;
    try testing.expect(a.known);
    try testing.expect(b.known);
    try testing.expect(a.first.contains('x'));
    try testing.expect(!a.first.contains('y'));
    try testing.expect(b.first.contains('y'));
    try testing.expect(!b.first.contains('x'));
    try testing.expect(!a.first.nullable);
    try testing.expect(!b.first.nullable);
}

test "self-reference with nullable path converges" {
    // r = 'x' r?;  -- FIRST(r) = {x}, not nullable.
    var f = try Fixture.init("r = 'x' r?;");
    defer f.deinit();
    const r = f.table.rules.get("r").?;
    try testing.expect(r.known);
    try testing.expect(r.first.contains('x'));
    try testing.expect(!r.first.nullable);
}

test "lr rule FIRST comes from seed arms only" {
    // Direct LR: recursive arm contributes nothing, seed arm drives
    // FIRST. FIRST(expr) = FIRST(term) = digits.
    var f = try Fixture.init(
        \\#[lr]
        \\expr = expr "+" term / term;
        \\term = ['0'-'9']+;
    );
    defer f.deinit();
    const expr = f.table.rules.get("expr").?;
    try testing.expect(expr.known);
    try testing.expect(expr.first.contains('5'));
    try testing.expect(!expr.first.contains('+'));
    try testing.expect(!expr.first.nullable);
}

test "caller of lr rule inherits seed FIRST" {
    var f = try Fixture.init(
        \\#[lr]
        \\expr = expr "+" term / term;
        \\term = ['0'-'9']+;
        \\stmt = expr ';';
    );
    defer f.deinit();
    const stmt = f.table.rules.get("stmt").?;
    try testing.expect(stmt.known);
    try testing.expect(stmt.first.contains('5'));
    try testing.expect(!stmt.first.nullable);
}

test "lr rule with no seed arm has empty FIRST" {
    // Pure recursion with no seed: the rule can never match.
    // FIRST is empty, nullable false. `known=true` because we
    // analyzed it soundly -- there's just nothing to be first.
    var f = try Fixture.init(
        \\#[lr]
        \\r = r "x";
    );
    defer f.deinit();
    const r = f.table.rules.get("r").?;
    try testing.expect(r.known);
    try testing.expect(!r.first.nullable);
    var b: u16 = 0;
    while (b < 256) : (b += 1) try testing.expect(!r.first.contains(@intCast(b)));
}

test "indirect lr converges through intermediate rule" {
    // `expr` is the LR rule. Its first arm calls `wrap`, which calls
    // `expr` back. The fixed point resolves without special indirect
    // handling: on each iteration the self-ref returns bottom for
    // `expr`, `wrap` inherits whatever FIRST(expr) stabilized at,
    // and the seed arm anchors the result.
    var f = try Fixture.init(
        \\#[lr]
        \\expr = wrap "+" term / term;
        \\wrap = expr;
        \\term = ['0'-'9']+;
    );
    defer f.deinit();
    const expr = f.table.rules.get("expr").?;
    const wrap = f.table.rules.get("wrap").?;
    try testing.expect(expr.known);
    try testing.expect(wrap.known);
    try testing.expect(expr.first.contains('5'));
    try testing.expect(wrap.first.contains('5'));
}

test "unresolved rule reference is unknown" {
    var f = try Fixture.init("a = missing;");
    defer f.deinit();
    const a = f.table.rules.get("a").?;
    try testing.expect(!a.known);
}

test "unresolved ref through a choice poisons the rule" {
    var f = try Fixture.init(
        \\a = 'x' / missing;
    );
    defer f.deinit();
    const a = f.table.rules.get("a").?;
    try testing.expect(!a.known);
}

test "where-bound reference resolves via enclosing scope" {
    var f = try Fixture.init(
        \\kv = k "=" v
        \\  where
        \\    k = ['a'-'z']+;
        \\    v = ['0'-'9']+
        \\  end;
    );
    defer f.deinit();
    const kv = f.table.rules.get("kv").?;
    try testing.expect(kv.known);
    try testing.expect(kv.first.contains('a'));
    try testing.expect(kv.first.contains('z'));
    try testing.expect(!kv.first.contains('0'));
    try testing.expect(!kv.first.nullable);
}

test "where bindings are independently addressable" {
    var f = try Fixture.init(
        \\kv = k "=" v
        \\  where
        \\    k = ['a'-'z']+;
        \\    v = ['0'-'9']+
        \\  end;
    );
    defer f.deinit();
    const k = f.table.lookupWhere("kv", "k").?;
    const v = f.table.lookupWhere("kv", "v").?;
    try testing.expect(k.contains('a'));
    try testing.expect(!k.contains('5'));
    try testing.expect(v.contains('5'));
    try testing.expect(!v.contains('a'));
}

test "where binding shadows same-named top-level rule" {
    // Top-level `k` uses `'X'`; inside `outer`, `k` refers to the
    // where binding (letters). Outer's FIRST must come from letters,
    // not 'X'.
    var f = try Fixture.init(
        \\k = 'X';
        \\outer = k "!"
        \\  where
        \\    k = ['a'-'z']
        \\  end;
    );
    defer f.deinit();
    const outer = f.table.rules.get("outer").?;
    try testing.expect(outer.known);
    try testing.expect(outer.first.contains('a'));
    try testing.expect(!outer.first.contains('X'));
}

test "where binding can reference a sibling where binding" {
    var f = try Fixture.init(
        \\outer = a
        \\  where
        \\    a = b;
        \\    b = 'q'
        \\  end;
    );
    defer f.deinit();
    const outer = f.table.rules.get("outer").?;
    try testing.expect(outer.known);
    try testing.expect(outer.first.contains('q'));
}

test "where binding can reference a top-level rule" {
    var f = try Fixture.init(
        \\top = 'T';
        \\outer = a
        \\  where
        \\    a = top
        \\  end;
    );
    defer f.deinit();
    const outer = f.table.rules.get("outer").?;
    try testing.expect(outer.known);
    try testing.expect(outer.first.contains('T'));
}

test "duplicate where-binding names don't loop the fixed point" {
    // Two where bindings share the name `k` but have different bodies.
    // They map to the same scope key; if the fixed-point loop analyzes
    // both without dedup, each iteration flips the entry between the
    // two bodies' FIRSTs and `changed` never settles.
    var f = try Fixture.init(
        \\kv = k
        \\  where
        \\    k = 'x';
        \\    k = 'y'
        \\  end;
    );
    defer f.deinit();
    // If we got here, the fixed point terminated. Either binding's
    // FIRST is acceptable -- the main compiler reports the duplicate
    // as a diagnostic; the analyzer's job is only to not hang.
    const k = f.table.lookupWhere("kv", "k").?;
    try testing.expect(k.contains('x') or k.contains('y'));
}

test "table keys survive the parser" {
    // Build a fixture, drop the parser, then read the table. The
    // arena-duped keys must still be live.
    var p = ast.Parser.init(testing.allocator, "r = 'x';");
    const r = try p.parse();
    try testing.expect(r.ok());
    var tbl = try analyze(testing.allocator, r.program);
    defer tbl.deinit();
    p.deinit(); // frees AST arena; table must be independent.

    const e = tbl.rules.get("r").?;
    try testing.expect(e.known);
    try testing.expect(e.first.contains('x'));
}

test "resolver() roundtrips through computeWithResolver" {
    var f = try Fixture.init(
        \\alpha = ['a'-'z'];
        \\word = alpha+;
    );
    defer f.deinit();
    const word_body = &f.program.items[1].rule.body;
    const info = first.computeWithResolver(word_body, f.table.resolver()).?;
    try testing.expect(info.contains('a'));
    try testing.expect(info.contains('z'));
    try testing.expect(!info.nullable);
}

test "demoteLongestInPlace: disjoint literals are demoted" {
    const src = "a = #[longest](\"GET\" / \"POST\" / \"DELETE\");";
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    try demoteLongestInPlace(testing.allocator, buf);
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
    try testing.expectEqual(
        @as(usize, std.mem.count(u8, src, "\n")),
        std.mem.count(u8, buf, "\n"),
    );
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

test "demoteLongestInPlace: rule_ref arms demote via the table" {
    // The whole-grammar path's raison d'etre: arms that are bare
    // rule calls were opaque to the local analyzer. `alpha` and
    // `digit` have disjoint FIRSTs through the table, so the
    // longest-match can be demoted to ordered choice.
    const src =
        \\alpha = ['a'-'z'];
        \\digit = ['0'-'9'];
        \\tok = #[longest](alpha / digit);
    ;
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    try demoteLongestInPlace(testing.allocator, buf);
    try testing.expect(std.mem.indexOf(u8, buf, "#[longest]") == null);
}

test "demoteLongestInPlace: rule_ref arms with overlapping FIRST are kept" {
    // Both arms' FIRSTs include 'a'. Demotion would change which
    // strings match, so the table must say "no."
    const src =
        \\letters = ['a'-'z'];
        \\alnum = ['a'-'z' '0'-'9'];
        \\tok = #[longest](letters / alnum);
    ;
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    try demoteLongestInPlace(testing.allocator, buf);
    try testing.expect(std.mem.indexOf(u8, buf, "#[longest]") != null);
}

test "demoteLongestInPlace: unresolved rule_ref arm blocks demotion" {
    // `missing` isn't defined, so the table entry is known=false.
    // That poisons the disjointness check and the longest stays.
    const src =
        \\alpha = ['a'-'z'];
        \\tok = #[longest](alpha / missing);
    ;
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    try demoteLongestInPlace(testing.allocator, buf);
    try testing.expect(std.mem.indexOf(u8, buf, "#[longest]") != null);
}

test "demoteLongestInPlace: where-binding arms demote through scope" {
    // The two arms refer to `a` and `b` which are where-scoped
    // bindings with disjoint FIRSTs. Only the scoped resolver can
    // see them; demotion should fire.
    const src =
        \\outer = #[longest](a / b)
        \\  where
        \\    a = "x";
        \\    b = "y"
        \\  end;
    ;
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    try demoteLongestInPlace(testing.allocator, buf);
    try testing.expect(std.mem.indexOf(u8, buf, "#[longest]") == null);
}

test "demoteLongestInPlace: self-lr arm blocks demotion" {
    // Self-reference is a longest arm. Without `disjointness_mode`,
    // ScopedResolver returns `FirstInfo.empty()` for the self-ref,
    // which `canDemoteLongest` reads as "disjoint with everything"
    // and silently rewrites the rule. Ordered choice coincides with
    // longest here by accident, but the reasoning is unsound: bottom
    // is not runtime-empty FIRST. With the flag on, the lookup
    // returns null, canDemoteLongest bails, and `#[longest]` stays.
    const src =
        \\#[lr]
        \\expr = #[longest](expr "+" term / term);
        \\term = ['0'-'9']+;
    ;
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    try demoteLongestInPlace(testing.allocator, buf);
    try testing.expect(std.mem.indexOf(u8, buf, "#[longest]") != null);
}

test "demoteLongestInPlace: duplicate rule name doesn't cross-pollute first's scope" {
    // Two rules named `foo`. The first's arms reference top-level
    // `x`/`y` (same FIRST -> overlap -> no demote). The second has a
    // where-scope rebinding `x`/`y` to disjoint literals. Before the
    // canonical-rule filter, the seed loop merged those bindings
    // into where_scopes["foo"], and the walker resolved the first
    // foo's rule_refs via those phantom bindings -- falsely disjoint
    // -> spurious demote.
    const src =
        \\x = "same";
        \\y = "same";
        \\foo = #[longest](x / y);
        \\foo = #[longest](x / y)
        \\  where
        \\    x = "a";
        \\    y = "b"
        \\  end;
    ;
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    try demoteLongestInPlace(testing.allocator, buf);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, buf, "#[longest]"));
}

test "demoteLongestInPlace: lr rule doesn't poison its own demotion" {
    // The `#[lr]` rule's seed arm `#[longest](alpha / digit)` has
    // disjoint arms that resolve via the table. The self-reference
    // in the non-seed arm is handled by ScopedResolver.self_lr --
    // it doesn't leak out of the LR rule to prevent the demotion
    // inside.
    const src =
        \\alpha = ['a'-'z'];
        \\digit = ['0'-'9'];
        \\#[lr]
        \\expr = expr "." tail / #[longest](alpha / digit);
        \\tail = alpha+;
    ;
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    try demoteLongestInPlace(testing.allocator, buf);
    try testing.expect(std.mem.indexOf(u8, buf, "#[longest]") == null);
}
