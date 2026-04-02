const runtime_abi = @import("kira_runtime_abi");

pub const RuntimeContract = struct {
    module_name: []const u8,
    execution_mode: runtime_abi.ExecutionMode,
    allows_vm_fallback: bool = true,
};
