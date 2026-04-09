const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Value = @import("value.zig").Value;
const printValue = @import("value.zig").printValue;
const debug = @import("debug.zig");

const trace_execution = !@import("builtin").is_test;

pub const InterpretResult = enum {
    ok,
    compile_error,
    runtime_error,
};

// Optional comptime stack size: fixed array when set, dynamic when null.
pub fn Vm(comptime stack_size: ?comptime_int) type {
    const Stack = if (stack_size) |s| FixedStack(s) else DynamicStack;

    return struct {
        const Self = @This();

        chunk: *Chunk,
        // Instruction pointer: index of the next instruction to execute.
        ip: usize,
        stack: Stack,

        pub fn init(allocator: std.mem.Allocator, c: *Chunk) Self {
            return .{
                .chunk = c,
                .ip = 0,
                .stack = Stack.init(allocator),
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

        pub fn interpret(self: *Self) InterpretResult {
            return self.run();
        }

        // Dispatch loop. Faster VMs use direct threaded code, jump tables,
        // or computed goto to avoid the switch overhead. Zig has no goto,
        // but the compiler can lower a dense enum switch to a jump table
        // automatically, so a plain switch is both idiomatic and efficient.
        fn run(self: *Self) InterpretResult {
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
                    _ = debug.disassembleInstruction(self.chunk, self.ip);
                }

                const instruction = self.readByte();
                const op = std.meta.intToEnum(OpCode, instruction) catch
                    return .runtime_error;
                switch (op) {
                    .op_constant => {
                        const constant = self.readConstant();
                        self.push(constant) catch return .runtime_error;
                    },
                    .op_constant_wide => {
                        const constant = self.readConstantWide();
                        self.push(constant) catch return .runtime_error;
                    },
                    .op_return => {
                        printValue(self.pop());
                        std.debug.print("\n", .{});
                        return .ok;
                    },
                }
            }
        }

        fn readByte(self: *Self) u8 {
            const byte = self.chunk.code.items[self.ip];
            self.ip += 1;
            return byte;
        }

        fn readConstant(self: *Self) []const u8 {
            return self.chunk.constants.items[self.readByte()];
        }

        fn readConstantWide(self: *Self) []const u8 {
            const index: usize = @as(usize, self.readByte()) |
                (@as(usize, self.readByte()) << 8) |
                (@as(usize, self.readByte()) << 16);
            return self.chunk.constants.items[index];
        }

        pub fn deinit(self: *Self) void {
            self.stack.deinit();
        }
    };
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

fn testVm(comptime stack_size: ?comptime_int) type {
    return struct {
        fn helperChunk(alloc: std.mem.Allocator) !Chunk {
            var c = Chunk.init(alloc);
            try c.writeConstant("hello", 1);
            try c.write(@intFromEnum(OpCode.op_return), 1);
            return c;
        }

        fn interpretReturnsOk() !void {
            const alloc = std.testing.allocator;
            var c = try helperChunk(alloc);
            defer c.deinit();
            var machine = Vm(stack_size).init(alloc, &c);
            defer machine.deinit();
            try std.testing.expectEqual(.ok, machine.interpret());
        }

        fn constantIsPushedOntoStack() !void {
            const alloc = std.testing.allocator;
            var c = Chunk.init(alloc);
            defer c.deinit();
            try c.writeConstant("world", 1);
            try c.writeConstant("hello", 1);
            try c.write(@intFromEnum(OpCode.op_return), 1);

            var machine = Vm(stack_size).init(alloc, &c);
            defer machine.deinit();

            // Manually execute the first constant instruction.
            const first = machine.readByte();
            try std.testing.expectEqual(@intFromEnum(OpCode.op_constant), first);
            const val = machine.readConstant();
            try machine.push(val);
            try std.testing.expectEqualStrings("world", machine.stackSlice()[0]);
        }

        fn fixedStackOverflows() !void {
            if (stack_size == null) return;
            const alloc = std.testing.allocator;
            var c = Chunk.init(alloc);
            defer c.deinit();
            // Write more constants than the stack can hold.
            for (0..stack_size.? + 1) |_| {
                try c.writeConstant("x", 1);
            }
            try c.write(@intFromEnum(OpCode.op_return), 1);

            var machine = Vm(stack_size).init(alloc, &c);
            defer machine.deinit();
            // Should hit runtime_error from stack overflow, not crash.
            try std.testing.expectEqual(.runtime_error, machine.interpret());
        }
    };
}

test "dynamic vm: interpret returns ok" {
    try testVm(null).interpretReturnsOk();
}

test "dynamic vm: constant is pushed onto stack" {
    try testVm(null).constantIsPushedOntoStack();
}

test "fixed vm: interpret returns ok" {
    try testVm(256).interpretReturnsOk();
}

test "fixed vm: constant is pushed onto stack" {
    try testVm(256).constantIsPushedOntoStack();
}

test "fixed vm: stack overflow returns runtime error" {
    try testVm(4).fixedStackOverflows();
}
