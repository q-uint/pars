const std = @import("std");

pub const TokenType = enum {
    /// '(' - groups a sub-expression.
    left_paren,
    /// ')' - closes a grouped sub-expression.
    right_paren,
    /// '[' - opens a charset expression.
    left_bracket,
    /// ']' - closes a charset expression.
    right_bracket,
    /// '{' - opens a semantic action body.
    left_brace,
    /// '}' - closes a semantic action body.
    right_brace,
    /// ',' - separates parameters in parameterized rules and fields in actions.
    comma,
    /// ':' - separates keys from values inside action bodies.
    colon,
    /// '=' - binds a rule name to its body, or a let-capture to a pattern.
    equal,
    /// '-' - charset range separator, e.g. the minus in ['a'-'z'].
    minus,
    /// '.' - any-byte wildcard.
    dot,
    /// '%' - separator-list sugar: 'A % B' desugars to 'A (B A)*'.
    percent,
    /// '^' - cut marker; with a following string, attaches a failure label.
    caret,

    /// '/' - ordered choice: try the left alternative, then the right on failure.
    slash,
    /// '|' - ordered choice alternative spelling used in grammar module bodies.
    pipe,
    /// '*' - zero-or-more quantifier.
    star,
    /// '+' - one-or-more quantifier.
    plus,
    /// '?' - optional quantifier.
    question,
    /// '!' - negative lookahead: succeeds when the following pattern fails.
    bang,
    /// '&' - positive lookahead: succeeds without consuming input.
    amp,

    /// '=>' - introduces a semantic action attached to a rule body.
    arrow,

    /// An identifier: a rule name, a let-binding name, or a field key.
    identifier,
    /// A string literal in double quotes, e.g. "HTTP/". The triple-quoted
    /// form """...""" allows embedded newlines and skips escape processing.
    string,
    /// A case-insensitive string literal with an 'i' prefix, e.g. i"HTTP/".
    /// Matches the literal regardless of ASCII letter case.
    string_i,
    /// A character literal in single quotes, e.g. 'a'.
    char,

    /// 'rule' - top-level rule declaration keyword.
    kw_rule,
    /// 'let' - names the span matched by a sub-pattern within a rule body.
    kw_let,
    /// 'grammar' - opens a named collection of related rules.
    kw_grammar,
    /// 'extends' - marks a grammar as inheriting rules from a parent grammar.
    kw_extends,
    /// 'super' - invokes the parent grammar's definition of a rule.
    kw_super,

    /// An unrecognized or malformed lexeme; carries the diagnostic message.
    err,
    /// End of input.
    eof,
};

pub const Token = struct {
    type: TokenType,
    /// For normal tokens, a slice of the source covering the lexeme.
    /// For `.err` tokens, a static diagnostic message string.
    lexeme: []const u8,
    line: usize,
    /// 1-based column of the first byte of the token on its line.
    column: usize,
    /// Byte offset of the first byte of the token into the source.
    start: usize,
    /// Length in bytes of the source span the token covers. For `.err`
    /// tokens this is still the source span that triggered the error,
    /// not the length of the `lexeme` message.
    len: usize,
};

const Scanner = struct {
    start: usize,
    current: usize,
    line: usize,
    /// Byte offset of the first byte of the current line, used to
    /// derive columns for diagnostics.
    line_start: usize,
    /// Snapshot of `line` taken when a token starts scanning. Multi-
    /// line tokens (e.g. triple-quoted strings) would otherwise report
    /// the line they end on, not the line they begin on.
    token_line: usize,
    /// Snapshot of the token's starting column, taken at the same time.
    token_col: usize,
    source: []const u8,
};

var scanner: Scanner = undefined;

pub fn init(source: []const u8) void {
    scanner.source = source;
    scanner.start = 0;
    scanner.current = 0;
    scanner.line = 1;
    scanner.line_start = 0;
    scanner.token_line = 1;
    scanner.token_col = 1;
}

pub fn getSource() []const u8 {
    return scanner.source;
}

