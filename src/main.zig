const std = @import("std");
const pars = @import("pars");
const VM = pars.vm.Vm(null);
const InterpretResult = pars.vm.InterpretResult;

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    const io = init.io;

    var vm = VM.init(alloc);
    defer vm.deinit();

    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);

    if (args.len == 1) {
        try repl(&vm, alloc, io);
    } else if (args.len == 2 or args.len == 3) {
        const input = if (args.len == 3)
            readInput(alloc, io, args[2])
        else
            readStdin(alloc, io);
        defer alloc.free(input);
        try runFile(&vm, alloc, io, args[1], input);
    } else {
        std.debug.print("Usage: pars <grammar> [input]\n", .{});
        std.process.exit(64);
    }
}

fn repl(vm: *VM, alloc: std.mem.Allocator, io: std.Io) !void {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);

    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);

    try runRepl(vm, alloc, &stdin_reader.interface, &stdout_writer.interface);
}

// The REPL keeps a *sticky input buffer*: a single byte slice that
// persists across iterations. Meta commands (lines starting with `:`)
// manipulate the buffer; every other line is compiled as a pars
// expression and matched against whatever the buffer currently holds.
//
// Multi-line input is supported: if a statement looks syntactically
// incomplete (all parse errors land at EOF), the REPL shows a `... `
// continuation prompt and accumulates further lines before executing.
//
// Extracted from `repl()` so tests can drive it with in-memory reader
// and writer.
fn runRepl(
    vm: *VM,
    alloc: std.mem.Allocator,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
) !void {
    var sticky: std.ArrayList(u8) = .empty;
    defer sticky.deinit(alloc);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try stdout.writeAll("pars REPL. type :help for commands.\n");

    while (true) {
        const prompt: []const u8 = if (buf.items.len == 0) "> " else "... ";
        try stdout.writeAll(prompt);
        try stdout.flush();

        const line = (try stdin.takeDelimiter('\n')) orelse {
            try stdout.writeAll("\n");
            try stdout.flush();
            return;
        };

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (trimmed[0] == ':') {
            buf.clearRetainingCapacity();
            const exit = try handleMeta(trimmed, &sticky, alloc, stdout, vm);
            try stdout.flush();
            if (exit) return;
            continue;
        }

        if (buf.items.len > 0) try buf.append(alloc, '\n');
        try buf.appendSlice(alloc, trimmed);

        if (vm.isIncomplete(buf.items)) continue;

        const result = vm.match(buf.items, sticky.items);
        try reportResult(stdout, result, vm);
        try stdout.flush();
        buf.clearRetainingCapacity();
    }
}

fn handleMeta(
    line: []const u8,
    sticky: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    stdout: anytype,
    vm: *VM,
) !bool {
    // Split on the first space: everything before is the command,
    // everything after (left-trimmed) is the argument.
    const space = std.mem.indexOfScalar(u8, line, ' ');
    const cmd = if (space) |s| line[0..s] else line;
    const arg = if (space) |s| std.mem.trimStart(u8, line[s + 1 ..], " \t") else "";

    if (std.mem.eql(u8, cmd, ":input")) {
        if (arg.len == 0) {
            try stdout.print("input ({d} bytes): \"{s}\"\n", .{ sticky.items.len, sticky.items });
        } else {
            sticky.clearRetainingCapacity();
            try sticky.appendSlice(alloc, arg);
            try stdout.print("input set ({d} bytes)\n", .{arg.len});
        }
    } else if (std.mem.eql(u8, cmd, ":clear")) {
        sticky.clearRetainingCapacity();
        try stdout.writeAll("input cleared\n");
    } else if (std.mem.eql(u8, cmd, ":use")) {
        if (arg.len == 0) {
            try stdout.writeAll("usage: :use <module>\n");
        } else {
            const source = try std.fmt.allocPrint(alloc, "use \"{s}\";", .{arg});
            defer alloc.free(source);
            switch (vm.match(source, "")) {
                .ok => try stdout.print("loaded {s}\n", .{arg}),
                .compile_error => {}, // vm.match already wrote the error to stderr
                else => try stdout.writeAll("failed to load module\n"),
            }
        }
    } else if (std.mem.eql(u8, cmd, ":help")) {
        try stdout.writeAll(
            \\commands:
            \\  :input <text>  set the sticky input buffer
            \\  :input         show the current input
            \\  :clear         clear the sticky input
            \\  :use <module>  load a module (e.g. :use std/abnf)
            \\  :exit / :quit  exit the REPL
            \\  :help          this message
            \\
            \\any other line is compiled as a pars expression and
            \\matched against the sticky input.
            \\
        );
    } else if (std.mem.eql(u8, cmd, ":exit") or std.mem.eql(u8, cmd, ":quit")) {
        return true;
    } else {
        try stdout.print("unknown command: {s}\n", .{cmd});
    }
    return false;
}

