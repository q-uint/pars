//! pars-lsp entry point.
//!
//! Reads LSP messages from stdin, dispatches through `Server`, writes
//! responses and notifications to stdout. The protocol exits cleanly
//! on an `exit` notification (or on stream EOF); `shutdown` flips a
//! flag that the exit handler consults to pick a process status.

const std = @import("std");
const server_mod = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    const io = init.io;

    // Large buffers: LSP clients routinely send full-document text
    // payloads, which can easily exceed a few KB on real grammar
    // files. Undersized buffers cause takeDelimiterExclusive or
    // readSliceAll to fail with StreamTooLong.
    var stdin_buf: [1 << 20]u8 = undefined;
    var stdout_buf: [1 << 16]u8 = undefined;

    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);

    var server = server_mod.Server.initWithIo(alloc, io, &stdout_writer.interface);
    defer server.deinit();

    while (true) {
        const body_opt = server_mod.readMessage(alloc, &stdin_reader.interface) catch |err| {
            std.debug.print("pars-lsp: framing error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        const body = body_opt orelse return;
        defer alloc.free(body);

        // `exit` is a notification, not a request. The spec says the
        // server must terminate with exit code 0 if it got `shutdown`
        // first, else 1. We check the method name up front so we never
        // try to dispatch through the generic handler after the client
        // has declared it is leaving.
        if (isExitMessage(body)) {
            std.process.exit(if (server.shutdown_requested) 0 else 1);
        }

        server.handleMessage(body) catch |err| {
            std.debug.print("pars-lsp: handler error: {s}\n", .{@errorName(err)});
        };
    }
}

fn isExitMessage(body: []const u8) bool {
    // Cheap string scan. A stricter implementation would parse the
    // JSON, but no other LSP method contains `"method":"exit"`, and
    // the worst case of a false positive is an early exit on a client
    // that is already shutting down.
    return std.mem.indexOf(u8, body, "\"method\":\"exit\"") != null or
        std.mem.indexOf(u8, body, "\"method\": \"exit\"") != null;
}
