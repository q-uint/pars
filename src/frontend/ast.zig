//! Typed AST for the pars language. Produced by a standalone parser
//! that is purely structural: no name resolution, no charset bit-packing,
//! no semantic validation beyond what the grammar requires. The main
//! compiler still goes straight from tokens to bytecode; this module
//! exists to feed consumers that want an explicit tree — railroad
//! diagram rendering today, whole-grammar analysis and an eventual
//! AST-driven lowering later.
//!
//! Every node carries a source span so tooling can map back to bytes
//! without re-parsing. Slices and pointers are owned by the parser's
//! arena and freed together on `Parser.deinit`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const scanner_mod = @import("scanner.zig");
const literal = @import("literal.zig");
const Scanner = scanner_mod.Scanner;
const Token = scanner_mod.Token;
const TokenType = scanner_mod.TokenType;

/// Byte-offset span into the source. `line` is the 1-based line of the
/// first byte so renderers can anchor diagnostics without a second pass.
pub const Span = struct {
    start: u32,
    len: u32,
    line: u32,

    pub fn end(self: Span) u32 {
        return self.start + self.len;
    }
};

pub const Program = struct {
    items: []const TopLevel,
};

pub const TopLevel = union(enum) {
    use_decl: UseDecl,
    tagged_block: TaggedBlock,
    rule: Rule,
    /// Bare top-level expression. The compiler emits these into the
    /// main chunk as the match entry point when present.
    bare_expr: Expr,
};

pub const UseDecl = struct {
    /// Module path with the surrounding quotes stripped.
    path: []const u8,
    path_span: Span,
    span: Span,
};

pub const TaggedBlock = struct {
    /// Tag name, e.g. `abnf` in `@abnf"""..."""`.
    tag: []const u8,
    tag_span: Span,
    /// Body bytes between the opening and closing triple quotes,
    /// verbatim. No escape processing.
    body: []const u8,
    body_span: Span,
    span: Span,
};

/// Declaration-level attributes recognized by the parser. Mirrors the
/// bitset the compiler tracks on `RuleTable` but kept separate so the
/// AST module doesn't depend on compile-side types.
pub const Attrs = struct {
    /// `#[lr]` — opts the rule into direct left recursion.
    lr: bool = false,
};

pub const Rule = struct {
    name: []const u8,
    name_span: Span,
    attrs: Attrs,
    body: Expr,
    /// Sub-rule definitions introduced by a trailing `where` block.
    /// Empty when the rule has no `where`.
    where_bindings: []const WhereBinding,
    span: Span,
};

pub const WhereBinding = struct {
    name: []const u8,
    name_span: Span,
    body: Expr,
    span: Span,
};

pub const Expr = struct {
    kind: ExprKind,
    span: Span,
};

pub const ExprKind = union(enum) {
    /// Reference to an identifier: either a rule name, a where-binding,
    /// or a capture back-reference. The AST does not resolve which —
    /// that is a name-resolution concern for consumers.
    ///
    /// TODO: capture back-refs need separate analysis semantics. When
    /// a back-ref's name shadows a top-level rule, FIRST analysis
    /// currently treats the ref as a call to that rule. Safe for
    /// disjointness (a superset FIRST cannot falsely claim
    /// disjointness) but unsafe for nullable: a nullable capture body
    /// whose name shadows a non-nullable rule gets the rule's
    /// nullable=false, which `canDemoteLongest` relies on. Latent
    /// today — ABNF-lowered source emits no captures, and
    /// `demoteLongestInPlace` only runs on that source. Fix is either
    /// a name-resolution pass before FIRST or an `is_backref` bit
    /// populated at parse time.
    rule_ref: []const u8,
    string_lit: StringLit,
    char_lit: u8,
    charset: []const CharsetItem,
    any_byte,
    group: *const Expr,
    capture: Capture,
    /// `#[longest](A / B / ...)` — arms in source order.
    longest: []const Expr,
    /// Bare `^` commit marker.
    cut,
    /// `^"label"` commit marker with failure label.
    cut_labeled: []const u8,
    /// N-ary ordered choice, arms in source order. Flattened at parse
    /// time so `A / B / C` is one node with three arms.
    choice: []const Expr,
    /// N-ary sequence (juxtaposition), parts in source order.
    sequence: []const Expr,
    quantifier: Quantifier,
    lookahead: Lookahead,
};

pub const StringLit = struct {
    /// Content between the delimiters, verbatim. Escape sequences like
    /// `\n` are preserved as-is — the compiler matches on raw bytes,
    /// and any consumer that wants decoded bytes should decode itself.
    raw: []const u8,
    case_insensitive: bool,
    triple_quoted: bool,
};

pub const CharsetItem = union(enum) {
    single: u8,
    range: struct { lo: u8, hi: u8 },
};

pub const Capture = struct {
    name: []const u8,
    name_span: Span,
    body: *const Expr,
};

pub const Quantifier = struct {
    operand: *const Expr,
    kind: QuantKind,
};

pub const QuantKind = union(enum) {
    star,
    plus,
    question,
    /// `A{n}`, `A{n,m}`, `A{n,}`, `A{,m}`. At least one of `min` or
    /// `max` is set; the parser rejects the `{}` form.
    bounded: Bounds,
};

