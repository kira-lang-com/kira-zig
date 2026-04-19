const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source = @import("kira_source");
const syntax = @import("kira_ksl_syntax_model");

pub fn tokenize(
    allocator: std.mem.Allocator,
    input: *const source.SourceFile,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
) ![]const syntax.Token {
    var lexer = Lexer{
        .allocator = allocator,
        .input = input,
        .diagnostics = out_diagnostics,
    };
    return lexer.lexAll();
}

const Lexer = struct {
    allocator: std.mem.Allocator,
    input: *const source.SourceFile,
    diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
    index: usize = 0,

    fn lexAll(self: *Lexer) ![]const syntax.Token {
        var tokens = std.array_list.Managed(syntax.Token).init(self.allocator);

        while (!self.done()) {
            self.skipTrivia();
            if (self.done()) break;
            try tokens.append(try self.nextToken());
        }

        try tokens.append(.{
            .kind = .eof,
            .lexeme = "",
            .span = source.Span.init(self.index, self.index),
        });
        return tokens.toOwnedSlice();
    }

    fn nextToken(self: *Lexer) !syntax.Token {
        const start = self.index;
        const ch = self.peek();
        if (isIdentifierStart(ch)) return self.lexIdentifierOrKeyword(start);
        if (std.ascii.isDigit(ch)) return self.lexNumber(start);

        _ = self.advance();
        return switch (ch) {
            '@' => self.token(.at_sign, start, self.index),
            ',' => self.token(.comma, start, self.index),
            ':' => self.token(.colon, start, self.index),
            ';' => self.token(.semicolon, start, self.index),
            '.' => self.token(.dot, start, self.index),
            '(' => self.token(.l_paren, start, self.index),
            ')' => self.token(.r_paren, start, self.index),
            '{' => self.token(.l_brace, start, self.index),
            '}' => self.token(.r_brace, start, self.index),
            '[' => self.token(.l_bracket, start, self.index),
            ']' => self.token(.r_bracket, start, self.index),
            '+' => self.token(.plus, start, self.index),
            '*' => self.token(.star, start, self.index),
            '/' => self.token(.slash, start, self.index),
            '!' => if (self.match('=')) self.token(.bang_equal, start, self.index) else self.token(.bang, start, self.index),
            '=' => if (self.match('=')) self.token(.equal_equal, start, self.index) else self.token(.equal, start, self.index),
            '<' => if (self.match('=')) self.token(.less_equal, start, self.index) else self.token(.less, start, self.index),
            '>' => if (self.match('=')) self.token(.greater_equal, start, self.index) else self.token(.greater, start, self.index),
            '-' => if (self.match('>')) self.token(.arrow, start, self.index) else self.token(.minus, start, self.index),
            '"' => self.lexString(start),
            else => {
                try diagnostics.appendOwned(self.allocator, self.diagnostics, .{
                    .severity = .@"error",
                    .code = "KSLP001",
                    .title = "unexpected character",
                    .message = try std.fmt.allocPrint(self.allocator, "KSL does not recognize `{c}` here.", .{ch}),
                    .labels = &.{diagnostics.primaryLabel(source.Span.init(start, self.index), "unexpected character")},
                    .help = "Remove the character or replace it with valid KSL syntax.",
                });
                return error.DiagnosticsEmitted;
            },
        };
    }

    fn lexIdentifierOrKeyword(self: *Lexer, start: usize) !syntax.Token {
        while (!self.done() and isIdentifierContinue(self.peek())) _ = self.advance();
        const lexeme = self.input.text[start..self.index];
        const kind = keywordKind(lexeme) orelse .identifier;
        return self.token(kind, start, self.index);
    }

    fn lexNumber(self: *Lexer, start: usize) !syntax.Token {
        while (!self.done() and std.ascii.isDigit(self.peek())) _ = self.advance();
        var kind: syntax.TokenKind = .integer_literal;
        if (!self.done() and self.peek() == '.' and self.index + 1 < self.input.text.len and std.ascii.isDigit(self.input.text[self.index + 1])) {
            kind = .float_literal;
            _ = self.advance();
            while (!self.done() and std.ascii.isDigit(self.peek())) _ = self.advance();
        }
        return self.token(kind, start, self.index);
    }

    fn lexString(self: *Lexer, start: usize) !syntax.Token {
        while (!self.done() and self.peek() != '"') _ = self.advance();
        if (self.done()) {
            try diagnostics.appendOwned(self.allocator, self.diagnostics, .{
                .severity = .@"error",
                .code = "KSLP002",
                .title = "unterminated string literal",
                .message = "The string literal reaches the end of the file without a closing quote.",
                .labels = &.{diagnostics.primaryLabel(source.Span.init(start, self.index), "string starts here")},
                .help = "Close the string with `\"`.",
            });
            return error.DiagnosticsEmitted;
        }
        _ = self.advance();
        return self.token(.string_literal, start, self.index);
    }

    fn skipTrivia(self: *Lexer) void {
        while (!self.done()) {
            const ch = self.peek();
            if (std.ascii.isWhitespace(ch)) {
                _ = self.advance();
                continue;
            }
            if (ch == '/' and self.index + 1 < self.input.text.len and self.input.text[self.index + 1] == '/') {
                while (!self.done() and self.peek() != '\n') _ = self.advance();
                continue;
            }
            break;
        }
    }

    fn token(self: *Lexer, kind: syntax.TokenKind, start: usize, end: usize) syntax.Token {
        return .{
            .kind = kind,
            .lexeme = self.input.text[start..end],
            .span = source.Span.init(start, end),
        };
    }

    fn peek(self: *Lexer) u8 {
        return self.input.text[self.index];
    }

    fn match(self: *Lexer, ch: u8) bool {
        if (self.done()) return false;
        if (self.input.text[self.index] != ch) return false;
        self.index += 1;
        return true;
    }

    fn advance(self: *Lexer) u8 {
        const ch = self.input.text[self.index];
        self.index += 1;
        return ch;
    }

    fn done(self: *Lexer) bool {
        return self.index >= self.input.text.len;
    }
};

