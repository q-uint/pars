const std = @import("std");

/// A structured compile-time diagnostic. Messages are static strings;
/// the location is a source-byte span plus 1-based line and column so
/// the renderer can show a snippet with a caret without re-scanning.
pub const CompileError = struct {
    line: usize,
    column: usize,
    start: usize,
    len: usize,
    message: []const u8,
    at_eof: bool,
};

pub fn renderAll(errors: []const CompileError, source: []const u8, writer: *std.Io.Writer) !void {
    for (errors) |e| {
        try renderOne(source, writer, e);
    }
}

pub fn renderOne(source: []const u8, writer: *std.Io.Writer, e: CompileError) !void {
    try writer.print("error: {s}\n", .{e.message});
    try writer.print(" --> line {d}, column {d}\n", .{ e.line, e.column });

    const line_range = findLine(source, e.line);
    const line_text = source[line_range.start..line_range.end];

    // Clamp the caret column into the rendered line so a reported
    // column past end-of-line (e.g. EOF on an empty file) still
    // produces a readable pointer rather than running off the edge.
    const caret_col = if (e.column == 0) 1 else e.column;
    const caret_pad = caret_col - 1;
    const caret_len: usize = if (e.at_eof) 1 else @max(e.len, 1);

    try writer.print("{d: >4} | {s}\n", .{ e.line, line_text });
    try writer.writeAll("     | ");
    var i: usize = 0;
    while (i < caret_pad) : (i += 1) try writer.writeByte(' ');
    i = 0;
    while (i < caret_len) : (i += 1) try writer.writeByte('^');
    try writer.print(" {s}\n", .{e.message});
}

const LineRange = struct { start: usize, end: usize };

fn findLine(source: []const u8, line: usize) LineRange {
    var current_line: usize = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (current_line == line and source[i] == '\n') {
            return .{ .start = start, .end = i };
        }
        if (source[i] == '\n') {
            current_line += 1;
            start = i + 1;
        }
    }
    if (current_line == line) {
        return .{ .start = start, .end = source.len };
    }
    return .{ .start = source.len, .end = source.len };
}
