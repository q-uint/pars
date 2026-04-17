const std = @import("std");
const pars_stdlib = @import("pars_stdlib");
const scanner_mod = @import("scanner.zig");
const chunk_mod = @import("chunk.zig");
const debug = @import("debug.zig");
const object = @import("object.zig");
const value_mod = @import("value.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Value = value_mod.Value;
const Scanner = scanner_mod.Scanner;
const Token = scanner_mod.Token;
const TokenType = scanner_mod.TokenType;

/// Maps rule names to numeric indices and stores compiled chunks in a
/// flat array for direct-index dispatch. The name map is used at
/// compile time; at runtime op_call uses the index to jump straight
/// to the chunk without a hash lookup.
pub const RuleTable = struct {
    by_name: std.StringHashMapUnmanaged(u32) = .empty,
    chunks: std.ArrayListUnmanaged(?Chunk) = .empty,
    names: std.ArrayListUnmanaged([]const u8) = .empty,

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

// One local in scope during the current rule body. A local is either a
// where-bound sub-rule (resolved via rule_index) or a let-capture
// (resolved via capture_slot). The compiler pre-registers where-bindings
// before compiling the main body so forward references work.
const Local = struct {
    name: Token,
    // Scope depth at which this local was declared. -1 marks a local
    // that has been declared but not yet initialized, which guards
    // against self-referential patterns like `let x = x`.
    depth: i32,
    // Rule table index for where-bound sub-rules. namedRule checks
    // locals[] first and emits op_call with this index on a hit.
    rule_index: u32 = 0,
    // VM capture slot for let-bindings. At runtime op_capture_begin
    // saves the input position into this slot and op_capture_end
    // stores the resulting Span.
    capture_slot: u8 = 0,
    // True when this local is a let-capture rather than a where-binding.
    is_capture: bool = false,
    // Set to true the first time namedRule resolves this binding. At
    // endScope, any local still false is reported as unused so a typo
    // like `where k = ident end => kk` surfaces immediately.
    used: bool = false,
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

/// Single-pass compiler that translates PEG source into bytecode. All
/// mutable compilation state lives in this struct, making the compiler
/// reentrant and safe to embed in contexts that require independent
/// compilation sessions.
pub const Compiler = struct {
    parser: Parser = undefined,
    compiling_chunk: *Chunk = undefined,
    errors: std.ArrayList(CompileError) = .empty,
    // Backing buffers for diagnostics whose messages are formatted at
    // runtime. Freed at the start of each compile and in deinit; errors
    // whose messages are string literals are not tracked here.
    owned_error_messages: std.ArrayList([]u8) = .empty,
    alloc: std.mem.Allocator,
    compiling_source: []const u8 = &.{},
    compiling_rules: ?*RuleTable = null,
    last_rule_name: ?Token = null,
    had_expression: bool = false,
    // Bytecode offset where the current expression started, used by
    // choice and quantifier operators to retroactively wrap compiled
    // code with backtracking instructions. Saved and restored across
    // recursive parsePrecedence calls.
    last_expr_start: usize = 0,
    obj_pool: *object.ObjPool = undefined,
    scanner: Scanner = undefined,
    // Locals in scope during the current rule body. Indexed by compile-
    // time slot number; the VM reads them by the same index at runtime.
    // Capped at 256 so slot indices fit in a single byte operand.
    locals: [256]Local = undefined,
    local_count: usize = 0,
    // Nesting depth of the current scope within a rule body. 0 at the
    // outermost level, incremented by beginScope and decremented by
    // endScope. Used to decide which locals to pop when a scope exits.
    scope_depth: u32 = 0,
    // Number of capture slots allocated in the current rule body.
    // Each `let` binding gets the next slot. Reset per rule.
    capture_count: u8 = 0,

    const ParseFn = *const fn (self: *Compiler) void;

    const ParseRule = struct {
        prefix: ?ParseFn,
        infix: ?ParseFn,
        precedence: Precedence,
    };

    pub fn init(alloc: std.mem.Allocator) Compiler {
        return .{ .alloc = alloc };
    }

    fn currentChunk(self: *Compiler) *Chunk {
        return self.compiling_chunk;
    }

    fn beginScope(self: *Compiler) void {
        self.scope_depth += 1;
    }

    fn endScope(self: *Compiler) void {
        self.scope_depth -= 1;
        // Discard every local whose depth exceeds the new scope level.
        // Where-rules live in the rule table, not on the value stack,
        // so no op_pop is emitted -- the compiler just forgets them.
        // Report any local that was never resolved by namedRule so typos
        // and leftover bindings surface. Skipped when the current rule
        // body is already in error recovery to avoid noise on broken
        // input.
        while (self.local_count > 0 and
            self.locals[self.local_count - 1].depth > @as(i32, @intCast(self.scope_depth)))
        {
            const local = self.locals[self.local_count - 1];
            // Capture bindings are useful by their existence (they record
            // spans); skip the unused check for them. Where-bindings that
            // are never referenced are likely typos and are still reported.
            if (!local.used and !local.is_capture and !self.parser.panic_mode) {
                self.reportUnusedLocal(local);
            }
            self.local_count -= 1;
        }
    }

    // Emit an "unused where-binding" diagnostic for `local`. Bypasses the
    // errorAt panic gate so every unused binding in the same scope gets
    // reported in one pass, and points the caret at the original name
    // token recorded when the binding was registered.
    fn reportUnusedLocal(self: *Compiler, local: Local) void {
        const kind = if (local.is_capture) "capture" else "where";
        const buf = std.fmt.allocPrint(
            self.alloc,
            "Unused {s}-binding '{s}'.",
            .{ kind, local.name.lexeme },
        ) catch return;
        self.owned_error_messages.append(self.alloc, buf) catch {
            self.alloc.free(buf);
            return;
        };
        self.errors.append(self.alloc, .{
            .line = local.name.line,
            .column = local.name.column,
            .start = local.name.start,
            .len = local.name.len,
            .message = buf,
            .at_eof = false,
        }) catch return;
        self.parser.had_error = true;
    }

    fn identifiersEqual(a: Token, b: Token) bool {
        return std.mem.eql(u8, a.lexeme, b.lexeme);
    }

    fn addLocal(self: *Compiler, name: Token) void {
        if (self.local_count >= 256) {
            self.errorAtPrevious("Too many local variables in rule.");
            return;
        }
        self.locals[self.local_count] = .{ .name = name, .depth = -1 };
        self.local_count += 1;
    }

    // Record the existence of a local. Checks for a duplicate name in
    // the current scope before delegating to addLocal. Locals are added
    // with depth=-1 (uninitialized) until markInitialized is called.
    fn declareVariable(self: *Compiler, name: Token) void {
        var i = self.local_count;
        while (i > 0) {
            i -= 1;
            const local = self.locals[i];
            if (local.depth != -1 and local.depth < @as(i32, @intCast(self.scope_depth))) break;
            if (identifiersEqual(name, local.name)) {
                self.errorAtPrevious("Already a variable with this name in this scope.");
                return;
            }
        }
        self.addLocal(name);
    }

    // Mark the most recently declared local as fully initialized by
    // recording its actual scope depth (replacing the -1 sentinel).
    fn markInitialized(self: *Compiler) void {
        self.locals[self.local_count - 1].depth = @intCast(self.scope_depth);
    }

    /// Diagnostics produced by the most recent `compile` call. The slice is
    /// invalidated the next time `compile` is called.
    pub fn getErrors(self: *const Compiler) []const CompileError {
        return self.errors.items;
    }

    pub fn compile(self: *Compiler, source: []const u8, chunk: *Chunk, rule_table: *RuleTable, obj_pool: *object.ObjPool) bool {
        self.scanner = Scanner.init(source);
        self.obj_pool = obj_pool;
        self.compiling_chunk = chunk;
        self.compiling_source = source;
        self.compiling_rules = rule_table;
        self.last_rule_name = null;
        self.had_expression = false;

        self.errors.clearRetainingCapacity();
        for (self.owned_error_messages.items) |buf| self.alloc.free(buf);
        self.owned_error_messages.clearRetainingCapacity();

        self.parser.had_error = false;
        self.parser.panic_mode = false;
        self.local_count = 0;
        self.scope_depth = 0;
        self.capture_count = 0;

        self.advance();

        while (!self.check(.eof)) {
            self.declaration();
        }

        self.endCompiler();
        self.compiling_rules = null;

        return !self.parser.had_error;
    }

    pub fn deinit(self: *Compiler) void {
        self.errors.deinit(self.alloc);
        self.errors = .empty;
        for (self.owned_error_messages.items) |buf| self.alloc.free(buf);
        self.owned_error_messages.deinit(self.alloc);
        self.owned_error_messages = .empty;
    }

    fn advance(self: *Compiler) void {
        self.parser.previous = self.parser.current;

        while (true) {
            self.parser.current = self.scanner.scanToken();
            if (self.parser.current.type != .err) break;

            self.errorAtCurrent(self.parser.current.lexeme);
        }
    }

    fn consume(self: *Compiler, token_type: TokenType, message: []const u8) void {
        if (self.parser.current.type == token_type) {
            self.advance();
            return;
        }
        self.errorAtCurrent(message);
    }

    fn check(self: *Compiler, token_type: TokenType) bool {
        return self.parser.current.type == token_type;
    }

    fn match(self: *Compiler, token_type: TokenType) bool {
        if (!self.check(token_type)) return false;
        self.advance();
        return true;
    }

    fn expression(self: *Compiler) void {
        self.parsePrecedence(.choice);
    }

    // Return true when the current token is an identifier immediately
    // followed by '=', which signals a rule declaration.
    fn peekIsEqual(self: *const Compiler) bool {
        var peek = self.scanner;
        while (true) {
            const tok = peek.scanToken();
            if (tok.type != .err) return tok.type == .equal;
        }
    }

    fn declaration(self: *Compiler) void {
        if (self.check(.kw_use)) {
            self.advance();
            self.useDeclaration();
        } else if (self.check(.identifier) and self.peekIsEqual()) {
            self.ruleDeclaration();
        } else {
            self.statement();
        }
        if (self.parser.panic_mode) self.synchronize();
    }

    // Resolve a "std/..." module path to its embedded source. Returns null
    // if the name is not a known stdlib module.
    fn resolveStdlib(path: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, path, "std/abnf")) return pars_stdlib.abnf;
        return null;
    }

    // Compile and merge a module's rules into the current rule table.
    // The module's "main" chunk (entry point) is discarded; only the
    // rule declarations it defines are kept.
    fn useDeclaration(self: *Compiler) void {
        self.consume(.string, "Expect a module path string after 'use'.");
        if (self.parser.had_error) return;

        const raw = self.parser.previous.lexeme;
        const path = stripStringDelimiters(raw, 0);

        const src = resolveStdlib(path) orelse {
            self.errorAtPrevious("Unknown module. Relative imports are not yet supported.");
            return;
        };

        var sub = Compiler.init(self.alloc);
        defer sub.deinit();
        var dummy = Chunk.init(self.alloc);
        defer dummy.deinit();
        if (!sub.compile(src, &dummy, self.compiling_rules.?, self.obj_pool)) {
            self.errorAtPrevious("Module failed to compile.");
        }

        _ = self.match(.semicolon);
    }

    fn statement(self: *Compiler) void {
        self.expressionStatement();
    }

    fn expressionStatement(self: *Compiler) void {
        self.expression();
        self.had_expression = true;
    }

    // Advance the scanner without emitting diagnostics. Used by the
    // where pre-scan pass, which restores parser state afterwards.
    fn advanceRaw(self: *Compiler) void {
        self.parser.previous = self.parser.current;
        self.parser.current = self.scanner.scanToken();
    }

    // Pre-scan the token stream to find the 'where' block (if any) and
    // register every sub-rule name in locals[] before the main body is
    // compiled. This gives the main body and each sub-rule body the full
    // set of where-bound names in scope, supporting mutual recursion.
    // Scanner and parser state are restored after the scan.
    fn preRegisterWhereNames(self: *Compiler) void {
        const saved_scanner = self.scanner;
        const saved_parser = self.parser;

        // Skip tokens until 'where', 'end', or eof.
        while (self.parser.current.type != .kw_where and
            self.parser.current.type != .kw_end and
            self.parser.current.type != .eof)
        {
            self.advanceRaw();
        }

        if (self.parser.current.type == .kw_where) {
            self.advanceRaw(); // consume 'where'
            while (self.parser.current.type != .kw_end and
                self.parser.current.type != .eof)
            {
                if (self.parser.current.type == .identifier) {
                    const name_tok = self.parser.current;
                    self.advanceRaw(); // consume identifier
                    if (self.parser.current.type == .equal) {
                        // This identifier begins a sub-rule declaration.
                        const rule_idx = self.compiling_rules.?.getOrCreateIndex(
                            self.alloc,
                            name_tok.lexeme,
                        ) catch break;
                        if (self.local_count < 256) {
                            self.locals[self.local_count] = .{
                                .name = name_tok,
                                .depth = @intCast(self.scope_depth),
                                .rule_index = rule_idx,
                            };
                            self.local_count += 1;
                        }
                    }
                } else {
                    self.advanceRaw();
                }
            }
        }

        self.scanner = saved_scanner;
        self.parser = saved_parser;
    }

    // Compile a 'where' block: a sequence of sub-rule declarations
    // terminated by 'end'. Each sub-rule has the form 'name = body'
    // with an optional trailing semicolon. The 'end' keyword serves as
    // both the block terminator and the outer rule's statement terminator
    // (no additional ';' is needed after 'end').
    fn whereBlock(self: *Compiler) void {
        // Tracks sub-rule names already declared in this block so a second
        // declaration of the same name is reported with a pointer back to
        // the first one, instead of silently overwriting its body.
        var seen: [256]Token = undefined;
        var seen_count: usize = 0;

        while (!self.check(.kw_end) and !self.check(.eof)) {
            self.consume(.identifier, "Expect sub-rule name in 'where'.");
            const name_tok = self.parser.previous;

            var duplicate_of: ?Token = null;
            for (seen[0..seen_count]) |prev| {
                if (identifiersEqual(name_tok, prev)) {
                    duplicate_of = prev;
                    break;
                }
            }
            if (duplicate_of) |prev| {
                // previous still points at name_tok (the duplicate) here,
                // so the caret lands on the offending identifier.
                self.errorAtPreviousFmt(
                    "Duplicate where-binding '{s}'. Previous declaration at line {d}, column {d}.",
                    .{ name_tok.lexeme, prev.line, prev.column },
                );
            } else if (seen_count < seen.len) {
                seen[seen_count] = name_tok;
                seen_count += 1;
            }

            self.consume(.equal, "Expect '=' after sub-rule name in 'where'.");

            // Find the pre-registered local index for this name.
            var rule_idx: ?u32 = null;
            for (self.locals[0..self.local_count]) |local| {
                if (identifiersEqual(name_tok, local.name)) {
                    rule_idx = local.rule_index;
                    break;
                }
            }
            if (rule_idx == null) {
                self.errorAtPrevious("Internal: where sub-rule name was not pre-registered.");
                return;
            }

            // Compile the sub-rule body into its own chunk. For a duplicate
            // we still walk the body to surface any further errors inside
            // it, but drop the chunk afterwards so the first declaration's
            // body remains authoritative.
            const saved_chunk = self.compiling_chunk;
            var sub_chunk = Chunk.init(self.alloc);
            self.compiling_chunk = &sub_chunk;
            self.expression();
            self.emitByte(@intFromEnum(OpCode.op_return));
            self.compiling_chunk = saved_chunk;

            if (duplicate_of == null) {
                self.compiling_rules.?.setChunk(rule_idx.?, sub_chunk);
            } else {
                sub_chunk.deinit();
            }

            // Trailing ';' is optional before 'end'.
            _ = self.match(.semicolon);
        }
        self.consume(.kw_end, "Expect 'end' to close 'where' block.");
    }

    fn ruleDeclaration(self: *Compiler) void {
        self.consume(.identifier, "Expect rule name.");
        const name_token = self.parser.previous;
        self.consume(.equal, "Expect '=' after rule name.");

        const index = self.compiling_rules.?.getOrCreateIndex(self.alloc, name_token.lexeme) catch {
            self.errorAtPrevious("Out of memory.");
            return;
        };

        // Compile the rule body into its own chunk. Each rule is an
        // independent scope, so local state starts fresh for every rule.
        const saved_chunk = self.compiling_chunk;
        var rule_chunk = Chunk.init(self.alloc);
        self.compiling_chunk = &rule_chunk;
        self.local_count = 0;
        self.scope_depth = 0;
        self.capture_count = 0;

        // Pre-scan for 'where' sub-rule names so the main body can
        // reference them. Must happen inside the scope.
        self.beginScope();
        self.preRegisterWhereNames();
        self.expression();
        const has_where = self.match(.kw_where);
        if (has_where) {
            self.whereBlock(); // consumes 'end'
        }
        self.endScope();
        self.emitByte(@intFromEnum(OpCode.op_return));

        if (comptime print_code) {
            if (!self.parser.had_error) {
                debug.disassembleChunk(self.currentChunk(), name_token.lexeme);
            }
        }

        self.compiling_chunk = saved_chunk;

        self.compiling_rules.?.setChunk(index, rule_chunk);
        self.last_rule_name = name_token;
        if (has_where) {
            // ';' after 'end' is optional.
            _ = self.match(.semicolon);
        } else {
            self.consume(.semicolon, "Expect ';' after rule body.");
        }
    }

    fn synchronize(self: *Compiler) void {
        self.parser.panic_mode = false;

        while (self.parser.current.type != .eof) {
            if (self.parser.previous.type == .semicolon) return;
            if (self.parser.previous.type == .kw_end) return;
            self.advance();
        }
    }

    fn namedRule(self: *Compiler) void {
        const name = self.parser.previous;
        // Check locals first (innermost scope wins).
        var i = self.local_count;
        while (i > 0) {
            i -= 1;
            const local = &self.locals[i];
            if (local.depth != -1 and identifiersEqual(name, local.name)) {
                local.used = true;
                if (local.is_capture) {
                    self.emitBytes(@intFromEnum(OpCode.op_match_backref), local.capture_slot);
                    return;
                }
                self.emitRuleCall(local.rule_index);
                return;
            }
        }
        // Fall through to the global rule table.
        const index = self.compiling_rules.?.getOrCreateIndex(self.alloc, name.lexeme) catch {
            self.errorAtPrevious("Out of memory.");
            return;
        };
        self.emitRuleCall(index);
    }

    // Prefix parser for `<name: pattern>`. The angle brackets provide
    // explicit visual boundaries for the captured region. Inside the
    // brackets, a full expression is parsed (choice-level precedence)
    // since `>` acts as an unambiguous terminator. After a successful
    // match, the name is available as a back-reference that matches the
    // same text byte-for-byte.
    fn capture(self: *Compiler) void {
        self.consume(.identifier, "Expect binding name after '<'.");
        const name = self.parser.previous;
        self.consume(.colon, "Expect ':' after capture name.");

        self.declareVariable(name);
        if (self.capture_count >= 255) {
            self.errorAtPrevious("Too many capture bindings in rule.");
            return;
        }
        const slot = self.capture_count;
        self.locals[self.local_count - 1].is_capture = true;
        self.locals[self.local_count - 1].capture_slot = slot;
        self.capture_count += 1;

        self.emitBytes(@intFromEnum(OpCode.op_capture_begin), slot);
        self.expression();
        self.markInitialized();
        self.emitBytes(@intFromEnum(OpCode.op_capture_end), slot);
        self.consume(.right_angle, "Expect '>' to close capture.");
    }

    // Pratt loop. Sequence is the only operator without a token of its own:
    // two juxtaposed primaries are a sequence with no opcode between them.
    // The loop handles it as a second case after infix dispatch (see ADR 005):
    // if the next token can start a primary, recurse one precedence level
    // tighter so that sequence stays left-associative.
    fn parsePrecedence(self: *Compiler, precedence: Precedence) void {
        const saved_expr_start = self.last_expr_start;
        self.last_expr_start = self.currentChunk().code.items.len;

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
                self.parsePrecedence(Precedence.sequence.next());
                continue;
            }

            break;
        }

        self.last_expr_start = saved_expr_start;
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
        t[@intFromEnum(TokenType.left_angle)] = .{ .prefix = capture, .infix = null, .precedence = .none };

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

    fn grouping(self: *Compiler) void {
        self.expression();
        self.consume(.right_paren, "Expect ')' after expression.");
    }

    fn anyChar(self: *Compiler) void {
        self.emitByte(@intFromEnum(OpCode.op_match_any));
    }

    fn charLiteral(self: *Compiler) void {
        const b = self.extractCharByte(self.parser.previous.lexeme) orelse return;
        self.emitBytes(@intFromEnum(OpCode.op_match_char), b);
    }

    fn stringLiteral(self: *Compiler) void {
        const bytes = stripStringDelimiters(self.parser.previous.lexeme, 0);
        self.emitMatchString(.op_match_string, .op_match_string_wide, bytes);
    }

    fn stringLiteralIgnoreCase(self: *Compiler) void {
        // The 'i' prefix counts as one extra leading byte before the quotes.
        const bytes = stripStringDelimiters(self.parser.previous.lexeme, 1);
        self.emitMatchString(.op_match_string_i, .op_match_string_i_wide, bytes);
    }

    /// Compile a charset expression: `[` has already been consumed.
    /// The body is a sequence of single characters ('a') and ranges ('a'-'z').
    /// Each element sets bits in a 256-bit membership vector. The result is
    /// emitted as an op_match_charset referencing an ObjCharset constant.
    fn charset(self: *Compiler) void {
        var bits: [32]u8 = .{0} ** 32;

        if (self.parser.current.type == .right_bracket) {
            self.errorAtCurrent("Empty charset.");
            self.advance();
            return;
        }

        while (self.parser.current.type != .right_bracket and self.parser.current.type != .eof) {
            if (self.parser.current.type != .char) {
                self.errorAtCurrent("Expected a character literal inside charset.");
                return;
            }
            self.advance();
            const lo = self.extractCharByte(self.parser.previous.lexeme) orelse return;

            if (self.parser.current.type == .minus) {
                // Range: 'a'-'z'
                self.advance(); // consume '-'
                if (self.parser.current.type != .char) {
                    self.errorAtCurrent("Expected a character literal after '-' in charset range.");
                    return;
                }
                self.advance();
                const hi = self.extractCharByte(self.parser.previous.lexeme) orelse return;

                if (lo > hi) {
                    self.errorAtPrevious("Charset range start must not exceed range end.");
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

        self.consume(.right_bracket, "Expect ']' after charset.");

        const cs = self.obj_pool.createCharset(bits) catch {
            self.errorAtPrevious("Out of memory.");
            return;
        };

        self.currentChunk().emitOpConstant(
            .op_match_charset,
            .op_match_charset_wide,
            .{ .obj = cs.asObj() },
            self.parser.previous.line,
        ) catch {
            self.errorAtPrevious("Out of memory.");
        };
    }

    fn extractCharByte(self: *Compiler, lexeme: []const u8) ?u8 {
        // lexeme includes surrounding single quotes, e.g. 'a', '\n', '\x41'.
        const inner = lexeme[1 .. lexeme.len - 1];

        if (inner.len == 0) {
            self.errorAtPrevious("Empty character literal.");
            return null;
        }

        if (inner[0] != '\\') {
            if (inner.len != 1) {
                self.errorAtPrevious("Character literal must be a single byte.");
                return null;
            }
            return inner[0];
        }

        // Escape sequence.
        if (inner.len < 2) {
            self.errorAtPrevious("Incomplete escape sequence in character literal.");
            return null;
        }
        switch (inner[1]) {
            'n' => return '\n',
            'r' => return '\r',
            't' => return '\t',
            '\\' => return '\\',
            '\'' => return '\'',
            'x' => {
                if (inner.len != 4) {
                    self.errorAtPrevious("Hex escape must be two digits: \\xNN.");
                    return null;
                }
                const hi = std.fmt.charToDigit(inner[2], 16) catch {
                    self.errorAtPrevious("Invalid hex digit in escape sequence.");
                    return null;
                };
                const lo = std.fmt.charToDigit(inner[3], 16) catch {
                    self.errorAtPrevious("Invalid hex digit in escape sequence.");
                    return null;
                };
                return (hi << 4) | lo;
            },
            else => {
                self.errorAtPrevious("Unknown escape sequence in character literal.");
                return null;
            },
        }
    }

    fn emitRuleCall(self: *Compiler, index: u32) void {
        if (index <= std.math.maxInt(u8)) {
            self.emitBytes(@intFromEnum(OpCode.op_call), @intCast(index));
        } else {
            self.emitByte(@intFromEnum(OpCode.op_call_wide));
            self.emitByte(@intCast(index & 0xff));
            self.emitByte(@intCast((index >> 8) & 0xff));
            self.emitByte(@intCast((index >> 16) & 0xff));
        }
    }

    fn emitByte(self: *Compiler, byte: u8) void {
        self.currentChunk().write(byte, self.parser.previous.line) catch {
            self.errorAtPrevious("Out of memory.");
        };
    }

    fn emitBytes(self: *Compiler, byte1: u8, byte2: u8) void {
        self.emitByte(byte1);
        self.emitByte(byte2);
    }

    fn emitHalt(self: *Compiler) void {
        self.emitByte(@intFromEnum(OpCode.op_halt));
    }

    // Emit a jump instruction with a 2-byte placeholder offset. Returns
    // the bytecode offset of the instruction (for later backpatching).
    fn emitJump(self: *Compiler, op: OpCode) usize {
        const offset = self.currentChunk().code.items.len;
        self.emitByte(@intFromEnum(op));
        self.emitByte(0);
        self.emitByte(0);
        return offset;
    }

    // Backpatch a forward jump: write the offset from the instruction at
    // `offset` to the current end of the chunk.
    fn patchJump(self: *Compiler, offset: usize) void {
        const target = self.currentChunk().code.items.len;
        const ip_after = offset + 3;
        const jump = @as(i32, @intCast(target)) - @as(i32, @intCast(ip_after));
        if (jump < 0 or jump > std.math.maxInt(i16)) {
            self.errorAtPrevious("Too much code to jump over.");
            return;
        }
        const j: u16 = @intCast(jump);
        self.currentChunk().code.items[offset + 1] = @intCast(j & 0xff);
        self.currentChunk().code.items[offset + 2] = @intCast(j >> 8);
    }

    // Emit an op_commit that jumps backward to `loop_start`.
    fn emitLoop(self: *Compiler, loop_start: usize) void {
        self.emitByte(@intFromEnum(OpCode.op_commit));
        const ip_after = self.currentChunk().code.items.len + 2;
        const offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(ip_after));
        if (offset < std.math.minInt(i16) or offset > std.math.maxInt(i16)) {
            self.errorAtPrevious("Loop body too large.");
            return;
        }
        const off16: u16 = @bitCast(@as(i16, @intCast(offset)));
        self.emitByte(@intCast(off16 & 0xff));
        self.emitByte(@intCast(off16 >> 8));
    }

    // Insert an OP_CHOICE placeholder (3 zero bytes) at `offset` in the
    // chunk, shifting existing code to the right.
    fn insertChoicePlaceholder(self: *Compiler, offset: usize) void {
        self.currentChunk().insertBytesAt(offset, 3) catch {
            self.errorAtPrevious("Out of memory.");
            return;
        };
        self.currentChunk().code.items[offset] = @intFromEnum(OpCode.op_choice);
    }

    // Ordered choice infix: A / B. When called, A is already compiled
    // starting at last_expr_start. We retroactively insert OP_CHOICE
    // before A, emit OP_COMMIT after A, then compile B.
    fn choiceOp(self: *Compiler) void {
        const left_start = self.last_expr_start;
        self.insertChoicePlaceholder(left_start);
        const commit_offset = self.emitJump(.op_commit);
        // Patch OP_CHOICE: on failure, jump to start of alternative.
        self.patchJump(left_start);
        // Compile right operand (right-associative: same precedence).
        self.parsePrecedence(.choice);
        // Patch OP_COMMIT: on success, jump past alternative.
        self.patchJump(commit_offset);
    }

    // A* : zero or more.
    fn starOp(self: *Compiler) void {
        const operand_start = self.last_expr_start;
        self.insertChoicePlaceholder(operand_start);
        // OP_COMMIT loops back to the OP_CHOICE.
        self.emitLoop(operand_start);
        // Patch OP_CHOICE: on failure, exit loop.
        self.patchJump(operand_start);
    }

    // A+ : one or more. Compiled as: A (choice-loop of A).
    // The first A must match; subsequent iterations use choice/commit.
    fn plusOp(self: *Compiler) void {
        const operand_start = self.last_expr_start;
        const operand_len = self.currentChunk().code.items.len - operand_start;
        if (operand_len > 256) {
            self.errorAtPrevious("Pattern too large for '+' quantifier.");
            return;
        }
        // Copy the operand bytecode (before emitting anything that could
        // trigger a reallocation and invalidate a slice into the code).
        var buf: [256]u8 = undefined;
        @memcpy(buf[0..operand_len], self.currentChunk().code.items[operand_start..][0..operand_len]);

        // Emit: OP_CHOICE <exit> [duplicated A] OP_COMMIT <back>
        const choice_offset = self.emitJump(.op_choice);
        for (buf[0..operand_len]) |byte| {
            self.emitByte(byte);
        }
        self.emitLoop(choice_offset);
        self.patchJump(choice_offset);
    }

    // A? : optional.
    fn questionOp(self: *Compiler) void {
        const operand_start = self.last_expr_start;
        self.insertChoicePlaceholder(operand_start);
        const commit_offset = self.emitJump(.op_commit);
        // Patch OP_CHOICE: on failure, skip past OP_COMMIT.
        self.patchJump(operand_start);
        // Patch OP_COMMIT: continue (offset 0 since target is next byte).
        self.patchJump(commit_offset);
    }

    fn emitMatchString(self: *Compiler, narrow: OpCode, wide: OpCode, bytes: []const u8) void {
        const lit = self.obj_pool.copyLiteral(bytes) catch {
            self.errorAtPrevious("Out of memory.");
            return;
        };
        self.currentChunk().emitOpConstant(narrow, wide, .{ .obj = lit.asObj() }, self.parser.previous.line) catch {
            self.errorAtPrevious("Out of memory.");
        };
    }

    fn endCompiler(self: *Compiler) void {
        // If no bare expression was compiled but rules were defined,
        // auto-emit a call to the last rule as the entry point.
        if (!self.had_expression) {
            if (self.last_rule_name) |name| {
                const index = self.compiling_rules.?.getOrCreateIndex(self.alloc, name.lexeme) catch {
                    self.errorAtPrevious("Out of memory.");
                    self.emitHalt();
                    return;
                };
                self.emitRuleCall(index);
            }
        }
        self.emitHalt();
        if (comptime print_code) {
            if (!self.parser.had_error) {
                debug.disassembleChunk(self.currentChunk(), "code");
            }
        }
    }

    fn errorAtCurrent(self: *Compiler, message: []const u8) void {
        self.errorAt(&self.parser.current, message);
    }

    fn errorAtPrevious(self: *Compiler, message: []const u8) void {
        self.errorAt(&self.parser.previous, message);
    }

    fn errorAtPreviousFmt(self: *Compiler, comptime fmt: []const u8, args: anytype) void {
        if (self.parser.panic_mode) return;
        const buf = std.fmt.allocPrint(self.alloc, fmt, args) catch {
            self.errorAt(&self.parser.previous, "Out of memory.");
            return;
        };
        self.owned_error_messages.append(self.alloc, buf) catch {
            self.alloc.free(buf);
            self.errorAt(&self.parser.previous, "Out of memory.");
            return;
        };
        self.errorAt(&self.parser.previous, buf);
    }

    fn errorAt(self: *Compiler, token: *const Token, message: []const u8) void {
        if (self.parser.panic_mode) return;
        self.parser.panic_mode = true;
        self.parser.had_error = true;

        // Scanner errors put the diagnostic text in the lexeme field;
        // surface that to the caller in place of the parser's message.
        const msg = if (token.type == .err) token.lexeme else message;

        self.errors.append(self.alloc, .{
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
    pub fn renderErrors(self: *const Compiler, source: []const u8, writer: *std.Io.Writer) !void {
        for (self.errors.items) |e| {
            try renderOne(source, writer, e);
        }
    }
};

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
    pool: object.ObjPool,
    compiler: Compiler,

    fn deinit(self: *TestCompileResult) void {
        self.chunk.deinit();
        self.rules.deinit(self.alloc);
        self.compiler.deinit();
        self.pool.deinit();
    }
};

fn compileForTest(alloc: std.mem.Allocator, source: []const u8) !TestCompileResult {
    var result: TestCompileResult = .{
        .chunk = Chunk.init(alloc),
        .rules = .{},
        .ok = false,
        .alloc = alloc,
        .pool = object.ObjPool.init(alloc),
        .compiler = Compiler.init(alloc),
    };
    result.ok = result.compiler.compile(source, &result.chunk, &result.rules, &result.pool);
    return result;
}

test "stray token at start flags Expected-an-expression diagnostic" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, ")");
    defer result.deinit();

    try std.testing.expect(!result.ok);
    const errs = result.compiler.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expectEqual(@as(usize, 1), errs[0].line);
    try std.testing.expectEqual(@as(usize, 1), errs[0].column);
    try std.testing.expect(!errs[0].at_eof);
}

test "empty source compiles to just halt" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "");
    defer result.deinit();

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
    const src = "   )";
    var result = try compileForTest(alloc, src);
    defer result.deinit();

    try std.testing.expect(!result.ok);

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try result.compiler.renderErrors(src, &aw.writer);

    const expected =
        "error: Expected an expression: a string, a character literal, '.', '[', '(', or a rule name.\n" ++
        " --> line 1, column 4\n" ++
        "   1 |    )\n" ++
        "     |    ^ Expected an expression: a string, a character literal, '.', '[', '(', or a rule name.\n";
    try std.testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "rule declaration populates rule table" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "digit = ['0'-'9'];");
    defer result.deinit();

    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(usize, 1), result.rules.count());
    try std.testing.expect(result.rules.get("digit") != null);
}

