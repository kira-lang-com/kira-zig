const core = @import("kira_core");
const runtime_abi = @import("kira_runtime_abi");

pub const BridgeDescriptor = struct {
    bridge_id: core.BridgeId,
    function_id: core.SymbolId,
    symbol_name: []const u8,
    source_execution: runtime_abi.FunctionExecution,
    target_execution: runtime_abi.FunctionExecution,
    calling_convention: runtime_abi.CallingConvention,
};
