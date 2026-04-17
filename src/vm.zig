const std = @import("std");
const builtin = @import("builtin");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const printValue = value_mod.printValue;
const debug = @import("debug.zig");
const compiler_mod = @import("compiler.zig");
const object = @import("object.zig");
const RuleTable = compiler_mod.RuleTable;
const Compiler = compiler_mod.Compiler;

// Comptime toggle: per-instruction disassembly during run(). Off by
// default so the REPL and scripts produce clean output; flip to true
// when debugging the dispatch loop.
const trace_execution = false;

const CallFrame = struct {
    // Caller's chunk and ip, restored on OP_RETURN so execution
    // resumes at the instruction after the OP_CALL.
    chunk: *Chunk,
    ip: usize,
    // Callee's chunk: the rule actually active in this frame. Kept
    // separate from `chunk` so left-recursion detection can compare
    // against the rule being executed, not the rule that made the
    // call. Comparing against the caller falsely flags right-
    // recursion through shared dispatch rules (e.g. primary → capture
    // → expr → primary, where the inner primary's call to capture
    // would match the outer capture's own outgoing call).
    callee: *Chunk,
    // Input position at which the callee was entered. Used to detect
    // left recursion: if the same rule is already active at the same
    // position, no input can ever be consumed and the parse would
    // loop forever.
    entry_pos: usize,
};

const max_frames = 64;

const BacktrackFrame = struct {
    ip: usize,
    pos: usize,
    chunk: *Chunk,
    frame_count: usize,
};

const max_bt = 256;

pub const InterpretResult = enum {
    ok,
    no_match,
    compile_error,
    runtime_error,
};

