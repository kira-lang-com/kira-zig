const std = @import("std");
const source_pkg = @import("kira_source");
const diagnostics = @import("kira_diagnostics");
const lexer = @import("kira_lexer");
const parser = @import("kira_parser");
const semantics = @import("kira_semantics");
const syntax = @import("kira_syntax_model");
const ir = @import("kira_ir");
const bytecode = @import("kira_bytecode");
const ffi_support = @import("ffi_support.zig");

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

    validateImports(allocator, &parsed.source, parsed.program.?, &diags) catch |err| switch (err) {
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

    const imported_globals = try collectImportedGlobals(allocator, &parsed.source, parsed.program.?);
    const hir = semantics.analyzeWithImports(allocator, parsed.program.?, imported_globals, &diags) catch |err| switch (err) {
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

    const ir_program = ir.lowerProgram(allocator, hir) catch |err| switch (err) {
        error.UnsupportedExecutableFeature, error.UnsupportedType => {
            try diags.append(.{
                .severity = .@"error",
                .code = "KIR001",
                .title = "feature is not executable in the current backend pipeline",
                .message = "This program uses language constructs that are not yet lowered into the shared executable IR.",
                .help = "Use `kirac check` to validate the frontend shape, or stay within the currently executable subset for `run` and `build`.",
            });
            return .{
                .source = parsed.source,
                .diagnostics = try diags.toOwnedSlice(),
                .ir_program = null,
                .failure_stage = .ir,
            };
        },
        else => return err,
    };
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

    _ = try ffi_support.prepareNativeLibraries(allocator, path, program.imports);

    return .{
        .source = lexed.source,
        .diagnostics = try diags.toOwnedSlice(),
        .program = program,
    };
}

pub fn checkFile(allocator: std.mem.Allocator, path: []const u8) !CheckPipelineResult {
    const parsed = try parseFile(allocator, path);
    if (parsed.program == null) {
        return .{
            .source = parsed.source,
            .diagnostics = parsed.diagnostics,
            .failure_stage = parsed.failure_stage,
        };
    }

    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    for (parsed.diagnostics) |diag| try diags.append(diag);

    validateImports(allocator, &parsed.source, parsed.program.?, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => {
            return .{
                .source = parsed.source,
                .diagnostics = try diags.toOwnedSlice(),
                .failure_stage = .semantics,
            };
        },
        else => return err,
    };

    const imported_globals = try collectImportedGlobals(allocator, &parsed.source, parsed.program.?);
    _ = semantics.analyzeWithImports(allocator, parsed.program.?, imported_globals, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => {
            return .{
                .source = parsed.source,
                .diagnostics = try diags.toOwnedSlice(),
                .failure_stage = .semantics,
            };
        },
        else => return err,
    };

    return .{
        .source = parsed.source,
        .diagnostics = try diags.toOwnedSlice(),
        .failure_stage = null,
    };
}

fn validateImports(
    allocator: std.mem.Allocator,
    source: *const source_pkg.SourceFile,
    program: syntax.ast.Program,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !void {
    for (program.imports) |import_decl| {
        const resolved = try resolveImportPath(allocator, source.path, import_decl.module_name);
        defer allocator.free(resolved.display_name);
        defer {
            for (resolved.candidates) |candidate| allocator.free(candidate);
            allocator.free(resolved.candidates);
        }

        if (resolved.exists) continue;

        try diagnostics.appendOwned(allocator, diags, .{
            .severity = .@"error",
            .code = "KSEM032",
            .title = "unresolved import",
            .message = try std.fmt.allocPrint(
                allocator,
                "Kira could not find a module for import '{s}'.",
                .{resolved.display_name},
            ),
            .labels = &.{
                diagnostics.primaryLabel(import_decl.span, "import does not resolve to a module file"),
            },
            .notes = try resolvedCandidateNotes(allocator, resolved.candidates),
            .help = "Create the imported module file or remove the import.",
        });
        return error.DiagnosticsEmitted;
    }
}

fn collectImportedGlobals(
    allocator: std.mem.Allocator,
    source: *const source_pkg.SourceFile,
    program: syntax.ast.Program,
) !semantics.ImportedGlobals {
    var constructs = std.array_list.Managed([]const u8).init(allocator);
    var callables = std.array_list.Managed([]const u8).init(allocator);
    var functions = std.array_list.Managed(semantics.ImportedFunction).init(allocator);
    var types = std.array_list.Managed(semantics.ImportedType).init(allocator);

    for (program.imports) |import_decl| {
        const resolved = try resolveImportPath(allocator, source.path, import_decl.module_name);
        defer allocator.free(resolved.display_name);
        defer {
            for (resolved.candidates) |candidate| allocator.free(candidate);
            allocator.free(resolved.candidates);
        }

        const module_path = firstExistingCandidate(resolved.candidates) orelse continue;
        const harvested = try collectModuleGlobals(allocator, module_path);
        for (harvested.constructs) |name| try constructs.append(name);
        for (harvested.callables) |name| try callables.append(name);
        for (harvested.functions) |function_decl| try functions.append(function_decl);
        for (harvested.types) |type_decl| try types.append(type_decl);
    }

    return .{
        .constructs = try constructs.toOwnedSlice(),
        .callables = try callables.toOwnedSlice(),
        .functions = try functions.toOwnedSlice(),
        .types = try types.toOwnedSlice(),
    };
}

fn collectModuleGlobals(allocator: std.mem.Allocator, module_path: []const u8) !semantics.ImportedGlobals {
    const source = try source_pkg.SourceFile.fromPath(allocator, module_path);
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);

    const tokens = lexer.tokenize(allocator, &source, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => return .{},
        else => return err,
    };
    const program = parser.parse(allocator, tokens, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => return .{},
        else => return err,
    };

    return harvestProgramGlobals(allocator, program);
}

fn harvestProgramGlobals(allocator: std.mem.Allocator, program: syntax.ast.Program) !semantics.ImportedGlobals {
    var constructs = std.array_list.Managed([]const u8).init(allocator);
    var callables = std.array_list.Managed([]const u8).init(allocator);
    var functions = std.array_list.Managed(semantics.ImportedFunction).init(allocator);
    var types = std.array_list.Managed(semantics.ImportedType).init(allocator);
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    var lowering_ctx = semantics.LoweringContext{
        .allocator = allocator,
        .diagnostics = &diags,
    };

    for (program.decls) |decl| {
        switch (decl) {
            .construct_decl => |construct_decl| try constructs.append(try allocator.dupe(u8, construct_decl.name)),
            .construct_form_decl => |form_decl| try callables.append(try allocator.dupe(u8, form_decl.name)),
            .function_decl => |function_decl| {
                try callables.append(try allocator.dupe(u8, function_decl.name));
                const foreign = semantics.resolveForeignFunction(&lowering_ctx, function_decl.annotations, function_decl.span) catch null;
                var params = std.array_list.Managed(semantics.ResolvedType).init(allocator);
                for (function_decl.params) |param| {
                    if (param.type_expr) |type_expr| {
                        try params.append(semantics.typeFromSyntax(type_expr.*));
                    } else {
                        try params.append(.{ .kind = .unknown });
                    }
                }
                try functions.append(.{
                    .name = try allocator.dupe(u8, function_decl.name),
                    .params = try params.toOwnedSlice(),
                    .return_type = if (function_decl.return_type) |return_type| semantics.typeFromSyntax(return_type.*) else .{ .kind = .unknown },
                    .execution = if (foreign != null) .native else .inherited,
                    .is_extern = foreign != null,
                    .foreign = foreign,
                });
            },
            .type_decl => |type_decl| {
                var fields = std.array_list.Managed(semantics.ImportedField).init(allocator);
                for (type_decl.members) |member| {
                    if (member != .field_decl or member.field_decl.is_static) continue;
                    const field_ty: semantics.ResolvedType = if (member.field_decl.type_expr) |type_expr|
                        semantics.typeFromSyntax(type_expr.*)
                    else
                        .{ .kind = .unknown };
                    try fields.append(.{
                        .name = try allocator.dupe(u8, member.field_decl.name),
                        .ty = field_ty,
                    });
                }
                try types.append(.{
                    .name = try allocator.dupe(u8, type_decl.name),
                    .fields = try fields.toOwnedSlice(),
                    .ffi = semantics.resolveNamedTypeInfo(&lowering_ctx, type_decl.annotations, type_decl.span) catch null,
                });
            },
        }
    }

    return .{
        .constructs = try constructs.toOwnedSlice(),
        .callables = try callables.toOwnedSlice(),
        .functions = try functions.toOwnedSlice(),
        .types = try types.toOwnedSlice(),
    };
}

const ImportResolution = struct {
    display_name: []u8,
    candidates: [][]u8,
    exists: bool,
};

fn resolveImportPath(allocator: std.mem.Allocator, source_path: []const u8, module_name: syntax.ast.QualifiedName) !ImportResolution {
    const display_name = try qualifiedNameDisplay(allocator, module_name);
    const relative_slash = try qualifiedNameRelativePath(allocator, module_name, '/');
    defer allocator.free(relative_slash);
    const relative_backslash = try qualifiedNameRelativePath(allocator, module_name, '\\');
    defer allocator.free(relative_backslash);

    var candidates_list = std.array_list.Managed([]u8).init(allocator);
    var cursor = try absolutizePath(allocator, std.fs.path.dirname(source_path) orelse ".");
    defer allocator.free(cursor);

    while (true) {
        try candidates_list.append(try std.fmt.allocPrint(allocator, "{s}/{s}.kira", .{ cursor, relative_slash }));
        try candidates_list.append(try std.fmt.allocPrint(allocator, "{s}/{s}/main.kira", .{ cursor, relative_slash }));
        try candidates_list.append(try std.fmt.allocPrint(allocator, "{s}\\{s}.kira", .{ cursor, relative_backslash }));
        try candidates_list.append(try std.fmt.allocPrint(allocator, "{s}\\{s}\\main.kira", .{ cursor, relative_backslash }));

        const parent = std.fs.path.dirname(cursor) orelse break;
        if (std.mem.eql(u8, parent, cursor)) break;

        const parent_copy = try allocator.dupe(u8, parent);
        allocator.free(cursor);
        cursor = parent_copy;
    }

    const candidates = try candidates_list.toOwnedSlice();

    var exists = false;
    for (candidates) |candidate| {
        if (fileExists(candidate)) {
            exists = true;
            break;
        }
    }

    return .{
        .display_name = display_name,
        .candidates = candidates,
        .exists = exists,
    };
}

fn absolutizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.cwd().realpathAlloc(allocator, path);
}

