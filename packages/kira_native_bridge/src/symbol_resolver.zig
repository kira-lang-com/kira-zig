const std = @import("std");
const trampoline = @import("trampoline.zig");

pub fn resolveSymbol(library: anytype, symbol_name: [:0]const u8) !trampoline.NativeTrampolineFn {
    return library.lookup(trampoline.NativeTrampolineFn, symbol_name) orelse error.MissingNativeSymbol;
}