// Optional comptime stack size: fixed array when set, dynamic when null.
pub fn Vm(comptime stack_size: ?comptime_int) type {
    const Stack = if (stack_size) |s| FixedStack(s) else DynamicStack;

    return struct {
        const Self = @This();

        chunk: ?*Chunk,
        // Instruction pointer: index of the next instruction to execute.
        ip: usize,
        // Input being matched and the current cursor into it. A successful
        // primary advances `pos`; a failure leaves `pos` unchanged and (in
        // the future) unwinds to a saved backtrack frame on `stack`.
        input: []const u8,
        pos: usize,
        // Dormant until backtrack frames land. Per ADR 006, successful
        // matches leave nothing here; the stack will hold saved (ip, pos)
        // pairs pushed by a future op_choice and popped by op_commit/fail.
        stack: Stack,
        // Rule table: maps rule names to their compiled chunks. Populated
        // by the compiler during rule declarations and persists across
        // REPL iterations so rules defined on one line can be called later.
        rules: RuleTable,
        // Call stack for rule-to-rule invocation. Each frame saves the
        // caller's chunk and ip so op_return can restore them.
        frames: [max_frames]CallFrame,
        frame_count: usize,
        // Backtrack stack for ordered choice and quantifiers. Each
        // frame saves enough state to restore the VM to the point
        // before a speculative match attempt.
        bt_stack: [max_bt]BacktrackFrame,
        bt_top: usize,
        // Capture slots for let-bindings. capture_starts holds the
        // input position saved by op_capture_begin; captures holds the
        // completed Span after op_capture_end.
        capture_starts: [256]usize,
        captures: [256]value_mod.Span,
        allocator: std.mem.Allocator,
        obj_pool: object.ObjPool,
        compiler: Compiler,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .chunk = null,
                .ip = 0,
                .input = "",
                .pos = 0,
                .stack = Stack.init(allocator),
                .rules = .{},
                .frames = undefined,
                .frame_count = 0,
                .bt_stack = undefined,
                .bt_top = 0,
                .capture_starts = undefined,
                .captures = undefined,
                .allocator = allocator,
                .obj_pool = object.ObjPool.init(allocator),
                .compiler = Compiler.init(allocator),
            };
        }

        pub fn push(self: *Self, val: Value) !void {
            try self.stack.push(val);
        }

        pub fn pop(self: *Self) Value {
            return self.stack.pop();
        }

        pub fn stackSlice(self: *Self) []const Value {
            return self.stack.slice();
        }

        pub fn interpret(self: *Self, source: []const u8) InterpretResult {
            return self.match(source, "");
        }

        // Returns true when `source` appears syntactically incomplete:
        // all compile errors land at EOF, which means the input was cut
        // off in the middle of a statement rather than being malformed.
        // Uses a throwaway rule table so the real VM state is not touched.
        pub fn isIncomplete(self: *Self, source: []const u8) bool {
            var chunk = Chunk.init(self.allocator);
            defer chunk.deinit();
            var rules: RuleTable = .{};
            defer rules.deinit(self.allocator);
            var probe = Compiler.init(self.allocator);
            defer probe.deinit();
            const ok = probe.compile(source, &chunk, &rules, &self.obj_pool);
            if (ok) return false;
            for (probe.getErrors()) |e| {
                if (!e.at_eof) return false;
            }
            return true;
        }

        pub fn match(
            self: *Self,
            source: []const u8,
            input: []const u8,
        ) InterpretResult {
            var c = Chunk.init(self.allocator);
            defer c.deinit();

            if (!self.compiler.compile(source, &c, &self.rules, &self.obj_pool)) {
                self.renderCompileErrorsToStderr(source);
                return .compile_error;
            }

            self.chunk = &c;
            self.ip = 0;
            self.input = input;
            self.pos = 0;
            self.frame_count = 0;
            self.bt_top = 0;
            return self.run();
        }

        // Dispatch loop. Faster VMs use direct threaded code, jump tables,
        // or computed goto to avoid the switch overhead. Zig has no goto,
        // but the compiler can lower a dense enum switch to a jump table
        // automatically, so a plain switch is both idiomatic and efficient.
        pub fn run(self: *Self) InterpretResult {
            while (true) {
                if (comptime trace_execution) {
                    const s = self.stackSlice();
                    if (s.len > 0) {
                        std.debug.print("          ", .{});
                        for (s) |slot| {
                            std.debug.print("[ ", .{});
                            printValue(slot);
                            std.debug.print(" ]", .{});
                        }
                        std.debug.print("\n", .{});
                    }
                    _ = debug.disassembleInstruction(self.chunk.?, self.ip);
                }

                const instruction = self.readByte();
                const op = std.enums.fromInt(OpCode, instruction) orelse {
                    self.runtimeError("unknown opcode {d}", .{instruction});
                    return .runtime_error;
                };
                switch (op) {
                    .op_match_char => {
                        const byte = self.readByte();
                        if (self.pos >= self.input.len or self.input[self.pos] != byte) {
                            if (self.fail() == .no_match) return .no_match;
                        } else {
                            self.pos += 1;
                        }
                    },
                    .op_match_any => {
                        if (self.pos >= self.input.len) {
                            if (self.fail() == .no_match) return .no_match;
                        } else {
                            self.pos += 1;
                        }
                    },
                    .op_match_string => {
                        const literal = self.readConstantLiteral();
                        if (!self.consumePrefix(literal)) {
                            if (self.fail() == .no_match) return .no_match;
                        }
                    },
                    .op_match_string_wide => {
                        const literal = self.readConstantWideLiteral();
                        if (!self.consumePrefix(literal)) {
                            if (self.fail() == .no_match) return .no_match;
                        }
                    },
                    .op_match_string_i => {
                        const literal = self.readConstantLiteral();
                        if (!self.consumePrefixIgnoreCase(literal)) {
                            if (self.fail() == .no_match) return .no_match;
                        }
                    },
                    .op_match_string_i_wide => {
                        const literal = self.readConstantWideLiteral();
                        if (!self.consumePrefixIgnoreCase(literal)) {
                            if (self.fail() == .no_match) return .no_match;
                        }
                    },
                    .op_match_charset => {
                        const cs = self.readConstantCharset();
                        if (!self.consumeCharset(cs)) {
                            if (self.fail() == .no_match) return .no_match;
                        }
                    },
                    .op_match_charset_wide => {
                        const cs = self.readConstantWideCharset();
                        if (!self.consumeCharset(cs)) {
                            if (self.fail() == .no_match) return .no_match;
                        }
                    },
                    .op_call => {
                        if (!self.callRule(self.readByte())) return .runtime_error;
                    },
                    .op_call_wide => {
                        if (!self.callRule(self.readWideIndex())) return .runtime_error;
                    },
                    .op_return => {
                        if (self.frame_count == 0) {
                            self.runtimeError("op_return with empty call stack", .{});
                            return .runtime_error;
                        }
                        self.frame_count -= 1;
                        const frame = self.frames[self.frame_count];
                        self.chunk = frame.chunk;
                        self.ip = frame.ip;
                    },
                    .op_choice => {
                        const offset = self.readJumpOffset();
                        if (self.bt_top >= max_bt) {
                            self.runtimeError("Backtrack stack overflow.", .{});
                            return .runtime_error;
                        }
                        self.bt_stack[self.bt_top] = .{
                            .ip = @intCast(@as(isize, @intCast(self.ip)) + offset),
                            .pos = self.pos,
                            .chunk = self.chunk.?,
                            .frame_count = self.frame_count,
                        };
                        self.bt_top += 1;
                    },
                    .op_commit => {
                        const offset = self.readJumpOffset();
                        if (self.bt_top == 0) {
                            self.runtimeError("op_commit with empty backtrack stack", .{});
                            return .runtime_error;
                        }
                        self.bt_top -= 1;
                        self.ip = @intCast(@as(isize, @intCast(self.ip)) + offset);
                    },
                    .op_fail => {
                        if (self.fail() == .no_match) return .no_match;
                    },
                    .op_capture_begin => {
                        const slot = self.readByte();
                        self.capture_starts[slot] = self.pos;
                    },
                    .op_capture_end => {
                        const slot = self.readByte();
                        const start = self.capture_starts[slot];
                        self.captures[slot] = .{ .start = start, .len = self.pos - start };
                    },
                    .op_match_backref => {
                        const slot = self.readByte();
                        const span = self.captures[slot];
                        const text = self.input[span.start..][0..span.len];
                        if (!self.consumePrefix(text)) {
                            if (self.fail() == .no_match) return .no_match;
                        }
                    },
                    .op_fail_twice => {
                        if (self.bt_top == 0) {
                            self.runtimeError("op_fail_twice with empty backtrack stack", .{});
                            return .runtime_error;
                        }
                        self.bt_top -= 1;
                        if (self.fail() == .no_match) return .no_match;
                    },
                    .op_back_commit => {
                        const offset = self.readJumpOffset();
                        if (self.bt_top == 0) {
                            self.runtimeError("op_back_commit with empty backtrack stack", .{});
                            return .runtime_error;
                        }
                        self.bt_top -= 1;
                        const frame = self.bt_stack[self.bt_top];
                        self.pos = frame.pos;
                        self.ip = @intCast(@as(isize, @intCast(self.ip)) + offset);
                    },
                    .op_halt => return .ok,
                }
            }
        }

        const FailResult = enum { backtracked, no_match };

        fn fail(self: *Self) FailResult {
            if (self.bt_top > 0) {
                self.bt_top -= 1;
                const frame = self.bt_stack[self.bt_top];
                self.pos = frame.pos;
                self.ip = frame.ip;
                self.chunk = frame.chunk;
                self.frame_count = frame.frame_count;
                return .backtracked;
            }
            return .no_match;
        }

        fn readJumpOffset(self: *Self) i16 {
            const lo = self.readByte();
            const hi = self.readByte();
            return @bitCast(@as(u16, lo) | (@as(u16, hi) << 8));
        }

        fn callRule(self: *Self, index: u32) bool {
            const rule_chunk = self.rules.getChunkPtr(index) orelse {
                const name = if (index < self.rules.names.items.len)
                    self.rules.names.items[index]
                else
                    "(unknown)";
                self.runtimeError("Undefined rule '{s}'.", .{name});
                return false;
            };
            // Detect left recursion: if the target rule is already
            // active at the same input position, no input can ever
            // be consumed and the parse would loop forever. Compare
            // against each frame's callee (the rule it is executing),
            // not its caller chunk.
            for (self.frames[0..self.frame_count]) |f| {
                if (f.callee == rule_chunk and f.entry_pos == self.pos) {
                    const name = if (index < self.rules.names.items.len)
                        self.rules.names.items[index]
                    else
                        "(unknown)";
                    self.runtimeError(
                        "Left recursion detected in rule '{s}'.",
                        .{name},
                    );
                    return false;
                }
            }
            if (self.frame_count >= max_frames) {
                self.runtimeError("Call stack overflow.", .{});
                return false;
            }
            self.frames[self.frame_count] = .{
                .chunk = self.chunk.?,
                .callee = rule_chunk,
                .ip = self.ip,
                .entry_pos = self.pos,
            };
            self.frame_count += 1;
            self.chunk = rule_chunk;
            self.ip = 0;
            return true;
        }

        fn readWideIndex(self: *Self) u32 {
            const lo = self.readByte();
            const mid = self.readByte();
            const hi = self.readByte();
            return @as(u32, lo) | (@as(u32, mid) << 8) | (@as(u32, hi) << 16);
        }

        fn consumePrefix(self: *Self, literal: []const u8) bool {
            if (self.input.len - self.pos < literal.len) return false;
            if (!std.mem.eql(u8, self.input[self.pos..][0..literal.len], literal)) {
                return false;
            }
            self.pos += literal.len;
            return true;
        }

        fn consumePrefixIgnoreCase(self: *Self, literal: []const u8) bool {
            if (self.input.len - self.pos < literal.len) return false;
            const slice = self.input[self.pos..][0..literal.len];
            for (literal, slice) |l, r| {
                if (asciiToLower(l) != asciiToLower(r)) return false;
            }
            self.pos += literal.len;
            return true;
        }

        fn consumeCharset(self: *Self, cs: *const object.ObjCharset) bool {
            if (self.pos >= self.input.len) return false;
            if (!cs.contains(self.input[self.pos])) return false;
            self.pos += 1;
            return true;
        }

        fn readByte(self: *Self) u8 {
            const byte = self.chunk.?.code.items[self.ip];
            self.ip += 1;
            return byte;
        }

        fn readConstant(self: *Self) Value {
            return self.chunk.?.constants.items[self.readByte()];
        }

        fn readConstantWide(self: *Self) Value {
            const index: usize = @as(usize, self.readByte()) |
                (@as(usize, self.readByte()) << 8) |
                (@as(usize, self.readByte()) << 16);
            return self.chunk.?.constants.items[index];
        }

        fn readConstantLiteral(self: *Self) []const u8 {
            return self.readConstant().asObj().asLiteral().chars();
        }

        fn readConstantWideLiteral(self: *Self) []const u8 {
            return self.readConstantWide().asObj().asLiteral().chars();
        }

        fn readConstantCharset(self: *Self) *const object.ObjCharset {
            return self.readConstant().asObj().asCharset();
        }

        fn readConstantWideCharset(self: *Self) *const object.ObjCharset {
            return self.readConstantWide().asObj().asCharset();
        }

        fn runtimeError(self: *Self, comptime fmt: []const u8, args: anytype) void {
            if (builtin.is_test) return;
            std.debug.print(fmt, args);
            std.debug.print("\n", .{});

            // ip points past the offending instruction, so subtract 1.
            const line = self.chunk.?.getLine(self.ip - 1);
            std.debug.print("[line {d}] in script\n", .{line});
        }

        fn renderCompileErrorsToStderr(self: *Self, source: []const u8) void {
            if (builtin.is_test) return;
            var aw = std.Io.Writer.Allocating.init(self.allocator);
            defer aw.deinit();
            self.compiler.renderErrors(source, &aw.writer) catch return;
            std.debug.print("{s}", .{aw.writer.buffered()});
        }

        pub fn deinit(self: *Self) void {
            self.stack.deinit();
            self.rules.deinit(self.allocator);
            self.compiler.deinit();
            self.obj_pool.deinit();
        }
    };
}

