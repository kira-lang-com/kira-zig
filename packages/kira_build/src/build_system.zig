const std = @import("std");
const build_def = @import("kira_build_definition");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const bytecode = @import("kira_bytecode");
const hybrid = @import("kira_hybrid_definition");
const runtime_abi = @import("kira_runtime_abi");
const llvm_backend = @import("kira_llvm_backend");
const pipeline = @import("pipeline.zig");
const builtin = @import("builtin");
const cache = @import("cache.zig");

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
    failure_stage: ?pipeline.FrontendStage = null,

    pub fn failed(self: BuildArtifactOutcome) bool {
        return diagnostics.hasErrors(self.diagnostics);
    }
};

pub const BuildSystem = struct {
    allocator: std.mem.Allocator,
    use_cache: bool = true,

    pub fn init(allocator: std.mem.Allocator) BuildSystem {
        return .{ .allocator = allocator };
    }

    pub fn check(self: BuildSystem, path: []const u8) ![]const diagnostics.Diagnostic {
        const result = try pipeline.checkFile(self.allocator, path);
        return result.diagnostics;
    }

    pub fn checkForBackend(self: BuildSystem, path: []const u8, target: build_def.ExecutionTarget) !pipeline.CheckPipelineResult {
        if (self.use_cache) {
            const maybe_cache = cache.Cache.initForSource(self.allocator, path) catch null;
            if (maybe_cache) |build_cache| {
                const maybe_entry = build_cache.entryForBuild(path, target) catch null;
                if (maybe_entry) |entry| {
                    if (entry.hasCheckSuccess()) {
                        return .{
                            .source = try source_pkg.SourceFile.fromPath(self.allocator, path),
                            .diagnostics = &.{},
                            .failure_stage = null,
                        };
                    }

                    const result = try pipeline.checkFileForBackend(self.allocator, path, target);
                    if (!result.failed()) {
                        entry.storeCheckSuccess() catch {};
                    }
                    return result;
                }
            }
        }
        return pipeline.checkFileForBackend(self.allocator, path, target);
    }

    pub fn checkPackageRoot(self: BuildSystem, source_root: []const u8) !pipeline.CheckPipelineResult {
        return pipeline.checkPackageRoot(self.allocator, source_root);
    }

    pub fn compileVm(self: BuildSystem, path: []const u8) !pipeline.VmPipelineResult {
        return pipeline.compileFileToBytecode(self.allocator, path);
    }

    pub fn compileFrontend(self: BuildSystem, path: []const u8) !pipeline.FrontendPipelineResult {
        return pipeline.compileFileToIr(self.allocator, path);
    }

    pub fn compileForBackend(self: BuildSystem, request: build_def.BuildRequest) !pipeline.ExecutablePipelineResult {
        return pipeline.compileFileForBackend(self.allocator, request.source_path, request.target.execution, request.native_libraries);
    }

    pub fn build(self: BuildSystem, request: build_def.BuildRequest) !BuildArtifactOutcome {
        if (self.use_cache) {
            const maybe_cache = cache.Cache.initForSource(self.allocator, request.source_path) catch null;
            if (maybe_cache) |build_cache| {
                const maybe_entry = build_cache.entryForBuild(request.source_path, request.target.execution) catch null;
                if (maybe_entry) |entry| {
                    if (entry.hasArtifacts()) {
                        return .{ .artifacts = try entry.restoreTo(request.output_path) };
                    }

                    const uncached = try self.buildUncached(request);
                    if (!uncached.failed()) {
                        entry.storeFrom(request.output_path) catch {};
                    }
                    return uncached;
                }
            }
        }
        return self.buildUncached(request);
    }

    fn buildUncached(self: BuildSystem, request: build_def.BuildRequest) !BuildArtifactOutcome {
        return switch (request.target.execution) {
            .vm => self.buildBytecodeArtifact(request),
            .llvm_native => self.buildNativeArtifact(request),
            .hybrid => self.buildHybridArtifact(request),
        };
    }

    pub fn buildBytecodeArtifact(self: BuildSystem, request: build_def.BuildRequest) !BuildArtifactOutcome {
        const compiled = try self.compileForBackend(request);
        if (compiled.bytecode_module == null) {
            return .{
                .source = compiled.source,
                .diagnostics = compiled.diagnostics,
                .failure_kind = if (compiled.failure_stage == .backend_prepare) .build else .frontend,
                .failure_stage = compiled.failure_stage,
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
        const compiled = try self.compileForBackend(request);
        if (compiled.failed()) {
            return .{
                .source = compiled.source,
                .diagnostics = compiled.diagnostics,
                .failure_kind = if (compiled.failure_stage == .backend_prepare) .build else .frontend,
                .failure_stage = compiled.failure_stage,
            };
        }

        const ir_program = compiled.ir_program.?;
        const object_path = try defaultObjectPath(self.allocator, request.output_path);
        const backend_result = llvm_backend.compile(self.allocator, .{
            .mode = .llvm_native,
            .program = &ir_program,
            .module_name = std.fs.path.stem(request.source_path),
            .emit = .{
                .object_path = object_path,
                .executable_path = request.output_path,
            },
            .resolved_native_libraries = compiled.native_libraries,
        }) catch |err| {
            const backend_diagnostics = try pipeline.backendDiagnostics(self.allocator, compiled.source.path, err);
            return .{
                .source = compiled.source,
                .diagnostics = backend_diagnostics,
                .failure_kind = .toolchain,
                .failure_stage = .backend_prepare,
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
        const compiled = try self.compileForBackend(request);
        if (compiled.failed()) {
            return .{
                .source = compiled.source,
                .diagnostics = compiled.diagnostics,
                .failure_kind = if (compiled.failure_stage == .backend_prepare) .build else .frontend,
                .failure_stage = compiled.failure_stage,
            };
        }

        const ir_program = compiled.ir_program.?;
        const bytecode_path = try replaceExtension(self.allocator, request.output_path, ".kbc");
        const object_path = try replaceExtension(self.allocator, request.output_path, objectExtension());
        const library_path = try replaceExtension(self.allocator, request.output_path, sharedLibraryExtension());

        const bytecode_module = compiled.bytecode_module orelse return .{
            .source = compiled.source,
            .diagnostics = compiled.diagnostics,
            .failure_kind = .build,
            .failure_stage = compiled.failure_stage,
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
            .resolved_native_libraries = compiled.native_libraries,
        }) catch |err| {
            const backend_diagnostics = try pipeline.backendDiagnostics(self.allocator, compiled.source.path, err);
            return .{
                .source = compiled.source,
                .diagnostics = backend_diagnostics,
                .failure_kind = .toolchain,
                .failure_stage = .backend_prepare,
            };
        };

        const manifest = buildHybridManifest(self.allocator, ir_program, std.fs.path.stem(request.source_path), bytecode_path, library_path) catch |err| {
            const backend_diagnostics = try pipeline.backendDiagnostics(self.allocator, compiled.source.path, err);
            return .{
                .source = compiled.source,
                .diagnostics = backend_diagnostics,
                .failure_kind = .build,
                .failure_stage = .backend_prepare,
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
            .param_types = try lowerHybridTypeRefs(allocator, function_decl.param_types),
            .return_type = lowerHybridTypeRef(function_decl.return_type),
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

fn lowerHybridTypeRefs(allocator: std.mem.Allocator, types: []const @import("kira_ir").ValueType) ![]hybrid.TypeRef {
    const lowered = try allocator.alloc(hybrid.TypeRef, types.len);
    for (types, 0..) |value_type, index| lowered[index] = lowerHybridTypeRef(value_type);
    return lowered;
}

fn lowerHybridTypeRef(value_type: @import("kira_ir").ValueType) hybrid.TypeRef {
    return .{
        .kind = @enumFromInt(@intFromEnum(value_type.kind)),
        .name = value_type.name,
    };
}
