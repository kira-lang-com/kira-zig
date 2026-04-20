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
const package_manager = @import("kira_package_manager");

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

    const module_map = try package_manager.loadModuleMapForSource(allocator, parsed.source.path);
    const merged_program = buildProgramGraph(allocator, parsed.source.path, parsed.program.?, module_map, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => {
            return .{
                .source = parsed.source,
                .diagnostics = try diags.toOwnedSlice(),
                .ir_program = null,
                .failure_stage = .parser,
            };
        },
        else => return err,
    };

    validateImports(allocator, &parsed.source, merged_program, &diags) catch |err| switch (err) {
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

    const hir = semantics.analyzeWithImports(allocator, merged_program, .{}, &diags) catch |err| switch (err) {
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

fn buildProgramGraph(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    root_program: syntax.ast.Program,
    module_map: package_manager.ModuleMap,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !syntax.ast.Program {
    var visited = std.StringHashMap(void).init(allocator);
    var imports = std.array_list.Managed(syntax.ast.ImportDecl).init(allocator);
    var decls = std.array_list.Managed(syntax.ast.Decl).init(allocator);
    var functions = std.array_list.Managed(syntax.ast.FunctionDecl).init(allocator);

    try appendProgramGraph(allocator, &visited, &imports, &decls, &functions, source_path, root_program, module_map, diags);

    return .{
        .imports = try imports.toOwnedSlice(),
        .decls = try decls.toOwnedSlice(),
        .functions = try functions.toOwnedSlice(),
    };
}

fn appendProgramGraph(
    allocator: std.mem.Allocator,
    visited: *std.StringHashMap(void),
    imports: *std.array_list.Managed(syntax.ast.ImportDecl),
    decls: *std.array_list.Managed(syntax.ast.Decl),
    functions: *std.array_list.Managed(syntax.ast.FunctionDecl),
    source_path: []const u8,
    program: syntax.ast.Program,
    module_map: package_manager.ModuleMap,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !void {
    if (visited.contains(source_path)) return;
    try visited.put(try allocator.dupe(u8, source_path), {});

    for (program.imports) |import_decl| try imports.append(import_decl);
    for (program.decls) |decl| try decls.append(decl);
    for (program.functions) |function_decl| try functions.append(function_decl);

    for (program.imports) |import_decl| {
        const resolved = try resolveImportPath(allocator, source_path, import_decl.module_name, module_map);
        defer allocator.free(resolved.display_name);
        defer {
            for (resolved.candidates) |candidate| allocator.free(candidate);
            allocator.free(resolved.candidates);
        }

        if (packageRootOwnerForImport(module_map, import_decl.module_name)) |owner| {
            const module_files = try collectPackageModuleFiles(allocator, owner.source_root);
            defer allocator.free(module_files);
            for (module_files) |module_path| {
                const imported_program = try parseModuleProgram(allocator, module_path, diags);
                try appendProgramGraph(allocator, visited, imports, decls, functions, module_path, imported_program, module_map, diags);
            }
            continue;
        }

        const module_path = firstExistingCandidate(resolved.candidates) orelse continue;
        const imported_program = try parseModuleProgram(allocator, module_path, diags);
        try appendProgramGraph(allocator, visited, imports, decls, functions, module_path, imported_program, module_map, diags);
    }
}

fn parseModuleProgram(
    allocator: std.mem.Allocator,
    module_path: []const u8,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
) !syntax.ast.Program {
    const source = try source_pkg.SourceFile.fromPath(allocator, module_path);
    var module_diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const tokens = lexer.tokenize(allocator, &source, &module_diags) catch {
        for (module_diags.items) |diag| try out_diagnostics.append(diag);
        return error.DiagnosticsEmitted;
    };
    return parser.parse(allocator, tokens, &module_diags) catch {
        for (module_diags.items) |diag| try out_diagnostics.append(diag);
        return error.DiagnosticsEmitted;
    };
}

fn validateImports(
    allocator: std.mem.Allocator,
    source: *const source_pkg.SourceFile,
    program: syntax.ast.Program,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
) !void {
    const module_map = try package_manager.loadModuleMapForSource(allocator, source.path);
    for (program.imports) |import_decl| {
        const resolved = try resolveImportPath(allocator, source.path, import_decl.module_name, module_map);
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
    const module_map = try package_manager.loadModuleMapForSource(allocator, source.path);
    var constructs = std.array_list.Managed([]const u8).init(allocator);
    var callables = std.array_list.Managed([]const u8).init(allocator);
    var functions = std.array_list.Managed(semantics.ImportedFunction).init(allocator);
    var types = std.array_list.Managed(semantics.ImportedType).init(allocator);
    var annotations = std.array_list.Managed(semantics.ImportedAnnotation).init(allocator);

    for (program.imports) |import_decl| {
        const resolved = try resolveImportPath(allocator, source.path, import_decl.module_name, module_map);
        defer allocator.free(resolved.display_name);
        defer {
            for (resolved.candidates) |candidate| allocator.free(candidate);
            allocator.free(resolved.candidates);
        }

        if (packageRootOwnerForImport(module_map, import_decl.module_name)) |owner| {
            const module_files = try collectPackageModuleFiles(allocator, owner.source_root);
            defer allocator.free(module_files);
            for (module_files) |module_path| {
                const harvested = try collectModuleGlobals(allocator, module_path);
                for (harvested.constructs) |name| try constructs.append(name);
                for (harvested.callables) |name| try callables.append(name);
                for (harvested.functions) |function_decl| try functions.append(function_decl);
                for (harvested.types) |type_decl| try types.append(type_decl);
                for (harvested.annotations) |annotation_decl| try annotations.append(annotation_decl);
            }
            continue;
        }

        const module_path = firstExistingCandidate(resolved.candidates) orelse continue;
        const harvested = try collectModuleGlobals(allocator, module_path);
        for (harvested.constructs) |name| try constructs.append(name);
        for (harvested.callables) |name| try callables.append(name);
        for (harvested.functions) |function_decl| try functions.append(function_decl);
        for (harvested.types) |type_decl| try types.append(type_decl);
        for (harvested.annotations) |annotation_decl| try annotations.append(annotation_decl);
    }

    return .{
        .constructs = try constructs.toOwnedSlice(),
        .callables = try callables.toOwnedSlice(),
        .functions = try functions.toOwnedSlice(),
        .types = try types.toOwnedSlice(),
        .annotations = try annotations.toOwnedSlice(),
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

    return harvestProgramGlobals(allocator, program, module_path);
}

fn harvestProgramGlobals(allocator: std.mem.Allocator, program: syntax.ast.Program, module_path: []const u8) !semantics.ImportedGlobals {
    var constructs = std.array_list.Managed([]const u8).init(allocator);
    var callables = std.array_list.Managed([]const u8).init(allocator);
    var functions = std.array_list.Managed(semantics.ImportedFunction).init(allocator);
    var types = std.array_list.Managed(semantics.ImportedType).init(allocator);
    var annotations = std.array_list.Managed(semantics.ImportedAnnotation).init(allocator);
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    var lowering_ctx = semantics.LoweringContext{
        .allocator = allocator,
        .diagnostics = &diags,
    };

    for (program.decls) |decl| {
        switch (decl) {
            .annotation_decl => |annotation_decl| {
                const lowered = semantics.lowerAnnotationDecl(&lowering_ctx, annotation_decl, module_path) catch continue;
                try annotations.append(.{
                    .name = lowered.name,
                    .parameters = lowered.parameters,
                    .module_path = lowered.module_path,
                    .span = lowered.span,
                });
            },
            .capability_decl => {},
            .construct_decl => |construct_decl| try constructs.append(try allocator.dupe(u8, construct_decl.name)),
            .construct_form_decl => |form_decl| try callables.append(try allocator.dupe(u8, form_decl.name)),
            .function_decl => |function_decl| {
                try callables.append(try allocator.dupe(u8, function_decl.name));
                const foreign = semantics.resolveForeignFunction(&lowering_ctx, function_decl.annotations, function_decl.span) catch null;
                var params = std.array_list.Managed(semantics.ResolvedType).init(allocator);
                for (function_decl.params) |param| {
                    if (param.type_expr) |type_expr| {
                        try params.append(try semantics.typeFromSyntax(allocator, type_expr.*));
                    } else {
                        try params.append(.{ .kind = .unknown });
                    }
                }
                try functions.append(.{
                    .name = try allocator.dupe(u8, function_decl.name),
                    .params = try params.toOwnedSlice(),
                    .return_type = if (function_decl.return_type) |return_type| try semantics.typeFromSyntax(allocator, return_type.*) else .{ .kind = .unknown },
                    .execution = if (foreign != null) .native else .inherited,
                    .is_extern = foreign != null,
                    .foreign = foreign,
                });
            },
            .type_decl => |type_decl| {
                try callables.append(try allocator.dupe(u8, type_decl.name));
                var parents = std.array_list.Managed([]const u8).init(allocator);
                for (type_decl.parents) |parent_name| {
                    try parents.append(try allocator.dupe(u8, parent_name.segments[parent_name.segments.len - 1].text));
                }
                const ffi_info = semantics.resolveNamedTypeInfo(&lowering_ctx, type_decl.annotations, type_decl.span) catch null;
                // For @FFI.Alias types, let fields with defaults are enum-style constants
                // (not instance layout slots). Skip them just as the old static let did.
                const is_alias = if (ffi_info) |info| info == .alias else false;
                var fields = std.array_list.Managed(semantics.ImportedField).init(allocator);
                for (type_decl.members) |member| {
                    if (member != .field_decl) continue;
                    if (is_alias and member.field_decl.storage == .immutable and member.field_decl.value != null) continue;
                    const field_ty: semantics.ResolvedType = if (member.field_decl.type_expr) |type_expr|
                        try semantics.typeFromSyntax(allocator, type_expr.*)
                    else
                        .{ .kind = .unknown };
                    try fields.append(.{
                        .name = try allocator.dupe(u8, member.field_decl.name),
                        .storage = @enumFromInt(@intFromEnum(member.field_decl.storage)),
                        .ty = field_ty,
                        .default_value = if (member.field_decl.value) |value| try semantics.lowerFieldDefaultExpr(&lowering_ctx, value) else null,
                    });
                }
                try types.append(.{
                    .name = try allocator.dupe(u8, type_decl.name),
                    .parents = try parents.toOwnedSlice(),
                    .fields = try fields.toOwnedSlice(),
                    .ffi = ffi_info,
                });
                for (type_decl.members) |member| {
                    if (member != .function_decl) continue;
                    const function_decl = member.function_decl;
                    const foreign = semantics.resolveForeignFunction(&lowering_ctx, function_decl.annotations, function_decl.span) catch null;
                    var params = std.array_list.Managed(semantics.ResolvedType).init(allocator);
                    try params.append(.{ .kind = .named, .name = type_decl.name });
                    for (function_decl.params) |param| {
                        if (param.type_expr) |type_expr| {
                            try params.append(try semantics.typeFromSyntax(allocator, type_expr.*));
                        } else {
                            try params.append(.{ .kind = .unknown });
                        }
                    }
                    const method_name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_decl.name, function_decl.name });
                    try callables.append(method_name);
                    try functions.append(.{
                        .name = method_name,
                        .params = try params.toOwnedSlice(),
                        .return_type = if (function_decl.return_type) |return_type| try semantics.typeFromSyntax(allocator, return_type.*) else .{ .kind = .unknown },
                        .execution = if (foreign != null) .native else .inherited,
                        .is_extern = foreign != null,
                        .foreign = foreign,
                    });
                }
            },
        }
    }

    return .{
        .constructs = try constructs.toOwnedSlice(),
        .callables = try callables.toOwnedSlice(),
        .functions = try functions.toOwnedSlice(),
        .types = try types.toOwnedSlice(),
        .annotations = try annotations.toOwnedSlice(),
    };
}

const ImportResolution = struct {
    display_name: []u8,
    candidates: [][]u8,
    exists: bool,
};

fn resolveImportPath(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    module_name: syntax.ast.QualifiedName,
    module_map: package_manager.ModuleMap,
) !ImportResolution {
    const display_name = try qualifiedNameDisplay(allocator, module_name);
    const relative_slash = try qualifiedNameRelativePath(allocator, module_name, '/');
    defer allocator.free(relative_slash);
    const relative_backslash = try qualifiedNameRelativePath(allocator, module_name, '\\');
    defer allocator.free(relative_backslash);

    var candidates_list = std.array_list.Managed([]u8).init(allocator);
    try appendOwnedModuleCandidates(allocator, &candidates_list, module_name, module_map);
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

fn appendOwnedModuleCandidates(
    allocator: std.mem.Allocator,
    candidates_list: *std.array_list.Managed([]u8),
    module_name: syntax.ast.QualifiedName,
    module_map: package_manager.ModuleMap,
) !void {
    var best_owner: ?package_manager.ModuleMap.ModuleOwner = null;
    var best_depth: usize = 0;
    for (module_map.owners) |owner| {
        const owner_depth = qualifiedPrefixDepth(owner.module_root, module_name);
        if (owner_depth == 0) continue;
        if (owner_depth > best_depth) {
            best_depth = owner_depth;
            best_owner = owner;
        }
    }

    if (best_owner) |owner| {
        const relative_slash = try qualifiedRelativeAfterPrefix(allocator, owner.module_root, module_name, '/');
        defer allocator.free(relative_slash);
        const relative_backslash = try qualifiedRelativeAfterPrefix(allocator, owner.module_root, module_name, '\\');
        defer allocator.free(relative_backslash);
        try appendRootAwareModuleCandidates(allocator, candidates_list, owner.source_root, owner.module_root, relative_slash, '/');
        try appendRootAwareModuleCandidates(allocator, candidates_list, owner.source_root, owner.module_root, relative_backslash, '\\');
        if (relative_slash.len != 0) {
            try candidates_list.append(try joinModuleDirectoryCandidate(allocator, owner.source_root, owner.module_root, relative_slash, '/'));
            try candidates_list.append(try joinModuleDirectoryCandidate(allocator, owner.source_root, owner.module_root, relative_backslash, '\\'));
        }
    }
}

fn qualifiedPrefixDepth(prefix: []const u8, module_name: syntax.ast.QualifiedName) usize {
    var parts = std.mem.splitScalar(u8, prefix, '.');
    var depth: usize = 0;
    while (parts.next()) |part| {
        if (depth >= module_name.segments.len) return 0;
        if (!std.mem.eql(u8, part, module_name.segments[depth].text)) return 0;
        depth += 1;
    }
    return depth;
}

fn packageRootOwnerForImport(
    module_map: package_manager.ModuleMap,
    module_name: syntax.ast.QualifiedName,
) ?package_manager.ModuleMap.ModuleOwner {
    for (module_map.owners) |owner| {
        const depth = qualifiedPrefixDepth(owner.module_root, module_name);
        if (depth == 0) continue;
        if (depth == module_name.segments.len) return owner;
    }
    return null;
}

fn qualifiedRelativeAfterPrefix(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    module_name: syntax.ast.QualifiedName,
    comptime separator: u8,
) ![]u8 {
    const depth = qualifiedPrefixDepth(prefix, module_name);
    if (depth == 0 or depth > module_name.segments.len) return error.InvalidArguments;
    if (depth == module_name.segments.len) return allocator.dupe(u8, "");

    var builder = std.array_list.Managed(u8).init(allocator);
    for (module_name.segments[depth..], 0..) |segment, index| {
        if (index != 0) try builder.append(separator);
        try builder.appendSlice(segment.text);
    }
    return builder.toOwnedSlice();
}

fn joinModuleCandidate(
    allocator: std.mem.Allocator,
    source_root: []const u8,
    _: []const u8,
    relative: []const u8,
    comptime separator: u8,
) ![]u8 {
    if (relative.len == 0) {
        return error.InvalidArguments;
    }
    return if (separator == '/')
        std.fmt.allocPrint(allocator, "{s}/{s}.kira", .{ source_root, relative })
    else
        std.fmt.allocPrint(allocator, "{s}\\{s}.kira", .{ source_root, relative });
}

fn joinModuleDirectoryCandidate(
    allocator: std.mem.Allocator,
    source_root: []const u8,
    _: []const u8,
    relative: []const u8,
    comptime separator: u8,
) ![]u8 {
    if (relative.len == 0) {
        return if (separator == '/')
            std.fmt.allocPrint(allocator, "{s}/main.kira", .{source_root})
        else
            std.fmt.allocPrint(allocator, "{s}\\main.kira", .{source_root});
    }
    return if (separator == '/')
        std.fmt.allocPrint(allocator, "{s}/{s}/main.kira", .{ source_root, relative })
    else
        std.fmt.allocPrint(allocator, "{s}\\{s}\\main.kira", .{ source_root, relative });
}

fn appendRootAwareModuleCandidates(
    allocator: std.mem.Allocator,
    candidates_list: *std.array_list.Managed([]u8),
    source_root: []const u8,
    module_root: []const u8,
    relative: []const u8,
    comptime separator: u8,
) !void {
    if (relative.len != 0) {
        try candidates_list.append(try joinModuleCandidate(allocator, source_root, module_root, relative, separator));
        return;
    }

    const root_name = std.fs.path.basename(module_root);
    const root_name_lower = try std.ascii.allocLowerString(allocator, root_name);
    defer allocator.free(root_name_lower);
    const app_root = try appendAppRoot(allocator, source_root);
    defer allocator.free(app_root);

    if (separator == '/') {
        try candidates_list.append(try std.fmt.allocPrint(allocator, "{s}/{s}.kira", .{ source_root, root_name_lower }));
        try candidates_list.append(try std.fmt.allocPrint(allocator, "{s}/{s}.kira", .{ app_root, root_name_lower }));
        if (!std.mem.eql(u8, root_name, root_name_lower)) {
            try candidates_list.append(try std.fmt.allocPrint(allocator, "{s}/{s}.kira", .{ source_root, root_name }));
            try candidates_list.append(try std.fmt.allocPrint(allocator, "{s}/{s}.kira", .{ app_root, root_name }));
        }
    } else {
        try candidates_list.append(try std.fmt.allocPrint(allocator, "{s}\\{s}.kira", .{ source_root, root_name_lower }));
        try candidates_list.append(try std.fmt.allocPrint(allocator, "{s}\\{s}.kira", .{ app_root, root_name_lower }));
        if (!std.mem.eql(u8, root_name, root_name_lower)) {
            try candidates_list.append(try std.fmt.allocPrint(allocator, "{s}\\{s}.kira", .{ source_root, root_name }));
            try candidates_list.append(try std.fmt.allocPrint(allocator, "{s}\\{s}.kira", .{ app_root, root_name }));
        }
    }
}

fn appendAppRoot(allocator: std.mem.Allocator, source_root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ source_root, "app" });
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

fn collectPackageModuleFiles(allocator: std.mem.Allocator, source_root: []const u8) ![][]u8 {
    var files = std.array_list.Managed([]u8).init(allocator);
    if (std.mem.eql(u8, std.fs.path.basename(source_root), "app")) {
        if (std.fs.path.dirname(source_root)) |package_root| {
            try appendPackageRootModuleFiles(allocator, &files, package_root);
        }
        try appendPackageModuleFiles(allocator, &files, source_root, source_root);
        return files.toOwnedSlice();
    }

    try appendPackageRootModuleFiles(allocator, &files, source_root);

    const app_root = try appendAppRoot(allocator, source_root);
    defer allocator.free(app_root);
    if (dirExists(app_root)) {
        try appendPackageModuleFiles(allocator, &files, app_root, app_root);
    }
    return files.toOwnedSlice();
}

fn appendPackageRootModuleFiles(
    allocator: std.mem.Allocator,
    files: *std.array_list.Managed([]u8),
    source_root: []const u8,
) !void {
    var dir = try std.fs.openDirAbsolute(source_root, .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ".kira")) continue;

        const child_path = try std.fs.path.join(allocator, &.{ source_root, entry.name });
        try files.append(child_path);
    }
}

fn appendPackageModuleFiles(
    allocator: std.mem.Allocator,
    files: *std.array_list.Managed([]u8),
    root_path: []const u8,
    current_path: []const u8,
) !void {
    var dir = try std.fs.openDirAbsolute(current_path, .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ current_path, entry.name });
        defer allocator.free(child_path);
        switch (entry.kind) {
            .directory => try appendPackageModuleFiles(allocator, files, root_path, child_path),
            .file => {
                if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ".kira")) continue;
                try files.append(try allocator.dupe(u8, child_path));
            },
            else => {},
        }
    }
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn dirExists(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

test "built-in Foundation resolves before installed package conflicts" {
    const package_manager_pkg = @import("kira_package_manager");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("Workspace/App/app");
    try tmp.dir.makePath("Workspace/ConflictFoundation");
    try tmp.dir.writeFile(.{
        .sub_path = "Workspace/App/kira.toml",
        .data =
        \\[package]
        \\name = "App"
        \\version = "0.1.0"
        \\kind = "app"
        \\kira = "0.1.0"
        \\
        \\[defaults]
        \\execution_mode = "vm"
        \\build_target = "host"
        \\
        \\[dependencies]
        \\Foundation = { path = "../ConflictFoundation" }
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "Workspace/App/app/main.kira",
        .data =
        \\import Foundation
        \\
        \\@Main
        \\function main() {
        \\    Foundation.printLine("ok");
        \\    return;
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "Workspace/ConflictFoundation/kira.toml",
        .data =
        \\[package]
        \\name = "Foundation"
        \\version = "9.9.9"
        \\kind = "library"
        \\kira = "0.1.0"
        \\module_root = "Foundation"
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "Workspace/ConflictFoundation/Foundation.kira",
        .data = "function broken( { return; }\n",
    });

    const app_root = try tmp.dir.realpathAlloc(arena.allocator(), "Workspace/App");
    const source_path = try tmp.dir.realpathAlloc(arena.allocator(), "Workspace/App/app/main.kira");

    var package_diags = std.array_list.Managed(diagnostics.Diagnostic).init(arena.allocator());
    _ = try package_manager_pkg.syncProject(arena.allocator(), app_root, "0.1.0", .{}, &package_diags);

    const result = try checkFile(arena.allocator(), source_path);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "path dependency rooted at repo root resolves module file from app directory" {
    const package_manager_pkg = @import("kira_package_manager");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("Workspace/KiraUI/app");
    try tmp.dir.makePath("Workspace/CardExample/app");

    try tmp.dir.writeFile(.{
        .sub_path = "Workspace/KiraUI/kira.toml",
        .data =
        \\[package]
        \\name = "KiraUI"
        \\version = "0.1.0"
        \\kind = "library"
        \\kira = "0.1.0"
        \\module_root = "KiraUI"
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "Workspace/KiraUI/app/kiraui.kira",
        .data =
        \\function hello() {
        \\    return;
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "Workspace/CardExample/kira.toml",
        .data =
        \\[package]
        \\name = "CardExample"
        \\version = "0.1.0"
        \\kind = "app"
        \\kira = "0.1.0"
        \\
        \\[defaults]
        \\execution_mode = "vm"
        \\build_target = "host"
        \\
        \\[dependencies]
        \\KiraUI = { path = "../KiraUI" }
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "Workspace/CardExample/app/main.kira",
        .data =
        \\import KiraUI
        \\
        \\@Main
        \\function main() {
        \\    hello();
        \\    return;
        \\}
        ,
    });

    const app_root = try tmp.dir.realpathAlloc(arena.allocator(), "Workspace/CardExample");
    const source_path = try tmp.dir.realpathAlloc(arena.allocator(), "Workspace/CardExample/app/main.kira");
    var package_diags = std.array_list.Managed(diagnostics.Diagnostic).init(arena.allocator());
    _ = try package_manager_pkg.syncProject(arena.allocator(), app_root, "0.1.0", .{}, &package_diags);

    const result = try checkFile(arena.allocator(), source_path);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "current library root import exposes declarations from every library file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("Workspace/UILibrary/app");
    try tmp.dir.writeFile(.{
        .sub_path = "Workspace/UILibrary/kira.toml",
        .data =
        \\[package]
        \\name = "UILibrary"
        \\version = "0.1.0"
        \\kind = "library"
        \\kira = "0.1.0"
        \\module_root = "UI"
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "Workspace/UILibrary/app/main.kira",
        .data =
        \\import UI
        \\
        \\@Main
        \\function main() {
        \\    header()
        \\    footer()
        \\    return;
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "Workspace/UILibrary/app/UI.kira",
        .data =
        \\function header() {
        \\    return;
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "Workspace/UILibrary/app/Footer.kira",
        .data =
        \\function footer() {
        \\    return;
        \\}
        ,
    });

    const source_path = try tmp.dir.realpathAlloc(arena.allocator(), "Workspace/UILibrary/app/main.kira");
    const result = try checkFile(arena.allocator(), source_path);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}
