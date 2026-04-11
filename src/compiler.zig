const std = @import("std");
const scanner = @import("scanner.zig");
const chunk_mod = @import("chunk.zig");
const debug = @import("debug.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Token = scanner.Token;
const TokenType = scanner.TokenType;

// Comptime toggle: disassemble the chunk after a successful compile.
// Off by default so the REPL and scripts produce clean output; flip to
// true when debugging codegen.
const print_code = false;

/// A structured compile-time diagnostic. Messages are static strings;
/// the location is a source-byte span plus 1-based line and column so
/// the renderer can show a snippet with a caret without re-scanning.
pub const CompileError = struct {
    line: usize,
    column: usize,
    start: usize,
    len: usize,
    message: []const u8,
    at_eof: bool,
};

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
var errors: std.ArrayList(CompileError) = .empty;
var errors_alloc: std.mem.Allocator = undefined;
var compiling_source: []const u8 = &.{};

fn currentChunk() *Chunk {
    return compiling_chunk;
}

/// Diagnostics produced by the most recent `compile` call. The slice is
/// invalidated the next time `compile` is called.
pub fn getErrors() []const CompileError {
    return errors.items;
}

pub fn compile(alloc: std.mem.Allocator, source: []const u8, chunk: *Chunk) bool {
    scanner.init(source);
    compiling_chunk = chunk;
    compiling_source = source;

    errors.clearRetainingCapacity();
    errors_alloc = alloc;

    parser.had_error = false;
    parser.panic_mode = false;

    advance();
    expression();
    consume(.eof, "Expect end of expression.");
    endCompiler();

    return !parser.had_error;
}

/// Free any memory retained by the module-global error list. Safe to
/// call repeatedly; the next `compile` re-initializes the list.
pub fn deinit(alloc: std.mem.Allocator) void {
    errors.deinit(alloc);
    errors = .empty;
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
        errorAtPrevious("Expected an expression: a string, a character literal, '.', or '('.");
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
    if (comptime print_code) {
        if (!parser.had_error) {
            debug.disassembleChunk(currentChunk(), "code");
        }
    }
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
    parser.had_error = true;

    // Scanner errors put the diagnostic text in the lexeme field;
    // surface that to the caller in place of the parser's message.
    const msg = if (token.type == .err) token.lexeme else message;

    errors.append(errors_alloc, .{
        .line = token.line,
        .column = token.column,
        .start = token.start,
        .len = token.len,
        .message = msg,
        .at_eof = token.type == .eof,
    }) catch {
        // If we cannot even record the error, fall back to a direct
        // write so the failure is not silently swallowed.
        std.debug.print("[line {d}] Error: {s}\n", .{ token.line, msg });
    };
}

/// Renders all diagnostics from the most recent `compile` call to the
/// given writer, one per error, with a source snippet and caret:
///
///     error: Expect expression.
///      --> line 1, column 5
///       |
///     1 | "a" )
///       |     ^ Expect expression.
///
/// `source` must be the same buffer passed to `compile`.
pub fn renderErrors(source: []const u8, writer: *std.Io.Writer) !void {
    for (errors.items) |e| {
        try renderOne(source, writer, e);
    }
}

fn renderOne(source: []const u8, writer: *std.Io.Writer, e: CompileError) !void {
    try writer.print("error: {s}\n", .{e.message});
    try writer.print(" --> line {d}, column {d}\n", .{ e.line, e.column });

    const line_range = findLine(source, e.line);
    const line_text = source[line_range.start..line_range.end];

    // Clamp the caret column into the rendered line so a reported
    // column past end-of-line (e.g. EOF on an empty file) still
    // produces a readable pointer rather than running off the edge.
    const caret_col = if (e.column == 0) 1 else e.column;
    const caret_pad = caret_col - 1;
    const caret_len: usize = if (e.at_eof) 1 else @max(e.len, 1);

    try writer.print("{d: >4} | {s}\n", .{ e.line, line_text });
    try writer.writeAll("     | ");
    var i: usize = 0;
    while (i < caret_pad) : (i += 1) try writer.writeByte(' ');
    i = 0;
    while (i < caret_len) : (i += 1) try writer.writeByte('^');
    try writer.print(" {s}\n", .{e.message});
}

const LineRange = struct { start: usize, end: usize };

fn findLine(source: []const u8, line: usize) LineRange {
    var current_line: usize = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (current_line == line and source[i] == '\n') {
            return .{ .start = start, .end = i };
        }
        if (source[i] == '\n') {
            current_line += 1;
            start = i + 1;
        }
    }
    if (current_line == line) {
        return .{ .start = start, .end = source.len };
    }
    return .{ .start = source.len, .end = source.len };
}

fn compileForTest(alloc: std.mem.Allocator, source: []const u8) !struct {
    chunk: Chunk,
    ok: bool,
} {
    var c = Chunk.init(alloc);
    const ok = compile(alloc, source, &c);
    return .{ .chunk = c, .ok = ok };
}

test "stray token at start flags Expected-an-expression diagnostic" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, ")");
    defer result.chunk.deinit();
    defer deinit(alloc);

    try std.testing.expect(!result.ok);
    const errs = getErrors();
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expectEqual(@as(usize, 1), errs[0].line);
    try std.testing.expectEqual(@as(usize, 1), errs[0].column);
    try std.testing.expect(!errs[0].at_eof);
}

test "empty source flags Expected-an-expression at eof" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "");
    defer result.chunk.deinit();
    defer deinit(alloc);

    try std.testing.expect(!result.ok);
    const errs = getErrors();
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expect(errs[0].at_eof);
}

test "renderErrors produces snippet with caret pointing at token" {
    const alloc = std.testing.allocator;
    const src = "   )";
    var result = try compileForTest(alloc, src);
    defer result.chunk.deinit();
    defer deinit(alloc);

    try std.testing.expect(!result.ok);

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try renderErrors(src, &aw.writer);

    const expected =
        "error: Expected an expression: a string, a character literal, '.', or '('.\n" ++
        " --> line 1, column 4\n" ++
        "   1 |    )\n" ++
        "     |    ^ Expected an expression: a string, a character literal, '.', or '('.\n";
    try std.testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "scanner error surfaces through compile with correct location" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "\"unterminated");
    defer result.chunk.deinit();
    defer deinit(alloc);

    try std.testing.expect(!result.ok);
    const errs = getErrors();
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expectEqualStrings("Unterminated string.", errs[0].message);
    try std.testing.expectEqual(@as(usize, 1), errs[0].column);
}
