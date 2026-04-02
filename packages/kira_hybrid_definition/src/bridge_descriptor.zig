const core = @import("kira_core");
const runtime_abi = @import("kira_runtime_abi");

pub const BridgeDescriptor = struct {
    bridge_id: core.BridgeId,
    library_id: core.LibraryId,
    symbol_id: core.SymbolId,
    symbol_name: []const u8,
    calling_convention: runtime_abi.CallingConvention,
};
