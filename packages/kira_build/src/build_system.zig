const std = @import("std");
const backend_api = @import("kira_backend_api");
const build_def = @import("kira_build_definition");
const bytecode = @import("kira_bytecode");
const hybrid = @import("kira_hybrid_definition");
const llvm_backend = @import("kira_llvm_backend");
const pipeline = @import("pipeline.zig");
const builtin = @import("builtin");
const runtime_abi = @import("kira_runtime_abi");

pub const BuildSystem = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BuildSystem {
        return .{ .allocator = allocator };
    }

    pub fn check(self: BuildSystem, path: []const u8) ![]const @import("kira_diagnostics").Diagnostic {
        const result = try pipeline.checkFile(self.allocator, path);
        return result.diagnostics;
    }

    pub fn compileVm(self: BuildSystem, path: []const u8) !pipeline.VmPipelineResult {
        return pipeline.compileFileToBytecode(self.allocator, path);
    }

    pub fn compileFrontend(self: BuildSystem, path: []const u8) !pipeline.FrontendPipelineResult {
        return pipeline.compileFileToIr(self.allocator, path);
    }

    pub fn build(self: BuildSystem, request: build_def.BuildRequest) !build_def.BuildResult {
        return switch (request.target.execution) {
            .vm => self.buildBytecodeArtifact(request),
            .llvm_native => self.buildNativeArtifact(request),
            .hybrid => self.buildHybridArtifact(request),
        };
    }

    pub fn buildBytecodeArtifact(self: BuildSystem, request: build_def.BuildRequest) !build_def.BuildResult {
        const compiled = try self.compileVm(request.source_path);
        try compiled.bytecode_module.writeToFile(request.output_path);
        const artifact = build_def.Artifact{
            .kind = .bytecode,
            .path = request.output_path,
        };
        const artifacts = try self.allocator.alloc(build_def.Artifact, 1);
        artifacts[0] = artifact;
        return .{ .artifacts = artifacts };
    }

    pub fn buildNativeArtifact(self: BuildSystem, request: build_def.BuildRequest) !build_def.BuildResult {
        const compiled = try self.compileFrontend(request.source_path);
        const object_path = try defaultObjectPath(self.allocator, request.output_path);
        const backend_result = try llvm_backend.compile(self.allocator, .{
            .mode = .llvm_native,
            .program = &compiled.ir_program,
            .module_name = std.fs.path.stem(request.source_path),
            .emit = .{
                .object_path = object_path,
                .executable_path = request.output_path,
            },
            .resolved_native_libraries = request.native_libraries,
        });

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

    pub fn buildHybridArtifact(self: BuildSystem, request: build_def.BuildRequest) !build_def.BuildResult {
        const compiled = try self.compileFrontend(request.source_path);
        const bytecode_path = try replaceExtension(self.allocator, request.output_path, ".kbc");
        const object_path = try replaceExtension(self.allocator, request.output_path, objectExtension());
        const library_path = try replaceExtension(self.allocator, request.output_path, sharedLibraryExtension());

        const bytecode_module = try bytecode.compileProgram(self.allocator, compiled.ir_program, .hybrid_runtime);
        try bytecode_module.writeToFile(bytecode_path);

        const backend_result = try llvm_backend.compile(self.allocator, .{
            .mode = .hybrid,
            .program = &compiled.ir_program,
            .module_name = std.fs.path.stem(request.source_path),
            .emit = .{
                .object_path = object_path,
                .shared_library_path = library_path,
            },
            .resolved_native_libraries = request.native_libraries,
        });

        const manifest = try buildHybridManifest(self.allocator, compiled.ir_program, std.fs.path.stem(request.source_path), bytecode_path, library_path);
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
        if (function_decl.execution == .inherited) return error.HybridBuildRequiresExplicitExecution;
        try functions.append(.{
            .id = function_decl.id,
            .name = function_decl.name,
            .execution = function_decl.execution,
            .exported_name = if (function_decl.execution == .native)
                try std.fmt.allocPrint(allocator, "kira_native_fn_{d}", .{function_decl.id})
            else
                null,
        });
    }

    const entry_function = program.functions[program.entry_index];
    if (entry_function.execution == .inherited) return error.HybridBuildRequiresExplicitExecution;
    return .{
        .module_name = try allocator.dupe(u8, module_name),
        .bytecode_path = try allocator.dupe(u8, bytecode_path),
        .native_library_path = try allocator.dupe(u8, library_path),
        .entry_function_id = entry_function.id,
        .entry_execution = entry_function.execution,
        .functions = try functions.toOwnedSlice(),
    };
}