fn reportResult(stdout: anytype, result: InterpretResult, vm: *VM) !void {
    switch (result) {
        .ok => try stdout.print("ok: matched {d}/{d} bytes\n", .{ vm.pos, vm.input.len }),
        .no_match => try stdout.print("no match at byte {d}/{d}\n", .{ vm.pos, vm.input.len }),
        // Compile errors are already reported by the compiler via stderr.
        .compile_error => {},
        .runtime_error => try stdout.writeAll("runtime error\n"),
    }
}

fn readInput(alloc: std.mem.Allocator, io: std.Io, path: []const u8) []const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => {
            std.debug.print("Could not open input file \"{s}\".\n", .{path});
            std.process.exit(74);
        },
        error.OutOfMemory => {
            std.debug.print("Not enough memory to read \"{s}\".\n", .{path});
            std.process.exit(74);
        },
        else => {
            std.debug.print("Could not read input file \"{s}\".\n", .{path});
            std.process.exit(74);
        },
    };
}

fn readStdin(alloc: std.mem.Allocator, io: std.Io) []const u8 {
    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buf);
    return reader.interface.allocRemaining(alloc, .unlimited) catch {
        std.debug.print("Could not read stdin.\n", .{});
        std.process.exit(74);
    };
}

fn runFile(vm: *VM, alloc: std.mem.Allocator, io: std.Io, path: []const u8, input: []const u8) !void {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |err| switch (err) {
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
    defer alloc.free(source);

    const result = vm.match(source, input);
    switch (result) {
        .ok => {},
        .no_match => std.process.exit(1),
        .compile_error => std.process.exit(65),
        .runtime_error => std.process.exit(70),
    }
}

test "repl session: set input, match, inspect, clear, exit" {
    const alloc = std.testing.allocator;

    var vm = VM.init(alloc);
    defer vm.deinit();

    const script =
        ":input GET /foo HTTP/1.1\n" ++
        "\"GET\"\n" ++
        "\"GET\" \" \" \"/\"\n" ++
        "\"POST\"\n" ++
        ":input\n" ++
        ":clear\n" ++
        ":input\n" ++
        ":exit\n";

    var reader = std.Io.Reader.fixed(script);

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    try runRepl(&vm, alloc, &reader, &aw.writer);

    const expected =
        "pars REPL. type :help for commands.\n" ++
        "> input set (17 bytes)\n" ++
        "> ok: matched 3/17 bytes\n" ++
        "> ok: matched 5/17 bytes\n" ++
        "> no match at byte 0/17\n" ++
        "> input (17 bytes): \"GET /foo HTTP/1.1\"\n" ++
        "> input cleared\n" ++
        "> input (0 bytes): \"\"\n" ++
        "> ";

    try std.testing.expectEqualStrings(expected, aw.writer.buffered());
}

test "repl: unknown meta command and eof exit" {
    const alloc = std.testing.allocator;

    var vm = VM.init(alloc);
    defer vm.deinit();

    const script = ":bogus\n";

    var reader = std.Io.Reader.fixed(script);

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    try runRepl(&vm, alloc, &reader, &aw.writer);

    const expected =
        "pars REPL. type :help for commands.\n" ++
        "> unknown command: :bogus\n" ++
        "> \n";

    try std.testing.expectEqualStrings(expected, aw.writer.buffered());
}

fn runExample(comptime grammar_path: []const u8, input: []const u8) !void {
    const alloc = std.testing.allocator;
    var vm = VM.init(alloc);
    defer vm.deinit();
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, grammar_path, alloc, .unlimited);
    defer alloc.free(source);
    const result = vm.match(source, input);
    try std.testing.expectEqual(.ok, result);
    try std.testing.expectEqual(input.len, vm.pos);
}

