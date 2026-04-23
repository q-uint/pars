const std = @import("std");
const pars_stdlib = @import("pars_stdlib");
const scanner_mod = @import("scanner.zig");
const chunk_mod = @import("../runtime/chunk.zig");
const debug = @import("../runtime/debug.zig");
const object = @import("../runtime/object.zig");
const value_mod = @import("../runtime/value.zig");
const rule_table_mod = @import("../runtime/rule_table.zig");
const compile_error_mod = @import("compile_error.zig");
const literal = @import("literal.zig");
const pratt = @import("pratt.zig");
const peephole = @import("../peephole.zig");
const abnf = @import("../abnf/abnf.zig");
const abnf_lower = @import("../abnf/abnf_lower.zig");
const grammar_analysis = @import("../analysis/grammar.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Value = value_mod.Value;
const Scanner = scanner_mod.Scanner;
const Token = scanner_mod.Token;
const TokenType = scanner_mod.TokenType;

pub const RuleTable = rule_table_mod.RuleTable;
pub const RuleAttrs = rule_table_mod.RuleAttrs;
pub const CompileError = compile_error_mod.CompileError;

// Comptime toggle: disassemble the chunk after a successful compile.
// Off by default so the REPL and scripts produce clean output; flip to
// true when debugging codegen.
const print_code = false;

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
    // Backing buffers for `@abnf"""..."""` blocks: the lowered pars
    // source is fed to a sub-compiler, which inserts rule names that
    // slice into this source. The source must outlive the rule table,
    // so we keep the buffers until the outer compiler deinits.
    owned_abnf_sources: std.ArrayList([]u8) = .empty,
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
    // Snapshot of local_count at the start of the current expression.
    // choiceOp uses it to know which locals were declared by the left
    // arm so they can be dropped before the right arm is compiled,
    // giving each arm of `A / B` its own naming scope without bumping
    // scope_depth.
    last_expr_local_count: usize = 0,
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
    // Nesting depth of the current lookahead context. A cut (`^`) inside
    // `!(...)` or `&(...)` is rejected at compile time because a
    // lookahead promises its body has no effect on the caller's
    // backtracking state, and a cut would leak a commit out of that
    // transparent scope (ADR 008).
    lookahead_depth: u32 = 0,
    // Per-pass peephole switches. Default is "all on"; tests that
    // assert raw bytecode shape construct a Compiler with the
    // relevant pass turned off via `initWithPeephole`.
    peephole_config: peephole.Config = .{},

    pub fn init(alloc: std.mem.Allocator) Compiler {
        return .{ .alloc = alloc };
    }

    pub fn initWithPeephole(alloc: std.mem.Allocator, cfg: peephole.Config) Compiler {
        return .{ .alloc = alloc, .peephole_config = cfg };
    }

    pub fn currentChunk(self: *Compiler) *Chunk {
        return self.compiling_chunk;
    }

    fn beginScope(self: *Compiler) void {
        self.scope_depth += 1;
    }

    fn endScope(self: *Compiler) void {
        self.scope_depth -= 1;
        // Find the count where locals at the new (or shallower) depth
        // start, then drop everything above it. Where-rules live in the
        // rule table, not on the value stack, so no op_pop is emitted --
        // the compiler just forgets them.
        var target = self.local_count;
        while (target > 0 and
            self.locals[target - 1].depth > @as(i32, @intCast(self.scope_depth)))
        {
            target -= 1;
        }
        self.dropLocalsTo(target);
    }

    // Pop locals down to `target`, reporting any that were never used.
    // Used by endScope (depth-driven) and by choiceOp (count-driven, to
    // discard a choice arm's locals between arms without touching
    // scope_depth). Skipped during panic mode to avoid noise on broken
    // input. Captures are exempt from the unused check because their
    // value is recording the span, not being read by a back-reference.
    fn dropLocalsTo(self: *Compiler, target: usize) void {
        while (self.local_count > target) {
            const local = self.locals[self.local_count - 1];
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

    // Mark the local at `idx` as fully initialized by recording its
    // actual scope depth (replacing the -1 sentinel). The caller must
    // pass the slot explicitly because the local just declared is not
    // always the most recent one by the time its body is compiled:
    // a capture body can itself declare a nested capture, which leaves
    // the outer binding below the top of the locals array.
    fn markInitialized(self: *Compiler, idx: usize) void {
        self.locals[idx].depth = @intCast(self.scope_depth);
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
        for (self.owned_abnf_sources.items) |buf| self.alloc.free(buf);
        self.owned_abnf_sources.clearRetainingCapacity();

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

        // Post-emit peephole passes run once the chunk and every rule
        // body are finalized. Skipped when compilation already errored
        // so we don't rewrite half-emitted bytecode.
        if (!self.parser.had_error) {
            self.runPostEmitPeephole(chunk, rule_table) catch {
                self.errorAtPrevious("Out of memory.");
            };
        }

        self.compiling_rules = null;

        return !self.parser.had_error;
    }

    fn runPostEmitPeephole(self: *Compiler, chunk: *Chunk, rule_table: *RuleTable) !void {
        if (self.peephole_config.merge_adjacent_literals) {
            try peephole.post_emit.mergeAdjacentLiterals(chunk, self.obj_pool);
            for (rule_table.chunks.items) |*maybe_chunk| {
                if (maybe_chunk.*) |*rc| {
                    try peephole.post_emit.mergeAdjacentLiterals(rc, self.obj_pool);
                }
            }
        }
    }

    pub fn deinit(self: *Compiler) void {
        self.errors.deinit(self.alloc);
        self.errors = .empty;
        for (self.owned_error_messages.items) |buf| self.alloc.free(buf);
        self.owned_error_messages.deinit(self.alloc);
        self.owned_error_messages = .empty;
        for (self.owned_abnf_sources.items) |buf| self.alloc.free(buf);
        self.owned_abnf_sources.deinit(self.alloc);
        self.owned_abnf_sources = .empty;
    }

    pub fn advance(self: *Compiler) void {
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
        pratt.parsePrecedence(self, .choice);
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

    // Return true when the upcoming `#[ident]` is an expression attribute
    // (currently `#[longest]`) rather than a rule-declaration attribute
    // like `#[lr]`. Called while the current token is still `#`, so the
    // scanner is copied to look ahead without disturbing parser state.
    fn peekIsExpressionAttr(self: *const Compiler) bool {
        var peek = self.scanner;
        // Skip the `[`.
        while (true) {
            const tok = peek.scanToken();
            if (tok.type == .err) continue;
            if (tok.type != .left_bracket) return false;
            break;
        }
        // The attribute name identifier.
        while (true) {
            const tok = peek.scanToken();
            if (tok.type == .err) continue;
            if (tok.type != .identifier) return false;
            return std.mem.eql(u8, tok.lexeme, "longest");
        }
    }

    fn declaration(self: *Compiler) void {
        if (self.check(.kw_use)) {
            self.advance();
            self.useDeclaration();
        } else if (self.check(.tagged_string)) {
            self.advance();
            self.taggedStringDeclaration();
        } else if (self.check(.hash)) {
            // `#[longest](...)` is an expression form that can appear at
            // top level (compiled into the main chunk). Everything else
            // starting with `#[` is a rule-declaration attribute list.
            if (self.peekIsExpressionAttr()) {
                self.statement();
            } else {
                self.ruleDeclarationWithAttrs();
            }
        } else if (self.check(.identifier) and self.peekIsEqual()) {
            self.ruleDeclaration(.{});
        } else {
            self.statement();
        }
        if (self.parser.panic_mode) self.synchronize();
    }

    // Parse a bracketed attribute list (`#[name (, name)*]`) that
    // prefixes a rule declaration, then dispatch into ruleDeclaration
    // with the flags it set. Today only `lr` is recognized (ADR 010);
    // unknown attribute names are compile errors, reserving the syntax
    // for future annotations without silently accepting typos.
    fn ruleDeclarationWithAttrs(self: *Compiler) void {
        self.advance(); // consume '#'
        self.consume(.left_bracket, "Expect '[' after '#' to open attribute list.");
        if (self.parser.had_error) return;

        var attrs: RuleAttrs = .{};

        while (true) {
            self.consume(.identifier, "Expect attribute name in '#[...]'.");
            if (self.parser.had_error) return;
            const name = self.parser.previous;

            if (std.mem.eql(u8, name.lexeme, "lr")) {
                attrs.lr = true;
            } else {
                self.errorAtPreviousFmt(
                    "Unknown attribute '{s}'.",
                    .{name.lexeme},
                );
                return;
            }

            if (!self.match(.comma)) break;
        }

        self.consume(.right_bracket, "Expect ']' to close attribute list.");
        if (self.parser.had_error) return;

        if (!self.check(.identifier) or !self.peekIsEqual()) {
            self.errorAtCurrent("Expect rule declaration after attribute list.");
            return;
        }
        self.ruleDeclaration(attrs);
    }

    // Resolve a "std/..." module path to its embedded source. Returns null
    // if the name is not a known stdlib module.
    fn resolveStdlib(path: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, path, "std/abnf")) return pars_stdlib.abnf;
        if (std.mem.eql(u8, path, "std/abnf_grammar")) return pars_stdlib.abnf_grammar;
        if (std.mem.eql(u8, path, "std/pars_grammar")) return pars_stdlib.pars_grammar;
        return null;
    }

    // Handle on a sub-compilation that merges its rules into the current
    // rule table. Discards the sub's main chunk. Caller inspects `.ok`
    // and `.sub.getErrors()` before calling `deinit`.
    const SubCompile = struct {
        sub: Compiler,
        chunk: Chunk,
        ok: bool,

        fn deinit(self: *SubCompile) void {
            self.sub.deinit();
            self.chunk.deinit();
        }
    };

    fn subCompileIntoSharedRules(self: *Compiler, src: []const u8) SubCompile {
        var sub = Compiler.init(self.alloc);
        var dummy = Chunk.init(self.alloc);
        const ok = sub.compile(src, &dummy, self.compiling_rules.?, self.obj_pool);
        return .{ .sub = sub, .chunk = dummy, .ok = ok };
    }

    // Extract the tag name and body from a `@<tag>"""..."""` lexeme.
    // Caller guarantees the lexeme has this shape (enforced by the
    // scanner). `tag` is a slice into the lexeme; `body` ditto.
    const TaggedStringParts = struct {
        tag: []const u8,
        body: []const u8,
        body_offset_in_token: usize,
    };

    fn splitTaggedString(lex: []const u8) TaggedStringParts {
        // Scanner guarantees: leading '@', identifier, opening `"""`,
        // closing `"""`.
        std.debug.assert(lex.len >= 1 + 3 + 3 and lex[0] == '@');
        std.debug.assert(std.mem.endsWith(u8, lex, "\"\"\""));
        var i: usize = 1;
        while (i < lex.len and lex[i] != '"') : (i += 1) {}
        const tag = lex[1..i];
        std.debug.assert(i + 3 <= lex.len - 3);
        std.debug.assert(std.mem.eql(u8, lex[i .. i + 3], "\"\"\""));
        const body_start = i + 3;
        const body_end = lex.len - 3;
        return .{
            .tag = tag,
            .body = lex[body_start..body_end],
            .body_offset_in_token = body_start,
        };
    }

    // Compile an `@abnf"""..."""` block. The token lives in
    // self.parser.previous; the body is parsed as ABNF, lowered to
    // pars source, and sub-compiled into the shared rule table.
    fn taggedStringDeclaration(self: *Compiler) void {
        // Only reachable from declaration() under compile(), which sets
        // compiling_rules before the parse loop.
        std.debug.assert(self.compiling_rules != null);
        const token = self.parser.previous;
        const parts = splitTaggedString(token.lexeme);
        const body_host_offset: u32 = @intCast(token.start + parts.body_offset_in_token);

        if (!std.mem.eql(u8, parts.tag, "abnf")) {
            self.errorAtPreviousFmt("Unknown tagged-string prefix '@{s}'.", .{parts.tag});
            return;
        }

        // Parse ABNF.
        var parser = abnf.Parser.init(self.alloc, parts.body);
        defer parser.deinit();
        const parsed = parser.parse() catch {
            self.errorAtPrevious("Out of memory parsing ABNF block.");
            return;
        };

        if (!parsed.ok()) {
            for (parsed.errors) |e| {
                self.reportAbnfErrorAtAbnfSpan(body_host_offset, e.span, e.message, "ABNF parse error");
            }
            return;
        }

        // Lower.
        var lowered = abnf_lower.lower(self.alloc, parsed.rulelist) catch {
            self.errorAtPrevious("Out of memory lowering ABNF block.");
            return;
        };
        defer lowered.deinit();

        if (!lowered.ok()) {
            for (lowered.errors) |e| {
                self.reportAbnfErrorAtAbnfSpan(body_host_offset, e.span, e.message, "ABNF lowering error");
            }
            return;
        }

        // Take ownership of the generated source: rule names inserted
        // into the shared rule table by the sub-compiler slice into
        // this buffer, so it must outlive `lowered` (which the arena
        // would otherwise free on scope exit).
        const owned_source = self.alloc.dupe(u8, lowered.source) catch {
            self.errorAtPrevious("Out of memory.");
            return;
        };
        self.owned_abnf_sources.append(self.alloc, owned_source) catch {
            self.alloc.free(owned_source);
            self.errorAtPrevious("Out of memory.");
            return;
        };

        // Every multi-arm ABNF alternation is emitted as
        // `#[longest](...)` by the lowering pass. Demote each such
        // group to ordered choice when FIRST-disjointness proves the
        // semantics match. The rewrite is in place and byte-preserving,
        // so the ABNF span map below stays valid.
        grammar_analysis.demoteLongestInPlace(self.alloc, owned_source) catch {};

        // Sub-compile the generated pars source into the shared rule
        // table. Errors from the sub-compiler use positions in the
        // generated source; the span map translates them back to ABNF
        // spans, and those in turn translate to host-file offsets.
        var sc = self.subCompileIntoSharedRules(owned_source);
        defer sc.deinit();
        if (!sc.ok) {
            for (sc.sub.getErrors()) |e| {
                const abnf_span = lookupAbnfSpan(lowered.spans, @intCast(e.start));
                if (abnf_span) |sp| {
                    self.reportAbnfErrorAtAbnfSpan(body_host_offset, sp, e.message, "ABNF block");
                } else {
                    self.reportAbnfErrorAtToken(token, e.message, "ABNF block");
                }
            }
        }
    }

    // Report an ABNF-block error whose position in the ABNF body is
    // known. Translates the ABNF offset into a host-source offset and
    // computes line/column, so the diagnostic points at the exact byte
    // inside the `@abnf"""..."""` body.
    fn reportAbnfErrorAtAbnfSpan(
        self: *Compiler,
        body_host_offset: u32,
        span: abnf.Span,
        message: []const u8,
        kind: []const u8,
    ) void {
        const host_start = body_host_offset + span.start;
        const lc = computeLineCol(self.compiling_source, host_start);
        self.appendAbnfError(.{
            .line = lc.line,
            .column = lc.column,
            .start = host_start,
            .len = @max(span.len, 1),
            .at_eof = false,
        }, message, kind);
    }

    // Fallback: report at the whole `@abnf` token position.
    fn reportAbnfErrorAtToken(self: *Compiler, token: Token, message: []const u8, kind: []const u8) void {
        self.appendAbnfError(.{
            .line = token.line,
            .column = token.column,
            .start = token.start,
            .len = token.len,
            .at_eof = false,
        }, message, kind);
    }

    const ErrorLocation = struct {
        line: usize,
        column: usize,
        start: usize,
        len: usize,
        at_eof: bool,
    };

    // Append a diagnostic for an `@abnf` block phase directly, without
    // going through errorAt's panic-mode guard. Block-phase errors
    // come from a sub-phase and are semantically independent, so they
    // should all surface rather than be suppressed after the first.
    fn appendAbnfError(self: *Compiler, loc: ErrorLocation, message: []const u8, kind: []const u8) void {
        const buf = std.fmt.allocPrint(self.alloc, "{s}: {s}", .{ kind, message }) catch {
            self.parser.had_error = true;
            return;
        };
        self.owned_error_messages.append(self.alloc, buf) catch {
            self.alloc.free(buf);
            self.parser.had_error = true;
            return;
        };
        self.errors.append(self.alloc, .{
            .line = loc.line,
            .column = loc.column,
            .start = loc.start,
            .len = loc.len,
            .message = buf,
            .at_eof = loc.at_eof,
        }) catch {};
        self.parser.had_error = true;
    }

    // Binary-search the span map for the entry whose generated-source
    // range contains `gen_offset`, and return its ABNF span. Returns
    // null if `gen_offset` precedes the first mapped byte (e.g. in the
    // injected `use "std/abnf";` preamble).
    fn lookupAbnfSpan(spans: []const abnf_lower.SpanMapping, gen_offset: u32) ?abnf.Span {
        var lo: usize = 0;
        var hi: usize = spans.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (spans[mid].gen_offset <= gen_offset) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        return spans[lo - 1].abnf_span;
    }

    // Walk `source` up to `offset` and compute 1-based line and column.
    fn computeLineCol(source: []const u8, offset: usize) struct { line: usize, column: usize } {
        var line: usize = 1;
        var line_start: usize = 0;
        var i: usize = 0;
        const clamped = @min(offset, source.len);
        while (i < clamped) : (i += 1) {
            if (source[i] == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }
        return .{ .line = line, .column = clamped - line_start + 1 };
    }

    // Compile and merge a module's rules into the current rule table.
    // The module's "main" chunk (entry point) is discarded; only the
    // rule declarations it defines are kept.
    fn useDeclaration(self: *Compiler) void {
        self.consume(.string, "Expect a module path string after 'use'.");
        if (self.parser.had_error) return;

        const raw = self.parser.previous.lexeme;
        const path = literal.stripStringDelimiters(raw, 0).body;

        const src = resolveStdlib(path) orelse {
            self.errorAtPrevious("Unknown module. Relative imports are not yet supported.");
            return;
        };

        var sc = self.subCompileIntoSharedRules(src);
        defer sc.deinit();
        if (!sc.ok) self.errorAtPrevious("Module failed to compile.");

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

        // Skip tokens until the current rule's 'where' block, or the
        // rule's terminator. Stopping at ';' matters: without it, a
        // rule that has no where-block causes the scan to run on into
        // the next rule and register its sub-rules as locals of the
        // current scope, which then surface as spurious "unused
        // where-binding" errors at the current rule's endScope.
        while (self.parser.current.type != .kw_where and
            self.parser.current.type != .kw_end and
            self.parser.current.type != .semicolon and
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

    fn ruleDeclaration(self: *Compiler, attrs: RuleAttrs) void {
        self.consume(.identifier, "Expect rule name.");
        const name_token = self.parser.previous;
        self.consume(.equal, "Expect '=' after rule name.");

        const index = self.compiling_rules.?.getOrCreateIndex(self.alloc, name_token.lexeme) catch {
            self.errorAtPrevious("Out of memory.");
            return;
        };
        self.compiling_rules.?.setAttrs(index, attrs);

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

    pub fn namedRule(self: *Compiler) void {
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
    pub fn capture(self: *Compiler) void {
        self.consume(.identifier, "Expect binding name after '<'.");
        const name = self.parser.previous;
        self.consume(.colon, "Expect ':' after capture name.");

        self.declareVariable(name);
        if (self.capture_count >= 255) {
            self.errorAtPrevious("Too many capture bindings in rule.");
            return;
        }
        const slot = self.capture_count;
        // Remember which local slot this capture owns. A nested capture
        // declared while compiling the body will push additional locals,
        // so `self.local_count - 1` no longer points here afterwards.
        const local_idx = self.local_count - 1;
        self.locals[local_idx].is_capture = true;
        self.locals[local_idx].capture_slot = slot;
        self.capture_count += 1;

        self.emitBytes(@intFromEnum(OpCode.op_capture_begin), slot);
        self.expression();
        self.markInitialized(local_idx);
        self.emitBytes(@intFromEnum(OpCode.op_capture_end), slot);
        self.consume(.right_angle, "Expect '>' to close capture.");
    }

    // !A : negative lookahead. Succeeds when A fails to match at the
    // current position; consumes no input either way.
    //
    // Emits:
    //     op_choice L1
    //     <A>
    //     op_fail_twice
    //   L1:
    //
    // If A succeeds, op_fail_twice pops our choice frame and propagates
    // failure to the surrounding context. If A fails, the choice frame
    // restores the pre-A position and transfers control to L1, where
    // execution continues past the lookahead.
    pub fn notLookahead(self: *Compiler) void {
        const choice_offset = self.emitJump(.op_choice_lookahead);
        self.lookahead_depth += 1;
        pratt.parsePrecedence(self, pratt.Precedence.lookahead.next());
        self.lookahead_depth -= 1;
        self.emitByte(@intFromEnum(OpCode.op_fail_twice));
        self.patchJump(choice_offset);
    }

    // &A : positive lookahead. Succeeds when A matches at the current
    // position; consumes no input either way.
    //
    // Emits:
    //     op_choice L1
    //     <A>
    //     op_back_commit L2
    //   L1:
    //     op_fail
    //   L2:
    //
    // If A succeeds, op_back_commit pops the choice frame, restores the
    // saved position (so A is not consumed), and jumps past the failure
    // tail. If A fails, control lands at L1 and op_fail propagates the
    // failure outward.
    pub fn andLookahead(self: *Compiler) void {
        const choice_offset = self.emitJump(.op_choice_lookahead);
        self.lookahead_depth += 1;
        pratt.parsePrecedence(self, pratt.Precedence.lookahead.next());
        self.lookahead_depth -= 1;
        const back_commit_offset = self.emitJump(.op_back_commit);
        self.patchJump(choice_offset);
        self.emitByte(@intFromEnum(OpCode.op_fail));
        self.patchJump(back_commit_offset);
    }

    pub fn grouping(self: *Compiler) void {
        // A parenthesised group introduces a fresh naming scope: bindings
        // declared inside (`<x: ...>`, captures) are not visible outside
        // the group, and a same-named binding inside shadows one outside.
        self.beginScope();
        self.expression();
        self.endScope();
        self.consume(.right_paren, "Expect ')' after expression.");
    }

    // `#[longest](A / B / C)` — try every alternative from the same
    // starting position and commit to the one that consumed the most
    // input. Ties resolve to the earlier arm (since best is updated
    // only on a strictly greater endpoint). If no arm matches, the
    // whole group fails. The `#` token was already consumed by the
    // Pratt prefix dispatch.
    //
    // Layout:
    //   op_longest_begin
    //     op_choice  L1          ; arm fails → jump to next arm
    //       <arm 1>
    //     op_longest_step        ; arm succeeded → record and rewind
    //   L1: op_choice L2
    //       <arm 2>
    //     op_longest_step
    //   L2: ...
    //   op_longest_end           ; advance to best endpoint or fail
    //
    // Each arm is its own naming scope, matching ordered choice: a
    // `<x: ...>` binding in one arm is dropped before the next arm is
    // compiled so names can be reused without collision. The whole
    // group is also its own scope, so bindings inside do not leak.
    pub fn longestPrefix(self: *Compiler) void {
        self.consume(.left_bracket, "Expect '[' after '#'.");
        if (self.parser.had_error) return;

        self.consume(.identifier, "Expect attribute name in '#[...]'.");
        if (self.parser.had_error) return;
        const name = self.parser.previous;
        if (!std.mem.eql(u8, name.lexeme, "longest")) {
            self.errorAtPreviousFmt(
                "Unknown expression attribute '{s}'. Expected 'longest'.",
                .{name.lexeme},
            );
            return;
        }

        self.consume(.right_bracket, "Expect ']' to close attribute list.");
        self.consume(.left_paren, "Expect '(' after '#[longest]'.");
        if (self.parser.had_error) return;

        self.beginScope();
        self.emitByte(@intFromEnum(OpCode.op_longest_begin));

        while (true) {
            const local_count_before_arm = self.local_count;
            const choice_offset = self.emitJump(.op_choice);
            // Parse one alternative. `.sequence` keeps the loop body
            // from swallowing the `/` or `|` that separates arms,
            // leaving it for the outer loop to dispatch.
            pratt.parsePrecedence(self, .sequence);
            if (self.parser.had_error) break;
            self.emitByte(@intFromEnum(OpCode.op_longest_step));
            self.patchJump(choice_offset);
            self.dropLocalsTo(local_count_before_arm);

            if (self.match(.slash) or self.match(.pipe)) continue;
            break;
        }

        self.emitByte(@intFromEnum(OpCode.op_longest_end));
        self.consume(.right_paren, "Expect ')' to close '#[longest](...)'.");
        self.endScope();
    }

    pub fn anyChar(self: *Compiler) void {
        self.emitByte(@intFromEnum(OpCode.op_match_any));
    }

    pub fn charLiteral(self: *Compiler) void {
        const b = self.extractCharByte(self.parser.previous.lexeme) orelse return;
        self.emitBytes(@intFromEnum(OpCode.op_match_char), b);
    }

    pub fn stringLiteral(self: *Compiler) void {
        self.emitStringLiteral(0, .op_match_string, .op_match_string_wide);
    }

    pub fn stringLiteralIgnoreCase(self: *Compiler) void {
        // The 'i' prefix counts as one extra leading byte before the quotes.
        self.emitStringLiteral(1, .op_match_string_i, .op_match_string_i_wide);
    }

    // Resolve a string-literal lexeme to the byte sequence the runtime
    // should match. Single-quoted strings decode escape sequences
    // (`\n`, `\xNN`, etc.); triple-quoted strings are emitted verbatim.
    // Escape errors surface as compile diagnostics; the compiler swallows
    // the instruction so codegen can continue looking for further errors.
    fn emitStringLiteral(self: *Compiler, prefix_len: usize, narrow: OpCode, wide: OpCode) void {
        const stripped = literal.stripStringDelimiters(self.parser.previous.lexeme, prefix_len);
        if (stripped.triple_quoted) {
            self.emitMatchString(narrow, wide, stripped.body);
            return;
        }
        const decoded = literal.decodeStringBody(self.alloc, stripped.body) catch |e| switch (e) {
            error.OutOfMemory => {
                self.errorAtPrevious("Out of memory.");
                return;
            },
            else => |le| {
                self.errorAtPrevious(literal.errorMessage(le));
                return;
            },
        };
        defer self.alloc.free(decoded);
        self.emitMatchString(narrow, wide, decoded);
    }

    /// Compile a charset expression: `[` has already been consumed.
    /// The body is a sequence of single characters ('a') and ranges ('a'-'z').
    /// Each element sets bits in a 256-bit membership vector. The result is
    /// emitted as an op_match_charset referencing an ObjCharset constant.
    pub fn charset(self: *Compiler) void {
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
            self.previousSpan(),
        ) catch {
            self.errorAtPrevious("Out of memory.");
        };
    }

    fn extractCharByte(self: *Compiler, lexeme: []const u8) ?u8 {
        return literal.extractCharByte(lexeme) catch |e| {
            self.errorAtPrevious(literal.errorMessage(e));
            return null;
        };
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

    // The source span of the most recently consumed token. Every byte
    // emitted while this token is `previous` inherits this span, which
    // gives the disassembler and the VM's error reporter a precise
    // click-target back into the source.
    fn previousSpan(self: *Compiler) chunk_mod.SourceSpan {
        const t = self.parser.previous;
        return .{ .start = t.start, .len = t.len, .line = t.line };
    }

    fn emitByte(self: *Compiler, byte: u8) void {
        self.currentChunk().write(byte, self.previousSpan()) catch {
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

    // Insert a choice-family placeholder (3 zero bytes, one of op_choice,
    // op_choice_quant, op_choice_lookahead) at `offset` in the chunk,
    // shifting existing code to the right.
    fn insertChoicePlaceholder(self: *Compiler, offset: usize, op: OpCode) void {
        self.currentChunk().insertBytesAt(offset, 3) catch {
            self.errorAtPrevious("Out of memory.");
            return;
        };
        self.currentChunk().code.items[offset] = @intFromEnum(op);
    }

    // Ordered choice infix: A / B. When called, A is already compiled
    // starting at last_expr_start. We retroactively insert OP_CHOICE
    // before A, emit OP_COMMIT after A, then compile B. Each arm is its
    // own naming scope: locals declared in the left arm are dropped
    // before the right arm is compiled, and the right arm's locals are
    // dropped before falling through to the surrounding context. Done
    // by adjusting local_count rather than scope_depth, since the left
    // arm has already been compiled at the outer scope by the time this
    // infix runs.
    pub fn choiceOp(self: *Compiler) void {
        const left_start = self.last_expr_start;
        const local_count_before_left = self.last_expr_local_count;
        self.insertChoicePlaceholder(left_start, .op_choice);
        const commit_offset = self.emitJump(.op_commit);
        // Patch OP_CHOICE: on failure, jump to start of alternative.
        self.patchJump(left_start);
        // Drop the left arm's locals so the right arm starts fresh and
        // can re-use the same names without colliding.
        self.dropLocalsTo(local_count_before_left);
        // Compile right operand (right-associative: same precedence).
        const local_count_before_right = self.local_count;
        pratt.parsePrecedence(self, .choice);
        self.dropLocalsTo(local_count_before_right);
        // Patch OP_COMMIT: on success, jump past alternative.
        self.patchJump(commit_offset);

        // Emit-time peephole: collapse `A / B` into a single charset
        // when both arms are single-byte matchers. Composes across
        // chained alternatives (A / B / C) because the left-associative
        // parse means each pair fuses before the next pair is built.
        if (self.peephole_config.fuse_charset_choice) {
            _ = peephole.emit_time.fuseCharsetChoice(
                self.currentChunk(),
                self.obj_pool,
                left_start,
                commit_offset,
                self.previousSpan(),
            ) catch {
                self.errorAtPrevious("Out of memory.");
            };
        }
    }

    // A* : zero or more.
    pub fn starOp(self: *Compiler) void {
        const operand_start = self.last_expr_start;
        self.insertChoicePlaceholder(operand_start, .op_choice_quant);
        // OP_COMMIT loops back to the OP_CHOICE.
        self.emitLoop(operand_start);
        // Patch OP_CHOICE: on failure, exit loop.
        self.patchJump(operand_start);
    }

    // A+ : one or more. Compiled as: A (choice-loop of A).
    // The first A must match; subsequent iterations use choice/commit.
    pub fn plusOp(self: *Compiler) void {
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

        // Emit: OP_CHOICE_QUANT <exit> [duplicated A] OP_COMMIT <back>
        const choice_offset = self.emitJump(.op_choice_quant);
        for (buf[0..operand_len]) |byte| {
            self.emitByte(byte);
        }
        self.emitLoop(choice_offset);
        self.patchJump(choice_offset);
    }

    // A? : optional.
    pub fn questionOp(self: *Compiler) void {
        const operand_start = self.last_expr_start;
        self.insertChoicePlaceholder(operand_start, .op_choice_quant);
        const commit_offset = self.emitJump(.op_commit);
        // Patch OP_CHOICE: on failure, skip past OP_COMMIT.
        self.patchJump(operand_start);
        // Patch OP_COMMIT: continue (offset 0 since target is next byte).
        self.patchJump(commit_offset);
    }

    // Upper bound on the operand size (in bytes) for a bounded quantifier.
    // Matches plusOp's copy-buffer size, since the operand is duplicated
    // up to `max` times.
    const bounded_operand_limit: usize = 256;
    // Upper bound on the repetition count. Keeps the emitted bytecode
    // proportionally small (operand_len * count) rather than allowing a
    // grammar author to blow up the chunk with a single `{...}` clause.
    const bounded_count_limit: u32 = 255;

    // A{n}, A{n,m}, A{n,}, A{,m} : bounded repetition.
    //
    // Desugars to existing quantifier opcodes at compile time: `n`
    // required copies of A's bytecode, followed by either (m - n) copies
    // wrapped as A? or, for the unbounded form, an A* tail. No new VM
    // machinery is involved; the operand's bytecode is duplicated
    // verbatim, the same technique plusOp uses.
    pub fn boundedOp(self: *Compiler) void {
        const operand_start = self.last_expr_start;
        const operand_len = self.currentChunk().code.items.len - operand_start;

        // Parse {min}, {min,}, {min,max}, or {,max}.
        var min: u32 = 0;
        var max: u32 = 0;
        var has_min = false;
        var has_max = false;
        var saw_comma = false;

        if (self.check(.number)) {
            self.advance();
            min = std.fmt.parseInt(u32, self.parser.previous.lexeme, 10) catch {
                self.errorAtPrevious("Bound value is out of range.");
                return;
            };
            has_min = true;
        }
        if (self.match(.comma)) {
            saw_comma = true;
            if (self.check(.number)) {
                self.advance();
                max = std.fmt.parseInt(u32, self.parser.previous.lexeme, 10) catch {
                    self.errorAtPrevious("Bound value is out of range.");
                    return;
                };
                has_max = true;
            }
        }
        self.consume(.right_brace, "Expect '}' to close bounded quantifier.");
        if (self.parser.had_error) return;

        if (!has_min and !has_max) {
            self.errorAtPrevious("Bounded quantifier requires at least one bound.");
            return;
        }
        // No comma means the exact form A{n}: the single bound is both min and max.
        const unbounded = saw_comma and !has_max;
        if (!saw_comma) max = min;

        if (!unbounded) {
            if (max == 0) {
                self.errorAtPrevious("Upper bound must be at least 1.");
                return;
            }
            if (min > max) {
                self.errorAtPrevious("Lower bound exceeds upper bound.");
                return;
            }
            if (max > bounded_count_limit) {
                self.errorAtPrevious("Bounded quantifier upper bound is too large.");
                return;
            }
        } else if (min > bounded_count_limit) {
            self.errorAtPrevious("Bounded quantifier lower bound is too large.");
            return;
        }
        if (operand_len > bounded_operand_limit) {
            self.errorAtPrevious("Pattern too large for bounded quantifier.");
            return;
        }

        // Snapshot the operand's bytecode before any mutation, so later
        // array growth can't invalidate a slice into it.
        var buf: [bounded_operand_limit]u8 = undefined;
        @memcpy(buf[0..operand_len], self.currentChunk().code.items[operand_start..][0..operand_len]);

        // When min == 0, the already-emitted operand becomes the first A?.
        // Wrapping it in-place reuses questionOp's shape: insert an
        // op_choice_quant before the operand and an op_commit after it.
        if (min == 0) {
            self.insertChoicePlaceholder(operand_start, .op_choice_quant);
            const commit_offset = self.emitJump(.op_commit);
            self.patchJump(operand_start);
            self.patchJump(commit_offset);
        }

        const required_extras: u32 = if (min == 0) 0 else min - 1;
        var i: u32 = 0;
        while (i < required_extras) : (i += 1) {
            for (buf[0..operand_len]) |byte| self.emitByte(byte);
        }

        if (unbounded) {
            // Append A*: choice_quant + A + loop, same shape as starOp
            // but with a fresh copy of the operand's bytecode.
            const choice_offset = self.emitJump(.op_choice_quant);
            for (buf[0..operand_len]) |byte| self.emitByte(byte);
            self.emitLoop(choice_offset);
            self.patchJump(choice_offset);
        } else {
            const optional_extras: u32 = if (min == 0) max - 1 else max - min;
            var j: u32 = 0;
            while (j < optional_extras) : (j += 1) {
                const choice_offset = self.emitJump(.op_choice_quant);
                for (buf[0..operand_len]) |byte| self.emitByte(byte);
                const commit_offset = self.emitJump(.op_commit);
                self.patchJump(choice_offset);
                self.patchJump(commit_offset);
            }
        }
    }

    fn emitMatchString(self: *Compiler, narrow: OpCode, wide: OpCode, bytes: []const u8) void {
        const lit = self.obj_pool.copyLiteral(bytes) catch {
            self.errorAtPrevious("Out of memory.");
            return;
        };
        self.currentChunk().emitOpConstant(narrow, wide, .{ .obj = lit.asObj() }, self.previousSpan()) catch {
            self.errorAtPrevious("Out of memory.");
        };
    }

    // `^` (bare) or `^"label"` (labelled): cut. Commits the innermost
    // enclosing ordered choice in the current rule so later failures
    // cannot backtrack into another alternative (ADR 008). A labelled
    // cut also records the label; any failure after the cut propagates
    // as a runtime error with that label rather than silently backing
    // out to the caller. Cuts inside a lookahead are rejected here so
    // the transparency of `!(...)` / `&(...)` is preserved.
    //
    // The label, if present, must be written adjacent to the `^` with
    // no whitespace: `^"msg"`. A string after a space (`^ "B"`) is a
    // following sequence primary, not a label. Without this rule the
    // syntax would be ambiguous, since strings are also ordinary
    // pattern primaries.
    pub fn cut(self: *Compiler) void {
        if (self.lookahead_depth > 0) {
            self.errorAtPrevious("Cut is not allowed inside a lookahead.");
            return;
        }
        const caret = self.parser.previous;
        const adjacent_label = self.check(.string) and
            self.parser.current.start == caret.start + caret.len;
        if (!adjacent_label) {
            self.emitByte(@intFromEnum(OpCode.op_cut));
            return;
        }
        self.advance();
        const bytes = literal.stripStringDelimiters(self.parser.previous.lexeme, 0).body;
        const lit = self.obj_pool.copyLiteral(bytes) catch {
            self.errorAtPrevious("Out of memory.");
            return;
        };
        self.currentChunk().emitOpConstant(
            .op_cut_label,
            .op_cut_label_wide,
            .{ .obj = lit.asObj() },
            self.previousSpan(),
        ) catch {
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

    pub fn errorAtPrevious(self: *Compiler, message: []const u8) void {
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
        try compile_error_mod.renderAll(self.errors.items, source, writer);
    }
};
