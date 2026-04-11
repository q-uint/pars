const std = @import("std");
const scanner = @import("scanner.zig");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Token = scanner.Token;

const Parser = struct {
    current: Token,
    previous: Token,
    had_error: bool,
    panic_mode: bool,
};

const Precedence = enum(u8) {
    none,
    choice, // '/'
    sequence, // juxtaposition
    lookahead, // '!' '&'
    quantifier, // '*' '+' '?'
    primary,
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

fn consume(token_type: scanner.TokenType, message: []const u8) void {
    if (parser.current.type == token_type) {
        advance();
        return;
    }
    errorAtCurrent(message);
}

fn expression() void {
    parsePrecedence(.choice);
}

fn parsePrecedence(precedence: Precedence) void {
    _ = precedence;
}

fn grouping() void {
    expression();
    consume(.right_paren, "Expect ')' after expression.");
}

fn unaryLookahead() void {
    const operator_type = parser.previous.type;

    parsePrecedence(.lookahead);

    switch (operator_type) {
        .bang => {}, // emit op_neg_lookahead later
        .amp => {}, // emit op_pos_lookahead later
        else => unreachable,
    }
}

fn charLiteral() void {
    const lexeme = parser.previous.lexeme;
    emitConstant(lexeme[1 .. lexeme.len - 1]);
}

fn stringLiteral() void {
    const lexeme = parser.previous.lexeme;
    const delim: usize = if (lexeme.len >= 6 and
        std.mem.startsWith(u8, lexeme, "\"\"\"") and
        std.mem.endsWith(u8, lexeme, "\"\"\""))
        3
    else
        1;
    emitConstant(lexeme[delim .. lexeme.len - delim]);
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

fn emitConstant(value: []const u8) void {
    currentChunk().writeConstant(value, parser.previous.line) catch {
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
