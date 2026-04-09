const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Value = @import("value.zig").Value;
const printValue = @import("value.zig").printValue;
const debug = @import("debug.zig");

const trace_execution = true;
const stack_max = 256;

pub const InterpretResult = enum {
    ok,
    compile_error,
    runtime_error,
};

pub const VM = struct {
    chunk: *Chunk,
    // Instruction pointer: index of the next instruction to execute.
    ip: usize,
    stack: [stack_max]Value,
    stack_top: usize,

    pub fn init(c: *Chunk) VM {
        return .{
            .chunk = c,
            .ip = 0,
            .stack = undefined,
            .stack_top = 0,
        };
    }

    pub fn push(self: *VM, val: Value) void {
        self.stack[self.stack_top] = val;
        self.stack_top += 1;
    }

    pub fn pop(self: *VM) Value {
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }

    pub fn interpret(self: *VM) InterpretResult {
        return self.run();
    }

    // Dispatch loop. Faster VMs use direct threaded code, jump tables,
    // or computed goto to avoid the switch overhead. Zig has no goto,
    // but the compiler can lower a dense enum switch to a jump table
    // automatically, so a plain switch is both idiomatic and efficient.
    fn run(self: *VM) InterpretResult {
        while (true) {
            if (comptime trace_execution) {
                if (self.stack_top > 0) {
                    std.debug.print("          ", .{});
                    for (self.stack[0..self.stack_top]) |slot| {
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
                    self.push(constant);
                },
                .op_constant_wide => {
                    const constant = self.readConstantWide();
                    self.push(constant);
                },
                .op_return => {
                    printValue(self.pop());
                    std.debug.print("\n", .{});
                    return .ok;
                },
            }
        }
    }

    fn readByte(self: *VM) u8 {
        const byte = self.chunk.code.items[self.ip];
        self.ip += 1;
        return byte;
    }

    fn readConstant(self: *VM) []const u8 {
        return self.chunk.constants.items[self.readByte()];
    }

    fn readConstantWide(self: *VM) []const u8 {
        const index: usize = @as(usize, self.readByte()) |
            (@as(usize, self.readByte()) << 8) |
            (@as(usize, self.readByte()) << 16);
        return self.chunk.constants.items[index];
    }

    pub fn deinit(self: *VM) void {
        _ = self;
    }
};
