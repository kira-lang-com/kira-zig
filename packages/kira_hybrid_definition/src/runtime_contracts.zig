const runtime_abi = @import("kira_runtime_abi");

pub const RuntimeContract = struct {
    module_name: []const u8,
    entry_function_id: u32,
    entry_execution: runtime_abi.FunctionExecution,
};
