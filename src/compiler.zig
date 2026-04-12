const std = @import("std");
const scanner = @import("scanner.zig");
const chunk_mod = @import("chunk.zig");
const debug = @import("debug.zig");
const object = @import("object.zig");
const value_mod = @import("value.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Value = value_mod.Value;
const Token = scanner.Token;
const TokenType = scanner.TokenType;

/// Maps rule names to numeric indices and stores compiled chunks in a
/// flat array for direct-index dispatch. The name map is used at
/// compile time; at runtime op_call uses the index to jump straight
/// to the chunk without a hash lookup.
pub const RuleTable = struct {
    by_name: std.StringHashMapUnmanaged(u32) = .{},
    chunks: std.ArrayListUnmanaged(?Chunk) = .{},
    names: std.ArrayListUnmanaged([]const u8) = .{},

    /// Return the index for `name`, allocating a new slot if this is
    /// the first reference. Forward references get a null chunk that
    /// ruleDeclaration fills in later.
    pub fn getOrCreateIndex(self: *RuleTable, alloc: std.mem.Allocator, name: []const u8) !u32 {
        const gop = try self.by_name.getOrPut(alloc, name);
        if (!gop.found_existing) {
            const idx: u32 = @intCast(self.chunks.items.len);
            gop.value_ptr.* = idx;
            try self.chunks.append(alloc, null);
            try self.names.append(alloc, name);
        }
        return gop.value_ptr.*;
    }

    pub fn setChunk(self: *RuleTable, index: u32, c: Chunk) void {
        if (self.chunks.items[index]) |*old| old.deinit();
        self.chunks.items[index] = c;
    }

    pub fn getChunkPtr(self: *RuleTable, index: u32) ?*Chunk {
        if (self.chunks.items[index]) |*c| return c;
        return null;
    }

    pub fn count(self: *const RuleTable) usize {
        return self.by_name.count();
    }

    pub fn get(self: *const RuleTable, name: []const u8) ?u32 {
        return self.by_name.get(name);
    }

    pub fn deinit(self: *RuleTable, alloc: std.mem.Allocator) void {
        for (self.chunks.items) |*slot| {
            if (slot.*) |*c| c.deinit();
        }
        self.chunks.deinit(alloc);
        self.names.deinit(alloc);
        self.by_name.deinit(alloc);
    }
};

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
var compiling_rules: ?*RuleTable = null;
var last_rule_name: ?Token = null;
var had_expression: bool = false;
// Bytecode offset where the current expression started, used by
// choice and quantifier operators to retroactively wrap compiled
// code with backtracking instructions. Saved and restored across
// recursive parsePrecedence calls.
var last_expr_start: usize = 0;

fn currentChunk() *Chunk {
    return compiling_chunk;
}

/// Diagnostics produced by the most recent `compile` call. The slice is
/// invalidated the next time `compile` is called.
pub fn getErrors() []const CompileError {
    return errors.items;
}

pub fn compile(alloc: std.mem.Allocator, source: []const u8, chunk: *Chunk, rule_table: *RuleTable) bool {
    scanner.init(source);
    compiling_chunk = chunk;
    compiling_source = source;
    compiling_rules = rule_table;
    last_rule_name = null;
    had_expression = false;

    errors.clearRetainingCapacity();
    errors_alloc = alloc;

    parser.had_error = false;
    parser.panic_mode = false;

    advance();

    while (!check(.eof)) {
        declaration();
    }

    endCompiler();
    compiling_rules = null;

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

fn check(token_type: TokenType) bool {
    return parser.current.type == token_type;
}

fn match(token_type: TokenType) bool {
    if (!check(token_type)) return false;
    advance();
    return true;
}

fn expression() void {
    parsePrecedence(.choice);
}

fn declaration() void {
    if (match(.kw_rule)) {
        ruleDeclaration();
    } else {
        statement();
    }
    if (parser.panic_mode) synchronize();
}

fn statement() void {
    expressionStatement();
}

fn expressionStatement() void {
    expression();
    had_expression = true;
}

fn ruleDeclaration() void {
    consume(.identifier, "Expect rule name.");
    const name_token = parser.previous;
    consume(.equal, "Expect '=' after rule name.");

    const index = compiling_rules.?.getOrCreateIndex(errors_alloc, name_token.lexeme) catch {
        errorAtPrevious("Out of memory.");
        return;
    };

    // Compile the rule body into its own chunk.
    const saved_chunk = compiling_chunk;
    var rule_chunk = Chunk.init(errors_alloc);
    compiling_chunk = &rule_chunk;

    expression();
    emitByte(@intFromEnum(OpCode.op_return));

    if (comptime print_code) {
        if (!parser.had_error) {
            debug.disassembleChunk(currentChunk(), name_token.lexeme);
        }
    }

    compiling_chunk = saved_chunk;

    compiling_rules.?.setChunk(index, rule_chunk);
    last_rule_name = name_token;
}

fn synchronize() void {
    parser.panic_mode = false;

    while (parser.current.type != .eof) {
        if (parser.current.type == .kw_rule) return;
        advance();
    }
}

fn namedRule() void {
    const name = parser.previous;
    const index = compiling_rules.?.getOrCreateIndex(errors_alloc, name.lexeme) catch {
        errorAtPrevious("Out of memory.");
        return;
    };
    emitRuleCall(index);
}

// Pratt loop. Sequence is the only operator without a token of its own:
// two juxtaposed primaries are a sequence with no opcode between them.
// The loop handles it as a second case after infix dispatch (see ADR 005):
// if the next token can start a primary, recurse one precedence level
// tighter so that sequence stays left-associative.
fn parsePrecedence(precedence: Precedence) void {
    const saved_expr_start = last_expr_start;
    last_expr_start = currentChunk().code.items.len;

    advance();
    const prefix_rule = getRule(parser.previous.type).prefix orelse {
        errorAtPrevious("Expected an expression: a string, a character literal, '.', '[', '(', or a rule name.");
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

    last_expr_start = saved_expr_start;
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
    t[@intFromEnum(TokenType.left_bracket)] = .{ .prefix = charset, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.string)] = .{ .prefix = stringLiteral, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.string_i)] = .{ .prefix = stringLiteralIgnoreCase, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.char)] = .{ .prefix = charLiteral, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.dot)] = .{ .prefix = anyChar, .infix = null, .precedence = .none };
    t[@intFromEnum(TokenType.identifier)] = .{ .prefix = namedRule, .infix = null, .precedence = .none };

    t[@intFromEnum(TokenType.slash)] = .{ .prefix = null, .infix = choiceOp, .precedence = .choice };
    t[@intFromEnum(TokenType.pipe)] = .{ .prefix = null, .infix = choiceOp, .precedence = .choice };
    t[@intFromEnum(TokenType.star)] = .{ .prefix = null, .infix = starOp, .precedence = .quantifier };
    t[@intFromEnum(TokenType.plus)] = .{ .prefix = null, .infix = plusOp, .precedence = .quantifier };
    t[@intFromEnum(TokenType.question)] = .{ .prefix = null, .infix = questionOp, .precedence = .quantifier };

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
    // escapes and multi-byte forms will land with extended charset work.
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

