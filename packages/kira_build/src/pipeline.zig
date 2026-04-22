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
const program_graph = @import("kira_program_graph");

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
    const merged_program = program_graph.buildProgramGraph(allocator, parsed.source.path, parsed.program.?, module_map, &diags) catch |err| switch (err) {
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

pub fn checkPackageRoot(allocator: std.mem.Allocator, source_root: []const u8) !CheckPipelineResult {
    const module_files = try program_graph.collectPackageModuleFiles(allocator, source_root);
    if (module_files.len == 0) {
        const source = try source_pkg.SourceFile.initOwned(allocator, source_root, "");
        const diags = try allocator.alloc(diagnostics.Diagnostic, 1);
        diags[0] = .{
            .severity = .@"error",
            .code = "KPROJECT002",
            .title = "library has no source files",
            .message = "Kira could not find any `.kira` source files in this package's canonical `app/` source root.",
            .help = "Add library source files under the package `app/` directory.",
        };
        return .{
            .source = source,
            .diagnostics = diags,
            .failure_stage = .parser,
        };
    }

    const source = try source_pkg.SourceFile.fromPath(allocator, module_files[0]);
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    const module_map = try package_manager.loadModuleMapForSource(allocator, module_files[0]);
    const merged_program = program_graph.buildProgramGraphFromFiles(allocator, module_files, module_map, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => {
            return .{
                .source = source,
                .diagnostics = try diags.toOwnedSlice(),
                .failure_stage = .parser,
            };
        },
        else => return err,
    };

    for (module_files) |module_path| {
        const parsed = try parseFile(allocator, module_path);
        if (parsed.program == null) {
            return .{
                .source = parsed.source,
                .diagnostics = parsed.diagnostics,
                .failure_stage = parsed.failure_stage,
            };
        }
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
    }

    _ = semantics.analyzeLibrary(allocator, merged_program, .{}, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => {
            return .{
                .source = source,
                .diagnostics = try diags.toOwnedSlice(),
                .failure_stage = .semantics,
            };
        },
        else => return err,
    };

    return .{
        .source = source,
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
    const module_map = try package_manager.loadModuleMapForSource(allocator, source.path);
    for (program.imports) |import_decl| {
        if (program_graph.packageRootOwnerForImport(module_map, import_decl.module_name)) |owner| {
            const module_files = try program_graph.collectPackageModuleFiles(allocator, owner.source_root);
            defer {
                for (module_files) |module_file| allocator.free(module_file);
                allocator.free(module_files);
            }
            if (module_files.len != 0) continue;
        }

        const resolved = try program_graph.resolveImportPath(allocator, source.path, import_decl.module_name, module_map);
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
            .notes = try program_graph.resolvedCandidateNotes(allocator, resolved.candidates),
            .help = "Create the imported module under an allowed `app/` source root or remove the import.",
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
        if (program_graph.packageRootOwnerForImport(module_map, import_decl.module_name)) |owner| {
            const module_files = try program_graph.collectPackageModuleFiles(allocator, owner.source_root);
            defer {
                for (module_files) |module_file| allocator.free(module_file);
                allocator.free(module_files);
            }
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

        const resolved = try program_graph.resolveImportPath(allocator, source.path, import_decl.module_name, module_map);
        defer allocator.free(resolved.display_name);
        defer {
            for (resolved.candidates) |candidate| allocator.free(candidate);
            allocator.free(resolved.candidates);
        }

        const module_path = program_graph.firstExistingCandidate(resolved.candidates) orelse continue;
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

test "compile frontend deduplicates mixed-separator paths while walking current package imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("Workspace/callbacks/app");
    try tmp.dir.writeFile(.{
        .sub_path = "Workspace/callbacks/project.toml",
        .data =
        \\[project]
        \\name = "callbacks"
        \\version = "0.1.0"
        \\
        \\[defaults]
        \\execution_mode = "llvm"
        \\build_target = "host"
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "Workspace/callbacks/app/main.kira",
        .data =
        \\import callbacks as cb
        \\
        \\@Main
        \\function main() {
        \\    cb.hello()
        \\    return
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "Workspace/callbacks/app/callbacks.kira",
        .data =
        \\function hello() {
        \\    return
        \\}
        ,
    });

    const app_root = try tmp.dir.realpathAlloc(arena.allocator(), "Workspace/callbacks/app");
    const mixed_source_path = try std.fmt.allocPrint(arena.allocator(), "{s}/main.kira", .{app_root});
    const result = try compileFileToIr(arena.allocator(), mixed_source_path);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(result.ir_program != null);
}