fn asciiToLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

// Fixed-size stack backed by an array. Fast and cache-friendly, but
// will panic on overflow if the program exceeds the limit.
fn FixedStack(comptime size: comptime_int) type {
    return struct {
        const Self = @This();

        buf: [size]Value,
        top: usize,

        fn init(_: std.mem.Allocator) Self {
            return .{ .buf = undefined, .top = 0 };
        }

        fn push(self: *Self, val: Value) !void {
            if (self.top >= size) return error.StackOverflow;
            self.buf[self.top] = val;
            self.top += 1;
        }

        fn pop(self: *Self) Value {
            self.top -= 1;
            return self.buf[self.top];
        }

        fn slice(self: *Self) []const Value {
            return self.buf[0..self.top];
        }

        fn deinit(_: *Self) void {}
    };
}

// Dynamic stack backed by an ArrayList. Grows as needed so it never
// overflows, at the cost of heap allocation and possible realloc on
// push. Cache locality may be worse than a fixed array since the
// backing memory is heap-allocated and can move on resize.
const DynamicStack = struct {
    items: std.ArrayList(Value),

    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) DynamicStack {
        return .{ .items = .empty, .allocator = allocator };
    }

    fn push(self: *DynamicStack, val: Value) !void {
        try self.items.append(self.allocator, val);
    }

    fn pop(self: *DynamicStack) Value {
        return self.items.pop().?;
    }

    fn slice(self: *DynamicStack) []const Value {
        return self.items.items;
    }

    fn deinit(self: *DynamicStack) void {
        self.items.deinit(self.allocator);
    }
};

