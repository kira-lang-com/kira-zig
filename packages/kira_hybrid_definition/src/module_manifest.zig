const runtime_abi = @import("kira_runtime_abi");

pub const HybridModuleManifest = struct {
    module_name: []const u8,
    runtime_mode: runtime_abi.ExecutionMode,
};
