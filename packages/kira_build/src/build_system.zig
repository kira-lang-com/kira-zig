const std = @import("std");
const build_def = @import("kira_build_definition");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const bytecode = @import("kira_bytecode");
const hybrid = @import("kira_hybrid_definition");
const runtime_abi = @import("kira_runtime_abi");
const llvm_backend = @import("kira_llvm_backend");
const pipeline = @import("pipeline.zig");
const ffi_support = @import("ffi_support.zig");
const builtin = @import("builtin");

pub const BuildFailureKind = enum {
    frontend,
    build,
    toolchain,
};

pub const BuildArtifactOutcome = struct {
    source: ?source_pkg.SourceFile = null,
    diagnostics: []const diagnostics.Diagnostic = &.{},
    artifacts: []const build_def.Artifact = &.{},
    failure_kind: ?BuildFailureKind = null,

    pub fn failed(self: BuildArtifactOutcome) bool {
        return diagnostics.hasErrors(self.diagnostics);
    }
};

pub const BuildSystem = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BuildSystem {
        return .{ .allocator = allocator };
    }

    pub fn check(self: BuildSystem, path: []const u8) ![]const diagnostics.Diagnostic {
        const result = try pipeline.checkFile(self.allocator, path);
        return result.diagnostics;
    }

    pub fn compileVm(self: BuildSystem, path: []const u8) !pipeline.VmPipelineResult {
        return pipeline.compileFileToBytecode(self.allocator, path);
    }

    pub fn compileFrontend(self: BuildSystem, path: []const u8) !pipeline.FrontendPipelineResult {
        return pipeline.compileFileToIr(self.allocator, path);
    }

    pub fn build(self: BuildSystem, request: build_def.BuildRequest) !BuildArtifactOutcome {
        return switch (request.target.execution) {
            .vm => self.buildBytecodeArtifact(request),
            .llvm_native => self.buildNativeArtifact(request),
            .hybrid => self.buildHybridArtifact(request),
        };
    }

    pub fn buildBytecodeArtifact(self: BuildSystem, request: build_def.BuildRequest) !BuildArtifactOutcome {
        const compiled = try self.compileVm(request.source_path);
        if (compiled.bytecode_module == null) {
            return .{
                .source = compiled.source,
                .diagnostics = compiled.diagnostics,
                .failure_kind = if (compiled.failure_stage == .ir) .build else .frontend,
            };
        }

        try compiled.bytecode_module.?.writeToFile(request.output_path);

        const artifacts = try self.allocator.alloc(build_def.Artifact, 1);
        artifacts[0] = .{
            .kind = .bytecode,
            .path = request.output_path,
        };
        return .{ .artifacts = artifacts };
    }

    pub fn buildNativeArtifact(self: BuildSystem, request: build_def.BuildRequest) !BuildArtifactOutcome {
        const compiled = try self.compileFrontend(request.source_path);
        if (compiled.ir_program == null) {
            return .{
                .source = compiled.source,
                .diagnostics = compiled.diagnostics,
                .failure_kind = .frontend,
            };
        }

        const ir_program = compiled.ir_program.?;
        const object_path = try defaultObjectPath(self.allocator, request.output_path);
        const parsed = try pipeline.parseFile(self.allocator, request.source_path);
        const discovered_native_libraries = if (parsed.program) |program|
            try ffi_support.prepareNativeLibraries(self.allocator, request.source_path, program.imports)
        else
            &.{};
        const backend_result = llvm_backend.compile(self.allocator, .{
            .mode = .llvm_native,
            .program = &ir_program,
            .module_name = std.fs.path.stem(request.source_path),
            .emit = .{
                .object_path = object_path,
                .executable_path = request.output_path,
            },
            .resolved_native_libraries = try mergeNativeLibraries(self.allocator, request.native_libraries, discovered_native_libraries),
        }) catch |err| {
            const backend_diagnostics = try backendDiagnostics(self.allocator, compiled.source.path, err);
            return .{
                .source = compiled.source,
                .diagnostics = backend_diagnostics,
                .failure_kind = .toolchain,
            };
        };

        const artifacts = try self.allocator.alloc(build_def.Artifact, backend_result.artifacts.len);
        for (backend_result.artifacts, 0..) |artifact, index| {
            artifacts[index] = .{
                .kind = switch (artifact.kind) {
                    .bytecode => .bytecode,
                    .native_object => .native_object,
                    .native_library => .native_library,
                    .executable => .executable,
                    .hybrid_bundle => return error.NotImplemented,
                },
                .path = artifact.path,
            };
        }
        return .{ .artifacts = artifacts };
    }

    pub fn buildHybridArtifact(self: BuildSystem, request: build_def.BuildRequest) !BuildArtifactOutcome {
        const compiled = try self.compileFrontend(request.source_path);
        if (compiled.ir_program == null) {
            return .{
                .source = compiled.source,
                .diagnostics = compiled.diagnostics,
                .failure_kind = .frontend,
            };
        }

        const ir_program = compiled.ir_program.?;
        const bytecode_path = try replaceExtension(self.allocator, request.output_path, ".kbc");
        const object_path = try replaceExtension(self.allocator, request.output_path, objectExtension());
        const library_path = try replaceExtension(self.allocator, request.output_path, sharedLibraryExtension());
        const parsed = try pipeline.parseFile(self.allocator, request.source_path);
        const discovered_native_libraries = if (parsed.program) |program|
            try ffi_support.prepareNativeLibraries(self.allocator, request.source_path, program.imports)
        else
            &.{};

        const bytecode_module = bytecode.compileProgram(self.allocator, ir_program, .hybrid_runtime) catch |err| {
            const backend_diagnostics = try backendDiagnostics(self.allocator, compiled.source.path, err);
            return .{
                .source = compiled.source,
                .diagnostics = backend_diagnostics,
                .failure_kind = .build,
            };
        };
        try bytecode_module.writeToFile(bytecode_path);

        const backend_result = llvm_backend.compile(self.allocator, .{
            .mode = .hybrid,
            .program = &ir_program,
            .module_name = std.fs.path.stem(request.source_path),
            .emit = .{
                .object_path = object_path,
                .shared_library_path = library_path,
            },
            .resolved_native_libraries = try mergeNativeLibraries(self.allocator, request.native_libraries, discovered_native_libraries),
        }) catch |err| {
            const backend_diagnostics = try backendDiagnostics(self.allocator, compiled.source.path, err);
            return .{
                .source = compiled.source,
                .diagnostics = backend_diagnostics,
                .failure_kind = .toolchain,
            };
        };

        const manifest = buildHybridManifest(self.allocator, ir_program, std.fs.path.stem(request.source_path), bytecode_path, library_path) catch |err| {
            const backend_diagnostics = try backendDiagnostics(self.allocator, compiled.source.path, err);
            return .{
                .source = compiled.source,
                .diagnostics = backend_diagnostics,
                .failure_kind = .build,
            };
        };
        try manifest.writeToFile(request.output_path);

        const artifacts = try self.allocator.alloc(build_def.Artifact, backend_result.artifacts.len + 2);
        artifacts[0] = .{ .kind = .bytecode, .path = bytecode_path };
        artifacts[1] = .{ .kind = .hybrid_manifest, .path = request.output_path };
        for (backend_result.artifacts, 0..) |artifact, index| {
            artifacts[index + 2] = .{
                .kind = switch (artifact.kind) {
                    .bytecode => .bytecode,
                    .native_object => .native_object,
                    .native_library => .native_library,
                    .executable => .executable,
                    .hybrid_bundle => return error.NotImplemented,
                },
                .path = artifact.path,
            };
        }
        return .{ .artifacts = artifacts };
    }

    pub fn readBytecode(self: BuildSystem, path: []const u8) !bytecode.Module {
        _ = self;
        return bytecode.Module.readFromFile(std.heap.page_allocator, path);
    }
};