/// Compile a charset expression: `[` has already been consumed.
/// The body is a sequence of single characters ('a') and ranges ('a'-'z').
/// Each element sets bits in a 256-bit membership vector. The result is
/// emitted as an op_match_charset referencing an ObjCharset constant.
fn charset() void {
    var bits: [32]u8 = .{0} ** 32;

    if (parser.current.type == .right_bracket) {
        errorAtCurrent("Empty charset.");
        advance();
        return;
    }

    while (parser.current.type != .right_bracket and parser.current.type != .eof) {
        if (parser.current.type != .char) {
            errorAtCurrent("Expected a character literal inside charset.");
            return;
        }
        advance();
        const lo = extractCharByte(parser.previous.lexeme) orelse return;

        if (parser.current.type == .minus) {
            // Range: 'a'-'z'
            advance(); // consume '-'
            if (parser.current.type != .char) {
                errorAtCurrent("Expected a character literal after '-' in charset range.");
                return;
            }
            advance();
            const hi = extractCharByte(parser.previous.lexeme) orelse return;

            if (lo > hi) {
                errorAtPrevious("Charset range start must not exceed range end.");
                return;
            }

            var byte: usize = lo;
            while (byte <= hi) : (byte += 1) {
                bits[byte >> 3] |= @as(u8, 1) << @intCast(byte & 0x07);
            }
        } else {
            // Single character.
            bits[lo >> 3] |= @as(u8, 1) << @intCast(lo & 0x07);
        }
    }

    consume(.right_bracket, "Expect ']' after charset.");

    const cs = object.createCharset(bits) catch {
        errorAtPrevious("Out of memory.");
        return;
    };

    currentChunk().emitOpConstant(
        .op_match_charset,
        .op_match_charset_wide,
        .{ .obj = cs.asObj() },
        parser.previous.line,
    ) catch {
        errorAtPrevious("Out of memory.");
    };
}

