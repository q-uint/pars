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
//! FIRST(R). The fixed point handles indirect cycles naturally —
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

    pub fn resolver(self: *const ScopedResolver) first.Resolver {
        return .{
            .ctx = @ptrCast(self),
            .lookupFn = lookupAdapter,
        };
    }

    fn lookupAdapter(ctx: *const anyopaque, name: []const u8) ?FirstInfo {
        const self: *const ScopedResolver = @ptrCast(@alignCast(ctx));
        if (self.self_lr) |s| if (std.mem.eql(u8, s, name)) {
            // `#[lr]` self-reference contributes bottom, not null:
            // the call is well-understood (it's the LR loop), it
            // just doesn't add to FIRST at this point.
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

    // Seed: every rule and every where-binding starts at bottom.
    // `#[lr]` rules are seeded the same way; recursion is handled at
    // lookup time via ScopedResolver.self_lr, not via special
    // seeding.
    //
    // Duplicate names (which the main compiler rejects as a
    // diagnostic) keep the first binding here. The analyzer only
    // needs one entry per name; the main pipeline surfaces the
    // duplication separately.
    for (program.items) |item| {
        if (item != .rule) continue;
        const r = item.rule;
        const owned_name = try alloc.dupe(u8, r.name);
        const gop = try table.rules.getOrPut(alloc, owned_name);
        if (!gop.found_existing) gop.value_ptr.* = Entry.bottom();

        if (r.where_bindings.len == 0) continue;
        const scope_gop = try table.where_scopes.getOrPut(alloc, owned_name);
        if (!scope_gop.found_existing) scope_gop.value_ptr.* = .empty;
        const scope = scope_gop.value_ptr;
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

    while (true) {
        var changed = false;
        for (program.items) |item| {
            if (item != .rule) continue;
            const r = item.rule;

            // Rule body: scope to this rule; bind self_lr when `#[lr]`.
            scoped.rule_name = r.name;
            scoped.self_lr = if (r.attrs.lr) r.name else null;
            if (try reanalyze(alloc, &table.rules, r.name, &r.body, rsv)) {
                changed = true;
            }

            // Where bindings share the rule's where-scope. No self_lr:
            // where bindings don't carry attributes today.
            scoped.self_lr = null;
            if (r.where_bindings.len > 0) {
                const scope = table.where_scopes.getPtr(r.name).?;
                for (r.where_bindings) |wb| {
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

// Recompute one entry. Returns true when the entry changed. Skips
// recomputation when the current entry is already `known=false`
// (unknown is the lattice top; once there, stay there).
fn reanalyze(
    alloc: Allocator,
    map: anytype,
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