fn haltChunk(alloc: std.mem.Allocator) !Chunk {
    var c = Chunk.init(alloc);
    try c.write(@intFromEnum(OpCode.op_halt), 1);
    return c;
}

test "dynamic vm: halt returns ok" {
    const alloc = std.testing.allocator;
    var c = try haltChunk(alloc);
    defer c.deinit();
    var machine = Vm(null).init(alloc);
    defer machine.deinit();
    machine.chunk = &c;
    try std.testing.expectEqual(.ok, machine.run());
}

test "fixed vm: halt returns ok" {
    const alloc = std.testing.allocator;
    var c = try haltChunk(alloc);
    defer c.deinit();
    var machine = Vm(256).init(alloc);
    defer machine.deinit();
    machine.chunk = &c;
    try std.testing.expectEqual(.ok, machine.run());
}

const VmTest = Vm(null);

fn expectMatch(source: []const u8, input: []const u8, expected: InterpretResult) !void {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    try std.testing.expectEqual(expected, machine.match(source, input));
}

test "string literal matches input prefix" {
    try expectMatch("\"GET\"", "GET /", .ok);
}

test "string literal rejects non-matching input" {
    try expectMatch("\"GET\"", "POST /", .no_match);
}

test "string literal rejects input shorter than literal" {
    try expectMatch("\"GET\"", "GE", .no_match);
}

