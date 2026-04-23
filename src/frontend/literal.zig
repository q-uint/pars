const std = @import("std");

// Errors returned by extractCharByte. Each maps to a human-readable
// diagnostic via errorMessage so callers can surface them through
// whatever reporting mechanism they own.
pub const ExtractError = error{
    Empty,
    MultiByte,
    IncompleteEscape,
    HexWrongLength,
    HexInvalidDigit,
    UnknownEscape,
};

pub fn errorMessage(e: ExtractError) []const u8 {
    return switch (e) {
        error.Empty => "Empty character literal.",
        error.MultiByte => "Character literal must be a single byte.",
        error.IncompleteEscape => "Incomplete escape sequence.",
        error.HexWrongLength => "Hex escape must be two digits: \\xNN.",
        error.HexInvalidDigit => "Invalid hex digit in escape sequence.",
        error.UnknownEscape => "Unknown escape sequence.",
    };
}

/// Decode a character-literal lexeme (e.g. `'a'`, `'\n'`, `'\x41'`) into
/// the single byte it denotes. The lexeme must include its surrounding
/// single quotes.
pub fn extractCharByte(lexeme: []const u8) ExtractError!u8 {
    const inner = lexeme[1 .. lexeme.len - 1];

    if (inner.len == 0) return error.Empty;

    if (inner[0] != '\\') {
        if (inner.len != 1) return error.MultiByte;
        return inner[0];
    }

    if (inner.len < 2) return error.IncompleteEscape;
    switch (inner[1]) {
        'n' => return '\n',
        'r' => return '\r',
        't' => return '\t',
        '\\' => return '\\',
        '\'' => return '\'',
        'x' => {
            if (inner.len != 4) return error.HexWrongLength;
            const hi = std.fmt.charToDigit(inner[2], 16) catch return error.HexInvalidDigit;
            const lo = std.fmt.charToDigit(inner[3], 16) catch return error.HexInvalidDigit;
            return (hi << 4) | lo;
        },
        else => return error.UnknownEscape,
    }
}

pub const StrippedString = struct {
    /// The lexeme with quote delimiters (and any prefix) removed.
    body: []const u8,
    /// Whether the source used the triple-quoted form. Triple-quoted
    /// strings are raw: the compiler emits `body` verbatim. Single-
    /// quoted strings go through `decodeStringBody` to resolve escape
    /// sequences into the actual bytes to match.
    triple_quoted: bool,
};

/// Strip the surrounding quote delimiters from a string-literal lexeme,
/// accounting for an optional leading prefix (such as `i` on
/// case-insensitive strings) and the triple-quoted form.
pub fn stripStringDelimiters(lexeme: []const u8, prefix_len: usize) StrippedString {
    const body = lexeme[prefix_len..];
    const triple = body.len >= 6 and
        std.mem.startsWith(u8, body, "\"\"\"") and
        std.mem.endsWith(u8, body, "\"\"\"");
    const delim: usize = if (triple) 3 else 1;
    return .{ .body = body[delim .. body.len - delim], .triple_quoted = triple };
}

/// Decode escape sequences in a single-quoted string-literal body into
/// the bytes the runtime should match. The returned slice is owned by
/// the caller. Triple-quoted strings are raw — do not pass their body
/// through this function.
///
/// Recognized escapes: `\n`, `\r`, `\t`, `\\`, `\'`, `\"`, `\xNN`.
/// Anything else returns `ExtractError` so the caller can surface a
/// diagnostic.
pub fn decodeStringBody(
    allocator: std.mem.Allocator,
    body: []const u8,
) (ExtractError || std.mem.Allocator.Error)![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, body.len);

    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c != '\\') {
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (i + 1 >= body.len) return error.IncompleteEscape;
        switch (body[i + 1]) {
            'n' => {
                try out.append(allocator, '\n');
                i += 2;
            },
            'r' => {
                try out.append(allocator, '\r');
                i += 2;
            },
            't' => {
                try out.append(allocator, '\t');
                i += 2;
            },
            '\\' => {
                try out.append(allocator, '\\');
                i += 2;
            },
            '\'' => {
                try out.append(allocator, '\'');
                i += 2;
            },
            '"' => {
                try out.append(allocator, '"');
                i += 2;
            },
            'x' => {
                if (i + 4 > body.len) return error.HexWrongLength;
                const hi = std.fmt.charToDigit(body[i + 2], 16) catch return error.HexInvalidDigit;
                const lo = std.fmt.charToDigit(body[i + 3], 16) catch return error.HexInvalidDigit;
                try out.append(allocator, (hi << 4) | lo);
                i += 4;
            },
            else => return error.UnknownEscape,
        }
    }
    return out.toOwnedSlice(allocator);
}