fn extractCharByte(lexeme: []const u8) ?u8 {
    if (lexeme.len != 3) {
        errorAtPrevious("Character literal must be a single byte.");
        return null;
    }
    return lexeme[1];
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

fn emitRuleCall(index: u32) void {
    if (index <= std.math.maxInt(u8)) {
        emitBytes(@intFromEnum(OpCode.op_call), @intCast(index));
    } else {
        emitByte(@intFromEnum(OpCode.op_call_wide));
        emitByte(@intCast(index & 0xff));
        emitByte(@intCast((index >> 8) & 0xff));
        emitByte(@intCast((index >> 16) & 0xff));
    }
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

// Emit a jump instruction with a 2-byte placeholder offset. Returns
// the bytecode offset of the instruction (for later backpatching).
fn emitJump(op: OpCode) usize {
    const offset = currentChunk().code.items.len;
    emitByte(@intFromEnum(op));
    emitByte(0);
    emitByte(0);
    return offset;
}

// Backpatch a forward jump: write the offset from the instruction at
// `offset` to the current end of the chunk.
fn patchJump(offset: usize) void {
    const target = currentChunk().code.items.len;
    const ip_after = offset + 3;
    const jump = @as(i32, @intCast(target)) - @as(i32, @intCast(ip_after));
    if (jump < 0 or jump > std.math.maxInt(i16)) {
        errorAtPrevious("Too much code to jump over.");
        return;
    }
    const j: u16 = @intCast(jump);
    currentChunk().code.items[offset + 1] = @intCast(j & 0xff);
    currentChunk().code.items[offset + 2] = @intCast(j >> 8);
}

// Emit an op_commit that jumps backward to `loop_start`.
fn emitLoop(loop_start: usize) void {
    emitByte(@intFromEnum(OpCode.op_commit));
    const ip_after = currentChunk().code.items.len + 2;
    const offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(ip_after));
    if (offset < std.math.minInt(i16) or offset > std.math.maxInt(i16)) {
        errorAtPrevious("Loop body too large.");
        return;
    }
    const off16: u16 = @bitCast(@as(i16, @intCast(offset)));
    emitByte(@intCast(off16 & 0xff));
    emitByte(@intCast(off16 >> 8));
}

// Insert an OP_CHOICE placeholder (3 zero bytes) at `offset` in the
// chunk, shifting existing code to the right.
fn insertChoicePlaceholder(offset: usize) void {
    currentChunk().insertBytesAt(offset, 3) catch {
        errorAtPrevious("Out of memory.");
        return;
    };
    currentChunk().code.items[offset] = @intFromEnum(OpCode.op_choice);
}

// Ordered choice infix: A / B. When called, A is already compiled
// starting at last_expr_start. We retroactively insert OP_CHOICE
// before A, emit OP_COMMIT after A, then compile B.
fn choiceOp() void {
    const left_start = last_expr_start;
    insertChoicePlaceholder(left_start);
    const commit_offset = emitJump(.op_commit);
    // Patch OP_CHOICE: on failure, jump to start of alternative.
    patchJump(left_start);
    // Compile right operand (right-associative: same precedence).
    parsePrecedence(.choice);
    // Patch OP_COMMIT: on success, jump past alternative.
    patchJump(commit_offset);
}

// A* : zero or more.
fn starOp() void {
    const operand_start = last_expr_start;
    insertChoicePlaceholder(operand_start);
    // OP_COMMIT loops back to the OP_CHOICE.
    emitLoop(operand_start);
    // Patch OP_CHOICE: on failure, exit loop.
    patchJump(operand_start);
}

// A+ : one or more. Compiled as: A (choice-loop of A).
// The first A must match; subsequent iterations use choice/commit.
fn plusOp() void {
    const operand_start = last_expr_start;
    const operand_len = currentChunk().code.items.len - operand_start;
    if (operand_len > 256) {
        errorAtPrevious("Pattern too large for '+' quantifier.");
        return;
    }
    // Copy the operand bytecode (before emitting anything that could
    // trigger a reallocation and invalidate a slice into the code).
    var buf: [256]u8 = undefined;
    @memcpy(buf[0..operand_len], currentChunk().code.items[operand_start..][0..operand_len]);

    // Emit: OP_CHOICE <exit> [duplicated A] OP_COMMIT <back>
    const choice_offset = emitJump(.op_choice);
    for (buf[0..operand_len]) |byte| {
        emitByte(byte);
    }
    emitLoop(choice_offset);
    patchJump(choice_offset);
}

// A? : optional.
fn questionOp() void {
    const operand_start = last_expr_start;
    insertChoicePlaceholder(operand_start);
    const commit_offset = emitJump(.op_commit);
    // Patch OP_CHOICE: on failure, skip past OP_COMMIT.
    patchJump(operand_start);
    // Patch OP_COMMIT: continue (offset 0 since target is next byte).
    patchJump(commit_offset);
}

fn emitMatchString(narrow: OpCode, wide: OpCode, bytes: []const u8) void {
    const lit = object.copyLiteral(bytes) catch {
        errorAtPrevious("Out of memory.");
        return;
    };
    currentChunk().emitOpConstant(narrow, wide, .{ .obj = lit.asObj() }, parser.previous.line) catch {
        errorAtPrevious("Out of memory.");
    };
}

fn endCompiler() void {
    // If no bare expression was compiled but rules were defined,
    // auto-emit a call to the last rule as the entry point.
    if (!had_expression) {
        if (last_rule_name) |name| {
            const index = compiling_rules.?.getOrCreateIndex(errors_alloc, name.lexeme) catch {
                errorAtPrevious("Out of memory.");
                emitHalt();
                return;
            };
            emitRuleCall(index);
        }
    }
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

const TestCompileResult = struct {
    chunk: Chunk,
    rules: RuleTable,
    ok: bool,
    alloc: std.mem.Allocator,

    fn deinit(self: *TestCompileResult) void {
        self.chunk.deinit();
        self.rules.deinit(self.alloc);
    }
};

fn compileForTest(alloc: std.mem.Allocator, source: []const u8) !TestCompileResult {
    var c = Chunk.init(alloc);
    var rt: RuleTable = .{};
    const ok = compile(alloc, source, &c, &rt);
    return .{ .chunk = c, .rules = rt, .ok = ok, .alloc = alloc };
}

test "stray token at start flags Expected-an-expression diagnostic" {
    const alloc = std.testing.allocator;
    object.init(alloc);
    defer object.freeObjects();
    var result = try compileForTest(alloc, ")");
    defer result.deinit();
    defer deinit(alloc);

    try std.testing.expect(!result.ok);
    const errs = getErrors();
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expectEqual(@as(usize, 1), errs[0].line);
    try std.testing.expectEqual(@as(usize, 1), errs[0].column);
    try std.testing.expect(!errs[0].at_eof);
}

test "empty source compiles to just halt" {
    const alloc = std.testing.allocator;
    object.init(alloc);
    defer object.freeObjects();
    var result = try compileForTest(alloc, "");
    defer result.deinit();
    defer deinit(alloc);

    // An empty program is valid: no declarations, main chunk is just OP_HALT.
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(usize, 1), result.chunk.code.items.len);
    try std.testing.expectEqual(
        @intFromEnum(OpCode.op_halt),
        result.chunk.code.items[0],
    );
}

test "renderErrors produces snippet with caret pointing at token" {
    const alloc = std.testing.allocator;
    object.init(alloc);
    defer object.freeObjects();
    const src = "   )";
    var result = try compileForTest(alloc, src);
    defer result.deinit();
    defer deinit(alloc);

    try std.testing.expect(!result.ok);

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try renderErrors(src, &aw.writer);

    const expected =
        "error: Expected an expression: a string, a character literal, '.', '[', '(', or a rule name.\n" ++
        " --> line 1, column 4\n" ++
        "   1 |    )\n" ++
        "     |    ^ Expected an expression: a string, a character literal, '.', '[', '(', or a rule name.\n";
    try std.testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "rule declaration populates rule table" {
    const alloc = std.testing.allocator;
    object.init(alloc);
    defer object.freeObjects();
    var result = try compileForTest(alloc, "rule digit = ['0'-'9']");
    defer result.deinit();
    defer deinit(alloc);

    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(usize, 1), result.rules.count());
    try std.testing.expect(result.rules.get("digit") != null);
}

test "multiple rule declarations populate rule table" {
    const alloc = std.testing.allocator;
    object.init(alloc);
    defer object.freeObjects();
    var result = try compileForTest(
        alloc,
        "rule digit = ['0'-'9']\nrule alpha = ['a'-'z']",
    );
    defer result.deinit();
    defer deinit(alloc);

    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(usize, 2), result.rules.count());
    try std.testing.expect(result.rules.get("digit") != null);
    try std.testing.expect(result.rules.get("alpha") != null);
}

