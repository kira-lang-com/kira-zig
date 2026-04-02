const Span = @import("kira_source").Span;

pub const TokenKind = enum {
    eof,
    identifier,
    integer,
    string,
    kw_function,
    kw_let,
    kw_return,
    at_sign,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    semicolon,
    comma,
    equal,
    plus,
};

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    span: Span,
};