fn defaultObjectPath(allocator: std.mem.Allocator, executable_path: []const u8) ![]const u8 {
    const ext = executableExtension();
    if (ext.len > 0 and std.mem.endsWith(u8, executable_path, ext)) {
        const stem = executable_path[0 .. executable_path.len - ext.len];
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, objectExtension() });
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ executable_path, objectExtension() });
}

fn mergeNativeLibraries(
    allocator: std.mem.Allocator,
    explicit: []const @import("kira_native_lib_definition").ResolvedNativeLibrary,
    discovered: []const @import("kira_native_lib_definition").ResolvedNativeLibrary,
) ![]const @import("kira_native_lib_definition").ResolvedNativeLibrary {
    const merged = try allocator.alloc(@import("kira_native_lib_definition").ResolvedNativeLibrary, explicit.len + discovered.len);
    @memcpy(merged[0..explicit.len], explicit);
    @memcpy(merged[explicit.len..], discovered);
    return merged;
}

fn replaceExtension(allocator: std.mem.Allocator, path: []const u8, extension: []const u8) ![]const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return std.fmt.allocPrint(allocator, "{s}{s}", .{ path, extension });
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ path[0 .. path.len - ext.len], extension });
}

fn objectExtension() []const u8 {
    return if (builtin.os.tag == .windows) ".obj" else ".o";
}

