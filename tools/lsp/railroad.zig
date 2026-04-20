//! Railroad diagram IR and AST-to-IR lowering. The LSP exposes this
//! through the `pars/railroad` request; the VS Code extension
//! serializes the resulting tree to JSON and hands it to a pure-JS
//! renderer (tabatkins/railroad-diagrams) in a webview.
//!
//! The node vocabulary is deliberately close to what the JS renderer
//! accepts, so the webview dispatches on `kind` with minimal
//! translation. Constructs that have no direct railroad primitive
//! (lookaheads, captures, `#[longest]`, bounded quantifiers, cuts)
//! become labelled `group` or `comment` nodes — the lossless fallback
//! that keeps every operator visible.
//!
//! Non-terminal nodes preserve the referenced rule name so the UI can
//! expand them inline on click.

const std = @import("std");
const pars = @import("pars");

const Allocator = std.mem.Allocator;
const ast = pars.ast;

pub const Node = union(enum) {
    /// A literal atom to match. `text` is the display form, not the
    /// decoded bytes: `"foo"`, `i"bar"`, `'a'`, `[a-z0-9]`, `.`.
    terminal: []const u8,
    /// Reference to a named rule. `name` is the raw identifier; the
    /// renderer keys expansion lookups off it.
    non_terminal: []const u8,
    sequence: []const Node,
    choice: []const Node,
    optional: *const Node,
    zero_or_more: *const Node,
    one_or_more: *const Node,
    /// Visual wrapper with a caption. Used for constructs that don't
    /// have a first-class railroad primitive: lookaheads (`!A`, `&A`),
    /// named captures (`<x: A>`), `#[longest](...)`, and bounded
    /// quantifiers (`A{n,m}`).
    group: Group,
    /// Inline annotation with no sub-structure. Used for cut markers.
    comment: []const u8,
};

pub const Group = struct {
    label: []const u8,
    child: *const Node,
};

/// Lower a pars AST expression into a railroad node tree. All nodes
/// and slices are allocated from `arena`; the caller owns the arena
/// and frees it when done with the result.
pub fn lower(arena: Allocator, expr: ast.Expr) Allocator.Error!Node {
    return lowerExpr(arena, expr);
}

fn lowerExpr(arena: Allocator, expr: ast.Expr) Allocator.Error!Node {
    return switch (expr.kind) {
        .rule_ref => |name| .{ .non_terminal = name },
        .any_byte => .{ .terminal = "." },
        .char_lit => |byte| .{ .terminal = try formatCharLit(arena, byte) },
        .string_lit => |s| .{ .terminal = try formatStringLit(arena, s) },
        .charset => |items| .{ .terminal = try formatCharset(arena, items) },
        .cut => .{ .comment = "^" },
        .cut_labeled => |label| .{ .comment = try std.fmt.allocPrint(arena, "^\"{s}\"", .{label}) },
        .group => |inner| try lowerExpr(arena, inner.*),
        .sequence => |parts| try lowerSequence(arena, parts),
        .choice => |arms| try lowerChoice(arena, arms),
        .longest => |arms| blk: {
            const inner = try lowerChoice(arena, arms);
            break :blk try wrapGroup(arena, "longest", inner);
        },
        .quantifier => |q| try lowerQuantifier(arena, q),
        .lookahead => |la| blk: {
            const inner = try lowerExpr(arena, la.operand.*);
            const label: []const u8 = if (la.negative) "!" else "&";
            break :blk try wrapGroup(arena, label, inner);
        },
        .capture => |c| blk: {
            const inner = try lowerExpr(arena, c.body.*);
            const label = try std.fmt.allocPrint(arena, "{s}:", .{c.name});
            break :blk try wrapGroup(arena, label, inner);
        },
    };
}

fn lowerSequence(arena: Allocator, parts: []const ast.Expr) Allocator.Error!Node {
    const out = try arena.alloc(Node, parts.len);
    for (parts, 0..) |p, i| out[i] = try lowerExpr(arena, p);
    return .{ .sequence = out };
}

