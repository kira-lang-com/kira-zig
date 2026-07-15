const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const model = @import("kira_semantics_model");
const syntax = @import("kira_syntax_model");
const analyzer = @import("analyzer.zig");

pub fn analyzeSource(allocator: std.mem.Allocator, text: []const u8, diags: *std.array_list.Managed(diagnostics.Diagnostic)) !model.Program {
    const lexer = @import("kira_lexer");
    const parser = @import("kira_parser");
    const source_pkg = @import("kira_source");

    const source = try source_pkg.SourceFile.initOwned(allocator, "test.kira", text);
    const tokens = try lexer.tokenize(allocator, &source, diags);
    const program = try parser.parse(allocator, tokens, diags);
    return analyzer.analyze(allocator, program, diags);
}

pub fn parseSource(
    allocator: std.mem.Allocator,
    text: []const u8,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !syntax.ast.Program {
    const lexer = @import("kira_lexer");
    const parser = @import("kira_parser");
    const source_pkg = @import("kira_source");

    const source = try source_pkg.SourceFile.initOwned(allocator, "test.kira", text);
    const tokens = try lexer.tokenize(allocator, &source, diags);
    return parser.parse(allocator, tokens, diags);
}

pub fn expectFirstDiagnosticTitle(items: []const diagnostics.Diagnostic, expected_title: []const u8) !void {
    try std.testing.expect(items.len > 0);
    try std.testing.expectEqualStrings(expected_title, items[0].title);
}

pub fn findTypeDeclByName(program: model.Program, name: []const u8) ?model.TypeDecl {
    for (program.types) |type_decl| {
        if (std.mem.eql(u8, type_decl.name, name)) return type_decl;
    }
    return null;
}