pub fn executableExtension() []const u8 {
    return if (builtin.os.tag == .windows) ".exe" else "";
}

pub fn sharedLibraryExtension() []const u8 {
    return switch (builtin.os.tag) {
        .windows => ".dll",
        .macos => ".dylib",
        else => ".so",
    };
}

fn buildHybridManifest(
    allocator: std.mem.Allocator,
    program: @import("kira_ir").Program,
    module_name: []const u8,
    bytecode_path: []const u8,
    library_path: []const u8,
) !hybrid.HybridModuleManifest {
    var functions = std.array_list.Managed(hybrid.FunctionManifest).init(allocator);
    for (program.functions) |function_decl| {
        const resolved_execution = resolveHybridExecution(function_decl.execution);
        try functions.append(.{
            .id = function_decl.id,
            .name = function_decl.name,
            .execution = resolved_execution,
            .exported_name = if (resolved_execution == .native and !function_decl.is_extern)
                try std.fmt.allocPrint(allocator, "kira_native_fn_{d}", .{function_decl.id})
            else
                null,
        });
    }

    const entry_function = program.functions[program.entry_index];
    return .{
        .module_name = try allocator.dupe(u8, module_name),
        .bytecode_path = try allocator.dupe(u8, bytecode_path),
        .native_library_path = try allocator.dupe(u8, library_path),
        .entry_function_id = entry_function.id,
        .entry_execution = resolveHybridExecution(entry_function.execution),
        .functions = try functions.toOwnedSlice(),
    };
}

fn resolveHybridExecution(execution: runtime_abi.FunctionExecution) runtime_abi.FunctionExecution {
    return switch (execution) {
        .inherited => .runtime,
        else => execution,
    };
}

fn backendDiagnostic(allocator: std.mem.Allocator, source_path: []const u8, err: anyerror) !diagnostics.Diagnostic {
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
            .help = "Set KIRA_LLVM_HOME or run `zig build fetch-llvm` to install the pinned LLVM toolchain.",
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
        else => .{
            .severity = .@"error",
            .code = "KBUILD999",
            .title = "toolchain build failed",
            .message = try std.fmt.allocPrint(allocator, "Kira hit a toolchain failure while building this program ({s}).", .{@errorName(err)}),
            .help = "Check the toolchain setup and try the build again.",
        },
    };
}

fn backendDiagnostics(allocator: std.mem.Allocator, source_path: []const u8, err: anyerror) ![]diagnostics.Diagnostic {
    const items = try allocator.alloc(diagnostics.Diagnostic, 1);
    items[0] = try backendDiagnostic(allocator, source_path, err);
    return items;
}