test "auto-call emits op_call for last rule in main chunk" {
    const alloc = std.testing.allocator;
    object.init(alloc);
    defer object.freeObjects();
    var result = try compileForTest(alloc, "rule digit = ['0'-'9']");
    defer result.deinit();
    defer deinit(alloc);

    try std.testing.expect(result.ok);
    // Main chunk should have: OP_CALL <index> OP_HALT
    try std.testing.expect(result.chunk.code.items.len >= 3);
    try std.testing.expectEqual(
        @intFromEnum(OpCode.op_call),
        result.chunk.code.items[0],
    );
}

test "error recovery skips to next rule" {
    const alloc = std.testing.allocator;
    object.init(alloc);
    defer object.freeObjects();
    // First rule has a bad body; second rule is valid.
    var result = try compileForTest(
        alloc,
        "rule bad = )\nrule digit = ['0'-'9']",
    );
    defer result.deinit();
    defer deinit(alloc);

    try std.testing.expect(!result.ok);
    // Despite the error, the second rule should still be in the table.
    try std.testing.expect(result.rules.get("digit") != null);
}

test "repeated rule calls emit the same index operand" {
    const alloc = std.testing.allocator;
    object.init(alloc);
    defer object.freeObjects();
    // The rule body contains three calls to "digit" via sequence.
    var result = try compileForTest(
        alloc,
        "rule digit = ['0'-'9']\nrule triple = digit digit digit",
    );
    defer result.deinit();
    defer deinit(alloc);

    try std.testing.expect(result.ok);
    // The "triple" rule chunk: three op_call + op_return = 7 bytes.
    const triple = result.rules.getChunkPtr(result.rules.get("triple").?) orelse
        return error.TestUnexpectedResult;
    const code = triple.code.items;
    try std.testing.expectEqual(@as(usize, 7), code.len);
    const call_op = @intFromEnum(OpCode.op_call);
    try std.testing.expectEqual(call_op, code[0]);
    try std.testing.expectEqual(call_op, code[2]);
    try std.testing.expectEqual(call_op, code[4]);
    // All three share the same rule index.
    try std.testing.expectEqual(code[1], code[3]);
    try std.testing.expectEqual(code[1], code[5]);
}

test "scanner error surfaces through compile with correct location" {
    const alloc = std.testing.allocator;
    object.init(alloc);
    defer object.freeObjects();
    var result = try compileForTest(alloc, "\"unterminated");
    defer result.deinit();
    defer deinit(alloc);

    try std.testing.expect(!result.ok);
    const errs = getErrors();
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expectEqualStrings("Unterminated string.", errs[0].message);
    try std.testing.expectEqual(@as(usize, 1), errs[0].column);
}
