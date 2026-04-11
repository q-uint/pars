const std = @import("std");
const pars = @import("pars");
const VM = pars.vm.Vm(null);

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    var vm = VM.init(alloc);
    defer vm.deinit();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len == 1) {
        try repl(&vm);
    } else if (args.len == 2) {
        try runFile(&vm, args[1]);
    } else {
        std.debug.print("Usage: pars [path]\n", .{});
        std.process.exit(64);
    }
}

fn repl(vm: *VM) !void {
    var stdin_buf: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    var stdout_buf: [64]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    while (true) {
        try stdout.writeAll("> ");
        try stdout.flush();

        const line = (try stdin.takeDelimiter('\n')) orelse {
            try stdout.writeAll("\n");
            try stdout.flush();
            return;
        };

        _ = vm.interpret(line);
    }
}

fn runFile(vm: *VM, path: []const u8) !void {
    const source = std.fs.cwd().readFileAlloc(
        std.heap.page_allocator,
        path,
        std.math.maxInt(usize),
    ) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => {
            std.debug.print("Could not open file \"{s}\".\n", .{path});
            std.process.exit(74);
        },
        error.OutOfMemory => {
            std.debug.print("Not enough memory to read \"{s}\".\n", .{path});
            std.process.exit(74);
        },
        else => {
            std.debug.print("Could not read file \"{s}\".\n", .{path});
            std.process.exit(74);
        },
    };
    defer std.heap.page_allocator.free(source);

    const result = vm.interpret(source);
    switch (result) {
        .ok => {},
        .no_match => std.process.exit(1),
        .compile_error => std.process.exit(65),
        .runtime_error => std.process.exit(70),
    }
}