test "sequence of literals matches concatenation" {
    try expectMatch("\"GET\" \" \" \"/\"", "GET /", .ok);
}

test "sequence fails if any primary fails" {
    try expectMatch("\"GET\" \" \" \"/\"", "GET:/", .no_match);
}

test "character literal matches single byte" {
    try expectMatch("'a'", "abc", .ok);
}

test "character literal rejects wrong byte" {
    try expectMatch("'a'", "xbc", .no_match);
}

test "dot matches any single byte" {
    try expectMatch(".", "x", .ok);
}

test "dot fails on empty input" {
    try expectMatch(".", "", .no_match);
}

test "case-insensitive string matches regardless of case" {
    try expectMatch("i\"http\"", "HTTP/1.1", .ok);
    try expectMatch("i\"http\"", "http/1.1", .ok);
    try expectMatch("i\"http\"", "HtTp/1.1", .ok);
}

test "case-insensitive string rejects non-letters that differ" {
    try expectMatch("i\"a-b\"", "a_b", .no_match);
}

test "grouping compiles to the same code as the inner expression" {
    try expectMatch("(\"GET\")", "GET", .ok);
    try expectMatch("(\"GET\" \" \") \"/\"", "GET /", .ok);
}

test "charset matches a single character in range" {
    try expectMatch("['a'-'z']", "m", .ok);
}

test "charset rejects character outside range" {
    try expectMatch("['a'-'z']", "M", .no_match);
}

test "charset matches boundary characters" {
    try expectMatch("['a'-'z']", "a", .ok);
    try expectMatch("['a'-'z']", "z", .ok);
}

test "charset with multiple ranges" {
    try expectMatch("['a'-'z' '0'-'9']", "m", .ok);
    try expectMatch("['a'-'z' '0'-'9']", "5", .ok);
    try expectMatch("['a'-'z' '0'-'9']", "!", .no_match);
}