test "multiple rule declarations populate rule table" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(
        alloc,
        "digit = ['0'-'9'];\nalpha = ['a'-'z'];",
    );
    defer result.deinit();

    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(usize, 2), result.rules.count());
    try std.testing.expect(result.rules.get("digit") != null);
    try std.testing.expect(result.rules.get("alpha") != null);
}

test "auto-call emits op_call for last rule in main chunk" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "digit = ['0'-'9'];");
    defer result.deinit();

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
    // First rule has a bad body; second rule is valid.
    var result = try compileForTest(
        alloc,
        "bad = );\ndigit = ['0'-'9'];",
    );
    defer result.deinit();

    try std.testing.expect(!result.ok);
    // Despite the error, the second rule should still be in the table.
    try std.testing.expect(result.rules.get("digit") != null);
}

test "repeated rule calls emit the same index operand" {
    const alloc = std.testing.allocator;
    // The rule body contains three calls to "digit" via sequence.
    var result = try compileForTest(
        alloc,
        "digit = ['0'-'9'];\ntriple = digit digit digit;",
    );
    defer result.deinit();

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
    var result = try compileForTest(alloc, "\"unterminated");
    defer result.deinit();

    try std.testing.expect(!result.ok);
    const errs = result.compiler.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expectEqualStrings("Unterminated string.", errs[0].message);
    try std.testing.expectEqual(@as(usize, 1), errs[0].column);
}

