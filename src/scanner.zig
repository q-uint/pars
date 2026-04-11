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
    /// A string literal in double quotes, e.g. "HTTP/".
    string,
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
    lexeme: []const u8,
    line: usize,
};

const Scanner = struct {
    start: usize,
    current: usize,
    line: usize,
    source: []const u8,
};

var scanner: Scanner = undefined;

pub fn init(source: []const u8) void {
    scanner.source = source;
    scanner.start = 0;
    scanner.current = 0;
    scanner.line = 1;
}

pub fn scanToken() Token {
    skipWhitespace();
    scanner.start = scanner.current;

    if (isAtEnd()) return makeToken(.eof);

    const c = advance();
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
    while (peek() != '"' and !isAtEnd()) {
        if (peek() == '\n') scanner.line += 1;
        _ = advance();
    }

    if (isAtEnd()) return errorToken("Unterminated string.");

    _ = advance();
    return makeToken(.string);
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
        .line = scanner.line,
    };
}

fn errorToken(message: []const u8) Token {
    return .{
        .type = .err,
        .lexeme = message,
        .line = scanner.line,
    };
}
