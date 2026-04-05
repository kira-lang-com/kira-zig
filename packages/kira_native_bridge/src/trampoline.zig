const runtime_abi = @import("kira_runtime_abi");

pub const NativeTrampolineFn = *const fn (
    ?[*]const runtime_abi.BridgeValue,
    u32,
    *runtime_abi.BridgeValue,
) callconv(.c) void;

pub const Trampoline = struct {
    function_id: u32,
    symbol_name: []const u8,
    invoke: NativeTrampolineFn,
};
