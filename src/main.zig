const std = @import("std");
const pars = @import("pars");
const Chunk = pars.chunk.Chunk;
const OpCode = pars.chunk.OpCode;
const debug = pars.debug;

pub fn main() !void {
    var c = Chunk.init(std.heap.page_allocator);
    defer c.deinit();

    const constant = try c.addConstant("hello");
    try c.write(@intFromEnum(OpCode.op_constant), 123);
    try c.write(@intCast(constant), 123);

    try c.write(@intFromEnum(OpCode.op_return), 123);
    debug.disassembleChunk(&c, "test chunk");
}
