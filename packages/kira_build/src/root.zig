pub const BuildSystem = @import("build_system.zig").BuildSystem;
pub const VmPipelineResult = @import("pipeline.zig").VmPipelineResult;
pub const compileFileToBytecode = @import("pipeline.zig").compileFileToBytecode;
pub const lexFile = @import("pipeline.zig").lexFile;
pub const parseFile = @import("pipeline.zig").parseFile;
pub const checkFile = @import("pipeline.zig").checkFile;
pub const resolveNativeManifestFile = @import("native_lib_resolver.zig").resolveNativeManifestFile;
