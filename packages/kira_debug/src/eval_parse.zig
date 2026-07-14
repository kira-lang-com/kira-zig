//! Tokenizer and recursive-descent parser for the debugger's expression grammar.
//! Produces an arena-allocated `Node` tree consumed by `eval.zig`'s interpreter.
//! Grammar (lowest to highest precedence):
//!
//!   or         := and ( '||' and )*
//!   and        := not ( '&&' not )*
//!   not        := '!' not | comparison
//!   comparison := additive ( ( '==' | '!=' | '<' | '<=' | '>' | '>=' ) additive )?
//!   additive   := multiplicative ( ( '+' | '-' ) multiplicative )*
//!   mult       := unary ( ( '*' | '/' ) unary )*
//!   unary      := '-' unary | primary
//!   primary    := int | 'true' | 'false' | str | ident | '(' or ')'
//!
//! Comparison is deliberately non-associative (`a < b < c` is a syntax error),
//! matching most languages and keeping predicates unambiguous.
const std = @import("std");
const eval_types = @import("eval_types.zig");

const EvalError = eval_types.EvalError;

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

pub const TokenKind = enum {
    int_lit,
    str_lit,
    ident,
    kw_true,
    kw_false,
    plus,
    minus,
    star,
    slash,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    logic_and,
    logic_or,
    bang,
    lparen,
    rparen,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    /// For `int_lit`: the parsed value. Otherwise 0.
    int_val: i64 = 0,
    /// For `ident`: the name; for `str_lit`: the unquoted contents. Otherwise "".
    text: []const u8 = "",
};

pub fn tokenize(a: std.mem.Allocator, expr: []const u8) EvalError![]Token {
    var toks: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < expr.len) {
        const c = expr[i];
        // Whitespace.
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            i += 1;
            continue;
        }
        // Two-character operators first so `==` is not read as two `=`.
        if (i + 1 < expr.len) {
            const two = expr[i .. i + 2];
            if (std.mem.eql(u8, two, "==")) {
                try toks.append(a, .{ .kind = .eq });
                i += 2;
                continue;
            } else if (std.mem.eql(u8, two, "!=")) {
                try toks.append(a, .{ .kind = .ne });
                i += 2;
                continue;
            } else if (std.mem.eql(u8, two, "<=")) {
                try toks.append(a, .{ .kind = .le });
                i += 2;
                continue;
            } else if (std.mem.eql(u8, two, ">=")) {
                try toks.append(a, .{ .kind = .ge });
                i += 2;
                continue;
            } else if (std.mem.eql(u8, two, "&&")) {
                try toks.append(a, .{ .kind = .logic_and });
                i += 2;
                continue;
            } else if (std.mem.eql(u8, two, "||")) {
                try toks.append(a, .{ .kind = .logic_or });
                i += 2;
                continue;
            }
        }
        switch (c) {
            '+' => {
                try toks.append(a, .{ .kind = .plus });
                i += 1;
            },
            '-' => {
                try toks.append(a, .{ .kind = .minus });
                i += 1;
            },
            '*' => {
                try toks.append(a, .{ .kind = .star });
                i += 1;
            },
            '/' => {
                try toks.append(a, .{ .kind = .slash });
                i += 1;
            },
            '<' => {
                try toks.append(a, .{ .kind = .lt });
                i += 1;
            },
            '>' => {
                try toks.append(a, .{ .kind = .gt });
                i += 1;
            },
            '!' => {
                try toks.append(a, .{ .kind = .bang });
                i += 1;
            },
            '(' => {
                try toks.append(a, .{ .kind = .lparen });
                i += 1;
            },
            ')' => {
                try toks.append(a, .{ .kind = .rparen });
                i += 1;
            },
            '"' => {
                // String literal: contents up to the next quote. No escape processing
                // is needed for the debugger's simple predicates.
                const start = i + 1;
                var j = start;
                while (j < expr.len and expr[j] != '"') : (j += 1) {}
                if (j >= expr.len) return EvalError.SyntaxError; // unterminated
                try toks.append(a, .{ .kind = .str_lit, .text = expr[start..j] });
                i = j + 1;
            },
            '0'...'9' => {
                const start = i;
                while (i < expr.len and expr[i] >= '0' and expr[i] <= '9') : (i += 1) {}
                const n = std.fmt.parseInt(i64, expr[start..i], 10) catch return EvalError.SyntaxError;
                try toks.append(a, .{ .kind = .int_lit, .int_val = n });
            },
            'A'...'Z', 'a'...'z', '_' => {
                const start = i;
                while (i < expr.len and isIdentChar(expr[i])) : (i += 1) {}
                const word = expr[start..i];
                if (std.mem.eql(u8, word, "true")) {
                    try toks.append(a, .{ .kind = .kw_true });
                } else if (std.mem.eql(u8, word, "false")) {
                    try toks.append(a, .{ .kind = .kw_false });
                } else {
                    try toks.append(a, .{ .kind = .ident, .text = word });
                }
            },
            else => return EvalError.SyntaxError,
        }
    }
    try toks.append(a, .{ .kind = .eof });
    return toks.items;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
}

// ---------------------------------------------------------------------------
// AST
// ---------------------------------------------------------------------------