test "example: csv-line" {
    try runExample("examples/csv-line.pars", "alice,30,new york");
}

test "example: http-request-line" {
    try runExample("examples/http-request-line.pars", "GET /index.html HTTP/1.1");
}

test "example: identifier" {
    try runExample("examples/identifier.pars", "foo_123");
}

test "example: integer (negative)" {
    try runExample("examples/integer.pars", "-42");
}

test "example: integer (unsigned)" {
    try runExample("examples/integer.pars", "100");
}

test "example: ipv4" {
    try runExample("examples/ipv4.pars", "192.168.1.1");
}

test "repl: multiline where block accumulates across prompts" {
    const alloc = std.testing.allocator;

    var vm = VM.init(alloc);
    defer vm.deinit();

    const script =
        ":input abc:123\n" ++
        "kv = k \":\" v\n" ++
        "  where\n" ++
        "    k = ['a'-'z']+;\n" ++
        "    v = ['0'-'9']+\n" ++
        "  end\n" ++
        ":exit\n";

    var reader = std.Io.Reader.fixed(script);

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    try runRepl(&vm, alloc, &reader, &aw.writer);

    const out = aw.writer.buffered();
    // Continuation prompts appear while the where block is open.
    try std.testing.expect(std.mem.indexOf(u8, out, "... ") != null);
    // The complete rule ultimately matches.
    try std.testing.expect(std.mem.indexOf(u8, out, "ok:") != null);
}

test "repl: where clause on a single line" {
    const alloc = std.testing.allocator;

    var vm = VM.init(alloc);
    defer vm.deinit();

    const script =
        ":input abc:123\n" ++
        "kv = k \":\" v where k = ['a'-'z']+; v = ['0'-'9']+ end\n" ++
        ":exit\n";

    var reader = std.Io.Reader.fixed(script);

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    try runRepl(&vm, alloc, &reader, &aw.writer);

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "ok:") != null);
}

test "repl: stdlib rules available after use directive" {
    const alloc = std.testing.allocator;

    var vm = VM.init(alloc);
    defer vm.deinit();

    const script =
        ":input abc123\n" ++
        "use \"std/abnf\";\n" ++
        "ALPHA+ DIGIT+\n" ++
        ":exit\n";

    var reader = std.Io.Reader.fixed(script);

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    try runRepl(&vm, alloc, &reader, &aw.writer);

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "ok:") != null);
}

test "repl: :use loads a stdlib module" {
    const alloc = std.testing.allocator;

    var vm = VM.init(alloc);
    defer vm.deinit();

    const script =
        ":input abc123\n" ++
        ":use std/abnf\n" ++
        "ALPHA+ DIGIT+\n" ++
        ":exit\n";

    var reader = std.Io.Reader.fixed(script);

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    try runRepl(&vm, alloc, &reader, &aw.writer);

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "loaded std/abnf") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ok:") != null);
}

test "repl: help command lists all meta commands" {
    const alloc = std.testing.allocator;

    var vm = VM.init(alloc);
    defer vm.deinit();

    const script = ":help\n:exit\n";

    var reader = std.Io.Reader.fixed(script);

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();

    try runRepl(&vm, alloc, &reader, &aw.writer);

    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, ":input <text>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ":clear") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ":use <module>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ":exit / :quit") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ":help") != null);
}