pub fn scanToken() Token {
    skipWhitespace();
    scanner.start = scanner.current;
    scanner.token_line = scanner.line;
    scanner.token_col = scanner.start - scanner.line_start + 1;

    if (isAtEnd()) return makeToken(.eof);

    const c = advance();

    if (c == 'i' and peek() == '"') {
        _ = advance();
        const tok = string();
        if (tok.type == .err) return tok;
        return makeToken(.string_i);
    }

    if (isAlpha(c)) return identifier();

    switch (c) {
        '(' => return makeToken(.left_paren),
        ')' => return makeToken(.right_paren),
        '[' => return makeToken(.left_bracket),
        ']' => return makeToken(.right_bracket),
        '{' => return makeToken(.left_brace),
        '}' => return makeToken(.right_brace),
        ',' => return makeToken(.comma),
        ':' => return makeToken(.colon),
        '.' => return makeToken(.dot),
        '%' => return makeToken(.percent),
        '^' => return makeToken(.caret),
        '-' => return makeToken(.minus),
        '/' => return makeToken(.slash),
        '|' => return makeToken(.pipe),
        '*' => return makeToken(.star),
        '+' => return makeToken(.plus),
        '?' => return makeToken(.question),
        '!' => return makeToken(.bang),
        '&' => return makeToken(.amp),
        '=' => return makeToken(if (match('>')) .arrow else .equal),
        '"' => return string(),
        '\'' => return charLiteral(),
        else => return errorToken("Unexpected character."),
    }
}