test "use std/abnf populates DIGIT in rule table" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "use \"std/abnf\";");
    defer result.deinit();
    try std.testing.expect(result.ok);
    try std.testing.expect(result.rules.get("DIGIT") != null);
    try std.testing.expect(result.rules.get("ALPHA") != null);
}

test "use unknown module is a compile error" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "use \"std/bogus\";");
    defer result.deinit();
    try std.testing.expect(!result.ok);
}

test "char literal escape \\n compiles successfully" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "'\\n'");
    defer result.deinit();
    try std.testing.expect(result.ok);
    // Main chunk: OP_MATCH_CHAR 0x0A OP_HALT
    try std.testing.expectEqual(@as(usize, 3), result.chunk.code.items.len);
    try std.testing.expectEqual(@intFromEnum(OpCode.op_match_char), result.chunk.code.items[0]);
    try std.testing.expectEqual(@as(u8, '\n'), result.chunk.code.items[1]);
}

test "char literal escape \\r compiles successfully" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "'\\r'");
    defer result.deinit();
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(u8, '\r'), result.chunk.code.items[1]);
}

test "char literal escape \\t compiles successfully" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "'\\t'");
    defer result.deinit();
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(u8, '\t'), result.chunk.code.items[1]);
}

test "char literal hex escape \\x41 compiles to 0x41" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "'\\x41'");
    defer result.deinit();
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(u8, 0x41), result.chunk.code.items[1]);
}

