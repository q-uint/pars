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
const stack_mod = @import("stack.zig");
const frame_mod = @import("frame.zig");
const RuleTable = compiler_mod.RuleTable;
const Compiler = compiler_mod.Compiler;
const FixedStack = stack_mod.FixedStack;
const DynamicStack = stack_mod.DynamicStack;
const CallFrame = frame_mod.CallFrame;
const BacktrackFrame = frame_mod.BacktrackFrame;
const max_frames = frame_mod.max_frames;
const max_bt = frame_mod.max_bt;

pub const FrameKind = frame_mod.FrameKind;
pub const no_label = frame_mod.no_label;

// Comptime toggle: per-instruction disassembly during run(). Off by
// default so the REPL and scripts produce clean output; flip to true
// when debugging the dispatch loop.
const trace_execution = false;

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
                            if (self.handleFail()) |r| return r;
                        } else {
                            self.pos += 1;
                        }
                    },
                    .op_match_any => {
                        if (self.pos >= self.input.len) {
                            if (self.handleFail()) |r| return r;
                        } else {
                            self.pos += 1;
                        }
                    },
                    .op_match_string => {
                        const literal = self.readConstantLiteral();
                        if (!self.consumePrefix(literal)) {
                            if (self.handleFail()) |r| return r;
                        }
                    },
                    .op_match_string_wide => {
                        const literal = self.readConstantWideLiteral();
                        if (!self.consumePrefix(literal)) {
                            if (self.handleFail()) |r| return r;
                        }
                    },
                    .op_match_string_i => {
                        const literal = self.readConstantLiteral();
                        if (!self.consumePrefixIgnoreCase(literal)) {
                            if (self.handleFail()) |r| return r;
                        }
                    },
                    .op_match_string_i_wide => {
                        const literal = self.readConstantWideLiteral();
                        if (!self.consumePrefixIgnoreCase(literal)) {
                            if (self.handleFail()) |r| return r;
                        }
                    },
                    .op_match_charset => {
                        const cs = self.readConstantCharset();
                        if (!self.consumeCharset(cs)) {
                            if (self.handleFail()) |r| return r;
                        }
                    },
                    .op_match_charset_wide => {
                        const cs = self.readConstantWideCharset();
                        if (!self.consumeCharset(cs)) {
                            if (self.handleFail()) |r| return r;
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
                        if (!self.pushBacktrack(.choice)) return .runtime_error;
                    },
                    .op_choice_quant => {
                        if (!self.pushBacktrack(.quant)) return .runtime_error;
                    },
                    .op_choice_lookahead => {
                        if (!self.pushBacktrack(.lookahead)) return .runtime_error;
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
                        if (self.handleFail()) |r| return r;
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
                            if (self.handleFail()) |r| return r;
                        }
                    },
                    .op_fail_twice => {
                        if (self.bt_top == 0) {
                            self.runtimeError("op_fail_twice with empty backtrack stack", .{});
                            return .runtime_error;
                        }
                        self.bt_top -= 1;
                        if (self.handleFail()) |r| return r;
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
                    .op_cut => {
                        self.cutInnermostChoice();
                    },
                    .op_cut_label => {
                        const idx = self.readByte();
                        self.cutInnermostChoice();
                        self.setCommitLabel(idx);
                    },
                    .op_cut_label_wide => {
                        const idx = self.readWideIndex();
                        self.cutInnermostChoice();
                        self.setCommitLabel(idx);
                    },
                    .op_halt => return .ok,
                }
            }
        }

        const FailResult = enum { backtracked, no_match, label_error };

        // Thin wrapper around fail() for match-site dispatch. Returns
        // null to continue execution (the frame was backtracked into),
        // or the InterpretResult the caller should return on exit.
        fn handleFail(self: *Self) ?InterpretResult {
            return switch (self.fail()) {
                .backtracked => null,
                .no_match => .no_match,
                .label_error => .runtime_error,
            };
        }

        fn fail(self: *Self) FailResult {
            // Unwind committed frames silently: they are ghosts left
            // behind by a cut so that op_commit still pops them, but
            // they must not catch a backtracking failure.
            while (self.bt_top > 0) {
                self.bt_top -= 1;
                const frame = self.bt_stack[self.bt_top];
                if (frame.committed) continue;
                self.pos = frame.pos;
                self.ip = frame.ip;
                self.chunk = frame.chunk;
                self.frame_count = frame.frame_count;
                return .backtracked;
            }
            // No backtrack frame left. If a labelled cut fired in any
            // active rule, the innermost such label becomes a runtime
            // error rather than a silent no_match.
            var i = self.frame_count;
            while (i > 0) {
                i -= 1;
                if (self.frames[i].commit_label != no_label) {
                    const idx = self.frames[i].commit_label;
                    const chunk_ptr = self.frames[i].callee;
                    const label = chunk_ptr.constants.items[idx].asObj().asLiteral().chars();
                    self.runtimeError("{s}", .{label});
                    return .label_error;
                }
            }
            return .no_match;
        }

        fn pushBacktrack(self: *Self, kind: FrameKind) bool {
            if (self.bt_top >= max_bt) {
                self.runtimeError("Backtrack stack overflow.", .{});
                return false;
            }
            const offset = self.readJumpOffset();
            self.bt_stack[self.bt_top] = .{
                .ip = @intCast(@as(isize, @intCast(self.ip)) + offset),
                .pos = self.pos,
                .chunk = self.chunk.?,
                .frame_count = self.frame_count,
                .kind = kind,
                .committed = false,
            };
            self.bt_top += 1;
            return true;
        }

        // Mark the innermost ordered-choice frame pushed by the current
        // rule as committed (ADR 008). The frame stays on the backtrack
        // stack so the matching op_commit still pops it, but fail()
        // skips it when unwinding. Only frames whose frame_count equals
        // the current call depth are eligible, which scopes a cut to
        // the rule it textually appears in: a cut in a called rule
        // cannot commit a choice in its caller. Walks past quantifier
        // and lookahead frames; a cut with no eligible choice in scope
        // is a no-op.
        fn cutInnermostChoice(self: *Self) void {
            var i = self.bt_top;
            while (i > 0) {
                i -= 1;
                const f = self.bt_stack[i];
                if (f.frame_count != self.frame_count) return;
                if (f.kind == .choice and !f.committed) {
                    self.bt_stack[i].committed = true;
                    return;
                }
            }
        }

        fn setCommitLabel(self: *Self, idx: u32) void {
            if (self.frame_count > 0) {
                self.frames[self.frame_count - 1].commit_label = idx;
            }
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
                .commit_label = no_label,
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
