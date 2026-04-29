const std = @import("std");
const source_pkg = @import("kira_source");
const diagnostics = @import("kira_diagnostics");
const lexer = @import("kira_lexer");
const parser = @import("kira_parser");
const semantics = @import("kira_semantics");
const syntax = @import("kira_syntax_model");
const ir = @import("kira_ir");
const bytecode = @import("kira_bytecode");
const build_def = @import("kira_build_definition");
const llvm_backend = @import("kira_llvm_backend");
const native = @import("kira_native_lib_definition");
const ffi_support = @import("ffi_support.zig");
const package_manager = @import("kira_package_manager");
const program_graph = @import("kira_program_graph");

pub const FrontendStage = enum {
    lexer,
    parser,
    graph,
    semantics,
    ir,
    backend_prepare,
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
    native_libraries: []const native.ResolvedNativeLibrary = &.{},
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
    native_libraries: []const native.ResolvedNativeLibrary = &.{},
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
    native_libraries: []const native.ResolvedNativeLibrary = &.{},
    failure_stage: ?FrontendStage = null,

    pub fn failed(self: VmPipelineResult) bool {
        return self.bytecode_module == null;
    }
};

pub const ExecutablePipelineResult = struct {
    source: source_pkg.SourceFile,
    diagnostics: []const diagnostics.Diagnostic,
    ir_program: ?ir.Program,
    bytecode_module: ?bytecode.Module = null,
    native_libraries: []const native.ResolvedNativeLibrary = &.{},
    failure_stage: ?FrontendStage = null,

    pub fn failed(self: ExecutablePipelineResult) bool {
        return self.ir_program == null or diagnostics.hasErrors(self.diagnostics);
    }
};

fn diagnosticsOwnedOrFallback(
    allocator: std.mem.Allocator,
    diags: *std.array_list.Managed(diagnostics.Diagnostic),
    stage: FrontendStage,
) ![]const diagnostics.Diagnostic {
    if (diags.items.len == 0) {
        try diags.append(.{
            .severity = .@"error",
            .code = "KICE002",
            .title = "compiler stage failed without a diagnostic",
            .message = try std.fmt.allocPrint(
                allocator,
                "Kira stopped during the {s} stage without reporting a normal diagnostic.",
                .{@tagName(stage)},
            ),
            .help = "This is a compiler bug. Please report the command and source file that triggered it.",
        });
    }
    return diags.toOwnedSlice();
}

pub fn compileFileToIr(allocator: std.mem.Allocator, path: []const u8) !FrontendPipelineResult {
    const parsed = try parseFile(allocator, path);
    if (parsed.program == null) {
        return .{
            .source = parsed.source,
            .diagnostics = parsed.diagnostics,
            .ir_program = null,
            .native_libraries = parsed.native_libraries,
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
                .diagnostics = try diagnosticsOwnedOrFallback(allocator, &diags, .graph),
                .ir_program = null,
                .native_libraries = parsed.native_libraries,
                .failure_stage = .graph,
            };
        },
        else => return err,
    };
    const native_libraries = try ffi_support.prepareImportedNativeLibraries(allocator, parsed.native_libraries, merged_program.imports, module_map);

    validateImports(allocator, &parsed.source, merged_program, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => {
            return .{
                .source = parsed.source,
                .diagnostics = try diagnosticsOwnedOrFallback(allocator, &diags, .semantics),
                .ir_program = null,
                .native_libraries = native_libraries,
                .failure_stage = .semantics,
            };
        },
        else => return err,
    };

    const hir = semantics.analyzeWithImports(allocator, merged_program, .{}, &diags) catch |err| switch (err) {
        error.DiagnosticsEmitted => {
            return .{
                .source = parsed.source,
                .diagnostics = try diagnosticsOwnedOrFallback(allocator, &diags, .semantics),
                .ir_program = null,
                .native_libraries = native_libraries,
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
                .native_libraries = native_libraries,
                .failure_stage = .ir,
            };
        },
        else => return err,
    };
    return .{
        .source = parsed.source,
        .diagnostics = try diags.toOwnedSlice(),
        .ir_program = ir_program,
        .native_libraries = native_libraries,
    };
}

pub fn compileFileToBytecode(allocator: std.mem.Allocator, path: []const u8) !VmPipelineResult {
    const prepared = try compileFileForBackend(allocator, path, .vm, &.{});
    return .{
        .source = prepared.source,
        .diagnostics = prepared.diagnostics,
        .ir_program = prepared.ir_program,
        .bytecode_module = prepared.bytecode_module,
        .native_libraries = prepared.native_libraries,
        .failure_stage = prepared.failure_stage,
    };
}