test "char literal hex escape \\x00 compiles to 0x00" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "'\\x00'");
    defer result.deinit();
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(u8, 0x00), result.chunk.code.items[1]);
}

test "charset with hex escaped range compiles successfully" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "['\\x00'-'\\x1F']");
    defer result.deinit();
    try std.testing.expect(result.ok);
}

test "char literal unknown escape is a compile error" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "'\\z'");
    defer result.deinit();
    try std.testing.expect(!result.ok);
}

test "char literal hex escape with bad digit is a compile error" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "'\\xZZ'");
    defer result.deinit();
    try std.testing.expect(!result.ok);
}

test "unused where-binding is reported" {
    const alloc = std.testing.allocator;
    const src =
        "foo = \"x\"\n" ++
        "  where\n" ++
        "    a = \"y\"\n" ++
        "  end\n";
    var result = try compileForTest(alloc, src);
    defer result.deinit();

    try std.testing.expect(!result.ok);
    const errs = result.compiler.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expectEqualStrings(
        "Unused where-binding 'a'.",
        errs[0].message,
    );
    try std.testing.expectEqual(@as(usize, 3), errs[0].line);
    try std.testing.expectEqual(@as(usize, 5), errs[0].column);
}

test "used where-binding is not reported" {
    const alloc = std.testing.allocator;
    const src =
        "foo = a\n" ++
        "  where\n" ++
        "    a = \"y\"\n" ++
        "  end\n";
    var result = try compileForTest(alloc, src);
    defer result.deinit();

    try std.testing.expect(result.ok);
}

