const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const model = @import("kira_semantics_model");
const syntax = @import("kira_syntax_model");
const lowering = @import("lower_to_hir.zig");

pub fn analyze(allocator: std.mem.Allocator, program: syntax.ast.Program, out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic)) !model.Program {
    return lowering.lowerProgram(allocator, program, out_diagnostics);
}

test "reports missing main" {
    const lexer = @import("kira_lexer");
    const parser = @import("kira_parser");
    const source_pkg = @import("kira_source");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const source = try source_pkg.SourceFile.initOwned(allocator, "test.kira", "func helper() { return; }");
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const tokens = try lexer.tokenize(allocator, &source, &diags);
    const program = try parser.parse(allocator, tokens, &diags);
    const result = analyze(allocator, program, &diags);

    try std.testing.expectError(error.MissingMain, result);
    try std.testing.expect(diags.items.len > 0);
}
