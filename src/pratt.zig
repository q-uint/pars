const std = @import("std");
const scanner_mod = @import("scanner.zig");
const compiler_mod = @import("compiler.zig");
const TokenType = scanner_mod.TokenType;
const Compiler = compiler_mod.Compiler;

// Binding powers from loosest to tightest. A prefix parser compiles the
// first primary of an expression; an infix parser then loops in
// parsePrecedence as long as the next token's row in the rules table has
// precedence >= the caller's. Sequence has no token of its own and is
// handled specially in parsePrecedence; see ADR 005.
pub const Precedence = enum(u8) {
    none,
    choice, // '/'
    sequence, // juxtaposition (no token)
    lookahead, // '!' '&' — prefix, binds looser than quantifier so `!A*` is `!(A*)`.
    quantifier, // '*' '+' '?'
    primary,

    pub fn next(self: Precedence) Precedence {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};

pub const ParseFn = *const fn (self: *Compiler) void;

pub const ParseRule = struct {
    prefix: ?ParseFn,
    infix: ?ParseFn,
    precedence: Precedence,
};

// Pratt rule table, one row per TokenType. Unassigned rows default to
// all-null/.none, so an empty row means "this token is not currently
// part of the expression grammar". Listing rows by `@intFromEnum` index
// keeps the table robust to enum reorderings.
const token_count = @typeInfo(TokenType).@"enum".fields.len;

const rules: [token_count]ParseRule = blk: {
    const empty = ParseRule{ .prefix = null, .infix = null, .precedence = .none };
    var t: [token_count]ParseRule = @splat(empty);

    t[@intFromEnum(TokenType.left_paren)] = .{ .prefix = Compiler.grouping, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.left_bracket)] = .{ .prefix = Compiler.charset, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.string)] = .{ .prefix = Compiler.stringLiteral, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.string_i)] = .{ .prefix = Compiler.stringLiteralIgnoreCase, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.char)] = .{ .prefix = Compiler.charLiteral, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.dot)] = .{ .prefix = Compiler.anyChar, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.identifier)] = .{ .prefix = Compiler.namedRule, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.left_angle)] = .{ .prefix = Compiler.capture, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.bang)] = .{ .prefix = Compiler.notLookahead, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.amp)] = .{ .prefix = Compiler.andLookahead, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.caret)] = .{ .prefix = Compiler.cut, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.hash)] = .{ .prefix = Compiler.longestPrefix, .infix = null, .precedence = .none };

    t[@intFromEnum(TokenType.slash)] = .{ .prefix = null, .infix = Compiler.choiceOp, .precedence = .choice };
    t[@intFromEnum(TokenType.pipe)] = .{ .prefix = null, .infix = Compiler.choiceOp, .precedence = .choice };
    t[@intFromEnum(TokenType.star)] = .{ .prefix = null, .infix = Compiler.starOp, .precedence = .quantifier };
    t[@intFromEnum(TokenType.plus)] = .{ .prefix = null, .infix = Compiler.plusOp, .precedence = .quantifier };
    t[@intFromEnum(TokenType.question)] = .{ .prefix = null, .infix = Compiler.questionOp, .precedence = .quantifier };
    t[@intFromEnum(TokenType.left_brace)] = .{ .prefix = null, .infix = Compiler.boundedOp, .precedence = .quantifier };

    break :blk t;
};

pub fn getRule(token_type: TokenType) ParseRule {
    return rules[@intFromEnum(token_type)];
}

// Pratt loop. Sequence is the only operator without a token of its own:
// two juxtaposed primaries are a sequence with no opcode between them.
// The loop handles it as a second case after infix dispatch (see ADR 005):
// if the next token can start a primary, recurse one precedence level
// tighter so that sequence stays left-associative.
pub fn parsePrecedence(self: *Compiler, precedence: Precedence) void {
    const saved_expr_start = self.last_expr_start;
    const saved_expr_local_count = self.last_expr_local_count;
    self.last_expr_start = self.currentChunk().code.items.len;
    self.last_expr_local_count = self.local_count;

    self.advance();
    const prefix_rule = getRule(self.parser.previous.type).prefix orelse {
        self.errorAtPrevious("Expected an expression: a string, a character literal, '.', '[', '(', or a rule name.");
        return;
    };
    prefix_rule(self);

    while (true) {
        const rule = getRule(self.parser.current.type);
        if (rule.infix) |infix_rule| {
            if (@intFromEnum(precedence) <= @intFromEnum(rule.precedence)) {
                self.advance();
                infix_rule(self);
                continue;
            }
        }

        // Sequence continuation: juxtaposed primaries form a sequence.
        // Only applies when the caller is at or below sequence precedence
        // and the current token can start a primary (i.e. has a prefix
        // rule). The right operand parses one level tighter so that
        // sequence is left-associative.
        if (@intFromEnum(precedence) <= @intFromEnum(Precedence.sequence) and
            getRule(self.parser.current.type).prefix != null)
        {
            parsePrecedence(self, Precedence.sequence.next());
            continue;
        }

        break;
    }

    self.last_expr_start = saved_expr_start;
    self.last_expr_local_count = saved_expr_local_count;
}
