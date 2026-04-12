const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const printValue = value_mod.printValue;
const debug = @import("debug.zig");
const compiler = @import("compiler.zig");
const object = @import("object.zig");

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
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            object.init(allocator);
            return .{
                .chunk = null,
                .ip = 0,
                .input = "",
                .pos = 0,
                .stack = Stack.init(allocator),
                .allocator = allocator,
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

        pub fn match(
            self: *Self,
            source: []const u8,
            input: []const u8,
        ) InterpretResult {
            var c = Chunk.init(self.allocator);
            defer c.deinit();

            if (!compiler.compile(self.allocator, source, &c)) {
                renderCompileErrorsToStderr(source);
                return .compile_error;
            }

            self.chunk = &c;
            self.ip = 0;
            self.input = input;
            self.pos = 0;
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
                const op = std.meta.intToEnum(OpCode, instruction) catch {
                    self.runtimeError("unknown opcode {d}", .{instruction});
                    return .runtime_error;
                };
                switch (op) {
                    .op_match_char => {
                        const byte = self.readByte();
                        if (self.pos >= self.input.len) return .no_match;
                        if (self.input[self.pos] != byte) return .no_match;
                        self.pos += 1;
                    },
                    .op_match_any => {
                        if (self.pos >= self.input.len) return .no_match;
                        self.pos += 1;
                    },
                    .op_match_string => {
                        const literal = self.readConstantLiteral();
                        if (!self.consumePrefix(literal)) return .no_match;
                    },
                    .op_match_string_wide => {
                        const literal = self.readConstantWideLiteral();
                        if (!self.consumePrefix(literal)) return .no_match;
                    },
                    .op_match_string_i => {
                        const literal = self.readConstantLiteral();
                        if (!self.consumePrefixIgnoreCase(literal)) return .no_match;
                    },
                    .op_match_string_i_wide => {
                        const literal = self.readConstantWideLiteral();
                        if (!self.consumePrefixIgnoreCase(literal)) return .no_match;
                    },
                    .op_match_charset => {
                        const cs = self.readConstantCharset();
                        if (!self.consumeCharset(cs)) return .no_match;
                    },
                    .op_match_charset_wide => {
                        const cs = self.readConstantWideCharset();
                        if (!self.consumeCharset(cs)) return .no_match;
                    },
                    .op_halt => return .ok,
                }
            }
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
            var buf: [1024]u8 = undefined;
            var w = std.fs.File.stderr().writer(&buf);
            w.interface.print(fmt, args) catch {};
            w.interface.print("\n", .{}) catch {};

            // ip points past the offending instruction, so subtract 1.
            const line = self.chunk.?.getLine(self.ip - 1);
            w.interface.print("[line {d}] in script\n", .{line}) catch {};
            w.interface.flush() catch {};
        }

        pub fn deinit(self: *Self) void {
            self.stack.deinit();
            compiler.deinit(self.allocator);
            object.freeObjects();
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

fn renderCompileErrorsToStderr(source: []const u8) void {
    var buf: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buf);
    compiler.renderErrors(source, &stderr_writer.interface) catch return;
    stderr_writer.interface.flush() catch return;
}

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