pub const Op = enum { add, sub, mul, div, eq, ne, lt, le, gt, ge, logic_and, logic_or };

pub const NodeKind = enum { int_lit, bool_lit, str_lit, ident, neg, not, binary };

pub const Node = struct {
    kind: NodeKind,
    int_val: i64 = 0,
    bool_val: bool = false,
    text: []const u8 = "",
    op: Op = .add,
    lhs: ?*Node = null,
    rhs: ?*Node = null,
};

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

const Parser = struct {
    a: std.mem.Allocator,
    toks: []Token,
    pos: usize = 0,

    fn peek(self: *Parser) TokenKind {
        return self.toks[self.pos].kind;
    }

    fn advance(self: *Parser) Token {
        const t = self.toks[self.pos];
        if (self.pos + 1 < self.toks.len) self.pos += 1;
        return t;
    }

    fn node(self: *Parser, n: Node) EvalError!*Node {
        const p = try self.a.create(Node);
        p.* = n;
        return p;
    }

    // or := and ( '||' and )*
    fn parseOr(self: *Parser) EvalError!*Node {
        var left = try self.parseAnd();
        while (self.peek() == .logic_or) {
            _ = self.advance();
            const right = try self.parseAnd();
            left = try self.node(.{ .kind = .binary, .op = .logic_or, .lhs = left, .rhs = right });
        }
        return left;
    }

    // and := not ( '&&' not )*
    fn parseAnd(self: *Parser) EvalError!*Node {
        var left = try self.parseNot();
        while (self.peek() == .logic_and) {
            _ = self.advance();
            const right = try self.parseNot();
            left = try self.node(.{ .kind = .binary, .op = .logic_and, .lhs = left, .rhs = right });
        }
        return left;
    }

    // not := '!' not | comparison
    fn parseNot(self: *Parser) EvalError!*Node {
        if (self.peek() == .bang) {
            _ = self.advance();
            const operand = try self.parseNot();
            return self.node(.{ .kind = .not, .lhs = operand });
        }
        return self.parseComparison();
    }

    // comparison := additive ( cmp additive )?  (non-associative)
    fn parseComparison(self: *Parser) EvalError!*Node {
        const left = try self.parseAdditive();
        const op: ?Op = switch (self.peek()) {
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => null,
        };
        if (op) |o| {
            _ = self.advance();
            const right = try self.parseAdditive();
            return self.node(.{ .kind = .binary, .op = o, .lhs = left, .rhs = right });
        }
        return left;
    }

    // additive := mult ( ( '+' | '-' ) mult )*
    fn parseAdditive(self: *Parser) EvalError!*Node {
        var left = try self.parseMultiplicative();
        while (true) {
            const op: Op = switch (self.peek()) {
                .plus => .add,
                .minus => .sub,
                else => break,
            };
            _ = self.advance();
            const right = try self.parseMultiplicative();
            left = try self.node(.{ .kind = .binary, .op = op, .lhs = left, .rhs = right });
        }
        return left;
    }

    // mult := unary ( ( '*' | '/' ) unary )*
    fn parseMultiplicative(self: *Parser) EvalError!*Node {
        var left = try self.parseUnary();
        while (true) {
            const op: Op = switch (self.peek()) {
                .star => .mul,
                .slash => .div,
                else => break,
            };
            _ = self.advance();
            const right = try self.parseUnary();
            left = try self.node(.{ .kind = .binary, .op = op, .lhs = left, .rhs = right });
        }
        return left;
    }

    // unary := '-' unary | primary
    fn parseUnary(self: *Parser) EvalError!*Node {
        if (self.peek() == .minus) {
            _ = self.advance();
            const operand = try self.parseUnary();
            return self.node(.{ .kind = .neg, .lhs = operand });
        }
        return self.parsePrimary();
    }

    // primary := int | 'true' | 'false' | str | ident | '(' or ')'
    fn parsePrimary(self: *Parser) EvalError!*Node {
        const t = self.advance();
        switch (t.kind) {
            .int_lit => return self.node(.{ .kind = .int_lit, .int_val = t.int_val }),
            .kw_true => return self.node(.{ .kind = .bool_lit, .bool_val = true }),
            .kw_false => return self.node(.{ .kind = .bool_lit, .bool_val = false }),
            .str_lit => return self.node(.{ .kind = .str_lit, .text = t.text }),
            .ident => return self.node(.{ .kind = .ident, .text = t.text }),
            .lparen => {
                const inner = try self.parseOr();
                if (self.peek() != .rparen) return EvalError.SyntaxError;
                _ = self.advance();
                return inner;
            },
            else => return EvalError.SyntaxError,
        }
    }
};

/// Tokenize and parse `expr` into an arena-allocated AST. All nodes and tokens are
/// allocated from `a`; the caller frees them by dropping the arena. Rejects any input
/// that does not parse to a single complete expression (trailing tokens are an error).
pub fn parse(a: std.mem.Allocator, expr: []const u8) EvalError!*Node {
    const toks = try tokenize(a, expr);
    var p = Parser{ .a = a, .toks = toks };
    const root = try p.parseOr();
    if (p.peek() != .eof) return EvalError.SyntaxError;
    return root;
}