pub const Bounds = struct {
    min: ?u32,
    max: ?u32,
};

pub const Lookahead = struct {
    operand: *const Expr,
    /// True for `!A`, false for `&A`.
    negative: bool,
};

pub const ParseError = struct {
    message: []const u8,
    span: Span,
};

pub const ParseResult = struct {
    program: Program,
    errors: []const ParseError,

    pub fn ok(self: ParseResult) bool {
        return self.errors.len == 0;
    }
};

/// Standalone parser. Holds an arena the parse result is allocated
/// into; the arena is freed by `deinit`, after which any slice or
/// pointer returned by the parser is invalid.
pub const Parser = struct {
    source: []const u8,
    scanner: Scanner,
    current: Token,
    previous: Token,
    arena: std.heap.ArenaAllocator,
    errors: std.ArrayList(ParseError),
    /// Suppress cascaded diagnostics until a synchronization point is
    /// reached. Mirrors the main compiler's panic mode so a single
    /// syntax mistake doesn't fan out into a cloud of follow-up errors.
    panic_mode: bool,

    pub fn init(gpa: Allocator, source: []const u8) Parser {
        var p: Parser = .{
            .source = source,
            .scanner = Scanner.init(source),
            .current = undefined,
            .previous = undefined,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .errors = .empty,
            .panic_mode = false,
        };
        // Prime `current` so the first advance() has something to move
        // into `previous`.
        p.current = p.scanner.scanToken();
        while (p.current.type == .err) {
            p.reportAtCurrent(p.current.lexeme);
            p.current = p.scanner.scanToken();
        }
        return p;
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    pub fn parse(self: *Parser) !ParseResult {
        const alloc = self.arena.allocator();
        var items: std.ArrayList(TopLevel) = .empty;

        while (!self.check(.eof)) {
            const item = self.parseTopLevel() orelse {
                self.synchronize();
                continue;
            };
            try items.append(alloc, item);
            if (self.panic_mode) self.synchronize();
        }

        return .{
            .program = .{ .items = try items.toOwnedSlice(alloc) },
            .errors = try self.errors.toOwnedSlice(alloc),
        };
    }

    fn advance(self: *Parser) void {
        self.previous = self.current;
        while (true) {
            self.current = self.scanner.scanToken();
            if (self.current.type != .err) break;
            self.reportAtCurrent(self.current.lexeme);
        }
    }

    fn check(self: *const Parser, t: TokenType) bool {
        return self.current.type == t;
    }

    fn match(self: *Parser, t: TokenType) bool {
        if (!self.check(t)) return false;
        self.advance();
        return true;
    }

    fn consume(self: *Parser, t: TokenType, message: []const u8) bool {
        if (self.check(t)) {
            self.advance();
            return true;
        }
        self.reportAtCurrent(message);
        return false;
    }

    // Peek past the current identifier to see if the next non-error
    // token is `=`. Used to disambiguate `ident = ...` (rule
    // declaration) from `ident` (rule reference in a bare expression).
    fn peekIsEqual(self: *const Parser) bool {
        var peek = self.scanner;
        while (true) {
            const tok = peek.scanToken();
            if (tok.type == .err) continue;
            return tok.type == .equal;
        }
    }

    // Decide whether `#[...]` begins an expression-position attribute
    // (currently only `longest`) rather than a rule-declaration
    // attribute like `lr`. Called while `current` is still `#`, so the
    // scanner is copied and not mutated.
    fn peekIsExpressionAttr(self: *const Parser) bool {
        var peek = self.scanner;
        // Advance past `[` and the attribute identifier.
        var saw_bracket = false;
        while (true) {
            const tok = peek.scanToken();
            if (tok.type == .err) continue;
            if (!saw_bracket) {
                if (tok.type != .left_bracket) return false;
                saw_bracket = true;
                continue;
            }
            if (tok.type != .identifier) return false;
            return std.mem.eql(u8, tok.lexeme, "longest");
        }
    }

    fn reportAtCurrent(self: *Parser, message: []const u8) void {
        self.reportAt(self.current, message);
    }

    fn reportAtPrevious(self: *Parser, message: []const u8) void {
        self.reportAt(self.previous, message);
    }

    fn reportAt(self: *Parser, tok: Token, message: []const u8) void {
        if (self.panic_mode) return;
        self.panic_mode = true;
        self.errors.append(self.arena.allocator(), .{
            .message = message,
            .span = tokSpan(tok),
        }) catch {};
    }

    fn synchronize(self: *Parser) void {
        self.panic_mode = false;
        // Advance past the offending token, then stop at a boundary
        // that plausibly starts the next declaration.
        while (!self.check(.eof)) {
            if (self.previous.type == .semicolon or self.previous.type == .kw_end) {
                return;
            }
            switch (self.current.type) {
                .kw_use, .tagged_string, .hash => return,
                .identifier => {
                    // An identifier followed by `=` starts a new rule.
                    if (self.peekIsEqual()) return;
                },
                else => {},
            }
            self.advance();
        }
    }

    fn parseTopLevel(self: *Parser) ?TopLevel {
        if (self.check(.kw_use)) {
            return self.parseUseDecl();
        }
        if (self.check(.tagged_string)) {
            return self.parseTaggedBlock();
        }
        if (self.check(.hash)) {
            // `#[longest](...)` compiles at expression level even when
            // it appears at top level. Declaration-level attributes
            // like `#[lr]` prefix a rule.
            if (self.peekIsExpressionAttr()) {
                const e = self.parseExpr() orelse return null;
                return .{ .bare_expr = e };
            }
            return self.parseRuleWithAttrs();
        }
        if (self.check(.identifier) and self.peekIsEqual()) {
            return self.parseRule(.{}, self.current.start, self.current.line);
        }
        const e = self.parseExpr() orelse return null;
        return .{ .bare_expr = e };
    }

    fn parseUseDecl(self: *Parser) ?TopLevel {
        const start_tok = self.current;
        self.advance(); // consume `use`
        if (!self.consume(.string, "Expect a module-path string after 'use'.")) return null;
        const raw = self.previous;
        _ = self.match(.semicolon);
        const path = literal.stripStringDelimiters(raw.lexeme, 0).body;
        return .{ .use_decl = .{
            .path = path,
            .path_span = tokSpan(raw),
            .span = spanFrom(start_tok, self.previous),
        } };
    }

    fn parseTaggedBlock(self: *Parser) ?TopLevel {
        const tok = self.current;
        self.advance(); // consume the tagged-string token
        const parts = splitTaggedString(tok.lexeme) catch {
            self.reportAt(tok, "Malformed tagged string.");
            return null;
        };

        const body_start: u32 = @intCast(tok.start + parts.body_offset);
        const tag_start: u32 = @intCast(tok.start + 1);
        return .{ .tagged_block = .{
            .tag = parts.tag,
            .tag_span = .{
                .start = tag_start,
                .len = @intCast(parts.tag.len),
                .line = @intCast(tok.line),
            },
            .body = parts.body,
            .body_span = .{
                .start = body_start,
                .len = @intCast(parts.body.len),
                .line = @intCast(tok.line),
            },
            .span = tokSpan(tok),
        } };
    }

    // Parse a `#[attr, ...]` prefix and then the rule it annotates.
    fn parseRuleWithAttrs(self: *Parser) ?TopLevel {
        const hash_tok = self.current;
        self.advance(); // consume `#`
        if (!self.consume(.left_bracket, "Expect '[' after '#' to open attribute list.")) return null;

        var attrs: Attrs = .{};
        while (true) {
            if (!self.consume(.identifier, "Expect attribute name in '#[...]'.")) return null;
            const name = self.previous.lexeme;
            if (std.mem.eql(u8, name, "lr")) {
                attrs.lr = true;
            } else {
                // Mirror the compiler: unknown attribute names are
                // hard errors, reserving the syntax space rather than
                // silently accepting typos.
                self.reportAtPrevious("Unknown attribute.");
                return null;
            }
            if (!self.match(.comma)) break;
        }
        if (!self.consume(.right_bracket, "Expect ']' to close attribute list.")) return null;

        if (!self.check(.identifier) or !self.peekIsEqual()) {
            self.reportAtCurrent("Expect rule declaration after attribute list.");
            return null;
        }
        return self.parseRule(attrs, hash_tok.start, hash_tok.line);
    }

    fn parseRule(self: *Parser, attrs: Attrs, rule_start: usize, rule_line: usize) ?TopLevel {
        if (!self.consume(.identifier, "Expect rule name.")) return null;
        const name_tok = self.previous;
        if (!self.consume(.equal, "Expect '=' after rule name.")) return null;

        const body = self.parseExpr() orelse return null;

        var bindings: []const WhereBinding = &.{};
        if (self.match(.kw_where)) {
            bindings = self.parseWhereBlock() orelse return null;
            _ = self.match(.semicolon);
        } else {
            if (!self.consume(.semicolon, "Expect ';' after rule body.")) return null;
        }

        return .{ .rule = .{
            .name = name_tok.lexeme,
            .name_span = tokSpan(name_tok),
            .attrs = attrs,
            .body = body,
            .where_bindings = bindings,
            .span = .{
                .start = @intCast(rule_start),
                .len = @intCast(self.previous.start + self.previous.len - rule_start),
                .line = @intCast(rule_line),
            },
        } };
    }

    fn parseWhereBlock(self: *Parser) ?[]const WhereBinding {
        const alloc = self.arena.allocator();
        var list: std.ArrayList(WhereBinding) = .empty;
        while (!self.check(.kw_end) and !self.check(.eof)) {
            if (!self.consume(.identifier, "Expect sub-rule name in 'where'.")) return null;
            const name_tok = self.previous;
            if (!self.consume(.equal, "Expect '=' after sub-rule name.")) return null;
            const body = self.parseExpr() orelse return null;
            _ = self.match(.semicolon);
            list.append(alloc, .{
                .name = name_tok.lexeme,
                .name_span = tokSpan(name_tok),
                .body = body,
                .span = .{
                    .start = @intCast(name_tok.start),
                    .len = @intCast(self.previous.start + self.previous.len - name_tok.start),
                    .line = @intCast(name_tok.line),
                },
            }) catch return null;
        }
        if (!self.consume(.kw_end, "Expect 'end' to close 'where' block.")) return null;
        return list.toOwnedSlice(alloc) catch null;
    }

    // Precedence, tightest to loosest:
    //   primary  < quantifier < lookahead < sequence < choice
    //
    // The Pratt table in `pratt.zig` runs a single loop; here we use
    // one function per level, producing an n-ary flat node for choice
    // and sequence so tools (railroad, analysis) don't have to
    // rebalance a binary tree to see the operator's full fanout.

    fn parseExpr(self: *Parser) ?Expr {
        return self.parseChoice();
    }

    fn parseChoice(self: *Parser) ?Expr {
        const alloc = self.arena.allocator();
        const first = self.parseSequence() orelse return null;
        if (!self.check(.slash) and !self.check(.pipe)) return first;

        var arms: std.ArrayList(Expr) = .empty;
        arms.append(alloc, first) catch return null;
        const start = first.span.start;
        const line = first.span.line;

        while (self.match(.slash) or self.match(.pipe)) {
            const arm = self.parseSequence() orelse return null;
            arms.append(alloc, arm) catch return null;
        }

        const slice = arms.toOwnedSlice(alloc) catch return null;
        const last = slice[slice.len - 1];
        return .{
            .kind = .{ .choice = slice },
            .span = .{
                .start = start,
                .len = last.span.end() - start,
                .line = line,
            },
        };
    }

    fn parseSequence(self: *Parser) ?Expr {
        const alloc = self.arena.allocator();
        const first = self.parsePrefix() orelse return null;
        if (!self.startsPrimary()) return first;

        var parts: std.ArrayList(Expr) = .empty;
        parts.append(alloc, first) catch return null;
        const start = first.span.start;
        const line = first.span.line;

        while (self.startsPrimary()) {
            const part = self.parsePrefix() orelse return null;
            parts.append(alloc, part) catch return null;
        }

        const slice = parts.toOwnedSlice(alloc) catch return null;
        const last = slice[slice.len - 1];
        return .{
            .kind = .{ .sequence = slice },
            .span = .{
                .start = start,
                .len = last.span.end() - start,
                .line = line,
            },
        };
    }

    // `!` and `&` prefix operators. Both bind looser than a following
    // quantifier (ADR 005/008): `!A*` groups as `!(A*)`.
    fn parsePrefix(self: *Parser) ?Expr {
        if (self.check(.bang) or self.check(.amp)) {
            const op = self.current;
            const negative = self.check(.bang);
            self.advance();
            const operand = self.parsePrefix() orelse return null;
            const op_ptr = self.arena.allocator().create(Expr) catch return null;
            op_ptr.* = operand;
            return .{
                .kind = .{ .lookahead = .{ .operand = op_ptr, .negative = negative } },
                .span = .{
                    .start = @intCast(op.start),
                    .len = operand.span.end() - @as(u32, @intCast(op.start)),
                    .line = @intCast(op.line),
                },
            };
        }
        return self.parseQuantified();
    }

    fn parseQuantified(self: *Parser) ?Expr {
        var primary = self.parsePrimary() orelse return null;
        while (true) {
            if (self.check(.star) or self.check(.plus) or self.check(.question)) {
                const op = self.current;
                self.advance();
                const operand = self.arena.allocator().create(Expr) catch return null;
                operand.* = primary;
                const kind: QuantKind = switch (op.type) {
                    .star => .star,
                    .plus => .plus,
                    .question => .question,
                    else => unreachable,
                };
                primary = .{
                    .kind = .{ .quantifier = .{ .operand = operand, .kind = kind } },
                    .span = .{
                        .start = operand.span.start,
                        .len = @intCast(op.start + op.len - operand.span.start),
                        .line = operand.span.line,
                    },
                };
                continue;
            }
            if (self.check(.left_brace)) {
                self.advance();
                const bounds = self.parseBounds() orelse return null;
                const close = self.previous;
                const operand = self.arena.allocator().create(Expr) catch return null;
                operand.* = primary;
                primary = .{
                    .kind = .{ .quantifier = .{ .operand = operand, .kind = .{ .bounded = bounds } } },
                    .span = .{
                        .start = operand.span.start,
                        .len = @intCast(close.start + close.len - operand.span.start),
                        .line = operand.span.line,
                    },
                };
                continue;
            }
            return primary;
        }
    }

    fn parseBounds(self: *Parser) ?Bounds {
        var min: ?u32 = null;
        var max: ?u32 = null;
        var saw_comma = false;

        if (self.check(.number)) {
            self.advance();
            min = std.fmt.parseInt(u32, self.previous.lexeme, 10) catch {
                self.reportAtPrevious("Bound value is out of range.");
                return null;
            };
        }
        if (self.match(.comma)) {
            saw_comma = true;
            if (self.check(.number)) {
                self.advance();
                max = std.fmt.parseInt(u32, self.previous.lexeme, 10) catch {
                    self.reportAtPrevious("Bound value is out of range.");
                    return null;
                };
            }
        }
        if (!self.consume(.right_brace, "Expect '}' to close bounded quantifier.")) return null;

        if (min == null and max == null) {
            self.reportAtPrevious("Bounded quantifier requires at least one bound.");
            return null;
        }
        // `A{n}` without a comma is the exact form: the single bound
        // plays both roles. `A{n,}` keeps max null as the unbounded
        // upper end; `A{,m}` keeps min null.
        if (!saw_comma) max = min;
        return .{ .min = min, .max = max };
    }

    fn parsePrimary(self: *Parser) ?Expr {
        switch (self.current.type) {
            .string => return self.parseStringLit(false),
            .string_i => return self.parseStringLit(true),
            .char => return self.parseCharLit(),
            .dot => {
                const tok = self.current;
                self.advance();
                return .{ .kind = .any_byte, .span = tokSpan(tok) };
            },
            .identifier => {
                const tok = self.current;
                self.advance();
                return .{ .kind = .{ .rule_ref = tok.lexeme }, .span = tokSpan(tok) };
            },
            .left_paren => return self.parseGroup(),
            .left_bracket => return self.parseCharset(),
            .left_angle => return self.parseCapture(),
            .caret => return self.parseCut(),
            .hash => return self.parseLongest(),
            else => {
                self.reportAtCurrent("Expected an expression.");
                return null;
            },
        }
    }

    fn parseStringLit(self: *Parser, case_insensitive: bool) ?Expr {
        const tok = self.current;
        self.advance();
        const prefix_len: usize = if (case_insensitive) 1 else 0;
        const stripped = literal.stripStringDelimiters(tok.lexeme, prefix_len);
        return .{
            .kind = .{ .string_lit = .{
                .raw = stripped.body,
                .case_insensitive = case_insensitive,
                .triple_quoted = stripped.triple_quoted,
            } },
            .span = tokSpan(tok),
        };
    }

    fn parseCharLit(self: *Parser) ?Expr {
        const tok = self.current;
        self.advance();
        const byte = literal.extractCharByte(tok.lexeme) catch |e| {
            self.reportAtPrevious(literal.errorMessage(e));
            return null;
        };
        return .{ .kind = .{ .char_lit = byte }, .span = tokSpan(tok) };
    }

    fn parseGroup(self: *Parser) ?Expr {
        const open = self.current;
        self.advance(); // consume `(`
        const inner = self.parseExpr() orelse return null;
        if (!self.consume(.right_paren, "Expect ')' after expression.")) return null;
        const close = self.previous;
        const ptr = self.arena.allocator().create(Expr) catch return null;
        ptr.* = inner;
        return .{
            .kind = .{ .group = ptr },
            .span = .{
                .start = @intCast(open.start),
                .len = @intCast(close.start + close.len - open.start),
                .line = @intCast(open.line),
            },
        };
    }

    fn parseCharset(self: *Parser) ?Expr {
        const alloc = self.arena.allocator();
        const open = self.current;
        self.advance(); // consume `[`

        if (self.check(.right_bracket)) {
            self.reportAtCurrent("Empty charset.");
            return null;
        }

        var items: std.ArrayList(CharsetItem) = .empty;
        while (!self.check(.right_bracket) and !self.check(.eof)) {
            if (!self.check(.char)) {
                self.reportAtCurrent("Expected a character literal inside charset.");
                return null;
            }
            const lo_tok = self.current;
            self.advance();
            const lo = literal.extractCharByte(lo_tok.lexeme) catch |e| {
                self.reportAtPrevious(literal.errorMessage(e));
                return null;
            };

            if (self.match(.minus)) {
                if (!self.check(.char)) {
                    self.reportAtCurrent("Expected a character literal after '-' in charset range.");
                    return null;
                }
                const hi_tok = self.current;
                self.advance();
                const hi = literal.extractCharByte(hi_tok.lexeme) catch |e| {
                    self.reportAtPrevious(literal.errorMessage(e));
                    return null;
                };
                if (lo > hi) {
                    self.reportAtPrevious("Charset range start must not exceed range end.");
                    return null;
                }
                items.append(alloc, .{ .range = .{ .lo = lo, .hi = hi } }) catch return null;
            } else {
                items.append(alloc, .{ .single = lo }) catch return null;
            }
        }

        if (!self.consume(.right_bracket, "Expect ']' after charset.")) return null;
        const close = self.previous;
        return .{
            .kind = .{ .charset = items.toOwnedSlice(alloc) catch return null },
            .span = .{
                .start = @intCast(open.start),
                .len = @intCast(close.start + close.len - open.start),
                .line = @intCast(open.line),
            },
        };
    }

    fn parseCapture(self: *Parser) ?Expr {
        const open = self.current;
        self.advance(); // consume `<`
        if (!self.consume(.identifier, "Expect binding name after '<'.")) return null;
        const name_tok = self.previous;
        if (!self.consume(.colon, "Expect ':' after capture name.")) return null;
        const body = self.parseExpr() orelse return null;
        if (!self.consume(.right_angle, "Expect '>' to close capture.")) return null;
        const close = self.previous;

        const body_ptr = self.arena.allocator().create(Expr) catch return null;
        body_ptr.* = body;
        return .{
            .kind = .{ .capture = .{
                .name = name_tok.lexeme,
                .name_span = tokSpan(name_tok),
                .body = body_ptr,
            } },
            .span = .{
                .start = @intCast(open.start),
                .len = @intCast(close.start + close.len - open.start),
                .line = @intCast(open.line),
            },
        };
    }

    fn parseCut(self: *Parser) ?Expr {
        const caret = self.current;
        self.advance(); // consume `^`
        // A label must be immediately adjacent: `^"msg"` with no
        // whitespace between the two tokens. `^ "B"` is a bare cut
        // followed by a sequence string primary.
        const adjacent = self.check(.string) and
            self.current.start == caret.start + caret.len;
        if (!adjacent) {
            return .{ .kind = .cut, .span = tokSpan(caret) };
        }
        const str_tok = self.current;
        self.advance();
        const label = literal.stripStringDelimiters(str_tok.lexeme, 0).body;
        return .{
            .kind = .{ .cut_labeled = label },
            .span = .{
                .start = @intCast(caret.start),
                .len = @intCast(str_tok.start + str_tok.len - caret.start),
                .line = @intCast(caret.line),
            },
        };
    }

    fn parseLongest(self: *Parser) ?Expr {
        const alloc = self.arena.allocator();
        const hash = self.current;
        self.advance(); // consume `#`
        if (!self.consume(.left_bracket, "Expect '[' after '#'.")) return null;
        if (!self.consume(.identifier, "Expect attribute name in '#[...]'.")) return null;
        if (!std.mem.eql(u8, self.previous.lexeme, "longest")) {
            self.reportAtPrevious("Unknown expression attribute. Expected 'longest'.");
            return null;
        }
        if (!self.consume(.right_bracket, "Expect ']' to close attribute list.")) return null;
        if (!self.consume(.left_paren, "Expect '(' after '#[longest]'.")) return null;

        var arms: std.ArrayList(Expr) = .empty;
        while (true) {
            const arm = self.parseSequence() orelse return null;
            arms.append(alloc, arm) catch return null;
            if (!self.match(.slash) and !self.match(.pipe)) break;
        }
        if (!self.consume(.right_paren, "Expect ')' to close '#[longest](...)'.")) return null;
        const close = self.previous;
        return .{
            .kind = .{ .longest = arms.toOwnedSlice(alloc) catch return null },
            .span = .{
                .start = @intCast(hash.start),
                .len = @intCast(close.start + close.len - hash.start),
                .line = @intCast(hash.line),
            },
        };
    }

    // Whether `current` can start a primary expression — used by the
    // sequence loop to decide whether to keep eating tokens.
    fn startsPrimary(self: *const Parser) bool {
        return switch (self.current.type) {
            .string,
            .string_i,
            .char,
            .dot,
            .identifier,
            .left_paren,
            .left_bracket,
            .left_angle,
            .caret,
            .bang,
            .amp,
            => true,
            // `#` only starts a primary when it's the expression-level
            // `#[longest](...)`; declaration-level `#[lr]` never appears
            // mid-expression, so accepting `.hash` here would create
            // false-positive sequence continuations.
            .hash => self.peekIsExpressionAttr(),
            else => false,
        };
    }
};

fn tokSpan(tok: Token) Span {
    return .{
        .start = @intCast(tok.start),
        .len = @intCast(tok.len),
        .line = @intCast(tok.line),
    };
}

fn spanFrom(start_tok: Token, end_tok: Token) Span {
    return .{
        .start = @intCast(start_tok.start),
        .len = @intCast(end_tok.start + end_tok.len - start_tok.start),
        .line = @intCast(start_tok.line),
    };
}

const TaggedParts = struct {
    tag: []const u8,
    body: []const u8,
    body_offset: usize,
};

fn splitTaggedString(lex: []const u8) !TaggedParts {
    if (lex.len < 1 + 3 + 3 or lex[0] != '@') return error.Malformed;
    if (!std.mem.endsWith(u8, lex, "\"\"\"")) return error.Malformed;
    var i: usize = 1;
    while (i < lex.len and lex[i] != '"') : (i += 1) {}
    if (i + 3 > lex.len - 3) return error.Malformed;
    if (!std.mem.eql(u8, lex[i .. i + 3], "\"\"\"")) return error.Malformed;
    return .{
        .tag = lex[1..i],
        .body = lex[i + 3 .. lex.len - 3],
        .body_offset = i + 3,
    };
}

const testing = std.testing;

test "empty source produces empty program" {
    var p = Parser.init(testing.allocator, "");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    try testing.expectEqual(@as(usize, 0), r.program.items.len);
}

test "whitespace and comments produce empty program" {
    var p = Parser.init(testing.allocator, "  -- just a comment\n   ");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    try testing.expectEqual(@as(usize, 0), r.program.items.len);
}

test "single rule with string literal body" {
    var p = Parser.init(testing.allocator, "foo = \"bar\";");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    try testing.expectEqual(@as(usize, 1), r.program.items.len);
    const rule = r.program.items[0].rule;
    try testing.expectEqualStrings("foo", rule.name);
    try testing.expect(!rule.attrs.lr);
    try testing.expectEqualStrings("bar", rule.body.kind.string_lit.raw);
    try testing.expect(!rule.body.kind.string_lit.case_insensitive);
    try testing.expect(!rule.body.kind.string_lit.triple_quoted);
}

test "case-insensitive and triple-quoted strings are distinguished" {
    var p = Parser.init(testing.allocator,
        \\a = i"Foo";
        \\b = """multi""";
        \\c = i"""both""";
    );
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    const a = r.program.items[0].rule.body.kind.string_lit;
    try testing.expect(a.case_insensitive);
    try testing.expect(!a.triple_quoted);
    const b = r.program.items[1].rule.body.kind.string_lit;
    try testing.expect(!b.case_insensitive);
    try testing.expect(b.triple_quoted);
    const c = r.program.items[2].rule.body.kind.string_lit;
    try testing.expect(c.case_insensitive);
    try testing.expect(c.triple_quoted);
}

test "char literal decodes escape sequences" {
    var p = Parser.init(testing.allocator,
        \\a = '\n';
        \\b = '\x41';
    );
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    try testing.expectEqual(@as(u8, '\n'), r.program.items[0].rule.body.kind.char_lit);
    try testing.expectEqual(@as(u8, 0x41), r.program.items[1].rule.body.kind.char_lit);
}

test "any-byte dot is its own node kind" {
    var p = Parser.init(testing.allocator, "a = .;");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    try testing.expect(r.program.items[0].rule.body.kind == .any_byte);
}

test "identifier becomes rule_ref" {
    var p = Parser.init(testing.allocator, "a = b;");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    try testing.expectEqualStrings("b", r.program.items[0].rule.body.kind.rule_ref);
}

test "charset with singles and ranges" {
    var p = Parser.init(testing.allocator, "a = ['a'-'z' '_' '0'-'9'];");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    const items = r.program.items[0].rule.body.kind.charset;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(@as(u8, 'a'), items[0].range.lo);
    try testing.expectEqual(@as(u8, 'z'), items[0].range.hi);
    try testing.expectEqual(@as(u8, '_'), items[1].single);
    try testing.expectEqual(@as(u8, '0'), items[2].range.lo);
    try testing.expectEqual(@as(u8, '9'), items[2].range.hi);
}

test "empty charset is an error" {
    var p = Parser.init(testing.allocator, "a = [];");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(!r.ok());
}

test "sequence flattens across juxtaposed primaries" {
    var p = Parser.init(testing.allocator, "a = x y z;");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    const parts = r.program.items[0].rule.body.kind.sequence;
    try testing.expectEqual(@as(usize, 3), parts.len);
    try testing.expectEqualStrings("x", parts[0].kind.rule_ref);
    try testing.expectEqualStrings("y", parts[1].kind.rule_ref);
    try testing.expectEqualStrings("z", parts[2].kind.rule_ref);
}

test "choice flattens across / and |" {
    var p = Parser.init(testing.allocator, "a = x / y | z;");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    const arms = r.program.items[0].rule.body.kind.choice;
    try testing.expectEqual(@as(usize, 3), arms.len);
}

test "choice binds looser than sequence" {
    var p = Parser.init(testing.allocator, "a = x y / z w;");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    const arms = r.program.items[0].rule.body.kind.choice;
    try testing.expectEqual(@as(usize, 2), arms.len);
    try testing.expectEqual(@as(usize, 2), arms[0].kind.sequence.len);
    try testing.expectEqual(@as(usize, 2), arms[1].kind.sequence.len);
}

test "quantifiers star plus question" {
    var p = Parser.init(testing.allocator,
        \\a = x*;
        \\b = x+;
        \\c = x?;
    );
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    try testing.expect(r.program.items[0].rule.body.kind.quantifier.kind == .star);
    try testing.expect(r.program.items[1].rule.body.kind.quantifier.kind == .plus);
    try testing.expect(r.program.items[2].rule.body.kind.quantifier.kind == .question);
}

test "bounded quantifier variants" {
    var p = Parser.init(testing.allocator,
        \\a = x{3};
        \\b = x{2,5};
        \\c = x{1,};
        \\d = x{,4};
    );
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    const a = r.program.items[0].rule.body.kind.quantifier.kind.bounded;
    try testing.expectEqual(@as(u32, 3), a.min.?);
    try testing.expectEqual(@as(u32, 3), a.max.?);
    const b = r.program.items[1].rule.body.kind.quantifier.kind.bounded;
    try testing.expectEqual(@as(u32, 2), b.min.?);
    try testing.expectEqual(@as(u32, 5), b.max.?);
    const c = r.program.items[2].rule.body.kind.quantifier.kind.bounded;
    try testing.expectEqual(@as(u32, 1), c.min.?);
    try testing.expect(c.max == null);
    const d = r.program.items[3].rule.body.kind.quantifier.kind.bounded;
    try testing.expect(d.min == null);
    try testing.expectEqual(@as(u32, 4), d.max.?);
}

test "empty bounds are rejected" {
    var p = Parser.init(testing.allocator, "a = x{};");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(!r.ok());
}

test "lookahead binds looser than quantifier" {
    var p = Parser.init(testing.allocator, "a = !x*;");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    // !x* parses as !(x*): the outer node is lookahead, its operand is x*.
    const outer = r.program.items[0].rule.body.kind;
    try testing.expect(outer == .lookahead);
    try testing.expect(outer.lookahead.negative);
    try testing.expect(outer.lookahead.operand.kind == .quantifier);
}

test "positive and negative lookahead" {
    var p = Parser.init(testing.allocator,
        \\a = &x;
        \\b = !x;
    );
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    try testing.expect(!r.program.items[0].rule.body.kind.lookahead.negative);
    try testing.expect(r.program.items[1].rule.body.kind.lookahead.negative);
}

test "grouping preserves inner expression" {
    var p = Parser.init(testing.allocator, "a = (x / y) z;");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    const parts = r.program.items[0].rule.body.kind.sequence;
    try testing.expectEqual(@as(usize, 2), parts.len);
    try testing.expect(parts[0].kind == .group);
    try testing.expect(parts[0].kind.group.kind == .choice);
}

test "named capture carries name and body" {
    var p = Parser.init(testing.allocator, "a = <q: \"hello\">;");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    const cap = r.program.items[0].rule.body.kind.capture;
    try testing.expectEqualStrings("q", cap.name);
    try testing.expectEqualStrings("hello", cap.body.kind.string_lit.raw);
}

test "bare cut vs labelled cut" {
    var p = Parser.init(testing.allocator,
        \\a = ^;
        \\b = ^"oops";
    );
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    try testing.expect(r.program.items[0].rule.body.kind == .cut);
    try testing.expectEqualStrings("oops", r.program.items[1].rule.body.kind.cut_labeled);
}

test "cut followed by a separate string is not a label" {
    // `^ "x"` with whitespace is a bare cut then a string primary in
    // sequence — the adjacency check distinguishes label from primary.
    var p = Parser.init(testing.allocator, "a = ^ \"x\";");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    const parts = r.program.items[0].rule.body.kind.sequence;
    try testing.expectEqual(@as(usize, 2), parts.len);
    try testing.expect(parts[0].kind == .cut);
    try testing.expect(parts[1].kind == .string_lit);
}

test "longest block gathers arms" {
    var p = Parser.init(testing.allocator, "a = #[longest](x / y / z);");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    const arms = r.program.items[0].rule.body.kind.longest;
    try testing.expectEqual(@as(usize, 3), arms.len);
}

test "longest can appear at top level" {
    var p = Parser.init(testing.allocator, "#[longest](x / y)");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    try testing.expect(r.program.items[0] == .bare_expr);
    try testing.expect(r.program.items[0].bare_expr.kind == .longest);
}

test "rule attribute #[lr] is recognized" {
    var p = Parser.init(testing.allocator, "#[lr] expr = expr \"+\" term / term;");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    const rule = r.program.items[0].rule;
    try testing.expect(rule.attrs.lr);
    try testing.expectEqualStrings("expr", rule.name);
}

test "unknown rule attribute is rejected" {
    var p = Parser.init(testing.allocator, "#[bogus] a = x;");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(!r.ok());
}

test "where block collects sub-rules" {
    var p = Parser.init(testing.allocator,
        \\kv = k "=" v
        \\  where
        \\    k = ident;
        \\    v = ident
        \\  end
    );
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    const rule = r.program.items[0].rule;
    try testing.expectEqual(@as(usize, 2), rule.where_bindings.len);
    try testing.expectEqualStrings("k", rule.where_bindings[0].name);
    try testing.expectEqualStrings("v", rule.where_bindings[1].name);
}

test "use declaration captures path" {
    var p = Parser.init(testing.allocator, "use \"std/abnf\";");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    try testing.expectEqualStrings("std/abnf", r.program.items[0].use_decl.path);
}

test "tagged @abnf block preserves body with trailing quote" {
    // Body is `URI = scheme ":"` (ending in `"`); the scanner must
    // let the leading `"` of the trailing run belong to the body.
    var p = Parser.init(testing.allocator, "@abnf\"\"\"URI = scheme \":\"\"\"\"");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    const blk = r.program.items[0].tagged_block;
    try testing.expectEqualStrings("abnf", blk.tag);
    try testing.expectEqualStrings("URI = scheme \":\"", blk.body);
}

test "multiple declarations cohabit" {
    var p = Parser.init(testing.allocator,
        \\use "std/abnf";
        \\digit = ['0'-'9'];
        \\ident = alpha digit*;
    );
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    try testing.expectEqual(@as(usize, 3), r.program.items.len);
    try testing.expect(r.program.items[0] == .use_decl);
    try testing.expect(r.program.items[1] == .rule);
    try testing.expect(r.program.items[2] == .rule);
}

test "missing semicolon after rule body is reported" {
    var p = Parser.init(testing.allocator, "a = x y\nb = z;");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(!r.ok());
}

test "spans cover full rule extent" {
    const src = "foo = \"bar\";";
    var p = Parser.init(testing.allocator, src);
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    const rule = r.program.items[0].rule;
    try testing.expectEqual(@as(u32, 0), rule.span.start);
    // Span covers `foo = "bar";` — all twelve bytes of the source.
    try testing.expectEqual(@as(u32, @intCast(src.len)), rule.span.len);
}

test "expression spans reflect operator coverage" {
    var p = Parser.init(testing.allocator, "a = x y z;");
    defer p.deinit();
    const r = try p.parse();
    try testing.expect(r.ok());
    const body = r.program.items[0].rule.body;
    try testing.expect(body.kind == .sequence);
    // `x y z` starts at column 5 (0-based offset 4) and runs for 5 bytes.
    try testing.expectEqual(@as(u32, 4), body.span.start);
    try testing.expectEqual(@as(u32, 5), body.span.len);
}