fn lowerChoice(arena: Allocator, arms: []const ast.Expr) Allocator.Error!Node {
    const out = try arena.alloc(Node, arms.len);
    for (arms, 0..) |a, i| out[i] = try lowerExpr(arena, a);
    return .{ .choice = out };
}

fn lowerQuantifier(arena: Allocator, q: ast.Quantifier) Allocator.Error!Node {
    const operand = try boxed(arena, try lowerExpr(arena, q.operand.*));
    return switch (q.kind) {
        .star => .{ .zero_or_more = operand },
        .plus => .{ .one_or_more = operand },
        .question => .{ .optional = operand },
        .bounded => |b| .{ .group = .{ .label = try formatBounds(arena, b), .child = operand } },
    };
}

fn wrapGroup(arena: Allocator, label: []const u8, child: Node) Allocator.Error!Node {
    return .{ .group = .{ .label = label, .child = try boxed(arena, child) } };
}

fn boxed(arena: Allocator, node: Node) Allocator.Error!*const Node {
    const p = try arena.create(Node);
    p.* = node;
    return p;
}

fn formatCharLit(arena: Allocator, byte: u8) Allocator.Error![]const u8 {
    return switch (byte) {
        '\n' => "'\\n'",
        '\r' => "'\\r'",
        '\t' => "'\\t'",
        '\\' => "'\\\\'",
        '\'' => "'\\''",
        else => if (byte >= 0x20 and byte <= 0x7e)
            try std.fmt.allocPrint(arena, "'{c}'", .{byte})
        else
            try std.fmt.allocPrint(arena, "'\\x{x:0>2}'", .{byte}),
    };
}

fn formatStringLit(arena: Allocator, s: ast.StringLit) Allocator.Error![]const u8 {
    const prefix: []const u8 = if (s.case_insensitive) "i" else "";
    const delim: []const u8 = if (s.triple_quoted) "\"\"\"" else "\"";
    return std.fmt.allocPrint(arena, "{s}{s}{s}{s}", .{ prefix, delim, s.raw, delim });
}

fn formatCharset(arena: Allocator, items: []const ast.CharsetItem) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(arena, '[');
    for (items, 0..) |it, i| {
        if (i > 0) try buf.append(arena, ' ');
        switch (it) {
            .single => |c| try buf.appendSlice(arena, try formatCharLit(arena, c)),
            .range => |r| {
                try buf.appendSlice(arena, try formatCharLit(arena, r.lo));
                try buf.append(arena, '-');
                try buf.appendSlice(arena, try formatCharLit(arena, r.hi));
            },
        }
    }
    try buf.append(arena, ']');
    return buf.toOwnedSlice(arena);
}

fn formatBounds(arena: Allocator, b: ast.Bounds) Allocator.Error![]const u8 {
    if (b.min != null and b.max != null and b.min.? == b.max.?) {
        return std.fmt.allocPrint(arena, "{{{d}}}", .{b.min.?});
    }
    if (b.min != null and b.max == null) return std.fmt.allocPrint(arena, "{{{d},}}", .{b.min.?});
    if (b.min == null and b.max != null) return std.fmt.allocPrint(arena, "{{,{d}}}", .{b.max.?});
    return std.fmt.allocPrint(arena, "{{{d},{d}}}", .{ b.min orelse 0, b.max orelse 0 });
}

/// Serialize a node tree to JSON via the caller's stringifier. The
/// shape mirrors tabatkins/railroad-diagrams' primitives closely so
/// the JS side can dispatch on `kind` with minimal translation.
///
/// The explicit `anyerror` return type breaks the inferred-error-set
/// dependency loop between writeJson and its list/single helpers,
/// which call back into writeJson for nested children.
pub fn writeJson(s: *std.json.Stringify, node: Node) anyerror!void {
    switch (node) {
        .terminal => |text| try writeLeaf(s, "terminal", "text", text),
        .non_terminal => |name| try writeLeaf(s, "non_terminal", "name", name),
        .comment => |text| try writeLeaf(s, "comment", "text", text),
        .sequence => |items| try writeListNode(s, "sequence", items),
        .choice => |items| try writeListNode(s, "choice", items),
        .optional => |child| try writeSingleNode(s, "optional", child.*),
        .zero_or_more => |child| try writeSingleNode(s, "zero_or_more", child.*),
        .one_or_more => |child| try writeSingleNode(s, "one_or_more", child.*),
        .group => |g| {
            try s.beginObject();
            try s.objectField("kind");
            try s.write("group");
            try s.objectField("label");
            try s.write(g.label);
            try s.objectField("item");
            try writeJson(s, g.child.*);
            try s.endObject();
        },
    }
}