fn isAtEnd() bool {
    return scanner.current >= scanner.source.len;
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        c == '_';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn advance() u8 {
    const c = scanner.source[scanner.current];
    scanner.current += 1;
    return c;
}

fn peek() u8 {
    if (isAtEnd()) return 0;
    return scanner.source[scanner.current];
}

fn peekNext() u8 {
    if (scanner.current + 1 >= scanner.source.len) return 0;
    return scanner.source[scanner.current + 1];
}

fn match(expected: u8) bool {
    if (isAtEnd()) return false;
    if (scanner.source[scanner.current] != expected) return false;
    scanner.current += 1;
    return true;
}

fn identifier() Token {
    while (isAlpha(peek()) or isDigit(peek())) _ = advance();
    return makeToken(identifierType());
}

fn identifierType() TokenType {
    const lexeme = scanner.source[scanner.start..scanner.current];
    switch (lexeme[0]) {
        'e' => return checkKeyword(1, "xtends", .kw_extends),
        'g' => return checkKeyword(1, "rammar", .kw_grammar),
        'l' => return checkKeyword(1, "et", .kw_let),
        'r' => return checkKeyword(1, "ule", .kw_rule),
        's' => return checkKeyword(1, "uper", .kw_super),
        else => return .identifier,
    }
}

fn checkKeyword(start: usize, rest: []const u8, token_type: TokenType) TokenType {
    const lexeme = scanner.source[scanner.start..scanner.current];
    if (lexeme.len == start + rest.len and std.mem.eql(u8, lexeme[start..], rest)) {
        return token_type;
    }
    return .identifier;
}

fn string() Token {
    if (peek() == '"' and peekNext() == '"') {
        _ = advance();
        _ = advance();
        return tripleString();
    }

    while (peek() != '"' and !isAtEnd()) {
        if (peek() == '\n') {
            scanner.line += 1;
            scanner.line_start = scanner.current + 1;
        }
        _ = advance();
    }

    if (isAtEnd()) return errorToken("Unterminated string.");

    _ = advance();
    return makeToken(.string);
}

fn tripleString() Token {
    while (!isAtEnd()) {
        if (peek() == '"' and peekNext() == '"' and
            scanner.current + 2 < scanner.source.len and
            scanner.source[scanner.current + 2] == '"')
        {
            _ = advance();
            _ = advance();
            _ = advance();
            return makeToken(.string);
        }
        if (peek() == '\n') {
            scanner.line += 1;
            scanner.line_start = scanner.current + 1;
        }
        _ = advance();
    }
    return errorToken("Unterminated triple-quoted string.");
}

fn charLiteral() Token {
    while (peek() != '\'' and !isAtEnd()) {
        if (peek() == '\n') return errorToken("Unterminated character literal.");
        _ = advance();
    }

    if (isAtEnd()) return errorToken("Unterminated character literal.");

    _ = advance();
    return makeToken(.char);
}

fn skipWhitespace() void {
    while (true) {
        switch (peek()) {
            ' ', '\r', '\t' => {
                _ = advance();
            },
            '\n' => {
                scanner.line += 1;
                _ = advance();
                scanner.line_start = scanner.current;
            },
            '-' => {
                if (peekNext() == '-') {
                    while (peek() != '\n' and !isAtEnd()) _ = advance();
                } else {
                    return;
                }
            },
            else => return,
        }
    }
}

fn makeToken(token_type: TokenType) Token {
    return .{
        .type = token_type,
        .lexeme = scanner.source[scanner.start..scanner.current],
        .line = scanner.token_line,
        .column = scanner.token_col,
        .start = scanner.start,
        .len = scanner.current - scanner.start,
    };
}

fn errorToken(message: []const u8) Token {
    return .{
        .type = .err,
        .lexeme = message,
        .line = scanner.token_line,
        .column = scanner.token_col,
        .start = scanner.start,
        .len = scanner.current - scanner.start,
    };
}

const Expected = struct { type: TokenType, lexeme: []const u8 };

fn expectTokens(source: []const u8, expected: []const Expected) !void {
    init(source);
    for (expected) |e| {
        const tok = scanToken();
        try std.testing.expectEqual(e.type, tok.type);
        try std.testing.expectEqualStrings(e.lexeme, tok.lexeme);
    }
    const tail = scanToken();
    try std.testing.expectEqual(TokenType.eof, tail.type);
}

test "empty source yields eof" {
    try expectTokens("", &.{});
}

test "whitespace only yields eof" {
    try expectTokens("   \t\r\n  ", &.{});
}

test "line comment is skipped" {
    try expectTokens("-- nothing here\nrule", &.{
        .{ .type = .kw_rule, .lexeme = "rule" },
    });
}

test "single-character punctuation" {
    try expectTokens("()[]{},:.%^/|*+?!&", &.{
        .{ .type = .left_paren, .lexeme = "(" },
        .{ .type = .right_paren, .lexeme = ")" },
        .{ .type = .left_bracket, .lexeme = "[" },
        .{ .type = .right_bracket, .lexeme = "]" },
        .{ .type = .left_brace, .lexeme = "{" },
        .{ .type = .right_brace, .lexeme = "}" },
        .{ .type = .comma, .lexeme = "," },
        .{ .type = .colon, .lexeme = ":" },
        .{ .type = .dot, .lexeme = "." },
        .{ .type = .percent, .lexeme = "%" },
        .{ .type = .caret, .lexeme = "^" },
        .{ .type = .slash, .lexeme = "/" },
        .{ .type = .pipe, .lexeme = "|" },
        .{ .type = .star, .lexeme = "*" },
        .{ .type = .plus, .lexeme = "+" },
        .{ .type = .question, .lexeme = "?" },
        .{ .type = .bang, .lexeme = "!" },
        .{ .type = .amp, .lexeme = "&" },
    });
}

test "equal vs arrow" {
    try expectTokens("= =>", &.{
        .{ .type = .equal, .lexeme = "=" },
        .{ .type = .arrow, .lexeme = "=>" },
    });
}

test "keywords" {
    try expectTokens("rule let grammar extends super", &.{
        .{ .type = .kw_rule, .lexeme = "rule" },
        .{ .type = .kw_let, .lexeme = "let" },
        .{ .type = .kw_grammar, .lexeme = "grammar" },
        .{ .type = .kw_extends, .lexeme = "extends" },
        .{ .type = .kw_super, .lexeme = "super" },
    });
}

test "near-miss keywords are identifiers" {
    try expectTokens("ruler letter grammars extend supers", &.{
        .{ .type = .identifier, .lexeme = "ruler" },
        .{ .type = .identifier, .lexeme = "letter" },
        .{ .type = .identifier, .lexeme = "grammars" },
        .{ .type = .identifier, .lexeme = "extend" },
        .{ .type = .identifier, .lexeme = "supers" },
    });
}

test "plain string literal" {
    try expectTokens("\"HTTP/\"", &.{
        .{ .type = .string, .lexeme = "\"HTTP/\"" },
    });
}

test "triple-quoted string allows newlines" {
    try expectTokens("\"\"\"a\nb\"\"\"", &.{
        .{ .type = .string, .lexeme = "\"\"\"a\nb\"\"\"" },
    });
    try std.testing.expectEqual(@as(usize, 2), scanner.line);
}

test "case-insensitive string literal" {
    try expectTokens("i\"HTTP/\"", &.{
        .{ .type = .string_i, .lexeme = "i\"HTTP/\"" },
    });
}

test "unterminated string produces error" {
    init("\"oops");
    const tok = scanToken();
    try std.testing.expectEqual(TokenType.err, tok.type);
    try std.testing.expectEqualStrings("Unterminated string.", tok.lexeme);
}

test "unterminated triple-quoted string" {
    init("\"\"\"oops");
    const tok = scanToken();
    try std.testing.expectEqual(TokenType.err, tok.type);
    try std.testing.expectEqualStrings("Unterminated triple-quoted string.", tok.lexeme);
}

test "character literal" {
    try expectTokens("'a'", &.{
        .{ .type = .char, .lexeme = "'a'" },
    });
}

test "unterminated character literal at eof" {
    init("'a");
    const tok = scanToken();
    try std.testing.expectEqual(TokenType.err, tok.type);
    try std.testing.expectEqualStrings("Unterminated character literal.", tok.lexeme);
}

test "character literal rejects newline" {
    init("'\n'");
    const tok = scanToken();
    try std.testing.expectEqual(TokenType.err, tok.type);
}

test "minus preserved outside of comment" {
    try expectTokens("'0'-'9'", &.{
        .{ .type = .char, .lexeme = "'0'" },
        .{ .type = .minus, .lexeme = "-" },
        .{ .type = .char, .lexeme = "'9'" },
    });
}

test "identifier starting with i is not a case-insensitive string" {
    try expectTokens("i ix", &.{
        .{ .type = .identifier, .lexeme = "i" },
        .{ .type = .identifier, .lexeme = "ix" },
    });
}

test "newline bumps line counter" {
    init("a\nb");
    const first = scanToken();
    try std.testing.expectEqual(@as(usize, 1), first.line);
    const second = scanToken();
    try std.testing.expectEqual(@as(usize, 2), second.line);
}

test "cut with label is two tokens" {
    try expectTokens("^\"expected rparen\"", &.{
        .{ .type = .caret, .lexeme = "^" },
        .{ .type = .string, .lexeme = "\"expected rparen\"" },
    });
}

test "full rule body tokenizes" {
    try expectTokens(
        "rule kv = let k = ident \"=\" let v = ident => { key: k, value: v }",
        &.{
            .{ .type = .kw_rule, .lexeme = "rule" },
            .{ .type = .identifier, .lexeme = "kv" },
            .{ .type = .equal, .lexeme = "=" },
            .{ .type = .kw_let, .lexeme = "let" },
            .{ .type = .identifier, .lexeme = "k" },
            .{ .type = .equal, .lexeme = "=" },
            .{ .type = .identifier, .lexeme = "ident" },
            .{ .type = .string, .lexeme = "\"=\"" },
            .{ .type = .kw_let, .lexeme = "let" },
            .{ .type = .identifier, .lexeme = "v" },
            .{ .type = .equal, .lexeme = "=" },
            .{ .type = .identifier, .lexeme = "ident" },
            .{ .type = .arrow, .lexeme = "=>" },
            .{ .type = .left_brace, .lexeme = "{" },
            .{ .type = .identifier, .lexeme = "key" },
            .{ .type = .colon, .lexeme = ":" },
            .{ .type = .identifier, .lexeme = "k" },
            .{ .type = .comma, .lexeme = "," },
            .{ .type = .identifier, .lexeme = "value" },
            .{ .type = .colon, .lexeme = ":" },
            .{ .type = .identifier, .lexeme = "v" },
            .{ .type = .right_brace, .lexeme = "}" },
        },
    );
}