fn keywordKind(lexeme: []const u8) ?syntax.TokenKind {
    if (std.mem.eql(u8, lexeme, "import")) return .kw_import;
    if (std.mem.eql(u8, lexeme, "as")) return .kw_as;
    if (std.mem.eql(u8, lexeme, "type")) return .kw_type;
    if (std.mem.eql(u8, lexeme, "function")) return .kw_function;
    if (std.mem.eql(u8, lexeme, "shader")) return .kw_shader;
    if (std.mem.eql(u8, lexeme, "option")) return .kw_option;
    if (std.mem.eql(u8, lexeme, "group")) return .kw_group;
    if (std.mem.eql(u8, lexeme, "uniform")) return .kw_uniform;
    if (std.mem.eql(u8, lexeme, "storage")) return .kw_storage;
    if (std.mem.eql(u8, lexeme, "read")) return .kw_read;
    if (std.mem.eql(u8, lexeme, "read_write")) return .kw_read_write;
    if (std.mem.eql(u8, lexeme, "texture")) return .kw_texture;
    if (std.mem.eql(u8, lexeme, "sampler")) return .kw_sampler;
    if (std.mem.eql(u8, lexeme, "vertex")) return .kw_vertex;
    if (std.mem.eql(u8, lexeme, "fragment")) return .kw_fragment;
    if (std.mem.eql(u8, lexeme, "compute")) return .kw_compute;
    if (std.mem.eql(u8, lexeme, "input")) return .kw_input;
    if (std.mem.eql(u8, lexeme, "output")) return .kw_output;
    if (std.mem.eql(u8, lexeme, "threads")) return .kw_threads;
    if (std.mem.eql(u8, lexeme, "let")) return .kw_let;
    if (std.mem.eql(u8, lexeme, "if")) return .kw_if;
    if (std.mem.eql(u8, lexeme, "else")) return .kw_else;
    if (std.mem.eql(u8, lexeme, "return")) return .kw_return;
    if (std.mem.eql(u8, lexeme, "true")) return .kw_true;
    if (std.mem.eql(u8, lexeme, "false")) return .kw_false;
    return null;
}

fn isIdentifierStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentifierContinue(ch: u8) bool {
    return isIdentifierStart(ch) or std.ascii.isDigit(ch);
}

test "lexer tokenizes a shader header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const file = try source.SourceFile.initOwned(allocator, "test.ksl", "shader Demo {}");
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const tokens = try tokenize(allocator, &file, &diags);
    try std.testing.expectEqual(@as(usize, 5), tokens.len);
    try std.testing.expectEqual(syntax.TokenKind.kw_shader, tokens[0].kind);
    try std.testing.expectEqual(syntax.TokenKind.identifier, tokens[1].kind);
}