fn writeLeaf(s: *std.json.Stringify, kind: []const u8, field: []const u8, value: []const u8) !void {
    try s.beginObject();
    try s.objectField("kind");
    try s.write(kind);
    try s.objectField(field);
    try s.write(value);
    try s.endObject();
}

fn writeListNode(s: *std.json.Stringify, kind: []const u8, items: []const Node) !void {
    try s.beginObject();
    try s.objectField("kind");
    try s.write(kind);
    try s.objectField("items");
    try s.beginArray();
    for (items) |it| try writeJson(s, it);
    try s.endArray();
    try s.endObject();
}

fn writeSingleNode(s: *std.json.Stringify, kind: []const u8, child: Node) !void {
    try s.beginObject();
    try s.objectField("kind");
    try s.write(kind);
    try s.objectField("item");
    try writeJson(s, child);
    try s.endObject();
}

const testing = std.testing;

/// Parse `source`, lower the `rule_index`-th rule's body to a railroad
/// node, and serialize the result to JSON. Bundles everything a test
/// needs to assert both structural and wire-level shape.
const RoundTrip = struct {
    parser: *ast.Parser,
    arena: *std.heap.ArenaAllocator,
    json: []u8,
    node: Node,

    fn deinit(self: *RoundTrip) void {
        self.parser.deinit();
        testing.allocator.destroy(self.parser);
        self.arena.deinit();
        testing.allocator.destroy(self.arena);
        testing.allocator.free(self.json);
    }
};

fn roundTrip(source: []const u8, rule_index: usize) !RoundTrip {
    const parser = try testing.allocator.create(ast.Parser);
    parser.* = ast.Parser.init(testing.allocator, source);
    const r = try parser.parse();
    if (!r.ok()) {
        parser.deinit();
        testing.allocator.destroy(parser);
        return error.ParseFailed;
    }

    const arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);

    const expr = r.program.items[rule_index].rule.body;
    const node = try lower(arena.allocator(), expr);

    var aw = std.Io.Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try writeJson(&s, node);
    const json = try testing.allocator.dupe(u8, aw.writer.buffered());

    return .{ .parser = parser, .arena = arena, .json = json, .node = node };
}

test "rule reference lowers to non_terminal" {
    var rt = try roundTrip("foo = bar;", 0);
    defer rt.deinit();
    try testing.expect(rt.node == .non_terminal);
    try testing.expectEqualStrings("bar", rt.node.non_terminal);
}

test "string literal lowers to terminal with quotes" {
    var rt = try roundTrip("foo = \"hi\";", 0);
    defer rt.deinit();
    try testing.expectEqualStrings("\"hi\"", rt.node.terminal);
}

test "case-insensitive string keeps its prefix" {
    var rt = try roundTrip("foo = i\"hi\";", 0);
    defer rt.deinit();
    try testing.expectEqualStrings("i\"hi\"", rt.node.terminal);
}

test "char literal is rendered in single quotes" {
    var rt = try roundTrip("foo = 'x';", 0);
    defer rt.deinit();
    try testing.expectEqualStrings("'x'", rt.node.terminal);
}

test "char literal with non-printable byte uses hex escape" {
    var rt = try roundTrip("foo = '\\x01';", 0);
    defer rt.deinit();
    try testing.expectEqualStrings("'\\x01'", rt.node.terminal);
}

test "charset is rendered bracketed with items space-separated" {
    var rt = try roundTrip("foo = ['a'-'z' '_'];", 0);
    defer rt.deinit();
    try testing.expectEqualStrings("['a'-'z' '_']", rt.node.terminal);
}