pub fn compileFileForBackend(
    allocator: std.mem.Allocator,
    path: []const u8,
    target: build_def.ExecutionTarget,
    explicit_native_libraries: []const native.ResolvedNativeLibrary,
) !ExecutablePipelineResult {
    const frontend = try compileFileToIr(allocator, path);
    if (frontend.ir_program == null or diagnostics.hasErrors(frontend.diagnostics)) {
        return .{
            .source = frontend.source,
            .diagnostics = frontend.diagnostics,
            .ir_program = null,
            .bytecode_module = null,
            .native_libraries = frontend.native_libraries,
            .failure_stage = frontend.failure_stage,
        };
    }

    const ir_program = frontend.ir_program.?;
    const merged_native_libraries = try mergeNativeLibraries(allocator, explicit_native_libraries, frontend.native_libraries);

    switch (target) {
        .vm => {
            const module = bytecode.compileProgram(allocator, ir_program, .vm) catch |err| {
                const backend_diagnostics = try backendDiagnostics(allocator, frontend.source.path, err);
                return .{
                    .source = frontend.source,
                    .diagnostics = backend_diagnostics,
                    .ir_program = ir_program,
                    .bytecode_module = null,
                    .native_libraries = merged_native_libraries,
                    .failure_stage = .backend_prepare,
                };
            };
            return .{
                .source = frontend.source,
                .diagnostics = frontend.diagnostics,
                .ir_program = ir_program,
                .bytecode_module = module,
                .native_libraries = merged_native_libraries,
                .failure_stage = frontend.failure_stage,
            };
        },
        .llvm_native => {
            llvm_backend.validate(allocator, .{
                .mode = .llvm_native,
                .program = &ir_program,
                .module_name = std.fs.path.stem(path),
                .emit = dummyNativeEmitOptions(),
                .resolved_native_libraries = merged_native_libraries,
            }) catch |err| {
                const backend_diagnostics = try backendDiagnostics(allocator, frontend.source.path, err);
                return .{
                    .source = frontend.source,
                    .diagnostics = backend_diagnostics,
                    .ir_program = ir_program,
                    .bytecode_module = null,
                    .native_libraries = merged_native_libraries,
                    .failure_stage = .backend_prepare,
                };
            };
            return .{
                .source = frontend.source,
                .diagnostics = frontend.diagnostics,
                .ir_program = ir_program,
                .bytecode_module = null,
                .native_libraries = merged_native_libraries,
                .failure_stage = frontend.failure_stage,
            };
        },
        .hybrid => {
            const module = bytecode.compileProgram(allocator, ir_program, .hybrid_runtime) catch |err| {
                const backend_diagnostics = try backendDiagnostics(allocator, frontend.source.path, err);
                return .{
                    .source = frontend.source,
                    .diagnostics = backend_diagnostics,
                    .ir_program = ir_program,
                    .bytecode_module = null,
                    .native_libraries = merged_native_libraries,
                    .failure_stage = .backend_prepare,
                };
            };
            llvm_backend.validate(allocator, .{
                .mode = .hybrid,
                .program = &ir_program,
                .module_name = std.fs.path.stem(path),
                .emit = dummyNativeEmitOptions(),
                .resolved_native_libraries = merged_native_libraries,
            }) catch |err| {
                const backend_diagnostics = try backendDiagnostics(allocator, frontend.source.path, err);
                return .{
                    .source = frontend.source,
                    .diagnostics = backend_diagnostics,
                    .ir_program = ir_program,
                    .bytecode_module = null,
                    .native_libraries = merged_native_libraries,
                    .failure_stage = .backend_prepare,
                };
            };
            return .{
                .source = frontend.source,
                .diagnostics = frontend.diagnostics,
                .ir_program = ir_program,
                .bytecode_module = module,
                .native_libraries = merged_native_libraries,
                .failure_stage = frontend.failure_stage,
            };
        },
    }
}

pub fn checkFileForBackend(
    allocator: std.mem.Allocator,
    path: []const u8,
    target: build_def.ExecutionTarget,
) !CheckPipelineResult {
    const prepared = try compileFileForBackend(allocator, path, target, &.{});
    return .{
        .source = prepared.source,
        .diagnostics = prepared.diagnostics,
        .failure_stage = prepared.failure_stage,
    };
}

