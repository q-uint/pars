const std = @import("std");
const pars = @import("pars");
const Chunk = pars.chunk.Chunk;
const OpCode = pars.chunk.OpCode;
const VM = pars.vm.VM;
const debug = pars.debug;

pub fn main() !void {
    var c = Chunk.init(std.heap.page_allocator);
    defer c.deinit();

    try c.writeConstant("hello", 123);
    try c.write(@intFromEnum(OpCode.op_return), 123);

    var machine = VM.init(&c);
    defer machine.deinit();
    _ = machine.interpret();
}
