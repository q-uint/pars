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
        error.IncompleteEscape => "Incomplete escape sequence in character literal.",
        error.HexWrongLength => "Hex escape must be two digits: \\xNN.",
        error.HexInvalidDigit => "Invalid hex digit in escape sequence.",
        error.UnknownEscape => "Unknown escape sequence in character literal.",
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

/// Strip the surrounding quote delimiters from a string-literal lexeme,
/// accounting for an optional leading prefix (such as `i` on
/// case-insensitive strings) and the triple-quoted form.
pub fn stripStringDelimiters(lexeme: []const u8, prefix_len: usize) []const u8 {
    const body = lexeme[prefix_len..];
    const delim: usize = if (body.len >= 6 and
        std.mem.startsWith(u8, body, "\"\"\"") and
        std.mem.endsWith(u8, body, "\"\"\""))
        3
    else
        1;
    return body[delim .. body.len - delim];
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
    try std.testing.expectEqualStrings("abc", stripStringDelimiters("\"abc\"", 0));
}

test "stripStringDelimiters: with prefix" {
    try std.testing.expectEqualStrings("abc", stripStringDelimiters("i\"abc\"", 1));
}

test "stripStringDelimiters: triple-quoted" {
    try std.testing.expectEqualStrings("abc", stripStringDelimiters("\"\"\"abc\"\"\"", 0));
}
