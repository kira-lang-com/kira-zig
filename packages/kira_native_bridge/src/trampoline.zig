pub const NativeTrampolineFn = *const fn () callconv(.c) void;

pub const Trampoline = struct {
    function_id: u32,
    symbol_name: []const u8,
    invoke: NativeTrampolineFn,
};