fn dummyNativeEmitOptions() @import("kira_backend_api").NativeEmitOptions {
    return .{
        .object_path = "__kira_check__.o",
        .executable_path = "__kira_check__",
        .shared_library_path = "__kira_check__.so",
    };
}

fn mergeNativeLibraries(
    allocator: std.mem.Allocator,
    explicit: []const native.ResolvedNativeLibrary,
    discovered: []const native.ResolvedNativeLibrary,
) ![]const native.ResolvedNativeLibrary {
    const merged = try allocator.alloc(native.ResolvedNativeLibrary, explicit.len + discovered.len);
    @memcpy(merged[0..explicit.len], explicit);
    @memcpy(merged[explicit.len..], discovered);
    return merged;
}

pub fn backendDiagnostic(allocator: std.mem.Allocator, source_path: []const u8, err: anyerror) !diagnostics.Diagnostic {
    return switch (err) {
        error.NativeFunctionInVmBuild => .{
            .severity = .@"error",
            .code = "KBUILD001",
            .title = "native code requires a native-capable backend",
            .message = "This program contains @Native functions, but the selected backend only supports runtime execution.",
            .help = try std.fmt.allocPrint(
                allocator,
                "Use `kira build --backend hybrid {s}` for mixed @Runtime/@Native programs, or `kira build --backend llvm {s}` for fully native output.",
                .{ source_path, source_path },
            ),
        },
        error.LlvmBackendUnavailable => .{
            .severity = .@"error",
            .code = "KBUILD002",
            .title = "LLVM backend is unavailable",
            .message = "Kira could not start the native toolchain because LLVM is not available in this build.",
            .help = "Set KIRA_LLVM_HOME or run `kira-bootstrapper fetch-llvm` to install the pinned LLVM toolchain.",
        },
        error.RuntimeEntrypointInNativeBuild => .{
            .severity = .@"error",
            .code = "KBUILD003",
            .title = "native build cannot start from a runtime entrypoint",
            .message = "The selected native backend needs a native entrypoint, but @Main resolves to runtime execution.",
            .help = "Use the VM or hybrid backend, or mark the entry function with @Native.",
        },
        error.RuntimeCallInNativeBuild => .{
            .severity = .@"error",
            .code = "KBUILD004",
            .title = "native build depends on runtime-only code",
            .message = "The selected native backend encountered a call that still requires the runtime.",
            .help = "Use the hybrid backend for mixed execution, or move the called function to @Native.",
        },
        error.HybridBuildRequiresExplicitExecution => .{
            .severity = .@"error",
            .code = "KBUILD005",
            .title = "hybrid build needs explicit execution annotations",
            .message = "A hybrid build can only package functions that are explicitly marked with @Runtime or @Native.",
            .help = "Annotate each reachable function with @Runtime or @Native.",
        },
        error.UnsupportedExecutableFeature, error.UnsupportedType => .{
            .severity = .@"error",
            .code = "KIR001",
            .title = "feature is not executable in the current backend pipeline",
            .message = "This program uses language constructs that are not yet supported by the selected backend preparation stage.",
            .help = "Use a different backend if available, or stay within the currently executable subset for `check`, `build`, and `run`.",
        },
        else => .{
            .severity = .@"error",
            .code = "KBUILD999",
            .title = "toolchain build failed",
            .message = try std.fmt.allocPrint(allocator, "Kira hit a toolchain failure while preparing this program ({s}).", .{@errorName(err)}),
            .help = "Check the toolchain setup and try the command again.",
        },
    };
}

pub fn backendDiagnostics(allocator: std.mem.Allocator, source_path: []const u8, err: anyerror) ![]diagnostics.Diagnostic {
    const items = try allocator.alloc(diagnostics.Diagnostic, 1);
    items[0] = try backendDiagnostic(allocator, source_path, err);
    return items;
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

    const native_libraries = try ffi_support.prepareNativeLibraries(allocator, path, program.imports);

    return .{
        .source = lexed.source,
        .diagnostics = try diags.toOwnedSlice(),
        .program = program,
        .native_libraries = native_libraries,
    };
}