fn resolvedCandidateNotes(allocator: std.mem.Allocator, candidates: [][]u8) ![]const []const u8 {
    const notes = try allocator.alloc([]const u8, candidates.len);
    for (candidates, 0..) |candidate, index| {
        notes[index] = try std.fmt.allocPrint(allocator, "looked for {s}", .{candidate});
    }
    return notes;
}

fn qualifiedNameDisplay(allocator: std.mem.Allocator, name: syntax.ast.QualifiedName) ![]u8 {
    return joinQualifiedName(allocator, name, ".");
}

fn qualifiedNameRelativePath(allocator: std.mem.Allocator, name: syntax.ast.QualifiedName, comptime separator: u8) ![]u8 {
    const sep = [_]u8{separator};
    return joinQualifiedName(allocator, name, &sep);
}

fn joinQualifiedName(allocator: std.mem.Allocator, name: syntax.ast.QualifiedName, separator: []const u8) ![]u8 {
    var builder = std.array_list.Managed(u8).init(allocator);
    for (name.segments, 0..) |segment, index| {
        if (index != 0) try builder.appendSlice(separator);
        try builder.appendSlice(segment.text);
    }
    return builder.toOwnedSlice();
}

fn firstExistingCandidate(candidates: [][]u8) ?[]const u8 {
    for (candidates) |candidate| {
        if (fileExists(candidate)) return candidate;
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
