const std = @import("std");
const source_pkg = @import("kira_source");
const diagnostics = @import("kira_diagnostics");
const lexer = @import("kira_lexer");
const parser = @import("kira_parser");
const semantics = @import("kira_semantics");
const ir = @import("kira_ir");
const bytecode = @import("kira_bytecode");

pub const FrontendPipelineResult = struct {
    source: source_pkg.SourceFile,
    diagnostics: []const diagnostics.Diagnostic,
    ir_program: ir.Program,
};

pub const VmPipelineResult = struct {
    source: source_pkg.SourceFile,
    diagnostics: []const diagnostics.Diagnostic,
    ir_program: ir.Program,
    bytecode_module: bytecode.Module,
};

pub fn compileFileToIr(allocator: std.mem.Allocator, path: []const u8) !FrontendPipelineResult {
    const source = try source_pkg.SourceFile.fromPath(allocator, path);
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const tokens = try lexer.tokenize(allocator, &source, &diags);
    const ast = try parser.parse(allocator, tokens, &diags);
    const hir = try semantics.analyze(allocator, ast, &diags);
    const ir_program = try ir.lowerProgram(allocator, hir);

    return .{
        .source = source,
        .diagnostics = try diags.toOwnedSlice(),
        .ir_program = ir_program,
    };
}

pub fn compileFileToBytecode(allocator: std.mem.Allocator, path: []const u8) !VmPipelineResult {
    const frontend = try compileFileToIr(allocator, path);
    const module = try bytecode.compileProgram(allocator, frontend.ir_program, .vm);
    return .{
        .source = frontend.source,
        .diagnostics = frontend.diagnostics,
        .ir_program = frontend.ir_program,
        .bytecode_module = module,
    };
}

pub fn lexFile(allocator: std.mem.Allocator, path: []const u8) !struct { source: source_pkg.SourceFile, diagnostics: []const diagnostics.Diagnostic, tokens: []const @import("kira_syntax_model").Token } {
    const source = try source_pkg.SourceFile.fromPath(allocator, path);
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const tokens = try lexer.tokenize(allocator, &source, &diags);
    return .{
        .source = source,
        .diagnostics = try diags.toOwnedSlice(),
        .tokens = tokens,
    };
}

pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !struct { source: source_pkg.SourceFile, diagnostics: []const diagnostics.Diagnostic, program: @import("kira_syntax_model").ast.Program } {
    const lexed = try lexFile(allocator, path);
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    for (lexed.diagnostics) |diag| try diags.append(diag);
    const program = try parser.parse(allocator, lexed.tokens, &diags);
    return .{
        .source = lexed.source,
        .diagnostics = try diags.toOwnedSlice(),
        .program = program,
    };
}

pub fn checkFile(allocator: std.mem.Allocator, path: []const u8) !struct { source: source_pkg.SourceFile, diagnostics: []const diagnostics.Diagnostic } {
    const parsed = try parseFile(allocator, path);
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    for (parsed.diagnostics) |diag| try diags.append(diag);
    _ = try semantics.analyze(allocator, parsed.program, &diags);
    return .{
        .source = parsed.source,
        .diagnostics = try diags.toOwnedSlice(),
    };
}