test "charset with single characters" {
    try expectMatch("['_']", "_", .ok);
    try expectMatch("['_']", "a", .no_match);
}

test "charset mixed ranges and singles" {
    try expectMatch("['a'-'z' '_' '0'-'9']", "_", .ok);
    try expectMatch("['a'-'z' '_' '0'-'9']", "x", .ok);
    try expectMatch("['a'-'z' '_' '0'-'9']", "7", .ok);
    try expectMatch("['a'-'z' '_' '0'-'9']", "!", .no_match);
}

test "charset fails on empty input" {
    try expectMatch("['a'-'z']", "", .no_match);
}

test "charset in sequence" {
    try expectMatch("['a'-'z'] ['0'-'9']", "a1", .ok);
    try expectMatch("['a'-'z'] ['0'-'9']", "1a", .no_match);
}

test "single rule declaration matches via auto-call" {
    try expectMatch("digit = ['0'-'9'];", "5", .ok);
}

test "single rule declaration rejects non-matching input" {
    try expectMatch("digit = ['0'-'9'];", "x", .no_match);
}

test "rule calling another rule" {
    try expectMatch("digit = ['0'-'9'];\ntwo_digits = digit digit;", "42", .ok);
}

test "rule calling another rule fails on short input" {
    try expectMatch("digit = ['0'-'9'];\ntwo_digits = digit digit;", "4", .no_match);
}

test "forward rule reference" {
    try expectMatch("pair = digit digit;\ndigit = ['0'-'9'];", "42", .ok);
}

test "undefined rule produces runtime error" {
    try expectMatch("bogus", "x", .runtime_error);
}

test "rule with sequence body" {
    try expectMatch(
        "http_ver = \"HTTP/\" ['0'-'9'] '.' ['0'-'9'];",
        "HTTP/1.1",
        .ok,
    );
}

test "empty program matches nothing" {
    try expectMatch("", "", .ok);
}

// -- Choice tests --

test "choice picks first matching alternative" {
    try expectMatch("\"GET\" / \"POST\"", "GET /", .ok);
}

test "choice falls back to second alternative" {
    try expectMatch("\"GET\" / \"POST\"", "POST /", .ok);
}

test "choice fails if no alternative matches" {
    try expectMatch("\"GET\" / \"POST\"", "DELETE /", .no_match);
}

test "choice restores position on backtrack" {
    // "GE" matches the first 2 bytes of "GET" but the full literal
    // "GEX" fails, so the parser must backtrack to pos 0 for "GET".
    try expectMatch("\"GEX\" / \"GET\"", "GET", .ok);
}

test "three-way choice" {
    try expectMatch("\"a\" / \"b\" / \"c\"", "a", .ok);
    try expectMatch("\"a\" / \"b\" / \"c\"", "b", .ok);
    try expectMatch("\"a\" / \"b\" / \"c\"", "c", .ok);
    try expectMatch("\"a\" / \"b\" / \"c\"", "d", .no_match);
}

test "choice with sequence: choice binds looser than sequence" {
    // "ab" / "cd" means ("ab") / ("cd"), not "a" ("b" / "c") "d"
    try expectMatch("'a' 'b' / 'c' 'd'", "ab", .ok);
    try expectMatch("'a' 'b' / 'c' 'd'", "cd", .ok);
    try expectMatch("'a' 'b' / 'c' 'd'", "ad", .no_match);
}

test "pipe is synonym for slash" {
    try expectMatch("\"GET\" | \"POST\"", "POST", .ok);
}

test "choice in rules" {
    try expectMatch(
        "method = \"GET\" / \"POST\" / \"PUT\";\nreq = method \" /\";",
        "PUT /",
        .ok,
    );
}

// -- Quantifier tests --

test "star matches zero occurrences" {
    try expectMatch("'a'*", "", .ok);
}

test "star matches multiple occurrences" {
    try expectMatch("'a'*", "aaaa", .ok);
}

test "star stops at non-matching byte" {
    try expectMatch("'a'* 'b'", "aaab", .ok);
}

test "plus requires at least one match" {
    try expectMatch("'a'+", "", .no_match);
}

