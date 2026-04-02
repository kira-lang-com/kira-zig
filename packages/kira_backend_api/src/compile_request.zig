const ir = @import("kira_ir");
const native = @import("kira_native_lib_definition");

pub const BackendMode = enum {
    vm_bytecode,
    llvm_native,
    hybrid,
};

pub const CompileRequest = struct {
    mode: BackendMode,
    program: *const ir.Program,
    resolved_native_libraries: []const native.ResolvedNativeLibrary = &.{},
};
