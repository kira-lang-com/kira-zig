const std = @import("std");
const backend_api = @import("kira_backend_api");
const build_def = @import("kira_build_definition");
const bytecode = @import("kira_bytecode");
const pipeline = @import("pipeline.zig");

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

    pub fn buildBytecodeArtifact(self: BuildSystem, request: build_def.BuildRequest) !build_def.BuildResult {
        const compiled = try self.compileVm(request.source_path);
        const backend_request = backend_api.CompileRequest{
            .mode = .vm_bytecode,
            .program = undefined,
            .resolved_native_libraries = request.native_libraries,
        };
        _ = backend_request;
        try compiled.bytecode_module.writeToFile(request.output_path);
        const artifact = build_def.Artifact{
            .kind = .bytecode,
            .path = request.output_path,
        };
        const artifacts = try self.allocator.alloc(build_def.Artifact, 1);
        artifacts[0] = artifact;
        return .{ .artifacts = artifacts };
    }

    pub fn readBytecode(self: BuildSystem, path: []const u8) !bytecode.Module {
        _ = self;
        return bytecode.Module.readFromFile(std.heap.page_allocator, path);
    }
};
