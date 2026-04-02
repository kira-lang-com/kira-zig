const native = @import("kira_native_lib_definition");

pub fn resolveSymbol(_: native.ResolvedNativeLibrary, _: []const u8) !usize {
    return error.NotImplemented;
}
