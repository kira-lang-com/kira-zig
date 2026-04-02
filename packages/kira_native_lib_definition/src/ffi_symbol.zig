const runtime_abi = @import("kira_runtime_abi");

pub const NativeSymbol = struct {
    name: []const u8,
    symbol_name: []const u8,
    calling_convention: runtime_abi.CallingConvention = .c,
};