test "plus matches one occurrence" {
    try expectMatch("'a'+", "a", .ok);
}

test "plus matches many occurrences" {
    try expectMatch("'a'+", "aaaa", .ok);
}

test "plus followed by literal" {
    try expectMatch("['0'-'9']+ '.'", "123.", .ok);
}

test "question matches zero occurrences" {
    try expectMatch("'a'? 'b'", "b", .ok);
}

test "question matches one occurrence" {
    try expectMatch("'a'? 'b'", "ab", .ok);
}

test "quantifier with charset" {
    try expectMatch("['a'-'z']+", "hello", .ok);
    try expectMatch("['a'-'z']+", "HELLO", .no_match);
}

test "quantifier in rule" {
    try expectMatch("digit = ['0'-'9'];\nnumber = digit+;", "42", .ok);
}

test "combined: choice and quantifiers" {
    try expectMatch(
        "alpha = ['a'-'z' 'A'-'Z'];\n" ++
            "digit = ['0'-'9'];\n" ++
            "ident = alpha (alpha / digit)*;",
        "foo123",
        .ok,
    );
}

test "combined: optional and sequence" {
    try expectMatch(
        "digit = ['0'-'9'];\n" ++
            "sign = '+' / '-';\n" ++
            "integer = sign? digit+;",
        "-42",
        .ok,
    );
}

test "combined: optional sign with unsigned" {
    try expectMatch(
        "digit = ['0'-'9'];\n" ++
            "sign = '+' / '-';\n" ++
            "integer = sign? digit+;",
        "42",
        .ok,
    );
}

test "left-recursive rule produces left-recursion error" {
    try expectMatch(
        "expr = expr \"+\" expr / ['0'-'9'];",
        "1+2",
        .runtime_error,
    );
}

test "mutual right-recursion through a dispatch rule is not flagged" {
    // A dispatches to B; B consumes a byte before calling A again.
    // No position is ever revisited by the same rule, so this must
    // parse cleanly rather than tripping left-recursion detection.
    try expectMatch(
        "A = B; B = 'x' A / 'y';",
        "xxy",
        .ok,
    );
}

test "where clause: sub-rule used in body" {
    try expectMatch(
        "x = y where y = \"y\" end;",
        "y",
        .ok,
    );
}

test "where clause: trailing semicolon on last sub-rule is optional" {
    try expectMatch(
        "x = y where y = \"y\"; end;",
        "y",
        .ok,
    );
}

test "where clause: multiple sub-rules" {
    try expectMatch(
        "kv = k \":\" v where k = ['a'-'z']+; v = ['0'-'9']+ end;",
        "abc:123",
        .ok,
    );
}

test "where clause: sub-rule references another sub-rule" {
    try expectMatch(
        "pair = a a where a = ['a'-'z'] end;",
        "xy",
        .ok,
    );
}

test "where clause: no semicolon after end is valid" {
    try expectMatch(
        "x = y where y = \"y\" end",
        "y",
        .ok,
    );
}

test "where clause: body not matched when sub-rule fails" {
    try expectMatch(
        "x = y where y = \"y\" end;",
        "z",
        .no_match,
    );
}

test "where clause: prior plain rule does not leak into scan" {
    // The pre-scan for where-bindings must stop at the current rule's
    // terminating ';'. Otherwise a trailing rule's where-block is
    // registered as locals of the preceding rule and surfaces as a
    // spurious "unused where-binding" error.
    try expectMatch(
        "a = \"a\"; x = y where y = \"y\" end;",
        "y",
        .ok,
    );
}

test "rules persist across REPL iterations" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();

    // First iteration: define a rule.
    const r1 = machine.match("digit = ['0'-'9'];", "5");
    try std.testing.expectEqual(.ok, r1);

    // Second iteration: call the rule by name.
    const r2 = machine.match("digit", "7");
    try std.testing.expectEqual(.ok, r2);

    // Third iteration: rule still available.
    const r3 = machine.match("digit digit", "42");
    try std.testing.expectEqual(.ok, r3);
}

test "capture records matched span" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match("<k: ['a'-'z']+>", "hello123");
    try std.testing.expectEqual(.ok, result);
    try std.testing.expectEqual(@as(usize, 0), machine.captures[0].start);
    try std.testing.expectEqual(@as(usize, 5), machine.captures[0].len);
}

