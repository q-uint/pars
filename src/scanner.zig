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
    /// ';' - terminates a rule declaration or where-clause sub-rule.
    semicolon,
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

    /// 'let' - names the span matched by a sub-pattern within a rule body.
    kw_let,
    /// 'grammar' - opens a named collection of related rules.
    kw_grammar,
    /// 'extends' - marks a grammar as inheriting rules from a parent grammar.
    kw_extends,
    /// 'super' - invokes the parent grammar's definition of a rule.
    kw_super,
    /// 'use' - imports rules from a module into the current grammar.
    kw_use,
    /// 'where' - introduces locally-scoped rule definitions for the enclosing rule.
    kw_where,
    /// 'end' - closes a 'where' block and terminates the enclosing rule declaration.
    kw_end,

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

pub const Scanner = struct {
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

    pub fn init(source: []const u8) Scanner {
        return .{
            .source = source,
            .start = 0,
            .current = 0,
            .line = 1,
            .line_start = 0,
            .token_line = 1,
            .token_col = 1,
        };
    }

    pub fn scanToken(self: *Scanner) Token {
        self.skipWhitespace();
        self.start = self.current;
        self.token_line = self.line;
        self.token_col = self.start - self.line_start + 1;

        if (self.isAtEnd()) return self.makeToken(.eof);

        const c = self.advance();

        if (c == 'i' and self.peek() == '"') {
            _ = self.advance();
            const tok = self.string();
            if (tok.type == .err) return tok;
            return self.makeToken(.string_i);
        }

        if (isAlpha(c)) return self.identifier();

        switch (c) {
            '(' => return self.makeToken(.left_paren),
            ')' => return self.makeToken(.right_paren),
            '[' => return self.makeToken(.left_bracket),
            ']' => return self.makeToken(.right_bracket),
            '{' => return self.makeToken(.left_brace),
            '}' => return self.makeToken(.right_brace),
            ',' => return self.makeToken(.comma),
            ';' => return self.makeToken(.semicolon),
            ':' => return self.makeToken(.colon),
            '.' => return self.makeToken(.dot),
            '%' => return self.makeToken(.percent),
            '^' => return self.makeToken(.caret),
            '-' => return self.makeToken(.minus),
            '/' => return self.makeToken(.slash),
            '|' => return self.makeToken(.pipe),
            '*' => return self.makeToken(.star),
            '+' => return self.makeToken(.plus),
            '?' => return self.makeToken(.question),
            '!' => return self.makeToken(.bang),
            '&' => return self.makeToken(.amp),
            '=' => return self.makeToken(if (self.match('>')) .arrow else .equal),
            '"' => return self.string(),
            '\'' => return self.charLiteral(),
            else => return self.errorToken("Unexpected character."),
        }
    }

    fn isAtEnd(self: *const Scanner) bool {
        return self.current >= self.source.len;
    }

    fn advance(self: *Scanner) u8 {
        const c = self.source[self.current];
        self.current += 1;
        return c;
    }

    fn peek(self: *const Scanner) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    fn peekNext(self: *const Scanner) u8 {
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    fn match(self: *Scanner, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;
        self.current += 1;
        return true;
    }

    fn identifier(self: *Scanner) Token {
        while (isAlpha(self.peek()) or isDigit(self.peek())) _ = self.advance();
        return self.makeToken(self.identifierType());
    }

    fn identifierType(self: *const Scanner) TokenType {
        const lexeme = self.source[self.start..self.current];
        switch (lexeme[0]) {
            'e' => return switch (self.source[self.start..self.current].len) {
                3 => self.checkKeyword(1, "nd", .kw_end),
                7 => self.checkKeyword(1, "xtends", .kw_extends),
                else => .identifier,
            },
            'g' => return self.checkKeyword(1, "rammar", .kw_grammar),
            'l' => return self.checkKeyword(1, "et", .kw_let),
            's' => return self.checkKeyword(1, "uper", .kw_super),
            'u' => return self.checkKeyword(1, "se", .kw_use),
            'w' => return self.checkKeyword(1, "here", .kw_where),
            else => return .identifier,
        }
    }

    fn checkKeyword(self: *const Scanner, kw_start: usize, rest: []const u8, token_type: TokenType) TokenType {
        const lexeme = self.source[self.start..self.current];
        if (lexeme.len == kw_start + rest.len and std.mem.eql(u8, lexeme[kw_start..], rest)) {
            return token_type;
        }
        return .identifier;
    }

    fn string(self: *Scanner) Token {
        if (self.peek() == '"' and self.peekNext() == '"') {
            _ = self.advance();
            _ = self.advance();
            return self.tripleString();
        }

        while (self.peek() != '"' and !self.isAtEnd()) {
            if (self.peek() == '\n') {
                self.line += 1;
                self.line_start = self.current + 1;
            }
            _ = self.advance();
        }

        if (self.isAtEnd()) return self.errorToken("Unterminated string.");

        _ = self.advance();
        return self.makeToken(.string);
    }

    fn tripleString(self: *Scanner) Token {
        while (!self.isAtEnd()) {
            if (self.peek() == '"' and self.peekNext() == '"' and
                self.current + 2 < self.source.len and
                self.source[self.current + 2] == '"')
            {
                _ = self.advance();
                _ = self.advance();
                _ = self.advance();
                return self.makeToken(.string);
            }
            if (self.peek() == '\n') {
                self.line += 1;
                self.line_start = self.current + 1;
            }
            _ = self.advance();
        }
        return self.errorToken("Unterminated triple-quoted string.");
    }

    fn charLiteral(self: *Scanner) Token {
        while (self.peek() != '\'' and !self.isAtEnd()) {
            if (self.peek() == '\n') return self.errorToken("Unterminated character literal.");
            _ = self.advance();
        }

        if (self.isAtEnd()) return self.errorToken("Unterminated character literal.");

        _ = self.advance();
        return self.makeToken(.char);
    }

    fn skipWhitespace(self: *Scanner) void {
        while (true) {
            switch (self.peek()) {
                ' ', '\r', '\t' => {
                    _ = self.advance();
                },
                '\n' => {
                    self.line += 1;
                    _ = self.advance();
                    self.line_start = self.current;
                },
                '-' => {
                    if (self.peekNext() == '-') {
                        while (self.peek() != '\n' and !self.isAtEnd()) _ = self.advance();
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn makeToken(self: *const Scanner, token_type: TokenType) Token {
        return .{
            .type = token_type,
            .lexeme = self.source[self.start..self.current],
            .line = self.token_line,
            .column = self.token_col,
            .start = self.start,
            .len = self.current - self.start,
        };
    }

    fn errorToken(self: *const Scanner, message: []const u8) Token {
        return .{
            .type = .err,
            .lexeme = message,
            .line = self.token_line,
            .column = self.token_col,
            .start = self.start,
            .len = self.current - self.start,
        };
    }
};

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        c == '_';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

const Expected = struct { type: TokenType, lexeme: []const u8 };

fn expectTokens(source: []const u8, expected: []const Expected) !void {
    var s = Scanner.init(source);
    for (expected) |e| {
        const tok = s.scanToken();
        try std.testing.expectEqual(e.type, tok.type);
        try std.testing.expectEqualStrings(e.lexeme, tok.lexeme);
    }
    const tail = s.scanToken();
    try std.testing.expectEqual(TokenType.eof, tail.type);
}

test "empty source yields eof" {
    try expectTokens("", &.{});
}

test "whitespace only yields eof" {
    try expectTokens("   \t\r\n  ", &.{});
}

test "line comment is skipped" {
    try expectTokens("-- nothing here\nwhere", &.{
        .{ .type = .kw_where, .lexeme = "where" },
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
    try expectTokens("use let grammar extends super where end", &.{
        .{ .type = .kw_use, .lexeme = "use" },
        .{ .type = .kw_let, .lexeme = "let" },
        .{ .type = .kw_grammar, .lexeme = "grammar" },
        .{ .type = .kw_extends, .lexeme = "extends" },
        .{ .type = .kw_super, .lexeme = "super" },
        .{ .type = .kw_where, .lexeme = "where" },
        .{ .type = .kw_end, .lexeme = "end" },
    });
}

test "near-miss use is identifier" {
    try expectTokens("user used", &.{
        .{ .type = .identifier, .lexeme = "user" },
        .{ .type = .identifier, .lexeme = "used" },
    });
}

test "near-miss end is identifier" {
    try expectTokens("endo ended", &.{
        .{ .type = .identifier, .lexeme = "endo" },
        .{ .type = .identifier, .lexeme = "ended" },
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
    var s = Scanner.init("\"\"\"a\nb\"\"\"");
    const tok = s.scanToken();
    try std.testing.expectEqual(TokenType.string, tok.type);
    try std.testing.expectEqualStrings("\"\"\"a\nb\"\"\"", tok.lexeme);
    try std.testing.expectEqual(@as(usize, 2), s.line);
}

test "case-insensitive string literal" {
    try expectTokens("i\"HTTP/\"", &.{
        .{ .type = .string_i, .lexeme = "i\"HTTP/\"" },
    });
}

test "unterminated string produces error" {
    var s = Scanner.init("\"oops");
    const tok = s.scanToken();
    try std.testing.expectEqual(TokenType.err, tok.type);
    try std.testing.expectEqualStrings("Unterminated string.", tok.lexeme);
}

test "unterminated triple-quoted string" {
    var s = Scanner.init("\"\"\"oops");
    const tok = s.scanToken();
    try std.testing.expectEqual(TokenType.err, tok.type);
    try std.testing.expectEqualStrings("Unterminated triple-quoted string.", tok.lexeme);
}

test "character literal" {
    try expectTokens("'a'", &.{
        .{ .type = .char, .lexeme = "'a'" },
    });
}

test "unterminated character literal at eof" {
    var s = Scanner.init("'a");
    const tok = s.scanToken();
    try std.testing.expectEqual(TokenType.err, tok.type);
    try std.testing.expectEqualStrings("Unterminated character literal.", tok.lexeme);
}

test "character literal rejects newline" {
    var s = Scanner.init("'\n'");
    const tok = s.scanToken();
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
    var s = Scanner.init("a\nb");
    const first = s.scanToken();
    try std.testing.expectEqual(@as(usize, 1), first.line);
    const second = s.scanToken();
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
        "kv = ident \"=\" ident;",
        &.{
            .{ .type = .identifier, .lexeme = "kv" },
            .{ .type = .equal, .lexeme = "=" },
            .{ .type = .identifier, .lexeme = "ident" },
            .{ .type = .string, .lexeme = "\"=\"" },
            .{ .type = .identifier, .lexeme = "ident" },
            .{ .type = .semicolon, .lexeme = ";" },
        },
    );
}
