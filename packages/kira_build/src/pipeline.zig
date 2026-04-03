const std = @import("std");
const source_pkg = @import("kira_source");
const diagnostics = @import("kira_diagnostics");
const lexer = @import("kira_lexer");
const parser = @import("kira_parser");
const semantics = @import("kira_semantics");
const syntax = @import("kira_syntax_model");
const ir = @import("kira_ir");
const bytecode = @import("kira_bytecode");

pub const FrontendStage = enum {
    lexer,
    parser,
    semantics,
    ir,
};

pub const LexPipelineResult = struct {
    source: source_pkg.SourceFile,
    diagnostics: []const diagnostics.Diagnostic,
    tokens: ?[]const syntax.Token,
    failure_stage: ?FrontendStage = null,

    pub fn failed(self: LexPipelineResult) bool {
        return self.tokens == null;
    }
};

pub const ParsePipelineResult = struct {
    source: source_pkg.SourceFile,
    diagnostics: []const diagnostics.Diagnostic,
    program: ?syntax.ast.Program,
    failure_stage: ?FrontendStage = null,

    pub fn failed(self: ParsePipelineResult) bool {
        return self.program == null;
    }
};

pub const CheckPipelineResult = struct {
    source: source_pkg.SourceFile,
    diagnostics: []const diagnostics.Diagnostic,
    failure_stage: ?FrontendStage = null,

    pub fn failed(self: CheckPipelineResult) bool {
        return diagnostics.hasErrors(self.diagnostics);
    }
};

pub const FrontendPipelineResult = struct {
    source: source_pkg.SourceFile,
    diagnostics: []const diagnostics.Diagnostic,
    ir_program: ?ir.Program,
    failure_stage: ?FrontendStage = null,

    pub fn failed(self: FrontendPipelineResult) bool {
        return self.ir_program == null;
    }
};

pub const VmPipelineResult = struct {
    source: source_pkg.SourceFile,
    diagnostics: []const diagnostics.Diagnostic,
    ir_program: ?ir.Program,
    bytecode_module: ?bytecode.Module,
    failure_stage: ?FrontendStage = null,

    pub fn failed(self: VmPipelineResult) bool {
        return self.bytecode_module == null;
    }
};

pub fn compileFileToIr(allocator: std.mem.Allocator, path: []const u8) !FrontendPipelineResult {
    const parsed = try parseFile(allocator, path);
    if (parsed.program == null) {
        return .{
            .source = parsed.source,
            .diagnostics = parsed.diagnostics,
            .ir_program = null,
            .failure_stage = parsed.failure_stage,
        };
    }

    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    for (parsed.diagnostics) |diag| try diags.append(diag);

    const hir = semantics.analyze(allocator, parsed.program.?, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => {
            return .{
                .source = parsed.source,
                .diagnostics = try diags.toOwnedSlice(),
                .ir_program = null,
                .failure_stage = .semantics,
            };
        },
        else => return err,
    };

    const ir_program = try ir.lowerProgram(allocator, hir);
    return .{
        .source = parsed.source,
        .diagnostics = try diags.toOwnedSlice(),
        .ir_program = ir_program,
    };
}

pub fn compileFileToBytecode(allocator: std.mem.Allocator, path: []const u8) !VmPipelineResult {
    const frontend = try compileFileToIr(allocator, path);
    if (frontend.ir_program == null) {
        return .{
            .source = frontend.source,
            .diagnostics = frontend.diagnostics,
            .ir_program = null,
            .bytecode_module = null,
            .failure_stage = frontend.failure_stage,
        };
    }

    const module = bytecode.compileProgram(allocator, frontend.ir_program.?, .vm) catch |err| switch (err) {
        error.NativeFunctionInVmBuild => {
            var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
            for (frontend.diagnostics) |diag| try diags.append(diag);
            try diags.append(.{
                .severity = .@"error",
                .code = "KBUILD001",
                .title = "native code requires a native-capable backend",
                .message = "This program contains @Native functions, but the VM backend only supports runtime execution.",
                .help = try std.fmt.allocPrint(
                    allocator,
                    "Use `kira run --backend hybrid {s}` for mixed @Runtime/@Native programs, or `kira run --backend llvm {s}` for fully native execution.",
                    .{ path, path },
                ),
            });
            return .{
                .source = frontend.source,
                .diagnostics = try diags.toOwnedSlice(),
                .ir_program = frontend.ir_program,
                .bytecode_module = null,
                .failure_stage = .ir,
            };
        },
        else => return err,
    };
    return .{
        .source = frontend.source,
        .diagnostics = frontend.diagnostics,
        .ir_program = frontend.ir_program,
        .bytecode_module = module,
        .failure_stage = frontend.failure_stage,
    };
}

pub fn lexFile(allocator: std.mem.Allocator, path: []const u8) !LexPipelineResult {
    const source = try source_pkg.SourceFile.fromPath(allocator, path);
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const tokens = lexer.tokenize(allocator, &source, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => {
            return .{
                .source = source,
                .diagnostics = try diags.toOwnedSlice(),
                .tokens = null,
                .failure_stage = .lexer,
            };
        },
        else => return err,
    };

    return .{
        .source = source,
        .diagnostics = try diags.toOwnedSlice(),
        .tokens = tokens,
    };
}

pub fn parseFile(allocator: std.mem.Allocator, path: []const u8) !ParsePipelineResult {
    const lexed = try lexFile(allocator, path);
    if (lexed.tokens == null) {
        return .{
            .source = lexed.source,
            .diagnostics = lexed.diagnostics,
            .program = null,
            .failure_stage = lexed.failure_stage,
        };
    }

    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    for (lexed.diagnostics) |diag| try diags.append(diag);

    const program = parser.parse(allocator, lexed.tokens.?, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => {
            return .{
                .source = lexed.source,
                .diagnostics = try diags.toOwnedSlice(),
                .program = null,
                .failure_stage = .parser,
            };
        },
        else => return err,
    };

    return .{
        .source = lexed.source,
        .diagnostics = try diags.toOwnedSlice(),
        .program = program,
    };
}

pub fn checkFile(allocator: std.mem.Allocator, path: []const u8) !CheckPipelineResult {
    const frontend = try compileFileToIr(allocator, path);
    return .{
        .source = frontend.source,
        .diagnostics = frontend.diagnostics,
        .failure_stage = frontend.failure_stage,
    };
}