test "captures in sequence get distinct slots" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match(
        "<k: ['a'-'z']+> \":\" <v: ['0'-'9']+>",
        "abc:123",
    );
    try std.testing.expectEqual(.ok, result);
    try std.testing.expectEqual(@as(usize, 0), machine.captures[0].start);
    try std.testing.expectEqual(@as(usize, 3), machine.captures[0].len);
    try std.testing.expectEqual(@as(usize, 4), machine.captures[1].start);
    try std.testing.expectEqual(@as(usize, 3), machine.captures[1].len);
}

test "capture wraps choice inside brackets" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const r1 = machine.match("<s: \"http\" / \"ftp\"> \"://\"", "http://");
    try std.testing.expectEqual(.ok, r1);
    try std.testing.expectEqual(@as(usize, 0), machine.captures[0].start);
    try std.testing.expectEqual(@as(usize, 4), machine.captures[0].len);
}

test "capture inside rule declaration" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match(
        "kv = <k: ['a'-'z']+> \"=\" <v: ['0'-'9']+>;",
        "abc=42",
    );
    try std.testing.expectEqual(.ok, result);
    try std.testing.expectEqual(@as(usize, 0), machine.captures[0].start);
    try std.testing.expectEqual(@as(usize, 3), machine.captures[0].len);
    try std.testing.expectEqual(@as(usize, 4), machine.captures[1].start);
    try std.testing.expectEqual(@as(usize, 2), machine.captures[1].len);
}

test "back-reference matches same text" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match("<w: ['a'-'z']+> \"-\" w", "abc-abc");
    try std.testing.expectEqual(.ok, result);
}

test "back-reference rejects different text" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match("<w: ['a'-'z']+> \"-\" w", "abc-xyz");
    try std.testing.expectEqual(.no_match, result);
}

test "capture survives backtracking in choice" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match(
        "(<k: \"ab\"> \"X\") / \"abc\"",
        "abc",
    );
    try std.testing.expectEqual(.ok, result);
}

test "negative lookahead passes when operand does not match" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match("!\"no\" ['a'-'z']+", "yes");
    try std.testing.expectEqual(.ok, result);
}

test "negative lookahead fails when operand matches" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match("!\"no\" ['a'-'z']+", "nope");
    try std.testing.expectEqual(.no_match, result);
}

test "negative lookahead does not consume input" {
    // If `!'a'` consumed input, the subsequent `'b'` would see the
    // second byte 'b' at position 1 instead of position 0 on a
    // non-matching case, or miss the 'b' on a matching case.
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const ok = machine.match("!\"a\" \"b\"", "b");
    try std.testing.expectEqual(.ok, ok);
}

test "keyword exclusion pattern with nested negative lookaheads" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();

    const source =
        "word = !keyword ident" ++
        "  where" ++
        "    keyword    = (\"if\" / \"else\") !ident_char;" ++
        "    ident      = ident_char+;" ++
        "    ident_char = ['a'-'z']" ++
        "  end";

    // Reserved keywords are rejected.
    try std.testing.expectEqual(.no_match, machine.match(source, "if"));
    try std.testing.expectEqual(.no_match, machine.match(source, "else"));
    // Identifiers that happen to start with a keyword still match,
    // because the trailing `!ident_char` rules them out as keywords.
    try std.testing.expectEqual(.ok, machine.match(source, "ifx"));
    try std.testing.expectEqual(.ok, machine.match(source, "elsewhere"));
    // Plain non-keyword identifiers match.
    try std.testing.expectEqual(.ok, machine.match(source, "hello"));
}

test "positive lookahead passes when operand matches, without consuming" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    // &"a" asserts 'a' at position 0, then 'a' consumes it.
    const result = machine.match("&\"a\" \"a\" \"b\"", "ab");
    try std.testing.expectEqual(.ok, result);
}

test "positive lookahead fails when operand does not match" {
    var machine = VmTest.init(std.testing.allocator);
    defer machine.deinit();
    const result = machine.match("&\"a\" \"b\"", "b");
    try std.testing.expectEqual(.no_match, result);
}