test "extractCharByte: plain byte" {
    try std.testing.expectEqual(@as(u8, 'a'), try extractCharByte("'a'"));
}

test "extractCharByte: escape sequences" {
    try std.testing.expectEqual(@as(u8, '\n'), try extractCharByte("'\\n'"));
    try std.testing.expectEqual(@as(u8, '\r'), try extractCharByte("'\\r'"));
    try std.testing.expectEqual(@as(u8, '\t'), try extractCharByte("'\\t'"));
    try std.testing.expectEqual(@as(u8, '\\'), try extractCharByte("'\\\\'"));
    try std.testing.expectEqual(@as(u8, '\''), try extractCharByte("'\\''"));
}

test "extractCharByte: hex escape" {
    try std.testing.expectEqual(@as(u8, 0x41), try extractCharByte("'\\x41'"));
    try std.testing.expectEqual(@as(u8, 0x00), try extractCharByte("'\\x00'"));
}

test "extractCharByte: errors" {
    try std.testing.expectError(error.Empty, extractCharByte("''"));
    try std.testing.expectError(error.UnknownEscape, extractCharByte("'\\q'"));
    try std.testing.expectError(error.HexInvalidDigit, extractCharByte("'\\xZZ'"));
    try std.testing.expectError(error.HexWrongLength, extractCharByte("'\\x4'"));
}

test "stripStringDelimiters: plain" {
    const s = stripStringDelimiters("\"abc\"", 0);
    try std.testing.expectEqualStrings("abc", s.body);
    try std.testing.expect(!s.triple_quoted);
}

test "stripStringDelimiters: with prefix" {
    const s = stripStringDelimiters("i\"abc\"", 1);
    try std.testing.expectEqualStrings("abc", s.body);
    try std.testing.expect(!s.triple_quoted);
}

test "stripStringDelimiters: triple-quoted" {
    const s = stripStringDelimiters("\"\"\"abc\"\"\"", 0);
    try std.testing.expectEqualStrings("abc", s.body);
    try std.testing.expect(s.triple_quoted);
}

test "decodeStringBody: plain bytes pass through" {
    const out = try decodeStringBody(std.testing.allocator, "abc");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("abc", out);
}

test "decodeStringBody: named escapes" {
    const out = try decodeStringBody(std.testing.allocator, "a\\nb\\tc\\r\\\\\\'\\\"");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, "a\nb\tc\r\\'\"", out);
}

test "decodeStringBody: hex escape" {
    const out = try decodeStringBody(std.testing.allocator, "\\x41BC");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("ABC", out);
}

test "decodeStringBody: hex escape at end" {
    const out = try decodeStringBody(std.testing.allocator, "pre\\x00");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, "pre\x00", out);
}

test "decodeStringBody: empty body" {
    const out = try decodeStringBody(std.testing.allocator, "");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "decodeStringBody: unknown escape errors" {
    try std.testing.expectError(error.UnknownEscape, decodeStringBody(std.testing.allocator, "\\q"));
}

test "decodeStringBody: incomplete trailing backslash" {
    try std.testing.expectError(error.IncompleteEscape, decodeStringBody(std.testing.allocator, "abc\\"));
}

test "decodeStringBody: hex too short" {
    try std.testing.expectError(error.HexWrongLength, decodeStringBody(std.testing.allocator, "\\x4"));
}

test "decodeStringBody: hex invalid digit" {
    try std.testing.expectError(error.HexInvalidDigit, decodeStringBody(std.testing.allocator, "\\xZZ"));
}