pub fn checkFile(allocator: std.mem.Allocator, path: []const u8) !CheckPipelineResult {
    return checkFileForBackend(allocator, path, .vm);
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
                .failure_stage = .graph,
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

test "check and build stop points share imported graph diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "App/app");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/project.toml",
        .data =
        \\[project]
        \\name = "App"
        \\version = "0.1.0"
        \\
        \\[defaults]
        \\execution_mode = "vm"
        \\build_target = "host"
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/main.kira",
        .data =
        \\import support as Support
        \\
        \\@Main
        \\function main() {
        \\    return;
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/support.kira",
        .data = "function helper( { return; }\n",
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "App/app/main.kira", arena.allocator());
    const checked = try checkFileForBackend(arena.allocator(), source_path, .vm);
    const built = try compileFileForBackend(arena.allocator(), source_path, .vm, &.{});

    try std.testing.expectEqual(FrontendStage.graph, checked.failure_stage.?);
    try std.testing.expectEqual(FrontendStage.graph, built.failure_stage.?);
    try std.testing.expectEqualStrings(checked.diagnostics[0].code.?, built.diagnostics[0].code.?);
    try std.testing.expectEqualStrings(checked.diagnostics[0].title, built.diagnostics[0].title);
}

test "check reaches backend preparation for selected backend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "App/app");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "App/app/main.kira",
        .data =
        \\@Main
        \\function main() {
        \\    nativeHelper();
        \\    return;
        \\}
        \\
        \\@Native
        \\function nativeHelper() {
        \\    return;
        \\}
        ,
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "App/app/main.kira", arena.allocator());
    const result = try checkFileForBackend(arena.allocator(), source_path, .vm);

    try std.testing.expect(result.failed());
    try std.testing.expectEqual(FrontendStage.backend_prepare, result.failure_stage.?);
    try std.testing.expectEqualStrings("KBUILD001", result.diagnostics[0].code.?);
}

test "built-in Foundation resolves before installed package conflicts" {
    const package_manager_pkg = @import("kira_package_manager");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "Workspace/App/app");
    try tmp.dir.createDirPath(std.testing.io, "Workspace/ConflictFoundation");
    try tmp.dir.writeFile(std.testing.io, .{
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
    try tmp.dir.writeFile(std.testing.io, .{
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
    try tmp.dir.writeFile(std.testing.io, .{
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
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/ConflictFoundation/Foundation.kira",
        .data = "function broken( { return; }\n",
    });

    const app_root = try tmp.dir.realPathFileAlloc(std.testing.io, "Workspace/App", arena.allocator());
    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "Workspace/App/app/main.kira", arena.allocator());

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

    try tmp.dir.createDirPath(std.testing.io, "Workspace/KiraUI/app");
    try tmp.dir.createDirPath(std.testing.io, "Workspace/CardExample/app");

    try tmp.dir.writeFile(std.testing.io, .{
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
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/KiraUI/app/kiraui.kira",
        .data =
        \\function hello() {
        \\    return;
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
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
    try tmp.dir.writeFile(std.testing.io, .{
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

    const app_root = try tmp.dir.realPathFileAlloc(std.testing.io, "Workspace/CardExample", arena.allocator());
    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "Workspace/CardExample/app/main.kira", arena.allocator());
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

    try tmp.dir.createDirPath(std.testing.io, "Workspace/UILibrary/app");
    try tmp.dir.writeFile(std.testing.io, .{
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
    try tmp.dir.writeFile(std.testing.io, .{
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
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/UILibrary/app/UI.kira",
        .data =
        \\function header() {
        \\    return;
        \\}
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/UILibrary/app/Footer.kira",
        .data =
        \\function footer() {
        \\    return;
        \\}
        ,
    });

    const source_path = try tmp.dir.realPathFileAlloc(std.testing.io, "Workspace/UILibrary/app/main.kira", arena.allocator());
    const result = try checkFile(arena.allocator(), source_path);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "compile frontend deduplicates mixed-separator paths while walking current package imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "Workspace/callbacks/app");
    try tmp.dir.writeFile(std.testing.io, .{
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
    try tmp.dir.writeFile(std.testing.io, .{
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
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "Workspace/callbacks/app/callbacks.kira",
        .data =
        \\function hello() {
        \\    return
        \\}
        ,
    });

    const app_root = try tmp.dir.realPathFileAlloc(std.testing.io, "Workspace/callbacks/app", arena.allocator());
    const mixed_source_path = try std.fmt.allocPrint(arena.allocator(), "{s}/main.kira", .{app_root});
    const result = try compileFileToIr(arena.allocator(), mixed_source_path);

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expect(result.ir_program != null);
}