test "where-binding only referenced by a typo is flagged as unused" {
    const alloc = std.testing.allocator;
    // 'k' is bound but the body references 'kk', so 'k' goes unused.
    // 'kk' falls through to the global rule table and is fine at
    // compile time, exactly like any other forward-declared rule.
    const src =
        "foo = kk\n" ++
        "  where\n" ++
        "    k = \"x\"\n" ++
        "  end\n";
    var result = try compileForTest(alloc, src);
    defer result.deinit();

    try std.testing.expect(!result.ok);
    const errs = result.compiler.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errs.len);
    try std.testing.expectEqualStrings(
        "Unused where-binding 'k'.",
        errs[0].message,
    );
}

test "multiple unused where-bindings are all reported" {
    const alloc = std.testing.allocator;
    const src =
        "foo = \"x\"\n" ++
        "  where\n" ++
        "    a = \"y\";\n" ++
        "    b = \"z\"\n" ++
        "  end\n";
    var result = try compileForTest(alloc, src);
    defer result.deinit();

    try std.testing.expect(!result.ok);
    const errs = result.compiler.getErrors();
    try std.testing.expectEqual(@as(usize, 2), errs.len);
}

test "duplicate where-binding reports prior declaration location" {
    const alloc = std.testing.allocator;
    const src =
        "foo = a\n" ++
        "  where\n" ++
        "    a = \"x\";\n" ++
        "    a = \"y\"\n" ++
        "  end\n";
    var result = try compileForTest(alloc, src);
    defer result.deinit();

    try std.testing.expect(!result.ok);
    const errs = result.compiler.getErrors();
    try std.testing.expectEqual(@as(usize, 1), errs.len);

    const e = errs[0];
    try std.testing.expectEqual(@as(usize, 4), e.line);
    try std.testing.expectEqual(@as(usize, 5), e.column);
    try std.testing.expectEqualStrings(
        "Duplicate where-binding 'a'. Previous declaration at line 3, column 5.",
        e.message,
    );

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try result.compiler.renderErrors(src, &aw.writer);
    const expected =
        "error: Duplicate where-binding 'a'. Previous declaration at line 3, column 5.\n" ++
        " --> line 4, column 5\n" ++
        "   4 |     a = \"y\"\n" ++
        "     |     ^ Duplicate where-binding 'a'. Previous declaration at line 3, column 5.\n";
    try std.testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "capture emits capture-begin and capture-end opcodes" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "<k: \"x\">");
    defer result.deinit();

    try std.testing.expect(result.ok);
    const code = result.chunk.code.items;
    // op_capture_begin 0, op_match_string X, op_capture_end 0, op_halt
    try std.testing.expectEqual(@intFromEnum(OpCode.op_capture_begin), code[0]);
    try std.testing.expectEqual(@as(u8, 0), code[1]);
    const halt_pos = code.len - 1;
    try std.testing.expectEqual(@intFromEnum(OpCode.op_halt), code[halt_pos]);
    try std.testing.expectEqual(@intFromEnum(OpCode.op_capture_end), code[halt_pos - 2]);
    try std.testing.expectEqual(@as(u8, 0), code[halt_pos - 1]);
}

