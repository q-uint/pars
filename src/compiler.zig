const std = @import("std");
const scanner = @import("scanner.zig");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Token = scanner.Token;
const TokenType = scanner.TokenType;

const Parser = struct {
    current: Token,
    previous: Token,
    had_error: bool,
    panic_mode: bool,
};

// Binding powers from loosest to tightest. A prefix parser compiles the
// first primary of an expression; an infix parser then loops in
// parsePrecedence as long as the next token's row in the rules table has
// precedence >= the caller's. Sequence has no token of its own and is
// handled specially in parsePrecedence; see ADR 005.
const Precedence = enum(u8) {
    none,
    choice, // '/'
    sequence, // juxtaposition (no token)
    quantifier, // '*' '+' '?'
    lookahead, // '!' '&'
    primary,

    fn next(self: Precedence) Precedence {
        return @enumFromInt(@intFromEnum(self) + 1);
    }
};

const ParseFn = *const fn () void;

const ParseRule = struct {
    prefix: ?ParseFn,
    infix: ?ParseFn,
    precedence: Precedence,
};

var parser: Parser = undefined;
var compiling_chunk: *Chunk = undefined;

fn currentChunk() *Chunk {
    return compiling_chunk;
}

pub fn compile(source: []const u8, chunk: *Chunk) bool {
    scanner.init(source);
    compiling_chunk = chunk;

    parser.had_error = false;
    parser.panic_mode = false;

    advance();
    expression();
    consume(.eof, "Expect end of expression.");
    endCompiler();

    return !parser.had_error;
}

fn advance() void {
    parser.previous = parser.current;

    while (true) {
        parser.current = scanner.scanToken();
        if (parser.current.type != .err) break;

        errorAtCurrent(parser.current.lexeme);
    }
}

fn consume(token_type: TokenType, message: []const u8) void {
    if (parser.current.type == token_type) {
        advance();
        return;
    }
    errorAtCurrent(message);
}

fn expression() void {
    parsePrecedence(.choice);
}

// Pratt loop. Sequence is the only operator without a token of its own:
// two juxtaposed primaries are a sequence with no opcode between them.
// The loop handles it as a second case after infix dispatch (see ADR 005):
// if the next token can start a primary, recurse one precedence level
// tighter so that sequence stays left-associative.
fn parsePrecedence(precedence: Precedence) void {
    advance();
    const prefix_rule = getRule(parser.previous.type).prefix orelse {
        errorAtPrevious("Expect expression.");
        return;
    };
    prefix_rule();

    while (true) {
        const rule = getRule(parser.current.type);
        if (rule.infix) |infix_rule| {
            if (@intFromEnum(precedence) <= @intFromEnum(rule.precedence)) {
                advance();
                infix_rule();
                continue;
            }
        }

        // Sequence continuation: juxtaposed primaries form a sequence.
        // Only applies when the caller is at or below sequence precedence
        // and the current token can start a primary (i.e. has a prefix
        // rule). The right operand parses one level tighter so that
        // sequence is left-associative.
        if (@intFromEnum(precedence) <= @intFromEnum(Precedence.sequence) and
            getRule(parser.current.type).prefix != null)
        {
            parsePrecedence(Precedence.sequence.next());
            continue;
        }

        break;
    }
}

// Pratt rule table, one row per TokenType. Unassigned rows default to
// all-null/.none, so an empty row means "this token is not currently
// part of the expression grammar". Listing rows by `@intFromEnum` index
// keeps the table robust to enum reorderings.
const token_count = @typeInfo(TokenType).@"enum".fields.len;

const rules: [token_count]ParseRule = blk: {
    const empty = ParseRule{ .prefix = null, .infix = null, .precedence = .none };
    var t: [token_count]ParseRule = @splat(empty);

    t[@intFromEnum(TokenType.left_paren)] = .{ .prefix = grouping, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.string)] = .{ .prefix = stringLiteral, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.string_i)] = .{ .prefix = stringLiteralIgnoreCase, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.char)] = .{ .prefix = charLiteral, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.dot)] = .{ .prefix = anyChar, .infix = null, .precedence = .none };

    break :blk t;
};

fn getRule(token_type: TokenType) ParseRule {
    return rules[@intFromEnum(token_type)];
}

fn grouping() void {
    expression();
    consume(.right_paren, "Expect ')' after expression.");
}

fn anyChar() void {
    emitByte(@intFromEnum(OpCode.op_match_any));
}

fn charLiteral() void {
    const lexeme = parser.previous.lexeme;
    // Lexeme includes the surrounding single quotes: 'a' -> length 3.
    // Only single-byte character literals are supported at this stage;
    // escapes and multi-byte forms will land with the charset work.
    if (lexeme.len != 3) {
        errorAtPrevious("Character literal must be a single byte.");
        return;
    }
    emitBytes(@intFromEnum(OpCode.op_match_char), lexeme[1]);
}

fn stringLiteral() void {
    const bytes = stripStringDelimiters(parser.previous.lexeme, 0);
    emitMatchString(.op_match_string, .op_match_string_wide, bytes);
}

fn stringLiteralIgnoreCase() void {
    // The 'i' prefix counts as one extra leading byte before the quotes.
    const bytes = stripStringDelimiters(parser.previous.lexeme, 1);
    emitMatchString(.op_match_string_i, .op_match_string_i_wide, bytes);
}

// Strips the surrounding quote delimiters, accounting for an optional
// leading prefix (`i` for case-insensitive) and the triple-quoted form.
fn stripStringDelimiters(lexeme: []const u8, prefix_len: usize) []const u8 {
    const body = lexeme[prefix_len..];
    const delim: usize = if (body.len >= 6 and
        std.mem.startsWith(u8, body, "\"\"\"") and
        std.mem.endsWith(u8, body, "\"\"\""))
        3
    else
        1;
    return body[delim .. body.len - delim];
}

fn emitByte(byte: u8) void {
    currentChunk().write(byte, parser.previous.line) catch {
        errorAtPrevious("Out of memory.");
    };
}

fn emitBytes(byte1: u8, byte2: u8) void {
    emitByte(byte1);
    emitByte(byte2);
}

fn emitHalt() void {
    emitByte(@intFromEnum(OpCode.op_halt));
}

fn emitMatchString(narrow: OpCode, wide: OpCode, bytes: []const u8) void {
    currentChunk().emitOpConstant(narrow, wide, bytes, parser.previous.line) catch {
        errorAtPrevious("Out of memory.");
    };
}

fn endCompiler() void {
    emitHalt();
}

fn errorAtCurrent(message: []const u8) void {
    errorAt(&parser.current, message);
}

fn errorAtPrevious(message: []const u8) void {
    errorAt(&parser.previous, message);
}

fn errorAt(token: *const Token, message: []const u8) void {
    if (parser.panic_mode) return;
    parser.panic_mode = true;

    std.debug.print("[line {d}] Error", .{token.line});

    switch (token.type) {
        .eof => std.debug.print(" at end", .{}),
        .err => {},
        else => std.debug.print(" at '{s}'", .{token.lexeme}),
    }

    std.debug.print(": {s}\n", .{message});
    parser.had_error = true;
}
