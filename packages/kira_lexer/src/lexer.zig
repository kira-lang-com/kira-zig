const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");

pub fn tokenize(allocator: std.mem.Allocator, source: *const source_pkg.SourceFile, out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic)) ![]syntax.Token {
    var tokens = std.array_list.Managed(syntax.Token).init(allocator);
    var index: usize = 0;
    while (index < source.text.len) {
        const byte = source.text[index];
        switch (byte) {
            ' ', '\t', '\r', '\n' => index += 1,
            '@' => {
                try tokens.append(makeToken(.at_sign, source.text[index .. index + 1], index, index + 1));
                index += 1;
            },
            '(' => {
                try tokens.append(makeToken(.l_paren, source.text[index .. index + 1], index, index + 1));
                index += 1;
            },
            ')' => {
                try tokens.append(makeToken(.r_paren, source.text[index .. index + 1], index, index + 1));
                index += 1;
            },
            '{' => {
                try tokens.append(makeToken(.l_brace, source.text[index .. index + 1], index, index + 1));
                index += 1;
            },
            '}' => {
                try tokens.append(makeToken(.r_brace, source.text[index .. index + 1], index, index + 1));
                index += 1;
            },
            ';' => {
                try tokens.append(makeToken(.semicolon, source.text[index .. index + 1], index, index + 1));
                index += 1;
            },
            ',' => {
                try tokens.append(makeToken(.comma, source.text[index .. index + 1], index, index + 1));
                index += 1;
            },
            '=' => {
                try tokens.append(makeToken(.equal, source.text[index .. index + 1], index, index + 1));
                index += 1;
            },
            '+' => {
                try tokens.append(makeToken(.plus, source.text[index .. index + 1], index, index + 1));
                index += 1;
            },
            '"' => {
                const start = index;
                index += 1;
                while (index < source.text.len and source.text[index] != '"') : (index += 1) {}
                if (index >= source.text.len) {
                    try diagnostics.appendOwned(allocator, out_diagnostics, .{
                        .severity = .@"error",
                        .code = "KLEX002",
                        .title = "unterminated string literal",
                        .message = "Kira reached the end of the file before this string literal was closed.",
                        .labels = &.{
                            diagnostics.primaryLabel(source_pkg.Span.init(start, source.text.len), "string literal starts here"),
                        },
                        .help = "Close the string with a matching '\"'.",
                    });
                    return error.DiagnosticsEmitted;
                }
                const contents = source.text[start + 1 .. index];
                index += 1;
                try tokens.append(makeToken(.string, contents, start, index));
            },
            '0'...'9' => {
                const start = index;
                while (index < source.text.len and std.ascii.isDigit(source.text[index])) : (index += 1) {}
                try tokens.append(makeToken(.integer, source.text[start..index], start, index));
            },
            'A'...'Z', 'a'...'z', '_' => {
                const start = index;
                while (index < source.text.len and isIdentifierContinue(source.text[index])) : (index += 1) {}
                const lexeme = source.text[start..index];
                const kind = keywordKind(lexeme);
                try tokens.append(makeToken(kind, lexeme, start, index));
            },
            else => {
                try diagnostics.appendOwned(allocator, out_diagnostics, .{
                    .severity = .@"error",
                    .code = "KLEX001",
                    .title = "unexpected character",
                    .message = "Kira found a character that does not belong to the current grammar.",
                    .labels = &.{
                        diagnostics.primaryLabel(source_pkg.Span.init(index, index + 1), "this character is not valid here"),
                    },
                    .help = "Remove the character or replace it with valid Kira syntax.",
                });
                return error.DiagnosticsEmitted;
            },
        }
    }
    try tokens.append(makeToken(.eof, "", source.text.len, source.text.len));
    return tokens.toOwnedSlice();
}

fn isIdentifierContinue(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn keywordKind(lexeme: []const u8) syntax.TokenKind {
    if (std.mem.eql(u8, lexeme, "function")) return .kw_function;
    if (std.mem.eql(u8, lexeme, "let")) return .kw_let;
    if (std.mem.eql(u8, lexeme, "return")) return .kw_return;
    return .identifier;
}

fn makeToken(kind: syntax.TokenKind, lexeme: []const u8, start: usize, end: usize) syntax.Token {
    return .{
        .kind = kind,
        .lexeme = lexeme,
        .span = source_pkg.Span.init(start, end),
    };
}

test "tokenizes bootstrap grammar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const source = try source_pkg.SourceFile.initOwned(allocator, "test.kira", "@Main\nfunction main() { let x = 1 + 2; return; }");
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const tokens = try tokenize(allocator, &source, &diags);

    try std.testing.expectEqual(@as(usize, 18), tokens.len);
    try std.testing.expectEqual(syntax.TokenKind.at_sign, tokens[0].kind);
    try std.testing.expectEqual(syntax.TokenKind.identifier, tokens[1].kind);
    try std.testing.expectEqualStrings("Main", tokens[1].lexeme);
    try std.testing.expectEqual(syntax.TokenKind.kw_function, tokens[2].kind);
    try std.testing.expectEqualStrings("main", tokens[3].lexeme);
    try std.testing.expectEqual(syntax.TokenKind.plus, tokens[12].kind);
}
