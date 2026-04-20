//! Stdlib discovery and loading for the pars LSP.
//!
//! Resolves module paths like "std/abnf" to absolute filesystem paths,
//! so goto-definition and hover can return `file://` locations that any
//! LSP client can open. The compiler still reads stdlib sources from
//! its own embedded copy (see build.zig); this module exists only so
//! the editor can point a user at a file on disk.
//!
//! Discovery order for the stdlib directory:
//!
//!   1. `$PARS_STDLIB_PATH` — dev/override.
//!   2. `stdlib_install_path` — compile-time install prefix baked by
//!      build.zig. This is the normal installed-binary path.
//!   3. `stdlib_source_path` — compile-time repo `lib/` path, used by
//!      `zig build test` and in-place dev runs.
//!
//! The first directory that exists wins; an individual module file only
//! needs to exist under the chosen directory for resolution to succeed.

const std = @import("std");
const build_opts = @import("lsp_build_opts");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Locate the stdlib directory. Returns the allocator-owned path, or
/// null if no candidate directory exists. Callers own the returned
/// slice.
pub fn findDir(alloc: Allocator, io: Io) !?[]u8 {
    // POSIX-only: the LSP already assumes a POSIX host (see the
    // `/`-rooted path handling in pathToFileUri). Zig 0.16 moved
    // environment access behind `std.process.Environ`, which would
    // require threading the `Environ` through every caller; libc
    // `getenv` is a simpler dependency for this single override knob.
    if (std.c.getenv("PARS_STDLIB_PATH")) |raw| {
        const p = std.mem.sliceTo(raw, 0);
        if (p.len > 0 and dirExists(io, p)) return try alloc.dupe(u8, p);
    }

    if (dirExists(io, build_opts.stdlib_install_path)) {
        return try alloc.dupe(u8, build_opts.stdlib_install_path);
    }
    if (dirExists(io, build_opts.stdlib_source_path)) {
        return try alloc.dupe(u8, build_opts.stdlib_source_path);
    }
    return null;
}

fn dirExists(io: Io, path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    var d = Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// Resolve a module path like "std/abnf" to the absolute filesystem
/// path of its source file, or null if the module name is unrecognized
/// or the stdlib directory is not present. Caller owns the returned
/// slice.
///
/// Only the `std/` namespace is recognized today; unknown names return
/// null rather than erroring so the LSP can silently fall back to a
/// null result (matching the behavior for unresolvable local refs).
pub fn resolveModulePath(alloc: Allocator, io: Io, module: []const u8) !?[]u8 {
    const filename = moduleFilename(module) orelse return null;
    const dir = (try findDir(alloc, io)) orelse return null;
    defer alloc.free(dir);
    return try std.fs.path.join(alloc, &.{ dir, filename });
}

fn moduleFilename(module: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, module, "std/abnf")) return "abnf.pars";
    if (std.mem.eql(u8, module, "std/abnf_grammar")) return "abnf_grammar.pars";
    if (std.mem.eql(u8, module, "std/pars_grammar")) return "pars_grammar.pars";
    return null;
}

/// Encode an absolute filesystem path as a `file://` URI. Caller owns
/// the returned slice. Percent-encodes bytes that are not safe in a
/// path segment per RFC 3986; `/` is preserved.
pub fn pathToFileUri(alloc: Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "file://");
    // On POSIX, `path` starts with `/`. On Windows, it would be
    // `C:\...`; we'd need a leading `/` and forward slashes there, but
    // that's out of scope for now — the LSP only runs on POSIX today.
    const hex = "0123456789ABCDEF";
    for (path) |c| {
        if (isUnreservedUriByte(c) or c == '/') {
            try out.append(alloc, c);
        } else {
            try out.append(alloc, '%');
            try out.append(alloc, hex[(c >> 4) & 0xF]);
            try out.append(alloc, hex[c & 0xF]);
        }
    }
    return try out.toOwnedSlice(alloc);
}

fn isUnreservedUriByte(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '.' or c == '_' or c == '~';
}

/// Read a stdlib source file into memory. Caller owns the returned
/// slice. Returns null if the file doesn't exist or cannot be read.
pub fn readSource(alloc: Allocator, io: Io, path: []const u8) !?[]u8 {
    if (!std.fs.path.isAbsolute(path)) return null;
    const file = Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);

    const size = file.length(io) catch return null;
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);

    const n = file.readPositionalAll(io, buf, 0) catch {
        alloc.free(buf);
        return null;
    };
    return buf[0..n];
}

test "pathToFileUri: plain ascii path" {
    const alloc = std.testing.allocator;
    const uri = try pathToFileUri(alloc, "/home/user/lib/abnf.pars");
    defer alloc.free(uri);
    try std.testing.expectEqualStrings("file:///home/user/lib/abnf.pars", uri);
}

test "pathToFileUri: spaces are percent-encoded" {
    const alloc = std.testing.allocator;
    const uri = try pathToFileUri(alloc, "/a b/c.pars");
    defer alloc.free(uri);
    try std.testing.expectEqualStrings("file:///a%20b/c.pars", uri);
}

test "moduleFilename recognizes shipped modules" {
    try std.testing.expectEqualStrings("abnf.pars", moduleFilename("std/abnf").?);
    try std.testing.expectEqualStrings("abnf_grammar.pars", moduleFilename("std/abnf_grammar").?);
    try std.testing.expectEqualStrings("pars_grammar.pars", moduleFilename("std/pars_grammar").?);
    try std.testing.expect(moduleFilename("std/unknown") == null);
    try std.testing.expect(moduleFilename("relative/thing") == null);
}