test "multiple captures get distinct slots" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "<a: \"x\"> <b: \"y\">");
    defer result.deinit();

    try std.testing.expect(result.ok);
    const code = result.chunk.code.items;
    // First capture uses slot 0.
    try std.testing.expectEqual(@intFromEnum(OpCode.op_capture_begin), code[0]);
    try std.testing.expectEqual(@as(u8, 0), code[1]);
    // Find second capture_begin; its slot should be 1.
    var found_second = false;
    for (code[2..], 2..) |byte, i| {
        if (byte == @intFromEnum(OpCode.op_capture_begin) and i > 1) {
            try std.testing.expectEqual(@as(u8, 1), code[i + 1]);
            found_second = true;
            break;
        }
    }
    try std.testing.expect(found_second);
}

test "unreferenced capture is not flagged as unused" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "foo = <k: \"x\">;");
    defer result.deinit();

    try std.testing.expect(result.ok);
}

test "back-reference emits op_match_backref" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "<k: \"x\"> k");
    defer result.deinit();

    try std.testing.expect(result.ok);
    const code = result.chunk.code.items;
    // Find op_match_backref after the capture_end.
    var found = false;
    for (code) |byte| {
        if (byte == @intFromEnum(OpCode.op_match_backref)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "capture allows choice inside brackets" {
    const alloc = std.testing.allocator;
    var result = try compileForTest(alloc, "<s: \"http\" / \"ftp\">");
    defer result.deinit();

    try std.testing.expect(result.ok);
}
