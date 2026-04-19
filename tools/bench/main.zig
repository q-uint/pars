//! pars bench harness.
//!
//! Compiles and runs a fixed set of grammar/input pairs, printing for
//! each one: input length, total bytecode size (top-level + rule
//! chunks), and the number of opcodes dispatched. The counts are
//! deterministic, so the output is meant to be diffed across commits
//! to catch codegen regressions and confirm peephole/AST-level
//! optimisations actually reduce work.

const std = @import("std");
const pars = @import("pars");
const VM = pars.vm.Vm(null);

const Fixture = struct {
    name: []const u8,
    grammar: []const u8,
    input: []const u8,
    // When true, `input` is a path read from disk; otherwise the
    // bytes themselves are the input. Used for fixtures that want a
    // larger or structured payload without embedding it in source.
    input_is_path: bool = false,
};

const fixtures = [_]Fixture{
    .{ .name = "csv-line", .grammar = "examples/csv-line.pars", .input = "alice,30,new york" },
    .{ .name = "http-request-line", .grammar = "examples/http-request-line.pars", .input = "examples/http-request-line.input", .input_is_path = true },
    .{ .name = "identifier", .grammar = "examples/identifier.pars", .input = "foo_123" },
    .{ .name = "integer", .grammar = "examples/integer.pars", .input = "-42" },
    .{ .name = "ipv4", .grammar = "examples/ipv4.pars", .input = "192.168.1.1" },
    .{ .name = "iso-date", .grammar = "examples/iso-date.pars", .input = "2026-04-18" },
    .{ .name = "keyword-exclusion", .grammar = "examples/keyword-exclusion.pars", .input = "hello" },
    .{ .name = "left-recursive-expr", .grammar = "examples/left-recursive-expr.pars", .input = "1+2-3+4" },
    .{ .name = "longest-match", .grammar = "examples/longest-match.pars", .input = "<=" },
    .{ .name = "quoted-word", .grammar = "examples/quoted-word.pars", .input = "'hello'" },
    // Heaviest fixture: use the pars-grammar-validator from stdlib
    // to validate a real .pars file. Exercises the whole stdlib
    // grammar, including the parts that backtrack on real input.
    .{ .name = "grammar/identifier", .grammar = "examples/grammar.pars", .input = "examples/identifier.pars", .input_is_path = true },
};

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout_writer.interface;

    try w.print("{s:<24} {s:>8} {s:>6} {s:>10}  {s}\n", .{ "name", "input", "code", "ops", "result" });
    try w.print("{s:<24} {s:>8} {s:>6} {s:>10}  {s}\n", .{ "----", "-----", "----", "---", "------" });

    var total_ops: u64 = 0;
    var total_code: usize = 0;

    for (fixtures) |fx| {
        const source = std.Io.Dir.cwd().readFileAlloc(io, fx.grammar, alloc, .unlimited) catch |err| {
            try w.print("{s:<24} error reading grammar {s}: {s}\n", .{ fx.name, fx.grammar, @errorName(err) });
            continue;
        };
        defer alloc.free(source);

        const input: []const u8 = if (fx.input_is_path)
            std.Io.Dir.cwd().readFileAlloc(io, fx.input, alloc, .unlimited) catch |err| {
                try w.print("{s:<24} error reading input {s}: {s}\n", .{ fx.name, fx.input, @errorName(err) });
                continue;
            }
        else
            fx.input;
        defer if (fx.input_is_path) alloc.free(input);

        var vm = VM.init(alloc);
        defer vm.deinit();

        const result = vm.match(source, input);
        try w.print("{s:<24} {d:>8} {d:>6} {d:>10}  {s}\n", .{
            fx.name, input.len, vm.last_code_bytes, vm.instructions, @tagName(result),
        });

        total_ops += vm.instructions;
        total_code += vm.last_code_bytes;
    }

    try w.print("{s:<24} {s:>8} {s:>6} {s:>10}  {s}\n", .{ "----", "-----", "----", "---", "------" });
    try w.print("{s:<24} {s:>8} {d:>6} {d:>10}\n", .{ "total", "", total_code, total_ops });
    try w.flush();
}
