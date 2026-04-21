//! Whole-grammar FIRST / nullable analysis.
//!
//! Computes, for every rule in a program, the set of input bytes that
//! may begin a successful match and whether the rule may match the
//! empty string. Extends `first.zig`'s local analysis via a monotone
//! fixed point over the rule table: each iteration recomputes every
//! rule's entry using the current table as the resolver for
//! `rule_ref` subterms. Bits can only be added, `nullable` only flips
//! false -> true, so the lattice is finite and convergence is
//! guaranteed.
//!
//! Unanalyzable rules (bodies that contain malformed escapes, or that
//! transitively call a rule whose entry is itself unanalyzable) have
//! `known=false`. A `rule_ref` to a `known=false` rule poisons the
//! containing computation the same way the local analyzer's `null`
//! return does.
//!
//! Deliberately out of scope for this pass:
//!   - `#[lr]` rules are marked `known=false`. Sound FIRST for a
//!     directly left-recursive rule needs seed-arm classification
//!     (leftmost-call check); follow-up work.
//!   - `where` bindings: their names aren't in the top-level table,
//!     so a rule that references a where-binding falls through to an
//!     unresolved lookup and becomes `known=false`. Rules that use
//!     `where` but only reference top-level names analyze fine.
//!   - `use "..."` imports are not pre-expanded; unresolved names
//!     resolve to `known=false`. A future pass can merge imported
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

/// Rule name -> Entry, owned by an arena so key slices outlive the
/// AST the analyzer consumed. Free via `deinit`.
pub const RuleFirstTable = struct {
    arena: std.heap.ArenaAllocator,
    rules: std.StringHashMapUnmanaged(Entry),

    pub fn deinit(self: *RuleFirstTable) void {
        self.arena.deinit();
    }

    /// Look up a rule's FIRST/nullable. Returns null for unknown
    /// names or `known=false` entries -- the same null contract the
    /// local analyzer's `rule_ref` branch uses.
    pub fn lookup(self: *const RuleFirstTable, name: []const u8) ?FirstInfo {
        const entry = self.rules.get(name) orelse return null;
        if (!entry.known) return null;
        return entry.first;
    }

    /// A resolver suitable for `first.computeWithResolver`. Lookups
    /// consult the top-level table only; `where`-scope shadowing is
    /// not modeled yet.
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

/// Run whole-grammar FIRST analysis over `program`. The returned
/// table owns its storage via an arena; call `deinit` to free. Names
/// are duped into the arena so the table is safe to keep after the
/// AST parser is destroyed.
pub fn analyze(gpa: Allocator, program: ast.Program) !RuleFirstTable {
    var table: RuleFirstTable = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .rules = .empty,
    };
    errdefer table.arena.deinit();

    const alloc = table.arena.allocator();

    // Seed: every top-level rule starts at the bottom (empty FIRST,
    // not nullable). `#[lr]` rules seed as `unknown` and stay there --
    // their real FIRST requires seed-arm classification.
    //
    // Duplicate names (which the main compiler rejects as a
    // diagnostic) keep the first binding here. The analyzer only
    // needs one entry per name; the main pipeline will surface the
    // duplication separately.
    for (program.items) |item| {
        switch (item) {
            .rule => |r| {
                const entry: Entry = if (r.attrs.lr) Entry.unknown() else Entry.bottom();
                const owned_name = try alloc.dupe(u8, r.name);
                const gop = try table.rules.getOrPut(alloc, owned_name);
                if (gop.found_existing) {
                    // Name was already duped on the first insertion;
                    // the second dupe is unreferenced but the arena
                    // frees it in bulk, so no leak.
                } else {
                    gop.value_ptr.* = entry;
                }
            },
            .use_decl, .tagged_block, .bare_expr => {},
        }
    }

    // Fixed point. Each iteration recomputes every analyzable rule's
    // entry with the current table as the resolver; termination is
    // guaranteed by monotonicity on a finite lattice.
    const rsv = table.resolver();
    while (true) {
        var changed = false;
        for (program.items) |item| {
            if (item != .rule) continue;
            const r = item.rule;
            const cur = table.rules.get(r.name).?;
            // `known=false` is sticky: `#[lr]` rules stay unknown,
            // and rules that turned unknown on a previous iteration
            // can't recover (the lattice is monotone on bits, but
            // knownness is a one-way transition).
            if (!cur.known) continue;

            const computed = first.computeWithResolver(&r.body, rsv);
            const new_entry: Entry = if (computed) |info|
                .{ .first = info, .known = true }
            else
                Entry.unknown();

            if (!entriesEqual(cur, new_entry)) {
                try table.rules.put(alloc, r.name, new_entry);
                changed = true;
            }
        }
        if (!changed) break;
    }

    return table;
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

test "lr rule is marked unknown" {
    var f = try Fixture.init(
        \\#[lr]
        \\expr = expr "+" term / term;
        \\term = ['0'-'9']+;
    );
    defer f.deinit();
    const expr = f.table.rules.get("expr").?;
    try testing.expect(!expr.known);
    const term = f.table.rules.get("term").?;
    try testing.expect(term.known);
    try testing.expect(term.first.contains('5'));
}

test "caller of lr rule is poisoned to unknown" {
    var f = try Fixture.init(
        \\#[lr]
        \\expr = expr "+" term / term;
        \\term = ['0'-'9']+;
        \\stmt = expr ';';
    );
    defer f.deinit();
    const stmt = f.table.rules.get("stmt").?;
    try testing.expect(!stmt.known);
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

test "where-bound reference falls through to unknown (conservative)" {
    // `k` is a where-binding, not a top-level rule. The current
    // analyzer doesn't model where-scopes, so the rule_ref to `k`
    // fails to resolve and the rule becomes known=false. Documented
    // limitation; lifted when where-scope support lands.
    var f = try Fixture.init(
        \\kv = k "=" v
        \\  where
        \\    k = ['a'-'z']+;
        \\    v = ['0'-'9']+
        \\  end;
    );
    defer f.deinit();
    const kv = f.table.rules.get("kv").?;
    try testing.expect(!kv.known);
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