test "any-byte dot is its own terminal" {
    var rt = try roundTrip("foo = .;", 0);
    defer rt.deinit();
    try testing.expectEqualStrings(".", rt.node.terminal);
}

test "sequence lowers to n-ary sequence node" {
    var rt = try roundTrip("foo = x y z;", 0);
    defer rt.deinit();
    try testing.expect(rt.node == .sequence);
    try testing.expectEqual(@as(usize, 3), rt.node.sequence.len);
}

test "choice lowers to n-ary choice node" {
    var rt = try roundTrip("foo = x / y | z;", 0);
    defer rt.deinit();
    try testing.expect(rt.node == .choice);
    try testing.expectEqual(@as(usize, 3), rt.node.choice.len);
}

test "quantifiers map to their railroad counterparts" {
    {
        var rt = try roundTrip("foo = x*;", 0);
        defer rt.deinit();
        try testing.expect(rt.node == .zero_or_more);
    }
    {
        var rt = try roundTrip("foo = x+;", 0);
        defer rt.deinit();
        try testing.expect(rt.node == .one_or_more);
    }
    {
        var rt = try roundTrip("foo = x?;", 0);
        defer rt.deinit();
        try testing.expect(rt.node == .optional);
    }
}

test "bounded quantifier renders as a labelled group" {
    var rt = try roundTrip("foo = x{2,5};", 0);
    defer rt.deinit();
    try testing.expect(rt.node == .group);
    try testing.expectEqualStrings("{2,5}", rt.node.group.label);
}

test "lookaheads become labelled groups" {
    {
        var rt = try roundTrip("foo = &x;", 0);
        defer rt.deinit();
        try testing.expect(rt.node == .group);
        try testing.expectEqualStrings("&", rt.node.group.label);
    }
    {
        var rt = try roundTrip("foo = !x;", 0);
        defer rt.deinit();
        try testing.expect(rt.node == .group);
        try testing.expectEqualStrings("!", rt.node.group.label);
    }
}

test "captures become labelled groups with name" {
    var rt = try roundTrip("foo = <q: x>;", 0);
    defer rt.deinit();
    try testing.expect(rt.node == .group);
    try testing.expectEqualStrings("q:", rt.node.group.label);
}

test "longest wraps a choice in a labelled group" {
    var rt = try roundTrip("foo = #[longest](x / y);", 0);
    defer rt.deinit();
    try testing.expect(rt.node == .group);
    try testing.expectEqualStrings("longest", rt.node.group.label);
    try testing.expect(rt.node.group.child.* == .choice);
}

test "cut renders as a comment" {
    var rt = try roundTrip("foo = ^;", 0);
    defer rt.deinit();
    try testing.expect(rt.node == .comment);
    try testing.expectEqualStrings("^", rt.node.comment);
}

test "labelled cut carries its label in the comment" {
    var rt = try roundTrip("foo = ^\"oops\";", 0);
    defer rt.deinit();
    try testing.expect(rt.node == .comment);
    try testing.expectEqualStrings("^\"oops\"", rt.node.comment);
}

test "groups in source collapse to their content" {
    var rt = try roundTrip("foo = (x / y);", 0);
    defer rt.deinit();
    try testing.expect(rt.node == .choice);
}

test "json shape: sequence of two non_terminals" {
    var rt = try roundTrip("foo = a b;", 0);
    defer rt.deinit();
    const expected =
        "{\"kind\":\"sequence\",\"items\":[" ++
        "{\"kind\":\"non_terminal\",\"name\":\"a\"}," ++
        "{\"kind\":\"non_terminal\",\"name\":\"b\"}" ++
        "]}";
    try testing.expectEqualStrings(expected, rt.json);
}

test "json shape: zero-or-more around a terminal" {
    var rt = try roundTrip("foo = \"a\"*;", 0);
    defer rt.deinit();
    const expected =
        "{\"kind\":\"zero_or_more\",\"item\":" ++
        "{\"kind\":\"terminal\",\"text\":\"\\\"a\\\"\"}" ++
        "}";
    try testing.expectEqualStrings(expected, rt.json);
}
